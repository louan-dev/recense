// Derived from Spec: FEAT-15
// Bose Bridge: one pair of QuietComfort SC, many sources. The headphones have one Bluetooth link and one analog
// pair, and that is firmware we cannot write — so everything the owner wanted from a 2nd-gen QC Ultra is done on
// this side of those two doors, where we own the code:
//   • the pair and what it really allows (Phones.traits), each trait's source marked checked or assumption;
//   • the route decision (BridgeDecision.decide): pure, no CoreAudio, no AVAudioSession, so the Mac and the
//     iPhone/iPad glue share one brain and the ten invariants in FEAT-15 are testable without hardware;
//   • seats (Seats): the place in a piece, append-only in a Home, carried offline by FEAT-09 — resume a passage
//     on any device, which no QC Ultra does;
//   • two symphonies at once (Symphonies): N voices, each its own file, clock, gain and ear, mixed into the one
//     stream the headphones can receive. Also something no QC Ultra does.
// No network at any point. No Bose app, no Bose account, no Worker, no R2.
import AVFoundation
import CryptoKit
import Foundation

// MARK: - P1 · The pair and what it allows

/// What a pair of headphones can actually do. Sources are in `Phones.traits`; nothing here is guessed silently.
struct PhoneTraits: Equatable, Sendable {
    /// The analog cable plays with the headphones switched off or empty (passive).
    var wiredWhileOff: Bool
    /// The analog cable plays while the USB-C cable charges.
    var wiredWhileCharging: Bool
    /// Bluetooth keeps working while charging.
    var btWhileCharging: Bool
    /// The USB-C port carries audio, not just power.
    var usbAudio: Bool
    /// How many source devices the firmware holds at once (multipoint).
    var maxLinks: Int
}

enum Phones: String, Codable, CaseIterable, Identifiable, Sendable {
    case qcsc, qc45, ultra1, ultra2, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .qcsc: return "QuietComfort SC"
        case .qc45: return "QuietComfort 45"
        case .ultra1: return "QC Ultra (1st Gen)"
        case .ultra2: return "QC Ultra (2nd Gen)"
        case .other: return "Other headphones"
        }
    }

    /// Evidence, 2026-11-15 (FEAT-15 "What the hardware allows"):
    ///   checked    · QC SC multipoint holds two devices (Bose product page); so does the QC Ultra 2nd Gen
    ///               (Bose press release, Bluetooth 5.4) — three links is not a feature the SC is missing.
    ///   checked    · the QC45-generation analog cable plays powered on or off, with no ANC (Bose owner's guide);
    ///               Bluetooth is disabled while charging (Bose support); "the headphones don't play … while
    ///               charging" (Bose QC SC support).
    ///   checked    · the QC Ultra 2nd Gen adds USB-C audio, 16-bit 44.1/48 kHz (Bose press release).
    ///   assumption · analog audio while the USB-C cable charges (passive wire to the drivers; Bose documents the
    ///               powered case only) — FEAT-15 test A settles it.
    ///   assumption · the QC SC's USB-C is charge-only; no Bose document claims audio on it.
    var traits: PhoneTraits {
        switch self {
        case .qcsc, .qc45:
            return PhoneTraits(wiredWhileOff: true, wiredWhileCharging: true, btWhileCharging: false,
                               usbAudio: false, maxLinks: 2)
        case .ultra1:
            return PhoneTraits(wiredWhileOff: false, wiredWhileCharging: true, btWhileCharging: false,
                               usbAudio: false, maxLinks: 2)
        case .ultra2:
            return PhoneTraits(wiredWhileOff: false, wiredWhileCharging: true, btWhileCharging: true,
                               usbAudio: true, maxLinks: 2)
        case .other:
            return PhoneTraits(wiredWhileOff: false, wiredWhileCharging: false, btWhileCharging: false,
                               usbAudio: false, maxLinks: 1)
        }
    }

    /// What to plug in, in the owner's own terms, for this exact pair.
    var chargeHint: String {
        switch self {
        case .qcsc:
            return "Plug the 3.5 mm → 2.5 mm cable into the Mac's headphone jack. It plays with the headphones switched off, even at 0%."
        case .qc45:
            return "Plug the Bose audio cable into the Mac's headphone jack. It plays with the headphones switched off."
        case .ultra1:
            return "Plug the Bose audio cable into the Mac's headphone jack and keep the headphones powered on: they are silent on the cable when off."
        case .ultra2:
            return "Plug its USB-C cable into the Mac: sound and charge on the one cable. The audio cable also works."
        case .other:
            return "Plug in an audio cable, or wait for the Bluetooth link to come back."
        }
    }
}

