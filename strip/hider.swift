// The menu-bar hider, part of Recense (folded in on 2026-10-31 from an app once called Nook; renamed hider.swift on 2026-11-05).
//
//   [ always-hidden icons ] ┆ [ hidden icons ] │ [ visible icons ] [ system icons ]
//
// macOS lets no app move other apps' icons, so icons are hidden by ⌘-dragging them left of a divider: left of │ for the
// hidden tier, left of ┆ for the always-hidden tier.
// - Peek (hidden tier only): the chevron in the strip (click, or hover 0.5 s), hovering the divider's spot in the menu bar
//   for 0.5 s, Recense's app menu ▸ Menu-Bar Hider ▸ Show Hidden Icons, or `recense show-icons`.
// - Always-hidden tier: ⌥-clicking the strip's chevron, Recense's app menu ▸ Menu-Bar Hider ▸ Reveal Always-Hidden Icons,
//   or `recense show-all-icons`.
// No key or modifier ever reveals them (D23: a held ⌘ did, until 2026-11-06, and the icons took the strip's place during
// ⌘-Tab, ⌘C and ⌘-drag).
//
// Overlap rule (A2): no app's icon ever sits under a strip control (`stripBounds`).
// - Collapsed: the divider spans the exact available menu-bar room down to within 2 pt of macOS's left cutoff (via
//   bracket + binary search in `fit`), leaving < 2 pt on its left so every hidden icon overflows the bar and is moved
//   completely off-screen by MenuBarAgent (fixing the 0.85 step-down bug that left a ~50–150 pt gap in the screen center
//   under the strip).
// - Peek: `hidden` (│) expands to 12 pt in the free space right of the strip (`strip.maxX .. screen.maxX`) while `always`
//   (┆) stays collapsed to the left cutoff, so shown icons sit only in the free space right of the strip's controls and
//   always-hidden icons stay off-screen.
//
// Off (Recense's app menu ▸ Hide Menu-Bar Icons, or `defaults write local.recense hiderEnabled -bool NO`): no status items,
// no monitors, no timer.

import AppKit
import ApplicationServices

enum HiderPrefs {
    static var enabled: Bool {
        get { _ = migrated; return UserDefaults.standard.object(forKey: "hiderEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hiderEnabled") }
    }
    static var hoverToPeek: Bool {
        get { _ = migrated; return UserDefaults.standard.object(forKey: "hiderHoverToPeek") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hiderHoverToPeek") }
    }
    /// Once: carry the old `nookEnabled` setting over to `hiderEnabled`, and drop the position of Nook's old `.toggle`
    /// item, which no longer exists.
    private static let migrated: Void = {
        let d = UserDefaults.standard
        if let old = d.object(forKey: "nookEnabled") as? Bool {
            if d.object(forKey: "hiderEnabled") == nil { d.set(old, forKey: "hiderEnabled") }
            d.removeObject(forKey: "nookEnabled")
        }
        if let oldPeek = d.object(forKey: "nookHoverToPeek") as? Bool {
            if d.object(forKey: "hiderHoverToPeek") == nil { d.set(oldPeek, forKey: "hiderHoverToPeek") }
            d.removeObject(forKey: "nookHoverToPeek")
        }
        d.removeObject(forKey: "NSStatusItem Preferred Position local.sill.nook.toggle")
    }()
}

final class MenuBarHider {
    enum State: Equatable {
        case collapsed          // both tiers off-screen
        case peek               // hidden tier shown in free space right of the strip; always-hidden tier off-screen
        case allShown           // both hidden and always-hidden tiers shown
    }

    private var item: NSStatusItem?          // │ (hidden tier divider)
    private var itemPad: NSStatusItem?       // companion span so │ + pad can exceed macOS 27's 960 pt single-item cap
    private var alwaysItem: NSStatusItem?    // ┆ (always-hidden tier divider)
    private var alwaysPad: NSStatusItem?     // companion span so ┆ + pad can exceed macOS 27's 960 pt single-item cap
    private(set) var state: State = .collapsed
    private var monitors: [Any] = []
    private var appObserver: NSObjectProtocol?
    private var tuckWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var fitGeneration = 0
    private var savedDividerSpot: CGRect?    // right end of │ when narrow, for 0.5 s hover-to-peek while collapsed

