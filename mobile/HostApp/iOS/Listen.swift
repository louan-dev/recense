// Listen (notes item 31): Recense on the iPhone and iPad. The broadcast extension (ios/Broadcast) hears whatever is
// playing in any app, on the device, in its own language; here it is cut into sentences, each translated into the
// chosen language (Apple's on-device Translation, as Recense does), and drawn into a Picture in Picture window, the
// floating window that stays over every app until Listen is turned off. Two looks, as on the Mac: Follow (the
// sentence and its translation, the newest word lit) and Learn (two sentences, top and bottom, taking turns).
// In the app: Read along (Spotify's look) with Copy, Clear and full screen. What's heard is kept per episode, made
// by itself (named by when it began and its language; a long silence starts the next), and joined to an older episode
// when what plays continues it (Align.swift), so going back to something opens where it was left (Episode).
import SwiftUI
import ShowsKit
import AVKit
import ReplayKit
import Speech
import Translation
import CryptoKit
import UserNotifications
import NaturalLanguage

struct Sentence: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var heard: String
    var said: String
    var at: Double  // about where in the episode, in seconds of listening (iOS can't see the other app's clock)
    var t: Double? = nil  // the episode's own time, when the Mac wrote it (Recense, handoff.swift)
    var words: [Word]? = nil  // each word as it was said, in seconds into the episode, the clock `time` is on (FEAT-04)
    var replays: Int? = nil  // how many times it was heard again (a rewind or a replay), never added twice (Align.swift)
    var time: Double { t ?? at }
}

extension Sentence {
    // FEAT-04 P1: files written before 11-12 timed words on the wall clock; they read onto the episode's own clock,
    // the first word at the sentence's time (ContentClock.content leaves content-timed words alone).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); heard = try c.decode(String.self, forKey: .heard)
        said = try c.decode(String.self, forKey: .said); at = try c.decode(Double.self, forKey: .at)
        t = try c.decodeIfPresent(Double.self, forKey: .t); replays = try c.decodeIfPresent(Int.self, forKey: .replays)
        words = try c.decodeIfPresent([Word].self, forKey: .words).map { ContentClock.content($0, at: t ?? at) }
    }
}

// One episode's whole transcript, kept on the device (Documents/Recense/library/Listen/<key>.json) and in Gallery
// (keep/listen/<key>.json, src/listen.js) so the Mac and the other devices find it by title. place: the sentence
// last heard, where Read along opens and where new sentences go when this episode is played again.
struct Episode: Identifiable, Codable, Hashable {
    var key: String
    var title: String
    var heard: String
    var into: String
    var place: Int = 0
    var updated: Double = 0  // ms since 1970, the newer copy wins
    var by: String? = nil    // "iphone", "ipad" or "mac": who played it last (the Mac resumes where another left off)
    var ear: String? = nil   // what heard it: "broadcast" (another app's sound itself); "mic" (the room) before 11-11
    var clock: Double? = nil // where the Mac's player was at `updated`, in seconds into the episode (FEAT-04)
    var rate: Double? = nil  // how fast it was playing then (0 paused)
    var sentences: [Sentence] = []
    var id: String { key }

