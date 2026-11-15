// Derived from Spec: FEAT-07 (rules 1, 2, 5)
// Find in the transcript, and where the scrubber's detents are. Pure, so it is tested apart from the views.
// Search ignores case and accents ("viet" finds "Việt", "e" finds "é"; Vietnamese đ is d), over each line's words
// and its translation, so a search works in every language the transcript holds, as the lines arrive.
import Foundation

public enum TranscriptFind {
    /// Folded for matching: lowercased, accents off, đ → d.
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "d")
    }

    /// The lines that hold `query` (in their words or their translation), in time order. Under 2 letters: none.
    public static func hits(_ lines: [TranscriptLine], _ query: String) -> [Int] {
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard q.count >= 2 else { return [] }
        return lines.indices.filter { fold(lines[$0].text).contains(q) || fold(lines[$0].translation ?? "").contains(q) }
    }

    /// The hit after (or, going back, before) the one at `current`, wrapping round; the first one when none is current.
    public static func step(_ hits: [Int], from current: Int?, back: Bool = false) -> Int? {
        guard !hits.isEmpty else { return nil }
        guard let c = current, let i = hits.firstIndex(of: c) else { return back ? hits.last : hits.first }
        return hits[(i + (back ? hits.count - 1 : 1)) % hits.count]
    }

    /// Three levels, never more (rule 2): light a sentence, medium a chapter, strong a search hit or an end.
    public enum Detent: Int, Comparable, Sendable {
        case light = 1, medium, strong
        public static func < (a: Detent, b: Detent) -> Bool { a.rawValue < b.rawValue }
    }

    /// The strongest detent crossed sliding from `a` to `b` (either way), or nil (rule 5: one per crossing, the strongest).
    public static func detent(_ lines: [TranscriptLine], hits: Set<Int>, duration: Double, from a: Double, to b: Double) -> Detent? {
        let lo = min(a, b), hi = max(a, b)
        guard hi > lo else { return nil }
        func crossed(_ t: Double) -> Bool { t > lo && t <= hi || (t == 0 && lo <= 0 && hi > 0) }
        if crossed(0) || (duration > 0 && crossed(duration)) || hits.contains(where: { lines.indices.contains($0) && crossed(lines[$0].start) }) { return .strong }
        if lines.contains(where: { $0.chapter != nil && crossed($0.start) }) { return .medium }
        if lines.contains(where: { crossed($0.start) }) { return .light }
        return nil
    }
}
