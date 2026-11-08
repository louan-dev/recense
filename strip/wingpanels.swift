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
// Summoned by a two-finger swipe in from the trackpad's right or left edge (app.swift, trackEdgeSwipe), the
// Recense menu, the editor's right-click menu, `recense wing-left|wing-right`, or the editor's voice moves.
// Closed by the × on the panel, a two-finger swipe back toward its edge, Esc, or a click anywhere outside it.
//
// Two presentations (setting "wingMotion"): slide (default: the panel slides in from its edge, as Notification
// Center does) and fan (the cards spread out from the edge one after another). Reduce Motion: neither; it appears.

enum WingSide: String, CaseIterable { case left, right }
enum WingMotion: String { case slide, fan }
var wingMotion: WingMotion {
    get { WingMotion(rawValue: UserDefaults.standard.string(forKey: "wingMotion") ?? "") ?? .slide }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "wingMotion") }
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
        var ready = false
    }
    private var wings: [WingSide: Wing] = [:]
    private(set) var open: Set<WingSide> = []
    private var pendingShow: Set<WingSide> = []
    private var monitors: [Any] = []
    private var transition: [WingSide: Int] = [:]

    let vault: URL, cache: URL
    /// The pad's current text, for the Agenda card.
    var currentText: () -> String = { "" }
    /// The editor's own host, kept in step with the panels' wings state.
    var editor: () -> EditorHost? = { nil }
    /// A card cites into the page / jumps to a line in it.
    var onInsert: ((String) -> Void)?
    var onJump: ((Int) -> Void)?
    /// Extra entries for a panel's right-click menu.
    var menuItems: () -> [NSMenuItem] = { [] }

    init(vault: URL, cache: URL) { self.vault = vault; self.cache = cache }

    func isOpen(_ s: WingSide) -> Bool { open.contains(s) }

    func toggle(_ s: WingSide) { isOpen(s) ? hide(s) : show(s) }

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
        installMonitors()
        guard w.ready else { pendingShow.insert(s); return }   // first time: once the page has laid itself out
        present(s)
    }

    private func present(_ s: WingSide) {
        guard let w = wings[s] else { return }
        let screen = WingPanels.pointerScreen()
        w.panel.setFrame(frame(s, height: w.height, on: screen), display: false)
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        w.stage.frame = w.panel.contentView?.bounds ?? .zero
        w.panel.alphaValue = 1
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        if still {
            w.panel.orderFrontRegardless()
        } else if wingMotion == .slide {
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
        } else {
            w.panel.orderFrontRegardless()
            w.host.send("fanOut()")
        }
        log("wings: \(s.rawValue) open (\(still ? "still" : wingMotion.rawValue))")
    }

    func hide(_ s: WingSide, _ why: String = "asked") {
        pendingShow.remove(s)
        guard open.contains(s), let w = wings[s] else { return }
        open.remove(s); syncFlags()
        if open.isEmpty { removeMonitors() }
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
            if wingMotion == .slide {
                w.stage.animator().setFrameOrigin(NSPoint(x: s == .right ? w.stage.frame.width + WingPanels.edgeInset
                                                                         : -(w.stage.frame.width + WingPanels.edgeInset), y: 0))
            } else {
                w.panel.animator().alphaValue = 0
            }
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
    func frame(_ s: WingSide, height: CGFloat, on screen: NSScreen?) -> NSRect {
        let v = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxH = v.height - WingPanels.topGap - WingPanels.bottomGap
        let h = min(max(height, 60), maxH)
        let x = s == .right ? v.maxX - WingPanels.width - WingPanels.edgeInset : v.minX + WingPanels.edgeInset
        return NSRect(x: x.rounded(), y: (v.maxY - WingPanels.topGap - h).rounded(), width: WingPanels.width, height: h.rounded())
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
            layout(s, height: CGFloat((d["height"] as? NSNumber)?.doubleValue ?? 0), glass: d["glass"] as? [[NSNumber]] ?? [])
        default: break
        }
    }

    /// The page's shapes, in its own (top-left) coordinates: [x, y, width, height, opacity, corner radius].
    private func layout(_ s: WingSide, height: CGFloat, glass shapes: [[NSNumber]]) {
        guard var w = wings[s] else { return }
        if height > 0, abs(height - w.height) >= 1 {
            w.height = height
            if w.panel.isVisible {
                // Grow or shrink from the top, as Notification Center does; the stage keeps its slide offset.
                let x = w.stage.frame.origin.x
                w.panel.setFrame(frame(s, height: height, on: w.panel.screen), display: true)
                w.stage.frame = NSRect(x: x, y: 0, width: WingPanels.width, height: w.panel.frame.height)
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

    // MARK: Closing: Esc, or a click outside

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let mice: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps are always outside the panels. (Global monitors can't hold the click back: it still
        // reaches what was clicked.)
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mice, handler: { [weak self] _ in self?.hideAll("a click in another app") }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mice, handler: { [weak self] e in
            guard let self = self else { return e }
            if !self.wings.values.contains(where: { $0.panel === e.window }) { self.hideAll("a click outside") }
            return e
        }) { monitors.append(m) }
        // Esc anywhere (needs the Accessibility permission Recense already has for the scroll filter).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 { self?.hideAll("Esc") }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self = self, e.keyCode == 53, !self.open.isEmpty else { return e }
            self.hideAll("Esc"); return nil
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
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

/// `recense selftest`: the edge swipe (app.swift, trackEdgeSwipe) fed with made-up trackpad frames, and the two
/// panels' places. Needs no trackpad, window or permission.
func wingsSelftest() -> Bool {
    var heard: [String] = []
    let saved = edgeSwipeHandler
    edgeSwipeHandler = { heard.append($0) }
    defer { edgeSwipeHandler = saved; gWingOpenLeft = false; gWingOpenRight = false }
    /// One touch from `a` to `b` (two fingers, x and y as fractions of the trackpad), then the fingers lift.
    func swipe(_ a: [(Float, Float)], _ b: [(Float, Float)]) -> [String] {
        heard = []
        for step in 0...10 {
            let t = Float(step) / 10
            trackEdgeSwipe(a.indices.map { i in
                (id: Int32(i + 1), p: MTPoint(x: a[i].0 + (b[i].0 - a[i].0) * t, y: a[i].1 + (b[i].1 - a[i].1) * t))
            })
        }
        trackEdgeSwipe([])
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))   // the handler is called on the main queue
        return heard
    }
    let w = WingPanels(vault: URL(fileURLWithPath: "/tmp"), cache: URL(fileURLWithPath: "/tmp"))
    let r = w.frame(.right, height: 300, on: nil), l = w.frame(.left, height: 300, on: nil)   // a 1440 × 900 screen
    let checks: [(String, Bool)] = [
        ("two fingers in from the right edge open the right wing", swipe([(0.97, 0.5), (0.88, 0.6)], [(0.85, 0.5), (0.76, 0.6)]) == ["right-in"]),
        ("two fingers in from the left edge open the left wing", swipe([(0.03, 0.5), (0.12, 0.6)], [(0.15, 0.5), (0.24, 0.6)]) == ["left-in"]),
        ("the same swipe away from the edges opens nothing", swipe([(0.6, 0.5), (0.5, 0.6)], [(0.48, 0.5), (0.38, 0.6)]).isEmpty),
        ("scrolling up or down along the edge opens nothing", swipe([(0.97, 0.3), (0.9, 0.4)], [(0.96, 0.7), (0.89, 0.8)]).isEmpty
            && !gEdgeSwiping),
        ("a short nudge in from the edge opens nothing", swipe([(0.97, 0.5), (0.88, 0.6)], [(0.95, 0.5), (0.86, 0.6)]).isEmpty),
        ("two fingers back toward the right edge close an open right wing", {
            gWingOpenRight = true; defer { gWingOpenRight = false }
            return swipe([(0.4, 0.5), (0.5, 0.6)], [(0.6, 0.5), (0.7, 0.6)]) == ["right-out"]
        }()),
        ("…and do nothing while it's closed", swipe([(0.4, 0.5), (0.5, 0.6)], [(0.6, 0.5), (0.7, 0.6)]).isEmpty),
        ("two fingers back toward the left edge close an open left wing", {
            gWingOpenLeft = true; defer { gWingOpenLeft = false }
            return swipe([(0.6, 0.5), (0.5, 0.6)], [(0.4, 0.5), (0.3, 0.6)]) == ["left-out"]
        }()),
        ("one action per touch", swipe([(0.97, 0.5), (0.88, 0.6)], [(0.6, 0.5), (0.5, 0.6)]) == ["right-in"]),
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
