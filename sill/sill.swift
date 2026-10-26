// sill.swift
// Sill V0.1: a quiet top-center panel with two surfaces.
//   time  — the default: current time and date, small, no focus taken.
//   pad   — Draftpad: the same one-file Markdown strip as draftpad.swift, same draftpad.md.
// Built directly on draftpad.swift; the pad code (pages, file sync, cursor memory) is unchanged.
//
// Build:  zsh build.sh            (or: swiftc -O sill.swift -o sill)
// Run:    ./sill &                 opens the time view
// Control the running copy (BetterTouchTool, Shortcuts, shell):
//   ./sill up         open one level: hidden → pad → clock
//   ./sill down       close one level: clock → pad → hidden
//   ./sill pad        show the pad          ./sill time      show the time
//   ./sill show       show the last surface ./sill hide      hide
//   ./sill toggle     hide if visible, otherwise show the pad (the hotkey does this)
//   ./sill quit       save and quit         ./sill status    prints time / pad / hidden / not running
//   ./sill background launch without showing anything (used by the login item)
//   - show-type commands launch the app if it isn't running yet; hide / quit exit 1 if nothing runs.
//   - any other argument prints usage and exits 64.
//
// In the panel:
//   click the time           = open the pad
//   click the small time     = back to the time view (top of the pad)
//   Two fingers left         = next topic, deeper into the note; past the last one starts a new topic
//   Two fingers right        = back toward the top; the first topic is a hard stop
//   Cmd+] / Cmd+[            = next / previous topic
//   Esc or Cmd+W             = hide
//   Ctrl+Option+Space        = toggle the pad
// Trackpad gestures (three-finger up / down) are NOT handled here. BetterTouchTool runs `sill up` / `sill down`
// through scripts/gesture.sh, so there is exactly one gesture source and nothing double-fires.
//
// File format: pages are separated by  <!-- page -->  (hidden in Obsidian's reading view).

import Cocoa
import SwiftTerm
import Carbon.HIToolbox
import IOKit.ps
import EventKit
import AVFoundation
import ScreenCaptureKit
import LocalAuthentication
import CoreAudio
import AudioToolbox
import WebKit
import Speech

// MARK: - Settings (edit these)

// The same canonical note Draftpad uses. Override for one launch with  DRAFTPAD=/path/to/draftpad.md ./sill &
let defaultNotePath = "/Users/chauphan/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian/draftpad.md"
let notePath: String = {
    if let p = ProcessInfo.processInfo.environment["DRAFTPAD"], !p.isEmpty {
        return (p as NSString).expandingTildeInPath
    }
    return defaultNotePath
}()
let panelWidth: CGFloat = 620           // every surface shares one size
let padSize = NSSize(width: panelWidth, height: 400)
let timeSize = padSize                  // one size for every surface: switching never changes the geometry
let closeOnHoverAway = true              // the panel retracts into the menu bar when the pointer leaves it
let hoverAwayDelay: TimeInterval = 0.45 // grace period, so brushing past the edge doesn't close it
let morphOutDuration: TimeInterval = 0.24   // closing: shrink back up into the menu bar
let cardRadius: CGFloat = 26                 // bottom corners of the card
let cardEar: CGFloat = 14                    // the concave flare where the card meets the menu bar
let cardColor = NSColor(calibratedWhite: 0.055, alpha: 1)  // black glass, a breath lighter than black
let shadowMargin: CGFloat = 36               // transparent room around the card for its shadow
let fontSize: CGFloat = 14
let hotKeyCode = UInt32(kVK_Space)
let hotKeyMods = UInt32(controlKey | optionKey)
let footerHeight: CGFloat = 24
let headerHeight: CGFloat = 10         // breathing room at the top of the pad; no clock there
let repeatGuard: TimeInterval = 0.3     // a gesture this soon after the last change is ignored (BTT + native double-fire)

let pageMarker = "<!-- page -->"
let pageJoiner = "\n\n\(pageMarker)\n\n"
let commandName = Notification.Name("local.sill.command")
let statePath = "/tmp/local.sill.state"   // what `sill status` reads: "time", "pad" or "hidden"

enum Mode: String { case time, pad, hub, notebook, media }

// MARK: - Helpers

func parsePages(_ s: String) -> [String] {
    let parts = s.components(separatedBy: pageMarker)
    let pages = parts.enumerated().map { (i, p) -> String in
        var t = Substring(p)
        if i > 0 { while t.first == "\n" { t = t.dropFirst() } }
        if i < parts.count - 1 { while t.last == "\n" { t = t.dropLast() } }
        return String(t)
    }
    return pages.isEmpty ? [""] : pages
}

/// A fresh thought opens with today's date on its first line, centered: a compass, not a title. It's plain text in
/// draftpad.md, so Obsidian shows it too.
func dateStamp(_ d: Date = Date()) -> String {
    let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .none
    return f.string(from: d)
}
func isDateStamp(_ line: String) -> Bool {
    let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .none
    return f.date(from: line.trimmingCharacters(in: .whitespaces)) != nil
}

/// Blank: nothing on it but whitespace (and, for a fresh thought, its date).
func isBlank(_ s: String) -> Bool {
    var lines = s.components(separatedBy: "\n")
    if let first = lines.first, isDateStamp(first) { lines.removeFirst() }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

func writeState(_ state: String) {
    try? state.write(toFile: statePath, atomically: true, encoding: .utf8)
}

func readState() -> String? {
    guard let s = try? String(contentsOfFile: statePath, encoding: .utf8) else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return ["time", "pad", "hub", "notebook", "media", "hidden"].contains(t) ? t : nil
}

// MARK: - Views

final class SillPanel: NSPanel {
    /// Only the pad takes keyboard focus. The time view never steals typing from the app you're in.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// A view that reports clicks, even when the panel isn't key.
class ClickView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The card's outline: where it meets the menu bar its top edge flares outward on both sides with a concave curve
/// (like a drop of the bar itself), then it runs down and rounds off at the bottom. `r` is the full shape, ears
/// included; the body is `ear` narrower on each side.
func contouredCard(_ r: NSRect, ear: CGFloat, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let l = r.minX + ear, rt = r.maxX - ear, top = r.maxY, bottom = r.minY
    p.move(to: CGPoint(x: r.minX, y: top))
    p.addLine(to: CGPoint(x: r.maxX, y: top))
    p.addArc(tangent1End: CGPoint(x: rt, y: top), tangent2End: CGPoint(x: rt, y: top - ear), radius: ear)
    p.addLine(to: CGPoint(x: rt, y: bottom + radius))
    p.addArc(tangent1End: CGPoint(x: rt, y: bottom), tangent2End: CGPoint(x: rt - radius, y: bottom), radius: radius)
    p.addLine(to: CGPoint(x: l + radius, y: bottom))
    p.addArc(tangent1End: CGPoint(x: l, y: bottom), tangent2End: CGPoint(x: l, y: bottom + radius), radius: radius)
    p.addLine(to: CGPoint(x: l, y: top - ear))
    p.addArc(tangent1End: CGPoint(x: l, y: top), tangent2End: CGPoint(x: r.minX, y: top), radius: ear)
    p.closeSubpath()
    return p
}

/// A rectangle with only its bottom corners rounded (AppKit coordinates: y grows upward).
func bottomRounded(_ r: NSRect, _ radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + radius, y: r.minY), radius: radius)
    p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + radius), radius: radius)
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
    p.closeSubpath()
    return p
}

/// The panel's root: black, flush with the menu bar, rounded only at the bottom, and it reports the pointer
/// entering and leaving so the panel can close when you move away.
final class RootView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// Clips the strip of pages and reports size changes so the strip can re-layout.
final class Viewport: NSView {
    var onResize: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }
}

final class PadTextView: NSTextView {
    private enum Axis { case horizontal, vertical }
    private static var axis: Axis?   // shared: one gesture = one axis, even if it crosses page views

    /// dx is normalised so "fingers move left" is negative, whatever the natural-scrolling setting.
    var onDrag: ((CGFloat, Bool) -> Void)?
    var onEscape: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { super.scrollWheel(with: event); return }
        if event.phase == .began || event.phase == .mayBegin { PadTextView.axis = nil }

        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if PadTextView.axis == nil {
            if dx == 0 && dy == 0 { super.scrollWheel(with: event); return }
            PadTextView.axis = abs(dx) > abs(dy) ? .horizontal : .vertical
        }
        if PadTextView.axis == .vertical { super.scrollWheel(with: event); return }

        guard event.momentumPhase.isEmpty else { return }
        let ended = event.phase == .ended || event.phase == .cancelled
        onDrag?(event.isDirectionInvertedFromDevice ? dx : -dx, ended)
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Centers a topic's first line when it's a date stamp; everything else stays as typed.
func styleStamp(_ tv: NSTextView) {
    guard let ts = tv.textStorage else { return }
    let str = ts.string as NSString
    let first = str.lineRange(for: NSRange(location: 0, length: 0))
    let left = NSMutableParagraphStyle(); left.alignment = .natural
    let center = NSMutableParagraphStyle(); center.alignment = .center
    guard first.length > 0 else { return }
    let stamp = isDateStamp(str.substring(with: first).trimmingCharacters(in: .newlines))
    ts.beginEditing()                                       // only the first line is touched: cheap on long topics
    ts.addAttribute(.paragraphStyle, value: stamp ? center : left, range: first)
    if stamp { ts.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.85), range: first) }
    ts.endEditing()
    tv.typingAttributes[.paragraphStyle] = left
}

final class PageView {
    let scroll = NSScrollView()
    let textView = PadTextView(frame: .zero)

    init(frame: NSRect) {
        scroll.frame = frame
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false       // no scroll bar, no edge highlight: just the text
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 14, height: 10)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        scroll.documentView = textView
    }
}

// MARK: - Hotkey

var hotKeyAction: (() -> Void)?
var hotKeyRef: EventHotKeyRef?

func registerHotKey(_ action: @escaping () -> Void) {
    hotKeyAction = action
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        hotKeyAction?()
        return noErr
    }, 1, &spec, nil, nil)
    let id = EventHotKeyID(signature: OSType(0x53494C4C), id: 1)   // 'SILL'
    let err = RegisterEventHotKey(hotKeyCode, hotKeyMods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    if err != noErr { NSLog("sill: Ctrl+Option+Space is taken (is draftpad still running?), error \(err)") }
}

// MARK: - Native gestures (EXPERIMENTAL)
//
// Three-finger swipe up / down read straight from the trackpad, so BetterTouchTool isn't needed.
// macOS has no public API for system-wide multi-finger swipes: NSEvent global monitors don't receive them.
// This uses the private MultitouchSupport framework, the same source BetterTouchTool, Jitouch and MiddleClick
// use. It only reads touches (it can't block them), needs no permission prompt, and may break in a future
// macOS release; if it does, the BTT triggers via scripts/gesture.sh still work, and SILL_GESTURES=0 turns this off.
// It assumes macOS's own three-finger swipes (Mission Control, App Exposé, swipe between apps) are off or on
// four fingers, otherwise both would act on the same swipe.

struct MTPoint { var x: Float; var y: Float }
struct MTReadout { var pos: MTPoint; var vel: MTPoint }
/// One touch, as MultitouchSupport reports it (96 bytes). Only `state` and `normalized.pos` are used.
struct MTFinger {
    var frame: Int32; var timestamp: Double; var identifier: Int32; var state: Int32
    var unknown1: Int32; var unknown2: Int32
    var normalized: MTReadout                 // 0...1 across the surface, y = 0 at the edge nearest you
    var size: Float; var unknown3: Int32; var angle: Float; var majorAxis: Float; var minorAxis: Float
    var millimeters: MTReadout; var unknown4: Int32; var unknown5: Int32; var unknown6: Float
}
typealias MTFrameCallback = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

let swipeDistance: Float = 0.10      // fraction of the trackpad height the three fingers must travel together
let fingerDistance: Float = 0.05     // ...and the least each one of them must travel, in the same direction

/// Gesture state lives in globals because a C callback can't capture context. Touch frames arrive on one
/// MultitouchSupport thread.
///
/// A swipe counts only when exactly three fingers are down and *all three* move the same way. A resting thumb or
/// palm next to a two-finger scroll is a third contact that doesn't move, so it can't turn a scroll into a swipe.
var gestureHandler: ((String) -> Void)?
var gStarts: [Int32: MTPoint] = [:]      // where each of the current three fingers was when the three-finger phase began
var gSpent = false
/// Read by the scroll filter on the main thread: three fingers are down and moving together right now / did last touch.
var gThreeMoving = false, gLastTouchWasSwipe = false
var gWasDown = false

let frameCallback: MTFrameCallback = { _, data, count, _, _ in
    guard let data = data else { return 0 }
    let fingers = data.assumingMemoryBound(to: MTFinger.self)
    var touching: [(id: Int32, p: MTPoint)] = []
    for i in 0..<Int(count) where (3...5).contains(fingers[i].state) {   // make-touch, touching, break-touch
        touching.append((fingers[i].identifier, fingers[i].normalized.pos))
    }
    let n = touching.count
    if !gWasDown && n > 0 { gLastTouchWasSwipe = false }                 // a new touch begins
    gWasDown = n > 0
    if n == 0 { gStarts = [:]; gSpent = false; gThreeMoving = false; return 0 }
    if n > 3 { gStarts = [:]; gSpent = true; gThreeMoving = false; return 0 }   // four or more: ignore until lifted
    if n < 3 { gStarts = [:]; gThreeMoving = false; return 0 }

    // Exactly three. (Re)start tracking if this is a new set of fingers.
    if Set(touching.map { $0.id }) != Set(gStarts.keys) {
        gStarts = Dictionary(uniqueKeysWithValues: touching.map { ($0.id, $0.p) })
        gThreeMoving = false
        return 0
    }
    var dys: [Float] = [], dxs: [Float] = []
    for t in touching {
        let s0 = gStarts[t.id]!
        dys.append(t.p.y - s0.y); dxs.append(t.p.x - s0.x)
    }
    let allUp = dys.allSatisfy { $0 > 0.01 }, allDown = dys.allSatisfy { $0 < -0.01 }
    gThreeMoving = allUp || allDown
    if gThreeMoving { gLastTouchWasSwipe = true }
    guard !gSpent else { return 0 }
    let dy = dys.reduce(0, +) / 3, dx = dxs.reduce(0, +) / 3
    let together = dys.allSatisfy { abs($0) >= fingerDistance } && (allUp || allDown)
    if together && abs(dy) > swipeDistance && abs(dy) > abs(dx) * 1.5 {
        gSpent = true                                                    // one action per swipe
        let cmd = dy > 0 ? "up" : "down"
        DispatchQueue.main.async { gestureHandler?(cmd) }
    }
    return 0
}

/// With macOS's own three-finger gestures off, three fingers scroll like two. BetterTouchTool used to swallow
/// that scroll; this does the same: scroll events are dropped while three fingers are moving together on the
/// trackpad, and so is the momentum after such a touch. Two-finger scrolling, even with a thumb resting, is untouched.
/// Needs Accessibility permission (System Settings → Privacy & Security → Accessibility → sill).
var scrollTap: CFMachPort?
let scrollFilter: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = scrollTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel, event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 else {
        return Unmanaged.passUnretained(event)
    }
    if gThreeMoving { return nil }
    let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
    if !gWasDown && momentum != 0 && gLastTouchWasSwipe { return nil }
    return Unmanaged.passUnretained(event)
}

/// Installs the scroll filter. Returns false until Accessibility permission is granted.
func installScrollFilter() -> Bool {
    if scrollTap != nil { return true }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                      eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                                      callback: scrollFilter, userInfo: nil) else { return false }
    scrollTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

final class NativeGestures {
    typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    typealias Register = @convention(c) (UnsafeMutableRawPointer, MTFrameCallback) -> Void
    typealias StartStop = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias Dimensions = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32

    private var devices: [AnyObject] = []
    private var createList: CreateList?, register: Register?, unregister: Register?
    private var start: StartStop?, stop: Stop?, dimensions: Dimensions?

    init?() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let c = dlsym(h, "MTDeviceCreateList"), let r = dlsym(h, "MTRegisterContactFrameCallback"),
              let s = dlsym(h, "MTDeviceStart") else { return nil }
        createList = unsafeBitCast(c, to: CreateList.self)
        register = unsafeBitCast(r, to: Register.self)
        start = unsafeBitCast(s, to: StartStop.self)
        if let u = dlsym(h, "MTUnregisterContactFrameCallback") { unregister = unsafeBitCast(u, to: Register.self) }
        if let t = dlsym(h, "MTDeviceStop") { stop = unsafeBitCast(t, to: Stop.self) }
        if let d = dlsym(h, "MTDeviceGetSensorDimensions") { dimensions = unsafeBitCast(d, to: Dimensions.self) }
    }

    /// Starts listening on every trackpad. Returns how many were found.
    @discardableResult
    func begin() -> Int {
        end()
        guard let list = createList?()?.takeRetainedValue() as? [AnyObject] else { return 0 }
        for dev in list {
            let p = Unmanaged.passUnretained(dev).toOpaque()
            // Skip the Touch Bar (a 2-row sensor) and anything else that isn't a trackpad-shaped surface.
            var rows: Int32 = 0, cols: Int32 = 0
            if let dim = dimensions, dim(p, &rows, &cols) == 0, rows < 6 { continue }
            register?(p, frameCallback)
            _ = start?(p, 0)
            devices.append(dev)
        }
        return devices.count
    }

    func end() {
        for dev in devices {
            let p = Unmanaged.passUnretained(dev).toOpaque()
            unregister?(p, frameCallback)
            stop?(p)
        }
        devices.removeAll()
        gStarts = [:]; gSpent = false
    }
}

// MARK: - Time & essentials
//
// Top of the panel, a pyramid of clocks: local time centered, Vietnam bottom-left, US Eastern bottom-right.
// When the panel opens they show (local with seconds), then melt into thin bars and stay that way until hovered.
// Hovering a clock brings all three back, then that clock's own weather (Salem, Ho Chi Minh City or New York, in °F);
// moving away tucks the weather into its clock, then the clocks fold.
//
// The local bar's color says how close the next Apple Calendar event is (timed events in the next 24 hours):
//   red     ≤ 1 hour      (ADHD rule of thumb: things take about twice as long, so this is ~30 minutes of real room)
//   yellow  ≤ 6 hours
//   green   > 6 hours
//   gray    nothing coming up, or no Calendar access
// These thresholds are a starting point, not a settled hierarchy. The Vietnam and Eastern bars stay gray.
//
// Below: a calendar (month, a week strip you move through by hovering and swiping two fingers, and the
// chosen day's events; click one to edit it in Calendar).

let timeVisibleFor: TimeInterval = 4      // how long the time stays up after the panel opens before it melts
let redWithin: TimeInterval = 60 * 60
let yellowWithin: TimeInterval = 6 * 60 * 60
/// The three clocks: local (top center), then bottom-left and bottom-right. Each has the place its weather is for.
/// "PT" at home (like "ET" for Eastern, covering both standard and daylight time); elsewhere, the zone's abbreviation.
func localZoneLabel() -> String {
    TimeZone.current.identifier == "America/Los_Angeles" ? "PT" : (TimeZone.current.abbreviation() ?? "")
}
struct ClockSpec { let label: String; let zone: String?; let place: String; let lat: Double; let lon: Double }
let clockSpecs = [
    ClockSpec(label: localZoneLabel(), zone: nil, place: "Salem, OR", lat: 44.9429, lon: -123.0351),
    ClockSpec(label: "VN", zone: "Asia/Ho_Chi_Minh", place: "Ho Chi Minh City", lat: 10.8231, lon: 106.6297),
    ClockSpec(label: "ET", zone: "America/New_York", place: "New York", lat: 40.7128, lon: -74.0060),
]
// Weather: Open-Meteo (free, no account). Sill's only network request: one call every 30 minutes carrying the
// three fixed coordinates above and nothing else. Set weatherEnabled = false to turn it off.
let weatherEnabled = true

/// One clock that folds into a bar.
final class FoldingClock {
    let label = NSTextField(labelWithString: "")
    let bar = NSView()
    let weather = NSTextField(labelWithString: "")
    var weatherText = ""
    var weatherWork: DispatchWorkItem?
    let format = DateFormatter()
    let barWidth: CGFloat
    var center = NSPoint.zero
    let suffix: String
    let spec: ClockSpec

    init(_ spec: ClockSpec, size: CGFloat, barWidth: CGFloat, seconds: Bool = false) {
        self.spec = spec
        self.barWidth = barWidth
        self.suffix = spec.label
        let zone = spec.zone
        if let z = zone { format.timeZone = TimeZone(identifier: z) }
        format.setLocalizedDateFormatFromTemplate(seconds ? "jmmss" : "jmm")   // follows the 12/24-hour setting
        label.font = roundedFont(size, zone == nil ? .medium : .semibold)
        label.textColor = .white
        label.alignment = .center
        label.alphaValue = 0
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        bar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.5).cgColor
        weather.font = .systemFont(ofSize: zone == nil ? 12 : 11, weight: .regular)
        weather.textColor = .white
        weather.alignment = .center
        weather.alphaValue = 0
    }

    func add(to parent: NSView) { [label, bar, weather].forEach(parent.addSubview) }

    /// The area that reveals this clock's weather when hovered.
    var hoverRect: NSRect { label.frame.union(weather.frame).insetBy(dx: 20, dy: -2) }

    func place(at c: NSPoint) {
        center = c
        let h = label.font!.pointSize + 8
        label.frame = NSRect(x: c.x - 130, y: c.y - h / 2, width: 260, height: h)
        weather.frame = NSRect(x: c.x - 100, y: c.y - h / 2 - 16, width: 200, height: 16)
        bar.frame = barFrame(folded: bar.alphaValue > 0)
    }

    func barFrame(folded: Bool) -> NSRect {
        let w = folded ? barWidth : 0
        return NSRect(x: (center.x - w / 2).rounded(), y: (center.y - 1.5).rounded(), width: w, height: 3)
    }

    /// The time, then its zone label in a smaller, quieter type, the same on every clock.
    func tick(_ now: Date) {
        let t = format.string(from: now)
        guard t != lastTime else { return }
        lastTime = t
        let size = label.font!.pointSize
        let s = NSMutableAttributedString(string: t, attributes: [.font: label.font!, .foregroundColor: label.textColor!])
        if !suffix.isEmpty {
            s.append(NSAttributedString(string: "  " + suffix, attributes: [
                .font: roundedFont(11, .semibold),                // the zone, quieter than the time
                .foregroundColor: NSColor.white]))
        }
        let para = NSMutableParagraphStyle(); para.alignment = .center
        s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
        label.attributedStringValue = s
    }
    var lastTime = ""

    func unfold() {
        label.animator().alphaValue = 1
        bar.animator().frame = barFrame(folded: false)
        bar.animator().alphaValue = 0
    }

    /// The weather fades in under the clock, a beat after the clock itself appears.
    func showWeather() {
        weatherWork?.cancel()
        guard !weatherText.isEmpty else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.weather.stringValue = self.weatherText
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self.weather.animator().alphaValue = 1
            }
        }
        weatherWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: w)   // hover the number a moment for the weather
    }

    /// The weather tucks back into the clock.
    func hideWeather() {
        weatherWork?.cancel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            weather.animator().alphaValue = 0
        }
    }

    func fold() {
        weather.animator().alphaValue = 0
        label.animator().alphaValue = 0
        bar.animator().frame = barFrame(folded: true)
        bar.animator().alphaValue = 1
    }
}

// MARK: - Calendar

// MARK: - Agenda: the prioritized three-day window
//
// The calendar organizes the schedule before you look at it: a forward-looking window of three calendar days, every
// event occurrence in it, ranked by a small transparent score. The score decides the order, never what you see.
//
// Window rule: start at the reference date (today, or the day you slid to). If no eligible event remains on it, skip it:
// the window is the next three calendar dates instead. "Eligible" means the occurrence overlaps that date and hasn't
// ended yet (in progress counts; all-day and multi-day count). Dates come from Calendar.current, never 24-hour offsets,
// so midnight, time zones and daylight saving land on real date boundaries.
//
// Priority score (higher = nearer the top). Weights live in `AgendaScore` so they can be read and tuned in one place:
//   Explicit markers in the title (the title itself is never changed):
//     [URGENT] +100 · [DEADLINE] +70 · [GOAL] +40
//   Time urgency (bands, not a per-second score):
//     in progress +30 · starts within 2 h +25 · within 6 h +15 · later today +8
//     an all-day event on the first day +8 (all-day is not "unimportant")
//   Day proximity within the window: first day +12 · second +6 · third +0
//   Has an alarm in Apple Calendar: +4 (a small hint, not a verdict)
//   Ties: earlier start first, then title, then the occurrence key, so equal items never shuffle.

enum AgendaScore {
    static let markers: [(String, Int)] = [("[URGENT]", 100), ("[DEADLINE]", 70), ("[GOAL]", 40)]
    static let inProgress = 30, within2h = 25, within6h = 15, laterToday = 8, allDayFirstDay = 8
    static let dayProximity = [12, 6, 0]
    static let alarm = 4

    static func score(_ e: EKEvent, dayIndex: Int, now: Date, calendar cal: Calendar = .current) -> Int {
        var s = 0
        let title = (e.title ?? "").uppercased()
        for (m, w) in markers where title.contains(m) { s += w }
        if e.isAllDay {
            if dayIndex == 0 { s += allDayFirstDay }
        } else if e.startDate <= now && e.endDate > now {
            s += inProgress
        } else {
            let until = e.startDate.timeIntervalSince(now)
            if until <= 2 * 3600 { s += within2h }
            else if until <= 6 * 3600 { s += within6h }
            else if cal.isDate(e.startDate, inSameDayAs: now) { s += laterToday }
        }
        s += dayProximity[min(max(dayIndex, 0), dayProximity.count - 1)]
        if !(e.alarms ?? []).isEmpty { s += alarm }
        return s
    }
}

struct AgendaItem {
    let event: EKEvent
    let key: String            // one occurrence: item + its own start/end + calendar
    let day: Date              // the window date it's listed (and counted) under
    let dayIndex: Int
    let score: Int
}

struct Agenda {
    let days: [Date]           // the three dates
    let start: Date, end: Date // [start of first date, start of the date after the third)
    let items: [AgendaItem]    // ranked
    var counts: [Int] { days.map { d in items.filter { $0.day == d }.count } }

    static func occurrenceKey(_ e: EKEvent) -> String {
        "\(e.calendarItemIdentifier)|\(e.calendar?.calendarIdentifier ?? "")|\(e.startDate.timeIntervalSince1970)|\(e.endDate.timeIntervalSince1970)"
    }

    /// Builds the window from `reference` and ranks everything in it. `fetch(start, end)` returns occurrences
    /// overlapping the interval (EventKit expands repeating events into occurrences).
    static func build(reference: Date, now: Date, calendar cal: Calendar = .current,
                      fetch: (Date, Date) -> [EKEvent]) -> Agenda {
        let ref = cal.startOfDay(for: reference)
        let refEnd = cal.date(byAdding: .day, value: 1, to: ref)!
        let remaining = fetch(ref, refEnd).contains { $0.endDate > now && $0.endDate > ref && $0.startDate < refEnd }
        let first = remaining ? ref : refEnd
        let days = (0..<3).map { cal.date(byAdding: .day, value: $0, to: first)! }
        let end = cal.date(byAdding: .day, value: 3, to: first)!
        var seen = Set<String>()
        var items: [AgendaItem] = []
        for e in fetch(first, end) where e.endDate > now && e.endDate > first && e.startDate < end {
            let key = occurrenceKey(e)
            guard seen.insert(key).inserted else { continue }         // the same occurrence never twice
            // Listed under the date it starts on, or the window's first date if it began earlier (ongoing).
            let day = cal.startOfDay(for: max(e.startDate, first))
            let idx = days.firstIndex(of: day) ?? 0
            items.append(AgendaItem(event: e, key: key, day: day, dayIndex: idx,
                                    score: AgendaScore.score(e, dayIndex: idx, now: now, calendar: cal)))
        }
        items.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.event.startDate != $1.event.startDate { return $0.event.startDate < $1.event.startDate }
            let t0 = $0.event.title ?? "", t1 = $1.event.title ?? ""
            if t0 != t1 { return t0 < t1 }
            return $0.key < $1.key
        }
        return Agenda(days: days, start: first, end: end, items: items)
    }
}

/// One event in the original Sill layout: a center spine with a small blue dot. The title sits right-aligned to the
/// left of the spine (wrapping to two lines); to the right, its date and time, and the location under them when the
/// event has one. Every row shares the spine, so dates and times line up straight down. Clicking opens the event in
/// Apple Calendar.
final class EventRow: NSView {
    let event: EKEvent
    let key: String
    private let titleField: NSTextField
    static let titleColor = NSColor.white
    static let hoverColor = bioCyan
    static let font = roundedFont(12.5, .medium)

    init(_ e: EKEvent, key: String, listedOn day: Date, width: CGFloat, timeFormat: DateFormatter, showDate: Bool = true) {
        event = e
        self.key = key
        let cal = Calendar.current
        let mid = (width * 0.52).rounded()
        let titleW = mid - 14
        let title = NSTextField(wrappingLabelWithString: e.title ?? "")
        title.font = EventRow.font; title.textColor = EventRow.titleColor
        title.alignment = .right
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        title.cell?.truncatesLastVisibleLine = true
        title.toolTip = e.title
        titleField = title
        let th = min(34, ceil(title.sizeThatFits(NSSize(width: titleW, height: 100)).height))
        let df = DateFormatter(); df.setLocalizedDateFormatFromTemplate("EEEMMMd")
        let dayName = DateFormatter(); dayName.setLocalizedDateFormatFromTemplate("EEE")
        var hours: String
        if e.isAllDay { hours = "All day" } else {
            let endsOtherDay = !cal.isDate(e.startDate, inSameDayAs: e.endDate.addingTimeInterval(-1))
            hours = "\(timeFormat.string(from: e.startDate)) – " + (endsOtherDay ? "\(dayName.string(from: e.endDate)) " : "") + timeFormat.string(from: e.endDate)
        }
        let place = e.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let h = max(22, th + 4, place.isEmpty ? 22 : 38)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: h))
        title.frame = NSRect(x: 0, y: h - th - 2, width: titleW, height: th)
        let dot = NSView(frame: NSRect(x: mid - 3, y: h - 13, width: 6, height: 6))
        // Events marked [URGENT], [DEADLINE] or [GOAL] show their weight in the dot (Lantern glow), not by moving.
        let marked = AgendaScore.markers.contains { (e.title ?? "").uppercased().contains($0.0) }
        dot.wantsLayer = true; dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = (marked ? bioCyan : calmBlue).cgColor
        if marked { dot.layer?.shadowColor = bioCyan.cgColor; dot.layer?.shadowRadius = 4; dot.layer?.shadowOpacity = 0.9; dot.layer?.shadowOffset = .zero }
        let when = NSTextField(labelWithString: showDate ? "\(df.string(from: day)) · \(hours)" : hours)
        when.font = EventRow.font; when.textColor = .white; when.lineBreakMode = .byTruncatingTail
        when.frame = NSRect(x: mid + 10, y: h - 20, width: width - mid - 10, height: 18)
        when.toolTip = when.stringValue
        [title, dot, when].forEach(addSubview)
        if !place.isEmpty {
            let loc = NSTextField(labelWithString: place)
            loc.font = roundedFont(11.5, .medium); loc.textColor = .white; loc.lineBreakMode = .byTruncatingTail
            loc.frame = NSRect(x: mid + 10, y: h - 36, width: width - mid - 10, height: 15)
            loc.toolTip = place
            addSubview(loc)
        }
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { titleField.textColor = EventRow.hoverColor }
    override func mouseExited(with e: NSEvent) { titleField.textColor = EventRow.titleColor }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    /// Opens this event in Calendar, ready to edit. Calendar's changes come back through EKEventStoreChanged.
    override func mouseDown(with ev: NSEvent) {
        let id = event.calendarItemIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        if let url = URL(string: "ical://ekevent/\(id)?method=show&options=more"), NSWorkspace.shared.open(url) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// The day strip is a sliding scale. Hover it and swipe two fingers: the days slide continuously under your
/// fingers, and each time the center lands on a new day the trackpad gives a click (haptic) and that day swells:
/// its number grows, its weekday grows from one letter to three (W → WED) and it turns blue, while the days around it
/// stay readable but gently blurred. Fingers left → future, fingers right → past (Draftpad's direction logic).
/// Weekdays: M T W R F S SU.
let shortWeekdays = ["SU", "M", "T", "W", "R", "F", "S"]          // indexed by Calendar weekday - 1
let longWeekdays = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]

/// SF Pro Rounded, with even-width digits: the soft, round type of the calendar.
func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
    return NSFont(descriptor: d, size: size) ?? base
}

final class DayCell {
    let number = NSTextField(labelWithString: "")
    let shortDay = NSTextField(labelWithString: "")
    let longDay = NSTextField(labelWithString: "")
    let dot = NSView()
    let box = NSView()                       // holds the cell; scaled and blurred as one
    init() {
        box.wantsLayer = true
        number.font = roundedFont(15, .semibold)
        number.alignment = .center
        for l in [shortDay, longDay] {
            l.font = roundedFont(9, .bold)
            l.alignment = .center
        }
        shortDay.textColor = NSColor.white.withAlphaComponent(0.9)        // white type throughout: gray sinks into the bar
        longDay.textColor = .white
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2
        [shortDay, longDay, number, dot].forEach(box.addSubview)
    }
}

final class DayStrip: NSView {
    var onSelect: ((Date) -> Void)?
    var hasEvents: (Date) -> Bool = { _ in false }
    private(set) var anchor = Calendar.current.startOfDay(for: Date())   // day 0
    private var pos: CGFloat = 0             // continuous position in days from the anchor; the center sits here
    private var landed = 0                   // the day the center last snapped to
    private var settleTimer: Timer?
    private var cells: [DayCell] = []
    private let span = 4                     // days drawn on each side of the center
    var cellWidth: CGFloat = 33              // even spacing; the essentials panel spaces the days out

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = true
        for _ in 0...(2 * span) { let c = DayCell(); cells.append(c); addSubview(c.box) }
    }
    required init?(coder: NSCoder) { fatalError() }

    var selected: Date { Calendar.current.date(byAdding: .day, value: landed, to: anchor)! }

    func reset(to day: Date) {
        settleTimer?.invalidate()
        anchor = Calendar.current.startOfDay(for: day)
        pos = 0; landed = 0
        layoutCells()
    }

    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); layoutCells() }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return }
        guard event.momentumPhase.isEmpty else { return }          // no coasting: the scale stays under your fingers
        let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        if event.phase == .began { settleTimer?.invalidate() }
        if abs(dx) > abs(event.scrollingDeltaY) || event.phase == .changed {
            pos -= dx / cellWidth                                  // fingers left (dx < 0) → later days
            land(Int(pos.rounded()))
            layoutCells()
        }
        if event.phase == .ended || event.phase == .cancelled { settle() }
    }

    /// The center reached a new day: click under the fingers, tell the calendar.
    private func land(_ day: Int) {
        guard day != landed else { return }
        landed = day
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        onSelect?(selected)
    }

    /// Glide the last fraction of a day onto the landed day.
    private func settle() {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let target = CGFloat(self.landed)
            self.pos += (target - self.pos) * 0.22
            if abs(target - self.pos) < 0.002 { self.pos = target; t.invalidate() }
            self.layoutCells()
        }
    }

    func redraw() { layoutCells() }

    /// Moved by the horizon: glide to a day without a click of its own (the horizon already clicks).
    func glide(toOffset day: Int) {
        guard day != landed else { return }
        landed = day
        onSelect?(selected)
        settle()
    }
    var landedOffset: Int { landed }

    private func layoutCells() {
        // Modelled on the reference calendar: evenly spaced days; the selected one larger and blue (medium
        // weight, not bold); its neighbors a light gray, the next ones a step dimmer, the ends faint (weekends
        // muted red) and fading under the month name. No blur near the center, only a whisper at the ends.
        let cal = Calendar.current
        let mid = bounds.midX, h = bounds.height
        let base = Int(pos.rounded())
        let focus = NSColor.white                  // where the slider lands: white, larger
        for (i, c) in cells.enumerated() {
            let offset = base - span + i
            let day = cal.date(byAdding: .day, value: offset, to: anchor)!
            let d = CGFloat(offset) - pos
            let dist = abs(d)
            let e = max(0, 1 - dist)
            c.box.frame = NSRect(x: mid + d * cellWidth - cellWidth / 2, y: 0, width: cellWidth, height: h)

            let wd = cal.component(.weekday, from: day) - 1
            c.number.stringValue = String(format: "%02d", cal.component(.day, from: day))
            c.shortDay.stringValue = shortWeekdays[wd]
            c.longDay.stringValue = longWeekdays[wd]
            let weekend = wd == 0 || wd == 6
            // Brightness falls off with distance: 0.86 next door, 0.68 two away, then the weekend tint at the ends.
            _ = weekend
            let rest = NSColor.white                       // distance shows through the fade and blur, not gray
            // Only today's date glows bioluminescent, wherever the slider is; every other day stays white.
            c.number.textColor = cal.isDateInToday(day) ? bioCyan : (rest.blended(withFraction: e, of: focus) ?? rest)
            c.number.font = roundedFont(15, .medium)

            // The swell: the selected number grows by a third; the weekday spreads from one letter to three.
            let scale = 1 + 0.33 * e
            c.number.frame = NSRect(x: -6, y: 9, width: cellWidth + 12, height: 22)
            c.number.wantsLayer = true
            c.number.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            c.number.layer?.position = CGPoint(x: cellWidth / 2, y: 20)
            c.number.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
            for (l, a) in [(c.shortDay, 1 - e), (c.longDay, e)] {
                l.frame = NSRect(x: -8, y: h - 14, width: cellWidth + 16, height: 12)
                l.alphaValue = a
            }
            c.dot.frame = NSRect(x: cellWidth / 2 - 2, y: 2, width: 4, height: 4)
            c.dot.isHidden = !hasEvents(day)
            c.dot.layer?.backgroundColor = calmBlue.cgColor

            c.box.alphaValue = dist < 1.5 ? 1 : max(0, 1 - (dist - 1.5) * 0.45)   // 2 away ≈ 0.8, 3 away ≈ 0.3
            let blur = max(0, dist - 2.6) * 0.8
            if blur > 0.05, let f = CIFilter(name: "CIGaussianBlur") {
                f.setValue(blur, forKey: kCIInputRadiusKey)
                c.box.layer?.filters = [f]
            } else {
                c.box.layer?.filters = []
            }
        }
    }

}

