// Nook, the menu-bar hider, as part of Sill (folded in from nook/main.swift on 2026-10-31; Nook is no longer its own app).
//
//   [ always-hidden icons ] ┆ [ hidden icons ] │ ‹›  [ visible icons ] [ system icons ]
//
// macOS gives apps no way to move other apps' icons, so icons are placed by ⌘-dragging them left of a divider. A
// collapsed divider is wide and pushes everything on its left off the screen. Since macOS 27 a status item wider than
// the room left of it is moved off the bar instead, so a collapsed divider spans only that room (see `fit`).
//
// Turned off (Sill menu ▸ Menu-Bar Hider, or `defaults write local.sill nookEnabled -bool NO`): no status items, no
// monitors, no timer. Turned on, the timer and the mouse-moved monitor run only while icons are showing or hover-peek
// is on, and the pointer work is one rect test.

import AppKit

enum NookRuleAction: String, Codable, CaseIterable {
    case hideAll = "Hide all"
    case showAll = "Show all"
    case showSelection = "Show selection"   // shows the hidden tier, keeps the always-hidden one tucked away
}

struct NookRule: Codable {
    var bundleID: String
    var name: String
    var action: NookRuleAction
}

enum NookPrefs {
    private static let d = UserDefaults.standard
    static var enabled: Bool {
        get { d.object(forKey: "nookEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "nookEnabled") }
    }
    static var autoHideDelay: Double {          // seconds; 0 = never
        get { d.object(forKey: "nookAutoHideDelay") as? Double ?? 3 }
        set { d.set(newValue, forKey: "nookAutoHideDelay") }
    }
    static var hoverToPeek: Bool {
        get { d.object(forKey: "nookHoverToPeek") as? Bool ?? true }
        set { d.set(newValue, forKey: "nookHoverToPeek") }
    }
    static var rulesEnabled: Bool {
        get { d.object(forKey: "nookRulesEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "nookRulesEnabled") }
    }
    static var rules: [NookRule] {
        get { (d.data(forKey: "nookRules")).flatMap { try? JSONDecoder().decode([NookRule].self, from: $0) } ?? [] }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "nookRules") }
    }
}

final class NookMenuItem: NSMenuItem {
    private var handler: () -> Void = {}
    init(_ title: String, on: Bool = false, _ handler: @escaping () -> Void) {
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.handler = handler
        self.target = self
        state = on ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("not supported") }
    @objc private func fire() { handler() }
}

/// One divider status item.
final class NookDivider {
    let item: NSStatusItem
    let glyph: String
    private(set) var collapsed = false
    init(_ name: String, glyph: String) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = name           // remembers where it was ⌘-dragged
        self.glyph = glyph
        item.button?.appearsDisabled = true
    }
    func expand() {
        collapsed = false
        item.length = NSStatusItem.variableLength
        item.button?.title = glyph
        item.button?.alphaValue = 0.4
    }
    func collapse() {
        guard !collapsed else { return }
        collapsed = true
        item.button?.title = ""
        let room = (item.button?.window?.frame.minX ?? 0) - (item.button?.window?.screen?.frame.minX ?? 0)
        fit(max(room + 12, 200), tries: 12)
    }
    /// Steps the width down until macOS keeps the item on the bar.
    private func fit(_ length: CGFloat, tries: Int) {
        item.length = length
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, self.collapsed, tries > 0, let w = self.item.button?.window else { return }
            let onBar = NSScreen.screens.contains { $0.frame.contains(NSPoint(x: w.frame.maxX - 1, y: w.frame.midY)) }
            if !onBar { self.fit(length * 0.85, tries: tries - 1) }
        }
    }
    func remove() { NSStatusBar.system.removeStatusItem(item) }
}

final class Nook: NSObject {
    private var toggle: NSStatusItem?
    private var hidden: NookDivider?
    private var always: NookDivider?
    private var hiddenShown = false
    private var alwaysShown = false
    private var activeRule: NookRuleAction?
    private var deadline = Date.distantFuture
    private var timer: Timer?
    private var moveMonitor: Any?
    private var monitors: [Any] = []
    private var holdWork: DispatchWorkItem?
    private var appObserver: NSObjectProtocol?

    var running: Bool { toggle != nil }

    func setEnabled(_ on: Bool) {
        NookPrefs.enabled = on
        on ? start() : stop()
    }

