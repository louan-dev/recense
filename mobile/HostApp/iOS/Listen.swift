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
import NaturalLanguage

struct Sentence: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var heard: String
    var said: String
    var at: Double  // about where in the episode, in seconds of listening (iOS can't see the other app's clock)
    var t: Double? = nil  // the episode's own time, when the Mac wrote it (Recense, handoff.swift)
    var words: [TranscriptWord]? = nil  // each word as SpeechAnalyzer timed it, in seconds since 1970 (the transcript lights them)
    var replays: Int? = nil  // how many times it was heard again (a rewind or a replay), never added twice (Align.swift)
    var time: Double { t ?? at }
}

// One episode's whole transcript, kept on the device (Documents/Listen/episodes/<key>.json) and in Gallery
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
    var ear: String? = nil   // what heard it: "broadcast" (another app's sound itself) or, later, "mic" (the room)
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

    @Published var on = Captions.state().on
    @Published var error: String?
    @Published var episode: Episode?
    @Published var episodes: [Episode] = []  // every one kept on this device, newest first
    @Published var heard = Captions.state().heard { didSet { var s = Captions.state(); s.heard = heard; Captions.put(s); retarget(); Task { await readyEars() } } }
    @Published var into = UserDefaults.standard.string(forKey: "listen.into") ?? "en" { didSet { UserDefaults.standard.set(into, forKey: "listen.into"); retarget() } }
    @Published var look = UserDefaults.standard.string(forKey: "listen.look") ?? "follow" { didSet { UserDefaults.standard.set(look, forKey: "listen.look"); draw() } }
    // Float: the window goes over other apps when Gallery is left. Dock: it stays in Gallery and doesn't follow.
    @Published var floats = UserDefaults.standard.object(forKey: "listen.floats") as? Bool ?? true {
        didSet { UserDefaults.standard.set(floats, forKey: "listen.floats"); pip?.canStartPictureInPictureAutomaticallyFromInline = floats }
    }
    @Published var config: TranslationSession.Configuration?
    // the translation pack (Apple Translation's on-device language models): said under the pickers, so a missing one
    // is never a silent blank (playbook rule 3). fetching: the pair being downloaded once, for offline use.
    @Published var pack = ""
    @Published var fetching: TranslationSession.Configuration?
    private var toFetch: [(String, String)] = []
    static let missing = "not translated (pack missing)"
    var sentences: [Sentence] { episode?.sentences ?? [] }

    let layer = AVSampleBufferDisplayLayer()
    private var pip: AVPictureInPictureController?
    private var lines: [Int: String] = [:]       // what the extension heard, one entry per recognition request
    private var lineWords: [Int: [TranscriptWord]] = [:]  // its words, timed (SpeechAnalyzer), in seconds since 1970
    // how far the words arrive behind the voice: the transcript lights each word this long after it was said, at the
    // voice's own pace (live captions can't be ahead of what they heard)
    @Published var lag = 1.5
    private var skip: [Int: Int] = [:]           // sentences of a request that belong to the episode before
    private var map: [String: String] = [:]      // "request.sentence" → the episode sentence it is (or matched)
    private var added: Set<String> = []          // episode sentences this listening added (not matched to older ones)
    private var said: [String: String] = [:]     // translations by the text they were made from
    private var pending: [String] = []
    private var wake: CheckedContinuation<Void, Never>?
    private let engine = AVAudioEngine()
    private var last: Captions.Line?
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
        Captions.observe(Captions.changed) { [weak self] in if let l = Captions.line() { self?.take(l) } }
        Captions.observe(Captions.stateChanged) { [weak self] in self?.stateChanged() }
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
                if let l = Captions.line(), l != me.last { me.take(l) }
            }
        }
        // kept on the device every 10 s while it changes, sent to Gallery every minute
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in Task { @MainActor in Listener.shared.catchUp(); Listener.shared.save() } }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Listener.shared.catchUp() }
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in
            let me = Listener.shared
            await me.upload()
            if let k = me.episode?.key { await me.fetch(k) }
        } }
    }

    // a silent sound mixed under whatever is playing keeps the app running behind the other app (UIBackgroundModes
    // audio), so it can take lines from the extension, translate them and redraw the floating window
    private func keepAwake(_ on: Bool) {
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
        ears = Self.legacyEars(heard)
    }

    /// "en_US" (the device's locale) and "en-US" (the recognizer's) are one language: the picker shows it chosen.
    private func matchHeard() {
        if !hearable.contains(where: { $0.identifier == heard }),
           let same = hearable.first(where: { $0.identifier(.bcp47) == Locale(identifier: heard).identifier(.bcp47) }) { heard = same.identifier }
    }

    /// The chosen language's SpeechAnalyzer model, downloaded once (the one moment Listen needs a connection) so the
    /// broadcast extension finds it on the device; said in a line under the picker.
    func readyEars() async {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            let id = heard
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
        ears = Self.legacyEars(heard)
    }
    static func legacyEars(_ id: String) -> String {
        SFSpeechRecognizer(locale: Locale(identifier: id))?.supportsOnDeviceRecognition == true
            ? "Heard on this device by SFSpeechRecognizer (no word times)." : "This device can't hear \(name(id)) offline."
    }
    static let into = ["en", "vi", "fr"]  // Recense's tr/en|vi|fr
    static func name(_ id: String) -> String { Locale.current.localizedString(forIdentifier: id) ?? id }

    private func stateChanged() {
        let s = Captions.state()
        error = s.error
        if s.live != on {
            on = s.live
            stopping = false
            catchUp()  // the end of the broadcast before, if the app missed it
            if on {
                lines = [:]; lineWords = [:]; skip = [:]; map = [:]; added = []; lastMatch = nil; replayedNow = []
                fresh()  // every broadcast starts its own; Align joins it to an older one when the content continues
                if floats { startPiP() } else { keepAwake(true) }
            } else {
                save(); Task { await upload() }
                Listener.held = false; pip?.stopPictureInPicture(); keepAwake(false)
            }
        }
    }

    @Published var stopping = false
    // the extension ends its own broadcast when it sees this (within 2 s); the app can't end it otherwise
    /// Start listening: the floating window gets ready and the system's Start Broadcast sheet opens (the one tap
    /// iOS requires before another app's sound reaches Recense).
    func start() {
        startPiP()
        Task { try? await Task.sleep(for: .milliseconds(300)); BroadcastButton.tap() }
    }

    func stop() {
        var s = Captions.state()
        s.stop = true
        Captions.put(s)
        stopping = true
    }

    // MARK: episodes

    private static var folder: URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Listen/episodes", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func loadEpisodes() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        episodes = files.compactMap { try? JSONDecoder().decode(Episode.self, from: Data(contentsOf: $0)) }.sorted { $0.updated > $1.updated }
    }

    private func save() {
        guard dirty, let e = episode else { return }
        dirty = false
        try? JSONEncoder().encode(e).write(to: Self.folder.appendingPathComponent(e.key + ".json"), options: .atomic)
        episodes.removeAll { $0.key == e.key }
        episodes.insert(e, at: 0)
        unsent.insert(e.key)
    }
    private var unsent: Set<String> = []

    // what's playing now: the episode before is kept as it is (where it was, all it heard) and leaves Read along;
    // this one comes in with all it heard before, open where it was left. Gallery's copy is taken if newer.
    /// A new episode, named by when it began and what it's heard in ("9 Nov 2026 at 21:40 · French"): nothing to
    /// choose or type. If what plays turns out to continue an older episode, adoptIfResumed() moves it there.
    func fresh() {
        lastLineAt = Date()
        choose(Date().formatted(date: .abbreviated, time: .shortened) + " · " + Self.name(heard))
        episode?.ear = "broadcast"
    }

    func choose(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        save()
        if let e = episode, unsent.contains(e.key) { let copy = e; Task { await send(copy) } }
        let key = Episode.key(t)
        episode = episodes.first { $0.key == key } ?? Episode(key: key, title: t, heard: heard, into: into, updated: Date().timeIntervalSince1970 * 1000)
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
        let from = Locale.Language(identifier: heard), to = Locale.Language(identifier: into)
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
    static let stops: Set<Character> = [".", "?", "!", "…", "。", "？", "！", "؟", "።", "፧", "།", "॥", "।"]
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
    static func timed(_ text: String, _ words: [TranscriptWord]) -> [[TranscriptWord]] {
        let sents = split(text)
        var spans: [Range<String.Index>] = [], cur = text.startIndex
        for s in sents {
            if let r = text.range(of: s, range: cur..<text.endIndex) { spans.append(r); cur = r.upperBound } else { spans.append(cur..<cur) }
        }
        var out = Array(repeating: [TranscriptWord](), count: sents.count)
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
        let after = lastMatch.flatMap { id in e.sentences.firstIndex { $0.id == id } }
        let not = besides.flatMap { id in e.sentences.firstIndex { $0.id == id } }
        return Align.match(text, in: e.sentences.map(\.heard), place: e.place, after: after, besides: not)
    }
    private var lastMatch: String?             // the sentence placed last (a short one is only known right after it)
    private var replayedNow: Set<String> = []  // sentences counted as replayed in this listening

    /// A sentence heard before, cut short then (the content was left mid-sentence), is kept whole now.
    private func complete(_ i: Int, _ text: String, _ ws: [TranscriptWord]?) {
        let old = episode!.sentences[i].heard
        guard let end = old.trimmingCharacters(in: .whitespaces).last, !Self.stops.contains(end), Align.completes(text, old) else { return }
        episode!.sentences[i].heard = text
        if let ws { episode!.sentences[i].words = ws }
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
            map = [:]; added = []; lastMatch = nil
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
            for (k, text) in Self.split(lines[n] ?? "").enumerated() where k >= skip[n, default: 0] {
                let ws = timed.flatMap { k < $0.count && !$0[k].isEmpty ? $0[k] : nil }
                let lid = "\(n).\(k)"
                if let sid = map[lid], let i = episode!.sentences.firstIndex(where: { $0.id == sid }) {
                    guard episode!.sentences[i].heard != text else { continue }
                    guard added.contains(sid) else { complete(i, text, ws); continue }
                    // it grew: if it is now plainly one heard before, use that one and drop the copy
                    if let j = match(text, besides: sid) {
                        let keep = episode!.sentences[j].id
                        episode!.sentences.remove(at: i)
                        added.remove(sid); map[lid] = keep; lastMatch = keep
                        episode!.place = episode!.sentences.firstIndex { $0.id == keep } ?? episode!.place
                    } else {
                        episode!.sentences[i].heard = text
                        if let ws { episode!.sentences[i].words = ws }
                        episode!.sentences[i].said = config == nil ? text : said[text] ?? episode!.sentences[i].said
                        translate(text)
                    }
                    touch()
                } else if let j = match(text) {
                    let sid = episode!.sentences[j].id
                    map[lid] = sid
                    episode!.place = j
                    lastMatch = sid
                    if !replayedNow.contains(sid) { replayedNow.insert(sid); episode!.sentences[j].replays = (episode!.sentences[j].replays ?? 0) + 1 }
                    complete(j, text, ws)
                    lastHeard = Date()
                    touch()
                } else {
                    // new: goes after where the user is, and becomes where they are
                    let at = episode!.sentences.isEmpty ? 0 : episode!.place + 1
                    let prev = at > 0 ? episode!.sentences[at - 1].at : 0
                    let s = Sentence(id: UUID().uuidString.prefix(12).lowercased(), heard: text, said: config == nil ? text : said[text] ?? "",
                                     at: prev + min(30, Date().timeIntervalSince(lastHeard)), words: ws)
                    episode!.sentences.insert(s, at: min(at, episode!.sentences.count))
                    episode!.place = min(at, episode!.sentences.count - 1)
                    map[lid] = s.id; added.insert(s.id); lastMatch = s.id
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
        if on, l != last, Date().timeIntervalSince(lastLineAt) > 180, !added.isEmpty { fresh() }
        lastLineAt = Date()
        last = l
        lines[l.n] = l.text
        if let ws = l.words, let t0 = l.t0 {
            lineWords[l.n] = ws.map { TranscriptWord(text: $0.text, start: t0 + $0.start, end: t0 + $0.end) }
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
        case .supported: pack = "Translation \(names): needs a one-time download. Tap Download for offline."
        case .unsupported: pack = "Translation \(names) isn't available on this device."
        @unknown default: pack = ""
        }
    }

    /// Downloads English, Vietnamese and French for every direction between them, once, while the app is open (iOS
    /// asks before each download). Afterwards translation needs no connection.
    func fetchAll() {
        toFetch = []
        for a in Self.into { for b in Self.into where a != b { toFetch.append((a, b)) } }
        fetchNext()
    }
    private func fetchNext() {
        guard !toFetch.isEmpty else {
            fetching = nil
            // what said "pack missing" is translated again now
            if episode != nil { for i in episode!.sentences.indices where episode!.sentences[i].said == Self.missing { episode!.sentences[i].said = "" } }
            said = [:]; rebuild()
            Task { await checkPack() }
            return
        }
        let (a, b) = toFetch.removeFirst()
        fetching = .init(source: .init(identifier: a), target: .init(identifier: b))
    }
    func fetched(_ session: TranslationSession) async {
        try? await session.prepareTranslation()
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
        p.canStartPictureInPictureAutomaticallyFromInline = floats
        p.requiresLinearPlayback = true
        pip = p
        pipObs = p.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { _, _ in Task { @MainActor in Listener.shared.pipNote() } }
        pipActive = p.observe(\.isPictureInPictureActive, options: [.new]) { _, _ in Task { @MainActor in Listener.shared.pipNote() } }
        draw()
        // a still frame goes stale for PiP; draw again each second
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in Listener.shared.draw() } }
    }
    private var pipObs: NSKeyValueObservation?
    private var pipActive: NSKeyValueObservation?
    @Published var pipState = ""
    func pipNote() {
        guard let pip else { pipState = "Floating window: not supported here"; return }
        pipState = pip.isPictureInPictureActive ? "Floating window: open" : pip.isPictureInPicturePossible ? "Floating window: ready" : "Floating window: not ready"
    }

    // Float puts the window over other apps now and whenever Gallery is left; Dock brings it back into Gallery
    func float() { floats = true; startPiP() }
    func dock() { floats = false; pip?.stopPictureInPicture() }

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

    // the last word, by the language's own word breaks (Chinese, Thai, Tibetan have no spaces), with what trails it
    static func lastWord(_ text: String) -> Range<String.Index>? {
        let t = NLTokenizer(unit: .word); t.string = text
        var last: Range<String.Index>?
        t.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in last = r; return true }
        return last.map { $0.lowerBound..<text.endIndex } ?? text.range(of: #"\S+$"#, options: .regularExpression)
    }

    static let lit = UIColor(red: 1, green: 0.84, blue: 0.2, alpha: 1)  // the word being heard, Recense's yellow (Overlay.current)

    // the sentence with its newest word lit, as Recense's light follows the voice
    static func karaoke(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor, lit on: Bool, alpha: CGFloat = 1, center: Bool = true) -> NSAttributedString {
        let style = NSMutableParagraphStyle(); style.alignment = center ? .center : .natural; style.baseWritingDirection = .natural; style.lineBreakMode = .byWordWrapping
        let a = NSMutableAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color.withAlphaComponent(alpha), .paragraphStyle: style])
        if on, let r = lastWord(text) { a.addAttribute(.foregroundColor, value: lit.withAlphaComponent(alpha), range: NSRange(r, in: text)) }
        return a
    }

    // the floating window's middle button: holds the words where they are (Listen keeps hearing; play shows the newest)
    nonisolated(unsafe) static var held = false
    func hold(_ on: Bool) {
        Listener.held = on
        pip?.invalidatePlaybackState()
        if !on { draw() }
    }

    func draw() {
        if Listener.held { return }
        let size = CGSize(width: 640, height: 300), w = size.width - 40
        let img = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { c in
            UIColor(white: 0.04, alpha: 1).setFill(); c.fill(CGRect(origin: .zero, size: size))  // Recense's panel
            // draws s so its last line sits on box's bottom (older lines go up and off the top) or centred in box
            func put(_ s: NSAttributedString, in box: CGRect, bottom: Bool = true) {
                let h = ceil(s.boundingRect(with: CGSize(width: w, height: 5000), options: .usesLineFragmentOrigin, context: nil).height)
                let y = bottom || h > box.height ? box.maxY - h : box.midY - h / 2
                c.cgContext.saveGState(); c.cgContext.clip(to: box)
                s.draw(with: CGRect(x: box.minX, y: y, width: w, height: h), options: .usesLineFragmentOrigin, context: nil)
                c.cgContext.restoreGState()
            }
            guard let p = episode?.place, p < sentences.count else {
                put(Self.karaoke(on ? "Listening…" : "Listen is off", size: 34, weight: .medium, color: .gray, lit: false), in: CGRect(x: 20, y: 0, width: w, height: size.height), bottom: false)
                return
            }
            let cur = sentences[p], two = config != nil
            if look == "learn" {
                // two places taking turns; each sentence starts in the language heard, the light on its newest word,
                // and once heard dissolves into its translation in the same place (website Learn: fade out 0.15 s,
                // fade in 0.4 s, turn 0.3 s)
                for k in 0..<2 {
                    let box = CGRect(x: 20, y: k == 0 ? 12 : size.height / 2 + 6, width: w, height: size.height / 2 - 18)
                    let t = Date().timeIntervalSince(slots[k].since)
                    let old = t < 0.15
                    let (s, a): (Sentence?, CGFloat) = old ? (slots[k].was, 1 - t / 0.15) : (slots[k].now, min(1, (t - 0.15) / 0.4))
                    guard let s else { continue }
                    // the was-sentence leaving had been heard; the current one turns once heard, if there is a translation
                    let turned: CGFloat = !two || s.said.isEmpty || s.id == cur.id ? 0
                        : old ? 1 : min(1, Date().timeIntervalSince(slots[k].heard ?? Date()) / 0.3)
                    if turned < 1 { put(Self.karaoke(s.heard, size: 28, weight: .semibold, color: .white, lit: s.id == cur.id, alpha: a * (1 - turned)), in: box, bottom: false) }
                    if turned > 0 { put(Self.karaoke(s.said, size: 28, weight: .regular, color: UIColor(white: 1, alpha: 0.8), lit: false, alpha: a * turned), in: box, bottom: false) }
                }
            } else {
                // Follow: the sentence being heard on top, what it says below, both with the newest word lit
                if two {
                    // as Recense: the heard words semibold white, what they say a step quieter (regular, 80 %)
                    put(Self.karaoke(cur.heard, size: 27, weight: .semibold, color: .white, lit: true), in: CGRect(x: 20, y: 12, width: w, height: 126))
                    put(Self.karaoke(cur.said.isEmpty ? "…" : cur.said, size: 24, weight: .regular, color: UIColor(white: 1, alpha: 0.8), lit: true), in: CGRect(x: 20, y: 152, width: w, height: 136))
                } else {
                    put(Self.karaoke(cur.heard, size: 32, weight: .semibold, color: .white, lit: true), in: CGRect(x: 20, y: 12, width: w, height: size.height - 24))
                }
            }
        }
        guard let cg = img.cgImage, let sb = Self.sample(cg) else { return }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sb)
    }

    private static func sample(_ cg: CGImage) -> CMSampleBuffer? {
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
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb)
        if let sb, let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(a) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(a, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}

