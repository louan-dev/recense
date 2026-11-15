// Regression guard: BUG-11 (a file played in Recense was heard in the last broadcast's language: French audio through
// the English model came back "Like courage, jé, que, que, que, la, la, la…", Mac probe 11-14).
// SpeechAhead's language choice: the pure rules, then the real engine on a French recording made with `say`.
// Run (outside the sandbox: `say` and the speech models need it), from the repo root:
//   zsh mobile/ios/Tests/aheadlang/run.zsh   (French, Vietnamese and English recordings, each must be heard in its own)
import Foundation
import NaturalLanguage
import AVFoundation

var bad = 0
func expect(_ ok: Bool, _ what: String) { if !ok { bad += 1; print("FAIL \(what)") } }
let auto = ["en", "fr", "vi"]

// the first choice: the surest outright, ties to the earlier candidate; nothing heard → no choice
expect(SpeechAhead.choose(["en": 0.6, "fr": 4.2, "vi": 0.1], among: auto, current: nil) == "fr", "first choice is the surest")
expect(SpeechAhead.choose(["en": 1.0, "fr": 1.0], among: auto, current: nil) == "en", "a tie goes to the earlier candidate")
expect(SpeechAhead.choose(["en": 0, "fr": 0, "vi": 0], among: auto, current: nil) == nil, "no speech in any: no choice")
expect(SpeechAhead.choose([:], among: auto, current: nil) == nil, "no candidate heard: no choice")
// after a choice: only a clear margin (1.5x) changes it
expect(SpeechAhead.choose(["en": 1.2, "fr": 1.0], among: auto, current: "fr") == nil, "a slightly surer one doesn't flip it")
expect(SpeechAhead.choose(["en": 3.0, "fr": 1.0], among: auto, current: "fr") == "en", "a clearly surer one does")

// the probe's window inside the stretch [a, b)
let w1 = SpeechAhead.window(0, 120, playhead: 50)
expect(w1 == (50, 60), "the playhead's stretch: at the playhead (\(w1))")
let w2 = SpeechAhead.window(120, 240, playhead: 50)
expect(w2 == (120, 130), "another stretch: at its start (\(w2))")
let w3 = SpeechAhead.window(0, 120, playhead: 119)
expect(w3 == (110, 120), "near the end: pulled back, never past it (\(w3))")
let w4 = SpeechAhead.window(0, 2, playhead: 0)
expect(w4 == (0, 2), "a stretch shorter than the probe: all of it (\(w4))")

@MainActor func real(_ path: String) async {
    let url = URL(fileURLWithPath: path)
    let want = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "fr"
    let length = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 12
    // what the phone does on Automatic with no broadcast before: the fallback is "en"
    let a = SpeechAhead(url: url, lang: "en", among: auto, duration: length)
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        var once = false
        a.changed = { _ in if a.finished, !once { once = true; c.resume() } }
        a.start()
        Task { try? await Task.sleep(for: .seconds(90)); if !once { once = true; c.resume() } }
    }
    let text = a.phrases.map(\.text).joined(separator: " ")
    let r = NLLanguageRecognizer(); r.processString(text)
    print("heard in \(a.heardIn ?? "nothing"): \(text)")
    expect(a.heardIn == want, "a \(want) file on Automatic is heard in \(want) (heardIn \(a.heardIn ?? "nil"))")
    expect(r.dominantLanguage == NLLanguage(want), "its words read as \(want) (\(r.dominantLanguage?.rawValue ?? "?"))")
}

Task { @MainActor in
    if CommandLine.arguments.count > 1 { await real(CommandLine.arguments[1]) } else { print("(no recording given: pure rules only)") }
    print(bad == 0 ? "ALL OK" : "\(bad) FAILED")
    exit(bad == 0 ? 0 : 1)
}
RunLoop.main.run()
