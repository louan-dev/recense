# sill

Sill is a quiet strip at the top centre of the Mac's screen; time, date, batteries, a recorder, Draftpad and Recense,
the listening surface where a recording becomes something to learn from: heard, read, seen lit and felt in its rhythm.
One app, one process, no Dock icon. It works offline; Gallery's Worker and R2 are an optional cloud side for sharing
transcripts and files.

Its menu-bar hider (Nook) is part of Sill, not an app of its own.

## Why this exists
Sill began as a kindness to an old MacBook: an M1 with 8 GB of memory and a nearly full disk, gasping under files that
only ever grow. Instead of buying a new machine, I wanted to give this one room to breathe again, with one small app
in place of a handful of always-on ones, and with my words, recordings and drafts kept on hardware I can see.

It is also my attempt to make learning feel like a playground. Long walls of text lose me; a song I love, a sermon in
my parents' language, a film watched twice do not. Recense grew out of what has actually worked for me: hearing a
voice while its words light up as they are sung, seeing the melody drawn over the line, reading the translation beside
it. If it helps me, I hope it can help the people dear to me, people for whom English is a wall, English speakers
curious about a culture or a city they don't yet know, and people whose bodies or minds learn better through more than
one sense. I didn't find a tool like that without a company in the middle, so I am building one, slowly, and handing
it on. Everyday media is full of quiet lessons; Sill tries to catch them in the moment they pass by.

## Long-term goals
Each goal comes from one design philosophy, zero friction: nothing stands between a thought, a sound or a glance and
what it's for. Each project meets a different kind of friction, so each carries its own part of that philosophy.

- **The strip: friction of attention.** Time, the next event and the Mac's state sit where the eye already rests; it
  costs near nothing while idle, takes no focus, and asks for nothing until reached for.
- **Recense: friction of understanding.** Language is learned through more than one sense at once; Recense joins the
  voice you hear, the words in their own script, a light that moves with the syllables as sung, the melody and liaison
  drawn over the line, and a translation beside it. Every recording heard, transcribed and translated on this Mac, in
  its language and its script, so a song or a sermon becomes a lesson without leaving it.
- **Continuity: friction of place.** The same transcript, corrections and timing wherever a recording plays; in Sill,
  in Gallery, on iPhone and iPad. A correction made once teaches every surface.
- **Draftpad: friction of capture.** One endless `draftpad.md`, reached by a swipe, so a thought lands before it fades;
  topics instead of files, so nothing needs a name first.
- **Nook and the desk tools: friction of clutter.** Menu-bar icons tucked until wanted; notes (Obsidian, Notability,
  files), calendar and a right-edge widget panel inside Sill, so the tools come to the work instead of the reverse.