    func start() {
        guard NookPrefs.enabled, !running else { return }
        // Creation order decides first placement (first created = rightmost); after that autosave keeps it.
        toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggle?.autosaveName = "local.sill.nook.toggle"
        hidden = NookDivider("local.sill.divider", glyph: "│")
        always = NookDivider("local.sill.nook.always", glyph: "┆")
        if let b = toggle?.button {
            b.target = self
            b.action = #selector(toggleClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.toolTip = "Click to show or hide menu-bar icons. ⌥-click: also the always-hidden ones. Right-click: settings."
        }
        // Clicks in the bar may open a menu below it, so keep icons out a while.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self = self, self.hiddenShown, self.pointerInMenuBar() else { return }
            self.hold(10)
        }) { monitors.append(m) }
        // Holding ⌘ on its own for a moment shows both dividers so icons can be ⌘-dragged across them.
        let flags: (NSEvent) -> Void = { [weak self] e in self?.commandChanged(e.modifierFlags.contains(.command)) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(g) }
        if let k = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in self?.holdWork?.cancel() }) { monitors.append(k) }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.applyRule(for: app)
        }
        // Show first so the items get a place on the bar, then tuck the icons away.
        show(all: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.hide()
            self?.applyRule(for: NSWorkspace.shared.frontmostApplication)
        }
    }

    func stop() {
        guard running else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors = []
        if let m = moveMonitor { NSEvent.removeMonitor(m); moveMonitor = nil }
        if let o = appObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); appObserver = nil }
        timer?.invalidate(); timer = nil
        holdWork?.cancel()
        hidden?.remove(); always?.remove()
        if let t = toggle { NSStatusBar.system.removeStatusItem(t) }
        toggle = nil; hidden = nil; always = nil
        hiddenShown = false; alwaysShown = false; activeRule = nil
    }

    // MARK: Show / hide

    func show(all: Bool = false) { hiddenShown = true; alwaysShown = all; render() }
    func hide() { hiddenShown = false; alwaysShown = false; render() }

    private func render() {
        guard running else { return }
        // Expand left to right, collapse right to left, so each collapsed width is measured against a settled bar.
        if hiddenShown { hidden?.expand() } else { always?.collapse(); hidden?.collapse() }
        if hiddenShown && alwaysShown { always?.expand() } else if hiddenShown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.always?.collapse() }
        }
        toggle?.button?.image = NSImage(systemSymbolName: hiddenShown ? "chevron.right" : "chevron.left",
                                        accessibilityDescription: "Show or hide menu-bar icons")
        updateWatchers()
    }

    /// The timer runs only while icons are showing; the mouse-moved monitor only while hover-peek can fire.
    private func updateWatchers() {
        if hiddenShown, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        } else if !hiddenShown {
            timer?.invalidate(); timer = nil
        }
        let wantMove = running && NookPrefs.hoverToPeek && !hiddenShown
        if wantMove, moveMonitor == nil {
            moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.mouseMoved() }
        } else if !wantMove, let m = moveMonitor {
            NSEvent.removeMonitor(m); moveMonitor = nil
        }
    }

    private func hold(_ seconds: Double? = nil) {
        let s = seconds ?? NookPrefs.autoHideDelay
        deadline = s > 0 ? Date().addingTimeInterval(s) : .distantFuture
    }

    private func tick() {
        guard hiddenShown, Date() >= deadline else { return }
        if activeRule == .showAll || activeRule == .showSelection {
            // A rule keeps the hidden tier open, but an explicitly revealed always-hidden tier still tucks back.
            if alwaysShown && activeRule == .showSelection { show(all: false) }
            return
        }
        guard NookPrefs.autoHideDelay > 0 || alwaysShown else { return }
        if pointerInMenuBar() { hold(); return }       // don't pull icons from under the cursor
        hide()
    }

    private func pointerInMenuBar() -> Bool {
        let p = NSEvent.mouseLocation
        guard let s = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }) else { return false }
        let height = max(s.frame.maxY - s.visibleFrame.maxY, NSStatusBar.system.thickness)
        return p.y >= s.frame.maxY - height
    }

    /// Hover to peek: the pointer over ‹› or the right end of the collapsed │ shows the hidden tier only, never the
    /// always-hidden one.
    private func mouseMoved() {
        guard !hiddenShown, pointerInMenuBar(), let t = toggle?.button?.window?.frame else { return }
        let p = NSEvent.mouseLocation
        var zone = t.insetBy(dx: -6, dy: -6)
        if let d = hidden?.item.button?.window?.frame { zone = zone.union(CGRect(x: d.maxX - 16, y: d.minY, width: 16, height: d.height)) }
        if zone.contains(p) { show(); hold() }
    }

    private func commandChanged(_ down: Bool) {
        holdWork?.cancel()
        if down {
            let w = DispatchWorkItem { [weak self] in self?.show(all: true); self?.deadline = .distantFuture }
            holdWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
        } else if hiddenShown && deadline == .distantFuture {
            hold(0.8)
        }
    }

    // MARK: Clicks

    @objc private func toggleClicked() {
        guard let e = NSApp.currentEvent else { return }
        if e.type == .rightMouseUp || e.modifierFlags.contains(.control) {
            guard let b = toggle?.button else { return }
            menu().popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 5), in: b)
        } else if e.modifierFlags.contains(.option) {
            show(all: !alwaysShown); hold()
        } else if hiddenShown {
            hide()
        } else {
            show(); hold()
        }
    }

    // MARK: Rules

    private func applyRule(for app: NSRunningApplication?) {
        guard NookPrefs.rulesEnabled, let id = app?.bundleIdentifier,
              let rule = NookPrefs.rules.first(where: { $0.bundleID == id }) else {
            if activeRule != nil { activeRule = nil; hide() }   // left a rule app: back to the default
            return
        }
        activeRule = rule.action
        switch rule.action {
        case .hideAll: hide()
        case .showAll: show(all: true)
        case .showSelection: show(all: false)
        }
    }

    private func setRule(_ id: String, _ name: String, _ action: NookRuleAction) {
        var rules = NookPrefs.rules
        if let i = rules.firstIndex(where: { $0.bundleID == id }) { rules[i].action = action }
        else { rules.append(NookRule(bundleID: id, name: name, action: action)) }
        NookPrefs.rules = rules
        applyRule(for: NSWorkspace.shared.frontmostApplication)
    }

    private func removeRule(_ id: String) {
        NookPrefs.rules = NookPrefs.rules.filter { $0.bundleID != id }
        applyRule(for: NSWorkspace.shared.frontmostApplication)
    }

    private func actionsMenu(_ id: String, _ name: String, current: NookRuleAction?) -> NSMenu {
        let m = NSMenu()
        for a in NookRuleAction.allCases {
            m.addItem(NookMenuItem(a.rawValue, on: a == current) { [weak self] in self?.setRule(id, name, a) })
        }
        if current != nil {
            m.addItem(.separator())
            m.addItem(NookMenuItem("Remove Rule") { [weak self] in self?.removeRule(id) })
        }
        return m
    }

    // MARK: Settings

    /// The hider's settings: the ‹› right-click menu, and the same entries under Sill's app menu.
    func menu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NookMenuItem("Hide Menu-Bar Icons", on: running) { [weak self] in
            guard let self = self else { return }
            self.setEnabled(!self.running)
        })
        guard running else { return menu }
        menu.addItem(.separator())
        menu.addItem(NookMenuItem(hiddenShown ? "Hide Items" : "Show Hidden Items") { [weak self] in
            guard let self = self else { return }
            if self.hiddenShown { self.hide() } else { self.show(); self.hold() }
        })
        menu.addItem(NookMenuItem("Reveal Always-Hidden Items  (⌥-click ‹›)") { [weak self] in
            self?.show(all: true); self?.hold()
        })
        menu.addItem(.separator())
        let auto = NSMenuItem(title: "Auto-hide After", action: nil, keyEquivalent: "")
        let autoMenu = NSMenu()
        for (label, secs) in [("Never", 0.0), ("1 second", 1), ("2 seconds", 2), ("3 seconds", 3),
                              ("5 seconds", 5), ("10 seconds", 10), ("30 seconds", 30)] {
            autoMenu.addItem(NookMenuItem(label, on: NookPrefs.autoHideDelay == secs) { NookPrefs.autoHideDelay = secs })
        }
        auto.submenu = autoMenu
        menu.addItem(auto)
        menu.addItem(NookMenuItem("Peek on Hover", on: NookPrefs.hoverToPeek) { [weak self] in
            NookPrefs.hoverToPeek.toggle(); self?.updateWatchers()
        })
        menu.addItem(.separator())
        menu.addItem(NookMenuItem("Rules Mode", on: NookPrefs.rulesEnabled) { [weak self] in
            NookPrefs.rulesEnabled.toggle(); self?.applyRule(for: NSWorkspace.shared.frontmostApplication)
        })
        let rulesItem = NSMenuItem(title: "Rules", action: nil, keyEquivalent: "")
        let rulesMenu = NSMenu()
        let rules = NookPrefs.rules
        for r in rules {
            let item = NSMenuItem(title: "\(r.name)  →  \(r.action.rawValue)", action: nil, keyEquivalent: "")
            item.submenu = actionsMenu(r.bundleID, r.name, current: r.action)
            rulesMenu.addItem(item)
        }
        if !rules.isEmpty { rulesMenu.addItem(.separator()) }
        let add = NSMenuItem(title: "Add Rule for…", action: nil, keyEquivalent: "")
        let addMenu = NSMenu()
        let existing = Set(rules.map { $0.bundleID })
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && !existing.contains($0.bundleIdentifier!)
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in apps {
            let id = app.bundleIdentifier!, name = app.localizedName ?? id
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            if let icon = app.icon?.copy() as? NSImage { icon.size = NSSize(width: 16, height: 16); item.image = icon }
            item.submenu = actionsMenu(id, name, current: nil)
            addMenu.addItem(item)
        }
        add.submenu = addMenu
        rulesMenu.addItem(add)
        rulesItem.submenu = rulesMenu
        menu.addItem(rulesItem)
        menu.addItem(.separator())
        let how = NSMenuItem(title: "⌘-drag icons left of │ to hide them, left of ┆ to always hide them", action: nil, keyEquivalent: "")
        how.isEnabled = false
        menu.addItem(how)
        let why = NSMenuItem(title: "(macOS lets no app move other apps' icons)", action: nil, keyEquivalent: "")
        why.isEnabled = false
        menu.addItem(why)
        return menu
    }
}
