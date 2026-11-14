# BUG-04 · setText put the caret back at a stale offset after a native round-trip

From: T-0001 · Status: `[~]` (tests pass; owner's real-device check pending) · Spec: none (shared editor)

## Repro
- Device: owner reports on iPhone, iPad and Mac (not iOS-only); not reproduced in generic
  WebKit (iPhone 15 / iPad Pro 11 / desktop emulation, and a CodeMirror iOS-replay of Enter)
  because that in-page-only testing never exercises the native save/merge round-trip.
- Steps: in Draftpad, place the caret at the end of a line and press Return.
- Observed: the line break is inserted (confirmed correct, in-page, by prior scouting), but
  afterward the caret ends up positioned earlier in the document than the line that was just
  split — owner's words: "it only lets you inverse line break so new text floats on top, it
  doesn't let you indent below." Typing the next character lands it on the wrong (earlier) line.
- Expected: after Return, typing continues on the new line, below the break.

## Root cause
`editor/src/bridge.js`'s `setText(nextText)` — the function
`window.recenseEditor.setText(s)` that every native host (Draftpad.swift on iOS,
editorhost.swift on Mac) calls after its save/merge round-trip comes back with text that
differs from what's on screen (`saveNow()` / `pollExternal()` in `Draftpad.swift`; the
equivalent in `editorhost.swift`) — replaced the **whole document**:

```js
dispatch({
  changes: { from: 0, to: current.length, insert: s },
  selection: { anchor, head }   // anchor/head = the OLD selection's raw offsets,
                                 // only clamped to the new text's length
});
```

`anchor`/`head` were the selection's offsets **before** this transaction, clamped only so
they don't run past the end of the new string — never re-mapped through what actually
changed. Any round-trip that changes content *before* the caret (a 3-way merge adopting a
line from another device, a save-path normalization, anything) leaves the caret at the same
raw numeric offset, which now falls earlier in the document than the line it was on — one
line "above" where it should be. The next host round-trip after Enter is exactly this kind
of change (even a single adopted/merged line shifts everything after it), which is why this
fires on real devices (real native host, real save path) and not in generic WebKit testing
(no native host, no round-trip).

This is shared `editor/` code (`editor/dist/editor.html`), hosted by both
`strip/editorhost.swift` (Mac) and `mobile/HostApp/iOS/Draftpad.swift` (iPhone/iPad) — the
same root cause explains the bug on all three devices without needing an iOS-specific theory.

## Invariants
- **I1:** `setText(s)` is a no-op (no dispatch at all) when `s` equals the live document
  byte-for-byte — unaffected by this fix, still true.
- **I2:** When `s` differs from the live document, `setText` dispatches only the minimal
  changed region (`computeMinimalTextChange`, already used by `legal.js`'s Enter/Tab
  handling) and does **not** pass an explicit `selection` — CodeMirror maps the existing
  selection through that minimal change automatically, keeping the caret anchored to the
  same unchanged content on either side of the edit, not at a stale raw offset.

## Fix
`editor/src/bridge.js`: `setText` now computes `computeMinimalTextChange(current, s)`
(imported from `editor/src/legal.js`, reusing the same diff helper `legal.js` already uses
for its own minimal-change dispatches) and dispatches only that change, with no explicit
`selection` override. CodeMirror's own change-mapping repositions the caret correctly.

## Red test
`editor/test/bug04-settext-caret.test.mjs` — `// Regression guard: BUG-04`. Places the caret
right before a line ("BBB" in `"AAA\nBBB"`), calls `setText` with a round-trip text that
inserts a new line before it (`"ZZZ\nAAA\nBBB"`), and asserts the caret still sits right
before "BBB" afterward. Failed before the fix (caret landed inside "AAA" instead); passes
after. A second case guards the no-op/byte-identical path (I1).

## Not fully closed
The exact native-side trigger that makes the host's round-trip return text differing from
`mine` on a routine, single-device Enter press (vs. only during a genuine cross-device merge)
could not be confirmed without real-device logging in the time available — see
`.handoff/t-0001-redo/HANDOFF.md`. The fix above is correct and strictly safer regardless of
how often the round-trip fires (it only changes behavior on the already-buggy path), but the
owner's real-device check (Checks, below) is the test that actually proves this closes T-0001.

## Real path
Owner confirms on the real iPhone (iPhone Mirroring, never the simulator), the real iPad, and
the Mac: open Draftpad, place the caret at the end of a line, press Return, and type a
character — it must land on the new line below the break, not merge onto the line above, on
all three devices.