## Menu-bar hider (Nook, inside Sill)
`sill/nook.swift`. Sill adds `[ always-hidden ] ┆ [ hidden ] │ ‹›` to the menu bar; ⌘-drag icons left of │ to hide them,
left of ┆ to always hide them (macOS has no API to move other apps' icons). Click ‹› to show or hide; hovering ‹› peeks
at the hidden tier only; ⌥-click (or right-click ▸ Reveal Always-Hidden Items) shows both; holding ⌘ shows both dividers
for arranging. Everything tucks back after the auto-hide delay (3 s). Right-click ‹› (or Sill's app menu ▸ Menu-Bar
Hider) for auto-hide, Peek on Hover, per-app Rules (hide all, show all, show selection) and the off switch; off means no
status items, monitors or timers. Nook.app is retired; it opens with Sill.

## Features

### Layers
Three fingers up and down move through the strip's layers: hidden → **Essentials** → **Drafting**.
- **Essentials:** time and date (it doesn't take keyboard focus), batteries (a bolt while charging), and four icons
  between them; recorder, Recense and others, glowing on hover. Two fingers page through essentials → DEVONthink hub →
  notebook (Obsidian).
- **Drafting:** the layer where Draftpad runs; one endless `draftpad.md` in the Obsidian vault, paged by topic, with
  cursor memory.
- Edge bars on hover: recorder / volume (left), vault / brightness (right), R2 (bottom).
- Voice → calendar card; Mac ↔ iPhone ↔ iPad handoff.

### Recense
Recense is built for learning by ear, eye and rhythm together; each feature below adds a sense to the same line.
- **Follows what plays** in QuickTime, Music, Safari, Chrome, Firefox and Gallery pages, or opens local files; the
  transcript shows as a see-through strip below the menu bar and notch, or in its own window.
- **Hears** on this Mac: Apple SpeechAnalyzer for each system language (corrections teach it), the open ears
  (Omnilingual ASR) for the rest, and the canon for recited texts.
- **Translates** on this Mac with Apple's Translation framework, so the meaning sits beside the sound.
- **Lights the words as sung:** syllables heard from the vocal stem (Demucs), words hung on them, unsung words left
  dark, held notes held, each syllable swept at its sung speed; the eye follows the voice instead of reading ahead.
  Word timing by ear in the editor's toolbar.
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
- Idle backfill separates and measures songs under 15 minutes. Transcripts cache locally and mirror to Gallery's
  `keep/<key>/` when available.

## Layout

```
sill/
  sill/              the app
    sill.swift         the strip, panels, gestures, Draftpad
    recense.swift      Recense: players, transcripts, light, editor, export
    soundengine.swift  process tap and EQ/Key/Space chain
    cadence.swift      the karaoke light's timing
    prosody.swift      prosody notation
    speech.swift       on-device transcription (SpeechAnalyzer)
    openears.swift     the open ears (ears/omni.py)
    canon.swift        recited texts (canon/*.json)
    voiceprint.swift   voice matching
    handoff.swift      Mac ↔ iPhone ↔ iPad handoff
    homebar/           the home-bar host page
    Sources/sill/      links to the files above for the Swift package
    build.sh, Package.swift, scripts/, launchagent/
  reference/         read-only sources (draftpad, pomo)
  docs/              architecture, decisions, design renders
  export/            project description, north star, decisions
  notes/             task tables
  .claude/CLAUDE.md  instructions for Claude Code sessions
```

## Build and run

```
cd ~/Developer/sill/sill
zsh build.sh                              # builds /Applications/Sill.app and ./sill
./sill &                                  # opens the time view
zsh scripts/install-launchagent.sh        # start at login (status | remove)
```

`build.sh` copies Gallery's shared client code (`homebar.js`, `homebar.css`, `keylabel.js`, `room.js`, `prosody.js`,
`prosogram.js`) into the bundle. With Apple's Command Line Tools 27.2 unpacked in `../.toolchain` it builds against the
macOS 27 SDK, which on-device hearing needs.

## Commands

`./sill up | down | pad | time | show | hide | toggle | quit | status | background`

`status` prints `time`, `pad`, `hidden` or `not running`. Show-type commands launch Sill if it isn't running;
`background` launches it hidden (the login item uses this).

## Gestures and controls

| Where | Two fingers right → left | Two fingers left → right |
| --- | --- | --- |
| Essentials | Back toward the first panel | Next panel |
| Drafting | Back toward the first topic; leaving a blank topic deletes it | Next topic; past the last, a new dated topic |

| Do this | Result |
| --- | --- |
| Three fingers up / down | One layer up / down |
| Click the time | Open Draftpad |
| Click the small time at the top of Draftpad | Back to the time view |
| Ctrl+Option+Space | Toggle Draftpad |
| Esc or ⌘W (in Draftpad) | Hide |
| ⌘] / ⌘[ | Next / previous topic |
| Swipe up | Summon Sill; dismiss the Recense card |
| Two fingers held still | Time ruler on where the media is |

Three-finger swipes use Apple's private MultitouchSupport framework (no permission prompt; experimental, so a macOS
update could break it). Turn macOS's own three-finger swipes off in System Settings → Trackpad → More Gestures.
`SILL_GESTURES=0 ./sill &` disables them. Swipes are logged to `~/Library/Logs/sill.log` when Sill runs from the login
item. BetterTouchTool fallback: `zsh ~/Developer/sill/sill/scripts/gesture.sh up` (or `down`, `hide`, `quit`).

## Roadmap
Idle efficiency (file watchers over polling, clock ticks only while visible); strip colours and panels; Notes in Sill
(Obsidian, Notability read-only, filesystem); a health chip from `views/health.json`; Nook folded into Sill (hidden
and deep tiers, hover to peek, behind a setting); and a right-edge widget panel starting with Find My.
