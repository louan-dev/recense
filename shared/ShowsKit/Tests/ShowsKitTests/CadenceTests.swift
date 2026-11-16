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
}
