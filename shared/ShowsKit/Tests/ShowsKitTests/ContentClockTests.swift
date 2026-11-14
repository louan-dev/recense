// Derived from Spec: FEAT-04 (P1, one clock)
import XCTest
@testable import ShowsKit

final class ContentClockTests: XCTestCase {
    let wall = 1_762_990_000.0  // 2026-11-12, as SpeechAnalyzer's words come in on iOS
    func live() -> [Word] {
        [Word(text: "The", start: wall + 0.2, end: wall + 0.5), Word(text: "court", start: wall + 0.6, end: wall + 1.1)]
    }

    func testWallWordsLandOnTheSentencesTime() {
        let c = ContentClock.content(live(), at: 42)
        XCTAssertEqual(c.map(\.start), [42, 42.4], accuracy: 1e-6)
        XCTAssertEqual(c.map(\.end), [42.3, 42.9], accuracy: 1e-6)
        XCTAssertFalse(ContentClock.isWall(c))
    }

    func testContentWordsAreLeftAlone() {
        let mac = [Word(text: "held", start: 12.5, end: 12.9, lang: "en")]
        XCTAssertEqual(ContentClock.content(mac, at: 99), mac)
    }

    // the old iOS files (wall clock) and the Mac's (content) read to the same offsets
    func testBothFormatsReadToTheSameOffsets() {
        let ios = ContentClock.content(live(), at: 42)
        let mac = [Word(text: "The", start: 42, end: 42.3), Word(text: "court", start: 42.4, end: 42.9)]
        XCTAssertEqual(ios.map(\.start), mac.map(\.start), accuracy: 1e-6)
    }

    func testAnchorRoundTrips() {
        let a = ContentClock.Anchor(wall: wall + 0.2, content: 42)
        XCTAssertEqual(a.content(atWall: wall + 1.2), 43, accuracy: 1e-6)
        let back = a.wall(ContentClock.content(live(), at: 42))
        XCTAssertEqual(back.map(\.start), live().map(\.start), accuracy: 1e-6)
    }

    func testPausedAnchorStandsStill() {
        let a = ContentClock.Anchor(wall: wall, content: 42, rate: 0)
        XCTAssertEqual(a.content(atWall: wall + 30), 42)
    }

    func testShiftMovesSyllablesAndPin() {
        let w = Word(text: "la", start: 1, end: 2, syl: [Syl(c: 2, s: 1, e: 2)], tm: Pin(s: 1, e: 2, k: 0))
        let s = w.shifted(by: 10)
        XCTAssertEqual(s.syl?.first?.s, 11); XCTAssertEqual(s.tm?.e, 12)
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
