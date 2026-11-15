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
}

private actor Flag { var on = false; func set() { on = true } }
