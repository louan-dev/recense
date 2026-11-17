# BUG-25 · Carry's staging stalls: long names never stage, gone files are waited on forever, stray bytes never leave

From: T-0111, T-0108, T-0092 (handoff audit and pair-fix, 2026-11-16) ·
Guards: FEAT-09 P3 (settling), BUG-19 ·
Status: `[~]` (tested without radios; device check owed)

## What the owner would see
- "Waiting for N files from <device>" that never ends, and every later carry resending the whole log.
- `.carry/incoming` on the iPhone growing (25 stray files on 11-16).

## Red (read from code; T-0092 seen on the iPhone)
- T-0111 · a staged file was named base64(key). A Vietnamese key near 190 bytes passes the 255-byte file-name
  limit; `moveItem` into staging throws; the op stays owed forever.
- T-0108 · `receiveSeen` skipped an op whose file was gone ("delete forever" after the put). The receiver kept it in
  `waiting`, so `settledThrough` never passed it and every later "seen" resent every op and file after it.
  A put edited three times sent the same file three times.
- T-0092 · bytes that land after their op settled, or with no op waiting, were never placed or removed.

## Green
- `CarrySync.stagingName(key)` = SHA-256 hex (64 bytes). The resource name on the link stays base64(key).
- `CarrySync.answer(ops, exists:)`: each result key's bytes once (seq order, trash skipped); keys with no bytes
  go back as a `"gone"` message. The receiver, after the ops sent before it settle, clears those keys from
  `waiting` and advances. An older peer ignores the unknown message type (as before: it waits).
- `CarrySync.orphans(staged, expecting:, now:, maxAge:)`: at launch every staged file goes (nothing waits in
  memory; the unsettled ops are asked for again); before each carry, staged files no op waits for go after
  `orphanAge` = 600 s (bytes may land before their op).

## Invariants (tested: `mobile/ios/Tests/carrysync/main.swift`)
- A 300+-byte accented key stages under a 64-byte hex name; same key, same name.
- Ops put a×3, put deleted, trash t, move b→c with a and c present: send = [a, c]; gone = [deleted].
- Staged {waited (1 h, expected), fresh (1 min), stale (1 h)}: running sweep removes only stale; launch sweep removes all.

## Device check (owed)
- Mac → iPhone: carry a song whose name is 100+ Vietnamese letters; it reaches the iPhone.
- Carry a file, delete it forever on the Mac before the iPhone connects; the iPhone says "Up to date with <Mac>".
- iPhone `Files › Recense › .carry/incoming` is empty after a relaunch.
