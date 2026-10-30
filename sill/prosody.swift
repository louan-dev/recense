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
        /// the tie to the next word (French liaison / enchaînement / elision), nil where there is none
        var link: Link? = nil
        /// the voice runs on into the next word (no pause or breath after this one): the ribbon stays unbroken
        var joins: Bool = false
        /// the sung note of each syllable whose pitch can be trusted: [u (0…1 across the word), MIDI note]
        var notes: [[Float]]? = nil
    }
    struct Link: Codable { var next: Int; var sound: String; var kind: String; var made: Bool }

    /// Everything the drawing needs, cached as one object.
    struct Result: Codable {
        /// schema version: bump when the shape changes, so a stale cache is recomputed rather than misread
        var v: Int = 4
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
              r.v == 4, r.transcript == stamp else { return nil }
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
            <script src="prosogram.js"></script>
            <script>
            // the score (item 20): Gallery's own notation for one row of words, drawn whole at the positions Recense
            // draws them, as a PNG; Recense lays it under the row as a ghost and sweeps the light through it
            window.score = (spec) => {
              const P = window.__P;
              if (!P || P.key !== spec.key || !globalThis.Prosogram) return null;
              const s = spec.size, laneH = s * 1.9, dpr = 2;
              const cells = spec.cells.map(c => { const w = P.words[c.flat]; return w && { w, x: c.x, width: c.w, row: 0, top: 0, y: s * 0.3 }; }).filter(Boolean);
              if (!cells.length) return null;
              const cv = document.createElement('canvas');
              cv.width = Math.max(1, Math.ceil(spec.width * dpr)); cv.height = Math.max(1, Math.ceil(laneH * dpr));
              // two pictures: the prosody (dimmed ahead, revealed by the light) and the score's symbols (lit throughout)
              const one = layer => {
                const ctx = cv.getContext('2d'); ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, cv.width, cv.height); ctx.scale(dpr, dpr);
                Prosogram.plugin.full(ctx, { t: 1e9, pro: P.pro, words: P.words, progress: P.progress, expr: 1, glyphs: false, layer,
                  page: [{ line: { words: cells.map(c => c.w) }, cells, size: s, alpha: 1, lineHeight: laneH, font: s + 'px sans-serif' }],
                  colors: { ahead: 'rgb(150,148,140)', pale: 'rgb(228,224,214)' }, at: () => null, signals: { E: true } });
                return cv.toDataURL('image/png');
              };
              return [one('prosody'), one('symbols'), one('ties')];
            };
            </script>
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

    // ---------- what the window draws ----------

    /// One word's notation as the overlay draws it: its ribbon, its link to the next word, and when the next word starts.
    struct Mark { var line: WordLine; var tie: Link?; var end: Double; var next: Double }
    /// The playing recording's notation, by word (text + start in ms): read by the overlay every frame, no JS involved.
    nonisolated(unsafe) static var live: (key: String, stamp: String, marks: [String: Mark])? = nil
    nonisolated(unsafe) private static var busy: String? = nil
    // ---------- the notation toggle (item 20) ----------
    /// What the overlay draws between a line and its translation, set by the toggle under the home bar's vertical bar:
    /// p = the prosody ribbon, c = the chord progression, n = the sung notes; "" = nothing.
    nonisolated(unsafe) static var mode: String = UserDefaults.standard.string(forKey: "notationMode") ?? "p" {
        didSet { UserDefaults.standard.set(mode, forKey: "notationMode") }
    }
    /// the media time heard now (the overlay's clock, set every frame) and the chords heard so far on this recording
    nonisolated(unsafe) static var now: Double = 0
    nonisolated(unsafe) static var chords: [(t: Double, text: String)] = []
    nonisolated(unsafe) private static var chordsKey = ""
    static func heard(chord text: String?, key: String) {
        guard let text, !text.isEmpty else { return }
        if chordsKey != key { chordsKey = key; chords = [] }
        let t = now
        chords.removeAll { abs($0.t - t) <= 0.4 }
        if let last = chords.last(where: { $0.t < t }), last.text == text { return }
        chords.append((t, text)); chords.sort { $0.t < $1.t }
    }
    /// A note's name as the Key label spells it: English C/do, French Do, Vietnamese Đô (the native language's).
    static func noteName(_ midi: Float, lang: String) -> String {
        let pc = ((Int(midi.rounded()) % 12) + 12) % 12
        let am = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"][pc]
        let fr = ["Do", "Do♯", "Ré", "Mi♭", "Mi", "Fa", "Fa♯", "Sol", "La♭", "La", "Si♭", "Si"][pc]
        let vi = ["Đô", "Đô♯", "Rê", "Mi♭", "Mi", "Fa", "Fa♯", "Son", "La♭", "La", "Si♭", "Si"][pc]
        return lang == "fr" ? fr : lang == "vi" ? vi : am + "/" + fr.lowercased()
    }

    // ---------- the score: Gallery's notation, drawn by prosogram.js for one row ----------
    /// One row's notation pictures, by its layout; asked for once, drawn in the engine page, then only composited.
    nonisolated(unsafe) private static var scores: [String: (NSImage, NSImage, NSImage)] = [:]
    nonisolated(unsafe) private static var asked: [String: Date] = [:]
    /// The picture of a row's notation (cells: each word's flat index, x from the picture's left, width), or nil while
    /// it is being drawn; `ready` runs once it is, so the view redraws.
    @MainActor
    static func score(size: CGFloat, width: CGFloat, cells: [(flat: Int, x: CGFloat, w: CGFloat)], ready: @escaping () -> Void) -> (prosody: NSImage, symbols: NSImage, ties: NSImage)? {
        guard let l = live, let eng = engine else { return nil }
        let id = "\(l.key)|\(Int(size))|\(Int(width))|" + cells.map { "\($0.flat):\(Int($0.x)):\(Int($0.w))" }.joined(separator: ",")
        if let img = scores[id] { return img }
        if let t = asked[id], Date().timeIntervalSince(t) < 1 { return nil }
        asked[id] = Date()
        let spec: [String: Any] = ["key": l.key, "size": size, "width": width, "cells": cells.map { ["flat": $0.flat, "x": $0.x, "w": $0.w] }]
        guard let d = try? JSONSerialization.data(withJSONObject: spec), let json = String(data: d, encoding: .utf8) else { return nil }
        eng.web.evaluateJavaScript("window.score && window.score(\(json))") { value, _ in
            let imgs = (value as? [String] ?? []).compactMap { url -> NSImage? in
                guard let comma = url.firstIndex(of: ","), let png = Data(base64Encoded: String(url[url.index(after: comma)...])),
                      let img = NSImage(data: png) else { return nil }
                img.size = NSSize(width: width, height: size * 1.9); return img
            }
            guard imgs.count == 3 else { return }
            if scores.count > 300 { scores.removeAll() }
            scores[id] = (imgs[0], imgs[1], imgs[2]); asked[id] = nil
            ready()
        }
        return nil
    }

    static func markKey(_ text: String, _ start: Double) -> String { "\(text)@\(Int((start * 1000).rounded()))" }
    static func mark(_ text: String, _ start: Double) -> Mark? { live?.marks[markKey(text, start)] }

    /// Make sure `live` holds the notation of these lines (computed once, cached on disk); a no-op while it's current.
    @MainActor
    static func ensure(key: String, lines: [Line], features f: Features?, lang: String, song: Bool) {
        guard let f else { if live?.key != key { live = nil }; return }
        let words = lines.flatMap { sourceBeats($0) }.map { (text: $0.text, start: $0.start, end: $0.end) }
        guard !words.isEmpty else { return }
        let st = stamp(words)
        if let l = live, l.key == key, l.stamp == st { return }
        if live?.key != key { live = nil }
        guard busy != key + st else { return }
        busy = key + st
        let font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        let input = Input(words: words, lang: lang, kind: song ? "song" : "speech", hop: f.hop, frames: f.count,
                          db: f.db, onset: f.onset, pitch: f.pitch, clarity: f.clarity, voiced: f.voiced, floor: f.floor,
                          measure: { text in
                              let ch = Array(text), total = max(1, (text as NSString).size(withAttributes: [.font: font]).width)
                              return (0...ch.count).map { i in Float((String(ch.prefix(i)) as NSString).size(withAttributes: [.font: font]).width / total) }
                          })
        Task { @MainActor in
            defer { if busy == key + st { busy = nil } }
            guard let r = await compute(key: key, input) else { return }
            var marks: [String: Mark] = [:]
            for wl in r.words where words.indices.contains(wl.flat) {
                let w = words[wl.flat], nx = words.indices.contains(wl.flat + 1) ? words[wl.flat + 1].start : w.end
                marks[markKey(w.text, w.start)] = Mark(line: wl, tie: wl.link?.made == true ? wl.link : nil, end: w.end, next: nx)
            }
            live = (key, st, marks)
            log("prosody: \(marks.count) words on the ribbon, \(marks.values.filter { $0.tie != nil }.count) links (\(lang))")
        }
    }

    /// The words' own language when the recording doesn't say (a cached transcript): fr and vi get their notation.
    @MainActor private static var langs: [String: String] = [:]
    @MainActor static func language(_ lines: [Line]) -> String {
        let text = lines.prefix(40).flatMap(\.words).map(\.text).joined(separator: " ")
        let k = String(text.prefix(200))
        if let l = langs[k] { return l }
        let l = dominantLanguage(text)?.code ?? ""
        langs[k] = l; return l
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
        // (always analysed in the engine page, even with a cached figure: the score is drawn from that analysis)

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
            "key": key,
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
                       cut: Array.from(p.cut).slice(0, p.n),
                       link: x.link && x.link.next != null ? { next: x.link.next, sound: String(x.link.sound || ''),
                             kind: String(x.link.kind || ''), made: (x.link.realized || 0) >= 0.7 } : null,
                       joins: !(x.breathAfter >= 0.12 || x.cutAfter >= 0.85),
                       notes: (x.syl || []).filter(sy => Number.isFinite(sy.pitch) && sy.rel >= 0.4 && sy.un != null).map(sy => [sy.un, sy.pitch]) });
          }
          window.__P = { key: IN.key, pro, words, progress };
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