// MARK: - P1 · Ports and routes

/// How a port is attached. One word per door the sound can leave by.
enum Wire: String, Codable, Sendable { case bluetooth, usb, builtIn, jack, other }

/// One audio port as the host sees it. The Mac fills this from CoreAudio, the iPhone from AVAudioSession:
/// both then hand the same struct to `decide`, so there is one route brain, not two.
struct Port: Identifiable, Equatable, Sendable {
    var id: UInt32
    var name: String
    var wire: Wire
    var output: Bool
    var input: Bool

    init(id: UInt32, name: String, wire: Wire, output: Bool = true, input: Bool = false) {
        self.id = id; self.name = name; self.wire = wire; self.output = output; self.input = input
    }

    var lower: String { name.lowercased() }
    /// The host's own loudspeakers (the thing that must never be left playing out loud).
    var isSpeakers: Bool { wire == .builtIn && output && !lower.contains("headphone") }
    var isBuiltInMic: Bool { wire == .builtIn && input }

    /// Which headphone route this port is, or nil (speakers, a display, a capture device).
    func route(names: [String]) -> Route? {
        guard output else { return nil }
        let isPhones = names.contains { !$0.isEmpty && lower.contains($0) }
        if wire == .usb && isPhones { return .phonesUSB }
        if wire == .bluetooth && isPhones { return .phonesBluetooth }
        if wire == .jack { return .jack }
        if wire == .builtIn && lower.contains("headphone") { return .jack }   // macOS: "External Headphones"
        if wire == .usb && (lower.contains("earpods") || lower.contains("lightning")) { return .earbuds }
        return nil
    }
}

/// The doors, strongest first. `<` means "better": `phonesUSB` wins every comparison.
enum Route: Int, Codable, Comparable, Sendable {
    case phonesUSB, phonesBluetooth, jack, earbuds
    static func < (a: Route, b: Route) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .phonesUSB: return "the Bose over USB-C"
        case .phonesBluetooth: return "the Bose over Bluetooth"
        case .jack: return "the headphone cable"
        case .earbuds: return "wired earbuds"
        }
    }
}

struct BridgeSettings: Equatable, Sendable {
    var phones: Phones = .qcsc
    /// Names that count as "the owner's Bose". Lower-cased, matched as substrings.
    var names: [String] = ["bose", "quietcomfort", "qc sc", "qc45"]
    var muteSpeakers = true
    /// Keep the host's own microphone as the default input, so a Bluetooth link stays in stereo instead of
    /// dropping to call quality the moment anything opens the headset mic.
    var pinMic = true
    var batteryWarn = 20
}

/// What the glue should do, decided without touching any audio framework.
struct BridgeDecision: Equatable, Sendable {
    var output: UInt32?
    var route: Route?
    var mute: [UInt32] = []
    var pinMicTo: UInt32?
    /// One sentence for the owner, always about the state as it is now. The glue decides whether to *show* it
    /// (only when `route` differs from `was`); the decision only decides what it says.
    var say: String = ""