    static let tuckDelay: TimeInterval = 3
    static let showGrace: TimeInterval = 8   // after Show Hidden Icons: time to bring the pointer up to the menu bar
    static let peekDelay: TimeInterval = 0.5 // hover-to-peek dwell time (matches the strip's chevron)
    static let stripControlWidth: CGFloat = 720
    static let minIconWidth: CGFloat = 18
    /// The only events the hider watches. No key or modifier event (D23); `hiderSelftest` checks this.
    static let watched: NSEvent.EventTypeMask = [.mouseMoved]

    var running: Bool { item != nil }
    var collapsed: Bool { state == .collapsed }
    var hiddenShown: Bool { state != .collapsed }
    var alwaysShown: Bool { state == .allShown }

    // MARK: - Pure geometry & overlap rules (shared with hiderSelftest)

    /// The strip's frame on `screen` (centered, width 720 pt). No app's menu-bar icon may ever intersect this rect.
    static func stripBounds(on screen: CGRect, width: CGFloat = stripControlWidth) -> CGRect {
        let h: CGFloat = 30
        return CGRect(x: (screen.midX - width / 2).rounded(), y: screen.maxY - h, width: width, height: h)
    }

    /// The free menu-bar space to the right of the strip's controls (`strip.maxX ... screen.maxX`).
    static func peekFreeSpace(on screen: CGRect, stripWidth: CGFloat = stripControlWidth) -> ClosedRange<CGFloat> {
        let strip = stripBounds(on: screen, width: stripWidth)
        return strip.maxX ... screen.maxX
    }

