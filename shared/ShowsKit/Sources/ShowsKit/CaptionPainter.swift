// Derived from Spec: FEAT-05 (P1, the one painter)
// Draws a caption line into any CGContext: the in-app Learn and Follow views, the Mac's floating panel and the iOS
// floating window's frames all call it, so they are the same pixels (FEAT-05 rule 1). Core Text and Core Graphics
// only, so it runs on the Mac and on iOS alike.
//   Follow  the original on top (semibold, ≤ 3 rows), its translation under it (regular, ≤ 2 rows), both lit word by word.
//   Learn   one run of phrases (semibold, ≤ 2 rows): each phrase dissolves into its translation `Caption.turnTime`
//           after it is heard, in place; its width eases from the original's to the translation's, so the row
//           re-flows with no gaps and re-centres (Reduce Motion: the width snaps and only the dissolve remains).
// Colours (measured from the owner's reference videos, FEAT-05): spoken white, the word being spoken gold up to the
// light's edge, not yet spoken white at 55 %. A row too long shrinks the text (to 60 % at most) before it is cut.
// Balance (each language its own size and opacity; a hidden side takes no room), a guessed line at half, a
// "translating…" placeholder, right-to-left rows, and Learning's two places (`drawPlaces`) came from the Mac's renderer
// (option A, 11-17). The Mac keeps prominence (SPEC 47) and its voice glow until FEAT-05 P4.
import CoreGraphics
import CoreText
import Foundation

public enum CaptionMode: String, Sendable { case learn, follow }

public struct CaptionStyle: Sendable {
    public var size: CGFloat = 28
    public var spoken = CGColor(srgbRed: 0xF2 / 255.0, green: 0xF1 / 255.0, blue: 0xF1 / 255.0, alpha: 1)
    public var current = CGColor(srgbRed: 0xF5 / 255.0, green: 0xE3 / 255.0, blue: 0x99 / 255.0, alpha: 1)
    public var upcoming = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55)
    /// A soft shadow so the text reads over any picture (there is no panel behind it).
    public var shadow = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6)
    public var reduceMotion = false
    /// Balance (the Mac's Text Size and Balance menu): the original's (1) and the translation's (2) size and opacity.
    public struct Balance: Sendable, Equatable {
        public var l1: CGFloat, l2: CGFloat, a1: CGFloat, a2: CGFloat
        public init(l1: CGFloat = 1, l2: CGFloat = 1, a1: CGFloat = 1, a2: CGFloat = 1) { self.l1 = l1; self.l2 = l2; self.a1 = a1; self.a2 = a2 }
    }
    public var balance = Balance()
    /// A line still being heard (a guess): the original at half.
    public var guess = false
    /// Shown, dim, where a translation not yet back will go (Follow); nil shows nothing.
    public var translating: String? = nil
    public init() {}
}

public enum CaptionPainter {
    /// A word or a phrase placed on the canvas (Core Graphics coordinates: y grows upward; `rect` is its line box).
    public struct Item {
        public enum Kind: Sendable { case original, translation }
        public let kind: Kind
        public let text: String
        public let rect: CGRect
        public let font: CTFont
        /// Its beat (Follow, and a Learn phrase's words).
        public let beat: Caption.Beat?
        /// Learn: how far its phrase has turned into the translation (0 … 1); the original fades by it, the translation shows by it.
        public let alpha: CGFloat
        /// The "translating…" placeholder: drawn as not yet spoken.
        public var placeholder = false
    }

    public struct Layout {
        public var items: [Item] = []
        public var scale: CGFloat = 1
    }

    // ---------- layout ----------

    public static func layout(_ line: Caption.Line, mode: CaptionMode, at t: Double, in box: CGRect, style: CaptionStyle = .init()) -> Layout {
        var scale: CGFloat = 1
        while true {
            if let l = attempt(line, mode: mode, at: t, in: box, style: style, scale: scale) { return l }
            if scale <= 0.6 { return attempt(line, mode: mode, at: t, in: box, style: style, scale: scale, force: true)! }
            scale = max(0.6, scale * 0.9)
        }
    }

    static func font(_ size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    }

