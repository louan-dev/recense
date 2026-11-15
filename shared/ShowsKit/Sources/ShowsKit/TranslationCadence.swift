// Derived from Spec: FEAT-10 (the translation follows the voice), owner 2026-11-15
// The translated line lights as the original is spoken: each translated word takes the time of the source word at the
// same place in the line (word j of m ↔ source word ⌊j·n/m⌋), so the voice's own pace and pauses carry into the
// translation. A line with no word times spreads its words evenly over the line. The Mac does the same with each
// word's source indices (EnWord.s); this is the rule where a translation is a plain sentence (iPhone, iPad).
import Foundation

public enum TranslationCadence {
    /// The time each translated word lights.
    public static func times(source: [Word], start: Double, end: Double, count m: Int) -> [Double] {
        guard m > 0 else { return [] }
        let n = source.count
        if n == 0 {
            let span = max(0, end - start)
            return (0..<m).map { start + span * Double($0) / Double(m) }
        }
        return (0..<m).map { j in source[min(n - 1, j * n / m)].start }
    }

    /// How much of `text` is spoken at `t`: the index after the last word whose time has come.
    public static func spoken(_ text: String, source: [Word], start: Double, end: Double, at t: Double) -> String.Index {
        let ranges = text.split(whereSeparator: \.isWhitespace).map { $0.startIndex..<$0.endIndex }
        let ts = times(source: source, start: start, end: end, count: ranges.count)
        guard let last = ts.lastIndex(where: { $0 <= t }) else { return text.startIndex }
        return ranges[last].upperBound
    }
}
