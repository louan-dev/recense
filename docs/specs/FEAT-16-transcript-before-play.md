# FEAT-16 · The transcript is complete before the audio plays

From: T-0095 · Owner 2026-11-16 · Status: `[ ]`

## Rule
Pressing play on a piece that has no finished transcript shows one load indicator.
Nothing plays, and nothing scrolls, until the whole transcript is made, stored and loaded.
Then the audio starts with the transcript time-synced to the word (FEAT-04 content clock) and autoscroll on.
Model: Apple Podcasts (spinner, then audio and transcript together).

## Facts (code read 2026-11-16)
- Mac: `Episode.transcribeLoop()` (strip/recense.swift ~3867) transcribes "the chunk being played first, then onward":
  playback and transcription run together. This is the behavior to remove for the play path.
- iOS: live captions (`mobile/HostApp/iOS/Listen.swift`, `Captions.swift`) are for outside audio (S0); stored shows use `ShowsKit` Transcript view.
- A finished transcript is `Cache.read(key)?.complete == true` (recense.swift ~3293).

## Phases (each gate = its check)
- P1 gate: pure function `canPlay(transcriptComplete:)`; selftest: false while any chunk is undone, true once `complete`. Mac strip.
- P2 gate: Mac play path shows the spinner, runs the transcription in whole-file order (no play-first chunking), starts audio only when `complete`; selftest + screenshot of the spinner.
- P3 gate: iPhone and iPad (stored shows): same rule and spinner; checked on the device via iPhone Mirroring.
- P4 gate: autoscroll and word sync start at the first frame of audio; no drift after 10 min.

## Not covered (stays live by nature)
Live captions of outside audio (Listen S0) have no file to finish; unchanged.

## Risk and open choice for the owner
An hour of audio with no stored transcript may take minutes before it plays. The rule as written has no skip.
Recommended: show progress (percent), keep the rule strict, and let a transcript already stored play at once.
