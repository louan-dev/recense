// The transcript's light and the scrubber's rules (Views/Transcript.swift, Views/Scrubber.swift), in English,
// Vietnamese and French.
import XCTest
@testable import ShowsKit

final class TranscriptTests: XCTestCase {
    private func said(_ l: TranscriptLine, _ t: Double) -> String { String(l.text[..<TranscriptLight.spoken(l, at: t)]) }

    func testActiveLineIsTheLastBegun() {
        let ls = TranscriptLine.sample
        XCTAssertNil(TranscriptLight.active(ls, at: -1))
        XCTAssertEqual(TranscriptLight.active(ls, at: 0), 0)
        XCTAssertEqual(TranscriptLight.active(ls, at: 12.9), 1)
        XCTAssertEqual(TranscriptLight.active(ls, at: 13), 2)
        XCTAssertEqual(TranscriptLight.active(ls, at: 999), ls.count - 1)
    }

    func testWordsLightByTheirOwnTimes() {
        let en = TranscriptLine(id: "e", start: 0, end: 3, text: "The court held, plainly.", words: [
            .init(text: "The", start: 0, end: 0.3), .init(text: "court", start: 0.3, end: 0.6),
            .init(text: "held,", start: 0.6, end: 1), .init(text: "plainly.", start: 1.2, end: 2)])
        XCTAssertEqual(said(en, 0.1), "The")
        XCTAssertEqual(said(en, 0.7), "The court held,")
        XCTAssertEqual(said(en, 5), "The court held, plainly.")
        XCTAssertEqual(said(en, -1), "")
    }

    func testVietnameseWordsKeepTheirDiacriticsAndSyllables() {
        // DictationTranscriber gives Vietnamese words of two syllables ("Tòa án", "phán quyết")
        let vi = TranscriptLine(id: "v", start: 0, end: 3, text: "Tòa án đã phán quyết rằng hợp đồng vô hiệu.", words: [
            .init(text: "Tòa án", start: 0, end: 0.5), .init(text: "đã", start: 0.5, end: 0.8), .init(text: "phán quyết", start: 0.8, end: 1.4),
            .init(text: "rằng", start: 1.4, end: 1.6), .init(text: "hợp đồng", start: 1.6, end: 2.2), .init(text: "vô hiệu.", start: 2.2, end: 2.9)])
        XCTAssertEqual(said(vi, 0.9), "Tòa án đã phán quyết")
        XCTAssertEqual(said(vi, 1.7), "Tòa án đã phán quyết rằng hợp đồng")
        // a word decomposed (NFD) still finds its place in a composed (NFC) line
        var nfd = vi
        nfd.words = vi.words.map { TranscriptWord(text: $0.text.decomposedStringWithCanonicalMapping, start: $0.start, end: $0.end) }
        XCTAssertEqual(said(nfd, 0.9), "Tòa án đã phán quyết")
        XCTAssertTrue(TranscriptLight.ranges(nfd).allSatisfy { $0 != nil })
    }

    func testFrenchElisionAndAccents() {
        let fr = TranscriptLine(id: "f", start: 0, end: 2, text: "L'appel a été jugé irrecevable.", words: [
            .init(text: "L'appel", start: 0, end: 0.4), .init(text: "a", start: 0.4, end: 0.5), .init(text: "été", start: 0.5, end: 0.8),
            .init(text: "jugé", start: 0.8, end: 1.1), .init(text: "irrecevable.", start: 1.1, end: 1.9)])
        XCTAssertEqual(said(fr, 0.85), "L'appel a été jugé")
    }

    func testAWordTheTextLacksIsSkippedNotMisplaced() {
        let l = TranscriptLine(id: "x", start: 0, end: 2, text: "one two three", words: [
            .init(text: "one", start: 0, end: 0.5), .init(text: "zwei", start: 0.5, end: 1), .init(text: "three", start: 1, end: 1.5)])
        XCTAssertEqual(said(l, 0.7), "one")
        XCTAssertEqual(said(l, 1.2), "one two three")
    }

    func testWithoutWordTimesTheLightStopsAtAWholeWord() {
        let vi = TranscriptLine(id: "p", start: 10, end: 20, text: "Tuy nhiên, nguyên đơn đã kháng cáo lên tòa án cấp cao hơn.")
        for t in stride(from: 10.0, through: 20, by: 0.5) {
            let s = said(vi, t)
            // the cut is never inside a word: what follows starts with a space or punctuation, or nothing
            let cut = TranscriptLight.spoken(vi, at: t), rest = vi.text[cut...]
            XCTAssertTrue(cut == vi.text.startIndex || rest.isEmpty || rest.first!.isWhitespace || rest.first!.isPunctuation, "cut inside a word at \(t): \(s)|\(rest)")
        }
        XCTAssertEqual(said(vi, 9), "")
        XCTAssertEqual(said(vi, 21), vi.text)
    }

    func testClockAndCopy() {
        XCTAssertEqual(TranscriptLight.clock(0), "0:00")
        XCTAssertEqual(TranscriptLight.clock(754), "12:34")
        XCTAssertEqual(TranscriptLight.clock(4521), "1:15:21")
        let two = Array(TranscriptLine.sample.prefix(2))
        let text = TranscriptLight.text(two, translations: true)
        XCTAssertTrue(text.hasPrefix("[0:00] Welcome back."))
        XCTAssertTrue(text.contains("\nTòa án phán quyết rằng hợp đồng vô hiệu"))
        XCTAssertFalse(TranscriptLight.text(two, translations: false).contains("Chào mừng"))
    }