    // the same as listenKey() in src/listen.js
    static func key(_ title: String) -> String {
        let norm = "listen:" + title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return SHA256.hash(data: Data(norm.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }
}

@MainActor
final class Listener: NSObject, ObservableObject {
    static let shared = Listener()

    @Published var on = Captions.state().on   // the broadcast is live
    @Published var error: String?
    // S3b (ListenEars.swift): which ear hears now, where the sound goes, the one Pause (kept across launches), and the
    // once-per-stop "Tap once to keep hearing"
    @Published var ear: Ears.Ear = .none { didSet { if ear != oldValue { draw() } } }  // the empty frame says which: listening, paused, off
    @Published var route: Ears.Route = .speaker
    @Published var paused = UserDefaults.standard.bool(forKey: "listen.paused") { didSet { if paused != oldValue { draw() } } }
    @Published var prompting = false
    var hearing: Bool { ear != .none }
    private var lastOther: Bool?
    private var prompts = UserDefaults.standard.data(forKey: "listen.prompts")
        .flatMap { try? JSONDecoder().decode(Ears.Prompts.self, from: $0) } ?? Ears.Prompts()
    @Published var episode: Episode?
    @Published var episodes: [Episode] = []  // every one kept on this device, newest first
    /// Under Automatic (heard == Captions.automatic), the language last heard: lines say it (Line.locale).
    @Published var spoken = Captions.state().detected ?? "en"
    private var lastCheck: String?
    /// The language being heard now: the chosen one, or under Automatic the one spoken.
    var lang: String { heard == Captions.automatic ? spoken : heard }
    @Published var heard = Captions.state().heard { didSet {
        var s = Captions.state(); s.heard = heard; Captions.put(s); retarget(); Task { await readyEars() }
    } }
    @Published var sooner = Captions.state().sooner ?? false { didSet {
        var s = Captions.state(); s.sooner = sooner; Captions.put(s)
    } }
    @Published var into = UserDefaults.standard.string(forKey: "listen.into") ?? "en" { didSet { UserDefaults.standard.set(into, forKey: "listen.into"); retarget() } }
    @Published var look = UserDefaults.standard.string(forKey: "listen.look") ?? "follow" { didSet { UserDefaults.standard.set(look, forKey: "listen.look"); draw() } }
    // The floating window shows by itself while another app plays and Recense is behind, and hides on pause
    // (Floating.swift; owner 11-10, no Dock). Whether iOS lets it reopen from behind is measured once and kept.
    private var reshow = Floating.Reshow(rawValue: UserDefaults.standard.string(forKey: "listen.reshowFromBehind2") ?? "") ?? .unknown
    private var quietFrom: Date?
    private var leftAt: Date?            // when Recense was last left for another app (Floating.settle)
    private var wasFront = true          // iPad windows: the focus moving to another app counts as leaving (leftAt)
    private var startedActive = false    // this start came from an active iPad app: says nothing about "behind"
    private var resting = false          // the window rests as a thin strip behind (Floating.rest)
    private var tried = false
    private var reshowing = false
    private var lastFloat = ""
    private var closing = false
    private var ticking = false
    private(set) var hidBehind = false   // Recense hid the window on a pause behind; stays awake to reopen it
    @Published var config: TranslationSession.Configuration?
    // the translation pack (Apple Translation's on-device language models): said under the pickers, so a missing one
    // is never a silent blank (playbook rule 3). fetching: the pair being downloaded once, for offline use.
    @Published var pack = ""
    @Published var fetching: TranslationSession.Configuration?
    private var toFetch: [(String, String)] = []
    // what Download did, said under the pickers: each pair's progress, then which ones didn't arrive and why
    // (iOS declines silently otherwise: a refused sheet or a failed download looked like nothing happened)
    @Published var fetchNote = ""
    private var fetchTotal = 0, fetchHad = 0, fetchGot = 0
    private var fetchFailed: [String] = []
    private var fetchPair = ""
    static let missing = "not translated (pack missing)"
    var sentences: [Sentence] { episode?.sentences ?? [] }

    let layer = AVSampleBufferDisplayLayer()
    private var pip: AVPictureInPictureController?
    private var lines: [Int: String] = [:]       // what the extension heard, one entry per recognition request
    private var lineWords: [Int: [Word]] = [:]  // its words, timed (SpeechAnalyzer), in seconds since 1970
    // FEAT-04: where the live words cross onto the episode's clock (the newest sentence heard: its first word, its time)
    private var anchor: ContentClock.Anchor?
    /// Live words (wall clock) stored on the episode's clock, the first at the sentence's time; the anchor follows.
    private func onClock(_ ws: [Word], at t: Double) -> [Word] {
        guard let f = ws.first, ContentClock.isWall(ws) else { return ws }
        anchor = ContentClock.Anchor(wall: f.start, content: t)
        return ContentClock.content(ws, at: t)
    }
    /// Where the content is now, on its own clock: what the broadcast hears (`lag` behind), else where the Mac said its
    /// player was (for 2 minutes after it said so); nil when nothing tells, and nothing is lit by time.
    func contentNow(_ wall: Double = Date().timeIntervalSince1970) -> Double? {
        if hearing, let a = anchor { return a.content(atWall: wall - lag) }
        if let e = episode, e.by == "mac", let c = e.clock, wall - e.updated / 1000 < 120 {
            return ContentClock.Anchor(wall: e.updated / 1000, content: c, rate: e.rate ?? 1).content(atWall: wall)
        }
        return nil
    }
    // how far the words arrive behind the voice: the transcript lights each word this long after it was said, at the
    // voice's own pace (live captions can't be ahead of what they heard)
    @Published var lag = 1.5
    private var savedNoteAt = Date.distantPast   // T-0043: flash "Note saved" on the floating strip after a Draftpad save
    private var skip: [Int: Int] = [:]           // sentences of a request that belong to the episode before
    private var map: [String: String] = [:]      // "request.sentence" → the episode sentence it is (or matched)
    private var added: Set<String> = []          // episode sentences this listening added (not matched to older ones)
    private var said: [String: String] = [:]     // translations by the text they were made from
    private var pending: [String] = []
    private var wake: CheckedContinuation<Void, Never>?
    private let engine = AVAudioEngine()
    private var last: Captions.Line?      // the extension's last line taken
    // the ring (CaptionRing.swift): which version of each line was taken (kept across launches, so a line is taken
    // once), and the numbers given to lines of an earlier broadcast (their n would collide with this one's)
    private var seen: [String: UInt64] = (UserDefaults.standard.dictionary(forKey: "listen.ringSeen") as? [String: String] ?? [:])
        .compactMapValues { UInt64($0) }
    private var nums: [String: Int] = [:]
    private var lastHeard = Date()
    private var lastLineAt = Date()  // when the extension last said something (a long silence starts a new episode)
    private var dirty = false

    override init() {
        super.init()
        Captions.observe(Captions.changed) { [weak self] in if self?.on == true, let l = Captions.line() { self?.take(l) } }
        Captions.observe(Captions.stateChanged) { [weak self] in self?.stateChanged() }
        if !UserDefaults.standard.bool(forKey: "listen.autoSet") {
            UserDefaults.standard.set(true, forKey: "listen.autoSet")
            var s = Captions.state(); s.heard = Captions.automatic; Captions.put(s); heard = Captions.automatic
        }
        loadEpisodes()
        if let k = UserDefaults.standard.string(forKey: "listen.episode") { episode = episodes.first { $0.key == k } }
        retarget()
        catchUp()
        draw()
        Task { await findEars() }
        // Darwin notifications can be missed while the app is between states: also look twice a second
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                let me = Listener.shared
                if Captions.state().live != me.on || Captions.state().error != me.error { me.stateChanged() }
                if me.on, let l = Captions.line(), l != me.last { me.take(l) }
                me.redecide()
            }
        }
        // kept on the device every 10 s while it changes, sent to Gallery every minute
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in Task { @MainActor in Listener.shared.catchUp(); Listener.shared.save() } }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Listener.shared.catchUp() }
        }
        // left for another app: stay awake so a play there shows the window (quiet counted from now, Floating.awake)
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let me = Listener.shared
                me.leftAt = Date()
                if me.quietFrom != nil { me.quietFrom = Date() }
                me.keepAwake(true); me.floatTick()
            }
        }
        // the ears: decided again whenever the sound moves (speaker ↔ headphones), another app starts or stops sound,
        // a call interrupts, or Recense comes to the front
        for n in [AVAudioSession.routeChangeNotification, AVAudioSession.silenceSecondaryAudioHintNotification,
                  AVAudioSession.interruptionNotification, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { _ in
                Task { @MainActor in Listener.shared.redecide() }
            }
        }
        UNUserNotificationCenter.current().delegate = self
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in
            let me = Listener.shared
            await me.upload()
            if let k = me.episode?.key { await me.fetch(k) }
        } }
    }

    // a silent sound mixed under whatever is playing keeps the app running behind the other app (UIBackgroundModes
    // audio), so it can take lines from the extension, translate them and redraw the floating window
    func keepAwake(_ on: Bool) {
        if on, !engine.isRunning {
            let src = AVAudioSourceNode { _, _, _, abl in
                for b in UnsafeMutableAudioBufferListPointer(abl) { memset(b.mData, 0, Int(b.mDataByteSize)) }
                return noErr
            }
            engine.attach(src)
            engine.connect(src, to: engine.mainMixerNode, format: nil)
            try? engine.start()
        } else if !on { engine.stop() }
    }

    func allowSpeech() {
        guard ProcessInfo.processInfo.environment["RECENSE_NO_LISTEN"] == nil else { return }  // simulator screenshots: no prompt over the screen
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    // the languages this device can hear without sending audio anywhere: SFSpeechRecognizer's on-device ones, and on
    // iOS 26 SpeechAnalyzer's (shared/speechcore.swift), whose model is downloaded once, when the language is chosen
    @Published var hearable: [Locale] = SFSpeechRecognizer.supportedLocales()
        .filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
        .sorted { name($0.identifier) < name($1.identifier) }
    @Published var ears = ""   // which ears hear the chosen language here, said under the picker

    func findEars() async {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            let have = Set(hearable.map { $0.identifier(.bcp47) })
            var more: [Locale] = []
            for l in await SpeechTranscriber.supportedLocales + DictationTranscriber.supportedLocales where !have.contains(l.identifier(.bcp47)) {
                if !more.contains(where: { $0.identifier(.bcp47) == l.identifier(.bcp47) }) { more.append(l) }
            }
            hearable = (hearable + more).sorted { Self.name($0.identifier) < Self.name($1.identifier) }
            matchHeard()
            await readyEars()
            return
        }
        #endif
        matchHeard()
        ears = Self.legacyEars(lang)
    }

    /// "en_US" (the device's locale) and "en-US" (the recognizer's) are one language: the picker shows it chosen.
    private func matchHeard() {
        if heard != Captions.automatic, !hearable.contains(where: { $0.identifier == heard }),
           let same = hearable.first(where: { $0.identifier(.bcp47) == Locale(identifier: heard).identifier(.bcp47) }) { heard = same.identifier }
    }

    /// The chosen language's SpeechAnalyzer model, downloaded once (the one moment Listen needs a connection) so the
    /// broadcast extension finds it on the device; said in a line under the picker.
    func readyEars() async {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            let id = heard
            if id == Captions.automatic {
                // all three models once, so the ears can check which is spoken (the extension never downloads)
                var missing: [String] = []
                for c in SpeechCore.auto {
                    guard let (m, l) = await SpeechEngine.module(c) else { missing.append(Self.name(c)); continue }
                    if await SpeechEngine.installed(m, l) { _ = await SpeechEngine.prepare(m, l, keep: Set(SpeechCore.auto), download: false); continue }
                    ears = "Downloading \(Self.name(c)), once…"
                    if !(await SpeechEngine.prepare(m, l, keep: Set(SpeechCore.auto))) { missing.append(Self.name(c)) }
                }
                guard id == heard else { return }
                ears = missing.isEmpty ? "Follows whichever of English, French and Vietnamese is spoken, on this device, word by word."
                    : "Not downloaded yet (needs a connection once): \(missing.joined(separator: ", ")). The others are followed."
                return
            }
            guard let (m, l) = await SpeechEngine.module(id) else { ears = Self.legacyEars(id); return }
            let kind = m == .speech ? "SpeechTranscriber" : "DictationTranscriber"
            if await SpeechEngine.installed(m, l) { ears = "Heard on this device by \(kind), word by word."; _ = await SpeechEngine.prepare(m, l, download: false); return }
            ears = "Downloading \(Self.name(id)) for \(kind), once…"
            let ok = await SpeechEngine.prepare(m, l)
            guard id == heard else { return }
            ears = ok ? "Heard on this device by \(kind), word by word." : "\(kind)'s \(Self.name(id)) isn't downloaded yet (needs a connection once). " + Self.legacyEars(id)
            return
        }
        #endif
        ears = Self.legacyEars(lang)
    }
    static func legacyEars(_ id: String) -> String {
        SFSpeechRecognizer(locale: Locale(identifier: id))?.supportsOnDeviceRecognition == true
            ? "Heard on this device by SFSpeechRecognizer (no word times)." : "This device can't hear \(name(id)) offline."
    }
    static let into = ["en", "vi", "fr"]  // Recense's tr/en|vi|fr
    /// A language's name for a picker row: "English (United States)", or "Automatic". The three languages Automatic
    /// follows are said under the picker: in the row they wrapped after "English," on the iPhone (11-10).
    static func name(_ id: String) -> String {
        id == Captions.automatic ? "Automatic" : Locale.current.localizedString(forIdentifier: id) ?? id
    }
    /// The short name for status lines and episode titles: "English", so "… · English (United States)" never wraps.
    static func short(_ id: String) -> String {
        id == Captions.automatic ? "Automatic"
            : Locale.current.localizedString(forLanguageCode: Locale(identifier: id).language.languageCode?.identifier ?? id) ?? id
    }
    static let automaticNote = "Automatic follows English, French and Vietnamese, whichever is spoken."

    private func stateChanged() {
        let s = Captions.state()
        error = s.error
        // the ears' language checks, the last 20, where a run can be read back (Library/Preferences, listen.checks)
        if let c = s.check, c != lastCheck {
            lastCheck = c
            var all = UserDefaults.standard.stringArray(forKey: "listen.checks") ?? []
            all.append(Date().formatted(date: .omitted, time: .standard) + " " + c)
            UserDefaults.standard.set(Array(all.suffix(20)), forKey: "listen.checks")
        }
        if s.live != on {
            on = s.live
            stopping = false
            catchUp()  // the end of the broadcast before, if the app missed it
            if on {
                if paused { resume() }  // a broadcast started from Control Center is a clear "hear"
                beginListening()
                fresh()  // every broadcast starts its own; Align joins it to an older one when the content continues
            } else {
                save(); Task { await upload() }
            }
            redecide()
        }
    }

    private func beginListening() {
        lines = [:]; lineWords = [:]; anchor = nil; skip = [:]; map = [:]; added = []; lastMatch = nil; replayedNow = []; clearRun()
    }

    // MARK: the ears (S3b, ListenEars.swift)

    /// Which ear hears, decided again at every change: the broadcast, or nothing and one "Tap once to keep hearing"
    /// per stop. Never the mic (owner, 11-10).
    func redecide() {
        if on { restBroadcast(paused) }   // the extension rewrites the state every 2 s: a Pause written between its read and write was lost
        let s = AVAudioSession.sharedInstance()
        route = Ears.route(s.currentRoute.outputs.map(\.portType.rawValue))
        let other = s.isOtherAudioPlaying || s.secondaryAudioShouldBeSilencedHint
        let front = UIApplication.shared.applicationState == .active
        // for the device run: does iOS still tell us, behind other apps, when their sound starts and stops?
        if !front, let was = lastOther, was != other {
            UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "listen.gateFlipsBehind") + 1, forKey: "listen.gateFlipsBehind")
        }
        lastOther = other
        let c = Ears.decide(.init(broadcast: on, route: route, paused: paused, otherAudio: other))
        var p = prompts
        p.update(before: ear, now: c)
        if p.notify(c) { notifyStop() }
        if p != prompts { prompts = p; savePrompts() }
        let shows = prompts.shows(c)
        if prompting, !shows { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["listen.stop"]) }
        prompting = shows
        if c.ear != ear { switchEar(to: c.ear) }
        floatTick()
    }

    private func switchEar(to e: Ears.Ear) {
        let was = ear
        ear = e
        if e != .none, was == .none { keepAwake(true) }
        if e == .none {
            save(); Task { await upload() }
            Listener.held = false; pip?.stopPictureInPicture(); keepAwake(false)
        }
    }

    /// The one Pause: both ears stop and nothing asks to hear until Resume. Kept across launches.
    func pause() {
        paused = true; UserDefaults.standard.set(true, forKey: "listen.paused")
        restBroadcast(true)   // the broadcast stays on, resting: ending it showed iOS's "stopped" alert, and Resume needed the sheet
        redecide()
    }
    func resume() {
        paused = false; UserDefaults.standard.set(false, forKey: "listen.paused")
        restBroadcast(false)
        prompts.resumed(); savePrompts()
        redecide()
    }
    private func restBroadcast(_ on: Bool) {
        var s = Captions.state()
        guard (s.hold == true) != on else { return }
        s.hold = on
        Captions.put(s)
    }
    private func savePrompts() { UserDefaults.standard.set(try? JSONEncoder().encode(prompts), forKey: "listen.prompts") }

    /// The one listening button, the same on Home and Listen: Resume when paused, Pause while hearing, Start when
    /// nothing hears (opens iOS's broadcast sheet). Until 11-10 both offered "Pause listening" while not hearing.
    /// Whether the one button is Start, drawn over the system's picker (StartBroadcast) instead of a plain Button.
    var startsBroadcast: Bool { !paused && !stopping && !hearing }
    var control: (title: String, symbol: String, act: () -> Void) {
        if paused { return ("Resume listening", "play.circle.fill", { self.resume() }) }
        if stopping { return ("Pausing…", "pause.circle.fill", {}) }
        if hearing { return ("Pause listening", "pause.circle.fill", { self.pause() }) }
        return ("Start listening", "record.circle", { self.start() })
    }

    /// Why the prompt shows, in one line.
    var promptWhy: String {
        "Recense hears what other apps play through the broadcast, on the speaker or headphones."
    }

    /// The one notification of a stop (local; nothing leaves the device). Tapping it opens the broadcast sheet.
    private func notifyStop() {
        let c = UNUserNotificationCenter.current()
        Task {
            guard (try? await c.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let n = UNMutableNotificationContent()
            n.title = "Recense stopped hearing"
            n.body = "Tap once to keep hearing what plays."
            try? await c.add(UNNotificationRequest(identifier: "listen.stop", content: n, trigger: nil))
        }
    }

    @Published var stopping = false
    // the extension ends its own broadcast when it sees this (within 2 s); the app can't end it otherwise
    /// Start listening: the floating window gets ready and the system's Start Broadcast sheet opens (the one tap
    /// iOS requires before another app's sound reaches Recense).
    func start() {
        makePiP()
        Task { try? await Task.sleep(for: .milliseconds(300)); BroadcastButton.tap() }
    }

    func stop() {
        var s = Captions.state()
        s.stop = true
        Captions.put(s)
        stopping = true
    }

    // MARK: episodes

    // Episodes live in the Recense home's library (the places contract): Documents/Recense/library/Listen/ here,
    // ~/Recense/library/Listen/ on the Mac. Until 11-09 they were in Documents/Listen/episodes/: moved on first launch.
    private static let folder: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let u = docs.appendingPathComponent("Recense/library/Listen", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        migrate(from: docs.appendingPathComponent("Listen/episodes", isDirectory: true), to: u,
                trash: docs.appendingPathComponent("Recense/trash", isDirectory: true))
        return u
    }()

    /// Moves every episode from the old folder. When both places hold the same episode, the newer copy stays and the
    /// older goes to the Recense trash (which never empties by itself): nothing is lost.
    static func migrate(from old: URL, to new: URL, trash: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            let dest = new.appendingPathComponent(f.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                let updated = { (u: URL) in (try? JSONDecoder().decode(Episode.self, from: Data(contentsOf: u)))?.updated ?? 0 }
                let (keep, drop) = updated(f) > updated(dest) ? (f, dest) : (dest, f)
                try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
                let gone = trash.appendingPathComponent("listen-\(Int(Date().timeIntervalSince1970))-" + drop.lastPathComponent)
                guard (try? fm.moveItem(at: drop, to: gone)) != nil else { continue }
                if keep == f { try? fm.moveItem(at: f, to: dest) }
            } else {
                try? fm.moveItem(at: f, to: dest)
            }
        }
        // the old folders go once empty (Documents/Listen/episodes, then Documents/Listen)
        for d in [old, old.deletingLastPathComponent()] where (try? fm.contentsOfDirectory(atPath: d.path))?.isEmpty == true {
            try? fm.removeItem(at: d)
        }
    }

    private func loadEpisodes() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        episodes = files.compactMap { try? JSONDecoder().decode(Episode.self, from: Data(contentsOf: $0)) }.sorted { $0.updated > $1.updated }
        // an episode that heard nothing is not kept (11-10: every launch left a "0 sentences" one in Episodes and
        // Recently Played); the one in use stays
        let current = UserDefaults.standard.string(forKey: "listen.episode")
        for e in episodes where e.sentences.isEmpty && e.key != current { delete(e) }
    }

    private func save() {
        guard dirty, let e = episode else { return }
        dirty = false
        try? JSONEncoder().encode(e).write(to: Self.folder.appendingPathComponent(e.key + ".json"), options: .atomic)
        episodes.removeAll { $0.key == e.key }
        episodes.insert(e, at: 0)
        unsent.insert(e.key)
    }
    // episodes Gallery hasn't taken yet: kept across launches, so what was heard offline catches up whenever the
    // network comes back, even after the app was closed (FEAT-04 P2; it was in memory only and lost on relaunch)
    private var unsent: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "listen.unsent") ?? []) {
        didSet { UserDefaults.standard.set(unsent.sorted(), forKey: "listen.unsent") }
    }

    // what's playing now: the episode before is kept as it is (where it was, all it heard) and leaves Read along;
    // this one comes in with all it heard before, open where it was left. Gallery's copy is taken if newer.
    /// A new episode, named by when it began and what it's heard in ("9 Nov 2026 at 21:40 · French"): nothing to
    /// choose or type. If what plays turns out to continue an older episode, adoptIfResumed() moves it there.
    func fresh() {
        lastLineAt = Date()
        choose(Date().formatted(date: .abbreviated, time: .shortened) + " · " + Self.short(lang), ear: "broadcast")
    }

    func choose(_ title: String, ear: String? = nil) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        save()
        if let e = episode, e.sentences.isEmpty, e.key != Episode.key(t) { delete(e) }  // it heard nothing: not kept
        if let e = episode, unsent.contains(e.key) { let copy = e; Task { await send(copy) } }
        let key = Episode.key(t)
        episode = episodes.first { $0.key == key } ?? Episode(key: key, title: t, heard: heard, into: into, updated: Date().timeIntervalSince1970 * 1000, ear: ear)  // its ear from the start (it was set after the first save, and the row said "Broadcast")
        UserDefaults.standard.set(key, forKey: "listen.episode")
        // what the extension already heard belongs to the episode before
        for (n, text) in lines { skip[n] = Self.split(text).count }
        map = [:]; added = []; pending = []
        dirty = true; save()
        rebuild()
        Task { await fetch(key) }
    }

    func clear() {
        guard episode != nil else { return }
        episode!.sentences = []; episode!.place = 0
        map = [:]; added = []
        touch(); draw()
    }

    func delete(_ e: Episode) {
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(e.key + ".json"))
        episodes.removeAll { $0.key == e.key }
        unsent.remove(e.key)
        if episode?.key == e.key { episode = nil }
    }

    private func touch() {
        episode?.updated = Date().timeIntervalSince1970 * 1000
        episode?.by = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        dirty = true
    }

    // MARK: Gallery's copy (src/listen.js)

    private func request(_ key: String, method: String = "GET", body: Data? = nil) -> URLRequest? {
        guard let d = Token.read(), let t = try? JSONDecoder().decode([String: String].self, from: d),
              let id = t["id"], let secret = t["secret"] else { return nil }
        var r = URLRequest(url: URL(string: "https://\(Gallery.base.host!)/main/api/listen" + (key.isEmpty ? "" : "/" + key))!)
        r.httpMethod = method
        r.httpBody = body
        r.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
        r.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        r.setValue("1", forHTTPHeaderField: "x-gallery")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        return r
    }

    func fetch(_ key: String) async {
        guard let r = request(key), let (d, res) = try? await URLSession.shared.data(for: r),
              (res as? HTTPURLResponse)?.statusCode == 200, let theirs = try? JSONDecoder().decode(Episode.self, from: d) else { return }
        take(theirs)
    }

    private func take(_ theirs: Episode) {
        var theirs = theirs
        let ours = episode?.key == theirs.key ? episode : episodes.first { $0.key == theirs.key }
        let timed = theirs.sentences.contains { $0.t != nil } && !(ours?.sentences.contains { $0.t != nil } ?? false)
        guard theirs.updated > (ours?.updated ?? 0) || timed else { return }
        // ours is newer but theirs is the Mac's whole timed transcript: take it, and keep our place, found by its words
        if let ours, ours.updated >= theirs.updated, ours.sentences.indices.contains(ours.place) {
            let w = Align.words(ours.sentences[ours.place].heard)
            if let j = theirs.sentences.indices.max(by: { Align.overlap(w, Align.words(theirs.sentences[$0].heard)) < Align.overlap(w, Align.words(theirs.sentences[$1].heard)) }),
               Align.overlap(w, Align.words(theirs.sentences[j].heard)) >= 0.6 { theirs.place = j }
            theirs.updated = ours.updated; theirs.by = ours.by
            unsent.insert(theirs.key)
        }
        try? JSONEncoder().encode(theirs).write(to: Self.folder.appendingPathComponent(theirs.key + ".json"), options: .atomic)
        episodes.removeAll { $0.key == theirs.key }
        episodes.insert(theirs, at: 0)
        if episode?.key == theirs.key { episode = theirs; map = [:]; added = []; rebuild() }
    }

    func upload() async {
        save()
        for key in unsent { if let e = episodes.first(where: { $0.key == key }) { await send(e) } }
    }

    private func send(_ e: Episode) async {
        guard let body = try? JSONEncoder().encode(e), let r = request(e.key, method: "PUT", body: body),
              let (d, res) = try? await URLSession.shared.data(for: r), let code = (res as? HTTPURLResponse)?.statusCode else { return }
        if code == 200 { unsent.remove(e.key) }
        if code == 409, let theirs = try? JSONDecoder().decode(Episode.self, from: d) { unsent.remove(e.key); take(theirs) }
    }

    // MARK: sentences and translation (.translationTask on the root view keeps the session alive)

    private func retarget() {
        let from = Locale.Language(identifier: lang), to = Locale.Language(identifier: into)
        config = from.languageCode == to.languageCode ? nil : .init(source: from, target: to)
        said = [:]
        Task { await checkPack() }
        // translations made into another language are made again
        if let e = episode, e.into != into || e.heard != heard {
            episode!.into = into; episode!.heard = heard
            for i in episode!.sentences.indices { episode!.sentences[i].said = config == nil ? episode!.sentences[i].heard : "" }
            touch()
        }
        rebuild()
    }

    // "Bonjour. Ça va ? Oui" → ["Bonjour.", "Ça va ?", "Oui"]; "你好吗？我很好。" → ["你好吗？", "我很好。"] (row 30: scripts
    // without spaces end a sentence at their own stops, which need no space after them; Arabic ؟ and Ge'ez ። too)
    static let stops = Align.stops
    static let wideStops: Set<Character> = ["。", "？", "！", "؟", "።", "፧", "།", "॥", "।"]
    static func split(_ text: String) -> [String] {
        var out: [String] = [], cur = ""
        let cs = Array(text)
        for (i, c) in cs.enumerated() {
            cur.append(c)
            guard stops.contains(c) else { continue }
            let next = i + 1 < cs.count ? cs[i + 1] : nil
            if let n = next, stops.contains(n) || "」』”\"')）".contains(n) { continue }
            if next == nil || next!.isWhitespace || wideStops.contains(c) {
                let t = cur.trimmingCharacters(in: .whitespaces); if !t.isEmpty { out.append(t) }; cur = ""
            }
        }
        let t = cur.trimmingCharacters(in: .whitespaces); if !t.isEmpty { out.append(t) }
        return out
    }

    /// The timed words of a line, shared out among its sentences (split()), each word to the sentence it sits in.
    static func timed(_ text: String, _ words: [Word]) -> [[Word]] {
        let sents = split(text)
        var spans: [Range<String.Index>] = [], cur = text.startIndex
        for s in sents {
            if let r = text.range(of: s, range: cur..<text.endIndex) { spans.append(r); cur = r.upperBound } else { spans.append(cur..<cur) }
        }
        var out = Array(repeating: [Word](), count: sents.count)
        cur = text.startIndex
        for w in words {
            guard let r = text.range(of: w.text, range: cur..<text.endIndex) else { continue }
            cur = r.upperBound
            if let k = spans.firstIndex(where: { $0.contains(r.lowerBound) }) { out[k].append(w) }
        }
        return out
    }

    // is this sentence one the episode already has (the user went back, or played it again)? the closest to where
    // they are wins when several are alike
    private func match(_ text: String, besides: String? = nil) -> Int? {
        guard let e = episode else { return nil }
        let after = (run.last?.old ?? lastMatch).flatMap { id in e.sentences.firstIndex { $0.id == id } }
        let not = besides.flatMap { id in e.sentences.firstIndex { $0.id == id } }
        return Align.match(text, in: e.sentences.map(\.heard), place: e.place, after: after, besides: not)
    }
    private var lastMatch: String?             // the sentence placed last (a short one is only known right after it)
    // held (Align.fit): finished sentences kept as new for now, each like an older one (`old`), until they prove a
    // rewind; a song's chorus never does, so it stays in order at the end and the light stays on it (owner, 11-10)
    private var run: [(copy: String, old: String)] = []
    private var runAnchor: String?             // where the listening was when the run began

    private func index(_ id: String?) -> Int? { id.flatMap { id in episode?.sentences.firstIndex { $0.id == id } } }
    /// Align.fit for a finished sentence like stored sentence j; copy: where it grew as a new one, if it did.
    private func fit(_ j: Int, copy: Int?) -> Align.Fit {
        Align.fit(j, after: copy ?? index(lastMatch), end: copy.map { $0 - 1 } ?? episode!.place,
                  run: run.compactMap { index($0.old) }, anchor: index(runAnchor))
    }
    /// The held run proved a rewind: its copies go, and what pointed at them points at the sentences they repeat.
    private func dropRun() {
        for r in run {
            episode!.sentences.removeAll { $0.id == r.copy }
            added.remove(r.copy)
            for (k, v) in map where v == r.copy { map[k] = r.old }
        }
        clearRun()
    }
    private func clearRun() { run = []; runAnchor = nil }
    private func hold(_ copy: String, like old: String, continues: Bool, end: String?) {
        if continues { run.append((copy, old)) } else { run = [(copy, old)]; runAnchor = end }
    }
    private var replayedNow: Set<String> = []  // sentences counted as replayed in this listening

    /// A sentence heard before, cut short then (the content was left mid-sentence), is kept whole now.
    private func complete(_ i: Int, _ text: String, _ ws: [Word]?) {
        let old = episode!.sentences[i].heard
        guard let end = old.trimmingCharacters(in: .whitespaces).last, !Self.stops.contains(end), Align.completes(text, old) else { return }
        episode!.sentences[i].heard = text
        if let ws { episode!.sentences[i].words = onClock(ws, at: episode!.sentences[i].time) }
        episode!.sentences[i].said = config == nil ? text : said[text] ?? ""
        translate(text)
        touch()
    }

    /// Content left partway in another episode and resumed now: when the sentences this listening added continue an
    /// episode of the last 30 days (three in a row, in order), they belong there. They move over (matched, never
    /// added twice) and that episode goes on from where they are; this one is removed if they were all it had.
    private func adoptIfResumed() -> Bool {
        guard let e = episode, !added.isEmpty, added.count <= 20 else { return false }
        let mine = e.sentences.filter { added.contains($0.id) }.map(\.heard)
        let since = Date().timeIntervalSince1970 * 1000 - 30 * 86_400_000
        for o in episodes where o.key != e.key && o.updated > since {
            guard let j = Align.continues(mine, in: o.sentences.map(\.heard)) else { continue }
            var left = e
            left.sentences.removeAll { added.contains($0.id) }
            if left.sentences.isEmpty { delete(e) } else { episode = left; dirty = true; save() }
            episode = o
            episode!.place = j
            UserDefaults.standard.set(o.key, forKey: "listen.episode")
            map = [:]; added = []; lastMatch = nil; clearRun()
            touch()
            rebuild()
            return true
        }
        return false
    }

    private func translate(_ text: String) {
        guard config != nil, said[text] == nil, !pending.contains(text) else { return }
        pending.removeAll { text.hasPrefix($0) }  // an older, shorter version of the same sentence
        pending.append(text)
        wake?.resume(); wake = nil
    }

    private func rebuild() {
        guard episode != nil else { draw(); return }
        for n in lines.keys.sorted() {
            let timed = lineWords[n].map { Self.timed(lines[n] ?? "", $0) }
            let parts = Self.split(lines[n] ?? "")
            for (k, text) in parts.enumerated() where k >= skip[n, default: 0] {
                let ws = timed.flatMap { k < $0.count && !$0[k].isEmpty ? $0[k] : nil }
                let lid = "\(n).\(k)"
                // still being heard (the last of its line, no stop yet): new, growing in place; only a finished one is
                // compared with what was heard before (a beginning like "And the judge" matched an old sentence and
                // the new one was lost, 11-09; mobile/ios/Tests/align "growing live captions")
                let done = k < parts.count - 1 || Align.complete(text)
                if let sid = map[lid], let i = episode!.sentences.firstIndex(where: { $0.id == sid }) {
                    guard episode!.sentences[i].heard != text else { continue }
                    guard added.contains(sid) else { complete(i, text, ws); continue }
                    // it grew whole: if it is one heard before and Align.fit says so (it follows the last one
                    // recognised, or a held run proved a rewind), use that one and drop the copy; else it stays new
                    let j = done ? match(text, besides: sid) : nil
                    let f = j.map { fit($0, copy: i) }
                    if let j, let f, !f.holds {
                        let keep = episode!.sentences[j].id
                        if f == .merge(continues: true) { dropRun() } else { clearRun() }
                        episode!.sentences.removeAll { $0.id == sid }
                        added.remove(sid); map[lid] = keep; lastMatch = keep
                        episode!.place = index(keep) ?? episode!.place
                        if let k = index(keep) { complete(k, text, ws) }
                    } else {
                        if let j, case .hold(let c) = f { hold(sid, like: episode!.sentences[j].id, continues: c, end: i > 0 ? episode!.sentences[i - 1].id : nil) }
                        else if done { clearRun() }
                        episode!.sentences[i].heard = text
                        if let ws { episode!.sentences[i].words = onClock(ws, at: episode!.sentences[i].time) }
                        episode!.sentences[i].said = config == nil ? text : said[text] ?? episode!.sentences[i].said
                        translate(text)
                    }
                    touch()
                } else if done, let j = match(text), case let f = fit(j, copy: nil), !f.holds {
                    let sid = episode!.sentences[j].id
                    if f == .merge(continues: true) { dropRun() } else { clearRun() }
                    let j = index(sid) ?? j
                    map[lid] = sid
                    episode!.place = j
                    lastMatch = sid
                    if !replayedNow.contains(sid) { replayedNow.insert(sid); episode!.sentences[j].replays = (episode!.sentences[j].replays ?? 0) + 1 }
                    complete(j, text, ws)
                    lastHeard = Date()
                    touch()
                } else {
                    // new: goes after where the user is, and becomes where they are. A finished one like an older
                    // sentence is held (new for now: a chorus, a repeated phrase) until it proves a rewind (Align.fit)
                    let like = done ? match(text) : nil
                    let likeId = like.map { episode!.sentences[$0].id }
                    let holds = like.map { fit($0, copy: nil) }
                    let end = episode!.sentences.isEmpty ? nil : episode!.sentences[min(episode!.place, episode!.sentences.count - 1)].id
                    let at = episode!.sentences.isEmpty ? 0 : episode!.place + 1
                    let prev = at > 0 ? episode!.sentences[at - 1].at : 0
                    // on the episode's clock: as far after the last sentence heard as its first word was said (gaps
                    // over 30 s count as 30), or, without words, as long as the listening went on
                    let gap = ws?.first.flatMap { f in anchor.map { f.start - $0.wall } }
                    let t = gap.map { max(prev, anchor!.content + min(30, max(0, $0))) } ?? prev + min(30, Date().timeIntervalSince(lastHeard))
                    let s = Sentence(id: UUID().uuidString.prefix(12).lowercased(), heard: text, said: config == nil ? text : said[text] ?? "",
                                     at: t, words: ws.map { onClock($0, at: t) })
                    episode!.sentences.insert(s, at: min(at, episode!.sentences.count))
                    episode!.place = min(at, episode!.sentences.count - 1)
                    map[lid] = s.id; added.insert(s.id); lastMatch = s.id
                    if let likeId, case .hold(let c)? = holds { hold(s.id, like: likeId, continues: c, end: end) }
                    else if done { clearRun() }
                    lastHeard = Date()
                    translate(text)
                    touch()
                    if adoptIfResumed() { return }
                }
            }
        }
        // sentences translated before this app run, or into another language, get done as they come into view
        if let e = episode, config != nil {
            for s in e.sentences[max(0, e.place - 3)..<min(e.sentences.count, e.place + 4)] where s.said.isEmpty || s.said == Self.missing { translate(s.heard) }
        }
        changed()
    }

    /// Takes the lines the extension heard while this app was asleep or not running. Lines of an earlier broadcast
    /// get numbers of their own, so they don't overwrite this broadcast's lines.
    func catchUp() {
        let ring = Captions.ring()
        defer {  // what was taken live counts too: kept every 10 s, so a relaunch doesn't take it twice
            if seen.count > 600 { let keep = Set(ring.lines.map(\.ringKey)); seen = seen.filter { keep.contains($0.key) } }
            UserDefaults.standard.set(seen.mapValues { String($0) }, forKey: "listen.ringSeen")
        }
        let missed = ring.unseen(seen)
        guard !missed.isEmpty else { return }
        if episode == nil { fresh() }
        let now = Captions.state().b
        for l in missed {
            var x = l
            if l.b != now {
                if nums[l.ringKey] == nil { nums[l.ringKey] = 1_000_000 + nums.count }
                x.n = nums[l.ringKey]!
            }
            take(x, key: l.ringKey)
        }
    }

    private func take(_ l: Captions.Line, key: String? = nil) {
        seen[key ?? l.ringKey] = l.ringStamp
        if key != nil { lines[l.n] = l.text; rebuild(); return }  // from the ring: text only, not the live line
        // 3 minutes without a word, then speech: something else is playing now, so it starts its own episode
        if hearing, l != last, Date().timeIntervalSince(lastLineAt) > 180, !added.isEmpty {
            beginListening(); fresh()
        }
        lastLineAt = Date()
        last = l
        if heard == Captions.automatic, SpeechCore.code(l.locale) != spoken, SpeechCore.auto.contains(SpeechCore.code(l.locale)) {
            spoken = SpeechCore.code(l.locale); retarget()
        }
        lines[l.n] = l.text
        if let ws = l.words, let t0 = l.t0 {
            lineWords[l.n] = ws.map { Word(text: $0.text, start: t0 + $0.start, end: t0 + $0.end) }
            if let w = ws.last { lag = 0.7 * lag + 0.3 * min(4, max(0.3, Date().timeIntervalSince1970 - (t0 + w.end))) }
        }
        rebuild()
    }

    /// Whether the chosen pair translates on this device, said in one line.
    func checkPack() async {
        guard let c = config, let from = c.source, let to = c.target else { pack = ""; return }
        let names = "\(Self.name(from.minimalIdentifier)) → \(Self.name(to.minimalIdentifier))"
        switch await LanguageAvailability().status(from: from, to: to) {
        case .installed: pack = "Translation \(names): on this device, works offline."
        case .supported: pack = "Translation \(names): needs a one-time download. Tap Download."
        case .unsupported: pack = "Translation \(names) isn't available on this device."
        @unknown default: pack = ""
        }
    }

    /// Downloads English, Vietnamese and French for every direction between them, once, while the app is open (iOS
    /// asks before each download). Afterwards translation needs no connection.
    func fetchAll() {
        Task {
            toFetch = []; fetchHad = 0; fetchGot = 0; fetchFailed = []
            for a in Self.into { for b in Self.into where a != b {
                let st = await LanguageAvailability().status(from: .init(identifier: a), to: .init(identifier: b))
                if st == .installed { fetchHad += 1 } else { toFetch.append((a, b)) }
            } }
            fetchTotal = toFetch.count
            fetchNext()
        }
    }
    private func fetchNext() {
        guard !toFetch.isEmpty else {
            fetching = nil
            let had = fetchHad + fetchGot, all = fetchHad + fetchTotal
            fetchNote = fetchFailed.isEmpty
                ? "Translation: all \(all) directions between English, Vietnamese and French are on this device."
                : "Translation: \(had) of \(all) directions on this device. Not downloaded: " + fetchFailed.joined(separator: "; ") + "."
            // what said "pack missing" is translated again now
            if episode != nil { for i in episode!.sentences.indices where episode!.sentences[i].said == Self.missing { episode!.sentences[i].said = "" } }
            said = [:]; rebuild()
            Task { await checkPack() }
            return
        }
        let (a, b) = toFetch.removeFirst()
        fetchPair = "\(Self.name(a)) → \(Self.name(b))"
        fetchNote = "Downloading \(fetchPair) (\(fetchTotal - toFetch.count) of \(fetchTotal))…"
        fetching = .init(source: .init(identifier: a), target: .init(identifier: b))
    }
    func fetched(_ session: TranslationSession) async {
        let names = fetchPair
        do { try await session.prepareTranslation(); fetchGot += 1 }
        catch { fetchFailed.append("\(names) (\(error.localizedDescription))") }
        fetchNext()
    }

    func serve(_ session: TranslationSession) async {
        try? await session.prepareTranslation()
        await checkPack()
        while !Task.isCancelled {
            if pending.isEmpty { await withCheckedContinuation { wake = $0 } }
            guard !pending.isEmpty else { continue }
            let text = pending.removeFirst()
            guard let r = try? await session.translate(text) else {
                // offline without the pack (or any other failure): the sentence says so instead of staying blank
                await checkPack()
                guard episode != nil else { continue }
                for i in episode!.sentences.indices where episode!.sentences[i].heard == text && episode!.sentences[i].said.isEmpty {
                    episode!.sentences[i].said = Self.missing
                }
                touch(); changed()
                continue
            }
            said[text] = r.targetText
            guard episode != nil else { continue }
            for i in episode!.sentences.indices where episode!.sentences[i].heard == text { episode!.sentences[i].said = r.targetText }
            touch()
            changed()
        }
    }

    // MARK: the floating window

    // made once the layer is in a window, so it is ready (possible) before the user leaves the app
    func makePiP() {
        guard pip == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        if layer.controlTimebase == nil {
            var tb: CMTimebase?
            CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
            if let tb { CMTimebaseSetTime(tb, time: CMClockGetTime(CMClockGetHostTimeClock())); CMTimebaseSetRate(tb, rate: 1); layer.controlTimebase = tb }
        }
        let p = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self))
        p.delegate = self
        p.canStartPictureInPictureAutomaticallyFromInline = false   // floatTick opens it only while something plays
        p.requiresLinearPlayback = true
        pip = p
        pipObs = p.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { _, _ in Task { @MainActor in Listener.shared.pipNote() } }
        pipActive = p.observe(\.isPictureInPictureActive, options: [.new]) { c, _ in
            let open = c.isPictureInPictureActive
            Task { @MainActor in
                let me = Listener.shared
                me.pipNote()
                // iOS suspends Recense behind other apps unless it plays: the silent sound keeps it awake while the
                // window shows, so the window can hide on pause (11-10 iPhone: it stayed up without this)
                if open { me.keepAwake(true) } else if !me.hearing, !me.hidBehind { me.keepAwake(false) }
            }
        }
        draw()
        // a still frame goes stale for PiP; draw again each second
        if !ticking {   // once: makePiP runs again after dropPiP
            ticking = true
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in Listener.shared.draw() } }
            // show and hide decided 10 times a second: on play or pause the window follows within the owner's 0.5 s
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in Task { @MainActor in Listener.shared.floatTick() } }
        }
    }
    /// Lets go of the floating window's controller (its window closes with it); makePiP makes a new one.
    private func dropPiP() {
        pipObs = nil; pipActive = nil
        pip = nil
        pipNote()
    }
    private var pipObs: NSKeyValueObservation?
    private var pipActive: NSKeyValueObservation?
    @Published var pipState = ""
    func pipNote() {
        guard let pip else { pipState = "Floating window: not supported here"; return }
        pipState = pip.isPictureInPictureActive ? "Floating window: open" : pip.isPictureInPicturePossible ? "Floating window: ready" : "Floating window: not ready"
    }

    /// Once a second and at every sound change: open the window as Recense is left while something plays, hide it
    /// in Recense (Home shows the transcript) and after 3 s of the other app paused behind it.
    func floatTick() {
        if pip == nil, UIApplication.shared.applicationState == .active { makePiP() }   // after dropPiP
        guard let pip else { return }
        if Floating.reattach(open: pip.isPictureInPictureActive, attached: pip.contentSource != nil, closing: closing) {
            pip.contentSource = .init(sampleBufferDisplayLayer: layer, playbackDelegate: self)
            floatNote("content attached again")
        }
        let s = AVAudioSession.sharedInstance()
        let playing = Floating.playing(flag: s.isOtherAudioPlaying || s.secondaryAudioShouldBeSilencedHint, hearing: hearing,
                                       soundAgo: Captions.state().sound.map { Date().timeIntervalSince($0) })   // T-0041
        // iPad windows: another app's window can cover Recense while it stays active (11-10 iPad log: "front playing" for
        // 2 min under a full-screen Firefox), so in front also needs the focus; active without it may start the window
        let active = UIApplication.shared.applicationState == .active
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let key = UIApplication.shared.connectedScenes.contains { ($0 as? UIWindowScene)?.windows.contains { $0.isKeyWindow } == true }
        let front = Floating.front(active: active, pad: pad, key: key)
        let canStart = active && !front
        if wasFront != front {
            if !front { leftAt = Date(); if quietFrom != nil { quietFrom = Date() } }
            floatNote("focus: \(front ? "Recense" : "another app") (active=\(active) key=\(key))")
            wasFront = front
        }
        pip.canStartPictureInPictureAutomaticallyFromInline = Floating.autoOpen(paused: paused)
        if playing { quietFrom = nil } else if quietFrom == nil { quietFrom = Date() }
        if !playing || front { tried = false }
        if front { hidBehind = false }
        // behind other apps, awake while the window is open, while hearing, or for 10 minutes of quiet (Floating.awake)
        let quiet = quietFrom.map { Date().timeIntervalSince($0) } ?? 0
        if !front { keepAwake(Floating.awake(front: front, open: pip.isPictureInPictureActive, hearing: hearing, quiet: quiet)) }
        let rest = Floating.rest(front: front, open: pip.isPictureInPictureActive, reopens: reshow == .works, quiet: quiet, paused: paused, canStart: canStart)
        if rest != resting {
            resting = rest; drawnKey = ""; drawnAt = .distantPast
            floatNote(rest ? "rest: thin strip (iOS won't reopen it behind)" : "wake: full captions")
            draw()
        }
        let act = Floating.decide(.init(front: front, playing: playing, paused: paused, open: pip.isPictureInPictureActive,
                                        quiet: quietFrom.map { Date().timeIntervalSince($0) } ?? 0, reshow: reshow, tried: tried,
                                        hid: hidBehind, left: leftAt.map { Date().timeIntervalSince($0) } ?? 9, canStart: canStart))
        let line = "\(front ? "front" : canStart ? "unfocused" : "behind") \(playing ? "playing" : "quiet") \(pip.isPictureInPictureActive ? "open" : "closed") \(act)"
        if line != lastFloat { lastFloat = line; floatNote("\(line) reshow=\(reshow.rawValue) awake=\(engine.isRunning)") }
        switch act {
        case .hide:
            hidBehind = !front && !paused
            guard !closing else { break }
            closing = true
            pip.stopPictureInPicture()
            // 11-10 iPhone: behind other apps iOS ignored stop (no "will stop", still open a second later), so the
            // window is taken apart instead: first its content, then the controller (made again when Recense is in front)
            Task {
                try? await Task.sleep(for: .milliseconds(150))   // the owner's bar is 0.5 s from pause to gone
                if pip.isPictureInPictureActive { floatNote("stop ignored; detaching content"); pip.contentSource = nil }
                try? await Task.sleep(for: .seconds(1))
                if pip.isPictureInPictureActive { floatNote("still open; releasing the controller"); dropPiP() }
                floatNote("hide done: \(self.pip?.isPictureInPictureActive == true ? "still open" : "closed")")
                closing = false
            }
        case .show:
            tried = true; reshowing = true; hidBehind = false; startedActive = canStart
            if pip.contentSource == nil {   // detached to hide it (below): give it the layer back first
                pip.contentSource = .init(sampleBufferDisplayLayer: layer, playbackDelegate: self)
            }
            floatNote("reopen: possible=\(pip.isPictureInPicturePossible)")
            startPiP()
            // works when it opened; refused only on iOS's own error (the delegate), never on a silent wait: one silent
            // try read as "refused" on 11-10 and the window never came back (listen.reshowFromBehind is set aside for it)
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard reshowing else { return }
                if pip.isPictureInPictureActive { if startedActive { reshowing = false } else { learn(.works) } }
                else { reshowing = false; floatNote("reopen: not open after 2 s, no error; tried again on the next play") }
            }
        case .none: break
        }
    }
    /// The floating window's log for the device run (Library/Preferences listen.floatLog, last 30 lines).
    func floatNote(_ line: String) {
        var log = UserDefaults.standard.stringArray(forKey: "listen.floatLog") ?? []
        log.append("\(Date().formatted(date: .omitted, time: .standard)) \(line)")
        UserDefaults.standard.set(Array(log.suffix(30)), forKey: "listen.floatLog")
    }

    /// Flash "Note saved" on the floating strip for 2.5 s after a Draftpad save during a broadcast (T-0043).
    func noteSaved() { savedNoteAt = Date(); draw() }
    func learn(_ r: Floating.Reshow) {
        reshowing = false
        guard r != reshow else { return }
        reshow = r; UserDefaults.standard.set(r.rawValue, forKey: "listen.reshowFromBehind2")
    }
    var reshowTrying: Bool { reshowing && !startedActive }   // a refusal while active (iPad) says nothing about behind

    func startPiP() {
        try? AVAudioSession.sharedInstance().setActive(true)
        keepAwake(true)
        makePiP()
        draw()
        if pip?.isPictureInPicturePossible == true { pip?.startPictureInPicture() }
        else { Task { for _ in 0..<20 where pip?.isPictureInPicturePossible != true { try? await Task.sleep(for: .milliseconds(100)) }
            pip?.startPictureInPicture(); pipNote() } }
    }

    // Learn's two places: top holds even sentences, bottom odd; when a new one takes a place, what was there fades
    // out, then the new one fades in, while the other place stays
    // out, then the new one fades in, while the other place stays. Once heard, a sentence dissolves into its
    // translation in the same place (row 31, as the website's Learn: TURN in gallery.js)
    private struct Slot { var now: Sentence?; var was: Sentence?; var since = Date.distantPast; var heard: Date? }
    private var slots = [Slot(), Slot()]
    private var animating = false

    private func changed() {
        let p = episode?.place ?? 0
        for j in [p - 1, p] where j >= 0 && j < sentences.count {
            let s = sentences[j], k = j % 2
            if slots[k].now?.id != s.id { slots[k] = Slot(now: s, was: slots[k].now, since: Date()); animate() }
            else { slots[k].now = s }
            if j < p, slots[k].heard == nil { slots[k].heard = Date(); animate() }
        }
        draw()
    }

    private func animate() {
        guard !animating else { return }
        animating = true
        Task {
            while slots.contains(where: { Date().timeIntervalSince($0.since) < 0.55 || Date().timeIntervalSince($0.heard ?? .distantPast) < 0.6 }) { draw(); try? await Task.sleep(for: .milliseconds(33)) }
            animating = false
            draw()
        }
    }

    // the floating window's middle button: holds the words where they are (Listen keeps hearing; play shows the newest)
    nonisolated(unsafe) static var held = false
    func hold(_ on: Bool) {
        Listener.held = on
        pip?.invalidatePlaybackState()
        if !on { draw() }
    }

    /// The floating window's canvas in points, drawn at 3x: the window shows it at about this size, so the transcript's
    /// own type reads large and sharp. (Until 11-10: 640x300 at 1x, stretched by iOS, soft and small; centred, so every
    /// new word moved every other one; older lines cut through at the top.)
    static let canvas = CGSize(width: 400, height: 188)
    private var drawnKey = ""
    private var drawnAt = Date.distantPast
    private var drawSoon = false

    /// Draws what the floating window shows, in the transcript's look (ShowsKit's TranscriptLineText, as Read along):
    /// a new picture when what it shows changes (at most 10 a second), the same one again each second, as PiP goes stale
    /// without frames; and, ahead of time, one picture per coming word, stamped for the moment it starts (the layer runs on
    /// the host clock and shows each on the refresh its word starts on; before, a word waited for the next redraw, up to
    /// a second late behind other apps).
    func draw() {
        if Listener.held { if !queued.isEmpty { layer.flush(); queued = [] }; return }
        if resting {
            guard drawnKey != "rest" || Date().timeIntervalSince(drawnAt) >= 1, let sb = Self.restPicture() else { return }
            layer.flush(); queued = []; queuedShape = ""
            layer.enqueue(sb); drawnKey = "rest"; drawnAt = Date()
            return
        }
        let wall = Date(), nowL = wall.timeIntervalSince1970 - lag
        let (rows, note) = frame(at: wall)
        let key = Self.key(rows, note), shape = Self.key(rows.map(\.unlit), note)
        // a picture stamped ahead that's on screen by now already shows this
        if let shown = queued.last(where: { $0.at <= nowL }) { drawnKey = shown.key; drawnAt = wall }
        queued.removeAll { $0.at <= nowL }
        let stale = shape != queuedShape || abs(lag - queuedLag) > 0.008
        let since = wall.timeIntervalSince(drawnAt)
        if key != drawnKey || since >= 1 || stale {
            if since < 0.1 {
                guard !drawSoon else { return }
                drawSoon = true
                Task { try? await Task.sleep(for: .milliseconds(100)); drawSoon = false; draw() }
                return
            }
            guard let sb = picture(rows, note, at: nil) else { return }
            if layer.status == .failed || !queued.isEmpty || stale { layer.flush() }   // keeps the picture on screen
            queued = []; queuedShape = shape; queuedLag = lag
            drawnKey = key; drawnAt = wall
            layer.enqueue(sb)
        }
        // the coming words of the lit line(s), each in its own picture stamped for its start
        let starts = rows.filter(\.on).flatMap { $0.line.words.map(\.start) }
        let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        for at in Floating.onsets(starts, after: queued.last?.at ?? nowL) where at - nowL > 0.004 {
            let (r, n) = frame(at: Date(timeIntervalSince1970: at + lag + 0.0005))
            guard let sb = picture(r, n, at: host + (at - nowL)) else { break }
            layer.enqueue(sb)
            queued.append((at, Self.key(r, n)))
        }
    }
    /// Pictures stamped ahead, in the light's time, with what each shows; the shape (lines without their light) and lag
    /// they were drawn for: either changing makes them wrong, so they're dropped and drawn again.
    private var queued: [(at: Double, key: String)] = []
    private var queuedShape = ""
    private var queuedLag = 0.0

    private static func key(_ rows: [FloatingCaption.Row], _ note: String?) -> String {
        rows.map { "\($0.line.id)|\($0.line.text)|\($0.line.translation ?? "")|\($0.cut)|\(Int($0.alpha * 10))|\(Int($0.turned * 10))" }.joined(separator: "/") + (note ?? "")
    }

    /// One picture of the window; `at` (host-clock seconds) stamps it for that moment, nil shows it at once.
    private func picture(_ rows: [FloatingCaption.Row], _ note: String?, at: Double?) -> CMSampleBuffer? {
        let r = ImageRenderer(content: FloatingCaption(rows: rows, learn: look == "learn", note: note)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .environment(\.dynamicTypeSize, .xLarge))
        r.scale = 3
        guard let cg = r.cgImage else { return nil }
        return Self.sample(cg, at: at)
    }

    /// What the window shows now: Follow, the sentence before (quiet) and the one being heard (lit as it's said, its
    /// translation under it); Learn, two places taking turns, each sentence dissolving into its translation once heard.
    private func frame(at wall: Date = Date()) -> ([FloatingCaption.Row], String?) {
        guard let p = episode?.place, p < sentences.count else {
            return ([], hearing ? "Listening…" : paused ? "Listen is paused" : "Listen is off")
        }
        let two = config != nil, now = wall.timeIntervalSince1970 - lag
        func line(_ s: Sentence, said: Bool) -> TranscriptLine {
            // the window is drawn on the wall clock (its frames are scheduled by word onsets): words go back to it
            TranscriptLine(id: s.id, start: s.time, end: s.time, text: s.heard, words: anchor.map { $0.wall(s.words ?? []) } ?? s.words ?? [],
                           translation: said && two && !s.said.isEmpty ? s.said : nil)
        }
        if look == "learn" {
            let cur = sentences[p]
            return ((0..<2).compactMap { k -> FloatingCaption.Row? in
                let t = wall.timeIntervalSince(slots[k].since), old = t < 0.15
                guard let s = old ? slots[k].was : slots[k].now else { return nil }
                let a = old ? 1 - t / 0.15 : min(1, (t - 0.15) / 0.4)
                let turned = !two || s.said.isEmpty || s.id == cur.id ? 0 : old ? 1 : min(1, wall.timeIntervalSince(slots[k].heard ?? wall) / 0.3)
                let on = s.id == cur.id
                return FloatingCaption.Row(line: line(s, said: false), on: on, t: on ? now : nil, alpha: a, said: s.said.isEmpty ? nil : s.said, turned: turned)
            }, nil)
        }
        var rows: [FloatingCaption.Row] = []
        if p > 0 { rows.append(FloatingCaption.Row(line: line(sentences[p - 1], said: false), on: false, t: nil)) }
        rows.append(FloatingCaption.Row(line: line(sentences[p], said: true), on: true, t: now))
        let savedNote = wall.timeIntervalSince(savedNoteAt) < 2.5 ? "Note saved" : nil
        return (rows, savedNote)
    }

    /// The resting window: a thin dark strip (PiP sizes the window to the picture's shape).
    private static func restPicture() -> CMSampleBuffer? {
        guard let ctx = CGContext(data: nil, width: 1200, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.06, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 40))
        return ctx.makeImage().flatMap { sample($0) }
    }

    private static func sample(_ cg: CGImage, at: Double? = nil) -> CMSampleBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, cg.width, cg.height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: cg.width, height: cg.height, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        CVPixelBufferUnlockBaseAddress(pb, [])
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt)
        guard let fmt else { return nil }
        let pts = at.map { CMTime(seconds: $0, preferredTimescale: 1_000_000_000) } ?? CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb)
        if at == nil, let sb, let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(a) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(a, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}