    static func decide(ports: [Port],
                       arrived: Set<UInt32> = [],
                       current: UInt32? = nil,
                       was: Route? = nil,
                       settings: BridgeSettings = BridgeSettings()) -> BridgeDecision {
        let names = settings.names.map { $0.lowercased() }
        let paired: [(port: Port, route: Route)] = ports.compactMap { p in p.route(names: names).map { (p, $0) } }

        // 1 · something was just plugged in or connected: the owner did that for a reason, it wins.
        // 2 · nothing arrived and the current output is already a headphone port: leave the owner's choice alone.
        // 3 · otherwise the strongest port still there.
        let pick = paired.filter { arrived.contains($0.port.id) }.min { $0.route < $1.route }
            ?? paired.first { $0.port.id == current }
            ?? paired.min { $0.route < $1.route }

        guard let pick else {
            // Only a route that was *lost* mutes the speakers. With no headphones ever seen (a launch with the Bose
            // switched off), muting would silence the Mac for nothing — which it did on the owner's Mac, 11-15.
            let mute = settings.muteSpeakers && was != nil ? ports.filter(\.isSpeakers).map(\.id) : []
            let muted = mute.isEmpty ? "" : " The speakers are muted, so nothing plays out loud."
            let lost = was.map { "\($0.label.prefix(1).uppercased())\($0.label.dropFirst()) is gone." } ?? "No headphones."
            return BridgeDecision(output: nil, route: nil, mute: mute, pinMicTo: nil,
                                  say: "\(lost) \(settings.phones.chargeHint)\(muted)")
        }

        var say = "Playing through \(pick.route.label)."
        switch pick.route {
        case .phonesUSB where settings.phones.traits.usbAudio:
            say = "Playing through the Bose over USB-C: sound and charge on the one cable."
        case .jack where !settings.phones.traits.wiredWhileOff:
            say = "Playing through the headphone cable. Keep the headphones powered on: they are silent on the cable when off."
        case .jack where settings.phones.traits.wiredWhileOff:
            say = "Playing through the headphone cable. It keeps playing with the headphones off, even at 0%."
        default: break
        }

        let mic = settings.pinMic && pick.route == .phonesBluetooth ? ports.first(where: \.isBuiltInMic)?.id : nil
        return BridgeDecision(output: pick.port.id, route: pick.route, mute: [], pinMicTo: mic, say: say)
    }
}

// MARK: - P3 · Seats: the same passage on the next device

/// Where a piece was left, by whom, and when. One line per save; the newest line for a key wins, so two devices
/// writing at the same moment produce two lines instead of a conflict, and a merge can never lose a position.
struct Seat: Codable, Equatable, Identifiable, Sendable {
    var key: String
    var title: String
    /// Unix seconds when this seat was taken.
    var at: Double
    /// Seconds into the piece.
    var position: Double
    var rate: Double = 1
    var device: String = Seats.thisDevice
    /// The file or source this is a seat in, when the device knows it.
    var source: String?

    var id: String { "\(key)@\(at)" }
}

enum Seats {
    /// One append-only file inside a Home, so FEAT-09's carry already moves it between devices: no new transport,
    /// no network. `jsonl` is in `CarrySync.textExtensions`, so carry line-merges it instead of picking a winner.
    static let fileName = "seats.jsonl"
    /// Compaction is the only rewrite, and only past this many lines.
    static let compactAbove = 2000

    static var thisDevice: String { ProcessInfo.processInfo.hostName }

    /// The same shape as `Handoff.key` (strip/handoff.swift), so the offline seats and the R2 handoff can be
    /// reconciled later without a migration.
    static func key(_ title: String) -> String {
        let norm = "listen:" + title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(SHA256.hash(data: Data(norm.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24))
    }

    static func url(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    /// Append one seat. Never rewrites the file, except to compact it when it has grown past `compactAbove`.
    @discardableResult
    static func save(_ seat: Seat, in folder: URL, compactAbove limit: Int = compactAbove) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = url(in: folder)
        let line = String(decoding: try JSONEncoder().encode(seat), as: UTF8.self) + "\n"
        if let h = try? FileHandle(forWritingTo: file) {
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data(line.utf8))
        } else {
            try Data(line.utf8).write(to: file)
        }
        // Counting is the only read a save does, and only once the file is big enough to be worth counting.
        if size(in: folder) > limit * 100, lines(in: folder).count > limit { try compact(in: folder) }
        return file
    }

