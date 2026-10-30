import Cocoa
import WebKit

/// Prosody, computed once per recording and cached beside the measured voice.
///
/// `prosody.js` is the ONE implementation of the language layer (French and Vietnamese syllables, tone templates,
/// liaison, stylisation). Porting it to Swift would make a second copy that drifts, so Recense runs the real file in a
/// hidden WKWebView used purely as a compute engine: no UI, no page of its own, nothing on the clock path.
///
/// The contract is deliberately narrow, so this engine could be replaced by a Swift one later without anything else
/// changing:
///   in   the corrected transcript's words (text + start + end), the measured voice, the language, speech or song
///   out  one `WordLine` per word: the polyline the figure is drawn from, and nothing else
///
/// Timing: `measure` is required by prosody.js on purpose (there is no hidden default, because a canvas host and a
/// headless one would otherwise measure different syllable windows for the same audio). Recense passes the **native**
/// glyph widths it actually draws with, so the windows match the lines on screen exactly.
enum Prosody {

    // ---------- what comes back ----------

    /// One word's figure: parallel arrays, as prosody.js produces them.
    ///   u    0…1 across the word's drawn width
    ///   h    −1…+1 height, in the speaker's own range (see `semitone` for what one step is worth)
    ///   w    0…1 thickness (loudness)
    ///   cut  0…1 how detached the line is just after this sample
    struct WordLine: Codable {
        var flat: Int
        var u: [Float]
        var h: [Float]
        var w: [Float]
        var cut: [Float]
    }

    /// Everything the drawing needs, cached as one object.
    struct Result: Codable {
        /// schema version: bump when the shape changes, so a stale cache is recomputed rather than misread
        var v: Int = 1
        /// which transcript this was computed from — a correction changes it and forces a recompute
        var transcript: String
        var lang: String
        var kind: String
        /// height units per semitone, so a drawn interval can be read back in semitones
        var semitone: Float
        var reference: Float
        var span: Float
        var words: [WordLine]
    }

    // ---------- the cache ----------

    static func url(_ key: String) -> URL { cacheDir.appendingPathComponent(key + ".prosody.json") }

    /// The cached figure for `key`, or nil when there is none, it was made by an older schema, or the transcript has
    /// changed since (a fixed word must change the prosogram, so replays stay at zero errors).
    static func cached(_ key: String, transcript stamp: String) -> Result? {
        guard let d = try? Data(contentsOf: url(key)),
              let r = try? JSONDecoder().decode(Result.self, from: d),
              r.v == 1, r.transcript == stamp else { return nil }
        return r
    }

    static func save(_ r: Result, key: String) {
        guard let d = try? JSONEncoder().encode(r) else { return }
        try? d.write(to: url(key), options: .atomic)
    }

    /// A stamp that changes whenever the words or their times do. Corrections land in the words, so this is enough.
    static func stamp(_ words: [(text: String, start: Double, end: Double)]) -> String {
        var h = Hasher()
        for w in words { h.combine(w.text); h.combine(Int((w.start * 1000).rounded())); h.combine(Int((w.end * 1000).rounded())) }
        return String(h.finalize(), radix: 16)
    }

    // ---------- the engine ----------

    /// A hidden web view that holds prosody.js. One per process, created on first use and kept, because starting a
    /// WKWebView costs more than keeping an idle one. It is never shown and never put in a window that moves: the
    /// Translation framework taught us what a moved host view costs (EXC_RESOURCE, ~305k Mach ports; see the
    /// on-device translation note in recense.swift).
    @MainActor private static var engine: Engine?

    @MainActor
    final class Engine: NSObject, WKNavigationDelegate {
        let web: WKWebView
        private var ready = false
        private var waiting: [(Bool) -> Void] = []

        override init() {
            let cfg = WKWebViewConfiguration()
            web = WKWebView(frame: .zero, configuration: cfg)
            super.init()
            web.navigationDelegate = self
            guard let dir = Bundle.main.resourceURL?.appendingPathComponent("homebar"),
                  FileManager.default.fileExists(atPath: dir.appendingPathComponent("prosody.js").path) else {
                log("prosody: Resources/homebar/prosody.js is missing (build.sh copies it from Gallery)")
                return
            }
            // A page with nothing in it but the language layer.
            let html = """
            <!doctype html><meta charset="utf-8"><title>prosody</title>
            <script src="prosody.js"></script>
            """
            web.loadHTMLString(html, baseURL: dir)
        }

        func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
            ready = true
            let fire = waiting; waiting = []
            for f in fire { f(true) }
        }

        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { fail(e) }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { fail(e) }
        private func fail(_ e: Error) {
            log("prosody: engine failed to load — \(e.localizedDescription)")
            let fire = waiting; waiting = []
            for f in fire { f(false) }
        }

