// Draws Gallery Files' icon at 1024×1024: a white field and one cloud filled with a colour wheel, photos in the
// cloud. iOS rounds the corners itself; on macOS the squircle and its shadow are drawn here, as macOS expects.
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
cg.drawLinearGradient(gradient(color(255, 255, 255), color(240, 241, 245)), start: CGPoint(x: 0, y: field.maxY), end: CGPoint(x: 0, y: field.minY), options: [])

// one cloud (iCloud) holding the Photos colour wheel: a conic sweep of its petal colours, nothing else.
// Geometry in the 1024 square, scaled into the field.
let k = field.width / S
func place(_ p: CGPoint) -> CGPoint { CGPoint(x: field.minX + p.x * k, y: field.minY + p.y * k) }
let lift: CGFloat = 0
// side puffs share their x-centre and radius with the base's round ends, so each side is one smooth edge
let cloud: [(CGPoint, CGFloat)] = [  // centre, radius (y up)
    (CGPoint(x: 362, y: 478), 112),
    (CGPoint(x: 522, y: 566), 166),
    (CGPoint(x: 662, y: 478), 112),
    (CGPoint(x: 362, y: 404), 112),
    (CGPoint(x: 662, y: 404), 112),
]
let base = CGRect(x: 362, y: 292, width: 300, height: 224)

// the cloud as a mask: each part filled on its own, so overlaps simply add up
let mask = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
mask.setFillColor(gray: 1, alpha: 1)
for (c, r) in cloud {
    let pc = place(c)
    mask.fillEllipse(in: CGRect(x: pc.x - r * k, y: pc.y - r * k, width: 2 * r * k, height: 2 * r * k))
}
let b = CGRect(origin: place(base.origin), size: CGSize(width: base.width * k, height: base.height * k))
mask.fill(b)
let waist = CGRect(origin: place(CGPoint(x: 250, y: 404)), size: CGSize(width: 524 * k, height: 74 * k))  // straight sides between the puffs
mask.fill(waist)

// a soft shadow under the cloud, then the colour wheel inside it
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 30 * k, color: color(30, 30, 60, 0.18))
cg.beginTransparencyLayer(auxiliaryInfo: nil)
cg.clip(to: CGRect(x: 0, y: 0, width: 1024, height: 1024), mask: mask.makeImage()!)
let wheel: [CGColor] = [color(255, 159, 10), color(255, 214, 10), color(52, 199, 89), color(48, 176, 199),
                        color(10, 132, 255), color(94, 92, 230), color(191, 90, 242), color(255, 55, 95), color(255, 159, 10)]
// a conic sweep, as 720 thin wedges, each colour blended from its two neighbours on the wheel
let hub = place(CGPoint(x: 512, y: 480)), steps = 720, reach = 1024 * k
for i in 0..<steps {
    let t = CGFloat(i) / CGFloat(steps), at = t * CGFloat(wheel.count - 1)
    let j = min(Int(at), wheel.count - 2), f = at - CGFloat(j)
    let c0 = wheel[j].components!, c1 = wheel[j + 1].components!
    cg.setFillColor(CGColor(colorSpace: space, components: (0..<4).map { c0[$0] + (c1[$0] - c0[$0]) * f })!)
    let a0 = .pi / 2 - t * 2 * .pi, a1 = a0 - 2 * .pi / CGFloat(steps) - 0.012  // a little overlap: no seams
    cg.move(to: hub)
    cg.addArc(center: hub, radius: reach, startAngle: a0, endAngle: a1, clockwise: true)
    cg.closePath(); cg.fillPath()
}
// a faint white light from the top, the way Apple's glyphs catch it
cg.drawLinearGradient(gradient(color(255, 255, 255, 0.22), color(255, 255, 255, 0)), start: place(CGPoint(x: 0, y: 780)), end: place(CGPoint(x: 0, y: 420)), options: [])
cg.endTransparencyLayer()
cg.restoreGState()

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
