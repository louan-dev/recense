# FEAT-20 · The Mac's song pipeline and syllable light on iPhone and iPad, 1:1

From: owner (2026-11-16, lane prosody-port): "Port Mac syllable prosody to iPhone/iPad 1:1: ports the Mac's song
pipeline and syllable-by-syllable display to iPhone and iPad, 1:1. Demucs can't run on iOS, so the spec must choose
between two routes: the Mac separates the vocals and sends the timing, or a separator runs on the device."
Status: `[~]` P1 coded, not compiled, device check owed · Builds on: FEAT-04 (one Word type), FEAT-07/16 (transcript
view), FEAT-09 (carry), `unified-offline-first-and-redesign.md` §stems ("ship `features.json` instead of stems").
See also: BUG-24 (2026-11-16): P1 compiles and is in the iOS build of 12:16, yet no voice measure has reached the
iPhone (no `voices` folder), so the light is still word by word there; the iPad is an Air 13-inch (M3), not M2.

Labels: **proven** = a test in this repo shows it · **documented** = a vendor or paper says so, not run here ·
**assumed** = believed, not shown · **untested** = open.

## Baseline (what the result must match)
The Mac's karaoke overlay today, on a song with a measured voice (`<key>.features.json`, source `vocals`):
- the line being sung shows every word as a 35 % ghost; the word being sung is lit **gold** from its first letter,
  the light crossing it **syllable by syllable** at the speed each syllable is sung (`Cadence.progress`,
  `strip/recense.swift:5512-5548`), then easing to white once sung;
- a word written but not sung (`un`) is never lit (`strip/cadence.swift:1-8`);
- a listener's own timing (`tm`, corrections field "time") wins over the voice (`Cadence.pin`, `strip/cadence.swift:267`);
- under the line, in Follow: the prosody ribbon (prosogram); in Learn: chords and sung notes too (`strip/prosody.swift:170-176`).

The light's position must match the Mac's to the frame (the owner's allowance against the Mac is 50 ms,
`shared/ShowsKit/Sources/ShowsKit/Views/Transcript.swift` `TranscriptLight.frame`).

## The Mac pipeline, stage by stage, and its iOS counterpart

