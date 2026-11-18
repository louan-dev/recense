# FEAT-08 · Draftpad as one matter

From: owner 2026-11-14 (note and essay on the document as matter; echoes T-0046 ****** and T-0050 *****) · Status: `[ ]`
Law: `docs/law/purpose.md` (one matter, many states; rules 1–5; the twelve crossings).
Lanes: Draftpad (`editor/`, `shared/notesync.swift`) and strip (`strip/app.swift` VoiceEntry).

## The rule from the owner's essay
**No format commitment up front.** One page, every state present, each reachable from any other.
Nothing ever moves a section into a new file: sections written apart stay side by side (the interval is the music).

## What exists (facts, 2026-11-14)
- Draftpad = one `draftpad.md` in the Obsidian vault; the editor is `editor/`; merged across devices by `shared/notesync.swift`.
- Ink anchors to lines: BUG-06/07 (`editor/src/ink.js`).
- Timed words: `shared/ShowsKit/Sources/ShowsKit/Word.swift` (FEAT-04).
- Talk-to-write on the Mac: `strip/app.swift` VoiceEntry; on-device speech: `shared/speechcore.swift`.
- Crossing status today: `docs/law/purpose.md`, "The twelve crossings" (4 run or partly run, 8 unbuilt).

## The vessel
- **Liquid core:** the `.md` page is the one source of truth (purpose.md rule 5).
- **Every passage keeps its seed:** device, input (pencil / keys / touch / voice), time, place in the page (rule 3).
  Stored in a sidecar beside the page, never inside the owner's text.
- **Solid:** ink strokes stored beside the passage they touch, never a separate file to open.
- **Plasma:** each spoken passage keeps its audio and per-word times, so audio is searchable and plays from any word (T-0046).
- **Gas:** read-aloud of any passage, in vi / en / fr.
- **Other formats are states, not copies:** `.docx`, `.odt`, `.pdf` (with ink), `.txt` are made on demand from the core;
  edits made in LibreOffice or Word come back into the same page (round trip).
- **Movement first:** continue the page while walking: phone in a pocket, AirPods, the Action button or a Lock Screen
  control → the voice lands on the same page, in order.
- **Low toll on vulnerability:** no title, no file name, no format choice, no save button; private by default.

## Done check: the 12-move test
- One passage carried through all 12 crossings between ink, type, mark and voice (purpose.md table).
- Pass =
  - same page (no new file);
  - nothing lost (every word, stroke and audio second still present);
  - nothing duplicated;
  - every passage traces back to its seed;
  - each crossing reverses (round trip returns the same matter).
- Automated in `editor/` tests where the crossing is code; a device run (iPad + iPhone via iPhone Mirroring, Mac) for the rest.
- **Baseline to beat:** Notability + Obsidian + Voice Memos used together today: count files created and words lost
  carrying one passage through the same 12 moves. Done = 1 file, 0 words lost, where the baseline makes several files.

## Phases
- **P0 spikes** (30 min each; each may fail, and the failure is the answer):
  1. md ⇄ odt / docx round trip offline with pandoc (one-time install: source, size, checksum recorded; owner approves the download).
  2. Handwriting → text in vi / en / fr on iPad (Vision). Vietnamese is untested.
  3. A Lock Screen or Action-button voice control that appends to the open page.
