# FEAT-32 · Recense a source: a page, a song or a video becomes one item you can read, hear and translate, offline

From: owner 2026-11-18 (review: "should be like a Safari LLM finder on a NotebookLM/Ask engine"); owner 2026-11-18 ("Recense equivalent of reader mode: find text or audio or video with audio, download offline in the appless hub and the app; AI narration; translation in Vietnamese, French, English, switch between all via the original source; recense in a different language, or learn side by side with the original") · Status: `[ ]` spec only · Effort: high, in slices

## Review 2026-11-18 · owner direction: "a Safari LLM finder on a NotebookLM / Ask engine"
**Verdict: object to the scope below.** It builds the ingest half and files the engine the owner asked for as a separate wish.
- **Rule (owner):** FEAT-32 is the finder in Safari plus the notebook engine under it. S1–S5 stay, as the way sources get in.
- **Finding 1 · scope, proven by the text:** "Not adopting" rejects the Safari layer, and the Owed list defers offline Ask. Both are the owner's core.
- **Finding 2 · premises, re-checked on main 2d6d398 (all hold):**
  - `claude -p` is at `strip/app.swift:6685`.
  - Ask is a web place (`Places.swift:16-17`).
  - No `askcore` exists.
  - The SDK header gives `write(_:toBufferCallback:toMarkerCallback:)` as iOS 16 / macOS 13.
  - `recensetext.swift` lenses run on FoundationModels with a **4,096-token context**.
- **Finding 3 · the 4,096-token context is the design centre.** NotebookLM reads whole sources at once; we can't.
  - The engine must retrieve 6–10 passages and give each answer line its passage ids. `recensetext` already checks citations.
- **Finding 4 · search across languages, proven on this Mac:**
  - SQLite FTS5 (`unicode61 remove_diacritics 2`) finds "nguoi" → "Người" and "fete" → "fête" (sqlite3 3.54).
  - iOS's system SQLite having FTS5: **assumed**, so the first check is on the iPhone.
  - Apple sentence embeddings (`NLEmbedding`): en yes, fr yes, **vi none**. So meaning-search cannot rest on Apple embeddings.
  - The way round: keyword search (FTS5) in every language, plus a search of each item's existing `tr/en.json` layer, so a Vietnamese question finds French sources.
  - A bundled multilingual model (bge-m3 is already what the Worker uses) would be a one-time download. It is a later step, not S6.
- **Finding 5 · "Safari" means real Safari, not a skin.** A Safari Web Extension on iPhone, iPad and Mac.
  - It uses the FEAT-30 S0 transport (native messaging) to send the question to the app. The engine runs in the app, not in the extension.
  - Extension memory limits on iOS are **untested**.
  - Answers light their source on the page through a text fragment (`#:~:text=`; Safari support **assumed**).
  - The same panel offers "Add to notebook" (= S1).
- **Finding 6 · S2/S3 narration is the Audio Overview equivalent.** Keep it: a source or an answer heard in en/vi/fr with word times.
- **Gate:** nothing calls out at the moment of use. The Gallery Ask (Workers AI + Vectorize) stays as an optional fallback; it reads every file (owner 2026-11-18).

### New slice order (replaces the S-order below; S1–S5 keep their text)
1. **S1** capture (unchanged).
2. **S6 · Notebook index = FEAT-21's index, not a second one** (correction 2026-11-18, review 3).
   - The source is `keep/<key>/find.tsv` + our fold, with FTS5 only as step 2 (FEAT-21 P1, wishes T-0046 ★★★★★★, T-0051 ★★★★★).
   - Passage ids = `key#segId`. Pages from S1 write their own `find.tsv`.
   - **Correction to Finding 4:** FTS5 does **not** fold "đ" ("duong" misses "đường", re-run 2026-11-18, as FEAT-21 found 11-16). Our fold runs first.
   - Done when: an en/fr/vi query on the iPhone in airplane mode returns ranked passages.
3. **S7 · Ask with citations:** Apple model, 4k budget, answer schema in `recensetext`, each line cites ids; one UI in `editor/`.
   - Done when: every answer line opens its source at the cited second or sentence.