final class CalendarView: NSView {
    let store: EKEventStore
    let month = NSTextField(labelWithString: "")
    let strip = DayStrip()
    let list = NSScrollView()
    let listBody = FlippedView()
    let empty = NSTextField(labelWithString: "")
    let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "calendar.badge.checkmark", accessibilityDescription: nil)!)
    var selected = Calendar.current.startOfDay(for: Date())
    var allowed = false
    let timeFormat = DateFormatter()
    let monthFormat = DateFormatter()
    let weekdayFormat = DateFormatter()
    let stripHeight: CGFloat = 44
    var gapBelowStrip: CGFloat = 6            // room the essentials panel keeps for the horizon
    var onDayChange: ((Date) -> Void)?        // the day strip landed on a new day
    // The agenda's pinned summary (stays put while the list scrolls).
    let heading = NSTextField(labelWithString: "")
    let dayCounts = NSTextField(labelWithString: "")
    let headerHeight: CGFloat = 58
    // The NEXT line: the most pressing event, how far it is from NOW. Pinned; the lanes scroll under it.
    let nextBox = NSView()
    let nextTag = NSTextField(labelWithString: "NEXT")
    let nextTitle = NSTextField(labelWithString: "")
    let nextWhen = NSTextField(labelWithString: "")
    let moreCue = NSTextField(labelWithString: "↓")
    private var shownSignature = ""
    var shownWindow: Date?
    private var lastScroll = Date.distantPast
    private var deferred: DispatchWorkItem?

    init(store: EKEventStore) {
        self.store = store
        super.init(frame: .zero)
        timeFormat.setLocalizedDateFormatFromTemplate("jmm")
        monthFormat.setLocalizedDateFormatFromTemplate("MMM")
        weekdayFormat.setLocalizedDateFormatFromTemplate("EEE")
        month.font = .systemFont(ofSize: 22, weight: .bold)
        month.textColor = .white
        let glow = NSShadow()                                     // a faint halo, as in the reference
        glow.shadowColor = NSColor.white.withAlphaComponent(0.35); glow.shadowBlurRadius = 6; glow.shadowOffset = .zero
        _ = glow                                              // crisp white, no halo (as in the reference)
        strip.onSelect = { [weak self] d in self?.selected = d; self?.reloadDay(); self?.onDayChange?(d) }
        strip.hasEvents = { [weak self] d in self?.dayHasEvents(d) ?? false }
        // Only the list scrolls: native momentum and vertical elasticity, a transient overlay scroller, no sideways.
        list.drawsBackground = false
        list.hasVerticalScroller = true
        list.scrollerStyle = .overlay
        list.autohidesScrollers = true
        list.hasHorizontalScroller = false
        list.horizontalScrollElasticity = .none; list.verticalScrollElasticity = .allowed
        list.usesPredominantAxisScrolling = true
        list.documentView = listBody
        list.contentView.postsBoundsChangedNotifications = true
        list.automaticallyAdjustsContentInsets = false      // the panel isn't a titled window: no inset should push the list
        list.contentInsets = NSEdgeInsetsZero
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: list.contentView, queue: .main) { [weak self] _ in
            self?.lastScroll = Date()
        }
        for (l, size) in [(heading, CGFloat(10)), (dayCounts, CGFloat(10))] {
            l.font = roundedFont(size, .bold); l.textColor = .white; l.lineBreakMode = .byTruncatingTail
        }
        // Time-sensitive ranks move once a minute (only if something actually changed), and a new day resets the window.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.reloadDay() }
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            self?.resetToToday()
        }
        empty.font = roundedFont(13, .medium)
        empty.textColor = .white
        emptyIcon.contentTintColor = .white
        emptyIcon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        empty.alignment = .center
        nextBox.wantsLayer = true
        nextBox.layer?.cornerRadius = 12
        nextBox.layer?.backgroundColor = bioCyan.withAlphaComponent(0.08).cgColor
        nextBox.layer?.borderColor = bioCyan.withAlphaComponent(0.25).cgColor
        nextBox.layer?.borderWidth = 1
        nextTag.attributedStringValue = NSAttributedString(string: "NEXT", attributes: [.font: roundedFont(10, .heavy), .foregroundColor: bioCyan, .kern: 1.4])
        for l in [nextTitle, nextWhen] { l.font = roundedFont(12.5, .semibold); l.textColor = .white; l.lineBreakMode = .byTruncatingTail }
        nextWhen.alignment = .right
        [nextTag, nextTitle, nextWhen].forEach(nextBox.addSubview)
        moreCue.font = roundedFont(12, .bold); moreCue.textColor = bioCyan; moreCue.alignment = .right
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: list.contentView, queue: .main) { [weak self] _ in
            self?.updateMoreCue()
        }
        [strip, month, heading, dayCounts, nextBox, list, moreCue, empty, emptyIcon].forEach(addSubview)        // the month sits over the strip's faded end
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); reload() }

    func resetToToday() {
        shownWindow = nil                          // opening the panel starts the lanes at the top
        selected = Calendar.current.startOfDay(for: Date())
        markedDays = []; markedRange = nil
        strip.reset(to: selected)
        reload()
    }

    /// Days with events, looked up a month at a time around the selection (cheap to ask per cell).
    var markedDays: Set<Date> = []
    var markedRange: ClosedRange<Date>?
    func dayHasEvents(_ day: Date) -> Bool {
        let cal = Calendar.current
        if markedRange == nil || !markedRange!.contains(day) {
            let start = cal.date(byAdding: .day, value: -20, to: day)!, end = cal.date(byAdding: .day, value: 20, to: day)!
            markedRange = start...end
            markedDays = []
            for e in events(from: start, days: 40) {
                var d = cal.startOfDay(for: e.startDate)
                while d < e.endDate && d <= end { markedDays.insert(d); d = cal.date(byAdding: .day, value: 1, to: d)! }
            }
        }
        return markedDays.contains(cal.startOfDay(for: day))
    }

    func events(from start: Date, days: Int) -> [EKEvent] {
        guard allowed, let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
    }

    func reload() {
        let w = bounds.width, h = bounds.height
        guard w > 0 else { return }
        month.stringValue = monthFormat.string(from: selected)
        let mw = ceil(month.fittingSize.width) + 2
        // Centered and spaced out: the month, then nine days with the selected one in the middle.
        let cw = strip.cellWidth
        let total = mw + 10 + 9 * cw
        let x0 = max(0, ((w - total) / 2).rounded())
        month.frame = NSRect(x: x0, y: h - stripHeight + 9, width: mw, height: 26)
        strip.frame = NSRect(x: x0 + mw + 10, y: h - stripHeight, width: 9 * cw, height: stripHeight)

        markedRange = nil                // calendar data may have changed: look the event days up again
        strip.redraw()
        reloadDay()
    }

    /// The agenda for the reference date (today, or the day you slid to): one NEXT line, then a lane per day.
    /// The window and the "most pressing" pick come from `Agenda`; inside a lane, events stay in time order so nothing
    /// reshuffles while you read. A past date shows that day as one lane. Routine refreshes keep your place.
    func reloadDay() {
        let w = bounds.width, h = bounds.height
        guard w > 0 else { return }
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        month.stringValue = monthFormat.string(from: selected)
        let top = h - stripHeight - gapBelowStrip
        heading.frame = .zero; dayCounts.frame = .zero
        nextBox.frame = NSRect(x: 0, y: top - 46, width: w, height: 34)
        nextTag.frame = NSRect(x: 14, y: 9, width: 44, height: 15)
        nextWhen.frame = NSRect(x: w - 154, y: 8, width: 140, height: 17)
        nextTitle.frame = NSRect(x: 62, y: 8, width: w - 62 - 162, height: 17)
        // The list stops just above the cue's own line, so the ↓ never sits on top of an event.
        let listFrame = NSRect(x: 0, y: 16, width: w, height: max(0, top - headerHeight - 16))
        list.frame = listFrame
        moreCue.frame = NSRect(x: w - 40, y: 0, width: 36, height: 16)             // quiet, in the corner

        guard allowed else {
            nextBox.isHidden = true
            show([], signature: "denied", window: nil)
            empty.stringValue = "Allow Sill in Privacy & Security → Calendars"
            return
        }
        let byTime: (EKEvent, EKEvent) -> Bool = { $0.isAllDay != $1.isAllDay ? $0.isAllDay : ($0.startDate != $1.startDate ? $0.startDate < $1.startDate : ($0.title ?? "") < ($1.title ?? "")) }
        if selected < today {
            nextBox.isHidden = true
            let evs = events(from: selected, days: 1).sorted(by: byTime)
            let lane = (day: selected, rows: evs.map { (e: $0, key: Agenda.occurrenceKey($0)) })
            show([lane], signature: "past|\(selected)|" + lane.rows.map { $0.key }.joined(separator: ","), window: selected)
            return
        }
        let agenda = Agenda.build(reference: selected, now: now) { [weak self] a, b in
            guard let self = self else { return [] }
            return self.store.events(matching: self.store.predicateForEvents(withStart: a, end: b, calendars: nil))
        }
        // NEXT: the top of the ranking, counted from NOW.
        if let first = agenda.items.first {
            nextBox.isHidden = false
            nextTitle.stringValue = first.event.title ?? ""
            nextTitle.toolTip = first.event.title
            let t = first.event.startDate.timeIntervalSince(now)
            nextWhen.stringValue = t <= 0 ? "NOW" : t < 3600 ? "NOW + \(max(1, Int((t / 60).rounded(.up)))) min" : "NOW + " + lifeSpan(t)
        } else { nextBox.isHidden = true }
        let lanes = agenda.days.map { d in
            (day: d, rows: agenda.items.filter { $0.day == d }.map { $0.event }.sorted(by: byTime).map { (e: $0, key: Agenda.occurrenceKey($0)) })
        }
        let sig = "\(agenda.start)|" + agenda.items.map { "\($0.key)#\($0.event.title ?? "")#\($0.event.location ?? "")" }.sorted().joined(separator: ",")
            + "|next:\(nextTitle.stringValue)\(nextWhen.stringValue)"
        show(lanes, signature: sig, window: agenda.start)
    }

    /// Lays out the lanes. Same content: nothing moves. A new window: back to the top. Otherwise the row at the top of
    /// the view keeps its place, and while you're scrolling the change waits until you stop.
    private func show(_ lanes: [(day: Date, rows: [(e: EKEvent, key: String)])], signature: String, window: Date?) {
        let w = bounds.width
        let listFrame = list.frame
        let newWindow = window != shownWindow
        if signature == shownSignature && !newWindow { finishLayout(listFrame); return }
        if !newWindow && Date().timeIntervalSince(lastScroll) < 1.2 {
            deferred?.cancel()
            let d = DispatchWorkItem { [weak self] in self?.reloadDay() }
            deferred = d
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: d)
            return
        }
        let originY = list.contentView.bounds.origin.y
        let anchor = (listBody.subviews.compactMap { $0 as? EventRow }.first { $0.frame.maxY > originY + 1 })
        let anchorKey = anchor?.key, anchorOffset = (anchor?.frame.minY ?? 0) - originY
        listBody.subviews.forEach { $0.removeFromSuperview() }
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "d MMM"                         // "9 Oct": day first, always
        var y: CGFloat = 4
        var anchorY: CGFloat?
        for lane in lanes {
            // Lane label: the date, then how many (or FREE).
            let label = NSTextField(labelWithString: "")
            let date = dayFmt.string(from: lane.day)
            let tail = lane.rows.isEmpty ? "FREE" : "\(lane.rows.count)"
            let a = NSMutableAttributedString(string: date, attributes: [.font: roundedFont(11, .heavy), .foregroundColor: bioCyan, .kern: 1.2])
            a.append(NSAttributedString(string: "     " + tail, attributes: [.font: roundedFont(11, .heavy), .foregroundColor: NSColor.white, .kern: 1.2]))
            label.attributedStringValue = a
            label.frame = NSRect(x: 4, y: y, width: w - 8, height: 16)
            listBody.addSubview(label)
            y += lane.rows.isEmpty ? 26 : 24
            for r in lane.rows {
                let row = EventRow(r.e, key: r.key, listedOn: lane.day, width: w - 8, timeFormat: timeFormat, showDate: false)
                row.setFrameOrigin(NSPoint(x: 4, y: y))
                if r.key == anchorKey { anchorY = y }
                listBody.addSubview(row)
                y += row.frame.height + 14
            }
            if !lane.rows.isEmpty { y += 6 }
        }
        listBody.frame = NSRect(x: 0, y: 0, width: w, height: max(listFrame.height, y))
        let maxY = max(0, listBody.frame.height - listFrame.height)
        let target: CGFloat = newWindow ? 0 : min(maxY, max(0, (anchorY.map { $0 - anchorOffset }) ?? originY))
        list.contentView.scroll(to: NSPoint(x: 0, y: target))
        list.reflectScrolledClipView(list.contentView)
        shownSignature = signature
        shownWindow = window
        finishLayout(listFrame)
    }

    private func finishLayout(_ listFrame: NSRect) {
        layoutEmpty(listBody.subviews.isEmpty, listFrame)
        updateMoreCue()
    }

    /// An honest "more below" cue: shows only while there's list content under the visible part.
    func updateMoreCue() {
        let visibleBottom = list.contentView.bounds.maxY
        moreCue.isHidden = listBody.frame.height - visibleBottom < 4
    }

    private func layoutEmpty(_ isEmpty: Bool, _ listFrame: NSRect) {
        let w = bounds.width
        empty.isHidden = !isEmpty
        empty.frame = NSRect(x: 0, y: listFrame.midY - 14, width: w, height: 17)
        emptyIcon.frame = NSRect(x: w / 2 - 10, y: listFrame.midY + 6, width: 20, height: 18)
        emptyIcon.isHidden = empty.isHidden
    }
}

/// Top-down layout for the event list.
final class FlippedView: NSView { override var isFlipped: Bool { true } }

// MARK: - Recorder
//
// Capture in the essentials panel, in three states:
//   Ready      a slim capsule. Click it to open the pre-flight settings.
//   Settings   choose any mix of Microphone (.m4a), Screen (.mov) and Camera (.mov), pick the microphone, display
//              and camera, watch a live input meter, see where files go, then Start Recording.
//   Recording  click: pause / resume · double-click: stop and save · right-click: Reveal in Finder / Copy Path.
//
// Microphone audio is AAC (.m4a) in Voice Memos' recordings folder, where Chau expects it (Voice Memos keeps its own
// index, so these may not show in its list). Screen (display + system audio, ScreenCaptureKit, macOS 15+) and camera
// (face-to-face video with the chosen microphone) are .mov files in ~/Movies/Sill Recordings. All selected streams
// start together and stop together. The camera is a separate file for now; a picture-in-picture composite is not
// built yet. Permissions are asked the first time each source is used.

let recordingsFolder = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"
let screenRecordingsFolder = NSHomeDirectory() + "/Movies/Sill Recordings"

enum CaptureState: Equatable { case ready, settings, recording, paused }

/// The Mac's built-in microphone when there is one. Using AirPods as the microphone switches them into their
/// low-quality call mode for everything you hear as well, so recordings default to the Mac's mic; AirPods can still
/// be picked in the output settings.
func preferredMicID() -> String? {
    let mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
    return (mics.first { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) }
            ?? AVCaptureDevice.default(for: .audio))?.uniqueID
}

struct CaptureChoice {
    var mic = true, screen = false, camera = false
    var micID: String? = preferredMicID()
    var cameraID: String? = AVCaptureDevice.default(for: .video)?.uniqueID
    var displayIndex = 0
}

func audioDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
}
func videoDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
}

/// Screen + system audio to a .mov, via ScreenCaptureKit's recording output (macOS 15 and later).
@available(macOS 15.0, *)
final class ScreenCapture: NSObject, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private var finished: ((Bool) -> Void)?

    func start(to url: URL, screen: NSScreen?, micID: String? = nil, _ done: @escaping (Bool) -> Void) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let id = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
                    done(false); return
                }
                let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
                let cfg = SCStreamConfiguration()
                let scale = screen?.backingScaleFactor ?? 2
                cfg.width = Int(CGFloat(display.width) * scale); cfg.height = Int(CGFloat(display.height) * scale)
                cfg.capturesAudio = true                      // computer audio, always
                cfg.captureMicrophone = true                  // and your voice
                if let id = micID { cfg.microphoneCaptureDeviceID = id }
                cfg.showsCursor = true
                let rc = SCRecordingOutputConfiguration()
                rc.outputURL = url
                rc.outputFileType = .mov
                let out = SCRecordingOutput(configuration: rc, delegate: self)
                let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
                try s.addRecordingOutput(out)
                try await s.startCapture()
                stream = s
                done(true)
            } catch {
                NSLog("sill: screen capture couldn't start: \(error.localizedDescription)")
                done(false)
            }
        }
    }

    func stop(_ done: @escaping (Bool) -> Void) {
        guard let s = stream else { done(false); return }
        finished = done
        Task {
            try? await s.stopCapture()
            stream = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.finished?(true); self.finished = nil }
        }
    }
    func recordingOutputDidFinishRecording(_ o: SCRecordingOutput) {
        DispatchQueue.main.async { self.finished?(true); self.finished = nil }
    }
    func recordingOutput(_ o: SCRecordingOutput, didFailWithError error: Error) {
        NSLog("sill: screen capture failed: \(error.localizedDescription)")
        DispatchQueue.main.async { self.finished?(false); self.finished = nil }
    }
}

/// Microphone + computer audio, always together, in one .m4a.
///
/// ScreenCaptureKit hands Sill both the system's audio output and the chosen microphone on one clock. They're
/// written as two tracks while recording, then mixed down into a single-track .m4a when you stop (silence where the
/// computer played nothing), so every audio recording simply includes whatever the Mac was playing. Pausing drops
/// the samples and closes the gap, so the file has no dead air.
@available(macOS 15.0, *)
final class MixedAudioRecorder: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var systemIn: AVAssetWriterInput?
    private var micIn: AVAssetWriterInput?
    private var started = false
    private var paused = false
    private var gap = CMTime.zero                  // total paused time, removed from timestamps
    private var pauseStart: CMTime?
    private var lastPTS = CMTime.zero
    private let queue = DispatchQueue(label: "local.sill.mixed-audio")
    private var tempURL: URL?
    private var finalURL: URL?
    private(set) var power: Float = -160          // microphone
    private(set) var systemPower: Float = -160    // computer audio

    var level: CGFloat { CGFloat(max(0, min(1, (power + 65) / 55))) }
    var systemLevel: CGFloat { CGFloat(max(0, min(1, (systemPower + 65) / 55))) }

    func start(to url: URL, micID: String?, _ done: @escaping (Bool) -> Void) {
        finalURL = url
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sill-\(UUID().uuidString).m4a")
        tempURL = temp
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { done(false); return }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let cfg = SCStreamConfiguration()
                cfg.width = 2; cfg.height = 2                         // audio only: the video is a token 2×2
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                cfg.capturesAudio = true
                cfg.excludesCurrentProcessAudio = true
                cfg.captureMicrophone = true
                if let id = micID { cfg.microphoneCaptureDeviceID = id }
                cfg.sampleRate = 48000; cfg.channelCount = 2

                let w = try AVAssetWriter(outputURL: temp, fileType: .m4a)
                let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                          AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
                let sys = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
                let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
                [sys, mic].forEach { $0.expectsMediaDataInRealTime = true; w.add($0) }
                writer = w; systemIn = sys; micIn = mic

                let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
                try await s.startCapture()
                stream = s
                done(true)
            } catch {
                NSLog("sill: audio capture couldn't start: \(error.localizedDescription)")
                done(false)
            }
        }
    }

    func stream(_ s: SCStream, didOutputSampleBuffer b: CMSampleBuffer, of type: SCStreamOutputType) {
        guard b.isValid, let w = writer, type == .audio || type == .microphone else { return }
        let pts = b.presentationTimeStamp
        if type == .microphone { power = rms(b) } else if let p = floatRMS(b) { systemPower = p }
        if paused { return }
        if !started {
            guard w.startWriting() else { NSLog("sill: audio writer: \(w.error?.localizedDescription ?? "?")"); return }
            w.startSession(atSourceTime: pts)
            started = true
        }
        let input = type == .audio ? systemIn : micIn
        guard let i = input, i.isReadyForMoreMediaData else { return }
        lastPTS = pts
        if gap == .zero { i.append(b) }
        else if let shifted = retime(b, by: gap) { i.append(shifted) }
    }

    func pause() { queue.async { self.paused = true; self.pauseStart = self.lastPTS } }
    func resume() {
        queue.async {
            // Everything after the pause moves earlier by its length (estimated from the wall clock).
            if let p = self.pauseStart { _ = p }
            self.paused = false
        }
    }
    /// Pause length, measured by the caller on the wall clock (the stream has no samples while paused).
    func addGap(seconds: Double) { queue.async { self.gap = CMTimeAdd(self.gap, CMTime(seconds: seconds, preferredTimescale: 48000)) } }

    func stop(_ done: @escaping (URL?) -> Void) {
        guard let s = stream else { done(nil); return }
        Task {
            try? await s.stopCapture()
            stream = nil
            queue.async {
                guard let w = self.writer, self.started else { done(nil); return }
                self.systemIn?.markAsFinished(); self.micIn?.markAsFinished()
                w.finishWriting { self.mixDown(done) }
            }
        }
    }

    /// Two tracks → one, explicitly: an audio-mix reader sums the computer track and the microphone track into one
    /// PCM stream, which is encoded as a single AAC track. (An export preset may keep or drop tracks depending on
    /// the macOS version; mixing ourselves means the computer audio can't silently go missing.) If anything fails,
    /// the two-track file is kept as is, so nothing is lost.
    private func mixDown(_ done: @escaping (URL?) -> Void) {
        guard let temp = tempURL, let out = finalURL else { done(nil); return }
        let asset = AVURLAsset(url: temp)
        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard !tracks.isEmpty else { throw NSError(domain: "sill", code: 1) }
                let reader = try AVAssetReader(asset: asset)
                let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                                          AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                                          AVLinearPCMIsBigEndianKey: false]
                let mix = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcm)
                reader.add(mix)
                try? FileManager.default.removeItem(at: out)
                let writer = try AVAssetWriter(outputURL: out, fileType: .m4a)
                let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                          AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
                writer.add(input)
                guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? NSError(domain: "sill", code: 2) }
                writer.startSession(atSourceTime: .zero)
                let q = DispatchQueue(label: "local.sill.mixdown")
                input.requestMediaDataWhenReady(on: q) {
                    _ = reader                                   // keep the reader alive until the mix is done
                    while input.isReadyForMoreMediaData {
                        if let b = mix.copyNextSampleBuffer() { input.append(b); continue }
                        input.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed { try? FileManager.default.removeItem(at: temp); done(out) }
                            else { NSLog("sill: mixdown write failed (\(writer.error?.localizedDescription ?? "?")); keeping the two-track file")
                                   try? FileManager.default.removeItem(at: out); try? FileManager.default.moveItem(at: temp, to: out); done(out) }
                        }
                        return
                    }
                }
            } catch {
                NSLog("sill: mixdown failed (\(error.localizedDescription)); keeping the two-track file")
                try? FileManager.default.moveItem(at: temp, to: out); done(out)
            }
        }
    }

    private func retime(_ b: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(b, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(b, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for k in 0..<count {
            timing[k].presentationTimeStamp = CMTimeSubtract(timing[k].presentationTimeStamp, offset)
            if timing[k].decodeTimeStamp.isValid { timing[k].decodeTimeStamp = CMTimeSubtract(timing[k].decodeTimeStamp, offset) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: b, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    private func rms(_ b: CMSampleBuffer) -> Float {
        var list = AudioBufferList()
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(b, bufferListSizeNeededOut: nil, bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &block) == noErr, let data = list.mBuffers.mData else { return power }
        let n = Int(list.mBuffers.mDataByteSize) / 4
        guard n > 0 else { return power }
        let p = data.assumingMemoryBound(to: Float.self)
        var sum: Float = 0
        for i in 0..<n { sum += p[i] * p[i] }
        return 20 * log10(max(sqrt(sum / Float(n)), 1e-8))
    }
}

/// Listens to what the Mac is playing (no recording), for the computer-audio meter: so you can see before and during a
/// recording that the other person's voice is actually reaching the computer's audio, not just your headphones.
@available(macOS 15.0, *)
final class SystemAudioMeter: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "local.sill.system-meter")
    private(set) var power: Float = -160
    var level: CGFloat { CGFloat(max(0, min(1, (power + 65) / 55))) }

    func start() {
        guard stream == nil else { return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { return }
                let cfg = SCStreamConfiguration()
                cfg.width = 2; cfg.height = 2
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                cfg.capturesAudio = true
                cfg.excludesCurrentProcessAudio = true
                let s = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                                 configuration: cfg, delegate: nil)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                try await s.startCapture()
                stream = s
            } catch { NSLog("sill: computer-audio meter couldn't start: \(error.localizedDescription)") }
        }
    }
    func stop() {
        guard let s = stream else { return }
        stream = nil; power = -160
        Task { try? await s.stopCapture() }
    }
    func stream(_ s: SCStream, didOutputSampleBuffer b: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        power = floatRMS(b) ?? power
    }
}

/// RMS level (dB) of a float PCM sample buffer, as ScreenCaptureKit delivers audio. ScreenCaptureKit's audio is
/// non-interleaved stereo (one buffer per channel), so the buffer list is sized for however many buffers it has;
/// a fixed one-buffer list made the call fail and the meter sat at silence.
func floatRMS(_ b: CMSampleBuffer) -> Float? {
    var needed = 0
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(b, bufferListSizeNeededOut: &needed, bufferListOut: nil,
        bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr,
          needed > 0 else { return nil }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let listPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    var block: CMBlockBuffer?
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(b, bufferListSizeNeededOut: nil, bufferListOut: listPtr,
        bufferListSize: needed, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr else { return nil }
    var sum: Float = 0, n = 0
    for buf in UnsafeMutableAudioBufferListPointer(listPtr) {
        guard let d = buf.mData else { continue }
        let c = Int(buf.mDataByteSize) / 4
        let p = d.assumingMemoryBound(to: Float.self)
        for i in 0..<c { sum += p[i] * p[i] }
        n += c
    }
    guard n > 0 else { return nil }
    return 20 * log10(max(sqrt(sum / Float(n)), 1e-8))
}

/// Microphone (.m4a) and camera (.mov) capture in one AVCaptureSession, plus the level meter.
final class DeviceCapture: NSObject, AVCaptureFileOutputRecordingDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let audioFile = AVCaptureAudioFileOutput()
    let movieFile = AVCaptureMovieFileOutput()
    let levels = AVCaptureAudioDataOutput()       // receives the live audio so the input level can be read
    private var micInput: AVCaptureDeviceInput?
    private var lastPower: Float = -160
    private let levelQueue = DispatchQueue(label: "local.sill.levels")

    override init() {
        super.init()
        levels.setSampleBufferDelegate(self, queue: levelQueue)
    }

    /// Computes the level straight from the audio samples (RMS, in dB).
    func captureOutput(_ o: AVCaptureOutput, didOutput b: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let fmt = CMSampleBufferGetFormatDescription(b),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
        var list = AudioBufferList()
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(b, bufferListSizeNeededOut: nil, bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &block) == noErr, let data = list.mBuffers.mData else { return }
        let bytes = Int(list.mBuffers.mDataByteSize)
        var sum: Double = 0, n = 0
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let p = data.assumingMemoryBound(to: Float.self); n = bytes / 4
            for i in 0..<n { sum += Double(p[i] * p[i]) }
        } else if asbd.mBitsPerChannel == 16 {
            let p = data.assumingMemoryBound(to: Int16.self); n = bytes / 2
            for i in 0..<n { let v = Double(p[i]) / 32768; sum += v * v }
        } else if asbd.mBitsPerChannel == 32 {
            let p = data.assumingMemoryBound(to: Int32.self); n = bytes / 4
            for i in 0..<n { let v = Double(p[i]) / 2147483648; sum += v * v }
        }
        guard n > 0 else { return }
        let rms = sqrt(sum / Double(n))
        lastPower = Float(20 * log10(max(rms, 1e-8)))
    }

    /// Builds the session for the chosen devices. Returns false if a device couldn't be opened.
    func configure(micID: String?, cameraID: String?, wantMicFile: Bool, wantCamera: Bool) -> Bool {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        defer { session.commitConfiguration() }
        if let id = micID, let d = AVCaptureDevice(uniqueID: id), let i = try? AVCaptureDeviceInput(device: d),
           session.canAddInput(i) { session.addInput(i); micInput = i } else { micInput = nil }
        if wantCamera, let id = cameraID, let d = AVCaptureDevice(uniqueID: id), let i = try? AVCaptureDeviceInput(device: d),
           session.canAddInput(i) { session.addInput(i) } else if wantCamera { return false }
        if session.canAddOutput(levels) { session.addOutput(levels) }
        if wantMicFile, session.canAddOutput(audioFile) { session.addOutput(audioFile) }
        if wantCamera, session.canAddOutput(movieFile) { session.addOutput(movieFile) }
        return true
    }

    /// The microphone's current level, 0…1 (from the input's own meter).
    /// −65 dB (a quiet room) … −10 dB (loud speech) → 0 … 1.
    var level: CGFloat { CGFloat(max(0, min(1, (lastPower + 65) / 55))) }
    var power: Float { lastPower }

    func startFiles(audio: URL?, movie: URL?) {
        if let a = audio {
            // Stereo, so a multi-channel input (an aggregate of mic + BlackHole/Loopback) keeps both sides.
            audioFile.audioSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2]
            audioFile.startRecording(to: a, outputFileType: .m4a, recordingDelegate: self)
        }
        if let m = movie { movieFile.startRecording(to: m, recordingDelegate: self) }
    }
    func pause() { [audioFile, movieFile].forEach { if $0.isRecording { $0.pauseRecording() } } }
    func resume() { [audioFile, movieFile].forEach { if $0.isRecordingPaused { $0.resumeRecording() } } }
    func stopFiles() { [audioFile, movieFile].forEach { if $0.isRecording { $0.stopRecording() } } }

    func fileOutput(_ o: AVCaptureFileOutput, didFinishRecordingTo url: URL, from c: [AVCaptureConnection], error: Error?) {
        if let e = error { NSLog("sill: recording to \(url.lastPathComponent) ended with: \(e.localizedDescription)") }
    }
}

/// A small on/off chip for one capture source.
final class SourceChip: NSView {
    let icon = NSImageView(), label = NSTextField(labelWithString: "")
    var on = false { didSet { paint() } }
    var onToggle: ((Bool) -> Void)?
    init(_ symbol: String, _ title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        label.stringValue = title; label.font = roundedFont(11, .semibold)
        [icon, label].forEach(addSubview)
        paint()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        icon.frame = NSRect(x: 9, y: (bounds.height - 14) / 2, width: 15, height: 14)
        label.frame = NSRect(x: 28, y: (bounds.height - 15) / 2, width: bounds.width - 32, height: 15)
    }
    func paint() {
        layer?.backgroundColor = (on ? NSColor.systemRed.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.08)).cgColor
        icon.contentTintColor = .white                       // white whether on or off; the chip's fill shows the state
        label.textColor = .white
    }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { on.toggle(); onToggle?(on) }
}

/// A small floating mirror: turn Camera on in the output settings and you see yourself, to check framing and
/// lighting before you record. It sits beside the panel, rounded, mirrored like FaceTime, and closes when Camera
/// goes off (or the settings close without recording).
final class CameraPreview {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 180), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
    let session = AVCaptureSession()
    private var layer: AVCaptureVideoPreviewLayer?

    init() {
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = true
        let v = NSView(frame: window.contentRect(forFrameRect: window.frame))
        v.wantsLayer = true
        v.layer?.cornerRadius = 18; v.layer?.masksToBounds = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        v.layer?.borderWidth = 1; v.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        let pl = AVCaptureVideoPreviewLayer(session: session)
        pl.videoGravity = .resizeAspectFill
        pl.frame = v.bounds
        v.layer?.addSublayer(pl)
        layer = pl
        window.contentView = v
    }

    func show(cameraID: String?, beside anchor: NSRect) {
        let begin = {
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            if let id = cameraID, let d = AVCaptureDevice(uniqueID: id), let i = try? AVCaptureDeviceInput(device: d),
               self.session.canAddInput(i) { self.session.addInput(i) }
            self.session.commitConfiguration()
            // The connection only exists once a camera is attached, so automatic mirroring has to be switched off here,
            // before setting it (setting it while automatic is on throws, which used to take Sill down).
            if let c = self.layer?.connection, c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = true
            }
            DispatchQueue.global().async { self.session.startRunning() }
            // To the right of the panel's card, level with its bottom.
            self.window.setFrameOrigin(NSPoint(x: anchor.maxX + 12, y: anchor.minY))
            self.window.orderFrontRegardless()
            if let l = self.window.contentView?.layer {
                let a = CASpringAnimation(keyPath: "transform.scale"); a.fromValue = 0.85; a.toValue = 1
                a.stiffness = 260; a.damping = 20; a.duration = a.settlingDuration; l.add(a, forKey: "pop")
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: begin()
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { ok in if ok { DispatchQueue.main.async(execute: begin) } }
        default: break
        }
    }

    func hide() {
        window.orderOut(nil)
        DispatchQueue.global().async { self.session.stopRunning() }
    }
}

/// The pre-flight card: sources, devices, a live input meter, where files go, and Start Recording.
/// The computer-audio meter as a waveform: a row of thin vertical bars, the newest sound in the middle-right, older
/// sound drifting left, the whole shape tapering to dots at both ends. At rest it's a quiet dotted line; with sound it
/// swells into tall white bars.
final class WaveMeter: NSView {
    private var history: [CGFloat]
    let count = 72
    override init(frame: NSRect) { history = Array(repeating: 0, count: 72); super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    func push(_ level: CGFloat) {
        history.removeFirst()
        // A little texture so speech reads as speech, not a block.
        history.append(level > 0.02 ? min(1, level * CGFloat.random(in: 0.7...1.15)) : 0)
        needsDisplay = true
    }
    func reset() { history = Array(repeating: 0, count: count); needsDisplay = true }
    override func draw(_ r: NSRect) {
        let w = bounds.width, h = bounds.height
        let step = w / CGFloat(count)
        let bw = max(1.5, step * 0.45)
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count - 1)
            let taper = pow(sin(.pi * t), 0.7)                        // fades to dots at both ends
            let v = history[i] * taper
            let bh = max(2, (h - 2) * v)
            let a = 0.35 + 0.65 * min(1, v * 1.6)                    // quiet bars gray, loud bars white
            NSColor.white.withAlphaComponent(a).setFill()
            let x = CGFloat(i) * step + (step - bw) / 2
            NSBezierPath(roundedRect: NSRect(x: x, y: (h - bh) / 2, width: bw, height: bh), xRadius: bw / 2, yRadius: bw / 2).fill()
        }
    }
}

