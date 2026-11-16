// The app's own playback, heard (milestone 3): the playing episode's file goes through the shared engine
// (shared/speechcore.swift, SpeechAhead: two-minute stretches, the playhead's first) and its phrases become Now
// Playing's transcript (ShowsKit's TranscriptView). Offline: SpeechAnalyzer's model for the language is on the device
// (Listen downloads it once when the language is chosen); without SpeechAnalyzer, SFSpeechRecognizer on the device.
// The language is Listen's "Hear in"; on Automatic, the file's own (BUG-11).
// The file: the pool's copy on this device (B1 sets where the pool lives; until
// then Documents/Recense/<path>, or RECENSE_TRANSCRIPT_FILE for a simulator check).
import Foundation
import AVFoundation
import ShowsKit

@MainActor final class PlaybackEars {
    static let shared = PlaybackEars()
    private var ahead: SpeechAhead?
    private var key: String?

    /// Where an episode's bytes are on this device, if they are (Recense/<path>, or a played file's saved copy).
    static var file: (ShowsKit.Episode) -> URL? = { e in
        if let p = ProcessInfo.processInfo.environment["RECENSE_TRANSCRIPT_FILE"] { return URL(fileURLWithPath: p) }
        return Offline.url(e.item.path)
    }

    /// This device's saved transcripts (TranscriptSource's cache), one JSON file per media path.
    static let cache = TranscriptCache(dir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Recense/transcripts"))

    /// Follows what the model plays (player P1 S2): the transcript saved here, else the Mac's (saved here at once),
    /// else heard on this device, each labelled with where it came from.
    func follow(_ model: ShowsModel) {
        guard let e = model.playing else { ahead?.stop(); ahead = nil; key = nil; return }
        guard e.id != key else { return }
        ahead?.stop(); ahead = nil; key = e.id
        gate?.cancel(); gate = nil; held = false
        model.transcript = []
        model.transcriptSource = nil
        model.transcriptNote = "Opening the transcript…"
        let path = Offline.origin(e.item.path)
        Task {
            let r = await TranscriptSource.load(path: path, cache: Self.cache) { await siteData($0) }
            guard key == e.id else { return }
            if !r.lines.isEmpty {
                // a transcript this device heard before BUG-13 comes back by sentence; any other as it is
                model.transcript = Phrasing.regrouped(r.lines); model.transcriptSource = r.note; model.transcriptNote = nil
                PlaybackTranslator.shared.run(model, lang: Listener.shared.lang)
            } else {
                hear(model, e)
            }
        }
    }

    /// A played file's copy just landed here: hear it, if nothing else gave its transcript.
    func saved(_ model: ShowsModel) {
        guard let e = model.playing, e.id == key, model.transcript.isEmpty, ahead == nil else { return }
        hear(model, e)
    }

    private func hear(_ model: ShowsModel, _ e: ShowsKit.Episode) {
        guard let url = Self.file(e) else {
            model.transcriptNote = "No transcript yet. It will be heard on this device once the file is saved here."
            return
        }
        // BUG-11: on Automatic the file's own sound picks its language (SpeechAhead's check), not the last broadcast's;
        // Listen's language is only the fallback until a candidate is heard surely
        let lang = Listener.shared.lang, auto = Listener.shared.heard == Captions.automatic
        let path = Offline.origin(e.item.path)
        let a = SpeechAhead(url: url, lang: lang, among: auto ? SpeechCore.auto : nil, duration: e.duration ?? Self.length(url))
        a.playhead = { [weak model] in model?.transport?.time ?? 0 }
        a.changed = { [weak model, weak a] ps in
            let lines = Self.lines(ps), heardIn = a?.heardIn ?? lang
            model?.transcript = lines
            model?.transcriptSource = "Heard on this device in \(Listener.short(heardIn))\(auto ? " (automatic)" : "")."
            model?.transcriptNote = a.map { $0.finished ? nil : "Loading transcript… \(Int(Double($0.done.count) / Double($0.count) * 100))%" } ?? nil
            if let model { PlaybackTranslator.shared.run(model, lang: heardIn) }
            if a?.finished == true { Self.cache.write(path, lines) }   // the next open needs no hearing
        }
        model.transcriptNote = auto ? "Hearing on this device, finding its language…" : "Hearing \(Listener.short(lang)) on this device…"
        ahead = a
        a.start()
        holdUntilWhole(model, a, key: e.id)
    }

    // FEAT-16 P3 (T-0095): a stored piece with no finished transcript plays only once it is whole, so the words never drift
    // from the sound. hold = pause (again, if the listener presses play); release = play once whole, or once it can't be made.
    enum Gate { case hold, release, none }
    nonisolated static func gate(playing: Bool, complete: Bool, giveUp: Bool, held: Bool) -> Gate {
        if !complete && !giveUp { return playing ? .hold : .none }
        return held ? .release : .none
    }
    private var gate: Task<Void, Never>?
    private var held = false

    private func holdUntilWhole(_ model: ShowsModel, _ a: SpeechAhead, key id: String) {
        gate?.cancel()
        gate = Task { @MainActor [weak self, weak model, weak a] in
            while !Task.isCancelled {
                guard let self, let model, let a, self.key == id, let t = model.transport else { return }
                switch Self.gate(playing: t.isPlaying, complete: a.finished, giveUp: a.problem != nil, held: self.held) {
                case .hold: self.held = true; t.toggle()
                case .release: self.held = false; t.toggle(); return
                case .none: if a.finished { return }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    static func length(_ url: URL) -> Double {
        (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
    }

    /// One line per sentence, as the Mac (BUG-13; a line per phrase cut sentences after "the"): every phrase's words in
    /// time order, a phrase with no timed words as one word.
    static func lines(_ ps: [SpeechCore.Phrase]) -> [TranscriptLine] {
        Phrasing.lines(ps.flatMap { p in
            p.words.isEmpty ? [Word(text: p.text, start: p.start, end: p.end)]
                            : p.words.map { Word(text: $0.text, start: $0.start, end: $0.end) }
        })
    }
}

