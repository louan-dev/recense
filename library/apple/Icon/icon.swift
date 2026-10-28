// Draws Gallery Files' icon at 1024×1024: a quiet off-white field with three stacked sheets, the front one a soft
// blue: a gallery of files, nothing more. iOS and macOS round the corners themselves on iOS; on macOS the squircle
// and its shadow are drawn here, as macOS expects.
//   swift icon.swift ios <out.png>      full-bleed square (iOS masks it)
//   swift icon.swift mac <out.png>      macOS shape: rounded rect inset on a transparent canvas
import AppKit

let args = CommandLine.arguments
let mac = args.count > 1 && args[1] == "mac"
let out = URL(fileURLWithPath: args.count > 2 ? args[2] : "icon.png")
let S: CGFloat = 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])! }
func gradient(_ a: CGColor, _ b: CGColor) -> CGGradient { CGGradient(colorsSpace: space, colors: [a, b] as CFArray, locations: [0, 1])! }
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

// the field
var field = CGRect(x: 0, y: 0, width: S, height: S)
if mac {
    field = CGRect(x: 100, y: 100, width: 824, height: 824)  // Apple's macOS grid: 824 pt body on 1024
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.28))
    cg.addPath(rounded(field, 185)); cg.setFillColor(color(245, 245, 247)); cg.fillPath()
    cg.restoreGState()
    cg.addPath(rounded(field, 185)); cg.clip()
}
cg.drawLinearGradient(gradient(color(252, 252, 253), color(232, 233, 237)), start: CGPoint(x: 0, y: field.maxY), end: CGPoint(x: 0, y: field.minY), options: [])

// three sheets, back to front, each a little lower and to the right; geometry in the 1024 square, scaled into the field
let k = field.width / S
func place(_ r: CGRect) -> CGRect { CGRect(x: field.minX + r.minX * k, y: field.minY + r.minY * k, width: r.width * k, height: r.height * k) }
let w: CGFloat = 470, h: CGFloat = 560, step: CGFloat = 62, radius: CGFloat = 64 * k
let front = CGRect(x: (S - w) / 2 + step, y: (S - h) / 2 - step, width: w, height: h)

func sheet(_ r: CGRect, _ top: CGColor, _ bottom: CGColor, shadow: CGFloat) {
    let p = rounded(place(r), radius)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 34 * k, color: color(20, 24, 40, shadow))
    cg.addPath(p); cg.setFillColor(bottom); cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(p); cg.clip()
    let pr = place(r)
    cg.drawLinearGradient(gradient(top, bottom), start: CGPoint(x: 0, y: pr.maxY), end: CGPoint(x: 0, y: pr.minY), options: [])
    cg.restoreGState()
    // a hairline edge, so white sheets read on the white field
    cg.addPath(p); cg.setStrokeColor(color(0, 0, 0, 0.06)); cg.setLineWidth(2 * k); cg.strokePath()
}
sheet(front.offsetBy(dx: -2 * step, dy: 2 * step), color(255, 255, 255), color(244, 245, 248), shadow: 0.10)
sheet(front.offsetBy(dx: -step, dy: step), color(255, 255, 255), color(240, 241, 245), shadow: 0.12)
sheet(front, color(94, 160, 255), color(10, 104, 230), shadow: 0.22)

// on the front sheet, a sun rising on a horizon: a picture, said as quietly as possible
let f = place(front)
let horizon = f.minY + 150 * k, sun: CGFloat = 78 * k
cg.setFillColor(color(255, 255, 255, 0.92))
cg.move(to: CGPoint(x: f.midX + sun, y: horizon))
cg.addArc(center: CGPoint(x: f.midX, y: horizon), radius: sun, startAngle: 0, endAngle: .pi, clockwise: false)
cg.closePath(); cg.fillPath()
cg.setStrokeColor(color(255, 255, 255, 0.92)); cg.setLineWidth(16 * k); cg.setLineCap(.round)
cg.move(to: CGPoint(x: f.minX + 92 * k, y: horizon)); cg.addLine(to: CGPoint(x: f.maxX - 92 * k, y: horizon)); cg.strokePath()

NSGraphicsContext.current = nil
if !mac {  // iOS wants no alpha
    let flat = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 3,
                                hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: flat)
    NSImage(cgImage: rep.cgImage!, size: NSSize(width: 1024, height: 1024)).draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    NSGraphicsContext.current = nil
    try! flat.representation(using: .png, properties: [:])!.write(to: out)
} else {
    try! rep.representation(using: .png, properties: [:])!.write(to: out)
}
