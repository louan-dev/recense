# FEAT-01 · Clean text → chaptered audiobook
From: owner 2026-11-12 ("make a universal rule format for all digital text to run through clean and with chapters").
Amended: owner 2026-11-18 (PLAN-1118 §5k, §5k-bis; §11c "Global M4B cleaning" and "Humanness of AI narration").
Study tool P2 (PLAYBOOK §3). Status `[~]`.
Rhythm, tempo and drums: FEAT-35 (built on this spec).

## Rule
Every digital text (PDF, TXT, later EPUB/DOCX/HTML) runs through one engine and one rule format.
Output: a reading copy (`clean.md`) and a voice copy (`speech.md`); headings become chapters.
- Amended 2026-11-18: every source (A2), on every device (A5). "Later" no longer applies to EPUB and DOCX.

## Format: TOML profiles in `text/rules/`
- `base.toml` applies to all text; a source profile `extends` it (e.g. `mpep.toml`).
- `[meta]`: `name`, `extends`, `lang`, `columns`, `top_band_pt`, `skip_leading_toc`.
- `[[rule]]`: `id`, `stage`, `match` (Python regex), `action`, `with`, `why`.
- Stages, in order:
  - `page`: one line at a time (headers, footers, folios).
  - `heading`: `#` chapter, `##` section; extras `until`, `join_next`.
  - `reflow`: engine step; joins hyphenated words and wrapped lines.
  - `text`: edits the reading copy; citations stay exact.
  - `speech`: edits the voice copy only.
- Actions: `drop`, `replace`, `heading`, `say` (`how` = `section` | `decimal`).
- Added 2026-11-18:
  - `[meta] no_break`: tokens after which a phrase never splits (FEAT-35).
  - `[meta] flags`: `i` and `m` only; never inline flags in `match`.
  - `[[texture]]` and the rule key `texture`: FEAT-35 owns them.
  - Stage `write` (dictation, spoken → formal): A8 below. Declared now so the format does not change later.

## Invariants (checks)
1. **No content loss:** word diff raw → `clean.md` drops only page furniture and the TOC; 0 words added.
2. Each numbered section in the source's TOC appears once as a heading, in order.
3. `test_rules.py`: pronunciation cases pass (e.g. `§ 1901.07(a)` → "section nineteen oh-one point oh seven a").
4. M4B chapter count = heading count (ffprobe).
- Added 2026-11-18:
5. **One table, three runtimes:** every row of `text/cases.tsv` passes in each runtime its `rt` column names.
6. **Every pair round-trips** (A8): written → spoken → written returns the same citation.
7. **The raw transcript is never rewritten.** The extractor opens `keep/<key>.v2.json` read-only.
   - Check: the file's sha256 before a render equals its sha256 after.
8. **No cap in narration:** no page limit on OCR and no character limit on text.
   - FEAT-26's `PasteText.pdfOCRPages = 20` and `textLimit = 50_000` stay FEAT-26's paste rules (proven, `shared/pastetext.swift:10-11`).
