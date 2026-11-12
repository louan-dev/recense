// Derived from Spec: FEAT-04 (P1, one clock)
// Every stored word is timed in seconds into the recording (the content's own clock). Live ears time words on the wall
// clock (seconds since 1970); they cross over here, once, when a word is stored, and back only to schedule a frame.
import Foundation

public enum ContentClock {
    /// Word times above this are the wall clock (seconds since 1970; 1e9 is 2001-09-09), never a place in a recording.
    public static let wallFloor: Double = 1e9

    public static func isWall(_ ws: [Word]) -> Bool { (ws.first?.start ?? 0) > wallFloor }

    /// Wall-clock words on the content's clock, the first one starting at `at`; content words come back unchanged.
    public static func content(_ ws: [Word], at: Double) -> [Word] {
        guard let f = ws.first, isWall(ws) else { return ws }
        return ws.map { $0.shifted(by: at - f.start) }
    }

    /// Where a wall-clock moment falls on the content's clock: `content` was playing at `wall`, moving at `rate`
    /// (1 while playing, 0 paused).
    public struct Anchor: Equatable, Sendable {
        public var wall: Double
        public var content: Double
        public var rate: Double
        public init(wall: Double, content: Double, rate: Double = 1) { self.wall = wall; self.content = content; self.rate = rate }
        public func content(atWall w: Double) -> Double { content + (w - wall) * rate }
        /// Content words back on the wall clock (only for scheduling frames; rate 0 has no wall time, so they stay).
        public func wall(_ ws: [Word]) -> [Word] {
            guard rate > 0, !ContentClock.isWall(ws) else { return ws }
            return ws.map { w in
                var x = w.shifted(by: wall - content)
                if rate != 1 { x.start = wall + (w.start - content) / rate; x.end = wall + (w.end - content) / rate }
                return x
            }
        }
    }
}
