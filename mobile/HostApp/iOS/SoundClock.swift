// The broadcast's clock from the sound's own timestamps (owner 11-10). The extension used to start its clock when the
// first buffer reached its queue, and fed every later buffer as if the sound never stopped: a buffer's delivery delay
// moved every word, and each pause in the other app pulled every later word earlier by the pause's length.
// Now t0 is the first buffer's presentation time (host clock) turned into wall time, and a gap between buffers is
// kept: a short one as silence fed to the analyzer, a long one as a skew added to every later word's time.
// Foundation only: mobile/ios/Tests/soundclock/main.swift runs it on the Mac. Compiled into the app and the extension
// (listed by hand for GalleryBroadcast in project.pbxproj).
import Foundation

struct SoundClock {
    /// A gap shorter than this is jitter, not a pause.
    static let slack = 0.02
    /// At most this much silence is fed for one gap (enough to end the sentence before it); the rest becomes a skew.
    static let fill = 2.0
    /// A buffer stamped further than this from now is on some other clock: its arrival time is used instead.
    static let sane = 5.0

    /// Wall time (s since 1970) of the first sample fed: the analyzer's time 0.
    private(set) var t0: Double?
    /// Host time (s) of the first sample fed.
    private var first = 0.0
    /// Seconds of sound given to the analyzer, silence included: the analyzer's own clock.
    private(set) var fed = 0.0
    /// From analyzer time `at` on, `add` seconds go onto every word (long gaps), in order.
    private(set) var skews: [(at: Double, add: Double)] = []

    /// Before a buffer stamped `pts` (host s) is fed: how many seconds of silence go first. `hostNow` and `wallNow` are
    /// the same instant on the two clocks.
    mutating func before(pts: Double, hostNow: Double, wallNow: Double) -> Double {
        let p = abs(hostNow - pts) < Self.sane ? pts : hostNow
        guard t0 != nil else { first = p; t0 = wallNow - (hostNow - p); return 0 }
        let gap = (p - first) - (fed + skew(at: .infinity))
        guard gap > Self.slack else { return 0 }
        let silence = min(gap, Self.fill)
        if gap > silence { skews.append((at: fed + silence, add: gap - silence)) }
        return silence
    }

    /// After `seconds` of sound (or silence) went to the analyzer.
    mutating func gave(_ seconds: Double) { fed += seconds }

    /// What goes onto a word heard at analyzer time `t` so it's in t0's time.
    func skew(at t: Double) -> Double { skews.reduce(0) { $1.at <= t ? $0 + $1.add : $0 } }
}
