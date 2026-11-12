# BUG-02 · Vertical scroll turns into a page swipe; pages jump

From: T-0025, T-0026, T-0027 · Status: `[~]` · Code: `editor/src/pagemode.js` (`installPageSwipe`)

## Cause (read in the code, 2026-11-12)
- Commit c8f1307 (11-08, "unified whiteboard") made pages follow the finger and decide the drag's axis early.
- **Touch and Pencil:** the axis was locked after 4 px of movement, sideways if `|dx| > 1.2·|dy|`.
  A finger's first 4 px are noisy, so many vertical scrolls locked sideways: the page slid and jumped.
- **Trackpad:** the axis was locked from the first wheel event alone, sideways if `|deltaX| > |deltaY|`.
- **Before c8f1307:** a swipe needed 60 px sideways and `|dx| > 1.4·|dy|` (b3097f2). The owner wants that feel back.

## Invariants
- **A1 · Slop:** no axis is chosen until the drag has moved 12 px on either axis (Σ of wheel deltas for a trackpad).
  12 px is an assumption near UIScrollView's touch slop; change it here first if the device check disagrees.
- **A2 · Ratio:** the axis is sideways only if `|dx| > 1.4·|dy|`; otherwise vertical.
- **A3 · Lock:** once vertical, the whole gesture stays vertical: no page drag, no page change, scrolling not blocked.
- **A4 · Commit:** a page changes only at `|dx| ≥ min(60, 0.2·width)` on a sideways gesture (unchanged).
- One function, `decideAxis(dx, dy)`, holds A1–A2 for touch, Pencil, mouse and trackpad.

## Red test first
- File: `editor/test/bug02-axis.test.mjs`, `// Regression guard: BUG-02` on each test.
- Cases: (5, 3) → none yet; (13, 10) → vertical; (20, 10) → sideways; (0, 12) → vertical; (14, 10) → vertical.

## Device check
- iPhone (iPhone Mirroring) and iPad: scroll a long page with a slanted thumb; the page must not slide.
- Mac trackpad: a diagonal two-finger scroll stays vertical; a clear sideways swipe still turns the page.
