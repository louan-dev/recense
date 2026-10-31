// Nook — a menu bar hider inspired by Tuck. Targets macOS 14+ (tested design: Sequoia 15.5).
// Build & run: zsh build.sh, then open /Applications/Nook.app
//
// How it works: macOS gives apps no way to hide Apple's own icons (clock, battery...).
// Nook adds two divider status items. When collapsed, a divider becomes 10,000pt wide and
// pushes every icon to its left off-screen. You ⌘-drag icons to the left of a divider.
//
//   [ always-hidden icons ] ┆ [ hidden icons ] │ ‹›  [ always-visible icons ] [ system icons ]

import AppKit
import ServiceManagement

// MARK: - Model & preferences

enum RuleAction: String, Codable, CaseIterable {
    case hideAll = "Hide all"
    case showAll = "Show all"
    case showSelection = "Show selection"   // reveals the "hidden" tier, keeps "always hidden" tucked away
}

struct Rule: Codable {
    var bundleID: String
    var name: String
    var action: RuleAction
}

enum Prefs {
    private static let d = UserDefaults.standard

    static var autoHideDelay: Double {          // seconds; 0 = never
        get { d.object(forKey: "autoHideDelay") as? Double ?? 3 }
        set { d.set(newValue, forKey: "autoHideDelay") }
    }
    static var hoverToPeek: Bool {
        get { d.object(forKey: "hoverToPeek") as? Bool ?? true }
        set { d.set(newValue, forKey: "hoverToPeek") }
    }
    static var rulesEnabled: Bool {
        get { d.object(forKey: "rulesEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "rulesEnabled") }
    }
    static var onboarded: Bool {
        get { d.bool(forKey: "onboarded") }
        set { d.set(newValue, forKey: "onboarded") }
    }
    static var rules: [Rule] {
        get {
            guard let data = d.data(forKey: "rules") else { return [] }
            return (try? JSONDecoder().decode([Rule].self, from: data)) ?? []
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "rules") }
    }
}

// MARK: - Closure-based menu item

final class ActionItem: NSMenuItem {
    private var handler: () -> Void = {}

    init(_ title: String, _ handler: @escaping () -> Void) {
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.handler = handler
        self.target = self
    }
    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { handler() }
}

// MARK: - Menu bar controller

final class BarController: NSObject {
    private var toggleItem: NSStatusItem!      // the ‹ › button (rightmost of ours)
    private var hiddenDivider: NSStatusItem!   // │ icons to its left are "hidden"
    private var alwaysDivider: NSStatusItem!   // ┆ icons to its left are "always hidden"

    private var hiddenShown = true
    private var alwaysShown = false
    private var activeRule: RuleAction?
    private var frontmost: NSRunningApplication?
    private var deadline = Date.distantFuture
    private var timer: Timer?

    // MARK: Lifecycle

    func start() {
        // Creation order decides placement (first created = rightmost).
        toggleItem = makeItem("nook-toggle")
        hiddenDivider = makeItem("nook-divider")
        alwaysDivider = makeItem("nook-always")

        if let b = toggleItem.button {
            b.target = self
            b.action = #selector(toggleClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // Hover to peek + keep items open while you're interacting with the menu bar.
        _ = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.mouseMoved()
        }
        _ = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // A click in the bar may open a menu below it, so give it extra time.
            if self?.pointerInMenuBar() == true { self?.hold(10) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }

        frontmost = NSWorkspace.shared.frontmostApplication
        render()
        if Prefs.onboarded {
            hold()
            applyRule(for: frontmost)
        } else {
            onboard()
        }
    }

    private func makeItem(_ name: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = name   // remembers where you ⌘-dragged it
        return item
    }

    // MARK: Show / hide

    private func show(all: Bool = false) { hiddenShown = true; alwaysShown = all; render() }
    private func hide() { hiddenShown = false; alwaysShown = false; render() }

