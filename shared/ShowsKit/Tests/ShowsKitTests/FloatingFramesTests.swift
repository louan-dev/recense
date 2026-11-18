// Derived from Spec: BUG-24 (P1b: the floating window sweeps too, drawn by the one painter)
// Regression guard: BUG-24 (the iPhone and iPad floating window drew one picture per word, so a word lit whole at its
// start, and stamped them as if the player always ran at 1×: at 1.5× each word lit late, more so down the line).
import CoreGraphics
import XCTest
@testable import ShowsKit

final class FloatingFramesTests: XCTestCase {
    private func line(_ ws: [(String, Double, Double)], translation: String? = nil) -> Caption.Line {
        Caption.Line(words: ws.map { Word(text: $0.0, start: $0.1, end: $0.2) }, translationText: translation)
    }

    func testALongWordGetsFourPicturesAndAShortWordOne() {
        let l = line([("Hello", 0, 1.0), ("a", 1.0, 1.2)])
        let got = FloatingFrames.stamps(l, after: -0.01, ahead: 5)
        XCTAssertEqual(got.count, 6, "\(got)")
        for (g, w) in zip(got, [0, 0.25, 0.5, 0.75, 1.0, 1.2]) { XCTAssertEqual(g, w, accuracy: 1e-9) }
    }

    func testStampsStayInsideTheWindowAhead() {
        let l = line([("Hello", 0, 1.0)])
        XCTAssertEqual(FloatingFrames.stamps(l, after: 0.3, ahead: 0.4), [0.5])
        XCTAssertEqual(FloatingFrames.stamps(l, after: 0.5, ahead: 0.1), [], "a stamp at `after` is already on screen")
    }

    func testTheTranslationsWordsAreStampedToo() {
        let l = line([("Bonjour", 0, 0.2), ("monde", 0.2, 0.4)], translation: "Hello world")
        let src = Set(FloatingFrames.stamps(line([("Bonjour", 0, 0.2), ("monde", 0.2, 0.4)]), after: -1, ahead: 5))
        let both = Set(FloatingFrames.stamps(l, after: -1, ahead: 5))
        XCTAssertTrue(src.isSubset(of: both))
        let tr = Caption.translationBeats(l)
        for b in tr { XCTAssertTrue(both.contains(b.start), "the translation's \(b.text) lights in its own picture") }
    }

    func testTheSignatureChangesExactlyAtTheStamps() {
        let l = line([("Hello", 0, 1.0), ("a", 1.0, 1.2)])
        let at = { (t: Double) in FloatingFrames.signature([l], current: 0, mode: .follow, at: t) }
        XCTAssertEqual(at(0.05), at(0.2), "inside one quarter of a word the picture is the same")
        XCTAssertNotEqual(at(0.2), at(0.3), "the next quarter is a new picture")
        XCTAssertEqual(at(1.05), at(1.15), "a short word is one picture")
        XCTAssertNotEqual(at(1.15), at(1.25), "and white once it ends")
    }

    func testFollowShowsTheLineTheTranscriptTurnsTo() {
        let ls = [TranscriptLine(id: "a", start: 0, end: 1, text: "One two", words: [Word(text: "One", start: 0, end: 0.5), Word(text: "two", start: 0.5, end: 1)]),
                  TranscriptLine(id: "b", start: 2, end: 3, text: "Three four", words: [Word(text: "Three", start: 2, end: 2.5), Word(text: "four", start: 2.5, end: 3)])]
        for t in stride(from: -0.5, through: 3.5, by: 0.05) {
            XCTAssertEqual(FloatingFrames.current(ls, at: t), TranscriptLight.following(ls, at: t), "at \(t)")
            // Regression guard: BUG-24 review 7: with Reduce Motion the app jumps to the active line; the window does too
            XCTAssertEqual(FloatingFrames.current(ls, at: t, jump: true), TranscriptLight.following(ls, at: t, jump: true), "jump at \(t)")
        }
    }