extension Listener: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in Listener.shared.floatNote("iOS: will stop") }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in Listener.shared.floatNote("iOS: did stop") }
    }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError e: Error) {
        Task { @MainActor in
            let me = Listener.shared
            let n = e as NSError
            me.floatNote("iOS: failed to start (\(n.domain) \(n.code): \(n.localizedDescription))")
            if me.reshowTrying { me.learn(.refused) }   // iOS won't reopen it from behind: it stays open on pause from now
            else if me.reshowing { me.reshowing = false }   // iPad, active: tried again on the next play
            else { me.error = "The floating window didn't open: \(e.localizedDescription)" }
        }
    }
}

extension Listener: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in Listener.shared.hold(!playing) }
    }
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)  // live: no scrubber
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { Listener.held }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize s: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval i: CMTime) async {}
}

// the layer PiP draws from. PiP only starts from a layer that is really on screen: it sits behind Home's transcript
// (ListeningCard) and is the preview on Listen; leaving the app from either turns it into the floating window.
// (the layer's frame follows the view's layout; set from updateUIView it stayed 0×0, and PiP never became possible)
struct CaptionLayer: UIViewRepresentable {
    final class Host: UIView {
        // One host holds the layer: the last to come on screen. Until 11-10 Home's card and Listen's preview (both on
        // screen while Listen opens) took it from each other on every layout; each move resized it, PiP measured it
        // again and asked for another layout, and iOS's watchdog ended Recense (0x8BADF00D) before Listen showed.
        nonisolated(unsafe) static weak var owner: Host?
        nonisolated(unsafe) static let all = NSHashTable<Host>.weakObjects()

