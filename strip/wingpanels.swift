import AppKit
import WebKit

// The wings in native floating panels (owner, 2026-11-08): one panel per screen edge, at Notification Center's place
// (the right one just below the menu bar, inset from the right edge; the left one its exact mirror), above every
// window, on every Space, never taking typing focus. Each panel hosts the same bundled editor page in wings-only mode
// (editor/src/wingpanel.js), through an EditorHost of its own, so the cards, their state, the calendar saves and
// "Move to the other side" are wings.js itself, shared with iOS. The page lays out the cards and reports where they
// are; the panel draws Notification Center's frosted glass (NSVisualEffectView) behind each one, and the desktop
// shows between them.
//
// Summoned (owner, 2026-11-08) by three fingers sideways on the trackpad (app.swift, trackThree; `wingSwipe` below),
// the Recense menu, the editor's right-click menu, `recense wing-left|wing-right`, or the editor's voice moves;
// Recense's own window needn't be open. No long holds on the Mac (owner).
// A summoned wing stays locked open, whatever Recense does, until its ×, the three-finger swipe that puts it away,
// or the menu. No click outside or Esc closes it.
// It slides in from its edge as Notification Center does; Reduce Motion: it appears.

enum WingSide: String, CaseIterable { case left, right }

/// Three fingers sideways: leftward brings out the right wing, rightward the left one (both can be out). Leftward from
/// the middle of the trackpad puts the left wing back in while it's out, rightward from the middle the right one; a
/// swipe that has nothing to open puts the other wing in. nil: nothing to do.
func wingSwipe(dir: Int, startX: Float, left: Bool, right: Bool) -> (side: WingSide, open: Bool)? {
    let middle = startX >= 0.3 && startX <= 0.7
    if dir < 0 {
        if middle && left { return (.left, false) }
        if !right { return (.right, true) }
        return left ? (.left, false) : nil
    }
    if middle && right { return (.right, false) }
    if !left { return (.left, true) }
    return right ? (.right, false) : nil
}

/// Read by the trackpad thread (app.swift): which wings are open, so a swipe toward that edge closes it.
var gWingOpenLeft = false, gWingOpenRight = false

/// Becomes key only when something in it needs typing (a click in a field), so opening it never moves focus.
final class WingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class WingPanels {
    static let width: CGFloat = 360
    static let edgeInset: CGFloat = 8      // from the screen's side edge, as Notification Center
    static let topGap: CGFloat = 6         // below the menu bar
    static let bottomGap: CGFloat = 8

    private struct Wing {
        let panel: WingPanel
        let stage: FlippedView              // what slides; the panel itself never leaves its screen
        let host: EditorHost
        var glass: [NSVisualEffectView] = []
        var height: CGFloat = 0
        var width: CGFloat = WingPanels.width   // grows with Recense's line (the page asks, 360–560)
        var ready = false
    }
    private var wings: [WingSide: Wing] = [:]
    private(set) var open: Set<WingSide> = []
    private var pendingShow: Set<WingSide> = []
    private var transition: [WingSide: Int] = [:]

    let vault: URL, cache: URL
    /// The pad's current text, for the Agenda card.
    var currentText: () -> String = { "" }
    /// The editor's own host, kept in step with the panels' wings state.
    var editor: () -> EditorHost? = { nil }
    /// A card cites into the page / jumps to a line in it.
    var onInsert: ((String) -> Void)?
    var onJump: ((Int) -> Void)?
    /// Recense's line on screen (words, translation), for both wings' Recense card.
    private var line = ("", "")
    func setRecenseLine(_ original: String, _ translation: String) {
        line = (original, translation)
        for w in wings.values { w.host.send("setRecenseLine(\(jsString(original)), \(jsString(translation)))") }
    }

    /// Extra entries for a panel's right-click menu.
    var menuItems: () -> [NSMenuItem] = { [] }

    init(vault: URL, cache: URL) { self.vault = vault; self.cache = cache }

    func isOpen(_ s: WingSide) -> Bool { open.contains(s) }

    func toggle(_ s: WingSide) { isOpen(s) ? hide(s) : show(s) }

    /// Three fingers sideways (app.swift): see `wingSwipe`.
    func swipe(_ dir: Int, from x: Float) {
        guard let d = wingSwipe(dir: dir, startX: x, left: isOpen(.left), right: isOpen(.right)) else { return }
        d.open ? show(d.side) : hide(d.side, "three-finger swipe")
    }

