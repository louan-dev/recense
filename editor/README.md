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
  - **Tools & 8-colour pure-dot row:** `select` (default; mouse never inks), `pen`, `highlighter` (rendered under text with `mix-blend-mode: multiply`) and `eraser-whole` (`eraseWholeStrokes`), then a colour wheel, plus 8 colours (`INK_COLORS`, replaceable from the wheel).
  - **Draw-and-hold shape snapping:** quick freehand writing (such as a handwritten letter `'o'`) stays freehand; holding at the end of a stroke (`>= 320 ms`) snaps rough circles to clean geometric `<ellipse>` shapes and straight strokes to `<line>`.
  - **240 Hz Apple Pencil Pro coalesced input & squeeze:** captures `e.getCoalescedEvents()` for full-fidelity strokes; squeezing or double-tapping Apple Pencil Pro (`onPencilAction('squeeze' | 'doubleTap')`) wakes or sleeps the palette in its place under the top edge.
  - **Dropped-in file embeds keep ink on top (`src/embeds.js`):** dropping a PDF or image onto the page inserts `![caption](target)` and captures Pencil strokes over `.cm-embed` widgets so annotations stay anchored to the embedded file.
  - **CRDT-safe multi-device merge (`mergeInkDocuments`):** unions strokes by `id` and respects `removed` tombstone IDs across Mac and iPad/iPhone.
