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

## Hard limit: outside audio
Recense cannot hold back another app's audio. In the recording the audio is Apple Podcasts', so "do not play until complete" cannot apply there.
Nearest version that works now: when the piece is in Recense's own library, Recense plays it and the rule holds.
For outside audio: Recense shows the spinner and `--:--` and stays silent about sync until its transcript is whole (no half-synced scrolling).
Route to the full version: a one-tap "Play in Recense" that fetches the episode into the library, transcribes it, then plays it.
Untested: whether iOS lets Recense pause another app (assumed no).

## Risk and open choice for the owner
An hour of audio with no stored transcript may take minutes before it plays. The rule as written has no skip.
Recommended: show progress (percent), keep the rule strict, and let a transcript already stored play at once.
