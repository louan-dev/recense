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
check("quiet 0.3 s", Floating.decide(now(open: true, quiet: 0.3)), .hide)
check("quiet 3 s, works", Floating.decide(now(open: true, quiet: 5, reshow: .works)), .hide)
check("quiet, refused keeps it", Floating.decide(now(open: true, quiet: 60, reshow: .refused)), .none)
check("quiet, closed", Floating.decide(now(quiet: 9)), .none)
// leaving Recense opens it only while something plays
if Floating.autoOpen(playing: false, paused: false) { bad += 1; print("FAIL autoOpen silent") }
if Floating.autoOpen(playing: true, paused: true) { bad += 1; print("FAIL autoOpen paused") }
if !Floating.autoOpen(playing: true, paused: false) { bad += 1; print("FAIL autoOpen playing") }

// regression 11-10 (iPhone log): a hide detached the content and nothing gave it back, so leaving Recense never opened it
if !Floating.reattach(open: false, attached: false, closing: false) { bad += 1; print("FAIL reattach after a hide") }
if Floating.reattach(open: false, attached: false, closing: true) { bad += 1; print("FAIL reattach mid-hide") }
if Floating.reattach(open: true, attached: false, closing: false) { bad += 1; print("FAIL reattach while open") }
if Floating.reattach(open: false, attached: true, closing: false) { bad += 1; print("FAIL reattach attached") }

// each coming word gets its own picture, stamped for its start; past ones and ones too far ahead don't
let on = Floating.onsets([9.0, 10.2, 10.2, 10.6, 11.4, 13.0], after: 10.0, ahead: 1.5)
if on != [10.2, 10.6, 11.4] { bad += 1; print("FAIL onsets \(on)") }
if !Floating.onsets([10.0], after: 10.0).isEmpty { bad += 1; print("FAIL onset at now is already shown") }
// awake behind: while open, hearing, or within 10 minutes of quiet (11-10 log: asleep behind, no play ever seen)
if !Floating.awake(front: false, open: false, hearing: false, quiet: 30) { bad += 1; print("FAIL awake after leaving quiet") }
if Floating.awake(front: false, open: false, hearing: false, quiet: 601) { bad += 1; print("FAIL asleep after 10 min quiet") }
if !Floating.awake(front: false, open: true, hearing: false, quiet: 9999) { bad += 1; print("FAIL awake while open") }
print(bad == 0 ? "ALL OK" : "\(bad) FAILED")
