// swiftc -O mobile/HostApp/iOS/Floating.swift mobile/ios/Tests/floating/main.swift -o "$TMPDIR/floating" && "$TMPDIR/floating"
var bad = 0
func check(_ name: String, _ got: Floating.Act, _ want: Floating.Act) {
    if got != want { bad += 1; print("FAIL \(name): got \(got), want \(want)") }
}
func now(front: Bool = false, playing: Bool = false, paused: Bool = false, open: Bool = false, quiet: Double = 0,
         reshow: Floating.Reshow = .unknown, tried: Bool = false, hid: Bool = true, left: Double = 9) -> Floating.Now {
    .init(front: front, playing: playing, paused: paused, open: open, quiet: quiet, reshow: reshow, tried: tried, hid: hid, left: left)
}

// in Recense: never floats (Home shows the transcript)
check("front, open", Floating.decide(now(front: true, playing: true, open: true)), .hide)
check("front, closed", Floating.decide(now(front: true, playing: true)), .none)
// Pause hides it anywhere
check("paused behind", Floating.decide(now(playing: true, paused: true, open: true)), .hide)
// behind, playing: opens once per stretch of sound, not when iOS refused before
check("play behind", Floating.decide(now(playing: true)), .show)
check("play behind, tried", Floating.decide(now(playing: true, tried: true)), .none)
check("play behind, refused", Floating.decide(now(playing: true, reshow: .refused)), .none)
// regression 11-10 (iPhone): just after leaving Recense iOS opens it by itself; a second start read as "refused"
check("play behind, just left", Floating.decide(now(playing: true, hid: false, left: 0.4)), .none)
// owner 11-10: autoshow on play anywhere: left Recense while quiet, then another app plays
check("play behind, left quiet a while ago", Floating.decide(now(playing: true, hid: false, left: 30)), .show)
check("play behind, open", Floating.decide(now(playing: true, open: true)), .none)
// behind, paused sound: hides within the owner's 0.5 s (0.3 s of quiet), not on a blip; never when it couldn't come back
check("quiet 0.1 s", Floating.decide(now(open: true, quiet: 0.1)), .none)
check("quiet 0.3 s, not proven to reopen: rests", Floating.decide(now(open: true, quiet: 0.3)), .none)
check("quiet 0.3 s, works", Floating.decide(now(open: true, quiet: 0.3, reshow: .works)), .hide)
// T-0002: open at rest on leave, so a long quiet behind finally closes it (battery)
check("quiet 10 min behind closes", Floating.decide(now(open: true, quiet: Floating.stayAwake)), .hide)
check("quiet 3 s, works", Floating.decide(now(open: true, quiet: 5, reshow: .works)), .hide)
check("quiet, refused keeps it", Floating.decide(now(open: true, quiet: 60, reshow: .refused)), .none)
check("quiet, closed", Floating.decide(now(quiet: 9)), .none)
// leaving Recense opens it only while something plays
// T-0002: iOS opens it only as Recense is left, and YouTube starts after that: open on every leave
if !Floating.autoOpen(paused: false) { bad += 1; print("FAIL autoOpen on leave, nothing playing yet") }
if Floating.autoOpen(paused: true) { bad += 1; print("FAIL autoOpen paused") }

// regression 11-10 (iPhone log): a hide detached the content and nothing gave it back, so leaving Recense never opened it
if !Floating.reattach(open: false, attached: false, closing: false) { bad += 1; print("FAIL reattach after a hide") }
if Floating.reattach(open: false, attached: false, closing: true) { bad += 1; print("FAIL reattach mid-hide") }
if Floating.reattach(open: true, attached: false, closing: false) { bad += 1; print("FAIL reattach while open") }
if Floating.reattach(open: false, attached: true, closing: false) { bad += 1; print("FAIL reattach attached") }

