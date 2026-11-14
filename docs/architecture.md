# Recense · architecture and reuse

This file settles *how code is arranged so it can be reused and recombined*. What Recense is, its names and where a
feature goes are law: `docs/law/` (where they differ, the law wins). Written 2026-10-28 from the owner's words; changes
only when a decision does.

The "Names" and "Why the second app kept coming back" sections (written when the app was called Sill, then garbled by
the rename) were replaced on 2026-11-14 by `docs/law/structure.md` § Names; the originals are in git history.

## The reuse problem, in the owner's words
> "the homebar i designed i didn't realize it was gonna be on recense, recense, and gallery … it'd be cool to separate the
> features from the core of what it does, so it's easier to reuse features, group them together with others, or build new
> apps by just pointing in the folder, copying the code and combining it in another … not necessarily that I want a new
> app, but I want it to be easy to reuse code and recombine to make new stuff, so it's not so intertwined that it becomes
> hard to separate."

So the goal is **separability**, not shipping. Optimise for *"copy this folder into something else and it still works"*.

## The one rule that makes reuse work
**A feature knows nothing about its host.** It receives a host object, declares what it needs, and never names the app
it's running in.

This already exists and already works — twice:
- `Homebar.tray(host)` in `gallery/src/client/homebar.js`, with the host contract written in the comment above
  `const tray`. One implementation; Gallery serves it, Recense bundles it into `Resources/homebar/`.
- `room.js` and `keylabel.js`, same shape, loaded by `src/page/gallery.js` on the web and copied by `recense/build.sh` into
  the app.

Everything below is that pattern, made explicit instead of remembered.

## Two reuse tracks
Recense's shared code is in two languages with two different delivery mechanisms. Keep them separate in your head.

### Track W · web modules (JS/CSS)
**Canonical home: `gallery/gallery/src/client/`.** Gallery's Worker serves them; `recense/build.sh` copies them into
`Recense.app/Contents/Resources/homebar/`. Consumers today: Gallery's `/main` player, Recense's Recense panel, the prototypes.

Promote each to a folder with its contract beside it:

```
gallery/src/client/
  homebar/    homebar.js, homebar.css, CONTRACT.md
  keylabel/   keylabel.js, CONTRACT.md
  room/       room.js, CONTRACT.md
  prosody/    prosody.js, CONTRACT.md          ← move from recense/.handoff/prototypes/_shared/
  prosogram/  prosogram.js, CONTRACT.md        ← move from recense/recense/homebar/prosogram/
  MANIFEST.json
```

