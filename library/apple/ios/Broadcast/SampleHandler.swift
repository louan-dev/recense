// Gallery's broadcast extension (notes item 31): started from Control Center › Screen Recording › Gallery, it gets
// the audio of whatever is playing on the iPhone or iPad (any app, any Safari tab), the way Sill's system-audio tap
// does on the Mac. Speech is recognised on the device (never sent anywhere) in the language the app says to hear,
// and each line goes to the app through Captions, which translates it and shows it in the floating window.
// Video frames are dropped; only .audioApp is used. The extension has a 50 MB limit, so nothing large lives here.
import ReplayKit
import Speech

class SampleHandler: RPBroadcastSampleHandler {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var n = 0
    private var started = Date()
    private let q = DispatchQueue(label: "speech")

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        var s = Captions.state()
        s.on = true
        s.stop = false
        s.beat = Date()
        s.error = nil
        let locale = Locale(identifier: s.heard)
        recognizer = SFSpeechRecognizer(locale: locale)
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            s.error = "Open Gallery › Listen once to allow speech recognition."
        } else if recognizer?.supportsOnDeviceRecognition != true {
            s.error = "\(locale.localizedString(forIdentifier: s.heard) ?? s.heard) can't be heard on this device."
        }
        Captions.put(s)
        q.async { self.begin() }
        // say "still running" every 2 s, and end the broadcast when the app's Stop listening asks
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            var s = Captions.state()
            if s.stop {
                s.stop = false; s.on = false; s.beat = nil
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
        var s = Captions.state()
        s.on = false
        s.beat = nil
        s.stop = false
        Captions.put(s)
    }

    override func processSampleBuffer(_ sb: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .audioApp else { return }
        q.async {
            // a recognition request stops itself after about a minute: start the next one between utterances
            if Date().timeIntervalSince(self.started) > 50 { self.request?.endAudio(); self.begin() }
            self.request?.appendAudioSampleBuffer(sb)
        }
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
