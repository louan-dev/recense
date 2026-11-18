// Derived from Spec: BUG-24 (P1b: the floating window sweeps too) and FEAT-05 (rules 1, 6, 7: one painter, the window
// a mirror, its frames stamped ahead on the layer's clock).
// What the iPhone and iPad floating window draws, and when: the one painter (`CaptionPainter`) draws each picture, the
// line Follow shows is the one the transcript turns to (`TranscriptLight.following`), and a word of 0.25 s or more gets
// up to 4 pictures, so its light crosses it instead of lighting it whole at its start. The moments are in the light's
// time; `schedule` puts them on the wall at the player's speed (a second of file takes 1/rate seconds at rate).
import CoreGraphics
import Foundation

public enum FloatingFrames {
    /// Pictures inside one word, at most (its start and each further quarter).
    public static let perWord = 4
    /// A word shorter than this keeps one picture (BUG-24 P1b).
    public static let shortWord = 0.25
    /// While a Learn place fades or a phrase turns, a picture this often (the fades last 0.15–0.4 s, a turn 0.3 s).
    public static let fadeStep = 1.0 / 15

    /// A transcript line as the painter reads it (its translation as unaligned words). A line without word times gets
    /// its words spread evenly over its time (at least 0.3 s a word), so it is placed, lit and turned like any other.
    public static func line(_ l: TranscriptLine) -> Caption.Line {
        Caption.Line(words: l.words.isEmpty ? spread(l.text, from: l.start, to: l.end) : l.words, translationText: l.translation)
    }

    /// `text`'s words spread evenly from `from` to `to`, at least 0.3 s each.
    public static func spread(_ text: String, from: Double, to: Double) -> [Word] {
        let ws = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !ws.isEmpty else { return [] }
        let step = max(0.3, (to - from) / Double(ws.count))
        return ws.enumerated().map { i, w in Word(text: w, start: from + step * Double(i), end: from + step * Double(i + 1)) }
    }

    /// Follow on our player: the current line's and the next one's word moments, and the moment the transcript turns to
    /// the next line (it shows whole and grey then, FEAT-05; with Reduce Motion, when it starts, among its words' moments).
    public static func followStamps(_ tls: [TranscriptLine], _ lines: [Caption.Line], after now: Double, ahead: Double,
                                    jump: Bool = false) -> [Double] {
        guard !tls.isEmpty, tls.count == lines.count else { return [] }
        let c = current(tls, at: now, jump: jump) ?? -1
        var out = Set<Double>()
        for j in [c, c + 1] where lines.indices.contains(j) { out.formUnion(stamps(lines[j], after: now, ahead: ahead)) }
        if c + 1 < tls.count, !jump { let at = TranscriptLight.turn(tls, to: c + 1).at; if at > now, at <= now + ahead { out.insert(at) } }
        return out.sorted()
    }

    /// The line Follow shows at t: the one the transcript view turns to, so the window and the app show the same line
    /// (`jump`: Reduce Motion, where the view jumps to the active line; BUG-24 review 7).
    public static func current(_ lines: [TranscriptLine], at t: Double, jump: Bool = false) -> Int? {
        TranscriptLight.following(lines, at: t, jump: jump)
    }

    private static func beats(_ l: Caption.Line) -> [Caption.Beat] { Caption.sourceBeats(l.words) + Caption.translationBeats(l) }
    private static func pieces(_ b: Caption.Beat) -> Int { b.end - b.start >= shortWord ? perWord : 1 }

    /// The moments in (now, now + ahead] at which a line's picture changes: each word's start, each further quarter of
    /// a word of `shortWord` or more, and its end (it turns white), for the original's and the translation's words.
    public static func stamps(_ l: Caption.Line, after now: Double, ahead: Double) -> [Double] {
        var out = Set<Double>()
        for b in beats(l) where !b.un {
            let n = pieces(b)
            for k in 0...n {
                let at = b.start + (b.end - b.start) * Double(k) / Double(n)
                if at > now, at <= now + ahead { out.insert(at) }
            }
        }
        return out.sorted()
    }

    /// Learn: the words' moments of every line the two places show in the window, and every `fadeStep` while a place
    /// fades or one of its phrases turns into its translation.
    public static func learnStamps(_ lines: [Caption.Line], after now: Double, ahead: Double) -> [Double] {
        guard !lines.isEmpty else { return [] }
        var out = Set<Double>(), seen = Set<Int>()
        var x = now + fadeStep
        while x <= now + ahead + 1e-9 {
            let shown = Caption.places(lines, at: x, held: false)
            for s in shown { seen.insert(s.line) }
            if shown.contains(where: { $0.alpha < 1 || turning(lines[$0.line], at: x) }) { out.insert(x) }
            x += fadeStep
        }
        for s in Caption.places(lines, at: now, held: false) { seen.insert(s.line) }
        for j in seen { out.formUnion(stamps(lines[j], after: now, ahead: ahead)) }
        return out.sorted()
    }

    private static func turning(_ l: Caption.Line, at t: Double) -> Bool {
        guard let en = l.translation, !en.isEmpty else { return false }
        let bs = Caption.sourceBeats(l.words)
        return Caption.phrases(l).contains { let u = Caption.turned(l, $0, beats: bs, at: t); return u > 0 && u < 1 }
    }

    /// The stamps on the wall clock (`clock`: the light's time `content` was at `wall`, moving at `rate`). Paused, none.
    public static func schedule(_ stamps: [Double], on clock: ContentClock.Anchor) -> [(at: Double, wall: Double)] {
        stamps.compactMap { at in clock.wall(atContent: at).map { (at, $0) } }
    }

    /// What the picture at t shows, as a key: it changes exactly at the stamps, so a picture is drawn only when it would differ.
    public static func signature(_ lines: [Caption.Line], current: Int?, mode: CaptionMode, at t: Double) -> String {
        func state(_ l: Caption.Line) -> String {
            beats(l).map { b in
                if b.un || t < b.start { return "0" }
                if t >= b.end { return "w" }
                return String(1 + min(pieces(b) - 1, Int(Double(pieces(b)) * (t - b.start) / max(1e-6, b.end - b.start))))
            }.joined()
        }
        switch mode {
        case .follow:
            guard let i = current, lines.indices.contains(i) else { return "-" }
            return "\(i):" + state(lines[i])
        case .learn:
            return Caption.places(lines, at: t, held: false).map { s in
                let l = lines[s.line], bs = Caption.sourceBeats(l.words)
                let turns = l.translation.map { _ in Caption.phrases(l).map { String(Int(Caption.turned(l, $0, beats: bs, at: t) * 10)) }.joined(separator: ",") } ?? ""
                return "\(s.line)@\(s.place)~\(Int(s.alpha * 15)):\(state(l))/\(turns)"
            }.joined(separator: "|")
        }
    }

    /// One picture of the window at t: Follow, `lines[current]` (original over its translation); Learn, the two places.
    public static func draw(_ lines: [Caption.Line], current: Int?, mode: CaptionMode, at t: Double, in ctx: CGContext,
                            box: CGRect, style: CaptionStyle = .init()) {
        switch mode {
        case .follow:
            guard let i = current, lines.indices.contains(i) else { return }
            CaptionPainter.draw(lines[i], mode: .follow, at: t, in: ctx, box: box, style: style)
        case .learn:
            CaptionPainter.drawPlaces(lines, at: t, held: false, in: ctx, box: box, style: style)
        }
    }
}