    func testScrubberMovesFromWhereItWasAndGoesFinerUpward() {
        // slide: from the playhead, not to the finger (homebar.js beginSeek)
        XCTAssertEqual(ScrubMath.time(t0: 600, dx: 100, width: 400, duration: 3600, level: 0), 1500)
        XCTAssertEqual(ScrubMath.time(t0: 600, dx: 100, width: 400, duration: 3600, level: 1), 825)
        XCTAssertEqual(ScrubMath.time(t0: 10, dx: -400, width: 400, duration: 3600, level: 0), 0, "never before the start")
        XCTAssertEqual(ScrubMath.time(t0: 3500, dx: 400, width: 400, duration: 3600, level: 0), 3600, "never past the end")
        // up: ×4, ×16, ×64, only while the window still spans 10 s
        XCTAssertEqual(ScrubMath.level(up: 10, unit: 44, duration: 3600), 0)
        XCTAssertEqual(ScrubMath.level(up: 60, unit: 44, duration: 3600), 1)
        XCTAssertEqual(ScrubMath.level(up: 120, unit: 44, duration: 3600), 2)
        XCTAssertEqual(ScrubMath.level(up: 500, unit: 44, duration: 3600), 3)
        XCTAssertEqual(ScrubMath.level(up: 500, unit: 44, duration: 60), 1, "a minute goes no finer than ×4 (15 s)")
        // tap: jumps there
        XCTAssertEqual(ScrubMath.jump(x: 100, width: 400, duration: 3600), 900)
    }

    @MainActor func testOnePlayheadForScrubberAndLines() {
        let t = SampleTransport(at: 8, playing: false)
        XCTAssertEqual(TranscriptLight.active(TranscriptLine.sample, at: t.time), 1)
        t.seek(to: 20)          // the scrubber (or a tapped line) seeks the transport the lines read
        XCTAssertEqual(TranscriptLight.active(TranscriptLine.sample, at: t.time), 3)
        t.skip(-15)
        XCTAssertEqual(t.time, 5)
    }

    /// The light may be at most one frame late, and a frame must stay well inside the owner's 50 ms bar against the Mac
    /// (it was 1/12 s: up to 83 ms late). The view's light must use this frame, not a slower timer of its own.
    func testLightRedrawsWellInsideFiftyMilliseconds() throws {
        XCTAssertLessThanOrEqual(TranscriptLight.frame, 1.0 / 60 + 1e-9)
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/ShowsKit/Views/Transcript.swift").standardizedFileURL, encoding: .utf8)
        XCTAssertTrue(src.contains("TimelineView(.animation(minimumInterval: TranscriptLight.frame"))
        XCTAssertFalse(src.contains("by: ticking ? 1.0 / 12"))
    }

    /// The view scrolls to a line before it begins, by the scroll's own length, so its first word lights in place
    /// (blind critic, 11-10: the first word of a new line was seen ~450 ms late while the view scrolled to it).
    func testViewScrollsToTheNextLineBeforeItBegins() {
        let lines = TranscriptLine.sample                                    // line 2 begins at 6 s
        let last = lines[0].words.last!.start                                // line 1's last word, ~5.54 s
        let turn = TranscriptLight.turn(lines, to: 1)
        XCTAssertEqual(TranscriptLight.active(lines, at: 5.7), 0)            // the light stays on the true clock
        XCTAssertEqual(TranscriptLight.following(lines, at: last + 0.05), 0) // the last word lights on a still, bold line
        XCTAssertEqual(TranscriptLight.following(lines, at: turn.at), 1)     // then the view is on its way
        XCTAssertGreaterThanOrEqual(turn.at, last + TranscriptLight.hold)
        XCTAssertLessThanOrEqual(turn.at + turn.scroll + TranscriptLight.rest, 6 + 1e-9)   // still before it lights
        XCTAssertGreaterThanOrEqual(turn.scroll, TranscriptLight.quickest)
        XCTAssertEqual(TranscriptLight.following(lines, at: 5.7, jump: true), 0)   // Reduce Motion jumps on time
        XCTAssertEqual(TranscriptLight.following(lines, at: 5.2), 0)
        // a long pause before the next line: the full lead and the full scroll
        let paused = [TranscriptLine(id: "a", start: 0, end: 2, text: "Hi", words: [TranscriptWord(text: "Hi", start: 0, end: 1)]),
                      TranscriptLine(id: "b", start: 5, end: 6, text: "Yes")]
        XCTAssertEqual(TranscriptLight.turn(paused, to: 1).at, 5 - TranscriptLight.lead, accuracy: 1e-9)
        XCTAssertEqual(TranscriptLight.turn(paused, to: 1).scroll, TranscriptLight.scroll)
    }

    /// A light worked out for "now" is seen one refresh later: the playhead is read at the frame's on-screen time.
    func testFrameLeadIsTheTimeToTheNextRefresh() {
        let p = 1.0 / 60
        XCTAssertEqual(FrameClock.lead(now: 10.000, target: 10.010, period: p), 0.010, accuracy: 1e-9)
        // a target already passed moves on by whole refreshes
        XCTAssertEqual(FrameClock.lead(now: 10.020, target: 10.010, period: p), 10.010 + p - 10.020, accuracy: 1e-9)
        XCTAssertEqual(FrameClock.lead(now: 10.050, target: 10.010, period: p), 10.010 + 3 * p - 10.050, accuracy: 1e-9)
        // no refresh seen yet: one period (the frame being drawn shows at the next refresh)
        XCTAssertEqual(FrameClock.lead(now: 10, target: 0, period: p), p, accuracy: 1e-9)
        // never more than one refresh, never negative
        XCTAssertLessThanOrEqual(FrameClock.lead(now: 5, target: 9, period: p), p)
        XCTAssertGreaterThanOrEqual(FrameClock.lead(now: 10.010, target: 10.010, period: p), 0)
    }
}
