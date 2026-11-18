import AppKit
import CoreFoundation
import Darwin
import Foundation

// MARK: - B1: One cue vocabulary (tick, thud, edge, open) + Settings › Haptics (Off · Calm · Full)
//
// At most 4 named cues across Recense:
//   • tick — step, detent, layer step, page step, or word onset (.alignment / actuator ID 15)
//   • thud — home value, first/last boundary, or pin (.levelChange / actuator ID 5)
//   • edge — zone boundary or edge crossing (.levelChange / actuator ID 3)
//   • open — rest-hold console or surface open (.generic / actuator ID 16)
//
// Modes (Settings › Haptics):
//   • Off  — no haptic cues fire.
//   • Calm — only zone/edge/boundary cues (.edge, .thud, .open) fire; step .tick cues are silenced for sensory load.
//   • Full — all 4 cues fire (default).
//
// Spike result (MTActuatorActuate in MultitouchSupport.framework, macOS 27.2):
//   • PROVEN (API & IOKit return code): MTDeviceGetMTActuator + MTActuatorOpen + MTActuatorActuate resolve and return
//     0 (kIOReturnSuccess) on this Mac's Force Touch trackpad for actuation IDs [1, 3, 5, 15, 16] (15 = light tick,
//     3 = crisp edge detent, 5 = firm thud, 16 = generic open), whereas invalid IDs (e.g. 6) return -536870212.
//   • UNTESTED (subjective feel): whether the tactile difference between IDs 15/3/5/16 and NSHapticFeedbackManager is
//     materially stronger under a finger requires the owner's physical trackpad check.
//   • Opt-in via `Haptics.useDirectActuator` (default false), with `NSHapticFeedbackManager` as default and fallback.

enum HapticCue: String, CaseIterable {
    case tick
    case thud
    case edge
    case open

    /// In `Calm` mode, only zone/edge/boundary cues fire; step ticks are suppressed for sensory load.
    var isZoneOrEdge: Bool {
        switch self {
        case .tick: return false
        case .thud, .edge, .open: return true
        }
    }

    var publicPattern: NSHapticFeedbackManager.FeedbackPattern {
        switch self {
        case .tick: return .alignment
        case .thud: return .levelChange
        case .edge: return .levelChange
        case .open: return .generic
        }
    }

    /// Hardware actuation IDs verified to return kIOReturnSuccess (0) on Apple Force Touch trackpads.
    var actuatorID: Int32 {
        switch self {
        case .tick: return 15
        case .edge: return 3
        case .thud: return 5
        case .open: return 16
        }
    }
}

enum HapticMode: String, CaseIterable {
    case off = "off"
    case calm = "calm"
    case full = "full"

    var label: String {
        switch self {
        case .off: return "Off"
        case .calm: return "Calm"
        case .full: return "Full"
        }
    }

    func allows(_ cue: HapticCue) -> Bool {
        switch self {
        case .off: return false
        case .calm: return cue.isZoneOrEdge
        case .full: return true
        }
    }
}

/// Private MultitouchSupport trackpad actuator spike (opt-in, with public NSHapticFeedbackManager fallback).
final class DirectTrackpadActuator {
    static let shared = DirectTrackpadActuator()

    typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    typealias GetActuator = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    typealias ActOpen = @convention(c) (UnsafeMutableRawPointer) -> Int32
    typealias ActClose = @convention(c) (UnsafeMutableRawPointer) -> Int32
    typealias ActIsOpen = @convention(c) (UnsafeMutableRawPointer) -> Bool
    typealias Actuate = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32

    private var createList: CreateList?
    private var getActuator: GetActuator?
    private var actOpen: ActOpen?
    private var actClose: ActClose?
    private var actIsOpen: ActIsOpen?
    private var actuateFn: Actuate?

    var isSymbolLoaded: Bool {
        createList != nil && getActuator != nil && actOpen != nil && actClose != nil && actuateFn != nil
    }

