# Recense Reference

> Archived draft from October 2026, when Recense was its own app and heard through Groq and Whisper. Today Recense lives inside Recense and hears on this Mac; see the [README](../README.md) for what is current.

This page holds the exact workings of Recense along with every key and setting. The story behind it lives in [the preface](recense-preface.md), and the overview lives in [the README](README.md).

## Why standard subtitles and lyrics fail

- **Code-switching inside a sentence.** Typical automatic speech recognition (ASR) commits to one language per request. When a singer moves from Spanish to English mid-breath, or from Dari to English, the rest gets mangled or quietly *translated* into the first language. Whisper sometimes writes the same stretch twice, once translated and once as sung.
- **A disconnected wall of text.** Sentence-level captions can't show which sung sound maps to which English word, especially when the two languages order words differently.
- **Hallucinations and drift.** Whisper writes a phantom "Thank you for watching" over a guitar solo, and captions lag after you seek or change speed.

## How Recense solves it: only exact sync, no guessing

**What it follows.** Recense follows QuickTime Player, Music, Safari and Chromium browsers (Chrome, Arc, Brave, Edge, Vivaldi, Opera, Chromium) through Apple Events. It follows Firefox through the **Recense Bridge** extension. In browsers, any audible `<audio>` or `<video>` on any page counts, not just a list of known sites.

> Apple Events isn't zero-config. macOS asks once for Automation permission per app. Safari and Chrome also need **Allow JavaScript from Apple Events** turned on. In Safari it's in the Develop menu, and in Chrome it's under View › Developer.

**What it does with the audio:**