`MANIFEST.json` lists each module, the files it owns, what it needs from a host, and who consumes it. **`build.sh` reads
the manifest instead of carrying a hand-maintained `cp` list** (today: `build.sh:29`, five filenames typed by hand — the
exact thing that made the homebar's spread invisible).

### Track S · Swift modules
Today: one SwiftPM `executableTarget` named `recense`, with `app.swift`, `recense.swift` and `soundengine.swift`
**symlinked** into `Sources/recense/` (`main.swift -> ../../app.swift`, etc.). That symlink trick is good — it keeps a flat
authoring layout while satisfying SwiftPM. Keep it.

**One big file per area is fine.** For a solo author Swift has no headers, search beats file-hopping, and 7k-line files
have not slowed this project down. **Do not split for tidiness.** Split only where a seam buys separability:

| Target | Holds | Portable? |
|---|---|---|
| `VoiceMeasure` | `Features.measure`, YIN, smoothing, stylisation, nuclei | **yes** — Accelerate + AVFoundation only, no AppKit, no `Process()` |
| `MediaChain` | the Core Audio process tap and the EQ/Key/Space chain (`soundengine.swift`) | **no** — macOS only, declare it |
| `Transcribe` | the ASR and translation provider seam (below) | partly |
| `RecenseCore` | Episode, transcripts, cache, `keep/` merge, ffmpeg export, the 47123 server | **no** — `Process()`, ffmpeg |
| `RecenseUI` | panel, overlay, homebar WKWebView host, Recense menu | macOS |
| `RecenseUI` | strip, panels, menu-bar hider, draftpad | macOS |

**Extract `VoiceMeasure` first.** Cleanest boundary, no UI, it is what the prosogram work needs, and it is the only
piece with any future outside macOS.

### Access levels when splitting (settled 2026-10-28)
**Promote to `package`, not `public`.** `Package.swift` is `swift-tools-version:5.9`, which has the `package` access
level: visible to other targets in this package, invisible outside it. That is exactly what a split for internal
organisation needs, and `public` is the wrong tool for three reasons — it advertises API nobody intends to support, it
makes class members non-overridable (you then start writing `open`, a stronger promise than you want internally), and it
erases the one boundary that may genuinely matter later. If `VoiceMeasure` ever becomes its own package for an iOS
target, *then* its surface becomes `public` deliberately, and the diff shows exactly what is being committed to.

Nothing needs annotating today: one target means every declaration is already implicitly `internal` and everything sees
everything. The modifiers only start mattering at the split, which is why it is mechanical rather than a redesign.

Method: move the files into the new target, build, and let each *"inaccessible due to 'internal' protection level"* name
the next line to annotate. `package` on whatever the compiler complains about, `internal` left alone, **no logic
changes**, one commit.

Two things that will eat the session if unanticipated:
- **Synthesized initialisers do not cross module boundaries.** A struct's memberwise `init` is internal, so the first
  breakage after extracting `VoiceMeasure` is every construction site of a moved struct — write explicit
  `package init(...)`. `Features` is `Codable` and serialised to `features.json`, so verify its init survives the move
  rather than assuming.
- **`package` is not inherited by members.** Marking a type `package` does not promote its properties or methods; each
  one called across the boundary needs its own annotation.

**Every module declares its platform reach in its header comment.** That one line is what stops someone discovering at
build time that a "shared" module shells out to ffmpeg.

## Provider seams (the pattern for swapping an engine)
When an external service can be replaced by something on-device, put a protocol between the callers and the engine.
**Recense already does this for translation and it is the model to copy.**

`recense.swift:251` — *"on-device translation (Apple's Translation, macOS 15+): the stand-in when every Groq model is
out"*. Groq's free quota dies hours into a long podcast; lines about to be heard get translated on the Mac instead, free,
offline, marked as drafts, and a model redoes them later when quota frees up.

**Learn from the scar tissue in that comment, because the same class of bug will appear in any Apple-framework swap:**
one Translation session switched across language pairs, hosted in a window that was hidden, shown and moved, leaked Mach
ports until macOS killed the process — `EXC_RESOURCE`, 305,834 ports, after about 20 hours. The fix: one session per
language pair, each in its own 1-point view, in a window that is **never hidden or moved**, closed a minute after its
last job, and only for languages already downloaded. **Apply the same discipline to any on-device speech session.**

### The `Transcriber` seam (design settled 2026-10-28; build it now with Groq as the only implementation)

The point of the design is that **engines differ in ways callers must not guess about.** Whisper decides the language
itself and reads a prompt; on-device speech needs a locale and a downloaded model and has no prompt. So the types carry
those differences instead of hiding them.

```swift
/// One request. Callers ask for what they want; the engine reports what it could not honour.
struct TranscribeRequest {
    var audio: URL
    var locale: Locale?             // nil = let the engine decide (Whisper can; on-device cannot)
    var hints: [String] = []        // corrected spellings, highest value LAST (Whisper reads the prompt's tail)
    var wantWordTimings = true
}

/// How far the times can be off. Not a Bool: prosody needs to know how much to trust them.
enum TimingResolution: Sendable {
    case word(tolerance: TimeInterval)
    case segment(tolerance: TimeInterval)
    case none
}

enum Capability: Sendable { case wordTimings, hints, autoLocale, multiLocalePerRequest }

enum Availability: Sendable { case ready, needsDownload(bytes: Int64), unsupported }

struct TranscribeResult: Sendable {
    var words: [Word]
    var locale: Locale              // what the engine actually used or heard
    var timing: TimingResolution
    var ignored: Set<Capability>    // what it could not honour — callers read this, never assume
    var engine: String              // provenance, stored with the transcript
}

protocol Transcriber: Sendable {
    var id: String { get }                                   // "groq.whisper-large-v3", "apple.speechtranscriber"
    var capabilities: Set<Capability> { get }
    var needsNetwork: Bool { get }
    func availability(for locale: Locale) async -> Availability
    func transcribe(_ request: TranscribeRequest) async throws -> TranscribeResult
}
```

Why each part earns its place:
- **`TimingResolution` carries a tolerance, not a flag.** This is the word-timing blocker expressed in the type system:
  `prosody.js`'s `invert()` must refuse anything coarser than `.word`, because syllable windows built from segment-level
  times would silently corrupt every pitch and loudness number. A caller cannot forget to check a value it has to switch
  on.
- **`ignored` forces honesty.** If an engine cannot use `hints`, the caller sees that the glossary corrections were
  dropped rather than wondering why spellings regressed.
- **`availability` is separate from `transcribe`.** On-device models download per locale; that must surface before a job
  starts, not as a failure inside one. This is the same rule the Translation work arrived at the hard way — *only
  languages already downloaded are used*.
- **`engine` travels with the transcript.** `keep/<key>/` and `features.json` need provenance once two engines exist.

**Hard rule: never mix engines within one episode unless provenance is recorded per segment.** Two engines mean two
timing resolutions, so some syllables would be measured from word times and others from segment times — exactly the kind
of invisible inconsistency that makes a measured number worthless. `Word` already carries `draft: Bool?` for lines Apple
translated while Groq was out (`recense.swift:390`); add engine provenance the same way, or refuse the mix.

Implementations:
- **`GroqTranscriber`** — today's path. `capabilities = [.wordTimings, .hints, .autoLocale]`,
  `timing = .word(tolerance: …)` (measure it), `needsNetwork = true`. Keeps the 224-token prompt tail, the rate-limit
  retry parsing (`recense.swift:105`) and the quota-exhaustion draft path.
- **`OnDeviceTranscriber`** — Apple Speech (`SpeechAnalyzer`/`SpeechTranscriber`, the 26 generation). Expect
  `capabilities` **without** `.hints` and **without** `.autoLocale`; `timing` to be measured by the spike, not assumed.
  **Apply the Translation lifecycle discipline**: one long-lived analyser per locale, never hosted in a view that is
  hidden or moved, closed after an idle period, and only for locales whose assets are already downloaded.

Config already has the right shape — `cfg.base`, `cfg.whisperModel`, `cfg.translateModel`, `cfg.apiKey` all come from
`~/.config/recense/config` (`recense.swift:38–53`), so no endpoint was ever hard-coded. Add
`TRANSCRIBER=groq|ondevice|auto`, where `auto` prefers on-device when `availability == .ready` and falls back to Groq,
recording which ran.

**Build this before the OS upgrade.** With `GroqTranscriber` as the only implementation the behaviour is identical, the
refactor is verifiable today, and the on-device class becomes an addition rather than a rewrite.

### What Apple does *not* give you
- **No public stem separation.** Nothing in iOS/macOS 26 splits a mix into vocals and instrumental. `SoundAnalysis`
  classifies; it does not separate. Logic's Stem Splitter, Final Cut's Voice Isolation and Voice Memos' Enhance are app
  features, not frameworks. **Demucs stays**, so `RecenseCore` keeps its `Process()` dependency and remains macOS-only.
  A portable version would mean converting a separation model to Core ML — its own project, not part of this seam.
- **On-device LLM is available separately.** The Foundation Models framework (26 generation) could take over the Groq
  `chat/completions` translate call and the glossary reasoning. Distinct from Apple's Translation framework, which is
  already wired as the quota fallback.

## Offline ASR (built 2026-10-29; the plan below is kept for its reasoning)
**What was built** (`recense/speech.swift`, `recense/voiceprint.swift`, wired through `recense.swift`; notes 20261029 item 9):
- **Toolchain.** The Mac runs macOS 27.2 but Xcode is 16.4 (SDK 15.5), which can't compile SpeechAnalyzer. Apple's
  Command Line Tools 27.2 are unpacked (not installed, no admin) in `recense/.toolchain/`; `build.sh` builds with them
  into `.build-sdk27` when they're there (`--build-system native`: their SwiftPM would compile SwiftTerm's Metal shader
  and the tools have no `metal`), else exactly as before with Groq as the only engine (`#if compiler(>=6.2)`).
