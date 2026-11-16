# FEAT-16 · The transcript is complete before the audio plays

From: T-0095 · Owner 2026-11-16 · Status: `[ ]`

## Rule
Pressing play on a piece that has no finished transcript shows one load indicator.
Nothing plays, and nothing scrolls, until the whole transcript is made, stored and loaded.
Then the audio starts with the transcript time-synced to the word (FEAT-04 content clock) and autoscroll on.
Model: Apple Podcasts (spinner, then audio and transcript together).

## Evidence: the owner's media (gallery share QymBYs2S7iPGdAOn4xFS, 2026-11-15)
- `IMG_4208.PNG` = Apple Podcasts, Now Playing: "Loading…" spinner where the transcript goes; the scrubber shows a spinner and `--:--`;
  the transport (15/30, speed, sleep) is already drawn; the transcript button is lit. Nothing scrolls yet.
- Screen recording (8 s) = Recense's caption panel over a Podcasts episode: the pause button shows (audio running) while Recense's
  blue loading dash spins the whole time, so audio is ahead of the transcript. The date line shows empty boxes (missing glyphs): T-0096.

## Evidence: Apple's Podcasts.app bundle (static strings only, no decompiling; behavior below is inferred, not run)
- `PodcastsTranscripts.framework`: transcript text is fetched ahead, not made while playing ("Fetched transcript identifier from MAPI for local
  episode with AdamId…"; it is dropped if that episode "is no longer playing").
- Timed data: `TimedMetadata`, `timedContent`, `createParagraphs(splittingBehavior:)`, `_durationFromPlayerStartTimeToFirstWordTime`.
- Sync gate: `TranscriptSyncingStateObserver`, `_isSyncing`, a `loading` state, `_bridgedUpdateContentUnavailableConfiguration…` (the spinner view).
- Follow: `_activeParagraph`, "scroll to paragraph from reset live tracking": autoscroll follows the active paragraph; a manual scroll
  breaks tracking and a control resets it.
- Search: `TranscriptSearchButton` (floating, own backdrop layer), `_searchRanges`, `_activeSearchRange`, `OFFLINE_SEARCH_TITLE`
  (search is a separate offline-capable mode).
- Lesson to copy: gate = syncing state; paragraph = unit of follow; search = a floating pill. Lesson to beat: Apple's transcript is made on
  their server; ours is made on the device, so the wait is real and must show progress.

## Facts (code read 2026-11-16)
- Mac: `Episode.transcribeLoop()` (strip/recense.swift ~3867) transcribes "the chunk being played first, then onward":
  playback and transcription run together. This is the behavior to remove for the play path.
- iOS: live captions (`mobile/HostApp/iOS/Listen.swift`, `Captions.swift`) are for outside audio (S0); stored shows use `ShowsKit` Transcript view.
- A finished transcript is `Cache.read(key)?.complete == true` (recense.swift ~3293).

## Phases (each gate = its check)
- P1 gate: pure function `canPlay(transcriptComplete:)`; selftest: false while any chunk is undone, true once `complete`. Mac strip.
- P2 gate: Mac play path shows the spinner, runs the transcription in whole-file order (no play-first chunking), starts audio only when `complete`; selftest + screenshot of the spinner.
- P3 gate (coded 11-16; `Ears.gate` selftest in mobile/ios/Tests/ears passes; installed iPhone + iPad; on-device check pending): iPhone and iPad (stored shows): same rule and spinner; checked on the device via iPhone Mirroring.
- P4 (view already follows the playhead with a "Now" reset, Transcript.swift; the gate makes the first frame whole; 10-min drift check pending on device): autoscroll and word sync start at the first frame of audio; no drift after 10 min.

- P5 gate: the FEAT-07 pill (search + scrubber, one pill) on every surface that shows a transcript: Mac strip window,
  iPhone and iPad stored shows, Listen episodes, the web player. Surface list in the spec's table is the check: each gets a screenshot.
  Design stays FEAT-07's; this phase only places it. Follow-reset control (Apple's "reset live tracking") ships with it.

### P5 surfaces (code read 2026-11-16, before coding)
The pill = FEAT-07's: Find (magnifier → find face: field, "2 of 5", ⌃ ⌄, waveform or a 0.35 s hold back) and the scrubber, one pill.
Follow reset = Apple's "reset live tracking": a hand scroll lets go of the voice; one visible control brings it back.

| Surface | Where (file:line) | Pill before P5 | Follow reset before P5 | P5 status |
|---|---|---|---|---|
| iPhone, stored shows (Now Playing) | `shared/ShowsKit/Sources/ShowsKit/Views/NowPlaying.swift:113` → `Views/Transcript.swift:269-280` → `Views/SearchPill.swift` | present (FEAT-07 P2) | "Now" `Transcript.swift:257-265`; ··· Follow the Playhead `:337`; hand scroll detaches `:366-372` | present, no change; device screenshot owed |
| iPad, stored shows | same ShowsKit code as iPhone | present | present | present, no change; iPad screenshot owed |
| Listen episodes (iOS) | `mobile/HostApp/iOS/Listen.swift:1497` (`seek: nil`, no `duration`) | Find face only; no scrubber (another app's audio cannot be moved) | present (same view) | present, no change; Open question below |
| Mac strip window | `strip/recense.swift:997-1209` `RecenseHomeBar` (WKWebView over `strip/homebar/index.html`, which runs Gallery's `library/src/client/homebar.js`) | scrubber only (homebar Time Seeking); no Find | not needed: one line on screen; a scroll turns the drum and plays from the line picked (`recense.swift:1962-1987`), so view and voice never part | to build: Find in `homebar.js` (shared with web) + the lines sent from `recense.swift` |
| Web player (Gallery) | `library/src/client/gallery.js:1751` `Homebar.horizontal`; transcript `showTranscript` `:5017`, whole transcript `openAll` `:5293` | scrubber only (homebar Time Seeking); no Find | none: the whole-transcript sheet re-follows every line turn (`:6107-6117`) | to build: Find in `homebar.js`, hit marks on its ruler, Now in the sheet |

Not a transcript surface: the Mac's ShowsKit Library window (`LibraryShelf`, `Root.swift:162`) has no transcript view of its own.

## Hard limit: outside audio
Recense cannot hold back another app's audio. In the recording the audio is Apple Podcasts', so "do not play until complete" cannot apply there.
Nearest version that works now: when the piece is in Recense's own library, Recense plays it and the rule holds.
For outside audio: Recense shows the spinner and `--:--` and stays silent about sync until its transcript is whole (no half-synced scrolling).
Route to the full version: a one-tap "Play in Recense" that fetches the episode into the library, transcribes it, then plays it.
Untested: whether iOS lets Recense pause another app (assumed no).

## Risk and open choice for the owner
An hour of audio with no stored transcript may take minutes before it plays. The rule as written has no skip.
Recommended: show progress (percent), keep the rule strict, and let a transcript already stored play at once.