- **Live audio transcript sidecar & offline section summaries (`src/audio.js`):**
  - While audio plays, a zero-chrome transcript pane (`createTranscriptPane`) appears beside the page and highlights the active cue (`activeCueIndexAt`).
  - Double-tap or swipe a cue to bookmark (`bookmarkCue` → quiet `●` dot); dwell (`280 ms`), right-click, or press `Enter` to annotate (`annotateCue` → inserts `[@MM:SS] ...` into the active window); or draw directly on cues with Apple Pencil (`<svg class="rc-cue-ink-svg">`).
  - **On-device section audio summaries (`summarizeSectionOffline`, `speakSectionSummary`):** pure offline extractive summarizer for English, French, and Vietnamese legal/academic text (`§` sections, headings, and paragraphs), spoken via native `AVSpeechSynthesizer` on Mac and iOS (the voice follows the text's language, best installed voice first, through one `speak()` per host), with WebKit `speechSynthesis` fallback.
- **Ambidextrous Dual Notification-Center Sidebars ("Dual Wings") & 4 Feathery Offline-First Widgets (`src/wings.js`):**
  - **Symmetric Dual Sidebars (`.rc-wing-left` & `.rc-wing-right`):** slide in from the left edge (`L→R`) and right edge (`R→L`) with macOS Notification-Center spring kinetics (`320ms cubic-bezier(0.22, 1, 0.36, 1)`), sized for a 13" screen (`width: min(272px, 30vw)`) so either wing can open alone (`'left'`, `'right'`) or **both simultaneously (`'both'` bilateral mode)** without cramping the central 66ch Draftpad column.
  - **True Ambidexterity:** `swapWings()` mirrors all widgets between left and right wings in one action when switching hands or posture; `moveWidget(id, side)` moves any widget to either wing; two-touch simultaneous inward edge swipes open both wings together; and multilingual voice commands (`"left wing"`, `"right wing"`, `"both wings"`, `"swap wings"`, `"close wings"`, `"cánh trái"`, `"hai bên"`, `"đổi bên"`, `"volet gauche"`, `"deux volets"`, `"inverser"`) drive the exact same moves.
  - **On the Mac, native panels (`src/wingpanel.js`, `strip/wingpanels.swift`):** the host loads this same page once per side with `window.__RECENSE_WING_SIDE = 'left' | 'right'`; the page then shows only that wing, Notification-Center style (no title, no ×: the grabber at the top of the inner edge, **Show in wing…**, the cards), reports its height and every card's shape so the host draws frosted glass behind them, and sends citations and Agenda jumps to the editor. The editor page calls `setNativeWings(true)` there, so `openWing` / `closeWing` / `toggleWing` (gestures, voice, API) open the panels instead. iOS keeps the in-page wings.
  - **Card controls (W2):** swipe a card left to Remove (Undo toast, 5 s), right to Pin (pinned cards stay first; again to unpin); on the Mac a two-finger horizontal trackpad swipe does the same, on iOS a haptic marks the threshold, with Reduce Motion the card fades instead of sliding. Hold and drag to reorder. Each card's ··· menu: Move up, Move down, Move to the other wing, Pin / Unpin, Remove. The Recense card is a card like the others (pin, remove, move, re-add).
  - **Show in wing…:** a pill at the top of each wing that dissolves into a field; typing filters what this wing can still show; Return or a tap adds it. Nothing playing → the wing opens with the field open and the cursor in it. Esc or ✕ closes it. `onFindChange(side, open)` tells the host (the Mac panel takes key focus only while it is open). Layout and pins are saved in `draftpad.wings.json` (version 2; version 1 loads unchanged). Tests: `test/p12-cardcontrols.test.mjs`.
  - **Card heights (W3):** 1–4 rows (S/M/L/XL; `--rc-row` 112 px + 10 px gaps), from the bottom-edge grabber (`role=slider`, snaps per row with a haptic, ↑/↓ keys) or Size in the ··· menu. Defaults keep the earlier look (Preview and Player L, Agenda M, the rest S). More rows show more: the Agenda lists one event per row and counts the rest; the Recense card clamps its line per size (CSS only). Text never scales; overflow scrolls inside the card. `setSize(side, id, rows)` / `getSize`. State v3 adds `sizes`; v2 and v1 load unchanged. Tests: `test/p13-cardsizes.test.mjs`.
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
- **Dual Wings, Feathery Widgets & Calendar Extractor:** `openWing(side)`, `closeWing(side)`, `toggleWing(side)`, `isWingOpen(side)`, `swapWings()`, `moveWidget(id, side)`, `getWingLayout()`, `setPreviewTarget(src, caption)`, `setMediaSource(src, title)`, `setPlaybackRate(rate)`, `setLoopRange(start, end)`, `setFindMyItems(items)`, `setMailMessages(msgs)`, `extractCalendarEvents(text, opts)`, `getCalendarEvents()`, `setWingsState(json)`, `getWingsState()`; Mac panels: `setNativeWings(on)`, `insertBlock(text)`, `jumpToLine(n)`.
- **Page → Native (`window.webkit.messageHandlers`):**
  - `editor`: debounced (`300 ms`) full plain markdown string for `draftpad.md`.
  - `ink`: debounced (`300 ms`) JSON string for `draftpad.ink.json`.
  - `ui`: `{ haptic: 'snap' | 'edge' | 'open' | 'squeeze' | 'shapeSnap' | 'erase' }` and `'bounce'`.
  - `audio`: `{ action: 'seek' | 'bookmark' | 'unbookmark' | 'annotate' | 'speakSummary', ... }`.
  - `calendar`: `{ action: 'addEvents' | 'jumpToLine', events: [...] }`: `addEvents` carries one confirmed event; the host saves it with `EventKit` and answers `calendarResult(id, ok, message)`. At load it sends `setCalendarAdded(ids)`.
  - `wings`: `{ action: 'saveState' | 'cite' | 'openSession' | 'openApp' | 'wing' | 'insert' | 'jumpToLine' | 'layout', ... }` (`saveState` carries `state` as a JSON string) → persisted to `draftpad.wings.json`; `openApp` with `app: 'iphone-mirroring'` opens iPhone Mirroring (Mac).
  - `link`: URL string to open externally on `⌘`-click.

## Build & Test

```sh
cd editor
npm test
npm run build
```

Open `editor/dist/editor.html` directly in Safari or load it inside `WKWebView`.

## Ink palette and shape snapping (2026-11-08)
- The palette's tool buttons show icons (select, pen, highlighter, eraser), with names on hover and for VoiceOver. Circle and underline are gone: hold the stroke's end instead.
- The pen only turns a stroke into a shape when you hold still at its end for 0.5 s (`SNAP_HOLD_MS`) and it's bigger than a letter (`SNAP_MIN_SIZE`, 40 px):
  a closed loop becomes an ellipse, and a nearly straight stroke becomes a line. Letters and curves stay as drawn.

## Palette pill, colour wheel, handwriting search (2026-11-08)
- **Pill:** a small pill sits under the top edge, always. Tap it (or Pencil Pro double-tap / squeeze) and it glows and
  wakes the palette, which floats over the text without moving it, the same on blank and written pages. Tap anywhere
  else, or Esc, and it sleeps.
- **Eraser:** the cursor becomes a see-through ring the exact size it erases (`ERASER_RADIUS`, 12 pt). The partial eraser
  is gone.
- **Colour wheel** (after the eraser): pick from the gradient and lightness slider, or the dropper samples any shade on
  screen (Mac: `NSColorSampler`; iOS: the system colour picker; browsers with `EyeDropper`). A ✓ appears; only ✓
  replaces the selected colour. Tapping anywhere else closes the menu and keeps the old colour.
- **Handwriting in ⌘F:** 1.5 s after you stop writing, the group of pen strokes is read on the device (Apple Vision;
  English, French, Vietnamese; `shared/inkocr.swift`) and the text is kept with the strokes in the ink file. Find shows
  a "✎ n" button beside the text count; it steps through ink matches and makes them glow. Accents and case are ignored.
- **Paging:** a mouse drag in the margin selects text; Option + drag pages.

## Recense what you typed; Chapters (2026-11-08, M1)
Brief: `.handoff/coordinator/recense-the-text-brief.md`. Recense writes new text from yours (it never changes yours).
- **The layer** (`src/recense.js`): off by default. Turn it on with ✦ in the toolbar, **··· › Recense layer**, or say
  "recense". One lens at a time, dimmed under your text, never in the file:
  - **Gist**: the chapter's title and one-line gist above a section, a line per paragraph after it;
  - **Reformat**: the structure already there (IRAC for law, a timeline for dates, definitions, else an outline);
  - **Source**: each sentence's translation (English → Vietnamese, anything else → English;
    **Translate into** changes it for the page).
  Change the lens from **··· › Lens** or say "gist", "reformat", "source".