    private init() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let c = dlsym(h, "MTDeviceCreateList"),
              let g = dlsym(h, "MTDeviceGetMTActuator"),
              let o = dlsym(h, "MTActuatorOpen"),
              let cl = dlsym(h, "MTActuatorClose"),
              let io = dlsym(h, "MTActuatorIsOpen"),
              let a = dlsym(h, "MTActuatorActuate") else { return }
        createList = unsafeBitCast(c, to: CreateList.self)
        getActuator = unsafeBitCast(g, to: GetActuator.self)
        actOpen = unsafeBitCast(o, to: ActOpen.self)
        actClose = unsafeBitCast(cl, to: ActClose.self)
        actIsOpen = unsafeBitCast(io, to: ActIsOpen.self)
        actuateFn = unsafeBitCast(a, to: Actuate.self)
    }

    /// Fires `cue.actuatorID` on the first trackpad device with a valid MTActuator. Returns true on kIOReturnSuccess (0).
    @discardableResult
    func actuate(_ cue: HapticCue) -> Bool {
        guard let createList = createList,
              let getActuator = getActuator,
              let actOpen = actOpen,
              let actClose = actClose,
              let actIsOpen = actIsOpen,
              let actuateFn = actuateFn,
              let list = createList()?.takeRetainedValue() as? [AnyObject] else { return false }
        for dev in list {
            let p = Unmanaged.passUnretained(dev).toOpaque()
            guard let act = getActuator(p) else { continue }
            let wasOpen = actIsOpen(act)
            if !wasOpen && actOpen(act) != 0 { continue }
            let rc = actuateFn(act, cue.actuatorID, 0, 0.0, 0.0)
            if !wasOpen { _ = actClose(act) }
            if rc == 0 { return true }
        }
        return false
    }
}

enum Haptics {
    static let modeKey = "recense.haptics.mode"
    static let actuatorKey = "recense.haptics.directActuator"
    static let changedNotification = Notification.Name("recense.haptics.changed")

    /// Optional test observer receiving `(cue, backend)` where backend is `"public"` or `"actuator"`.
    static var testObserver: ((HapticCue, String) -> Void)?
    /// When set in tests, overrides hardware actuator return value.
    static var actuatorOverride: ((HapticCue) -> Bool)?

