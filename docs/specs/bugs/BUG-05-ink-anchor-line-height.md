# BUG-05 · Ink drifts off its line (and leaves stray marks) because anchoring uses a fixed 28px line height

From: T-0014 (owner 2026-11-12, "ink doesnt stay anchored random specs of dots appear when you scroll") · Status: `[~]`
Code: `editor/src/ink.js` (`createInkLayer`, `DEFAULT_LINE_HEIGHT`), `editor/src/index.js` (`createInkLayer(...)` call, `setFontSize`)

## Cause (read in the code, 2026-11-12)
- `DEFAULT_LINE_HEIGHT = 28` (ink.js:58) is the only line height `createInkLayer` ever uses: the
  call site in `index.js:583` passes no `lineHeight` option, so every anchoring call
  (`anchorStrokeToDoc`, `resolveStrokeAnchor`, `snapUnderlineStroke`, `groupHandwriting`,
  `erasePartialStrokes`) inside the layer runs on the hard-coded 28px, never the real one.
- Draftpad's own text size is **not** 28px by default: `--rc-font-size: 18px` (styles.css:12), and the
  owner can change it live via `setFontSize(px)` (index.js:772) — `document.documentElement.style
  .setProperty('--rc-font-size', ...)` plus a CodeMirror font-size compartment reconfigure. Neither
  path ever touches ink's assumed line height.
- A stroke's position is stored once at draw time as a raw pointer y-coordinate (correct, whatever
  it is), but it is **re-snapped** to `lineIndexInPage * lineHeight` every time `resolveStrokeAnchor`
  runs — on every doc edit, on `setInk`/`mergeInk` (app load, sync merge), and already-correctly on
  every font-size change too (that `reconfigure` is an effect, which index.js:546-548 already routes
  through `inkLayer.relayout()`). Each of those re-snaps uses the wrong constant, so a stroke jumps to
  wherever `28px * lineIndex` lands instead of wherever the line actually renders.
- The drift is `lineIndex * (actual_line_px - 28)`: near-zero for the first line of a page, growing
  with every line further down — which is exactly "random specs of dots" (ink scattered away from its
  text, worse deeper into a page) and "doesn't stay anchored... when you scroll" (you only notice the
  drift once you scroll far enough to see a line whose ink has wandered off it).
- `editor/src/ink.js` is shared by the Mac host (`strip/editorhost.swift`) and the mobile host
  (`mobile/HostApp/iOS/Draftpad.swift`) — one source, so this is correctly filed against both, per
  the triage note ("recense - mac, mobile").

## Invariants
- **A1 · Real line height at draw time:** when a live CodeMirror `view` is available, `anchorStrokeToDoc`
  (called from `onPointerUp` right when a stroke is finished) converts the pointer's raw y-coordinate
  to a line index using `view.defaultLineHeight` (CodeMirror's own measured line height), never the
  28px constant. A stroke drawn on line N must anchor to line N, not `floor(N * realHeight / 28)`.
- **A2 · Live, not cached:** the line height used is read fresh from the view each time a stroke is
  anchored — not a value captured once when `createInkLayer` was constructed — so a stroke drawn after
  a `setFontSize` change anchors correctly at the new size too.
- **A3 · No change to existing pure-function tests:** `anchorStrokeToDoc`, `resolveStrokeAnchor`, and
  friends keep their current signature and default (`lineHeight = DEFAULT_LINE_HEIGHT`); only what
  `createInkLayer` passes them changes.
- **Known follow-up, not fixed here:** `resolveStrokeAnchor`'s re-layout on a doc edit only shifts a
  stroke's stored pixel points by `deltaLines * lineHeight` when the matched line number changes; a
  *pure* font-size change with no text edit leaves already-drawn strokes' pixel points untouched even
  though the text under them re-flows to the new line height. Fixing that needs resolve to rebuild a
  stroke's position from `anchor.offsetInPage` + `anchor.relY` at the current line height instead of
  delta-shifting old points — a larger change to the resolve path, logged here rather than folded in,
  since A1 (the anchor-time fix) already covers the reported symptom (wrong line, worse deeper into a
  scrolled page) without it.

## Red test first (`/bug`)
- File: `editor/test/bug05-lineheight.test.mjs`, `// Regression guard: BUG-05` on each test.
- Harness: the pointer-drag harness from `test/bug04-touch-draws.test.mjs`, with a `mockView
  .defaultLineHeight` the test can set.
- Cases:
  1. `mockView.defaultLineHeight = 40`, no `lineHeight` option passed, draw at pointer y = line 5's
     real pixel position (`5 * 40`) → the committed stroke's `anchor.offsetInPage` is 5, not
     `floor(5 * 40 / 28)` (A1).
  2. Draw once at `defaultLineHeight = 40` (line 5), then set `defaultLineHeight = 24` and draw a
     second stroke at line 5's new pixel position (`5 * 24`) → it also anchors to line 5, proving the
     live value is read fresh, not cached from creation (A2).
  3. No `defaultLineHeight` on the mock (as today's `p3-ink.test.mjs`/`bug04` mock has none) and an
     explicit `lineHeight: 28` option → draw at line 5's 28px position still anchors to line 5 (A3, no
     regression on the existing createInkLayer test).

## Device check
- Mac: write a line of ink near the top and another ~30 lines down a long page; change text size
  (Aa / settings) once; both strokes must still sit on their own line, not drift.
- iPhone (iPhone Mirroring) and iPad: same check, plus scroll the page after writing — ink must track
  its line, no stray marks appearing elsewhere on the page.
