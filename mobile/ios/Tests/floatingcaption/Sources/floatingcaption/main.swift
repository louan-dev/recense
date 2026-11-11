// Regression 11-10 (owner's iPad video): when the sentence before and the current one didn't both fit, the older one was
// cut through at the top of the floating window. Now only whole lines show: nothing is drawn in the top margin unless
// the current line alone is taller than the window; then its newest words stay at the bottom and its start fades at
// the top (it was centred, cut at both ends, the words being heard lost below).
// Pictures land in $TMPDIR/floatingcaption-shots/ to look at.
import AppKit
import SwiftUI
import ShowsKit

let size = CGSize(width: 400, height: 188)   // Listener.canvas
let shots = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("floatingcaption-shots")
try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)

func line(_ id: String, _ text: String) -> TranscriptLine { TranscriptLine(id: id, start: 0, end: 0, text: text) }
func rows(_ before: String?, _ now: String) -> [FloatingCaption.Row] {
    (before.map { [FloatingCaption.Row(line: line("a", $0), on: false, t: nil)] } ?? [])
        + [FloatingCaption.Row(line: line("b", now), on: true, t: 0)]
}

/// The brightest pixel in the top and bottom `band` points (any channel, 0...255); the picture is saved as `name`.png.
@MainActor func margins(_ r: [FloatingCaption.Row], band: CGFloat = 10, name: String) -> (top: Int, bottom: Int) {
    let v = FloatingCaption(rows: r, learn: false, note: nil).frame(width: size.width, height: size.height)
    let ir = ImageRenderer(content: v); ir.scale = 2
    guard let cg = ir.cgImage else { print("FAIL \(name): no picture"); return (999, 999) }
    let rep = NSBitmapImageRep(cgImage: cg)
    try? rep.representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent(name + ".png"))
    func brightest(_ ys: Range<Int>) -> Int {
        var m = 0
        for y in ys { for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            m = max(m, Int(max(c.redComponent, c.greenComponent, c.blueComponent) * 255))
        } }
        return m
    }
    let b = Int(band * 2)
    return (brightest(0..<b), brightest((rep.pixelsHigh - b)..<rep.pixelsHigh))
}

var bad = 0
let short1 = "It collides, it collides.", short2 = "Into every light."
let long = (1...6).map { _ in "The sun goes down and the light turns cold over the water," }.joined(separator: " ") + " now."
let background = 20   // Color(white: 0.04) is 10; text starts near 115
MainActor.assumeIsolated {
    for (name, r) in [("both-fit", rows(short1, short2)), ("before-too-long", rows(long, short2)), ("one-line", rows(nil, short2))] {
        let m = margins(r, name: name)
        if m.top > background { bad += 1; print("FAIL \(name): a line is cut at the top (\(m.top)); only whole lines show") }
        if m.bottom > background { bad += 1; print("FAIL \(name): a line is cut at the bottom (\(m.bottom))") }
    }
    // the one allowed overflow: the bottom stays whole (the words being heard), the top only faintly (the fade)
    let m = margins(rows(short1, long), name: "current-too-long")
    if m.bottom > background { bad += 1; print("FAIL current-too-long: its newest words are cut at the bottom (\(m.bottom))") }
    if m.top > 50 { bad += 1; print("FAIL current-too-long: its start is cut at the top instead of fading (\(m.top))") }
}
print(bad == 0 ? "ALL OK" : "\(bad) FAILED")
exit(bad == 0 ? 0 : 1)
