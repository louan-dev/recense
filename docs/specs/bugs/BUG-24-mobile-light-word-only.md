# BUG-24 · On iPhone and iPad the light steps word by word: no sweep inside a word, no prosody, and no number for lag or drift

From: T-0141 (owner, 2026-11-16, relayed by session 6d8dbabe; the same wish as T-0132) ·
Device: iPhone 12 Pro Max, iPad Air 13-inch (M3) · Status: `[ ]` written, not built ·
Builds on: FEAT-20 (the Mac's song light on iOS), FEAT-04 (one clock), BUG-12 (headphone latency), FEAT-09 (carry).

This spec is diagnosis and plan only. No app code was written for it.

Labels, used on every claim:
- **proven** = shown by code, a file listing or a log line named here.
- **assumed** = believed, not shown.
- **untested** = nobody has run it.

Terms, once:
- **The light**: the brightening that follows the voice across the words.
- **Word step**: a whole word lights at once, when it starts.
- **Sweep**: the light crosses the letters of a word while the word is spoken.
- **Voice measure**: `features.json`, 100 readings a second of the voice (loudness, onset, pitch, clarity, voiced).
- **Prosody ribbon**: the drawing under a line that shows pitch and stress.
- **Player**: Recense playing a file it holds. **Live Listen**: Recense captioning another app's sound.
- **Lag**: the light is late (or early) against the voice. **Drift**: two devices slide apart over time.

## What the owner sees
- iPhone and iPad: the light jumps one word at a time. No syllables. No prosody ribbon.
- The Mac: the light moves inside each word, and the ribbon is drawn.
- Also reported: the light ahead of or behind the voice; devices drifting apart when they play together.

## Cause, in three lines
1. **The phone's renderer steps by word unless a line carries song data.** It never sweeps on its own.
2. **Song data comes only from the Mac, through the Worker, and only for songs the Mac has processed.**
   None of the items this iPhone played had been processed by the Mac. Nothing reached the phone.
3. **Prosody was never built for mobile, and Live Listen has no voice measure at all.**

## Red (the evidence)

### R1 · The renderer: word step is the default · proven
- `shared/ShowsKit/Sources/ShowsKit/Views/Transcript.swift:81-88` (`TranscriptLight.spoken`):
  "up to the end of the last word begun". A word lights whole at its start.
- Same file `:171`: the sweep (`sung`) runs only `if SongLight.sung(line)`.
- `SongLight.swift:96`: `sung` is true only when a word has `syl`, `un` or `tm`.
  Those three fields come only from a fit against a song's voice measure, or a listener's own timing.
- The Mac never steps by word. `strip/recense.swift:5516-5551` (`Cadence.progress`):
  - no voice measure: a straight sweep by the clock (`:5537-5538`);
  - any voice measure, speech included: a sweep shaped by the voice's loudness (`:5539-5550`, `curve` at `:5500`;
    `Cadence.track = ep.features` at `:8252`, with no test of its source);
  - a song's fitted syllables: syllable by syllable (`:5526-5536`).
- So the gap is wider than songs. **For speech too, the Mac sweeps and the phone steps.**

### R2 · The data: which of the three cases is true
Asked: (a) never made for mobile items, (b) made but never reaches the phone, (c) reaches it but is not read.

**Player (stored media): case (a) for every item measured · proven on the iPhone, untested on the iPad.**
Read from the iPhone's own app container on 2026-11-16 14:00 (`xcrun devicectl device info files`, read-only):
- `Library/Application Support/Recense/` holds one folder, `transcripts`. **There is no `voices` folder.**
  `voices` is where a voice measure is saved (`mobile/HostApp/iOS/SongVoice.swift:12-13`).
  So no voice measure has ever been saved on this iPhone.
- `transcripts` holds 6 files. Every line id in them has the form `<ms>-<n>` (for example `23500-0`).
  That form means "heard on this device" (`Phrasing.swift:74-77`). None came from the Mac.
- The 6 items: three short test clips, "Well, certainly, agony.", one empty file, and a 251-second song
  ("There's one way out, one way in"; `Documents/Recense/library/Music/Human by Civil Twilight.m4a`).
- The Mac has no transcript for any of them: a search of all 537 `~/Recense/keep/*.v2.json` for their text found 0.
  No transcript on the Mac means no vocal separation and no voice measure there either.
- `Documents/` on the iPhone: 0 files named `features`, 0 `.fp` fingerprint files, 49 Listen episodes.
- Why the Mac never processed them: the Mac transcribes and measures what it plays, and Gallery's files while idle
  (`strip/recense.swift:6970` `measureMissing`, which lists R2 `tmp/` and `keep/`). A song that arrived by carry or a
  phone download into `library/Music` is neither, until someone plays it on the Mac. **assumed** from the code read;
  the 0 matches above are the proof for these items.

