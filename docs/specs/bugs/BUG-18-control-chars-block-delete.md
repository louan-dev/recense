# BUG-18 · Pages full of ⌧ boxes can't be swiped away

From: T-0085 (owner, 2026-11-15: "the delete is still fucked up", screenshot of a page of ⌧ boxes)
· Device: Mac (seen), every host (shared editor) · Status: `[~]` (fixed in editor, source of 0x04 open)

## What the owner sees
A page shows a row of ⌧ boxes. Swiping off it never deletes it, though it holds no words.

## Red (measured)
- Live `draftpad.md` (iCloud vault, 2026-11-15 17:5x): 15 runs of byte 0x04 (ASCII EOT, Ctrl+D's code).
  Pages 2–5 at the top hold nothing but 0x04.
- `isWindowEmpty` (`editor/src/pages.js`) only trimmed whitespace, so those pages counted as text,
  and `swipeRightToLeft` / `swipeLeftToRight` stepped past them instead of deleting.

## Root cause
1. Control characters reach the document (source not yet found: not Karabiner, not `strip/app.swift` key synthesis).
2. The empty-page test treats them as text.

## Invariants (guarded by `editor/test/bug18-control-chars.test.mjs`)
- A1 · A page whose content, after removing control characters (U+0000–U+0008, U+000B, U+000C,
  U+000E–U+001F, U+007F) and whitespace, is empty or only a date heading, is empty.
- A2 · Typed, pasted or dropped text never inserts those characters; tab, newline and return pass.
- A3 · A host load (`setText`) leaves the file as it is; cleaning the live file is a separate step shown to the owner.
- A4 (T-0090) · Control characters that are in the file render as CodeMirror widgets (a muted dot, 0.6ch, titled with
  the code point), never as raw text WebKit draws as ⌧ boxes, so a click among them places the caret where aimed.

## Open
- Find what types 0x04 (log keys reaching the editor on Mac and iPhone).
