// Derived from Spec: FEAT-05 (P1, one caption for every surface)
// The caption's rules, one copy for the Mac, the iPhone and the iPad: when each word lights, how far through a word the
// light is, which words a translated word follows, and Learn's phrases. Moved here from strip/recense.swift
// (`Beat`, `sourceBeats`, `englishBeats`, `sources`, `phrases`, `endsClause`, `leansOn`, `leansOnEnglish`,
// `Cadence.progress`) without changing a rule; the Mac's copies go in FEAT-05 P2. `learn.js` is the web's twin.
// Namespaced (Caption.*) so the Mac's own global names don't clash while both exist.
import Foundation

public enum Caption {
    /// How long a heard phrase takes to turn into its translation, from the moment the light leaves its last word.
    public static let turnTime = 0.3
    /// How long a phrase's translation needs on screen to be read: a moment to find it, and a little per word.
    public static func readingTime(words n: Int) -> Double { 0.7 + 0.28 * Double(n) }

    /// A translated word and the original words (indices) it translates; empty when nobody aligned it.
    public struct Translated: Codable, Hashable, Sendable {
        public let w: String; public let s: [Int]
        public init(w: String, s: [Int] = []) { self.w = w; self.s = s }
    }

    /// One line of a caption: its timed words and, once translated, the translation's words.
    public struct Line: Hashable, Sendable {
        public let words: [Word]
        public let translation: [Translated]?
        public init(words: [Word], translation: [Translated]?) { self.words = words; self.translation = translation }
        public var start: Double { words.first?.start ?? 0 }
        public var end: Double { words.last?.end ?? 0 }
        /// A plain translated sentence (iPhone, iPad) as unaligned words.
        public init(words: [Word], translationText: String?) {
            self.words = words
            self.translation = translationText.map { $0.split(whereSeparator: \.isWhitespace).map { Translated(w: String($0)) } }
        }
    }

    /// A word and the stretch of time in which it is spoken.
    public struct Beat: Hashable, Sendable {
        public let text: String; public let start: Double; public let end: Double
        public var syl: [Syl]? = nil; public var un = false; public var k: Double? = nil; public var c: [Double]? = nil
        public init(text: String, start: Double, end: Double, syl: [Syl]? = nil, un: Bool = false, k: Double? = nil, c: [Double]? = nil) {
            self.text = text; self.start = start; self.end = end; self.syl = syl; self.un = un; self.k = k; self.c = c
        }
    }

    /// A run of original words and the run of translation that goes with it (Learn).
    public struct Phrase: Hashable, Sendable {
        public let src: Range<Int>; public let en: Range<Int>
        public init(src: Range<Int>, en: Range<Int>) { self.src = src; self.en = en }
    }

    // ---------- when each word lights ----------

    /// The original words as beats: each lasts until the next one starts, at least 50 ms.
    public static func sourceBeats(_ words: [Word]) -> [Beat] {
        words.enumerated().map { i, w in
            let next = i + 1 < words.count ? words[i + 1].start : .infinity
            let k = w.tm.flatMap { $0.c != nil || abs($0.k) <= 0.05 && w.syl?.isEmpty == false ? nil : $0.k }
            return Beat(text: w.text, start: w.start, end: max(w.start + 0.05, min(w.end, next)), syl: w.syl, un: w.un == true, k: k, c: w.tm?.c)
        }
    }

    /// The original words a translated word translates. One claiming most of a long line is a misread alignment.
    public static func sources(_ w: Translated, of m: Int) -> [Int] {
        let s = w.s.filter { $0 >= 0 && $0 < m }
        return m > 3 && s.count > max(2, m / 2) ? [] : s
    }