    static func size(in folder: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url(in: folder).path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Every line, in the order written (two devices' lines may interleave after a merge).
    static func lines(in folder: URL) -> [Seat] {
        guard let text = try? String(contentsOf: url(in: folder), encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, let d = t.data(using: .utf8) else { return nil }
            return try? dec.decode(Seat.self, from: d)
        }
    }

    /// One seat per key, the newest kept, newest first. This is what a screen shows and what resume reads.
    static func newest(_ seats: [Seat]) -> [Seat] {
        var best: [String: Seat] = [:]
        for s in seats where (best[s.key]?.at ?? -.greatestFiniteMagnitude) <= s.at { best[s.key] = s }
        return best.values.sorted { $0.at > $1.at }
    }

    static func all(in folder: URL) -> [Seat] { newest(lines(in: folder)) }

    static func seat(for title: String, in folder: URL) -> Seat? {
        let k = key(title)
        return newest(lines(in: folder)).first { $0.key == k }
    }

    /// Keep the newest line per key and nothing else. Written to a sibling first, then moved into place, so a
    /// crash mid-compaction leaves the old file intact.
    static func compact(in folder: URL) throws {
        let keep = newest(lines(in: folder)).sorted { $0.at < $1.at }
        let enc = JSONEncoder()
        let text = try keep.map { String(decoding: try enc.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        let tmp = folder.appendingPathComponent(fileName + ".new")
        try Data(text.utf8).write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url(in: folder), withItemAt: tmp)
    }
}

// MARK: - P4 · Two symphonies at once

/// Many voices, one stream. The headphones receive one signal, so two symphonies have to become one before they
/// leave the host: that is a mixer, and no pair of headphones on the market has one. Each voice keeps its own
/// file, its own clock and its own ear; seeking one never moves the other. Mac, iPhone and iPad run this file.
@MainActor
final class Symphonies: ObservableObject {
    struct Voice: Identifiable, Equatable {
        var id: Int
        var url: URL
        var title: String
        /// 0…1, before the headroom clamp below.
        var gain: Float = 1
        /// −1 left ear … 0 both … +1 right ear.
        var place: Float = 0
        var duration: Double = 0
        /// Seconds into the file, as of the last `tick()`.
        var position: Double = 0
        var playing: Bool = false
    }

    @Published private(set) var voices: [Voice] = []
    @Published private(set) var trouble: String?

    /// Where a paused or stopped voice leaves its seat. Set by the glue (the Listen home); nil = don't keep seats.
    var seatFolder: URL?

    private let engine = AVAudioEngine()
    private var nodes: [Int: AVAudioPlayerNode] = [:]
    private var files: [Int: AVAudioFile] = [:]
    /// Where each voice was told to start from, in seconds (seek and resume both go through this).
    private var offsets: [Int: Double] = [:]
    private var nextID = 1
    /// The last position a seat was written at, per voice: a stop right after an end-of-file stop must not write
    /// the same seat twice.
    private var seated: [Int: Double] = [:]

    var playing: Bool { voices.contains(where: \.playing) }

    /// Each voice's share after the headroom clamp: g'ᵢ = gᵢ / max(1, Σ gⱼ). Adding a second voice can never clip.
    /// Pure, so FEAT-15's invariant 9 is checked without audio hardware.
    nonisolated static func headroom(_ gains: [Float]) -> [Float] {
        let sum = gains.reduce(0, +)
        let d = max(1, sum)
        return gains.map { $0 / d }
    }

    /// Open a file and give it a voice. It does not start until `play()`.
    @discardableResult
    func add(_ url: URL, title: String? = nil, place: Float = 0, gain: Float = 1) throws -> Int {
        let file = try AVAudioFile(forReading: url)
        let id = nextID; nextID += 1
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        nodes[id] = node; files[id] = file; offsets[id] = 0
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        var voice = Voice(id: id, url: url, title: title ?? url.deletingPathExtension().lastPathComponent,
                          gain: gain, place: place, duration: seconds)
        // A second voice, with no ear asked for, takes the other ear: that is the owner's two-symphony split.
        if place == 0, voices.count == 1, voices[0].place == 0 {
            voices[0].place = -1
            voice.place = 1
        }
        voices.append(voice)
        applyMix()
        return id
    }

    func remove(_ id: Int) {
        keepSeat(id)
        if let node = nodes[id] {
            node.stop()
            engine.detach(node)
        }
        nodes[id] = nil; files[id] = nil; offsets[id] = nil
        voices.removeAll { $0.id == id }
        applyMix()
        if voices.isEmpty { engine.stop() }
    }

    func set(gain: Float, for id: Int) {
        guard let i = voices.firstIndex(where: { $0.id == id }) else { return }
        voices[i].gain = min(1, max(0, gain))
        applyMix()
    }

    func set(place: Float, for id: Int) {
        guard let i = voices.firstIndex(where: { $0.id == id }) else { return }
        voices[i].place = min(1, max(-1, place))
        applyMix()
    }

    /// Start every voice that is not playing, each from its own offset.
    func play() {
        guard !voices.isEmpty else { return }
        do { try startEngine() } catch { trouble = error.localizedDescription; return }
        for v in voices where !v.playing { schedule(v.id, from: offsets[v.id] ?? 0) }
        for i in voices.indices { voices[i].playing = true }
    }

    func play(_ id: Int) {
        do { try startEngine() } catch { trouble = error.localizedDescription; return }
        schedule(id, from: offsets[id] ?? 0)
        if let i = voices.firstIndex(where: { $0.id == id }) { voices[i].playing = true }
    }

    /// Pause everything, each voice keeping its place (and leaving a seat).
    func pause() {
        for v in voices { pause(v.id) }
    }

    func pause(_ id: Int) {
        guard let node = nodes[id], let i = voices.firstIndex(where: { $0.id == id }) else { return }
        offsets[id] = position(id)
        voices[i].position = offsets[id] ?? 0
        voices[i].playing = false
        node.stop()
        keepSeat(id)
        if !playing { engine.pause() }
    }

    /// Move one voice. The others do not move — FEAT-15 invariant 10.
    func seek(_ id: Int, to seconds: Double) {
        guard let i = voices.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(0, seconds), voices[i].duration)
        offsets[id] = clamped
        voices[i].position = clamped
        guard voices[i].playing, let node = nodes[id] else { return }
        node.stop()
        schedule(id, from: clamped)
    }

    /// Resume this voice where any device left it (P3).
    func resumeFromSeat(_ id: Int) {
        guard let folder = seatFolder, let i = voices.firstIndex(where: { $0.id == id }),
              let seat = Seats.seat(for: voices[i].title, in: folder) else { return }
        seek(id, to: seat.position)
    }

    /// Read every voice's clock. The glue calls this on a timer while a screen is open; nothing polls on its own.
    func tick() {
        for i in voices.indices where voices[i].playing {
            voices[i].position = position(voices[i].id)
            if voices[i].duration > 0, voices[i].position >= voices[i].duration - 0.05 {
                // A voice that reaches its end stops itself; the others keep playing.
                voices[i].playing = false
                offsets[voices[i].id] = 0
                nodes[voices[i].id]?.stop()
                keepSeat(voices[i].id)
            }
        }
        if !playing && engine.isRunning { engine.pause() }
    }

    func stopAll() {
        for v in voices { keepSeat(v.id) }
        for (_, node) in nodes { node.stop() }
        engine.stop()
        for i in voices.indices { voices[i].playing = false }
    }

    // MARK: the private half

    private func startEngine() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    private func schedule(_ id: Int, from seconds: Double) {
        guard let node = nodes[id], let file = files[id] else { return }
        let sr = file.processingFormat.sampleRate
        let start = AVAudioFramePosition(max(0, seconds) * sr)
        let count = AVAudioFrameCount(max(0, file.length - start))
        guard count > 0 else { return }
        node.scheduleSegment(file, startingFrame: start, frameCount: count, at: nil)
        node.play()
    }

    private func position(_ id: Int) -> Double {
        guard let node = nodes[id], let file = files[id] else { return offsets[id] ?? 0 }
        guard let t = node.lastRenderTime, let played = node.playerTime(forNodeTime: t) else { return offsets[id] ?? 0 }
        let sr = file.processingFormat.sampleRate
        return (offsets[id] ?? 0) + Double(played.sampleTime) / sr
    }

    private func applyMix() {
        let shares = Symphonies.headroom(voices.map(\.gain))
        for (i, v) in voices.enumerated() {
            nodes[v.id]?.volume = shares[i]
            nodes[v.id]?.pan = v.place
        }
    }

    private func keepSeat(_ id: Int) {
        guard let folder = seatFolder, let v = voices.first(where: { $0.id == id }), v.position > 1,
              abs((seated[id] ?? -1) - v.position) > 0.5 else { return }
        seated[id] = v.position
        let seat = Seat(key: Seats.key(v.title), title: v.title, at: Date().timeIntervalSince1970,
                        position: v.position, rate: 1, device: Seats.thisDevice, source: v.url.lastPathComponent)
        try? Seats.save(seat, in: folder)
    }
}

// MARK: - selftest

/// `recense selftest`: FEAT-15's ten invariants — the capability table, the route decision for every rule it has,
/// seats (newest wins, compaction) and the mixer's headroom. No audio device, no headphones, no network.
func boseBridgeSelftest() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String) { print("\(pass ? "ok  " : "FAIL") bose bridge, \(what)"); ok = ok && pass }

