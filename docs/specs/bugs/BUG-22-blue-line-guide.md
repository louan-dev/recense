# BUG-22 · A blue band follows the caret's line in Draftpad

From: owner 2026-11-16 (WISHES.md: "Draftpad: remove the blue line guide on browser + apps")
· Device: every host (PWA, Mac strip, iPhone, iPad) · Status: `[~]` (fixed in editor, device check owed)

## What the owner sees
A pale blue band sits behind whatever line the caret is on, and moves with it.

## Cause
`editor/src/index.js` turned on CodeMirror's `highlightActiveLine()`, and `editor/src/theme.js` painted
`.cm-activeLine` rgba(91,155,213,0.07) dark / rgba(43,108,176,0.06) light. Every host loads this one
editor (`strip/editorhost.swift`, `mobile/HostApp/iOS/Draftpad.swift`, `editor/dist/pwa`), and none adds a
line of its own, so one source drew it everywhere.

Kept, not the guide: the caret (cyan), the page-break divider (marks a real break), the faded toolbar border.

## Invariant
- No line of the editor gets a background because the caret is on it, on any host.

## Red → green
`editor/test/bug22-no-line-guide.test.mjs`: 3 of 3 failed before the fix, 3/3 pass after.
Browser pane, built PWA after its cache was cleared: `.cm-activeLine` count 0, every line background transparent.

## Open
- An installed PWA shows the band until its service worker picks up the new build (new hash `d8c3ec099e`).
- Device check on Mac, iPhone and iPad (iPhone Mirroring).