- **Citations**: tap a lens line and the sentences it comes from light up. A line that cites nothing says **added**.
  A line whose words aren't in what it cites is dropped, never shown (`src/lenses.js`).
- **When it runs**: a section untouched for 60 s, on power or with the battery above 30 %; or **··· › Recense now**
  (or say "recense now"). Never while you type. Each section (≤ ~1,500 words, cut at your headings) is cached by a hash
  of its sentences, so an edit redoes only that section; lines that cite untouched sentences stay meanwhile ("earlier").
- **Engine**: Apple's on-device model (`shared/recensetext.swift`). Without it (Apple Intelligence off, or an
  unsupported language) the lenses are extractive, your own most central sentences, labelled **extract**.
- **Wing card**: while the layer is on and you're writing, the Recense card shows the caret paragraph's lens line with
  its source under it; the playing media's line comes back when you leave the editor.
- **Saved pages** write `<vault>/Recensed/<id>.json` (transcript Lines: the sentences, each lens, the chapters). Unsaved
  pages keep their lenses in the app's cache only.
- **Chapters tab** (`src/chapters.js`): your headings, live; for stretches without one, the recensed title in italics
  with ✦ (never written into the page); text not yet recensed as one "New since HH:MM" entry. Each entry shows a dim gist
  and its listening time (150 words a minute). Tap to jump; hold or ··· for **Play from here**, **Make heading** (the only
  way a recensed title enters your page, as a `#` heading) and **Copy gist**. Titles hold still while the panel is open.
- Tests: `test/p11-recense.test.mjs` (Line JSON, the citation check, only edited lines redone, titles held while
  open, Make heading the only write, saved pages only, the wing card).

## Pages expire unless saved; Saved, Playlists, calendar sheet (2026-11-08)
- **Ephemeral pages** (`src/library.js`): a page lives 14 days, like a new Recense episode (`Rules.newKeepDays`), from
  the later of its date heading and its last edit (kept per page in `draftpad.pages.json`). The newest page, the page
  on screen and undated pages never expire. Expired pages are appended to `<vault>/Draftpad expired/<YYYY-MM>.md`
  first, and leave the note only once that write succeeded (their ink goes with them).
- **Bookmark** (toolbar, the same icon as the player's bookmarks): tap to save the page ("N days left" shows until
  then). Tap again: the **Saved in** sheet (Saved pages, New playlist, your playlists; tick, then Done). A saved page
  carries one hidden line under its heading, `<!-- saved k3x9q2 -->` (Obsidian hides it too).
- **Side panel tabs**: Chapters (was Outline; see below) · Saved (jump to a saved page) · Playlists (Listen reads the pages aloud in order;
  Name & details; × removes with a toast, no confirmation). Format of `draftpad.playlists.json` is at the top of
  `src/library.js` (pages now; episodes and audio files share the same list later).
- **Calendar sheet** (`src/calsheet.js`): every new future date in your notes opens a prefilled sheet once typing
  pauses (3 s): title, day, times, all day, place, notes. Nothing is saved until **Add to Calendar**; **Don't add**
  is remembered (`x:<id>` in `draftpad.events.json`); tapping outside or Esc asks again next time. Not in wing panels.
- Read-aloud for playlists: `src/speech.js` (host voice with word ranges, `shared/draftpadlibrary.swift`).
