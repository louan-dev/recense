# FEAT-08 · Draftpad as one matter

From: owner 2026-11-14 (note and essay on the document as matter; echoes T-0046 ****** and T-0050 *****) · Status: `[~]`
(P1 and P2 built in code; device checks owed; P0 and P3–P11 not built)
Amended 2026-11-18 (owner 2026-11-18, PLAN-1118 §12 wish 11 "phase changes", §12c batch law): the **Phases** section is
rewritten so each phase ships alone; new phases P5–P11; added "One home and embodiments", "Debug channel",
"Device checks", "Offline-first gate", "Open questions", "Registry block".
Law: `docs/law/purpose.md` (one matter, many states; rules 1–5; the twelve crossings).
Lanes: Draftpad (`editor/`, `shared/notesync.swift`) and strip (`strip/app.swift` VoiceEntry).

Labels: **proven** = a test or the code shows it (file:line) · **assumed** = believed, not shown · **untested** = nobody ran it.

## One home and embodiments (added 2026-11-18)
- **One home: `editor/src/`** (`matter.js`, `mattermenu.js`): seeds, the 12 crossings, undo, merge, the Matter menu.
  - Glue only: `strip/editorhost.swift` (Mac), `mobile/HostApp/iOS/Draftpad.swift` (iPhone, iPad),
    `strip/app.swift` VoiceEntry (P10).
  - File rules (read, blind save, Unsaved) are not this spec's logic: `shared/notesync.swift`, `shared/draftpadfile.swift`.
  - **Known second copy (a gap):** voice append exists twice, `shared/voiceappend.swift` (the App Intent, which runs
    with no web view) and `appendVoicePassage` (`editor/src/matter.js:255`). Q-B2.
- **Embodiments:** Mac · iPhone (12 Pro Max) · iPad (Air M2 13-inch) · web (the editor PWA,
  `library/src/client/editorpwa/`: **untested** for the Matter sidecar; no host saves it there).
- **Code headers:** each file or function derived from this spec starts with `// Derived from Spec: FEAT-08 P<n>`.

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

## Phases (rewritten 2026-11-18: each phase ships alone)
Sources: the 12-move test (above); T-0046 (talk to annotate, listen back, searchable audio and text);
T-0050 (Draftpad at the Notability standard); PLAN-1118 §12c. Phase ids P0–P4 keep their old meaning; P5–P11 are new.

### Batch law (PLAN-1118 §12c; the owner's grouping rules, 2026-11-12)
- A build batch holds at most 2 features, each already specced, and never two high-effort ones.
- **Batch 1** (Stream A, chunk 1): FEAT-23 P0 + P0c (high) with FEAT-08 **P5 + P6** (low, medium).
  - One read serves both: `editor/src/matter.js`, `audio.js`, `links.js`, `index.js`, and the two hosts.
  - FEAT-08's share is held to P5 and P6 so the batch never holds two high-effort features.
- **Batch 2 · after batch 1** (chunk 2): T-0050, the Notability gauntlet (**P11**, high), with **P7** (medium).
  Same files: `editor/src/ink.js`, `matter.js`, `index.js`.
- **Batch 3 · after batch 2:** **P8** alone (high: anchoring math).
- **Not batched:** P0 (spikes, any time); P9 (with narration, `shared/voice/`); P10 (with `strip/app.swift` VoiceEntry);
  P3 (after P0.1); P4 (after FEAT-21 P1).
- One commit per phase. A failed phase leaves its batch (HELD); the rest ship.

### Index
| Phase | Ships in | Status |
|---|---|---|
| P0 spikes | alone | `[ ]` |
| P1 seed + 12-move harness | built 11-16 | `[~]` |
| P2 voice continuation | built 11-17 | `[~]` |
| P5 hosts name the device | batch 1 | `[~]` built 11-18 (work/a2-underlay); device check owed |
| P6 note time in the seed | batch 1 | `[~]` built 11-18 (work/a2-underlay); device check owed |
| P7 marks drawn | batch 2 | `[ ]` |
| P11 the Notability bar | batch 2 | `[ ]` |
| P8 strokes follow words | batch 3 | `[ ]` |
| P9 read-aloud, real voice | with narration | `[ ]` |
| P10 spoken input wired | with VoiceEntry | `[ ]` |
| P3 other formats | after P0.1 | `[ ]` |
| P4 searchable audio + ink | after FEAT-21 P1 | `[ ]` |

