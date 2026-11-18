# SEC-02 · Carry peer auth: a paired device proves its key, not its name

From: T-0121, T-0122, T-0123; PLAN-1118 §3 (owner 2026-11-18) ·
Guards: FEAT-09 (P1, P1b, P4), FEAT-02, BUG-17, BUG-26 ·
Status: [~] building (A3: P3, P1, P2 on one branch; device check owed)

## 1 · Threat model
Who can reach the transport (MultipeerConnectivity: Wi-Fi, AWDL peer-to-peer, Bluetooth):
- **A neighbour** in radio range running any MC app with service type `recense-p2p`.
- **A renamed impostor:** a device whose name is set to a paired device's name ("Chau's iPad").
- **A stolen or reset device** that was paired: it holds a real identity key (stolen), or none (reset).
- **A relay in the middle** between two of the owner's devices.

What each can do today (proven by reading the code, 2026-11-18; not run):
- Trust is by name.
  `carrymanager.swift:118-121` (`isPaired`) and `:208-209` (`pairedConnected`) compare `displayName` only.
- The transport encrypts but does not authenticate.
  `p2ptransport.swift:16` uses `securityIdentity: nil`.
  `:140` accepts any invitation from a paired name; `:152` invites any peer with a paired name.
- **Theft:** an impostor sends `seen 0`.
  `receiveSeen` (`carrymanager.swift:416-433`) answers with this device's whole ops log and the bytes of every file.
- **Tampering:** `ops` (`:466`) and `gone` (`:437`) from that name settle on this disk (moves, fetches, replaces).
- **Escape (assumed, not run):** `library/Music/../../x` passes `CarrySync.split` (`carrysync.swift:95-101`);
  `CarryApply.locate` (`carryapply.swift:14`) joins it to `Homes.root` unnormalised: a write outside `~/Recense/`.
- **Swapped bytes:** `landed`/`tryPlace` (`carrymanager.swift:514-538`) place a file without checking its SHA-256 against the op's.
- `invitationProof` (`carrypair.swift:133`) exists, but only the selftest calls it (`:387`).

What must be impossible after (each is an invariant in §4):
- A device not holding a paired identity key gets no ops, no bytes and no effect on disk, whatever its name.
- A captured message, replayed or reflected, has no effect.
- A forgotten (revoked) device is refused like a stranger.
- No op or file ever lands outside `~/Recense/`, and no file whose hash differs from its op lands at all.

## 2 · Design
Terms: **SAS** = the six digits compared or typed; **MAC** = a checksum only the key can make or check.

### 2.1 What pairing produces (unchanged ceremony, one new store)
- Pairing stays exactly as FEAT-09 P1/P1b: X25519 identity keys, confirmed by the SAS (commitment, or passkey rounds).
  The SAS already binds both public keys, so `Paired.key` is an authenticated long-term key.
- New: the **trust store**, Keychain item `local.recense.carry` / account `peers.v2`.
  It holds JSON `[CarryPeer]` (name, key, paired). Its access is `AfterFirstUnlockThisDeviceOnly`, and it never syncs to iCloud.
- Only the trust store decides trust. `peers.json` stays as a readable mirror, and nothing reads trust from it.
  Why: a plain file can be edited by any process.
- A peer's name is a label only. Every check matches on `key`.
- The group secret keeps its FEAT-09 role (one group, `sameGroup`). Carry auth does not use it.

### 2.2 Invitation (invitationProof kept, as a pre-filter)
- Inviting a trusted peer: `context = myKey(32) ‖ nonce(16) ‖ invitationProof(me, peer.key, nonce)(32)`.
  This replaces `withContext: nil` at `p2ptransport.swift:80` and `:152`.
- The advertiser auto-accepts only when the key is in the trust store and the proof verifies.
  Otherwise it falls back to `confirmUnpaired` (pairing mode only).
- A pre-filter only: a replayed context gets a connection, then fails 2.3.

### 2.3 Every session: mutual handshake (Noise-KK-like, described, not copied)
1. On `.connected`, or right after `finish()`, each side sends plain `auth` `.hello(key, eph, nonce)`.
   `eph` is a fresh X25519 key and `nonce` is 32 random bytes, both made new for every session.
2. Look `key` up in the trust store. Unknown key: no channel.
   If not pairing with this peer, disconnect it and set `lastError` (see 2.6).
3. `ikm = X25519(me, them) ‖ X25519(myEph, theirEph)`.
   `th = SHA-256("recense.carry.th.v1" ‖ lower(key,eph,nonce) ‖ higher(key,eph,nonce))`, ordered by static key bytes.
   `HKDF-SHA256(ikm, salt: th, info: "recense.carry.session.v1", 96)` → `kConfirm`, `kLowHigh`, `kHighLow`.
