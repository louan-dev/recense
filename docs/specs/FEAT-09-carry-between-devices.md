# FEAT-09 · Carry between devices: pair once, then the same homes everywhere

From: owner 2026-11-11 (carry, `.handoff/places/INBOX.md` L29–47) · owner 2026-11-14 (stable core for music and
self-study, Phase 1) · T-0035 · T-0047 · Status: `[~]` (P1 pairing core, P2/P3 rules, the glue and the Devices
screen built; P2/P3's full settling — move/trash/restore replay, conflict merge — not yet wired into the glue)

## Glue, built 2026-11-14 (`shared/carrymanager.swift`)
- Pairing (P1) is wired end to end: "Pair a Device…" on the Mac menu (Devices) and the iOS Devices screen opens
  this device to the next stranger that connects within P2PTransport's 10 s invite timeout; the six-digit code
  is shown on both screens; "They Match" seals and stores the group secret in the Keychain, alongside the
  identity key, and records the peer in `peers.json`.
- "Carry Now" pushes every file that is new or changed since the last carry to every paired, connected device,
  landing through `Homes.add` on arrival — the exact gap the owner hit (a file in `~/Recense/downloads/` not
  reaching the iPhone).
- **Not yet wired**, said plainly rather than half-built: carrysync.swift's P2/P3 settling (the append-only ops
  log, move/trash/restore replay across devices, text merge, keep-both siblings). "Carry Now" only pushes; it
  does not yet replay a remove or a rename from one device onto another. That is the rest of P4.
- Files move over `P2PTransport.send(fileAt:)` directly, not through `shared/pieces`'s resumable chunks — fine
  for Homes' sizes today; swapping it in later changes nothing public in `carrymanager.swift`.
- If two devices are each already in a *different* group, pairing refuses rather than merging them (no wire
  message yet compares group fingerprints before the secret is sent). Cannot happen on a first pairing.

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
- `Recense/.carry/peers.json`: name, public key, paired date (no secrets).
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
- Replaying the same ops twice changes nothing (idempotent): ops at or below the seen vector's seq are skipped, and
  each decision is "nothing" once its result is in place. The vector is the guard: without it, a put replayed after
  its own move and trash would bring the file back (tested).

### P4 · When it runs
- When two paired devices see each other: starts within 2 s, one file at a time, progress shown per file.
- A dropped link resumes from the pieces already held.
- iOS: while Recense is open, plus the background processing window. Never blocks playing, reading or writing.

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
- `shared/carrymanager.swift`: the glue — starts the link, runs pairing, orchestrates "Carry Now". One copy,
  used by the Mac's Devices menu (`strip/app.swift`) and the iOS Devices screen (`mobile/HostApp/iOS/Devices.swift`).

## Done checks
- `swiftc -O shared/notesync.swift shared/carrysync.swift mobile/ios/Tests/carrysync/main.swift -o "$TMPDIR/carrysync" && "$TMPDIR/carrysync"`
  (ALL OK); `swiftc -O shared/carrypair.swift mobile/ios/Tests/carrypair/main.swift -o "$TMPDIR/carrypair" && "$TMPDIR/carrypair"`
  (ALL OK: same code on both, a device in the middle never matches in 300 runs, forged nonce and stranger refused) — 2026-11-14 ✓.
- `strip/recense selftest`, 198 ok, exit 0 (includes homesSelftest, carrysyncSelftest, carrypairSelftest) — 2026-11-14 ✓.
- `zsh strip/build.sh`; iOS compile (GalleryFiles + RecenseGuest), both BUILD SUCCEEDED — 2026-11-14 ✓.
- **Not yet checked (owner, real devices):** Pair a Mac and an iPhone; airplane mode on with Wi-Fi and Bluetooth
  on; a file added to a home on one reaches the other via "Carry Now" within the session. The full P4 settling
  check (a song added on the iPad plays on the iPhone and the Mac; a file removed on one is in `trash/` on all
  three; Restore brings it back on all three) waits on the ops-log/settling wiring noted above, not built yet.

## Offline gate
- Outside services: **none.** Radios on the devices only; no account, no internet, no company.