4. **S8 · Safari finder:** the extension panel ("Ask this page" / "Ask my notebook" / "Add to notebook"); answers light on the page.
   - Waits on the FEAT-30 S0 spike.
5. **S2/S3** narration (Audio Overview), **S4** extractor, **S5** links, as written.
6. **Hub:** the same index built with node + SQLite, so the appless hub can search. It has no Apple model, so hub answers use the fallback.

## Review 2 · the browser-skin pastes (Safari capsule, Arc Peek, Zen Compact / Glance / Split), checked 2026-11-18 on main 9742e52
**Verdict:** take five interaction ideas into S7/S8. Reject a second in-app browser, the hover-only and button-free controls, and WebLLM.

### Claims checked
- **True:**
  - `RecensePlaces` (`Places.swift:6`); `.glassCircle()` (`Places.swift:43`); `MoreMenu` (`:51`); `Theme` (ShowsKit).
  - The old `Browser.swift` root is "retired (B2 redo)" (`:74`) but still holds an Ask sheet and a `NavigationSplitView`.
  - Ask is a web place (`Places.swift:16-17`) that can't read local files offline.
  - Workers AI is capped at 10,000 neurons a day (`ai.js:348`). Study and Folio spaces exist (`Model.swift:224-225`).
  - Zen is desktop only (`zen-browser/desktop`).
- **Stale:**
  - "idle `b.steps++` drains the budget": fixed 2026-11-05 (G20). Steps count only when a step called AI (`ai.js:350,364`).
  - "Error 1027 breaks Ask": that outage was the docs-sync bisync, since fixed.
- **False:**
  - "Safari Reader is functionally identical to Readability": Safari Reader is Apple's own code. Readability is Firefox's.
  - "Readability.js is about 1,500 lines": it is 2,812 (Apache-2.0).