9. **The M4B says what it holds:** `ffprobe` shows the chapters, their titles and the audio stream's `language` tag.
10. **Two exports at once give two intact files** (BUG-33's test, kept).
11. **One `bestVoice`:** exactly one definition in the repo.
    - Check: `grep -rn "func bestVoice" --include='*.swift' shared strip mobile | wc -l` prints 1.

## Voice
Kokoro-82M ONNX (`af_heart`), fully offline. Setup-only download: GitHub release
`thewh1teagle/kokoro-onnx` model-files-v1.0:
- `kokoro-v1.0.onnx` sha256 `7d5df8ec…3636a6c5`;
- `voices-v1.0.bin` sha256 `bca610b8…1fbf7d`.
- Amended 2026-11-18: only these prefixes and suffixes are recorded. The full values: `TO FILL at install` (A4).

## Open
- Per-word timings: Kokoro-ONNX gives sentence-level timing only; P2 asks for timings from TTS.
  Option: forced alignment of TTS audio against `speech.md` (same engine as P1).
  - 2026-11-18: moved to FEAT-35 P0 (spike) and its word-time fallback.
- Vietnamese/French profiles and voices (PLAYBOOK §3 voice line).
  - 2026-11-18: voices answered by A4 and A6; the `vi` and `fr` profiles are A1 data.

---

# Amendment 2026-11-18 · Global M4B cleaning and humanness of the narration

## Verdict first
- **Rule:** any source, on any device, becomes a chaptered M4B audiobook, offline.
- **One rule table, three runtimes:** the TOML stays the source; Python, Swift and JS read the same compiled JSON.
- **One proof:** five source kinds in three languages, checked by `ffprobe`, played offline on the iPhone.

## Terms (defined once)
- **Extractor:** the step that turns a file into headings and paragraphs.
- **ChapterPlan:** the list of chapters (title, start) one narration will have.
- **M4BWriter:** the code that writes the M4B file: audio, chapters, cover, language.
- **Backend:** one text-to-speech engine behind one Swift protocol.
- **Carry:** Recense's own device-to-device file sync (FEAT-22).

## Premises checked against the code (main 87bd9f9, 2026-11-18)
- **proven** `text/` is back in git: `clean.py` (150 lines), `audiobook.py` (60), `test_rules.py` (16), `rules/base.toml` (74), `rules/mpep.toml` (112). Commit 80853e2.
- **proven** `clean.py` reads PDFs with Poppler's `pdftotext` and `pdfinfo` (`text/clean.py:58-64`).
- **proven** The `say` action is Python code (number words), not data (`text/clean.py:22-28`).
  - So "the same rules in three runtimes" needs a `say` verbalizer per runtime, pinned by `cases.tsv`.
- **proven** `test_rules.py` holds 5 English cases in a Python dict, not in a shared file.
- **proven** `ExportGate` already runs exports one at a time, with free names and honest errors (`shared/exportjobs.swift`, BUG-33).
  - So the "one serial export queue" is `ExportGate`. No second queue is written.
- **proven** FEAT-26's `PasteText` extracts PDF text with PDFKit and images with Vision OCR, in `shared/` (`shared/pastetext.swift:43-60`).
- **proven** Vision OCR lists `vi-VT` for Vietnamese, the code `InkOCR` asks for (`shared/inkocr.swift:12`; Vision's list printed on this Mac, 2026-11-18).
- **proven** The Audiobooks home is `library/Audiobooks` (`shared/homes.swift:25`).
- **proven** Three `bestVoice` copies and one more speech site (the dedupe target):
  - `strip/editorhost.swift:499` (`EditorHost.bestVoice`, called at `:495`);
  - `shared/draftpadlibrary.swift:126` (`ReadAloud.bestVoice`, called at `:93`);
  - `mobile/HostApp/iOS/Draftpad.swift:366` (`DraftpadWeb.bestVoice`, called at `:362`);
  - `strip/app.swift:6150` (`NotebookPanel`'s own `AVSpeechSynthesizer`, no voice choice).
  - PLAN-1118 §5k counts "4 copies, 3 near-duplicate bestVoice"; its line numbers are stale.
- **proven** The ears env: `~/.local/share/recense/omni` (`strip/openears.swift:14`).
- **proven** `ffprobe` and `pdftotext` are installed on the Mac (`/opt/homebrew/bin`).
- **stated by PLAN-1118 §5k-bis, not re-checked** The M4B `ffprobe` check never ran.
- **assumed** `NSAttributedString` reads `.docx` on macOS only, so iPhone and iPad ask the Mac for docx.

## One home (three folders, one job each)
- **`text/`: the rules and the Mac's engine.**
  - Data: `rules/*.toml` (source), `rules.json` (compiled), `cases.tsv` (the shared test table).
  - Code: `clean.py`, `compile_rules.py` (new), the Python extractor, `test_rules.py`.
  - Why: the rules are data that every runtime reads. One folder owns that data.
- **`shared/m4b/`: chapters and the file.** `ChapterPlan.swift`, `M4BWriter.swift`.
  - Why: the same Swift writes the M4B on the Mac and on iOS, so ffmpeg is no longer needed to write one.
- **`shared/voice/`: the voices.** `VoiceBackend.swift` (the protocol), the backends, the one `bestVoice`.
  - Why: Swift both apps compile lives in `shared/` (`.claude/CLAUDE.md` § Parity).
- **Thin interpreters of `rules.json`, one per runtime, pinned by `cases.tsv`:**
  - Python: `text/clean.py`.
  - Swift: `shared/ShowsKit/Sources/ShowsKit/TextRules.swift` (tested by `swift test`, as PLAN-1118 §5k-bis says).
  - JS: `editor/src/textrules.js` (the editor runs in every host).
  - This is a sanctioned twin: the logic is the data; the loops cannot drift without a red row. Registered as a PARITY gap.
- **Not a second copy:** the export queue stays `ExportGate` in `shared/exportjobs.swift`.
  - It may move into `shared/m4b/` in A3, with every build reference updated in the same commit.

## Embodiments
- **Mac:** every source; Kokoro and VieNeu; the heavy PDF clean; writes the M4B.
- **iPhone and iPad:**
  - "Make audiobook…" sends a request to the Mac (catch-up through carry) and plays the result offline.
  - "Quick voice now" (labelled as such): Apple's voice, offline, for md, txt, notes, OCR and transcripts.
  - PDF, docx and epub: through the Mac (gap).
- **Web:** "Make audiobook…" asks the Mac. Never a Worker render.

## A1 · One rule table: `text/rules.json` + `text/cases.tsv`
- **Compile:** `python3 -I text/compile_rules.py` reads `rules/*.toml` and writes `rules.json`.
  - It resolves `extends`, so each profile is one flat list.
  - It rejects any regex outside the portable subset, naming the rule's `id`.
- **The portable subset** (Python `re`, Apple `NSRegularExpression`, JS `RegExp`):
  - Allowed: literals; classes `[...]`; `\d`, `\s`, `\w`; `* + ? {m,n}` and their lazy forms; `( )`, `(?: )`; `|`; `^ $`; `(?= )`, `(?! )`.
  - Rejected: named groups (`(?P<…>)` and `(?<…>)` differ); lookbehind; atomic groups; possessive quantifiers; inline flags.
  - `\b` and `\w` beside non-ASCII letters differ in JS. The compiler writes a `match_js` with a Unicode-aware form where needed.
- **`rules.json` shape:** `{ "v": 1, "profiles": { "<name>": { "meta": {…}, "rules": [ {…} ], "texture": [ {…} ] } } }`.
- **Where each runtime reads it:**
  - The Mac app and the iOS app bundle `text/rules.json` by reference (a build step or file reference). Never a committed copy.
  - The editor imports it at build time into `editor/dist/editor.html`.
- **`text/cases.tsv`:** UTF-8, tab-separated, one header row:
  - `profile	lang	direction	rt	input	expected	why`
  - `direction`: `clean` (text stage), `speak` (speech stage), `write` (A8), `phrases` (FEAT-35).
  - `rt`: the runtimes that must pass the row: `py,swift,js` (default), or fewer.
    - `say` rows are `py,swift`: no JS caller speaks text (the web asks the Mac).
  - A tab or newline inside a field is written `\t` or `\n`.
  - Lines that start with `#` are comments.
- **Runners:** `test_rules.py`, a ShowsKit test and an editor test each read the same file.
- **Languages:**
  - The 5 English cases move from `test_rules.py` into `cases.tsv`.
  - French and Vietnamese rows are data written by agy, reviewed by Claude before they enter the file.
  - Profile layers `vi` and `fr` (e.g. "Điều 5 khoản 2"; "article L. 123-4") per PLAN-1118 §5k-bis.
- **Checks:**
  - All three runners pass every row their `rt` names.
  - MPEP 1900 rerun: still 13 chapters, 0 words lost, 0 added.

## A2 · Extractors: every source becomes headings + paragraphs
- **Output, for every input:** markdown with `#` and `##` headings and blank-line paragraphs.
- **Language per paragraph:** tagged in Swift by Apple's `NLLanguageRecognizer`, on the device. One copy.
  - The profile's `[meta] lang` is the hint when a paragraph is too short to tell.
- **Inputs:**
  - **PDF (Mac):** `clean.py` with `pdftotext` and the profile's column crop (proven today).
  - **PDF, scanned:** `PasteText`'s OCR path, every page (invariant 8).
  - **docx (Mac):** Python standard library (`zipfile`, `xml.etree`) reads `word/document.xml`.
    - Paragraph styles `Title` and `Heading1` → `#`; `Heading2` → `##`.
  - **epub (Mac):** Python standard library. The OPF spine gives the order; XHTML `h1` → `#`, `h2` → `##`, `p` → paragraphs.
    - The epub's own table of contents (nav) is skipped.
  - **md, txt (every device):** read as they are. Text with no headings is chaptered by length (A3).
  - **Image or screenshot (every device):** `InkOCR` through `PasteText.imageText`, with reading order fixed:
    - Vision's boxes sorted by column, then top to bottom.
  - **Draftpad pages and FEAT-23 notes (every device):** through `notesync`; ink becomes OCR text.
  - **Transcripts of audio and video (every device):** the Lines of `keep/<key>.v2.json`, read-only (invariant 7).
    - Chapters from the recording's existing `chapterStarts`.
- **Checks:**
  - Per input kind, a fixture: words out = words in the source's text nodes, minus furniture.
  - The transcript's sha256 is unchanged after a render.

## A3 · `shared/m4b/`: ChapterPlan, M4BWriter, on `ExportGate`
- **ChapterPlan:**
  - Text with headings: one chapter per heading, titled by it (invariant 4).
  - Text without headings: a chapter about every 10 minutes, cut at a paragraph end.
  - Recordings: today's `chapterStarts`, named by headings when they exist, else by the first 6 words.
- **M4BWriter:** `AVAssetWriter` with an AAC track, a chapter track, a cover and metadata.
  - **untested** that a chapter track written this way plays with chapters on iOS. A3's first check.
  - Audio stream `language`: ISO 639-2 (`eng`, `fra`, `vie`) of the language with the most words.
  - A mixed document also lists every language in the comment tag: "Languages: en, vi".
  - Title, artist ("Recense"), genre ("Audiobook") and the cover are always written (fixes M-B6).
  - The encoder delay is recorded so players trim it.
- **Queue:** every export runs through `ExportGate`. Names from `ExportJobs.stamp` and `freeURL`. Never an overwrite.
- **Where it goes:** `Homes.url(.audiobooks)` = `library/Audiobooks`, with its lifecycle (FEAT-29). Never the vault, never tmp.
- **The Mac keeps ffmpeg** only to transcode inputs.
- **Checks:**
  - `ffprobe -v error -show_chapters -show_entries stream_tags=language -of json <file.m4b>`:
    - chapter count = ChapterPlan count; titles equal; `language` as above.
  - Duration within 1 s of the sum of the rendered audio.
  - Two exports at once → two intact files.

## A4 · `shared/voice/`: one protocol, one `bestVoice`, neural voices
- **The protocol** (Swift; names proposed):
  - `VoiceBackend`: `id`, `languages` (ISO 639-1), `supportsSpeed`, `givesWordTimes`.
  - `voices(for lang) -> [VoiceInfo]`.
  - `render(text, lang, voice, speed) async throws -> Rendered` (samples, sample rate, optional words).
- **Backends:**
  - `KokoroBackend` (Mac): English and French. A long-lived Python process, so the model loads once.
  - `VieNeuBackend` (Mac): Vietnamese, the Southern presets.
  - `SystemBackend` (every device): `AVSpeechSynthesizer.write`. Shown as "Quick voice".
  - One model in memory at a time on the 8 GB Mac (research note, 2026-11-08).
- **One `bestVoice(lang:text:)`** in `shared/voice/` replaces the three copies and serves the fourth site (Premises).
  - Order: the voice the owner picked at the gate (A6), then Premium, then Enhanced, then the default.
- **Setup-only installs** (once, then offline forever), into a venv beside the ears env: `~/.local/share/recense/voice`.
  - Manifest `~/.local/share/recense/voice/manifest.json`, one entry per file: `name`, `source`, `version`, `bytes`, `sha256`, `installed`.
  - **Kokoro:** GitHub release `thewh1teagle/kokoro-onnx` model-files-v1.0, and PyPI `kokoro-onnx`.
    - Sizes: `TO FILL at install`. Checksums: full values `TO FILL at install` (only prefixes are known, Voice above).
  - **VieNeu v3 Turbo 3.8.3** (Apache-2.0): Hugging Face `pnnbao-ump/VieNeu-TTS-v3-Turbo`, PyPI `vieneu`.
    - Size: model cache 608 MB (measured 2026-11-08, research note). Checksum: `TO FILL at install`.
  - The install script verifies each sha256 and refuses a mismatch.
- **Checks:**
  - Invariant 11 (one `bestVoice`).
  - With the network blocked, each backend renders one sentence per language.

## A5 · "Make audiobook…" on every surface (W2)
- **Where:** the ··· menu of any file, note, Draftpad page, Library row and woven Home page; the Mac panel; the web player.
  - Voice: "make audiobook". French and Vietnamese phrases are reviewed data.
- **Choices** (one sheet):
  - Language: one, or alternating original and translation per paragraph (translation by FEAT-10, on the device).
  - Voice. Chapters: by heading or by length. Drums: FEAT-35.
- **iPhone and iPad:**
  - A request file `library/Audiobooks/.queue/<stamp>.json` reaches the Mac by carry.
    - Fields: `v`, `source` (`home`, `path`, `sha256`), `langs`, `voice`, `chapters`, `requestedBy`, `t`.
  - The Mac drains it like the download queue (every 60 s and on folder change; BUG-33 D1).
  - The M4B comes back by carry and plays offline.
  - The row says "Waiting for the Mac" until then. "Quick voice now" is the offline choice.
- **Web:** posts the same request to the Mac's `POST /export` (the existing endpoint).
  - Away from the Mac: assumed through the hub (FEAT-18); never a Worker render.

## A6 · The voice gate (W2; the owner decides, by taste)
- **Clips:** 10 per language per candidate, 15–30 s each, from the proof's sources: a heading, a list, a citation, a quote.
- **Candidates:**
  - en: Kokoro `af_heart` and up to 3 more, one of them low.
  - fr: Kokoro's French voice (assumed `ff_siwis`; not checked here).
  - vi: VieNeu Southern presets, with the ~15 untested presets tried for the low voice (PLAYBOOK §3 Voices).
  - **Always one low, soothing voice per language.**
- **Steps:**
  1. agy's blind panel shortlists at most 3 per language.
  2. The owner hears each shortlisted voice against the best macOS voice: same text, order random, names hidden.
- **Bar, per voice:** the owner's mean rating ≥ 4 of 5, and preferred to the macOS voice on ≥ 8 of 10 clips.
- **Record:** `~/.claude/context/recense/research/voice-gate-<date>.md` (ratings, picks, clip list).

## A7 · The proof
- **Five sources:** the MPEP 1900 PDF, a docx, an epub, a Draftpad page, a screenshot through OCR.
- **Three languages:** each source once; each of en, fr, vi at least once.
  - Reading (open Q2): MPEP is English only, so the minimum set is MPEP (en), docx (fr), epub (vi), Draftpad page (en + vi), screenshot (fr).
- **Each output:** a chaptered M4B, passing A3's `ffprobe` check.
- **On the iPhone:** Airplane Mode on (Settings ▸ Airplane Mode); Recense ▸ Library ▸ Audiobooks; each plays; chapters skip.
  - Seen through iPhone Mirroring, never the simulator; screen-recorded; agy judges.

## A8 · The `write` stage (dictation; chunk 3, after A1–A7)
- Pairs, not two lists: a citation rule states the written form and the spoken form once; the engine derives both directions.
- Context rules: "section" becomes `§` only inside a citation; numbers keep their exact form.
- Applies to what the owner writes (voice append, Draftpad dictation, FEAT-23 notes), never to a recording's transcript.
- Check: "35 USC section 103 and 37 CFR 1.56" → `35 U.S.C. § 103 and 37 C.F.R. § 1.56`.

## Phases, in order (W1 → W2, PLAN-1118 §11c)
- **A0** recovered `text/` (done, 80853e2).
- **W1:** A1 rules + cases · A2 extractors · A3 `shared/m4b/` (worker) · A4 `shared/voice/` + installs.
- **W2:** A5 "Make audiobook…" everywhere · A6 the voice gate · A7 the proof · BUG-33 device check.
- **Chunk 3:** A8.
- Each phase ships alone: A1 to the Mac first, A5 to the devices as soon as one source works.

## Debug channel: `~/Recense/logs/narration.jsonl` and `~/Recense/logs/m4b.jsonl`
- iPhone and iPad: `Recense/logs/` inside the app's container (assumed path).
- Writer: PLAN-1118 §11b's shared JSONL writer (Stream B). Not built yet.
- Every event: `ts` (ISO 8601 UTC, ms), `dev`, `ev`. No event carries the document's words.
- `narration.jsonl`:
  - `narration.extract` — `source`, `kind` (`pdf` | `docx` | `epub` | `md` | `txt` | `ocr` | `note` | `transcript`), `bytes`, `headings`, `paragraphs`, `langs`, `ms`.
  - `narration.rules` — `profile`, `per_stage` (count of rules fired), `words_in`, `words_lost`, `words_added`, `ms`.
  - `narration.render` — `backend`, `voice`, `lang`, `phrases`, `audio_s`, `rtf` (render time ÷ audio time), `ms`.
  - `narration.voice_missing` — `lang`, `wanted`, `fallback`.
  - `narration.request` — `source`, `via` (`carry` | `post`), `from`.
  - `narration.voice_pick` — `lang`, `chosen`, `quality`, `backend` (from the one `bestVoice`).
- `m4b.jsonl`:
  - `m4b.queued` — `job`, `source`, `position`.
  - `m4b.written` — `job`, `path`, `bytes`, `chapters`, `langs`, `duration_s`, `ms`.
  - `m4b.failed` — `job`, `stage`, `status`, `stderr_tail` (≤ 400 characters), `timed_out`.

## Device checks
- **Mac:** "Make audiobook…" on each of the five sources; `ffprobe` each; play one in Recense.
- **iPhone, through iPhone Mirroring, never the simulator:**
  - "Make audiobook…" on a note → "Waiting for the Mac" → the M4B arrives.
  - Airplane Mode on: it plays, chapters skip, the light runs.
  - "Quick voice now" on a note, offline.
- **iPad:** iPhone Mirroring cannot reach it. The owner repeats the iPhone steps and records with Control Center ▸ Screen Recording.
- **Web:** "Make audiobook…" from the web player on the Mac's network → the M4B appears in Audiobooks.

## Offline-first gate
- **At the moment of use: no outside service.**
  - Extraction, rules, OCR (Vision), language tags (NaturalLanguage), voices and the M4B writer all run on the device.
- **Setup only** (once; stored with source, size and sha256 in the voice manifest):
  - GitHub (Kokoro model files), PyPI (`kokoro-onnx`, `vieneu`, `numpy`, `soundfile`), Hugging Face (VieNeu).
  - Homebrew: `ffmpeg`, `ffprobe`, Poppler (`pdftotext`). Open source, replaceable.
  - Apple's system voices: Settings ▸ Accessibility ▸ Spoken Content ▸ Voices.
- **Reaching another device:**
  - Requests and M4Bs travel by carry (self-hosted, catch-up, never blocks).
  - The web reaches the Mac directly or through the hub. Never a Worker render.
- **Cloudflare, the Worker, R2, Groq:** none.

## Open questions (amendment)
- Q1 (coordinator): iOS "Quick voice" for PDFs through `PasteText` (no column crop), or PDFs only through the Mac?
- Q2 (owner): the proof is five sources covering three languages (A7's reading), or every source in all three?
- Q3 (coordinator): the web's route to the Mac when not on its network (FEAT-18 hub) is assumed.
- Q4 (A1): the full Kokoro checksums; the spec holds only their prefixes and suffixes.

## Registry blocks (for PARITY.md)
```
<!-- parity:begin narration -->
feature: narration · any source → clean text → voice (FEAT-01)
home: text/ (rules/*.toml, rules.json, cases.tsv, clean.py, compile_rules.py); shared/voice/ (VoiceBackend, backends, bestVoice)
symbols: VoiceBackend, KokoroBackend, VieNeuBackend, SystemBackend, bestVoice, TextRules
embodiments: [ ] mac · [ ] iphone · [ ] ipad · [ ] web (asks the Mac)
events: narration.extract, narration.rules, narration.render, narration.voice_missing, narration.request, narration.voice_pick
spec: docs/specs/features/FEAT-01-clean-text-audiobook.md
check (proposed, not yet run): python3 -I text/test_rules.py
check (proposed, not yet run): swift test in shared/ShowsKit (TextRules over text/cases.tsv)
check (proposed, not yet run): npm test in editor/ (textrules over text/cases.tsv)
device: iPhone (iPhone Mirroring, Airplane Mode): a carried narration plays; "Quick voice now" works offline
device: iPad (owner's screen recording): the iPhone steps
gaps: rules interpreted three times (py, swift, js), pinned by cases.tsv; say rows py+swift only; PDF/docx/epub on iPhone and iPad go through the Mac
<!-- parity:end -->

<!-- parity:begin m4b -->
feature: m4b · ChapterPlan + M4BWriter on ExportGate (FEAT-01 A3)
home: shared/m4b/ (ChapterPlan.swift, M4BWriter.swift); queue ExportGate in shared/exportjobs.swift
symbols: ChapterPlan, M4BWriter, ExportGate, ExportJobs
embodiments: [ ] mac · [ ] iphone · [ ] ipad · [ ] web (asks the Mac)
events: m4b.queued, m4b.written, m4b.failed
spec: docs/specs/features/FEAT-01-clean-text-audiobook.md
check (BUG-33's, not run this session): strip/recense selftest exportjobs
check (proposed, not yet run): ffprobe -v error -show_chapters -show_entries stream_tags=language -of json <file.m4b>
device: iPhone (iPhone Mirroring, Airplane Mode): chapters skip; language shown
device: iPad (owner's screen recording): the same
gaps: the web writes no M4B (asks the Mac); the iOS chapter track is untested
<!-- parity:end -->
```