    let speakers = Port(id: 1, name: "MacBook Pro Speakers", wire: .builtIn, output: true)
    let mic = Port(id: 2, name: "MacBook Pro Microphone", wire: .builtIn, output: false, input: true)
    let bt = Port(id: 3, name: "Bose QuietComfort SC", wire: .bluetooth, output: true, input: true)
    let jack = Port(id: 4, name: "External Headphones", wire: .builtIn, output: true)
    let usb = Port(id: 5, name: "Bose QC Ultra", wire: .usb, output: true)

    // 1 · an arriving Bluetooth Bose wins over the speakers the Mac is using.
    let d1 = BridgeDecision.decide(ports: [speakers, mic, bt], arrived: [3], current: 1)
    check(d1.output == 3 && d1.route == .phonesBluetooth, "an arriving Bose takes over from the speakers")
    // and the mic stays built-in, so the link keeps stereo
    check(d1.pinMicTo == 2, "on Bluetooth the default input stays the built-in mic (stereo, not call quality)")

    // 2 · nothing arrived and the owner is already on the cable: leave it exactly there.
    let d2 = BridgeDecision.decide(ports: [speakers, mic, jack, bt], arrived: [], current: 4)
    check(d2.output == 4 && d2.route == .jack, "a choice already on headphones is left alone")