- **Not in the code:** `askcore.swift`, `draftpad.seed.jsonl`, `recense://`, `keep/<key>/note.md`, voice-activity detection, a Contacts reader. FEAT-23 owns the note-per-item file.
- **Partly there:** a local model on the Mac. `recense.swift:41` has an optional OpenAI-compatible server hook (LM Studio, Ollama, llama.cpp), used today for translation only.
- **Unverified:**
  - "Apple's model runs outside the app's memory" (assumed, Apple's architecture).
  - "Arc encourages ten live WebViews" (an opinion).
  - Reading the Contacts notes field needs an Apple-granted entitlement (assumed).
- **Cited repos (GitHub API):**
  - `lukoplt/AI-notebook`: 20 stars, MIT, macOS only, depends on GRDB, SwiftSoup and ZIPFoundation. Study only.
  - `mozilla/readability`: Apache-2.0.
  - `LocalMode-AI/LocalMode`: 71 stars, MIT.
  - `ihiteshsharma/offline-browser-rag`: 0 stars, no licence.
  - `mlc-ai/web-llm`: Apache-2.0.

### Adopted into S7 (Ask) and S8 (Safari)
1. **Source list always shown.** Under every answer, the retrieved passages are listed with their place (`mm:ss` or the paragraph), even when the model leaves out a bracket. The reader checks the source, not the model's word. (Principle from LocalMode.)
2. **Citation card (Arc Peek / Zen Glance).**
   - Tapping a citation opens one card over the page: the passage lit, or the audio looping its line at the current speed.
   - Three visible buttons: **Close** (back to the same scroll place) · **Open beside** (two panes, no more) · **Add to Draftpad**.
   - It reuses FEAT-23 moment links.
3. **Add to Draftpad with its source.** The answer and its citations are added through the existing FEAT-08 append path (the matter sidecar), not a new file.
4. **Reading column.** Captured pages and answers open in the existing transcript and editor views, not a new Reader.
   - Proposed numbers: at most 60 characters a line, line height 1.8. This is within WCAG 1.4.8 (≤ 80 characters, spacing ≥ 1.5).
   - The repo has no reading-width rule yet: the owner confirms the numbers, and they go into `docs/law/interaction.md`.
5. **Long answers within 4,096 tokens.** Map-reduce: each passage group is summarised with its ids, then the summaries are joined. On the Mac, the existing optional local-server hook may take the long synthesis. Off unless set; replaceable.

### Rejected (and why)
- **A Safari-skin browser inside the app** (WKWebView + capsule): a second copy of Safari. The finder lives in real Safari (S8). The app shows sources it already holds.
- **Zen Compact Mode (chrome only on edge hover):** hover-only breaks `interaction.md:31` (every action has a visible control). The resting stroke (`homebar.css:4-16`) is already the visible rest state.
- **A 4-way split grid:** clutter. Two panes at most (Open beside).
- **"Speak the next question, no mic button" and "0 visible buttons, two-finger arc":** each breaks `interaction.md:31`. Voice and gestures only speed up a visible control.
- **WebLLM for guests:** a multi-GB download into a guest's browser, and WebGPU support differs across browsers. Guests get hub or Worker answers.
- **Contacts notes as a source:** restricted entitlement, and outside this feature.

### Owner decision (answered 2026-11-18)
- **Raven, Matters and Sealed are indexed and answered from**, on the device and by the cloud fallback ("NO sealed, do not withhold the sealed data from cloud ai access"). No sealed rule anywhere in FEAT-32.

## Verdict first (original, 2026-11-18; scope superseded by the review above)
- **The owner's idea is mostly assembled already.** Four of its five parts exist as separate pieces. What is missing is the front door (a link or a page in) and one join (narration with word timings, so a page plays like any recording).
- **The pasted Safari/Zen/Arc skin advice is a UI skin, not this feature.** None of it is adopted here (see "Not adopting").
- **Several things the pastes name do not exist in the repo.** Checked 2026-11-18 on main 977765c; the table has them.

## Premises checked against the code
| Claim in the pastes | Verdict | Evidence |
|---|---|---|
| `shared/askcore.swift`, a local SQLite FTS5 index, on-device cited Ask | **Does not exist** | no `askcore` file; no FTS5 anywhere in Swift or JS. Ask is the Gallery web page (`mobile/HostApp/iOS/Places.swift:17`, `.webPlace("Ask")`) over Workers AI + Vectorize (`library/src/ai.js`: gpt-oss-120b, bge-m3). It does not work offline. **True gap, separate feature, filed as a wish, not built here** |
| `strip/app.swift` shells out to `claude -p` | **True** | `strip/app.swift:6685` |
| Readability.js is available to inject | **Not in the repo** | no copy; only build artefacts matched |
| `Browser.swift` had its sidebar retired for `RecensePlaces` | **Half true** | `Browser.swift` is still the Files-shaped archive browser (its header). `Places.swift` holds `RecensePlaces` (Draftpad, Listen, Ask, Data …) |
| Typed or pasted text cannot yet be recensed | **False, it exists** | `shared/recensetext.swift`: sentences → transcript `Line`s, per-phrase language, Apple Translation en/vi/fr, Apple on-device model lenses (Gist, IRAC) whose every line cites source sentences; no network |
| No AI narration yet | **Partly exists** | `shared/draftpadlibrary.swift` `ReadAloud` (AVSpeechSynthesizer, word ranges live); `library/chau/show.mjs` renders outlines to .m4a with macOS voices in en/vi/fr (Mac only, no word timings) |
| Translation switching on a transcript | **Built** | FEAT-10 (`shared/translateplan.swift`): en / vi / fr / auto / off, on the device; per-language `keep/<key>/tr/<lang>.json` |
| Saving audio and video for offline use | **Built or specced** | FEAT-12 (audio → Music, `[x]`), FEAT-11 (iOS download engine, spike passed), FEAT-30 (Safari bridge) |
| The appless hub plays an item without the app | **Built for transcripts** | `keep/<key>/asr.json` + `tr/<lang>.json` (`library/src/layout.js`), share links `/m/<token>` |
| Zen Browser is desktop-only | **Not checked**; irrelevant to the decision |

## What is missing (the real gap, proven by reading)
- **No way in for a web page.** Nothing turns a URL or an open page into text: no extractor, no snapshot. (`recensetext` takes text the page's editor already holds.)
- **Narration has no timings you can keep.** `ReadAloud` speaks live and `show.mjs` writes audio without word times. A page narrated today could not light words, loop a phrase or be shared as a recording.
- **No audio in the other language.** Translation is text; the player cannot say a French line in a Vietnamese voice and keep its place.

## The design: one item, whatever it came from
An item is a `keep/<key>/` folder (unchanged format). A page becomes one by getting an `asr.json` whose words carry times, exactly like a recording. Then Follow, loop, karaoke light, FEAT-10 translation, export and the hub work with no new player code.

### S1 · Recense the selection or the shared text (no extractor, no new dependency)
- Entry: select text in Safari → Share → Recense (FEAT-03's "Open with Recense"), or paste (FEAT-26).
- Saves `source.json` `{url, title, fetchedAt, sha256, lang}` and the text, then runs the existing `recensetext` path (sentences, languages, translation).
- Done when: a French and a Vietnamese paragraph from a real page arrive as items with Source lines and an en translation, in airplane mode after capture.
- **Why first:** the owner chooses what to keep, so a failed page extractor can never block the feature.

### S2 · Narration with timings (spike first)
- The SDK has the hook: `AVSpeechSynthesizer.write(_:toBufferCallback:toMarkerCallback:)` returns audio buffers plus word markers (AVFAudio header: iOS 16, macOS 13). **Verified to exist; word accuracy for vi and fr voices is untested.**
- Spike: render one 200-word paragraph per language to .m4a and map the markers to `Word.start/end`. Pass = every word has a time, drift under 80 ms against a hand-checked sample, on iPhone and Mac.
- Output: `keep/<key>/audio.<lang>.m4a` + the words' times in `asr.json`; rendered once per (voice, text), as `show.mjs` already caches.
- If the spike fails for a language: that language narrates live only (today's `ReadAloud`) and says so; nothing is faked.

### S3 · Hear it in another language
- A "Listen in" choice on the item: original, en, vi, fr. Choosing X narrates `tr/X.json`'s text (S2 on the translation), stored as `audio.X.m4a`, with its own times.
- The line is the unit: the original line and its translation share `segId` (FEAT-10), so switching language keeps the place.
- Learn side by side: original line above, chosen language below (as FEAT-10 shows now), both lit by their own clock.
- Done when: switch en → vi → fr mid-paragraph and the same sentence stays lit each time.

### S4 · Page extractor (convenience, after S1 to S3 prove the loop)
- Measure before importing anything: write a small text-density extractor and test it on 20 saved pages (en, vi, fr: news, blog, a legal page, a forum thread) against Mozilla Readability used as the **yardstick, not a dependency**. Adopt Readability only if the own extractor loses clearly; the law (`spec-and-index-law.md`) allows no outside kit by default.
- The snapshot (extracted text + source URL + sha256) is kept on the device; the page itself need not be.

### S5 · Audio and video links join the same door
- "Recense this link" routes by kind: page → S1/S4; audio or video → the download engines (FEAT-11/12/30) → on-device ears → `asr.json`. One entry point, no new engine.

## Offline and ownership (the gate)
- Outside services: the source page itself, fetched **once** at capture; Apple Translation language packs, installed once. Narration, translation and lenses run on the device.
- Catch-up to the hub is the normal `keep/` sync: never blocks; the hub plays the item with no app; no company is required beyond what `keep/` already uses.

## Not adopting (and why)
- **Safari capsule + Zen Compact/Glance/Split skin:** a surface change, owned by the UI specs and `docs/law/`; it adds no ingest, narration or translation. Two of its ideas already exist: a tapped citation lights its source sentences in Draftpad (`recensetext` brief), and Mac wing panels (`strip/wingpanels.swift`).
- **Arc's Peek / workspaces:** a second workspace beside Draftpad.
- **WebLLM in a WebView:** an in-page model on an 8 GB Mac; Apple's model already runs on the device.
- **A new FTS5/embedding "AskCore":** a real gap but its own feature; see wish below.

## Owed
- Wish filed: "Ask works offline" (on-device index + cited answers); today Ask needs the network.
- S2's spike decides whether S3 is real for Vietnamese.
- Check that the hub's web player can switch between `audio.<lang>.m4a` tracks (not read yet).