final class PreflightView: NSView {
    let title = NSTextField(labelWithString: "Output settings")
    let micChip = SourceChip("mic.fill", "Mic"), screenChip = SourceChip("display", "Screen"), camChip = SourceChip("video.fill", "Camera")
    let micPick = NSPopUpButton(), screenPick = NSPopUpButton(), camPick = NSPopUpButton()
    let meter = WaveMeter(frame: .zero)
    let path = NSTextField(labelWithString: "")
    let start = NSButton()
    let close = NSButton()
    var choice = CaptureChoice()
    var onStart: ((CaptureChoice) -> Void)?
    var staysOpen = false { didSet { close.isHidden = staysOpen } }   // inside the audio menu: its ✕ closes it, not hovering away
    var onClose: (() -> Void)?
    var onCamera: ((Bool) -> Void)?             // Camera on/off: show or hide the mirror
    private var leaveWork: DispatchWorkItem?
    private var menuOpen = false
    let probe = DeviceCapture()
    var systemMeter: AnyObject?                 // SystemAudioMeter: the computer-audio meter while the card is open
    let meterLabel = NSTextField(labelWithString: "Computer audio")
    private var meterTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.19, alpha: 0.98).cgColor
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        title.font = roundedFont(12, .bold); title.textColor = .white
        micChip.on = choice.mic; screenChip.on = choice.screen; camChip.on = choice.camera
        micChip.onToggle = { [weak self] v in self?.choice.mic = v; self?.refreshPath() }
        screenChip.onToggle = { [weak self] v in self?.choice.screen = v; self?.refreshPath() }
        camChip.onToggle = { [weak self] v in self?.choice.camera = v; self?.refreshPath(); self?.onCamera?(v) }
        for p in [micPick, screenPick, camPick] {
            p.isBordered = false; p.font = roundedFont(11, .medium); p.controlSize = .small
            p.target = self; p.action = #selector(picked(_:))
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuOpen = true }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuOpen = false }

        path.font = roundedFont(9.5, .medium); path.textColor = .white
        path.lineBreakMode = .byTruncatingMiddle
        start.isBordered = false; start.wantsLayer = true
        start.layer?.backgroundColor = NSColor.systemRed.cgColor
        start.attributedTitle = NSAttributedString(string: "Start Recording",
            attributes: [.font: roundedFont(12, .bold), .foregroundColor: NSColor.white])
        start.target = self; start.action = #selector(startTapped)
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        close.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        close.target = self; close.action = #selector(closeTapped)
        meterLabel.font = roundedFont(10, .semibold); meterLabel.textColor = .white
        [title, close, micChip, screenChip, camChip, micPick, screenPick, camPick, meter, meterLabel, path, start].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    // Moving the pointer off the card closes it (after a short grace, and never while a picker menu is open).
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with e: NSEvent) { leaveWork?.cancel() }
    override func mouseExited(with e: NSEvent) {
        leaveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isHidden, !self.menuOpen, !self.staysOpen, let win = self.window else { return }
            let r = win.convertToScreen(self.convert(self.bounds, to: nil))
            if !NSMouseInRect(NSEvent.mouseLocation, r, false) { self.closeTapped() }
        }
        leaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
    }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        let w = s.width, h = s.height, pad: CGFloat = 14
        title.frame = NSRect(x: pad, y: h - 26, width: 160, height: 16)
        close.frame = NSRect(x: w - 28, y: h - 27, width: 16, height: 16)
        let cw = (w - 2 * pad - 16) / 3
        for (i, c) in [micChip, screenChip, camChip].enumerated() {
            c.frame = NSRect(x: pad + CGFloat(i) * (cw + 8), y: h - 58, width: cw, height: 26)
        }
        for (i, p) in [micPick, screenPick, camPick].enumerated() {
            p.frame = NSRect(x: pad + CGFloat(i) * (cw + 8) - 4, y: h - 84, width: cw + 8, height: 20)
        }
        meterLabel.frame = NSRect(x: pad, y: h - 104, width: 96, height: 13)
        meter.frame = NSRect(x: pad + 100, y: h - 114, width: w - 2 * pad - 100, height: 30)
        path.frame = NSRect(x: pad, y: 46, width: w - 2 * pad, height: 13)
        start.frame = NSRect(x: pad, y: 12, width: w - 2 * pad, height: 26)
        start.layer?.cornerRadius = 13
    }

    /// Opening: fill the device lists, start the live meter.
    func open() {
        micPick.removeAllItems(); camPick.removeAllItems(); screenPick.removeAllItems()
        let mics = audioDevices(), cams = videoDevices()
        for d in mics { micPick.addItem(withTitle: d.localizedName); micPick.lastItem?.representedObject = d.uniqueID }
        if let id = choice.micID, let i = mics.firstIndex(where: { $0.uniqueID == id }) { micPick.selectItem(at: i) }
        for d in cams { camPick.addItem(withTitle: d.localizedName); camPick.lastItem?.representedObject = d.uniqueID }
        if let id = choice.cameraID, let i = cams.firstIndex(where: { $0.uniqueID == id }) { camPick.selectItem(at: i) }
        for (i, s) in NSScreen.screens.enumerated() { screenPick.addItem(withTitle: s.localizedName); screenPick.lastItem?.tag = i }
        screenPick.selectItem(at: min(choice.displayIndex, NSScreen.screens.count - 1))
        if cams.isEmpty { camPick.addItem(withTitle: "No camera"); camPick.isEnabled = false }
        refreshPath()
        startMeter()
    }

    func shutDown() {
        meterTimer?.invalidate(); meterTimer = nil
        if #available(macOS 15.0, *) { (systemMeter as? SystemAudioMeter)?.stop() }
        systemMeter = nil
        meter.reset()
    }

    /// The meter shows the computer's audio (what the other person sounds like to the Mac), so a wrong sound setting
    /// shows up as a flat line before you record, not as a silent file afterwards.
    func startMeter() {
        guard #available(macOS 15.0, *) else { meterLabel.stringValue = "Needs macOS 15"; return }
        let m = (systemMeter as? SystemAudioMeter) ?? SystemAudioMeter()
        systemMeter = m
        m.start()
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.meter.push(m.level)
        }
    }

    func refreshPath() {
        var where_: [String] = []
        if choice.mic { where_.append("~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/") }
        if choice.screen || choice.camera { where_.append("~/Movies/Sill Recordings/") }
        path.stringValue = where_.isEmpty ? "Choose at least one source" : where_.joined(separator: "  ·  ")
        start.isEnabled = !where_.isEmpty
        start.alphaValue = where_.isEmpty ? 0.4 : 1
    }

    @objc func picked(_ p: NSPopUpButton) {
        if p === micPick { choice.micID = p.selectedItem?.representedObject as? String }
        if p === camPick { choice.cameraID = p.selectedItem?.representedObject as? String; if choice.camera { onCamera?(true) } }
        if p === screenPick { choice.displayIndex = p.selectedItem?.tag ?? 0 }
    }
    @objc func startTapped() { shutDown(); onStart?(choice) }
    @objc func closeTapped() { shutDown(); onClose?() }
}

/// The capture capsule at the bottom of the panel.
final class RecorderView: NSView {
    let ring = NSView()
    let core = NSView()
    let pauseBars = CAShapeLayer()
    let timer = NSTextField(labelWithString: "")
    let badge = NSView()
    let meterBars: [CALayer] = (0..<7).map { _ in CALayer() }
    let streams = NSTextField(labelWithString: "")       // which sources are live, as symbols
    let cancelButton = NSButton()                         // discard this recording (files go to the Trash)

    private(set) var state: CaptureState = .ready
    var onOpenSettings: (() -> Void)?
    var choice = CaptureChoice()
    let devices = DeviceCapture()
    var screenCapture: AnyObject?
    var mixed: AnyObject?                     // MixedAudioRecorder (mic + computer audio)
    var files: [URL] = []
    var lastFile: URL? { files.last }
    var sessionStart = Date()
    var pausedTotal: TimeInterval = 0
    var pausedAt: Date?
    private var singleClick: DispatchWorkItem?
    private var meterTimer: Timer?
    var onLevel: ((CGFloat) -> Void)?          // the live level, for the left edge bar

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.wantsLayer = true
        ring.layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        ring.layer?.borderWidth = 1.5
        core.wantsLayer = true
        pauseBars.fillColor = NSColor.white.cgColor
        core.layer?.addSublayer(pauseBars)
        timer.font = roundedFont(14, .semibold); timer.textColor = .white
        badge.wantsLayer = true
        for b in meterBars { b.backgroundColor = NSColor.systemRed.cgColor; b.cornerRadius = 1; badge.layer?.addSublayer(b) }
        streams.font = .systemFont(ofSize: 12); streams.textColor = NSColor.white.withAlphaComponent(0.7)
        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel recording")
        cancelButton.isBordered = false
        cancelButton.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        cancelButton.toolTip = "Cancel recording (moves its files to the Trash)"
        cancelButton.target = self; cancelButton.action = #selector(cancelRecording)
        [ring, core, timer, badge, streams, cancelButton].forEach(addSubview)
        render(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); layoutParts() }

    func layoutParts() {
        let h = bounds.height
        ring.frame = NSRect(x: 0, y: (h - 30) / 2, width: 30, height: 30)
        ring.layer?.cornerRadius = 15
        timer.frame = NSRect(x: 40, y: h / 2 - 9, width: 60, height: 19)
        badge.frame = NSRect(x: 102, y: h / 2 - 9, width: 40, height: 18)
        streams.frame = NSRect(x: 148, y: h / 2 - 8, width: bounds.width - 148 - 24, height: 16)
        cancelButton.frame = NSRect(x: bounds.width - 20, y: h / 2 - 9, width: 18, height: 18)
        render(animated: false)
    }

    func render(animated: Bool) {
        let rec = state == .recording, paused = state == .paused
        cancelButton.isHidden = !(rec || paused)
        let size: CGFloat = rec ? 12 : (paused ? 14 : 18)
        let target = NSRect(x: ring.frame.midX - size / 2, y: ring.frame.midY - size / 2, width: size, height: size)
        let radius = rec ? 3 : (paused ? 4 : size / 2)
        if animated, let l = core.layer {
            let spring = CASpringAnimation(keyPath: "cornerRadius")
            spring.fromValue = l.cornerRadius; spring.toValue = radius
            spring.stiffness = 300; spring.damping = 20; spring.duration = spring.settlingDuration
            l.add(spring, forKey: "radius")
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.3, 0.5, 1)
                core.animator().frame = target
            }
        } else { core.frame = target }
        core.layer?.cornerRadius = radius
        core.layer?.backgroundColor = (paused ? NSColor.systemOrange : NSColor.systemRed).cgColor
        let bars = CGMutablePath()
        bars.addRect(CGRect(x: 3.5, y: 3, width: 2.5, height: 8)); bars.addRect(CGRect(x: 8, y: 3, width: 2.5, height: 8))
        pauseBars.path = bars
        pauseBars.opacity = paused ? 1 : 0
        let live = rec || paused
        if !live { timer.stringValue = "Ready" } else { tick() }
        badge.isHidden = !(live && choice.mic)
        streams.attributedStringValue = live ? sourceSymbols() : NSAttributedString()
        // Words like "Canceled" or "Camera unavailable" need more room than a running time.
        timer.frame.size.width = live ? 60 : 160
    }

    /// The live sources as SF Symbols (drawn as images: the symbols' private-use characters don't render in a plain
    /// label and showed up as "?" boxes).
    private func sourceSymbols() -> NSAttributedString {
        var names: [String] = []
        if choice.mic { names.append("mic.fill") }; if choice.screen { names.append("display") }; if choice.camera { names.append("video.fill") }
        let out = NSMutableAttributedString()
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(0.7)]))
        for (i, n) in names.enumerated() {
            guard let img = NSImage(systemSymbolName: n, accessibilityDescription: n)?.withSymbolConfiguration(cfg) else { continue }
            let a = NSTextAttachment(); a.image = img
            a.bounds = CGRect(x: 0, y: -2, width: img.size.width, height: img.size.height)
            if i > 0 { out.append(NSAttributedString(string: "   ")) }
            out.append(NSAttributedString(attachment: a))
        }
        return out
    }

    private var lastComputerSound = Date()
    /// While recording: if the computer has been silent for a while, say so (the call might not be reaching the file).
    func checkComputerAudio() {
        guard state == .recording, #available(macOS 15.0, *), let m = mixed as? MixedAudioRecorder else {
            streams.textColor = NSColor.white.withAlphaComponent(0.7); return
        }
        if m.systemLevel > 0.08 { lastComputerSound = Date() }
        let silent = Date().timeIntervalSince(lastComputerSound) > 10
        streams.textColor = silent ? .systemOrange : NSColor.white.withAlphaComponent(0.7)
        if silent { streams.stringValue = "No computer audio" } else { streams.attributedStringValue = sourceSymbols() }
    }

    func tick() {
        checkComputerAudio()
        guard state == .recording || state == .paused else { return }
        let paused = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        let s = Int(Date().timeIntervalSince(sessionStart) - pausedTotal - paused)
        timer.stringValue = String(format: "%02d:%02d", s / 60, s % 60)
    }

    func runMeter(_ on: Bool) {
        meterTimer?.invalidate(); meterTimer = nil
        if !on { onLevel?(0) }
        guard on, choice.mic else { return }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            var level = self.devices.level
            if #available(macOS 15.0, *), let m = self.mixed as? MixedAudioRecorder { level = m.systemLevel }
            self.onLevel?(CGFloat(level))
            CATransaction.begin(); CATransaction.setAnimationDuration(0.08)
            for (i, b) in self.meterBars.enumerated() {
                let shape = 1 - abs(CGFloat(i) - 3) / 4
                let hgt = max(3, 16 * level * (0.45 + 0.55 * shape) * CGFloat.random(in: 0.75...1))
                b.frame = NSRect(x: CGFloat(i) * 5, y: (18 - hgt) / 2, width: 3, height: hgt)
            }
            CATransaction.commit()
        }
    }

    // MARK: Gestures

    // Hovering the red button while Ready opens the output settings, as does clicking it.
    private var buttonHover: NSTrackingArea?
    override func updateTrackingAreas() {
        if let t = buttonHover { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: ring.frame.insetBy(dx: -6, dy: -6), options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t); buttonHover = t
        super.updateTrackingAreas()
    }
    override func mouseEntered(with e: NSEvent) { if state == .ready { onOpenSettings?() } }

    override func mouseDown(with e: NSEvent) {
        if state == .ready || state == .settings { onOpenSettings?(); return }      // Ready → pre-flight
        if e.clickCount >= 2 { singleClick?.cancel(); stop(); return }
        let w = DispatchWorkItem { [weak self] in self?.togglePause() }
        singleClick = w
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: w)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let reveal = m.addItem(withTitle: "Reveal in Finder", action: #selector(revealFile), keyEquivalent: "")
        let copy = m.addItem(withTitle: "Copy Path", action: #selector(copyPath), keyEquivalent: "")
        [reveal, copy].forEach { $0.target = self; $0.isEnabled = lastFile != nil && state == .ready }
        if state == .recording || state == .paused {
            m.addItem(.separator())
            m.addItem(withTitle: "Cancel Recording", action: #selector(cancelRecording), keyEquivalent: "").target = self
        }
        return m
    }
    @objc func revealFile() { NSWorkspace.shared.activateFileViewerSelecting(Array(files.suffix(3))) }
    @objc func copyPath() {
        guard let f = lastFile else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(f.path, forType: .string)
    }

    // MARK: Capture

    func newFile(_ ext: String, in dir: String, _ tag: String) -> URL {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return URL(fileURLWithPath: dir).appendingPathComponent("Sill \(f.string(from: Date()))\(tag).\(ext)")
    }

    /// Starts every selected stream together.
    func begin(_ c: CaptureChoice) {
        choice = c
        files = []
        sessionStart = Date(); pausedTotal = 0; pausedAt = nil
        // Audio: the microphone and whatever the Mac is playing, together in one .m4a. (Fallback on older macOS:
        // the microphone alone.)
        var micByCaptureSession = false
        if c.mic {
            if #available(macOS 15.0, *) {
                let rec = MixedAudioRecorder()
                let url = newFile("m4a", in: recordingsFolder, "")
                rec.start(to: url, micID: c.micID) { ok in
                    DispatchQueue.main.async {
                        if ok { self.mixed = rec; self.files.append(url) }
                        else { NSLog("sill: mixed audio didn't start (check Screen Recording / Microphone permission)") }
                    }
                }
            } else { micByCaptureSession = true }
        }
        if micByCaptureSession || c.camera {
            guard devices.configure(micID: c.micID, cameraID: c.cameraID, wantMicFile: micByCaptureSession, wantCamera: c.camera) else {
                timer.stringValue = "Camera unavailable"; return
            }
            devices.session.startRunning()
            let audioURL = micByCaptureSession ? newFile("m4a", in: recordingsFolder, "") : nil
            let movieURL = c.camera ? newFile("mov", in: screenRecordingsFolder, " camera") : nil
            devices.startFiles(audio: audioURL, movie: movieURL)
            files += [audioURL, movieURL].compactMap { $0 }
        }
        if c.screen {
            if #available(macOS 15.0, *) {
                let cap = ScreenCapture()
                let url = newFile("mov", in: screenRecordingsFolder, " screen")
                let screen = NSScreen.screens.indices.contains(c.displayIndex) ? NSScreen.screens[c.displayIndex] : NSScreen.main
                cap.start(to: url, screen: screen, micID: c.micID) { ok in
                    DispatchQueue.main.async {
                        if ok { self.screenCapture = cap; self.files.append(url) }
                        else { NSLog("sill: screen stream didn't start (check Screen Recording permission)") }
                    }
                }
            }
        }
        state = .recording
        lastComputerSound = Date()
        runMeter(true)
        render(animated: true)
    }

    func togglePause() {
        if state == .recording {
            pausedAt = Date(); devices.pause(); runMeter(false); state = .paused
            if #available(macOS 15.0, *) { (mixed as? MixedAudioRecorder)?.pause() }
        } else if state == .paused {
            if let p = pausedAt {
                let gap = Date().timeIntervalSince(p)
                pausedTotal += gap
                if #available(macOS 15.0, *) { (mixed as? MixedAudioRecorder)?.addGap(seconds: gap) }
            }
            if #available(macOS 15.0, *) { (mixed as? MixedAudioRecorder)?.resume() }
            pausedAt = nil; devices.resume(); runMeter(true); state = .recording
        }
        render(animated: true)
    }

    /// Cancel: stops everything like Stop, then moves this recording's files to the Trash (recoverable from there)
    /// once each one has finished writing.
    @objc func cancelRecording() {
        guard state == .recording || state == .paused else { return }
        let discard = files
        stop { [discard] in
            for f in discard where FileManager.default.fileExists(atPath: f.path) {
                try? FileManager.default.trashItem(at: f, resultingItemURL: nil)
            }
        }
        files = []
        timer.stringValue = "Canceled"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.state == .ready { self?.timer.stringValue = "Ready" }
        }
    }

    /// Stops every stream and saves the files. (Screen capture can't pause, so it records through pauses.)
    /// `finished` runs once every file has been written.
    func stop(finished: (() -> Void)? = nil) {
        guard state == .recording || state == .paused else { return }
        let group = DispatchGroup()
        devices.stopFiles()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { self.devices.session.stopRunning() }
        if #available(macOS 15.0, *), let cap = screenCapture as? ScreenCapture { group.enter(); cap.stop { _ in group.leave() } }
        if #available(macOS 15.0, *), let rec = mixed as? MixedAudioRecorder { group.enter(); rec.stop { _ in group.leave() } }
        // The camera/audio file writers finish on their own shortly after stopFiles.
        group.enter(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { group.leave() }
        if let f = finished { group.notify(queue: .main, execute: f) }
        screenCapture = nil; mixed = nil
        runMeter(false)
        state = .ready; pausedAt = nil
        render(animated: true)
    }
}



/// Recense's menu-bar mark (copied from Recense's `menuBarIcon()`): a rounded frame holding two lines of subtitle.
func recenseIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let frame = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3.5, width: 15, height: 11), xRadius: 3.25, yRadius: 3.25)
        frame.lineWidth = 1.3
        NSColor.black.setStroke(); frame.stroke()
        for (y, w, a) in [(8.6, 8.0, 1.0), (6.2, 4.5, 0.45)] as [(CGFloat, CGFloat, CGFloat)] {
            let l = NSBezierPath()
            l.move(to: NSPoint(x: 9 - w / 2, y: y)); l.line(to: NSPoint(x: 9 + w / 2, y: y))
            l.lineWidth = 1.3; l.lineCapStyle = .round
            NSColor.black.withAlphaComponent(a).setStroke(); l.stroke()
        }
        return true
    }
    img.isTemplate = true
    img.accessibilityDescription = "Recense"
    return img
}

// MARK: - Bitwarden
//
// Vault search inside Sill, through Bitwarden's official command-line tool (`bw`, installed with Homebrew).
//
// Unlocking: the first time, you type your master password into Sill once. Sill keeps it in your login keychain
// and from then on unlocks with Touch ID (or your Mac password if Touch ID isn't available). Honest limits:
// Bitwarden's CLI has no Touch ID or PIN of its own, so this Touch ID check is Sill's, guarding a keychain item that
// only apps you allow can read; it's the same trade-off password tools like Alfred workflows make.
// The unlocked session lives only in Sill's memory and is dropped as soon as the vault closes, so every opening
// asks for Touch ID (and after 10 idle minutes, or when Sill quits).
// Copied passwords are marked concealed (clipboard managers skip them) and cleared after 30 seconds.
//
// One-time setup in Terminal: `bw login` (Sill never handles your email or two-factor code).

let bwPath = "/opt/homebrew/bin/bw"
let bwKeychainService = "local.sill.bitwarden"
let bwIdleLock: TimeInterval = 10 * 60
let clipboardClearAfter: TimeInterval = 30

/// One vault entry of any kind (login, secure note, card, identity), flattened into labelled fields.
struct VaultField { let label: String; let value: String; let hidden: Bool }
struct VaultItem {
    let name: String
    let kind: String            // Login, Note, Card, Identity
    let subtitle: String        // username, card brand, …
    let fields: [VaultField]
    let notes: String
    let favorite: Bool
    let host: String            // the first website's host, for the icon and the subtitle
    let updatedText: String     // "Updated 2d ago"
    let shortUpdated: String    // "2d"
    var password: String? { fields.first { $0.label == "Password" }?.value }

    init(_ d: [String: Any]) {
        name = d["name"] as? String ?? ""
        notes = d["notes"] as? String ?? ""
        favorite = d["favorite"] as? Bool ?? false
        let firstURI = ((d["login"] as? [String: Any])?["uris"] as? [[String: Any]])?.first?["uri"] as? String ?? ""
        let u = URL(string: firstURI.contains("://") ? firstURI : "https://" + firstURI)
        host = firstURI.isEmpty ? "" : (u?.host ?? "")
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let r = d["revisionDate"] as? String, let date = iso.date(from: r) {
            let rel = RelativeDateTimeFormatter(); rel.unitsStyle = .abbreviated
            updatedText = "Updated " + rel.localizedString(for: date, relativeTo: Date())
            shortUpdated = compactInterval(max(60, Date().timeIntervalSince(date)))
        } else { updatedText = ""; shortUpdated = "" }
        var f: [VaultField] = []
        func add(_ label: String, _ v: Any?, hidden: Bool = false) {
            if let s = v as? String, !s.isEmpty { f.append(VaultField(label: label, value: s, hidden: hidden)) }
        }
        switch d["type"] as? Int ?? 0 {
        case 1:
            kind = "Login"
            let l = d["login"] as? [String: Any] ?? [:]
            add("Username", l["username"]); add("Password", l["password"], hidden: true)
            add("Verification code (TOTP seed)", l["totp"], hidden: true)
            for u in (l["uris"] as? [[String: Any]] ?? []) { add("Website", u["uri"]) }
            subtitle = l["username"] as? String ?? ""
        case 3:
            kind = "Card"
            let c = d["card"] as? [String: Any] ?? [:]
            add("Cardholder", c["cardholderName"]); add("Brand", c["brand"])
            add("Number", c["number"], hidden: true)
            let m = c["expMonth"] as? String ?? "", y = c["expYear"] as? String ?? ""
            if !m.isEmpty || !y.isEmpty { add("Expires", "\(m)/\(y)") }
            add("Security code", c["code"], hidden: true)
            let n = c["number"] as? String ?? ""
            subtitle = [(c["brand"] as? String) ?? "", n.count >= 4 ? "•••• " + n.suffix(4) : ""].filter { !$0.isEmpty }.joined(separator: " ")
        case 4:
            kind = "Identity"
            let i = d["identity"] as? [String: Any] ?? [:]
            let full = [i["firstName"], i["middleName"], i["lastName"]].compactMap { $0 as? String }.joined(separator: " ")
            add("Name", full); add("Email", i["email"]); add("Phone", i["phone"]); add("Company", i["company"])
            add("Address", [i["address1"], i["address2"], i["city"], i["state"], i["postalCode"], i["country"]]
                .compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: ", "))
            add("Username", i["username"])
            add("SSN", i["ssn"], hidden: true); add("Passport", i["passportNumber"], hidden: true)
            add("License", i["licenseNumber"], hidden: true)
            subtitle = full
        default:
            kind = "Note"
            subtitle = String((d["notes"] as? String ?? "").prefix(60)).replacingOccurrences(of: "\n", with: " ")
        }
        for c in (d["fields"] as? [[String: Any]] ?? []) {   // custom fields; type 1 = hidden
            add(c["name"] as? String ?? "Field", c["value"], hidden: (c["type"] as? Int) == 1)
        }
        fields = f
    }
}

final class Bitwarden {
    static let shared = Bitwarden()
    private(set) var session: String?
    private var lastUse = Date()

    func run(_ args: [String], env extra: [String: String] = [:]) -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bwPath)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin"
        if let s = session { env["BW_SESSION"] = s }
        extra.forEach { env[$0] = $1 }
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return (-1, Data()) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    var installed: Bool { FileManager.default.isExecutableFile(atPath: bwPath) }

    /// "unauthenticated", "locked" or "unlocked".
    func status() -> String {
        let (_, d) = run(["status"])
        return ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["status"] as? String ?? "unknown"
    }

    func unlock(with password: String) -> Bool {
        let (code, d) = run(["unlock", "--raw", "--passwordenv", "SILL_BW_PW"], env: ["SILL_BW_PW": password])
        let key = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard code == 0, !key.isEmpty else { return false }
        session = key
        lastUse = Date()
        DispatchQueue.global(qos: .utility).async { _ = self.run(["sync"]) }
        return true
    }

    /// Forget the session now, so the next open asks for Touch ID again.
    func lockNow() {
        guard session != nil else { return }
        session = nil
        DispatchQueue.global(qos: .utility).async { _ = self.run(["lock"]) }
    }

    func lockIfIdle() {
        guard session != nil, Date().timeIntervalSince(lastUse) > bwIdleLock else { return }
        session = nil
        DispatchQueue.global(qos: .utility).async { _ = self.run(["lock"]) }
    }

    func favorites() -> [VaultItem] {
        lastUse = Date()
        let (_, d) = run(["list", "items"])
        guard let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
        return list.map(VaultItem.init).filter { $0.favorite }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func search(_ q: String) -> [VaultItem] {
        lastUse = Date()
        let (_, d) = run(["list", "items", "--search", q])
        guard let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
        return list.map(VaultItem.init)
    }

    // Master password in the login keychain.
    func storedPassword() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: bwKeychainService,
                                kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func store(_ password: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: bwKeychainService]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecAttrAccount as String] = "master password"
        add[kSecAttrLabel as String] = "Sill: Bitwarden unlock"
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    func forget() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: bwKeychainService] as CFDictionary)
    }
}

/// Puts a secret on the clipboard, hidden from clipboard managers, and clears it after a while if it's still there.
func copySecret(_ s: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(s, forType: .string)
    pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    let change = pb.changeCount
    DispatchQueue.main.asyncAfter(deadline: .now() + clipboardClearAfter) {
        if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
    }
}

/// A small text button (copy, reveal, back).
final class TextButton: NSButton {
    var act: (() -> Void)?
    convenience init(_ title: String, _ a: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title; isBordered = false; act = a
        font = .systemFont(ofSize: 10, weight: .semibold); contentTintColor = .systemBlue
        target = self; action = #selector(fire)
        attributedTitle = NSAttributedString(string: title, attributes: [.font: font!, .foregroundColor: NSColor.systemBlue])
    }
    @objc func fire() { act?() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}

/// One entry, every field visible: hidden values masked until you reveal them, each one copyable, notes in full.
final class VaultDetail: NSView {
    let scroll = NSScrollView()
    let body = FlippedView()
    var onBack: (() -> Void)?
    var onCopy: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = body
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: VaultItem) {
        body.subviews.forEach { $0.removeFromSuperview() }
        let w = bounds.width
        scroll.frame = bounds
        var y: CGFloat = 0
        let back = TextButton("‹ Back") { [weak self] in self?.onBack?() }
        back.frame = NSRect(x: 0, y: y, width: 70, height: 16); body.addSubview(back)
        let title = NSTextField(labelWithString: item.name)
        title.font = .systemFont(ofSize: 14, weight: .bold); title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 0, y: y + 18, width: w, height: 18); body.addSubview(title)
        y += 42
        for f in item.fields {
            let label = NSTextField(labelWithString: f.label)
            label.font = .systemFont(ofSize: 10, weight: .semibold); label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 0, y: y, width: w - 90, height: 13)
            let value = NSTextField(labelWithString: f.hidden ? String(repeating: "•", count: 10) : f.value)
            value.font = .monospacedSystemFont(ofSize: 12, weight: .regular); value.textColor = .white
            value.lineBreakMode = .byTruncatingTail
            value.isSelectable = !f.hidden
            value.frame = NSRect(x: 0, y: y + 14, width: w - 90, height: 16)
            let copy = TextButton("Copy") { [weak self] in
                copySecret(f.value); self?.onCopy?("\(f.label) copied" + (f.hidden ? " · clears in 30 s" : ""))
            }
            copy.frame = NSRect(x: w - 40, y: y + 13, width: 40, height: 16)
            [label, value, copy].forEach(body.addSubview)
            if f.hidden {
                var shown = false
                let eye = TextButton("Show") {}
                eye.act = { [weak eye, weak value] in
                    shown.toggle()
                    value?.stringValue = shown ? f.value : String(repeating: "•", count: 10)
                    value?.isSelectable = shown
                    eye?.attributedTitle = NSAttributedString(string: shown ? "Hide" : "Show",
                        attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.systemBlue])
                }
                eye.frame = NSRect(x: w - 84, y: y + 13, width: 40, height: 16)
                body.addSubview(eye)
            }
            y += 38
        }
        if !item.notes.isEmpty {
            let label = NSTextField(labelWithString: "Notes")
            label.font = .systemFont(ofSize: 10, weight: .semibold); label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 0, y: y, width: w - 50, height: 13)
            let copy = TextButton("Copy") { [weak self] in copySecret(item.notes); self?.onCopy?("Notes copied") }
            copy.frame = NSRect(x: w - 40, y: y - 1, width: 40, height: 16)
            let notes = NSTextField(wrappingLabelWithString: item.notes)
            notes.font = .systemFont(ofSize: 12); notes.textColor = .white
            notes.isSelectable = true
            let h = notes.sizeThatFits(NSSize(width: w, height: 10_000)).height
            notes.frame = NSRect(x: 0, y: y + 15, width: w, height: h)
            [label, copy, notes].forEach(body.addSubview)
            y += 20 + h
        }
        body.frame = NSRect(x: 0, y: 0, width: w, height: max(bounds.height, y + 8))
        body.scroll(.zero)
    }
}

/// Site icons for vault rows, from Bitwarden's own icon service (the same one Bitwarden's apps use by default).
/// Only fetched while the vault is open; set vaultIcons = false to use letter tiles instead.
let vaultIcons = true
var iconCache: [String: NSImage] = [:]

func letterTile(_ name: String) -> NSImage {
    let img = NSImage(size: NSSize(width: 28, height: 28))
    img.lockFocus()
    NSColor(srgbRed: 0.12, green: 0.16, blue: 0.27, alpha: 1).setFill()      // navy, readable on the light bands
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 28, height: 28), xRadius: 7, yRadius: 7).fill()
    let s = String(name.prefix(1)).uppercased() as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
    let sz = s.size(withAttributes: attrs)
    s.draw(at: NSPoint(x: (28 - sz.width) / 2, y: (28 - sz.height) / 2), withAttributes: attrs)
    img.unlockFocus()
    return img
}


/// The outline of a vault row: rounded on the left, and on the right a clean angled cut, like a banner tag.
func bannerPath(_ w: CGFloat, _ h: CGFloat, cut: CGFloat, radius r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r, y: 0))
    p.addLine(to: CGPoint(x: w - cut, y: 0))           // bottom edge stops short…
    p.addLine(to: CGPoint(x: w, y: h))                 // …and the right side slants up to the top corner
    p.addLine(to: CGPoint(x: r, y: h))
    p.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: 0, y: h - r), radius: r)
    p.addLine(to: CGPoint(x: 0, y: r))
    p.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: r, y: 0), radius: r)
    p.closeSubpath()
    return p
}

/// A square with its corners cut off: the octagon the thumbnails are clipped to.
func chamferPath(_ s: CGFloat, cut c: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addLines(between: [CGPoint(x: c, y: 0), CGPoint(x: s - c, y: 0), CGPoint(x: s, y: c), CGPoint(x: s, y: s - c),
                         CGPoint(x: s - c, y: s), CGPoint(x: c, y: s), CGPoint(x: 0, y: s - c), CGPoint(x: 0, y: c)])
    p.closeSubpath()
    return p
}

/// One row on the vault arc, styled as a banner of glass: a frosted, see-through band cut at an angle on the right
/// (a blur of what's behind it, a soft highlight across the top and a bright rim, after macOS's "liquid glass";
/// the real Liquid Glass material only exists from macOS 26), an octagonal thumbnail, the title over its subtitle,
/// and how recently it changed just before the angled edge.
final class WheelRow: NSView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let sub = NSTextField(labelWithString: "")
    let trailing = NSTextField(labelWithString: "")
    let glass = NSVisualEffectView()
    let sheen = CAGradientLayer()
    let sheenMask = CAShapeLayer()
    let shape = CAShapeLayer()               // the rim
    let iconMask = CAShapeLayer()
    var item: VaultItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.material = .hudWindow
        glass.blendingMode = .withinWindow
        glass.state = .active
        glass.wantsLayer = true
        addSubview(glass)
        sheen.colors = [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0.04).cgColor,
                        NSColor.white.withAlphaComponent(0.0).cgColor]
        sheen.locations = [0, 0.55, 1]
        sheen.startPoint = CGPoint(x: 0.5, y: 1); sheen.endPoint = CGPoint(x: 0.5, y: 0)
        sheen.mask = sheenMask
        layer?.addSublayer(sheen)
        shape.fillColor = NSColor.clear.cgColor
        shape.lineWidth = 1
        layer?.addSublayer(shape)
        icon.wantsLayer = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.layer?.mask = iconMask
        // On glass over the dark panel the text is light: white title, soft white subtitle.
        name.font = roundedFont(12, .bold); name.textColor = .white; name.lineBreakMode = .byTruncatingTail
        sub.font = roundedFont(10, .medium); sub.textColor = NSColor.white.withAlphaComponent(0.7)
        sub.lineBreakMode = .byTruncatingTail
        trailing.font = roundedFont(10, .semibold); trailing.textColor = NSColor.white.withAlphaComponent(0.7)
        trailing.alignment = .right
        [icon, name, sub, trailing].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }          // the wheel handles clicks

    func configure(_ it: VaultItem, focus f: CGFloat) {
        item = it
        let w = bounds.width, h = bounds.height
        let cut = h * 0.42
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let path = bannerPath(w, h, cut: cut, radius: 7)
        glass.frame = bounds
        glass.maskImage = NSImage(size: bounds.size, flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.setFillColor(NSColor.black.cgColor); cg.addPath(path); cg.fillPath(); return true
        }
        sheen.frame = bounds
        sheenMask.frame = bounds; sheenMask.path = path
        sheen.opacity = Float(0.7 + 0.3 * f)
        shape.frame = bounds
        shape.path = path
        shape.strokeColor = NSColor.white.withAlphaComponent(0.22 + 0.35 * f).cgColor
        layer?.shadowPath = path
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Float(0.25 + 0.2 * f); layer?.shadowRadius = 8; layer?.shadowOffset = CGSize(width: 0, height: -3)
        let s = h - 8
        icon.frame = NSRect(x: 5, y: 4, width: s, height: s)
        iconMask.frame = icon.bounds
        iconMask.path = chamferPath(s, cut: s * 0.26)
        CATransaction.commit()
        icon.image = iconCache[it.host] ?? letterTile(it.name)
        name.stringValue = it.name
        sub.stringValue = it.host.isEmpty ? it.subtitle : it.host
        trailing.stringValue = it.shortUpdated
        let x = s + 13
        let tw: CGFloat = 34
        trailing.frame = NSRect(x: w - cut - tw - 2, y: h / 2 - 7, width: tw, height: 13)
        name.frame = NSRect(x: x, y: h / 2, width: trailing.frame.minX - x - 4, height: 15)
        sub.frame = NSRect(x: x, y: h / 2 - 14, width: trailing.frame.minX - x - 4, height: 13)
    }
}

/// The vault on an arc. Entries are capsules riding a curved path: the one at the center sits furthest out and
/// largest, the others lean back along the curve, tilt with it, shrink and fade. Two fingers scroll them along the
/// path; each entry that reaches the center clicks under your fingers. Click the centered entry to open it as a
/// floating card; click another to bring it to the center.
final class VaultWheel: NSView {
    var items: [VaultItem] = [] { didSet { pos = 0; landed = 0; layoutRows() } }
    var onOpen: ((VaultItem) -> Void)?
    private var pos: CGFloat = 0
    private var landed = 0
    private var settleTimer: Timer?
    private var rows: [WheelRow] = []
    let rowHeight: CGFloat = 38
    let rowStep: CGFloat = 42            // spacing along the path
    let bow: CGFloat = 34                // how far the center of the arc sits out from its ends
    let tilt: CGFloat = 0                // rows stay upright; the arc is in where they sit

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<9 { let r = WheelRow(frame: .zero); rows.append(r); addSubview(r) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); layoutRows() }
    func redraw() { layoutRows() }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, !items.isEmpty else { return }
        guard event.momentumPhase.isEmpty else { return }
        if event.phase == .began { settleTimer?.invalidate() }
        let dy = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        // Fingers up move down the list (to the cards below); fingers down move back up.
        pos = min(CGFloat(items.count - 1) + 0.3, max(-0.3, pos + dy / rowStep))
        let target = Int(pos.rounded())
        if target != landed, items.indices.contains(target) {
            landed = target
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        layoutRows()
        if event.phase == .ended || event.phase == .cancelled { settle() }
    }

    private func settle() {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let target = CGFloat(self.landed)
            self.pos += (target - self.pos) * 0.22
            if abs(target - self.pos) < 0.002 { self.pos = target; t.invalidate() }
            self.layoutRows()
        }
    }

    func focus(_ i: Int) {
        guard items.indices.contains(i), i != landed else { return }
        landed = i
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        settle()
    }

    private func layoutRows() {
        let w = bounds.width, mid = bounds.midY
        let rowWidth = w - bow - 8
        let base = Int(pos.rounded())
        for (k, r) in rows.enumerated() {
            let i = base - 4 + k
            guard items.indices.contains(i) else { r.isHidden = true; continue }
            let d = CGFloat(i) - pos
            let f = max(0, 1 - abs(d))
            // Position on a circular arc: the center bows out to the right, the ends curl back to the left.
            let angle = d * 0.38
            let x = bow * cos(angle) - bow * (1 - cos(angle)) * 0.6
            let y = mid - sin(angle) * rowStep / 0.38
            let scale = max(0.7, 1 - 0.08 * abs(d))
            let rw = rowWidth * scale, rh = rowHeight * scale
            r.isHidden = abs(d) > 3.6
            r.frameCenterRotation = 0
            r.frame = NSRect(x: x, y: y - rh / 2, width: rw, height: rh)
            r.configure(items[i], focus: f)
            r.frameCenterRotation = -d * tilt                       // lean with the curve
            r.alphaValue = max(0, 1 - 0.12 * abs(d))          // the bands stay solid; only the far ends fade
        }
    }

    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let base = Int(pos.rounded())
        var best: (Int, CGFloat)?
        for (k, r) in rows.enumerated() where !r.isHidden && r.frame.insetBy(dx: -4, dy: -4).contains(p) {
            let i = base - 4 + k
            let dist = abs(CGFloat(i) - pos)
            if best == nil || dist < best!.1 { best = (i, dist) }
        }
        guard let (i, _) = best, items.indices.contains(i) else { return }
        if i != landed { focus(i); return }
        onOpen?(items[i])
    }
}

