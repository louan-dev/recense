// Derived from Spec: FEAT-20 (P1, the Mac's syllable light on iPhone and iPad; route A)
// A song's words lit syllable by syllable on iPhone and iPad, as the Mac lights them. The Mac does the heavy part
// (Demucs separates the voice, Features measures it, keep/<key>/features.json); this device reads that file and hangs
// the words on the voice by the SAME rules (library/src/client/cadence.js, the one the web player runs and the Mac's
// Cadence.fit mirrors rule for rule), then lights each word with `fill` (cadence.js `fill`, the Mac's Cadence.progress).
// Nothing here measures audio: that stays on the Mac (FEAT-20 §Route).
// Status: coded, not compiled, device check owed.
import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

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

    // ---------- the lines, in the shape cadence.js reads (the Worker's `present`) ----------

    static func present(_ lines: [TranscriptLine]) -> [[String: Any]] {
        lines.map { l in
            var o: [String: Any] = ["id": Int(l.id) ?? l.id, "s": l.start, "e": l.end, "text": l.text,
                                    "words": l.words.map { w -> [String: Any] in
                                        var x: [String: Any] = ["t": w.text, "s": w.start, "e": w.end]
                                        if let g = w.lang { x["lang"] = g }
                                        if let p = w.tm {
                                            var m: [String: Any] = ["s": p.s, "e": p.e, "k": p.k]
                                            if let c = p.c { m["c"] = c }
                                            x["tm"] = m
                                        }
                                        return x
                                    }]
            // a line with a translation isn't English: no English spelling rules for its syllables (cadence.js langOf)
            if let tr = l.translation, !tr.isEmpty { o["enw"] = [["w": tr, "s": [Int]()]] }
            return o
        }
    }

    /// The lines with what cadence.js worked out laid back on them, word for word (s, e, syl, un; a listener's timing
    /// kept on tm). A shape that doesn't match the lines leaves them as they were.
    static func merge(_ lines: [TranscriptLine], fitted: [[String: Any]]) -> [TranscriptLine] {
        guard fitted.count == lines.count else { return lines }
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        return zip(lines, fitted).map { l, f in
            guard let ws = f["words"] as? [[String: Any]], ws.count == l.words.count else { return l }
            var out = l
            out.words = zip(l.words, ws).map { w, x in
                var y = w
                if let s = num(x["s"]), let e = num(x["e"]) { y.start = s; y.end = e }
                y.syl = (x["syl"] as? [[String: Any]])?.compactMap { q in
                    guard let c = (q["c"] as? NSNumber)?.intValue, let s = num(q["s"]), let e = num(q["e"]) else { return nil }
                    return Syl(c: c, s: s, e: e)
                }
                if y.syl?.isEmpty == true { y.syl = nil }
                y.un = (x["un"] as? Bool) == true ? true : nil
                if let p = w.tm {   // cadence.js pin: the word's span is the listener's; k or a trace shapes it
                    let c = (x["c"] as? [Any]).flatMap { Pin.trace($0) } ?? p.c
                    y.tm = Pin(s: y.start, e: y.end, k: num(x["k"]) ?? p.k, c: c)
                }
                return y
            }
            if let s = num(f["s"]), let e = num(f["e"]) { out.start = s; out.end = e }
            return out
        }
    }

    // ---------- the engine: cadence.js in JavaScriptCore ----------

    #if canImport(JavaScriptCore)
    /// Gallery's cadence.js, run as it is (no second copy of the rules to drift): no web view, no UI, no network.
    /// One per process; `fit` is called once per opened song, never on the clock path.
    public final class Engine {
        private let context: JSContext
        /// - script: cadence.js's text (the host's bundled copy; the tests read library/src/client/cadence.js).
        public init?(script: String) {
            guard let c = JSContext() as JSContext? else { return nil }
            c.evaluateScript(script)
            guard c.exception == nil, c.evaluateScript("typeof Cadence === 'object' && typeof Cadence.fit === 'function'")?.toBool() == true
            else { return nil }
            context = c
        }

        /// The lines timed to the voice and pinned to the listener's timing (cadence.js `pin(fit(lines, F, shift))`),
        /// or nil when the voice can't be followed or the engine failed (the lines then light by their own times).
        public func fit(_ lines: [TranscriptLine], features: Data) -> [TranscriptLine]? {
            guard !lines.isEmpty, SongLight.usable(features),
                  let l = try? JSONSerialization.data(withJSONObject: SongLight.present(lines)),
                  let ls = String(data: l, encoding: .utf8), let fs = String(data: features, encoding: .utf8) else { return nil }
            context.exception = nil
            context.setObject(ls as NSString, forKeyedSubscript: "__L" as NSString)
            context.setObject(fs as NSString, forKeyedSubscript: "__F" as NSString)
            let r = context.evaluateScript("""
            (() => { const F = JSON.parse(__F); return JSON.stringify(Cadence.pin(Cadence.fit(JSON.parse(__L), F, Number(F.shift) || 0))); })()
            """)
            context.setObject(nil, forKeyedSubscript: "__L" as NSString)
            context.setObject(nil, forKeyedSubscript: "__F" as NSString)
            guard context.exception == nil, let text = r?.toString(), let d = text.data(using: .utf8),
                  let fitted = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return nil }
            return SongLight.merge(lines, fitted: fitted)
        }
    }
    #endif
}