    // 3 · no headphone port at all: the speakers are muted and the sentence says what to plug in.
    let d3 = BridgeDecision.decide(ports: [speakers, mic], arrived: [], current: 1, was: .phonesBluetooth)
    check(d3.output == nil && d3.mute == [1], "no headphones: the built-in speakers are muted")

    // nothing was ever playing through headphones: the speakers are left alone (the Mac is not silenced at launch)
    let d3b = BridgeDecision.decide(ports: [speakers, mic], arrived: [], current: 1, was: nil)
    check(d3b.mute.isEmpty, "a launch with no headphones never mutes the speakers")

    // 4 · the sentence is this pair's, not a generic one.
    check(d3.say.contains("2.5 mm") && d3.say.contains("switched off"),
          "the QC SC is told about its 2.5 mm cable and that it plays switched off")
    var ultra = BridgeSettings(); ultra.phones = .ultra1
    let d4 = BridgeDecision.decide(ports: [speakers, mic], was: .phonesBluetooth, settings: ultra)
    check(d4.say.contains("powered on"), "a QC Ultra 1st Gen is told its cable needs the headphones powered on")

    // 5 · three links is not a feature the SC is missing: the flagship caps at two as well.
    check(Phones.qcsc.traits.maxLinks == 2 && Phones.ultra2.traits.maxLinks == 2,
          "both the QC SC and the QC Ultra 2nd Gen hold two devices, no more")
    // 6 · what the flagship really has that the SC does not.
    check(!Phones.qcsc.traits.usbAudio && Phones.ultra2.traits.usbAudio,
          "USB-C audio is the Ultra 2nd Gen's, not the SC's")
    check(Phones.qcsc.traits.wiredWhileOff && !Phones.ultra1.traits.wiredWhileOff,
          "the SC plays wired while switched off, where a QC Ultra 1st Gen does not")

