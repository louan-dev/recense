# BUG-19 · Carried files counted settled before they arrived; the songs never came

From: T-0087 (owner, 2026-11-15 18:11, iPad: "theres no music library made after pressing carry now") ·
Guards: FEAT-09 P3 (settling) · Device: iPad (00008122-0009799A026B801C), Mac ·
Status: `[~]` (fixed and tested; device check owed)

## What the owner sees
- iPad › Carry Now says "Up to date"; Library has no Music folder. No error on either device.

## Red (what the code and the devices show)
- iPad `.carry/applied.json` = {"Chau's MacBook Pro": 8}: all 8 of the Mac's ops counted applied.
  `Documents/Recense` has no `library/Music`; `.carry/incoming` is empty. The Mac holds all 8 files.
- Cause 1, the bytes were thrown away. `P2PTransport` handed MultipeerConnectivity's `localURL` to the main actor
  in a `Task`. MultipeerConnectivity deletes that file when its callback returns, so the move into staging found
  nothing. A failed receive (`error != nil`) was dropped with no message.
- Cause 2, the wrong name. `landed` decoded the carry key from `url.lastPathComponent`, the temporary file's random
  name, not the `resourceName` it was sent under. Decoding failed, and the file was deleted in silence.
- Cause 3, no second chance. `receiveOps` set `appliedSeq` to the highest seq as soon as the ops arrived. The
  fetches waited in memory only. The next "seen" said 8, so the Mac never sent them again.
- Cause 4, silence. Each error went to `lastError`, which the next successful Carry Now cleared. The status counted
  only this device's own ops ("Up to date"), not the files still owed.

## Green (the fix)
- `P2PTransport`: the received file is moved to a temporary file of ours inside the callback, before the hop to the
  main actor. `onReceive` passes the `resourceName`. A failed receive calls `onReceiveFailed` with the reason.
- `CarryManager.landed(_:named:from:)` decodes the key from the resource name.
- `waiting` keeps each owed op (key → peer, seq). `appliedSeq` moves only to `CarrySync.settledThrough`: the
  highest seq with nothing owed at or below it. A file that fails to place stays owed.
- On the next "seen" (Carry Now, or the next connect once P4 lands), the peer sends every op from the first owed
  one, with its bytes. Settling is idempotent: `CarrySync.decide` gives `.nothing` for a file already here.
- `applied.json` becomes `applied-v2.json`: a device that counted ops early asks once for the whole log again.
- Status: "Waiting for N files from <device>" while any are owed; errors name the file and the device.

## Invariants (tested: `mobile/ios/Tests/carrysync/main.swift`)
- Nothing owed: settled through the last op received.
- Owed ops 3–8 of 8: settled through 2, so the next "seen" asks for 3 on.
- The first op owed holds everything back; nothing received settles nothing.

## Check (no test can reach MultipeerConnectivity's temporary file)
- `grep -n 'moveItem(at: localURL' shared/p2ptransport.swift` prints one line, inside `didFinishReceivingResourceWithName`.
- `grep -n 'lastPathComponent' shared/carrymanager.swift` prints nothing in `landed`.

## Device check
- Owed: iPad Carry Now → `library/Music` holds the Mac's 6 songs; `applied-v2.json` = 8 only after they land.