// the pictures' moments (each word's start and quarters, stamped ahead) are ShowsKit's FloatingFrames (swift test, BUG-24)
// awake behind: while open, hearing, or within 10 minutes of quiet (11-10 log: asleep behind, no play ever seen)
if !Floating.awake(front: false, open: false, hearing: false, quiet: 30) { bad += 1; print("FAIL awake after leaving quiet") }
if Floating.awake(front: false, open: false, hearing: false, quiet: 601) { bad += 1; print("FAIL asleep after 10 min quiet") }
if !Floating.awake(front: false, open: true, hearing: false, quiet: 9999) { bad += 1; print("FAIL awake while open") }
// iOS refuses to reopen it behind (-1001): a pause there rests it (thin strip), a sound wakes it
if !Floating.rest(open: true, quiet: 0.3, paused: false) { bad += 1; print("FAIL rest on pause behind") }
if Floating.rest(open: true, quiet: 0, paused: false) { bad += 1; print("FAIL rest while playing") }
if Floating.rest(open: false, quiet: 9, paused: true) { bad += 1; print("FAIL rest with no window") }
// Regression guard: T-0139 (iPhone + iPad 11-16: never became the strip): a window that can close (it reopened behind
// once, or an active iPad) rests too while the close lands, so the strip shows on every device
if !Floating.rest(open: true, quiet: 9, paused: false) { bad += 1; print("FAIL rest when it can close and reopen") }
if !Floating.rest(open: true, quiet: Floating.stayAwake + 1, paused: false) { bad += 1; print("FAIL rest after a long quiet") }
// Regression guard: T-0077 (11-14: frozen caption, then black, after pause): Listen's pause rests it blank at once,
// even while the other app still plays, so no stale words stay while the hide lands or if iOS ignores it
if !Floating.rest(open: true, quiet: 0, paused: true) { bad += 1; print("FAIL paused window keeps its caption") }
// Regression guard: T-0036, T-0038 (owner 11-12: "floating bar pause bug. doesnt collapse"): the window's own pause
// button held the old words on a full window; it rests as the thin strip at once, and wakes on play
if !Floating.rest(open: true, quiet: 0, paused: false, held: true) { bad += 1; print("FAIL the window's pause doesn't collapse it") }
if Floating.rest(open: true, quiet: 0, paused: false, held: false) { bad += 1; print("FAIL play after the window's pause stays collapsed") }
// Regression guard: BUG-24 review 1 (11-18): with the ear on, our player stops counting as "own" once paused, so the
// window's play didn't resume the podcast it had paused. Play resumes exactly what the window's pause stopped.
func holdCheck(_ name: String, _ got: (toggle: Bool, pausedOurs: Bool), _ want: (Bool, Bool)) {
    if got.toggle != want.0 || got.pausedOurs != want.1 { bad += 1; print("FAIL hold \(name): got \(got), want \(want)") }
}
holdCheck("pause ours", Floating.hold(on: true, own: true, playing: true, pausedOurs: false), (true, true))
holdCheck("play after, ear on (own false)", Floating.hold(on: false, own: false, playing: false, pausedOurs: true), (true, false))
holdCheck("play after, already playing", Floating.hold(on: false, own: true, playing: true, pausedOurs: true), (false, false))
holdCheck("pause, ours not playing", Floating.hold(on: true, own: true, playing: false, pausedOurs: false), (false, false))
holdCheck("pause, the broadcast's", Floating.hold(on: true, own: false, playing: true, pausedOurs: false), (false, false))
holdCheck("play, we never paused it", Floating.hold(on: false, own: true, playing: false, pausedOurs: false), (false, false))
// Regression guard: BUG-24 review 2 (11-18): paused from the window, then played from the app, Control Center or the
// headphones, the window stayed a thin strip saying paused. Our player playing again lets the window's pause go.
if !Floating.release(held: true, own: true, playing: true) { bad += 1; print("FAIL our player resumed elsewhere, the window stays paused") }
if Floating.release(held: true, own: true, playing: false) { bad += 1; print("FAIL released while still paused") }
if Floating.release(held: true, own: false, playing: true) { bad += 1; print("FAIL another app's sound released the window's pause") }
if Floating.release(held: false, own: true, playing: true) { bad += 1; print("FAIL released a window that isn't paused") }
// Regression guard: BUG-24 review 3 (11-18): 12 pictures cover only 0.5-1 s of speech (4 to a long word, more at 2x),
// and behind other apps the queue was refilled only on the 1 s tick, so the sweep froze. The 0.1 s tick refills it
// once it is half spent; the 1 s keep-alive never flushes a queue that is still good.
if !Floating.refill(open: true, queued: Floating.queueCap / 2 - 1) { bad += 1; print("FAIL a half-spent queue isn't refilled") }
if Floating.refill(open: true, queued: Floating.queueCap / 2) { bad += 1; print("FAIL refilled a queue more than half full") }
if Floating.refill(open: false, queued: 0) { bad += 1; print("FAIL refilled with no window") }
if Floating.keepAlive(since: 1.2, queued: 3) { bad += 1; print("FAIL the keep-alive flushed a good queue") }
if !Floating.keepAlive(since: 1.2, queued: 0) { bad += 1; print("FAIL no keep-alive with nothing queued (PiP goes stale)") }
if Floating.keepAlive(since: 0.5, queued: 0) { bad += 1; print("FAIL keep-alive before a second") }
// regression 11-10 (iPad log 19:29): under a full-screen Firefox, Recense stayed active and read "front playing" for
// 2 min, so the window never came. On iPad, front needs the focus too; an active app without it may start the window.
if Floating.front(active: true, pad: true, key: false) { bad += 1; print("FAIL iPad active without focus counted as front") }
if !Floating.front(active: true, pad: true, key: true) { bad += 1; print("FAIL iPad focused is front") }
if !Floating.front(active: true, pad: false, key: false) { bad += 1; print("FAIL iPhone active is front") }
if Floating.front(active: false, pad: false, key: true) { bad += 1; print("FAIL behind is not front") }
var ipad = now(playing: true, reshow: .refused, hid: false, left: 2); ipad.canStart = true
check("iPad unfocused, playing, refused behind before", Floating.decide(ipad), .show)
ipad.left = 0.4
check("iPad unfocused, just switched", Floating.decide(ipad), .none)
var ipadQuiet = now(open: true, quiet: 0.5, reshow: .refused); ipadQuiet.canStart = true
check("iPad unfocused, paused: hides", Floating.decide(ipadQuiet), .hide)
if !Floating.rest(open: true, quiet: 9, paused: false) { bad += 1; print("FAIL iPad shows old words while its hide lands") }   // T-0139: blank while it hides
// Regression guard: T-0041 (iOS keeps "other audio playing" on ~40 s after a pause; iPhone log 11-12 12:50:52-12:51:36)
if Floating.playing(flag: true, hearing: true, soundAgo: 2) { bad += 1; print("FAIL paused behind still counts as playing") }
if !Floating.playing(flag: true, hearing: true, soundAgo: 0.1) { bad += 1; print("FAIL sound now is not playing") }
if !Floating.playing(flag: true, hearing: false, soundAgo: nil) { bad += 1; print("FAIL no broadcast: iOS flag decides") }
if Floating.playing(flag: false, hearing: true, soundAgo: 0.1) { bad += 1; print("FAIL flag off yet playing") }

