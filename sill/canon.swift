import Foundation

// ---------- text-anchored hearing: the canon ----------
// Pāli, Ge'ez, Avestan, Syriac, Coptic, Old Irish, and much of Sanskrit have no speech model anywhere: nobody speaks them
// day to day, so there's nothing to learn from. But what is heard in them is nearly always recited from a text that
// is fixed and written down: a sutta, a verse, a mantra, a liturgy. So Recense keeps the texts (canon/*.json in the
// app, more in <cache>/canon/), hears a recitation with whatever ears hear it closest (the open ears write it in
// some script, Apple's in theirs), finds the passage by its sound, and writes the passage's real words, in their own
// script, timed word by word to the voice. The text is known, so nothing is misheard; a recitation that matches no
// text is kept as it was heard.
//   canon/<lang>-<name>.json   {"lang": "pi", "script": "Latn", "source": "…", "texts": [{"id", "title", "lines": […]}]}
// Matching: every word is folded to a plain Latin sound key (any script → Latin, no marks, aspirates and doubled
// letters merged), passages are found by shared 4-letter runs, and the best is aligned letter by letter (local
// alignment); it counts as the passage when ≥ 30 letters align and 62 % of them agree.

enum Canon {
    struct Text {
        var id: String, title: String, lang: String, file: String
        var words: [String]            // as written
        var line: [Int]                // each word's line
        var keys: [String]             // each word's sound key
    }
    struct Match {
        var text: Text
        var from: Int, to: Int         // the text's words, from..<to
        var times: [(Double, Double)]  // each of them, timed
        var heardFrom: Int, heardTo: Int   // the heard words it stands for
        var identity: Double
        var score: Double              // letters that agree × how many of them agree
    }

    nonisolated(unsafe) static var library: [Text] = load()
    nonisolated(unsafe) static var index: [String: [(Int, Int)]] = [:]   // 4-letter run → (text, letter offset)
    nonisolated(unsafe) static var flat: [[UInt8]] = []                   // each text's keys, one run of letters
    nonisolated(unsafe) static var owner: [[Int]] = []                    // each letter's word in its text
    /// The languages a recitation from the canon may be heard as by Apple's ears (Sanskrit as Hindi, Pāli as Thai),
    /// and the canon's own: a hearing in one of them is checked against the texts.
    nonisolated(unsafe) static var hearAs: Set<String> = { _ = library; return heard }()
    nonisolated(unsafe) private static var heard: Set<String> = []