/// The opened entry, floating over the vault: it rises from the arc to the center with a soft spring.
final class FloatingCard: NSView {
    let detail = VaultDetail(frame: .zero)
    var onClose: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.2, alpha: 0.98).cgColor
        layer?.cornerRadius = 18
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedRed: 0.6, green: 0.55, blue: 1, alpha: 0.4).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.6; layer?.shadowRadius = 22; layer?.shadowOffset = CGSize(width: 0, height: -6)
        detail.onBack = { [weak self] in self?.onClose?() }
        addSubview(detail)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); detail.frame = bounds.insetBy(dx: 14, dy: 12) }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    func present(_ item: VaultItem) {
        isHidden = false
        detail.show(item)
        guard let l = layer else { return }
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.82; spring.toValue = 1
        spring.stiffness = 220; spring.damping = 20; spring.duration = spring.settlingDuration
        l.add(spring, forKey: "pop")
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.18
        l.add(fade, forKey: "fade")
    }
}

/// The Bitwarden widget, without a box. Locked, it is only a Touch ID mark. Click it, approve with Touch ID, and a
/// line draws out of the mark to become the search field, then the vault swings out of the mark onto its arc.
/// Locking (the lock button, Esc, or leaving the panel) folds it all back into the mark.
final class VaultView: NSView, NSTextFieldDelegate {
    let bar = NSView()                         // the mark when locked, the search bar when open
    let mark = NSImageView(image: NSImage(systemSymbolName: "touchid", accessibilityDescription: "Unlock Bitwarden")!)
    let field = NSTextField()
    let secure = NSSecureTextField()
    let lockButton = NSButton()
    let section = NSTextField(labelWithString: "")
    let deck = VaultWheel(frame: .zero)
    let card = FloatingCard(frame: .zero)
    let underline = NSView()
    let hint = NSTextField(labelWithString: "")
    var onKeyboard: ((NSView?) -> Void)?       // ask the panel for keyboard focus (nil gives it back)
    var onDenied: ((Bool) -> Void)?            // Touch ID refused; true when it was canceled
    var onClosed: (() -> Void)?                // locked again (by you, or after a failed unlock)
    private var markHover: NSTrackingArea?
    private(set) var unlocked = false
    private var unlocking = false
    var busy: Bool { unlocked || unlocking || !secure.isHidden }
    private var favorites: [VaultItem] = []
    private var searchWork: DispatchWorkItem?
    let markSize: CGFloat = 22                 // about the height of an unselected date number
    let markCenterFromTop: CGFloat = 28        // level with the middle of the calendar's date numbers

    override init(frame: NSRect) {
        super.init(frame: frame)
        bar.wantsLayer = true
        underline.wantsLayer = true
        underline.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        mark.contentTintColor = NSColor(srgbRed: 0.35, green: 0.6, blue: 1, alpha: 1)
        mark.toolTip = "Bitwarden: click to unlock with Touch ID"
        for f in [field, secure] as [NSTextField] {
            f.isBordered = false; f.drawsBackground = false; f.focusRingType = .none
            f.textColor = .white; f.font = .systemFont(ofSize: 13); f.delegate = self
        }
        field.placeholderAttributedString = NSAttributedString(string: "Search vault…",
            attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 13)])
        secure.placeholderAttributedString = NSAttributedString(string: "Master password, just this once",
            attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 13)])
        lockButton.isBordered = false
        lockButton.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Lock")
        lockButton.contentTintColor = .tertiaryLabelColor
        lockButton.target = self; lockButton.action = #selector(lockTapped)
        lockButton.toolTip = "Lock"
        [underline, mark, field, secure, lockButton].forEach(bar.addSubview)
        section.font = .systemFont(ofSize: 11, weight: .semibold); section.textColor = .secondaryLabelColor
        hint.font = roundedFont(11, .medium); hint.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        hint.alphaValue = 0
        mark.wantsLayer = true
        deck.wantsLayer = true
        deck.onOpen = { [weak self] item in self?.open(item) }
        card.isHidden = true
        card.onClose = { [weak self] in self?.showDeck() }
        card.detail.onCopy = { [weak self] m in self?.flash(m) }
        [bar, section, hint, deck, card].forEach(addSubview)
        showLocked(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    // MARK: Geometry

    var barY: CGFloat { bounds.height - markCenterFromTop - markSize / 2 }
    /// Generous target while locked: the fingerprint, its label and the space around them all respond.
    var lockedHitArea: NSRect { NSRect(x: 0, y: barY - 14, width: min(bounds.width, 190), height: markSize + 28) }
    var lockedBar: NSRect { NSRect(x: 2, y: barY, width: markSize, height: markSize) }
    var openBar: NSRect { NSRect(x: 2, y: barY, width: bounds.width - 4, height: markSize) }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        bar.frame = unlocked || !secure.isHidden ? openBar : lockedBar
        layoutBar()
        let below = s.height - markCenterFromTop - markSize / 2       // everything under the mark / search line
        section.frame = NSRect(x: 4, y: below - 22, width: s.width - 8, height: 15)
        hint.frame = NSRect(x: markSize + 12, y: barY + 3, width: s.width - markSize - 14, height: 16)
        deck.frame = NSRect(x: 0, y: 0, width: s.width, height: below - 28)
        card.frame = NSRect(x: 0, y: 4, width: s.width, height: below - 10)
    }

    /// Hovering the locked fingerprint says what it is; the mark brightens.
    override func updateTrackingAreas() {
        if let t = markHover { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: lockedHitArea, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t); markHover = t
        super.updateTrackingAreas()
    }
    override func mouseEntered(with e: NSEvent) {
        guard !unlocked, !unlocking else { return }
        say("Unlock Bitwarden")
        mark.animator().contentTintColor = NSColor(srgbRed: 0.55, green: 0.75, blue: 1, alpha: 1)
    }
    override func mouseExited(with e: NSEvent) {
        guard !unlocked, !unlocking else { return }
        say("")
        mark.contentTintColor = NSColor(srgbRed: 0.35, green: 0.6, blue: 1, alpha: 1)
    }

    /// The short line next to the fingerprint (hover prompt, Touch ID progress, errors).
    func say(_ t: String) {
        hint.stringValue = t
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.2; hint.animator().alphaValue = t.isEmpty ? 0 : 1 }
    }

    /// A gentle pulse on the mark while Touch ID is waiting.
    func pulse(_ on: Bool) {
        guard let l = mark.layer else { return }
        if on {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0.35; a.duration = 0.7; a.autoreverses = true; a.repeatCount = .infinity
            l.add(a, forKey: "pulse")
        } else { l.removeAnimation(forKey: "pulse") }
    }

    func layoutBar() {
        let w = bar.bounds.width, h = bar.bounds.height
        // Locked, there is only the fingerprint. Opening, the fingerprint fades as a line draws out of where it was,
        // and that line is the search field (no box). Locking, the line pulls back and the fingerprint returns.
        mark.frame = NSRect(x: 0, y: 0, width: h, height: h)
        underline.frame = NSRect(x: 0, y: 0, width: w, height: 1)
        field.frame = NSRect(x: 2, y: (h - 18) / 2 + 1, width: max(0, w - 30), height: 18)
        secure.frame = field.frame
        lockButton.frame = NSRect(x: w - 18, y: (h - 14) / 2, width: 14, height: 14)
        let open = w > h + 20
        mark.alphaValue = open ? 0 : 1
        underline.alphaValue = open ? 1 : 0
        field.alphaValue = open ? 1 : 0; secure.alphaValue = open ? 1 : 0; lockButton.alphaValue = open ? 1 : 0
    }

    /// Animates the bar between the mark and the full search bar.
    func stretch(open: Bool, _ done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = open ? 0.32 : 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: open ? .easeOut : .easeIn)
            bar.animator().frame = open ? openBar : lockedBar
            mark.animator().alphaValue = open ? 0 : 1
            underline.animator().alphaValue = open ? 1 : 0
        }, completionHandler: { [weak self] in self?.layoutBar(); done?() })
        // Keep the contents laid out while the bar changes width.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.layoutBar() }
    }

    /// The deck swings out of the mark on an arc (and back into it when locking).
    func swing(in coming: Bool) {
        guard let l = deck.layer else { return }
        let h = deck.bounds.height
        var t = CATransform3DMakeTranslation(markSize / 2, h, 0)          // pivot at the mark, top-left
        t = CATransform3DRotate(t, coming ? 0.9 : 0.7, 0, 0, 1)
        t = CATransform3DScale(t, 0.25, 0.25, 1)
        t = CATransform3DTranslate(t, -markSize / 2, -h, 0)
        l.removeAllAnimations()
        if coming {
            deck.isHidden = false
            let spring = CASpringAnimation(keyPath: "transform")
            spring.fromValue = NSValue(caTransform3D: t); spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            spring.stiffness = 170; spring.damping = 18; spring.mass = 1
            spring.duration = spring.settlingDuration
            l.add(spring, forKey: "swing")
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.2
            l.add(fade, forKey: "fade")
        } else {
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in self?.deck.isHidden = true; self?.deck.layer?.removeAllAnimations() }
            let a = CABasicAnimation(keyPath: "transform")
            a.fromValue = NSValue(caTransform3D: CATransform3DIdentity); a.toValue = NSValue(caTransform3D: t)
            a.duration = 0.22; a.timingFunction = CAMediaTimingFunction(name: .easeIn)
            a.fillMode = .forwards; a.isRemovedOnCompletion = false
            l.add(a, forKey: "swing")
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.22
            fade.fillMode = .forwards; fade.isRemovedOnCompletion = false
            l.add(fade, forKey: "fade")
            CATransaction.commit()
        }
    }

    // MARK: States

    func showLocked(animated: Bool) {
        unlocked = false
        field.stringValue = ""; field.isEditable = false; field.isHidden = false
        secure.isHidden = true
        section.stringValue = ""
        card.isHidden = true
        pulse(false)
        if animated {
            swing(in: false)
            stretch(open: false) { [weak self] in self?.deck.items = [] }
        } else {
            bar.frame = lockedBar; layoutBar()
            deck.isHidden = true; deck.items = []
        }
    }

    func showUnlocked() {
        unlocked = true
        unlocking = false
        secure.isHidden = true; field.isHidden = false; field.isEditable = true
        stretch(open: true) { [weak self] in
            guard let self = self, self.unlocked else { return }
            self.onKeyboard?(self.field)
            self.loadFavorites()
        }
    }

    func flash(_ t: String) {
        section.stringValue = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.section.stringValue == t else { return }
            self.section.stringValue = self.field.stringValue.isEmpty ? "Favorites" : "Results"
        }
    }

    /// Locks the vault: the session is dropped and everything folds back into the mark.
    func lock() {
        guard unlocked || unlocking else { return }
        unlocking = false
        Bitwarden.shared.lockNow()
        showLocked(animated: true)
        onKeyboard?(nil)
        onClosed?()
    }

    @objc func lockTapped() { lock() }

    // Clicking the mark starts Touch ID.
    override func mouseDown(with e: NSEvent) {
        if !unlocked, lockedHitArea.contains(convert(e.locationInWindow, from: nil)) { beginUnlock() }
    }

    func beginUnlock() {
        guard !unlocked, !unlocking else { return }
        let bw = Bitwarden.shared
        guard bw.installed else { say("Needs the Bitwarden CLI"); return }
        unlocking = true
        say("Touch ID…"); pulse(true)
        DispatchQueue.global(qos: .userInitiated).async {
            let st = bw.status()
            DispatchQueue.main.async {
                if st == "unauthenticated" { self.unlocking = false; self.pulse(false); self.say("Run bw login once"); return }
                if let pw = bw.storedPassword() {
                    self.touchID(pw)
                } else {
                    // First time only: the master password, then Touch ID from now on.
                    self.pulse(false); self.say("")
                    self.field.isHidden = true; self.secure.isHidden = false
                    self.stretch(open: true) { self.onKeyboard?(self.secure) }
                }
            }
        }
    }

    func touchID(_ pw: String) {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Mac Password"
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "open your Bitwarden vault") { ok, err in
            DispatchQueue.main.async {
                guard ok else {
                    self.unlocking = false; self.pulse(false); self.say("Not unlocked")
                    let code = (err as? LAError)?.code
                    self.onDenied?(code == .userCancel || code == .appCancel || code == .systemCancel || code == .userFallback)
                    return
                }
                self.say("Opening…")
                self.unlock(pw, remember: false)
            }
        }
    }

    func unlock(_ pw: String, remember: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Bitwarden.shared.unlock(with: pw)
            NSLog("sill: Bitwarden unlock \(ok ? "succeeded" : "failed")")
            DispatchQueue.main.async {
                guard self.unlocking else { Bitwarden.shared.lockNow(); return }    // closed meanwhile
                self.pulse(false)
                if ok {
                    if remember { Bitwarden.shared.store(pw) }
                    self.say("")
                    self.showUnlocked()
                } else {
                    if !remember { Bitwarden.shared.forget() }        // the stored one no longer works
                    self.unlocking = false
                    self.showLocked(animated: true)
                    self.say(remember ? "Wrong master password" : "Couldn't open. Click to type your master password")
                }
            }
        }
    }

    // MARK: Deck

    func loadFavorites() {
        section.stringValue = "Favorites"
        DispatchQueue.global(qos: .userInitiated).async {
            let favs = Bitwarden.shared.favorites()
            DispatchQueue.main.async {
                guard self.unlocked else { return }
                self.favorites = favs
                if self.field.stringValue.isEmpty { self.fill(favs, empty: "No favorites yet") }
                self.swing(in: true)
            }
        }
    }

    func fill(_ items: [VaultItem], empty: String) {
        if items.isEmpty { section.stringValue = empty }
        deck.items = Array(items.prefix(60))
        for it in deck.items { fetchIcon(it.host) }
    }

    /// Site icons load in the background and redraw the deck when they arrive.
    func fetchIcon(_ host: String) {
        guard vaultIcons, !host.isEmpty, iconCache[host] == nil,
              let url = URL(string: "https://icons.bitwarden.net/\(host)/icon.png") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] d, _, _ in
            guard let d = d, let img = NSImage(data: d) else { return }
            DispatchQueue.main.async { iconCache[host] = img; self?.deck.redraw() }
        }.resume()
    }

    /// The chosen entry rises off the arc into a floating card; the arc fades back behind it.
    func open(_ item: VaultItem) {
        deck.animator().alphaValue = 0.15
        card.present(item)
    }

    func showDeck() {
        card.isHidden = true
        deck.animator().alphaValue = 1
    }

    // Enter in the password field unlocks; Esc locks; typing searches.
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { lock(); return true }
        if c === secure, sel == #selector(NSResponder.insertNewline(_:)) {
            let pw = secure.stringValue
            secure.stringValue = ""
            if !pw.isEmpty { unlock(pw, remember: true) }
            return true
        }
        return false
    }

    func controlTextDidChange(_ n: Notification) {
        guard (n.object as? NSTextField) === field, unlocked else { return }
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        searchWork?.cancel()
        showDeck()
        guard q.count >= 2 else { section.stringValue = "Favorites"; fill(favorites, empty: "No favorites yet"); return }
        section.stringValue = "Results"
        let w = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                let items = Bitwarden.shared.search(q)
                DispatchQueue.main.async { if self?.unlocked == true { self?.fill(items, empty: "No matches") } }
            }
        }
        searchWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }
}

// MARK: - Shortcuts & quick actions
//
// A column of pill buttons in the essentials panel. Shortcuts run through the `shortcuts` command; a Finder
// Quick Action runs on whatever is selected in Finder, or on files dropped onto its pill.

enum PillAction { case shortcut(String), quickAction(String) }
let pills: [PillAction] = [.shortcut("New Side Quest"), .quickAction("Copy Public Link")]

final class Pill: NSView {
    let action: PillAction
    let label = NSTextField(labelWithString: "")
    let title: String
    var hovering = false { didSet { paint() } }

    init(_ a: PillAction) {
        action = a
        switch a { case .shortcut(let n), .quickAction(let n): title = n }
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        show(title)
        if case .quickAction = a { registerForDraggedTypes([.fileURL]) }
        paint()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String) {
        label.stringValue = text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        label.frame = NSRect(x: 16, y: (bounds.height - 16) / 2, width: bounds.width - 28, height: 16)
    }
    func paint() { layer?.backgroundColor = NSColor.white.withAlphaComponent(hovering ? 0.14 : 0.07).cgColor }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with e: NSEvent) {
        switch action {
        case .shortcut(let name): run("/usr/bin/shortcuts", ["run", name])
        case .quickAction(let name):
            let files = finderSelection()
            guard !files.isEmpty else { flash("Select a file in Finder"); return }
            runQuickAction(name, files)
        }
    }

    // Dropping files onto a Quick Action pill runs it on them.
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { hovering = true; return .copy }
    override func draggingExited(_ s: NSDraggingInfo?) { hovering = false }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        hovering = false
        guard case .quickAction(let name) = action,
              let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return false }
        runQuickAction(name, urls.map { $0.path })
        return true
    }

    func runQuickAction(_ name: String, _ files: [String]) {
        let wf = NSHomeDirectory() + "/Library/Services/\(name).workflow"
        var args: [String] = []
        for f in files { args += ["-i", f] }
        run("/usr/bin/automator", args + [wf])
    }

    /// Paths selected in Finder (asks once for permission to talk to Finder).
    func finderSelection() -> [String] {
        let src = "tell application \"Finder\" to get POSIX path of (selection as alias list)"
        var err: NSDictionary?
        guard let out = NSAppleScript(source: src)?.executeAndReturnError(&err) else { return [] }
        if out.numberOfItems == 0 { return out.stringValue.map { [$0] } ?? [] }
        return (1...out.numberOfItems).compactMap { out.atIndex($0)?.stringValue }
    }

    func run(_ tool: String, _ args: [String]) {
        show("Running…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] p in
            DispatchQueue.main.async { self?.flash(p.terminationStatus == 0 ? "Done" : "Didn't finish") }
        }
        do { try p.run() } catch { flash("Couldn't run") }
    }

    func flash(_ text: String) {
        show(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self = self else { return }
            self.show(self.title)
        }
    }
}

/// The shortcut pills, side by side.
final class PillColumn: NSView {
    let items = pills.map(Pill.init)
    override init(frame: NSRect) { super.init(frame: frame); items.forEach(addSubview) }
    required init?(coder: NSCoder) { fatalError() }
    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        let gap: CGFloat = 8
        let w = (s.width - gap * CGFloat(items.count - 1)) / CGFloat(items.count)
        for (i, p) in items.enumerated() { p.frame = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: s.height) }
    }
}

// MARK: - Batteries
//
// A quiet row in the top-left corner of the essentials panel: this Mac's battery, then any connected Bluetooth
// device that reports one (AirPods, headphones, keyboards, mice). Read from the system's power sources and
// Bluetooth report every two minutes. iPhone and iPad batteries aren't available to apps on the Mac, so they
// don't appear.

struct BatteryReading { let name: String; let symbol: String; let percent: Int; let charging: Bool }

func batterySymbol(_ p: Int, charging: Bool) -> String {
    if charging { return "battery.100.bolt" }
    switch p { case 88...: return "battery.100"; case 63..<88: return "battery.75"; case 38..<63: return "battery.50"
    case 13..<38: return "battery.25"; default: return "battery.0" }
}

func readBatteries() -> [BatteryReading] {
    var out: [BatteryReading] = []
    // This Mac.
    if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
       let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            out.append(BatteryReading(name: "Mac", symbol: "laptopcomputer", percent: cur * 100 / max, charging: charging))
        }
    }
    // Connected Bluetooth devices that report a battery.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    p.arguments = ["SPBluetoothDataType", "-json"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    guard (try? p.run()) != nil else { return out }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let ctls = json["SPBluetoothDataType"] as? [[String: Any]] else { return out }
    func pct(_ v: Any?) -> Int? { (v as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) } }
    for c in ctls {
        for dev in (c["device_connected"] as? [[String: Any]] ?? []) {
            for (name, v) in dev {
                guard let info = v as? [String: Any] else { continue }
                let levels = [info["device_batteryLevelLeft"], info["device_batteryLevelRight"]].compactMap(pct)
                let single = pct(info["device_batteryLevelMain"]) ?? pct(info["device_batteryLevel"])
                guard let level = levels.min() ?? single else { continue }
                let kind = (info["device_minorType"] as? String ?? "").lowercased()
                let symbol = name.lowercased().contains("airpods pro") ? "airpodspro"
                    : name.lowercased().contains("airpods") ? "airpods"
                    : kind.contains("headphone") ? "headphones" : kind.contains("keyboard") ? "keyboard"
                    : kind.contains("mouse") ? "computermouse" : "dot.radiowaves.left.and.right"
                let short = name.replacingOccurrences(of: "Chau’s ", with: "").replacingOccurrences(of: "Chau's ", with: "")
                out.append(BatteryReading(name: short, symbol: symbol, percent: level, charging: false))
            }
        }
    }
    return out
}

final class BatteryRow: NSView {
    private var timer: Timer?
    override init(frame: NSRect) {
        super.init(frame: frame)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let r = readBatteries()
            DispatchQueue.main.async { self.show(r) }
        }
    }

    func show(_ readings: [BatteryReading]) {
        subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 0
        for r in readings {
            let dev = NSImageView(image: NSImage(systemSymbolName: r.symbol, accessibilityDescription: r.name) ?? NSImage())
            dev.contentTintColor = NSColor.white.withAlphaComponent(0.75)
            dev.frame = NSRect(x: x, y: 1, width: 14, height: 13)
            let bat = NSImageView(image: NSImage(systemSymbolName: batterySymbol(r.percent, charging: r.charging), accessibilityDescription: nil) ?? NSImage())
            // Green when healthy or charging, yellow when getting low, red when it needs a charger.
            bat.contentTintColor = r.charging ? .systemGreen : r.percent <= 20 ? .systemRed : r.percent <= 40 ? .systemYellow : .systemGreen
            bat.frame = NSRect(x: x + 17, y: 1, width: 20, height: 13)
            let t = NSTextField(labelWithString: "\(r.percent)%")
            t.font = roundedFont(10, .semibold); t.textColor = NSColor.white.withAlphaComponent(0.75)
            t.sizeToFit()
            t.frame.origin = NSPoint(x: x + 40, y: 0)
            [dev, bat, t].forEach(addSubview)
            toolTip = readings.map { "\($0.name) \($0.percent)%" }.joined(separator: " · ")
            x = t.frame.maxX + 12
        }
    }
}

// MARK: - The essentials' instruments (design language of Chau's media player)
//
// Black glass, one calm blue at different intensities, and bioluminescent cyan as the only accent. Every control is
// a line until you reach for it: the horizon (the future, measured like a time rail), the left edge (recording), the
// right edge (the vault and brightness) and the home bar at the bottom (shortcuts).

// Nature's pair: the night ocean, and the bioluminescence that lights up in it (dinoflagellates glow at ~480 nm).
let calmBlue = NSColor(srgbRed: 0x1E / 255, green: 0x60 / 255, blue: 0x91 / 255, alpha: 1)   // night-ocean blue #1E6091
let bioCyan = NSColor(srgbRed: 0x63 / 255, green: 0xC5 / 255, blue: 0xFA / 255, alpha: 1)   // Lantern #63C5FA: the light
let midwater = NSColor(srgbRed: 0x0A / 255, green: 0x10 / 255, blue: 0x17 / 255, alpha: 1)  // Midwater #0A1017: the ground

/// A length of time in the units of a life rather than a song: hours, then days past 24 h, weeks past 7 days,
/// months past 3 weeks, years past 12 months; the next unit down is stacked after it ("1 mo 2 w").
func lifeSpan(_ t: TimeInterval) -> String {
    let h = Int((t / 3600).rounded())
    if h < 1 { return "now" }
    if h < 24 { return "\(h) h" }
    let d = h / 24, hr = h % 24
    if d < 7 { return hr == 0 ? "\(d) d" : "\(d) d \(hr) h" }
    if d < 21 { let w = d / 7, dd = d % 7; return dd == 0 ? "\(w) w" : "\(w) w \(dd) d" }
    let mo = Int(Double(d) / 30.44)
    if mo < 12 { let w = Int((Double(d) - Double(mo) * 30.44) / 7); return w == 0 ? "\(max(mo, 1)) mo" : "\(max(mo, 1)) mo \(w) w" }
    let y = mo / 12, m = mo % 12
    return m == 0 ? "\(y) y" : "\(y) y \(m) mo"
}

/// Something on the horizon: a Calendar event or a Reminder with a due time.
struct HorizonMark { let date: Date; let title: String; let alarmed: Bool }

/// The future as a time rail. Now is a small bioluminescent dot at the left; the line runs to the right. Upcoming
/// events and reminders sit on it as ticks, brighter the sooner they are. Hover the dot (or the line) and swipe two
/// fingers to the right: the glow stretches from now into the future and says how far ("5 h", "2 d", "1 mo 2 w");
/// past a day the rail rescales, so you can reach weeks, months, years. Move away and the glow draws back to now.
final class HorizonView: NSView {
    var marks: (Date, Date) -> [HorizonMark] = { _, _ in [] }
    var onReach: ((TimeInterval) -> Void)?            // you moved the reach (swipe, or it drew back)
    private(set) var reach: TimeInterval = 0          // how far ahead the glow reaches
    private var shownReach: TimeInterval = 0
    private var span: TimeInterval = 48 * 3600        // what the full width of the rail covers
    private var shownSpan: TimeInterval = 48 * 3600
    private var anim: Timer?
    private var retract: DispatchWorkItem?
    private var hovering = false
    private var sliding = false
    private var cache: [HorizonMark] = []
    private var cacheKey: (Date, TimeInterval) = (.distantPast, 0)
    private var lastUnitStep = 0
    let inset: CGFloat = 10
    let lineY: CGFloat = 30

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; retract?.cancel(); needsDisplay = true }
    override func mouseExited(with e: NSEvent) {
        hovering = false
        scheduleRetract(after: 2.5)
        needsDisplay = true
    }

    func reload() { cacheKey = (.distantPast, 0); needsDisplay = true }
    func reset() { retract?.cancel(); pinned = false; setReach(0) }
    /// Moved by the day strip: reach to the start of that day (no callback back).
    func reach(to d: Date) { retract?.cancel(); setReach(max(0, d.timeIntervalSinceNow)) }

    /// Two fingers right reach further into the future; left draws back. The step grows with the distance, so a
    /// short swipe moves hours near now and weeks far out.
    private var pinned = false
    private var holdWork: DispatchWorkItem?
    /// Fingers resting on the trackpad hold the reach where it is; rest them still for half a second and it's pinned
    /// (it stays until you slide again or the panel closes). Lifting them lets it draw back, slowly.
    private func fingers(_ e: NSEvent) {
        if e.phase == .mayBegin || e.phase == .began {
            retract?.cancel()
            holdWork?.cancel()
            if reach > 60 && e.phase == .mayBegin {
                let w = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.pinned = true
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                    self.needsDisplay = true
                }
                holdWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
            }
        }
        if e.phase == .ended || e.phase == .cancelled {
            holdWork?.cancel()
            scheduleRetract(after: 3)
        }
    }
    private var held = false
    /// Fingers on the event list (scrolling or just resting) keep the reach where it is until they lift.
    func hold(_ on: Bool) {
        if on { held = true; retract?.cancel() }
        else if held { held = false; if reach > 60 { scheduleRetract(after: 3) } }
    }
    private func scheduleRetract(after delay: TimeInterval) {
        retract?.cancel()
        guard !pinned, !held else { return }
        let back = DispatchWorkItem { [weak self] in self?.sliding = false; self?.retracting = true; self?.setReach(0); self?.onReach?(0) }
        retract = back
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: back)
    }
    private var retracting = false

    override func scrollWheel(with e: NSEvent) {
        fingers(e)
        guard e.hasPreciseScrollingDeltas, e.momentumPhase.isEmpty else { return }
        let dx = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX     // fingers right > 0
        guard abs(dx) >= abs(e.scrollingDeltaY) else { return }
        guard abs(dx) > 0.01 else { return }
        sliding = true
        pinned = false; holdWork?.cancel()
        retract?.cancel()
        retracting = false
        let rate = max(3600, reach) * 0.013          // about 3–4 days across most of the trackpad; hours near now
        setReach(min(5 * 365 * 86400, max(0, reach + dx * rate)))
        onReach?(reach)
    }

    private func setReach(_ r: TimeInterval) {
        reach = r
        span = max(48 * 3600, r / 0.78)
        // A click under the fingers each time the reach passes a whole unit (hour, day, week, month).
        let unit: TimeInterval = r < 86400 ? 3600 : r < 7 * 86400 ? 86400 : r < 30 * 86400 ? 7 * 86400 : 30.44 * 86400
        let step = Int(r / unit) + (unit == 3600 ? 0 : unit == 86400 ? 1000 : unit == 7 * 86400 ? 2000 : 3000)
        if step != lastUnitStep { lastUnitStep = step; if r > 0 { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) } }
        guard anim == nil else { return }
        anim = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            self.shownReach += (self.reach - self.shownReach) * (self.retracting ? 0.06 : 0.5)   // follows the fingers closely; draws back slowly
            self.shownSpan += (self.span - self.shownSpan) * 0.35
            if abs(self.reach - self.shownReach) < max(60, self.reach * 0.002), abs(self.span - self.shownSpan) < 60 {
                self.shownReach = self.reach; self.shownSpan = self.span
                t.invalidate(); self.anim = nil
            }
            self.needsDisplay = true
        }
    }

    private func x(for t: TimeInterval) -> CGFloat { inset + CGFloat(t / shownSpan) * (bounds.width - 2 * inset) }

    private func currentMarks(_ now: Date) -> [HorizonMark] {
        if abs(cacheKey.0.timeIntervalSince(now)) > 60 || cacheKey.1 < shownSpan {
            cache = marks(now, now.addingTimeInterval(max(span, shownSpan) * 1.3))
            cacheKey = (now, max(span, shownSpan) * 1.3)
        }
        return cache.filter { $0.date > now && $0.date.timeIntervalSince(now) <= shownSpan }
    }

    override func draw(_ dirty: NSRect) {
        let now = Date()
        let w = bounds.width
        let x0 = inset, x1 = w - inset
        // Tick scale, like a track's time rail, in whatever unit fits the current span.
        let steps: [TimeInterval] = ([3, 6, 12, 24, 48, 168, 336, 730.6, 2184, 4368, 8760] as [Double]).map { $0 * 3600 }
        let step = steps.first { shownSpan / $0 <= 8 } ?? steps.last!
        let tickAttr: [NSAttributedString.Key: Any] = [.font: roundedFont(8.5, .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
        var t = step
        while t < shownSpan * 0.999 {
            let x = x(for: t)
            calmBlue.setFill()
            NSBezierPath(rect: NSRect(x: x - 0.5, y: lineY - 6, width: 1, height: 4)).fill()
            let s = NSAttributedString(string: lifeSpan(t), attributes: tickAttr)
            let sz = s.size()
            if x + sz.width / 2 < x1 - 2 { s.draw(at: NSPoint(x: x - sz.width / 2, y: lineY - 18)) }
            t += step
        }
        // The rail: night-ocean blue, as rich as a pressed edge bar (full color, the same soft glow).
        let rail = NSRect(x: x0, y: lineY - 1.5, width: x1 - x0, height: 3)
        NSGraphicsContext.saveGraphicsState()
        let railGlow = NSShadow(); railGlow.shadowColor = calmBlue.withAlphaComponent(0.8); railGlow.shadowBlurRadius = 8; railGlow.set()
        calmBlue.setFill()
        NSBezierPath(roundedRect: rail, xRadius: 1.5, yRadius: 1.5).fill()
        NSGraphicsContext.restoreGraphicsState()

        // The reach: bitonal. Bioluminescence colors over the blue from now to where you've reached, so it's clear
        // where you are against what's ahead. The label is how far from now: "+1 d 2 h".
        if shownReach > 60 {
            let xr = x(for: shownReach)
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow(); glow.shadowColor = bioCyan.withAlphaComponent(0.85); glow.shadowBlurRadius = 7; glow.set()
            bioCyan.setFill()
            NSBezierPath(roundedRect: NSRect(x: x0, y: lineY - 1.5, width: xr - x0, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            NSBezierPath(ovalIn: NSRect(x: xr - 3.5, y: lineY - 3.5, width: 7, height: 7)).fill()
            NSGraphicsContext.restoreGraphicsState()
            if pinned {                                       // held: a ring around the tip
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: xr - 6, y: lineY - 6, width: 12, height: 12)); ring.lineWidth = 1.2; ring.stroke()
            }
            // At the anchor the label reads NOW (no "+"); further out, "+x" counted from NOW.
            let label = NSAttributedString(string: shownReach < 3600 ? "NOW" : "+" + lifeSpan(shownReach), attributes: [.font: roundedFont(11, .semibold), .foregroundColor: NSColor.white])
            let sz = label.size()
            label.draw(at: NSPoint(x: min(max(xr - sz.width / 2, x0), x1 - sz.width), y: lineY + 8))
        }

        // Events and reminders: ticks whose brightness is how soon they are; inside the reach they glow.
        let marks = currentMarks(now)
        var lastLabelEnd: CGFloat = -1000
        for m in marks.sorted(by: { $0.date < $1.date }) {
            let dt = m.date.timeIntervalSince(now)
            let x = x(for: dt)
            let soon = max(0.25, 1 - min(1, dt / (48 * 3600)) * 0.75)
            let inReach = dt <= shownReach
            let c = inReach ? bioCyan : (calmBlue.blended(withFraction: 0.45 * soon, of: .white) ?? calmBlue)
            NSGraphicsContext.saveGraphicsState()
            if inReach || m.alarmed { let g = NSShadow(); g.shadowColor = c; g.shadowBlurRadius = 5; g.set() }
            c.setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 1, y: lineY - 6, width: 2, height: 12), xRadius: 1, yRadius: 1).fill()
            NSGraphicsContext.restoreGraphicsState()
            let s = NSAttributedString(string: m.title, attributes: [.font: roundedFont(9.5, .semibold),
                                                                      .foregroundColor: inReach ? bioCyan : NSColor.white])
            let sz = s.size()
            let lx = min(max(x - sz.width / 2, x0), x1 - sz.width)
            if lx > lastLabelEnd + 6 && sz.width < 150 { s.draw(at: NSPoint(x: lx, y: lineY - 31)); lastLabelEnd = lx + sz.width }
        }

        // While you slide: today's date under the dot, in white, so "+x" has something to be counted from.
        if shownReach > 60 {
            let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMdd")
            let t = NSAttributedString(string: f.string(from: now), attributes: [.font: roundedFont(10, .semibold), .foregroundColor: NSColor.white])
            t.draw(at: NSPoint(x: max(0, x0 - t.size().width / 2), y: lineY - 22))
        }
        // Now: a small dark dot ringed with bioluminescence.
        let dot = NSRect(x: x0 - 4, y: lineY - 4, width: 8, height: 8)
        NSGraphicsContext.saveGraphicsState()
        let halo = NSShadow(); halo.shadowColor = bioCyan.withAlphaComponent(hovering ? 1 : 0.75); halo.shadowBlurRadius = hovering ? 9 : 6; halo.set()
        bioCyan.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: dot).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(srgbRed: 0.03, green: 0.12, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: 2.2, dy: 2.2)).fill()
    }
}