### Which phase makes each crossing real on a device
All 12 already pass in code (**proven** `editor/test/feat08-twelve-moves.test.mjs`). A phase makes one usable on the devices.
- 1 ink → type: runs one-way (`shared/inkocr.swift`); device check under P1.
- 2 type → ink: P8.
- 3 type → mark: P7.
- 4 mark → type: P7.
- 5 ink → mark: P7.
- 6 mark → ink: P8.
- 7 mark → voice: P9.
- 8 voice → mark: P10 (a timestamped margin note; its time from P6 in a media note).
- 9 type → voice: P9.
- 10 voice → type: P2 (iPhone, iPad); P10 (Mac).
- 11 ink → voice: P9.
- 12 voice → ink: P10.

### Each phase: change · files (`editor/` first, then hosts) · check · embodiments
- **P0 · Spikes** (30 min each; each may fail, and the failure is the answer):
  1. md ⇄ odt / docx round trip offline with pandoc (one-time install: source, size, checksum recorded; owner approves the download).
  2. Handwriting → text in vi / en / fr on iPad (Vision). Vietnamese is untested.
  3. A Lock Screen or Action-button voice control that appends to the open page.
  - Files: none committed (scratch). The result is written into this spec.
  - Embodiments: Mac (1), iPad (2), iPhone (3).
- **P1 · Seed per passage (sidecar) + the 12-move test harness.** `[~]` built 2026-11-16 (Handoff below).
  - Files: `editor/src/matter.js`, `editor/src/mattermenu.js`; the hosts save and load the sidecar.
  - Check, done in code: `editor/test/feat08-*.test.mjs`. Owed: the device checks under Handoff.
  - Embodiments: Mac, iPhone, iPad. Web untested.
- **P2 · Voice continuation from any device and while moving.** `[~]` **Built 2026-11-17** (work/draftpad-voice, ported onto `matter.js`):
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
  - Embodiments: iPhone, iPad (the intent); the open page on Mac, iPhone, iPad. The Mac's own entry is P10.
