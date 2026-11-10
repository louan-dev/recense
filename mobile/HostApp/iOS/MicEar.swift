// The microphone as Listen's stand-in ear (S3b): with no broadcast and the sound on the device's own speaker, the mic
// hears what plays. Text only: the sound stays in memory, goes to the speech engine and is never written anywhere.
// It is fed only while another app plays (Ears.Choice.feed), so with nothing playing the room isn't transcribed.
// iOS refuses to *start* recording in the background, so it starts only while Recense is in front, then keeps
// running behind other apps (UIBackgroundModes audio). Lines are made as the broadcast extension makes them
// (ios/Broadcast/SampleHandler.swift heard(_:final:), its twin): one line a stretch of about 50 s, words timed from t0.
import AVFoundation
import Speech

@MainActor final class MicEar {
    /// What the audio thread touches: the gate and where the sound goes. Locked; never the main actor.
    private final class Sink: @unchecked Sendable {
        let lock = NSLock()
        var feeding = false
        var live: AnyObject?                                 // SpeechLive (iOS 26)
        var request: SFSpeechAudioBufferRecognitionRequest?  // the fallback
        var seconds = 0.0                                    // how much sound the engine has had
        var lastFed: Date?
        var t0: Double?                                      // wall clock of the stream's 0 for the current stretch
        var gap = false                                      // fed again after a pause: the next line starts afresh

        func take(_ buf: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            guard feeding else { return }
            let now = Date()
            if lastFed.map({ now.timeIntervalSince($0) > 2 }) ?? true {
                t0 = now.timeIntervalSince1970 - seconds; gap = lastFed != nil
            }
            lastFed = now
            seconds += Double(buf.frameLength) / buf.format.sampleRate
            if #available(iOS 26, *), let l = live as? SpeechLive { l.append(buf); return }
            request?.append(buf)
        }
    }

    private let engine = AVAudioEngine()
    private let sink = Sink()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var requestAt = Date()
    private var restart: Timer?
    private var n = 0
    private var finals: [SpeechCore.Phrase] = []
    private var locale = ""
    private(set) var b = 0.0           // this run (Captions.Line.b)
    private(set) var running = false
    var onLine: (Captions.Line) -> Void = { _ in }

    /// Whether the mic's sound goes to the speech engine now.
    var feed: Bool {
        get { sink.lock.lock(); defer { sink.lock.unlock() }; return sink.feeding }
        set { sink.lock.lock(); sink.feeding = newValue; sink.lock.unlock() }
    }

    /// Starts hearing in `lang`. Call only while Recense is in front. false: the session or the input refused.
    func start(lang: String) async -> Bool {
        guard !running else { return true }
        let s = AVAudioSession.sharedInstance()
        do {
            // mixWithOthers: whatever plays keeps playing; defaultToSpeaker: play-and-record would use the earpiece
            try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try s.setActive(true)
        } catch { return false }
        locale = lang; b = Date().timeIntervalSince1970; n = 0; finals = []
        sink.lock.lock(); sink.seconds = 0; sink.lastFed = nil; sink.t0 = nil; sink.gap = false; sink.lock.unlock()
        if #available(iOS 26, *), let l = try? await SpeechLive.start(lang: lang, download: false, each: { [weak self] p, fin in
            Task { @MainActor in self?.heard(p, final: fin) }
        }) {
            sink.lock.lock(); sink.live = l; sink.lock.unlock()
        } else {
            beginLegacy()
            restart = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                Task { @MainActor [weak self] in
                    guard let self, Date().timeIntervalSince(self.requestAt) > 50 else { return }
                    self.beginLegacy()  // a request stops itself after about a minute
                }
            }
        }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { stop(); return false }
        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in sink.take(buf) }
        do { try engine.start() } catch { input.removeTap(onBus: 0); stop(); return false }
        running = true
        return true
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        restart?.invalidate(); restart = nil
        sink.lock.lock()
        let live = sink.live, req = sink.request
        sink.live = nil; sink.request = nil; sink.feeding = false
        sink.lock.unlock()
        if #available(iOS 26, *), let l = live as? SpeechLive { Task { await l.finish() } }
        req?.endAudio(); task?.finish(); task = nil
        running = false
    }

    /// Whether the engine still runs (an interruption, a call, stops it without a word).
    var alive: Bool { running && engine.isRunning }

    private func stretch() -> (t0: Double?, fresh: Bool) {
        sink.lock.lock(); defer { sink.lock.unlock() }
        let g = sink.gap; sink.gap = false
        return (sink.t0, g)
    }

    // the extension's heard(_:final:), with a new line wherever the mic was not fed for a while
    private func heard(_ p: SpeechCore.Phrase, final: Bool) {
        let (t0, fresh) = stretch()
        if fresh, !finals.isEmpty { n += 1; finals = [] }
        if final { finals.append(p) }
        let ps = finals + (final ? [] : [p])
        guard !ps.isEmpty else { return }
        onLine(Captions.Line(n: n, text: ps.map(\.text).joined(separator: " "), final: final, locale: locale,
                             words: ps.flatMap(\.words), t0: t0, b: b))
        if final, let first = finals.first, p.end - first.start > 50 { n += 1; finals = [] }
    }

    // SFSpeechRecognizer on the device, where there's no SpeechAnalyzer: one request (one line) about every 50 s
    private func beginLegacy() {
        if recognizer == nil { recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { return }
        task?.finish()
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.requiresOnDeviceRecognition = true
        r.shouldReportPartialResults = true
        r.addsPunctuation = true
        sink.lock.lock(); sink.request?.endAudio(); sink.request = r; sink.lock.unlock()
        requestAt = Date()
        n += 1
        let mine = n, loc = locale, bid = b
        task = recognizer.recognitionTask(with: r) { [weak self] result, _ in
            guard let result, !result.bestTranscription.segments.isEmpty else { return }
            let text = SpeechLegacy.words(result.bestTranscription.segments, lang: loc).map(\.text).joined(separator: " ")
            let line = Captions.Line(n: mine, text: text, final: result.isFinal, locale: loc, b: bid)
            Task { @MainActor in self?.onLine(line) }
        }
    }
}