/// A thin line on the card's edge that is also a control. Hover brightens it; it can carry a live level (the
/// recorder's meter) drawn along its length.
final class EdgeBar: NSView {
    var tint = NSColor.white.withAlphaComponent(0.45)
    var active = false { didSet { if active != oldValue { needsDisplay = true } } }      // pressed: recorder pinned / recording, vault open
    var level: CGFloat = 0 { didSet { if abs(level - oldValue) > 0.01 { needsDisplay = true } } }
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDwell: ((Bool) -> Void)?                              // hovered long enough (true) / left (false)
    var onScrollY: ((CGFloat) -> Void)?
    /// While you adjust (volume, brightness) the bioluminescence fills the line from the bottom to the value.
    var fill: CGFloat? { didSet { needsDisplay = true; fadeFill() } }
    private var fillWork: DispatchWorkItem?
    private func fadeFill() {
        fillWork?.cancel()
        guard fill != nil else { return }
        let w = DispatchWorkItem { [weak self] in self?.fill = nil }
        fillWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }
    private var hovering = false
    private var dwell: DispatchWorkItem?
    private var single: DispatchWorkItem?

    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    private var leaveWork: DispatchWorkItem?
    override func mouseEntered(with e: NSEvent) {
        leaveWork?.cancel()
        if !hovering { hovering = true; needsDisplay = true }
        dwell?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.onDwell?(true) }
        dwell = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
    }
    /// Leaving lets the line linger a moment, so brushing the edge doesn't make it blink on and off.
    override func mouseExited(with e: NSEvent) {
        dwell?.cancel(); onDwell?(false)
        leaveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hovering = false; self?.needsDisplay = true }
        leaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }
    override func mouseDown(with e: NSEvent) {
        if e.clickCount >= 2, onDoubleClick != nil { single?.cancel(); onDoubleClick?(); return }
        guard onDoubleClick != nil else { onClick?(); return }
        let w = DispatchWorkItem { [weak self] in self?.onClick?() }
        single = w
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: w)
    }
    override func scrollWheel(with e: NSEvent) {
        guard let f = onScrollY, e.hasPreciseScrollingDeltas, abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX) else { return }
        f(e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY)
    }

    override func draw(_ dirty: NSRect) {
        // Contextual: invisible until the pointer comes to it (or while it's pressed / adjusting / live).
        let visible = hovering || active || fill != nil || level > 0.02
        guard visible else { return }
        let w: CGFloat = hovering || active || fill != nil ? 4 : 3
        let r = NSRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        // At rest a translucent glass line; blue only once pressed (Touch ID, the recorder open).
        NSGraphicsContext.saveGraphicsState()
        if active { let g = NSShadow(); g.shadowColor = calmBlue.withAlphaComponent(0.8); g.shadowBlurRadius = 8; g.set() }
        (active ? calmBlue : NSColor.white.withAlphaComponent(0.42)).setFill()
        NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
        if !active {
            NSColor.white.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX + w * 0.2, y: 2, width: w * 0.3, height: bounds.height - 4), xRadius: 0.6, yRadius: 0.6).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        if let f = fill {
            let h = max(w, bounds.height * min(1, max(0, f)))
            NSGraphicsContext.saveGraphicsState()
            let g = NSShadow(); g.shadowColor = bioCyan.withAlphaComponent(0.9); g.shadowBlurRadius = 7; g.set()
            bioCyan.setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX, y: 0, width: w, height: h), xRadius: w / 2, yRadius: w / 2).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        // The live level: a bright segment that swells from the middle of the line.
        if level > 0.02 {
            let h = max(6, bounds.height * min(1, level * 1.4))
            let seg = NSRect(x: r.minX - 0.5, y: (bounds.height - h) / 2, width: w + 1, height: h)
            NSGraphicsContext.saveGraphicsState()
            let g = NSShadow(); g.shadowColor = bioCyan.withAlphaComponent(0.9); g.shadowBlurRadius = 7; g.set()
            bioCyan.setFill()
            NSBezierPath(roundedRect: seg, xRadius: seg.width / 2, yRadius: seg.width / 2).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// The home bar at the bottom: a short glass line. Press it for the R2 library.
final class HomeBar: NSView {
    let line = NSView()
    var onPress: (() -> Void)?
    private var hover = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.5).cgColor
        line.layer?.cornerRadius = 1.5
        line.alphaValue = 0                                  // contextual: shows when the pointer comes to it
        addSubview(line)
        toolTip = "Go to R2"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); line.frame = NSRect(x: (s.width - 70) / 2, y: 6, width: 70, height: 3) }
    override func hitTest(_ p: NSPoint) -> NSView? {
        let local = convert(p, from: superview)
        return NSRect(x: (bounds.width - 110) / 2, y: 0, width: 110, height: 22).contains(local) ? self : nil
    }
    override func resetCursorRects() { addCursorRect(NSRect(x: (bounds.width - 110) / 2, y: 0, width: 110, height: 22), cursor: .pointingHand) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: NSRect(x: (bounds.width - 110) / 2, y: 0, width: 110, height: 22),
                                       options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with e: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.2
            line.animator().alphaValue = 1
            line.animator().frame = NSRect(x: (bounds.width - 90) / 2, y: 6, width: 90, height: 3) }
    }
    override func mouseExited(with e: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.3; ctx.allowsImplicitAnimation = true
            line.animator().alphaValue = 0
            line.animator().frame = NSRect(x: (bounds.width - 70) / 2, y: 6, width: 70, height: 3) }
    }
    override func mouseDown(with e: NSEvent) { onPress?() }
}

/// Go to R2: a small browser over your R2 bucket (through rclone and its "r2" remote, already set up on this Mac).
/// Click a folder to go in, ‹ to go back; click a file to open it (a private link valid for an hour); drop files on
/// it to upload them into the folder you're in. ✕ closes it.
let r2Remote = "gallery"
let r2Bucket = "Main"            // the bucket the current R2 token can read; change to your media bucket
let rclonePath = "/opt/homebrew/bin/rclone"

final class R2Tray: NSView {
    struct Item { let name: String; let isDir: Bool; let size: Int; let date: String }
    let title = NSTextField(labelWithString: "")
    let hint = NSTextField(labelWithString: "")
    let back = NSButton()
    let close = NSButton()
    let list = NSScrollView()
    let body = FlippedView()
    var onClose: (() -> Void)?
    private var path: [String] = []
    private var items: [Item] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        let glass = NSVisualEffectView(frame: bounds)
        glass.material = .hudWindow; glass.blendingMode = .withinWindow; glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        title.font = roundedFont(12, .bold); title.textColor = .white; title.lineBreakMode = .byTruncatingHead
        hint.font = roundedFont(10.5, .semibold); hint.textColor = bioCyan; hint.alignment = .right
        for (bt, sym, sel) in [(back, "chevron.left", #selector(goBack)), (close, "xmark.circle.fill", #selector(closeTapped))] {
            bt.isBordered = false
            bt.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            bt.contentTintColor = .white
            bt.target = self; bt.action = sel
        }
        list.drawsBackground = false; list.hasVerticalScroller = false; list.documentView = body
        list.horizontalScrollElasticity = .none; list.usesPredominantAxisScrolling = true
        [title, hint, back, close, list].forEach(addSubview)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    @objc func closeTapped() { onClose?() }
    @objc func goBack() { guard !path.isEmpty else { return }; path.removeLast(); reload() }

    var remotePath: String { "\(r2Remote):\(r2Bucket)" + (path.isEmpty ? "" : "/" + path.joined(separator: "/")) }

    func reload() {
        title.stringValue = "Gallery · " + ([r2Bucket] + path).joined(separator: " / ")
        back.isHidden = path.isEmpty
        hint.stringValue = "Loading…"
        let target = remotePath
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, out) = R2Tray.rclone(["lsjson", target, "--max-depth", "1"])
            var got: [Item] = []
            if ok, let arr = (try? JSONSerialization.jsonObject(with: out)) as? [[String: Any]] {
                for o in arr {
                    let name = o["Name"] as? String ?? ""
                    if name.hasPrefix(".") { continue }
                    got.append(Item(name: name, isDir: o["IsDir"] as? Bool ?? false, size: o["Size"] as? Int ?? 0,
                                    date: String((o["ModTime"] as? String ?? "").prefix(10))))
                }
            }
            got.sort { $0.isDir != $1.isDir ? $0.isDir : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                guard target == self.remotePath else { return }
                self.items = got
                self.hint.stringValue = ok ? "Drop files to upload here" : "Couldn't reach R2"
                self.layoutRows()
            }
        }
    }

    static func rclone(_ args: [String]) -> (Bool, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rclonePath)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return (false, Data()) }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, d)
    }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        let w = s.width, h = s.height
        back.frame = NSRect(x: 10, y: h - 28, width: 18, height: 18)
        title.frame = NSRect(x: 32, y: h - 26, width: w - 230, height: 16)
        hint.frame = NSRect(x: w - 200, y: h - 25, width: 160, height: 15)
        close.frame = NSRect(x: w - 32, y: h - 29, width: 20, height: 20)
        list.frame = NSRect(x: 8, y: 8, width: w - 16, height: h - 42)
        layoutRows()
    }

    private func layoutRows() {
        body.subviews.forEach { $0.removeFromSuperview() }
        let w = list.bounds.width
        var y: CGFloat = 0
        for it in items {
            let row = R2Row(it, width: w)
            row.frame.origin = NSPoint(x: 0, y: y)
            row.onOpen = { [weak self] in self?.open(it) }
            body.addSubview(row)
            y += 26
        }
        if items.isEmpty && hint.stringValue != "Loading…" {
            let t = NSTextField(labelWithString: "Empty")
            t.font = roundedFont(12, .semibold); t.textColor = .white
            t.frame = NSRect(x: 8, y: 6, width: w, height: 16)
            body.addSubview(t); y = 28
        }
        body.frame = NSRect(x: 0, y: 0, width: w, height: max(list.bounds.height, y))
    }

    private func open(_ it: Item) {
        if it.isDir { path.append(it.name); reload(); return }
        hint.stringValue = "Opening…"
        let target = remotePath + "/" + it.name
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, out) = R2Tray.rclone(["link", target, "--expire", "1h"])
            let link = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                if ok, let u = URL(string: link) { NSWorkspace.shared.open(u); self.hint.stringValue = "Opened" }
                else { self.hint.stringValue = "Couldn't open" }
            }
        }
    }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { layer?.borderColor = bioCyan.cgColor; return .copy }
    override func draggingExited(_ s: NSDraggingInfo?) { layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        guard let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return false }
        hint.stringValue = "Uploading \(urls.count)…"
        let dest = remotePath
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = true
            for u in urls { ok = R2Tray.rclone(["copy", u.path, dest + (u.hasDirectoryPath ? "/" + u.lastPathComponent : "")]).0 && ok }
            DispatchQueue.main.async { self.hint.stringValue = ok ? "Uploaded" : "Upload failed"; self.reload() }
        }
        return true
    }
}

final class R2Row: NSView {
    var onOpen: (() -> Void)?
    init(_ it: R2Tray.Item, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        wantsLayer = true
        layer?.cornerRadius = 8
        let icon = NSImageView(image: NSImage(systemSymbolName: it.isDir ? "folder.fill" : "doc", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = it.isDir ? calmBlue : .white
        icon.frame = NSRect(x: 8, y: 4, width: 16, height: 16)
        let name = NSTextField(labelWithString: it.name)
        name.font = roundedFont(12, .semibold); name.textColor = .white; name.lineBreakMode = .byTruncatingMiddle
        name.frame = NSRect(x: 30, y: 4, width: width - 150, height: 16)
        let meta = NSTextField(labelWithString: it.isDir ? "" : ByteCountFormatter.string(fromByteCount: Int64(it.size), countStyle: .file))
        meta.font = roundedFont(11, .medium); meta.textColor = .white; meta.alignment = .right
        meta.frame = NSRect(x: width - 112, y: 4, width: 104, height: 16)
        [icon, name, meta].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor }
    override func mouseExited(with e: NSEvent) { layer?.backgroundColor = nil }
    override func mouseDown(with e: NSEvent) { onOpen?() }
}

/// Screen brightness through DisplayServices (EXPERIMENTAL: a private framework; no public API sets the built-in
/// display's brightness). Does nothing if the framework or its functions aren't there.
enum Brightness {
    typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias Set = @convention(c) (UInt32, Float) -> Int32
    static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    static let get: Get? = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
    static let set: Set? = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }
    @discardableResult static func nudge(_ delta: Float) -> Float? {
        guard let get = get, let set = set else { return nil }
        let d = CGMainDisplayID()
        var b: Float = 0
        guard get(d, &b) == 0 else { return nil }
        let n = min(1, max(0, b + delta))
        _ = set(d, n)
        return n
    }
}

/// The menu bar's color on a screen: a small patch of the bar to the right of the strip (clear of app menus and
/// status icons), read from what lies under Sill's own windows, averaged.
func menuBarColor(on s: NSScreen, below wid: CGWindowID) -> NSColor? {
    let top = NSScreen.screens.first?.frame.maxY ?? s.frame.maxY
    let h = RestStrip.menuBarHeight(s)
    let rect = CGRect(x: s.frame.midX + restWidth / 2 - 30, y: top - s.frame.maxY + h * 0.2, width: 20, height: max(2, h * 0.3))
    guard let img = CGWindowListCreateImage(rect, .optionOnScreenBelowWindow, wid, [.nominalResolution]) else { return nil }
    let rep = NSBitmapImageRep(cgImage: img)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, n: CGFloat = 0
    for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
    } }
    guard n > 0 else { return nil }
    return NSColor(srgbRed: r / n, green: g / n, blue: b / n, alpha: 1)
}

/// The player's round glass button: a translucent white disc, a hairline rim, and white pause bars or a play
/// triangle. Each press flips it with a small spring. (macOS no longer tells apps what's playing, so it flips on
/// your press rather than following the player.)
final class GlassPauseButton: NSButton {
    private var hover = false
    var showsPlay = false { didSet { needsDisplay = true } }
    var symbol: String?                 // a round glass button with an SF Symbol instead of play/pause
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    func bounce() {
        wantsLayer = true
        guard let l = layer else { return }
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5); l.position = CGPoint(x: frame.midX, y: frame.midY)
        let a = CASpringAnimation(keyPath: "transform.scale")
        a.fromValue = 0.78; a.toValue = 1; a.stiffness = 380; a.damping = 14; a.duration = a.settlingDuration
        l.add(a, forKey: "bounce")
    }
    override func draw(_ dirty: NSRect) {
        let d = min(bounds.width, bounds.height) - 1
        let c = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        NSColor.white.withAlphaComponent(hover ? 0.26 : 0.16).setFill()
        NSBezierPath(ovalIn: c).fill()
        NSColor.white.withAlphaComponent(0.3).setStroke()
        let rim = NSBezierPath(ovalIn: c.insetBy(dx: 0.5, dy: 0.5)); rim.lineWidth = 0.8; rim.stroke()
        if let sym = symbol, let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: d * 0.42, weight: .semibold).applying(.init(paletteColors: [.white]))) {
            img.draw(in: NSRect(x: c.midX - img.size.width / 2, y: c.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            return
        }
        NSColor.white.setFill()
        if showsPlay {
            let t = NSBezierPath()
            let s = d * 0.36
            t.move(to: NSPoint(x: c.midX - s * 0.38, y: c.midY - s / 2))
            t.line(to: NSPoint(x: c.midX - s * 0.38, y: c.midY + s / 2))
            t.line(to: NSPoint(x: c.midX + s * 0.55, y: c.midY))
            t.close(); t.fill()
        } else {
            let bw = d * 0.13, bh = d * 0.42, gap = d * 0.11
            for x in [c.midX - gap / 2 - bw, c.midX + gap / 2] {
                NSBezierPath(roundedRect: NSRect(x: x, y: c.midY - bh / 2, width: bw, height: bh), xRadius: bw / 2, yRadius: bw / 2).fill()
            }
        }
    }
}

/// A new desktop (Space), and you're taken to it. EXPERIMENTAL: macOS has no public API for Spaces, so this asks
/// Mission Control to add a desktop and clicks the new one (UI scripting through System Events, so it can break
/// when Apple rearranges Mission Control).
func newSpace() {
    let src = """
    do shell script "open -b com.apple.exposelauncher"
    delay 0.6
    tell application id "com.apple.systemevents"
        tell (first application process whose bundle identifier is "com.apple.dock")
            click (button 1 of group 2 of group 1 of group 1)
            delay 0.7
            click (last button of list 1 of group 2 of group 1 of group 1)
        end tell
    end tell
    """
    DispatchQueue.global(qos: .userInitiated).async {
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let e = err { NSLog("sill: new space didn't work: \(e)") }
    }
}

/// When something is, the way a world clock says how far ahead a city is: "Today, +3 HRS", "Tomorrow, +18 HRS",
/// "Fri, +3 DAYS", "Nov 2, +4 WKS".
/// NOW is the anchor every upcoming event is counted from: the current day of the week, shown as "NOW", followed by
/// how far ahead the event is from this moment ("NOW +1 d 3 h").
func worldClockAhead(_ d: Date, now: Date = Date()) -> String {
    let NOW = "NOW"
    let t = d.timeIntervalSince(now)
    let ahead = t < 3600 ? "+\(max(1, Int((t / 60).rounded(.up)))) min" : "+" + lifeSpan(t)
    return "\(NOW) \(ahead)"
}


/// The system output volume (CoreAudio, the default output device's virtual main volume).
enum Volume {
    static func device() -> AudioObjectID {
        var id = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }
    static var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                     mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    static func get() -> Float? {
        var v = Float32(0); var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device(), &address, 0, nil, &size, &v) == noErr ? v : nil
    }
    @discardableResult static func nudge(_ delta: Float) -> Float? {
        guard let v = get() else { return nil }
        var n = Float32(min(1, max(0, v + delta)))
        AudioObjectSetPropertyData(device(), &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &n)
        return n
    }
}

/// Move one desktop left (-1) or right (+1): the system's own ⌃← / ⌃→ (Keyboard Shortcuts › Mission Control,
/// on by default), sent as key events.
func switchSpace(_ dir: Int) {
    let key: CGKeyCode = dir < 0 ? 123 : 124
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { continue }
        e.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        e.post(tap: .cghidEventTap)
    }
}

/// Play/pause for whatever is playing anywhere: the same system event as the keyboard's ⏯ key.
func pressPlayPause() {
    let NX_KEYTYPE_PLAY: Int32 = 16
    for down in [true, false] {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
        let data1 = Int((NX_KEYTYPE_PLAY << 16) | ((down ? 0xa : 0xb) << 8))
        NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                           context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
    }
}

/// A transparent layer that only takes events its subviews take: the panel's edge controls live on it, above every
/// surface (essentials, Draftpad, the next panels), so they follow you everywhere.
final class PassThroughView: NSView {
    override func hitTest(_ p: NSPoint) -> NSView? {
        let v = super.hitTest(p)
        return v === self ? nil : v
    }
}

final class EssentialsView: ClickView {
    let local: FoldingClock
    let left: FoldingClock
    let right: FoldingClock
    var clocks: [FoldingClock] { [local, left, right] }
    let clockFormat = DateFormatter()
    let store = EKEventStore()
    lazy var calendar = CalendarView(store: store)
    let recorder = RecorderView(frame: .zero)
    let batteries = BatteryRow(frame: .zero)
    let preflight = PreflightView(frame: .zero)
    let cameraPreview = CameraPreview()
    let home = HomeBar(frame: .zero)            // the R2 library, behind the home bar
    let chrome = PassThroughView()              // the edge controls, shared by every surface (added by the app)
    let vault = VaultView(frame: .zero)
    let vaultSheet = NSVisualEffectView()       // the vault opens on this blurred surface over the calendar
    let horizon = HorizonView()
    let leftBar = EdgeBar()                     // recording
    let rightBar = EdgeBar()                    // the vault (and brightness)
    let recorderTray = NSView()                 // the recorder's controls, out of the left bar
    var reminders: [EKReminder] = []
    var remindersAllowed = false
    private var trayWork: DispatchWorkItem?
    private var linking = false
    private var listHoldMonitor: Any?
    var trayPinned = false
    let vaultClose = NSButton()
    let audioSheet = NSVisualEffectView()
    let audioClose = NSButton()
    let recenseOpen = NSButton()
    let recenseSheet = NSView()                 // Recense's viewer, embedded; opened from the audio menu
    let recenseClose = NSButton()
    lazy var recenseWeb: WKWebView = {
        let cfg = WKWebViewConfiguration()
        // Recense's `.drop { display: grid }` beats its own `hidden` attribute, so the drop veil would never go away.
        cfg.userContentController.addUserScript(WKUserScript(source: "document.head.insertAdjacentHTML('beforeend','<style>[hidden]{display:none!important}</style>')", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.appearance = NSAppearance(named: .darkAqua)     // Recense picks its dark tokens from the colour scheme
        v.setValue(false, forKey: "drawsBackground")
        v.underPageBackgroundColor = recenseFill
        return v
    }()
    /// Recense's dark `--bg` (viewer/read-along.html), so the page and Sill's fill are one colour.
    let recenseFill = NSColor(srgbRed: 0x11/255.0, green: 0x16/255.0, blue: 0x15/255.0, alpha: 1)
    static let recenseURL = URL(fileURLWithPath: NSHomeDirectory() + "/Developer/sill/recense/viewer/read-along.html")
    let r2 = R2Tray(frame: .zero)
    private var foldWork: [Int: DispatchWorkItem] = [:]
    var onKeyboard: ((NSView?) -> Void)?
    var onSwipeRight: (() -> Void)?
    private var swipeTravel: CGFloat = 0
    private var swipeArmed = false
    var calendarAllowed = false
    var cached: [EKEvent] = []
    var cachedAt = Date.distantPast
    var hovered: Set<Int> = []
    var hovering: Bool { !hovered.isEmpty }
    var collapseWork: DispatchWorkItem?

    let topZone: CGFloat = 116          // the band at the top that holds the clocks and the weather

    override init(frame: NSRect) {
        local = FoldingClock(clockSpecs[0], size: 26, barWidth: 120, seconds: true)
        left = FoldingClock(clockSpecs[1], size: 15, barWidth: 54)     // the size of an unselected date
        right = FoldingClock(clockSpecs[2], size: 15, barWidth: 54)
        super.init(frame: frame)
        clockFormat.setLocalizedDateFormatFromTemplate("jmm")
        for c in clocks { c.add(to: self) }
        calendar.strip.cellWidth = 46
        calendar.gapBelowStrip = 78
        addSubview(calendar)
        horizon.marks = { [weak self] a, b in self?.horizonMarks(from: a, to: b) ?? [] }
        // The two rails tell one story: reaching into the future on the horizon moves the day strip to that day,
        // and sliding the day strip stretches the horizon's glow to it.
        horizon.onReach = { [weak self] r in
            guard let self = self else { return }
            let cal = Calendar.current
            let day = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: Date().addingTimeInterval(r))).day ?? 0
            self.linking = true
            self.calendar.strip.glide(toOffset: day - cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: self.calendar.strip.anchor).day!)
            self.linking = false
        }
        calendar.onDayChange = { [weak self] d in
            guard let self = self, !self.linking else { return }
            self.horizon.reach(to: d)
        }
        addSubview(horizon)
        // Recorder: the left edge. Click records (with the last sources), click again pauses, double-click stops;
        // rest on it a moment and its controls slide out.
        recorderTray.wantsLayer = true
        // Its own frosted glass, so the event list underneath never shows through the pill.
        let trayGlass = NSVisualEffectView(frame: .zero)
        trayGlass.material = .hudWindow; trayGlass.blendingMode = .withinWindow; trayGlass.state = .active
        trayGlass.appearance = NSAppearance(named: .darkAqua)
        trayGlass.autoresizingMask = [.width, .height]
        recorderTray.addSubview(trayGlass, positioned: .below, relativeTo: nil)
        recorderTray.layer?.masksToBounds = true
        recorderTray.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        recorderTray.layer?.cornerRadius = 18
        recorderTray.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        recorderTray.layer?.borderWidth = 1
        recorderTray.alphaValue = 0
        recorderTray.isHidden = true
        // The audio menu: pressing the left bar opens it the way the vault opens from the right bar, a blurred
        // glass sheet over the calendar with the recorder and its output settings.
        audioSheet.material = .hudWindow
        audioSheet.blendingMode = .withinWindow
        audioSheet.state = .active
        audioSheet.appearance = NSAppearance(named: .darkAqua)
        audioSheet.wantsLayer = true
        audioSheet.layer?.cornerRadius = 18
        audioSheet.layer?.masksToBounds = true
        audioSheet.isHidden = true
        audioSheet.addSubview(recorder)
        audioClose.isBordered = false
        audioClose.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        audioClose.contentTintColor = .white
        audioClose.target = self; audioClose.action = #selector(closeAudio)
        audioSheet.addSubview(audioClose)
        chrome.addSubview(recorderTray)
        recenseOpen.isBordered = false
        recenseOpen.image = recenseIcon()
        recenseOpen.contentTintColor = .white
        recenseOpen.toolTip = "Recense"
        recenseOpen.target = self; recenseOpen.action = #selector(openRecense)
        audioSheet.addSubview(recenseOpen)
        recenseSheet.wantsLayer = true
        recenseSheet.layer?.backgroundColor = recenseFill.cgColor
        recenseSheet.layer?.cornerRadius = 18
        recenseSheet.layer?.masksToBounds = true
        recenseSheet.isHidden = true
        recenseClose.isBordered = false
        recenseClose.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        recenseClose.contentTintColor = .white
        recenseClose.target = self; recenseClose.action = #selector(closeRecense)
        recenseSheet.addSubview(recenseClose)
        chrome.addSubview(recenseSheet)
        leftBar.toolTip = "Audio: click to pin the recorder open · two fingers up / down for volume"
        leftBar.onClick = { [weak self] in
            guard let self = self else { return }
            if !self.recenseSheet.isHidden { self.showRecense(false); return }
            self.showAudio(self.audioSheet.isHidden)
        }
        leftBar.onScrollY = { [weak self] dy in
            if let v = Volume.nudge(Float(dy) * 0.004) { self?.leftBar.fill = CGFloat(v) }
        }
        recorder.onLevel = { [weak self] l in self?.leftBar.level = l }
        chrome.addSubview(leftBar)
        // The vault: the right edge. Click: Touch ID, and the vault opens over the calendar. Two fingers up and
        // down along it change the screen's brightness.
        rightBar.toolTip = "Bitwarden (click) · brightness (two fingers up / down)"
        rightBar.onClick = { [weak self] in self?.toggleVault() }
        rightBar.onScrollY = { [weak self] dy in
            if let b = Brightness.nudge(Float(dy) * 0.004) { self?.rightBar.fill = CGFloat(b) }
        }
        chrome.addSubview(rightBar)
        vaultSheet.material = .hudWindow
        vaultSheet.blendingMode = .withinWindow
        vaultSheet.state = .active
        vaultSheet.appearance = NSAppearance(named: .darkAqua)
        vaultSheet.wantsLayer = true
        vaultSheet.layer?.cornerRadius = 18
        vaultSheet.layer?.masksToBounds = true
        vaultSheet.isHidden = true
        vaultSheet.addSubview(vault)
        vaultClose.isBordered = false
        vaultClose.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close the vault")
        vaultClose.contentTintColor = .white
        vaultClose.toolTip = "Lock and close"
        vaultClose.target = self; vaultClose.action = #selector(closeVault)
        vaultSheet.addSubview(vaultClose)
        chrome.addSubview(vaultSheet)
        r2.isHidden = true
        chrome.addSubview(r2)
        home.onPress = { [weak self] in self?.toggleR2() }
        r2.onClose = { [weak self] in self?.toggleR2() }
        vault.onDenied = { [weak self] canceled in self?.showVault(false) }
        vault.onClosed = { [weak self] in self?.showVault(false) }
        chrome.addSubview(home)
        preflight.isHidden = true
        audioSheet.addSubview(preflight)
        preflight.staysOpen = true
        chrome.addSubview(audioSheet)
        recorder.onOpenSettings = { [weak self] in self?.openPreflight() }
        preflight.onClose = { [weak self] in self?.showAudio(false) }
        preflight.onCamera = { [weak self] on in
            guard let self = self, let win = self.window else { return }
            if on { self.cameraPreview.show(cameraID: self.preflight.choice.cameraID,
                                             beside: win.convertToScreen(self.preflight.convert(self.preflight.bounds, to: nil))) }
            else { self.cameraPreview.hide() }
        }
        preflight.onStart = { [weak self] c in self?.closePreflight(); self?.recorder.begin(c) }
        vault.onKeyboard = { [weak self] v in self?.onKeyboard?(v) }

        layoutContent()
        refresh()
        // Two fingers on the event list hold the horizon where you reached until you lift them.
        listHoldMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self = self, !self.isHidden, e.window === self.window else { return e }
            let p = self.calendar.list.convert(e.locationInWindow, from: nil)
            let over = self.calendar.list.bounds.contains(p)
            if over && (e.phase == .mayBegin || e.phase == .began || e.phase == .changed) { self.horizon.hold(true) }
            if e.phase == .ended || e.phase == .cancelled || (!e.momentumPhase.isEmpty && e.momentumPhase == .ended) {
                if e.momentumPhase.isEmpty || e.momentumPhase == .ended { self.horizon.hold(false) }
            }
            return e
        }

        NotificationCenter.default.addObserver(self, selector: #selector(calendarChanged),
                                               name: .EKEventStoreChanged, object: store)
        requestCalendar()
        fetchWeather()
        Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.fetchWeather() }
    }
    required init?(coder: NSCoder) { fatalError() }

    // The chrome is sized by the card (autoresizing), not by this view: this view slides during a pull, the edge
    // controls must not slide with it.
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layoutContent() }

    func layoutContent() {
        let w = bounds.width, top = bounds.height
        // The three clocks: local on top, Vietnam and Eastern drawn in close under it.
        local.place(at: NSPoint(x: w / 2, y: top - 32))
        left.place(at: NSPoint(x: w / 2 - 74, y: top - 70))
        right.place(at: NSPoint(x: w / 2 + 74, y: top - 70))
        // The calendar (day strip, then the day's events) with the horizon in the gap under the strip.
        let side: CGFloat = 40
        calendar.frame = NSRect(x: side, y: 16, width: w - 2 * side, height: max(0, top - 102 - 16))
        horizon.frame = NSRect(x: side + 10, y: calendar.frame.maxY - calendar.stripHeight - 74, width: w - 2 * side - 20, height: 66)
        leftBar.frame = NSRect(x: 6, y: top / 2 - 80, width: 20, height: 130)
        rightBar.frame = NSRect(x: w - 26, y: top / 2 - 80, width: 20, height: 130)
        // The recorder pill sits in the bottom-left corner, clear of the horizon, its labels and the event titles.
        recorderTray.frame = NSRect(x: 30, y: 12, width: 220, height: 36)
        recorderTray.subviews.first { $0 is NSVisualEffectView }?.frame = recorderTray.bounds
        recorder.frame = NSRect(x: 10, y: 1, width: 204, height: 34)
        vaultSheet.frame = NSRect(x: 28, y: 44, width: w - 56, height: top - 44 - 96)
        vault.frame = NSRect(x: 16, y: 6, width: vaultSheet.frame.width - 50, height: vaultSheet.frame.height - 10)
        vaultClose.frame = NSRect(x: vaultSheet.frame.width - 30, y: vaultSheet.frame.height - 30, width: 20, height: 20)
        audioSheet.frame = vaultSheet.frame
        let aw = audioSheet.frame.width, ah = audioSheet.frame.height
        audioClose.frame = NSRect(x: aw - 30, y: ah - 30, width: 20, height: 20)
        recenseOpen.frame = NSRect(x: aw - 56, y: ah - 30, width: 20, height: 20)
        // The page fills the whole surface in Recense's colour; the viewer itself sits where the vault would.
        recenseSheet.frame = bounds
        let rv = vaultSheet.frame
        recenseClose.frame = NSRect(x: rv.maxX - 30, y: rv.maxY - 30, width: 20, height: 20)
        recenseWeb.frame = NSRect(x: rv.minX, y: rv.minY, width: rv.width, height: rv.height - 36)
        recorder.frame = NSRect(x: 16, y: ah - 46, width: aw - 60, height: 36)
        r2.frame = NSRect(x: 40, y: 30, width: w - 80, height: top - 130)
        home.frame = NSRect(x: 0, y: 2, width: w, height: 44)
        preflight.frame = NSRect(x: 10, y: 8, width: aw - 20, height: min(200, ah - 58))
        batteries.frame = .zero
        updateTrackingAreas()
    }

    // MARK: Edges

    @objc func closeAudio() { showAudio(false) }
    @objc func openRecense() { showRecense(true) }
    @objc func closeRecense() { showRecense(false) }

    /// Recense as its own page, opened from the left bar's menu the way the right bar opens the vault.
    func showRecense(_ on: Bool) {
        leftBar.active = on || recorder.state == .recording || recorder.state == .paused
        if on {
            if !audioSheet.isHidden { showAudio(false) }
            if recenseWeb.superview == nil {
                recenseSheet.addSubview(recenseWeb, positioned: .below, relativeTo: recenseClose)
                let rv = vaultSheet.frame
                recenseWeb.frame = NSRect(x: rv.minX, y: rv.minY, width: rv.width, height: rv.height - 36)
                // Read as UTF-8 ourselves: the page declares no charset, and WebKit would guess Latin-1.
                let u = Self.recenseURL
                if let html = try? String(contentsOf: u, encoding: .utf8) {
                    recenseWeb.loadHTMLString(html, baseURL: u.deletingLastPathComponent())
                }
            }
            recenseSheet.isHidden = false
            recenseSheet.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                recenseSheet.animator().alphaValue = 1
                calendar.animator().alphaValue = 0.15
                horizon.animator().alphaValue = 0.15
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                recenseSheet.animator().alphaValue = 0
                calendar.animator().alphaValue = 1
                horizon.animator().alphaValue = 1
            }, completionHandler: { [weak self] in if self?.recenseSheet.alphaValue ?? 1 < 0.01 { self?.recenseSheet.isHidden = true } })
        }
    }

    /// The audio menu, mirroring the vault: fades in over a dimmed calendar; ✕ or the left bar closes it.
    func showAudio(_ on: Bool) {
        trayPinned = on
        leftBar.active = on || recorder.state == .recording || recorder.state == .paused
        if on {
            if !vaultSheet.isHidden { showVault(false); if vault.unlocked { vault.lock() } }
            audioSheet.isHidden = false
            audioSheet.alphaValue = 0
            openPreflight()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                audioSheet.animator().alphaValue = 1
                calendar.animator().alphaValue = 0.15
                horizon.animator().alphaValue = 0.15
            }
        } else {
            if !preflight.isHidden { closePreflight() }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                audioSheet.animator().alphaValue = 0
                calendar.animator().alphaValue = 1
                horizon.animator().alphaValue = 1
            }, completionHandler: { [weak self] in if self?.audioSheet.alphaValue ?? 1 < 0.01 { self?.audioSheet.isHidden = true } })
        }
    }

    func showRecorderTray(_ on: Bool) {
        recorderTray.isHidden = true                      // retired: the recorder lives in the audio menu now
        if true { return }
        trayWork?.cancel()
        if on || trayPinned {
            leftBar.active = trayPinned || recorder.state == .recording || recorder.state == .paused
            recorderTray.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.25; recorderTray.animator().alphaValue = 1 }
            return
        }
        // Leave it out while the pointer is on it; fold it back once the pointer is gone from both.
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, let win = self.window, !self.trayPinned else { return }
            let p = self.convert(win.mouseLocationOutsideOfEventStream, from: nil)
            if self.recorderTray.frame.insetBy(dx: -8, dy: -8).contains(p) || self.leftBar.frame.contains(p) || !self.preflight.isHidden {
                self.showRecorderTray(false); return
            }
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.2; self.recorderTray.animator().alphaValue = 0 },
                                                completionHandler: { if self.recorderTray.alphaValue < 0.01 { self.recorderTray.isHidden = true } })
        }
        trayWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    @objc func closeVault() { if vault.unlocked { vault.lock() } else { showVault(false) } }

    func toggleR2() {
        let show = r2.isHidden
        if show { r2.reload(); r2.isHidden = false; r2.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            r2.animator().alphaValue = show ? 1 : 0
            calendar.animator().alphaValue = show ? 0.15 : 1
            horizon.animator().alphaValue = show ? 0.15 : 1
        }, completionHandler: { [weak self] in if !show { self?.r2.isHidden = true } })
    }

    func toggleVault() {
        if !vaultSheet.isHidden {
            if vault.unlocked { vault.lock() } else { showVault(false) }
            return
        }
        showVault(true)
        vault.beginUnlock()
    }

    func showVault(_ on: Bool) {
        rightBar.active = on
        if on {
            vaultSheet.isHidden = false
            vaultSheet.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                vaultSheet.animator().alphaValue = 1
                calendar.animator().alphaValue = 0.15
                horizon.animator().alphaValue = 0.15
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                vaultSheet.animator().alphaValue = 0
                calendar.animator().alphaValue = 1
                horizon.animator().alphaValue = 1
            }, completionHandler: { [weak self] in if self?.vaultSheet.alphaValue ?? 1 < 0.01 { self?.vaultSheet.isHidden = true } })
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        for (i, c) in clocks.enumerated() {
            addTrackingArea(NSTrackingArea(rect: c.hoverRect, options: [.mouseEnteredAndExited, .activeAlways],
                                           owner: self, userInfo: ["clock": i]))
        }
        super.updateTrackingAreas()
    }

    /// Clicks on the clocks open the pad; the calendar handles its own clicks.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Only the clocks open the pad; everything else on the card is its own control.
        guard p.y > bounds.height - 92, preflight.isHidden, vaultSheet.isHidden, audioSheet.isHidden else { return }
        super.mouseDown(with: event)
    }


    /// The pre-flight card rises over the calendar from the recorder with a spring.
    func openPreflight() {
        guard preflight.isHidden else { return }
        preflight.choice = recorder.choice
        audioSheet.addSubview(preflight)           // inside the audio menu
        preflight.isHidden = false
        preflight.open()
        guard let l = preflight.layer else { return }
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.85; spring.toValue = 1; spring.stiffness = 260; spring.damping = 20
        spring.duration = spring.settlingDuration
        l.add(spring, forKey: "pop")
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.15
        l.add(fade, forKey: "fade")
    }

    func closePreflight() {
        preflight.shutDown()
        preflight.isHidden = true
        cameraPreview.hide()           // the mirror is for checking yourself before recording; recording takes the camera
    }

    /// Two fingers to the right, anywhere that isn't the day strip or the vault, opens the terminal panel.
    /// Whether a sideways swipe at this point belongs to the panel row (not to the day strip, the horizon, or an
    /// open vault / R2 sheet, which use sideways swipes or need the pointer themselves).
    func panelSwipeZone(_ windowPoint: NSPoint) -> Bool {
        let p = convert(windowPoint, from: nil)
        let stripFrame = calendar.convert(calendar.strip.frame, to: self)
        return bounds.contains(p) && !stripFrame.insetBy(dx: 0, dy: -6).contains(p) && !horizon.frame.contains(p)
            && vaultSheet.isHidden && r2.isHidden && audioSheet.isHidden
    }

    private var swipeMonitor: Any?
    func watchSwipes() {
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self = self, !self.isHidden, e.window === self.window else { return e }
            let p = self.convert(e.locationInWindow, from: nil)
            let stripFrame = self.calendar.convert(self.calendar.strip.frame, to: self)
            guard self.bounds.contains(p), !stripFrame.insetBy(dx: 0, dy: -6).contains(p),
                  !self.horizon.frame.contains(p), self.vaultSheet.isHidden, self.r2.isHidden else { return e }
            if e.phase == .began || e.phase == .mayBegin { self.swipeTravel = 0; self.swipeArmed = true }
            guard e.hasPreciseScrollingDeltas, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return e }
            guard e.momentumPhase.isEmpty, self.swipeArmed else { return nil }
            self.swipeTravel += e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
            if self.swipeTravel > 70 { self.swipeTravel = 0; self.swipeArmed = false; self.onSwipeRight?() }
            return nil
        }
    }

    override func scrollWheel(with e: NSEvent) {
        if swipeMonitor != nil { return }                      // the monitor handles panel swipes
        // A new gesture re-arms first: its opening event is often tiny or vertical, so this can't wait for the
        // horizontal check (waiting for it is what made every swipe dead).
        if e.phase == .began || e.phase == .mayBegin { swipeTravel = 0; swipeArmed = true }
        guard e.hasPreciseScrollingDeltas, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return }
        guard e.momentumPhase.isEmpty, swipeArmed else { return }
        swipeTravel += e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        // One swipe moves one panel: once it fires, the rest of that gesture is ignored.
        if swipeTravel > 70 { swipeTravel = 0; swipeArmed = false; onSwipeRight?() }   // fingers left → right: the next panel
    }

    // MARK: Clocks ⇄ bars

    /// Called each time the panel shows this surface.
    /// The time shows first (local with seconds), then after a pause melts into the bars and stays that way
    /// until you hover a bar or open the panel again.
    func surfaced() {
        refresh()
        calendar.resetToToday()
        horizon.reload()
        horizon.reset()
        reveal()
        // All three show, then each sinks into its own line at its own moment.
        for (i, delay) in [timeVisibleFor, timeVisibleFor + 0.8, timeVisibleFor + 1.6].enumerated() { scheduleFold(i, after: delay) }
    }

    func reveal(_ only: Int? = nil) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            for (i, c) in clocks.enumerated() where only == nil || only == i { foldWork[i]?.cancel(); c.unfold() }
        }
    }

    func fold(_ i: Int) {
        guard !hovered.contains(i) else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clocks[i].fold()
        }
    }

    func scheduleFold(_ i: Int, after delay: TimeInterval) {
        foldWork[i]?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.fold(i) }
        foldWork[i] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func collapse() { for i in clocks.indices { fold(i) } }

    // Hover a line: that clock rises on its own. Stay on its number a moment: its weather.
    override func mouseEntered(with event: NSEvent) {
        guard let i = event.trackingArea?.userInfo?["clock"] as? Int else { return }
        hovered.insert(i)
        reveal(i)
        clocks[i].showWeather()
    }

    override func mouseExited(with event: NSEvent) {
        guard let i = event.trackingArea?.userInfo?["clock"] as? Int else { return }
        hovered.remove(i)
        clocks[i].hideWeather()
        scheduleFold(i, after: 0.7)
    }

    // MARK: Content

    @objc func calendarChanged() {
        DispatchQueue.main.async { self.cachedAt = .distantPast; self.refresh(); self.calendar.reload() }
    }

    /// Called every second by the app; cheap when nothing changed.
    func refresh() {
        let now = Date()
        clocks.forEach { $0.tick(now) }
        recorder.tick()
        if calendarAllowed && now.timeIntervalSince(cachedAt) > 60 { cached = nextEvents(); cachedAt = now }
        let upcoming = cached.filter { $0.startDate > now }
        let color = barColor(for: upcoming.first).cgColor
        if local.bar.layer?.backgroundColor != color { local.bar.layer?.backgroundColor = color }
        let leftOn = trayPinned || recorder.state == .recording || recorder.state == .paused
        if leftBar.active != leftOn { leftBar.active = leftOn }
        let rightOn = !vaultSheet.isHidden
        if rightBar.active != rightOn { rightBar.active = rightOn }
        if Int(now.timeIntervalSince1970) % 30 == 0 { horizon.needsDisplay = true; fetchReminders() }
    }

    /// One blue, brighter the closer the next event: faint with nothing near, full inside the hour.
    func barColor(for next: EKEvent?) -> NSColor {
        guard let start = next?.startDate else { return NSColor.white.withAlphaComponent(0.5) }
        let left = start.timeIntervalSinceNow
        if left <= redWithin { return calmBlue.blended(withFraction: 0.3, of: bioCyan) ?? calmBlue }
        if left <= yellowWithin { return calmBlue }
        return calmBlue.withAlphaComponent(0.55)
    }

    /// What sits on the horizon: Calendar events (timed ones, and all-day ones at their start) and reminders with a
    /// due time. Alarmed ones glow.
    func horizonMarks(from a: Date, to b: Date) -> [HorizonMark] {
        var out: [HorizonMark] = []
        if calendarAllowed {
            // A repeating event (a weekly "Vietnam") shows once, at its next occurrence, not on every week.
            var seenSeries = Set<String>()
            let evs = store.events(matching: store.predicateForEvents(withStart: a, end: b, calendars: nil)).sorted { $0.startDate < $1.startDate }
            for e in evs where e.startDate > a {
                if e.hasRecurrenceRules {
                    let key = e.calendarItemIdentifier
                    if seenSeries.contains(key) { continue }
                    seenSeries.insert(key)
                }
                out.append(HorizonMark(date: e.startDate, title: e.title ?? "", alarmed: !(e.alarms ?? []).isEmpty))
            }
        }
        for r in reminders {
            guard let d = r.dueDateComponents?.date, d > a, d <= b else { continue }
            out.append(HorizonMark(date: d, title: r.title ?? "", alarmed: !(r.alarms ?? []).isEmpty))
        }
        return out
    }

    func fetchReminders() {
        guard remindersAllowed else { return }
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: Date(), ending: Date().addingTimeInterval(400 * 86400), calendars: nil)
        store.fetchReminders(matching: pred) { [weak self] rs in
            DispatchQueue.main.async { self?.reminders = rs ?? []; self?.horizon.reload() }
        }
    }

    /// Timed events starting in the next 24 hours, soonest first.
    func nextEvents() -> [EKEvent] {
        let now = Date()
        let pred = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(24 * 3600), calendars: nil)
        return store.events(matching: pred)
            .filter { !$0.isAllDay && $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
    }

    func requestCalendar() {
        let done: (Bool, Error?) -> Void = { [weak self] ok, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                NSLog("sill: Calendar access \(ok ? "granted" : "not granted")")
                self.calendarAllowed = ok; self.calendar.allowed = ok
                self.cachedAt = .distantPast; self.refresh(); self.calendar.reload(); self.horizon.reload()
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: done)
            store.requestFullAccessToReminders { [weak self] ok, _ in
                DispatchQueue.main.async { self?.remindersAllowed = ok; self?.fetchReminders() }
            }
        } else {
            store.requestAccess(to: .event, completion: done)
        }
    }

    // MARK: Weather

    func fetchWeather() {
        guard weatherEnabled else { return }
        let lats = clockSpecs.map { "\($0.lat)" }.joined(separator: ",")
        let lons = clockSpecs.map { "\($0.lon)" }.joined(separator: ",")
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lats)&longitude=\(lons)"
                      + "&current=temperature_2m,weather_code&temperature_unit=fahrenheit")!
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            let texts: [String?] = list.map { place in
                guard let cur = place["current"] as? [String: Any],
                      let temp = cur["temperature_2m"] as? Double else { return nil }
                let code = (cur["weather_code"] as? Int) ?? -1
                return "\(Int(temp.rounded()))°F  ·  \(EssentialsView.describe(code))"
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                for (c, t) in zip(self.clocks, texts) {
                    if let t = t { c.weatherText = t; c.weather.stringValue = t }
                }
            }
        }.resume()
    }

    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67: return "Rain"
        case 71...77: return "Snow"
        case 80...82: return "Showers"
        case 85, 86: return "Snow showers"
        case 95...99: return "Thunderstorm"
        default: return "—"
        }
    }
}

