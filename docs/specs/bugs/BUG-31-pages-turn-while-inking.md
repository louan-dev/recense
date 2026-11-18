# BUG-31 · Pages turn under the hand while annotating

From: PLAN-1118 §3 "Page lock while annotating", owner 2026-11-18 ·
Guards: UI-04 (tools and paging), law/interaction (no gesture-only action) ·
Status: `[~]`

## Invariants (each has a test marked `// Regression guard: BUG-31`)
1. A page lock exists (`setPagesLocked(view, bool)`, `editor/src/pagemode.js`). It is on while any tool but
   `select` (the text tool) is chosen: pen, highlighter, lasso, eraser (`toolLocksPages`, `ink.js`); off for `select`.
2. Locked: the wheel pager, touch drag, Pencil edge drag and `__hostSwipe` (Mac trackpad via `nativeSwipe`)
   turn nothing; `__hostSwipe` returns `'off'`. Vertical scroll is unaffected.
3. Locked: the page bar buttons (newer, older, new page), the dots and the menu still turn the page
   (they call `stepPage`/`newPage` directly). The lock never removes a visible control.
4. The page posts `{ pagesLocked: bool }` to the host on every tool change; iOS turns its screen-edge
   recognizers off while locked (`Draftpad.swift`). The Mac needs no host change: `nativeSwipe` answers `'off'`.
5. Nothing new animates; the lock only removes motion (Reduce Motion unaffected).
Test: `editor/test/bug31-pages-turn-while-inking.test.mjs`.

## Unchecked
- iPad: Pencil + finger on device (iPhone Mirroring / iPad), edge swipe off while a pen is chosen.