    // a stronger port that just arrived beats a weaker one already in use
    let d5 = BridgeDecision.decide(ports: [speakers, jack, usb], arrived: [5], current: 4)
    check(d5.route == .phonesUSB, "USB-C beats the cable when it arrives")

    // 7 + 8 · seats: newest wins, and compaction keeps one line per key.
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("recense-seats-selftest-\(ProcessInfo.processInfo.processIdentifier)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let title = "Symphony No. 9"
    do {
        try Seats.save(Seat(key: Seats.key(title), title: title, at: 1000, position: 12), in: scratch)
        try Seats.save(Seat(key: Seats.key(title), title: title, at: 1001, position: 480, device: "iPhone"), in: scratch)
        let seat = Seats.seat(for: title, in: scratch)
        check(seat?.position == 480 && seat?.device == "iPhone", "two seats for one piece read back as the newer one")

        let limit = 50
        for i in 0..<limit + 2 {
            try Seats.save(Seat(key: Seats.key("piece \(i % 3)"), title: "piece \(i % 3)",
                                at: 2000 + Double(i), position: Double(i)), in: scratch, compactAbove: limit)
        }
        let after = Seats.lines(in: scratch)
        check(after.count < limit && Seats.all(in: scratch).count == 4,
              "past the line limit the file compacts, and still holds one seat per piece (\(after.count) lines)")
        check(Seats.all(in: scratch).first { $0.title == "piece 0" }?.position == 51,
              "compaction keeps each piece's newest seat, not an older one")
    } catch {
        check(false, "seats are written and read back (\(error))")
    }

    // 9 · headroom: two voices at full gain each get half, so a second symphony cannot clip the first.
    let two = Symphonies.headroom([1, 1])
    check(two == [0.5, 0.5], "two voices at full gain play at half each (no clipping)")
    let one = Symphonies.headroom([0.4])
    check(one == [0.4], "one quiet voice is left as it is")
    let three = Symphonies.headroom([1, 0.5, 0.5])
    check(abs(three.reduce(0, +) - 1) < 0.0001, "three voices together still sum to one")

    // 10 · the key is the handoff's shape, so the offline seat and the R2 handoff agree on a title.
    check(Seats.key("  Symphony   No. 9 ") == Seats.key("symphony no. 9"),
          "a title's seat key ignores case and extra spaces")
    return ok
}
