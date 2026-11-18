// Derived from Spec: FEAT-20 (P1, the Mac's syllable light on iPhone and iPad; route A)
// A song's words lit syllable by syllable on iPhone and iPad, as the Mac lights them. The Mac does the heavy part
// (Demucs separates the voice, Features measures it, keep/<key>/features.json); this device reads that file and hangs
// the words on the voice with the Mac's own Cadence (shared/ShowsKit/Cadence, one Swift copy; the web player's
// cadence.js mirrors it rule for rule, checked by Fixtures/songlight.json), then lights each word with `fill` (cadence.js `fill`, the Mac's Cadence.progress).
// Nothing here measures audio: that stays on the Mac (FEAT-20 §Route).
// Status: compiled (iOS + ShowsKit tests), runs the Mac's Cadence; device check owed.
import Foundation

public enum SongLight {

    // ---------- where the voice comes from ----------

    /// The Worker's answer for a file's measured voice (library/src/transcript.js `?f=features`).
    public static func featuresPath(_ path: String) -> String { TranscriptSource.remotePath(path) + "&f=features" }

    /// A voice the light may follow: a vocal stem's (never a mix's: its loudness is the band's), more than 20 frames.
    /// The same test as cadence.js `fit` and the Mac's Cadence.fit.
    public static func usable(_ data: Data) -> Bool {
        struct F: Decodable { let source: String?; let db: [Int]? }
        guard let f = try? JSONDecoder().decode(F.self, from: data) else { return false }
        return f.source == "vocals" && (f.db?.count ?? 0) > 20
    }

    /// A file's measured voice, in the order the offline law asks for (docs/law/offline.md): this device's copy, else
    /// the Mac's (through the Worker), saved here at once so the next open needs no network; nil: none usable (the
    /// light then follows the words' own times, as before). One plain JSON file per media path, as TranscriptCache.
    public static func voice(path: String, dir: URL, fetch: @Sendable (String) async -> Data?) async -> Data? {
        let file = TranscriptCache(dir: dir).file(path)
        if let d = try? Data(contentsOf: file), usable(d) { return d }
        guard let d = await fetch(featuresPath(path)), usable(d) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? d.write(to: file, options: .atomic)
        return d
    }

    /// The Mac's and the web player's light (gallery.js UPCOMING / AHEAD, Cadence's settle): a word not yet sung at
    /// 35 %, a sung word easing from gold into white over 0.45 s.
    public static let ahead = 0.35, settle = 0.45

    // ---------- the light inside a word ----------

    /// How far the light has crossed a word at t, 0…1: cadence.js `fill`, the Mac's Cadence.progress, rule for rule.
    /// - written but not sung (`un`): 0, never lit
    /// - timed by the listener (`tm`): its traced light (c), or one sweep shaped by k, unless k is ~0 and the voice
    ///   gave syllables (then the syllables, inside the listener's span: cadence.js `pin`)
    /// - syllables (`syl`): each syllable's letters spread over the time it is sung, up to where the next comes in
    ///   (or 0.25 s past its end); the last one always reaches the word's last letter
    /// - else even across the word
    public static func fill(_ w: Word, at t: Double) -> Double {
        if w.un == true { return 0 }
        let span = max(0.05, w.end - w.start)
        let u = max(0, min(1, (t - w.start) / span))
        if let p = w.tm {   // the listener's own span (merge has set the word's to it; a word never fitted still has it)
            let u = max(0, min(1, (t - p.s) / max(0.05, p.e - p.s)))
            if let c = p.c, c.count > 1 {
                let x = u * Double(c.count - 1), j = min(c.count - 2, Int(x))
                return c[j] + (c[j + 1] - c[j]) * (x - Double(j))
            }
            if abs(p.k) > 0.05 || (w.syl ?? []).isEmpty { return pow(u, pow(2, -1.5 * p.k)) }
        }
        let n = w.text.unicodeScalars.count
        guard let syl = w.syl, !syl.isEmpty, n > 0 else { return t >= w.end ? 1 : u }
        let nn = Double(n)
        var c0 = 0.0
        for (k, y) in syl.enumerated() {
            let last = k + 1 == syl.count
            let end = last ? y.e : min(syl[k + 1].s, y.e + 0.25)
            let c1 = last ? nn : min(nn, Double(y.c))
            if t < y.s { return c0 / nn }
            if t < end { return min(1, (c0 + (c1 - c0) * (t - y.s) / max(0.05, end - y.s)) / nn) }
            c0 = c1
        }
        return 1
    }

    /// How many of a word's characters are lit at t: `fill` counts code points (as cadence.js and the Mac do), a text
    /// draws whole characters, so the cut is the last character whose code points are all lit.
    public static func litCount(_ w: Word, at t: Double) -> Int {
        let n = w.text.unicodeScalars.count
        guard n > 0 else { return 0 }
        let lit = Int((fill(w, at: t) * Double(n) + 1e-9).rounded(.down))
        var scalars = 0, chars = 0
        for ch in w.text {
            scalars += ch.unicodeScalars.count
            if scalars > lit { break }
            chars += 1
        }
        return chars
    }

    /// A line the voice timed (some word has syllables, a listener's timing or is marked unsung): drawn by `fill`.
    public static func sung(_ line: TranscriptLine) -> Bool { line.words.contains { $0.syl != nil || $0.un == true || $0.tm != nil } }

    // ---------- the engine: the Mac's Cadence, the one Swift copy (shared/ShowsKit/Cadence) ----------

    /// The lines timed to the voice and pinned to the listener's timing (`Cadence.pin(Cadence.fit(…))`, as on the Mac),
    /// or nil when the voice can't be followed (the lines then light by their own times). No web view, no network;
    /// called once per opened song, never on the clock path.
    /// The Worker sends the lines in the file's time and the voice in the transcript's, with `shift` between them
    /// (cadence.js `fit(lines, F, shift)`): the lines go back by it to be fitted and forward by it after, to the ms.
    public static func fit(_ lines: [TranscriptLine], features: Data) -> [TranscriptLine]? {
        struct Shift: Decodable { let shift: Double? }
        guard !lines.isEmpty, usable(features), let f = try? JSONDecoder().decode(Features.self, from: features) else { return nil }
        let d = (try? JSONDecoder().decode(Shift.self, from: features))?.shift ?? 0
        func move(_ ls: [TranscriptLine], _ by: Double) -> [TranscriptLine] {
            by == 0 ? ls : ls.map { $0.with(words: $0.words.map { w in
                let ms = { (x: Double) in (x * 1000).rounded() / 1000 }
                var y = w.shifted(by: by); y.start = ms(y.start); y.end = ms(y.end)
                y.syl = y.syl?.map { Syl(c: $0.c, s: ms($0.s), e: ms($0.e)) }
                y.tm = y.tm.map { Pin(s: ms($0.s), e: ms($0.e), k: $0.k, c: $0.c) }
                return y
            }) }
        }
        return move(Cadence.pin(Cadence.fit(move(lines, -d), f)), d)
    }
}

extension TranscriptLine: CadenceLine {
    public var cadenceID: Int { Int(id) ?? 0 }
    /// The Worker shows a listener's corrected text but sends the words as heard: Cadence's rules for `fixed` don't apply.
    public var fixed: Bool? { nil }
    public var translated: Bool { translation?.isEmpty == false }
    /// The same line with these words, its span theirs (cadence.js: a line runs from its first word to its last).
    public func with(words: [Word]) -> TranscriptLine {
        var l = self; l.words = words
        if let a = words.first, let b = words.last { l.start = a.start; l.end = b.end }
        return l
    }
}
