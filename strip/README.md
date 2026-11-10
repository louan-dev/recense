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
`recense/hider.swift`. Recense adds one divider to the menu bar: `[ hidden icons ] │ [ visible icons ] [ system icons ]`.
⌘-drag icons left of │ to hide them (macOS has no API to move other apps' icons). Three ways show │ and the hidden icons:
- the chevron (‹‹) in the strip, right of the batteries: click it, or rest the pointer on it for 0.5 s;
- Recense's app menu ▸ Menu-Bar Hider ▸ Show Hidden Icons;
- `./recense show-icons`.

No key or modifier reveals them: ⌘-Tab, ⌘C and ⌘-drag leave the menu bar as it is (D23; until 2026-11-06 a held ⌘
did, and the icons took the strip's place). Hovering the divider's spot also shows the hidden icons. They tuck away
3 s after the pointer leaves the menu bar, or 8 s after Show Hidden Icons if the pointer never comes up. Recense's
app menu ▸ Menu-Bar Hider ▸ Hide Menu-Bar Icons turns it off: no status item, monitors or timers. The earlier two-tier
version (an always-hidden tier, per-app Rules) is in the history: commit 93e5cb3, and tag `archive/nook-fix-1f871c` for
its macOS 27.2 placement fix.

## Features
The app icon is Gallery's petal cloud (the iOS app's icon, `mobile/ios/Assets.xcassets/AppIcon.appiconset`),
drawn in macOS's rounded-square shape into `AppIcon.icns`, so Recense looks the same on the Mac, iPhone and iPad.

### Layers
Three fingers up move through the strip's layers: hidden → **Essentials** → **Drafting**. Three fingers down close
the panel from any layer. Moving the pointer off the panel never closes it: once down, it waits for the swipe.
- **Essentials:** time and date (it doesn't take keyboard focus), batteries (a bolt while charging), and four icons
  between them; recorder, Recense and others, glowing on hover. Two fingers page through essentials → DEVONthink hub →
  notebook (Obsidian).
- **Drafting:** the layer where Draftpad runs; one endless `draftpad.md` in the Obsidian vault, paged by topic, with
  cursor memory. An edit from the iPhone or iPad that lands while you type here is merged in, never overwritten:
  each save merges the last version, yours and the file's by line; if both changed the same lines, yours stays in
  `draftpad.md` and the other device's goes beside it as `draftpad (other device <date time>).md` (`notesync.swift`).
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
  crosses each word as it is spoken and the matching translated word at the same moment, so the light keeps its
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

## Layout

Recense lives in `strip/` of the one repo, `~/Developer/recense` (the folders beside it are on [the front page](../README.md)).

```
strip/
  app.swift          the strip, panels, gestures, Draftpad (formerly sill.swift)
  ../shared/notesync.swift   Draftpad's file sync: 3-way merge, coordinated iCloud reads and writes (recense selftest)
  editorhost.swift   the new editor's web view host and its bridge; the page order for new pages on top
  recense.swift      Recense: players, transcripts, light, editor, export
  keephome.swift     where transcripts live (~/Recense/keep), the move out of the cache (recense selftest)
  soundengine.swift  process tap and EQ/Key/Space chain
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

`./recense up | down | pad | time | show | hide | toggle | quit | status | background | editor-new | editor-classic | show-icons | draftpad-flip | draftpad-flip-go | wing-left | wing-right | wing-close`

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

## Roadmap
Idle efficiency (file watchers over polling, clock ticks only while visible); strip colours and panels; Notes in Recense
(Obsidian, Notability read-only, filesystem); a health chip from `views/health.json`; and a right-edge widget panel starting with Find My.

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
`shared/transcript.swift` now holds `Word`, `Line`, `Chapter`, `LensLine` and the language rules (`scriptOf`,
`phraseLanguage`, `dominantLanguage`, `needsTranslation`, `languageName`), moved out of `recense.swift` so iOS builds
the same copy.
