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

    /// Where an episode's bytes are on this device, if they are.
    static var file: (ShowsKit.Episode) -> URL? = { e in
        if let p = ProcessInfo.processInfo.environment["RECENSE_TRANSCRIPT_FILE"] { return URL(fileURLWithPath: p) }
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recense/" + e.item.path)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Follows what the model plays: a new episode starts its hearing, the old one stops.
    func follow(_ model: ShowsModel) {
        guard let e = model.playing else { ahead?.stop(); ahead = nil; key = nil; return }
        guard e.id != key else { return }
        ahead?.stop(); ahead = nil; key = e.id
        model.transcript = []
        guard let url = Self.file(e) else { model.transcriptNote = "This episode isn't on this device yet, so it can't be heard here."; return }
        let lang = Listener.shared.lang
        let a = SpeechAhead(url: url, lang: lang, duration: e.duration ?? Self.length(url))
        a.playhead = { [weak model] in model?.transport?.time ?? 0 }
        a.changed = { [weak model, weak a] ps in
            model?.transcript = Self.lines(ps)
            model?.transcriptNote = a.map { $0.finished ? nil : "Hearing ahead of the playhead…" } ?? nil
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
                           words: p.words.map { Word(text: $0.text, start: $0.start, end: $0.end) })
        }
    }
}

