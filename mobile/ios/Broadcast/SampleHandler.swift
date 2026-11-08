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
    private var live: AnyObject?            // SpeechLive (iOS 26)
    private var t0: Double?                 // when the analyzer's stream began (s since 1970)
    private var finals: [SpeechCore.Phrase] = []
    private var locale = ""

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        var s = Captions.state()
        // a broadcast with SpeechAnalyzer that never reached broadcastFinished or Stop: iOS ended it (likely memory)
        if s.engine == "SpeechAnalyzer…" { s.analyzerFailed = Date() }
        s.on = true
        s.stop = false
        s.beat = Date()
        s.error = nil
        locale = s.heard
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
            } else { s.on = true; s.beat = Date(); Captions.put(s) }
        }
        t.resume()
        beat = t
    }
    private var beat: DispatchSourceTimer?

    override func broadcastFinished() {
        q.sync { beat?.cancel(); task?.cancel(); request?.endAudio() }
        if #available(iOS 26, *), let l = live as? SpeechLive { l.cancel() }
        var s = Captions.state()
        s.on = false
        s.beat = nil
        s.stop = false
        if s.engine == "SpeechAnalyzer…" { s.engine = "SpeechAnalyzer" }
        Captions.put(s)
    }

    override func processSampleBuffer(_ sb: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .audioApp else { return }
        if #available(iOS 26, *), let l = live as? SpeechLive {
            guard let pcm = SpeechCore.pcm(sb) else { return }
            q.async {
                if self.t0 == nil { self.t0 = Date().timeIntervalSince1970 }
                l.append(pcm)
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
        let lang = locale
        Task { @MainActor in
            let l = try? await SpeechLive.start(lang: lang, download: false) { [weak self] p, final in
                self?.q.async { self?.heard(p, final: final) }
            }
            guard let l else { self.q.async { self.startLegacy() }; return }
            self.q.async { self.live = l }
            var s = Captions.state(); s.engine = "SpeechAnalyzer…"; Captions.put(s)
        }
    }

    // One line a stretch of about 50 s, as the SFSpeechRecognizer requests were: the finished phrases, then the live
    // guess at what follows them (replaced by the next result). Words timed from t0.
    private func heard(_ p: SpeechCore.Phrase, final: Bool) {
        if final { finals.append(p) }
        let ps = finals + (final ? [] : [p])
        guard !ps.isEmpty else { return }
        Captions.put(Captions.Line(n: n, text: ps.map(\.text).joined(separator: " "), final: final, locale: locale,
                                   words: ps.flatMap(\.words), t0: t0))
        if final, let first = finals.first, p.end - first.start > 50 { n += 1; finals = [] }
    }

    // MARK: SFSpeechRecognizer (the fallback)

    private func startLegacy() {
        let id = locale
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
        let mine = n, locale = recognizer.locale.identifier
        // one line per request (about 50 s): partial results keep rewriting earlier words, so splitting them into
        // sentences here cut lines into single words; the app shows it as running text instead
        task = recognizer.recognitionTask(with: r) { result, _ in
            guard let result, !result.bestTranscription.segments.isEmpty else { return }
            Captions.put(Captions.Line(n: mine, text: Self.join(result.bestTranscription.segments[...]), final: result.isFinal, locale: locale))
        }
    }
}
