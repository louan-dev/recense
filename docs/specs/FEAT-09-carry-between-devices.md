# FEAT-09 · Carry between devices: pair once, then the same homes everywhere

From: owner 2026-11-11 (carry, `.handoff/places/INBOX.md` L29–47) · owner 2026-11-14 (stable core for music and
self-study, Phase 1) · T-0035 · T-0047 · Status: `[~]` (P1 pairing + P2/P3/P4 settling built and wired end to
end, real-device check owed; conflict text-merge against a tracked base is the one piece of P3 still open)

## Glue, built 2026-11-14/15 (`shared/carrymanager.swift`, `shared/carryapply.swift`)
- Pairing (P1) is wired end to end: "Pair a Device…" (Mac menu, iOS Devices screen, `recense carry pair` in
  Terminal, or the "Pair a device"/"Confirm pairing" voice commands) opens this device to the next stranger
  that connects within P2PTransport's 10 s invite timeout; the six-digit code is shown (or read back) on both
  sides; "They Match" seals and stores the group secret in the Keychain, alongside the identity key, and
  records the peer in `peers.json`.
- "Carry Now" (P2–P4) scans into this device's own append-only ops log and settles the real way: it exchanges
  "how much of yours have I applied" with every paired, connected device, sends the ops the other lacks plus
  the bytes those ops need, and the receiving side decides each one with `CarrySync.decide` and carries it out
  with `CarryApply.apply` — fetch, replace (old to `trash/`, origin recorded), keep both as a named sibling, or
  a plain local move for a replayed move/trash/restore. Never overwrites. `CarryApply.apply` is the one place
  that touches the file system for a settled action, tested without any radio (`carrymanagerSelftest`).
