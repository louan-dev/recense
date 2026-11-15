# BUG-10 · The floating window is black while Recense's own player plays

From: T-0069 (owner, 2026-11-14: "floating window is black while audio plays") · Device: iPhone 12 Pro Max ·
Status: `[~]` (fixed, owner's device check owed)

## What the owner sees
A file plays in Recense's player. They leave Recense: the floating window opens, then turns into a thin black
strip and stays black while the audio plays, until it closes 10 minutes later.

## Red (what the code and the phone show)
- `Listener.floatTick` (`mobile/HostApp/iOS/Listen.swift`) decides "playing" from `isOtherAudioPlaying`,
  `secondaryAudioShouldBeSilencedHint` and the broadcast's last sound. iOS never reports an app's own audio as
  "other", so Recense's own player reads as quiet.
- Quiet for `Floating.hideAfter` (0.3 s) behind another app with the window open → `Floating.rest` → the
  near-black strip (`restPicture`, gray 0.06), held until `Floating.stayAwake` (600 s).
- Even awake, `frame()` drew only the broadcast's sentences, never the player's transcript.
- iPhone `listen.floatLog`, 2026-11-14: `17:02:34 rest: thin strip`, `behind quiet open`, then nothing until
  `17:12:34 … hide` (the 600 s limit).
- The two parts fought over one audio session: `NativePlayer.play()` set `.spokenAudio` (does not mix),
  `makePiP()` set `.moviePlayback` + `.mixWithOthers`. After the player had played once, the window's silent
  keep-awake sound ran on a session that does not mix.

## Green (the fix)
- `Floating.playing(flag:hearing:soundAgo:own:)`: Recense's own player playing counts as playing.
- `Listener` draws the window from one source (`shown()`): Recense's player while it plays (or holds a file
  with no broadcast hearing), its transcript lines at the player's time; otherwise the broadcast's sentences.
  Both looks (Follow, Learn) and the stamped-ahead word pictures work unchanged: in the player's case the
  window's clock offset is `wall − player time` instead of the broadcast's lag, so a seek or pause redraws.
- One audio-session rule (`NativePlayer.session(playing:)`): the player takes the sound while it plays (other
  apps pause, as any player); otherwise Recense only mixes under other apps.

## Invariants (tested: `mobile/ios/Tests/floating/main.swift`)
- Own player playing, no other-audio flag, no broadcast → `playing == true`.
- Own player playing behind another app with the window open → never rests (`rest == false`) and never hides.
- Own player paused, no other audio → quiet (rests, then hides, as before).
- The broadcast's rules are unchanged (every earlier case still passes).

## Device check (owner, phone in hand)
Play a file in Recense, leave Recense: the window shows the transcript, the word lit as it is said, the
translation under it when Translate Into is on. Pause: it rests. Play again in Recense, leave: it shows again.
Then a YouTube video with the broadcast on: YouTube keeps playing while the window is up.
