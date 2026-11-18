// Derived from Spec: FEAT-01
// The chapter list of an audiobook, made from the transcript's rows: every heading row (`#` chapter, `##` section)
// becomes one chapter that starts when that row is spoken. Foundation only; the Mac and the iPhone share it.
// Invariant 4: M4B chapter count = heading count.
import Foundation

/// One row of the spoken text: `level` 0 is body text, 1 is `#`, 2 is `##` and so on.
struct ChapterRow: Sendable, Equatable {
    var text: String
    var start: TimeInterval
    var level: Int
    init(text: String, start: TimeInterval, level: Int = 0) { self.text = text; self.start = start; self.level = level }
}

struct M4BChapter: Sendable, Equatable {
    var title: String
    var start: TimeInterval
    var end: TimeInterval
}

enum ChapterPlan {
    /// Heading rows to chapters, in time order. The first chapter starts at 0 so no audio sits before a chapter;
    /// a heading that starts at the same instant as the one before it is dropped (two chapters cannot share a start);
    /// every start is clamped inside `duration`; an empty title becomes "Chapter N". A text with no heading
    /// is one chapter titled `fallbackTitle`, so a player never shows an audiobook without chapters.
    static func make(rows: [ChapterRow], duration: TimeInterval, fallbackTitle: String = "Chapter 1") -> [M4BChapter] {
        guard duration > 0 else { return [] }
        let heads = rows.filter { $0.level > 0 }.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        var starts: [(String, TimeInterval)] = []
        for h in heads {
            let t = min(max(h.start, 0), duration)
            if t >= duration { continue }
            if let last = starts.last, abs(last.1 - t) < 0.001 { continue }
            starts.append((title(h.text, n: starts.count + 1), t))
        }
        if starts.isEmpty { return [M4BChapter(title: fallbackTitle, start: 0, end: duration)] }
        starts[0].1 = 0
        return starts.enumerated().map { i, s in
            M4BChapter(title: s.0, start: s.1, end: i + 1 < starts.count ? starts[i + 1].1 : duration)
        }
    }

    /// "## 1901.07 Definitions" to "1901.07 Definitions".
    static func title(_ raw: String, n: Int) -> String {
        let t = raw.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Chapter \(n)" : t
    }
}