    static func load() -> [Text] {
        var dirs: [URL] = [cacheDir.appendingPathComponent("canon")]
        if let r = Bundle.main.resourceURL?.appendingPathComponent("canon") { dirs.insert(r, at: 0) }
        let dev = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/sill/sill/canon")
        if Bundle.main.resourceURL.map({ !FileManager.default.fileExists(atPath: $0.appendingPathComponent("canon").path) }) ?? true { dirs.append(dev) }
        var out: [Text] = []
        for d in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(contentsOf: f))) as? [String: Any], let lang = o["lang"] as? String,
                      let texts = o["texts"] as? [[String: Any]] else { continue }
                heard.insert(lang); heard.formUnion(o["hearAs"] as? [String] ?? [])
                for t in texts {
                    guard let id = t["id"] as? String, let lines = t["lines"] as? [String] else { continue }
                    var words: [String] = [], line: [Int] = [], keys: [String] = []
                    for (i, l) in lines.enumerated() {
                        for w in l.split(whereSeparator: { $0.isWhitespace }) {
                            let w = String(w).trimmingCharacters(in: CharacterSet(charactersIn: "“”‘’\"'.,;:!?—–-।॥()[]"))
                            let k = fold(w)
                            guard !w.isEmpty, !k.isEmpty else { continue }
                            words.append(w); line.append(i); keys.append(k)
                        }
                    }
                    out.append(Text(id: id, title: t["title"] as? String ?? id, lang: lang, file: f.lastPathComponent, words: words, line: line, keys: keys))
                }
            }
        }
        // the index: every 4-letter run of every text
        index = [:]; flat = []; owner = []
        for (ti, t) in out.enumerated() {
            var letters: [UInt8] = [], who: [Int] = []
            for (wi, k) in t.keys.enumerated() { for b in k.utf8 { letters.append(b); who.append(wi) } }
            flat.append(letters); owner.append(who)
            if letters.count >= 4 { for i in 0...(letters.count - 4) { index[String(decoding: letters[i..<i + 4], as: UTF8.self), default: []].append((ti, i)) } }
        }
        return out
    }

    static var languages: Set<String> { Set(library.map(\.lang)) }

    /// A word's sound, in plain Latin letters: any script to Latin, marks gone, the aspirates and doubled letters
    /// merged, w/v as one, so Pāli heard as Sinhala, Thai or Devanagari, and Sanskrit heard as Gujarati, meet their text.
    static func fold(_ s: String) -> String {
        var t = s.applyingTransform(.toLatin, reverse: false) ?? s
        t = t.applyingTransform(.stripDiacritics, reverse: false) ?? t
        t = t.lowercased()
        var k = String(t.unicodeScalars.filter { ("a"..."z").contains($0) }.map(Character.init))
        for (a, b) in [("kh", "k"), ("gh", "g"), ("ch", "c"), ("jh", "j"), ("th", "t"), ("dh", "d"), ("ph", "p"), ("bh", "b"), ("sh", "s"), ("w", "v")] {
            k = k.replacingOccurrences(of: a, with: b)
        }
        var out = "", last: Character = " "
        for c in k where c != last { out.append(c); last = c }
        return out
    }

    /// The passage `heard` (words with times) recites, if any: the text's words, each timed.
    static func match(_ heard: [(text: String, start: Double, end: Double)]) -> Match? {
        guard !library.isEmpty, !heard.isEmpty else { return nil }
        // the heard words as one run of letters, each letter timed within its word
        var h: [UInt8] = [], hw: [Int] = [], ht: [Double] = []
        for (i, w) in heard.enumerated() {
            let k = Array(fold(w.text).utf8)
            for (j, b) in k.enumerated() {
                h.append(b); hw.append(i)
                ht.append(w.start + (w.end - w.start) * Double(j) / Double(max(1, k.count)))
            }
        }
        guard h.count >= 30 else { return nil }
        // candidate passages: the diagonals where the most 4-letter runs agree
        var votes: [Int: Int] = [:]                       // text * 1_000_000 + diagonal bucket → runs
        for i in 0...(h.count - 4) {
            guard let hits = index[String(decoding: h[i..<i + 4], as: UTF8.self)], hits.count < 400 else { continue }
            for (ti, off) in hits { votes[ti * 1_000_000 + (off - i + 500_000) / 32, default: 0] += 1 }
        }
        let top = votes.sorted { $0.value > $1.value }.prefix(3).filter { $0.value >= 4 }
        var best: Match?
        for (v, _) in top {
            let ti = v / 1_000_000, diag = (v % 1_000_000) * 32 - 500_000
            let t = flat[ti]
            let lo = max(0, diag - 120), hi = min(t.count, diag + h.count + 120)
            guard lo < hi, let m = align(h, Array(t[lo..<hi])) else { continue }
            guard m.matches >= 30, m.identity >= 0.62 else { continue }
            // times: each aligned letter of the text takes its heard letter's time
            var first: [Int: Double] = [:], last: [Int: Double] = [:]
            for (ti2, hi2) in m.pairs {
                let w = owner[ti][lo + ti2]
                if first[w] == nil { first[w] = ht[hi2] }
                last[w] = ht[hi2]
            }
            guard let fw = first.keys.min(), let lw = first.keys.max() else { continue }
            var times: [(Double, Double)] = []
            for w in fw...lw { times.append((first[w] ?? -1, last[w] ?? -1)) }
            // words with no letter aligned: spread between their neighbours
            var i = 0
            while i < times.count {
                if times[i].0 >= 0 { i += 1; continue }
                var j = i; while j < times.count && times[j].0 < 0 { j += 1 }
                let a = i > 0 ? times[i - 1].1 : times[j].0, b = j < times.count ? times[j].0 : times[i - 1].1
                for k in i..<j { let f = Double(k - i + 1) / Double(j - i + 1); let x = a + (b - a) * f; times[k] = (x, x) }
                i = j
            }
            // a word lasts until the next begins (at most a second past its last letter)
            for k in times.indices {
                let next = k + 1 < times.count ? times[k + 1].0 : times[k].1 + 0.5
                times[k].1 = max(times[k].1 + 0.1, min(next - 0.02, times[k].1 + 1))
            }
            let hs = m.pairs.map(\.1)
            let cand = Match(text: library[ti], from: fw, to: lw + 1, times: times, heardFrom: hw[hs.min()!], heardTo: hw[hs.max()!] + 1, identity: m.identity,
                             score: Double(m.matches) * m.identity)
            if cand.score > best?.score ?? 0 { best = cand }
        }
        if let b = best { log(String(format: "canon: %@ (%@) words %d–%d, %.0f%% of letters agree", b.text.title, b.text.lang, b.from, b.to, b.identity * 100)) }
        return best
    }

    /// Smith–Waterman between the heard letters and a stretch of a text: the aligned (text, heard) letter pairs.
    static func align(_ h: [UInt8], _ t: [UInt8]) -> (pairs: [(Int, Int)], matches: Int, identity: Double)? {
        let n = h.count, m = t.count
        guard n > 0, m > 0 else { return nil }
        let match: Int32 = 3, miss: Int32 = -2, gap: Int32 = -2
        func vowel(_ c: UInt8) -> Bool { "aeiou".utf8.contains(c) }
        var H = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        var bestS: Int32 = 0, bi = 0, bj = 0
        for i in 1...n {
            for j in 1...m {
                let a = h[i - 1], b = t[j - 1]
                let s: Int32 = a == b ? match : (vowel(a) && vowel(b) ? -1 : miss)     // a vowel heard as another: half a miss
                let d = H[(i - 1) * (m + 1) + j - 1] + s
                let u = H[(i - 1) * (m + 1) + j] + gap, l = H[i * (m + 1) + j - 1] + gap
                let v = max(0, d, u, l)
                H[i * (m + 1) + j] = v
                if v > bestS { bestS = v; bi = i; bj = j }
            }
        }
        guard bestS > 0 else { return nil }
        var pairs: [(Int, Int)] = [], i = bi, j = bj, same = 0, cols = 0
        while i > 0 && j > 0 && H[i * (m + 1) + j] > 0 {
            let v = H[i * (m + 1) + j], a = h[i - 1], b = t[j - 1]
            let s: Int32 = a == b ? match : (vowel(a) && vowel(b) ? -1 : miss)
            cols += 1
            if v == H[(i - 1) * (m + 1) + j - 1] + s { pairs.append((j - 1, i - 1)); if a == b { same += 1 }; i -= 1; j -= 1 }
            else if v == H[(i - 1) * (m + 1) + j] + gap { i -= 1 }
            else { j -= 1 }
        }
        pairs.reverse()
        return (pairs, same, cols > 0 ? Double(same) / Double(cols) : 0)
    }

    static func report() -> [[String: Any]] {
        library.map { ["id": $0.id, "title": $0.title, "lang": $0.lang, "words": $0.words.count, "file": $0.file] }
    }
}
