// Player P1 (2026-11-11): a played file's transcript opens from this device, else the Mac's, else none (hear here).
// Regression: Now Playing on iOS never filled its transcript from anything but hearing on the device.
import XCTest
@testable import ShowsKit

final class TranscriptSourceTests: XCTestCase {
    private func tmp() -> TranscriptCache {
        TranscriptCache(dir: FileManager.default.temporaryDirectory.appendingPathComponent("tx-\(UUID().uuidString)"))
    }

    // the Worker's present() shape, in Vietnamese and French, with a translation on one line
    private let worker = Data("""
    {"lines":[
      {"id":3,"s":0.5,"e":2.1,"text":"Tòa án đã phán quyết","en":"The court ruled","words":[
        {"t":"Tòa","s":0.5,"e":0.8},{"t":"án","s":0.8,"e":1.0},{"t":"đã","s":1.0,"e":1.2},
        {"t":"phán","s":1.3,"e":1.6},{"t":"quyết","s":1.6,"e":2.1}]},
      {"id":"l-4","s":2.4,"e":3.9,"text":"La cour a tranché.","en":"","words":[
        {"t":"La","s":2.4,"e":2.6},{"t":"cour","s":2.6,"e":3.0},{"t":"a","s":3.0,"e":3.1},{"t":"tranché.","s":3.1,"e":3.9}]}
    ],"lang":"vi","complete":true,"version":2,"shift":0}
    """.utf8)

    func testDecodesTheWorkersLines() throws {
        let ls = try XCTUnwrap(TranscriptSource.decode(worker))
        XCTAssertEqual(ls.map(\.id), ["3", "l-4"])
        XCTAssertEqual(ls[0].text, "Tòa án đã phán quyết")
        XCTAssertEqual(ls[0].translation, "The court ruled")
        XCTAssertNil(ls[1].translation)   // "" means none
        XCTAssertEqual(ls[0].words.count, 5)
        XCTAssertEqual(ls[1].words.last?.end, 3.9)
    }

