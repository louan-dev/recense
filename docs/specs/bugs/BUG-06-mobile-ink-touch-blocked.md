# BUG-06 · Draftpad annotation does nothing on touch (iPhone has no Pencil, so it never works there)

From: T-0023 (owner 2026-11-12, "annotation tool doesnt even work. thats a bug") · Status: `[~]`
Code: `editor/src/ink.js` (`inks`, `onPointerMove`, `onPointerUp`)

## Cause (read in the code, 2026-11-12)
- Commit c8f1307 ("unified whiteboard") wrote the ink layer so a finger always scrolls/selects and
  only Apple Pencil (`pointerType === 'pen'`) ever draws, erases or finishes a stroke:
  - `inks(e)`: `if (e.pointerType === 'touch') return false;` — a touch press never starts a stroke,
    **even after the owner has explicitly picked a pen/highlighter/underline/circle/eraser tool
    from the palette.**
  - `onPointerMove(e)`: `if (e.pointerType === 'touch') return;` — a touch drag is never added to
    the stroke and never erases.
  - `onPointerUp(e)`: `if (e.pointerType === 'touch') return;` — even if the two guards above were
    bypassed, the final stroke is still thrown away on touch: it is never pushed to `inkDoc.strokes`,
    never rendered, never saved.
- This is a deliberate policy ("Select never draws... so the iPad writes at once while the Mac's
  mouse selects text" — ink.js:1482), not a timing bug: touch is excluded at every stage, regardless
  of which tool is active.
- **iPhone has no Apple Pencil support at all.** The playbook's own rule is "Mobile = iPhone + iPad,
  always both" (owner 2026-11-12). With this policy, the annotation tool is 100% unusable on iPhone —
  there is no input type on that device that is ever allowed to draw — which matches the owner's
  report exactly ("the annotation tool doesnt even work").
- On iPad with a Pencil in hand, Pencil input (`pointerType === 'pen'`) already passes all three
  gates, so this bug does not explain an iPad-with-Pencil failure; it explains iPhone (always) and
  iPad-by-finger (when the owner isn't holding the Pencil).

## Invariants
- **G1 · Tool picked, any pointer draws:** once a drawing tool is active (`currentTool !== SELECT_TOOL`,
  set by tapping the palette or by Pencil's first-touch auto-pick), a `touch` press draws or erases
  exactly like `mouse` or `pen` does. No pointer type is special-cased after a tool is chosen.
- **G2 · No tool picked, touch still scrolls:** before any tool is chosen (`currentTool === SELECT_TOOL`),
  a touch press still does nothing to the ink layer, so a finger can scroll or select text by default —
  unchanged from today.
- **G3 · Pencil's first-touch auto-pick stays Pencil-only:** `!toolChosen && pointerType === 'pen'`
  auto-selecting the pen tool on an untouched palette does not extend to touch — an untouched palette
  plus a stray finger tap must not suddenly start drawing.
- **G4 · Full stroke lifecycle:** a touch stroke that starts under G1 is tracked through move and
  committed on lift, identically to a mouse stroke (same `onPointerDown` → `onPointerMove` →
  `onPointerUp` path, same anchoring, same save).

## Red test first (`/bug`)
- File: `editor/test/bug06-touch-draws.test.mjs`, `// Regression guard: BUG-06` on each test.
- Harness: the existing `createInkLayer` mock DOM/view from `test/p3-ink.test.mjs`.
- Cases:
  1. No tool picked, synthetic `touch` pointerdown/move/up over the scroller → no stroke added
     (G2 unchanged).
  2. `setTool('pen')`, then synthetic `touch` pointerdown/move/up → exactly one stroke added, tool
     `pen` (G1, G4).
  3. Same as 2 but tool `eraser-whole` over an existing stroke's point → that stroke is removed (G1
     covers erase, not just pen).
  4. Untouched palette (`SELECT_TOOL`, `toolChosen` false), synthetic `touch` pointerdown only (no
     prior palette tap) → still no stroke (G3: only `pen` gets the auto-pick, not touch).

## Device check
- iPhone (iPhone Mirroring) and iPad, finger only, no Pencil in hand: pick a tool from the palette,
  draw a line with a finger, confirm it appears and survives a reload (`setInk`/`getInk` round trip).
- iPad with Pencil: confirm Pencil drawing still behaves exactly as before (regression check on the
  path this bug does not touch).
- If a finger stroke still fights the page's native scroll on a fast diagonal drag (the browser's
  touch gesture recognizer winning the race before `preventDefault()` on `pointerdown` takes effect),
  log it as a follow-up: `scrollDOM.style.touchAction = 'none'` while `currentTool !== SELECT_TOOL`.
  Not added pre-emptively here — unverified on a real device, and it would also block finger-scroll
  while a tool is merely selected but not yet drawn with, which needs an owner decision first.
