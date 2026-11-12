// Gallery's broadcast extension (notes item 31): started from Control Center › Screen Recording › Gallery, it gets
// the audio of whatever is playing on the iPhone or iPad (any app, any Safari tab), the way Recense's system-audio tap
// does on the Mac. Speech is recognised on the device (never sent anywhere) in the language the app says to hear,
// and each line goes to the app through Captions, which translates it and shows it in the floating window.
// Video frames are dropped; only .audioApp is used. The extension has a 50 MB limit, so nothing large lives here.
//
// The ears (milestone 3, 11-08): iOS 26's SpeechAnalyzer, the engine the Mac hears with (shared/speechcore.swift), its
// words timed. Its model runs in a system process, not in the extension (Apple, WWDC25 "SpeechAnalyzer"), and the app
// downloads it once when the language is chosen; the extension never downloads. Where there's no SpeechAnalyzer
// (iOS 18-25), no model for the language, or the last broadcast with it was ended by iOS without a word (memory),
// SFSpeechRecognizer on the device hears instead, as before.
import ReplayKit
import Speech

class SampleHandler: RPBroadcastSampleHandler {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var n = 0
    private var started = Date()
    private let q = DispatchQueue(label: "speech")
    private var live: AnyObject?            // SpeechAuto (iOS 26): one language, or under Automatic whichever is spoken
    private var clock = SoundClock()        // the analyzer's time against the sound's own stamps (t0, gaps); on q only
    private var finals: [SpeechCore.Phrase] = []
    private var locale = ""                // the language of the line being heard (Captions.Line.locale)
    private var lang = ""                  // the engine's language ("en"), to tell a change
    private var auto = false
    private var b = Date().timeIntervalSince1970   // this broadcast (Captions.Line.b)

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        var s = Captions.state()
        // a broadcast with SpeechAnalyzer that never reached broadcastFinished or Stop: iOS ended it (likely memory)
        if s.engine == "SpeechAnalyzer…" { s.analyzerFailed = Date() }
        s.on = true
        s.stop = false
        s.hold = nil   // a new broadcast is a clear "hear"
        s.beat = Date()
        s.error = nil
        auto = s.auto
        locale = auto ? SpeechCore.locale(s.start).identifier : s.heard
        b = Date().timeIntervalSince1970
        s.b = b
        let useAnalyzer = s.analyzerFailed.map { Date().timeIntervalSince($0) > 86_400 } ?? true
        Captions.put(s)
        if #available(iOS 26, *), useAnalyzer { startAnalyzer() } else { startLegacy() }
        // say "still running" every 2 s, and end the broadcast when the app's Stop listening asks
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            var s = Captions.state()
            if s.stop {
                s.stop = false; s.on = false; s.beat = nil
                if s.engine == "SpeechAnalyzer…" { s.engine = "SpeechAnalyzer" }
                Captions.put(s)
                self?.finishBroadcastWithError(NSError(domain: "Gallery", code: 0, userInfo: [NSLocalizedDescriptionKey: "Listening stopped."]))
            } else { self?.holding = s.hold == true; s.on = true; s.beat = Date(); Captions.put(s) }
        }
        t.resume()
        beat = t
    }
    private var beat: DispatchSourceTimer?
    private var holding = false   // Listen's Pause (State.hold): sound arriving now is dropped; the clock keeps the gap

    override func broadcastFinished() {
        q.sync { beat?.cancel(); task?.cancel(); request?.endAudio() }
        if #available(iOS 26, *), let l = live as? SpeechAuto { l.cancel() }
        var s = Captions.state()
        s.on = false
        s.beat = nil
        s.stop = false
        if s.engine == "SpeechAnalyzer…" { s.engine = "SpeechAnalyzer" }
        Captions.put(s)
    }

    override func processSampleBuffer(_ sb: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .audioApp, !holding else { return }
        if #available(iOS 26, *), let l = live as? SpeechAuto {
            guard let pcm = SpeechCore.pcm(sb) else { return }
            // the sound's own stamp (host clock), read with now on both clocks before the queue adds its delay
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds, wall = Date().timeIntervalSince1970
            q.async {
                let gap = self.clock.before(pts: pts, hostNow: host, wallNow: wall)
                if gap > 0, let z = Self.silence(like: pcm, seconds: gap) {
                    l.append(z); self.clock.gave(Double(z.frameLength) / z.format.sampleRate)
                }
                l.append(pcm); self.clock.gave(Double(pcm.frameLength) / pcm.format.sampleRate)
            }
            return
        }
        q.async {
            // a recognition request stops itself after about a minute: start the next one between utterances
            if Date().timeIntervalSince(self.started) > 50 { self.request?.endAudio(); self.begin() }
            self.request?.appendAudioSampleBuffer(sb)
        }
    }

    // MARK: SpeechAnalyzer

    @available(iOS 26, *)
    private func startAnalyzer() {
        let start = auto ? Captions.state().start : locale, among = auto ? SpeechCore.auto : []
        Task { @MainActor in
            let l = await SpeechAuto.start(lang: start, among: among, fast: Captions.state().sooner ?? false) { [weak self] p, final, lang in
                self?.q.async { self?.heard(p, final: final, lang: lang) }
            }
            guard let l else { self.q.async { self.startLegacy() }; return }
            l.onNote = { n in var s = Captions.state(); s.check = n; Captions.put(s) }
            self.q.async { self.live = l }
            var s = Captions.state(); s.engine = "SpeechAnalyzer…"; Captions.put(s)
        }
    }

    // One line a stretch of about 50 s, as the SFSpeechRecognizer requests were: the finished phrases, then the live
    // guess at what follows them (replaced by the next result). Words timed from t0.
    // Under Automatic, a change of language starts a new line in it, and the app learns it (State.detected).
    private func heard(_ p: SpeechCore.Phrase, final: Bool, lang: String) {
        if lang != self.lang {
            if !self.lang.isEmpty, !finals.isEmpty { n += 1; finals = [] }
            self.lang = lang
            if auto {
                locale = SpeechCore.locale(lang).identifier
                var s = Captions.state(); s.detected = lang; Captions.put(s)
            }
        }
        if final { finals.append(p) }
        let ps = finals + (final ? [] : [p])
        guard !ps.isEmpty else { return }
        Captions.put(Captions.Line(n: n, text: ps.map(\.text).joined(separator: " "), final: final, locale: locale,
                                   words: ps.flatMap(\.words).map(onClock), t0: clock.t0, b: b))
        if final, let first = finals.first, p.end - first.start > 50 { n += 1; finals = [] }
    }

    /// A word in t0's time: what a long pause before it took off the analyzer's clock goes back on (SoundClock).
    private func onClock(_ w: SpeechCore.W) -> SpeechCore.W {
        let k = clock.skew(at: w.start)
        guard k != 0 else { return w }
        var v = w; v.start += k; v.end += k; return v
    }

    /// `seconds` of silence in `like`'s format: a pause in the other app fed as what it was.
    private static func silence(like: AVAudioPCMBuffer, seconds: Double) -> AVAudioPCMBuffer? {
        let n = AVAudioFrameCount(seconds * like.format.sampleRate)
        guard n > 0, let z = AVAudioPCMBuffer(pcmFormat: like.format, frameCapacity: n) else { return nil }
        z.frameLength = n
        for b in UnsafeMutableAudioBufferListPointer(z.mutableAudioBufferList) { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        return z
    }

    // MARK: SFSpeechRecognizer (the fallback)

    private func startLegacy() {
        let id = locale  // under Automatic, the last language heard (SFSpeechRecognizer can't tell)
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: id))
        var s = Captions.state()
        s.engine = "SFSpeechRecognizer"
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            s.error = "Open Recense › Listen once to allow speech recognition."
        } else if recognizer?.supportsOnDeviceRecognition != true {
            s.error = "\(Locale.current.localizedString(forIdentifier: id) ?? id) can't be heard on this device."
        }
        Captions.put(s)
        q.async { self.begin() }
    }

    // the recogniser gives punctuation as its own segments ("gros ," "d' installer"): glue it back
    static func join(_ s: ArraySlice<SFTranscriptionSegment>) -> String {
        s.map(\.substring).joined(separator: " ")
            .replacingOccurrences(of: #" ([,.?!;:])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "' ", with: "'")
    }

    private func begin() {
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { return }
        task?.finish()
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.requiresOnDeviceRecognition = true
        r.shouldReportPartialResults = true
        r.addsPunctuation = true
        request = r
        started = Date()
        n += 1
        let mine = n, locale = recognizer.locale.identifier, bid = b
        // one line per request (about 50 s): partial results keep rewriting earlier words, so splitting them into
        // sentences here cut lines into single words; the app shows it as running text instead
        task = recognizer.recognitionTask(with: r) { result, _ in
            guard let result, !result.bestTranscription.segments.isEmpty else { return }
            Captions.put(Captions.Line(n: mine, text: Self.join(result.bestTranscription.segments[...]), final: result.isFinal, locale: locale, b: bid))
        }
    }
}
