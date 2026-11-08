# Recense Editor (`editor/`)

Offline-first Draftpad whiteboard and Markdown editor core built on CodeMirror 6 (MIT) for the Mac strip (`strip/editorhost.swift`) and the iOS/iPad app (`mobile/HostApp/iOS/Draftpad.swift`). Both platforms run the same bundle (`editor/dist/editor.html`) and read/write the same `draftpad.md` and `draftpad.ink.json` files offline.

## Features (M1–M6 & E2 Full Rebuild)

- **Self-contained offline build:** `npm run build` bundles all JavaScript and CSS into one file at `editor/dist/editor.html` with zero runtime network requests.
- **Draftpad byte-for-byte format (`100 windows = 1 .md file`):** preserves `\n\n<!-- page -->\n\n` page separators, line endings (`\n`, `\r\n`, lone `\r`), and opening full-style date lines (`Friday, November 6, 2026`) without rewriting the underlying file.
- **Mini-document window navigation (old Draftpad parity):**
  - Each window (`<!-- page -->` block) is an isolated mini document via `Decoration.replace({ block: true })` (`hiddenRanges`): vertical scrolling stays strictly inside that window's text and never crosses into another topic, while keeping independent per-window cursor and scroll memory.
  - **Left-to-right swipe (`swipeLeftToRight`):** steps to the newer window on the left; at window `0`, opens a brand-new window on the left (prepending a dated `<!-- page -->` block at the top of `draftpad.md`).
  - **Right-to-left swipe (`swipeRightToLeft`):** steps to the older window on the right; if the active window is empty (blank or bare date header only), deletes it and removes its `<!-- page -->` block from `draftpad.md` (when `total > 1`).
  - **Rubber-band drag (`0.25x`):** resists overscroll at boundaries with tactile edge feedback.
  - **Multimodal parity:** trackpad two-finger swipe, touch swipe, Apple Pencil edge swipe, and voice commands (`executeVoiceMove`) execute the exact same moves.
- **Zero-chrome surface, haptic zones & progressive disclosure (Freeform bar):**
  - At rest, the surface has zero buttons, words, or icons (`.rc-toolbar-faded` with `opacity: 0; pointer-events: none` and pure dot indicator `● ○ ○` via `formatDotIndicator`).
  - Hand-neutral, ambidextrous haptic zones (`detectHapticZone`, `attachHapticZones`) at the top (`44 px`) and symmetric left/right edges (`32 px`) emit tactile alignment/snap feedback and progressively disclose controls on hover, dwell (`280 ms`), or top-edge touch.
  - Respects `prefers-reduced-motion: reduce` and uses calm `320 ms` transitions for low sensory load.
- **Notability-style line-anchored ink whiteboard (`src/ink.js`):**
  - Type and write with an Apple Pencil Pro on the same surface with no mode switch and no Done button.
  - **Line-anchored JSON (`draftpad.ink.json`):** each stroke anchors to its window's line context (`hashLineContext`, `offsetInPage`, `embedTarget`, `relX`, `relY`). Inserting or deleting lines in Window 0 produces `deltaY = 0` for Window 1's ink, while edits above a stroke in the same window shift its ink vertically in lockstep with the text.
  - **Tools & 8-colour pure-dot row:** `pen`, `highlighter` (rendered under text with `mix-blend-mode: multiply`), `underline` (`snapUnderlineStroke`), `circle` (`detectAndSnapShape`), `eraser-whole` (`eraseWholeStrokes`), and `eraser-partial` (`erasePartialStrokes`), plus 8 high-contrast colours (`INK_COLORS`).
  - **Draw-and-hold shape snapping:** quick freehand writing (such as a handwritten letter `'o'`) stays freehand; holding at the end of a stroke (`>= 320 ms`) snaps rough circles to clean geometric `<ellipse>` shapes and straight strokes to `<line>`.
  - **240 Hz Apple Pencil Pro coalesced input & squeeze:** captures `e.getCoalescedEvents()` for full-fidelity strokes; squeezing or double-tapping Apple Pencil Pro (`onPencilAction('squeeze')`) toggles the eraser and reveals the pure-dot palette.
  - **Dropped-in file embeds keep ink on top (`src/embeds.js`):** dropping a PDF or image onto the page inserts `![caption](target)` and captures Pencil strokes over `.cm-embed` widgets so annotations stay anchored to the embedded file.
  - **CRDT-safe multi-device merge (`mergeInkDocuments`):** unions strokes by `id` and respects `removed` tombstone IDs across Mac and iPad/iPhone.
