# BUG-27 · Carry turns every edit into a copy beside the original

From: T-0106 (handoff audit, 2026-11-16) ·
Guards: FEAT-09 P3 (settling) ·
Status: `[~]` (tested without radios; device check owed)

## What the owner would see
- Edit a note or a Listen file on the Mac; on the iPhone a "name (iPhone date).ext" copy appears and the original
  stays old. Every later edit adds another copy.

## Red (read from code)
- `settle` passed `base: [:]`, so `decide` never reached "unchanged → replace": any differing copy became keepBoth.
- The copy was named for the receiving device, not the one whose version it holds.
- The rescued `work/carry-base` 5a379f6 was not ported: it records each device's own new edit as the agreed base,
  so two devices editing one file between carries would each replace the other's edit (one edit lost).

## Green
- `CarryOp.parent`: a put of a changed file names the sha it was edited from (`CarrySync.ops`). Optional on the wire:
  an older device omits it and gets the old keepBoth.
- `decide`: my copy == the op's parent → replace (my old version goes to `trash/`, as every replace). Otherwise keep
  both; the copy is named for `op.device`.
- `CarrySync.decideAll`: a batch decided in seq order against the disk as the earlier ops leave it.
- Still open: the 3-way text merge (needs the base text stored per agreed version); real conflicts keep both.

## Invariants (tested: `mobile/ios/Tests/carrysync/main.swift`)
- Scan A → B gives one put with parent A. Local A → replace. Local C → keepBoth "a (Mac …).m4a".
- No parent → never replace. A parentless op still decodes.
- Batch [put B parent A, put C parent B] over local A → replace, replace.

## Device check (owed)
- Edit a `.md` in Study on the Mac, carry; the iPhone shows the edit in the same file, no copy beside it.
- Edit the same file on both before carrying; both versions stay (one as a named copy).
