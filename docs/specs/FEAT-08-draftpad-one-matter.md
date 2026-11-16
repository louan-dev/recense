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
- **P2** voice continuation from any device and while moving.
- **P3** the other formats as live states (export, then import back).
- **P4** searchable audio and ink inside the page (with T-0046).

## Feasibility (labelled)
- Proven: Markdown core, ink anchoring, timed words, on-device speech.
- Assumed: lossless md ⇄ docx / odt round trip (formatting can drift; P0.1 decides).
- Untested: Vietnamese handwriting recognition; a Lock Screen control that writes into Draftpad.

## Offline gate
- At use: none. Setup only: pandoc (P0.1), Vision language data already on the device.

## Sources
- The owner's note and essay, 2026-11-14, verbatim (private): `~/.claude/context/recense/research/2026-11-14-wish-order-law.md` §2–§3.

## Handoff (lane draftpad-matter, 2026-11-16; branch `work/draftpad-matter`)
**Built (P1 core):** `editor/src/matter.js`, one record per passage with its seed and its forms in the four states, linked.
The sidecar is `draftpad.matter.json` beside `draftpad.md` and `draftpad.ink.json`. All 12 crossings are pure functions.
Each one is logged with an exact undo (`reverseLast`), and `checkMatter` encodes the five pass conditions.
Two devices merge with `mergeMatter`: passages, forms, stroke ids and spoken audio are unioned, and the latest move sets the phase.
The bridge exposes `getMatter`, `setMatter`, `mergeMatter`, `seedPassage`, `cross(n, pid, opts)`, `reverseCrossing` and `crossings` (`editor/src/index.js`).
`editor/dist` is rebuilt.

**The 12-move test: all 12 pass in code** (`editor/test/feat08-twelve-moves.test.mjs`, `feat08-crossings.test.mjs`, `feat08-bridge.test.mjs`).
- One pencil-born passage goes through the circuit 1, 3, 7, 12, 5, 4, 9, 8, 6, 11, 10, 2. After every move: same page and files, no word, stroke or audio lost, nothing duplicated, the seed traced.
- Undoing all 12 returns the start exactly. This also holds after a save and reload of the three files.
- Each crossing alone passes from a passage born in its own state, and its reverse returns the same matter.
- Tests were red first: both files failed on the missing module. Now 278 pass, 0 fail, 1 skipped (256 earlier + 22 FEAT-08). Run `npm ci` first if `node_modules` is missing.
- Smoke test: the built `dist/editor.html` in Chromium ran seed voice → #10 → a refused #6 → reverse, with no page errors.

**What "pass" covers, and what it does not yet:**
- The crossings run on the data: the page text, the ink file and the sidecar. No gesture, menu or voice command triggers a crossing yet. Only the bridge calls do.
- #1 and #11 use the OCR reading the hosts already set (`setInkText` → `stroke.ocr.t`). Without a reading, #1 refuses.
- #7, #9 and #11 build a read-aloud plan with *estimated* word times. Wiring the hosts' `speak` / `willSpeakRange` to replace them is owed.
- #8, #10 and #12 take the spoken audio and words as input. `strip/app.swift` VoiceEntry and the Lock Screen / Action button do not call `seedPassage` / `cross` yet (P2).
- #2 builds the word surface and `wordAt`. The ink layer does not yet anchor new strokes to words (it needs `posAtCoords` in `ink.js`).
- The sidecar grows: each log entry keeps a full copy of the passage before it, about 20 KB after 12 moves. Compaction is owed.
- Baseline count (Notability + Obsidian + Voice Memos): not measured; device run owed.
- P0 spikes (pandoc, Vietnamese handwriting, Lock Screen control) are not started. P3 formats (docx/odt/pdf) are not started.

**Swift (coded, not compiled, device check owed):**
- `strip/editorhost.swift`: the `matter` handler writes `draftpad.matter.json`; on load it calls `setMatter`. Like ink, it does not merge another device's copy while open.
- `mobile/HostApp/iOS/Draftpad.swift`: `matterNote`, load and save, the `matter` handler, and a poll that merges another device's copy through `mergeMatter`.
- `shared/notesync.swift` is unchanged. It already 3-way merges the body. The sidecar anchors to quoted words with their context, not offsets, so they survive its merges. The JSON sidecar is merged in JS.

**Device checks owed:**
- Mac: build; seed a passage via the console; run a crossing; check that `draftpad.matter.json` appears and reloads.
- iPhone 12 Pro Max: voice → #10 dictation lands on the open page in order; a merge after a Mac edit.
- iPad Air M2 13-inch: Pencil → OCR → #1 lands under the ink's line; #6 bracket stroke shows in the margin; #5 region.

**Owner questions:**
1. After #1 the handwriting stays visible next to its typed words (nothing hidden). Keep it, or let the ink fade once typed?
2. #4 writes `> ` (blockquote markup) into `draftpad.md`. Your words are untouched. Is that acceptable under rule 4?
3. Reverse: undo the last crossing *on this device*, or the last on the page (which may be another device's)? Today it is the last on the page.
4. Which gesture or voice phrase should start each crossing?