        override func layoutSubviews() {
            super.layoutSubviews()
            guard Host.owner === self else { return }
            let l = Listener.shared.layer
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if l.superlayer !== layer { layer.addSublayer(l) }
            if l.frame != bounds { l.frame = bounds }  // an unchanged frame set again still makes PiP measure again
            CATransaction.commit()
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            Host.all.add(self)
            if window != nil {
                Host.owner = self; setNeedsLayout(); Task { @MainActor in Listener.shared.makePiP() }
            } else if Host.owner === self {
                // leaving: the host still on screen (Home under a closing Listen) takes the layer back
                Host.owner = Host.all.allObjects.first { $0 !== self && $0.window != nil }
                Host.owner?.setNeedsLayout()
            }
        }
    }
    func makeUIView(context: Context) -> Host {
        let v = Host()
        v.backgroundColor = .black
        Listener.shared.layer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ v: Host, context: Context) { v.setNeedsLayout() }
}

struct ListenView: View {
    @ObservedObject var l = Listener.shared
    var title = "Listen"   // the guest app's one screen says "Now Playing"
    @State private var full = false
    @State private var clearing = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l.paused ? "Paused" : l.ear == .broadcast ? "Listening" : "Not hearing")
                        .font(.title3.bold())
                    Text("Hears whatever is playing in any app, on this device, then shows it in a window that floats over every app.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                // the one button (Listener.control, as on Home): Start, Pause (both ears, kept across launches), Resume
                if l.startsBroadcast {
                    StartBroadcast { Label(l.control.title, systemImage: l.control.symbol).font(.title3.weight(.semibold)).foregroundStyle(Theme.accent) }
                } else {
                    Button { l.control.act() } label: {
                        Label(l.control.title, systemImage: l.control.symbol).font(.title3.weight(.semibold))
                    }
                    .disabled(l.stopping)
                }
                // why nothing hears now: Start above is the one tap
                if l.prompting { Text(l.promptWhy).font(.subheadline).foregroundStyle(.secondary) }
                if let e = l.episode, l.hearing { LabeledContent("Now", value: e.title) }
                if let e = l.error { Text(e).font(.footnote).foregroundStyle(.blue) }
            } footer: {
                Text("Recense hears only what other apps play, never the room, and keeps only the text.")
            }
            Section {
                CaptionLayer().aspectRatio(640 / 300, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: Theme.artCorner, style: .continuous))
                    .listRowInsets(EdgeInsets())
                Picker("Look", selection: $l.look) {
                    Text("Follow").tag("follow")
                    Text("Learn").tag("learn")
                }.pickerStyle(.segmented)
            } footer: {
                Text("Leave Recense while something plays and this window floats over it; it hides when the sound pauses. \(l.pipState)")
            }
            Section {
                Picker("Hear in", selection: $l.heard) {
                    Text(Listener.name(Captions.automatic)).tag(Captions.automatic)
                    ForEach(l.hearable, id: \.identifier) { Text(Listener.name($0.identifier)).tag($0.identifier) }
                }
                Picker("Show in", selection: $l.into) {
                    ForEach(Listener.into, id: \.self) { Text(Listener.name($0)).tag($0) }
                }
                Toggle("Show Words Sooner (Less Accurate)", isOn: $l.sooner)
                Button { l.fetchAll() } label: { Label(l.fetching == nil ? "Download" : "Downloading…", systemImage: "arrow.down.circle") }
                    .disabled(l.fetching != nil)
            } header: { Text("Language") } footer: { Text([l.heard == Captions.automatic ? Listener.automaticNote : "", l.ears, l.pack, l.fetchNote].filter { !$0.isEmpty }.joined(separator: "\n")) }
            Section {
                Self.transcript(l, l.sentences, place: l.episode?.place, title: l.episode?.title ?? "Listen", live: true)
                    .frame(height: 420)
                    .listRowInsets(EdgeInsets())
            }
            if l.episodes.contains(where: { $0.key != l.episode?.key }) {
                Section("Episodes") {
                    ForEach(l.episodes.filter { $0.key != l.episode?.key }) { e in
                        // a view link, never NavigationLink(value:) + navigationDestination(for:): Library pushes Listen
                        // with a view link, and a value pushed onto that stack opened a second Listen instead of the
                        // episode (two Listens then fight over the one floating-window layer)
                        ListenEpisodeRow(e: e)
                        .swipeActions { Button("Delete") { l.delete(e) }.tint(.blue) }
                    }
                }
            }
        }
        .recenseScreen(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MoreMenu {
                    // Pause or Resume as the page's button says; Start is only the page's own button (StartBroadcast):
                    // a menu item can't hold the system's picker, and iOS ignores the picker tapped from code
                    if !l.startsBroadcast {
                        Button { l.control.act() } label: { Label(l.control.title.capitalized, systemImage: l.control.symbol) }
                            .disabled(l.stopping)
                    }
                    Button { full = true } label: { Label("Read Along Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
                    Button { clearing = true } label: { Label("Clear This Episode", systemImage: "trash") }.disabled(l.sentences.isEmpty)
                }
            }
        }
        .fullScreenCover(isPresented: $full) {
            NavigationStack {
                Self.transcript(l, l.sentences, place: l.episode?.place, title: l.episode?.title ?? "Listen", live: true)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(l.episode?.title ?? "").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { full = false } } }
            }
            .tint(Theme.accent)
        }
        .confirmationDialog("Clear what was heard in this episode?", isPresented: $clearing, titleVisibility: .visible) {
            Button("Clear") { l.clear() }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { l.allowSpeech() }
    }
}

