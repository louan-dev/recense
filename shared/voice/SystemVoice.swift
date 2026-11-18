// Derived from Spec: FEAT-01 (A4 · shared/voice/)
// Regression guard: FEAT-01 invariant 11, grepping the repo's Swift for the bestVoice definition (the pattern "func" + " bestVoice") prints exactly 1 line
import Foundation
import AVFoundation
import NaturalLanguage

/// The one `bestVoice` (FEAT-01 invariant 11). `lang` is an ISO code ("fr", "vi-VN"); when nil it is read from `text`.
/// Picks the highest-quality installed system voice for the language, else the system default for it.
func bestVoice(lang: String?, text: String) -> AVSpeechSynthesisVoice? {
    var code = lang
    if code == nil {
        let r = NLLanguageRecognizer()
        r.processString(text)
        code = r.dominantLanguage?.rawValue
    }
    guard let code = code else { return nil }
    let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(code) }
    return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: code)
}

/// Apple's voices, offline, on every device. Shown to the owner as "Quick voice".
final class SystemBackend: VoiceBackend {
    enum Failure: Error { case noVoice, noAudio }
    let id = "system"
    var languages: [String] { Array(Set(AVSpeechSynthesisVoice.speechVoices().map { String($0.language.prefix(2)) })).sorted() }
    let supportsSpeed = true
    let givesWordTimes = false
    private let synth = AVSpeechSynthesizer()

    func voices(for lang: String) -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
            .map { VoiceInfo(id: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality.rawValue) }
    }

    func render(text: String, lang: String, voice: VoiceInfo?, speed: Double) async throws -> RenderedSpeech {
        let v = voice.flatMap { AVSpeechSynthesisVoice(identifier: $0.id) } ?? bestVoice(lang: lang, text: text)
        guard let v = v else { throw Failure.noVoice }
        let u = AVSpeechUtterance(string: text)
        u.voice = v
        let wanted = Double(AVSpeechUtteranceDefaultSpeechRate) * speed
        u.rate = Float(min(max(wanted, Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
        var samples: [Float] = []
        var rate = 0.0
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            synth.write(u) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    if !finished { finished = true; done.resume() }   // an empty buffer ends the utterance
                    return
                }
                rate = pcm.format.sampleRate
                if let ch = pcm.floatChannelData {
                    samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(pcm.frameLength)))
                } else if let ch = pcm.int16ChannelData {
                    for i in 0..<Int(pcm.frameLength) { samples.append(Float(ch[0][i]) / 32768) }
                }
            }
        }
        guard !samples.isEmpty else { throw Failure.noAudio }
        return RenderedSpeech(samples: samples, sampleRate: rate, words: nil)
    }
}

/// `recense selftest`: the one `bestVoice` (FEAT-01 invariant 11), no audio, no permission.
func voiceSelftest() -> Bool {
    var all = true
    func check(_ ok: Bool, _ what: String) { all = all && ok; print("\(ok ? "ok  " : "FAIL") voice, \(what)") }
    check(bestVoice(lang: nil, text: "") == nil, "no text and no language gives no voice")
    if let v = bestVoice(lang: "en", text: "") {
        let best = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }.map { $0.quality.rawValue }.max()
        check(best == nil || v.quality.rawValue >= best!, "an English voice has the best installed quality")
    }
    if let v = bestVoice(lang: nil, text: "Le tribunal a rendu sa décision hier soir après une longue audience.") {
        check(v.language.hasPrefix("fr"), "French text is read by a French voice (\(v.language))")
    }
    check(SystemBackend().voices(for: "en").allSatisfy { $0.language.hasPrefix("en") }, "SystemBackend lists only the asked language")
    return all
}