// MARK: - At rest: the strip in the menu bar
//
// When the panel is closed, Sill is a strip lying over the menu bar: exactly the menu bar's height, 720 pt wide,
// centered, the menu bar's own color (nothing drawn), letting clicks through. At its two ends, like menu-bar items,
// sit the next event in the coming three days: a blue calendar mark on the left, the time to go on the right (15m,
// 3h, 1d; it takes the urgency color once the event's own Calendar alert time arrives). Hovering it (no gesture)
// grows a band a shade darker than the menu bar out from the center to the full width, only sideways, never taller;
// its content (weather, the event) starts blurred and comes into focus as it lands.
// The panel grows out of this strip and sinks back into it.

let restWidth: CGFloat = 720

/// Compact time until something: 15m, 3h, 2d, 2w, 1mo. ("mo" rather than "m" for months, so it can't be read as minutes.)
func compactInterval(_ t: TimeInterval) -> String {
    let m = Int((t / 60).rounded(.up))
    if m < 60 { return "\(max(m, 1))m" }
    let h = m / 60
    if h < 24 { return "\(h)h" }
    let d = h / 24
    if d < 14 { return "\(d)d" }
    if d < 30 { return "\(d / 7)w" }
    return "\(d / 30)mo"
}

func urgencyColor(_ untilStart: TimeInterval) -> NSColor {
    if untilStart <= redWithin { return .systemRed }
    if untilStart <= yellowWithin { return .systemYellow }
    return .systemGreen
}

/// The hover band, cut to the same outline as the panel: full width where it meets the menu bar, its two ends curving
/// inward and down (concave), then rounding off at the bottom. The outline is recomputed at every width, so it holds
/// its shape the whole time the band grows.
final class ContouredBand: NSView {
    let shape = CAShapeLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.mask = shape
    }
    required init?(coder: NSCoder) { fatalError() }
    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.frame = bounds
        let ear = min(cardEar, bounds.height * 0.6, bounds.width / 4)     // the same flare as the panel
        shape.path = bounds.width > 2 ? contouredCard(bounds, ear: ear, radius: min(ear, bounds.height - ear)) : nil
        CATransaction.commit()
    }
}

final class RestStrip: NSObject {
    let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let band = ContouredBand(frame: .zero)    // the hover extension: a shade darker than the menu bar, its exact height
    let content = NSView()                    // what the band reveals (blurred while it grows, sharp once it lands)
    let weather = NSTextField(labelWithString: "")
    let eventLine = NSTextField(labelWithString: "")
    let icon = NSImageView(image: NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)!)
    let countdown = NSTextField(labelWithString: "")
    let battery = NSTextField(labelWithString: "")
    let pause = GlassPauseButton()
    let sideQuest = GlassPauseButton()
    let space = GlassPauseButton()
    let spaceBack = GlassPauseButton()
    let spaceNext = GlassPauseButton()
    private var batteryText = ""
    private var batteryAt = Date.distantPast
    let store: EKEventStore
    var allowed: () -> Bool
    var weatherText: () -> String = { "" }
    var next: EKEvent?
    var checkedAt = Date.distantPast
    private(set) var expanded = false
    private let bandInset: CGFloat = 34
    private var bandTimer: Timer?
    private var monitors: [Any] = []
    private var shown = false

    init(store: EKEventStore, allowed: @escaping () -> Bool) {
        self.store = store
        self.allowed = allowed
        super.init()
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true          // the menu bar underneath keeps working
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSView()
        window.contentView = root
        band.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        content.wantsLayer = true
        content.layerUsesCoreImageFilters = true
        for l in [weather, eventLine, countdown] {
            l.font = .systemFont(ofSize: 12, weight: .semibold); l.textColor = .white; l.lineBreakMode = .byTruncatingTail
        }
        eventLine.alignment = .left
        countdown.alignment = .right
        countdown.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        icon.isHidden = true
        battery.font = roundedFont(11, .semibold)
        battery.textColor = NSColor(srgbRed: 0.42, green: 0.92, blue: 0.52, alpha: 1)     // batteries in green
        pause.isBordered = false
        pause.title = ""
        pause.toolTip = "Pause whatever is playing"
        pause.target = self; pause.action = #selector(playPause)
        sideQuest.symbol = "sparkles"; sideQuest.isBordered = false; sideQuest.title = ""
        sideQuest.toolTip = "New Side Quest: say it, check it, it goes into Calendar"
        sideQuest.target = self; sideQuest.action = #selector(runSideQuest)
        space.symbol = "square.grid.3x2"; space.isBordered = false; space.title = ""
        space.toolTip = "Mission Control"
        space.target = self; space.action = #selector(missionControl)
        for (b, sym, tip, sel) in [(spaceBack, "chevron.left", "Previous desktop", #selector(prevSpace)),
                                   (spaceNext, "chevron.right", "Next desktop", #selector(nextSpace))] {
            b.symbol = sym; b.isBordered = false; b.title = ""; b.toolTip = tip
            b.target = self; b.action = sel
        }
        eventLine.alignment = .right
        // Everything the strip carries lives in `content`, so at rest (asleep) nothing shows in the menu bar.
        [weather, eventLine, icon, countdown, battery, sideQuest, pause, spaceBack, space, spaceNext].forEach(content.addSubview)
        [band, content].forEach(root.addSubview)
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.checkedAt = .distantPast
        }
    }

    /// Wake (full context) or go back to sleep. Driven by the spatial controller. Clicks always pass through.
    func wake(_ on: Bool) {
        guard on != expanded else { return }
        expanded = on
        window.ignoresMouseEvents = !on          // awake, its pause button takes clicks; asleep, everything passes through
        setBand(open: on, animated: true)
    }

    @objc func playPause() { pressPlayPause(); pause.showsPlay.toggle(); pause.bounce() }
    /// New Side Quest, rebuilt: speak an entry, check the draft, it goes straight into Apple Calendar.
    lazy var voice: VoiceEntry = {
        let v = VoiceEntry(store: store)
        v.anchor = { [weak self] in self?.window.frame ?? .zero }
        v.onListening = { [weak self] on in
            self?.sideQuest.symbol = on ? "waveform" : "sparkles"
            self?.sideQuest.needsDisplay = true
        }
        return v
    }()
    @objc func runSideQuest() {
        sideQuest.bounce()
        voice.toggle()
    }
    @objc func missionControl() {
        space.bounce()
        // Mission Control itself (the same as its keyboard shortcut or the Mission Control app).
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
    }
    @objc func prevSpace() { spaceBack.bounce(); switchSpace(-1) }
    @objc func nextSpace() { spaceNext.bounce(); switchSpace(1) }

    static func menuBarHeight(_ s: NSScreen) -> CGFloat {
        let h = s.frame.maxY - s.visibleFrame.maxY
        return h > 0 ? h : NSStatusBar.system.thickness
    }

    static func frame(on s: NSScreen) -> NSRect {
        let h = menuBarHeight(s)
        return NSRect(x: (s.frame.midX - restWidth / 2).rounded(), y: s.frame.maxY - h, width: restWidth, height: h)
    }

    func place(on screen: NSScreen?) {
        guard let s = screen ?? NSScreen.main else { return }
        window.setFrame(RestStrip.frame(on: s), display: true)
        layoutStatic()
        setBand(open: expanded, animated: false)
    }

    func findNext() -> EKEvent? {
        guard allowed() else { return nil }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(3 * 24 * 3600), calendars: nil)
        return store.events(matching: pred).filter { $0.startDate > now }.min { $0.startDate < $1.startDate }
    }

    func alerting(_ e: EKEvent, _ now: Date) -> Bool {
        (e.alarms ?? []).contains { a in (a.absoluteDate ?? e.startDate.addingTimeInterval(a.relativeOffset)) <= now }
    }


    /// The resting pieces sit at the strip's two ends, like menu-bar items: the calendar mark left, time to go right.
    private func layoutStatic() {
        guard let b = window.contentView?.bounds else { return }
        // Awake: batteries at the left end, one play/pause in the middle, the next thing at the right end.
        content.frame = b
        weather.frame = .zero
        icon.frame = .zero
        battery.frame = NSRect(x: bandInset + 18, y: (b.height - 15) / 2, width: b.midX - 50 - bandInset - 18, height: 15)
        pause.frame = NSRect(x: b.midX - 10, y: (b.height - 20) / 2, width: 20, height: 20)
        sideQuest.frame = NSRect(x: b.midX - 40, y: (b.height - 20) / 2, width: 20, height: 20)
        // Desktops: back, new, forward.
        spaceBack.frame = NSRect(x: b.midX + 22, y: (b.height - 18) / 2, width: 18, height: 18)
        space.frame = NSRect(x: b.midX + 42, y: (b.height - 20) / 2, width: 20, height: 20)
        spaceNext.frame = NSRect(x: b.midX + 64, y: (b.height - 18) / 2, width: 18, height: 18)
        countdown.frame = NSRect(x: b.width - bandInset - 18 - 100, y: (b.height - 14) / 2, width: 100, height: 14)
        eventLine.frame = NSRect(x: b.midX + 90, y: (b.height - 15) / 2, width: b.width - bandInset - 18 - 106 - b.midX - 90, height: 15)
    }

    /// Hover: the darker band grows out from the center to the strip's full width (only sideways: its height is
    /// always the menu bar's). What it carries starts blurred and comes into focus as the band lands.
    func setBand(open: Bool, animated: Bool) {
        guard let b = window.contentView?.bounds else { return }
        let w = open ? b.width - 2 * bandInset : 0     // the calendar mark and countdown stay just outside its ends
        let target = NSRect(x: ((b.width - w) / 2).rounded(), y: 0, width: w, height: b.height)
        if !animated {
            band.frame = target
            content.alphaValue = open ? 1 : 0
            content.layer?.filters = []
            return
        }
        if open && band.frame.width == 0 { band.frame = NSRect(x: b.midX, y: 0, width: 0, height: b.height) }
        // Step the width ourselves (rather than a layer animation) so the contoured ends are redrawn at every size.
        bandTimer?.invalidate()
        let from = band.frame, start = Date(), duration: TimeInterval = open ? 0.38 : 0.26
        bandTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let p = min(1, Date().timeIntervalSince(start) / duration)
            let e = 1 - pow(1 - p, 3)                                         // ease out
            let w = from.width + (target.width - from.width) * e
            self.band.frame = NSRect(x: ((b.width - w) / 2).rounded(), y: 0, width: w, height: b.height)
            if p >= 1 { t.invalidate() }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            content.animator().alphaValue = open ? 1 : 0
        }
        // Blur → focus.
        guard let l = content.layer, let f = CIFilter(name: "CIGaussianBlur") else { return }
        f.name = "blur"
        f.setValue(0, forKey: kCIInputRadiusKey)
        l.filters = [f]
        let a = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        a.fromValue = open ? 7 : 0; a.toValue = open ? 0 : 7
        a.duration = open ? 0.42 : 0.2
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.add(a, forKey: "focus")
    }

    func refresh(visible: Bool) {
        let now = Date()
        let interval: TimeInterval = next == nil ? 5 : 30
        if now.timeIntervalSince(checkedAt) > interval { next = findNext(); checkedAt = now }
        if let e = next, e.startDate <= now { next = findNext(); checkedAt = now }
        shown = visible
        guard visible else {
            if window.isVisible { window.orderOut(nil); expanded = false; setBand(open: false, animated: false) }
            return
        }
        weather.stringValue = ""
        if now.timeIntervalSince(batteryAt) > 120 {
            batteryAt = now
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let text = readBatteries().map { $0.name == "Mac" ? "\($0.percent)%" : "\($0.name) \($0.percent)%" }.joined(separator: "   ")
                DispatchQueue.main.async { self?.batteryText = text; self?.battery.stringValue = text }
            }
        }
        if let e = next {
            let left = e.startDate.timeIntervalSince(now)
            // World-clock style: the event, then which day and how far ahead ("Tomorrow, +18 HRS").
            countdown.stringValue = worldClockAhead(e.startDate, now: now)
            countdown.font = roundedFont(10, .semibold)
            // One blue for what counts: the ahead-label turns blue once it's within 6 hours (or its alert came).
            let near = alerting(e, now) || left <= yellowWithin
            countdown.textColor = .white
            _ = near
            eventLine.textColor = .white
            eventLine.stringValue = e.title ?? ""
            countdown.isHidden = false
        } else {
            countdown.isHidden = true; eventLine.stringValue = ""
        }
        if !window.isVisible { window.orderFrontRegardless(); layoutStatic(); setBand(open: false, animated: false) }
    }
}

// MARK: - Essentials panels: the DEVONthink hub and the notebook
//
// The essentials layer is a row of panels you move through with two fingers, left → right: essentials, then the
// DEVONthink hub, then the notebook (your Obsidian vault with the Claude CLI). Right → left goes back. Essentials is
// the start of the row; nothing comes before it.

let devonID = "com.devon-technologies.think"

/// Talks to DEVONthink through AppleScript (osascript, off the main thread). It never launches DEVONthink on its own:
/// if it isn't running, the hub offers to open it.
enum Devon {
    struct Rec { let name: String; let uuid: String; let kind: String; let db: String }
    static var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: devonID).isEmpty }

    static func script(_ body: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", body]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: d, encoding: .utf8) : nil
    }

    static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    /// Where a listing comes from: every open database, one database's top level, one group, or a search.
    enum Source { case databases, database(String), group(String), search(String) }

    static func records(_ src: Source) -> [Rec]? {
        let list: String
        switch src {
        case .databases: list = "databases"
        case .database(let id): list = "children of root of (first database whose uuid is \(quote(id)))"
        case .group(let id): list = "children of (get record with uuid \(quote(id)))"
        case .search(let q): list = "search \(quote(q))"
        }
        let row: String
        if case .databases = src {
            row = "set out to out & (name of r) & T & (uuid of r) & T & \"database\" & T & (name of r) & LF"
        } else {
            row = """
                set nm to name of r
                if not ((nm is "Trash" or nm is "Tags") and (type of r as string) is "group") then
                    set out to out & nm & T & (uuid of r) & T & (type of r as string) & T & (name of database of r) & LF
                end if
            """
        }
        // Inside DEVONthink's dictionary "tab" means a browser tab, not a tab character, so the separator is
        // spelled out before the tell block.
        let body = """
        set T to character id 9
        set LF to character id 10
        tell application id "\(devonID)"
            set out to ""
            set n to 0
            repeat with r in (\(list))
                set n to n + 1
                if n > 60 then exit repeat
                \(row)
            end repeat
            return out
        end tell
        """
        guard let out = script(body) else { return nil }
        return out.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\t")
            return f.count >= 4 ? Rec(name: f[0], uuid: f[1], kind: f[2], db: f[3]) : nil
        }
    }

    /// Imports into a group (by uuid), a database's top level, or (neither) the Global Inbox.
    static func importFiles(_ urls: [URL], group: String? = nil, database: String? = nil) -> Bool {
        let target = group.map { "(get record with uuid \(quote($0)))" }
            ?? database.map { "root of (first database whose uuid is \(quote($0)))" }
            ?? "incoming group of inbox"
        let lines = urls.map { "import \(quote($0.path)) to \(target)" }.joined(separator: "\n")
        return script("tell application id \"\(devonID)\"\n\(lines)\nend tell") != nil
    }
}

/// Glass rows used by the hub (name, a quiet second line on the right).
final class HubRow: NSView {
    var onOpen: (() -> Void)?
    init(_ title: String, _ detail: String, symbol: String, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        wantsLayer = true
        layer?.cornerRadius = 8
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = calmBlue
        icon.frame = NSRect(x: 8, y: 5, width: 16, height: 16)
        let name = NSTextField(labelWithString: title)
        name.font = roundedFont(12.5, .semibold); name.textColor = .white; name.lineBreakMode = .byTruncatingMiddle
        name.frame = NSRect(x: 30, y: 5, width: width - 180, height: 17)
        let meta = NSTextField(labelWithString: detail)
        meta.font = roundedFont(11, .medium); meta.textColor = .white; meta.alignment = .right; meta.lineBreakMode = .byTruncatingTail
        meta.frame = NSRect(x: width - 146, y: 5, width: 138, height: 16)
        [icon, name, meta].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor }
    override func mouseExited(with e: NSEvent) { layer?.backgroundColor = nil }
    override func mouseDown(with e: NSEvent) { onOpen?() }
}

/// Two fingers across a panel move along the row of essentials panels. (Horizontal only; vertical scrolls the panel.)
class SwipePanel: NSView {
    var onNext: (() -> Void)?            // fingers left → right
    var onBack: (() -> Void)?            // fingers right → left
    private var travel: CGFloat = 0
    private var armed = false
    private var monitor: Any?
    /// Watches Sill's own scroll events over this panel (so it works over text fields and terminals too).
    func watchSwipes() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self = self, !self.isHidden, e.window === self.window,
                  self.bounds.contains(self.convert(e.locationInWindow, from: nil)) else { return e }
            if e.phase == .began || e.phase == .mayBegin { self.travel = 0; self.armed = true }
            guard e.hasPreciseScrollingDeltas, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return e }
            // One swipe moves one panel; a gesture that began on the previous panel doesn't carry over.
            guard e.momentumPhase.isEmpty, self.armed else { return nil }
            self.travel += e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
            if self.travel > 70 { self.travel = 0; self.armed = false; self.onNext?() }
            else if self.travel < -70 { self.travel = 0; self.armed = false; self.onBack?() }
            return nil
        }
    }
}

/// DEVONthink hub: search everything in DEVONthink, see the Global Inbox, drop files to import them into it.
/// Click a result to open it in DEVONthink.
final class DevonHub: SwipePanel, NSTextFieldDelegate {
    let title = NSTextField(labelWithString: "DEVONthink")
    let hint = NSTextField(labelWithString: "")
    let field = NSTextField()
    let list = NSScrollView()
    let body = FlippedView()
    let openApp = NSButton()
    let back = NSButton()
    private var searchWork: DispatchWorkItem?
    private var recs: [Devon.Rec] = []
    /// Where you are: empty = all databases; then a database, then groups inside it.
    private var path: [Devon.Rec] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = roundedFont(15, .bold); title.textColor = .white
        hint.font = roundedFont(11, .semibold); hint.textColor = bioCyan; hint.alignment = .right
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.textColor = .white; field.font = roundedFont(13, .medium); field.delegate = self
        field.placeholderAttributedString = NSAttributedString(string: "Search DEVONthink…",
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.7), .font: roundedFont(13, .medium)])
        field.wantsLayer = true
        list.drawsBackground = false; list.hasVerticalScroller = false; list.documentView = body
        list.horizontalScrollElasticity = .none; list.usesPredominantAxisScrolling = true
        openApp.isBordered = false; openApp.title = ""
        openApp.attributedTitle = NSAttributedString(string: "Open DEVONthink", attributes: [.foregroundColor: bioCyan, .font: roundedFont(12, .semibold)])
        openApp.target = self; openApp.action = #selector(launchDevon)
        openApp.isHidden = true
        back.isBordered = false
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        back.contentTintColor = .white
        back.target = self; back.action = #selector(goBack)
        back.isHidden = true
        title.lineBreakMode = .byTruncatingHead
        [title, hint, field, list, openApp, back].forEach(addSubview)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        let w = s.width, h = s.height
        back.frame = NSRect(x: 40, y: h - 40, width: 18, height: 20)
        title.frame = NSRect(x: path.isEmpty ? 44 : 62, y: h - 40, width: w - 360, height: 20)
        hint.frame = NSRect(x: w - 300, y: h - 37, width: 256, height: 15)
        field.frame = NSRect(x: 44, y: h - 76, width: w - 88, height: 22)
        list.frame = NSRect(x: 36, y: 50, width: w - 72, height: h - 136)
        openApp.frame = NSRect(x: (w - 160) / 2, y: h / 2 - 12, width: 160, height: 24)
        layoutRows()
    }

    override func draw(_ dirty: NSRect) {
        // The search line: a glass underline, like the vault's.
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(rect: NSRect(x: 44, y: bounds.height - 80, width: bounds.width - 88, height: 1)).fill()
    }

    @objc func launchDevon() {
        NSWorkspace.shared.openApplication(at: NSWorkspace.shared.urlForApplication(withBundleIdentifier: devonID)!,
                                           configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.reload() }
        }
    }

    private var loadedAt = Date.distantPast
    /// Coming back within a few seconds keeps what's there (no DEVONthink round-trip mid-swipe).
    func surfaced() {
        if Date().timeIntervalSince(loadedAt) < 15 && !recs.isEmpty { return }
        loadedAt = Date()
        reload()
    }

    func reload() {
        guard Devon.running else {
            recs = []; layoutRows()
            hint.stringValue = ""
            openApp.isHidden = false
            return
        }
        openApp.isHidden = true
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        back.isHidden = path.isEmpty
        title.stringValue = (["DEVONthink"] + path.map { $0.name }).joined(separator: " › ")
        setFrameSize(frame.size)
        let src: Devon.Source
        if !q.isEmpty { src = .search(q) }
        else if let here = path.last { src = here.kind == "database" ? .database(here.uuid) : .group(here.uuid) }
        else { src = .databases }
        hint.stringValue = !q.isEmpty ? "Searching…" : path.isEmpty ? "Your databases" : "Drop files to import here"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Devon.records(src)
            DispatchQueue.main.async {
                guard q == self.field.stringValue.trimmingCharacters(in: .whitespaces) else { return }
                self.recs = r ?? []
                if r == nil { self.hint.stringValue = "DEVONthink didn't answer (allow Sill to control it?)" }
                else if !q.isEmpty { self.hint.stringValue = "\(self.recs.count) found" }
                self.layoutRows()
            }
        }
    }

    @objc func goBack() { guard !path.isEmpty else { return }; path.removeLast(); reload() }

    private func open(_ r: Devon.Rec) {
        // Databases and groups open in place; anything else opens in DEVONthink.
        if r.kind == "database" || r.kind.contains("group") {
            field.stringValue = ""
            path.append(r); reload(); return
        }
        if let u = URL(string: "x-devonthink-item://\(r.uuid)") { NSWorkspace.shared.open(u) }
    }

    func controlTextDidChange(_ n: Notification) {
        searchWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reload() }
        searchWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    private func layoutRows() {
        body.subviews.forEach { $0.removeFromSuperview() }
        let w = list.bounds.width
        var y: CGFloat = 0
        for r in recs {
            let sym = r.kind == "database" ? "cylinder.split.1x2.fill" : r.kind.contains("group") ? "folder.fill"
                : r.kind.contains("PDF") ? "doc.richtext" : r.kind.contains("markdown") ? "text.alignleft" : "doc"
            let row = HubRow(r.name, r.kind == "database" ? "" : r.db, symbol: sym, width: w)
            row.frame.origin = NSPoint(x: 0, y: y)
            row.onOpen = { [weak self] in self?.open(r) }
            body.addSubview(row)
            y += 28
        }
        body.frame = NSRect(x: 0, y: 0, width: w, height: max(list.bounds.height, y))
    }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        hint.stringValue = "Drop to import into " + (path.last?.name ?? "the Global Inbox"); return .copy
    }
    override func draggingExited(_ s: NSDraggingInfo?) { reload() }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty, Devon.running else { return false }
        hint.stringValue = "Importing \(urls.count)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let here = self.path.last
            let ok = Devon.importFiles(urls, group: here.flatMap { $0.kind == "database" ? nil : $0.uuid },
                                       database: here.flatMap { $0.kind == "database" ? $0.uuid : nil })
            DispatchQueue.main.async { self.hint.stringValue = ok ? "Imported" : "Import failed"; self.reload() }
        }
        return true
    }
}

/// The notebook: your Obsidian vault with the Claude CLI running in it, so you can ask about, summarize or extend
/// your notes. Read aloud speaks whatever you've selected. Claude runs in the cloud: what you ask about leaves the Mac.
final class NotebookPanel: SwipePanel {
    let title = NSTextField(labelWithString: "Notebook")
    let note = NSTextField(labelWithString: "Obsidian vault · Claude (cloud) reads what you ask about")
    let speak = NSButton()
    var terminal: SillTerminal?
    let synth = AVSpeechSynthesizer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = roundedFont(15, .bold); title.textColor = .white
        note.font = roundedFont(11, .medium); note.textColor = .white
        speak.isBordered = false; speak.title = ""
        speak.attributedTitle = NSAttributedString(string: "Read aloud", attributes: [.foregroundColor: bioCyan, .font: roundedFont(12, .semibold)])
        speak.toolTip = "Select text in the notebook, then Read aloud (click again to stop)"
        speak.target = self; speak.action = #selector(readAloud)
        [title, note, speak].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        let w = s.width, h = s.height
        title.frame = NSRect(x: 44, y: h - 40, width: 120, height: 20)
        note.frame = NSRect(x: 130, y: h - 37, width: w - 280, height: 15)
        speak.frame = NSRect(x: w - 140, y: h - 40, width: 96, height: 20)
        terminal?.frame = NSRect(x: 40, y: 40, width: w - 80, height: h - 88)
    }

    @objc func readAloud() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate); return }
        let text = terminal?.getSelection() ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            note.stringValue = "Select some text first, then Read aloud"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.note.stringValue = "Obsidian vault · Claude (cloud) reads what you ask about"
            }
            return
        }
        synth.speak(AVSpeechUtterance(string: text))
    }
}

// MARK: - Media panel: transcribe and compress
//
// The last panel in the essentials row. Two drop zones in glass:
//   Transcribe: drop (or click to pick) an audio or video file, or press Listen to capture what the Mac is playing
//     (plus your mic) and transcribe it when you stop. Runs Whisper on this Mac (the openai-whisper you have
//     installed, large-v3-turbo model): nothing is uploaded. Text lands in ~/Documents/Sill Transcripts.
//   Compress: type the size you need (NotebookLM: 100 MB, Claude: 30 MB) and drop a video or audio file. Sill works
//     out the bitrate that fits, encodes with ffmpeg (two passes for video), checks the result, and tells you the
//     final size exactly. The compressed copy is saved next to the original.

let whisperPath = NSHomeDirectory() + "/.local/bin/whisper"
let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
let ffprobePath = "/opt/homebrew/bin/ffprobe"

/// Runs a command line tool to the end; returns (exit ok, stdout).
@discardableResult
func runTool(_ path: String, _ args: [String], cwd: String? = nil) -> (Bool, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let c = cwd { p.currentDirectoryURL = URL(fileURLWithPath: c) }
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    p.environment = env
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    guard (try? p.run()) != nil else { return (false, "") }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus == 0, String(data: d, encoding: .utf8) ?? "")
}

func fileSize(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
}

func mb(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }

enum Media {
    /// Transcribes with Whisper on this Mac. Returns the transcript file.
    static func transcribe(_ src: URL) -> URL? {
        let dir = NSHomeDirectory() + "/Documents/Sill Transcripts"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ok = runTool(whisperPath, [src.path, "--model", "large-v3-turbo", "--output_format", "txt",
                                       "--output_dir", dir, "--fp16", "False", "--verbose", "False"]).0
        let out = URL(fileURLWithPath: dir).appendingPathComponent(src.deletingPathExtension().lastPathComponent + ".txt")
        return ok && FileManager.default.fileExists(atPath: out.path) ? out : nil
    }

    struct Probe { let duration: Double; let hasVideo: Bool }
    static func probe(_ src: URL) -> Probe? {
        let d = runTool(ffprobePath, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", src.path]).1
        guard let dur = Double(d.trimmingCharacters(in: .whitespacesAndNewlines)), dur > 0 else { return nil }
        let v = runTool(ffprobePath, ["-v", "error", "-select_streams", "v", "-show_entries", "stream=codec_type",
                                      "-of", "csv=p=0", src.path]).1
        // Cover art in an audio file shows up as a video stream; a real video lasts longer than one frame.
        return Probe(duration: dur, hasVideo: v.contains("video") && !["mp3", "m4a", "flac", "wav", "aac"].contains(src.pathExtension.lowercased()))
    }

    enum Outcome { case done(URL, Int64), alreadySmall(Int64), tooSmall(Double), failed(String) }

    /// Compresses to fit `targetMB` (decimal megabytes, as upload limits count them), with a small safety margin.
    static func compress(_ src: URL, targetMB: Double, progress: @escaping (String) -> Void) -> Outcome {
        let original = fileSize(src)
        let target = Int64(targetMB * 1_000_000)
        if original <= target { return .alreadySmall(original) }
        guard let p = probe(src) else { return .failed("Couldn't read that file") }
        let base = src.deletingPathExtension().lastPathComponent
        let ext = p.hasVideo ? "mp4" : "m4a"
        let out = src.deletingLastPathComponent().appendingPathComponent("\(base) (\(Int(targetMB)) MB).\(ext)")
        var budget = Double(target) * 8 * 0.95 / p.duration           // bits per second for everything
        for attempt in 0..<3 {
            try? FileManager.default.removeItem(at: out)
            if p.hasVideo {
                let audio = min(128_000, budget * 0.15)
                let video = budget - audio
                guard video > 60_000 else { return .tooSmall(Double(original) / 1_000_000) }
                let log = NSTemporaryDirectory() + "sill-2pass-\(UUID().uuidString)"
                progress(attempt == 0 ? "Compressing… pass 1 of 2" : "A bit smaller… pass 1 of 2")
                runTool(ffmpegPath, ["-y", "-i", src.path, "-c:v", "libx264", "-preset", "medium", "-b:v", "\(Int(video))",
                                     "-pass", "1", "-passlogfile", log, "-an", "-f", "mp4", "/dev/null"])
                progress(attempt == 0 ? "Compressing… pass 2 of 2" : "A bit smaller… pass 2 of 2")
                let ok = runTool(ffmpegPath, ["-y", "-i", src.path, "-c:v", "libx264", "-preset", "medium", "-b:v", "\(Int(video))",
                                              "-pass", "2", "-passlogfile", log, "-c:a", "aac", "-b:a", "\(Int(audio))",
                                              "-movflags", "+faststart", out.path]).0
                for suffix in ["-0.log", "-0.log.mbtree"] { try? FileManager.default.removeItem(atPath: log + suffix) }
                guard ok else { return .failed("ffmpeg couldn't encode it") }
            } else {
                let rate = min(192_000, budget)
                guard rate >= 24_000 else { return .tooSmall(Double(original) / 1_000_000) }
                progress("Compressing audio…")
                guard runTool(ffmpegPath, ["-y", "-i", src.path, "-vn", "-c:a", "aac", "-b:a", "\(Int(rate))", out.path]).0
                else { return .failed("ffmpeg couldn't encode it") }
            }
            let size = fileSize(out)
            if size <= target { return .done(out, size) }
            budget *= Double(target) / Double(size) * 0.95                // overshot: aim lower and go again
        }
        return .failed("Couldn't get it under \(Int(targetMB)) MB")
    }
}

/// A glass drop zone: click to choose a file, or drop one on it.
final class DropZone: NSView {
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    var onFiles: (([URL]) -> Void)?
    private var hot = false { didSet { needsDisplay = true } }
    init(_ t: String, _ d: String) {
        super.init(frame: .zero)
        title.stringValue = t; title.font = roundedFont(13, .bold); title.textColor = .white; title.alignment = .center
        detail.stringValue = d; detail.font = roundedFont(10.5, .medium); detail.textColor = .white; detail.alignment = .center
        detail.maximumNumberOfLines = 2; detail.lineBreakMode = .byWordWrapping
        [title, detail].forEach(addSubview)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        title.frame = NSRect(x: 8, y: s.height / 2 + 2, width: s.width - 16, height: 18)
        detail.frame = NSRect(x: 12, y: s.height / 2 - 30, width: s.width - 24, height: 30)
    }
    override func draw(_ r: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 16, yRadius: 16)
        NSColor.white.withAlphaComponent(hot ? 0.14 : 0.07).setFill(); p.fill()
        (hot ? bioCyan : NSColor.white.withAlphaComponent(0.25)).setStroke()
        p.setLineDash([5, 4], count: 2, phase: 0); p.lineWidth = 1; p.stroke()
    }
    override func mouseDown(with e: NSEvent) {
        let o = NSOpenPanel()
        o.allowsMultipleSelection = false
        o.allowedContentTypes = [.audiovisualContent]
        NSApp.activate(ignoringOtherApps: true)
        if o.runModal() == .OK, let u = o.url { onFiles?([u]) }
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { hot = true; return .copy }
    override func draggingExited(_ s: NSDraggingInfo?) { hot = false }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        hot = false
        guard let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return false }
        onFiles?(urls); return true
    }
}