extension ListenView {
    /// One past episode: its transcript, read only, with Now Playing in the ··· menu.
    static func episodePage(_ l: Listener, _ e: Episode) -> some View {
        transcript(l, e.sentences, place: e.place, title: e.title, live: false, two: e.heard.prefix(2) != e.into.prefix(2))
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(e.title).navigationBarTitleDisplayMode(.inline)
            .tint(Theme.accent)
            .toolbar { ToolbarItem(placement: .primaryAction) { MoreMenu { Button { l.choose(e.title) } label: { Label("Now Playing", systemImage: "play.circle") } } } }
    }

    /// What was heard, in the shared transcript view (ShowsKit's TranscriptView, the one Now Playing has): the
    /// sentence being heard bold, its words lit at the voice's pace (SpeechAnalyzer's times, `lag` behind), the
    /// translation under each line. Another app's audio can't be moved from here, so a line has no Play.
    static func transcript(_ l: Listener, _ ss: [Sentence], place: Int?, title: String, live: Bool, two: Bool? = nil) -> some View {
        // Show translation if iOS is configured for it, or if the Mac already wrote translations into the sentences.
        let two = two ?? (l.config != nil || ss.contains { !$0.said.isEmpty })
        let lines = ss.enumerated().map { (i, s) in
            // Give each line a real duration so the proportional-fallback highlight works between turns.
            let end = i + 1 < ss.count ? ss[i + 1].time : s.time + 15
            return TranscriptLine(id: s.id, start: s.time, end: end, text: s.heard, words: s.words ?? [],
                                  translation: two && !s.said.isEmpty ? s.said : nil)
        }
        // Lit by time only when something tells where the content is (FEAT-04): the broadcast's words, or the Mac's
        // player (Listener.contentNow). Old archived content has no clock: shown still, at its last place.
        let timed = live && l.contentNow() != nil
        // iOS broadcast → place index is exact; live Gallery → time drives it; archived → place (stale but stable).
        let activeOverride = l.hearing ? place.flatMap { lines.indices.contains($0) ? $0 : nil }
                           : (timed ? nil : place.flatMap { lines.indices.contains($0) ? $0 : nil })
        return TranscriptView(lines: lines, title: title, seed: title,
                              time: { timed ? l.contentNow() : nil }, ticking: timed,
                              active: activeOverride, seek: nil,
                              empty: live ? "What's heard shows up here." : "Nothing was heard.")
    }
}

