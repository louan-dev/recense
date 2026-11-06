// The menu-bar hider, part of Recense (folded in on 2026-10-31 from an app once called Nook; renamed hider.swift on 2026-11-05).
//
//   [ hidden icons ] │ [ visible icons ] [ system icons ]
//
// macOS lets no app move other apps' icons, so icons are hidden by ⌘-dragging them left of the divider (hold ⌘ a
// moment with the pointer in the menu bar to see it). Collapsed, the divider is invisible and spans the room left of
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
    private var monitors: [Any] = []
    private var holdWork: DispatchWorkItem?
    private var tuckWork: DispatchWorkItem?
    private var commandSince: Date?          // when ⌘ went down on its own; nil once released or joined by a key or modifier
    static let tuckDelay: TimeInterval = 3
    static let holdDelay: TimeInterval = 0.7

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.collapse() }   // once it has a place
        let flags: (NSEvent) -> Void = { [weak self] e in self?.commandChanged(e.modifierFlags) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { e in flags(e); return e }) { monitors.append(l) }
        // Any key pressed with ⌘ means a shortcut, not arranging: don't reveal anything (in other apps and in Recense's own).
        let key: (NSEvent) -> Void = { [weak self] _ in self?.holdWork?.cancel(); self?.commandSince = nil }
        if let k = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: key) { monitors.append(k) }
        if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in key(e); return e }) { monitors.append(k) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in self?.mouseMoved() }) { monitors.append(m) }
    }

    func stop() {
        guard let it = item else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors = []
        holdWork?.cancel(); tuckWork?.cancel()
        NSStatusBar.system.removeStatusItem(it)
        item = nil
    }

    private func expand(showing: Bool = false) {
        collapsed = false
        item?.length = 12
        item?.button?.title = showing ? "┃" : ""
        item?.button?.alphaValue = 0.35
    }

    private func collapse() {
        guard let it = item else { return }
        collapsed = true
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

    /// Holding ⌘ on its own for a moment with the pointer in the menu bar shows the divider, so icons can be ⌘-dragged
    /// across it; letting go tucks them away again. ⌘ held anywhere else (a shortcut, ⌘-Tab, ⌘-click in a window) does
    /// nothing: until 2026-11-05 a held ⌘ revealed the icons wherever the pointer was, and they took the strip's place (R16).
    private func commandChanged(_ flags: NSEvent.ModifierFlags) {
        holdWork?.cancel()
        if MenuBarHider.commandAlone(flags) {
            commandSince = Date()
            let w = DispatchWorkItem { [weak self] in
                guard let self = self, self.pointerInMenuBar(NSEvent.mouseLocation) else { return }
                self.reveal()
            }
            holdWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + MenuBarHider.holdDelay, execute: w)
        } else {
            commandSince = nil
            if !collapsed, !flags.contains(.command) { scheduleTuck(0.8) }
        }
    }

    /// ⌘ and nothing else (Caps Lock and the fn/keypad bits don't count).
    static func commandAlone(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command
    }

    private func reveal() { tuckWork?.cancel(); expand(showing: true) }

    /// Hover to peek: the pointer at the divider's spot (its right end while collapsed) reveals the icons; once the
    /// pointer leaves the menu bar they tuck away after `tuckDelay`. Cheap: one frame test per move.
    private func mouseMoved() {
        guard let w = item?.button?.window else { return }
        let p = NSEvent.mouseLocation
        if collapsed {
            // ⌘ held alone first, then the pointer brought up to the menu bar to arrange icons
            if let t = commandSince, Date().timeIntervalSince(t) >= MenuBarHider.holdDelay, pointerInMenuBar(p) { reveal(); return }
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
        let how = NSMenuItem(title: "Hold ⌘ and drag icons left of the divider to hide them", action: nil, keyEquivalent: "")
        how.isEnabled = false
        m.addItem(how)
        return m
    }
}

final class HiderToggle: NSObject {
    static let shared = HiderToggle()
    weak var hider: MenuBarHider?
    @objc func fire() { guard let n = hider else { return }; n.setEnabled(!n.running) }
}

/// `recense selftest`: which modifier states count as ⌘ alone, the only state that reveals the icons (R16).
func hiderSelftest() -> Bool {
    let cases: [(NSEvent.ModifierFlags, Bool, String)] = [
        ([.command], true, "⌘"), ([.command, .capsLock], true, "⌘ with Caps Lock"), ([.command, .function], true, "⌘ with fn"),
        ([.command, .shift], false, "⌘⇧"), ([.command, .option], false, "⌘⌥"), ([.command, .control], false, "⌘⌃"),
        ([], false, "no modifier"), ([.shift], false, "⇧")]
    var ok = true
    for (flags, want, label) in cases {
        let got = MenuBarHider.commandAlone(flags)
        print("\(got == want ? "ok  " : "FAIL") hider, \(label): \(got ? "reveals" : "does nothing")")
        ok = ok && got == want
    }
    return ok
}