- **Not a protocol but an adapter.** `OnDeviceASR.transcribe` answers a request *the way Whisper answers one*
  (verbose_json: `language`, `segments`, timed `words` + `probability`, `engine`), so `whisper()` is the one seam and
  everything after it (chunks, cuts, the songs' second pass, `heardWords`, keep/, Gallery) is unchanged. Groq is asked
  only for a language this Mac can't hear (Persian) and only with a key; Recense no longer needs a key to start.
- **Modules.** SpeechTranscriber for en/fr (installed), DictationTranscriber for vi (SpeechTranscriber has no
  Vietnamese). Each language the listener uses is tried and scored (confidence × duration × NaturalLanguage
  agreement); the language heard last is kept while it's heard surely and leaves no voice unheard. Two languages by
  turns (French lesson, English aside) are merged phrase by phrase: a model writes nothing, or one 4-second word,
  over speech it doesn't know, so stretched words are trimmed (> 1.5 s → last 0.6 s) and unheard voice (smoothed
  loudness) triggers the other languages.
- **Measured** (blocker 2 settled): on 2 min of a real English recording SpeechTranscriber wrote 98 % of Whisper's
  words, word times within 0.09 s of Whisper's at the median (p90 0.26 s), ~30× real time; DictationTranscriber
  92 %, 0.05 s median. `TimingResolution` is `.word` for both.
