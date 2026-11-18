// Derived from Spec: FEAT-20 — the one copy of the light's rules (the Mac, iPhone and iPad run these).
// Parity with the Mac's code before the move: 381/381 local songs identical (words, syllables, progress), 2026-11-16.
import XCTest
@testable import ShowsKit

final class CadenceTests: XCTestCase {
    func testSyllableSplit() {
        XCTAssertEqual(Cadence.syllables("variations", lang: "en").count, 4)   // va-ri-a-tions
        XCTAssertEqual(Cadence.syllables("love", lang: "en").count, 1)         // silent final e
        XCTAssertEqual(Cadence.syllables("東京", lang: "ja"), [1, 2])          // a letter each
        XCTAssertEqual(Cadence.syllables("", lang: nil), [])
    }

    func testProgressFollowsSyllables() {
        // "hello": he (2 letters) sung 0–1 s, llo (3 letters) sung 2–3 s
        let b = Beat(text: "hello", start: 0, end: 3, syl: [Syl(c: 2, s: 0, e: 1), Syl(c: 5, s: 2, e: 3)])
        XCTAssertEqual(Cadence.progress(b, 0), 0, accuracy: 1e-9)
        XCTAssertEqual(Cadence.progress(b, 0.5), 0.16, accuracy: 1e-9)  // "he" spread to 0.25 s past its end: 0.8 of 5 letters
        XCTAssertEqual(Cadence.progress(b, 1.5), 0.4, accuracy: 1e-9)   // held after "he" (0.25 s past its end, then waits)
        XCTAssertEqual(Cadence.progress(b, 2.5), 0.7, accuracy: 1e-9)   // halfway through "llo"
        XCTAssertEqual(Cadence.progress(b, 3), 1, accuracy: 1e-9)
    }

    func testPinOverridesAndClock() {
        Cadence.track = nil
        let even = Beat(text: "word", start: 1, end: 2)
        XCTAssertEqual(Cadence.progress(even, 1.5), 0.5, accuracy: 1e-9)  // no voice measured: the clock
        let w = Word(text: "word", start: 1, end: 2, tm: Pin(s: 1, e: 2, k: 0, c: [0, 1]))
        XCTAssertEqual(Cadence.progress(Beat(w), 1.25), 0.25, accuracy: 1e-9) // a traced pin wins
    }

    func testBeatsReadWordsAsTheMacDoes() {
        let ws = [Word(text: "held", start: 0, end: 2, syl: [Syl(c: 4, s: 0, e: 2)], tm: Pin(s: 0, e: 2, k: 0.01)),
                  Word(text: "next", start: 1.5, end: 3, tm: Pin(s: 1.5, e: 3, k: 1)),
                  Word(text: "traced", start: 3, end: 4, tm: Pin(s: 3, e: 4, k: 1, c: [0, 1]))]
        let b = Cadence.beats(ws)
        XCTAssertEqual(b[0].end, 1.5)   // lit until the next word starts
        XCTAssertNil(b[0].k)            // k about 0 with syllables: the syllables shape it
        XCTAssertEqual(b[1].k, 1)       // a pin's k shapes it
        XCTAssertNil(b[2].k); XCTAssertEqual(b[2].c ?? [], [0, 1])   // a trace wins over k
    }

    // Review-1117 follow-up: the light's memo is read on the main thread and set from wherever a song is fitted.
    func testTheLightsMemoTakesManyThreads() {
        let f = Features(source: "vocals", floor: -40, db: Array(repeating: -200, count: 400), onset: Array(repeating: 0, count: 400),
                         pitch: Array(repeating: 6000, count: 400), clarity: Array(repeating: 90, count: 400), voiced: Array(repeating: 1, count: 400))
        DispatchQueue.concurrentPerform(iterations: 2000) { i in
            if i % 50 == 0 { Cadence.track = i % 100 == 0 ? f : nil }
            let s = Double(i % 30) / 10
            _ = Cadence.progress(Beat(text: "word", start: s, end: s + 0.5), s + 0.25)
        }
        Cadence.track = f
        XCTAssertEqual(Cadence.progress(Beat(text: "word", start: 1, end: 2), 2), 1, accuracy: 1e-9)
        Cadence.track = nil
    }
}