1. It gets the audio ahead of playback. A local file is read directly. A stream is downloaded, pulled with `yt-dlp` (YouTube, HLS, most video sites), or sent by the Firefox extension when only the page can read it.
2. For songs, it isolates the vocals with Demucs.
3. It transcribes with word timestamps (Groq's `whisper-large-v3`) in two-minute pieces, and starts each request where the voice starts.
4. It tightens Whisper's word times against the audio's loudness in 10 ms frames (`refine`). A word after a pause starts where the voice actually starts, not over the silence before it, and a word before a pause ends where the voice stops. On a vocal stem every word is tightened, and a "word" with no voice under it is dropped: Whisper heard it in silence.
5. It checks lyrics against what was actually sung, then times them to the voice.
6. It translates each line into English with a word-by-word alignment.
7. It follows the player's reported position. Ticks are smoothed so report jitter never makes the light twitch backwards. Seeks, pauses and rate changes snap it to the new position immediately. If your setup runs consistently early or late, `SYNC_OFFSET` shifts it.

## Two modes: Follow and Learn

A segmented switch in the top-right corner of the window (it appears on hover) toggles between the two modes. You can also press **`M`**.

### Follow: the read-along overlay

The original language sits on top and English sits below it. A light wipes continuously across each original word over exactly the time it's spoken, and across its English counterpart at the same time:

- A word brightens about 200 ms before its onset, so your eye arrives before your ear.
- At the onset, a gold attack pulse flashes and decays exponentially (`ink()`), so the rhythm reads as pulses rather than a cursor. The decay scales with the word: a clipped syllable gets a crisp flash, a held vowel a longer glow.
- In Arabic and Hebrew script the wipe runs right to left.
- Everything runs in media time, so the motion scales with playback speed on its own.

English and the original rarely share a word order. `englishBeats()` gives each English word the time of the words it translates. It then pools adjacent violators (PAVA) so the English beat times always move forward. The highlight never runs backward, even when the mapping crosses.

### Learn: syntactic morphing

In Learn mode, the original language is always what's coming, so you can read ahead and pronounce along. About 0.3 s (`turnTime`) after a phrase of three or four words is heard, a soft `.destinationIn` gradient sweeps across it. The words dissolve and their English surfaces in the same slot, in the direction you read. Nothing slides or reflows.

`phrases()` decides where to cut with dynamic programming. It prefers to cut at pauses of 0.25 s or more, at punctuation and at clause ends. It avoids leaving a short word that leans on the next one (*le, de, il, und*), and avoids ending an English phrase on *the* or *of*. Lines take turns between two places, one above the other (`learningPlaces`). The end of a thought stays put, in English, while the next line plays.

### The two modes and a drifting mind

This is built for ADHD minds whose curiosity drifts into another language. You can follow a Persian protest song or a Neapolitan street interview without leaving the language you're actually studying. Follow mode keeps that language anchored on screen. Learn mode feeds the drift without letting it take over. You stay rooted and you still get to wander.

It's also for linguists. When words are aligned and lit together, you can *see* how languages connect: cognates, word order flipping mid-clause, a borrowing sitting in the middle of a line. It's a model of language you see with your eyes, hear with your ears and say with your own voice.

## Daily use

### Learn languages with music and podcasts

- **Vocal isolation.** Demucs `htdemucs` (`--two-stems=vocals`) runs on the GPU (MPS) and falls back to the CPU, so Whisper hears the singer instead of the drums.
- **Lyrics verified by content, not by title.** Candidates come from LRCLIB by title and artist, within 10 s of the track's length. The winner must have at least 35% of the heard words land in its lines. If nothing passes, Recense searches Genius for the words actually sung (`lyricsBySung`) and pulls those songs' lyrics from LRCLIB. If nothing passes after that, you see what was heard rather than a confident wrong answer.
- **Lines cut at breaths.** Unpunctuated lyrics (Persian, as Whisper writes it) are split at the singer's longest pause of 0.2 s or more, again and again (`breathSplit`), so each line is a line of the song rather than a word count, and translates as a thought instead of a fragment.
- **Choruses and gaps.** A chorus written once and sung three times shows three times. A lyric line Whisper missed is laid over the unmatched singing at the voice's own rhythm (`layOver`). Suspect stretches, meaning phrases in a language the lyrics aren't in or phrases that match no lyric line, are re-transcribed in pieces of 25 s or less (`suspects`). That way Whisper decides their language afresh.
- **No phantom gratitude.** On a song heard without lyrics, Whisper's stock filler is dropped ("Thank you.", "1, 2, 3", lone words), along with subtitle-credit hallucinations. A track that turns out to have no words at all shows a breathing **♪ INSTRUMENTAL** instead of inventing some.

### A–B loop language practice: the Home Bar

This is the part I use most.

At rest, the Home Bar is a single stroke along the bottom of the window. It turns blue while Track loop is on and shows beads at its ends for A and B (hollow while A–B is off). Nothing on the bar asks for your attention until you reach for it.

- **Hover** to show **Track loop** (`L`) and **A–B** (`A` sets A, `B` sets B).
- **Click** to open Speed: 0.5×, 0.75×, 1×, 1.25×, 1.5×, 2×. Step through them with `<` and `>`. When the speed isn't 1×, the value hangs under the stroke as a quiet reminder.
- **Press and hold** (or drag) to turn the stroke into a ruler for the whole track, with the playhead where you are. Slide sideways to move and slide up to zoom in: 1×, 4×, 16×, 64×. Near A and B, the playhead is pulled in like a magnet.
- **Rest two fingers** on the trackpad over the bar, and the media pauses and the ruler opens: the frame freezes under your hand. Swipe sideways to scrub and slide up to zoom. When you lift your fingers, it plays on.

This is how I practice. I find a phrase, set A just before the breath and B just after the last syllable, and drop the speed to 0.75×. I loop until the vowels sit right, then go back to 1×. Language is a physical skill, and like any instrument, it gets learned in short loops.

### Obsidian transcript and audiobook exporter

**Export Transcript…** (`⌘E` in the menu-bar menu) exports the whole source, start to end, into the Obsidian vault in iCloud Drive, so the notes open on every device. You choose one of two formats:

- **Markdown:** YAML frontmatter (title, source, duration, export time, and the percentage transcribed if it isn't finished). Each line is timestamped, with its English as a blockquote beneath it.
- **Audiobook:** `ffmpeg` cuts the audio into chapters of about ten minutes, each cut at the gap before the nearest line, and hands them to **Audiobook Builder**, which builds the `.m4b`. Recense watches for the finished file, gives it the export's name and deletes the chapter files. Next to it, Recense writes a word-timed `.vtt` (karaoke cues, with the English under each line) and a Markdown note that embeds the audiobook.

[`viewer/read-along.html`](viewer/read-along.html) plays the `.m4b` with its `.vtt` on any device. Open both files and tap any word to seek to it.

## Under the hood

### Language fusion

Whisper names one language per request, by sound. NaturalLanguage names a language by spelling, per phrase. Each one is blind where the other sees.

- `NLLanguageRecognizer` runs over sliding three-word windows, so a line that switches mid-breath reports both languages (`lineLanguages`).
- Words are tagged with the language Whisper heard them in when their script matches. Suspect stretches are sent back as short, separate requests so the sound gets a fresh vote.
- For Arabic-script languages (Arabic, Persian, Dari, Urdu), spelling can't settle the question. NaturalLanguage confidently reads Dari as Urdu. Wherever the spelling can't tell, the sound decides (`spellingTells`, `phraseLanguage`).
- When Whisper writes a stretch twice (translated into its own language, and as sung in another script), `withoutTranslation` drops the translated copy.

### One recording, many sources

The same song arrives from YouTube, a podcast feed and a local file, and each source has its own address. Recense fingerprints the audio with Haitsma–Kalker (the Philips scheme). It uses 33 log-spaced bands from 300 to 2000 Hz, because 33 bands give 32 neighboring differences, which make one 32-bit word every 128 ms. The FFT runs on vDSP, at four phase offsets. Re-encoding, level and EQ barely move the bits, and a different recording flips half of them.

When a recording matches, Recense computes the time `shift` between sources and reuses the existing transcript rather than spending a day's quota again. Translations are also remembered line by line in `translations.json`.

### Translation models

Translation rotates across Groq's free models. When one hits its limit, the next takes over immediately:

```
qwen/qwen3.8-27b → openai/gpt-oss-20b → openai/gpt-oss-120b
```

(`TRANSLATE_MODEL` goes first in that list.) When every model is out for the day, or the network is down, macOS 15+ translates on the device with Apple's `TranslationSession`. These lines are marked as drafts (plainer, and without word alignment), and a model redoes them once quota returns.

### Storage that cleans up after a forgetful human

- **Media** (downloaded audio, a video's soundtrack, vocal stems) stays on the Mac only while it's in use. After that it moves to `tmp/` in an R2 bucket, or is deleted outright if R2 isn't configured. It can always be fetched or separated again.
- **Transcripts** cost a day's quota to remake, so they're mirrored to `keep/`, which never expires, and merged back on launch.
- **Corrections** (`<key>.edits.json`) and the glossary (`glossary.json`) are mirrored to `keep/` too, and fetched back with their transcript.
- **`tuneExpiry`** reruns daily. It measures how fast media has been arriving and sets the bucket's lifecycle rule to the longest stay that keeps everything under 80% of R2's 10 GB free tier, capped at 90 days.

It's my origin story, automated: storage that remembers to forget, so I don't have to.

## Keyboard shortcuts

| Key | Action |
|---|---|
| `M` | Switch between Follow and Learn |
| `E` | Correct the line on screen (also double-click it, or right-click → Reset Line to Auto) |
| `Space` | Play / pause |
| `←` / `→` | Skip back / forward 10 s |
| `L` | Track loop on / off |
| `A` / `B` | Set loop point A / B |
| `<` / `>` (also `,` `.` and `[` `]`) | Speed down / up |
| `Esc` | Fold the Home Bar |
| `⌘M` | Minimize / show subtitles (menu-bar menu) |
| `⌘E` | Export transcript (menu-bar menu) |

The keys work while the Recense window is focused. Everything except `M` needs a player to be followed. Clicking the subtitles also plays or pauses.

A correction pauses the player while you type: `Return` keeps it, `Esc` cancels, and an empty line hides one Whisper made up. Corrections sit on top of the transcript, so redos and pipeline upgrades never overwrite them. The words a correction adds go into that language's glossary, which becomes Whisper's prompt for everything transcribed afterwards.

## Getting started

### Requirements

- macOS 14.2 or later. macOS 15+ is recommended, since that's what the on-device translation fallback needs.
- Apple Silicon. `build.sh` targets `arm64`, and Demucs runs on MPS.
- A [Groq](https://console.groq.com) API key. The free tier works.

**Optional:**

- `yt-dlp` and `ffmpeg` from Homebrew (`/opt/homebrew/bin` or `/usr/local/bin`). `yt-dlp` handles streams, and `ffmpeg` is needed for audiobook chapters.
- Demucs at `~/.local/share/recense/demucs/bin/demucs`, for example as a virtualenv there. Without it, songs are transcribed from the full mix.
- [Audiobook Builder](https://www.splasm.com/audiobookbuilder/) in `/Applications`, for `.m4b` export.
- A free Genius API token, to find lyrics from the words sung.

```bash
brew install yt-dlp ffmpeg
```

```bash
python3 -m venv ~/.local/share/recense/demucs && ~/.local/share/recense/demucs/bin/pip install demucs
```

### Build

`build.sh` compiles `main.swift` and signs the app with a stable, self-signed identity named `Louan (recense)`. Because the signature doesn't change between rebuilds, macOS keeps the Apple Events permissions. Create your own self-signed code-signing certificate in Keychain Access, then change the name in `build.sh` to match it.

```bash
./build.sh && open Recense.app
```

Recense adds itself as a login item the first time it runs, so it's simply always there. You can turn that off in its menu.

### Firefox

Install the Recense Bridge from `extension/`. Either load `manifest.json` as a temporary add-on from `about:debugging`, or sign it as an unlisted add-on with `extension/sign.sh` and install the `.xpi` it leaves in `extension/signed/`. The extension talks only to `127.0.0.1:47123`.

### Configuration: `~/.config/recense/config`

Write one `KEY=VALUE` per line. Lines starting with `#` are ignored, and environment variables override the file.

| Key | Default | What it does |
|---|---|---|
| `GROQ_API_KEY` | (required) | Groq key for transcription and translation |
| `WHISPER_MODEL` | `whisper-large-v3` | Transcription model (`whisper-large-v3-turbo` is ignored in favor of the default) |
| `TRANSLATE_MODEL` | `qwen/qwen3.8-27b` | First model in the translation rotation |
| `API_BASE` | `https://api.groq.com/openai/v1` | OpenAI-compatible endpoint |
| `WHISPER_LANGUAGE` | (empty: detect) | Forces Whisper's language (ISO code) |
| `SYNC_OFFSET` | `0` | Seconds, scaled by playback rate. Positive values light words earlier |
| `SUBTITLE_DELAY` | `8` | Parsed, but currently has no effect |
| `GENIUS_TOKEN` | (empty) | Enables lyrics search by the words sung |
| `R2_ACCOUNT_ID` | (empty) | Cloudflare R2 account for offsite storage |
| `R2_ACCESS_KEY_ID` | (empty) | R2 access key |
| `R2_SECRET_ACCESS_KEY` | (empty) | R2 secret |
| `R2_BUCKET` | `recense-tmp` | Bucket holding `tmp/` and `keep/` |

> **When captions seem to "drop," check the log first.** Groq's free tier has *daily* quotas (tokens, requests, and audio seconds per day). Once a quota runs out, Recense pauses that work until the quota resets rather than hammering the API. The usual sign is a run of lines with no English, or no new lines at all. `~/Library/Logs/recense.log` says which quota ran out and for how long.

### Command line

These are for development and debugging. Each one runs and exits without opening the app.

```
Recense --replay <cache.v2.json> [lyrics.txt]   # re-run lyric choice and timing offline (no Groq calls) and score it
Recense --lyrics-for "<title>" <seconds>        # the lyrics candidates a title finds
Recense --match <audio> <audio>…                # is each later file the first one's recording, and at what offset
Recense --identify <key> <audio>                # file audio in the library, or alias it to an existing transcript
Recense --backfill                              # file every earlier transcript in the library now
```

If you run the app with `RECENSE_RAW=1`, every Whisper reply is also kept (`<key>.raw.json`). With the vocal stem beside it, `--replay` then replays the whole pipeline, second pass included. `RECENSE_CACHE` points a run at a separate cache and keeps it off R2.

`tests/regress.sh` compiles a fresh binary and replays every track that ever went wrong, as listed in `tests/tracks.tsv`. It fails if a track drops below its floor for words in the song or lyric lines shown, or if it shows a line in a language the track isn't sung in.

## Repository structure

```
main.swift              the whole app
Info.plist              bundle metadata (LSUIElement, macOS 14.2 minimum, Apple Events usage)
build.sh                compile and sign Recense.app
viewer/read-along.html  plays an exported .m4b with its word-timed .vtt; tap a word to seek
extension/              Recense Bridge for Firefox
  manifest.json  content.js  background.js  popup.html  popup.js  sign.sh
tests/
  regress.sh            replay-based regression suite
  tracks.tsv            tracks, floors and expected languages
  fixtures/             captured transcripts and lyrics (git-ignored: they're the songs' words)
```

## Status

Recense is a private pilot, distributed as a direct download. It isn't on the Mac App Store and won't be in its current form. The things that make it work conflict with the App Store sandbox: driving other apps with Apple Events, running JavaScript in browser tabs, launching `yt-dlp`, `ffmpeg` and Demucs as separate processes, and writing into another app's iCloud container.
