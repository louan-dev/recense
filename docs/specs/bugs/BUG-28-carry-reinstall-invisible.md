# BUG-28 · After a reinstall, a device's new changes are invisible to its peers

From: T-0110 (handoff audit, 2026-11-16) ·
Guards: FEAT-09 P3 (the seen vector) ·
Status: `[~]` (tested without radios; device check owed)

## What the owner would see
- Reinstall Recense on the iPhone: pairing still works (Keychain identity), but nothing new from the iPhone reaches
  the Mac until it has made as many changes as before.

## Red (read from code)
- The ops log lives in the app folder and restarts at seq 1. Each peer still holds `appliedSeq` = the old high number
  and asks only for ops above it.

## Green
- `CarrySync.renumber(mine, peerSaw:)`: when a peer's "seen" exceeds every seq in my log, every op moves up by
  that number; `receiveSeen` rewrites the log atomically, then answers. A peer that already holds one of them
  decides `.nothing` for it.

## Invariants (tested: `mobile/ios/Tests/carrysync/main.swift`)
- Log [1, 2], peer saw 40 → [41, 42], and the peer wants both. Peer saw 2 or 0, or an empty log → nil.

## Device check (owed)
- Delete and reinstall Recense on the iPhone, add a file there, carry: it reaches the Mac.
