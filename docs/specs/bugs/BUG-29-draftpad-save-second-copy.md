# BUG-29 · Draftpad's save on the Mac is an unfixed second copy of the iPhone's

From: T-0124, T-0125, T-0127 (review lane, 2026-11-16), T-0176 (review of this fix, 2026-11-18) ·
Guards: A4 / A11 (Draftpad file sync), T-0114 (fixed on iOS only) ·
Status: `[~]` (tests pass; device check owed)

## What the owner would see
- On the Mac, offline, with `draftpad.md` evicted by iCloud: Draftpad opens blank, and the first words typed replace the
  whole note on every device.
- A save that fails on the Mac (disk, iCloud mid-replace) is treated as done: the next poll reads the old file as
  "theirs" and puts it over the edit.
- Ink drawn on the iPad disappears after the Mac draws one stroke (the Mac writes its own ink over the sidecar).
- An ink sidecar that can't be read now (evicted, offline) loads as no ink; the next stroke saves only itself over it.
- Two Draftpad conflicts in the same minute: the second copy replaces the first.

## Red (read from code, 2026-11-18)
- `strip/app.swift` `load()`: `coordinatedRead(notePath) ?? ""`; it also created an empty `draftpad.md` when the path
  didn't exist (an evicted file).
- `strip/app.swift` `saveNow()`: ignores `coordinatedWrite`'s result and moves `lastWritten` anyway; reads "theirs" only
  when the mtime changed; on a conflict writes the note before the copy, at `conflictSiblingPath` (minute precision).
- `strip/editorhost.swift` "ink": `coordinatedWrite(json, to: inkPath)`, no read, no merge.
- `mobile/HostApp/iOS/Draftpad.swift` `loadInk`: `coordinatedRead(p) ?? ""`; `saveInkJSON` ignores the write result.
- The two hosts each held a copy of the load/save rule (`DraftpadFile.load/save` on iOS, `App.load/saveNow` on the Mac),
  and of the Agenda card's calendar save (`saveEvents`).

## Green
- One shared `DraftpadNote` (`shared/draftpadfile.swift`): load and save of `draftpad.md`, used by both hosts.
  It is the iOS rule (T-0114) moved, not a third copy: `readNote`, `planBlindSave`, `planNoteSave`, `Unsaved`,
  `freeSiblingPath` in `shared/notesync.swift`.
- One shared `DraftpadInk` (same file): load and save of `draftpad.ink.json`. `DraftpadInk.plan` decides each post:
  write it, merge the file first (the page's `mergeInk`, the one union in `editor/src/ink.js`), or wait.
- iOS: every save runs inside a background task, so leaving the app finishes it; the 3 s poll reads the files off the
  main thread.
- The Mac's 1 s poll retries an owed save (pending, or a note unreadable at load) at most every 10 s, and an ink post
  that is waiting; the classic pad still adopts a changed file without rewriting it.
- Open: `saveEvents` (the Agenda card's calendar save) is still two copies, `strip/editorhost.swift` and
  `Draftpad.swift`. Moving it to `shared/` is about 160 changed lines (two copies of `saveEvents` and `pageDate`
  out, one shared in, both callers), over this slice's 80-line limit: its own slice.

## Invariants (tested: `mobile/ios/Tests/draftpadfile/main.swift`)
1. A note that exists but can't be read loads as blank and **is never written over**; what was typed is kept in the
   unsaved folder (one file per launch) and the save is pending.
2. Once the note reads again, the save writes the note, then what was typed after it.
3. **A failed write never moves the base**: the next save still merges against the last text the file really held;
   what was typed is kept safe and the save is pending.
4. A save reads the file every time (not only when its mtime changed): an edit that kept the mtime is still merged.
5. A real conflict writes the other device's text beside the note **first**, under a name no file has (`freeSiblingPath`),
   and only then the note; a second conflict in the same minute gets " 2".
6. Ink: an unreadable sidecar loads as "not seen" (nil), never as empty ink; a post while it is unreadable writes
   nothing (`wait`) and is kept for the retry.
7. Ink: a post when the file holds strokes this host has not seen is merged first (`mergeFirst(disk)`), never written
   over; once seen, the union is written. A missing or empty sidecar, or one equal to what this host last saw, is
   written straight away.
8. Ink: a failed write keeps the post for the retry and does not move `seen`.
9. Ink: a merge handed to the page that does not come back (page not loaded, no ink layer, the call failed) undoes
   `seen` (`unsee()`), so the next post merges the file again instead of writing over it (review 1, 2026-11-18).
10. Matter (T-0176): `MatterWrite.plan` reads the sidecar with `readNote`; an unreadable `draftpad.matter.json` is
    `.wait`, never "no file": nothing is written over its seeds, links or crossings (tested:
    `mobile/ios/Tests/voiceappend/main.swift`).

## Device check (owed)
- Mac + iPad: draw on the iPad, then one stroke on the Mac: both strokes remain on both.
- Mac offline with `draftpad.md` evicted (`brctl evict`): Draftpad opens blank, type a line, go online: the note comes
  back with the typed line after it.
- iPhone: type, swipe home at once: the text is in `draftpad.md` on the Mac.