- **The glossary prompt became a lexicon** (blocker 3): contextual strings (`AnalysisContext`) changed nothing in
  tests. `Lexicon` keeps, per language, each corrected word, what was heard instead, a voiceprint of every place it
  was corrected and of places it was corrected back, and applies it on first transcriptions and replays when the same
  mistake recurs and the evidence agrees (same recording; or recognizer unsure < 0.8 or sound near; never nearer an
  "unlike"); the recognizer's own alternatives count too. Voiceprints alone only modestly separate one speaker's word
  from others (real speech, same word p50 7.4 vs others 8.75), so sound confirms and vetoes, never decides alone.
- **Blocked:** `SFSpeechLanguageModel.prepareCustomLanguageModel` fails with SFSpeechErrorDomain 1 for every variant
  tried (3–400 phrases, with/without weight, vocabulary, clientIdentifier; CLI and inside signed Recense with Speech
  Recognition allowed). `CustomLM` and the DictationTranscriber second opinion are wired and stay inert until it builds.
- **Check it:** `curl -s localhost:47123/speech`; `defaults write local.recense speechCheck -bool YES` + relaunch builds a
  throwaway model once and logs the result; `recense.log` lines `speech:` and `lexicon:`.

The owner intends to replace Groq/Whisper with an on-device extractor so transcription runs offline. **Before building
it, four things must be settled, and one is a blocker:**