- **P1** seed per passage (sidecar) + the 12-move test harness.
- **P2** voice continuation from any device and while moving. **Built 2026-11-17** (work/draftpad-voice, ported onto `matter.js`):
  - `shared/voiceappend.swift`: spoken words land at the end of draftpad.md as their own passage through `planBlindSave`;
    the passage (born voice, seed input "voice", already typed) goes into `draftpad.matter.json`.
    Note unreadable → the text waits in the Unsaved folder (T-0114) and joins at the next read; nothing lost.
  - iPhone/iPad: "Add to Draftpad" App Intent (`mobile/HostApp/iOS/DraftpadVoiceIntent.swift`), no app open:
    Siri ("Recense, add to Draftpad"), the Shortcuts app, or the Action button
    (Settings › Action Button › Shortcut › Recense › Add to Draftpad). It asks for the words; dictation answers.
  - Open page: `recenseEditor.appendVoice(text)` → `appendVoicePassage` (same shape as the Swift side).
  - Sidecar guard (`MatterWrite.plan`, both hosts): a `draftpad.matter.json` another writer changed is merged by the
    page (`mergeMatter`) before the page writes; no passage is written over.
  - Checks: `editor/test/feat08-voice.test.mjs`; `mobile/ios/Tests/voiceappend/main.swift` (swiftc).
  - Open: a Lock Screen / Control Center button (needs a widget extension); the Mac's own voice entry (App Intents
    need Xcode's metadata step); audio kept with the passage (P4). Untested on the device.
- **P3** the other formats as live states (export, then import back).
- **P4** searchable audio and ink inside the page (with T-0046).

## Notes on media (added 2026-11-16)
- A media item's note (`keep/<key>/note.md`, FEAT-23) is a Draftpad page like any other: same ink, same Matter menu.
- It is its own file. No crossing moves text between a media note and `draftpad.md` unless the owner pastes it.
- P4 here (searchable audio and ink inside the page) and FEAT-21 (one search) share one matcher; build FEAT-21 P1 first.

## Feasibility (labelled)
- Proven: Markdown core, ink anchoring, timed words, on-device speech.
- Assumed: lossless md ⇄ docx / odt round trip (formatting can drift; P0.1 decides).
- Untested: Vietnamese handwriting recognition; a Lock Screen control that writes into Draftpad.

## Offline gate
- At use: none. Setup only: pandoc (P0.1), Vision language data already on the device.

## Sources
- The owner's note and essay, 2026-11-14, verbatim (private): `~/.claude/context/recense/research/2026-11-14-wish-order-law.md` §2–§3.

## Decisions (2026-11-16; Q1 owner "keep", Q2–4 coordinator under the owner's delegation "2-4 you decide")
1. **Keep the ink.** After #1 (ink → type) the handwriting stays visible beside its typed words; no fade.
2. **`> ` markup is fine.** #4 may write blockquote markup into `draftpad.md`: plain Markdown, reads the same in Obsidian, the owner's words untouched.
3. **Undo is per device.** Reverse the last crossing made on this device. Never silently undo another device's crossing;
   if the passage changed since, refuse with a short note instead of guessing.
4. **One Matter menu.** Every crossing is reachable from one visible "Matter" list on the passage (selection / long-press;
   the same place on Mac, iPhone, iPad), named by what you get. Squeeze and the radial menu are shortcuts placed by lane
   draftpad-ink from `matterActions` (`{id, label, from, to, run}`). Voice phrases = the spoken label, P2 (with VoiceEntry).

## Handoff (lane draftpad-matter, 2026-11-16, round 2; branch `work/draftpad-matter`)
**Built:**
- `editor/src/matter.js` (P1 core):
  - one record per passage: its seed, and its forms in the four states, linked;
  - the sidecar `draftpad.matter.json` beside `draftpad.md` and `draftpad.ink.json`;
  - the 12 crossings, each logged with an exact undo;
  - `checkMatter`, the five pass conditions;
  - `mergeMatter`, the two-device union.
- Decisions 1–4 are in the code:
  - Q1: #1 leaves the strokes untouched.
  - Q3: `reverseLast(m, { device })` undoes the last crossing on that device. It refuses with a note when the passage changed since, or when the undo was compacted.
  - Q4: `matterActions(m, pid)` returns `{id, label, from, to, run}`, labelled by destination. A label that appears twice gets " from pencil/voice/text/mark". `menuForSelection` turns plain selected words into a passage on first use.
