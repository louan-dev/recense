# sill

Sill is a quiet strip at the top centre of the Mac's screen: time, date, batteries, a recorder, Draftpad and Recense,
the listening surface for transcripts, karaoke light and sound. One app, one process, no Dock icon. It works offline;
Gallery's Worker and R2 are an optional cloud side for sharing transcripts and files.

## Long-term outcomes
- One calm surface for time, notes, listening and the Mac's sound, costing near nothing while idle.
- Every recording heard, transcribed and translated on this Mac, in every language and in its own script.
- The same transcript, corrections and timing wherever a recording plays: in Sill, in Gallery, on iPhone and iPad.
- Desk tools inside Sill: notes (Obsidian, Notability, files), calendar, a menu-bar icon hider and a right-edge widget
  panel.

## Features

### The strip
- Time and date (never takes keyboard focus), batteries (a bolt while charging), and four icons between them:
  recorder, Recense and others, glowing on hover.
- Layers by three-finger swipe: hidden → essentials → Draftpad. Essentials pages: essentials → DEVONthink hub →
  notebook (Obsidian).
- Edge bars on hover: recorder / volume (left), vault / brightness (right), R2 (bottom).
- Draftpad: one endless `draftpad.md` in the Obsidian vault, paged by topic, with cursor memory.
- Voice → calendar card; Mac ↔ iPhone ↔ iPad handoff.

### Recense
- Follows what is playing in QuickTime, Music, Safari, Chrome, Firefox and Gallery pages, or opens local files, and
  shows the transcript as a see-through strip below the menu bar and notch, or in its own window.
- Hears on this Mac: Apple SpeechAnalyzer for every system language (corrections teach it), the open ears
  (Omnilingual ASR) for the rest, and the canon for recited texts. Each language in its own script.
- Translates on this Mac with Apple's Translation framework.
- Karaoke light that follows the voice: syllables heard from the vocal stem (Demucs), words hung on them, unsung words
  never lit, held notes held, each syllable swept at its sung speed. Word timing by ear in the editor's toolbar.
- Prosody notation over the lines: a ghost score with a gold sweep, turquoise liaison ties, chords and sung notes.
- Every script laid out correctly:
  - Written without spaces between words: Chinese, Japanese, Thai, Lao, Khmer, Burmese, Tibetan.
  - Right to left, laid out by the bidi algorithm (Latin names and numbers keep their order): Arabic, Persian, Urdu,
    Hebrew, Syriac, Thaana.
  - Other non-Latin scripts:
    - Europe and Central Asia: Cyrillic (Russian, Ukrainian, Belarusian, Bulgarian, Serbian, Macedonian, Kazakh,
      Kyrgyz, Tajik, Tatar, Bashkir, Mongolian), Greek, Armenian, Georgian, traditional Mongolian.
    - East Asia: Korean (Hangul).
    - South Asia: Devanagari (Hindi, Marathi, Nepali, Sanskrit), Bengali (Bengali, Assamese), Gurmukhi (Punjabi),
      Gujarati, Odia, Tamil, Telugu, Kannada, Malayalam, Sinhala.
    - Africa: Ge'ez (Amharic, Tigrinya), Tifinagh (Tamazight), Coptic..
- `[Ambient Sounds]` where no voice is heard; no overlay over captions the video already shows.
- Edit lines in place; corrections keep the voice's timing. Loop, A–B, speed, rename, download, Retranscribe,
  Retranslate, transcript and M4B export, share.
- Sound tray: a native process tap → EQ / Key / Space → limiter chain for every player, vocal / instrumental
  extraction, chord detection.
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
  nook/main.swift    menu-bar hider source, to be folded into Sill
  reference/         read-only sources (draftpad, pomo)
  docs/              architecture, decisions, design renders
  export/            project description, north star, decisions
  notes/             task tables
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
| Draftpad | Back toward the first topic; leaving a blank topic deletes it | Next topic; past the last, a new dated topic |

| Do this | Result |
| --- | --- |
| Three fingers up / down | One layer up / down |
| Click the time | Open the pad |
| Click the small time at the top of the pad | Back to the time view |
| Ctrl+Option+Space | Toggle the pad |
| Esc or ⌘W (in the pad) | Hide |
| ⌘] / ⌘[ | Next / previous topic |
| Swipe up | Summon Sill, dismiss the Recense card |
| Two fingers held still | Time ruler on where the media is |

Three-finger swipes use Apple's private MultitouchSupport framework (no permission prompt, experimental: a macOS
update could break it). Turn macOS's own three-finger swipes off in System Settings → Trackpad → More Gestures.
`SILL_GESTURES=0 ./sill &` disables them. Swipes are logged to `~/Library/Logs/sill.log` when Sill runs from the login
item. BetterTouchTool fallback: `zsh ~/Developer/sill/sill/scripts/gesture.sh up` (or `down`, `hide`, `quit`).

## Roadmap
Idle efficiency (file watchers over polling, clock ticks only while visible), strip colours and panels, Notes in Sill
(Obsidian, Notability read-only, filesystem), a health chip from `views/health.json`, the menu-bar hider (hidden and
always-hidden tiers, hover to peek, behind a setting), and a right-edge widget panel starting with Find My.