    /// Translated words take the time of the original words they translate. Word order differs between languages, so
    /// those times are made to run forward (pool adjacent violators), and words left sharing one moment are spread over
    /// the speech they came from: the light steps one word at a time and never leaps. Unaligned words take the time of
    /// the original word at the same place (word j of n ↔ ⌊j·m/n⌋), as FEAT-10's TranslationCadence.
    public static func translationBeats(_ line: Line) -> [Beat] {
        guard let en = line.translation else { return [] }
        let orig = line.words, m = orig.count, n = en.count
        guard m > 0, n > 0 else { return [] }
        var s: [Double] = [], e: [Double] = []
        for (i, w) in en.enumerated() {
            let src = sources(w, of: m)
            let idx = src.isEmpty ? [min(m - 1, Int(Double(i) * Double(m) / Double(n)))] : src
            s.append(idx.map { orig[$0].start }.min()!); e.append(idx.map { orig[$0].end }.max()!)
        }
        var blocks: [(v: Double, n: Int)] = []
        for x in s {
            blocks.append((x, 1))
            while blocks.count > 1, blocks[blocks.count - 2].v > blocks[blocks.count - 1].v {
                let b = blocks.removeLast(), a = blocks.removeLast()
                blocks.append(((a.v * Double(a.n) + b.v * Double(b.n)) / Double(a.n + b.n), a.n + b.n))
            }
        }
        var start: [Double] = [], i = 0
        for (k, b) in blocks.enumerated() {
            let next = k + 1 < blocks.count ? blocks[k + 1].v : line.end
            let spoken = e[i..<(i + b.n)].max()! - b.v
            let span = b.n == 1 ? 0 : max(0.1 * Double(b.n), min(next - b.v, spoken))
            for j in 0..<b.n { start.append(b.v + span * Double(j) / Double(b.n)) }
            i += b.n
        }
        for k in 1..<max(1, n) { start[k] = max(start[k], start[k - 1] + 0.02) }
        return (0..<n).map { k in
            let next = k + 1 < n ? start[k + 1] : .infinity
            let end = k + 1 < n ? min(next, max(start[k] + 0.08, e[k])) : max(start[k] + 0.15, line.end)
            return Beat(text: en[k].w, start: start[k], end: max(start[k] + 0.05, end))
        }
    }

    /// How far through a word the light is at t (0…1). A finger's trace wins, then the listener's timing (k), then a
    /// sung word's syllables, then the voice (`voice`, the Mac's prosody curve when it has one), then the clock.
    public static func progress(_ b: Beat, _ t: Double, voice: ((Beat, Double) -> Double?)? = nil) -> Double {
        if let c = b.c, c.count > 1 {
            let u = max(0, min(1, (t - b.start) / max(0.05, b.end - b.start))) * Double(c.count - 1)
            let j = min(c.count - 2, Int(u))
            return c[j] + (c[j + 1] - c[j]) * (u - Double(j))
        }
        if let k = b.k {
            let u = max(0, min(1, (t - b.start) / max(0.05, b.end - b.start)))
            return pow(u, pow(2, -1.5 * k))
        }
        if let syl = b.syl, !syl.isEmpty, !b.text.isEmpty {
            let n = Double(b.text.unicodeScalars.count)
            var c0 = 0.0
            for (k, y) in syl.enumerated() {
                let end = k + 1 < syl.count ? min(syl[k + 1].s, y.e + 0.25) : y.e
                if t < y.s { return c0 / n }
                if t < end { return min(1, (c0 + (Double(y.c) - c0) * (t - y.s) / max(0.05, end - y.s)) / n) }
                c0 = Double(y.c)
            }
            return 1
        }
        if let v = voice?(b, t) { return max(0, min(1, v)) }
        return max(0, min(1, (t - b.start) / max(0.05, b.end - b.start)))
    }

    // ---------- Learn's phrases ----------

