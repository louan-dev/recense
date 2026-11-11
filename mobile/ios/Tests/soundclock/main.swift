// swiftc -O mobile/HostApp/iOS/SoundClock.swift mobile/ios/Tests/soundclock/main.swift -o "$TMPDIR/soundclock" && "$TMPDIR/soundclock"
var bad = 0
func near(_ name: String, _ a: Double, _ b: Double) { if abs(a - b) > 1e-6 { bad += 1; print("FAIL \(name): \(a) want \(b)") } }

// t0 is the first buffer's stamp, not its arrival: stamped 0.3 s before it reached the extension (old way: +0.3 s on every word)
var c = SoundClock()
near("first: no silence", c.before(pts: 100.0, hostNow: 100.3, wallNow: 1_000_000.3), 0)
near("t0 = stamp in wall time", c.t0 ?? -1, 1_000_000.0)
c.gave(0.5)
near("back to back", c.before(pts: 100.5, hostNow: 100.9, wallNow: 1_000_000.9), 0)
c.gave(0.5)
// a 1.2 s pause in the other app: fed as 1.2 s of silence (old way: every later word 1.2 s early)
near("short pause → silence", c.before(pts: 102.2, hostNow: 102.4, wallNow: 1_000_002.4), 1.2)
c.gave(1.2); c.gave(0.5)
near("no skew for a short pause", c.skew(at: c.fed), 0)
// a 10-minute pause: 2 s of silence (ends the sentence), the other 598 s a skew on every later word
near("long pause → 2 s silence", c.before(pts: 102.7 + 600, hostNow: 702.9, wallNow: 1_000_602.9), 2)
c.gave(2)
near("no skew before the pause", c.skew(at: 1.0), 0)
near("skew after the pause", c.skew(at: c.fed), 598)
c.gave(0.5)
near("back to back after it", c.before(pts: 703.2, hostNow: 703.4, wallNow: 1_000_603.4), 0)
// any moment's wall time = t0 + analyzer time + skew: the end of what was fed is the stamp of the next buffer
near("wall time after the pause", (c.t0 ?? 0) + c.fed + c.skew(at: c.fed), 1_000_000.0 + (703.2 - 100.0))
// jitter under 20 ms isn't a pause
var j = SoundClock()
_ = j.before(pts: 10, hostNow: 10, wallNow: 10); j.gave(0.5)
near("jitter", j.before(pts: 10.515, hostNow: 10.6, wallNow: 10.6), 0)
// a stamp on another clock: arrival time is used
var d = SoundClock()
_ = d.before(pts: 5, hostNow: 9000, wallNow: 50)
near("stamp on another clock → arrival", d.t0 ?? -1, 50)
print(bad == 0 ? "ALL OK" : "\(bad) FAILED")
