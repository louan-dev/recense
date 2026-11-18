// Derived from Spec: PLAN-1118 §11b · the debug channel. Same fixture as library/test/debuglog.test.mjs.
import XCTest
@testable import ShowsKit

final class DebugChannelTests: XCTestCase {
    private struct Fix: Decodable { struct C: Decodable { let feature: String; let event: String; let fields: [String: String]; let at: Double; let line: String? }; let cases: [C] }

    func testSameBytesAsTheJSTwin() throws {
        let u = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/debugchannel.json")
        let fix = try JSONDecoder().decode(Fix.self, from: Data(contentsOf: u))
        XCTAssertGreaterThan(fix.cases.count, 5)
        for c in fix.cases {
            XCTAssertEqual(DebugChannel.line(feature: c.feature, event: c.event, fields: c.fields, at: Date(timeIntervalSince1970: c.at / 1000)), c.line, c.event)
        }
    }

    func testWritesOneLinePerEventAndNeverThrows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        DebugChannel.event("carry", "carry.send", ["n": "1"], in: dir)
        DebugChannel.event("carry", "carry.apply", [:], in: dir)
        DebugChannel.event("carry", "other.x", [:], in: dir)                 // refused: not carry.*
        DebugChannel.event("carry", "carry.bad", [:], in: URL(fileURLWithPath: "/dev/null/nope"))   // unwritable: dropped
        DebugChannel.flush()
        let lines = try String(contentsOf: dir.appendingPathComponent("carry.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"event\":\"carry.send\""))
        XCTAssertTrue(lines[1].contains("\"event\":\"carry.apply\""))
    }

    func testOverFiveMegabytesRotatesToOne() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 5_000_000).write(to: dir.appendingPathComponent("m4b.jsonl"))
        DebugChannel.event("m4b", "m4b.done", [:], in: dir); DebugChannel.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("m4b.1.jsonl").path))
        XCTAssertLessThan(try Data(contentsOf: dir.appendingPathComponent("m4b.jsonl")).count, 1000)
    }
}