final class MediaPanel: SwipePanel, NSTextFieldDelegate {
    let title = NSTextField(labelWithString: "Media")
    let status = NSTextField(labelWithString: "")
    let transcribeZone = DropZone("Transcribe", "Drop audio or video · runs on this Mac")
    let compressZone = DropZone("Compress", "Drop video or audio to fit the size below")
    let listen = NSButton()
    let sizeField = NSTextField()
    let sizeLabel = NSTextField(labelWithString: "MB")
    let output = NSTextView()
    let outScroll = NSScrollView()
    let copyButton = NSButton()
    private var busy = false
    private var listener: AnyObject?
    private var listenURL: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = roundedFont(15, .bold); title.textColor = .white
        status.font = roundedFont(11, .semibold); status.textColor = bioCyan; status.alignment = .right
        status.lineBreakMode = .byTruncatingMiddle
        for b in [listen, copyButton] { b.isBordered = false; b.title = ""; b.focusRingType = .none; b.refusesFirstResponder = true }
        setLink(listen, "● Listen to what's playing")
        listen.target = self; listen.action = #selector(toggleListen)
        setLink(copyButton, "Copy text")
        copyButton.target = self; copyButton.action = #selector(copyText)
        copyButton.isHidden = true
        sizeField.stringValue = UserDefaults.standard.string(forKey: "compressMB") ?? "95"
        sizeField.font = roundedFont(13, .semibold); sizeField.textColor = .white; sizeField.alignment = .right
        sizeField.isBordered = false; sizeField.drawsBackground = false; sizeField.focusRingType = .none; sizeField.delegate = self
        sizeField.wantsLayer = true
        sizeField.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor; sizeField.layer?.cornerRadius = 6
        sizeLabel.font = roundedFont(12, .semibold); sizeLabel.textColor = .white
        output.isEditable = false; output.drawsBackground = false
        output.textColor = .white; output.font = roundedFont(12, .regular)
        output.textContainerInset = NSSize(width: 4, height: 4)
        outScroll.documentView = output; outScroll.drawsBackground = false; outScroll.hasVerticalScroller = false
        output.autoresizingMask = [.width]; output.isVerticallyResizable = true
        transcribeZone.onFiles = { [weak self] u in self?.transcribe(u[0]) }
        compressZone.onFiles = { [weak self] u in self?.compress(u[0]) }
        [title, status, transcribeZone, compressZone, listen, sizeField, sizeLabel, outScroll, copyButton].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setLink(_ b: NSButton, _ t: String) {
        b.attributedTitle = NSAttributedString(string: t, attributes: [.foregroundColor: bioCyan, .font: roundedFont(12, .semibold)])
    }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        let w = s.width, h = s.height, gap: CGFloat = 16
        let zw = (w - 88 - gap) / 2
        title.frame = NSRect(x: 44, y: h - 40, width: 100, height: 20)
        status.frame = NSRect(x: 150, y: h - 37, width: w - 194, height: 15)
        transcribeZone.frame = NSRect(x: 44, y: h - 168, width: zw, height: 116)
        compressZone.frame = NSRect(x: 44 + zw + gap, y: h - 168, width: zw, height: 116)
        listen.frame = NSRect(x: 44, y: h - 196, width: zw, height: 20)
        sizeField.frame = NSRect(x: 44 + zw + gap + zw / 2 - 40, y: h - 196, width: 52, height: 20)
        sizeLabel.frame = NSRect(x: sizeField.frame.maxX + 6, y: h - 194, width: 30, height: 16)
        outScroll.frame = NSRect(x: 40, y: 36, width: w - 80, height: h - 244)
        output.frame = NSRect(x: 0, y: 0, width: outScroll.bounds.width, height: max(outScroll.bounds.height, output.frame.height))
        copyButton.frame = NSRect(x: w - 130, y: 14, width: 86, height: 18)
    }

    func controlTextDidChange(_ n: Notification) {
        let digits = sizeField.stringValue.filter { $0.isNumber || $0 == "." }
        if digits != sizeField.stringValue { sizeField.stringValue = digits }
        UserDefaults.standard.set(digits, forKey: "compressMB")
    }

    func say(_ t: String) { status.stringValue = t }
    func show(_ text: String) {
        output.string = text
        copyButton.isHidden = text.isEmpty
        output.sizeToFit()
    }
    @objc func copyText() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output.string, forType: .string)
        say("Copied")
    }

    func transcribe(_ u: URL) {
        guard !busy else { say("Still working on the last one"); return }
        guard FileManager.default.isExecutableFile(atPath: whisperPath) else { say("Whisper isn't installed at ~/.local/bin/whisper"); return }
        busy = true
        say("Transcribing \(u.lastPathComponent)… (on this Mac; long files take a while)")
        DispatchQueue.global(qos: .userInitiated).async {
            let out = Media.transcribe(u)
            let text = out.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                self.busy = false
                if let o = out { self.say("Saved to Documents › Sill Transcripts › \(o.lastPathComponent)"); self.show(text) }
                else { self.say("Couldn't transcribe that file") }
            }
        }
    }

    @objc func toggleListen() {
        guard #available(macOS 15.0, *) else { say("Listening needs macOS 15"); return }
        if let rec = listener as? MixedAudioRecorder {
            listener = nil
            setLink(listen, "● Listen to what's playing")
            say("Finishing the capture…")
            rec.stop { [weak self] url in DispatchQueue.main.async { if let u = url { self?.transcribe(u) } else { self?.say("Nothing was captured") } } }
            return
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Listened \(f.string(from: Date())).m4a")
        let rec = MixedAudioRecorder()
        rec.start(to: url, micID: preferredMicID()) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if ok { self.listener = rec; self.listenURL = url; self.setLink(self.listen, "■ Stop and transcribe"); self.say("Listening to what's playing (and your mic)…") }
                else { self.say("Couldn't listen (Screen Recording permission?)") }
            }
        }
    }

    func compress(_ u: URL) {
        guard !busy else { say("Still working on the last one"); return }
        guard let target = Double(sizeField.stringValue), target > 0 else { say("Type a size first"); return }
        busy = true
        let before = fileSize(u)
        say("Compressing \(u.lastPathComponent) to under \(Int(target)) MB…")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Media.compress(u, targetMB: target) { msg in DispatchQueue.main.async { self.say(msg) } }
            DispatchQueue.main.async {
                self.busy = false
                switch r {
                case .done(let out, let size):
                    self.say("Done: \(mb(size)) (was \(mb(before)))")
                    self.show("\(out.lastPathComponent)\n\(mb(before)) → \(mb(size)), under your \(Int(target)) MB limit.\nSaved next to the original.")
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                case .alreadySmall(let size): self.say("Already \(mb(size)): nothing to do")
                case .tooSmall(let orig): self.say("\(Int(target)) MB is too small for this length (it's \(String(format: "%.0f", orig)) MB)")
                case .failed(let why): self.say(why)
                }
            }
        }
    }
}

// MARK: - Voice → Apple Calendar (the rebuilt New Side Quest)
//
// Press the sparkle in the awake strip, say what you need ("call PacificSource tomorrow before 4 pm asking them to …"),
// press again (or pause), and a draft appears under the strip: title, when, notes, place. Enter saves it straight into
// Apple Calendar (location is optional and never blocks), Esc cancels, "Smarter" re-reads the sentence with Claude.
// Speech is recognized on this Mac (Apple's on-device recognizer). Only "Smarter" sends the sentence anywhere.

/// A calendar entry drafted from a sentence.
struct EventDraft {
    var title = ""
    var start = Date()
    var end = Date()
    var allDay = false
    var notes = ""
    var location = ""
    var alert: TimeInterval? = nil          // seconds relative to start (0 = at start)
}

