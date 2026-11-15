// Derived from Spec: BUG-13
// How timed words become transcript lines: by sentence, as the Mac always has. The two rules moved here unchanged from
// strip/recense.swift (`sentences`, `splitWords`), so the Mac, the iPhone and the iPad group one way; the Mac's names
// call these. iOS made a line per breath-phrase and cut sentences mid-way ("This is the" / "resent player" / "check,").
import Foundation

public enum Phrasing {
    /// Whole sentences translate far better than arbitrary segments, so lines follow sentence ends: a word ending in
    /// . ? ! … (past a closing quote or bracket), or a pause over `pause` seconds before the next word.
    public static func sentences(_ w: [Word], pause: Double = 1.2) -> [[Word]] {
        var out: [[Word]] = [], cur: [Word] = []
        for (i, x) in w.enumerated() {
            cur.append(x)
            let core = x.text.trimmingCharacters(in: CharacterSet(charactersIn: "»\"”’)"))
            let ends = core.last.map { ".?!…".contains($0) } ?? false
            let gap = i + 1 < w.count && w[i + 1].start - x.end > pause
            if ends || gap { out.append(cur); cur = [] }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// A run of words too long for one line, in near-even parts: cut at punctuation once a part is long enough, and
    /// never past `max` words; the last part keeps at least three.
    public static func split(_ w: [Word], max: Int = 14) -> [[Word]] {
        guard w.count > max else { return [w] }
        let parts = (w.count + max - 1) / max, target = w.count / parts
        var out: [[Word]] = [], cur: [Word] = []
        for (i, x) in w.enumerated() {
            cur.append(x)
            let left = w.count - i - 1
            let punct = x.text.last.map { ",.;:?!".contains($0) } ?? false
            if left > 2, out.count < parts - 1, (cur.count >= target && punct) || cur.count >= max { out.append(cur); cur = [] }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// The longest line the Mac makes from speech (strip/recense.swift, the transcript's `add`).
    public static let longest = 18

    /// Lines from timed words: one per sentence, a long one split (≤ `max` words). A line's id is its start in ms
    /// ("ms-0", "ms-1" on a tie), so it keeps its id as more of the file is heard.
    public static func lines(_ words: [Word], max: Int = longest) -> [TranscriptLine] {
        var seen: [Int: Int] = [:]
        return sentences(words.sorted { $0.start < $1.start }).flatMap { split($0, max: max) }.map { part in
            let ms = Int((part[0].start * 1000).rounded(.down)), n = seen[ms, default: 0]
            seen[ms] = n + 1
            return TranscriptLine(id: "\(ms)-\(n)", start: part[0].start, end: part[part.count - 1].end,
                                  text: join(part.map(\.text)), words: part)
        }
    }

    /// Lines this device heard before BUG-13 (one per breath-phrase), regrouped by sentence. Only those: every id
    /// "ms-n", every line with words, no translation, no chapter. Anything else (the Mac's: plain ids, translations,
    /// chapters, songs) comes back as it is.
    public static func regrouped(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        let here = !lines.isEmpty && lines.allSatisfy { l in
            !l.words.isEmpty && l.translation == nil && l.chapter == nil && Self.heardId(l.id)
        }
        return here ? Self.lines(lines.flatMap(\.words)) : lines
    }

    /// Words as one line of text: a space between them, none between two CJK characters (Chinese, Japanese).
    public static func join(_ words: [String]) -> String {
        var out = ""
        for w in words where !w.isEmpty {
            if let a = out.unicodeScalars.last, let b = w.unicodeScalars.first, !(cjk(a) && cjk(b)) { out += " " }
            out += w
        }
        return out
    }

    private static func heardId(_ id: String) -> Bool {
        let p = id.split(separator: "-", omittingEmptySubsequences: false)
        return p.count == 2 && p.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }
    /// Han, kana and their punctuation: scripts written without spaces between words.
    private static func cjk(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFF60, 0x20000...0x2FFFF: true
        default: false
        }
    }
}
