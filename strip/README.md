# recense

Recense is a quiet strip at the top centre of the Mac's screen; time, date, batteries, a recorder, Draftpad and its namesake,
the listening surface where a recording becomes something to learn from: heard, read, seen lit and felt in its rhythm.
One app, one process, no Dock icon. It works offline; Gallery's Worker and R2 are an optional cloud side for sharing
transcripts and files.

Its menu-bar hider is part of Recense, not an app of its own.

## Why this exists
Recense began as a kindness to an old MacBook: an M1 with 8 GB of memory and a nearly full disk, gasping under files that
only ever grow. Instead of buying a new machine, I wanted to give this one room to breathe again, with one small app
in place of a handful of always-on ones, and with my words, recordings and drafts kept on hardware I can see.

It is also my attempt to make learning feel like a playground. Long walls of text lose me; a song I love, a sermon in
my parents' language, a film watched twice do not. Recense grew out of what has actually worked for me: hearing a
voice while its words light up as they are sung, seeing the melody drawn over the line, reading the translation beside
it. If it helps me, I hope it can help the people dear to me, people for whom English is a wall, English speakers
curious about a culture or a city they don't yet know, and people whose bodies or minds learn better through more than
one sense. I didn't find a tool like that without a company in the middle, so I am building one, slowly, and handing
it on. Everyday media is full of quiet lessons; Recense tries to catch them in the moment they pass by.

## A score for the verbal world
Recense began in a conversation about conversation, held with someone who teaches it as a craft. Verbal exchange and
improvisation suffer from the same misunderstanding. Both are imagined as pure spontaneity, a gift that settles on the
fortunate at birth, and so both are left to chance. To improvise is to compose and perform in a single act, and
impromptu speech does exactly this: a reply is shaped in the very act of giving it, and a verbal exchange is a
succession of such replies, each formed from what the previous voice offered. In principle the two are one practice.
In practice they have separate names and separate teachers, and they are studied in separate buildings.

A transcript resembles a page that carries only the tune and its chords. The words are present, and the phrasing is
left to whoever reads them; the pause before an answer disappears, along with the voice that rises as conviction
gathers and the softening that invites a reply. Those who write sound down for others to perform met this difficulty
long ago, and the score is their answer. A score is multimodal. The eye reads it, the inner ear hears it, and the
hands and breath of the players carry it into the room. Recense gives speech a little of that depth: each word lit as
it is voiced, the melody and liaison drawn over the line, and the translation beside it.

**Learning in concert.** Speech reaches us through the ear, yet it is shaped by the face and the breath, and it is
understood best when more of those channels are open. Seeing a speaker makes speech in noise far easier to follow.
Training that engages several senses tends to produce faster and more effective learning than training through one.
Words spoken aloud are remembered better than words read silently, and subtitles in the language being sung have
helped television audiences improve their reading. This is how I learned to play: a piece entered through my eyes and
my ears and came to rest at last in my hands. Recense offers the same route into a language. The ear follows the
voice, the eye follows the light across each word, and the learner's own voice joins them.

<sub>Sumby and Pollack (1954) studied seeing speech in noise, and McGurk and MacDonald (1976) showed sight changing
what is heard. Shams and Seitz (2008) reviewed the benefits of training through several senses. MacLeod and colleagues
(2010) studied memory for words read aloud, and Kothari and colleagues (2004) studied same-language subtitles on
Indian television.</sub>

**Kinship.** Recense belongs to a long line of attempts to hear speech as melody. Aniruddh Patel's research suggests
that language and melody draw on overlapping resources in the brain for making sense of structure as it unfolds. The
Brazilian composer and bandleader Hermeto Pascoal spent years transcribing recorded speech and setting it to harmony,
treating a voice on the radio as a melody waiting for its chords. Recense carries the same intuition into the
learning of languages.

The longer essay, on improvisation, the measure of a gift, a score for speech and a shared tuning for the world's ideas,
is [the preface](../docs/recense-preface.md).

## Long-term goals
Each goal comes from one design philosophy, zero friction: nothing stands between a thought, a sound or a glance and
what it's for. Each project meets a different kind of friction, so each carries its own part of that philosophy.

- **The strip: friction of attention.** Time, the next event and the Mac's state sit where the eye already rests; it
  costs near nothing while idle, takes no focus, and asks for nothing until reached for.
- **Recense: friction of understanding.** Language is learned through more than one sense at once; Recense joins the
  voice you hear, the words in their own script, a light that moves with the syllables as sung, the melody and liaison
  drawn over the line, and a translation beside it. Every recording heard, transcribed and translated on this Mac, in
  its language and its script, so a song or a sermon becomes a lesson without leaving it.
- **Continuity: friction of place.** The same transcript, corrections and timing wherever a recording plays; in Recense,
  in Gallery, on iPhone and iPad. A correction made once teaches every surface.
- **Draftpad: friction of capture.** One endless `draftpad.md`, reached by a swipe, so a thought lands before it fades;
  topics instead of files, so nothing needs a name first.
- **The menu-bar hider and the desk tools: friction of clutter.** Menu-bar icons tucked until wanted; notes (Obsidian, Notability,
  files), calendar and a right-edge widget panel inside Recense, so the tools come to the work instead of the reverse.