4. Each side sends `.proof(HMAC(kConfirm, "recense.carry.proof.v1" ‖ role ‖ th))`, with role 0 for the lower key and 1 for the higher.
   Each checks the other's proof with the other's role.
5. The peer is authenticated once its proof is valid. The 10 s timer starts at `.connected` (2.6).
   Why the ephemeral keys: a stolen identity key cannot open sessions recorded before the theft (forward secrecy).

### 2.4 Every later message: sealed, counted
- `seen`, `ops`, `gone` and `forget` travel only inside plain type `sealed`.
- The payload is `{n: UInt64, box}`, where `box = ChaChaPoly.seal(JSON(Frame{type,payload}))`:
  - key: the sender's direction key;
  - nonce: `0x00000000 ‖ n` (big-endian);
  - authenticating data: `"recense.carry.sealed.v1"`.
- `n` starts at 1 on each side in each session. The receiver drops any frame with `n ≤ last`, or one that fails to open.
- Plain `seen`/`ops`/`gone` are dropped, no fallback. An older build ignores `auth` (`carrymanager.swift:136`): no carry, no loss.
- Before acting, each handler checks that the sender is an authenticated channel for its `MCPeerID`, and that the frame opened.
  It then keys state (`appliedSeq`, `waiting`, `received`) by the **trust-store name**, never `displayName`.
- Files (`sendResource`) are not sealed. A file is placed only when all of these hold:
  - its key is in `waiting` with this same peer;
  - its staged SHA-256 equals the authenticated op's `sha256`;
  - otherwise it is discarded and stays owed.
- Key safety: `CarrySync.safeKey` refuses empty, `.` and `..` components, a leading `/`, `\` and NUL.
  It runs in `split`, so every op key and every resource name is checked.

### 2.5 Revocation
- **"Forget <device>"** has one visible control on each surface:
  - iOS: Library › Devices, row › Forget;
  - Mac: Devices menu › Forget;
  - voice: "Forget device";
  - Terminal: `recense carry forget <name>`.
- Forgetting removes the entry from the trust store and from `peers.json`.
  - If the peer is connected, a sealed `forget` goes first, then it is disconnected.
  - The Terminal's `recense carry forget` has no link of its own (the running app holds it), so it cannot send
    the sealed `forget`. It says so: "Forget it on <name> too", and the running app drops that peer on its next frame.
  - The receiver removes the sender's key and shows "<name> unpaired this device".
- **Lost device:** forget it on each remaining device, no forwarding (open question 1); its key is then refused there.
- Data on forget: local files, ops logs and `appliedSeq` are kept. Staged bytes owed by it are discarded.

### 2.6 Migration and visible states
- First launch with SEC-02: `peers.v2` is absent. Old `peers.json` entries are not trusted, even though they hold keys.
  Why: `peers.json` was never protected, and BUG-17 left one-sided entries.
- Each old entry shows "Pair again to keep carrying" (Devices row, status, CLI); carry with it pauses.
  Files, ops logs and `appliedSeq` are untouched: nothing is lost.
- Re-pairing (the existing "Pair a device") writes `peers.v2`, and carry resumes from `appliedSeq` with no full re-send.
- These cases set `lastError` and list the device under "Needs pairing again":
  - a trusted name with an unknown key (a reset device, or an impostor);
  - a handshake that gives no valid proof within 10 s.

## 3 · Constraints
- CryptoKit (X25519, HKDF, HMAC, ChaChaPoly, SHA256) and Security (Keychain) only. No third-party crypto.
- Offline-first gate: outside services: none. No server, no account, nothing at the moment of use.
- One copy in `shared/`, built by the Mac and iOS alike. The new file is `shared/carryauth.swift`.
  - It is pure (messages in, messages out, no radio), so plain `swiftc` tests reach it.
  - Mac: add the symlink `strip/Sources/recense/carryauth.swift -> ../../../shared/carryauth.swift`.
  - iOS: picked up by the synchronized `../../shared` group (`project.pbxproj:9`).

## 4 · Invariants (tested: `mobile/ios/Tests/carryauth/main.swift`)
Run: `swiftc -O shared/carrypair.swift shared/carryauth.swift mobile/ios/Tests/carryauth/main.swift -o "$TMPDIR/carryauth" && "$TMPDIR/carryauth"` (ALL OK).
1. **Honest pair:** two trusted keys complete the handshake in both orders, and sealed `ops` open byte-equal on the other side.
2. **Wrong key:** a hello whose key is not in the trust store gives no channel and no proof.
3. **Renamed impostor:** its own key and a trusted peer's name → refused, and the trusted entry is unchanged.
4. **Replay:** a sealed frame delivered twice opens once.
   A frame captured in session 1 fails in session 2. A frame reflected back to its sender fails.
5. **Tamper:** one flipped bit in `box`, `n` or the proof → refused.
6. **Relay:** a middle device replacing `eph` or `nonce` makes both proofs fail; relaying unchanged lets it read nothing.
7. **Revoked:** after `forget`, the same key's hello is refused, and a received `forget` removes the sender.
8. **Invitation:** the right key and proof are accepted. Another key, a changed nonce or no context means no auto-accept.
9. **Migration:** with `peers.json` entries and no `peers.v2`, nobody is trusted and each entry is listed as needing pairing.
10. **Safe keys:** `../`, `/abs`, `a//b`, `.` and a NUL each give `split == nil`, and `CarryApply` throws `badKey` before any file call.
11. **Bytes check:** a staged file whose SHA-256 differs from its op's is not placed, and the op stays owed.
    Test it in `mobile/ios/Tests/carrysync/main.swift`, or the carryapply selftest.
