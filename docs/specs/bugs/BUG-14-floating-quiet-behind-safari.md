# BUG-14 · Floating window rests while Safari plays

From: T-0074 (owner, 2026-11-14: "plan a fix", with two screenshots: YouTube playing in Safari, no captions) ·
Device: iPhone 12 Pro Max · Status: `[~]` (building)

## What the owner sees
YouTube plays in Safari with the broadcast on (red time pill), and no floating captions come up.

## Red (what the code shows)
- The iPhone's `listen.floatLog`, 11-14 18:40:44–18:41:10: "behind quiet open", then "rest: thin strip". The
  window opened, but Recense read Safari's sound as quiet, so it rested.
- `Floating.playing`: while the broadcast hears, the broadcast's last real sound (`State.sound`) decides (T-0041).
  A sound date older than `soundGone` reads as quiet, however old it is. A date left by an earlier broadcast reads
  as quiet for good.
- `SampleHandler.processSampleBuffer` calls `noteSound` only on the SpeechAnalyzer path. The SFSpeechRecognizer
  fallback never writes `State.sound`.
- The fallback runs for 24 h after a broadcast that ended without `broadcastFinished` (`analyzerFailed`). An app
  install during a broadcast ends it that way. 11-14 had several installs. `listen.checks` shows no new SpeechAuto
  language check after 17:55:27, which fits the fallback (not confirmed: the engine was not logged).

## Green (the fix)
- `Floating.playing(… broadcastAgo:)`: a sound older than the running broadcast (`soundAgo > broadcastAgo`, from
  `State.b`) is no sound from this broadcast. Then iOS's flag decides, as with no broadcast.
- `processSampleBuffer`: every engine notes real sound. On the fallback the buffer is converted only when a note
  is due (at most 4 times a second), so the extension's 50 MB limit is not pressed.
- The float log's focus line names the engine (`engine=SpeechAnalyzer…` or `engine=SFSpeechRecognizer`), so a device
  run shows which one heard.

## Invariants (tested: `mobile/ios/Tests/floating/main.swift`)
- Flag on, hearing, sound from an earlier broadcast (sound 600 s ago, broadcast 20 s ago): playing.
- Flag on, hearing, this broadcast's sound 2 s ago: quiet (T-0041 stays).
- Flag on, hearing, this broadcast's sound 0.1 s ago: playing.
- Flag on, hearing, no broadcast start known: as before (the sound decides).
- Flag off: quiet, whatever the sound says.

## Not in this fix
- An install that ends a broadcast still counts as a SpeechAnalyzer failure (24 h on the fallback). Telling the two
  apart is its own change.

## Device check (owner, phone in hand)
- Start the broadcast, play a YouTube video in Safari, leave Recense.
- Pass: the float log shows "behind playing open" with an `engine=` on the focus line, and full captions show.