/// Start listening as iOS accepts it: the system's broadcast picker lies under the finger, our label drawn over it.
/// iOS no longer opens the sheet for a picker tapped from code (11-10 probe on the iPhone: picker on screen, its
/// button found, sendActions sent, no sheet), so every Start the owner taps is this view.
struct StartBroadcast<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .overlay { PickerFill() }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
    }
}

/// The picker stretched over its label, nearly clear (UIKit still delivers touches at alpha 0.02, not under 0.01).
private struct PickerFill: UIViewRepresentable {
    final class Host: UIView {
        let picker = RPSystemBroadcastPickerView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "com.chauphan.galleryfiles") + ".broadcast"
            picker.showsMicrophoneButton = false
            picker.alpha = 0.02
            addSubview(picker)
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() {
            super.layoutSubviews()
            picker.frame = bounds
            picker.subviews.forEach { $0.frame = picker.bounds }  // its button, centred at 44 pt, fills the label
        }
    }
    func makeUIView(context: Context) -> Host { Host() }
    func updateUIView(_ v: Host, context: Context) { v.setNeedsLayout() }
}

// the system's start/stop broadcast button, preset to Gallery's extension so the sheet has one choice. Tapped from
// code (start(): the stop notification) it no longer opens the sheet on iOS 26+; StartBroadcast is the owner's Start.
struct BroadcastButton: UIViewRepresentable {
    nonisolated(unsafe) static weak var view: RPSystemBroadcastPickerView?
    static func tap() {
        (view?.subviews.first { $0 is UIButton } as? UIButton)?.sendActions(for: .allTouchEvents)
    }
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        BroadcastButton.view = v
        v.preferredExtension = (Bundle.main.bundleIdentifier ?? "com.chauphan.galleryfiles") + ".broadcast"
        v.showsMicrophoneButton = false
        return v
    }
    func updateUIView(_ v: RPSystemBroadcastPickerView, context: Context) {}
}

