# BUG-09 · No Lock Screen scrubber for Recense's own player on iOS

From: T-0067 (owner, 2026-11-14: "plays but theres no lockscreen scrubber") · Device: iPhone 12 Pro Max ·
Status: `[~]` (fixed, owner's device check owed)

## What the owner sees
A file plays in Recense's player (Library › Shows › Music › Player check). On the Lock Screen there is no
scrubber: no title, no time bar to drag, no skip buttons.

## Red (what the code shows)
`grep -rn "MPNowPlayingInfoCenter\|MPRemoteCommandCenter" mobile/HostApp/iOS shared/ShowsKit` → nothing.
`NativePlayer` (an `AVPlayer`) sets the audio session to `.playback` and plays, but never tells iOS what is
playing or how long it is, and handles none of the system's commands. iOS draws the Lock Screen and Control
Center player only from those two.

## Green (the fix)
- `mobile/HostApp/iOS/NowPlayingInfo.swift` (pure): the Now Playing dictionary from the player's state:
  title (the file's name without its extension), album (the home or folder it sits in), duration, elapsed
  time, rate (1 playing, 0 paused). Elapsed is sent at every play, pause and seek; iOS runs the bar from the
  rate in between.
- `NativePlayer` publishes it on open, play, pause, seek, and once the duration is known; it answers the
  system's commands: play, pause, toggle, skip back 15 s, skip forward 30 s (the same as the in-app buttons),
  and dragging the scrubber (`changePlaybackPosition`).

## Invariants (tested: `mobile/ios/Tests/nowplaying/main.swift`)
- Duration known → the dictionary carries it and the elapsed time; unknown → no duration key (no 0:00 bar).
- Paused → rate 0; playing → rate 1. Elapsed is clamped to 0…duration.
- Title from `library/Music/Player check.m4a` is "Player check", album "Music"; from `downloads/x.mp4`, album "Downloads".
- The skip intervals the system shows are 15 back and 30 forward.

## Device check (owner, phone in hand)
Play a file, lock the phone: title, time bar and ±15/30 show; drag the bar → playback and the lit word move
there; pause and play from the Lock Screen and from the Bose.