- **P5 · The hosts name the device; the Mac re-reads the sidecar while open** (low; batch 1).
  - Change: both hosts call `setMatterDevice(<name>)` at load. A crossing's device is then the host's name,
    not a guess from the user agent (**proven** the guess and the setter: `editor/src/index.js:807`, `:1255`;
    no host calls it, search 2026-11-18).
  - The name: the device's carry name (FEAT-09 pairing) where one exists; else "Mac", "iPhone", "iPad".
    **assumed:** since iOS 16, `UIDevice.current.name` gives only the model without an entitlement.
  - The Mac host re-reads `draftpad.matter.json` (and a media note's `note.matter.json`) when it changes on disk while
    open, and merges it (`mergeMatter`, `matter.js:675`), as iOS does on its poll.
  - Files: `strip/editorhost.swift`, `mobile/HostApp/iOS/Draftpad.swift`. `editor/src/` only if the setter needs a guard.
    `shared/notesync.swift` unchanged.
  - Check (test, editor): after `setMatterDevice('Mac mini')` a crossing logs `device: 'Mac mini'`; a later
    user-agent guess never replaces it.
  - Check (device, Mac): a crossing made on the iPhone shows in the Mac's open page after the next poll, no reopen;
    the Mac's undo refuses it (decision 3).
  - Embodiments: Mac, iPhone, iPad. Web: n/a until the web writes notes (FEAT-23 A3 rule 5).
- **P6 · The note time in the seed** (FEAT-23 A1 rule 6; medium; batch 1).
  - Change: a seed gains an optional `media: { key, t }`, `t` in seconds rounded down to 0.1 s.
    Set when a passage is born in a media note (`keep/<key>/note.md`) while that item has a playhead.
    Not set on `draftpad.md` in this phase (Q-B1).
  - `checkMatter`'s five conditions are unchanged. `mergeMatter` keeps `media` from either side.
    A seed without `media` (every one written before) loads and saves byte-identical.
  - The Matter menu gains **"Play from mm:ss"** on a passage whose seed has `media` (FEAT-23 A1 rule 7).
  - Files: `editor/src/matter.js`, `editor/src/mattermenu.js`, `editor/src/audio.js` (the playhead;
    `updateAudioTime` already reaches the page, **proven** `strip/editorhost.swift:221`).
    Hosts: nothing beyond FEAT-23 P0c's note loading.
  - Check (test, editor): at `updateAudioTime(724.36)` a new passage's seed has `media.t = 724.3`; save → reload keeps it;
    two devices' sidecars merge with both `media` fields kept; new transcript lines (`setAudioTranscript`) leave the
    sidecar byte-identical; a sidecar from before this phase round-trips byte-identical.
  - Embodiments: Mac, iPhone, iPad. Web: with FEAT-23 A3 rule 5.
- **P7 · Marks drawn** (crossings 3, 4, 5; medium; batch 2).
  - Change: highlights, regions and margin notes in `forms.mark` are painted on the page (a CodeMirror decoration).
    Today they live in the sidecar and nothing draws them (Handoff, "Marks are not drawn").
  - Files: `editor/src/matter.js` (ranges from `forms.mark`), new `editor/src/marks.js` (the decoration),
    `editor/src/index.js` (wiring), `editor/src/styles.css`. Hosts: none.
  - Check (test, editor): a fixture with one highlight, one region and one note gives exactly three decorations at
    their ranges; after crossing 4 (mark → type) the decoration is gone and the quote is in the body;
    the 12-move test stays green.
  - Check (device): Mac and iPad: a highlight shows and survives a reload. Screenshot audit: one Matter pill.
  - Embodiments: Mac, iPhone, iPad.
- **P8 · Strokes follow their word** (crossings 2, 6; high; batch 3, alone).
  - Change: a stroke attached to a word (`word: {pid, i, w}`, `attachStrokeToWord`, `matter.js:770`) moves with that
    word when the line reflows, instead of by line (`resolveStrokeAnchor`, `ink.js:282`).
    Crossing 6 (a comment set down as a stroke) uses the same anchor.
  - Files: `editor/src/ink.js`, `editor/src/matter.js`. Hosts: none.
  - Check (test, editor): the BUG-07 anchor test passes; a stroke on word 7 of a passage stays on word 7, within 2 pt,
    when the column goes from 700 pt to 320 pt and back.
  - Check (device): iPad with Pencil, rotate portrait ⇄ landscape; Mac, resize the window.
  - Embodiments: Mac, iPhone, iPad (Pencil on iPad only).
- **P9 · Read-aloud on the real voice** (crossings 7, 9, 11; medium; with narration).
  - Change: read-aloud plans use the voice's own word times from the host (`speak`, `willSpeakRange`), not estimates.
    The voice is narration's `bestVoice` (`shared/voice/`, FEAT-01 / FEAT-35), never another copy.
  - Files: `editor/src/matter.js`; hosts `strip/editorhost.swift`, `mobile/HostApp/iOS/Draftpad.swift`
    (forward `willSpeakRange` to the page); `shared/voice/` belongs to the narration lane.
  - Check (test, editor): with a fake host reporting word ranges, the lit word follows the reports, not the estimate.
  - Check (device): iPhone via iPhone Mirroring: read a vi, an en and a fr passage aloud; the light follows.
    The sound is checked on the phone in hand.
  - Embodiments: Mac, iPhone, iPad.
- **P10 · Spoken input wired** (crossings 8, 10 on the Mac, 12; medium; with VoiceEntry).
  - Change: the Mac's VoiceEntry calls `appendVoice` (#10). A spoken aside lands as a timestamped margin note (#8;
    its time from P6 in a media note). A spoken phrase can be pinned at the caret's place (#12).
  - Files: `editor/src/matter.js`; `strip/app.swift` VoiceEntry, `strip/editorhost.swift`. iOS already has #10 (P2).
  - Check (test, editor): `feat08-voice` plus #8 and #12 fixtures.
  - Check (device): Mac, internet off, speak into VoiceEntry → the words land on the open page as their own passage,
    seed input "voice".
  - Embodiments: Mac (new); iPhone and iPad (#8, #12).
- **P11 · The Notability bar** (T-0050; high; batch 2).
  - Change: the gap list in the T-0050 bar is worked slice by slice with `gauntlet-loop`: a builder, agy as the harsh
    critic, a blind compare against the bar. Each slice that passes ships alone.
  - The bar: `.claude/worktrees/agy/.handoff/agy/T-0050-notability-bar.md` (agy; not yet written; referenced, not read).
    PLAN-1118 §11c names `docs/specs/T-0050-notability-bar.md`: the coordinator settles which (Q-B3).
  - Starts only after batch 1 merges (the same `editor/` files).
  - Files: set per slice by the bar; `editor/src/` first, the hosts as needed.
  - Check: per slice, its bar line measured on the device before and after.
  - Embodiments: Mac, iPhone, iPad.
- **P3 · The other formats as live states** (export, then import back). After P0.1 passes.
- **P4 · Searchable audio and ink inside the page** (T-0046). One matcher with FEAT-21; FEAT-21 P1 first.
  - T-0046's "talk to annotate and listen back" is served by P2, P6 and P10; its "searchable audio + text" by P4.

## Notes on media (added 2026-11-16)
- A media item's note (`keep/<key>/note.md`, FEAT-23) is a Draftpad page like any other: same ink, same Matter menu.
- It is its own file. No crossing moves text between a media note and `draftpad.md` unless the owner pastes it.
- P4 here (searchable audio and ink inside the page) and FEAT-21 (one search) share one matcher; build FEAT-21 P1 first.
- Added 2026-11-18: a media note's passages carry the item's second in their seed (P6), and its strokes carry it in
  `note.ink.json` (FEAT-23 A1 rule 6). The time never enters the text.

## Feasibility (labelled)
- Proven: Markdown core, ink anchoring, timed words, on-device speech.
- Assumed: lossless md ⇄ docx / odt round trip (formatting can drift; P0.1 decides).
- Untested: Vietnamese handwriting recognition; a Lock Screen control that writes into Draftpad.

## Offline-first gate (rewritten 2026-11-18)
Every outside service this spec touches, and when:
- **At the moment of use: none.** Seeds, crossings, undo, merge, marks, ink, read-aloud and voice input run on the device.
  Speech is Apple's on-device engine or the open ears (`shared/speechcore.swift`, `strip/openears.swift`), never Groq.
- **Setup only, stored on the device:**
  - pandoc (P0.1): one-time install, its source, size and checksum recorded; the owner approves the download;
  - Vision handwriting and speech language assets (Apple's, once per language);
  - the narration voices P9 uses (Kokoro en/fr, VieNeu vi), installed once by `shared/voice/` with source, size and
    checksum (PLAN-1118 §11c).
- **Reaching another device:** the sidecar rides with its page through FEAT-22's ladder (paired device, then the hub,
  then Cloudflare R2, optional, with FEAT-22's exit). Catch-up never blocks writing.
- **The web:** the editor PWA works offline only from its cache (`library/src/client/editorpwa/sw.js`) or the hub;
  served by the Gallery Worker it would need the network at the moment of use. Untested for this spec.
- No CDN, SDK or third-party library is added.

## Debug channel: `~/Recense/logs/matter.jsonl`
- Writer: ShowsKit `DebugChannel` and its JS twin `library/src/client/debuglog.js` (PLAN-1118 §11b).
  **Proven** only on Stream B's `skills` worktree; not on `main` (2026-11-18). These events wait for it.
- The editor posts each event to its host; the host writes the line. iOS: `Documents/Recense/logs/`.
- Fields: ids, counts, states, times, error text. Never what the person wrote or said.
- Events (name · fields):
  - `matter.seed` · `pid`, `input` (pencil / keys / touch / voice), `device`, `page` (draftpad / note), `hasMedia` (0/1)
  - `matter.cross` · `n` (1–12), `pid`, `device`, `ms`
  - `matter.undo` · `n`, `pid`, `device`
  - `matter.refuse` · `n`, `pid`, `reason` (changed / compacted / other-device)
  - `matter.merge` · `when` (open / poll / write), `passages`, `crossings`, `added`, `ms`
  - `matter.check` · `pass` (0/1), `failed` (names of the failed conditions, comma-separated)
  - `matter.voice` · `chars` (a count), `landed` (page / unsaved), `device`
  - `matter.error` · `where`, `error`

## Device checks (per embodiment; the simulator is not evidence)
- **Mac:** `zsh strip/build.sh`; select words → Matter → Highlight → it is drawn (P7) and survives a reload;
  a crossing made on the iPhone appears without reopening (P5); VoiceEntry lands a passage with the internet off (P10).
- **iPhone 12 Pro Max, through iPhone Mirroring**
  (`zsh mobile/ios/mirror-shot.zsh "$TMPDIR/shots/<screen>.png" --launch`, outside the sandbox):
  the pill appears on a selection; Read aloud lights the words (P9); after a Mac edit the merge shows; the Mac's crossing
  cannot be undone from the phone. Voice and sound: the phone in hand (iPhone Mirroring cannot use its microphone).
- **iPad Air M2 13-inch** (on the device; the owner confirms, or a recording from Control Center › Screen Recording):
  Pencil → Make text lands under the ink; a stroke on a word keeps to it through a rotation (P8); Circle as note.
- **Web:** untested; no check until the web writes notes (FEAT-23 A3 rule 5).
- Screenshot audit on every touched screen: one Matter pill, one menu, nothing carried over from another platform.

## Open questions (2026-11-18)
- **Q-B1** P6 stamps media time only in media notes. Should a passage typed in `draftpad.md` while something plays
  also keep that item's second? Not asked by the owner; left out.
- **Q-B2** Voice append exists twice (`shared/voiceappend.swift`, `matter.js:255`) because the App Intent runs with no
  web view. Keep both, held to one shared fixture, or route the intent through the editor? The parity law calls a
  second copy a bug.
- **Q-B3** The T-0050 bar's path: the agy worktree handoff, or `docs/specs/T-0050-notability-bar.md` (PLAN §11c)?
- **Q-B4** P5's device name: the carry name (FEAT-09) where one exists. Confirm that the pairing exposes it on both hosts.
- **Q-B5** Batch 1 per PLAN §12c says "A2 underlay + FEAT-08 (Opus high)". This spec holds FEAT-08's share to P5 + P6
  so the batch never carries two high-effort features. The coordinator confirms.

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
(Superseded 2026-11-18 for the new phases: see "Open questions (2026-11-18)", Q-B1 to Q-B5.)

## Registry block (for PARITY.md)
Proposal only: Stream B owns `docs/specs/PARITY.md`. Same keys as B's draft registry
(`.claude/worktrees/skills/docs/specs/PARITY.md`, not on `main` 2026-11-18). B's draft `draftpad` block covers
the page file and sync rules; this `matter` block covers the sidecar and the crossings.
```
<!-- parity:begin matter -->
feature: matter
home: editor/src/
note: matter.js + mattermenu.js: seeds, the 12 crossings, per-device undo, mergeMatter, the Matter menu (FEAT-08); file rules stay in `draftpad` (shared/notesync.swift, shared/draftpadfile.swift)
symbols: checkMatter mergeMatter matterActions reverseLast attachStrokeToWord appendVoicePassage
embodiments: mac=[ ] iphone=[ ] ipad=[ ] web=[ ]
events: matter.seed matter.cross matter.undo matter.refuse matter.merge matter.check matter.voice matter.error
spec: FEAT-08 FEAT-23 T-0046 T-0050
check: editor :: npm test
device: Mac, select words, Matter, Highlight: drawn, survives a reload; a crossing made on the iPhone shows without reopening
device: iPhone through iPhone Mirroring: the pill on a selection, Read aloud lights the words; the Mac's crossing cannot be undone from the phone
device: iPad, Pencil on a word, rotate: the stroke stays on its word
<!-- parity:end -->
```
- **Feature:** Draftpad as one matter (seeds, crossings, the Matter menu).
- **One home:** `editor/src/`.
- **Embodiments:** Mac `[ ]` · iPhone `[ ]` · iPad `[ ]` · web `[ ]` (P1 and P2 built in code; none device-checked).
- **Gaps:**
  - `appendVoicePassage` has a Swift twin, `shared/voiceappend.swift` (Q-B2); `sweep` will report it as a second copy;
  - web: the editor PWA loads `matter.js`, but no host saves the sidecar there (untested);
  - the hosts do not call `setMatterDevice` (P5);
  - marks are not drawn (P7); strokes move by line, not by word (P8).
