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