- **Still open, said plainly rather than hidden:** a real conflict (both sides changed since the last common
  point) always keeps both, because no base is tracked yet for the 3-way text merge `shared/notesync.swift`
  already knows how to do — a merge would be strictly better for Draftpad's own pages, but keep-both never
  loses a line either way. Starting automatically when two paired devices meet (rather than only on "Carry
  Now") is also still open, the same deliberate choice the first glue slice already made.
- Files move over `P2PTransport.send(fileAt:)` directly, not through `shared/pieces`'s resumable chunks — fine
  for Homes' sizes today; swapping it in later changes nothing public in `carrymanager.swift`.
- If two devices are each already in a *different* group, pairing refuses rather than merging them (no wire
  message yet compares group fingerprints before the secret is sent). Cannot happen on a first pairing.
- Ops and the bytes they need can arrive in either order (two separate MultipeerConnectivity channels): every
  incoming file is staged under `.carry/incoming/` by its destination key first, and placed only once the
  matching op has been decided, from whichever side — the op or the bytes — arrives second.

## Why
Your music, study files and downloads must be the same on the Mac, iPhone and iPad, with no internet and no
company in the middle. Today each device keeps its own `Recense/` homes and nothing moves between them.

## Built `[x]` (what this spec stands on)
- Homes and the exit: `shared/homes.swift` (FEAT-06, 3718a5b): every home, `.recense-index.json` per home,
  remove → `trash/` with its origin, `Carry.verify()` (one line per file: home, path, size, mtime, sha256, device),
  `Carry.move(to:)` (copy, verify every sha256, receipt; source kept).
- Bytes: `shared/pieces` (X1, aee6aec): a file cut into encrypted, fingerprinted pieces; `servePiece`, `Download`
  (resume from the pieces already held).

## Three layers, one stack (no second copy of any)
- **Link** = FEAT-02 (`shared/p2ptransport.swift`): MultipeerConnectivity finds the device and opens an encrypted
  session over Bluetooth or peer-to-peer Wi-Fi. No router, no internet.
- **Bytes** = `shared/pieces`.
- **Meaning** = this spec: who is paired, what changed, how differences settle.

## Planned `[ ]`

### P1 · Pair once (numeric comparison, as Bluetooth does)
- Each device holds one long-term key pair (CryptoKit Curve25519), in the Keychain, this device only.
- "Pair a device" (button, menu item, voice) on both: they exchange public keys over the link. The side with the
  greater key commits first: `SHA-256("recense.pair.commit.v1" ‖ its key ‖ other key ‖ its nonce)`; the other
  reveals its nonce only after the commitment arrives; then the committer reveals and is checked. Each computes
  `code = SHA-256("recense.pair.v1" ‖ revealer key ‖ its nonce ‖ committer key ‖ its nonce ‖ shared secret)` →
  first 4 bytes mod 1,000,000, shown as 6 digits. You tap "They match" on both screens. Nothing is typed.
  Why the commitment: without it a device in the middle could try keys until both codes match (a million tries
  takes seconds); with it, it gets one guess in a million (Bluetooth Secure Simple Pairing does the same).
- Then the group secret (32 random bytes) is sent sealed (ChaChaPoly) with a key derived from the shared secret
  (HKDF-SHA256, salt = the pairing transcript, info `recense.group.v1`), and kept in each Keychain. The device
  that has a group sends it; if neither has one, the committer makes it. Two devices already in different groups
  are refused (compared by an HMAC fingerprint; neither secret crosses the link).
- **Invariant (BUG-17):** pairing finishes on BOTH devices, or on neither. The tap and the sealed group can come in
  either order. A group that arrives before this device's own tap is held, and the tap opens it. The `hello` says
  whether its sender already holds a group, so exactly one side sends one. While "Pair a device" is on, a peer
  already in `peers.json` pairs again, and the new entry replaces the old one (a one-sided pairing can be redone).
  Either device may start first: a picked device that has not answered is invited again every 11 s.
  Each side answers the first hello with its own again, so a hello lost before the other side was looking is
  replaced. Two devices that already hold the same group pair by comparing fingerprints. The pair list shows
  each device once.
- `Recense/.carry/peers.json`: name, public key, paired date (no secrets).

### P1b · Pair by typing the code (passkey entry) — `[ ]` · From: T-0086 (owner 11-15: "type the code")
- One action pairs: one device shows six digits, you type them on the other. No "They Match" on either.
- Who shows: the device on which you picked the other's name. If both or neither picked, the greater public key shows.
  Each `hello` carries `picked: Bool`, so both decide alone and agree.
- The passkey $r$: 6 random digits, fresh for every attempt, never derived, never reused. $0 \le r < 10^6 < 2^{20}$.
- 20 rounds, one per bit $r_i$ of $r$ (Bluetooth LE Secure Connections' passkey entry, described, not copied):
  - each side picks a fresh 16-byte nonce $N$;
  - the shower sends $C_s = \mathrm{HMAC}_{N_s}(\text{"recense.passkey.v1"} \| PK_s \| PK_t \| r_i)$, the typer sends $C_t$ likewise;
  - the shower reveals $N_s$; the typer checks $C_s$ with its own $r_i$, then reveals $N_t$; the shower checks $C_t$;
  - any mismatch: refuse, show "Code didn't match", and the next attempt draws a new code.
- Why rounds: one commitment over the whole code lets a device in the middle try all $10^6$ codes offline after one
  run. Committing bit by bit means it must guess each bit before seeing it: success $2^{-20}$ per attempt.
- After round 20 both sides are authenticated. Transcript = SHA-256 of every round's nonces, in order. The group is
  sealed as in P1 (HKDF salt = transcript), or compared by fingerprint when both hold one. The shower needs no tap.
- The typer waits for the typed code before round 1; typing starts the rounds.
- Where you type or read it:
  - iPhone/iPad: Library › Devices shows the code large, or a 6-digit field (number pad).
  - Mac: a small window (Recense is LSUIElement, so its menu is hidden): the code large, or a 6-digit field.
  - Voice: "Enter pairing code 123456" (App Intent with the number as a parameter).
  - Terminal: `recense carry pair` prints or asks (only while the app is closed, BUG-17).
- Numeric comparison (P1) stays in code for an older peer's hello without `picked`; new builds always type.
- **Invariants (tested, `mobile/ios/Tests/carrypair/main.swift`):** the right code pairs both, in either role; a
  wrong code refuses both; a device in the middle with its own keys refuses (each leg's codes differ); a new attempt
  draws a new code; the group rules of P1 hold unchanged.
- **Invariant:** a device not in `peers.json` gets no session: its invitation carries a nonce and an HMAC of it
  under a key derived from the pairwise X25519 secret (info `recense.invite.v1`); a stranger can't make it (tested).

### P2 · What changed: one append-only log per device
- `Recense/.carry/ops/<device>.jsonl`; each line: `seq, device, at, op, home, path, toHome?, to?, sha256, size`
  (home/path = where the file was; toHome/to = where it went, for move, trash and restore).
- `op` is `put` (new or changed bytes), `move` (same bytes, new path), `trash` (moved into `trash/`),
  `restore` (back out of `trash/`). **There is no delete op.** "Delete forever" stays on the device where you did it.
- A device writes its own ops by comparing a fresh `Carry.verify()` scan with the last one it saved
  (`Recense/.carry/last.jsonl`): new path → put; same sha at a new path with the old gone → move;
  gone and present in `trash/` with that origin → trash.

### P3 · Settling (pure rules, tested without radios)
- Two devices exchange `{device: last seq seen}` (the seen vector, kept in `Recense/.carry/seen.json`) and send
  each other the ops the other lacks.
- Apply, per op, in seq order per device:
  - `put` on a path you don't have → fetch the bytes (pieces), write, record.
  - `put` with the sha you already have → nothing.
  - `put` on a path whose local file is unchanged since the base → the old version goes to `trash/` (with origin),
    the new one lands. **Never overwrite.**
  - Both sides changed since the base (a conflict):
    - text (`.md`, `.txt`) → `shared/notesync.swift` 3-way merge against the base;
    - anything else → keep both: `name (iPad 2026-11-14 1605).ext` beside it (notesync's one sibling namer, with
      the device's name and the file's own extension; Draftpad's own name is unchanged).
  - `move` / `trash` / `restore` → replayed only if the local file still has the op's sha; else nothing moves and
    the difference shows as a conflict sibling.
- The base is the last version both sides agreed on: `Recense/.carry/base/<sha256>` for text files only.
- **Built (P4, 2026-11-15) stands on the rules above but doesn't yet track a base:** `CarryManager`/`CarryApply`
  call `CarrySync.decide(..., base: [:], ...)`, so "unchanged since the base" and the text 3-way merge never
  fire yet — every real conflict settles as keep-both today, always safe, sometimes a sibling where tracking a
  base would later let a clean edit land without one. Base-tracking is the next slice, not a rewrite: `decide`
  already does the right thing the moment a real `base` dictionary is passed in.
- Replaying the same ops twice changes nothing (idempotent): ops at or below the seen vector's seq are skipped, and
  each decision is "nothing" once its result is in place. The vector is the guard: without it, a put replayed after
  its own move and trash would bring the file back (tested).

### P4 · When it runs — built
- "Carry now" scans into this device's own append-only ops log (`Recense/.carry/ops/<device>.jsonl`,
  `CarrySync.ops`), then settles with every paired, connected device: "how much of yours have I applied"
  (`seen`) → the ops the other lacks (`ops`) → the bytes those ops need, over FEAT-02's link. A move, a trash or
  a restore replays correctly on the other side — not just a plain file push (`shared/carrymanager.swift`,
  `shared/carryapply.swift`). A real conflict (both sides changed, no tracked base yet) always settles the safe
  way, keeping both as named siblings, rather than merging — the one piece of P3 still open, named honestly.
- **Automatic — `[~]` (built and tested; device check owed) · From: T-0084 (owner 11-15: "i dont want to carry now, i want it to be automatic").**
  - A paired peer connects: carry starts within 2 s.
  - While connected, a home changes (new file, rename, trash, restore): carry after 2 s of quiet (debounce).
    Mac: an FSEvents stream on `~/Recense` (homes only, `.carry/` ignored). iOS: Homes' own changes post
    `Homes.changed`; Files-app changes are caught on the next foreground.
  - iOS: Recense comes to the front: carry.
  - One carry at a time. Triggers during a carry fold into one follow-up carry after it.
  - The scan runs off the main thread, so playing, reading and writing never wait.
  - A file whose size and mtime match the last manifest reuses its SHA-256; only new or changed files are hashed.
  - Carry Now stays as the visible retry and shows its result ("Up to date", "Settled 3 changes", the error).
  - Pure scheduler `CarrySchedule` (`shared/carrysync.swift`): events in, "run now / at t" out; tested without radios.
  - **Invariants (tested, `mobile/ios/Tests/carrysync/main.swift`):** connect → a run within 2 s; ten changes
    0.5 s apart → one run, 2 s after the last; a trigger during a run → exactly one follow-up; foreground → a run;
    no paired peer connected → no run; after the last peer leaves, a change waits; Carry Now runs at once
    (it reports its own result). `Carry.verify(reuse:)` keeps an unchanged file's hash and re-hashes a changed one
    (`recense selftest`). Timing as built: connect and foreground 0.5 s, quiet 2 s.
  - Launch counts as coming to the front: `onChange(of: phase, initial: true)`; a cold launch is already `.active`
    (iPad 11-15: a plain `onChange` never fired, so its link never started).
  - Device check 11-15 19:59 ✓ (connect and launch): the iPad and iPhone filled Library › Music from the Mac with no tap.
    Owed: a song saved on the Mac while connected reaches the iPhone with no tap (the change trigger).
- A dropped link resumes from the pieces already held (`shared/pieces`) — not yet wired into this path; today a
  dropped link's file resends from the top, acceptable for the sizes Homes carries so far.
- iOS: while Recense is open, plus the background processing window. Never blocks playing, reading or writing.
- Device check (owner 11-15): a Pulltube song saved on the Mac shows in the iPhone's Library › Music with no tap.

### P5 · Where you see it
- "Devices" (Settings, menu, voice "devices"): paired devices, last carry time, what is waiting; "Pair a device";
  "Carry now". One control per function.
- `recense carry pair` (Mac Terminal, reachable from the iPhone/iPad over SSH, Library › Terminal): the same
  pairing exchange as the menu, for when the owner is at a keyboard, not the mouse — prints the six-digit code,
  waits for Enter in place of tapping "They Match". The owner still looks at both screens; the code is not skipped.

## Out of scope here
- Draftpad's vault (`draftpad.md`) keeps its current sync until a later slice brings it under carry.
- The folder carrier (USB stick, iCloud Drive, WebDAV as a dumb pipe; `private/` refused) = FEAT-09 P6, later.

## Code layout
- `shared/carrysync.swift`: P2 + P3, pure Swift, no radios (ops, scan diff, settling, conflict names).
- `shared/carrypair.swift`: P1's messages, code, group sealing and invitation proof; pure (CryptoKit), no radios.
- `shared/p2ptransport.swift`: FEAT-02 link + P1 pairing.
- `shared/carrymanager.swift`: the glue — starts the link, runs pairing, orchestrates "Carry Now" (the ops-log
  scan and the `seen`/`ops` exchange). One copy, used by the Mac's Devices menu + `recense carry pair`
  (`strip/app.swift`) and the iOS Devices screen + voice intents (`mobile/HostApp/iOS/Devices.swift`,
  `mobile/HostApp/iOS/PairIntent.swift`).
- `shared/carryapply.swift`: carries out one already-`decide`d action against this device's homes (fetch,
  replace, keep-both, or a plain move) — the only place that touches the file system for a settled change,
  tested without any radio (`carrymanagerSelftest`).

## Done checks
- `swiftc -O shared/notesync.swift shared/carrysync.swift mobile/ios/Tests/carrysync/main.swift -o "$TMPDIR/carrysync" && "$TMPDIR/carrysync"`
  (ALL OK); `swiftc -O shared/carrypair.swift mobile/ios/Tests/carrypair/main.swift -o "$TMPDIR/carrypair" && "$TMPDIR/carrypair"`
  (ALL OK: same code on both, a device in the middle never matches in 300 runs, forged nonce and stranger refused) — 2026-11-14 ✓.
- `strip/recense selftest`, exit 0 (includes homesSelftest, carrysyncSelftest, carrypairSelftest, and
  `carrymanagerSelftest` — fetch, replace with the old version landing in `trash/`, keep-both, and a move that
  carries its index across homes, all exercised with no radio) — 2026-11-15 ✓.
- `zsh strip/build.sh`; iOS compile (GalleryFiles + RecenseGuest), both BUILD SUCCEEDED — 2026-11-15 ✓.
- **Not yet checked (owner, real devices), the one gap left:** pair a Mac and an iPhone or iPad for real;
  airplane mode on with Wi-Fi and Bluetooth on; add, move, trash and restore a file on one device and watch
  "Carry Now" settle it correctly on the other within the session, with the three `recense carry verify`
  manifests matching afterward.

## Offline gate
- Outside services: **none.** Radios on the devices only; no account, no internet, no company.