    static func width(_ s: String, _ f: CTFont) -> CGFloat {
        let l = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.init(kCTFontAttributeName as String): f]))
        return CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
    }

    static func lineHeight(_ f: CTFont) -> CGFloat { ceil(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)) }

    /// A run of pieces wrapped into rows no wider than `w` (greedy), or nil when it needs more than `max` rows.
    static func wrap(_ widths: [CGFloat], space: CGFloat, width w: CGFloat, max: Int) -> [[Int]]? {
        var rows: [[Int]] = [[]], used: CGFloat = 0
        for (i, x) in widths.enumerated() {
            let add = rows[rows.count - 1].isEmpty ? x : space + x
            if !rows[rows.count - 1].isEmpty, used + add > w { rows.append([i]); used = x } else { rows[rows.count - 1].append(i); used += add }
        }
        return rows.count <= max ? rows : nil
    }

    private static func attempt(_ line: Caption.Line, mode: CaptionMode, at t: Double, in box: CGRect, style: CaptionStyle,
                                scale: CGFloat, force: Bool = false) -> Layout? {
        let bal = style.balance, en = line.translation ?? []
        let translated = !en.isEmpty, dim: CGFloat = style.guess ? 0.5 : 1
        let bold = font(style.size * scale * bal.l1, bold: true), regular = font(style.size * scale * bal.l2, bold: false)
        var out = Layout(scale: scale)
        var blocks: [[Piece]] = []
        var rowsOf: [[[Int]]] = []

        switch mode {
        case .follow:
            // Balance: each side its own size and opacity; a hidden side takes no room (untranslated speech always shows)
            if bal.a1 > 0 || !translated {
                let a = (translated ? bal.a1 : 1) * dim
                let src = Caption.sourceBeats(line.words).map { b in Piece(text: b.text, w: width(b.text, bold), kind: .original, font: bold, beat: b, alpha: a) }
                guard let r = wrap(src.map(\.w), space: width(" ", bold), width: box.width, max: force ? .max : 3) else { return nil }
                blocks.append(src); rowsOf.append(r)
            }
            if translated, bal.a2 > 0 {
                let tr = Caption.translationBeats(line).map { b in Piece(text: b.text, w: width(b.text, regular), kind: .translation, font: regular, beat: b, alpha: bal.a2) }
                guard let r2 = wrap(tr.map(\.w), space: width(" ", regular), width: box.width, max: force ? .max : 2) else { return nil }
                blocks.append(tr); rowsOf.append(r2)
            } else if line.translation == nil, bal.a2 > 0, let wait = style.translating {
                blocks.append([Piece(text: wait, w: width(wait, regular), kind: .translation, font: regular, beat: nil, alpha: bal.a2, placeholder: true)])
                rowsOf.append([[0]])
            }
        case .learn:
            // Balance: L2 hidden (or nothing to turn into): the original's words only, at the line's size, no turning
            let turns = translated && en.map(\.w) != ["…"] && bal.a2 > 0
            let orig = turns ? bold : font(style.size * scale, bold: true)
            let h = max(lineHeight(orig), turns ? lineHeight(regular) : 0), sp = width(" ", orig)
            let beats = Caption.sourceBeats(line.words)
            let ph = turns ? Caption.phrases(line) : [Caption.Phrase(src: 0..<beats.count, en: 0..<0)]
            var cells: [Piece] = []
            var cellWidths: [CGFloat] = []
            for p in ph {
                let o = p.src.map { beats[$0].text }.joined(separator: " ")
                let e = p.en.map { en[$0].w }.joined(separator: " ")
                let wo = width(o, orig), we = e.isEmpty ? wo : width(e, regular)
                let u = turns ? CGFloat(Caption.turned(line, p, beats: beats, at: t)) : 0
                let eased = u * u * (3 - 2 * u)
                let w = style.reduceMotion ? (u < 0.5 ? wo : we) : wo + (we - wo) * eased
                cellWidths.append(w)
                // the cell is drawn as its words (so each lights by its own beat) and, while it turns, its translation;
                // a right-to-left phrase's words run right to left inside it (the phrases keep the translation's order)
                let ws = p.src.map { beats[$0] }
                for b in Caption.visual(ws, rtl: Caption.rtl(words: ws.map(\.text)), text: \.text) {
                    cells.append(Piece(text: b.text, w: width(b.text, orig), kind: .original, font: orig, beat: b, alpha: (1 - u) * (turns ? bal.a1 : 1) * dim))
                }
                if u > 0, !e.isEmpty { cells.append(Piece(text: e, w: we, kind: .translation, font: regular, beat: nil, alpha: u * bal.a2)) }
            }
            // wrap by cell, then place each cell's pieces inside its eased width
            guard let rows = wrap(cellWidths, space: sp, width: box.width, max: force ? .max : 2) else { return nil }
            var y = box.midY + CGFloat(rows.count) * h / 2 - h
            var pieceAt = 0
            var perCell: [[Int]] = []
            for p in ph {
                var idx = Array(pieceAt..<(pieceAt + p.src.count)); pieceAt += p.src.count
                if pieceAt < cells.count, cells[pieceAt].kind == .translation, cells[pieceAt].beat == nil { idx.append(pieceAt); pieceAt += 1 }
                perCell.append(idx)
            }
            for row in rows {
                let rw = row.map { cellWidths[$0] }.reduce(0, +) + sp * CGFloat(max(0, row.count - 1))
                var x = box.midX - rw / 2
                for c in row {
                    let cw = cellWidths[c]
                    let words = perCell[c].filter { cells[$0].kind == .original }
                    let ow = words.map { cells[$0].w }.reduce(0, +) + sp * CGFloat(max(0, words.count - 1))
                    var wx = x + (cw - ow) / 2
                    for i in words {
                        let p = cells[i]
                        out.items.append(Item(kind: .original, text: p.text, rect: CGRect(x: wx, y: y, width: p.w, height: h), font: p.font, beat: p.beat, alpha: p.alpha))
                        wx += p.w + sp
                    }
                    for i in perCell[c] where cells[i].kind == .translation {
                        let p = cells[i]
                        out.items.append(Item(kind: .translation, text: p.text, rect: CGRect(x: x + (cw - p.w) / 2, y: y, width: p.w, height: h), font: p.font, beat: nil, alpha: p.alpha))
                    }
                    x += cw + sp
                }
                y -= h
            }
            return out
        }

        // Follow: stack the blocks, centred, the translation one line-height and a little below the original
        let gap = lineHeight(bold) * 0.35
        let total = zip(blocks, rowsOf).map { b, r in CGFloat(r.count) * lineHeight(b.first?.font ?? bold) }.reduce(0, +) + (blocks.count > 1 ? gap : 0)
        var y = box.midY + total / 2
        for (b, rows) in zip(blocks, rowsOf) {
            guard let f = b.first?.font else { continue }
            let lh = lineHeight(f), s = width(" ", f)
            let rtl = Caption.rtl(words: b.map(\.text))           // a right-to-left block's rows run right to left
            for row in rows {
                y -= lh
                let rw = row.map { b[$0].w }.reduce(0, +) + s * CGFloat(max(0, row.count - 1))
                var x = box.midX - rw / 2
                for i in Caption.visual(row, rtl: rtl, text: { b[$0].text }) {
                    let p = b[i]
                    out.items.append(Item(kind: p.kind, text: p.text, rect: CGRect(x: x, y: y, width: p.w, height: lh), font: p.font, beat: p.beat, alpha: p.alpha, placeholder: p.placeholder))
                    x += p.w + s
                }
            }
            y -= gap
        }
        return out
    }

    struct Piece {
        let text: String, w: CGFloat, kind: Item.Kind, font: CTFont, beat: Caption.Beat?, alpha: CGFloat
        var placeholder = false
    }

    // ---------- Learning's two places (SPEC 59) ----------

    /// The two places in `box`, the top (0) and the bottom (1), with a gap between them.
    public static func placeBoxes(_ box: CGRect, gap: CGFloat = 12) -> [CGRect] {
        let h = max(0, (box.height - gap) / 2)
        return [CGRect(x: box.minX, y: box.maxY - h, width: box.width, height: h), CGRect(x: box.minX, y: box.minY, width: box.width, height: h)]
    }

    /// The transcript's one size (SPEC 59): the largest in `lo…hi` at which every line fits one place, unshrunk and
    /// uncut, so no line is bigger or smaller than another. `lo` when even that is too big. Callers keep it per
    /// transcript, width and Balance (it lays out every line ~8 times).
    public static func uniformSize(_ lines: [Caption.Line], in place: CGRect, style: CaptionStyle, from lo: CGFloat, to hi: CGFloat) -> CGFloat {
        func fits(_ size: CGFloat) -> Bool {
            var s = style; s.size = size
            return lines.allSatisfy { line in
                guard let l = attempt(line, mode: .learn, at: -1, in: place, style: s, scale: 1) else { return false }
                return l.items.allSatisfy { $0.rect.minX >= place.minX - 0.5 && $0.rect.maxX <= place.maxX + 0.5
                                            && $0.rect.minY >= place.minY - 0.5 && $0.rect.maxY <= place.maxY + 0.5 }
            }
        }
        if fits(hi) { return hi }
        guard fits(lo) else { return lo }
        var a = lo, b = hi
        for _ in 0..<7 { let m = (a + b) / 2; if fits(m) { a = m } else { b = m } }
        return a
    }

    /// Learning: the lines in their two places at `t` (`Caption.places`), each faded by its place's alpha. `held`:
    /// paused, the screen never clears. Set `style.size` from `uniformSize` so every line shares one size.
    public static func drawPlaces(_ lines: [Caption.Line], at t: Double, held: Bool, in ctx: CGContext, box: CGRect,
                                  style: CaptionStyle = .init(), voice: ((Caption.Beat, Double) -> Double?)? = nil) {
        let boxes = placeBoxes(box)
        var best: [Int: (line: Int, alpha: Double)] = [:]
        for s in Caption.places(lines, at: t, held: held) where (best[s.place]?.alpha ?? -1) < s.alpha { best[s.place] = (s.line, s.alpha) }
        for (place, s) in best.sorted(by: { $0.key < $1.key }) {
            ctx.saveGState()
            ctx.setAlpha(CGFloat(s.alpha))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            draw(lines[s.line], mode: .learn, at: t, in: ctx, box: boxes[place], style: style, voice: voice)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }

    // ---------- drawing ----------

    /// Draws the line as it is at `t`. `voice`: the Mac's prosody curve for a word's light, when it has one.
    public static func draw(_ line: Caption.Line, mode: CaptionMode, at t: Double, in ctx: CGContext, box: CGRect,
                            style: CaptionStyle = .init(), voice: ((Caption.Beat, Double) -> Double?)? = nil) {
        let l = layout(line, mode: mode, at: t, in: box, style: style)
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.textMatrix = .identity
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3 * l.scale, color: style.shadow)
        for it in l.items where it.alpha > 0.001 {
            ctx.saveGState()
            ctx.setAlpha(it.alpha)
            if let b = it.beat { drawWord(it, b, at: t, ctx, style, voice) }
            else { glyphs(it, color: it.placeholder ? style.upcoming : style.spoken, ctx) }   // a turned phrase has been heard: white
            ctx.restoreGState()
        }
    }

    /// The light, as the Mac's `drawBody`: each side of the edge drawn once (no paler copy round the lit letters), and
    /// the edge crossing the word the way it is read.
    static func drawWord(_ it: Item, _ b: Caption.Beat, at t: Double, _ ctx: CGContext, _ style: CaptionStyle,
                         _ voice: ((Caption.Beat, Double) -> Double?)?) {
        if b.un || t < b.start { return glyphs(it, color: style.upcoming, ctx) }
        if t >= b.end { return glyphs(it, color: style.spoken, ctx) }
        let p = CGFloat(Caption.progress(b, t, voice: voice))
        let rtl = it.text.unicodeScalars.first.map { (0x0590...0x08FF).contains($0.value) } ?? false
        let edge = rtl ? it.rect.maxX - it.rect.width * p : it.rect.minX + it.rect.width * p
        let pad: CGFloat = 20
        let lit = rtl ? CGRect(x: edge, y: it.rect.minY - pad, width: it.rect.maxX - edge + pad, height: it.rect.height + 2 * pad)
                      : CGRect(x: it.rect.minX - pad, y: it.rect.minY - pad, width: edge - it.rect.minX + pad, height: it.rect.height + 2 * pad)
        let unlit = rtl ? CGRect(x: it.rect.minX - pad, y: it.rect.minY - pad, width: edge - it.rect.minX + pad, height: it.rect.height + 2 * pad)
                        : CGRect(x: edge, y: it.rect.minY - pad, width: it.rect.maxX - edge + pad, height: it.rect.height + 2 * pad)
        ctx.saveGState(); ctx.clip(to: unlit); glyphs(it, color: style.upcoming, ctx); ctx.restoreGState()
        ctx.saveGState(); ctx.clip(to: lit); glyphs(it, color: style.current, ctx); ctx.restoreGState()
    }

    static func glyphs(_ it: Item, color: CGColor, _ ctx: CGContext) {
        let a = NSAttributedString(string: it.text, attributes: [
            .init(kCTFontAttributeName as String): it.font,
            .init(kCTForegroundColorAttributeName as String): color,
        ])
        let l = CTLineCreateWithAttributedString(a)
        ctx.textPosition = CGPoint(x: it.rect.minX, y: it.rect.minY + CTFontGetDescent(it.font))
        CTLineDraw(l, ctx)
    }
}
