// Derived from Spec: FEAT-01 (A4 · shared/voice/)
import Foundation

/// One voice a backend can speak with.
struct VoiceInfo: Equatable {
    let id: String          // backend-specific identifier
    let name: String
    let language: String    // BCP 47, e.g. "vi-VN"
    let quality: Int        // 0 default, 1 enhanced, 2 premium (AVSpeechSynthesisVoiceQuality.rawValue for system voices)
}

/// A rendered stretch of speech. `words` is nil when the backend gives no word times.
struct RenderedSpeech {
    struct Word: Equatable { let text: String; let start: Double; let end: Double }
    let samples: [Float]    // mono
    let sampleRate: Double
    let words: [Word]?
}

/// The one protocol every narration voice implements (system now; Kokoro and VieNeu later, Mac only).
protocol VoiceBackend {
    var id: String { get }
    var languages: [String] { get }       // ISO 639-1
    var supportsSpeed: Bool { get }
    var givesWordTimes: Bool { get }
    func voices(for lang: String) -> [VoiceInfo]
    func render(text: String, lang: String, voice: VoiceInfo?, speed: Double) async throws -> RenderedSpeech
}