        func whenReady(_ done: @escaping (Bool) -> Void) {
            if ready { done(true) } else { waiting.append(done) }
        }
    }

    // ---------- computing ----------

    struct Input {
        var words: [(text: String, start: Double, end: Double)]
        var lang: String                 // "fr", "vi", … ; "" for the generic syllabifier
        var kind: String                 // "song" | "speech"
        var hop: Double
        var frames: Int
        var db: [Int], onset: [Int], pitch: [Int], clarity: [Int], voiced: [Int]
        var floor: Double
        /// Character-boundary fractions of each word's drawn width, measured with the font Recense draws with.
        /// Supplied by the caller precisely so the syllable windows match the lines on screen.
        var measure: (String) -> [Float]
    }

    /// Compute the figure, or return the cached one. Never called while playing: the result is cached and the drawing
    /// reads stored values, so no JavaScript ever runs on the clock path.
    @MainActor
    static func compute(key: String, _ input: Input) async -> Result? {
        let stamp = stamp(input.words)
        if let hit = cached(key, transcript: stamp) { return hit }

        if engine == nil { engine = Engine() }
        guard let eng = engine else { return nil }
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            eng.whenReady { c.resume(returning: $0) }
        }
        guard ok else { return nil }

        // Everything prosody.js needs, as JSON. `measure` cannot cross as a function, so its result is precomputed
        // per word and passed as a table the page turns back into a function.
        var widths: [[Float]] = []
        widths.reserveCapacity(input.words.count)
        for w in input.words { widths.append(input.measure(w.text)) }

        let payload: [String: Any] = [
            "words": input.words.enumerated().map { ["text": $0.element.text, "s": $0.element.start, "e": $0.element.end, "flat": $0.offset] },
            "widths": widths,
            "lang": input.lang,
            "kind": input.kind,
            "hop": input.hop,
            "frames": input.frames,
            "features": ["db": input.db, "onset": input.onset, "pitch": input.pitch,
                         "clarity": input.clarity, "voiced": input.voiced, "floor": input.floor],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return nil }

        let js = """
        (() => {
          const IN = \(json);
          const F = IN.features, hop = IN.hop, n = IN.frames;
          const words = IN.words.map(w => ({ text: w.text, s: w.s, e: w.e, flat: w.flat }));
          // the host's own glyph metrics, as a table: no canvas is involved anywhere in here
          const W = IN.widths;
          const measure = (text) => {
            const i = words.findIndex(w => w.text === text);
            const a = i >= 0 ? W[i] : null;
            if (a) return Float32Array.from(a);
            const m = [...text].length, out = new Float32Array(m + 1);
            for (let j = 0; j <= m; j++) out[j] = j / Math.max(1, m);
            return out;
          };
          const dbAt = (t) => { const k = Math.round(t / hop); return k < 0 || k >= n ? 0 : F.db[k] / 10; };
          const at = (sig, t) => sig === 'E'
            ? Math.max(0, Math.min(1, (dbAt(t) - F.floor) / 30))
            : null;
          const progress = (w, t) => Math.max(0, Math.min(1, (t - w.s) / Math.max(1e-6, w.e - w.s)));
          const pro = Prosody.analyze(
            { features: F, hop, frames: n, lang: IN.lang, kind: IN.kind },
            { at, progress, words, measure });
          const out = [];
          for (const w of words) {
            const x = pro.word[w.flat];
            if (!x || !x.pts || !x.pts.n) continue;
            const p = x.pts;
            out.push({ flat: w.flat,
                       u: Array.from(p.u).slice(0, p.n),
                       h: Array.from(p.h).slice(0, p.n),
                       w: Array.from(p.w).slice(0, p.n),
                       cut: Array.from(p.cut).slice(0, p.n) });
          }
          return JSON.stringify({ semitone: pro.semitone, reference: pro.reference, span: pro.span, words: out });
        })()
        """

        let text: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            eng.web.evaluateJavaScript(js) { value, error in
                if let error { log("prosody: compute failed — \(error.localizedDescription)"); c.resume(returning: nil); return }
                c.resume(returning: value as? String)
            }
        }
        guard let text, let d = text.data(using: .utf8) else { return nil }

        struct Raw: Decodable { var semitone: Float; var reference: Float; var span: Float; var words: [WordLine] }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: d) else {
            log("prosody: compute returned something unreadable")
            return nil
        }
        let r = Result(transcript: stamp, lang: input.lang, kind: input.kind,
                       semitone: raw.semitone, reference: raw.reference, span: raw.span, words: raw.words)
        save(r, key: key)
        return r
    }
}
