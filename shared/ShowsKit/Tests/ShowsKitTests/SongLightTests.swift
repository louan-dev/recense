// FEAT-20 (iOS syllable light, route A): SongLight.fill is cadence.js `fill` (and the Mac's Cadence.progress) rule for
// rule; the engine (the Mac's Swift Cadence) gives cadence.js's answer. Fixtures/songlight.json is made by library/test/songlight.test.mjs
// from cadence.js itself, so a drift on either side fails one of the two suites.
// Status: coded, not compiled (no Swift toolchain where it was written); run `swift test` in shared/ShowsKit.
import XCTest
@testable import ShowsKit

final class SongLightTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()   // ShowsKitTests, Tests, ShowsKit
        .deletingLastPathComponent().deletingLastPathComponent()                                // shared, repo
    private struct Fix: Decodable {
        struct Y: Decodable { let c: Int; let s: Double; let e: Double }
        struct W: Decodable { let t: String; let s: Double; let e: Double; let syl: [Y]?; let un: Bool }
        struct P: Decodable { let t: String; let s: Double; let e: Double; let k: Double?; let c: [Double]? }
        let notes: [[Double]]
        let fitted: [W]
        let samples: [[Double]]
        let pinned: [P]
        let pins: [[Double]]
    }
    private func fixture() throws -> Fix {
        let u = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/songlight.json")
        return try JSONDecoder().decode(Fix.self, from: Data(contentsOf: u))
    }
    private func word(_ w: Fix.W) -> Word {
        Word(text: w.t, start: w.s, end: w.e, syl: w.syl?.map { Syl(c: $0.c, s: $0.s, e: $0.e) }, un: w.un ? true : nil)
    }

    func testFillMatchesCadenceJsSyllableBySyllable() throws {
        let f = try fixture(), ws = f.fitted.map(word)
        XCTAssertEqual(ws[0].syl?.count, 4)   // Va-ri-a-tions
        for s in f.samples {
            let i = Int(s[0]), t = s[1]
            XCTAssertEqual(SongLight.fill(ws[i], at: t), s[2], accuracy: 1e-5, "\(ws[i].text) at \(t)")
        }
    }

    func testFillMatchesCadenceJsForAListenersTiming() throws {
        let f = try fixture()
        // as pin leaves them: the word's span is the listener's, with k (one shaped sweep) or a trace
        let ws = f.pinned.map { p in
            Word(text: p.t, start: p.s, end: p.e, tm: Pin(s: p.s, e: p.e, k: p.k ?? 0, c: p.c))
        }
        for s in f.pins {
            let i = Int(s[0]), t = s[1]
            XCTAssertEqual(SongLight.fill(ws[i], at: t), s[2], accuracy: 1e-5, "\(ws[i].text) at \(t)")
        }
    }

    func testAWordNotSungIsNeverLitAndCutsFallOnWholeLetters() {
        let un = Word(text: "dream", start: 1, end: 2, un: true)
        XCTAssertEqual(SongLight.fill(un, at: 1.5), 0)
        XCTAssertEqual(SongLight.litCount(un, at: 3), 0)
        // "Tòa" decomposed: o + combining grave is one letter of two code points, never cut in half
        let w = Word(text: "To\u{0300}a", start: 0, end: 1, syl: [Syl(c: 3, s: 0, e: 0.5), Syl(c: 4, s: 0.5, e: 1)])
        XCTAssertEqual(SongLight.litCount(w, at: 0.25), 1)   // 1.5 of 3 code points: "T" only
        XCTAssertEqual(SongLight.litCount(w, at: 0.5), 2)    // "Tò"
        XCTAssertEqual(SongLight.litCount(w, at: 1), 3)
    }

    func testOnlyAVocalStemIsFollowed() {
        let db = Array(repeating: -300, count: 30)
        func f(_ src: String, _ n: Int) -> Data { try! JSONSerialization.data(withJSONObject: ["source": src, "db": Array(db.prefix(n))]) }
        XCTAssertTrue(SongLight.usable(f("vocals", 30)))
        XCTAssertFalse(SongLight.usable(f("speech", 30)))   // a mix's loudness is the band's
        XCTAssertFalse(SongLight.usable(f("vocals", 20)))
        XCTAssertFalse(SongLight.usable(Data(#"{"none":true}"#.utf8)))
        XCTAssertEqual(SongLight.featuresPath("Music/a b.m4a"), "/main/api/transcript?path=Music/a%20b.m4a&f=features")
    }

    func testTheVoiceIsReadHereFirstThenFromTheMacAndSaved() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString)")
        let good = try JSONSerialization.data(withJSONObject: ["source": "vocals", "db": Array(repeating: 0, count: 30)])
        let asked = Counter()
        let got = await SongLight.voice(path: "Music/x.m4a", dir: dir) { p in asked.add(p); return good }
        XCTAssertEqual(got, good)
        let again = await SongLight.voice(path: "Music/x.m4a", dir: dir) { p in asked.add(p); return nil }   // offline now
        XCTAssertEqual(again, good)
        XCTAssertEqual(asked.paths, ["/main/api/transcript?path=Music/x.m4a&f=features"])
        let none = await SongLight.voice(path: "Music/y.m4a", dir: dir) { _ in Data(#"{"none":true}"#.utf8) }
        XCTAssertNil(none)
    }

    func testTheSwiftEngineHangsTheWordsOnTheVoiceAsCadenceJsDoes() throws {
        let f = try fixture()
        // the cadence.test.mjs voice, built here as there
        let n = 600
        var pitch = Array(repeating: 0, count: n)
        for x in f.notes { for k in Int((x[0] * 100).rounded())..<Int((x[1] * 100).rounded()) { pitch[k] = Int(x[2]) } }
        let features = try JSONSerialization.data(withJSONObject: [
            "format": 1, "source": "vocals", "hop": 0.01, "floor": -57.5, "db": Array(repeating: -200, count: n),
            "voiced": Array(repeating: 1, count: n), "onset": Array(repeating: 0, count: n), "clarity": Array(repeating: 90, count: n),
            "pitch": pitch] as [String: Any])
        let line = TranscriptLine(id: "2000001", start: 1.2, end: 4.2, text: "Variations on a dream", words: [
            Word(text: "Variations", start: 1.2, end: 1.6), Word(text: "on", start: 1.6, end: 2.1),
            Word(text: "a", start: 3.6, end: 3.7), Word(text: "dream", start: 3.9, end: 4.2)])
        let out = try XCTUnwrap(SongLight.fit([line], features: features))
        XCTAssertEqual(out.count, 1)
        for (w, x) in zip(out[0].words, f.fitted) {
            XCTAssertEqual(w.start, x.s, accuracy: 1e-6, w.text)
            XCTAssertEqual(w.end, x.e, accuracy: 1e-6, w.text)
            XCTAssertEqual(w.syl, x.syl?.map { Syl(c: $0.c, s: $0.s, e: $0.e) }, w.text)
        }
        XCTAssertTrue(SongLight.sung(out[0]))
        // no voice to follow: nothing changes hands
        XCTAssertNil(SongLight.fit([line], features: Data(#"{"none":true}"#.utf8)))
        // the Worker's lines are in the file's time, the voice in the transcript's: `shift` between them changes nothing
        var moved = features
        var o = try XCTUnwrap(JSONSerialization.jsonObject(with: moved) as? [String: Any]); o["shift"] = 2.5
        moved = try JSONSerialization.data(withJSONObject: o)
        let later = TranscriptLine(id: line.id, start: line.start + 2.5, end: line.end + 2.5, text: line.text,
                                   words: line.words.map { $0.shifted(by: 2.5) })
        let out2 = try XCTUnwrap(SongLight.fit([later], features: moved))
        for (w, x) in zip(out2[0].words, f.fitted) {
            XCTAssertEqual(w.start, x.s + 2.5, accuracy: 1e-6, w.text)
            XCTAssertEqual(w.end, x.e + 2.5, accuracy: 1e-6, w.text)
        }
    }

    func testTheWorkersSyllablesAndTimingAreRead() throws {
        let d = Data("""
        {"lines":[{"id":2000001,"s":1,"e":2,"text":"on a","words":[
          {"t":"on","s":1,"e":1.5,"syl":[{"c":2,"s":1,"e":1.5}]},{"t":"a","s":1.5,"e":2,"un":true,"tm":{"s":1.5,"e":2,"k":0.3}}]}]}
        """.utf8)
        let ls = try XCTUnwrap(TranscriptSource.decode(d))
        XCTAssertEqual(ls[0].words[0].syl, [Syl(c: 2, s: 1, e: 1.5)])
        XCTAssertEqual(ls[0].words[1].un, true)
        XCTAssertEqual(ls[0].words[1].tm?.k, 0.3)
        XCTAssertNil(ls[0].words[0].un)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func add(_ p: String) { lock.lock(); all.append(p); lock.unlock() }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return all }
}