    func testPendingOrEmptyIsNoTranscript() {
        XCTAssertNil(TranscriptSource.decode(Data(#"{"pending":true}"#.utf8)))
        XCTAssertNil(TranscriptSource.decode(Data(#"{"lines":[]}"#.utf8)))
        XCTAssertNil(TranscriptSource.decode(Data("<html>login</html>".utf8)))
    }

    func testAsksTheWorkerByPathEscaped() {
        XCTAssertEqual(TranscriptSource.remotePath("music/Mỹ Duyên & co.m4a"),
                       "/main/api/transcript?path=music/M%E1%BB%B9%20Duy%C3%AAn%20%26%20co.m4a")
    }

    func testTheMacsTranscriptIsSavedThenOpensOffline() async {
        let cache = tmp()
        let p = "music/Song.m4a"
        let first = await TranscriptSource.load(path: p, cache: cache) { _ in self.worker }
        XCTAssertEqual(first.origin, .mac)
        XCTAssertEqual(first.lines.count, 2)
        // offline: no fetch answers, the device's copy opens
        let offline = await TranscriptSource.load(path: p, cache: cache) { _ in nil }
        XCTAssertEqual(offline.origin, .device)
        XCTAssertEqual(offline.lines, first.lines)
        XCTAssertEqual(offline.note, "Saved on this device.")
    }

    func testTheDevicesCopyComesFirstWithoutAsking() async {
        let cache = tmp()
        cache.write("a.m4a", TranscriptLine.sample)
        let asked = Flag()
        let r = await TranscriptSource.load(path: "a.m4a", cache: cache) { _ in await asked.set(); return nil }
        XCTAssertEqual(r.origin, .device)
        let wasAsked = await asked.on
        XCTAssertFalse(wasAsked)
    }

    func testNothingAnywhereMeansHearItHere() async {
        let r = await TranscriptSource.load(path: "none.m4a", cache: tmp()) { _ in Data(#"{"pending":true}"#.utf8) }
        XCTAssertEqual(r.origin, .none)
        XCTAssertTrue(r.lines.isEmpty)
        XCTAssertNil(r.note)
    }
    // FEAT-22 P1 · keep/<key>/lines.json: the Mac's transcript as shown, carried to the phone, read before the Worker.
    private func sample() -> [TranscriptLine] {
        [TranscriptLine(id: "3", start: 0.5, end: 2.1, text: "Tòa án đã phán quyết", words: [
            Word(text: "Tòa", start: 0.5, end: 0.8, lang: "vi", syl: [Syl(c: 1, s: 0.5, e: 0.6), Syl(c: 3, s: 0.6, e: 0.8)]),
            Word(text: "án", start: 0.8, end: 1.0, un: true),
            Word(text: "phán", start: 1.3, end: 1.6, tm: Pin(s: 1.3, e: 1.6, k: -0.5, c: [0, 0.4, 1]))], translation: "The court ruled"),
         TranscriptLine(id: "4", start: 2.4, end: 3.9, text: "La cour a tranché.", words: [Word(text: "La", start: 2.4, end: 2.6)])]
    }

    func testEncodeIsDecodesInverseAndStable() throws {
        let a = try XCTUnwrap(TranscriptSource.encode(sample()))
        let back = try XCTUnwrap(TranscriptSource.decode(a))
        XCTAssertEqual(back.map(\.id), ["3", "4"])
        XCTAssertEqual(back[0].text, "Tòa án đã phán quyết")
        XCTAssertEqual(back[0].translation, "The court ruled")
        XCTAssertNil(back[1].translation)
        XCTAssertEqual(back[0].words[0].syl, [Syl(c: 1, s: 0.5, e: 0.6), Syl(c: 3, s: 0.6, e: 0.8)])
        XCTAssertEqual(back[0].words[1].un, true)
        XCTAssertEqual(back[0].words[2].tm, Pin(s: 1.3, e: 1.6, k: -0.5, c: [0, 0.4, 1]))
        XCTAssertEqual(back[0].words[0].lang, "vi")
        XCTAssertEqual(TranscriptSource.encode(sample()), a, "the same lines always make the same bytes (carry hashes the file)")
        XCTAssertNil(TranscriptSource.encode([]))
    }

    func testCarriedLinesOpenWithNoNetworkAndAreSavedForNext() async throws {
        let c = tmp(), keep = try XCTUnwrap(TranscriptSource.encode(sample()))
        let r = await TranscriptSource.load(path: "a.m4a", cache: c, keep: (data: keep, modified: Date())) { _ in nil }   // offline: fetch always fails
        XCTAssertEqual(r.origin, .mac)
        XCTAssertEqual(r.lines.count, 2)
        XCTAssertNotNil(c.read("a.m4a"), "saved on this device, so it opens next time even if the carried file is gone")
    }

    func testTheUpgradeRule_aNewerCarriedPassReplacesTheDeviceCopy_anOlderOneDoesNot() async throws {
        let c = tmp(), keep = try XCTUnwrap(TranscriptSource.encode(sample()))
        c.write("a.m4a", [TranscriptLine(id: "x", start: 0, end: 1, text: "phone")])
        let past = Date().addingTimeInterval(-3600), future = Date().addingTimeInterval(3600)
        let older = await TranscriptSource.load(path: "a.m4a", cache: c, keep: (data: keep, modified: past)) { _ in nil }
        XCTAssertEqual(older.origin, .device); XCTAssertEqual(older.lines.first?.text, "phone")
        let newer = await TranscriptSource.load(path: "a.m4a", cache: c, keep: (data: keep, modified: future)) { _ in nil }
        XCTAssertEqual(newer.origin, .mac); XCTAssertEqual(newer.lines.count, 2)
    }

    func testACarriedFileThatIsNotATranscriptIsIgnored() async throws {
        let c = tmp()
        let notTranscript: (data: Data, modified: Date) = (Data("{}".utf8), Date())
        let r: LoadedTranscript = await TranscriptSource.load(path: "a.m4a", cache: c, keep: notTranscript) { _ in nil }
        XCTAssertEqual(r.origin, TranscriptOrigin.none)
        c.write("a.m4a", [TranscriptLine(id: "x", start: 0, end: 1, text: "phone")])
        let garbage: (data: Data, modified: Date) = (Data("not json".utf8), Date().addingTimeInterval(60))
        let r2: LoadedTranscript = await TranscriptSource.load(path: "a.m4a", cache: c, keep: garbage) { _ in nil }
        XCTAssertEqual(r2.origin, TranscriptOrigin.device, "garbage never replaces a good copy")
    }
}

private actor Flag { var on = false; func set() { on = true } 
}
