// The app's own playback, heard (milestone 3): the playing episode's file goes through the shared engine
// (shared/speechcore.swift, SpeechAhead: two-minute stretches, the playhead's first) and its phrases become Now
// Playing's transcript (ShowsKit's TranscriptView). Offline: SpeechAnalyzer's model for the language is on the device
// (Listen downloads it once when the language is chosen); without SpeechAnalyzer, SFSpeechRecognizer on the device.
// The language is Listen's "Hear in". The file: the pool's copy on this device (B1 sets where the pool lives; until
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
        model.transcript = []
        model.transcriptSource = nil
        model.transcriptNote = "Opening the transcript…"
        let path = e.item.path
        Task {
            let r = await TranscriptSource.load(path: path, cache: Self.cache) { await siteData($0) }
            guard key == e.id else { return }
            if !r.lines.isEmpty {
                model.transcript = r.lines; model.transcriptSource = r.note; model.transcriptNote = nil
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
        let lang = Listener.shared.lang
        let path = e.item.path
        let a = SpeechAhead(url: url, lang: lang, duration: e.duration ?? Self.length(url))
        a.playhead = { [weak model] in model?.transport?.time ?? 0 }
        a.changed = { [weak model, weak a] ps in
            let lines = Self.lines(ps)
            model?.transcript = lines
            model?.transcriptSource = "Heard on this device."
            model?.transcriptNote = a.map { $0.finished ? nil : "Hearing ahead of the playhead…" } ?? nil
            if a?.finished == true { Self.cache.write(path, lines) }   // the next open needs no hearing
        }
        model.transcriptNote = "Hearing \(Listener.short(lang)) on this device…"
        ahead = a
        a.start()
    }

    static func length(_ url: URL) -> Double {
        (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
    }

    static func lines(_ ps: [SpeechCore.Phrase]) -> [TranscriptLine] {
        ps.enumerated().map { i, p in
            TranscriptLine(id: "\(Int(p.start * 1000))-\(i)", start: p.start, end: p.end, text: p.text,
                           words: p.words.map { TranscriptWord(text: $0.text, start: $0.start, end: $0.end) })
        }
    }
}

