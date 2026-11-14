# BUG-01 · Squeeze-hold menu stuck after hover loss or palm cancel

From: owner 2026-11-11 · Status: `[ ]` · Spec: UI-04 P1, P2
**Anticipated, not observed:** the radial menu is not built yet.
This spec fixes the guard before the code exists.

## Risk
- The menu opens while the squeeze is held (UI-04 P1).
- If the pencil leaves hover range, or a palm touch cancels the gesture,
  the `ended` / `cancelled` phase may never arrive (assumption, untested).
- Then the menu stays open and the next touch picks an item by accident.

## Invariants
- **G1 · Watchdog:** menu open and no squeeze or hover update for 150 ms → close, no pick.
- **G2 · Palm cancel:** a touch cancel while the squeeze is held → close, no pick.
- **G3 · Lift-off:** `hoverPose == nil` while the menu is open → close, no pick.
- After G1–G3 the state machine is back in `idle`; the next squeeze starts fresh.

## Red test first (`/bug`)
- File: `editor/test/pencilstate.test.mjs`.
- `// Regression guard: BUG-01` on each test.
- Cases: 149 ms silence → still open; 150 ms → closed; cancel → closed; nil hover → closed; no pick in any.
