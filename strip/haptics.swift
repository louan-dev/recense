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
    static let cueTimingOffsetMsKey = "recense.haptics.cueTimingOffsetMs"
    static let defaultCueTimingOffsetMs: Int = 50
    static let cueTimingRangeMs: ClosedRange<Int> = -100...260
    static let changedNotification = Notification.Name("recense.haptics.changed")

    /// Optional test observer receiving `(cue, backend)` where backend is `"public"` or `"actuator"`.
    static var testObserver: ((HapticCue, String) -> Void)?
    /// Records the `cueTimingOffsetMs` read by the most recent `perform(_:)` call (B4).
    private(set) static var lastReadCueTimingOffsetMs: Int = defaultCueTimingOffsetMs
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

    /// B4: Visual-delay remap (Settings › Cue timing). Offset between the karaoke light and its haptic/audio cue,
    /// clamped to `-100…+260 ms`. Default is `+50 ms` (the light leads and the cue follows at +50 ms).
    static var cueTimingOffsetMs: Int {
        get {
            guard UserDefaults.standard.object(forKey: cueTimingOffsetMsKey) != nil else {
                return defaultCueTimingOffsetMs
            }
            let raw = UserDefaults.standard.integer(forKey: cueTimingOffsetMsKey)
            return min(cueTimingRangeMs.upperBound, max(cueTimingRangeMs.lowerBound, raw))
        }
        set {
            let clamped = min(cueTimingRangeMs.upperBound, max(cueTimingRangeMs.lowerBound, newValue))
            UserDefaults.standard.set(clamped, forKey: cueTimingOffsetMsKey)
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }

    static var cueTimingOffsetSeconds: TimeInterval {
        Double(cueTimingOffsetMs) / 1000.0
    }

    /// Maps a karaoke light timestamp (seconds) to the timestamp when its haptic/audio cue fires.
    static func effectiveCueTimestamp(forLightTimestamp lightTime: Double) -> Double {
        lastReadCueTimingOffsetMs = cueTimingOffsetMs
        return lightTime + Double(lastReadCueTimingOffsetMs) / 1000.0
    }

    static func cueTimingSummary(_ ms: Int = cueTimingOffsetMs) -> String {
        if ms > 0 { return "+\(ms) ms (light leads, cue follows)" }
        if ms < 0 { return "\(ms) ms (cue leads light)" }
        return "0 ms (simultaneous)"
    }

    /// Fires a named haptic cue according to Settings › Haptics (`Off · Calm · Full`).
    /// Every cue reads `cueTimingOffsetMs` (`lastReadCueTimingOffsetMs`).
    /// Returns true if the cue was allowed and dispatched, false if filtered out by `Off` or `Calm`.
    @discardableResult
    static func perform(_ cue: HapticCue) -> Bool {
        lastReadCueTimingOffsetMs = cueTimingOffsetMs
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

    /// Fires a zone-boundary cue: `.tick` in `.full` mode (so the tick count tells you which zone you reached)
    /// and `.edge` in `.calm` mode (so zone boundaries remain felt when step ticks are silenced).
    @discardableResult
    static func performZoneBoundary() -> Bool {
        switch mode {
        case .off: return false
        case .calm: return perform(.edge)
        case .full: return perform(.tick)
        }
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
        let zonesHeader = NSMenuItem(title: "Console Zones (Speed & Level always on)", action: nil, keyEquivalent: "")
        zonesHeader.isEnabled = false
        m.addItem(zonesHeader)
        for z in ConsoleZone.unlockableZones {
            let zi = NSMenuItem(
                title: "Unlock \(z.label)",
                action: #selector(HapticsMenuTarget.shared.toggleZoneMenu(_:)),
                keyEquivalent: ""
            )
            zi.target = HapticsMenuTarget.shared
            zi.representedObject = z.rawValue
            zi.state = RestHoldConsole.shared.isZoneUnlocked(z) ? .on : .off
            m.addItem(zi)
        }
        m.addItem(.separator())
        let timingItem = NSMenuItem(title: "Cue Timing (\(cueTimingSummary()))", action: nil, keyEquivalent: "")
        let timingMenu = NSMenu(title: "Cue Timing")
        for preset in [-100, -50, 0, 50, 100, 180, 260] {
            let label = preset == 50 ? "+50 ms (Default — Light Leads)" : (preset > 0 ? "+\(preset) ms" : "\(preset) ms")
            let pi = NSMenuItem(title: label, action: #selector(HapticsMenuTarget.shared.selectCueTimingMenu(_:)), keyEquivalent: "")
            pi.target = HapticsMenuTarget.shared
            pi.representedObject = preset
            pi.state = (cueTimingOffsetMs == preset) ? .on : .off
            timingMenu.addItem(pi)
        }
        timingItem.submenu = timingMenu
        m.addItem(timingItem)
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
    private var zoneChecks: [ConsoleZone: NSButton] = [:]
    private var speedSeg: NSSegmentedControl?
    private var timingLabel: NSTextField?
    private var timingSlider: NSSlider?

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

    @objc func toggleZoneMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let z = ConsoleZone(rawValue: raw) else { return }
        let unlocked = !RestHoldConsole.shared.isZoneUnlocked(z)
        RestHoldConsole.shared.setZone(z, unlocked: unlocked)
        syncPanel()
        Haptics.perform(.edge)
    }

    @objc func selectCueTimingMenu(_ sender: NSMenuItem) {
        guard let ms = sender.representedObject as? Int else { return }
        Haptics.cueTimingOffsetMs = ms
        syncPanel()
        Haptics.perform(ms == Haptics.defaultCueTimingOffsetMs ? .thud : .tick)
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

    @objc func zoneCheckChanged(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let z = ConsoleZone(rawValue: raw) else { return }
        RestHoldConsole.shared.setZone(z, unlocked: sender.state == .on)
        Haptics.perform(.edge)
    }

    @objc func speedSegChanged(_ sender: NSSegmentedControl) {
        let detents = ConsoleZone.speed.detents
        guard detents.indices.contains(sender.selectedSegment) else { return }
        let v = detents[sender.selectedSegment]
        RestHoldConsole.shared.setValue(v, for: .speed, fireHaptics: true)
    }

    @objc func timingSliderChanged(_ sender: NSSlider) {
        let stepped = Int((sender.doubleValue / 10.0).rounded()) * 10
        let prev = Haptics.cueTimingOffsetMs
        Haptics.cueTimingOffsetMs = stepped
        syncPanel()
        if stepped != prev {
            Haptics.perform(stepped == Haptics.defaultCueTimingOffsetMs ? .thud : .tick)
        }
    }

    @objc func resetCueTiming(_ sender: Any?) {
        Haptics.cueTimingOffsetMs = Haptics.defaultCueTimingOffsetMs
        syncPanel()
        Haptics.perform(.thud)
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
        for (z, btn) in zoneChecks {
            btn.state = RestHoldConsole.shared.isZoneUnlocked(z) ? .on : .off
        }
        if let sseg = speedSeg {
            let detents = ConsoleZone.speed.detents
            let cur = RestHoldConsole.shared.globalSpeed
            if let idx = detents.enumerated().min(by: { abs($0.element - cur) < abs($1.element - cur) })?.offset {
                sseg.selectedSegment = idx
            }
        }
        let ms = Haptics.cueTimingOffsetMs
        timingSlider?.integerValue = ms
        timingLabel?.stringValue = "Cue Timing · \(Haptics.cueTimingSummary(ms))"
    }

    func showSettingsPanel() {
        if panel == nil {
            let w: CGFloat = 380, h: CGFloat = 332
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
            heading.frame = NSRect(x: 20, y: h - 50, width: w - 40, height: 18)
            root.addSubview(heading)

            let seg = NSSegmentedControl(labels: ["Off", "Calm", "Full"], trackingMode: .selectOne, target: self, action: #selector(segChanged(_:)))
            seg.segmentStyle = .rounded
            seg.frame = NSRect(x: 20, y: h - 82, width: w - 40, height: 26)
            root.addSubview(seg)
            self.segControl = seg

            let note = NSTextField(labelWithString: "Calm keeps only zone and edge cues for sensory load.\nFelt only while a finger rests on the trackpad.")
            note.font = .systemFont(ofSize: 11, weight: .regular)
            note.textColor = NSColor(white: 1.0, alpha: 0.68)
            note.maximumNumberOfLines = 2
            note.frame = NSRect(x: 20, y: h - 118, width: w - 40, height: 30)
            root.addSubview(note)

            let chk = NSButton(checkboxWithTitle: "Direct trackpad actuator (experimental)", target: self, action: #selector(checkChanged(_:)))
            chk.font = .systemFont(ofSize: 11.5, weight: .medium)
            chk.frame = NSRect(x: 20, y: h - 144, width: w - 40, height: 20)
            root.addSubview(chk)
            self.actuatorCheck = chk

            let consoleHeading = NSTextField(labelWithString: "Two-Finger Hold Console · Speed & Level active")
            consoleHeading.font = .systemFont(ofSize: 11.5, weight: .semibold)
            consoleHeading.textColor = NSColor(white: 1.0, alpha: 0.88)
            consoleHeading.frame = NSRect(x: 20, y: h - 174, width: w - 40, height: 16)
            root.addSubview(consoleHeading)

            let colW: CGFloat = (w - 40) / 4
            for (i, z) in ConsoleZone.unlockableZones.enumerated() {
                let zc = NSButton(checkboxWithTitle: z.label, target: self, action: #selector(zoneCheckChanged(_:)))
                zc.identifier = NSUserInterfaceItemIdentifier(z.rawValue)
                zc.font = .systemFont(ofSize: 11, weight: .regular)
                zc.frame = NSRect(x: 20 + CGFloat(i) * colW, y: h - 198, width: colW, height: 20)
                root.addSubview(zc)
                zoneChecks[z] = zc
            }

            let speedLabel = NSTextField(labelWithString: "Global Speed")
            speedLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
            speedLabel.textColor = NSColor(white: 1.0, alpha: 0.88)
            speedLabel.frame = NSRect(x: 20, y: h - 226, width: w - 40, height: 16)
            root.addSubview(speedLabel)

            let sseg = NSSegmentedControl(
                labels: ["0.5×", "0.75×", "1×", "1.25×", "1.5×", "2×"],
                trackingMode: .selectOne,
                target: self,
                action: #selector(speedSegChanged(_:))
            )
            sseg.segmentStyle = .rounded
            sseg.frame = NSRect(x: 20, y: h - 254, width: w - 40, height: 24)
            root.addSubview(sseg)
            self.speedSeg = sseg

            let tLabel = NSTextField(labelWithString: "Cue Timing · +50 ms (light leads, cue follows)")
            tLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
            tLabel.textColor = NSColor(white: 1.0, alpha: 0.88)
            tLabel.frame = NSRect(x: 20, y: 44, width: w - 104, height: 16)
            root.addSubview(tLabel)
            self.timingLabel = tLabel

            let resetBtn = NSButton(title: "+50 ms", target: self, action: #selector(resetCueTiming(_:)))
            resetBtn.bezelStyle = .inline
            resetBtn.font = .systemFont(ofSize: 10.5, weight: .medium)
            resetBtn.frame = NSRect(x: w - 78, y: 43, width: 58, height: 18)
            root.addSubview(resetBtn)

            let minLbl = NSTextField(labelWithString: "−100 ms")
            minLbl.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            minLbl.textColor = NSColor(white: 1.0, alpha: 0.55)
            minLbl.frame = NSRect(x: 20, y: 16, width: 48, height: 14)
            root.addSubview(minLbl)

            let slider = NSSlider(value: 50, minValue: -100, maxValue: 260, target: self, action: #selector(timingSliderChanged(_:)))
            slider.isContinuous = true
            slider.frame = NSRect(x: 72, y: 14, width: w - 144, height: 20)
            root.addSubview(slider)
            self.timingSlider = slider

            let maxLbl = NSTextField(labelWithString: "+260 ms")
            maxLbl.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            maxLbl.textColor = NSColor(white: 1.0, alpha: 0.55)
            maxLbl.alignment = .right
            maxLbl.frame = NSRect(x: w - 68, y: 16, width: 48, height: 14)
            root.addSubview(maxLbl)

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

// MARK: - B3: The console without home bars (spec B9c) & one global speed (spec B9d)

enum ConsoleZone: String, CaseIterable {
    case space = "space"   // slot -2 (↓↓ 2 ticks)
    case key   = "key"     // slot -1 (↓  1 tick)
    case speed = "speed"   // slot  0 (●  hold origin)
    case level = "level"   // slot +1 (↑  1 tick)
    case tone  = "tone"    // slot +2 (↑↑ 2 ticks)
    case voice = "voice"   // slot +3 (↑↑↑ 3 ticks)

    static let unlockableZones: [ConsoleZone] = [.tone, .key, .space, .voice]

    var slotOffset: Int {
        switch self {
        case .space: return -2
        case .key:   return -1
        case .speed: return 0
        case .level: return 1
        case .tone:  return 2
        case .voice: return 3
        }
    }

    var label: String {
        switch self {
        case .speed: return "Speed"
        case .level: return "Level"
        case .tone:  return "Tone"
        case .key:   return "Key"
        case .space: return "Space"
        case .voice: return "Voice"
        }
    }

    var detents: [Double] {
        switch self {
        case .speed: return [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
        case .level: return [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
        case .tone:  return [-2, -1, 0, 1, 2]
        case .key:   return [-6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6]
        case .space: return [0, 1, 2, 3, 4]
        case .voice: return [-2, -1, 0, 1, 2]
        }
    }

    var homeValue: Double {
        switch self {
        case .speed: return 1.0
        case .level: return 100.0
        case .tone, .key, .space, .voice: return 0.0
        }
    }

    func isHome(_ value: Double) -> Bool {
        abs(value - homeValue) < 1e-4
    }
}

final class RestHoldConsole {
    static let shared = RestHoldConsole()

    static let unlockedZonesKey = "recense.console.unlockedZones"
    static let globalSpeedKey = "recense.globalSpeed"
    static let valuesPrefix = "recense.console.value."
    static let speedChangedNotification = Notification.Name("recense.globalSpeed.changed")

    /// Vertical trackpad fraction per zone step (measured from where the two fingers landed).
    static let zoneStepHeight: Float = 0.08
    /// Horizontal trackpad fraction per value detent step.
    static let detentStepWidth: Float = 0.06

    private(set) var isHolding = false
    private(set) var activeZone: ConsoleZone = .speed
    private var horizontalAnchor: Float = 0
    private var baseDetentIndex: Int = 2

    var onZoneChanged: ((ConsoleZone, Double) -> Void)?
    var onValueChanged: ((ConsoleZone, Double) -> Void)?

    private init() {}

    // MARK: Progressive disclosure (2 zones at first: speed & level; tone, key, space, voice unlock in Settings)

    var unlockedZones: Set<ConsoleZone> {
        get {
            var set: Set<ConsoleZone> = [.speed, .level]
            if let saved = UserDefaults.standard.stringArray(forKey: Self.unlockedZonesKey) {
                for r in saved {
                    if let z = ConsoleZone(rawValue: r) { set.insert(z) }
                }
            }
            return set
        }
        set {
            let extra = newValue.intersection(Set(ConsoleZone.unlockableZones)).map(\.rawValue).sorted()
            UserDefaults.standard.set(extra, forKey: Self.unlockedZonesKey)
        }
    }

    func isZoneUnlocked(_ zone: ConsoleZone) -> Bool {
        zone == .speed || zone == .level || unlockedZones.contains(zone)
    }

    func setZone(_ zone: ConsoleZone, unlocked: Bool) {
        var cur = unlockedZones
        if unlocked { cur.insert(zone) } else if zone != .speed && zone != .level { cur.remove(zone) }
        unlockedZones = cur
    }

    func unlockAllZones(_ unlock: Bool) {
        unlockedZones = unlock ? Set(ConsoleZone.allCases) : [.speed, .level]
    }

    /// Ordered unlocked zones by vertical slot offset (`-2 ... +3`).
    var orderedActiveZones: [ConsoleZone] {
        ConsoleZone.allCases.filter { isZoneUnlocked($0) }.sorted { $0.slotOffset < $1.slotOffset }
    }

    // MARK: One global speed (B9d) & zone values

    var globalSpeed: Double {
        get {
            let v = UserDefaults.standard.object(forKey: Self.globalSpeedKey) as? Double ?? 1.0
            return nearestDetent(v, for: .speed)
        }
        set {
            setValue(newValue, for: .speed, fireHaptics: false)
        }
    }

    func value(for zone: ConsoleZone) -> Double {
        if zone == .speed { return globalSpeed }
        let key = Self.valuesPrefix + zone.rawValue
        guard let v = UserDefaults.standard.object(forKey: key) as? Double else { return zone.homeValue }
        return nearestDetent(v, for: zone)
    }

    func nearestDetent(_ raw: Double, for zone: ConsoleZone) -> Double {
        zone.detents.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? zone.homeValue
    }

    func detentIndex(for zone: ConsoleZone) -> Int {
        let cur = value(for: zone)
        return zone.detents.enumerated().min(by: { abs($0.element - cur) < abs($1.element - cur) })?.offset ?? 0
    }

    @discardableResult
    func setValue(_ raw: Double, for zone: ConsoleZone, fireHaptics: Bool = true) -> Double {
        let snapped = nearestDetent(raw, for: zone)
        let prev = value(for: zone)
        if zone == .speed {
            UserDefaults.standard.set(snapped, forKey: Self.globalSpeedKey)
            NotificationCenter.default.post(name: Self.speedChangedNotification, object: nil, userInfo: ["speed": snapped])
        } else {
            UserDefaults.standard.set(snapped, forKey: Self.valuesPrefix + zone.rawValue)
        }
        if fireHaptics && abs(snapped - prev) > 1e-5 {
            Haptics.perform(zone.isHome(snapped) ? .thud : .tick)
        }
        if abs(snapped - prev) > 1e-5 {
            onValueChanged?(zone, snapped)
            HapticsMenuTarget.shared.syncPanel()
        }
        return snapped
    }

    /// B9d: Where a player can't change speed (Music.app), report plainly instead of failing silently.
    static func speedCapabilityNotice(forBundleIdentifier bundleID: String?) -> String? {
        guard let id = bundleID?.lowercased() else { return nil }
        if id == "com.apple.music" {
            return "Music.app does not support playback speed changes; global speed saved for Recense, QuickTime, and web players."
        }
        return nil
    }

    // MARK: Two-finger rest-hold lifecycle (Hold → vertical zone → horizontal detent → Lift keeps value)

    func beginHold() {
        isHolding = true
        activeZone = .speed
        horizontalAnchor = 0
        baseDetentIndex = detentIndex(for: .speed)
        Haptics.perform(.open)
    }

    /// Updates the console from two-finger centroid displacement `(dx, dy)` relative to where the fingers landed.
    func update(dx: Float, dy: Float) {
        guard isHolding else { return }
        let desiredSlot = Int((dy / Self.zoneStepHeight).rounded())
        let available = orderedActiveZones
        let targetZone = available
            .filter { desiredSlot >= 0 ? $0.slotOffset <= desiredSlot : $0.slotOffset >= desiredSlot }
            .min(by: { abs($0.slotOffset - desiredSlot) < abs($1.slotOffset - desiredSlot) })
            ?? .speed

        if targetZone != activeZone {
            let steps = max(1, abs(targetZone.slotOffset - activeZone.slotOffset))
            activeZone = targetZone
            horizontalAnchor = dx
            baseDetentIndex = detentIndex(for: targetZone)
            for _ in 0..<steps {
                Haptics.performZoneBoundary()
            }
            onZoneChanged?(targetZone, value(for: targetZone))
            return
        }

        let detents = activeZone.detents
        let stepDelta = Int(((dx - horizontalAnchor) / Self.detentStepWidth).rounded())
        let targetIdx = max(0, min(detents.count - 1, baseDetentIndex + stepDelta))
        let targetVal = detents[targetIdx]
        if abs(targetVal - value(for: activeZone)) > 1e-5 {
            _ = setValue(targetVal, for: activeZone, fireHaptics: true)
        }
    }

    /// Two-finger double-tap resets the active control to its home value with a `thud`.
    func resetActiveZoneToHome() {
        _ = setValue(activeZone.homeValue, for: activeZone, fireHaptics: true)
    }

    func endHold() {
        isHolding = false
    }
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

    // 5. B3: Rest-hold console (2 zones at first, progressive unlock in Settings, boundary ticks, sideways detents + home thud, global speed B9d).
    let savedZones = RestHoldConsole.shared.unlockedZones
    let savedSpeed = RestHoldConsole.shared.globalSpeed
    defer {
        RestHoldConsole.shared.unlockedZones = savedZones
        RestHoldConsole.shared.globalSpeed = savedSpeed
        RestHoldConsole.shared.endHold()
    }
    RestHoldConsole.shared.unlockAllZones(false)
    _ = RestHoldConsole.shared.setValue(1.0, for: .speed, fireHaptics: false)
    let defaultTwoZonesOK = RestHoldConsole.shared.orderedActiveZones == [.speed, .level]

    fired.removeAll()
    RestHoldConsole.shared.beginHold()
    // Move +2 slots up while only speed & level are unlocked -> clamps to .level (1 boundary tick).
    RestHoldConsole.shared.update(dx: 0, dy: RestHoldConsole.zoneStepHeight * 2)
    let clampLockedOK = RestHoldConsole.shared.activeZone == .level && fired.map(\.0) == [.open, .tick]

    // Unlock tone, key, space, voice in Settings and verify 2-tick jump to .tone and sideways speed detents + home thud.
    RestHoldConsole.shared.unlockAllZones(true)
    fired.removeAll()
    RestHoldConsole.shared.beginHold()
    RestHoldConsole.shared.update(dx: 0, dy: RestHoldConsole.zoneStepHeight * 2) // 0 -> +2 (.tone): 2 ticks
    let toneTicksOK = RestHoldConsole.shared.activeZone == .tone && fired.map(\.0) == [.open, .tick, .tick]

    // Return to .speed (slot 0), step left to 0.75x (.tick), step right back to home 1.0x (.thud), step right to 1.25x (.tick), and lift.
    RestHoldConsole.shared.update(dx: 0, dy: 0)
    fired.removeAll()
    RestHoldConsole.shared.update(dx: -RestHoldConsole.detentStepWidth, dy: 0) // 0.75x -> .tick
    let at075 = abs(RestHoldConsole.shared.globalSpeed - 0.75) < 1e-4
    RestHoldConsole.shared.update(dx: 0, dy: 0)                                // 1.0x (home) -> .thud
    let at100 = abs(RestHoldConsole.shared.globalSpeed - 1.0) < 1e-4
    RestHoldConsole.shared.update(dx: RestHoldConsole.detentStepWidth, dy: 0)  // 1.25x -> .tick
    RestHoldConsole.shared.endHold()
    let at125Persisted = abs(RestHoldConsole.shared.globalSpeed - 1.25) < 1e-4
    let detentCuesOK = fired.map(\.0) == [.tick, .thud, .tick]
    let musicNoticeOK = RestHoldConsole.speedCapabilityNotice(forBundleIdentifier: "com.apple.Music") != nil
    let b3OK = defaultTwoZonesOK && clampLockedOK && toneTicksOK && at075 && at100 && at125Persisted && detentCuesOK && musicNoticeOK
    print("\(b3OK ? "ok  " : "FAIL") haptics, B3 rest-hold console zones, progressive unlock, home thud, and global speed persist")

    // 6. B4: Visual-delay remap (Settings › Cue timing, -100…+260 ms, default +50 ms where light leads and cue follows).
    let hadTimingObj = UserDefaults.standard.object(forKey: Haptics.cueTimingOffsetMsKey)
    defer {
        if let old = hadTimingObj {
            UserDefaults.standard.set(old, forKey: Haptics.cueTimingOffsetMsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Haptics.cueTimingOffsetMsKey)
        }
    }
    UserDefaults.standard.removeObject(forKey: Haptics.cueTimingOffsetMsKey)
    let default50OK = Haptics.cueTimingOffsetMs == 50
        && abs(Haptics.effectiveCueTimestamp(forLightTimestamp: 2.0) - 2.050) < 1e-6

    Haptics.cueTimingOffsetMs = -250
    let clampLowOK = Haptics.cueTimingOffsetMs == -100
        && abs(Haptics.effectiveCueTimestamp(forLightTimestamp: 2.0) - 1.900) < 1e-6

    Haptics.cueTimingOffsetMs = 400
    let clampHighOK = Haptics.cueTimingOffsetMs == 260
        && abs(Haptics.effectiveCueTimestamp(forLightTimestamp: 2.0) - 2.260) < 1e-6

    Haptics.cueTimingOffsetMs = 120
    _ = Haptics.perform(.tick)
    let readByCueOK = Haptics.lastReadCueTimingOffsetMs == 120
    let b4OK = default50OK && clampLowOK && clampHighOK && readByCueOK
    print("\(b4OK ? "ok  " : "FAIL") haptics, B4 cue timing defaults to +50 ms, clamps to -100…+260 ms, persists, and every cue reads it")

    return vocabOK && modesOK && spikeOK && b2OK && b3OK && b4OK
}