    /// Two-stage bracket + binary search for the maximum divider width that stays on the menu bar (`isOnBar == true`),
    /// refined to within `tolerance` (2 pt). Leaves at most `tolerance` pt to the left of the divider, which is strictly
    /// narrower than any menu-bar icon (`minIconWidth = 18 pt`), so every icon left of the collapsed divider overflows
    /// the bar and is moved off-screen by macOS instead of drifting into the screen center under the strip.
    static func binaryFitLength(dividerRightX: CGFloat, isOnBar: (CGFloat) -> Bool, tolerance: CGFloat = 2) -> CGFloat {
        var length = max(dividerRightX + 12, 200)
        var high: CGFloat?
        for _ in 0..<16 {
            if isOnBar(length) { break }
            high = length
            length *= 0.85
        }
        guard var hi = high else { return length }
        var lo = length
        for _ in 0..<10 {
            if hi - lo <= tolerance { break }
            let mid = (lo + hi) * 0.5
            if isOnBar(mid) { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// Frames of icons to the left of a collapsed divider when fitted with `binaryFitLength`.
    /// On macOS, any icon whose `minX < barLeftLimit` overflows the status bar and is hidden off-screen.
    static func visibleIconsWhenCollapsed(dividerRightX: CGFloat, barLeftLimit: CGFloat, iconWidths: [CGFloat]) -> [CGRect] {
        let len = binaryFitLength(dividerRightX: dividerRightX, isOnBar: { dividerRightX - $0 >= barLeftLimit })
        var x = dividerRightX - len
        var visible: [CGRect] = []
        for w in iconWidths {
            let minX = x - w
            if minX >= barLeftLimit {
                visible.append(CGRect(x: minX, y: 0, width: w, height: 24))
                x = minX
            }
        }
        return visible
    }

    /// Frames of hidden-tier icons during Peek: shown to the left of the narrow (12 pt) divider, clamped to the free
    /// space right of the strip (`strip.maxX .. screen.maxX`) because the always-hidden divider on their left is
    /// collapsed to `barLeftLimit`.
    static func visibleIconsInPeek(dividerRightX: CGFloat, iconWidths: [CGFloat], screen: CGRect, stripWidth: CGFloat = stripControlWidth) -> [CGRect] {
        let free = peekFreeSpace(on: screen, stripWidth: stripWidth)
        let clampedRightX = max(free.lowerBound + 12, min(dividerRightX, free.upperBound))
        var x = clampedRightX - 12
        var shown: [CGRect] = []
        for w in iconWidths {
            let minX = x - w
            guard minX >= free.lowerBound else { break }
            shown.append(CGRect(x: minX, y: 0, width: w, height: 24))
            x = minX
        }
        return shown
    }

    // MARK: - Lifecycle

    func setEnabled(_ on: Bool) {
        HiderPrefs.enabled = on
        on ? start() : stop()
    }

    func start() {
        guard HiderPrefs.enabled, !running else { return }
        ensureSafePreferredPositions()
        let it = NSStatusBar.system.statusItem(withLength: 12)
        it.autosaveName = "local.recense.divider"
        it.button?.title = ""
        it.button?.appearsDisabled = true
        item = it

        let ip = NSStatusBar.system.statusItem(withLength: 1)
        ip.autosaveName = "local.recense.span"
        ip.button?.title = ""
        ip.button?.appearsDisabled = true
        itemPad = ip

        let al = NSStatusBar.system.statusItem(withLength: 12)
        al.autosaveName = "local.recense.always"
        al.button?.title = ""
        al.button?.appearsDisabled = true
        alwaysItem = al

        let ap = NSStatusBar.system.statusItem(withLength: 1)
        ap.autosaveName = "local.recense.always.span4"
        ap.button?.title = ""
        ap.button?.appearsDisabled = true
        alwaysPad = ap

        expandBoth(showingGlyphs: false)
        // Once it has a place; unless Show Hidden Icons came first (`recense show-icons` launching Recense), whose tuck collapses it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.captureDividerSpot()
            if self.state == .collapsed { self.collapse() }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: MenuBarHider.watched, handler: { [weak self] _ in self?.mouseMoved() }) {
            monitors.append(m)
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // When the front app changes, its menu bar width (`barLeftLimit`) changes: refit the collapsed divider so
            // neither a wider app menu drops the divider nor a narrower app menu opens a gap under the strip.
            guard let self = self, self.running else { return }
            if self.state == .collapsed { self.collapse() }
            else if self.state == .peek, let al = self.alwaysItem { self.collapseItem(al, pad: self.alwaysPad) }
        }
    }

    func stop() {
        guard running else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors = []
        if let o = appObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); appObserver = nil }
        tuckWork?.cancel(); tuckWork = nil
        peekWork?.cancel(); peekWork = nil
        fitGeneration += 1
        [item, itemPad, alwaysItem, alwaysPad].compactMap { $0 }.forEach { NSStatusBar.system.removeStatusItem($0) }
        item = nil; itemPad = nil
        alwaysItem = nil; alwaysPad = nil
        state = .collapsed
    }

    /// Ensures the dividers' saved preferred positions sit in the right order:
    /// visible icons < divider (154) < span (170) < hidden icons < always (10051) < always.pad3 (10055) < always-hidden icons.
    private func ensureSafePreferredPositions() {
        let d = UserDefaults.standard
        let divKey = "NSStatusItem Preferred Position local.recense.divider"
        let divPadKey = "NSStatusItem Preferred Position local.recense.span"
        let alwKey = "NSStatusItem Preferred Position local.recense.always"
        let alwPadKey = "NSStatusItem Preferred Position local.recense.always.span4"
        let maxOffsetFromRight: CGFloat = {
            guard let s = NSScreen.main else { return 540 }
            let free = MenuBarHider.peekFreeSpace(on: s.frame)
            return max(200, s.frame.maxX - free.lowerBound - 24)
        }()
        let curDiv = (d.object(forKey: divKey) as? CGFloat) ?? 154
        if d.object(forKey: divKey) == nil || curDiv > maxOffsetFromRight || curDiv < 40 {
            d.set(154, forKey: divKey)
        }
        let safeDiv = (d.object(forKey: divKey) as? CGFloat) ?? 154
        d.set(safeDiv + 16, forKey: divPadKey)
        d.set(10051, forKey: alwKey)
        d.set(5220, forKey: alwPadKey)
    }

