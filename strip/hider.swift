// The menu-bar hider, part of Recense (folded in on 2026-10-31 from an app once called Nook; renamed hider.swift on 2026-11-05).
//
//   [ hidden icons ] │ [ visible icons ] [ system icons ]
//
// macOS lets no app move other apps' icons, so icons are hidden by ⌘-dragging them left of the divider. To see the
// divider and the hidden icons: the chevron in the strip (click, or hover 0.5 s), Recense's app menu ▸ Menu-Bar Hider ▸
// Show Hidden Icons, or `recense show-icons`. No key or modifier ever reveals them (D23: a held ⌘ did, until
// 2026-11-06, and the icons took the strip's place during ⌘-Tab, ⌘C and ⌘-drag). Collapsed, the divider is invisible and spans the room left of
// it, pushing those icons off the screen; since macOS 27 a status item wider than that room is moved off the bar
// instead, so it spans exactly that room (see `fit`). Hovering the divider's spot reveals the icons; they tuck away
// again a few seconds after the pointer leaves the menu bar.
//
// Off (Recense's app menu ▸ Hide Menu-Bar Icons, or `defaults write local.recense hiderEnabled -bool NO`): no status item,
// no monitors, no timer.

import AppKit

enum HiderPrefs {
    static var enabled: Bool {
        get { _ = migrated; return UserDefaults.standard.object(forKey: "hiderEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hiderEnabled") }
    }
    /// Once: carry the old `nookEnabled` setting over to `hiderEnabled`, and drop the positions of Nook's old status
    /// items (`local.sill.nook.always` and `.toggle`), which no longer exist.
    private static let migrated: Void = {
        let d = UserDefaults.standard
        if let old = d.object(forKey: "nookEnabled") as? Bool {
            if d.object(forKey: "hiderEnabled") == nil { d.set(old, forKey: "hiderEnabled") }
            d.removeObject(forKey: "nookEnabled")
        }
        for k in ["always", "toggle"] { d.removeObject(forKey: "NSStatusItem Preferred Position local.sill.nook.\(k)") }
    }()
}

final class MenuBarHider {
    private var item: NSStatusItem?
    private var collapsed = false
    private var showing = false              // the divider drawn: Show Hidden Icons, until the next collapse
    private var monitors: [Any] = []
    private var tuckWork: DispatchWorkItem?
    static let tuckDelay: TimeInterval = 3
    static let showGrace: TimeInterval = 8   // after Show Hidden Icons: time to bring the pointer up to the menu bar
    /// The only events the hider watches. No key or modifier event (D23); `hiderSelftest` checks this.
    static let watched: NSEvent.EventTypeMask = [.mouseMoved]

    var running: Bool { item != nil }

    func setEnabled(_ on: Bool) {
        HiderPrefs.enabled = on
        on ? start() : stop()
    }

    func start() {
        guard HiderPrefs.enabled, !running else { return }
        // With no saved spot macOS would put the divider rightmost and hide every icon; start it just left of the
        // system icons instead (the spot it had before 2026-10-31; ⌘-drag moves it).
        let pos = "NSStatusItem Preferred Position local.recense.divider"
        if UserDefaults.standard.object(forKey: pos) == nil { UserDefaults.standard.set(154, forKey: pos) }
        let it = NSStatusBar.system.statusItem(withLength: 12)
        it.autosaveName = "local.recense.divider"
        it.button?.title = ""
        it.button?.appearsDisabled = true
        item = it
        expand()
        // Once it has a place; unless Show Hidden Icons came first (`recense show-icons` launching Recense), whose tuck collapses it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in if self?.showing == false { self?.collapse() } }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: MenuBarHider.watched, handler: { [weak self] _ in self?.mouseMoved() }) { monitors.append(m) }
    }

    func stop() {
        guard let it = item else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors = []
        tuckWork?.cancel()
        NSStatusBar.system.removeStatusItem(it)
        item = nil
    }

    private func expand(showing: Bool = false) {
        collapsed = false
        self.showing = showing
        item?.length = 12
        item?.button?.title = showing ? "┃" : ""
        item?.button?.alphaValue = 0.35
    }

    private func collapse() {
        guard let it = item else { return }
        collapsed = true
        showing = false
        it.button?.title = ""
        let room = (it.button?.window?.frame.minX ?? 0) - (it.button?.window?.screen?.frame.minX ?? 0)
        fit(max(room + 12, 200), tries: 12)
    }

    private func fit(_ length: CGFloat, tries: Int) {
        item?.length = length
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, self.collapsed, tries > 0, let w = self.item?.button?.window else { return }
            let onBar = NSScreen.screens.contains { $0.frame.contains(NSPoint(x: w.frame.maxX - 1, y: w.frame.midY)) }
            if !onBar { self.fit(length * 0.85, tries: tries - 1) }
        }
    }

    /// Show the divider and the hidden icons (the strip's chevron, the menu item, `recense show-icons`). They tuck away
    /// `tuckDelay` after the pointer leaves the menu bar, or after `showGrace` if it never comes up.
    func showIcons() {
        guard running else { return }
        expand(showing: true)
        if pointerInMenuBar(NSEvent.mouseLocation) { tuckWork?.cancel(); tuckWork = nil } else { scheduleTuck(MenuBarHider.showGrace) }
    }

    /// Hover to peek: the pointer at the divider's spot (its right end while collapsed) reveals the icons; once the
    /// pointer leaves the menu bar they tuck away after `tuckDelay`. Cheap: one frame test per move.
    private func mouseMoved() {
        guard let w = item?.button?.window else { return }
        let p = NSEvent.mouseLocation
        if collapsed {
            let spot = CGRect(x: w.frame.maxX - 14, y: w.frame.minY, width: 14, height: w.frame.height)
            if spot.contains(p) { tuckWork?.cancel(); expand() }
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
        let on = NSMenuItem(title: "Hide Menu-Bar Icons", action: #selector(HiderToggle.fire), keyEquivalent: "")
        on.target = HiderToggle.shared; HiderToggle.shared.hider = self
        on.state = running ? .on : .off
        m.addItem(on)
        let show = NSMenuItem(title: "Show Hidden Icons", action: #selector(HiderToggle.show), keyEquivalent: "")
        show.target = HiderToggle.shared
        show.isEnabled = running
        m.addItem(show)
        let how = NSMenuItem(title: "Show them, then ⌘-drag icons left of the divider to hide them", action: nil, keyEquivalent: "")
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
}

/// `recense selftest`: the hider watches no key or modifier event, so no modifier state (⌘ held, ⌘-Tab, ⌘C, ⌘-drag)
/// can reveal the icons (D23).
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
    return ok
}