    static var mode: HapticMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: modeKey),
                  let m = HapticMode(rawValue: raw) else { return .full }
            return m
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }

    static var useDirectActuator: Bool {
        get { UserDefaults.standard.bool(forKey: actuatorKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: actuatorKey)
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }

    /// Fires a named haptic cue according to Settings › Haptics (`Off · Calm · Full`).
    /// Returns true if the cue was allowed and dispatched, false if filtered out by `Off` or `Calm`.
    @discardableResult
    static func perform(_ cue: HapticCue) -> Bool {
        let currentMode = mode
        guard currentMode.allows(cue) else { return false }
        if useDirectActuator {
            let ok = actuatorOverride?(cue) ?? DirectTrackpadActuator.shared.actuate(cue)
            if ok {
                testObserver?(cue, "actuator")
                return true
            }
        }
        NSHapticFeedbackManager.defaultPerformer.perform(cue.publicPattern, performanceTime: .now)
        testObserver?(cue, "public")
        return true
    }

    // MARK: Settings › Haptics menu & window

    static func menu() -> NSMenu {
        let m = NSMenu(title: "Haptics")
        for hm in HapticMode.allCases {
            let title: String
            switch hm {
            case .off: title = "Off"
            case .calm: title = "Calm (Zone & Edge Cues Only)"
            case .full: title = "Full"
            }
            let item = NSMenuItem(title: title, action: #selector(HapticsMenuTarget.shared.selectMode(_:)), keyEquivalent: "")
            item.target = HapticsMenuTarget.shared
            item.representedObject = hm.rawValue
            item.state = (mode == hm) ? .on : .off
            m.addItem(item)
        }
        m.addItem(.separator())
        let direct = NSMenuItem(
            title: "Direct Trackpad Actuator (Experimental)",
            action: #selector(HapticsMenuTarget.shared.toggleActuator(_:)),
            keyEquivalent: ""
        )
        direct.target = HapticsMenuTarget.shared
        direct.state = useDirectActuator ? .on : .off
        m.addItem(direct)
        m.addItem(.separator())
        let openPanel = NSMenuItem(
            title: "Haptics Settings…",
            action: #selector(HapticsMenuTarget.shared.openSettingsPanel(_:)),
            keyEquivalent: ""
        )
        openPanel.target = HapticsMenuTarget.shared
        m.addItem(openPanel)
        return m
    }
}

final class HapticsMenuTarget: NSObject {
    static let shared = HapticsMenuTarget()
    private var panel: NSPanel?
    private var segControl: NSSegmentedControl?
    private var actuatorCheck: NSButton?

    @objc func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = HapticMode(rawValue: raw) else { return }
        Haptics.mode = m
        syncPanel()
        Haptics.perform(.edge)
    }

    @objc func toggleActuator(_ sender: NSMenuItem) {
        Haptics.useDirectActuator.toggle()
        syncPanel()
        Haptics.perform(.tick)
    }

    @objc func segChanged(_ sender: NSSegmentedControl) {
        let modes = HapticMode.allCases
        guard modes.indices.contains(sender.selectedSegment) else { return }
        Haptics.mode = modes[sender.selectedSegment]
        Haptics.perform(.edge)
    }

    @objc func checkChanged(_ sender: NSButton) {
        Haptics.useDirectActuator = (sender.state == .on)
        Haptics.perform(.tick)
    }

    @objc func closePanel(_ sender: Any?) {
        panel?.orderOut(nil)
    }

    @objc func openSettingsPanel(_ sender: Any?) {
        showSettingsPanel()
    }

    func syncPanel() {
        if let seg = segControl, let idx = HapticMode.allCases.firstIndex(of: Haptics.mode) {
            seg.selectedSegment = idx
        }
        actuatorCheck?.state = Haptics.useDirectActuator ? .on : .off
    }

    func showSettingsPanel() {
        if panel == nil {
            let w: CGFloat = 360, h: CGFloat = 168
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.title = "Settings › Haptics"
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.appearance = NSAppearance(named: .darkAqua)
            p.backgroundColor = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 0.96)

            let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            p.contentView = root

            let heading = NSTextField(labelWithString: "Settings › Haptics")
            heading.font = .systemFont(ofSize: 13.5, weight: .semibold)
            heading.textColor = .white
            heading.frame = NSRect(x: 20, y: h - 52, width: w - 40, height: 18)
            root.addSubview(heading)

            let seg = NSSegmentedControl(labels: ["Off", "Calm", "Full"], trackingMode: .selectOne, target: self, action: #selector(segChanged(_:)))
            seg.segmentStyle = .rounded
            seg.frame = NSRect(x: 20, y: h - 86, width: w - 40, height: 26)
            root.addSubview(seg)
            self.segControl = seg

            let note = NSTextField(labelWithString: "Calm keeps only zone and edge cues for sensory load.\nFelt only while a finger rests on the trackpad.")
            note.font = .systemFont(ofSize: 11, weight: .regular)
            note.textColor = NSColor(white: 1.0, alpha: 0.68)
            note.maximumNumberOfLines = 2
            note.frame = NSRect(x: 20, y: h - 124, width: w - 40, height: 32)
            root.addSubview(note)

            let chk = NSButton(checkboxWithTitle: "Direct trackpad actuator (experimental)", target: self, action: #selector(checkChanged(_:)))
            chk.font = .systemFont(ofSize: 11.5, weight: .medium)
            chk.frame = NSRect(x: 20, y: 18, width: w - 40, height: 20)
            root.addSubview(chk)
            self.actuatorCheck = chk

            self.panel = p
        }
        syncPanel()
        if let scr = NSScreen.main, let p = panel {
            let f = p.frame
            p.setFrameOrigin(NSPoint(x: (scr.frame.midX - f.width / 2).rounded(), y: (scr.frame.maxY - f.height - 54).rounded()))
            p.orderFrontRegardless()
        }
    }

    var settingsWindow: NSPanel? { panel }
}

// MARK: - B2: Global gesture navigation feel & ambidextrous finger-origin measurement

enum GestureNavHaptics {
    /// Ambidextrous displacement: every finger's movement is measured strictly from where it landed (`starts[id]`),
    /// never from the screen side (left/right edge) or hand.
    static func relativeDisplacements(
        starts: [Int32: (x: Float, y: Float)],
        current: [(id: Int32, x: Float, y: Float)]
    ) -> [(dx: Float, dy: Float)]? {
        guard !current.isEmpty, current.count == starts.count else { return nil }
        var out: [(dx: Float, dy: Float)] = []
        out.reserveCapacity(current.count)
        for t in current {
            guard let s0 = starts[t.id] else { return nil }
            out.append((dx: t.x - s0.x, dy: t.y - s0.y))
        }
        return out
    }

    /// Three-finger layer navigation cue (`0 = hidden`, `1 = essentials`, `2 = draftpad`):
    /// - A `tick` per layer stepped (`0 -> 1` or `1 -> 2`).
    /// - A `thud` at the first (`0`, closing or already closed) and last (`2` when swiping up at the top layer).
    static func layerCue(fromLayer: Int, toLayer: Int, attemptedDirection: Int) -> HapticCue? {
        guard attemptedDirection != 0 else { return nil }
        if fromLayer != toLayer {
            if toLayer <= 0 { return .thud }
            return .tick
        }
        if attemptedDirection > 0 && fromLayer >= 2 { return .thud }
        if attemptedDirection < 0 && fromLayer <= 0 { return .thud }
        return nil
    }

    /// Two-finger paging cue across `count` pages (`0 ..< count`):
    /// - A `tick` per page stepped (`to != from` on interior pages).
    /// - A `thud` when landing on or pulling past the first (`0`) or last (`count - 1`) page.
    static func pageCue(from: Int, to: Int, count: Int, pullDelta: CGFloat) -> HapticCue? {
        guard count > 0 else { return nil }
        if to != from {
            if to <= 0 || to >= count - 1 { return .thud }
            return .tick
        }
        if from <= 0 && pullDelta < -10 { return .thud }
        if from >= count - 1 && pullDelta > 10 { return .thud }
        return nil
    }

    @discardableResult
    static func performLayer(fromLayer: Int, toLayer: Int, attemptedDirection: Int) -> HapticCue? {
        guard let cue = layerCue(fromLayer: fromLayer, toLayer: toLayer, attemptedDirection: attemptedDirection) else { return nil }
        Haptics.perform(cue)
        return cue
    }

    @discardableResult
    static func performPage(from: Int, to: Int, count: Int, pullDelta: CGFloat) -> HapticCue? {
        guard let cue = pageCue(from: from, to: to, count: count, pullDelta: pullDelta) else { return nil }
        Haptics.perform(cue)
        return cue
    }
}

func hapticsSelftest() -> Bool {
    let savedMode = Haptics.mode
    let savedActuator = Haptics.useDirectActuator
    defer {
        Haptics.testObserver = nil
        Haptics.actuatorOverride = nil
        Haptics.mode = savedMode
        Haptics.useDirectActuator = savedActuator
    }

    // 1. Vocabulary ceiling: at most 4 named cues (tick, thud, edge, open).
    let names = HapticCue.allCases.map(\.rawValue)
    let vocabOK = names == ["tick", "thud", "edge", "open"] && HapticCue.allCases.count == 4
    print("\(vocabOK ? "ok  " : "FAIL") haptics, one cue vocabulary of 4 named cues (tick, thud, edge, open)")

    // 2. Settings › Haptics modes: Off · Calm · Full. Calm allows only zone/edge cues (thud, edge, open) and suppresses tick.
    var fired: [(HapticCue, String)] = []
    Haptics.useDirectActuator = false
    Haptics.testObserver = { cue, backend in fired.append((cue, backend)) }

    Haptics.mode = .off
    for c in HapticCue.allCases { _ = Haptics.perform(c) }
    let offOK = fired.isEmpty && Haptics.mode == .off

    fired.removeAll()
    Haptics.mode = .calm
    for c in HapticCue.allCases { _ = Haptics.perform(c) }
    let calmCues = fired.map(\.0)
    let calmOK = calmCues == [.thud, .edge, .open] && !calmCues.contains(.tick)

    fired.removeAll()
    Haptics.mode = .full
    for c in HapticCue.allCases { _ = Haptics.perform(c) }
    let fullCues = fired.map(\.0)
    let fullOK = fullCues == [.tick, .thud, .edge, .open] && fired.allSatisfy { $0.1 == "public" }

    let modesOK = offOK && calmOK && fullOK
    print("\(modesOK ? "ok  " : "FAIL") haptics, Settings › Haptics (Off · Calm · Full) filters tick in Calm and persists")

    // 3. Opt-in MTActuatorActuate spike with automatic public fallback.
    fired.removeAll()
    Haptics.useDirectActuator = true
    Haptics.actuatorOverride = { _ in true }
    _ = Haptics.perform(.tick)
    let optInOK = fired.count == 1 && fired[0].0 == .tick && fired[0].1 == "actuator"

    fired.removeAll()
    Haptics.actuatorOverride = { _ in false }
    _ = Haptics.perform(.thud)
    let fallbackOK = fired.count == 1 && fired[0].0 == .thud && fired[0].1 == "public"

    Haptics.actuatorOverride = nil
    let symbolOK = DirectTrackpadActuator.shared.isSymbolLoaded
    let spikeOK = optInOK && fallbackOK && symbolOK
    print("\(spikeOK ? "ok  " : "FAIL") haptics, opt-in MTActuatorActuate spike resolves and falls back to NSHapticFeedbackManager")

    // 4. B2: Global gesture nav haptics (tick per layer/page, thud at first and last) and ambidextrous finger-origin measurement.
    Haptics.useDirectActuator = false
    Haptics.mode = .full
    fired.removeAll()
    _ = GestureNavHaptics.performLayer(fromLayer: 0, toLayer: 1, attemptedDirection: 1)
    _ = GestureNavHaptics.performLayer(fromLayer: 1, toLayer: 2, attemptedDirection: 1)
    _ = GestureNavHaptics.performLayer(fromLayer: 2, toLayer: 2, attemptedDirection: 1)
    _ = GestureNavHaptics.performLayer(fromLayer: 2, toLayer: 0, attemptedDirection: -1)
    let layerSeqOK = fired.map(\.0) == [.tick, .tick, .thud, .thud]

    fired.removeAll()
    _ = GestureNavHaptics.performPage(from: 0, to: 1, count: 4, pullDelta: 80)
    _ = GestureNavHaptics.performPage(from: 1, to: 2, count: 4, pullDelta: 80)
    _ = GestureNavHaptics.performPage(from: 2, to: 3, count: 4, pullDelta: 80)
    _ = GestureNavHaptics.performPage(from: 3, to: 3, count: 4, pullDelta: 80)
    _ = GestureNavHaptics.performPage(from: 1, to: 0, count: 4, pullDelta: -80)
    _ = GestureNavHaptics.performPage(from: 0, to: 0, count: 4, pullDelta: -80)
    let pageSeqOK = fired.map(\.0) == [.tick, .tick, .thud, .thud, .thud, .thud]

    let leftStarts: [Int32: (x: Float, y: Float)] = [1: (0.12, 0.20), 2: (0.18, 0.22), 3: (0.24, 0.21)]
    let leftCurr: [(id: Int32, x: Float, y: Float)] = [(1, 0.12, 0.34), (2, 0.18, 0.36), (3, 0.24, 0.35)]
    let rightStarts: [Int32: (x: Float, y: Float)] = [1: (0.72, 0.60), 2: (0.78, 0.62), 3: (0.84, 0.61)]
    let rightCurr: [(id: Int32, x: Float, y: Float)] = [(1, 0.72, 0.74), (2, 0.78, 0.76), (3, 0.84, 0.75)]
    let dLeft = GestureNavHaptics.relativeDisplacements(starts: leftStarts, current: leftCurr) ?? []
    let dRight = GestureNavHaptics.relativeDisplacements(starts: rightStarts, current: rightCurr) ?? []
    let ambidextrousOK = dLeft.count == 3 && dRight.count == 3 && zip(dLeft, dRight).allSatisfy {
        abs($0.dx - $1.dx) < 1e-5 && abs($0.dy - $1.dy) < 1e-5
    }
    let b2OK = layerSeqOK && pageSeqOK && ambidextrousOK
    print("\(b2OK ? "ok  " : "FAIL") haptics, B2 gesture nav fires tick per layer/page, thud at first/last, and measures from finger landing")

    return vocabOK && modesOK && spikeOK && b2OK
}