    private func captureDividerSpot() {
        guard let w = item?.button?.window, MenuBarHider.isWindowOnBar(w) else { return }
        let strip = w.screen.map { MenuBarHider.stripBounds(on: $0.frame) } ?? .zero
        if w.frame.maxX >= strip.maxX {
            savedDividerSpot = CGRect(x: w.frame.maxX - 16, y: w.frame.minY, width: 16, height: max(w.frame.height, 24))
        }
    }

    private static func isWindowOnBar(_ w: NSWindow) -> Bool {
        NSScreen.screens.contains { $0.frame.contains(NSPoint(x: w.frame.maxX - 1, y: w.frame.midY)) }
    }

    private static func axBarItems() -> [CGRect]? {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let barEl = bar else { return nil }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(barEl as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
              let items = kids as? [AXUIElement] else { return nil }
        var rects: [CGRect] = []
        for item in items {
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let posVal = posRef, let sizeVal = sizeRef else { continue }
            var pt = CGPoint.zero
            var sz = CGSize.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &pt)
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz)
            rects.append(CGRect(origin: pt, size: sz))
        }
        return rects
    }

    /// Returns the on-bar frame of `target` near `rightX` when MenuBarAgent is actually keeping it on the menu bar
    /// (not hidden behind macOS 27's `‹‹` overflow button). Falls back to `w.frame` only if `AXExtrasMenuBar` is unavailable.
    private static func onBarFrame(for w: NSWindow, rightX: CGFloat, minWidth: CGFloat = 10) -> CGRect? {
        if let rects = axBarItems() {
            return rects.first { $0.width >= minWidth && abs($0.maxX - rightX) <= 24 }
        }
        guard isWindowOnBar(w) && abs(w.frame.maxX - rightX) <= 12 else { return nil }
        return w.frame
    }

    // MARK: - State transitions (Collapsed / Peek / All Shown)

    private func expandBoth(showingGlyphs: Bool) {
        fitGeneration += 1
        item?.length = 12
        item?.button?.title = showingGlyphs ? "┃" : ""
        item?.button?.alphaValue = 0.35
        itemPad?.length = 1
        alwaysItem?.length = 12
        alwaysItem?.button?.title = showingGlyphs ? "┆" : ""
        alwaysItem?.button?.alphaValue = 0.35
        alwaysPad?.length = 1
    }

    func collapse() {
        guard let it = item else { return }
        state = .collapsed
        peekWork?.cancel(); peekWork = nil
        // Keep `always` 1 pt wide behind `hidden` so only `hidden` (+ its pad) spans the bar when both tiers are collapsed.
        alwaysItem?.button?.title = ""
        alwaysItem?.length = 1
        alwaysPad?.length = 1
        it.button?.title = ""
        collapseItem(it, pad: itemPad)
    }

    private func collapseItem(_ target: NSStatusItem, pad: NSStatusItem?) {
        fitGeneration += 1
        let gen = fitGeneration
        // Set `target` narrow (12 pt) and wait until MenuBarAgent moves it onto the bar before reading `w.frame.maxX`.
        target.length = 12
        pad?.length = 1
        waitForBarAndCollapse(target, pad: pad, tries: 8, gen: gen)
    }