12. **Pairing UI:** `PairPrompt` gains pure reducers, tested in `mobile/ios/Tests/carrypair/main.swift`:
    - T-0121: disconnecting the prompt's peer clears `askingCode` and `pairingWith`; another peer's disconnect clears nothing;
    - T-0123: re-picking an already-connected peer updates `picked`, so that side shows the code;
    - T-0122 (AppKit, no pure test): device check on the Mac: close the pairing window with X, then open it again from the menu.

13. **Keychain read error ≠ no peers:** a Keychain read is found, not found, or failed (`CarryStored`).
    A failed read of `peers.v2` keeps the trust store this process last had, and `writable` is false:
    pair, forget and re-pair refuse to write `peers.v2` (and its mirror) and set `lastError`. A failed read of
    `identity` never makes and saves a new key. Only "not found" starts empty. A failed read lists nobody new under
    "Needs pairing again" (the list stays as it was; never re-pair during a Keychain failure), and the
    unreadable message clears once every read works again.
14. **Keychain save in place:** saving updates the item (`SecItemUpdate`); only `errSecItemNotFound` adds it.
    No save ever deletes first, so a failed add can't leave the store empty; any other update error saves nothing.
15. **The 10 s proof deadline is per session:** each handshake session gets its own token (`CarryDeadlines`).
    A timer acts only if the peer's current session still carries its token, so a timer from an earlier
    connection never judges a reconnect early. While pairing, a timer does nothing; "Stop Pairing" re-arms
    10 s for every hello still held, so a stranger left unpaired is refused (unknown key) instead of waiting forever.
    A finished pairing ends pairing too: it re-arms every other held hello the same way (glue: no pure test reaches it).
16. **"Needs pairing again" never lists a trusted name:** a name that still has a trusted key is left out of the
    list (`CarryTrust.listed`), whether it came from `peers.json` or from a refused connection (an impostor or a
    reset device using that name). So no Forget on that list can un-trust the real device; its own row's Forget still can.
17. **Bytes being hashed are never swept:** the `.check` copy of a staged file keeps the file's old mtime, so
    `CarrySync.orphans` treats `<name>.check` as expected whenever `<name>` is, and the sweep counts keys in
    `placing` as expected. A `.check` nobody expects (left by a crash) is still swept. Tested in `Tests/carrysync`.
18. **Forget says what the other side still knows:** when no sealed `forget` was sent (`CarryForget.reply`,
    told = false: the CLI, or the peer not connected), the reply names the device and says "Forget it on <name> too".
