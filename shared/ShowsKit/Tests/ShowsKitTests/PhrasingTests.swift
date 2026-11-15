// Regression guard: BUG-13 (iOS made one transcript line per breath-phrase, so lines ended mid-sentence: "This is
// the" / "resent player" / "check," — the iPhone's saved transcript of French check, 11-14: 17 lines, 3 ending a sentence).
import XCTest
@testable import ShowsKit

final class PhrasingTests: XCTestCase {
    /// Words one after another, `step` s each, no pause between.
    private func words(_ text: String, from t0: Double = 0, step: Double = 0.3) -> [Word] {
        text.split(separator: " ").enumerated().map { i, s in
            Word(text: String(s), start: t0 + Double(i) * step, end: t0 + Double(i + 1) * step)
        }
    }
    /// The phone's lines before the fix: one per phrase, ids "ms-i".
    private func fragments(_ phrases: [String]) -> [TranscriptLine] {
        var t = 0.0, out: [TranscriptLine] = []
        for (i, p) in phrases.enumerated() {
            let w = words(p, from: t); t = w.last!.end
            out.append(TranscriptLine(id: "\(Int(w[0].start * 1000))-\(i)", start: w[0].start, end: t, text: p, words: w))
        }
        return out
    }
    private let phone = ["This is the", "resent player", "check,", "one,", "two, three, four,", "five.", "The", "player keeps playing"]

    func testThePhonesFragmentsBecomeOneSentence() {
        let w = words(phone.joined(separator: " "))
        let ls = Phrasing.lines(w)
        XCTAssertEqual(ls.map(\.text), ["This is the resent player check, one, two, three, four, five.", "The player keeps playing"])
        XCTAssertEqual(ls[1].start, w[11].start)
        XCTAssertEqual(ls[0].words.count, 11)
        XCTAssertEqual(ls[0].end, w[10].end)
    }
    func testAPauseOverTheLimitEndsALine() {
        let a = words("we stop here")
        XCTAssertEqual(Phrasing.lines(a + words("and go on", from: a.last!.end + 1.3)).count, 2)
        XCTAssertEqual(Phrasing.lines(a + words("and go on", from: a.last!.end + 1.0)).count, 1)
    }
    func testAnEndMarkInsideAClosingQuote() {
        XCTAssertEqual(Phrasing.lines(words("he said «it is done.» then left")).map(\.text), ["he said «it is done.»", "then left"])
    }
    func testALongSentenceIsSplitNoLineOverTheLongest() {
        let text = (1...40).map { $0 == 15 ? "w\($0)," : $0 == 40 ? "w\($0)." : "w\($0)" }.joined(separator: " ")
        let ls = Phrasing.lines(words(text))
        XCTAssertGreaterThan(ls.count, 1)
        XCTAssertTrue(ls.allSatisfy { $0.words.count <= Phrasing.longest }, "\(ls.map(\.words.count))")
        XCTAssertEqual(ls[0].words.last?.text, "w15,", "split at the comma near the even cut")
        XCTAssertEqual(ls.flatMap(\.words).count, 40, "no word lost")
    }
    func testIdsAreUniqueByStartAndTheSameWordsGiveTheSameLines() {
        let w = [Word(text: "a.", start: 0, end: 0.0002), Word(text: "b.", start: 0.0004, end: 0.3), Word(text: "c.", start: 1, end: 1.3)]
        let ls = Phrasing.lines(w)
        XCTAssertEqual(ls.map(\.id), ["0-0", "0-1", "1000-0"])
        XCTAssertEqual(Phrasing.lines(w), ls)
        XCTAssertEqual(Phrasing.regrouped(ls), ls, "regrouping twice changes nothing")
    }
    func testRegroupsThisDevicesOldFragments() {
        XCTAssertEqual(Phrasing.regrouped(fragments(phone)).map(\.text),
                       ["This is the resent player check, one, two, three, four, five.", "The player keeps playing"])
    }
    func testLeavesTheMacsLinesAsTheyAre() {
        var mac = fragments(phone)
        for i in mac.indices { mac[i].id = "\(i + 1)" }
        XCTAssertEqual(Phrasing.regrouped(mac), mac, "plain ids: the Mac's")
        var translated = fragments(phone)
        translated[0].translation = "Ceci est le"
        XCTAssertEqual(Phrasing.regrouped(translated), translated, "a translation: not this device's old fragments")
    }
    func testCJKWordsJoinWithNoSpace() {
        XCTAssertEqual(Phrasing.join(["我们", "走", "吧。"]), "我们走吧。")
        XCTAssertEqual(Phrasing.join(["Đi", "thôi."]), "Đi thôi.")
        XCTAssertEqual(Phrasing.join(["我", "OK"]), "我 OK")
    }
}
