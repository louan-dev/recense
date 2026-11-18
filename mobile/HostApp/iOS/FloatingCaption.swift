// Derived from Spec: BUG-24 (P1b) and FEAT-05 (rules 1, 6, 7)
// The floating window's picture, drawn by the one painter (ShowsKit CaptionPainter via FloatingFrames) straight into
// the frame's pixels: Follow, the line the transcript turns to over its translation; Learn, the two places. Core
// Graphics and ShowsKit only, so mobile/ios/Tests/floatingcaption renders it on the Mac. (Until 11-18: SwiftUI's
// ImageRenderer of TranscriptLineText rows, one picture per word, so a word lit whole at its start.)
import CoreGraphics
import ShowsKit

enum FloatingCaption {
    static let background = CGColor(gray: 0.04, alpha: 1)
    /// The text's size in points on the 400 × 188 canvas: Follow's 3 + 2 rows, and Learn's two places of 2 rows, fit.
    static let size: CGFloat = 24
    /// The caption's box inside the canvas.
    static func box(_ canvas: CGSize) -> CGRect { CGRect(x: 18, y: 12, width: canvas.width - 36, height: canvas.height - 24) }

    /// Paints one picture of the window at light time `t` into `ctx` (`canvas` points, `scale` pixels a point).
    /// `note`, when set, is shown instead ("Listening…", "No transcript yet", "Note saved"), dim, centred.
    static func paint(_ ctx: CGContext, canvas: CGSize, scale: CGFloat, lines: [Caption.Line], current: Int?, learn: Bool,
                      note: String?, at t: Double, reduceMotion: Bool = false) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: canvas.width * scale, height: canvas.height * scale))
        ctx.scaleBy(x: scale, y: scale)
        var style = CaptionStyle(); style.size = size; style.reduceMotion = reduceMotion
        if let note {
            // never lit: its words start at no time
            let words = note.split(separator: " ").map { Word(text: String($0), start: .infinity, end: .infinity) }
            style.size = 20
            CaptionPainter.draw(Caption.Line(words: words, translation: nil), mode: .follow, at: 0, in: ctx, box: box(canvas), style: style)
            return
        }
        FloatingFrames.draw(lines, current: current, mode: learn ? .learn : .follow, at: t, in: ctx, box: box(canvas), style: style)
    }
}
