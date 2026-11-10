// The broadcast extension's lines, kept so the app can catch up on what it missed. Today the Keychain holds only the
// latest line: while the app sleeps or is killed by iOS, every line in between was overwritten and lost. The ring keeps
// the last lines too, capped by count and by bytes (a Keychain item is meant to stay small), and the app takes the ones
// it hasn't seen when it wakes. Foundation only: mobile/ios/Tests/captionring/main.swift runs it on the Mac.
// Compiled into the app and the extension (listed by hand for GalleryBroadcast in project.pbxproj).
import Foundation

protocol RingLine: Codable {
    /// Which line this is: a newer version of the same line (it grows while it's heard) replaces the older one.
    var ringKey: String { get }
    /// Which version: equal stamps mean the same text.
    var ringStamp: UInt64 { get }
    /// About how many bytes it takes in the ring.
    var ringSize: Int { get }
}

struct CaptionRing<L: RingLine>: Codable {
    var lines: [L] = []

    /// Adds a line, or replaces the older version of it. Past either cap, the oldest lines go first; the newest
    /// line always stays, even when it alone is over the byte cap.
    mutating func add(_ l: L, maxLines: Int = 200, maxBytes: Int = 128_000) {
        lines.removeAll { $0.ringKey == l.ringKey }
        lines.append(l)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        var total = lines.reduce(0) { $0 + $1.ringSize }
        while total > maxBytes, lines.count > 1 { total -= lines.removeFirst().ringSize }
    }

    /// The lines whose version the reader hasn't taken (`seen`: key → stamp taken), oldest first.
    func unseen(_ seen: [String: UInt64]) -> [L] { lines.filter { seen[$0.ringKey] != $0.ringStamp } }
}

/// FNV-1a, 64-bit: a stable hash (Swift's own `hashValue` changes on every launch).
func ringHash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
    return h
}
