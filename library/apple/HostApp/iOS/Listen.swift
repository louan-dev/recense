// Listen (notes item 31): Recense on the iPhone and iPad. The broadcast extension (ios/Broadcast) hears whatever is
// playing in any app, on the device, in its own language; here it is cut into sentences, each translated into the
// chosen language (Apple's on-device Translation, as Recense does), and drawn into a Picture in Picture window, the
// floating window that stays over every app until Listen is turned off. Two looks, as on the Mac: Follow (the
// sentence and its translation, the newest word lit) and Learn (two sentences, top and bottom, taking turns).
// In the app: Read along (Spotify's look) with Copy, Clear and full screen. What's heard is kept per episode (the
// user says what's playing; iOS can't see other apps), so going back to one opens where it was left (Episode).
import SwiftUI
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
    @Published var heard = Captions.state().heard { didSet { var s = Captions.state(); s.heard = heard; Captions.put(s); retarget() } }
    @Published var into = UserDefaults.standard.string(forKey: "listen.into") ?? "en" { didSet { UserDefaults.standard.set(into, forKey: "listen.into"); retarget() } }
    @Published var look = UserDefaults.standard.string(forKey: "listen.look") ?? "follow" { didSet { UserDefaults.standard.set(look, forKey: "listen.look"); draw() } }
    // Float: the window goes over other apps when Gallery is left. Dock: it stays in Gallery and doesn't follow.
    @Published var floats = UserDefaults.standard.object(forKey: "listen.floats") as? Bool ?? true {
        didSet { UserDefaults.standard.set(floats, forKey: "listen.floats"); pip?.canStartPictureInPictureAutomaticallyFromInline = floats }
    }
    @Published var config: TranslationSession.Configuration?
    var sentences: [Sentence] { episode?.sentences ?? [] }

    let layer = AVSampleBufferDisplayLayer()
    private var pip: AVPictureInPictureController?
    private var lines: [Int: String] = [:]       // what the extension heard, one entry per recognition request
    private var skip: [Int: Int] = [:]           // sentences of a request that belong to the episode before
    private var map: [String: String] = [:]      // "request.sentence" → the episode sentence it is (or matched)
    private var added: Set<String> = []          // episode sentences this listening added (not matched to older ones)
    private var said: [String: String] = [:]     // translations by the text they were made from
    private var pending: [String] = []
    private var wake: CheckedContinuation<Void, Never>?
    private let engine = AVAudioEngine()
    private var last: Captions.Line?
    private var lastHeard = Date()
    private var dirty = false

    override init() {
        super.init()
        Captions.observe(Captions.changed) { [weak self] in if let l = Captions.line() { self?.take(l) } }
        Captions.observe(Captions.stateChanged) { [weak self] in self?.stateChanged() }
        loadEpisodes()
        if let k = UserDefaults.standard.string(forKey: "listen.episode") { episode = episodes.first { $0.key == k } }
        retarget()
        draw()
        // Darwin notifications can be missed while the app is between states: also look twice a second
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                let me = Listener.shared
                if Captions.state().live != me.on || Captions.state().error != me.error { me.stateChanged() }
                if let l = Captions.line(), l != me.last { me.take(l) }
            }
        }
        // kept on the device every 10 s while it changes, sent to Gallery every minute
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in Task { @MainActor in Listener.shared.save() } }
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

    func allowSpeech() { SFSpeechRecognizer.requestAuthorization { _ in } }

    // the languages this device can hear without sending audio anywhere
    static let hearable: [Locale] = SFSpeechRecognizer.supportedLocales()
        .filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
        .sorted { name($0.identifier) < name($1.identifier) }
    static let into = ["en", "vi", "fr"]  // Recense's tr/en|vi|fr
    static func name(_ id: String) -> String { Locale.current.localizedString(forIdentifier: id) ?? id }

    private func stateChanged() {
        let s = Captions.state()
        error = s.error
        if s.live != on {
            on = s.live
            stopping = false
            if on {
                lines = [:]; skip = [:]; map = [:]; added = []
                if episode == nil { choose(Date().formatted(date: .abbreviated, time: .shortened)) }
                if floats { startPiP() } else { keepAwake(true) }
            } else {
                save(); Task { await upload() }
                Listener.held = false; pip?.stopPictureInPicture(); keepAwake(false)
            }
        }
    }

    @Published var stopping = false
    // the extension ends its own broadcast when it sees this (within 2 s); the app can't end it otherwise
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
            let w = Self.words(ours.sentences[ours.place].heard)
            if let j = theirs.sentences.indices.max(by: { Self.overlap(w, Self.words(theirs.sentences[$0].heard)) < Self.overlap(w, Self.words(theirs.sentences[$1].heard)) }),
               Self.overlap(w, Self.words(theirs.sentences[j].heard)) >= 0.6 { theirs.place = j }
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

    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        a.isEmpty || b.isEmpty ? 0 : Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }

    // the index of every episode in Gallery (the Mac's too), for the picker
    @Published var everywhere: [(key: String, title: String)] = []
    func fetchIndex() async {
        guard let r = request(""), let (d, res) = try? await URLSession.shared.data(for: r), (res as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let eps = j["episodes"] as? [String: [String: Any]] else { return }
        everywhere = eps.compactMap { k, v in (v["title"] as? String).map { (k, $0) } }
            .sorted { (eps[$0.key]?["updated"] as? Double ?? 0) > (eps[$1.key]?["updated"] as? Double ?? 0) }
    }

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 })
    }

    // is this sentence one the episode already has (the user went back, or played it again)? the closest to where
    // they are wins when several are alike
    private func match(_ text: String, besides: String? = nil) -> Int? {
        guard let e = episode else { return nil }
        let w = Self.words(text)
        guard w.count >= 4 else { return nil }
        var best: (i: Int, score: Double)?
        for (i, s) in e.sentences.enumerated() where s.id != besides {
            let o = Self.words(s.heard)
            let score = Double(w.intersection(o).count) / Double(max(1, min(w.count, o.count)))
            if score >= 0.7, best == nil || score > best!.score || (score == best!.score && abs(i - e.place) < abs(best!.i - e.place)) { best = (i, score) }
        }
        return best?.i
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
            for (k, text) in Self.split(lines[n] ?? "").enumerated() where k >= skip[n, default: 0] {
                let lid = "\(n).\(k)"
                if let sid = map[lid], let i = episode!.sentences.firstIndex(where: { $0.id == sid }) {
                    guard episode!.sentences[i].heard != text, added.contains(sid) else { continue }
                    // it grew: if it is now plainly one heard before, use that one and drop the copy
                    if let j = match(text, besides: sid) {
                        let keep = episode!.sentences[j].id
                        episode!.sentences.remove(at: i)
                        added.remove(sid); map[lid] = keep
                        episode!.place = episode!.sentences.firstIndex { $0.id == keep } ?? episode!.place
                    } else {
                        episode!.sentences[i].heard = text
                        episode!.sentences[i].said = config == nil ? text : said[text] ?? episode!.sentences[i].said
                        translate(text)
                    }
                    touch()
                } else if let j = match(text) {
                    map[lid] = episode!.sentences[j].id
                    episode!.place = j
                    lastHeard = Date()
                    touch()
                } else {
                    // new: goes after where the user is, and becomes where they are
                    let at = episode!.sentences.isEmpty ? 0 : episode!.place + 1
                    let prev = at > 0 ? episode!.sentences[at - 1].at : 0
                    let s = Sentence(id: UUID().uuidString.prefix(12).lowercased(), heard: text, said: config == nil ? text : said[text] ?? "",
                                     at: prev + min(30, Date().timeIntervalSince(lastHeard)))
                    episode!.sentences.insert(s, at: min(at, episode!.sentences.count))
                    episode!.place = min(at, episode!.sentences.count - 1)
                    map[lid] = s.id; added.insert(s.id)
                    lastHeard = Date()
                    translate(text)
                    touch()
                }
            }
        }
        // sentences translated before this app run, or into another language, get done as they come into view
        if let e = episode, config != nil {
            for s in e.sentences[max(0, e.place - 3)..<min(e.sentences.count, e.place + 4)] where s.said.isEmpty { translate(s.heard) }
        }
        changed()
    }

    private func take(_ l: Captions.Line) {
        last = l
        lines[l.n] = l.text
        rebuild()
    }

    func serve(_ session: TranslationSession) async {
        try? await session.prepareTranslation()
        while !Task.isCancelled {
            if pending.isEmpty { await withCheckedContinuation { wake = $0 } }
            guard !pending.isEmpty else { continue }
            let text = pending.removeFirst()
            guard let r = try? await session.translate(text) else { continue }
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
    @State private var picking = false
    @State private var startAfterPick = false
    @State private var clearing = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l.on ? "Listening" : "Off").font(.headline)
                    Text("Hears whatever is playing in any app, on this device, then shows it in a window that floats over every app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                // Start asks what's playing, then opens the system's Start Broadcast sheet (its own button can draw as
                // nothing, so a real button taps it); Stop tells the extension to end the broadcast, no sheet
                Button {
                    if l.on { l.stop() } else { startAfterPick = true; picking = true }
                } label: {
                    Label(l.stopping ? "Stopping…" : l.on ? "Stop listening" : "Start listening", systemImage: l.on ? "stop.circle" : "record.circle")
                }
                .disabled(l.stopping)
                .background(BroadcastButton().frame(width: 1, height: 1).opacity(0.01))
                Button { startAfterPick = false; picking = true } label: {
                    LabeledContent("Playing", value: l.episode?.title ?? "Choose…")
                }
                .foregroundStyle(.primary)
                if let e = l.error { Text(e).font(.footnote).foregroundStyle(.blue) }
            }
            Section {
                CaptionLayer().aspectRatio(640 / 300, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10))
                    .listRowInsets(EdgeInsets())
                Picker("Look", selection: $l.look) {
                    Text("Follow").tag("follow")
                    Text("Learn").tag("learn")
                }.pickerStyle(.segmented)
                if l.floats {
                    Button { l.dock() } label: { Label("Dock in Gallery", systemImage: "pip.enter") }
                } else {
                    Button { l.float() } label: { Label("Float over apps", systemImage: "pip.exit") }
                }
            } footer: {
                Text(l.floats ? "Floats: leave Gallery and the window stays on top of other apps. \(l.pipState)"
                              : "Docked: the window stays here in Gallery and doesn't follow you out.")
            }
            Section("Language") {
                Picker("Hear in", selection: $l.heard) {
                    ForEach(Listener.hearable, id: \.identifier) { Text(Listener.name($0.identifier)).tag($0.identifier) }
                }
                Picker("Show in", selection: $l.into) {
                    ForEach(Listener.into, id: \.self) { Text(Listener.name($0)).tag($0) }
                }
            }
            Section {
                ReadAlong(sentences: l.sentences, place: l.episode?.place, live: true, two: l.config != nil,
                          expand: { full = true }, clear: { clearing = true })
                    .frame(height: 380)
                    .listRowInsets(EdgeInsets())
            }
            if l.episodes.contains(where: { $0.key != l.episode?.key }) {
                Section("Episodes") {
                    ForEach(l.episodes.filter { $0.key != l.episode?.key }) { e in
                        NavigationLink(value: e) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title).lineLimit(1)
                                Text("\(e.sentences.count) sentences · \(Date(timeIntervalSince1970: e.updated / 1000).formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions { Button("Delete") { l.delete(e) }.tint(.blue) }
                    }
                }
            }
        }
        .navigationTitle("Listen")
        .navigationDestination(for: Episode.self) { e in
            ReadAlong(sentences: e.sentences, place: e.place, live: false, two: e.heard.prefix(2) != e.into.prefix(2), expand: nil, clear: nil)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(e.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .primaryAction) { Button("Now playing") { l.choose(e.title) } } }
        }
        .fullScreenCover(isPresented: $full) {
            NavigationStack {
                ReadAlong(sentences: l.sentences, place: l.episode?.place, live: true, two: l.config != nil, expand: nil, clear: nil)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(l.episode?.title ?? "").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { full = false } } }
            }
        }
        .sheet(isPresented: $picking) {
            EpisodePicker { title in
                l.choose(title)
                picking = false
                if startAfterPick {
                    l.startPiP()
                    Task { try? await Task.sleep(for: .milliseconds(600)); BroadcastButton.tap() }
                }
            }
        }
        .confirmationDialog("Clear what was heard in this episode?", isPresented: $clearing, titleVisibility: .visible) {
            Button("Clear") { l.clear() }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { l.allowSpeech() }
    }
}