| # | Mac stage (code) | What it makes | iOS counterpart | Phase |
|---|---|---|---|---|
| 1 | Vocal separation: Demucs `htdemucs --two-stems=vocals`, MPS then CPU, ≈45 s a 4-min song; stem kept at 16 kHz mono (`strip/recense.swift:4115-4159`) | `<key>-vocals.wav` (this Mac, R2 `offsite` while it lasts) | **Route A: none on the device**; the Mac does it. Route B: an on-device separator (ladder step, below) | A: built on Mac already |
| 2 | Song transcription: Whisper on the stem, lyric prompt only on a mix (`strip/recense.swift:3907-3983`) | lines + words (keep/<key>/, the Worker's `present`) | the Mac's transcript through `TranscriptSource.load` (device copy, then the Worker) — unchanged; on-device ears only when there is none (`mobile/HostApp/iOS/Ears.swift`) | exists |
| 3 | Voice measure: `Features.measure` on the stem, 100 frames/s: db, onset, pitch (YIN), clarity, voiced (`strip/recense.swift:5160-5300`, `measureVoice` 4067-4089) | `keep/<key>/features.json`, pushed by `Keep.pushFeatures` | **read, not made**: `SongLight.voice` — this device's copy, else the Worker's `?f=features` (`library/src/transcript.js:242-251`), saved here at once | **P1 built** |
| 4 | Words hung on the voice: `Cadence.fit` (onsets, entries, rises; `strip/recense.swift:5394-5508`) and `Cadence.align` on the voice's own syllables (`strip/cadence.swift:120`) | each word's s/e, `syl` [{c, s, e}], `un` | **the Mac's own code**: `Cadence.fit` + `Cadence.align`, moved unchanged to `shared/ShowsKit/Cadence` (T-0132), called by `SongLight.fit` | **P1 built** |
| 5 | The listener's timing: `Cadence.pin` (`strip/cadence.swift:267`) | words retimed to `tm` | `Cadence.pin`, the same shared Swift; `tm` now decoded from the Worker (`TranscriptSource.decode`) | **P1 built** |
| 6 | The light inside a word: `Cadence.progress` (`strip/recense.swift:5512`) | 0…1 per frame | `SongLight.fill` (Swift, cadence.js `fill` rule for rule), `litCount` cut on whole letters | **P1 built** |
| 7 | The display: gold head, sung white, ghost ahead, unsung never lit (`strip/recense.swift:2046-2100, 2464`; web `gallery.js:4890-4947`) | the overlay | `TranscriptLineText.sung` in ShowsKit's transcript view (Now Playing, Listen's window) | **P1 built** |
| 8 | Prosody ribbon, ties, chords, notes: `prosody.js` + `prosogram.js` in a hidden WKWebView (`strip/prosody.swift`), drawn under the row (`strip/recense.swift:2175-2270`) | `<key>.prosody.json`, row pictures | the same two files in a hidden WKWebView on iOS (prosogram draws on a canvas, so JavaScriptCore alone can't), pictures laid under the line | P2 |
| 9 | Speech measured too (`measureSpeech`, source `speech`): notation only, never the light | features.json (speech) | same file, read; the light ignores it (`SongLight.usable`) | P1 (read rule) / P2 (draw) |
| 10 | Offline carry of the measure | — | `keep/<key>/features.json` carried device to device with the FEAT-09 ops log, so a song never opened online still lights | P3 |

## Route: A or B

**Route A · the Mac separates, measures and sends the measure.** iOS reads `features.json` (100 ints a second,
5 arrays: ≈ 0.5–1 MB a 4-minute song as JSON, **assumed** from the format) and runs the same rules.
**Route B · a separator on the device** (a Core ML conversion of Demucs/HT-Demucs or a smaller 2-stem model),
then `Features.measure` ported to iOS (vDSP exists there).

Evidence:
- **Size.** HT-Demucs weights are ≈ 80 MB fp32 per model (**documented**, facebookresearch/demucs); a Core ML
  build adds the app's largest asset by far. Route A ships no model: the rules are the shared Swift `Cadence` (**proven**, repo).
- **Speed.** Demucs takes ≈ 45 s for 4 minutes on an M-series GPU (**proven** in the Mac's own log line,
  `strip/recense.swift:4114`); an A14 (iPhone 12 Pro Max) is several times slower and iOS stops long background
  work (**assumed**). Route A does a `fit` of a song in Swift once per open (**assumed** tens of ms).
- **Offline law** (`docs/law/offline.md`): "work lands on the device first"; "models … may be downloaded once".
  Route A after the first open: the measure is on the device, no network (**proven** by `SongLight.voice` test).
  Route B: fully on the device, also allowed (a one-time model download).
- **When the Mac is away.** Route A: the Mac pushed the measure to keep/ (R2) when it made it, so the Worker serves
  it with the Mac off (**documented** in `transcript.js`); a song the Mac never saw has no measure, and its words light
  by their own times, as today. Route B covers exactly that case.
- **1:1.** Route A gives the same numbers as the Mac (one measure, the same rules). Route B would measure a different
  stem with a different separator, so the light could differ from the Mac's on the same song.

**Choice: Route A** (built, P1). **Route B is the fallback ladder step** (P4), only for songs that reach the phone and
never the Mac (FEAT-11 downloads while away), and only after a spike measures size, speed and memory on the
iPhone 12 Pro Max. Ladder for a song's light on iOS:
1. a measure on this device (cached, or carried: P3);
2. the Mac's measure through the Worker (saved here);
3. (P4) separated and measured on this device (model downloaded once; replaced by the Mac's measure when it comes);
4. the words' own times (today's light), never nothing.

## P1 (built: compiled, device check owed)
- `shared/ShowsKit/Sources/ShowsKit/SongLight.swift`: `featuresPath`, `usable` (vocal stem only, > 20 frames),
  `voice` (device copy → Worker → saved), `fill` / `litCount` (the light), `sung` (a line the voice timed),
  `fit` (`Cadence.pin(Cadence.fit(lines, F))` around the Worker's `shift`; the Mac's own Swift, `shared/ShowsKit/Cadence`).
- `TranscriptSource.decode` reads `syl`, `un` and `tm` when the Worker sends them.
- `Views/Transcript.swift` `TranscriptLineText.sung`: gold up to the letter reached, sung words white, unsung dim.
- `mobile/HostApp/iOS/SongVoice.swift` + `Ears.swift`: a transcript from the Mac or this device is fitted before it's
  shown.
- One logic per kind of surface (PLAYBOOK §2: JS for web, Swift for native, never a second copy): the Mac, iPhone
  and iPad run the one Swift `Cadence`; the web runs `cadence.js`. Amended 2026-11-17 (T-0132): iOS first ran a bundled
  `cadence.js` in JavaScriptCore, a second copy on a native surface; the shared Swift is proven identical to the Mac's
  code on 381/381 measured songs and gives cadence.js's own numbers on the shared fixture (`SongLightTests`).

## Done checks
1. `cd library && npm test` passes, including `test/songlight.test.mjs` (the fixture is current with cadence.js). **proven** (this lane).
2. `cd shared/ShowsKit && swift test` passes `SongLightTests` (Swift `fill` = cadence.js `fill` at 344 moments; the
   Swift engine fits the fixture song to cadence.js's own numbers; decode reads syl/un/tm). **proven** (85/85, 2026-11-17).
3. The iOS app builds (`xcodebuild … generic/platform=iOS`). **proven** (BUILD SUCCEEDED, 2026-11-17).
4. Device, against the baseline: the same song with a measure, played on the Mac and on the phone side by side:
   the gold head reaches each syllable at the same moment (≤ 50 ms by eye/video), held words held, an unsung word
   never lit. iPhone 12 Pro Max and iPad Air M2 13-inch. **untested**.
5. Airplane mode after one online open: the song still lights syllable by syllable. **untested**.
6. A podcast (no vocal measure) lights word by word exactly as before. **untested**.

## Phases after P1
- **P2** prosody ribbon, ties, chords, notes on iOS (stage 8): `prosody.js` + `prosogram.js` bundled, a hidden
  WKWebView engine as `strip/prosody.swift`'s, row pictures under `TranscriptLineText`. Follow/Learn toggle as the Mac's.
- **P3** carry `keep/<key>/features.json` with FEAT-09 (a carried sidecar of the song, not a home of its own).
- **P4** Route B: spike first (go/no-go under "Decided"), then the device separator as ladder step 3.

## Decided (2026-11-16, the owner: "you decide what's best based on what I'd choose")
1. **The look: the Podcasts layout stays; the Mac's light inside it, exactly.** The owner chose the iOS transcript's
   look (as iOS Podcasts, the owner's screenshots 08-91: `Views/Transcript.swift:1`), and "1:1" asks for the Mac's
   *light*, not the Mac's window. So iOS keeps its serif lines, scrolling and menus, and the active line of a song is
   lit as the Mac lights it: words not yet sung at 35 % (gallery.js `UPCOMING`), the word being sung gold up to the
   letter its syllable has reached, a sung word easing gold → white over 0.45 s, an unsung word never lit
   (`SongLight.ahead`, `settle`, `settled`; built). A song shown as the Mac's one-line overlay is not wanted.
2. **Route B: yes, as ladder step 3 (P4), never in place of A.** The offline law says the network is "an
   optimization, never a dependency" and the Mac mini is a relay, not a vital (`docs/law/offline.md:10, 18, 27`): a
   song downloaded on the phone away from the Mac (FEAT-11) must still light by its syllables. Under these rules:
   - the separator model is a **one-time download** with its source, size and checksum (offline law), never in the
     app binary, and only fetched once the owner turns it on (or the first song needs it, on Wi-Fi);
   - it runs only for a song with no Mac measure, on power or in the foreground; the Mac's measure, once it comes,
     **replaces** the device's (one measure, the Mac's, so the light is the Mac's: 1:1);
   - its output is the same `features.json` (source `vocals`), so nothing after stage 3 changes;
   - before any code: a spike on the iPhone 12 Pro Max (model size, seconds per 4-minute song, peak memory,
     heat) with a go/no-go of under 2 minutes and under 1.5 GB per song.

## Handoff

**Built (P1, Route A):** the Mac keeps separating (Demucs) and measuring the voice; iPhone/iPad read its
`features.json` (device copy first, then the Worker's `?f=features`, saved for offline), hang the words on the voice
with the Mac's own `Cadence` (`fit` + `pin`, shared Swift, `shared/ShowsKit/Cadence`), and light each word
syllable by syllable in gold with `SongLight.fill` (cadence.js `fill`, the Mac's `Cadence.progress`). Unsung words
are never lit; a listener's timing wins. Files: `shared/ShowsKit/Sources/ShowsKit/SongLight.swift`,
`TranscriptSource.swift` (decode syl/un/tm), `Views/Transcript.swift` (`sung`), `mobile/HostApp/iOS/SongVoice.swift`,
`Ears.swift`, `shared/ShowsKit/Cadence/*` (T-0132), `library/test/songlight.test.mjs`,
`shared/ShowsKit/Tests/ShowsKitTests/SongLightTests.swift` + `Fixtures/songlight.json`.

**Tests run (this lane, Linux, no Swift):**
- `node test/cadence.test.mjs`: 10/10 pass. `node test/songlight.test.mjs` (new): 2/2 pass.
- Swift `fill` checked by a line-for-line Python port against the fixture: 344/344 moments match cadence.js.
- Full `npm test` (with `CHROMIUM=/opt/pw-browsers/chromium`): every suite up to viewer.test passes (291 `ok`
  lines); viewer.test: 38 passed, then 1 FAIL `SPEC P3 12: Download bakes in EQ…` (the headless browser names the
  file `download`): outside this lane's diff (library/ change = one new test file + its entry in `package.json`),
  so not fixed here; the chain stopped there. `editorpwa.test.mjs` run alone: 2 ok, browser steps skipped
  (its headless shell is missing here).
- `swift test`: not run (no toolchain).

**Unverified:** nothing Swift is compiled (no toolchain in the lane's container). Coded, not compiled, device check owed.

**Steps for the owner / Mac session:**
1. Mac: `cd library && npm install && npm test` (expect all pass, incl. songlight 2/2).
2. Mac: `cd shared/ShowsKit && swift test --filter SongLightTests` (6–7 tests), then `swift test`.
3. Mac: `cd strip && ./build.sh` (ShowsKit changed: the Mac app must still build; nothing in strip/ changed).
4. Mac: `cd mobile/ios && ./build.sh`; install on the
   iPhone 12 Pro Max and the iPad Air M2 13-inch.
5. Pick a song the Mac has measured (`~/…/keep/<key>.features.json` exists, source `vocals`). Play it on the Mac
   overlay and on each device: Done check 4. Then airplane mode on the device, reopen: Done check 5. Then a
   podcast: Done check 6.
6. If a device shows no gold: Console for `cadence.js` missing from the bundle (SongVoice returns the lines as they
   were), or the Worker answering `{none:true}` for that path.

**Questions for the owner:** none open. Both were decided under "Decided" (Podcasts layout with the Mac's light;
Route B wanted as ladder step 3, spike first). Say so if either is wrong.
