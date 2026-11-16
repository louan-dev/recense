// Derived from Spec: FEAT-15
// The Mac's half of Bose Bridge: Core Audio and a menu, nothing else. Every rule lives in shared/bosebridge.swift,
// which the iPhone and iPad compile too (FEAT-15 P1–P4); this file only tells it what ports exist and does what it
// decides. It replaces the owner's standalone "Bose Bridge.app" (BoseBridgeApp.swift + Engine.swift, 2026-11-13):
// one app, one process (.claude/CLAUDE.md, "One app"), so its headphones icon becomes a submenu here and its
// toggles become Recense settings. Idle cost near zero (SL1): one HAL listener, no polling, and the battery is
// read every 5 minutes only while the Bose is actually on Bluetooth.
import AppKit
import AVFoundation
import CoreAudio
import Foundation
import UniformTypeIdentifiers

// MARK: - Core Audio, read and write

private let halSystem = AudioObjectID(kAudioObjectSystemObject)

private func halAddress(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func halDeviceIDs() -> [AudioObjectID] {
    var addr = halAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(halSystem, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(halSystem, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

private func halName(_ id: AudioObjectID) -> String {
    var addr = halAddress(kAudioObjectPropertyName)
    var ref: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr,
          let name = ref?.takeRetainedValue() else { return "" }
    return name as String
}

private func halTransport(_ id: AudioObjectID) -> UInt32 {
    var addr = halAddress(kAudioDevicePropertyTransportType)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
    return value
}

private func halHasStreams(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
    var addr = halAddress(kAudioDevicePropertyStreams, scope)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
}

private func halDefault(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
    var addr = halAddress(selector)
    var id = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(halSystem, &addr, 0, nil, &size, &id)
    return id
}

private func halSetDefault(_ selector: AudioObjectPropertySelector, _ id: AudioObjectID) {
    var addr = halAddress(selector)
    var device = id
    AudioObjectSetPropertyData(halSystem, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device)
}

private func halSetMute(_ id: AudioObjectID, _ muted: Bool) {
    var addr = halAddress(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
    var value: UInt32 = muted ? 1 : 0
    AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
}

/// Every audio port this Mac has, as `shared/bosebridge.swift` wants to see it.
private func halPorts() -> [Port] {
    halDeviceIDs().map { id in
        let t = halTransport(id)
        let wire: Wire
        switch t {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: wire = .bluetooth
        case kAudioDeviceTransportTypeUSB: wire = .usb
        case kAudioDeviceTransportTypeBuiltIn: wire = .builtIn
        default: wire = .other
        }
        return Port(id: id, name: halName(id), wire: wire,
                    output: halHasStreams(id, kAudioObjectPropertyScopeOutput),
                    input: halHasStreams(id, kAudioObjectPropertyScopeInput))
    }
}

private func halTransportLabel(_ wire: Wire) -> String {
    switch wire {
    case .builtIn: return "built-in"
    case .usb: return "USB"
    case .bluetooth: return "Bluetooth"
    case .jack: return "jack"
    case .other: return "other"
    }
}

/// The Bose battery, only when macOS reports it (it does over Bluetooth, through system_profiler). nil = unknown;
/// the menu then says so instead of guessing.
private func boseBattery(names: [String]) -> Int? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    p.arguments = ["-json", "SPBluetoothDataType"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return findBoseBattery(json, names: names, inside: false)
}

/// Walks system_profiler's JSON for a "…battery…" value like "60%" under a connected Bose.
private func findBoseBattery(_ node: Any, names: [String], inside: Bool) -> Int? {
    if let dict = node as? [String: Any] {
        for (key, value) in dict {
            let k = key.lowercased()
            if k.contains("not_connected") { continue }
            let bose = inside || names.contains { !$0.isEmpty && k.contains($0) }
            if bose, k.contains("battery"), let text = value as? String,
               let level = Int(text.filter(\.isNumber)) { return level }
            if let level = findBoseBattery(value, names: names, inside: bose) { return level }
        }
    } else if let array = node as? [Any] {
        for item in array {
            if let level = findBoseBattery(item, names: names, inside: inside) { return level }
        }
    }
    return nil
}

// MARK: - The bridge

@MainActor
final class BoseBridge: NSObject {
    private enum Key {
        static let on = "bose.on", phones = "bose.phones", mute = "bose.muteSpeakers"
        static let mic = "bose.pinMic", warn = "bose.batteryWarn", names = "bose.names", tell = "bose.tell"
    }
    private let defaults = UserDefaults.standard

    /// Built where the rest of the app is built (App's `lazy var bose`), which is not yet on the main actor.
    nonisolated override init() { super.init() }

    private(set) var nowPlaying = "—"
    private(set) var lastEvent = ""
    private(set) var battery: Int?
    let symphonies = Symphonies()

    private var listener: AudioObjectPropertyListenerBlock?
    private var pending: DispatchWorkItem?
    private var batteryTimer: DispatchSourceTimer?
    private var known = Set<AudioObjectID>()
    private var was: Route?
    private var settled = false
    private var muted: [AudioObjectID] = []
    private var warned = false

    var on: Bool {
        get { defaults.object(forKey: Key.on) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.on); newValue ? start() : stop() }
    }
    var tell: Bool {
        get { defaults.object(forKey: Key.tell) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.tell) }
    }
    var settings: BridgeSettings {
        var s = BridgeSettings()
        if let raw = defaults.string(forKey: Key.phones), let p = Phones(rawValue: raw) { s.phones = p }
        s.muteSpeakers = defaults.object(forKey: Key.mute) as? Bool ?? true
        s.pinMic = defaults.object(forKey: Key.mic) as? Bool ?? true
        s.batteryWarn = defaults.object(forKey: Key.warn) as? Int ?? 20
        if let names = defaults.string(forKey: Key.names) {
            let list = names.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !list.isEmpty { s.names = list }
        }
        return s
    }

    /// Seats live in the Listen home, so FEAT-09's carry moves them between devices with no new transport.
    private var seatFolder: URL? {
        let url = Homes.url(.listen)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func start() {
        symphonies.seatFolder = seatFolder
        guard on, listener == nil else { if !on { nowPlaying = "Bridge off" }; return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        var addr = halAddress(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(halSystem, &addr, DispatchQueue.main, block)
        listener = block

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 300)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.checkBattery() } }
        timer.resume()
        batteryTimer = timer

        settled = false
        was = nil
        apply()
    }

    func stop() {
        if let listener {
            var addr = halAddress(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(halSystem, &addr, DispatchQueue.main, listener)
        }
        listener = nil
        pending?.cancel()
        batteryTimer?.cancel()
        batteryTimer = nil
        unmute()
        was = nil
        nowPlaying = "Bridge off"
    }

    /// A Bluetooth device appears in stages, so wait 0.8 s for the list to settle before deciding anything.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.apply() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func apply() {
        let ports = halPorts()
        let arrived = settled ? Set(ports.map(\.id)).subtracting(known) : []
        known = Set(ports.map(\.id))
        let current = halDefault(kAudioHardwarePropertyDefaultOutputDevice)
        let d = BridgeDecision.decide(ports: ports, arrived: arrived, current: current, was: was, settings: settings)

        if let output = d.output {
            if output != current {
                halSetDefault(kAudioHardwarePropertyDefaultOutputDevice, output)
                halSetDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, output)
            }
            unmute()
            if let mic = d.pinMicTo, halDefault(kAudioHardwarePropertyDefaultInputDevice) != mic,
               let input = ports.first(where: { $0.id == halDefault(kAudioHardwarePropertyDefaultInputDevice) }),
               input.wire == .bluetooth {
                halSetDefault(kAudioHardwarePropertyDefaultInputDevice, mic)
            }
            let name = ports.first { $0.id == output }?.name ?? "—"
            nowPlaying = "\(name) · \(d.route?.label ?? "")"
        } else {
            for id in d.mute where !muted.contains(id) {
                halSetMute(id, true)
                muted.append(id)
            }
            let name = ports.first { $0.id == current }?.name ?? "—"
            nowPlaying = muted.isEmpty ? name : "\(name) (muted)"
        }

        if settled, d.route != was {
            lastEvent = d.say
            if tell { notify(d.say) }
        }
        was = d.route
        settled = true
    }

    private func unmute() {
        muted.forEach { halSetMute($0, false) }
        muted.removeAll()
    }

    private func checkBattery() {
        let s = settings
        guard was == .phonesBluetooth else { battery = nil; return }
        let names = s.names
        DispatchQueue.global(qos: .utility).async {
            let level = boseBattery(names: names)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.battery = level
                    guard s.batteryWarn > 0, let level else { return }
                    if level <= s.batteryWarn, !self.warned {
                        self.warned = true
                        self.lastEvent = "Bose battery at \(level)%. \(s.phones.chargeHint)"
                        if self.tell { self.notify(self.lastEvent) }
                    } else if level > s.batteryWarn + 10 {
                        self.warned = false
                    }
                }
            }
        }
    }

    private func notify(_ message: String) {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(escaped)\" with title \"Recense · Bose Bridge\""]
        try? p.run()
    }

    // MARK: - The menu (rebuilt every time it opens, like the hider's)

    func menu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        add(m, "Now: \(nowPlaying)")
        if !lastEvent.isEmpty { add(m, lastEvent.count > 80 ? String(lastEvent.prefix(79)) + "…" : lastEvent) }
        if let battery { add(m, "Battery: \(battery)%") } else if was == .phonesBluetooth {
            add(m, "Battery: not reported yet")
        }
        m.addItem(.separator())

        toggle(m, "Bose Bridge On", on, #selector(flipOn))
        let phones = NSMenuItem(title: "Headphones", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for p in Phones.allCases {
            let i = NSMenuItem(title: p.title, action: #selector(pickPhones(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = p.rawValue
            i.state = settings.phones == p ? .on : .off
            sub.addItem(i)
        }
        phones.submenu = sub
        m.addItem(phones)
        add(m, settings.phones.chargeHint.count > 90
            ? String(settings.phones.chargeHint.prefix(89)) + "…" : settings.phones.chargeHint)

        toggle(m, "Mute Speakers If Headphones Drop", settings.muteSpeakers, #selector(flipMute))
        toggle(m, "Keep the Bose in Full-Quality Stereo", settings.pinMic, #selector(flipMic))
        toggle(m, "Tell Me When the Route Changes", tell, #selector(flipTell))

        let warn = NSMenuItem(title: "Low-Battery Warning", action: nil, keyEquivalent: "")
        let warnMenu = NSMenu()
        for level in [0, 10, 20, 30] {
            let i = NSMenuItem(title: level == 0 ? "Off" : "\(level)%", action: #selector(pickWarn(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = level
            i.state = settings.batteryWarn == level ? .on : .off
            warnMenu.addItem(i)
        }
        warn.submenu = warnMenu
        m.addItem(warn)

        let devices = NSMenuItem(title: "Audio Devices", action: nil, keyEquivalent: "")
        let list = NSMenu()
        let names = settings.names
        for p in halPorts() where p.output || p.input {
            let io = [p.output ? "out" : nil, p.input ? "in" : nil].compactMap { $0 }.joined(separator: "+")
            let role = p.route(names: names).map { " → \($0.label)" } ?? ""
            list.addItem(NSMenuItem(title: "\(p.name) · \(halTransportLabel(p.wire)) \(io)\(role)",
                                    action: nil, keyEquivalent: ""))
        }
        devices.submenu = list
        m.addItem(devices)

        m.addItem(.separator())
        m.addItem(twoAtOnce())
        m.addItem(seatsMenu())
        return m
    }

    /// FEAT-15 P4: two symphonies at once. The headphones take one signal, so the mixing happens here.
    private func twoAtOnce() -> NSMenuItem {
        let item = NSMenuItem(title: "Two At Once", action: nil, keyEquivalent: "")
        let m = NSMenu()
        m.autoenablesItems = false
        let add = NSMenuItem(title: "Add a Piece…", action: #selector(addPiece), keyEquivalent: "")
        add.target = self
        m.addItem(add)
        if symphonies.voices.isEmpty {
            self.add(m, "Nothing playing yet. Add two pieces and they play together, one in each ear.")
        } else {
            m.addItem(.separator())
            for v in symphonies.voices {
                let row = NSMenuItem(title: "\(v.title) · \(clock(v.position)) / \(clock(v.duration))",
                                     action: nil, keyEquivalent: "")
                let sub = NSMenu()
                sub.autoenablesItems = false
                for (title, place) in [("Left Ear", Float(-1)), ("Both Ears", 0), ("Right Ear", 1)] {
                    let i = NSMenuItem(title: title, action: #selector(place(_:)), keyEquivalent: "")
                    i.target = self
                    i.representedObject = [v.id, place] as [Any]
                    i.state = abs(v.place - place) < 0.01 ? .on : .off
                    sub.addItem(i)
                }
                sub.addItem(.separator())
                for (title, gain) in [("Louder", min(1, v.gain + 0.2)), ("Quieter", max(0, v.gain - 0.2))] {
                    let i = NSMenuItem(title: "\(title) (\(Int(v.gain * 100))%)", action: #selector(gain(_:)), keyEquivalent: "")
                    i.target = self
                    i.representedObject = [v.id, gain] as [Any]
                    sub.addItem(i)
                }
                sub.addItem(.separator())
                let pp = NSMenuItem(title: v.playing ? "Pause This One" : "Play This One",
                                    action: #selector(playPauseOne(_:)), keyEquivalent: "")
                pp.target = self; pp.representedObject = v.id
                sub.addItem(pp)
                let seat = NSMenuItem(title: "Resume Where I Left Off", action: #selector(resumeSeat(_:)), keyEquivalent: "")
                seat.target = self; seat.representedObject = v.id
                sub.addItem(seat)
                let drop = NSMenuItem(title: "Remove", action: #selector(dropVoice(_:)), keyEquivalent: "")
                drop.target = self; drop.representedObject = v.id
                sub.addItem(drop)
                row.submenu = sub
                m.addItem(row)
            }
            m.addItem(.separator())
            let all = NSMenuItem(title: symphonies.playing ? "Pause All" : "Play All",
                                 action: #selector(playPauseAll), keyEquivalent: "")
            all.target = self
            m.addItem(all)
        }
        item.submenu = m
        return item
    }

    /// FEAT-15 P3: every passage any device left behind, newest first.
    private func seatsMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Where I Left Off", action: nil, keyEquivalent: "")
        let m = NSMenu()
        m.autoenablesItems = false
        let seats = seatFolder.map { Seats.all(in: $0) } ?? []
        if seats.isEmpty {
            add(m, "No seats yet. Pause a piece on any device and it appears here.")
        } else {
            for s in seats.prefix(12) {
                let i = NSMenuItem(title: "\(s.title) · \(clock(s.position)) · \(s.device)",
                                   action: nil, keyEquivalent: "")
                i.isEnabled = false
                m.addItem(i)
            }
            add(m, "Add that piece under Two At Once and choose “Resume Where I Left Off”.")
        }
        item.submenu = m
        return item
    }

    private func add(_ m: NSMenu, _ text: String) {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        m.addItem(i)
    }

    private func toggle(_ m: NSMenu, _ title: String, _ state: Bool, _ action: Selector) {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.state = state ? .on : .off
        m.addItem(i)
    }

    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: menu actions

    @objc private func flipOn() { on = !on }
    @objc private func flipTell() { tell = !tell }
    @objc private func flipMute() {
        defaults.set(!settings.muteSpeakers, forKey: Key.mute)
        if !settings.muteSpeakers { unmute() }
        apply()
    }
    @objc private func flipMic() { defaults.set(!settings.pinMic, forKey: Key.mic) }
    @objc private func pickPhones(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        defaults.set(raw, forKey: Key.phones)
        apply()
    }
    @objc private func pickWarn(_ sender: NSMenuItem) {
        guard let level = sender.representedObject as? Int else { return }
        defaults.set(level, forKey: Key.warn)
        warned = false
    }

    @objc private func addPiece() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        panel.directoryURL = Homes.url(.music)
        panel.prompt = "Play"
        guard panel.runModal() == .OK else { return }
        symphonies.seatFolder = seatFolder
        for url in panel.urls {
            do { _ = try symphonies.add(url) } catch { lastEvent = "Can't play \(url.lastPathComponent): \(error.localizedDescription)" }
        }
        symphonies.play()
    }

    @objc private func place(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any], let id = pair.first as? Int,
              let place = pair.last as? Float else { return }
        symphonies.set(place: place, for: id)
    }
    @objc private func gain(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any], let id = pair.first as? Int,
              let gain = pair.last as? Float else { return }
        symphonies.set(gain: gain, for: id)
    }
    @objc private func playPauseOne(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int,
              let v = symphonies.voices.first(where: { $0.id == id }) else { return }
        v.playing ? symphonies.pause(id) : symphonies.play(id)
    }
    @objc private func resumeSeat(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int else { return }
        symphonies.resumeFromSeat(id)
    }
    @objc private func dropVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int else { return }
        symphonies.remove(id)
    }
    @objc private func playPauseAll() {
        symphonies.tick()
        symphonies.playing ? symphonies.pause() : symphonies.play()
    }
}

// MARK: - `recense symphonies <file> <file> …`

/// Derived from Spec: FEAT-15 (the command named in the owner's directions). Plays every file given at the same
/// time through whatever the Mac's output is now — the first in the left ear, the second in the right — and keeps
/// a seat for each. Local files only, no network.
@MainActor
func runSymphoniesCLI(_ paths: [String]) -> Never {
    guard !paths.isEmpty else {
        fputs("usage: recense symphonies <audio file> [more files…]\n", stderr)
        exit(1)
    }
    let s = Symphonies()
    let listen = Homes.url(.listen)
    try? FileManager.default.createDirectory(at: listen, withIntermediateDirectories: true)
    s.seatFolder = listen
    for (i, path) in paths.enumerated() {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            _ = try s.add(url, place: paths.count == 1 ? 0 : (i % 2 == 0 ? -1 : 1))
        } catch {
            fputs("symphonies: can't play \(url.lastPathComponent): \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    s.play()
    for v in s.voices {
        print("\(v.title) · \(String(format: "%.0f", v.duration))s · \(v.place < 0 ? "left ear" : v.place > 0 ? "right ear" : "both ears")")
    }
    print("Playing \(s.voices.count) at once. Ctrl-C stops; each one keeps its seat.")
    let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
        MainActor.assumeIsolated {
            s.tick()
            if !s.playing {
                s.stopAll()
                exit(0)
            }
        }
    }
    RunLoop.main.add(timer, forMode: .default)
    RunLoop.main.run()
    exit(0)
}
