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
- **A5 · No lost pixels:** once a trackpad gesture is sideways, the slop already moved counts toward the drag (the page moves from the first pixel; owner 11-12: "doesnt budge").
- **A6 · One piece:** the drag moves the whole scroller (text, selection, cursor, ink), never the text layer alone (owner: "weird boxes", "slide and page do not sync").
- **A7 · Glide:** past the commit distance the old page leaves the way the fingers went (140 ms), the new page enters from the other side (220 ms); Reduce Motion turns pages without motion.
- **A8 · Native trackpad read (Mac):** the Mac host reads the trackpad directly (`EditorWebView.scrollWheel`,
  `strip/editorhost.swift`), not the web `wheel` event — same 12 px slop, same 1.4 ratio as `decideAxis`, axis
  resets when the fingers touch, momentum after lift is ignored, the lift settles the page. Bridges to the web
  via `window.recenseEditor.nativeSwipe(dx, ended)` (`editor/src/index.js`), which sets `view.__nativeWheel = true`
  (turning off the web wheel listener for that window) and drives the same `renderDrag`/`settleDrag` as every
  other input (`editor/src/pagemode.js`) — no duplicated drag logic. One swipe call in flight at a time; the
  newest drag replaces a pending one, the lift always goes through (`EditorHost.sendSwipe`).
  **Note for future debugging:** once this is active, the web `wheel` listener in `pagemode.js` no longer runs
  on Mac at all — a trackpad bug reported after this ships is in `EditorWebView.scrollWheel`, not the web path.
- One function, `decideAxis(dx, dy)`, holds A1–A2 for touch, Pencil, mouse and trackpad.

## Red test first
- File: `editor/test/bug02-axis.test.mjs`, `// Regression guard: BUG-02` on each test.
- Cases: (5, 3) → none yet; (13, 10) → vertical; (20, 10) → sideways; (0, 12) → vertical; (14, 10) → vertical.

## Device check
- iPhone (iPhone Mirroring) and iPad: scroll a long page with a slanted thumb; the page must not slide.
- Mac trackpad: a diagonal two-finger scroll stays vertical; a clear sideways swipe still turns the page.
- 2026-11-12 · owner · partial pass: boxes (A6) no longer appear on every new page, but still appear sometimes while typing — A6 not fully holding yet. Wants the slide ~40% more responsive; candidates are A1's slop (12 px before any axis locks) or A7's glide timing (140 ms / 220 ms) — needs a decision on which to tune before changing either number, not guessed.
- 2026-11-12 · owner · escalated: "tapping adds boxes. the slide is really really laggy."
- 2026-11-12 · SCOUTING · claude · confirmed defect (not yet fixed): `settleDrag` (pagemode.js:505) starts a 140ms `setTimeout` to run `turn()` but never stores or cancels its handle — a second gesture before it fires can race the first on the same element's transform. `turn()` runs synchronously inside that timer and swaps real page content, which could explain the lag if a page is long. Separately, line 341: left-to-right past the first page unconditionally creates a new blank page (`allowCreate: true`) — a mis-read tap in that race could explain a "box" (an unexpected blank page). Not confirmed which (or both) is the real cause — this is the third round on this bug; need a screen recording (not a screenshot) of the box appearing before patching again, per the owner's three-strikes rule.
- 2026-11-12 · owner · after ea5d9bb: "mac swipe still lags, boxes added from tapping trackpad"
- 2026-11-12 · claude · automated repro (`editor/scripts/repro-bug02.mjs`, real WebKit, built `dist/editor.html`, single short page): a pure touch tap, a plain mouse click (no modifier), 8 small accumulated wheel events 60ms apart (the "quick separate trackpad taps never reset within 350ms" theory), and typing 3 characters — none changed `pageCount` or `currentPage`. Rules out those three hypotheses as the sole cause. Does NOT rule out: (a) the original timer-race (a completed swipe immediately followed by a second gesture inside the 140ms `settleDrag` window — not retested in this version of the script), (b) anything in `editor/src/ink.js` (shape-snap, stray selection rectangle) — a different subsystem a "box" could just as easily come from. Next evidence needed: a screenshot (not just a description) of a box the moment it appears, to tell which subsystem it's actually in before guessing further.