/// Local, rule-based reading of a spoken sentence. Apple's date detector finds the when; the words before it are the
/// title, the words after are the notes. "before / by 4 pm" is a deadline: a 30-minute block ending then, alert at its
/// start. A time on its own ("at 2 pm") starts a 30-minute block. A date without a time is all-day.
enum DraftParser {
    static func parse(_ raw: String, now: Date = Date(), calendar cal: Calendar = .current) -> EventDraft {
        var d = EventDraft()
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        // Where (only if the sentence holds something that is clearly an address).
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue),
           let m = det.firstMatch(in: text, range: full) { d.location = ns.substring(with: m.range) }
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let m = det.firstMatch(in: text, range: full), let foundDate = m.date else {
            d.title = tidyTitle(text); d.allDay = true
            d.start = cal.startOfDay(for: now); d.end = cal.date(byAdding: .day, value: 1, to: d.start)!
            return d
        }
        var phrase = ns.substring(with: m.range).lowercased()
        let before = ns.substring(to: m.range.location)
        var after = ns.substring(from: m.range.location + m.range.length)
        let lowerBefore = before.lowercased()
        var deadline = ["before", "by", "no later than", "until"].contains { lowerBefore.hasSuffix($0 + " ") || phrase.hasPrefix($0 + " ") }
        var hasTime = phrase.range(of: #"\d|noon|midnight|morning|afternoon|evening|tonight|am\b|pm\b"#, options: .regularExpression) != nil
        var found = foundDate
        // "tomorrow before 4 pm": the detector often stops at the day; pick up a time right after it.
        if !hasTime, let t = after.range(of: #"^\s*(before|by|until|no later than|at|around)\s+(\d{1,2})(:(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?|^\s*(before|by|until|at)\s+(noon|midnight)"#,
                                         options: [.regularExpression, .caseInsensitive]) {
            let piece = after[t].lowercased()
            deadline = ["before", "by", "until", "no later"].contains { piece.trimmingCharacters(in: .whitespaces).hasPrefix($0) }
            var hour = 12, minute = 0
            if piece.contains("midnight") { hour = 0 } else if !piece.contains("noon") {
                let nums = piece.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap(Int.init)
                hour = nums.first ?? 12; minute = nums.count > 1 ? nums[1] : 0
                let pm = piece.contains("p"), am = piece.contains("a.") || piece.hasSuffix("am") || piece.contains(" am")
                if pm && hour < 12 { hour += 12 } else if !pm && !am && hour <= 7 { hour += 12 }   // "by 4" means 4 pm
            }
            found = cal.date(bySettingHour: hour, minute: minute, second: 0, of: found) ?? found
            phrase += " " + piece
            after = String(after[t.upperBound...])
            hasTime = true
        }
        // "by 5 tomorrow": the time can also come just before the day.
        var titleEnd = before
        if !hasTime, let t = before.range(of: #"\s(before|by|until|at|around)\s+(\d{1,2})(:(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?\s*$"#,
                                          options: [.regularExpression, .caseInsensitive]) {
            let piece = before[t].lowercased()
            deadline = ["before", "by", "until"].contains { piece.trimmingCharacters(in: .whitespaces).hasPrefix($0) }
            let nums = piece.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap(Int.init)
            var hour = nums.first ?? 12; let minute = nums.count > 1 ? nums[1] : 0
            let pm = piece.contains("p"), am = piece.contains("am") || piece.contains("a.")
            if pm && hour < 12 { hour += 12 } else if !pm && !am && hour <= 7 { hour += 12 }
            found = cal.date(bySettingHour: hour, minute: minute, second: 0, of: found) ?? found
            phrase = piece + " " + phrase
            titleEnd = String(before[..<t.lowerBound]) + " "
            hasTime = true
        }
        // A time with no day that has already passed today means tomorrow.
        let namesDay = phrase.range(of: #"today|tonight|tomorrow|day|mon|tue|wed|thu|fri|sat|sun|\d{1,2}/|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec"#, options: .regularExpression) != nil
        if hasTime && !namesDay && found < now { found = cal.date(byAdding: .day, value: 1, to: found) ?? found }
        if !hasTime {
            d.allDay = true
            d.start = cal.startOfDay(for: found); d.end = cal.date(byAdding: .day, value: 1, to: d.start)!
            d.alert = nil
        } else if deadline {
            d.end = found; d.start = found.addingTimeInterval(-30 * 60); d.alert = 0
        } else {
            d.start = found; d.end = found.addingTimeInterval(m.duration > 0 ? m.duration : 30 * 60); d.alert = -10 * 60
        }
        var titlePart = titleEnd
        for w in ["before", "by", "no later than", "until", "on", "at"] where titlePart.lowercased().hasSuffix(" " + w + " ") || titlePart.lowercased().hasSuffix(" " + w) {
            titlePart = String(titlePart.dropLast(w.count + 1))
        }
        d.title = tidyTitle(titlePart.isEmpty ? after : titlePart)
        d.notes = titlePart.isEmpty ? "" : tidyNotes(after)
        if !d.location.isEmpty {
            d.notes = tidyNotes(after.replacingOccurrences(of: d.location, with: ""))
        }
        return d
    }

    static func tidyTitle(_ s: String) -> String {
        var t = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        for lead in ["remind me to ", "i need to ", "i have to ", "need to ", "schedule ", "add "] where t.lowercased().hasPrefix(lead) {
            t = String(t.dropFirst(lead.count))
        }
        return capitalized(t)
    }

    /// "asking them to promote … and ask for a reference number" → "Ask them to promote …. Ask for a reference number."
    static func tidyNotes(_ s: String) -> String {
        var t = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        for lead in ["at ", "on ", "in "] where t.lowercased().hasPrefix(lead) { t = String(t.dropFirst(lead.count)) }
        if t.count < 3 { return "" }
        for lead in ["asking ", "to ask ", "and ", "to "] where t.lowercased().hasPrefix(lead) {
            t = (lead == "asking " ? "ask " : "") + String(t.dropFirst(lead.count)); break
        }
        let parts = t.components(separatedBy: " and ask ")
        let sentences = parts.enumerated().map { i, p in capitalized(i == 0 ? p : "ask " + p) }
        let joined = sentences.joined(separator: ". ")
        return joined.isEmpty ? "" : joined + (joined.hasSuffix(".") ? "" : ".")
    }

    static func capitalized(_ s: String) -> String { s.isEmpty ? s : s.prefix(1).uppercased() + s.dropFirst() }
}

/// Re-reads the sentence with Claude (the CLI you have installed), for phrasing the rules don't handle. Cloud.
enum SmarterParser {
    static func parse(_ text: String, now: Date = Date(), _ done: @escaping (EventDraft?) -> Void) {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]; iso.timeZone = .current
        let prompt = """
        Turn this spoken request into ONE Apple Calendar event. Now is \(iso.string(from: now)) (\(TimeZone.current.identifier)).
        Reply with only JSON: {"title": str, "start": ISO8601 with offset, "end": ISO8601 with offset, "allDay": bool,
        "notes": str, "location": str (empty if none), "alertMinutesBefore": int or null}.
        A deadline ("before 4 pm") is a 30-minute event ending at that time with alertMinutesBefore 0. Keep the title short
        (an action + who/what); put the rest in notes as short sentences. Never invent a location.
        Request: \(text)
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, out) = runTool("/opt/homebrew/bin/claude", ["-p", prompt])
            guard ok, let a = out.firstIndex(of: "{"), let b = out.lastIndex(of: "}"),
                  let json = try? JSONSerialization.jsonObject(with: Data(out[a...b].utf8)) as? [String: Any] else {
                DispatchQueue.main.async { done(nil) }; return
            }
            var d = EventDraft()
            d.title = json["title"] as? String ?? ""
            d.notes = json["notes"] as? String ?? ""
            d.location = json["location"] as? String ?? ""
            d.allDay = json["allDay"] as? Bool ?? false
            let parse = { (k: String) in (json[k] as? String).flatMap { iso.date(from: $0) } }
            d.start = parse("start") ?? now
            d.end = parse("end") ?? d.start.addingTimeInterval(1800)
            if d.allDay { d.start = Calendar.current.startOfDay(for: d.start); d.end = Calendar.current.date(byAdding: .day, value: 1, to: d.start)! }
            if let m = json["alertMinutesBefore"] as? Int { d.alert = TimeInterval(-60 * m) }
            DispatchQueue.main.async { done(d) }
        }
    }
}

/// A panel that can take typing (for editing the draft) without activating Sill's other windows.
final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

/// Listens, shows the words live, then the draft card under the strip.
final class VoiceEntry: NSObject, NSTextFieldDelegate {
    let store: EKEventStore
    let window = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let glass = NSVisualEffectView()
    private let heard = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let title = NSTextField(), when = NSTextField(labelWithString: ""), notes = NSTextField(), place = NSTextField()
    private let save = NSButton(), smarter = NSButton(), cancel = NSButton()
    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: DispatchWorkItem?
    private(set) var listening = false
    private var transcript = ""
    private var draft = EventDraft()
    private var lastSaved: EKEvent?
    var anchor: () -> NSRect = { .zero }           // the strip's frame on screen
    var onListening: ((Bool) -> Void)?

    init(store: EKEventStore) {
        self.store = store
        super.init()
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSView(); root.wantsLayer = true; root.layer?.cornerRadius = 18; root.layer?.masksToBounds = true
        glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active
        let tint = NSView(); tint.wantsLayer = true; tint.layer?.backgroundColor = midwater.withAlphaComponent(0.6).cgColor
        window.contentView = root
        [glass, tint].forEach { root.addSubview($0); $0.autoresizingMask = [.width, .height] }
        heard.font = roundedFont(13, .medium); heard.textColor = .white; heard.maximumNumberOfLines = 3
        status.font = roundedFont(10, .heavy); status.textColor = bioCyan
        for f in [title, notes, place] {
            f.isBordered = false; f.drawsBackground = true; f.backgroundColor = NSColor.white.withAlphaComponent(0.07)
            f.textColor = .white; f.focusRingType = .none; f.delegate = self; f.wantsLayer = true; f.layer?.cornerRadius = 6
        }
        title.font = roundedFont(15, .semibold); notes.font = roundedFont(12, .medium); place.font = roundedFont(12, .medium)
        place.placeholderAttributedString = NSAttributedString(string: "Location (optional)", attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.6), .font: roundedFont(12, .medium)])
        notes.placeholderAttributedString = NSAttributedString(string: "Notes", attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.6), .font: roundedFont(12, .medium)])
        when.font = roundedFont(12.5, .semibold); when.textColor = bioCyan
        for (b, t, sel) in [(save, "Save  ⏎", #selector(saveTapped)), (smarter, "Smarter", #selector(smarterTapped)), (cancel, "Cancel", #selector(cancelTapped))] {
            b.isBordered = false; b.title = ""
            b.attributedTitle = NSAttributedString(string: t, attributes: [.foregroundColor: b === save ? bioCyan : NSColor.white, .font: roundedFont(12.5, .semibold)])
            b.target = self; b.action = sel
        }
        smarter.toolTip = "Re-read the sentence with Claude (sends it to the cloud)"
        save.keyEquivalent = "\r"; cancel.keyEquivalent = "\u{1b}"
        [heard, status, title, when, notes, place, save, smarter, cancel].forEach(root.addSubview)
    }

    // MARK: Listening

    func toggle() { listening ? stop() : start() }

    func start() {
        SFSpeechRecognizer.requestAuthorization { st in
            DispatchQueue.main.async {
                guard st == .authorized else { self.showMessage("Allow Sill in Privacy & Security → Speech Recognition"); return }
                self.beginListening()
            }
        }
    }

    private func beginListening() {
        guard let rec = recognizer, rec.isAvailable else { showMessage("Speech recognition isn't available right now"); return }
        task?.cancel()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }   // stays on this Mac
        request = req
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in req.append(buf) }
        engine.prepare()
        do { try engine.start() } catch { showMessage("Couldn't use the microphone"); return }
        transcript = ""
        listening = true
        onListening?(true)
        layout(listeningMode: true)
        heard.stringValue = "Listening…"
        status.stringValue = "SPEAK · PRESS AGAIN TO FINISH"
        present()
        task = rec.recognitionTask(with: req) { [weak self] result, err in
            DispatchQueue.main.async {
                guard let self = self, self.listening else { return }
                if let r = result {
                    self.transcript = r.bestTranscription.formattedString
                    self.heard.stringValue = self.transcript
                    self.armSilence()
                    if r.isFinal { self.stop() }
                }
                if err != nil && self.transcript.isEmpty { self.stop() }
            }
        }
    }

    /// Two quiet seconds after you've said something ends the listening on its own.
    private func armSilence() {
        silence?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.stop() }
        silence = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: w)
    }

    func stop() {
        guard listening else { return }
        listening = false
        onListening?(false)
        silence?.cancel()
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.finish()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { showMessage("Didn't catch anything"); return }
        draft = DraftParser.parse(text)
        showDraft()
    }

    // MARK: The card

    private func present() {
        let a = anchor()
        let w: CGFloat = 520, h: CGFloat = listening ? 96 : 236
        window.setFrame(NSRect(x: a.midX - w / 2, y: a.minY - h - 8, width: w, height: h), display: true)
        window.orderFrontRegardless()
    }

    private func layout(listeningMode: Bool) {
        for v in [title, when, notes, place, save, smarter, cancel] { v.isHidden = listeningMode }
        heard.isHidden = false
    }

    private func showDraft() {
        layout(listeningMode: false)
        present()
        let w = window.frame.width, h = window.frame.height
        heard.stringValue = "“\(transcript)”"
        heard.font = roundedFont(11, .medium)
        heard.frame = NSRect(x: 18, y: h - 34, width: w - 36, height: 16)
        status.frame = .zero
        title.frame = NSRect(x: 16, y: h - 70, width: w - 32, height: 26)
        when.frame = NSRect(x: 18, y: h - 96, width: w - 36, height: 18)
        notes.frame = NSRect(x: 16, y: h - 150, width: w - 32, height: 46)
        place.frame = NSRect(x: 16, y: h - 180, width: w - 32, height: 22)
        cancel.frame = NSRect(x: 14, y: 12, width: 70, height: 22)
        smarter.frame = NSRect(x: w - 190, y: 12, width: 80, height: 22)
        save.frame = NSRect(x: w - 100, y: 12, width: 86, height: 22)
        fill()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(title)
    }

    private func fill() {
        title.stringValue = draft.title
        notes.stringValue = draft.notes
        place.stringValue = draft.location
        let df = DateFormatter(); df.setLocalizedDateFormatFromTemplate("EEEMMMd")
        let tf = DateFormatter(); tf.setLocalizedDateFormatFromTemplate("jmm")
        var s = draft.allDay ? "\(df.string(from: draft.start)) · All day" : "\(df.string(from: draft.start)) · \(tf.string(from: draft.start)) – \(tf.string(from: draft.end))"
        if let a = draft.alert { s += a == 0 ? " · alert at start" : " · alert \(Int(-a / 60)) min before" }
        let t = draft.start.timeIntervalSinceNow
        if t > 0 { s += "   ·   NOW + " + (t < 3600 ? "\(Int((t / 60).rounded(.up))) min" : lifeSpan(t)) }
        when.stringValue = s
    }

    private func layoutMessage() {
        let w = window.frame.width, h = window.frame.height
        heard.frame = NSRect(x: 18, y: h - 56, width: w - 36, height: 40)
        heard.font = roundedFont(13, .medium)
        status.frame = NSRect(x: 18, y: 14, width: w - 36, height: 14)
    }

    private func showMessage(_ m: String) {
        layout(listeningMode: true)
        present()
        layoutMessage()
        heard.stringValue = m
        status.stringValue = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self, !self.listening, self.title.isHidden else { return }
            self.window.orderOut(nil)
        }
    }

    @objc func cancelTapped() { window.orderOut(nil) }

    @objc func smarterTapped() {
        let text = transcript
        smarter.attributedTitle = NSAttributedString(string: "Reading…", attributes: [.foregroundColor: NSColor.white, .font: roundedFont(12.5, .semibold)])
        SmarterParser.parse(text) { [weak self] d in
            guard let self = self else { return }
            self.smarter.attributedTitle = NSAttributedString(string: "Smarter", attributes: [.foregroundColor: NSColor.white, .font: roundedFont(12.5, .semibold)])
            guard let d = d else { self.when.stringValue = "Claude couldn't read it; the draft is unchanged"; return }
            self.draft = d
            self.fill()
        }
    }

    /// Writes the event to your default Apple Calendar. Location is optional; nothing else is required.
    @objc func saveTapped() {
        draft.title = title.stringValue.trimmingCharacters(in: .whitespaces)
        draft.notes = notes.stringValue
        draft.location = place.stringValue.trimmingCharacters(in: .whitespaces)
        guard !draft.title.isEmpty else { when.stringValue = "Give it a title first"; return }
        guard let cal = store.defaultCalendarForNewEvents else { when.stringValue = "No default calendar in Calendar settings"; return }
        let e = EKEvent(eventStore: store)
        e.calendar = cal
        e.title = draft.title
        e.startDate = draft.start; e.endDate = draft.end; e.isAllDay = draft.allDay
        if !draft.notes.isEmpty { e.notes = draft.notes }
        if !draft.location.isEmpty { e.location = draft.location }
        if let a = draft.alert { e.addAlarm(EKAlarm(relativeOffset: a)) }
        do {
            try store.save(e, span: .thisEvent, commit: true)
            lastSaved = e
            confirmSaved()
        } catch {
            when.stringValue = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// "Saved · Undo" for a few seconds, then the card goes.
    private func confirmSaved() {
        layout(listeningMode: true)
        layoutMessage()
        heard.stringValue = "Saved to Calendar: \(draft.title)"
        status.stringValue = ""
        let undo = NSButton(title: "", target: self, action: #selector(undoSave))
        undo.isBordered = false
        undo.attributedTitle = NSAttributedString(string: "Undo", attributes: [.foregroundColor: bioCyan, .font: roundedFont(12.5, .semibold)])
        undo.frame = NSRect(x: window.frame.width - 80, y: 10, width: 64, height: 22)
        undo.identifier = NSUserInterfaceItemIdentifier("undo")
        window.contentView?.addSubview(undo)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            undo.removeFromSuperview()
            if self?.title.isHidden == true && self?.listening == false { self?.window.orderOut(nil) }
        }
    }

    @objc func undoSave() {
        if let e = lastSaved { try? store.remove(e, span: .thisEvent, commit: true) }
        lastSaved = nil
        window.contentView?.subviews.filter { $0.identifier?.rawValue == "undo" }.forEach { $0.removeFromSuperview() }
        heard.stringValue = "Removed"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.window.orderOut(nil) }
    }
}

// MARK: - Terminal
//
// The third surface: a real terminal (SwiftTerm, a full VT100/xterm emulator) running your login shell in your home
// folder. Reached from the essentials panel with a two-finger swipe to the right; a two-finger swipe to the left,
// or three fingers down, goes back. The shell keeps running while Sill is hidden, so you come back to where you were.

final class SillTerminal: LocalProcessTerminalView {
    var onSwipeBack: (() -> Void)?
    private var travel: CGFloat = 0
    private var monitor: Any?

    /// Horizontal two-finger swipes over the terminal leave it; vertical ones scroll its history as usual.
    /// (SwiftTerm doesn't let its scrolling be overridden, so this watches Sill's own scroll events.)
    func watchSwipes() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self = self, !self.isHidden, e.window === self.window,
                  self.bounds.contains(self.convert(e.locationInWindow, from: nil)),
                  e.hasPreciseScrollingDeltas, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return e }
            if e.phase == .began { self.travel = 0 }
            guard e.momentumPhase.isEmpty else { return nil }
            self.travel += e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
            if self.travel > 70 { self.travel = 0; self.onSwipeBack?() }     // fingers left to right: back to essentials
            return nil
        }
    }
}

// MARK: - Menu bar icon usage
//
// Sill counts which menu bar icons you click and ranks them by recent use (each click's weight halves every three
// weeks), seeded with TextSniper, Bob and SoundSource. The ranking is meant to decide which icons stay visible and
// which go past the divider. Hold ⌘ and a thin divider appears in the menu bar; icons ⌘-dragged to its left are tucked
// away off screen, and holding ⌘ brings them back while you hold it.

let shelfSize = 5
let shelfHalfLife: TimeInterval = 21 * 24 * 3600
let shelfSeeds = ["com.valerijs.boguckis.TextSniper", "com.hezongyidev.Bob", "com.rogueamoeba.soundsource"]
let shelfIgnored: Set<String> = ["local.sill", "com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.TextInputMenuAgent",
                                 "com.apple.Spotlight", "com.apple.notificationcenterui"]

/// One menu bar icon as macOS currently has it.
struct MenuExtra { let window: CGWindowID; let pid: pid_t; let bundleID: String; let frame: CGRect; let onScreen: Bool }

func currentMenuExtras() -> [MenuExtra] {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 25,
              let id = w[kCGWindowNumber as String] as? CGWindowID,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let h = b["Height"], h <= 40, let y = b["Y"], y < 2,
              let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, !shelfIgnored.contains(bid)
        else { return nil }
        let f = CGRect(x: b["X"] ?? 0, y: y, width: b["Width"] ?? 0, height: h)
        return MenuExtra(window: id, pid: pid, bundleID: bid, frame: f, onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }
}

/// Click history and ranking.
final class ShelfUsage {
    private let key = "shelfClicks"
    private var clicks: [String: [Double]]
    init() { clicks = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:] }

    func record(_ bundleID: String) {
        var c = clicks[bundleID] ?? []
        c.append(Date().timeIntervalSince1970)
        clicks[bundleID] = Array(c.suffix(300))
        UserDefaults.standard.set(clicks, forKey: key)
    }

    /// Recent clicks count most; each click's weight halves every three weeks. Seeds count as a few old clicks.
    func score(_ bundleID: String) -> Double {
        let now = Date().timeIntervalSince1970
        var s = (clicks[bundleID] ?? []).reduce(0) { $0 + pow(0.5, (now - $1) / shelfHalfLife) }
        if let i = shelfSeeds.firstIndex(of: bundleID) { s += 3 - Double(i) * 0.1 }
        return s
    }

    func top(from extras: [MenuExtra]) -> [MenuExtra] {
        var seen = Set<String>()
        return extras.sorted { score($0.bundleID) > score($1.bundleID) }
            .filter { seen.insert($0.bundleID).inserted && score($0.bundleID) > 0 }
            .prefix(shelfSize).map { $0 }
    }
}

/// The ⌘-drag divider that tucks icons away (Nook's technique: when collapsed it is enormously wide, pushing every
/// icon to its left off the screen).
final class ShelfDivider {
    let item = NSStatusBar.system.statusItem(withLength: 12)
    private(set) var collapsed = true
    private var flagMonitors: [Any] = []
    init() {
        item.autosaveName = "local.sill.divider"
        item.button?.title = ""
        item.button?.appearsDisabled = true
        collapse()
        let watch: (NSEvent) -> Void = { [weak self] e in self?.commandChanged(e.modifierFlags.contains(.command)) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: watch) { flagMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { e in watch(e); return e }) { flagMonitors.append(l) }
        // Any key pressed with ⌘ means a shortcut, not arranging: don't reveal anything.
        if let k = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in self?.holdWork?.cancel() }) { flagMonitors.append(k) }
    }
    private var holdWork: DispatchWorkItem?
    /// Holding ⌘ on its own for a moment shows the divider so icons can be ⌘-dragged across it; letting go tucks
    /// them away again. A quick ⌘ for a shortcut does nothing.
    private func commandChanged(_ down: Bool) {
        holdWork?.cancel()
        if down {
            let w = DispatchWorkItem { [weak self] in self?.expand(showing: true) }
            holdWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
        } else if !collapsed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.collapse() }
        }
    }
    func expand(showing: Bool = false) {
        collapsed = false
        item.length = 12
        item.button?.title = showing ? "┃" : ""
        item.button?.alphaValue = 0.35
    }
    func collapse() {
        collapsed = true
        item.button?.title = ""
        item.length = 10_000
    }
}

/// Counts clicks on menu bar icons and owns the divider. (The floating shelf that used to show the top icons was
/// retired on 2026-10-07: the ranking is meant to decide which icons stay visible and which go past the divider.)
final class MenuBarUsage {
    let usage = ShelfUsage()
    let divider = ShelfDivider()
    private var monitors: [Any] = []

    init() {
        // Count clicks on menu bar icons, wherever they happen.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.noteClick(at: NSEvent.mouseLocation)
        }) { monitors.append(m) }
    }

    private func noteClick(at p: NSPoint) {
        guard let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }),
              p.y >= s.frame.maxY - RestStrip.menuBarHeight(s) else { return }
        let top = (NSScreen.screens.first?.frame.maxY ?? s.frame.maxY)
        let q = CGPoint(x: p.x, y: top - p.y)                       // window-list coordinates (origin top-left)
        if let hit = currentMenuExtras().first(where: { $0.frame.contains(q) }) { usage.record(hit.bundleID) }
    }
}

// MARK: - Spatial controller: the strip
//
// Move into the strip and it wakes to full context; move away and it goes back to sleep after `exitLatency`.

let exitLatency: TimeInterval = 0.28

final class SpatialController {
    let strip: RestStrip
    var available: () -> Bool = { false }
    private var stripExit: DispatchWorkItem?
    private var monitors: [Any] = []

    init(strip: RestStrip) {
        self.strip = strip
        let watch: (NSEvent) -> Void = { [weak self] _ in self?.moved(NSEvent.mouseLocation) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: watch) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { e in watch(e); return e }) { monitors.append(l) }
    }

    private func moved(_ p: NSPoint) {
        guard available() else { rest(); return }
        let inStrip = NSMouseInRect(p, strip.window.frame.insetBy(dx: 0, dy: -1), false)
        if inStrip {
            stripExit?.cancel(); stripExit = nil
            if !strip.expanded { strip.wake(true) }
        } else if strip.expanded && stripExit == nil {
            let w = DispatchWorkItem { [weak self] in self?.stripExit = nil; self?.strip.wake(false) }
            stripExit = w
            DispatchQueue.main.asyncAfter(deadline: .now() + exitLatency, execute: w)
        }
    }

    /// Back to rest now (the panel took over).
    func rest() {
        stripExit?.cancel(); stripExit = nil
        strip.wake(false)
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSTextViewDelegate, LocalProcessTerminalViewDelegate {
    let initialCommand: String

    let panel = SillPanel(
        contentRect: NSRect(origin: .zero, size: timeSize),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)

    // Time surface
    let timeView = EssentialsView(frame: NSRect(origin: .zero, size: timeSize))

    // Pad surface
    let padView = NSView()
    let header = ClickView()
    let headerLabel = NSTextField(labelWithString: "")
    let viewport = Viewport(frame: .zero)
    let strip = NSView()
    let pageLabel = NSTextField(labelWithString: "")

    var mode: Mode = .time
    var lastChange = Date.distantPast
    let clockFormat = DateFormatter()

    var views: [PageView] = []
    var index = 0
    var cursors: [Int: Int] = [:]

    var dragX: CGFloat = 0
    var dragging = false
    var settling = false

    var lastMTime: Date?
    var lastWritten = ""
    var saveTimer: Timer?
    var ready = false

    var texts: [String] { views.map { $0.textView.string } }
    var gestures: NativeGestures?
    lazy var menuBar = MenuBarUsage()
    lazy var spatial = SpatialController(strip: rest)
    weak var cardRoot: NSView?
    /// The card wears the menu bar's own color (sampled from the bar just beside the strip, under Sill's windows),
    /// so the panel reads as the menu bar itself growing down.
    func matchMenuBar(_ screen: NSScreen?) {
        guard let s = screen ?? NSScreen.main, let c = menuBarColor(on: s, below: CGWindowID(rest.window.windowNumber)) else { return }
        cardRoot?.layer?.backgroundColor = c.cgColor
    }
    lazy var rest = RestStrip(store: timeView.store, allowed: { [weak self] in self?.timeView.calendarAllowed ?? false })
    var hoverWork: DispatchWorkItem?
    var terminal: SillTerminal?
    var terminalStarted = false
    let hubView = DevonHub(frame: .zero)
    let notebookView = NotebookPanel(frame: .zero)
    let mediaView = MediaPanel(frame: .zero)
    var retracting = false
    var transition = 0                       // bumps on every open / switch / close, so stale animations step aside
    let morph = NSView()
    var stage: NSView?

    init(initialCommand: String) {
        self.initialCommand = initialCommand
        super.init()
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ n: Notification) {
        clockFormat.setLocalizedDateFormatFromTemplate("jmm")        // follows the 12/24-hour system setting

        buildMenu()
        buildPanel()

        // Carry over the last page and cursor from earlier builds (domain "sill") or Draftpad, the first time.
        let d = UserDefaults.standard
        for name in ["sill", "draftpad"] where d.object(forKey: "page") == nil {
            guard let old = UserDefaults(suiteName: name), old.object(forKey: "page") != nil else { continue }
            d.set(old.integer(forKey: "page"), forKey: "page")
            if old.object(forKey: "cursor") != nil { d.set(old.integer(forKey: "cursor"), forKey: "cursor") }
        }
        index = max(d.integer(forKey: "page"), 0)
        if d.object(forKey: "cursor") != nil { cursors[index] = d.integer(forKey: "cursor") }
        load()
        index = min(index, views.count - 1)
        layoutStrip()
        updateLabel()
        updateClock()
        ready = true

        registerHotKey { [weak self] in self?.toggle() }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(remoteCommand(_:)), name: commandName, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollExternal()   // pick up edits made in Obsidian
            self?.updateClock()
            self?.restoreState()
        }

        startGestures()
        rest.weatherText = { [weak self] in
            guard let w = self?.timeView.local.weatherText, !w.isEmpty else { return "" }
            return "\(w)   \(clockSpecs[0].place.components(separatedBy: ",").first ?? "")"
        }
        rest.place(on: targetScreen())
        _ = menuBar
        spatial.available = { [weak self] in guard let self = self else { return false }; return !self.panel.isVisible || self.retracting }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        writeState("hidden")
        run(initialCommand)
    }

    func startGestures() {
        guard ProcessInfo.processInfo.environment["SILL_GESTURES"] != "0" else {
            NSLog("sill: native gestures off (SILL_GESTURES=0)"); return
        }
        if gestures == nil { gestures = NativeGestures() }
        gestureHandler = { [weak self] cmd in
            NSLog("sill: three-finger swipe \(cmd)")
            self?.run(cmd)
        }
        let n = gestures?.begin() ?? 0
        NSLog("sill: native gestures listening on \(n) trackpad(s)")
        startScrollFilter()
    }

    /// Asks for Accessibility once, then keeps trying quietly until it's granted.
    func startScrollFilter() {
        if installScrollFilter() { NSLog("sill: three-finger scroll filter on"); return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        NSLog("sill: waiting for Accessibility permission to stop three-finger scrolling")
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { t in
            if installScrollFilter() { t.invalidate(); NSLog("sill: three-finger scroll filter on") }
        }
    }

    /// Trackpad listeners can go quiet across sleep, so start them again on wake.
    @objc func didWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startGestures() }
    }

    func applicationWillTerminate(_ n: Notification) {
        gestures?.end()
        saveNow()
        try? FileManager.default.removeItem(atPath: statePath)
    }

    // MARK: UI

    func buildPanel() {
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)   // over the menu bar, as part of it
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // The window is transparent and a little larger than the card, so the card's shadow has room.
        let size = timeSize
        let container = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 2 * shadowMargin,
                                             height: size.height + shadowMargin))
        container.wantsLayer = true
        panel.contentView = container

        // The card hangs from the menu bar: charcoal, flat on top where it meets the bar, rounded at the bottom.
        // `morph` carries the shadow and is what scales during the open / close animation.
        // The flares sit just outside the card's body, inside the shadow margin.
        let cardFrame = NSRect(x: shadowMargin - cardEar, y: shadowMargin, width: size.width + 2 * cardEar, height: size.height)
        let outline = contouredCard(NSRect(origin: .zero, size: cardFrame.size), ear: cardEar, radius: cardRadius)
        morph.frame = cardFrame
        morph.wantsLayer = true
        if let l = morph.layer {
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.55
            l.shadowRadius = 18
            l.shadowOffset = CGSize(width: 0, height: -6)
            l.shadowPath = outline
        }
        container.addSubview(morph)

        let root = RootView(frame: morph.bounds)
        root.wantsLayer = true
        // Liquid glass: the desktop behind, blurred and darkened, instead of a flat color.
        root.layer?.backgroundColor = midwater.withAlphaComponent(0.55).cgColor   // glass, tinted with Midwater
        let glass = NSVisualEffectView(frame: root.bounds)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.autoresizingMask = [.width, .height]
        root.addSubview(glass)
        let tint = NSView(frame: root.bounds)                     // the Midwater tint, over the blur
        tint.wantsLayer = true
        tint.layer?.backgroundColor = midwater.withAlphaComponent(0.6).cgColor
        tint.autoresizingMask = [.width, .height]
        root.addSubview(tint)
        cardRoot = root
        let mask = CAShapeLayer()
        mask.path = outline
        root.layer?.mask = mask
        root.onEnter = { [weak self] in self?.hoverWork?.cancel() }
        root.onExit = { [weak self] in self?.pointerLeft() }
        morph.addSubview(root)

        // The content, which blurs in and out with the morph.
        let effect = NSView(frame: NSRect(x: cardEar, y: 0, width: size.width, height: size.height))
        effect.wantsLayer = true
        effect.layerUsesCoreImageFilters = true
        stage = effect
        root.addSubview(effect)

        // Time surface: fills the panel.
        timeView.frame = effect.bounds
        timeView.autoresizingMask = [.width, .height]
        timeView.onClick = { [weak self] in self?.present(.pad) }
        // The vault search needs typing; the rest of the essentials panel never takes the keyboard.
        timeView.onKeyboard = { [weak self] v in
            guard let self = self, self.panel.isVisible else { return }
            if v == nil && self.mode == .pad { self.panel.makeFirstResponder(self.views[self.index].textView); return }
            if v == nil && self.mode == .notebook { self.panel.makeFirstResponder(self.terminal); return }
            if v == nil && self.mode == .hub { self.panel.makeFirstResponder(self.hubView.field); return }
            if let v = v {
                self.panel.allowsKey = true
                self.panel.makeKeyAndOrderFront(nil)
                self.panel.makeFirstResponder(v)
            } else if self.panel.isKeyWindow {
                self.panel.makeFirstResponder(nil)
                self.panel.allowsKey = false
                self.panel.orderOut(nil)
                self.panel.orderFrontRegardless()
            }
        }
        effect.addSubview(timeView)

        // Pad surface: small time header, the page strip, page dots.
        padView.frame = NSRect(origin: .zero, size: padSize)
        padView.autoresizingMask = [.width, .height]

        header.frame = NSRect(x: 0, y: padSize.height - headerHeight, width: padSize.width, height: headerHeight)
        header.autoresizingMask = [.width, .minYMargin]
        header.onClick = { [weak self] in self?.present(.time) }
        headerLabel.isHidden = true
        headerLabel.frame = NSRect(x: 0, y: 3, width: padSize.width, height: 15)
        headerLabel.autoresizingMask = [.width]
        headerLabel.alignment = .center
        headerLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        headerLabel.textColor = .tertiaryLabelColor
        header.addSubview(headerLabel)
        padView.addSubview(header)

        viewport.frame = NSRect(x: 0, y: footerHeight,
                                width: padSize.width, height: padSize.height - footerHeight - headerHeight)
        viewport.autoresizingMask = [.width, .height]
        viewport.autoresizesSubviews = false
        viewport.wantsLayer = true
        viewport.layer?.masksToBounds = true
        viewport.onResize = { [weak self] in self?.layoutStrip() }
        strip.wantsLayer = true
        viewport.addSubview(strip)
        padView.addSubview(viewport)

        pageLabel.frame = NSRect(x: 0, y: 5, width: padSize.width, height: 14)
        pageLabel.autoresizingMask = [.width, .maxYMargin]
        pageLabel.alignment = .center
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        pageLabel.textColor = .tertiaryLabelColor
        padView.addSubview(pageLabel)

        // Lay the pad out at its own size before attaching it, so the autoresizing masks start correct.
        padView.isHidden = true
        padView.frame = effect.bounds
        effect.addSubview(padView)

        // The essentials panels after essentials: the DEVONthink hub, then the notebook (the Claude CLI in your
        // Obsidian vault, in a real terminal).
        hubView.frame = effect.bounds
        hubView.autoresizingMask = [.width, .height]
        hubView.isHidden = true
        hubView.onNext = { [weak self] in self?.present(.notebook) }
        hubView.onBack = { [weak self] in self?.present(.time) }
        effect.addSubview(hubView)

        notebookView.frame = effect.bounds
        notebookView.autoresizingMask = [.width, .height]
        notebookView.isHidden = true
        notebookView.onBack = { [weak self] in self?.present(.hub) }
        let term = SillTerminal(frame: .zero)
        term.nativeBackgroundColor = .clear
        term.wantsLayer = true
        term.layer?.backgroundColor = NSColor.clear.cgColor
        term.subviews.filter { $0 is NSScroller }.forEach { $0.isHidden = true }   // no scroll bar, like Draftpad
        term.nativeForegroundColor = .white
        term.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        term.processDelegate = self
        notebookView.addSubview(term)
        notebookView.terminal = term
        effect.addSubview(notebookView)
        mediaView.frame = effect.bounds
        mediaView.autoresizingMask = [.width, .height]
        mediaView.isHidden = true
        effect.addSubview(mediaView)
        mediaView.setFrameSize(effect.bounds.size)
        notebookView.setFrameSize(effect.bounds.size)
        terminal = term

        // The edge controls ride above every surface.
        timeView.chrome.frame = effect.bounds
        timeView.chrome.autoresizingMask = [.width, .height]
        effect.addSubview(timeView.chrome)

        // Two fingers move along the essentials panels (one handler for the whole row).
        watchPanelSwipes()
    }

    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Sill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let pageItem = NSMenuItem(); main.addItem(pageItem)
        let page = NSMenu(title: "Topic"); pageItem.submenu = page
        let prev = page.addItem(withTitle: "Previous Topic", action: #selector(prevPage), keyEquivalent: "[")
        let next = page.addItem(withTitle: "Next Topic", action: #selector(nextPage), keyEquivalent: "]")
        let hideItem = page.addItem(withTitle: "Hide", action: #selector(hidePanel), keyEquivalent: "w")
        let clear = page.addItem(withTitle: "Clear Terminal", action: #selector(clearTerminal), keyEquivalent: "k")
        [prev, next, hideItem, clear].forEach { $0.target = self }

        NSApp.mainMenu = main
    }

    @objc func prevPage() { step(-1) }
    @objc func nextPage() { step(1) }
    @objc func hidePanel() { hide() }

    func updateClock() {
        let now = Date()
        let t = clockFormat.string(from: now)
        if headerLabel.stringValue != t { headerLabel.stringValue = t }
        if !timeView.isHidden { timeView.refresh() }
        rest.refresh(visible: !panel.isVisible || retracting)
        Bitwarden.shared.lockIfIdle()    // the strip shows only while the panel is closed
    }

    // MARK: Commands

    @objc func remoteCommand(_ n: Notification) {
        run((n.object as? String) ?? "show")
    }

    func run(_ cmd: String) {
        switch cmd {
        // Layers: hidden → essentials (and its panels) → Draftpad. Three fingers up go one layer up, down one down.
        case "up":     guard settled() else { return }
                       if !panel.isVisible { present(.time) } else if mode != .pad { present(.pad) }
        case "down":   guard settled() else { return }
                       if panel.isVisible {
                           switch mode { case .pad: present(.time); case .time, .hub, .notebook, .media: hide() }
                       }
        case "pad":    present(.pad)
        case "time":   present(.time)
        case "show":   present(mode)
        case "hide":   hide()
        case "toggle": toggle()
        case "quit":   saveNow(); NSApp.terminate(nil)
        case "background": break
        case "snapshot": snapshot()
        default:       present(.time)
        }
    }

    /// Writes what the card currently shows to /tmp/sill-snapshot.png (for checking layouts without a screenshot).
    func snapshot() {
        // Also the top of the screen around the strip, exactly as it looks (menu bar included).
        if let scr = NSScreen.main {
            let r = CGRect(x: scr.frame.midX - 480, y: 0, width: 960, height: 60)
            if let cg = CGWindowListCreateImage(r, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "/tmp/sill-menubar.png"))
            }
        }
        // What's actually on screen (Sill has Screen Recording permission), falling back to an offscreen render.
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/sill-snapshot.png"))
            return
        }
        guard let root = morph.subviews.first, let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { NSLog("sill: snapshot failed"); return }
        root.cacheDisplay(in: root.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/sill-snapshot.png"))
    }

    @objc func toggle() { panel.isVisible ? hide() : present(.pad) }

    /// True unless a change just happened, which would make this gesture a double-fire.
    func settled() -> Bool { Date().timeIntervalSince(lastChange) > repeatGuard }

    // MARK: Moving along the essentials panels
    //
    // One handler for the whole row (essentials → DEVONthink hub → notebook), so forward and back behave the same
    // everywhere: two fingers left → right go forward, right → left go back; one swipe moves one panel; and a swipe
    // that arrives while the card is still switching (or just after) is ignored rather than half-applied.
    private var rowTravel: CGFloat = 0
    private var rowArmed = false
    private var lastRowEvent = Date.distantPast
    private var rowSettling = false
    private var rowDX: CGFloat = 0
    private var rowQuiet: DispatchWorkItem?
    let rowOrder: [Mode] = [.time, .hub, .notebook, .media]

    func rowView(_ m: Mode) -> NSView? {
        switch m { case .time: return timeView; case .hub: return hubView; case .notebook: return notebookView
                   case .media: return mediaView; case .pad: return nil }
    }

    /// Lays the current panel and the one you're pulling in side by side, offset by the finger travel. Forward
    /// panels wait on the left (fingers left → right bring them in), the previous one on the right.
    func rowLayout() {
        guard let i = rowOrder.firstIndex(of: mode), let cur = rowView(mode), let w = cur.superview?.bounds.width else { return }
        var dx = rowDX
        if dx > 0 && i == rowOrder.count - 1 { dx *= 0.25 }            // nothing after the last panel
        if dx < 0 && i == 0 { dx *= 0.25 }                              // essentials is the start
        dx = max(-w, min(w, dx))
        let h = cur.superview!.bounds.height
        cur.frame = NSRect(x: dx, y: 0, width: w, height: h)
        for (k, m) in rowOrder.enumerated() where m != mode {
            guard let v = rowView(m) else { continue }
            let neighbor = (dx > 0 && k == i + 1) || (dx < 0 && k == i - 1)
            v.isHidden = !neighbor
            if neighbor { v.frame = NSRect(x: dx > 0 ? dx - w : dx + w, y: 0, width: w, height: h) }
        }
    }

    func rowDrag(_ d: CGFloat) {
        if rowDX == 0, d != 0 {
            // The edge controls (bars, the recorder pill) step aside while panels move, so nothing floats over the
            // slide; they come back when it lands.
            if !timeView.trayPinned { timeView.showRecorderTray(false) }
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; timeView.chrome.animator().alphaValue = 0 }
            // A new pull: get the panel coming in ready (the hub's list, the notebook's session).
            if let i = rowOrder.firstIndex(of: mode) {
                let j = i + (d > 0 ? 1 : -1)
                if rowOrder.indices.contains(j) {
                    if rowOrder[j] == .hub { hubView.surfaced() }
                    if rowOrder[j] == .notebook { startTerminalIfNeeded() }
                }
            }
        }
        rowDX += d
        rowLayout()
    }

    func rowFinish() {
        rowQuiet?.cancel()
        guard !rowSettling, rowDX != 0, let i = rowOrder.firstIndex(of: mode), let cur = rowView(mode),
              let w = cur.superview?.bounds.width else { rowDX = 0; timeView.chrome.alphaValue = 1; return }
        let threshold = min(60, w * 0.2)
        var j = i
        if rowDX > threshold, i + 1 < rowOrder.count { j = i + 1 }
        else if rowDX < -threshold, i > 0 { j = i - 1 }
        let target = rowOrder[j]
        let h = cur.superview!.bounds.height
        rowSettling = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if j == i {
                cur.animator().frame = NSRect(x: 0, y: 0, width: w, height: h)
                for m in rowOrder where m != mode {
                    if let v = rowView(m), !v.isHidden { v.animator().frame.origin.x = rowDX > 0 ? -w : w }
                }
            } else {
                cur.animator().frame.origin.x = j > i ? w : -w
                rowView(target)?.animator().frame = NSRect(x: 0, y: 0, width: w, height: h)
            }
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.18; self.timeView.chrome.animator().alphaValue = 1 }
            self.rowSettling = false
            self.rowDX = 0
            for m in self.rowOrder { self.rowView(m)?.frame = NSRect(x: 0, y: 0, width: w, height: h) }
            if j != i { self.landPanel(target) }
            else { for m in self.rowOrder where m != self.mode { self.rowView(m)?.isHidden = true } }
        })
    }

    /// Makes `m` the current panel without any further animation (the slide already happened).
    func landPanel(_ m: Mode) {
        saveNow()
        mode = m
        lastChange = Date()
        hoverWork?.cancel()
        transition += 1
        writeState(m.rawValue)
        show(m, screen: panel.screen, animate: false)
    }
    private var rowAxis = 0                    // 0 undecided, 1 sideways (panels), 2 up/down (lists)
    private var rowMonitor: Any?
    func watchPanelSwipes() {
        rowMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self = self, e.window === self.panel, self.panel.isVisible, !self.retracting,
                  [.time, .hub, .notebook, .media].contains(self.mode) else { return e }
            // Where a swipe starts decides whose it is (the day strip and the horizon keep theirs). Once a pull is
            // under way it stays the row's to the end, wherever the moving panel now puts the pointer; checking
            // again mid-pull lost the lift and left the panels stuck halfway.
            let starting = e.phase == .began || e.phase == .mayBegin
            // A new touch forgets the last gesture's direction first, so a swipe that starts on the horizon or
            // the day strip is theirs (keeping the old direction is what stole the horizon's swipes).
            if starting && self.rowDX == 0 { self.rowAxis = 0 }
            let pulling = self.rowDX != 0 || self.rowAxis == 1
            if self.mode == .time && !pulling && !self.timeView.panelSwipeZone(e.locationInWindow) { return e }
            // A new gesture re-arms. Its opening event can be swallowed by whatever is under the pointer (a list,
            // a text field), so a pause of a quarter second between scroll events also counts as a new gesture.
            let now = Date()
            // Mid-pull, a pause is a hold (fingers resting), not a new gesture: only a real new touch starts over.
            let newTouch = e.phase == .began || e.phase == .mayBegin
            if newTouch || (self.rowDX == 0 && now.timeIntervalSince(self.lastRowEvent) > 0.25) {
                if self.rowDX != 0 { self.rowFinish() }            // a previous pull that never ended settles first
                self.rowTravel = 0; self.rowArmed = true; self.rowAxis = 0
            }
            self.lastRowEvent = now
            guard e.hasPreciseScrollingDeltas else { return e }
            // Each gesture picks one axis on its first real movement and keeps it. A sideways gesture is then
            // entirely Sill's (lists underneath never see a sliver of it, which is what made the lower half lag);
            // an up/down one is entirely the list's.
            if self.rowAxis == 0 {
                let dx = abs(e.scrollingDeltaX), dy = abs(e.scrollingDeltaY)
                if dx + dy < 0.5 { return e }
                self.rowAxis = dx > dy * 0.8 ? 1 : 2
            }
            if self.rowAxis == 2 { return e }
            guard e.momentumPhase.isEmpty else { return nil }
            // The same feel as Draftpad's topics: the panels follow your fingers, then settle (0.22 s, ease out).
            let d = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
            if !self.rowSettling { self.rowDrag(d) }
            if e.phase == .ended || e.phase == .cancelled { self.rowFinish() }
            else {
                // Holding two fingers still keeps both panels where they are, for as long as you hold; it settles
                // when you lift. (Safety: if the lift is never reported, it settles after 20 quiet seconds.)
                self.rowQuiet?.cancel()
                let w = DispatchWorkItem { [weak self] in self?.rowFinish() }
                self.rowQuiet = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: w)
            }
            return nil
        }
    }

    // MARK: Show / hide

    /// The screen to appear on: the one under the pointer, which is where the user's attention is.
    func targetScreen() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }

    /// Top-center of the screen, just under the menu bar.
    func frame(for m: Mode, on screen: NSScreen?) -> NSRect {
        let card = m == .pad ? padSize : timeSize
        let size = NSSize(width: card.width + 2 * shadowMargin, height: card.height + shadowMargin)
        guard let s = screen else { return NSRect(origin: .zero, size: size) }
        let top = s.frame.maxY                     // flush with the top of the screen: the panel hangs from the menu bar
        return NSRect(x: (s.frame.midX - size.width / 2).rounded(), y: (top - size.height).rounded(),
                      width: size.width, height: size.height)
    }

    // MARK: Morph
    //
    // Opening: the card grows out of the menu bar from its top center with a soft spring, while its content
    // goes from blurred to sharp. Closing: the reverse, quicker, and it fades into the bar.

    /// A transform that scales the card about its top center (where it meets the menu bar).
    func shrunk(_ sx: CGFloat, _ sy: CGFloat) -> CATransform3D {
        let w = morph.bounds.width, h = morph.bounds.height
        var t = CATransform3DMakeTranslation(w / 2, h, 0)
        t = CATransform3DScale(t, sx, sy, 1)
        return CATransform3DTranslate(t, -w / 2, -h, 0)
    }

    func blur(_ from: CGFloat, _ to: CGFloat, duration: TimeInterval) {
        guard let l = stage?.layer, let f = CIFilter(name: "CIGaussianBlur") else { return }
        f.name = "blur"
        f.setValue(to, forKey: kCIInputRadiusKey)
        l.filters = to > 0 ? [f] : []
        let a = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        a.fromValue = from; a.toValue = to; a.duration = duration
        if to == 0 {
            l.filters = [f]; f.setValue(0, forKey: kCIInputRadiusKey)
            a.isRemovedOnCompletion = true
        }
        l.add(a, forKey: "blur")
    }

    /// The card squeezed to the strip's shape: the width of the strip, the height of the menu bar.
    func restShape() -> CATransform3D {
        let s = panel.screen ?? targetScreen() ?? NSScreen.main!
        return shrunk(restWidth / morph.bounds.width, RestStrip.menuBarHeight(s) / morph.bounds.height)
    }

    func morphIn() {
        guard let l = morph.layer else { return }
        l.removeAllAnimations()
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: restShape())
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1; spring.stiffness = 210; spring.damping = 19; spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        l.transform = CATransform3DIdentity
        l.add(spring, forKey: "morph")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.16
        l.opacity = 1
        l.add(fade, forKey: "fade")
        blur(14, 0, duration: 0.3)
    }

    func morphOut(_ done: @escaping () -> Void) {
        guard let l = morph.layer else { done(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        shrink.toValue = NSValue(caTransform3D: restShape())
        shrink.duration = morphOutDuration
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        shrink.fillMode = .forwards; shrink.isRemovedOnCompletion = false
        l.add(shrink, forKey: "morph")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = morphOutDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .forwards; fade.isRemovedOnCompletion = false
        l.add(fade, forKey: "fade")
        blur(0, 10, duration: morphOutDuration)
        CATransaction.commit()
    }

    /// Shows surface `m`. Opening grows the card out of the menu bar; switching between surfaces uses the same
    /// motion (the card folds back into the bar, then grows out again showing the other surface).
    func present(_ m: Mode) {
        let wasVisible = panel.isVisible && !retracting
        let switching = wasVisible && mode != m
        if m != .pad { cancelDrag() }
        if m != .pad || mode == .pad { saveNow() }
        mode = m
        lastChange = Date()
        hoverWork?.cancel()
        retracting = false
        transition += 1
        let token = transition
        writeState(m.rawValue)

        if switching {
            morphOut { [weak self] in
                guard let self = self, self.transition == token else { return }   // a newer request won
                self.show(m, screen: self.panel.screen)
            }
        } else if wasVisible {
            show(m, screen: panel.screen, animate: false)
        } else {
            show(m, screen: targetScreen())
        }
    }

    /// Puts surface `m` in the card and brings the card up (growing out of the menu bar when `animate`).
    func show(_ m: Mode, screen: NSScreen?, animate: Bool = true) {
        if m != .time { timeView.vault.lock() }        // leaving the panel locks the vault
        updateClock()
        timeView.isHidden = m != .time
        padView.isHidden = m != .pad
        hubView.isHidden = m != .hub
        notebookView.isHidden = m != .notebook
        mediaView.isHidden = m != .media
        if m == .time { timeView.surfaced() }
        if m == .hub { hubView.surfaced() }
        if m == .notebook { startTerminalIfNeeded() }
        let target = frame(for: m, on: screen ?? targetScreen())

        if m == .time && panel.isKeyWindow {
            // Give the keyboard back to the app underneath; the time view never holds it.
            panel.makeFirstResponder(nil)
            panel.allowsKey = false
            panel.orderOut(nil)
        }
        panel.allowsKey = m != .time
        panel.setFrame(target, display: true)
        rest.place(on: panel.screen)
        rest.window.orderOut(nil)
        if animate { morphIn() } else {
            morph.layer?.removeAllAnimations()
            morph.layer?.opacity = 1
            morph.layer?.transform = CATransform3DIdentity
            stage?.layer?.removeAnimation(forKey: "blur")
            stage?.layer?.filters = []
        }
        if m == .pad {
            panel.makeKeyAndOrderFront(nil)
            if views.indices.contains(index) { panel.makeFirstResponder(views[index].textView) }
        } else if m == .notebook, let t = terminal {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(t)
        } else if m == .hub {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(hubView.field)
        } else if m == .media {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    // Terminal housekeeping.
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    /// `exit` (or ⌃D) ends the session; the next time the terminal opens it starts a fresh one.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.terminalStarted = false
            self.terminal?.getTerminal().resetToInitialState()
            if self.mode == .notebook && self.panel.isVisible { self.startTerminalIfNeeded() }
        }
    }

    /// ⌘K: clear the screen and the scrollback, keep the session (like Terminal.app).
    @objc func clearTerminal() {
        guard mode == .notebook, let t = terminal else { return }
        t.getTerminal().resetToInitialState()
        t.send(txt: "\u{0C}")                       // ⌃L: the shell redraws its prompt
    }

    /// The notebook starts the first time it's shown: the Claude CLI in your Obsidian vault (through a login shell,
    /// so your usual setup applies). If Claude exits, the next visit starts it again.
    func startTerminalIfNeeded() {
        guard !terminalStarted, let t = terminal else { return }
        terminalStarted = true
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let vault = (notePath as NSString).deletingLastPathComponent
        FileManager.default.changeCurrentDirectoryPath(vault)
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        t.startProcess(executable: shell, args: ["-l", "-c", "cd \(Devon.quote(vault)) && exec claude"],
                       environment: env.map { "\($0)=\($1)" }, execName: "-" + (shell as NSString).lastPathComponent)
    }

    func hide() {
        timeView.vault.lock()
        if !timeView.preflight.isHidden { timeView.closePreflight() }
        if !timeView.audioSheet.isHidden { timeView.showAudio(false) }
        cancelDrag()
        saveNow()
        hoverWork?.cancel()
        panel.makeFirstResponder(nil)
        panel.allowsKey = false
        lastChange = Date()
        writeState("hidden")
        transition += 1
        let token = transition
        guard panel.isVisible, !retracting else { return }
        // Shrink back up into the menu bar, blurring and fading, then leave the screen.
        retracting = true
        morphOut { [weak self] in
            guard let self = self, self.retracting, self.transition == token else { return }   // a summon wins
            self.retracting = false
            self.panel.orderOut(nil)
            self.morph.layer?.removeAllAnimations()
            self.stage?.layer?.filters = []
        }
    }

    /// The card's rectangle on screen (the window around it is larger, to leave room for the shadow).
    func cardOnScreen() -> NSRect { panel.convertToScreen(morph.convert(morph.bounds, to: nil)) }

    /// The pointer left the panel: close after a short grace period, unless it comes back.
    func pointerLeft() {
        guard closeOnHoverAway, panel.isVisible, !retracting else { return }
        if mode == .notebook || mode == .hub || mode == .media { return }          // typing in the notebook or the hub: stay
        if !timeView.audioSheet.isHidden { return }              // the audio menu stays open until you close it
        if mode == .time && timeView.vault.busy { return }     // don't vanish under the Touch ID prompt or an open vault
        hoverWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.panel.isVisible,
                  !NSMouseInRect(NSEvent.mouseLocation, self.cardOnScreen(), false) else { return }
            self.hide()
        }
        hoverWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverAwayDelay, execute: w)
    }

    func cancelDrag() {
        if dragging { dragging = false; dragX = 0; layoutStrip() }
    }

    @objc func screensChanged() {
        rest.place(on: panel.isVisible ? panel.screen : targetScreen())
        guard panel.isVisible else { return }
        panel.setFrame(frame(for: mode, on: panel.screen ?? targetScreen()), display: true)
    }

    /// Keeps the file behind `sill status` correct even if /tmp is cleaned while the app runs.
    func restoreState() {
        if !FileManager.default.fileExists(atPath: statePath) {
            writeState(panel.isVisible ? mode.rawValue : "hidden")
        }
    }

    // MARK: Strip layout

    func layoutStrip() {
        let w = viewport.bounds.width, h = viewport.bounds.height
        guard w > 0, !views.isEmpty else { return }
        let drag = dragging ? effectiveDrag() : 0
        // Topics run right to left: the next one waits on the left, so two fingers moving left → right bring it in.
        let n = CGFloat(views.count)
        strip.frame = NSRect(x: -(n - 1 - CGFloat(index)) * w + drag, y: 0, width: w * n, height: h)
        for (i, v) in views.enumerated() {
            v.scroll.frame = NSRect(x: (n - 1 - CGFloat(i)) * w, y: 0, width: w, height: h)
        }
    }

    /// Finger offset with rubber-banding when there's nowhere to go.
    func effectiveDrag() -> CGFloat {
        let w = viewport.bounds.width
        var v = dragX
        if v > 0 && index >= views.count - 1 { v *= 0.25 }     // nowhere newer to go (this topic is still blank)
        if v < 0 && index <= 0 { v *= 0.25 }                    // the first topic is the start of the page
        return max(-w, min(w, v))
    }

    func updateLabel() {
        if views.count <= 8 {
            // Newest on the left, like the topics themselves.
            pageLabel.stringValue = views.indices.reversed().map { $0 == index ? "●" : "○" }.joined(separator: " ")
        } else {
            pageLabel.stringValue = "\(index + 1) / \(views.count)"
        }
    }

    // MARK: Pages

    @discardableResult
    func appendView(_ text: String) -> PageView {
        let pv = PageView(frame: NSRect(origin: .zero, size: viewport.bounds.size))
        pv.textView.delegate = self
        pv.textView.onDrag = { [weak self] dx, ended in self?.handleDrag(dx, ended: ended) }
        pv.textView.onEscape = { [weak self] in self?.hide() }

        let saved = cursors[views.count]
        pv.textView.string = text
        styleStamp(pv.textView)
        views.append(pv)
        strip.addSubview(pv.scroll)
        layoutStrip()

        let len = (text as NSString).length
        pv.textView.setSelectedRange(NSRange(location: min(saved ?? len, len), length: 0))
        return pv
    }

    func removeLastView() {
        guard let v = views.popLast() else { return }
        v.scroll.removeFromSuperview()
        cursors[views.count] = nil
        layoutStrip()
    }

    /// Keyboard paging (Cmd+[ / Cmd+]).
    func step(_ delta: Int) {
        guard mode == .pad, !settling, !dragging else { return }
        let target = index + delta
        if target < 0 { bounce(); return }
        if target >= views.count {
            guard !isBlank(views[index].textView.string) else { bounce(); return }
            appendView(dateStamp() + "\n\n")
        }
        settle(to: target)
    }

    func handleDrag(_ dx: CGFloat, ended: Bool) {
        guard !settling else { return }
        dragging = true
        dragX += dx

        // Pulling past the last topic (fingers left → right) reveals a fresh one, dated, but only if this one has
        // something on it.
        if dragX > 8, index == views.count - 1, !isBlank(views[index].textView.string) {
            appendView(dateStamp() + "\n\n")
        }
        layoutStrip()
        updateLabel()
        if ended { finishDrag() }
    }

    func finishDrag() {
        let threshold = min(60, viewport.bounds.width * 0.2)
        var target = index
        if dragX > threshold, index < views.count - 1 { target = index + 1 }
        else if dragX < -threshold, index > 0 { target = index - 1 }
        dragging = false
        dragX = 0
        settle(to: target)
    }

    func settle(to target: Int) {
        let w = viewport.bounds.width
        if views.indices.contains(index) {
            cursors[index] = views[index].textView.selectedRange().location
        }
        index = target
        settling = true
        updateLabel()

        let dest = NSRect(x: -(CGFloat(views.count) - 1 - CGFloat(target)) * w, y: 0, width: strip.frame.width, height: strip.frame.height)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            strip.animator().frame = dest
        }, completionHandler: { [weak self] in self?.finishSettle() })
    }

    func finishSettle() {
        settling = false
        if !dragging {
            // Walking away from a blank trailing page removes it.
            while views.count > 1, views.count - 1 > index, isBlank(views[views.count - 1].textView.string) {
                removeLastView()
            }
        }
        layoutStrip()
        updateLabel()
        if mode == .pad && panel.isKeyWindow { panel.makeFirstResponder(views[index].textView) }
        saveNow()
    }

    func bounce() {
        guard let layer = strip.layer else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -7, 7, -3, 0]
        a.duration = 0.2
        layer.add(a, forKey: "bounce")
    }

    // MARK: Text delegate

    func textDidChange(_ notification: Notification) {
        if let tv = notification.object as? NSTextView { styleStamp(tv) }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in self?.saveNow() }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView,
              let i = views.firstIndex(where: { $0.textView === tv }) else { return }
        cursors[i] = tv.selectedRange().location
    }

    // MARK: File I/O (unchanged from draftpad)

    func mtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: notePath))?[.modificationDate] as? Date
    }

    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (notePath as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: notePath) { fm.createFile(atPath: notePath, contents: nil) }
        let text = (try? String(contentsOfFile: notePath, encoding: .utf8)) ?? ""
        lastWritten = text
        lastMTime = mtime()
        for t in parsePages(text) { appendView(t) }
    }

    func saveNow() {
        saveTimer?.invalidate(); saveTimer = nil
        guard ready, !views.isEmpty else { return }
        let text = texts.joined(separator: pageJoiner)
        if text != lastWritten {
            try? text.write(toFile: notePath, atomically: true, encoding: .utf8)
            lastWritten = text
        }
        lastMTime = mtime()
        let d = UserDefaults.standard
        d.set(index, forKey: "page")
        if views.indices.contains(index) {
            d.set(views[index].textView.selectedRange().location, forKey: "cursor")
        }
    }

    func pollExternal() {
        guard saveTimer == nil, !dragging, !settling, let m = mtime(), m != lastMTime else { return }
        lastMTime = m
        guard let text = try? String(contentsOfFile: notePath, encoding: .utf8) else { return }
        let new = parsePages(text)
        if new == texts { return }
        lastWritten = text

        if new.count == views.count {
            for (i, t) in new.enumerated() where views[i].textView.string != t {
                let tv = views[i].textView
                let sel = tv.selectedRange().location
                tv.string = t
                tv.setSelectedRange(NSRange(location: min(sel, (t as NSString).length), length: 0))
            }
        } else {
            while !views.isEmpty { removeLastView() }
            for t in new { appendView(t) }
            index = min(index, views.count - 1)
            layoutStrip()
        }
        updateLabel()
    }
}

// MARK: - Entry point

let commands = ["up", "down", "pad", "time", "show", "hide", "toggle", "quit", "status", "background", "snapshot"]

// Single instance, enforced with a lock file. Holding the lock means "I am the running copy".
let lockFD = open("/tmp/local.sill.lock", O_CREAT | O_RDWR, 0o600)
let holdsLock = lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) == 0

var initial = "time"
if let cmd = CommandLine.arguments.dropFirst().first {
    guard commands.contains(cmd) else {
        fputs("usage: sill [up|down|pad|time|show|hide|toggle|quit|status|background|snapshot]\n", stderr)
        exit(64)
    }
    if cmd == "status" {
        if holdsLock { print("not running"); exit(1) }
        guard let state = readState() else { print("unknown"); exit(1) }
        print(state)
        exit(0)
    }
    if !holdsLock {
        // A copy is already running: hand it the command and leave.
        DistributedNotificationCenter.default().postNotificationName(
            commandName, object: cmd, userInfo: nil, deliverImmediately: true)
        exit(0)
    }
    if cmd == "hide" || cmd == "quit" {
        fputs("sill is not running\n", stderr)
        exit(1)
    }
    // Nothing is running: launch, then act on the command. A first "toggle" or "up" opens the pad.
    initial = (cmd == "toggle" || cmd == "up") ? "pad" : (cmd == "down" ? "time" : cmd)
} else if !holdsLock {
    // Plain launch while a copy is already running: show the time there.
    DistributedNotificationCenter.default().postNotificationName(
        commandName, object: "time", userInfo: nil, deliverImmediately: true)
    exit(0)
}

writeState("hidden")

// However Sill was started (login item, Finder, macOS reopening it after a permission), its log goes to one place.
if isatty(STDERR_FILENO) == 0 {
    freopen(NSHomeDirectory() + "/Library/Logs/sill.log", "a", stderr)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appDelegate = App(initialCommand: initial)
app.delegate = appDelegate
app.run()