1. **Target: macOS 26 on this Mac** (owner's plan, 2026-10-28). That is the correct OS — transcription runs in Recense, on
   the Mac, so the Mac's OS is what gates it. Today: **macOS 15.5 (Darwin 24.5.0)**, **Xcode 16.4 / iOS 18.5 SDK**.
   Both need upgrading; Xcode 16.4 cannot compile against 26-generation APIs. Three things to get right:
   - **Keep the deployment floor and use availability guards.** `Package.swift` declares `platforms: [.macOS(.v14)]`.
     Put the new paths behind `if #available(macOS 26, *)` rather than raising the floor, so the app still builds and
     runs if the OS is ever rolled back and so `GroqTranscriber` stays reachable.
   - **Disk.** 21 GiB free today. A macOS major upgrade plus a new Xcode wants considerably more, with working space on
     top. **Finish the nervous-system Phase 1 moves before upgrading**, or the upgrade stalls partway.
   - **Verify the API surface against Apple's current docs.** This assistant is reliable on the 26 generation existing,
     not on every signature.
2. **Word timings are load-bearing and must be verified first.** `Word` (`recense.swift:381`) carries `start` and `end`,
   and the whole prosody layer hangs off them: `prosody.js`'s `invert()` turns word timings into syllable windows
   `s.t0/s.t1`, which are the windows every pitch and loudness number is measured over. If the on-device API's timing
   granularity is coarser than Whisper's, **every prosogram number changes.** Settle this with a spike on one clip,
   comparing on-device timings against the existing Groq timings, before any migration.
3. **The glossary → prompt mechanism does not transfer.** Corrected spellings are fed to Whisper as a prompt, truncated
   to the last 224 tokens (`recense.swift:574–607`). On-device speech has no equivalent prompt; it has contextual
   strings / custom vocabulary with different semantics and limits. This needs redesign, not porting.
4. **Whisper-specific workarounds become dead weight.** Whisper names one language per request and may silently
   translate the rest into it (`recense.swift:851–857`, `936`), which is why language detection pairs it with
   NaturalLanguage per phrase. On-device recognition is per-locale with different failure modes, so that whole design
   should be re-derived, not carried over. Rate-limit parsing (`recense.swift:105`, "Please try again in 975ms") and the
   quota-exhaustion draft path become fallback-only.

**What gets better.** No rate limit means ASR can be run across the whole library, which unblocks the corpus work in
`recense-voice-vision.md` (expected-answer files, and the Vietnamese orthography-as-label trick at scale). Offline ASR
also strengthens the nervous-system Phase 3 goal: transcription with no connection. And `~/Library/Caches/recense` stops
being precious — it is currently protected from deletion *because* regenerating it costs Groq calls.

**Disk first.** A macOS and Xcode upgrade wants well over the 21 GiB currently free. Finish the nervous-system Phase 1
moves before upgrading, or the upgrade will stall.

### What a macOS 26 upgrade puts at risk in this codebase
Recense is a daily driver that leans on private and permission-gated APIs, so note the state of each **before** upgrading
and re-check **after**. A major OS release is exactly when these break.

| At risk | Why | Check after |
|---|---|---|
| **MultitouchSupport gestures** (`app.swift`, three-finger swipes) | **private API**, already marked experimental in `.claude/CLAUDE.md` — first casualty of a major upgrade | layers up/down and panel paging still respond |
| **Core Audio process tap** (`soundengine.swift`) | tap and `muteBehavior` semantics have shifted between releases; SoundSource already breaks tap muting | tap a followed player, confirm original audio mutes and returns on quit |
| **Accessibility and Calendar permissions** | `build.sh` keeps a stable signing identity specifically so these survive *rebuilds*; an OS upgrade commonly still resets them | strip reads events; Recense follows a player |
| **Apple Events to QuickTime / Music** | `osascript` automation permissions reset on upgrade | exact-sync seek test from the handoffs |
| **Translation framework** | the Mach-port leak workaround (one session per pair, never-moved window) was tuned against macOS 15 behaviour | run a long session and watch port count; the old failure took ~20 h |
| **Gallery.app Touch ID / Secure Enclave** | `LAContext` and keychain behaviour around the sealed `rclone.conf` | open Gallery, unlock with Touch ID only |
| **rclone NFS mount** | mount semantics, and the existing "TextEdit won't open files on the mount" oddity | mount, read, write, delete to trash |

Record the before-state in `PROGRESS.md` §7 so "it broke in the upgrade" is provable rather than suspected.

## The prosogram in Recense: hidden WebView compute engine, native drawing (decided 2026-10-28)
**Decision: `prosody.js` stays the one and only implementation of the language layer. Recense runs it in a hidden
WKWebView used purely as a compute engine, and draws the result natively with its existing `Ink`/`Row` machinery.**

**Why not a Swift port.** Porting `prosody.js` (627 lines of French and Vietnamese syllabification, tone templates,
liaison, stylisation) would create a second implementation of the same logic. Two copies of language rules drift, and
every accuracy fix in `recense-voice-vision.md` would have to land twice and be scored twice. That is the duplication
this file forbids, and weakness 8 of the vision doc already asks for one side, not two.

**Why the home bar is the wrong surface.** `recense/recense/homebar/index.html` is a control strip: it posts commands outward
(`cmd`, `say`, `lang`, `size`, `fx`, `chroma?`, `chord`, `clear`, `download`) and receives no words, no lines, no
features and no clock. `RecenseHomeBar` sizes it to `clamp(36px, 100vh-104px, 116px)`. Meanwhile Recense's transcript is
drawn **natively** (`recense.swift:2170–2352`: `blocks`, `places`, `Row`, `Ink`, `draw(_ r: Row…)`, `draw(_ k: Ink…)`,
`NSAttributedString` with per-ink kern and lit/unlit alpha). The prosogram belongs under those lines, so it must be
drawn where they are.

**The contract, kept deliberately narrow so the engine can be replaced by a Swift one later:**
- **In:** the corrected transcript from `keep/` with word timestamps, plus the stem (or the audio).
- **Out:** per-word `pts` arrays — `u`, `h`, `w`, `cut` — and nothing else.
- Nothing about AppKit, windows or playback crosses this boundary.

**Rules this must obey:**
1. **Syllable windows must not come from canvas text metrics.** Do the glyph-metrics fix first (fact 1 above, and step 2
   of the prosogram order). A headless compute engine has no canvas; today it would silently fall back to uniform
   per-character spacing and measure different windows than the screen does.
2. **Compute once, cache in `features.json`.** Recense reads stored values at playback and runs **no JavaScript on the
   clock path**. The web view is a build-time tool, not a runtime dependency.
3. **Compute from the corrected transcript in `keep/`.** When a word is fixed, the prosogram is recomputed, so a replay
   is at zero errors in both Recense and Gallery.
4. **Do not touch the karaoke light.** The prosogram is drawn under the existing lines with the current lit/unlit
   machinery; Cadence stays exactly as it is.

**Status:** Gallery's side is built and verified in a browser (see below). Recense is not started.

### Gallery prosogram: verified 2026-10-28
Built as `gallery/src/client/prosogram-mount.js` — the whole adapter, with `client/gallery.js` untouched (it is the
C0/D1 session's). Loaded from `page/gallery.js`; `prosogram-main.js` carries the owner route and is gated on `live.main`
so a participant's page stays clean of it.

Verified in Chromium against Miniflare with a fixture whose pitch is a deliberate arch (MIDI 55 → 67 → 55):

| | |
|---|---|
| Panel mounts beside the player | yes |
| Per-syllable pitch | 57.07 · 61.04 · 65.91 · **66.27 at the arch's peak** · 60.04 |
| Normalised heights | −0.863 · 0 · +1 · +1 · −0.218 — follows the arch |
| First word's `pts.h` | climbs −1.000 → −0.378 monotonically |
| Reference / span | 61.04 MIDI / 9.2 st |
| Glyphs and staff | drawn, spoken vs ahead colouring correct |

**Two bugs the browser check caught that no unit test would have:**
- The media element lives inside `.mbox`'s **open shadow root** (`gallery.js:56` `stageMedia()`), so
  `document.querySelector("audio, video")` never found it and the panel silently never appeared.
- The plugin reads **`f.page`** — one block per transcript line, `{line, index, slot, alpha, cells, byFlat, lineHeight,
  size, font}` with `cells: [{w, x, width, row, y, top}]` (`harness.js:100, 126, 128`) — not the `f.lines` shape the
  contract comment described. `prosogram.js` draws the glyphs itself; a host supplies geometry only.

**Still unjudged:** whether the figure *reads well* at normal size. Its excursion is `AMP · size · expr` ≈ ±5 px at a
17 px font, and the test fixture was four words on a 1200 px canvas. That needs a real song and the owner's eyes.

## Enforcement, so this doesn't rot
Rules in a document decay. These are cheap and mechanical:
- **No upward imports.** A test greps each shared module for its hosts' names: `prosody.js`, `homebar.js`, `room.js`,
  `keylabel.js`, `prosogram.js` must not contain `Recense`, `Recense` or `Gallery` outside comments. If one does, it is not
  reusable and the test says so.
- **Manifest is the only copy list.** `build.sh` reads `MANIFEST.json`; a module not in the manifest is not bundled. No
  hand-typed filenames.
- **One canonical copy per module.** A duplicate is a bug. `prosody.js` currently exists twice, byte-identical
  (`recense/.handoff/prototypes/_shared/` and `recense/recense/homebar/prosogram/`), which is how drift starts.
- **Every module header states: what it needs from its host, and its platform reach.**

## Order of work
1. Kill Recense.app for good (three causes above, in order). **Move `recense/homebar/prosogram/` out first.**
2. Promote Track W to folders with `CONTRACT.md` + `MANIFEST.json`; make `build.sh` read the manifest; dedupe
   `prosody.js`. Add the no-upward-imports test.
3. Extract `VoiceMeasure` as a SwiftPM target (pure move, compiler as oracle, one commit, no logic changes).
4. Add the `Transcriber` seam with `GroqTranscriber` as the only implementation — behaviour identical, seam in place.
5. After the OS and Xcode upgrade: spike on-device word timings against Groq's on one clip (blocker 2). Only then write
   `OnDeviceTranscriber`.
6. Split `RecenseCore` / `RecenseUI` / `RecenseUI` if and when a second product actually needs it — not before.
7. **The prosogram in Recense: hidden WebView compute engine, native drawing** (see the section above). Order within it:
   glyph-metrics fix → compute-and-cache into `features.json` → recompute on correction → native draw under the
   existing `Ink`/`Row` lines. Not "mount the web prosogram in the home bar": that surface is a control strip and the
   transcript it belongs under is native.

**Done when:** no Recense.app can be built or launched; every shared module has one canonical copy, a contract and a
manifest entry; `build.sh` has no hand-typed file list; `VoiceMeasure` builds as its own target; and swapping the
transcriber is a config change, not an edit to its callers.