- **Live audio transcript sidecar & offline section summaries (`src/audio.js`):**
  - While audio plays, a zero-chrome transcript pane (`createTranscriptPane`) appears beside the page and highlights the active cue (`activeCueIndexAt`).
  - Double-tap or swipe a cue to bookmark (`bookmarkCue` → quiet `●` dot); dwell (`280 ms`), right-click, or press `Enter` to annotate (`annotateCue` → inserts `[@MM:SS] ...` into the active window); or draw directly on cues with Apple Pencil (`<svg class="rc-cue-ink-svg">`).
  - **On-device section audio summaries (`summarizeSectionOffline`, `speakSectionSummary`):** pure offline extractive summarizer for English, French, and Vietnamese legal/academic text (`§` sections, headings, and paragraphs), spoken via native `AVSpeechSynthesizer` on Mac and iOS with WebKit `speechSynthesis` fallback.
- **Find, Outline, Legal Numbering & Deletions Record (M2–M6):**
  - Instant case-insensitive Find/Replace (`⌘F`), slide-over Outline with heading folding and view-only **Newest first**, scoped legal list continuation and renumbering (`1.` → `1.1` → `(a)` → `(i)`), and transaction-filtered deletion history (`getRemoved()`).

## Native Shell Bridge (`window.recenseEditor`)

- **Document & State:** `setText(s)`, `getText()`, `getRemoved()`, `focus()`, `setCursor(offset)`, `insertBlock(text)`, `dropFile(path, caption)`, `setTheme('dark' | 'light')`, `setFontSize(px)`.
- **Window Navigation:** `step(delta)`, `swipeLeftToRight()`, `swipeRightToLeft()`, `openNewWindowOnLeft()`, `deleteEmptyWindow()`, `showPage(i)`, `currentPage()`, `pageCount()`, `setPageMode(on)`, `isPageMode()`, `voiceCommand(phrase)`.
- **Whiteboard Ink:** `getInk()`, `setInk(json)`, `mergeInk(remoteJson)`, `getInkTool()`, `setInkTool(tool)`, `getInkColor()`, `setInkColor(color)`, `toggleEraser()`, `onPencilAction('squeeze' | 'doubleTap')`.
- **Audio & Summaries:** `setAudioTranscript(json)`, `updateAudioTime(sec)`, `bookmarkAudioCue(idx, note)`, `annotateAudioCue(idx, text)`, `summarizeSection(idx)`, `summarizeAllSections()`.
- **Page → Native (`window.webkit.messageHandlers`):**
  - `editor`: debounced (`300 ms`) full plain markdown string for `draftpad.md`.
  - `ink`: debounced (`300 ms`) JSON string for `draftpad.ink.json`.
  - `ui`: `{ haptic: 'snap' | 'edge' | 'open' | 'squeeze' | 'shapeSnap' | 'erase' }` and `'bounce'`.
  - `audio`: `{ action: 'seek' | 'bookmark' | 'unbookmark' | 'annotate' | 'speakSummary', ... }`.
  - `link`: URL string to open externally on `⌘`-click.

## Build & Test

```sh
cd editor
npm test
npm run build
```

Open `editor/dist/editor.html` directly in Safari or load it inside `WKWebView`.