    /// Learn's phrases: a phrase ends where the speech pauses or a clause ends, rarely on a short word that leans on the
    /// next, and its translation is cut at the same share of the translation, a little behind rather than ahead, never
    /// after "the" or "of". A real alignment keeps a cut from parting a word from its translation.
    public static func phrases(_ line: Line) -> [Phrase] {
        let en = line.translation ?? []
        let words = line.words.map(\.text), m = words.count, n = en.count
        guard m > 1, n > 1 else { return [Phrase(src: 0..<m, en: 0..<n)] }
        let s = en.map { sources($0, of: m) }
        let aligned = s.allSatisfy { !$0.isEmpty } && !s.enumerated().allSatisfy { $0.element == [$0.offset] }
        func shares(_ w: [String]) -> [Double] {
            var c = [0.0]; for x in w { c.append(c.last! + Double(x.count + 1)) }
            return c.map { $0 / c.last! }
        }
        let po = shares(words), pe = shares(en.map(\.w))
        var cut: [Int: (k: Int, cost: Double)] = [:]
        for i in 1..<m {
            var best: (k: Int, cost: Double)?
            for k in 1..<n {
                if aligned, s[..<k].contains(where: { $0.max()! >= i }) || s[k...].contains(where: { $0.min()! < i }) { continue }
                var c = abs(pe[k] - (po[i] - 0.04)) * 4 + (leansOnEnglish(en[k - 1].w) ? 0.6 : 0)
                if endsClause(words[i - 1]) && endsClause(en[k - 1].w) { c -= 0.5 }
                if best.map({ c < $0.cost }) ?? true { best = (k, c) }
            }
            guard var b = best else { continue }
            if endsClause(words[i - 1]) { b.cost -= 1.2 }
            if line.words[i].start - line.words[i - 1].end >= 0.25 { b.cost -= 0.8 }
            if leansOn(words[i - 1]) { b.cost += 0.8 }
            if !aligned { b.cost += 0.5 }
            cut[i] = b
        }
        let size = [0, 2, 0.5, 0, 0.1, 0.7]
        var path: [(at: Int, k: Int, cost: Double, from: Int)] = [(0, 0, 0, -1)]
        for j in cut.keys.sorted() + [m] {
            let (k, c) = j < m ? (cut[j]!.k, cut[j]!.cost) : (n, 0)
            let options = path.indices.filter { path[$0].k < k }.map { i -> (from: Int, cost: Double) in
                let len = j - path[i].at
                return (i, path[i].cost + (len < size.count ? size[len] : 0.7 + Double(len - 5)) + c)
            }
            if let o = options.min(by: { $0.cost < $1.cost }) { path.append((j, k, o.cost, o.from)) }
        }
        var out: [Phrase] = [], i = path.count - 1
        while i > 0 { let p = path[i], q = path[p.from]; out.insert(Phrase(src: q.at..<p.at, en: q.k..<p.k), at: 0); i = p.from }
        return out
    }

    /// How far a phrase has turned into its translation at t (0…1): it starts as the light leaves its last word and
    /// takes `turnTime`. A line with no translation never turns.
    public static func turned(_ line: Line, _ p: Phrase, beats: [Beat], at t: Double) -> Double {
        guard line.translation?.isEmpty == false, !p.en.isEmpty, p.src.upperBound > 0, p.src.upperBound <= beats.count else { return 0 }
        let from = beats[p.src.upperBound - 1].end
        return max(0, min(1, (t - from) / turnTime))
    }

    /// A word that ends a clause (before any closing quote), in Latin, CJK, Arabic and Ge'ez punctuation.
    public static func endsClause(_ w: String) -> Bool {
        w.trimmingCharacters(in: CharacterSet(charactersIn: "\"'»”’)」』")).last.map { ",.;:?!…，。；：？！、،؛؟።፣፤፧".contains($0) } ?? false
    }
    /// A short word that leans on the next one, in whatever language (a Chinese or Thai word is short without leaning).
    public static func leansOn(_ w: String) -> Bool { !endsClause(w) && !w.unicodeScalars.contains(where: isUnspaced) && w.filter(\.isLetter).count <= 3 }
    static let leaningEnglish: Set<String> = ["a", "an", "the", "of", "to", "in", "on", "at", "by", "for", "from", "with", "into", "about",
        "as", "and", "or", "but", "if", "than", "that", "which", "who", "whose", "this", "these", "those", "my", "your", "his", "her",
        "its", "our", "their", "i", "you", "he", "she", "it", "we", "they", "is", "are", "was", "were", "be", "been", "am", "do",
        "does", "did", "have", "has", "had", "will", "would", "shall", "should", "can", "could", "may", "might", "must", "not", "no"]
    public static func leansOnEnglish(_ w: String) -> Bool { !endsClause(w) && leaningEnglish.contains(w.lowercased().filter { $0.isLetter || $0 == "'" }) }
    /// Scripts written without spaces between words (Thai, Lao, Tibetan, Burmese, Khmer, CJK).
    public static func isUnspaced(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x0E00...0x0EFF, 0x0F00...0x0FFF, 0x1000...0x109F, 0x1780...0x17FF, 0x2E80...0x2FFF, 0x3000...0x30FF, 0x3100...0x312F,
             0x31A0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x3134F: return true
        default: return false
        }
    }
}
