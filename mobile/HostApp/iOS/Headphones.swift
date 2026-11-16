// Derived from Spec: FEAT-15
// Headphones (FEAT-15 P5): the iPhone and iPad half of Bose Bridge. Every rule is in shared/bosebridge.swift,
// which the Mac compiles too — this screen only reads the live route out of AVAudioSession, shows what that pair
// of headphones can actually do, lists the seats any device left behind, and runs the two-at-once mixer.
// Offline from end to end: AVAudioSession, AVAudioEngine and files in the homes. No network, no Bose app.
#if GUEST
// Recense Guest plays what it is handed; it owns no homes and no headphone settings.
import SwiftUI
struct HeadphonesPlace: View { var body: some View { EmptyView() } }
#else
import AVFoundation
import Combine
import ShowsKit
import SwiftUI

@MainActor
final class HeadphonesModel: ObservableObject {
    @Published var route = ""
    @Published var say = ""
    @Published var phones: Phones {
        didSet {
            UserDefaults.standard.set(phones.rawValue, forKey: "bose.phones")
            read()
        }
    }
    @Published var seats: [Seat] = []
    @Published var pieces: [HomeEntry] = []
    let symphonies = Symphonies()

    private var watching: NSObjectProtocol?
    private var ticker: Timer?
    /// The mixer is its own ObservableObject; forward its changes so one screen redraws on both.
    private var mixerChanges: AnyCancellable?

    init() {
        let raw = UserDefaults.standard.string(forKey: "bose.phones") ?? Phones.qcsc.rawValue
        phones = Phones(rawValue: raw) ?? .qcsc
        symphonies.seatFolder = Self.listen
        mixerChanges = symphonies.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        watching = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.read() }
            }
        read()
        reload()
    }

    deinit { if let watching { NotificationCenter.default.removeObserver(watching) } }

    static var listen: URL {
        let url = Homes.url(.listen)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// AVAudioSession is iOS's only view of the route (there is no Core Audio HAL here), so the ports are built
    /// from it and handed to the one shared decision.
    func read() {
        let session = AVAudioSession.sharedInstance()
        var ports: [Port] = []
        var id: UInt32 = 1
        for out in session.currentRoute.outputs {
            ports.append(Port(id: id, name: out.portName, wire: Self.wire(out.portType), output: true))
            id += 1
        }
        for input in session.currentRoute.inputs {
            ports.append(Port(id: id, name: input.portName, wire: Self.wire(input.portType), output: false, input: true))
            id += 1
        }
        var settings = BridgeSettings()
        settings.phones = phones
        // iOS routes the audio itself; nothing here sets a default device, so `current` is simply the first output.
        let d = BridgeDecision.decide(ports: ports, current: ports.first(where: \.output)?.id,
                                      was: nil, settings: settings)
        route = ports.filter(\.output).map(\.name).joined(separator: ", ")
        say = d.say
    }

    static func wire(_ type: AVAudioSession.Port) -> Wire {
        switch type {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return .bluetooth
        case .headphones, .headsetMic: return .jack
        case .usbAudio: return .usb
        case .builtInSpeaker, .builtInMic, .builtInReceiver: return .builtIn
        default: return .other
        }
    }

    func reload() {
        seats = Seats.all(in: Self.listen)
        let kinds: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "flac", "m4b", "caf", "aac"]
        pieces = (Homes.index(.music) + Homes.index(.listen) + Homes.index(.audiobooks))
            .filter { kinds.contains(($0.path as NSString).pathExtension.lowercased()) }
    }

    func add(_ entry: HomeEntry) {
        for home in [Home.music, .listen, .audiobooks] {
            let url = Homes.file(entry, in: home)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            prepareSession()
            symphonies.seatFolder = Self.listen
            do { _ = try symphonies.add(url) } catch { say = "Can't play \(entry.path): \(error.localizedDescription)" }
            start()
            return
        }
    }

    /// Playback keeps going with the screen locked, and mixes with anything else the owner has running.
    private func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }

    func start() {
        prepareSession()
        symphonies.play()
        tickWhileOpen()
    }

    func tickWhileOpen() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.symphonies.tick()
                if !self.symphonies.playing { self.seats = Seats.all(in: Self.listen) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func stopTicking() {
        ticker?.invalidate()
        ticker = nil
        seats = Seats.all(in: Self.listen)
    }
}

struct HeadphonesPlace: View {
    @StateObject private var model = HeadphonesModel()

    var body: some View {
        List {
            Section("Now") {
                Text(model.route.isEmpty ? "No output" : model.route)
                Text(model.say).font(.callout).foregroundStyle(.secondary)
            }

            Section("Headphones") {
                Picker("Pair", selection: $model.phones) {
                    ForEach(Phones.allCases) { p in Text(p.title).tag(p) }
                }
                let t = model.phones.traits
                VStack(alignment: .leading, spacing: 4) {
                    Text("Holds \(t.maxLinks) devices at once").font(.callout)
                    Text(t.wiredWhileOff ? "Plays on the cable switched off, even at 0%"
                                         : "Needs power for the cable").font(.callout)
                    Text(t.usbAudio ? "USB-C carries sound as well as charge"
                                    : "USB-C charges only; sound comes by cable or Bluetooth").font(.callout)
                }.foregroundStyle(.secondary)
                Text("The battery level is not readable on iPhone or iPad — no public API. The Mac shows it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Two at once") {
                if model.symphonies.voices.isEmpty {
                    Text("Pick two pieces below. They play together, one in each ear.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.symphonies.voices) { v in
                        VoiceRow(voice: v, model: model)
                    }
                    Button(model.symphonies.playing ? "Pause all" : "Play all") {
                        model.symphonies.playing ? model.symphonies.pause() : model.start()
                    }
                }
            }

            Section("Pieces") {
                if model.pieces.isEmpty {
                    Text("Nothing in Music, Listen or Audiobooks yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.pieces, id: \.path) { e in
                        Button(e.path) { model.add(e) }
                    }
                }
            }

            Section("Where I left off") {
                if model.seats.isEmpty {
                    Text("Pause a piece on any device and it appears here.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.seats) { s in
                        VStack(alignment: .leading) {
                            Text(s.title)
                            Text("\(clock(s.position)) · \(s.device)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Headphones")
        .onAppear { model.read(); model.reload(); model.tickWhileOpen() }
        .onDisappear { model.stopTicking() }
    }
}

private struct VoiceRow: View {
    let voice: Symphonies.Voice
    @ObservedObject var model: HeadphonesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(voice.title)
            Text("\(clock(voice.position)) / \(clock(voice.duration))")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Ear", selection: Binding(
                get: { voice.place },
                set: { model.symphonies.set(place: $0, for: voice.id) })) {
                    Text("Left").tag(Float(-1))
                    Text("Both").tag(Float(0))
                    Text("Right").tag(Float(1))
                }.pickerStyle(.segmented)
            HStack {
                Text("Volume").font(.caption)
                Slider(value: Binding(get: { voice.gain },
                                      set: { model.symphonies.set(gain: $0, for: voice.id) }), in: 0...1)
            }
            HStack {
                Button(voice.playing ? "Pause" : "Play") {
                    voice.playing ? model.symphonies.pause(voice.id) : model.symphonies.play(voice.id)
                }
                Spacer()
                Button("Resume where I left off") { model.symphonies.resumeFromSeat(voice.id) }
                Spacer()
                Button("Remove") { model.symphonies.remove(voice.id) }
            }.font(.callout)
        }
    }
}

private func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let whole = Int(seconds.rounded())
    return String(format: "%d:%02d", whole / 60, whole % 60)
}
#endif
