// When the frame being drawn reaches the screen. A light worked out for "now" is seen one refresh later (16.7 ms at
// 60 Hz), so the transcript asks for the playhead at the frame's own on-screen time instead (owner 11-10: "time each
// word light to the moment the screen actually shows it").
import Foundation
import QuartzCore
#if os(macOS)
import AppKit
#endif

@MainActor public final class FrameClock: NSObject {
    public static let shared = FrameClock()
    private var link: CADisplayLink?
    private var users = 0
    private var target = 0.0
    private var period = 1.0 / 60

    /// Seconds from `now` (CACurrentMediaTime) until the next refresh, from the screen's last target and period.
    /// Pure, so the tests check it: a target already passed moves on by whole periods.
    nonisolated public static func lead(now: Double, target: Double, period: Double) -> Double {
        guard period > 0 else { return 0 }
        guard target > 0 else { return period }
        var t = target
        if t < now { t += ((now - t) / period).rounded(.up) * period }
        return min(period, max(0, t - now))
    }

    /// Seconds until what is drawn now is on screen.
    public var lead: Double { Self.lead(now: CACurrentMediaTime(), target: target, period: period) }

    /// The clock runs only while a light is drawn (each user starts and stops it once).
    public func start() {
        users += 1
        guard link == nil else { return }
        #if os(iOS)
        let l = CADisplayLink(target: self, selector: #selector(step))
        #else
        guard let l = NSScreen.main?.displayLink(target: self, selector: #selector(step)) else { return }
        #endif
        l.add(to: .main, forMode: .common)
        link = l
    }

    public func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        link?.invalidate(); link = nil; target = 0
    }

    @objc private func step(_ l: CADisplayLink) {
        target = l.targetTimestamp
        let p = l.targetTimestamp - l.timestamp
        if p > 0.002, p < 0.1 { period = p }
    }
}
