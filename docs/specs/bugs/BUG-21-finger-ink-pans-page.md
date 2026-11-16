# BUG-21 · A finger drag scrolls the page instead of inking

From: T-0131 (owner, 2026-11-16: "annotation tools dont seem to work. when i ddraw the page moves")
· Device: iPhone, iPad without Pencil (WebKit touch) · Status: `[~]` (fixed in editor, device check owed)

## What the owner sees
With a pen chosen, a finger drag moves the page; no stroke appears.

## Cause
WebKit decides whether a touch pans before any script runs: only CSS `touch-action` set before the
touch starts can stop it. `editor/src/ink.js` called `preventDefault()` on `pointerdown`, which cannot
stop a pan, and never set `touch-action` on the CodeMirror scroller. The pan wins, WebKit sends
`pointercancel`, and `onPointerCancel` drops the stroke.

## Invariant
- Any tool other than select (pen, highlighter, eraser) → scroller `touch-action: none`.
- Select → `touch-action` cleared, the finger scrolls again.
- A Pencil touch that auto-picks the pen (BUG-03/06 path) sets it too.

## Red → green
`editor/test/bug21-finger-ink-no-pan.test.mjs`: 4 of 5 failed before the fix, 5/5 after.

## Open
- While a tool is chosen, one finger can't scroll. Two-finger scroll (Notability's rule) and finger/trackpad
  palm-rejection equivalents are UI-04 P6, not this bug.
- Device check on iPhone + iPad via iPhone Mirroring.
