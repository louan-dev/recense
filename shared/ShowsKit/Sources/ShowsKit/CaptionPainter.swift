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
        let bold = font(style.size * scale, bold: true), regular = font(style.size * scale, bold: false)
        let h = lineHeight(bold), sp = width(" ", bold)
        var out = Layout(scale: scale)
        var blocks: [[(text: String, w: CGFloat, kind: Item.Kind, font: CTFont, beat: Caption.Beat?, alpha: CGFloat)]] = []
        var rowsOf: [[[Int]]] = []

        switch mode {
        case .follow:
            let src = Caption.sourceBeats(line.words).map { b in (text: b.text, w: width(b.text, bold), kind: Item.Kind.original, font: bold, beat: Optional(b), alpha: CGFloat(1)) }
            guard let r = wrap(src.map(\.w), space: sp, width: box.width, max: force ? .max : 3) else { return nil }
            blocks.append(src); rowsOf.append(r)
            let tr = Caption.translationBeats(line).map { b in (text: b.text, w: width(b.text, regular), kind: Item.Kind.translation, font: regular, beat: Optional(b), alpha: CGFloat(1)) }
            if !tr.isEmpty {
                guard let r2 = wrap(tr.map(\.w), space: width(" ", regular), width: box.width, max: force ? .max : 2) else { return nil }
                blocks.append(tr); rowsOf.append(r2)
            }
        case .learn:
            let beats = Caption.sourceBeats(line.words), en = line.translation ?? []
            let ph = Caption.phrases(line)
            var cells: [(text: String, w: CGFloat, kind: Item.Kind, font: CTFont, beat: Caption.Beat?, alpha: CGFloat)] = []
            var cellWidths: [CGFloat] = []
            for p in ph {
                let o = p.src.map { beats[$0].text }.joined(separator: " ")
                let e = p.en.map { en[$0].w }.joined(separator: " ")
                let wo = width(o, bold), we = e.isEmpty ? wo : width(e, bold)
                let u = CGFloat(Caption.turned(line, p, beats: beats, at: t))
                let eased = u * u * (3 - 2 * u)
                let w = style.reduceMotion ? (u < 0.5 ? wo : we) : wo + (we - wo) * eased
                cellWidths.append(w)
                // the cell is drawn as its words (so each lights by its own beat) and, while it turns, its translation
                for b in p.src.map({ beats[$0] }) { cells.append((b.text, width(b.text, bold), .original, bold, b, 1 - u)) }
                if u > 0, !e.isEmpty { cells.append((e, we, .translation, bold, nil, u)) }
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
        let gap = h * 0.35
        let total = zip(blocks, rowsOf).map { b, r in CGFloat(r.count) * lineHeight(b.first?.font ?? bold) }.reduce(0, +) + (blocks.count > 1 ? gap : 0)
        var y = box.midY + total / 2
        for (b, rows) in zip(blocks, rowsOf) {
            guard let f = b.first?.font else { continue }
            let lh = lineHeight(f), s = width(" ", f)
            for row in rows {
                y -= lh
                let rw = row.map { b[$0].w }.reduce(0, +) + s * CGFloat(max(0, row.count - 1))
                var x = box.midX - rw / 2
                for i in row {
                    let p = b[i]
                    out.items.append(Item(kind: p.kind, text: p.text, rect: CGRect(x: x, y: y, width: p.w, height: lh), font: p.font, beat: p.beat, alpha: 1))
                    x += p.w + s
                }
            }
            y -= gap
        }
        return out
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
            else { glyphs(it, color: style.spoken, ctx) }      // a turned phrase has been heard: white
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
