// Nook, the menu-bar hider, as part of Recense (folded in from Nook's own app on 2026-10-31; Nook is no longer an app).
//
//   [ hidden icons ] │ [ visible icons ] [ system icons ]
//
// macOS lets no app move other apps' icons, so icons are hidden by ⌘-dragging them left of the divider (hold ⌘ a
// moment to see it). Collapsed, the divider is invisible and spans the room left of it, pushing those icons off the
// screen; since macOS 27 a status item wider than that room is moved off the bar instead, so it spans exactly that room
// (see `fit`). Hovering the divider's spot reveals the icons; they tuck away again a few seconds after the pointer
// leaves the menu bar.
//
// Off (Recense's app menu ▸ Hide Menu-Bar Icons, or `defaults write local.recense nookEnabled -bool NO`): no status item,
// no monitors, no timer.

import AppKit

enum NookPrefs {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "nookEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "nookEnabled") }
    }
}

final class Nook {
    private var item: NSStatusItem?
    private var collapsed = false
    private var monitors: [Any] = []
    private var holdWork: DispatchWorkItem?
    private var tuckWork: DispatchWorkItem?
    static let tuckDelay: TimeInterval = 3

    var running: Bool { item != nil }

    func setEnabled(_ on: Bool) {
        NookPrefs.enabled = on
        on ? start() : stop()
    }

    func start() {
        guard NookPrefs.enabled, !running else { return }
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
        let flags: (NSEvent) -> Void = { [weak self] e in self?.commandChanged(e.modifierFlags.contains(.command)) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { e in flags(e); return e }) { monitors.append(l) }
        // Any key pressed with ⌘ means a shortcut, not arranging: don't reveal anything.
        if let k = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in self?.holdWork?.cancel() }) { monitors.append(k) }
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

    /// Holding ⌘ on its own for a moment shows the divider so icons can be ⌘-dragged across it; letting go tucks
    /// them away again. A quick ⌘ for a shortcut does nothing.
    private func commandChanged(_ down: Bool) {
        holdWork?.cancel()
        if down {
            let w = DispatchWorkItem { [weak self] in self?.tuckWork?.cancel(); self?.expand(showing: true) }
            holdWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
        } else if !collapsed {
            scheduleTuck(0.8)
        }
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
            if tuckWork == nil { scheduleTuck(Nook.tuckDelay) }
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
        let on = NSMenuItem(title: "Hide Menu-Bar Icons", action: #selector(NookToggle.fire), keyEquivalent: "")
        on.target = NookToggle.shared; NookToggle.shared.nook = self
        on.state = running ? .on : .off
        m.addItem(on)
        let how = NSMenuItem(title: "Hold ⌘ and drag icons left of the divider to hide them", action: nil, keyEquivalent: "")
        how.isEnabled = false
        m.addItem(how)
        return m
    }
}

final class NookToggle: NSObject {
    static let shared = NookToggle()
    weak var nook: Nook?
    @objc func fire() { guard let n = nook else { return }; n.setEnabled(!n.running) }
}