extension View {
    // translation stays alive wherever the user is in the app
    func listening() -> some View {
        modifier(Listening())
    }
}

private struct Listening: ViewModifier {
    @ObservedObject var l = Listener.shared
    func body(content: Content) -> some View {
        content
            // the system's broadcast button lives here, always in the window, so start() opens the sheet from any screen
            .background(BroadcastButton().frame(width: 1, height: 1).opacity(0.01))
            .translationTask(l.config) { await l.serve($0) }
            .translationTask(l.fetching) { await l.fetched($0) }
    }
}

// a tap on "Recense stopped hearing" opens the broadcast sheet (the one tap iOS requires); in front, Listen's own
// prompt shows instead of a banner
extension Listener: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        guard r.notification.request.identifier == "listen.stop" else { return }
        try? await Task.sleep(for: .milliseconds(600))  // Recense is in front by then
        await MainActor.run { Listener.shared.start() }
    }
    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        n.request.identifier == "listen.stop" ? [] : [.banner, .sound]
    }
}

/// One heard episode as a row that opens its transcript: Listen's Episodes and Home's Recently Played (a newer
/// listening bumps it there, owner 11-10). A view link, as every way into Listen's pages.
struct ListenEpisodeRow: View {
    let e: Episode
    var body: some View {
        NavigationLink { ListenView.episodePage(Listener.shared, e) } label: {
            HStack(spacing: 14) {
                Artwork(title: e.title, corner: 8, named: false).frame(width: 56, height: 56)
                    .overlay { Image(systemName: "captions.bubble").font(.title3).foregroundStyle(.white.opacity(0.9)) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(e.title).font(.title3).lineLimit(2)
                    Text("\(e.sentences.count) sentences · \(e.ear == "mic" ? "Microphone" : "Broadcast") · \(Date(timeIntervalSince1970: e.updated / 1000).formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
