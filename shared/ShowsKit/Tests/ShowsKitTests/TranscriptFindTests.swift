// Derived from Spec: FEAT-07 (done check 1: detents for a fixture transcript; search across languages)
import XCTest
@testable import ShowsKit

final class TranscriptFindTests: XCTestCase {
    let lines = [
        TranscriptLine(id: "a", start: 0, end: 4, text: "Hello and welcome", translation: "Xin chào và chào mừng", chapter: "Intro"),
        TranscriptLine(id: "b", start: 5, end: 9, text: "We talk about Việt Nam today", translation: "Hôm nay nói về Việt Nam"),
        TranscriptLine(id: "c", start: 10, end: 14, text: "Le café est prêt", translation: "The coffee is ready"),
        TranscriptLine(id: "d", start: 20, end: 24, text: "Đà Nẵng and Hà Nội", translation: nil, chapter: "Cities"),
    ]

    func testSearchIgnoresCaseAndAccents() {
        XCTAssertEqual(TranscriptFind.hits(lines, "viet"), [1])
        XCTAssertEqual(TranscriptFind.hits(lines, "CAFE"), [2])
        XCTAssertEqual(TranscriptFind.hits(lines, "da nang"), [3], "đ folds to d")
        XCTAssertEqual(TranscriptFind.hits(lines, "chao"), [0], "the translation is searched too")
        XCTAssertEqual(TranscriptFind.hits(lines, "coffee"), [2])
        XCTAssertEqual(TranscriptFind.hits(lines, "a"), [], "one letter finds nothing")
        XCTAssertEqual(TranscriptFind.hits(lines, "zzz"), [])
    }

    func testSearchSeesLinesAsTheyArrive() {
        XCTAssertEqual(TranscriptFind.hits(Array(lines.prefix(1)), "nam"), [])
        XCTAssertEqual(TranscriptFind.hits(Array(lines.prefix(2)), "nam"), [1])
    }

    func testStepWrapsBothWays() {
        let h = [1, 3, 5]
        XCTAssertEqual(TranscriptFind.step(h, from: nil), 1)
        XCTAssertEqual(TranscriptFind.step(h, from: 1), 3)
        XCTAssertEqual(TranscriptFind.step(h, from: 5), 1)
        XCTAssertEqual(TranscriptFind.step(h, from: 1, back: true), 5)
        XCTAssertNil(TranscriptFind.step([], from: nil))
    }

    func testDetentsThreeLevelsStrongestWins() {
        let none: Set<Int> = []
        XCTAssertEqual(TranscriptFind.detent(lines, hits: none, duration: 30, from: 4.5, to: 5.5), .light, "a sentence")
        XCTAssertEqual(TranscriptFind.detent(lines, hits: none, duration: 30, from: 15, to: 21), .medium, "a chapter")
        XCTAssertEqual(TranscriptFind.detent(lines, hits: [2], duration: 30, from: 4, to: 11), .strong, "a hit beats a sentence")
        XCTAssertEqual(TranscriptFind.detent(lines, hits: none, duration: 30, from: 29, to: 30), .strong, "the end")
        XCTAssertEqual(TranscriptFind.detent(lines, hits: none, duration: 30, from: 6, to: 3), .light, "sliding back crosses too")
        XCTAssertNil(TranscriptFind.detent(lines, hits: none, duration: 30, from: 6, to: 8))
    }
}

// Derived from Spec: FEAT-10 (the translation follows the voice)
final class TranslationCadenceTests: XCTestCase {
    let words = [Word(text: "Hello", start: 0, end: 0.5), Word(text: "my", start: 0.5, end: 0.7),
                 Word(text: "friend", start: 2.0, end: 2.6)]   // a pause before "friend"

    func testTranslationTakesTheVoicesPace() {
        // "Xin chào bạn của tôi": 5 words over 3 source words; the pause carries over
        XCTAssertEqual(TranslationCadence.times(source: words, start: 0, end: 3, count: 5), [0, 0, 0.5, 0.5, 2.0])
    }

    func testNoWordTimesSpreadsEvenly() {
        XCTAssertEqual(TranslationCadence.times(source: [], start: 10, end: 14, count: 4), [10, 11, 12, 13])
    }

    func testSpokenCutsAtTheLastWordDue() {
        let tr = "Xin chào bạn của tôi"
        XCTAssertEqual(String(tr[..<TranslationCadence.spoken(tr, source: words, start: 0, end: 3, at: 0.6)]), "Xin chào bạn của")
        XCTAssertEqual(String(tr[..<TranslationCadence.spoken(tr, source: words, start: 0, end: 3, at: 1.5)]), "Xin chào bạn của", "the pause holds")
        XCTAssertEqual(String(tr[..<TranslationCadence.spoken(tr, source: words, start: 0, end: 3, at: 2.1)]), tr)
        XCTAssertEqual(String(tr[..<TranslationCadence.spoken(tr, source: words, start: 0, end: 3, at: -1)]), "")
    }
}
