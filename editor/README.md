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
  - **On-device section audio summaries (`summarizeSectionOffline`, `speakSectionSummary`):** pure offline extractive summarizer for English, French, and Vietnamese legal/academic text (`§` sections, headings, and paragraphs), spoken via native `AVSpeechSynthesizer` on Mac and iOS (the voice follows the text's language, best installed voice first, through one `speak()` per host), with WebKit `speechSynthesis` fallback.
- **Ambidextrous Dual Notification-Center Sidebars ("Dual Wings") & 4 Feathery Offline-First Widgets (`src/wings.js`):**
  - **Symmetric Dual Sidebars (`.rc-wing-left` & `.rc-wing-right`):** slide in from the left edge (`L→R`) and right edge (`R→L`) with macOS Notification-Center spring kinetics (`320ms cubic-bezier(0.22, 1, 0.36, 1)`), sized for a 13" screen (`width: min(272px, 30vw)`) so either wing can open alone (`'left'`, `'right'`) or **both simultaneously (`'both'` bilateral mode)** without cramping the central 66ch Draftpad column.
  - **True Ambidexterity:** `swapWings()` mirrors all widgets between left and right wings in one action when switching hands or posture; `moveWidget(id, side)` moves any widget to either wing; two-touch simultaneous inward edge swipes open both wings together; and multilingual voice commands (`"left wing"`, `"right wing"`, `"both wings"`, `"swap wings"`, `"close wings"`, `"cánh trái"`, `"hai bên"`, `"đổi bên"`, `"volet gauche"`, `"deux volets"`, `"inverser"`) drive the exact same moves.
  - **Move any widget to the other side:** each card has one visible control above it ("Move to right ›" / "‹ Move to left", Enter or Space works too). The layout is saved in `draftpad.wings.json`.
  - **4 Feathery Offline-First Widgets (Replacing Heavy Mac App Launches):**
    - `preview`: Offline PDF/image exhibit viewer (`recense-file://...`) with one-tap Markdown citation into the active Draftpad window.
    - `quicktime`: Offline `<video>`/`<audio>` media player with playback rate (`0.5x`–`2x`), A–B loop range (`setLoopRange`), and `[@MM:SS]` timestamp citation into Draftpad.
    - `iphone` (Mac only): opens macOS's own iPhone Mirroring app. The Mac host turns it on (`enableWidget('iphone')`); iOS never shows it.
    - `findmy`: 100% offline-first cached device/location viewer (`setFindMyItems`) with one-tap location citation (`zero FindMy.app launch`), plus persistent signed-in web session support (`openPersistentSession('findmy')` + `WKWebsiteDataStore.default()`). **Off by default:** its sign-in opens icloud.com, which needs the network at the moment of use; place it with `moveWidget` only if you want it.
    - `mail`: 100% offline-first cached mail digest (`setMailMessages`) with one-tap blockquote citation (`> From: ...`, `zero Mail.app launch`), plus persistent signed-in web session support (`openPersistentSession('mail')` + `WKWebsiteDataStore.default()`). **Off by default**, for the same reason as `findmy`.
- **Multilingual date finder → Apple Calendar, only when you press Add (`src/wings.js`, `strip/editorhost.swift`, `mobile/HostApp/iOS/Draftpad.swift`):**
  - Continuously scans Draftpad text across all `<!-- page -->` windows in English, French (`le 14 novembre 2026 à 14h30`, `demain à 9h00`), and Vietnamese (`ngày 20/11/2026 lúc 08:30`, `ngày mai lúc 15:00`), ignoring bare standalone Draftpad page-header date lines.
  - Dated lines show in the `Agenda` card, rescanned 0.8 s after typing stops. Nothing is saved until you press **Add to Calendar** on a line; the card then shows "Adding…", "Added to Calendar", or "Not added: <reason> · Try again" as the host reports. Times are local ("1pm" is 1 PM here); a date without a time is an all-day event; "today"/"tomorrow" count only with a time; header fields like "Date: October 9, 2026" are skipped. Saved ids live in `draftpad.events.json`. The Mac asks for full calendar access (it already reads the agenda); iOS asks only to add events (write-only).
- **Find, Outline, Legal Numbering & Deletions Record (M2–M6):**
  - Instant case-insensitive Find/Replace (`⌘F`), slide-over Outline with heading folding and view-only **Newest first**, scoped legal list continuation and renumbering (`1.` → `1.1` → `(a)` → `(i)`), and transaction-filtered deletion history (`getRemoved()`).

## Native Shell Bridge (`window.recenseEditor`)

- **Document & State:** `setText(s)`, `getText()`, `getRemoved()`, `focus()`, `setCursor(offset)`, `insertBlock(text)`, `dropFile(path, caption)`, `setTheme('dark' | 'light')`, `setFontSize(px)`.
- **Window Navigation:** `step(delta)`, `swipeLeftToRight()`, `swipeRightToLeft()`, `openNewWindowOnLeft()`, `deleteEmptyWindow()`, `showPage(i)`, `currentPage()`, `pageCount()`, `setPageMode(on)`, `isPageMode()`, `voiceCommand(phrase)`.
- **Whiteboard Ink:** `getInk()`, `setInk(json)`, `mergeInk(remoteJson)`, `getInkTool()`, `setInkTool(tool)`, `getInkColor()`, `setInkColor(color)`, `toggleEraser()`, `onPencilAction('squeeze' | 'doubleTap')`.
- **Audio & Summaries:** `setAudioTranscript(json)`, `updateAudioTime(sec)`, `bookmarkAudioCue(idx, note)`, `annotateAudioCue(idx, text)`, `summarizeSection(idx)`, `summarizeAllSections()`.
- **Dual Wings, Feathery Widgets & Calendar Extractor:** `openWing(side)`, `closeWing(side)`, `toggleWing(side)`, `isWingOpen(side)`, `swapWings()`, `moveWidget(id, side)`, `getWingLayout()`, `setPreviewTarget(src, caption)`, `setMediaSource(src, title)`, `setPlaybackRate(rate)`, `setLoopRange(start, end)`, `setFindMyItems(items)`, `setMailMessages(msgs)`, `extractCalendarEvents(text, opts)`, `getCalendarEvents()`, `setWingsState(json)`, `getWingsState()`.
- **Page → Native (`window.webkit.messageHandlers`):**
  - `editor`: debounced (`300 ms`) full plain markdown string for `draftpad.md`.
  - `ink`: debounced (`300 ms`) JSON string for `draftpad.ink.json`.
  - `ui`: `{ haptic: 'snap' | 'edge' | 'open' | 'squeeze' | 'shapeSnap' | 'erase' }` and `'bounce'`.
  - `audio`: `{ action: 'seek' | 'bookmark' | 'unbookmark' | 'annotate' | 'speakSummary', ... }`.
  - `calendar`: `{ action: 'addEvents' | 'jumpToLine', events: [...] }`: `addEvents` carries one confirmed event; the host saves it with `EventKit` and answers `calendarResult(id, ok, message)`. At load it sends `setCalendarAdded(ids)`.
  - `wings`: `{ action: 'saveState' | 'cite' | 'openSession' | 'openApp', ... }` → persisted to `draftpad.wings.json`; `openApp` with `app: 'iphone-mirroring'` opens iPhone Mirroring (Mac).
  - `link`: URL string to open externally on `⌘`-click.

## Build & Test

```sh
cd editor
npm test
npm run build
```

Open `editor/dist/editor.html` directly in Safari or load it inside `WKWebView`.
