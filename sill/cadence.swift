import Foundation

// Cadence's voice-first pass, rule for rule with Gallery's cadence.js (`syllables`, `unitsOf`, `align`): change one,
// change the other, so Sill, the web player and the iOS app light the same syllable at the same moment.
// The audio is the truth and the words are a label on it: the voice's own syllables are found from the stem alone, then
// a song's words are hung on them over the whole song at once. A word sung is lit syllable by syllable and held for as
// long as it's sung; a word written but not sung is never lit (owner 2026-10-30: Variations on a Dream at 1:20, 1:52,
// 2:35; notes 20261029 row 35).
extension Cadence {
    private static let vowels: Set<Character> = Set("aeiouyæœøåıəаеёиоуыэюяіїєαεηιουω")

    /// A word's syllables, as where each ends in its letters (code points). Han, kana, Hangul and Ethiopic: a letter
    /// each. Latin, Cyrillic and Greek: one per run of vowels, split where two vowels are sung apart (va-ri-a-tions; not
    /// the -tion of "nation"), the consonants between two going to the second (or one to each, from two on, but pl,
    /// br… together). English drops a silent final e, -es or -ed (love, loves, liked; not the, lit-tle, wan-ted).
    static func syllables(_ word: String, lang: String?) -> [Int] {
        let cs = Array(word.unicodeScalars)
        if cs.isEmpty { return [] }
        if word.range(of: #"[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}\p{Script=Ethiopic}]"#, options: .regularExpression) != nil {
            var out: [Int] = []
            for (k, c) in cs.enumerated() {
                if c.properties.isAlphabetic { out.append(k + 1) } else if !out.isEmpty { out[out.count - 1] = k + 1 }
            }
            return out.isEmpty ? [cs.count] : out
        }
        let base: [Character] = cs.map { s in
            let d = String(s).decomposedStringWithCanonicalMapping.unicodeScalars.first ?? s
            return Character(String(d).lowercased().unicodeScalars.first.map(String.init) ?? String(d))
        }
        let isV = base.map { vowels.contains($0) }
        var nuclei: [(a: Int, b: Int)] = []
        for k in 0..<cs.count where isV[k] {
            if let last = nuclei.last, last.b == k {
                let hiatus = base[k - 1] == "i" && k >= 2 && !"tscgx".contains(base[k - 2]) && last.b - last.a == 1
                if !hiatus { nuclei[nuclei.count - 1].b = k + 1; continue }
            }
            nuclei.append((k, k + 1))
        }
        if nuclei.isEmpty { return [cs.count] }
        let en = lang == nil || lang!.hasPrefix("en")
        let lastN = nuclei[nuclei.count - 1]
        let tail = String(base[lastN.b...].filter { $0.isLetter })
        let before = String(base[..<lastN.a])
        let consL = before.range(of: #"[^aeiouy]l$"#, options: .regularExpression) != nil
        if en, nuclei.count > 1, lastN.b - lastN.a == 1, base[lastN.a] == "e",
           (tail.isEmpty && !consL)
            || (tail == "s" && before.range(of: #"(s|z|x|ch|sh|c|g)$"#, options: .regularExpression) == nil)
            || (tail == "d" && before.range(of: #"[td]$"#, options: .regularExpression) == nil) { nuclei.removeLast() }
        var out: [Int] = []
        for j in 0..<(nuclei.count - 1) {
            let a = nuclei[j].b, gap = nuclei[j + 1].a - a
            let onset = gap == 2 && "bcdfgkpt".contains(base[a]) && "lr".contains(base[a + 1])
            out.append(a + (gap >= 2 && !onset ? 1 : 0))
        }
        out.append(cs.count)
        return out
    }

    /// A syllable the voice sang: from, to, its middle pitch (MIDI × 100), its loudest (dB), and weak (15 dB or more
    /// under the song's sung level, or 11 semitones or more from the singer's middle: bleed, an octave slip, a breath).
    struct Unit { var s: Double, e: Double, m: Int, db: Double, weak: Bool }

    /// The voice's own syllables, from the stem alone: where it's pitched, cut where it stops for 30 ms or more (a
    /// consonant, a breath) and where its loudness dips 2.5 dB or more between two peaks (syllables sung legato on one
    /// breath). A pitch move with no dip stays inside its syllable (a held word falling to its next note).
    static func units(_ f: Features) -> [Unit] {
        let n = f.count, p = f.pitch, db = f.db
        let on = { (k: Int) in f.isVoiced(k) && p[k] > 0 }
        var L = [Double](repeating: 0, count: n)
        for k in 0..<n {
            var s = 0.0, c = 0.0
            for j in max(0, k - 3)...min(n - 1, k + 3) { s += Double(db[j]); c += 1 }
            L[k] = s / c
        }
        var runs: [(Int, Int)] = []
        var a = -1, last = -1
        for k in 0..<n {
            if on(k) { if a < 0 { a = k }; last = k }
            else if a >= 0 && k - last > 2 { if last + 1 - a >= 6 { runs.append((a, last + 1)) }; a = -1 }
        }
        if a >= 0 && last + 1 - a >= 6 { runs.append((a, last + 1)) }
        var out: [Unit] = []
        for (x, y) in runs {
            var cuts = [x]
            var peak = -Double.infinity, trough = Double.infinity, tk = -1, falling = false
            for k in x..<y {
                let v = L[k]
                if !falling { if v > peak { peak = v } else if peak - v >= 25 { falling = true; trough = v; tk = k } }
                else if v < trough { trough = v; tk = k }
                else if v - trough >= 25 { if tk - cuts[cuts.count - 1] >= 6 && y - tk >= 6 { cuts.append(tk) }; falling = false; peak = v }
            }
            cuts.append(y)
            for i in 0..<(cuts.count - 1) {
                let u = cuts[i], v = cuts[i + 1]
                var ps: [Int] = [], top = -Double.infinity
                for k in u..<v { if p[k] > 0 { ps.append(p[k]) }; if L[k] > top { top = L[k] } }
                ps.sort()
                out.append(Unit(s: f.time(u), e: f.time(v), m: ps.isEmpty ? 0 : ps[ps.count >> 1], db: top / 10, weak: false))
            }
        }
        if !out.isEmpty {
            let lv = out.map(\.db).sorted()[out.count * 3 / 4]
            let byLen = out.filter { $0.m > 0 }.map { ($0.m, $0.e - $0.s) }.sorted { $0.0 < $1.0 }
            var half = byLen.reduce(0) { $0 + $1.1 } / 2, reg = byLen.first?.0 ?? 0
            for (m, d) in byLen { reg = m; half -= d; if half <= 0 { break } }
            for i in out.indices { out[i].weak = out[i].db < lv - 15 || (out[i].m > 0 && abs(out[i].m - reg) >= 1100) }
        }
        return out
    }

    /// Lyric to voice (see cadence.js `align` for the costs, kept the same): a song's words (lines with ids 2 000 000
    /// and up) hung on the voice's syllables over the whole song by dynamic programming. `s`/`e` are retimed in place;
    /// → per word its syllables (nil: as it was) and whether it's unsung.
    static func align(_ lines: [Line], _ f: Features, _ flat: [Word], _ s: inout [Double], _ e: inout [Double]) -> (syl: [[Syl]?], un: [Bool]) {
        let F = flat.count
        var res = [[Syl]?](repeating: nil, count: F), un = [Bool](repeating: false, count: F)
        struct Y { let i: Int, c: Int, exp: Double, wt: Double, inner: Bool, first: Bool, end: Bool, fx: Bool }
        var Ys: [Y] = []
        var at = 0
        for l in lines {
            let from = at, c = l.words.count
            at += c
            guard c > 0, l.id >= 2_000_000 else { continue }
            let hint: String? = (l.english?.isEmpty == false) ? "und" : nil
            // a line a listener wrote (a text override, or one of Recense's own edits): Gallery's `fixed`
            let fx = l.fixed == true || (l.id >= edited && l.id < edited + cutShort)
            for i in from..<at {
                let cut = syllables(flat[i].text, lang: flat[i].lang ?? hint), K = max(1, cut.count)
                for k in 0..<K {
                    Ys.append(Y(i: i, c: k < cut.count ? cut[k] : flat[i].text.unicodeScalars.count,
                                exp: s[i] + (e[i] - s[i]) * Double(k) / Double(K), wt: (k > 0 ? 0.3 : 1) * (fx ? 0.25 : 1),
                                inner: k > 0, first: i == from && k == 0, end: i == at - 1 && k == K - 1, fx: fx))
                }
            }
        }
        guard !Ys.isEmpty else { return (res, un) }
        let lo = Ys.map(\.exp).min()! - 3, hi = Ys.map(\.exp).max()! + 3
        let U = units(f).filter { $0.s >= lo && $0.s < hi }
        let N = U.count, S = Ys.count
        guard N > 0 else { return (res, un) }
        var P = [Double](repeating: 0, count: N + 1), M = [Double](repeating: 0, count: N), Mend = M, gap = M
        for k in 0..<N {
            P[k + 1] = P[k] + min(4, (U[k].e - U[k].s) / 0.15) * (U[k].weak ? 0.15 : 1)
            gap[k] = k > 0 ? U[k].s - U[k - 1].e : .infinity
        }
        for k in 1..<max(1, N) {
            let g = gap[k]
            M[k] = M[k - 1] + (g <= 0.03 ? 1.2 : g < 0.3 ? 1.6 : 3 + g)
            Mend[k] = Mend[k - 1] + (g <= 0.03 ? 0.4 : g < 0.3 ? 0.8 : 3 + g)
        }
        func start(_ y: Y, _ a: Int) -> Double {
            y.wt * min(4, abs(U[a].s - y.exp) / 0.5) + (U[a].weak ? 1.5 : 0) - (y.first && gap[a] >= 0.5 ? 1 : 0)
        }
        var how: [[Int]] = [], back: [[Int]] = [], fl: [[Bool]] = [], uf: [[Bool]] = []
        var prevS = [Double](repeating: .infinity, count: N + 1), prevU = prevS
        prevS[0] = 0
        for y in 0..<S {
            let Y0 = Ys[y], Mx = Y0.end ? Mend : M, c = Y0.first ? 0.0 : 1.2
            var prev = [Double](repeating: 0, count: N + 1), pf = [Bool](repeating: false, count: N + 1)
            for j in 0...N { let u = prevU[j] < prevS[j]; prev[j] = u ? prevU[j] : prevS[j]; pf[j] = u }
            var curS = [Double](repeating: .infinity, count: N + 1), curU = curS
            var h = [Int](repeating: -2, count: N + 1), bq = [Int](repeating: 0, count: N), w = [Bool](repeating: false, count: N + 1)
            var mq = Double.infinity, q = -1, ma = Double.infinity, a0 = -1
            for a in 0..<N {
                let v0 = prev[a] - P[a] - c * (a > 0 ? U[a - 1].e : U[0].s)
                if v0 < mq { mq = v0; q = a }
                let from: Double
                if Y0.inner { from = gap[a] < 1 || a == 0 ? prev[a] : .infinity; bq[a] = a }
                else { from = P[a] + c * U[a].s + mq; bq[a] = q }
                let best = from + start(Y0, a) - Mx[a]
                if best < ma { ma = best; a0 = a }
                let v = Mx[a] + ma
                if v < curS[a + 1] { curS[a + 1] = v; h[a + 1] = a0 }
            }
            let share = Y0.inner ? 1.0 : 1.3
            if N >= 1 { for j in 1...N where prevS[j] + share < curS[j] { curS[j] = prevS[j] + share; h[j] = -3 } }
            let afterS = Y0.inner ? 4.0 : 3.0, afterU = Y0.inner ? 1.5 : 3.0
            for j in 0...N {
                let x = prevS[j] + afterS, z = prevU[j] + afterU
                if z < x { curU[j] = z; w[j] = true } else { curU[j] = x }
            }
            how.append(h); back.append(bq); fl.append(pf); uf.append(w)
            prevS = curS; prevU = curU
        }
        var j = 0, sung = true, bestEnd = Double.infinity
        for k in 0...N {
            let tail = P[N] - P[k]
            if prevS[k] + tail < bestEnd { bestEnd = prevS[k] + tail; j = k; sung = true }
            if prevU[k] + tail < bestEnd { bestEnd = prevU[k] + tail; j = k; sung = false }
        }
        guard bestEnd < .infinity else { return (res, un) }
        var got = [(s: Double, e: Double, x: Int)?](repeating: nil, count: S)
        for y in stride(from: S - 1, through: 0, by: -1) {
            if !sung { sung = !uf[y][j]; continue }
            let a = how[y][j]
            if a == -3 { got[y] = (0, 0, j - 1); continue }
            if a < 0 { break }
            got[y] = (U[a].s, U[j - 1].e, -1)
            j = back[y][a]
            sung = !fl[y][j]
        }
        // a sung syllable shared: its owner and the ones run into it split it evenly
        var y = 0
        while y < S {
            defer { y += 1 }
            guard let g = got[y], g.x >= 0, y > 0, let o = got[y - 1] else { continue }
            var z = y
            while z + 1 < S, let g2 = got[z + 1], g2.x == g.x { z += 1 }
            let u = U[g.x], t0 = max(u.s, o.s), d = (u.e - t0) / Double(z - y + 2)
            got[y - 1] = (o.s, t0 + d, -1)
            for k in y...z { got[k] = (t0 + d * Double(k - y + 1), t0 + d * Double(k - y + 2), -1) }
            y = z
        }
        // each word from its syllables; an unsung one inside a sung word takes the time between its neighbours
        var lastEnd = 0.0
        for i in 0..<F {
            let ys = (0..<S).filter { Ys[$0].i == i }
            if ys.isEmpty { continue }
            let sungYs = ys.filter { got[$0] != nil }
            // a word a listener wrote in is sung (they heard it): with no syllable of its own it keeps the time it was
            // given, between its neighbours, and the light goes on over it (Whitacre's "A world", owner 2026-10-30)
            if sungYs.isEmpty && Ys[ys[0]].fx {
                s[i] = max(lastEnd, s[i]); e[i] = max(s[i] + 0.05, e[i])
                lastEnd = e[i]
                continue
            }
            if sungYs.isEmpty {
                un[i] = true
                s[i] = max(lastEnd, min(s[i], i + 1 < F ? s[i + 1] : s[i])); e[i] = s[i]
                continue
            }
            let ns = got[sungYs[0]]!.s, ne = max(ns + 0.05, got[sungYs[sungYs.count - 1]]!.e)
            var out = ys.map { k in (c: Ys[k].c, s: got[k]?.s ?? .nan, e: got[k]?.e ?? .nan) }
            for k in out.indices where out[k].s.isNaN {
                let before = k > 0 ? out[k - 1].e : ns
                let after = out[(k + 1)...].first { !$0.s.isNaN }
                out[k].s = before
                out[k].e = after?.s ?? max(before, ne)
            }
            s[i] = ns; e[i] = ne
            res[i] = out.map { Syl(c: $0.c, s: $0.s, e: $0.e) }
            lastEnd = ne
        }
        // in order still, and none running into the next
        for i in 1..<max(1, F) where s[i] < s[i - 1] { s[i] = s[i - 1] }
        for i in 0..<max(0, F - 1) {
            if un[i] { e[i] = s[i]; continue }
            var k = i + 1
            while k < F && un[k] { k += 1 }
            if k < F && s[k] > s[i] && e[i] > s[k] { e[i] = max(s[i] + 0.05, s[k]) }
            if let r = res[i] { res[i] = r.map { y in let ye = min(y.e, e[i]); return Syl(c: y.c, s: min(y.s, ye), e: ye) } }
        }
        return (res, un)
    }
}