    /// The page's request: op is open / close / toggle; side is left, right or both.
    func handle(op: String, side: String) {
        let sides: [WingSide] = side == "both" ? WingSide.allCases : WingSide(rawValue: side).map { [$0] } ?? []
        for s in sides {
            switch op {
            case "open": show(s)
            case "close": hide(s, "the page")
            case "toggle": toggle(s)
            default: break
            }
        }
    }

    // MARK: Showing

    func show(_ s: WingSide) {
        guard !open.contains(s) else { return }
        let w = wing(s)
        open.insert(s); syncFlags()
        transition[s, default: 0] += 1
        w.host.setText(currentText())
        w.host.send("setArranging(false)")       // Move controls hidden at rest, every time it opens
        w.host.send("setRecenseLine(\(jsString(line.0)), \(jsString(line.1)))")
        guard w.ready else { pendingShow.insert(s); return }   // first time: once the page has laid itself out
        present(s)
    }

    private func present(_ s: WingSide) {
        guard let w = wings[s] else { return }
        let screen = WingPanels.pointerScreen()
        w.panel.setFrame(frame(s, height: w.height, width: w.width, on: screen), display: false)
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        w.stage.frame = w.panel.contentView?.bounds ?? .zero
        w.panel.alphaValue = 1
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        if still {
            w.panel.orderFrontRegardless()
        } else {
            // In from the edge, inside the panel's own bounds, so nothing shows on a neighbouring display.
            var start = w.stage.frame
            start.origin.x = s == .right ? start.width + WingPanels.edgeInset : -(start.width + WingPanels.edgeInset)
            w.stage.frame = start
            w.panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.26
                c.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                w.stage.animator().setFrameOrigin(.zero)
            }
        }
        log("wings: \(s.rawValue) open\(still ? " (still)" : "")")
    }

    func hide(_ s: WingSide, _ why: String = "asked") {
        pendingShow.remove(s)
        guard open.contains(s), let w = wings[s] else { return }
        open.remove(s); syncFlags()
        transition[s, default: 0] += 1
        let t = transition[s]
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let done = { [weak self] in
            guard let self = self, self.transition[s] == t else { return }
            w.panel.orderOut(nil); w.panel.alphaValue = 1; w.stage.setFrameOrigin(.zero)
        }
        if still || !w.panel.isVisible { done(); return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.2
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.stage.animator().setFrameOrigin(NSPoint(x: s == .right ? w.stage.frame.width + WingPanels.edgeInset
                                                                     : -(w.stage.frame.width + WingPanels.edgeInset), y: 0))
        }, completionHandler: done)
        log("wings: \(s.rawValue) closed (\(why))")
    }

    func hideAll(_ why: String = "asked") { open.forEach { hide($0, why) } }

    /// The pad's text changed: open panels rescan their Agenda.
    func textChanged(_ text: String) { for s in open { wings[s]?.host.setText(text) } }

    private func syncFlags() { gWingOpenLeft = open.contains(.left); gWingOpenRight = open.contains(.right) }

    // MARK: Geometry

    static func pointerScreen() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    /// Notification Center's place: below the menu bar, inset from the side edge; as tall as the cards, at most
    /// down to the bottom of the screen (above the Dock).
    func frame(_ s: WingSide, height: CGFloat, width: CGFloat = WingPanels.width, on screen: NSScreen?) -> NSRect {
        let v = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxH = v.height - WingPanels.topGap - WingPanels.bottomGap
        let h = min(max(height, 60), maxH)
        let wd = min(max(width, WingPanels.width), 560)
        let x = s == .right ? v.maxX - wd - WingPanels.edgeInset : v.minX + WingPanels.edgeInset
        return NSRect(x: x.rounded(), y: (v.maxY - WingPanels.topGap - h).rounded(), width: wd.rounded(), height: h.rounded())
    }

    // MARK: The panel and its page

    private func wing(_ s: WingSide) -> Wing {
        if let w = wings[s] { return w }
        let screen = WingPanels.pointerScreen()
        let f = frame(s, height: 200, on: screen)
        let p = WingPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.isMovable = false
        p.worksWhenModal = true
        p.appearance = NSAppearance(named: .darkAqua)
        let root = NSView(frame: NSRect(origin: .zero, size: f.size))
        root.autoresizingMask = [.width, .height]
        let stage = FlippedView(frame: root.bounds)
        stage.autoresizingMask = [.width, .height]
        root.addSubview(stage)
        p.contentView = root

        let host = EditorHost(frame: stage.bounds, vault: vault, cache: cache, wingSide: s.rawValue)
        host.web.autoresizingMask = [.width, .height]
        host.web.underPageBackgroundColor = .clear
        host.web.clickThrough = true
        host.web.extraItems = { [weak self] in self?.panelMenu(s) ?? [] }
        stage.addSubview(host.web)
        host.onWingMessage = { [weak self] d in self?.message(d, from: s) }
        host.onWingsSaved = { [weak self] json in self?.broadcast(json, except: host) }
        host.onEventsSaved = { [weak self] in self?.eventsSaved(except: host) }
        host.onLoad = {
            // The page lays itself out within a frame; a slow first layout still opens after half a second.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.becameReady(s) }
        }
        let w = Wing(panel: p, stage: stage, host: host)
        wings[s] = w
        return w
    }

    private func becameReady(_ s: WingSide) {
        guard var w = wings[s], !w.ready else { return }
        w.ready = true; wings[s] = w
        if pendingShow.remove(s) != nil, open.contains(s) { present(s) }
    }

    private func message(_ d: [String: Any], from s: WingSide) {
        switch d["action"] as? String {
        case "wing":
            handle(op: d["op"] as? String ?? "", side: d["side"] as? String ?? s.rawValue)
        case "insert":
            if let t = d["text"] as? String, !t.isEmpty { onInsert?(t) }
        case "jumpToLine":
            onJump?((d["line"] as? NSNumber)?.intValue ?? 1)
        case "layout":
            layout(s, height: CGFloat((d["height"] as? NSNumber)?.doubleValue ?? 0),
                   width: CGFloat((d["width"] as? NSNumber)?.doubleValue ?? Double(WingPanels.width)),
                   glass: d["glass"] as? [[NSNumber]] ?? [])
        default: break
        }
    }

    /// The page's shapes, in its own (top-left) coordinates: [x, y, width, height, opacity, corner radius].
    private func layout(_ s: WingSide, height: CGFloat, width: CGFloat, glass shapes: [[NSNumber]]) {
        guard var w = wings[s] else { return }
        let grew = height > 0 && abs(height - w.height) >= 1, widened = abs(width - w.width) >= 1
        if grew || widened {
            if height > 0 { w.height = height }
            w.width = width
            if w.panel.isVisible {
                // Grow or shrink from the top (and from the outer edge), as Notification Center does; the stage
                // keeps its slide offset.
                let x = w.stage.frame.origin.x
                let f = frame(s, height: w.height, width: w.width, on: w.panel.screen)
                w.panel.setFrame(f, display: true)
                w.stage.frame = NSRect(x: x, y: 0, width: f.width, height: f.height)
            }
        }
        while w.glass.count < shapes.count {
            let g = NSVisualEffectView()
            g.material = .hudWindow
            g.blendingMode = .behindWindow
            g.state = .active
            g.appearance = NSAppearance(named: .darkAqua)
            w.stage.addSubview(g, positioned: .below, relativeTo: w.host.web)
            w.glass.append(g)
        }
        for (i, g) in w.glass.enumerated() {
            guard i < shapes.count, shapes[i].count >= 6 else { g.isHidden = true; continue }
            let v = shapes[i].map { CGFloat($0.doubleValue) }
            g.isHidden = false
            g.frame = NSRect(x: v[0], y: v[1], width: v[2], height: v[3])
            g.alphaValue = v[4]
            let r = v[5].rounded()
            if g.maskImage?.capInsets.top != r { g.maskImage = WingPanels.roundedMask(r) }
        }
        wings[s] = w
        if !w.ready { DispatchQueue.main.async { [weak self] in self?.becameReady(s) } }
    }

    private static var masks: [CGFloat: NSImage] = [:]
    /// A stretchable rounded rectangle (continuous corners) that clips the glass to the card's shape.
    static func roundedMask(_ r: CGFloat) -> NSImage {
        if let m = masks[r] { return m }
        let side = r * 2 + 1
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        masks[r] = img
        return img
    }

    // MARK: One state across the pages

    private func pages() -> [EditorHost] { wings.values.map { $0.host } + [editor()].compactMap { $0 } }

    /// A page saved the wings (a card moved, a widget changed): every other page shows the same.
    func broadcast(_ json: String, except from: EditorHost) {
        for h in pages() where h !== from { h.applyWingsState(json) }
    }

    func eventsSaved(except from: EditorHost) {
        for h in pages() where h !== from { h.refreshCalendarAdded() }
    }

    // MARK: Menus

    private func panelMenu(_ s: WingSide) -> [NSMenuItem] {
        let close = NSMenuItem(title: "Close \(s == .left ? "Left" : "Right") Wing", action: #selector(WingMenuTarget.close(_:)), keyEquivalent: "")
        close.target = WingMenuTarget.shared; close.representedObject = s.rawValue
        WingMenuTarget.shared.panels = self
        return [close] + menuItems()
    }
}

