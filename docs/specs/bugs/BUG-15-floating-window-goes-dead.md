# BUG-15 · Floating window goes dead and won't close

From: T-0077 (owner, 2026-11-14: two iPhone screenshots 20:44/20:46 + IMG_4194.MOV, IMG_4195.MOV) ·
Device: iPhone, iPad · Status: `[~]` (building; device check owed — this fix could not be confirmed on the real
device in this pass, only read against the code and the existing `Floating.swift` test harness)

## What the owner sees
- iPhone: the window froze on one caption for 2+ minutes and stayed up over Recense's own player.
- iPad (video): it captions YouTube in Safari correctly, then sits over Recense as a black empty box through
  every tap, and never closes.

## Red (what the code shows)
- `Listener.dropPiP()` (`mobile/HostApp/iOS/Listen.swift`) drops the Swift references to the
  `AVPictureInPictureController` (`pip = nil`) but never resets `drawnKey`/`drawnAt` (`draw()`'s own staleness
  guard, line ~1132-1134) or the queued pictures. The next time `makePiP()` remakes a controller and `draw()` runs
  again, it is still compared against whatever `drawnKey` was left over from before the drop — including `"rest"`
  with a `drawnAt` inside the last second, which makes `draw()` skip enqueuing a fresh picture outright. This
  matches the iPhone symptom: the window reappears holding the last frame it drew before it was torn down, not a
  new one, and nothing forces a redraw until the key or clock happens to move past the guard.
- `floatTick()`'s hide path (`Listen.swift:1030-1045`) calls `pip.stopPictureInPicture()` once, waits 150 ms, and
  if iOS still reports the session active, only **detaches the content** (sets `contentSource = nil`) — it never
  asks iOS to stop a second time. A further 1 s later, if still active, it drops the Swift reference (`dropPiP()`)
  and gives up; nothing tells the system-level PiP surface itself to go away. The code's own comment already notes
  iOS has been seen to "ignore stop" (11-10 log). This fits the iPad symptom: with no content and no controller
  reference left on our side but the OS surface never actually told to close, a black, unresponsive box can be
  left on screen with nothing in the app able to reach it any more.

## Green (the fix)
- `dropPiP()` now also clears `drawnKey = ""`, `drawnAt = .distantPast`, and empties `queued` (flushing the layer),
  so a window made fresh after a drop is guaranteed a new picture on its very next `draw()`, never a stale one.
- The hide path retries `stopPictureInPicture()` once more right after detaching content (150 ms mark), before the
  final 1 s wait — giving iOS a second, cheap chance to actually end the PiP session instead of only ever asking
  once.

## Invariants
- `dropPiP()` leaves no instance state (`drawnKey`, `drawnAt`, `queued`) that could suppress or stale-match the
  next `draw()` after a fresh `makePiP()`.
- The hide sequence asks iOS to stop at least twice (immediately, then again after detaching content) before
  falling back to dropping the Swift reference.
- `Floating.swift`'s pure state machine (`decide`, `rest`, `reattach`) is unchanged — this fix is in `Listen.swift`'s
  teardown bookkeeping only, not the show/hide decision rules already covered by `mobile/ios/Tests/floating/main.swift`.

## Device check (owner, phone in hand) — OWED, not run in this pass
Play a YouTube tab in Safari, leave Recense, let it caption, pause, return to Recense: the window must close
cleanly, never freeze showing an old caption, never stay as a black box through taps. If it still does on the real
device, the root cause is more likely the "iOS ignores stop" platform behaviour itself (no public API to force a
PiP session closed beyond `stopPictureInPicture()`), which would need on-device `listen.floatLog` capture to
pin down further — not something resolvable by reading the code alone.