## Menu-bar hider
`strip/hider.swift`. Recense adds two dividers to the menu bar: `[ always-hidden icons ] ┆ [ hidden icons ] │ [ visible icons ] [ system icons ]`.
⌘-drag icons left of `│` (`┃`) to hide them, or left of `┆` to always hide them (macOS has no API to move other apps' icons).
- **Peek (hidden tier only, in the free space right of the strip):** click the chevron (`‹‹`) in the strip or rest the pointer on it for 0.5 s; rest the pointer on the divider's spot in the menu bar for 0.5 s (`Peek on Hover (0.5 s)`); choose Recense's app menu ▸ Menu-Bar Hider ▸ Show Hidden Icons; or run `./recense show-icons`.
- **Always-hidden tier:** ⌥-click the strip's chevron (`‹‹`), choose Recense's app menu ▸ Menu-Bar Hider ▸ Reveal Always-Hidden Icons, or run `./recense show-all-icons`.
- **No strip overlap (A2):** when collapsed, the divider's width is refined by bracket + binary search to within 2 pt of macOS's left menu-bar cutoff (and re-fitted on app switch), leaving less than one icon's width so hidden icons are pushed completely off-screen and never drift into the center under the strip's controls. During peek, `┆` stays collapsed so shown icons appear only in the free space right of the strip (`strip.maxX .. screen.maxX`).

No key or modifier reveals them: ⌘-Tab, ⌘C and ⌘-drag leave the menu bar as it is (D23; until 2026-11-06 a held ⌘
did, and the icons took the strip's place). They tuck away
3 s after the pointer leaves the menu bar, or 8 s after Show Hidden Icons if the pointer never comes up. Recense's
app menu ▸ Menu-Bar Hider ▸ Hide Menu-Bar Icons turns it off: no status item, monitors or timers.

## Features

**Paste as Text** (FEAT-26): copy a file in Finder, then press ⌘⌥V in any app, or choose Recense → Paste as Text. Text and code paste as a fenced block (up to 50 KB). PDFs paste their text, and scanned PDFs are read with on-device OCR. Images are also read with on-device OCR. A zip pastes the list of files inside it and is never unpacked or deleted. Your clipboard is put back afterwards. Everything runs offline.
The app icon is Gallery's petal cloud (the iOS app's icon, `mobile/ios/Assets.xcassets/AppIcon.appiconset`),
drawn in macOS's rounded-square shape into `AppIcon.icns`, so Recense looks the same on the Mac, iPhone and iPad.

### Haptics (`strip/haptics.swift`)
One cue vocabulary of at most 4 named cues across Recense (B1):
- `tick`: step, detent, layer step, page step, or word onset (`.alignment` / actuator ID `15`).
- `thud`: home value, first/last boundary, or pin (`.levelChange` / actuator ID `5`).
- `edge`: zone boundary or edge crossing (`.levelChange` / actuator ID `3`).
- `open`: rest-hold console or surface open (`.generic` / actuator ID `16`).
- **Settings › Haptics (`Off · Calm · Full`):** reachable in `Recense ▸ Settings ▸ Haptics`, `Recense ▸ Haptics`, or `./recense haptics-off | haptics-calm | haptics-full | haptics-settings`. `Calm` fires only zone and edge cues (`thud`, `edge`, `open`) and silences step `tick`s for sensory load.
- **Direct trackpad actuator spike (`MTActuatorActuate`):** opt-in (`Direct Trackpad Actuator (Experimental)`), with public `NSHapticFeedbackManager` as default and automatic fallback. Proven: `MTDeviceGetMTActuator` + `MTActuatorOpen` + `MTActuatorActuate` resolve in `MultitouchSupport.framework` on macOS 27.2 and return `0` (`kIOReturnSuccess`) on the Force Touch trackpad for actuation IDs `[1, 3, 5, 15, 16]`; subjective tactile difference vs. `NSHapticFeedbackManager` is untested pending owner trackpad feel.

- **Global gesture navigation feel (B2):** three-finger vertical swipes emit a `tick` per layer stepped (`hidden → Essentials → Drafting`) and a `thud` at the first and last layer boundaries; two-finger horizontal paging across the Essentials row (`Essentials → DEVONthink hub → Notebook → Media`) emits a `tick` per page stepped and a `thud` when landing on or pulling past the first or last page. Every finger displacement is measured strictly from where the fingers land (`GestureNavHaptics.relativeDisplacements`), never from the screen side or hand (ambidextrous).
- **The console without home bars & one global speed (B3, spec B9c–d):** holding two fingers still for 0.5 s opens the invisible console (`open` cue). Moving up or down steps through invisible zones measured from where the fingers landed; each boundary ticks (`tick` in Full, `edge` in Calm), and the tick count tells you where you are. Moving sideways changes the value through detents (`tick`), with a `thud` at the home value (`1×` speed, `100 %` level, `0` flat/semitones/off/neutral). Lifting the fingers keeps the value. Progressive disclosure starts with 2 zones (`Speed`, `Level`); `Tone`, `Key`, `Space`, and `Voice` unlock in `Settings › Haptics`. Speed is one global setting across Recense (`0.5×, 0.75×, 1×, 1.25×, 1.5×, 2×`), with an explicit notice when `Music.app` (which cannot change rate) is active; existing home-bar controls stay as the visible twins.
- **Visual-delay remap (`Settings › Cue timing`, B4):** adjusts the offset between the karaoke light and its haptic/audio cue over `−100…+260 ms`. Defaults to `+50 ms` (the light leads and the cue follows at `+50 ms`), persists in `UserDefaults`, and every cue reads it (`Haptics.cueTimingOffsetMs` / `Haptics.effectiveCueTimestamp(forLightTimestamp:)`).
- **Text to haptics on the Cadence light's clock (B5, spec B10b):** modes `Off · Emphasis · Words · Rhythm` sit in a `Text Haptics` menu right beside `Show Captions for This Track` (and in `Settings › Haptics`), with the plain note `"felt only while a finger rests on the trackpad"`. `Emphasis` fires only on the closed obligation word list (`must`/`shall` · `may` · `must not`/`shall not`). The haptic score (`TextHapticScore`) is computed once per episode and cached beside `features.json` as `<key>.haptics.json`.
- **Over-the-ear obligation audio textures (C2, spec B10d):** `SoundEngine` (`strip/soundengine.swift`) shapes each obligation word's duration with one of three textures: a **presence lift** (`+3.5 dB` @ 1 kHz, `+2.5 dB` @ 5 kHz) on `must`/`shall`, a **slight stereo widening** (`+18 %` room mix) on `may`, and a **low thump** (`+4.5 dB` @ 160 Hz, `−1.0 dB` @ 5 kHz) on `must not`/`shall not`. No binaural beats (`SoundEngine.usesBinauralBeats == false`).

### Layers
Three fingers up move through the strip's layers: hidden → **Essentials** → **Drafting**. Three fingers down close
the panel from any layer. Moving the pointer off the panel never closes it: once down, it waits for the swipe.
- **Essentials:** time and date (it doesn't take keyboard focus), batteries (a bolt while charging), and four icons
  between them; recorder, Recense and others, glowing on hover. The upcoming event name in both the resting strip
  (`RestStrip.eventLine`) and the Essentials agenda (`CalendarView.nextTitle`) shares one marquee view
  (`MarqueeTextView`, A3): when a title doesn't fit, it pauses 1.5 s at the start and loops seamlessly at 30 pt/s with
  softly faded edges and no `"…"`, without restarting on the 1 s refresh; short names stay still. With Reduce Motion on,
  it stays still and exposes the full title in its tooltip, VoiceOver, and on hover or click (popover). Two fingers page
  through essentials → DEVONthink hub → notebook (Obsidian).
- **Drafting:** the layer where Draftpad runs; one endless `draftpad.md` in the Obsidian vault, paged by topic, with
  cursor memory. An edit from the iPhone or iPad that lands while you type here is merged in, never overwritten:
  each save merges the last version, yours and the file's by line; if both changed the same lines, yours stays in
  `draftpad.md` and the other device's goes beside it as `draftpad (other device <date time>).md` (`notesync.swift`;
  a second one in the same minute gets " 2", never replacing the first). Load and save are the iPad's own rule
  (`../shared/draftpadfile.swift`, BUG-29): a note iCloud can't hand over now (evicted, offline) opens blank and is
  never written over; what you type waits in `~/Library/Application Support/Recense/` and is added after the note once
  it reads; a save that fails is tried again and never counts as done. Ink (`draftpad.ink.json`) is merged, not
  overwritten: strokes drawn on the iPad are unioned into the page before the Mac writes.
  - **New pages go on top of `draftpad.md`** (D4, safe version). Nothing reorders the file: the strip shows its
    pages bottom-up, so the page it adds at its newest end lands at the top of the file.
  - **Editor: new / classic.** The layer can host the new editor (the CodeMirror core, `editor/dist/editor.html`) in
    a web view instead of the classic strip. Switch with `./recense editor-new` and `./recense editor-classic`, the
    Topic menu, or right-click in the pad. Classic is the default. The new editor never writes the file itself:
    every save goes through the same merge (`notesync.swift`). Until the core is merged, a plain stand-in page with
    the same bridge runs instead (`editorhost.swift`). In the new editor, right-click → New Topic on Top.
  - **Pages in the new editor:** one page at a time, as in classic. Two fingers left or ⌘] go one page deeper, two
    fingers right or ⌘[ go back toward the top; both ends bounce. **Pages** in the toolbar switches to one long scroll.
    The first time the pad opens on a new day, today's page starts on top with the cursor in it.
  - **Links and embeds:** ⌘-click a link to open it in the browser. A line holding only `![](file.pdf)` or
    `![](image.png)` shows the PDF or image under it: a path is read from the vault folder, a web link is saved to
    `~/Library/Caches/recense/embeds/` the first time (up to 100 MB) and opens from there offline afterwards.
  - **Newest first, once:** `./recense draftpad-flip` logs the page order it would write; `./recense draftpad-flip-go`
    saves a copy to `~/Recense/backups/draftpad-<time>.md`, then writes `draftpad.md` newest-first through the normal
    save. The pages written on top stay first; each dated page keeps the undated pages under it.
- Edge bars on hover: recorder / volume (left), vault / brightness (right), R2 (bottom).
- Voice → calendar card; Mac ↔ iPhone ↔ iPad handoff.

### Recense
Recense is built for learning by ear, eye and rhythm together; each feature below adds a sense to the same line.
- **Follows what plays** in QuickTime, Music, Safari, Chrome, Firefox and Gallery pages, or opens local files; the
  transcript shows as a see-through strip below the menu bar and notch, or in its own window.
- **Skip Ad** (the window's button, shown only while the followed page plays an ad) skips only the ad: the page
  player's own Skip button when it shows one, otherwise the ad run to its end; the video then plays from where it was
  (0:00 after a pre-roll). The Firefox bridge (`bridge/content.js`) decides what is an ad by the player's own flag
  (`ad-showing` on YouTube): YouTube leaves `ad-created` on its player for the whole video, and that word alone once
  made the video itself an ad, so Skip Ad ran it to its end (fixed in bridge 2.1.16). Test:
  `node strip/bridge/test/ads.test.mjs` (headless Chromium on a page that mimics YouTube's ad states; needs
  `npm install` in `library/` for Playwright).
- **Hears** on this Mac: Apple SpeechAnalyzer for each system language (corrections teach it), the open ears
  (Omnilingual ASR) for the rest, and the canon for recited texts. A song is heard in one script (Amharic in Ge'ez,
  not the Arabic letters the open ears drift into), and lines heard again keep the song's language.
  The engine itself (models, hearing, word times) is shared with the iPhone and iPad (`../shared/speechcore.swift`).
  Every stretch is heard after 0.5 s of silence: DictationTranscriber (Vietnamese) heard nothing ("RecogFailed") when
  the voice began in a stretch's first instant, which a two-minute stretch cut mid-sentence does (measured 11-08).
  A corrected line keeps a typed space before `! ? ; :` (French writes `fini !`); the same rule as Gallery.
  When the open ears name a recording's language, Apple's ears for the listener's own languages hear it too and the
  surest is kept (an English lesson they named Arabic came out empty); a correction leaves unchanged words on the voice.
- **Translates** on this Mac with Apple's Translation framework, so the meaning sits beside the sound.
- **Two ways of reading** (M switches). Follow puts the original above and the translation below; a band of light
  crosses each word as it is spoken and the matching translated word at the same moment (read for the moment the frame
  reaches the screen, one refresh after it's drawn: `frameLead`, 11-10), so the light keeps its
  direction even where word order doubles back. Learn keeps the original ahead to read and say along with, and lets
  a phrase turn into its translation once it has been heard.
- **Learns from being corrected:** a word a correction introduces joins that language's glossary, which shapes what
  is heard afterward; Reset Line to Auto restores the automatic version.
- **Songs:** published lyrics (LRCLIB, then Genius) are chosen by what was actually sung and fitted to the voice; when
  none match, the screen shows what was heard, since an honest transcript serves a learner better than a confident
  mistake. A track with no voice shows ♪ INSTRUMENTAL.
- **Lyrics are looked up for music only**, 30 s to 20 min long: an item played in Music, kept in the Music folder, or
  heard as music by Apple's sound classifier in 30 s from its middle (once per item, kept with its transcript; a title
  alone counts only when nothing could be heard). Speech asks nothing. A song costs at most 2 LRCLIB requests: one exact
  lookup by artist, title, album and length, then one search. Genius, by the words sung, is asked only about a
  confirmed song, with one search and one lookup. Requests name Recense in their User-Agent, honour Retry-After on 429
  and 5xx (at most 30 s, 3 tries), and a failed network is asked again next time. A miss is asked again after 30 days
  or under a new title. Found lyrics count as the song's only within 2 s of its length, or once the singing matches
  them.
- **Knows a recording it has heard:** the same piece from a video site, a podcast feed or a file on disk is recognised
  by an acoustic fingerprint and reuses its transcript.
  The fingerprint lives in `../shared/fingerprint.swift`, one copy for the Mac and the iPhone and iPad. Its
  `locateLive` places the last 15-20 s of live sound in a known recording to within 32 ms, so the phone can light a
  transcript in time with sound tapped from another app (trusted once two calls in a row agree within 0.1 s).
- **Lights the words as sung:** syllables heard from the vocal stem (Demucs), words hung on them, unsung words left
  dark, held notes held, each syllable swept at its sung speed; the eye follows the voice instead of reading ahead.
  Word timing by ear in the editor's toolbar: the word loops, Start and End are tapped as it is sung (two fingers on a
  mark fine-tune it), the light follows the voice's syllables inside them, and Same in repeats times a chorus at once.
  The panel is drawn as Gallery's editor at the Mac's scale: the line, its words as chips (yellow once timed), Start
  and End as cards (the name in blue above the time), then Stop · Auto · Same in N repeats in blue.
  While a line is edited the window stretches down: the lines playing keep the top, the editor is a pane under
  them, and the home bar stays at the foot with all it does (as in Gallery's player).
  Under Start and End, the Light draws how the word fills: drag it up or down for faster or slower at first, slide
  along it as the word plays (or draw it, stopped) to trace it, double-click for the voice; a trace made in Gallery
  plays the same here.
  A whole stanza by ear, as in Gallery: Whole line loops it, tap its first beat and its last, and it loops between them
  until Use this cadence (or Retry); the words then follow the voice between the beats; Trace it gives each word its
  start, end and fill from the pointer slid along as it is sung; Back to the voice undoes it.
- **Draws the prosody** over the lines: a ghost score with a gold sweep, turquoise liaison ties, chords and sung notes;
  the shape of the sentence becomes visible, which helps where the written word and the spoken one part ways.
- **Reads each script as its readers do:**
  - Written without spaces between words: Chinese, Japanese, Thai, Lao, Khmer, Burmese, Tibetan.
  - Right to left, laid out by the bidi algorithm (Latin names and numbers keep their order): Arabic, Persian, Urdu,
    Hebrew, Syriac, Thaana.
  - Other non-Latin scripts:
    - Europe and Central Asia: Cyrillic (Russian, Ukrainian, Belarusian, Bulgarian, Serbian, Macedonian, Kazakh,
      Kyrgyz, Tajik, Tatar, Bashkir, Mongolian), Greek, Armenian, Georgian, traditional Mongolian.
    - East Asia: Korean (Hangul).
    - South Asia: Devanagari (Hindi, Marathi, Nepali, Sanskrit), Bengali (Bengali, Assamese), Gurmukhi (Punjabi),
      Gujarati, Odia, Tamil, Telugu, Kannada, Malayalam, Sinhala.
    - Africa: Ge'ez (Amharic, Tigrinya), Tifinagh (Tamazight), Coptic.
- **Practice:** loop, A–B and speed for shadowing a line until it sits; edit lines in place (corrections keep the
  voice's timing); rename, download, Retranscribe, Retranslate, transcript and M4B export, share.
- `[Ambient Sounds]` where no voice is heard; no overlay over captions the video already shows.
- **Sound tray:** a native process tap → EQ / Key / Space → limiter chain for each player; vocal / instrumental
  extraction, so the voice can be heard alone or sung over; chord detection.
- Idle backfill separates and measures songs under 15 minutes. A file asked for from Gallery (opened there, or
  Retranscribe) goes before the backfill.
- **Transcripts live in `~/Recense/keep/`** (D19; `keephome.swift`).
  - It holds each item's transcript, corrections, translations and features (`<key>.v2.json`, `.edits.json`,
    `.tr.<lang>.json`, `.features.json`).
  - Nothing there is ever swept. With the network off, a transcript opens from there.
  - R2's `keep/<key>/` mirrors it when R2 is set up.
  - `~/Library/Caches/recense/` keeps media only.
  - Read order: `~/Recense/keep` → the cache (only until the move below is verified) → R2's `keep/`.
  - At launch, any transcript still in the cache is copied over, checked by SHA-256, and only then removed from the
    cache. The launch log line starts `keep:`.
  - A copy that can't be made stays in the cache.
  - Two different versions: the newer one is kept; the older goes to `~/Recense/keep/.replaced/`.
  - `~/Recense/keep/.migrated-from-caches` records when the move was complete.
- **⏯ (the strip's play button, `pause.circle` / `play.circle` like QuickTime's menu-bar control, CC On/Off):** plays and pauses Recense's loaded piece, however long its player has
  been quiet. The system's ⏯ key goes out only with nothing loaded, or from the menu: Recense → Play/Pause Other Apps.
- **💡 Side Quest (the lightbulb left of the mic, Recense's own `lightbulb` symbol):** say a side quest, check it, and it
  goes into Calendar. While it listens, the bulb becomes a waveform.

### Library › Music (FEAT-07 P0, 2026-11-15)
Recense menu › **Library…** opens the same Library as the iPhone; tap **Music**. You get every track in `Recense/library/Music`.
- **Play / Pause:** the capsule on each row (it plays in QuickTime; Recense's window follows it with the transcript). It shows a pause sign while that track plays.
- **Loop:** in the row's ··· menu once the track plays. The capsule shows ⟲1 while it's on.
- **Rename…:** in the ··· menu. The file is renamed and its extension kept, and the next Carry sync renames it on every paired device.
- **Delete:** slide the row **left → right**, or ··· › Delete. The track goes to `Recense/trash/` and can be restored.

- **Transcript before sound (FEAT-16, T-0095).** A spoken piece whose transcript isn't whole yet is held: the player Recense follows is
  paused (again if you press play) and the window says "Loading transcript… N%". When the transcript is whole the player starts, so words
  and sound never drift. Songs, finished transcripts and failed ones are not held. Log line: `transcript gate`. Check: `recense selftest`.

## Layout

Recense lives in `strip/` of the one repo, `~/Developer/recense` (the folders beside it are on [the front page](../README.md)).

```
strip/
  app.swift          the strip, panels, gestures, Draftpad (formerly sill.swift)
  ../shared/notesync.swift   Draftpad's file sync: 3-way merge, coordinated iCloud reads and writes (recense selftest)
  ../shared/draftpadfile.swift   Draftpad's load and save of draftpad.md and its ink, shared with iOS (BUG-29)
  editorhost.swift   the new editor's web view host and its bridge; the page order for new pages on top
  recense.swift      Recense: players, transcripts, light, editor, export
  keephome.swift     where transcripts live (~/Recense/keep), the move out of the cache (recense selftest)
  soundengine.swift  process tap and EQ/Key/Space chain
  appear.swift       the app ear: any app's sound, transcribed live on this Mac (recense hear-app, recense selftest); also an iPhone's AirPlay cast, heard as "AirPlay" (macOS AirPlay Receiver on)
  cadence.swift      the karaoke light's timing
  prosody.swift      prosody notation
  speech.swift       on-device transcription (SpeechAnalyzer): the Mac's choices (open ears, canon, lexicon)
  speechcore.swift   link to ../shared/speechcore.swift: the engine both apps hear with (models, hearing, word times)
  fingerprint.swift  link to ../shared/fingerprint.swift: the acoustic fingerprint both apps place sound with (recense selftest)
  openears.swift     the open ears (ears/omni.py)
  canon.swift        recited texts (canon/*.json)
  voiceprint.swift   voice matching
  handoff.swift      Mac ↔ iPhone ↔ iPad handoff
  hider.swift        the menu-bar hider
  ears/omni.py       the open ears' worker (Omnilingual ASR)
  canon/             recited texts (Pali, Sanskrit) and tools/mkcanon.py
  homebar/           the home-bar host page
  bridge/            the Firefox bridge (reports the playing media, runs the window's controls, Skip Ad); test/ads.test.mjs
  Sources/recense/   links to the files above for the Swift package
  build.sh, Package.swift, scripts/, launchagent/
```

Recense's other folders stay at the repo root: `datasets/French/` (hello-pronunciation; media stay private on R2),
`reference/` (read-only sources: draftpad, pomo), `docs/` (architecture, decisions, design renders, beside the shared
plan), `export/` (project description, north star, decisions) and `.claude/CLAUDE.md` (instructions for Claude Code).

## Build and run

```
cd ~/Developer/recense/strip
zsh build.sh                              # builds /Applications/Recense.app and ./recense
./recense &                               # opens the time view
zsh scripts/install-launchagent.sh        # start at login, and again after a crash (status | remove)
zsh scripts/install-autoupdate.sh         # rebuild within 5 min of a push to main (status | remove)
```
- When `shared/ShowsKit` gains or loses a file, `build.sh` cleans its build folder first (the native build system keeps
  a package's file list; 11-07). It says "ShowsKit files changed: clean build".

What a build or a tool leaves in `strip/` stays on this Mac and out of git: `.build-log.txt`, the `./recense`
launcher (build.sh writes both), `_CodeSignature/` and wrangler's `.wrangler/` cache.

**Deploy from anywhere.** A push to `main` (from a phone or cloud session) reaches this Mac on its own:
`scripts/autoupdate.sh` runs every 5 minutes, fast-forwards the repo when `main` has new commits (in the main checkout only, never a worktree; never over
local edits), runs `build.sh` here so the app keeps this Mac's signature and its permissions, and relaunches Recense if it
was running. Log: `~/Library/Logs/recense-autoupdate.log`.

`build.sh` copies Gallery's shared client code from `../library/src/client` (`homebar.js`, `homebar.css`, `keylabel.js`, `room.js`, `prosody.js`,
`prosogram.js`) into the bundle, and stops if one is missing. With Apple's Command Line Tools 27.2 unpacked in `../.toolchain` it builds against the
macOS 27 SDK, which on-device hearing needs.

## Commands

`./recense up | down | pad | time | show | hide | toggle | quit | status | background | editor-new | editor-classic | show-icons | draftpad-flip | draftpad-flip-go | wing-left | wing-right | wing-close | words-sooner-on | words-sooner-off`

`selftest` runs the checks that need no running copy, network or permissions, and exits 1 if any fails: measuring audio
too short for one 10 ms frame (it crashed Recense while idle on 11-03 and 11-04), that the hider watches no key or
modifier event (so ⌘-Tab, ⌘C and ⌘-drag can't reveal its icons), and the lyrics lookups against a stand-in LRCLIB and Genius that count requests: 50
songs, talks and ambiguous titles (at most 2 requests a song, none for speech), the waits on 429 and 503, no network,
the User-Agent, the 2 s rule, the 30-day recheck and Genius's one search and one get; Draftpad's merge; and the editor
host: the page order round-trips the file byte for byte, new pages land on top, text reaches the page intact; the wings: three-finger sideways swipes fed with made-up trackpad frames (the open/tuck sequence below) and the two
panels' mirrored places; the handwriting reader (Vision, on device) reading a hand-lettered French line; and the page
library (expired pages archived once, the playlists file round trip, odd sidecar names refused); and Recense what you
typed (typed sentences as Lines with their language, the target language rule, the lens schemas, `Recensed/<id>.json`
kept inside the vault, the power check, the `Line` → ShowsKit `TranscriptLine` mapping).

`status` prints `time`, `pad`, `hidden` or `not running`. Show-type commands launch Recense if it isn't running;
`background` launches it hidden (the login item uses this).
`show-icons` shows the menu-bar hider's hidden icons (launching Recense hidden first if it isn't running).
`wing-left` / `wing-right` open a wing panel, `wing-close` closes both.

`hear-app [app] [--seconds N] [--lang en|fr|vi] [--out file.json]` taps one app's sound (Safari through WebKit's
GPU process) and transcribes it on this Mac, printing words as they come; `--out` saves them with their times.
When several running processes share the name, it hears the newest one and prints which pid it chose.
In the window, words show as soon as the ears guess them, drawn dim, and turn solid where the final words land; a guess
leaves 2 s after its last word. The careful transcriber hears by default, for the most exact final words, the transcript that is kept, studied and exported.
Recense's menu ▸ Show Words Sooner (Less Accurate), or `./recense words-sooner-on` / `words-sooner-off`, adds a quick
second transcriber (Apple's fast results) on the same analyzer for the guesses; `hear-app --sooner` does the same.
The ear takes the output device as its clock only when it has no microphone, so a headset's mic stays out of it.
`--split` (measuring only) gives the quick one its own analyzer. Sororité through afplay, two clean runs each (11-11, this M1):
- careful alone, the default: first text 4.7 to 5.3 s after the word (median), in 11.4 s batches; finals 86 and 88 words matched, WER 50 and 51 %; CPU 11 %
- Show Words Sooner: first text 0.6 s (median), p95 1.05 s; finals 74 and 76 matched, WER 57 and 55 %; CPU 12 %
- `--split`: first text 0.9 to 1.0 s with stalls, p95 13 to 15 s; finals 83 and 87 matched, WER 51 and 52 %; CPU 21 %
`--out` also records `seen`, each word with the moment it first showed, for measuring first-text lag.

`RECENSE_INSTANCE=<name>` runs a separate copy of a build beside the installed one (its own lock, command channel and
state file), for trying a build without replacing Recense.app: point it at a scratch vault with `DRAFTPAD=` and send it
commands with the same variable set, e.g. `RECENSE_INSTANCE=try .build-sdk27/release/recense wing-right`.

## Wings

Draftpad's wings (the widget cards: Preview, Player, Agenda, iPhone Mirroring, …) open in two floating panels at
Notification Center's place: the right one just below the menu bar, 8 pt in from the right edge, 360 pt wide, as tall
as its cards; the left one its exact mirror. They float above every window and on every Space. Each card sits on
frosted glass with the desktop showing between; no title and no × (VoiceOver still names each wing). Layout, pins and
cards are one state across both panels and the editor (`draftpad.wings.json`, version 2; a version 1 file loads as it was).

- **Show in wing…:** the pill at the top dissolves into a typing field; type to filter the widgets, apps and the
  Recense card that aren't in this wing yet; Return or a tap adds one. With nothing playing, the wing opens with the
  field already open and takes the keys (the panel becomes key only then, and hands focus back when the field or the
  wing closes). Esc or ✕ turns it back into the pill. Reduce Motion: a plain swap.
- **Cards:** swipe left (or two fingers left on the trackpad) to **Remove**, with Undo for 5 s; swipe right to **Pin**
  (pinned cards stay on top with a pin mark; swipe right again to unpin). Hold a card and drag to reorder. Each card's
  ··· menu has the same: Move up, Move down, Move to the other wing, Pin / Unpin, Size, Remove.
- **Card heights:** each card is 1–4 rows tall (S, M, L, XL), so neighbours line up; drag the bar on its bottom edge
  (it snaps per row) or pick Size in its ··· menu. More rows show more (the Agenda one event per row, Recense more of its
  line); the text never scales and what doesn't fit scrolls inside the card. Saved per card (`draftpad.wings.json` v3).

- **Open (no Recense window needed):** three fingers right → left brings out the right wing; three fingers left → right
  brings out the left wing; both can stay open. Also: Recense menu or the editor's right-click menu → Show Left Wing /
  Show Right Wing; `./recense wing-left|wing-right`; the editor's voice moves ("left wing", "right wing", "both wings").
- **Tuck in:** with both open, three fingers starting mid-trackpad toward the left tuck the left wing; then three fingers
  toward the right tuck the right wing. Also: slide (or press) the grabber at the top of the wing's inner edge toward
  the screen edge; Recense menu → Hide Left / Right Wing; right-click the panel → Close.
- **Locked open:** a wing stays out until you tuck it in, whatever Recense does (sleep, pulled up, hidden). No Esc or
  outside click closes it. No long holds.
- **Recense in the wings:** the first card on each side shows the current line (original and translation); the panel
  widens (360–560 pt) so two lines fit comfortably.
- **Cards that work:** Preview opens a PDF or image (Choose an exhibit…, or drop a file); Player plays a video or
  recording (Choose…, or drop) and "cite this moment" inserts a timestamped citation.
- One motion only: slide in from the edge; with Reduce Motion on, the panel just appears.
- Built in `wingpanels.swift` (panels, glass, swipe sequence `wingSwipe`) and `editor/src/wingpanel.js` (the same bundled
  page in wings-only mode); the swipe is `trackThree` in `app.swift`.

## Gestures and controls

| Where | Two fingers right → left | Two fingers left → right |
| --- | --- | --- |
| Essentials | Back toward the first panel | Next panel |
| Drafting | Back toward the first topic; leaving a blank topic deletes it | Next topic; past the last, a new dated topic |

| Do this | Result |
| --- | --- |
| Three fingers up | One layer up |
| Three fingers down | Close the panel (from Drafting too) |
| Click the time | Open Draftpad |
| Click the small time at the top of Draftpad | Back to the time view |
| Ctrl+Option+Space | Toggle Draftpad |
| Esc or ⌘W (in Draftpad) | Hide |
| ⌘] / ⌘[ | Next / previous topic |
| Swipe up | Summon Recense; dismiss the Recense card |
| Two fingers held still | Time ruler on where the media is |
| Three fingers right → left / left → right | Right / left wing out (from mid-trackpad, toward an open wing: tuck it in) |

Three-finger swipes use Apple's private MultitouchSupport framework (no permission prompt; experimental, so a macOS
update could break it). Turn macOS's own three-finger swipes off in System Settings → Trackpad → More Gestures.
`RECENSE_GESTURES=0 ./recense &` disables them. Swipes are logged to `~/Library/Logs/recense.log` when Recense runs
from the login item. BetterTouchTool fallback: `zsh ~/Developer/recense/strip/scripts/gesture.sh up` (or `down`, `hide`, `quit`).

### Recorder: controls on the strip (2026-11-17)
- The mic icon on the strip opens the recorder's presets (microphone, camera, screen). That panel is for before only.
- Start, and the panel folds up at once. The strip then shows, where the date was: a red **● time**,
  then three red buttons: **cancel** (files go to the Trash), **pause / go on** and **end** (stop and save).
- The mic icon hides while recording, so the panel can't hang down mid-recording.
- While recording (and while a warning shows), the strip stays awake without hovering, so the time is always in view.
- Order: cancel, pause, end: the two that finish a recording are never side by side.
- Problems show in orange in the same slot (**No audio**, **No screen**, then **Nothing saved** after stop).

### Recorder: no silent recordings (T-0149, 2026-11-17)
- If the microphone, computer audio or screen stream fails to start, stops mid-way, or writes nothing for 5 s,
  the timer turns orange and reads **Audio not recording** or **Screen not recording** instead of counting on.
- If stopping finds nothing on disk, the strip says **Nothing was saved** rather than going quietly back to Ready.

## Roadmap
Idle efficiency (file watchers over polling, clock ticks only while visible); strip colours and panels; Notes in Recense
(Obsidian, Notability read-only, filesystem); a health chip from `views/health.json`; and a right-edge widget panel starting with Find My.

The root README's open questions touch this list directly: the timers above, the private gesture framework, and
what isn't sized yet for the always-on peer. [See them there](../README.md).

## Draftpad page library (2026-11-08)
`shared/draftpadlibrary.swift` (linked into `Sources/recense/`, also built into iOS) answers the editor page:
`draftpad.playlists.json` and `draftpad.pages.json` beside the note, expired pages appended to
`<vault>/Draftpad expired/<YYYY-MM>.md` before the page removes them, and read-aloud with each word reported back.
The calendar sheet's **Don't add** is kept as `x:<id>` in `draftpad.events.json`; a revised place and notes reach the
event. See `editor/README.md` for what you see.

## Recense what you typed (2026-11-08, M1)
`shared/recensetext.swift` answers Draftpad's Recense layer on both apps, on the device only: the Source lens through
Apple's Translation (installed languages), Gist and IRAC from Apple's on-device model (guided generation; each field's
guide is in the schema, built at run time because the Command Line Tools ship no macro plugins; greedy, 700 tokens out
at most, so it can't overflow the 4,096-token context), and `<vault>/Recensed/<id>.json` for saved pages. While you
write, the wing panels' Recense card shows your text's lens line (`WingPanels.setTypedLine`).
M2 (Gist per paragraph): the Gist schema has one field per paragraph (`p1`…`pN`, six per call) after the title, then
the page gist; every line is asked for in the section's language by name, a line mixing two languages is flagged
(`isMixed`), and the section's other-language sentences go to the page translated, for the citation check.
**Check the real app without touching your notes:** `strip/recense draftpad-check <folder>` runs the installed editor,
this file and the on-device model on a test page in an off-screen window with throwaway storage, checks the Gist shape,
one language per line, per-sentence Source, Chapters, the wing card, then Retell, Ask and Reapply, and saves a PNG per
view (about 4 min on the M1: ~20 s a section for Gist + IRAC, ~25–30 s a section for each further lens).
M2 slice 2: Retell (plain line + the other language, given the sentences' own translation as its term reference), Ask
(question + answer) and Reapply (rule + new facts that turn on its elements, never the outcome) are asked for only when
the page opens that lens. Statutes, articles and case names quoted from the notes, and the glossary's terms
(`RecenseText.glossary`, set from `Glossary` on the Mac), keep their own language inside a line.
`shared/transcript.swift` now holds `Line`, `Chapter`, `LensLine` and the language rules (`scriptOf`,
`phraseLanguage`, `dominantLanguage`, `needsTranslation`, `languageName`), moved out of `recense.swift` so iOS builds
the same copy. The timed word (`Word`, `Pin`, `Syl`) is ShowsKit's (`shared/ShowsKit/Sources/ShowsKit/Word.swift`,
FEAT-04): one type for the Mac, iOS Listen and the transcript view, timed in seconds into the recording. The Mac's
handoff to the phone (`handoff.swift`) now sends each sentence's words and where its player is (`clock`, `rate`).

## Downloads (`recense download`)
Keeps media in `~/Recense/downloads/` as audio, audio+video or video (yt-dlp + ffmpeg; direct links fetched as they are), with `manifest.json` (source, mode, size, codecs, SHA-256, subtitles).
- `recense download <link> [audio|av|video] [--max 720] [--section 1:00-2:30] [--no-subs]`
- Offline first: a link already downloaded in that mode is served from the device. With no connection the request is queued (exit 75) and `recense download --queue` runs it later.
- Downloads resume and retry (8 parallel fragments); title, chapters and cover are embedded; the site's en/vi/fr captions are saved beside the file as `.vtt`.
- Anything an iPhone can't play (VP9, AV1) is converted to H.264/AAC MP4 on the Mac's hardware encoder.
- Pulltube (optional): set its download folder to `~/Recense/downloads/Pulltube`; `recense download --adopt` records what it saves (and anything put in `downloads/` by Finder or AirDrop). `--pulltube <link>` opens a link in it.
- In the home bar's menu: Download the played audio (as before), Download audio + video, Download the video, Open in Pulltube.
- The queue runs by itself whenever the Mac gains a connection (and at launch).
- Other devices ask through `downloads/.queue/` (one JSON file per request). Code: `shared/mediadownload.swift`.

## Homes and carry (`recense carry`)
One layout on every device (the folder contract; code `shared/homes.swift`, spec `docs/specs/FEAT-06-homes-folder-contract.md`).
Mac: `~/Recense/`. iPhone and iPad: `Documents/Recense/`, visible in the Files app.
- The homes: `library/Music/`, `library/Study/`, `library/Legal/`, `library/Audiobooks/`, `library/Listen/`, `downloads/`, `trash/`. Recense creates them at launch.
- Each home keeps `.recense-index.json`: one entry per file with path, size, SHA-256, when it landed, which device recorded it, tags. Plain files beside it, nothing in a database.
- Taking a file in moves it (never copies), never overwrites (`song 2.m4a`, as Finder does), and hashes it as it lands. Audio goes to Music, an `.m4b` to Audiobooks, a PDF or document to Study, anything else (a web page too) to `downloads/`, which the app labels **Inbox** (owner 2026-11-15; the folder keeps its name).
- **Nothing is deleted unless you say so:** Remove moves the file to `trash/` and records where it came from, so it can be put back; Delete forever works only inside `trash/`.
- `recense homes` lists the homes and how many files each has recorded; `recense homes adopt` records everything dropped into them by Finder, the Files app or AirDrop.
- The terminal commands run in place (`status`, `hide`, `quit`, `selftest`, `hear-app`, `carry`, `download`, `homes`); every other verb opens the app.
- `recense carry verify` writes `~/Recense/.carry/manifest.jsonl`: one line per file across every home (home, path, size, mtime, SHA-256, device) — what this Mac holds, readable by any tool.
- `recense carry move --to <folder>` copies every home there, verifies every SHA-256 after the copy, writes `carry-receipt-<when>.json`, and **leaves the source in place**. That is the exit: any folder works (a USB stick, iCloud Drive, the WebDAV mount), no Recense needed to read it.
- Local only: filesystem, CryptoKit and MultipeerConnectivity (device to device), no internet at any point.
- Automatic carry: a paired device that connects, a change inside a home (2 s after it stops), or the iPhone/iPad app coming to the front starts a carry. Only the homes count: writes to `keep/` (Gallery transcripts) or `.carry/` never start one (T-0091).

## Global destinations: screenshots, trash (FEAT-25)
One place per device for a screenshot and for anything removed from inside Recense, same shape as
Downloads above: `~/Recense/screenshots/` and `~/Recense/trash/`, each with `manifest.json` (source,
size, SHA-256). Code: `shared/destinations.swift`.
- `Destinations.adopt(.screenshots)` records any file dropped into `screenshots/` the manifest doesn't
  know yet (nothing is ever deleted by this call).
- `Destinations.trash(_:source:)` moves a file into `trash/` instead of destroying it, and records it.
- Redirecting where macOS actually saves a screenshot is a separate, one-time Mac setting, not code:
  `defaults write com.apple.screencapture location ~/Recense/screenshots && killall SystemUIServer`
  (undo with `defaults delete com.apple.screencapture location`). Not run automatically — see
  `docs/specs/FEAT-25-global-destination.md`.
- iPhone/iPad: no OS redirect exists for where a screenshot saves (always Photos); the sweep side of
  this (a Photos-library observer that adopts new screenshots) and the Safari-Downloads side (needs a
  writable File Provider, not built yet) are still open — see the spec's P2/P3.
- Test (no device needed): `swiftc -O shared/destinations.swift mobile/ios/Tests/destinations/main.swift -o "$TMPDIR/destinations" && "$TMPDIR/destinations"`.

## SSH (Topic › Connect To)
The terminal connects to any host in `~/Recense/ssh/hosts.json` (made from `~/.ssh/config` the first time; Topic › Connect To › Edit Hosts…). Each host lists routes tried in order: `lan` (same network, no internet), `tailscale`, `tunnel` (Cloudflare Tunnel through cloudflared, only when installed); the first that answers in 3 s is used. When ssh ends, the terminal goes back to its own session. Code: `shared/sshhosts.swift`.

## Bose Bridge (Recense › Bose Bridge)
One pair of headphones, many sources, no Bose app and no network. Spec: `docs/specs/FEAT-15-bose-bridge.md`.
- **The route follows what you plug in:** whatever just arrived wins (USB-C audio, then Bluetooth, then the
  headphone cable, then wired earbuds). A choice you already made in Sound settings is left alone until the next
  plug or unplug.
- **When the headphones drop** (charging, switched off, out of range), the built-in speakers are muted so nothing
  plays out loud, and the menu says what to plug in **for your exact pair**. A launch with no headphones mutes nothing.
- **Battery** is read every 5 minutes, only while the Bose is on Bluetooth, and only when macOS reports it.
- **Full-quality stereo:** on Bluetooth the default input stays the Mac's own microphone, so the link never drops
  to call-quality audio.
- **Two At Once:** two or more pieces play together through the one stream the headphones can receive — each with
  its own place in its own file, its own volume, and its own ear (left / both / right). Also
  `recense symphonies <file> <file>`: the first in the left ear, the second in the right.
- **Where I Left Off:** every paused piece leaves a seat in `library/Listen/seats.jsonl` (append-only, one line per
  save, newest wins). Carry moves that file between devices, so the iPhone's place in a piece is offered here.
- What the headphones themselves will not do, whatever we write: hold more than two devices (the QC Ultra 2nd Gen
  caps at two as well), play two streams at once, or change ANC and headphone EQ without Bose's own protocol.
  The bridge moves all of that to this side of the link. `strip/bosebridge.swift`, `shared/bosebridge.swift`.
