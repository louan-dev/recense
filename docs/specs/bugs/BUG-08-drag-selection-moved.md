# BUG-08 · The document moved while the owner was dragging a selection

From: T-0028 (owner, 2026-11-12: "draftpad deletion bug. if text is highlighted over the annotus page";
2026-11-14: "it deletes but the highlight is inaccurate and the cursor placement is all mixed up and
confusing") · Device: Mac, ink tool on **Select** · Status: `[~]` (fixed, owner's device check owed)

## What the owner sees
They drag over a few lines in Draftpad to highlight them. The highlight that appears is not what the
drag covered — it is shorter, or ends in the wrong place — and after Delete the caret sits on a
different line than expected.

## Red (what was measured, not assumed)
In real WebKit against the built `editor/dist/editor.html`
(`~/.claude/context/recense/reviews/highlight-delete-repro.mjs` and the Mac-host repro):

| Case | highlight | deleted | caret |
|---|---|---|---|
| plain drag over 3 lines, then Backspace | 172 | 169 | line 3 ✓ |
| with ink strokes on the page | exact | exact | ✓ |
| page mode, page mode + ink | exact | exact | ✓ |
| **host `setText` mid-drag (a line added above)** | **119** | **117** | **wrong line** |
| **host `nativeSwipe` mid-drag** | **167** | 164 | ✓ |

So the shared selection path is sound; the fault is the **host interrupting an active drag**.

## Root cause
1. `window.recenseEditor.setText(s)` is called by the Mac host after an autosave or a merge from
   another device (`strip/editorhost.swift`, `shared/notesync.swift`), whenever it is ready — including
   while the pointer is still down. CodeMirror maps the *stored* selection through a change (that is
   what BUG-04 fixed), but a **drag in progress keeps extending from the anchor the gesture started
   with**. Insert a line above it and every further mouse move measures from a stale anchor, so the
   highlight is not what the owner dragged over, and Delete removes that wrong range.
2. `nativeSwipe` (the Mac's trackpad swipe, `strip/editorhost.swift` `scrollWheel`) paged the view
   while the pointer was down, so the drag ended on a different character than the owner was on.

## Green (the fix)
- `editor/src/bridge.js` — `createEditorBridge` takes `isSelecting()`. While it is true, `setText`
  stores the text instead of dispatching (newest wins) and `applyDeferredText()` applies it once when
  the drag ends. Nothing is dropped: it is delayed by the length of one drag. With no drag in
  progress, behaviour is exactly as before (BUG-04's minimal-diff dispatch).
- `editor/src/index.js` — `dragSelecting` is true from `pointerdown` in the text until `pointerup`,
  `pointercancel` or window `blur` (the pointer is often released outside the text); on end, the
  deferred text lands. `nativeSwipe` returns `'selecting'` and does nothing while a drag is in progress.

## Invariants (the guards)
- The host's `setText` never changes the document while the pointer is down over text.
- A deferred round-trip applies **once**, with the newest text, when the pointer comes up.
- Applying twice changes nothing more; a deferred text already in the document dispatches nothing.
- With no drag in progress, `setText` still applies at once (BUG-04 behaviour kept).
- A trackpad swipe does not move the page during a selection drag.
- Tests: `editor/test/bug08-drag-selection.test.mjs` (5 checks, red → green).
- The five-case WebKit measurement above is the end-to-end guard; re-run it after touching
  `bridge.js`, `index.js` or the host's save path.

## Done checks
- `npm test` in `editor/` — 176/176.
- `npm run build` in `editor/`, `dist/editor.html` committed (the Mac app bundles it).
- The WebKit repro: all five cases equal the baseline (172 highlighted, 169 deleted).
- `zsh strip/build.sh` + `strip/recense selftest`.
- **Owner's device check, owed:** Draftpad on the Mac — drag over several lines while a save is in
  flight, Delete, and the highlight is what was dragged; then the same on the iPhone and iPad once a
  mobile build is installed (the shared editor code covers all three).

## Amendments
- 2026-11-14 · created, red → green in the same sitting; T-0028 updated.
