# BUG-12 · Words light ahead of the voice through headphones

From: T-0072 (owner, 2026-11-14: "its not exactly time synced"; "fix the delay and text cutoff, im using headphones
right now so yeah") · Device: iPhone 12 Pro Max, iPad · Status: `[~]` (building)

## What the owner sees
A file plays in Recense through Bluetooth headphones. The lit word in Now Playing and in the floating window runs
ahead of the voice.

## Red (what the code shows)
- `NativePlayer.time` (`mobile/HostApp/iOS/NativePlayer.swift`) is the player's position: what has left the phone.
- ShowsKit's transcript reads it every frame (`Transport.time`). The floating window stamps its pictures with it
  (`Listen.clockLag`, `shown`).
- Bluetooth plays that position later, by the route's latency. Nothing subtracts it.
- The web player already corrects for it (`RouteLatency`, `Player.swift`: "~0.2 s ahead of the voice on the iPhone"
  through AirPods, Sororité). The native player, added 11-13, never did.

## Green (the fix)
- `TranscriptLight.heard(_ position:latency:playing:)` (ShowsKit): while playing, `max(0, position − latency)`;
  paused, the position (nothing is in flight). Latency is clamped to 0–1 s.
- `NativePlayer.time` = that rule, with `RouteLatency.current`:
  - the same rule the web player uses: `AVAudioSession.outputLatency + ioBufferDuration`;
  - read once per route, and again on play and on every route change (the transcript reads `time` 60 times a second);
  - each new value is logged in the floating window's log (`listen.floatLog`): "route latency 0.xxx s (<port type>)".
- `NativePlayer.position` is the raw position. The Lock Screen's elapsed time and skip read it.
- Seek is unchanged: a seek to a line's start lights that line once its sound arrives.

## Invariants (tested: `shared/ShowsKit/Tests/ShowsKitTests/HeardTimeTests.swift`)
- Playing: heard = position − latency (10.0, 0.2 → 9.8).
- Never below 0 (0.1, 0.2 → 0).
- Paused: heard = position (10.0, 0.2 → 10.0).
- Latency outside 0–1 s is clamped (−0.5 → 0; 3.0 → 1.0).

## Device check (owner, phone in hand)
Headphones on. Play a file in Recense: each word lights as its sound is heard, in Now Playing and in the floating
window. Then without headphones: still in step.