19. **Nothing runs on a Keychain this launch could not read** (`CarryKeychainGate`, review of d730ee6):
    - an unread identity (a stand-in key) never pairs, advertises or starts a handshake, so no peer ever stores it;
    - an unread `group` secret never pairs (a pairing would save a peer's or a new group over it), and a pairing
      saves the group only after `peers.v2` was saved;
    - Forget checks it can write `peers.v2` before it sends the sealed `forget`: otherwise it sends nothing, keeps
      the peer, returns false and sets `lastError`, and every surface (voice included) shows that error;
    - an unread identity is read again (`CarryIdentityRead`) on each reload and on coming to the front, while no
      session or pairing runs; once read, the real key is taken and the link starts if it was asked for.
      Only "not found" makes a new key; a failed read never does;

Mutation check: drop `th` from the proof, or drop the `n` check, and 4 or 6 must go red.

## 5 · Phases
**P1 · Handshake + sealed messages + key safety** (~400 lines: ~180 new carryauth, ~200 tests, ~90 glue)
- Files: `shared/carryauth.swift` (new); `shared/carrymanager.swift` (routing, trust store, `pairedConnected` =
  authenticated, state keyed by trusted name); `shared/p2ptransport.swift` (invite context; `isPaired` takes it);
  `shared/carrysync.swift` (`safeKey`); `shared/carryapply.swift` (hash check); the symlink; the test; FEAT-09 Checks.
- Done: invariants 1–6, 8, 10, 11 pass; `zsh strip/build.sh` + `strip/recense selftest` exit 0;
  the iOS `xcodebuild … CODE_SIGNING_ALLOWED=NO build` passes.
- Device check: re-pair Mac↔iPhone once, carry a canary file; then rename the iPad to the Mac's name: nothing carries.

**P2 · Revocation + migration states** (~150 lines)
- Files: `carryauth.swift` (`forget`); `carrymanager.swift` (`forget(peer)`, `peers.v2` first-launch rule);
  iOS Library › Devices row; Mac Devices menu (`strip/`); `PairIntent.swift` ("Forget device"); CLI `recense carry forget`.
- Done: invariants 7 and 9 pass.
  Each surface's Forget control is screenshotted and passes the UI audit. Forgetting the iPad on the Mac stops carry both ways.

**P3 · Pairing UI fixes T-0121, T-0122, T-0123** (~40 lines)
- Files: `shared/carrypair.swift` (`PairPrompt` reducers), `carrymanager.swift` (`connected`, `invite`), `strip/paircode.swift` (willClose → `panel = nil`).
- Done: invariant 12 passes. The T-0122 device check passes on the Mac. Each triage entry gets `FIXED · <commit>`.
- P3 shares no logic with P1/P2, so it may merge first.

## 6 · Risks and edge cases
- Proven (read): today any name-match peer can read every file and change the disk (§1), until P1 ships.
- Assumed: MC `.reliable` delivers in order. `n > last` (not `== last+1`) is safe even if it does not.
- Assumed: the Terminal CLI and the app share the Keychain item (same binary); check `recense carry pair`, app closed.
- Assumed: path escape via `..` works on disk (it has not been run). The fix is cheap whether or not it does.
- Untested: stolen key with the device still trusted. It can authenticate to the others until they forget it (§2.5).
  It can also impersonate other peers to its own copy of the app (key-compromise impersonation), which is harmless.
- Untested: two trusted devices with one name: both work (trust is by key); rows show the paired date.
- Untested: version skew (one side on SEC-02): no carry, status "Update Recense on <name>", nothing lost.
- Edge: re-pairing a device with a new key replaces its old key (`CarryPeer.replacing`), so the old key is refused from then on.
- Edge: the owner must re-pair every pair once (Mac↔iPhone, Mac↔iPad, iPhone↔iPad if they carry directly).
- Out of scope: `op.device` is not tied to the sender; a trusted (owner's own) peer could relay made-up ops.

## Open questions (owner)
1. Should forgetting a lost device on one device forward the forget to the owner's other devices?
   Default: no. Forwarding would let a stolen device unpair the real ones.
2. Should SEC-02 trust the keys already in `peers.json` (they were SAS-confirmed) to skip the one re-pair?
   Default: no.

## Amendments
- 2026-11-18 · written (A3 design lane).
- 2026-11-18 · building (A3). Where the tests live: invariant 10 (`split`) in `Tests/carrysync`, since `split` is in
  carrysync.swift; 10's `badKey` and 11 in `carrymanagerSelftest`. Mutation check run: dropping the `n` check turns 4 red;
  dropping `th` from the proof alone stays green, because `th` also salts the HKDF (kConfirm differs anyway); dropping it
  from both turns 6 (relay replaced nonce) red. While pairing, a not-yet-trusted hello and any `auth` after it are held,
  in order, and answered once the pairing finishes (a proof that came first was otherwise lost). T-0123 also needed the
  failed pick cleared on both sides (`PairPrompt.failed`), or both sides stay "picked" and the greater key keeps showing.
- 2026-11-18 · follow-ups (A3-fix, review of 80ad4c0): 13 Keychain read error keeps pairings and refuses writes.
  14 Keychain save updates in place, adds only when not found.
  15 the proof deadline is per session (token); Stop Pairing re-arms held hellos.
  16 Needs pairing again leaves out names that still have a trusted key.
  17 a .check copy being hashed is never swept.
  18 §2.5: `recense carry forget` sends no sealed forget; it prints "Forget it on <name> too".
  19 (review of d730ee6) a stand-in identity never pairs, advertises or proves.