    private func render() {
        style(hiddenDivider, expanded: hiddenShown, glyph: "│")
        style(alwaysDivider, expanded: hiddenShown && alwaysShown, glyph: "┆")
        let symbol = hiddenShown ? "chevron.right" : "chevron.left"
        toggleItem.button?.image = NSImage(systemSymbolName: symbol,
                                           accessibilityDescription: "Toggle hidden menu bar items")
    }

    private func style(_ item: NSStatusItem, expanded: Bool, glyph: String) {
        guard let b = item.button else { return }
        if expanded {
            item.length = NSStatusItem.variableLength
            b.title = glyph
            b.alphaValue = 0.4
        } else {
            b.title = ""
            item.length = 10_000   // the trick: shoves everything on its left off-screen
        }
    }

    // MARK: Auto-hide & hover

    private func hold(_ seconds: Double? = nil) {
        let s = seconds ?? Prefs.autoHideDelay
        deadline = s > 0 ? Date().addingTimeInterval(s) : .distantFuture
    }

    private func tick() {
        guard hiddenShown, Prefs.autoHideDelay > 0, Date() >= deadline else { return }
        if activeRule == .showAll || activeRule == .showSelection { return }   // rule keeps them open
        if pointerInMenuBar() { hold(); return }                              // don't yank icons from under the cursor
        hide()
    }