    func testFollowStampsTheNextLinesTurnAndItsWords() {
        let ls = [TranscriptLine(id: "a", start: 0, end: 1, text: "One two", words: [Word(text: "One", start: 0, end: 0.5), Word(text: "two", start: 0.5, end: 1)]),
                  TranscriptLine(id: "b", start: 2, end: 3, text: "Three four", words: [Word(text: "Three", start: 2, end: 2.5), Word(text: "four", start: 2.5, end: 3)])]
        let got = FloatingFrames.followStamps(ls, ls.map(FloatingFrames.line), after: 1.2, ahead: 1.5)
        let still = FloatingFrames.followStamps(ls, ls.map(FloatingFrames.line), after: 1.2, ahead: 1.5, jump: true)
        XCTAssertFalse(still.contains(TranscriptLight.turn(ls, to: 1).at), "Reduce Motion: no early turn, the line changes as it starts")
        XCTAssertTrue(got.contains(TranscriptLight.turn(ls, to: 1).at), "the next line shows, whole and grey, when the transcript turns to it: \(got)")
        XCTAssertTrue(got.contains(2) && got.contains(2.25), "and its words light in their pictures: \(got)")
    }

    func testALineWithoutWordTimesIsSpreadOverItsTime() {
        let l = FloatingFrames.line(TranscriptLine(id: "a", start: 10, end: 11, text: "Hello there world"))
        XCTAssertEqual(l.words.map(\.text), ["Hello", "there", "world"])
        XCTAssertEqual(l.start, 10); XCTAssertEqual(l.end, 11, accuracy: 1e-9)
        let none = FloatingFrames.line(TranscriptLine(id: "b", start: 5, end: 5, text: "Two words"))
        XCTAssertGreaterThan(none.end, 5, "a line with no length still takes a moment per word")
    }

    func testLearnIsDrawnEveryFifteenthOfASecondWhileAPlaceFades() {
        let ls = [line([("One", 0, 0.5), ("two", 0.5, 1)]), line([("Three", 20, 20.5), ("four", 20.5, 21)])]
        // the second line opens a new run after 19 s of silence: it fades in over 0.4 s from 4 s before it is said
        let got = FloatingFrames.learnStamps(ls, after: 15.9, ahead: 0.6)
        let fading = got.filter { $0 > 16.15 && $0 < 16.5 }
        XCTAssertGreaterThanOrEqual(fading.count, 4, "\(got)")
        XCTAssertTrue(zip(fading, fading.dropFirst()).allSatisfy { $1 - $0 <= FloatingFrames.fadeStep + 1e-9 })
        XCTAssertTrue(FloatingFrames.learnStamps(ls, after: 10, ahead: 1).isEmpty, "nothing moves in a silence")
    }

    func testStampsAreScheduledOnTheWallAtThePlayersSpeed() {
        let clock = ContentClock.Anchor(wall: 100, content: 10, rate: 1.5)
        let got = FloatingFrames.schedule([10.75, 11.5], on: clock)
        XCTAssertEqual(got.map(\.wall), [100.5, 101])
        XCTAssertEqual(got.map(\.at), [10.75, 11.5])
        XCTAssertTrue(FloatingFrames.schedule([11], on: .init(wall: 100, content: 10, rate: 0)).isEmpty, "paused: nothing is ahead")
    }

    func testMidWordTheWindowsPictureIsHalfLit() {
        let w = 900, h = 300
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let l = line([("Everything", 0, 1.0)])
        var style = CaptionStyle(); style.shadow = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        let box = CGRect(x: 0, y: 0, width: w, height: h)
        FloatingFrames.draw([l], current: 0, mode: .follow, at: 0.5, in: ctx, box: box, style: style)
        let r = CaptionPainter.layout(l, mode: .follow, at: 0.5, in: box, style: style).items[0].rect
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        func opaque(_ x0: CGFloat, _ x1: CGFloat) -> Int {
            var n = 0
            for y in Int(r.minY)..<min(h, Int(r.maxY)) { for x in Int(x0)..<Int(x1) where p[((h - 1 - y) * w + x) * 4 + 3] > 200 { n += 1 } }
            return n
        }
        XCTAssertGreaterThan(opaque(r.minX, r.minX + r.width * 0.4), 0, "the heard half is lit")
        XCTAssertEqual(opaque(r.minX + r.width * 0.6, r.maxX), 0, "the unheard half is not")
    }
}
