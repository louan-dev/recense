// The floating window's picture (FloatingCaption.paint, the app's own file), rendered on the Mac.
// Regression 11-10 (owner's iPad video): a line was cut through at the top of the window. Now only whole lines show:
// nothing is drawn in the top or bottom margin (the painter shrinks a long line first).
// Regression guard: BUG-24 (P1b: the window drew one picture per word, so a word lit whole at its start; now, half
// way through a word, its left part is lit and its right part is not).
// Pictures land in $TMPDIR/floatingcaption-shots/ to look at.
import AppKit
import CoreGraphics
import ShowsKit

let size = CGSize(width: 400, height: 188), scale: CGFloat = 2   // Listener.canvas
let shots = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("floatingcaption-shots")
try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)

func words(_ text: String, from t0: Double = 0, step: Double = 0.5) -> [Word] {
    text.split(separator: " ").enumerated().map { i, w in Word(text: String(w), start: t0 + step * Double(i), end: t0 + step * Double(i + 1)) }
}

/// The picture's pixels (RGBA, row 0 at the top), saved as `name`.png.
func render(_ lines: [Caption.Line], current: Int?, learn: Bool = false, note: String? = nil, at t: Double, name: String) -> (CGContext, Int, Int) {
    let w = Int(size.width * scale), h = Int(size.height * scale)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    FloatingCaption.paint(ctx, canvas: size, scale: scale, lines: lines, current: current, learn: learn, note: note, at: t)
    if let img = ctx.makeImage() {
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent(name + ".png"))
    }
    return (ctx, w, h)
}

/// The brightest channel (0…255) over pixel rows `ys` (from the top) and columns `xs`.
func brightest(_ r: (CGContext, Int, Int), rows ys: Range<Int>, cols xs: Range<Int>? = nil) -> Int {
    let (ctx, w, _) = r, p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var m = 0
    for y in ys { for x in (xs ?? 0..<w) { let i = (y * w + x) * 4; m = max(m, Int(p[i]), Int(p[i + 1]), Int(p[i + 2])) } }
    return m
}

var bad = 0
let background = 20   // FloatingCaption.background (0.04) is 10; text is near 140 (dim) to 245 (white)
let band = Int(10 * scale)
// a long sentence and its translation: shrunk until it fits (a line still too long at 60 % is cut: FEAT-05 rule 8)
let long = (1...3).map { _ in "The sun goes down and the light turns cold over the water," }.joined(separator: " ") + " now."
let cases: [(String, [Caption.Line], Bool)] = [
    ("follow-short", [Caption.Line(words: words("Into every light."), translationText: "Dans chaque lumière.")], false),
    ("follow-long", [Caption.Line(words: words(long, step: 0.2), translationText: long)], false),
    ("learn-two", [Caption.Line(words: words("It collides, it collides."), translationText: "Ça se heurte."),
                   Caption.Line(words: words("Into every light.", from: 2.6), translationText: "Dans chaque lumière.")], true),
]
for (name, lines, learn) in cases {
    let r = render(lines, current: 0, learn: learn, at: 1.2, name: name)
    let top = brightest(r, rows: 0..<band), bottom = brightest(r, rows: (r.2 - band)..<r.2), all = brightest(r, rows: 0..<r.2)
    if all <= background { bad += 1; print("FAIL \(name): nothing drawn") }
    if top > background { bad += 1; print("FAIL \(name): a line is cut at the top (\(top)); only whole lines show") }
    if bottom > background { bad += 1; print("FAIL \(name): a line is cut at the bottom (\(bottom))") }
}

// BUG-24 P1b: half way through a 1-second word, the window shows it half lit (gold on the left, dim on the right)
do {
    let line = Caption.Line(words: [Word(text: "Everything", start: 0, end: 1)], translation: nil)
    let r = render([line], current: 0, at: 0.5, name: "half-lit")
    var style = CaptionStyle(); style.size = FloatingCaption.size
    let it = CaptionPainter.layout(line, mode: .follow, at: 0.5, in: FloatingCaption.box(size), style: style).items[0]
    let rows = Int((size.height - it.rect.maxY) * scale)..<Int((size.height - it.rect.minY) * scale)
    let x0 = Int(it.rect.minX * scale), x1 = Int(it.rect.maxX * scale), mid = (x0 + x1) / 2
    let left = brightest(r, rows: rows, cols: x0..<(x0 + (x1 - x0) * 2 / 5)), right = brightest(r, rows: rows, cols: (mid + (x1 - x0) / 10)..<x1)
    if left < 230 { bad += 1; print("FAIL half-lit: the heard part isn't lit (\(left))") }
    if right > 180 { bad += 1; print("FAIL half-lit: the unheard part is lit (\(right)); a word lights whole at its start") }
}

// a note shows, dim, in the middle
do {
    let r = render([], current: nil, note: "Listening…", at: 0, name: "note")
    let mid = brightest(r, rows: (r.2 / 2 - band)..<(r.2 / 2 + band))
    if mid <= background || mid > 200 { bad += 1; print("FAIL note: not shown dim in the middle (\(mid))") }
}
print(bad == 0 ? "ALL OK" : "\(bad) FAILED")
exit(bad == 0 ? 0 : 1)