extension Listener: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError e: Error) {
        Task { @MainActor in Listener.shared.error = "The floating window didn't open: \(e.localizedDescription)" }
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

// the layer PiP draws from. PiP only starts from a layer that is really on screen, so it is the preview on the
// Listen screen; leaving the app from there (home, another app) turns it into the floating window.
// (the layer's frame follows the view's layout; set from updateUIView it stayed 0×0, and PiP never became possible)
struct CaptionLayer: UIViewRepresentable {
    final class Host: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            let l = Listener.shared.layer
            if l.superlayer !== layer { layer.addSublayer(l) }
            l.frame = bounds
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { Task { @MainActor in Listener.shared.makePiP() } }
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
    @State private var full = false
    @State private var clearing = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l.on ? "Listening" : "Off").font(.title3.bold())
                    Text("Hears whatever is playing in any app, on this device, then shows it in a window that floats over every app.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                // Start opens the system's Start Broadcast sheet at once (iOS's own button can draw as nothing, so a
                // real button taps it); nothing to choose: episodes name themselves. Stop tells the extension to end it.
                Button {
                    if l.on { l.stop() } else { l.start() }
                } label: {
                    Label(l.stopping ? "Stopping…" : l.on ? "Stop listening" : "Start listening", systemImage: l.on ? "stop.circle.fill" : "record.circle")
                        .font(.title3.weight(.semibold))
                }
                .disabled(l.stopping)
                .background(BroadcastButton().frame(width: 1, height: 1).opacity(0.01))
                if let e = l.episode, l.on { LabeledContent("Now", value: e.title) }
                if let e = l.error { Text(e).font(.footnote).foregroundStyle(.blue) }
            }
            Section {
                CaptionLayer().aspectRatio(640 / 300, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: Theme.artCorner, style: .continuous))
                    .listRowInsets(EdgeInsets())
                Picker("Look", selection: $l.look) {
                    Text("Follow").tag("follow")
                    Text("Learn").tag("learn")
                }.pickerStyle(.segmented)
                if l.floats {
                    Button { l.dock() } label: { Label("Dock in Recense", systemImage: "pip.enter") }
                } else {
                    Button { l.float() } label: { Label("Float over apps", systemImage: "pip.exit") }
                }
            } footer: {
                Text(l.floats ? "Floats: leave Recense and the window stays on top of other apps. \(l.pipState)"
                              : "Docked: the window stays here in Recense and doesn't follow you out.")
            }
            Section {
                Picker("Hear in", selection: $l.heard) {
                    ForEach(l.hearable, id: \.identifier) { Text(Listener.name($0.identifier)).tag($0.identifier) }
                }
                Picker("Show in", selection: $l.into) {
                    ForEach(Listener.into, id: \.self) { Text(Listener.name($0)).tag($0) }
                }
                Button { l.fetchAll() } label: { Label(l.fetching == nil ? "Download for offline" : "Downloading…", systemImage: "arrow.down.circle") }
                    .disabled(l.fetching != nil)
            } header: { Text("Language") } footer: { Text([l.ears, l.pack].filter { !$0.isEmpty }.joined(separator: "\n")) }
            Section {
                Self.transcript(l, l.sentences, place: l.episode?.place, title: l.episode?.title ?? "Listen", live: true)
                    .frame(height: 420)
                    .listRowInsets(EdgeInsets())
            }
            if l.episodes.contains(where: { $0.key != l.episode?.key }) {
                Section("Episodes") {
                    ForEach(l.episodes.filter { $0.key != l.episode?.key }) { e in
                        NavigationLink(value: e) {
                            HStack(spacing: 14) {
                                Artwork(title: e.title, corner: 8, named: false).frame(width: 56, height: 56)
                                    .overlay { Image(systemName: "captions.bubble").font(.title3).foregroundStyle(.white.opacity(0.9)) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(e.title).font(.title3).lineLimit(2)
                                    Text("\(e.sentences.count) sentences · \(Date(timeIntervalSince1970: e.updated / 1000).formatted(date: .abbreviated, time: .shortened))")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions { Button("Delete") { l.delete(e) }.tint(.blue) }
                    }
                }
            }
        }
        .recenseScreen("Listen")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MoreMenu {
                    Button { if l.on { l.stop() } else { l.start() } } label: {
                        Label(l.on ? "Stop Listening" : "Start Listening", systemImage: l.on ? "stop.circle" : "record.circle")
                    }.disabled(l.stopping)
                    if l.floats { Button { l.dock() } label: { Label("Dock in Recense", systemImage: "pip.enter") } }
                    else { Button { l.float() } label: { Label("Float over Apps", systemImage: "pip.exit") } }
                    Button { full = true } label: { Label("Read Along Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
                    Button { clearing = true } label: { Label("Clear This Episode", systemImage: "trash") }.disabled(l.sentences.isEmpty)
                }
            }
        }
        .navigationDestination(for: Episode.self) { e in
            Self.transcript(l, e.sentences, place: e.place, title: e.title, live: false, two: e.heard.prefix(2) != e.into.prefix(2))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(e.title).navigationBarTitleDisplayMode(.inline)
                .tint(Theme.accent)
                .toolbar { ToolbarItem(placement: .primaryAction) { MoreMenu { Button { l.choose(e.title) } label: { Label("Now Playing", systemImage: "play.circle") } } } }
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
    /// What was heard, in the shared transcript view (ShowsKit's TranscriptView, the one Now Playing has): the
    /// sentence being heard bold, its words lit at the voice's pace (SpeechAnalyzer's times, `lag` behind), the
    /// translation under each line. Another app's audio can't be moved from here, so a line has no Play.
    static func transcript(_ l: Listener, _ ss: [Sentence], place: Int?, title: String, live: Bool, two: Bool? = nil) -> some View {
        let two = two ?? (l.config != nil)
        let lines = ss.map { s in
            TranscriptLine(id: s.id, start: s.time, end: s.time, text: s.heard, words: s.words ?? [],
                           translation: two && !s.said.isEmpty ? s.said : nil)
        }
        return TranscriptView(lines: lines, title: title, seed: title,
                              time: { live && l.on ? Date().timeIntervalSince1970 - l.lag : nil }, ticking: live && l.on,
                              active: place.flatMap { lines.indices.contains($0) ? $0 : nil }, seek: nil,
                              empty: live ? "What's heard shows up here." : "Nothing was heard.")
    }
}

// the system's start/stop broadcast button, preset to Gallery's extension so the sheet has one choice
struct BroadcastButton: UIViewRepresentable {
    nonisolated(unsafe) static weak var view: RPSystemBroadcastPickerView?
    static func tap() {
        (view?.subviews.first { $0 is UIButton } as? UIButton)?.sendActions(for: .allTouchEvents)
    }
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        BroadcastButton.view = v
        v.preferredExtension = "com.chauphan.galleryfiles.broadcast"
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
            .translationTask(l.config) { await l.serve($0) }
            .translationTask(l.fetching) { await l.fetched($0) }
    }
}