    private func waitForBarAndCollapse(_ target: NSStatusItem, pad: NSStatusItem?, tries: Int, gen: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self = self, self.fitGeneration == gen, let w = target.button?.window else { return }
            let barFrame = MenuBarHider.onBarFrame(for: w, rightX: w.frame.maxX, minWidth: 10)
            if barFrame == nil && tries > 0 {
                self.waitForBarAndCollapse(target, pad: pad, tries: tries - 1, gen: gen)
                return
            }
            if target === self.item { self.captureDividerSpot() }
            let screenMinX = w.screen?.frame.minX ?? 0
            let rightX = barFrame?.maxX ?? (MenuBarHider.isWindowOnBar(w) ? w.frame.maxX : (self.savedDividerSpot?.maxX ?? 1620))
            let room = max(rightX - screenMinX, 200)
            // macOS 27 MenuBarAgent caps any single NSStatusItem window at screen.width / 2 (960 pt on a 1920-wide
            // screen). When `room > 880` and `pad` sits immediately adjacent to `target` (no other app's icon between
            // them), give the right item a 700 pt span and binary-fit the left item over the remaining room so their
            // combined span reaches `barLeftLimit` and pushes every hidden icon off-bar.
            let adjacentPair: (right: NSStatusItem, left: NSStatusItem)? = {
                guard let pad = pad, let pw = pad.button?.window, MenuBarHider.isWindowOnBar(pw) else { return nil }
                if abs(w.frame.minX - pw.frame.maxX) <= 18 { return (target, pad) }
                if abs(pw.frame.minX - w.frame.maxX) <= 18 { return (pad, target) }
                return nil
            }()
            if room > 880, let pair = adjacentPair {
                pair.right.length = 700
                pair.left.length = 920
            } else {
                self.bracketAndRefine(target, rightX: rightX, length: min(room + 12, 940), high: nil, tries: 12, gen: gen)
            }
        }
    }

    /// Stage 1: step down by 0.85 until `target` stays on the bar (`low`), recording the last off-bar width (`high`).
    /// Stage 2: binary-search `[low, high]` down to <= 4 pt so no icon can fit in the remaining space on the left.
    private func bracketAndRefine(_ target: NSStatusItem, rightX: CGFloat, length: CGFloat, high: CGFloat?, tries: Int, gen: Int) {
        target.length = length
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self = self, self.fitGeneration == gen, let w = target.button?.window else { return }
            let barFrame = MenuBarHider.onBarFrame(for: w, rightX: rightX, minWidth: 10)
            if barFrame == nil && tries > 0 {
                self.bracketAndRefine(target, rightX: rightX, length: length * 0.85, high: length, tries: tries - 1, gen: gen)
            } else if let hi = high, let f = barFrame {
                self.refineBinary(target, rightX: rightX, low: length, lowMinX: f.minX, high: hi, steps: 6, sawOffBar: false, canPromote: true, gen: gen)
            }
        }
    }

    private func refineBinary(_ target: NSStatusItem, rightX: CGFloat, low: CGFloat, lowMinX: CGFloat, high: CGFloat, steps: Int, sawOffBar: Bool, canPromote: Bool, gen: Int) {
        if steps <= 0 || high - low <= 4 {
            if !sawOffBar && canPromote {
                self.refineBinary(target, rightX: rightX, low: low, lowMinX: lowMinX, high: high / 0.85, steps: 6, sawOffBar: false, canPromote: false, gen: gen)
                return
            }
            target.length = low
            return
        }
        let mid = (low + high) * 0.5
        target.length = mid
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self = self, self.fitGeneration == gen, let w = target.button?.window else { return }
            if let f = MenuBarHider.onBarFrame(for: w, rightX: rightX, minWidth: 10), f.minX < lowMinX - 0.5 {
                self.refineBinary(target, rightX: rightX, low: mid, lowMinX: f.minX, high: high, steps: steps - 1, sawOffBar: sawOffBar, canPromote: canPromote, gen: gen)
            } else {
                self.refineBinary(target, rightX: rightX, low: low, lowMinX: lowMinX, high: mid, steps: steps - 1, sawOffBar: true, canPromote: canPromote, gen: gen)
            }
        }
    }

    /// Peek: show the hidden tier in the free space right of the strip (`strip.maxX .. screen.maxX`), while keeping the
    /// always-hidden tier collapsed off-screen. Triggered by the strip's chevron (click, or hover 0.5 s), hovering the
    /// divider's spot for 0.5 s, the menu item, or `recense show-icons`.
    func showIcons() {
        guard running else { return }
        ensureSafePreferredPositions()
        state = .peek
        fitGeneration += 1
        item?.length = 12
        item?.button?.title = "┃"
        item?.button?.alphaValue = 0.35
        itemPad?.length = 1
        alwaysItem?.button?.title = ""
        if let al = alwaysItem { collapseItem(al, pad: alwaysPad) }
        if pointerInMenuBar(NSEvent.mouseLocation) { tuckWork?.cancel(); tuckWork = nil }
        else { scheduleTuck(MenuBarHider.showGrace) }
    }

    /// Reveal both the hidden tier and the always-hidden tier (`┆` and `│`). Triggered by ⌥-clicking the strip's
    /// chevron, `Recense ▸ Menu-Bar Hider ▸ Reveal Always-Hidden Icons`, or `recense show-all-icons`.
    func showAllIcons() {
        guard running else { return }
        ensureSafePreferredPositions()
        state = .allShown
        expandBoth(showingGlyphs: true)
        if pointerInMenuBar(NSEvent.mouseLocation) { tuckWork?.cancel(); tuckWork = nil }
        else { scheduleTuck(MenuBarHider.showGrace) }
    }

    // MARK: - Pointer & hover-to-peek (0.5 s)

    /// Hover to peek: resting the pointer at the divider's spot for `peekDelay` (0.5 s) reveals the hidden tier only
    /// (`showIcons()`), never the always-hidden tier; once the pointer leaves the menu bar they tuck away after `tuckDelay`.
    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        if collapsed {
            guard HiderPrefs.hoverToPeek else { return }
            let spot: CGRect? = {
                if let w = item?.button?.window, MenuBarHider.isWindowOnBar(w) {
                    return CGRect(x: w.frame.maxX - 16, y: w.frame.minY, width: 16, height: max(w.frame.height, 24))
                }
                return savedDividerSpot
            }()
            if let spot = spot, spot.contains(p) {
                if peekWork == nil {
                    let w = DispatchWorkItem { [weak self] in
                        self?.peekWork = nil
                        guard let self = self, self.collapsed else { return }
                        self.showIcons()
                    }
                    peekWork = w
                    DispatchQueue.main.asyncAfter(deadline: .now() + MenuBarHider.peekDelay, execute: w)
                }
            } else {
                peekWork?.cancel(); peekWork = nil
            }
        } else if !pointerInMenuBar(p) {
            if tuckWork == nil { scheduleTuck(MenuBarHider.tuckDelay) }
        } else {
            tuckWork?.cancel(); tuckWork = nil
        }
    }

    private func scheduleTuck(_ after: TimeInterval) {
        tuckWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.tuckWork = nil; self?.collapse() }
        tuckWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: w)
    }

    private func pointerInMenuBar(_ p: NSPoint) -> Bool {
        guard let s = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }) else { return false }
        return p.y >= s.frame.maxY - max(s.frame.maxY - s.visibleFrame.maxY, NSStatusBar.system.thickness)
    }

    /// Recense's app menu entry.
    func menu() -> NSMenu {
        let m = NSMenu()
        HiderToggle.shared.hider = self
        let on = NSMenuItem(title: "Hide Menu-Bar Icons", action: #selector(HiderToggle.fire), keyEquivalent: "")
        on.target = HiderToggle.shared
        on.state = running ? .on : .off
        m.addItem(on)

        let show = NSMenuItem(title: "Show Hidden Icons", action: #selector(HiderToggle.show), keyEquivalent: "")
        show.target = HiderToggle.shared
        show.isEnabled = running
        m.addItem(show)

        let showAll = NSMenuItem(title: "Reveal Always-Hidden Icons  (⌥-click ‹‹)", action: #selector(HiderToggle.showAll), keyEquivalent: "")
        showAll.target = HiderToggle.shared
        showAll.isEnabled = running
        m.addItem(showAll)

        let peek = NSMenuItem(title: "Peek on Hover (0.5 s)", action: #selector(HiderToggle.togglePeek), keyEquivalent: "")
        peek.target = HiderToggle.shared
        peek.state = HiderPrefs.hoverToPeek ? .on : .off
        peek.isEnabled = running
        m.addItem(peek)

        m.addItem(.separator())
        let how = NSMenuItem(title: "⌘-drag icons left of ┃ to hide them, left of ┆ to always hide them", action: nil, keyEquivalent: "")
        how.isEnabled = false
        m.addItem(how)
        return m
    }
}

final class HiderToggle: NSObject {
    static let shared = HiderToggle()
    weak var hider: MenuBarHider?
    @objc func fire() { guard let n = hider else { return }; n.setEnabled(!n.running) }
    @objc func show() { hider?.showIcons() }
    @objc func showAll() { hider?.showAllIcons() }
    @objc func togglePeek() { HiderPrefs.hoverToPeek.toggle() }
}

/// `recense selftest`:
/// 1. The hider watches no key or modifier event (D23).
/// 2. Overlap rule (A2): when collapsed, hidden icons are pushed completely off-bar (0 visible icons, 0 overlap with the
///    strip's controls). When peeking, icons show only in the free space right of the strip (`strip.maxX .. screen.maxX`)
///    and never overlap `stripBounds`.
func hiderSelftest() -> Bool {
    let cases: [(NSEvent.EventTypeMask, String)] = [
        (.flagsChanged, "modifier changes (⌘ held, ⌘-drag)"), (.keyDown, "key presses (⌘-Tab, ⌘C)"), (.keyUp, "key releases"),
        (.leftMouseDragged, "drags"), (.leftMouseDown, "clicks")]
    var ok = true
    for (mask, label) in cases {
        let watched = !MenuBarHider.watched.intersection(mask).isEmpty
        print("\(watched ? "FAIL" : "ok  ") hider, \(label): \(watched ? "watched" : "never reveals")")
        ok = ok && !watched
    }

    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1200)
    let strip = MenuBarHider.stripBounds(on: screen)
    let free = MenuBarHider.peekFreeSpace(on: screen)
    let icons: [CGFloat] = [28, 28, 28, 28]

    // Collapsed overlap check across varying app menu widths (barLeftLimit = 580, 720, 820):
    var collapsedClean = true
    for limit in [CGFloat(580), 720, 820] {
        let vis = MenuBarHider.visibleIconsWhenCollapsed(dividerRightX: 1623, barLeftLimit: limit, iconWidths: icons)
        let overlaps = vis.contains { $0.intersects(strip) }
        if !vis.isEmpty || overlaps { collapsedClean = false }
    }
    print("\(collapsedClean ? "ok  " : "FAIL") hider, collapsed: hidden icons fully off-screen, 0 overlap strip")
    ok = ok && collapsedClean

    // Peek overlap check: shown icons sit only in the free space right of the strip's controls (`strip.maxX .. screen.maxX`).
    let peekIcons = MenuBarHider.visibleIconsInPeek(dividerRightX: 1623, iconWidths: icons, screen: screen)
    let peekInFreeSpace = !peekIcons.isEmpty && peekIcons.allSatisfy {
        $0.minX >= free.lowerBound && $0.maxX <= free.upperBound && !$0.intersects(strip)
    }
    print("\(peekInFreeSpace ? "ok  " : "FAIL") hider, peek: icons show only right of strip (\(Int(free.lowerBound))..\(Int(free.upperBound))), 0 overlap strip")
    ok = ok && peekInFreeSpace

    return ok
}
