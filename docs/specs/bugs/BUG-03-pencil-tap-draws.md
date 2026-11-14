# BUG-03 · A Pencil tap meant to place the cursor draws a stroke instead

From: T-0030 · Status: `[~]` · Spec: UI-04 (Apple Pencil Pro mechanics)

## Repro
- Device: any iPad with Apple Pencil (observed); confirmed in code and by automated
  WebKit repro (`editor/scripts/repro-bug02.mjs` Test 5, run 2026-11-12).
- Steps: open a fresh Draftpad page (or any page where no tool has been explicitly
  picked yet this session), tap once with the Apple Pencil, zero movement, meaning
  to place the text cursor.
- Observed: a real ink stroke is created and committed — a visible mark ("a box")
  appears at the tap point, anchored to that line.
- Expected: a tap with no real movement, before any tool has been explicitly chosen,
  places the cursor like any other input; it does not draw.

## Root cause
`editor/src/ink.js:1484-1492` (`inks()`): on a fresh mount, `currentTool` starts at
`SELECT_TOOL` and `toolChosen` starts `false` (`:830-831`). The very first
`pointerType: 'pen'` touch auto-switches `currentTool` to `'pen'` — a deliberate
convenience (comment at `:829`: "Select until a Pencil touches the page or a tool
is picked") — and `onPointerDown` (`:1495`) immediately starts recording a stroke
from that same touch, with no way to tell a drawing gesture from a cursor-placement
tap at touchdown time. `onPointerUp` (`:1588-1601`) commits whatever was recorded,
even a single zero-movement point.

Every new Draftpad page is a fresh mount of the ink layer, so `toolChosen` resets to
`false` each time — this fires on the first Pencil touch of every new page, matching
the owner's report verbatim: "boxes appear when typing or adding a page" (T-0030).

**Existing test coverage missed this**: `test/p3-ink.test.mjs:502` ("Pencil on a
chosen Select leaves no ink") calls `layer.setTool('select')` explicitly before the
probe, which sets `toolChosen = true` (`:1435`) and masks this exact bug — it only
ever tested the already-chosen path, never the fresh-mount default.

## Invariants
- **I1:** On a fresh mount (`toolChosen` still false), a `pointerType: 'pen'`
  touch with less than `AUTO_PEN_TAP_PX` (3 px) of total movement commits no stroke.
- **I2:** The same touch, once it moves past `AUTO_PEN_TAP_PX`, still draws normally
  — the fix only discards the ambiguous near-zero case, not real marks.
- **I3:** Once a tool has been explicitly chosen (`toolChosen === true`), every pen
  touch draws exactly as before — this fix changes nothing on that path.

## Fix
`editor/src/ink.js`: a new `autoDetectedStroke` flag, set `true` only when `inks()`'s
auto-switch branch fires for the current touch, reset at the start of every
`inks()` call. In `onPointerUp`, before committing the stroke, discard it if
`autoDetectedStroke` is true and the stroke's total movement from its first point
is under `AUTO_PEN_TAP_PX`.

## Red test
`editor/test/bug03-pencil-tap-draws.test.mjs` — `// Regression guard: BUG-03`.
Fresh `createInkLayer` (no `setTool` call first, matching a real new page), a
zero-movement `pointerType: 'pen'` pointerdown+pointerup, asserts
`layer.getInk().strokes.length === 0`. Failed before the fix (`1`), passes after.

## Real path
Owner confirms on a real iPad with Apple Pencil: open a brand new Draftpad page,
tap once with the Pencil (no drag), confirm nothing is drawn, then confirm drawing
still works normally once the pen tool is picked from the palette or by a real stroke.