    private func pointerInMenuBar() -> Bool {
        let p = NSEvent.mouseLocation
        guard let s = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }) else { return false }
        let height = max(s.frame.maxY - s.visibleFrame.maxY, NSStatusBar.system.thickness)
        return p.y >= s.frame.maxY - height
    }

    private func mouseMoved() {
        guard Prefs.hoverToPeek, !hiddenShown, pointerInMenuBar(),
              let frame = toggleItem.button?.window?.frame else { return }
        if frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) {
            show()
            hold()
        }
    }

    // MARK: Click handling

    @objc private func toggleClicked(_ sender: Any?) {
        guard let e = NSApp.currentEvent else { return }
        if e.type == .rightMouseUp || e.modifierFlags.contains(.control) {
            showMenu()
        } else if e.modifierFlags.contains(.option) {
            show(all: !alwaysShown); hold()
        } else if hiddenShown {
            hide()
        } else {
            show(); hold()
        }
    }

    // MARK: Rules Mode

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        frontmost = app
        applyRule(for: app)
    }

    private func applyRule(for app: NSRunningApplication?) {
        guard Prefs.rulesEnabled, let id = app?.bundleIdentifier,
              let rule = Prefs.rules.first(where: { $0.bundleID == id }) else {
            if activeRule != nil { activeRule = nil; hide() }   // left a rule app → back to default
            return
        }
        activeRule = rule.action
        switch rule.action {
        case .hideAll:       hide()
        case .showAll:       show(all: true)
        case .showSelection: show(all: false)
        }
    }

    private func setRule(_ id: String, _ name: String, _ action: RuleAction) {
        var rules = Prefs.rules
        if let i = rules.firstIndex(where: { $0.bundleID == id }) {
            rules[i].action = action
        } else {
            rules.append(Rule(bundleID: id, name: name, action: action))
        }
        Prefs.rules = rules
        applyRule(for: frontmost)
    }

    private func removeRule(_ id: String) {
        Prefs.rules = Prefs.rules.filter { $0.bundleID != id }
        applyRule(for: frontmost)
    }

    // MARK: Settings menu

    private func showMenu() {
        guard let b = toggleItem.button else { return }
        buildMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 5), in: b)
    }

    private func actionsMenu(_ id: String, _ name: String, current: RuleAction?) -> NSMenu {
        let m = NSMenu()
        for action in RuleAction.allCases {
            let item = ActionItem(action.rawValue) { [weak self] in self?.setRule(id, name, action) }
            item.state = action == current ? .on : .off
            m.addItem(item)
        }
        if current != nil {
            m.addItem(.separator())
            m.addItem(ActionItem("Remove Rule") { [weak self] in self?.removeRule(id) })
        }
        return m
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(ActionItem(hiddenShown ? "Hide Items" : "Show Hidden Items") { [weak self] in
            guard let self = self else { return }
            if self.hiddenShown { self.hide() } else { self.show(); self.hold() }
        })
        menu.addItem(ActionItem("Reveal Always-Hidden Items") { [weak self] in
            self?.show(all: true); self?.hold(60)
        })
        menu.addItem(.separator())

        // Auto-hide delay
        let autoItem = NSMenuItem(title: "Auto-hide After", action: nil, keyEquivalent: "")
        let autoMenu = NSMenu()
        let options: [(String, Double)] = [("Never", 0), ("1 second", 1), ("2 seconds", 2), ("3 seconds", 3),
                                           ("5 seconds", 5), ("10 seconds", 10), ("30 seconds", 30)]
        for (label, secs) in options {
            let item = ActionItem(label) { Prefs.autoHideDelay = secs }
            item.state = Prefs.autoHideDelay == secs ? .on : .off
            autoMenu.addItem(item)
        }
        autoItem.submenu = autoMenu
        menu.addItem(autoItem)

        let hover = ActionItem("Peek on Hover") { Prefs.hoverToPeek.toggle() }
        hover.state = Prefs.hoverToPeek ? .on : .off
        menu.addItem(hover)
        menu.addItem(.separator())

        // Rules Mode
        let rulesOn = ActionItem("Rules Mode") { [weak self] in
            Prefs.rulesEnabled.toggle()
            self?.applyRule(for: self?.frontmost)
        }
        rulesOn.state = Prefs.rulesEnabled ? .on : .off
        menu.addItem(rulesOn)

        let rulesItem = NSMenuItem(title: "Rules", action: nil, keyEquivalent: "")
        let rulesMenu = NSMenu()
        let rules = Prefs.rules
        for rule in rules {
            let item = NSMenuItem(title: "\(rule.name)  →  \(rule.action.rawValue)", action: nil, keyEquivalent: "")
            item.submenu = actionsMenu(rule.bundleID, rule.name, current: rule.action)
            rulesMenu.addItem(item)
        }
        if !rules.isEmpty { rulesMenu.addItem(.separator()) }

        let addItem = NSMenuItem(title: "Add Rule for…", action: nil, keyEquivalent: "")
        let addMenu = NSMenu()
        let existing = Set(rules.map { $0.bundleID })
        var apps: [NSRunningApplication] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, !existing.contains(id) else { continue }
            apps.append(app)
        }
        apps.sort { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in apps {
            let id = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? id
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            if let icon = app.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            item.submenu = actionsMenu(id, name, current: nil)
            addMenu.addItem(item)
        }
        addItem.submenu = addMenu
        rulesMenu.addItem(addItem)
        rulesItem.submenu = rulesMenu
        menu.addItem(rulesItem)
        menu.addItem(.separator())

        // Launch at login
        let login = ActionItem("Launch at Login") {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch { NSSound.beep() }
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(ActionItem("Quit Nook") { NSApp.terminate(nil) })
        return menu
    }

    // MARK: First launch

    private func onboard() {
        Prefs.onboarded = true
        show(all: true)
        hold(60)   // stay open so you can arrange icons
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Welcome to Nook"
        alert.informativeText = """
        macOS doesn't let apps hide Apple's icons directly, so Nook adds two dividers (│ and ┆) next to the ‹ › button.

        1. Hold ⌘ and drag an icon (Battery, Wi-Fi…) to the LEFT of │ to hide it.
        2. Drag icons to the left of ┆ to keep them always hidden.
        3. Click ‹ › to show or hide. ⌥-click reveals everything. Right-click for settings and Rules Mode.
        """
        alert.runModal()
    }
}

// MARK: - App entry

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let bar = BarController()
    func applicationDidFinishLaunching(_ notification: Notification) { bar.start() }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)   // no Dock icon
application.run()