// What's playing? An episode heard before (it opens where it was left) or a new title. iOS doesn't tell an app what
// another app plays, so the user says; the title is also how the Mac finds the transcript.
struct EpisodePicker: View {
    @ObservedObject var l = Listener.shared
    var pick: (String) -> Void
    @State private var title = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Episode or talk title", text: $title).submitLabel(.done).onSubmit { pick(title) }
                    if let s = UIPasteboard.general.hasStrings ? UIPasteboard.general.string : nil, s.count < 200, title.isEmpty {
                        Button("Paste “\(s.prefix(50))”") { title = s }
                    }
                } footer: { Text("Use the same title on the Mac and the transcript is there too.") }
                let others = l.everywhere.filter { e in !l.episodes.contains { $0.key == e.key } && (title.isEmpty || e.title.localizedCaseInsensitiveContains(title)) }
                if !others.isEmpty {
                    Section("From your Mac and iPad") {
                        ForEach(others, id: \.key) { e in Button(e.title) { pick(e.title) }.foregroundStyle(.primary) }
                    }
                }
                if !l.episodes.isEmpty {
                    Section("Heard before") {
                        ForEach(l.episodes.filter { title.isEmpty || $0.title.localizedCaseInsensitiveContains(title) }) { e in
                            Button { pick(e.title) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.title).foregroundStyle(.primary)
                                    Text("\(e.sentences.count) sentences").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("What's playing?").navigationBarTitleDisplayMode(.inline)
            .task { await l.fetchIndex() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { pick(title) }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// Spotify's read-along card: big bold sentences on a colour, a time every so often, opened at where the user is and
// following it as it moves (live), the newest word lit. Every sentence can be selected; Copy takes the whole episode.
struct ReadAlong: View {
    var sentences: [Sentence]
    var place: Int?
    var live: Bool
    var two: Bool
    var expand: (() -> Void)?
    var clear: (() -> Void)?
    @State private var showOriginal = true

    static let card = Color(red: 0.36, green: 0.45, blue: 0.49)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Text("Read along").font(.subheadline.weight(.bold))
                Spacer()
                if two { Button { showOriginal.toggle() } label: { Image(systemName: showOriginal ? "character.bubble.fill" : "character.bubble") } }
                Button { UIPasteboard.general.string = Self.text(sentences, two: two) } label: { Image(systemName: "doc.on.doc") }
                    .disabled(sentences.isEmpty)
                if let clear { Button(action: clear) { Image(systemName: "trash") }.disabled(sentences.isEmpty) }
                if let expand { Button(action: expand) { Image(systemName: "arrow.up.left.and.arrow.down.right") } }
            }
            .foregroundStyle(.white).buttonStyle(.plain)
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if sentences.isEmpty {
                            Text(live ? "What's heard shows up here." : "Nothing was heard.").font(.title3.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                        }
                        ForEach(Array(sentences.enumerated()), id: \.element.id) { i, s in
                            VStack(alignment: .leading, spacing: 4) {
                                // a time over the first sentence of every minute
                                if i == 0 || Int(s.time) / 60 != Int(sentences[i - 1].time) / 60 {
                                    Text(Self.clock(s.time)).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                                }
                                // heard (up to where the user is) in white, the rest of the episode dimmer, as Spotify does
                                // the sentence being heard shows only its words that have stopped changing (Settle)
                                let hot = live && i == place
                                TimelineView(.periodic(from: .now, by: hot ? 0.25 : 3600)) { tl in
                                    let heard = hot ? Settle.text(s.heard, id: s.id, at: tl.date) : s.heard
                                    let said = hot ? Settle.text(s.said, id: s.id + ".said", at: tl.date) : s.said
                                    VStack(alignment: .leading, spacing: 4) {
                                        Self.lit(two ? (said.isEmpty ? "…" : said) : heard, on: hot, after: i > (place ?? Int.max))
                                            .font(.title3.weight(.semibold))
                                        if two && showOriginal {
                                            Text(heard).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(i > (place ?? Int.max) ? 0.35 : 0.6))
                                        }
                                    }
                                    .animation(.easeOut(duration: 0.35), value: heard)
                                }
                            }
                            .textSelection(.enabled)
                            .id(s.id)
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 24)
                }
                .onChange(of: place.flatMap { sentences.indices.contains($0) ? sentences[$0] : nil }) { _, s in
                    if live, let s { withAnimation { proxy.scrollTo(s.id, anchor: .center) } }
                }
                .onAppear { if let p = place, sentences.indices.contains(p) { proxy.scrollTo(sentences[p].id, anchor: .center) } }
            }
        }
        .background(Self.card, in: RoundedRectangle(cornerRadius: expand != nil ? 12 : 0))
    }

    static func lit(_ text: String, on: Bool, after: Bool) -> Text {
        let base = Color.white.opacity(after ? 0.45 : 1)
        guard on, let r = text.range(of: #"\S+$"#, options: .regularExpression) else { return Text(text).foregroundColor(base) }
        return Text(text[..<r.lowerBound]).foregroundColor(base) + Text(text[r]).foregroundColor(Color(Listener.lit))
    }

    static func clock(_ t: Double) -> String { String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60) }

    static func text(_ ss: [Sentence], two: Bool) -> String {
        ss.map { two ? "[\(clock($0.time))] \($0.said)\n\($0.heard)" : "[\(clock($0.time))] \($0.heard)" }.joined(separator: "\n\n")
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
    }
}

/// Live speech recognition rewrites its last words again and again as it hears more. Read along shows a word only
/// once it has stayed the same for a moment, so the sentence grows calmly instead of flickering (a word that
/// changes goes back to waiting, with every word after it). The floating window keeps the live text.
@MainActor enum Settle {
    static let wait: TimeInterval = 0.9
    private static var seen: [String: (words: [Substring], since: [Date])] = [:]

    static func text(_ t: String, id: String, at now: Date) -> String {
        let words = t.split(separator: " ", omittingEmptySubsequences: false)
        var old = seen[id] ?? ([], [])
        var keep = 0
        while keep < min(words.count, old.words.count), words[keep] == old.words[keep] { keep += 1 }
        if keep < words.count || keep < old.words.count {
            old = (words, Array(old.since.prefix(keep)) + Array(repeating: now, count: words.count - keep))
            seen[id] = old
            if seen.count > 64 { seen = [id: old] }
        }
        let shown = old.since.prefix { now.timeIntervalSince($0) >= wait }.count
        return words.prefix(shown).joined(separator: " ")
    }
}