- **The Matter menu** (`editor/src/mattermenu.js`):
  - a "Matter" pill appears 450 ms after a selection; tap it, or right-click / long-press the selection, to open the list;
  - items are 44 pt high; Esc or a tap outside closes it;
  - a refused crossing shows its short note in the list.
- **#2 word attachment:** `attachStrokeToWord`. The ink layer reports each new stroke (`onStrokeAdded`). The editor maps the stroke's start to a body position with `posAtCoords`, and the stroke gets `word: {pid, i, w}`.
- **Compaction:** the last 24 crossings per device stay reversible. Older ones keep their trace but not their undo. 100 crossings cost under 600 bytes each.
- **Bridge:** `getMatter`, `setMatter`, `mergeMatter`, `seedPassage`, `cross`, `reverseCrossing` (per device), `setMatterDevice`, `matterMenu(from, to)`, `runMatterAction(id, from, to)`, `openMatterMenu`, `crossings`.
- `editor/dist` is rebuilt.

**The 12-move test: all 12 pass in code** (`editor/test/feat08-*.test.mjs`: twelve-moves, crossings, decisions, bridge).
- One pencil-born passage goes through 1, 3, 7, 12, 5, 4, 9, 8, 6, 11, 10, 2. After every move: same page and files, nothing lost, nothing duplicated, traced to its seed. Undoing all 12 returns the start exactly, also after a save and reload.
- Each crossing alone passes with its reverse.
- Tests: 287 total, 286 pass, 0 fail, 1 skipped (256 from main + 30 FEAT-08). Run `npm ci` first if `node_modules` is missing.
- Chromium smoke test of the built `dist/editor.html`:
  - select words → the pill appears → the list shows Pencil over, Highlight, Read aloud;
  - Highlight is logged with device Mac;
  - per-device undo empties the log;
  - no page errors.

**Still owed (not verified, or not built):**
- **Marks are not drawn.** A highlight, region or note lives in the sidecar but nothing paints it on the page yet. That needs a CodeMirror decoration from `forms.mark`.
- **Read-aloud plans** (#7, #9, #11) use estimated word times. The hosts' `speak` and `willSpeakRange` are not connected yet.
- **Spoken input** (#8, #10, #12) comes in as data. VoiceEntry, the Lock Screen and the Action button do not call it yet (P2, with the spoken labels).
- **#2 is only half done.** Strokes are linked to words, but they still move by line (`resolveStrokeAnchor`), not with their word when a line reflows. The `posAtCoords` mapping is untested on a device.
- **Long-press:** iOS shows its own edit menu on long-press. The pill is the dependable path there; whether `contextmenu` fires in WKWebView is unchecked.
- **Not measured:** the baseline count (Notability + Obsidian + Voice Memos).
- **Not started:** the P0 spikes and P3 formats.

**Swift (coded, not compiled, device check owed):**
- `strip/editorhost.swift` saves and loads the sidecar; it does not merge another device's copy while open.
- `mobile/HostApp/iOS/Draftpad.swift` loads and saves it and merges another device's copy on poll.
- Neither host calls `setMatterDevice` yet. The editor guesses the device from the user agent (Mac / iPad / iPhone). A host call with the device's name would be better.
- `shared/notesync.swift` is unchanged (it already merges the body; anchors are quoted words, which survive its merges).

**Device checks:**
- Mac: build; select words → Matter → Highlight; right-click menu; the sidecar is written and reloads; undo.
- iPhone 12 Pro Max: the pill appears on a selection; Read aloud; merge after a Mac edit; the Mac's crossing cannot be undone from the phone.
- iPad Air M2 13-inch: Pencil → reading → Make text lands under the ink; Pencil over, then a stroke on a word gets `word`; Circle as note.

**Open questions:** none. Q1–Q4 are settled above. For lane draftpad-ink: place `matterActions` in the radial and selection menus; `mattermenu.js` is the plain fallback.