// Regression guard: BUG-10 (iPhone 11-14: Recense's own player read as quiet, so the window rested black for 10 min)
if !Floating.playing(flag: false, hearing: false, soundAgo: nil, own: true) { bad += 1; print("FAIL own player playing is not playing") }
if !Floating.playing(flag: true, hearing: true, soundAgo: 9, own: true) { bad += 1; print("FAIL own player loses to an old broadcast sound") }
if Floating.playing(flag: false, hearing: false, soundAgo: nil, own: false) { bad += 1; print("FAIL own player paused still playing") }
check("own player behind, open", Floating.decide(now(playing: Floating.playing(flag: false, hearing: false, soundAgo: nil, own: true), open: true)), .none)
if Floating.rest(open: true, quiet: 0, paused: false) { bad += 1; print("FAIL own player playing rests") }

// Regression guard: BUG-14 (iPhone 11-14 18:40: YouTube in Safari read as quiet, the window rested; the broadcast's
// last sound was older than the broadcast itself, as the fallback engine never notes sound)
if !Floating.playing(flag: true, hearing: true, soundAgo: 600, broadcastAgo: 20) { bad += 1; print("FAIL an earlier broadcast's sound reads as quiet") }
if Floating.playing(flag: true, hearing: true, soundAgo: 2, broadcastAgo: 20) { bad += 1; print("FAIL this broadcast's pause still counts as playing") }
if !Floating.playing(flag: true, hearing: true, soundAgo: 0.1, broadcastAgo: 20) { bad += 1; print("FAIL this broadcast's sound is not playing") }
if Floating.playing(flag: true, hearing: true, soundAgo: 2, broadcastAgo: nil) { bad += 1; print("FAIL no broadcast start: the sound no longer decides") }
if Floating.playing(flag: false, hearing: true, soundAgo: 600, broadcastAgo: 20) { bad += 1; print("FAIL flag off yet playing (old sound)") }

print(bad == 0 ? "ALL OK" : "\(bad) FAILED")
