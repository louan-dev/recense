// draftpad.swift
// An Antinote-style floating draftpad that reads/writes ONE markdown file in your Obsidian vault.
// Pages sit side by side in a horizontal strip; each page scrolls vertically on its own.
//
// Build:  swiftc -O draftpad.swift -o draftpad
// Run:    ./draftpad &
// Control the running copy from another tool (BetterTouchTool, Shortcuts, shell):
//   ./draftpad show     ./draftpad hide     ./draftpad toggle     ./draftpad quit     ./draftpad status
//   - show / toggle launch the app if it isn't running yet.
//   - hide / quit print "draftpad is not running" and exit 1 if there is nothing to act on.
//   - status prints "visible" or "hidden" and exits 0, or prints "not running" and exits 1.
//   - any other argument prints usage and exits 64 (so a typo can't launch a stray copy).
//
// Two fingers up/down      = scroll the current page (normal scrolling)
// Two fingers left/right   = the strip follows your fingers and snaps to the next / previous page.
//                            Pulling left past the last page (when it has text) opens a new one.
// Cmd+] / Cmd+[            = next / previous page from the keyboard
// Esc or Cmd+W             = hide
// Ctrl+Option+Space        = summon / hide
// Trackpad gestures (show / hide / quit) are NOT handled in this file. BetterTouchTool runs the
// commands above, so there is exactly one source of truth and nothing double-fires.
//
// File format: pages are separated by  <!-- page -->  (hidden in Obsidian's reading view).

import Cocoa
import Carbon.HIToolbox

// MARK: - Settings (edit these)

// DISCLAIMER: this default is hardcoded to the author's own Mac and iCloud vault, so it points at a folder
// that won't exist on yours. Edit it here and rebuild, or set the DRAFTPAD environment variable for a single
// launch:   DRAFTPAD=/path/to/draftpad.md ./draftpad &
let defaultNotePath = "/Users/chauphan/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian/draftpad.md"
let notePath: String = {
    if let p = ProcessInfo.processInfo.environment["DRAFTPAD"], !p.isEmpty {
        return (p as NSString).expandingTildeInPath
    }
    return defaultNotePath
}()
let panelSize = NSSize(width: 400, height: 300)
let fontSize: CGFloat = 14
let hotKeyCode = UInt32(kVK_Space)
let hotKeyMods = UInt32(controlKey | optionKey)
let footerHeight: CGFloat = 24

let pageMarker = "<!-- page -->"
let pageJoiner = "\n\n\(pageMarker)\n\n"
let toggleName = Notification.Name("local.draftpad.toggle")
let frameName = "DraftpadPanel"
let statePath = "/tmp/local.draftpad.state"   // what `draftpad status` reads: "visible" or "hidden"

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