**Case (b) also stands behind it · part proven, part assumed.**
- The only route for a voice measure to the phone is the Worker: `SongLight.swift:31-38` asks
  `/main/api/transcript?path=…&f=features`. **proven**
- Carry (device to device, no company) does not move `features.json` yet: FEAT-20 P3, unbuilt. **proven** (FEAT-20).
- So at first open the syllable light needs the network and Cloudflare. That is against the offline law. **proven**
- Whether the Worker can find a measure for a file in `library/Music` (a path it never listed) is **untested**.
- The Mac holds 382 measures (347 songs, 35 speech) in `~/Recense/keep/`. **proven** (counted).
  None of them is for an item this iPhone played.

**Case (c): two real gaps · proven.**
- Speech measures are refused: `SongLight.swift:22-26` accepts only `source == "vocals"`.
  The Mac uses a speech measure to shape the sweep (R1). The phone ignores it.
- A transcript heard on the phone is never fitted: `SongVoice.fit` has one caller, `Ears.swift:43`,
  on the path that loads a saved or Mac transcript. The path that hears a file (`Ears.swift:62` `hear`) skips it.
  (On the next open the saved copy goes through `:43`, so this costs only the first play.)

**Live Listen (another app's sound): case (a), by construction · proven.**
- Words come from the live recognizer as text, start and end only: `mobile/HostApp/iOS/Listen.swift:854`.
- No audio is kept and nothing measures the voice. There is no file for the Mac to process later.
- The floating window draws one picture per coming word (`Listen.swift:1145`), so it cannot sweep inside a word today.

### R3 · Is FEAT-20 P1 on the device at all · assumed (strong)
- FEAT-20 P1 merged to `main` on 2026-11-16 07:02 (`7ab3b30`). **proven**
- The newest iOS build, `mobile/build/ios-20261116-121623`, contains `cadence.js`. So the code compiles. **proven**
  (FEAT-20 still says "coded, not compiled": out of date.)
- The app on the iPhone last wrote its files at 12:21-12:23, after that build. **proven**
- That the running app is that build is **assumed**: the device does not report a commit.
- `swift test --filter SongLightTests` and FEAT-20's Done checks 2-6 are still **untested**.
- Either way the outcome on this iPhone is the same: with no voice measure, FEAT-20 P1 changes nothing on screen.

### R4 · Prosody · proven absent
- No file under `mobile/HostApp/` or `shared/ShowsKit/Sources/` mentions prosody or prosogram
  (the only hit is a comment in the bundled `cadence.js`).
- The Mac draws it from `strip/prosody.swift` and `strip/recense.swift:2175-2270`. FEAT-20 lists it as P2, unbuilt.

### R5 · Lag and drift: what is measured, and the missing numbers
Measured today:
- **Route latency** (the delay of the speaker or headphones, as iOS reports it), logged in `listen.floatLog`:
  Speaker 0.096 s and 0.032 s; Bluetooth 0.186 s (this iPhone, 2026-11-16 05:24 and 12:17). **proven**
  The Player subtracts it (BUG-12, `TranscriptLight.heard`).
- **Live lag**: Live Listen holds the light back by `lag`, starting at 1.5 s, then a running average of how late
  each word arrived, held between 0.3 and 4 s (`Listen.swift:149`, `:855`). **proven**
  So in Live Listen the light is behind the voice by design, by about the recognizer's delay.
- **Redraw**: 60 times a second (`Transcript.swift:30`); the frame's own on-screen time is used (`FrameClock.swift`).
- **FEAT-04 P3** (find known content by fingerprint, then light on the content's own clock) is unbuilt:
  `CaptionSeek` and `locateLive` are called by nothing in `Listen.swift` or the broadcast extension. **proven** (grep: 0).

Missing, so nobody can say how far off the light is:
1. **Light error, end to end, in milliseconds**: the moment a word lights on the glass, minus the moment its sound
   reaches the ear. Never recorded, on any route. The 0.186 s is what iOS reports, not what was observed.
2. **Word-time error of the phone's ears**: how far the recognizer's word starts are from the true starts.
   On the Mac a song's words are re-hung on the voice (`Cadence.fit`); on the phone they are used raw. No figure exists.
3. **The live lag's value over time**: updated on every heard line, logged nowhere.
4. **Clock offset between two devices**: nothing exchanges timestamps between the Mac, iPhone and iPad
   (searched `shared/p2ptransport.swift`, `shared/carrymanager.swift`, `strip/handoff.swift`,
   `mobile/HostApp/iOS/Devices.swift`: 0 hits). Each device plays on its own clock.
   Two devices "together" are started by hand and nothing keeps them in step. **proven** for those four files.
5. **Position difference while two devices play the same item**: not measured, because of 4.

## Green (the smallest fix, in phases)
One phase at a time. Each ends at its check. Bugs before features.

### P1 · The light sweeps inside every word, on the phone alone, with no data · effort: low to medium
- Rule: the Mac's own no-data rule. A word in progress is lit up to the letter the clock has reached
  (`SongLight.litCount`, which already falls back to the clock when a word has no syllables: `SongLight.swift:66`).
- Change: one function, `TranscriptLineText.lit` in ShowsKit. For a line with word times, light whole words already
  begun and ended, then the word in progress up to `litCount`. Keep today's colours (white said, 40 % ahead).
  Gold stays for a fitted song only (FEAT-20).
- Reach: Now Playing and Listen's in-app transcript, on iPhone, iPad and the Mac's ShowsKit views. One source.
- Not in P1: the floating window (P1b).
- Checks:
  1. `swift test` in `shared/ShowsKit/`: a new test, "at the middle of a 1-second word the cut is inside the word";
     at its start the cut is before it; at its end the word is whole. A line with no word times is unchanged.
  2. The floating caption test still passes ("whole lines only"): `swift run --package-path mobile/ios/Tests/floatingcaption`.
  3. Device: one screenshot through iPhone Mirroring with a word **half lit**. A still picture proves a sweep;
     no timing is needed. Same on the iPad.
- Offline: needs nothing. No file, no network, no Mac.

### P1b · The floating window sweeps too · effort: medium
- Today: one picture per word. Change: up to 4 pictures inside a long word (a word under 0.25 s keeps one).
- Check: the floating test (`mobile/ios/Tests/floating`), plus a Mirroring shot of the window with a half-lit word.
- Risk, **untested**: more pictures cost memory in the picture-in-picture pipeline. Measure before and after
  (pictures per minute, app memory) and write both numbers in this spec.
- Waits on: the float-rest lane (it is editing `Floating.swift` and `Listen.swift` now). Do not start before it merges.

### P2 · The voice measured on the phone, for speech in the Player · effort: high
- Move `Features.measure` from `strip/recense.swift:5164-5300` into `shared/` (one source; the Mac compiles the same
  file). It is plain signal maths on Accelerate, which iOS has. **assumed** portable; **untested**.
- The phone measures a file while it hears it (`SpeechAhead` already decodes it two minutes at a time),
  with `source: "speech"`, and saves it in `Recense/voices/`.
- ShowsKit gets the Mac's `curve` rule (`strip/recense.swift:5500-5510`, about 12 lines) and `SongLight.usable`
  lets a speech measure shape the sweep (never the fit: the fit stays vocals-only, as on the Mac).
- Fit a heard transcript on its first play too (`Ears.swift:62`), not only on the next open.
- Checks:
  1. A fixture: the same 30-second clip measured by the Mac build and by the shared code gives the same arrays.
  2. On the iPhone 12 Pro Max: seconds taken and peak memory for a 60-minute file, written in this spec.
     Go if it stays under the file's own length and under 300 MB; otherwise measure in the background on power only.
  3. Device: a podcast played in Airplane Mode; the sweep slows on a held vowel and holds through a breath.
- A song on the phone alone still gets P1's clock sweep. Its mix is not a voice (the band's loudness would lead the
  light), so syllables for songs wait for the Mac (P3) or an on-device separator (FEAT-20 P4).

### P3 · The Mac's catch-up reaches the phone with no company · effort: medium to high
- The Mac measures songs it holds but never played (`library/Music` in the homes), one at a time, while idle.
- `features.json` rides the carry (FEAT-09) as a sidecar of its song. This is FEAT-20 P3; build it here.
- The phone keeps looking on the device first, then carry, then the Worker (optional).
- Checks:
  1. Probe first, no code: play "Human by Civil Twilight" once on the Mac, then open it on the iPhone online.
     Does `Recense/voices/` appear on the iPhone? This turns the **untested** Worker lookup into a fact.
  2. Wi-Fi on, internet off (router unplugged from the modem): the measure arrives by carry; the song lights in gold,
     syllable by syllable. Then Airplane Mode: it still does.
  3. FEAT-20's Done check 4: the Mac and the phone side by side, the same syllable within 50 ms.

### P4 · Prosody ribbon on mobile · effort: high
- This is FEAT-20 P2, unchanged. After P2 here, the phone has its own speech measure, so the ribbon can be drawn for
  items the Mac never saw.

### P5 · Live Listen · spike first
- P1 already gives the sweep inside words (the recognizer's start and end, held back by the live lag).
- A live voice measure would have to run inside the broadcast extension. iOS caps that extension's memory
  (about 50 MB: documented by Apple, not measured here). Spike: measure memory with the five arrays streamed.
- Exact timing for content Recense already knows is FEAT-04 P3. Not repeated here.

### L1 · Record the missing numbers (no behaviour change) · effort: low
- Log to `listen.floatLog`, at most one line every 10 s while it changes:
  `live lag 1.42 s` (Live Listen) and `heard = position − 0.186 s` (Player).
- A sync probe: a bundled 20-second clip of clicks with a transcript of one "word" per click.
  The owner films the phone at 240 frames a second with a second device (4 ms a frame);
  the flash of each word against the click in the film's sound is the light error.
  iPhone Mirroring cannot time this: its own delay is unknown. **assumed**
- Check: the log lines appear after a device run; one filmed run per route (speaker, Bluetooth) gives a signed
  figure in milliseconds, written in this spec. Target: within 50 ms (the owner's allowance, FEAT-20).

### L2 · Two devices in step · needs the owner's one-line answer first
- Missing piece: a shared clock. Smallest version: over the existing peer link, exchange four timestamps,
  eight times, keep the fastest round trip; offset = ((t1 − t0) + (t2 − t3)) / 2 (the rule NTP uses). Log it.
- Then "play together" means: start at an agreed moment, re-check every 10 s, and correct by a small speed change
  (2 % at most), never by a jump.
- Open question for the owner (playbook §4, not self-answered): which case is "play together"?
  (a) the same file playing aloud on two devices at once, or
  (b) one device plays and another shows its captions.
  L1's numbers come first in either case.

## Offline path
- At play time, nothing here needs a network. P1 and P1b need no data at all.
- On the phone alone: the sweep (P1), the speech measure (P2), the ribbon from it (P4).
- The Mac adds later, as catch-up: vocal separation and the song's voice measure (P3), which replaces the phone's
  cruder light for that song. It arrives by carry on the local network; the Worker is a second, optional route.
- Never required: Cloudflare, or any company.

## Outside services
- Gallery Worker `/main/api/transcript?f=features` and R2 `keep/`: today the only route for a voice measure
  (a gap against the offline law). After P3: catch-up only, optional. Exit: carry over the local network.
- Demucs (vocal separation): open source, runs on the Mac, no network.
- Nothing else.

## Limits of the hardware
- **iPhone 12 Pro Max** (A14): no vocal separation on it until FEAT-20 P4's spike says go. P2's measure is the
  heaviest thing asked of it; its check sets the limit.
- **iPad Air 13-inch (M3)**, as the device list reports it (FEAT-20 says M2: correct there).
  It has no Taptic Engine. No phase here uses haptics. Any future beat or stress cue must be visible on the iPad.
- **Mac, M1 with 8 GB**: separation one song at a time, only while idle and nothing plays (as `measureMissing` does
  now). Speech is read 5 minutes at a time (existing rule, `measureSpeech`). Never two heavy jobs at once.
- **Broadcast extension**: a small memory cap (P5). **Picture-in-picture**: a cost per picture (P1b).

## Device check (every phase)
- On the owner's real iPhone through iPhone Mirroring, never the simulator:
  `zsh mobile/ios/mirror-shot.zsh "$TMPDIR/shots/<screen>.png" --launch` (outside the sandbox).
- The iPad: the owner looks, or a photo. Both devices before a phase is called done.
- Timing (L1, P3 check 3) is filmed, not mirrored.
- Read the phone's own files again after each phase, to see what arrived:
  `xcrun devicectl device info files --device 00008101-001A50643A98001E --domain-type appDataContainer --domain-identifier com.chauphan.galleryfiles --subdirectory "Library/Application Support/Recense"`

## Invariants (to be tested as each phase lands)
- A word with a start and an end is never lit all at once while it is still being spoken (P1).
- A line with no word times is drawn as before (P1).
- A word marked unsung is never lit; a listener's own timing wins (FEAT-20, unchanged).
- The light for an item never needs a network once the item is on the device (P1-P3).
- A measure from the Mac replaces the phone's for the same item; never the other way (P3).

## Not measured in this pass
- The iPad's app container (only the iPhone was read).
- R2 `keep/` itself (the Mac's local mirror was read instead).
- Any timing on a device. Every lag figure above is from logs or code, none from a stopwatch or a film.
