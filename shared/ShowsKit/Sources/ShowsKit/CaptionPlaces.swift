// Derived from Spec: FEAT-05 (rule 1, one painter) and SPEC 59 (Learning's two places).
// Moved from the Mac's renderer (strip/recense.swift WordsView.rtl/visual, learningPlaces, readBy) so every surface
// shares them: which script reads right to left, the order words are seen in, and which line holds which place.
import Foundation

extension Caption {
    /// Text in a script read right to left (Persian, Arabic, Urdu, Hebrew, Syriac, Thaana, N'Ko): its letters, by majority.
    public static func rtl(_ s: String) -> Bool {
        var r = 0, l = 0
        for u in s.unicodeScalars where u.properties.isAlphabetic {
            switch u.value {
            case 0x590...0x5FF, 0x600...0x6FF, 0x700...0x74F, 0x750...0x77F, 0x780...0x7BF, 0x7C0...0x7FF, 0x8A0...0x8FF,
                 0xFB1D...0xFB4F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: r += 1
            default: l += 1
            }
        }
        return r > 0 && r >= l
    }

    /// A run of words reads right to left when most of its letters do, or it opens in a right-to-left script and they
    /// are at least a third ("و New York كثيرا" does; an English line with one Arabic word doesn't).
    public static func rtl(words: [String]) -> Bool {
        var r = 0, l = 0, first: Bool? = nil
        for w in words {
            let n = w.unicodeScalars.filter { $0.properties.isAlphabetic }.count
            if n > 0, first == nil { first = rtl(w) }
            if rtl(w) { r += n } else { l += n }
        }
        return r > 0 && (r >= l || (first == true && 2 * r >= l))
    }

    /// Words in the order they are seen left to right. A right-to-left run goes backwards, but words read left to right
    /// inside it ("New York", and a number after them) keep their own order, as the bidi algorithm lays out a line.
    public static func visual<T>(_ xs: [T], rtl: Bool, text: (T) -> String) -> [T] {
        guard rtl else { return xs }
        let kind: [Character] = xs.map { x in
            let t = text(x)
            if Self.rtl(t) { return "r" }
            if t.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) { return "l" }
            return t.unicodeScalars.contains(where: { $0.properties.numericType != nil }) ? "n" : "o"
        }
        var lt = [Bool](repeating: false, count: xs.count), last: Character = "r"
        for i in xs.indices {
            switch kind[i] { case "l": lt[i] = true; last = "l"; case "r": last = "r"; case "n": lt[i] = last == "l"; default: break }
        }
        for i in xs.indices where kind[i] == "o" {     // between two words read left to right, a mark reads with them
            let a = xs[..<i].indices.last { kind[$0] != "o" }, b = xs[(i + 1)...].indices.first { kind[$0] != "o" }
            lt[i] = a.map { lt[$0] } == true && b.map { lt[$0] } == true
        }
        var out: [T] = [], run: [T] = []
        for i in xs.indices.reversed() {
            if lt[i] { run.insert(xs[i], at: 0) } else { out += run; run = []; out.append(xs[i]) }
        }
        return out + run
    }

    /// When a line has been read: its last phrase has turned and been given its reading time; untranslated, a moment
    /// after its last word.
    public static func readBy(_ line: Line) -> Double {
        guard let en = line.translation, !en.isEmpty, en.map(\.w) != ["…"],
              let end = sourceBeats(line.words).last?.end, let last = phrases(line).last else { return line.end + 0.6 }
        return end + turnTime + readingTime(words: last.en.count)
    }

    /// Learning's two places (SPEC 59), one over the other (0 the top), which the lines take in turn. The light crosses
    /// the bottom line; when it has crossed it, that line stays and the next fades in at the top, where the line before
    /// it was (once that one has been read); and so on. A line arrives a moment before it is spoken. A silence of 12 s
    /// clears both and starts again at the top; held (paused), the screen never clears.
    public static func places(_ lines: [Line], at t: Double, held: Bool) -> [(line: Int, place: Int, alpha: Double)] {
        let n = lines.count
        guard n > 0 else { return [] }
        let lead = 0.5, fadeOut = 0.15, fadeIn = 0.4
        func opens(_ k: Int) -> Bool { k == 0 || lines[k].start - lines[k - 1].end >= 12 }
        func place(_ j: Int) -> Int { var k = j; while !opens(k) { k -= 1 }; return (j - k) % 2 }
        func clears(_ j: Int) -> Double { max(lines[j].end + 2.5, readBy(lines[j])) }
        func from(_ j: Int) -> Double {
            if opens(j) { return lines[j].start - 4 }
            if opens(j - 1) { return min(lines[j - 1].end, lines[j].start - lead) }
            let freed = readBy(lines[j - 2]), spoken = min(lines[j - 2].end, lines[j].start - fadeOut - fadeIn)
            return max(min(max(lines[j - 1].end, freed), lines[j].start - lead), spoken)
        }
        func until(_ j: Int) -> Double {
            if j + 1 == n || opens(j + 1) { return clears(j) }
            if j + 2 == n || opens(j + 2) { return clears(j + 1) }
            return from(j + 2)
        }
        var lo = 0, hi = n - 1, now = 0
        while lo <= hi { let m = (lo + hi) / 2; if lines[m].start <= t { now = m; lo = m + 1 } else { hi = m - 1 } }
        var shown: [(line: Int, place: Int, alpha: Double)] = []
        for j in max(0, now - 2)...min(n - 1, now + 2) {
            let a = min((t - from(j) - fadeOut) / fadeIn, (until(j) + fadeOut - t) / fadeOut)
            if a > 0 { shown.append((j, place(j), min(1, a))) }
        }
        if shown.isEmpty, held, t >= lines[now].start, t <= clears(now) + 3 { return [(now, place(now), 1)] }
        return shown
    }
}