/// Menu entries need an Objective-C target; this one forwards to the panels.
final class WingMenuTarget: NSObject {
    static let shared = WingMenuTarget()
    weak var panels: WingPanels?
    @objc func close(_ sender: NSMenuItem) {
        if let s = (sender.representedObject as? String).flatMap(WingSide.init) { panels?.hide(s) }
    }
}

/// `recense selftest`: the three-finger swipe (app.swift, trackThree) fed with made-up trackpad frames, the owner's
/// open / close sequence through `wingSwipe`, and the two panels' places. Needs no trackpad, window or permission.
func wingsSelftest() -> Bool {
    var heard: [String] = []
    let saved = wingSwipeHandler, savedLayers = gestureHandler
    wingSwipeHandler = { d, x in heard.append("\(d < 0 ? "leftward" : "rightward")@\(Int((x * 10).rounded()))") }
    gestureHandler = { heard.append($0) }
    defer { wingSwipeHandler = saved; gestureHandler = savedLayers; gStarts = [:]; gSpent = false; gThreeMoving = false }
    /// One touch: three fingers from `a` (x, y as fractions of the trackpad) moving by (dx, dy), then lifted.
    func swipe(_ a: [(Float, Float)], _ dx: Float, _ dy: Float) -> [String] {
        heard = []; gStarts = [:]; gSpent = false
        for step in 0...10 {
            let t = Float(step) / 10
            trackThree(a.indices.map { i in (id: Int32(i + 1), p: MTPoint(x: a[i].0 + dx * t, y: a[i].1 + dy * t)) })
        }
        gStarts = [:]; gSpent = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))   // the handlers are called on the main queue
        return heard
    }
    let mid: [(Float, Float)] = [(0.42, 0.5), (0.5, 0.55), (0.58, 0.5)]
    let rightSide: [(Float, Float)] = [(0.72, 0.5), (0.8, 0.55), (0.88, 0.5)]
    // The owner's sequence: leftward → right out; rightward → left out (both); middle-left → left in; middle-right → right in.
    var lo = false, ro = false
    func step(_ dir: Int, _ x: Float) -> String {
        if let d = wingSwipe(dir: dir, startX: x, left: lo, right: ro) {
            if d.side == .left { lo = d.open } else { ro = d.open }
        }
        return (lo ? "L" : "-") + (ro ? "R" : "-")
    }
    let seen: [String] = [step(-1, 0.8), step(1, 0.2), step(-1, 0.5), step(1, 0.5)]
    let sequence = seen == ["-R", "LR", "-R", "--"]
    let w = WingPanels(vault: URL(fileURLWithPath: "/tmp"), cache: URL(fileURLWithPath: "/tmp"))
    let r = w.frame(.right, height: 300, on: nil), l = w.frame(.left, height: 300, on: nil)   // a 1440 × 900 screen
    let checks: [(String, Bool)] = [
        ("three fingers leftward are heard as a wing swipe", swipe(rightSide, -0.2, 0.01) == ["leftward@8"]),
        ("three fingers rightward from the middle too", swipe(mid, 0.2, -0.01) == ["rightward@5"]),
        ("three fingers up stay Recense's layers", swipe(mid, 0, 0.2) == ["up"]),
        ("a short sideways nudge does nothing", swipe(mid, 0.05, 0).isEmpty),
        ("a diagonal does nothing sideways", !swipe(mid, 0.12, 0.12).contains { $0.hasPrefix("left") || $0.hasPrefix("right") }),
        ("the owner's sequence: right out, left out, left in (middle), right in (middle)", sequence),
        ("with the right wing out, rightward from the left side brings the left one out",
            wingSwipe(dir: 1, startX: 0.15, left: false, right: true).map { $0.side == .left && $0.open } == true),
        ("with both out, leftward from the right side puts the left one in",
            wingSwipe(dir: -1, startX: 0.85, left: true, right: true).map { $0.side == .left && !$0.open } == true),
        ("the right panel sits 8 pt in from the right edge, 360 pt wide, under the menu bar", r.maxX == 1440 - 8 && r.width == 360
            && r.maxY == 900 - WingPanels.topGap),
        ("the left panel is its exact mirror", l.minX == 8 && l.width == r.width && l.minY == r.minY && l.height == r.height),
        ("a panel never runs past the bottom of the screen", w.frame(.right, height: 5000, on: nil).minY >= WingPanels.bottomGap),
    ]
    var ok = true
    for (label, pass) in checks {
        print("\(pass ? "ok  " : "FAIL") wings, \(label)")
        ok = ok && pass
    }
    return ok
}