func isBlank(_ s: String) -> Bool {
    s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// The running copy records whether its window is showing; `draftpad status` reads it back.
func writeState(_ state: String) {
    try? state.write(toFile: statePath, atomically: true, encoding: .utf8)
}

func readState() -> String? {
    guard let s = try? String(contentsOfFile: statePath, encoding: .utf8) else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return (t == "visible" || t == "hidden") ? t : nil
}

// MARK: - Views

final class PadPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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

final class PageView {
    let scroll = NSScrollView()
    let textView = PadTextView(frame: .zero)

    init(frame: NSRect) {
        scroll.frame = frame
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
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
        textView.textContainerInset = NSSize(width: 14, height: 14)
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
    let id = EventHotKeyID(signature: OSType(0x44465450), id: 1)   // 'DFTP'
    RegisterEventHotKey(hotKeyCode, hotKeyMods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    let panel = PadPanel(
        contentRect: NSRect(origin: .zero, size: panelSize),
        styleMask: [.borderless, .nonactivatingPanel, .resizable],
        backing: .buffered, defer: false)
    let viewport = Viewport(frame: .zero)
    let strip = NSView()
    let pageLabel = NSTextField(labelWithString: "")

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

    // MARK: Launch

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        buildPanel()

        let d = UserDefaults.standard
        index = max(d.integer(forKey: "page"), 0)
        if d.object(forKey: "cursor") != nil { cursors[index] = d.integer(forKey: "cursor") }
        load()
        index = min(index, views.count - 1)
        layoutStrip()
        updateLabel()
        ready = true

        registerHotKey { [weak self] in self?.toggle() }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(remoteCommand(_:)), name: toggleName, object: nil)

        // Pick up edits made in Obsidian.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollExternal()
            self?.restoreState()
        }

        show()
    }

    func applicationWillTerminate(_ n: Notification) {
        saveNow()
        try? FileManager.default.removeItem(atPath: statePath)
    }

    // MARK: UI

    func buildPanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 280, height: 180)
        panel.setFrameAutosaveName(frameName)

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        viewport.frame = NSRect(x: 0, y: footerHeight,
                                width: panelSize.width, height: panelSize.height - footerHeight)
        viewport.autoresizingMask = [.width, .height]
        viewport.autoresizesSubviews = false
        viewport.wantsLayer = true
        viewport.layer?.masksToBounds = true
        viewport.onResize = { [weak self] in self?.layoutStrip() }
        strip.wantsLayer = true
        viewport.addSubview(strip)
        effect.addSubview(viewport)

        pageLabel.frame = NSRect(x: 0, y: 5, width: panelSize.width, height: 14)
        pageLabel.autoresizingMask = [.width, .maxYMargin]
        pageLabel.alignment = .center
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        pageLabel.textColor = .tertiaryLabelColor
        effect.addSubview(pageLabel)
    }

    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit draftpad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

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
        let page = NSMenu(title: "Page"); pageItem.submenu = page
        let prev = page.addItem(withTitle: "Previous Page", action: #selector(prevPage), keyEquivalent: "[")
        let next = page.addItem(withTitle: "Next Page", action: #selector(nextPage), keyEquivalent: "]")
        let hideItem = page.addItem(withTitle: "Hide", action: #selector(hidePanel), keyEquivalent: "w")
        [prev, next, hideItem].forEach { $0.target = self }

        NSApp.mainMenu = main
    }

    @objc func prevPage() { step(-1) }
    @objc func nextPage() { step(1) }
    @objc func hidePanel() { hide() }

    // MARK: Show / hide

    @objc func toggle() { panel.isVisible ? hide() : show() }

    /// Commands sent by `draftpad show|hide|toggle|quit` from BetterTouchTool, shell, Shortcuts, etc.
    @objc func remoteCommand(_ n: Notification) {
        switch (n.object as? String) ?? "toggle" {
        case "show": show()
        case "hide": hide()
        case "quit": saveNow(); NSApp.terminate(nil)
        default: toggle()
        }
    }

    func show() {
        if !panel.setFrameUsingName(frameName) {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let vf = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: vf.midX - panelSize.width / 2,
                                             y: vf.midY - panelSize.height / 2 + vf.height * 0.12))
            }
        }
        panel.makeKeyAndOrderFront(nil)
        if views.indices.contains(index) { panel.makeFirstResponder(views[index].textView) }
        writeState("visible")
    }

    func hide() {
        if dragging { dragging = false; dragX = 0; layoutStrip() }
        saveNow()
        panel.orderOut(nil)
        writeState("hidden")
    }

    /// Keeps the file behind `draftpad status` correct even if /tmp is cleaned while the app runs.
    func restoreState() {
        if !FileManager.default.fileExists(atPath: statePath) {
            writeState(panel.isVisible ? "visible" : "hidden")
        }
    }

    // MARK: Strip layout

    func layoutStrip() {
        let w = viewport.bounds.width, h = viewport.bounds.height
        guard w > 0, !views.isEmpty else { return }
        let drag = dragging ? effectiveDrag() : 0
        strip.frame = NSRect(x: -CGFloat(index) * w + drag, y: 0,
                             width: w * CGFloat(views.count), height: h)
        for (i, v) in views.enumerated() {
            v.scroll.frame = NSRect(x: CGFloat(i) * w, y: 0, width: w, height: h)
        }
    }

    /// Finger offset with rubber-banding when there's nowhere to go.
    func effectiveDrag() -> CGFloat {
        let w = viewport.bounds.width
        var v = dragX
        if v < 0 && index >= views.count - 1 { v *= 0.25 }
        if v > 0 && index <= 0 { v *= 0.25 }
        return max(-w, min(w, v))
    }

    func updateLabel() {
        if views.count <= 8 {
            pageLabel.stringValue = views.indices.map { $0 == index ? "●" : "○" }.joined(separator: " ")
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
        guard !settling, !dragging else { return }
        let target = index + delta
        if target < 0 { bounce(); return }
        if target >= views.count {
            guard !isBlank(views[index].textView.string) else { bounce(); return }
            appendView("")
        }
        settle(to: target)
    }

    func handleDrag(_ dx: CGFloat, ended: Bool) {
        guard !settling else { return }
        dragging = true
        dragX += dx

        // Pulling past the last page reveals a fresh one, but only if this page has something on it.
        if dragX < -8, index == views.count - 1, !isBlank(views[index].textView.string) {
            appendView("")
        }
        layoutStrip()
        updateLabel()
        if ended { finishDrag() }
    }

    func finishDrag() {
        let threshold = min(60, viewport.bounds.width * 0.2)
        var target = index
        if dragX < -threshold, index < views.count - 1 { target = index + 1 }
        else if dragX > threshold, index > 0 { target = index - 1 }
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

        let dest = NSRect(x: -CGFloat(target) * w, y: 0, width: strip.frame.width, height: strip.frame.height)
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
        panel.makeFirstResponder(views[index].textView)
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
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in self?.saveNow() }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView,
              let i = views.firstIndex(where: { $0.textView === tv }) else { return }
        cursors[i] = tv.selectedRange().location
    }

    // MARK: File I/O

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

let commands = ["toggle", "show", "hide", "quit", "status"]

// Single instance, enforced with a lock file. Holding the lock means "I am the running copy".
let lockFD = open("/tmp/local.draftpad.lock", O_CREAT | O_RDWR, 0o600)
let holdsLock = lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) == 0

if let cmd = CommandLine.arguments.dropFirst().first {
    guard commands.contains(cmd) else {
        fputs("usage: draftpad [toggle|show|hide|quit|status]\n", stderr)
        exit(64)
    }
    if cmd == "status" {
        // If this process just took the lock, no other copy holds it, so nothing is running.
        if holdsLock { print("not running"); exit(1) }
        guard let state = readState() else { print("unknown"); exit(1) }
        print(state)
        exit(0)
    }
    if !holdsLock {
        // A copy is already running: hand it the command and leave.
        DistributedNotificationCenter.default().postNotificationName(
            toggleName, object: cmd, userInfo: nil, deliverImmediately: true)
        exit(0)
    }
    // Nothing is running. hide / quit have nothing to act on; show / toggle fall through and launch.
    if cmd == "hide" || cmd == "quit" {
        fputs("draftpad is not running\n", stderr)
        exit(1)
    }
} else if !holdsLock {
    // Plain launch while a copy is already running: just bring that copy up.
    DistributedNotificationCenter.default().postNotificationName(
        toggleName, object: "show", userInfo: nil, deliverImmediately: true)
    exit(0)
}

// A fresh copy starts hidden until show() runs. This also overwrites a stale file left by a killed copy.
writeState("hidden")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appDelegate = App()
app.delegate = appDelegate
app.run()