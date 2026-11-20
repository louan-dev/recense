// Derived from Spec: FEAT-39 (P2 the iPad view). The manifest the Mac writes (sync/src/livestate.mjs), read by the iPad:
// decoding, the order rows come in, the age label (same boundaries as livestate.mjs ageLabel), the pair link, the
// hub address, the snapshot reply and the offline copy. The vectors below are the ones sync/test/livestate.test.mjs uses.
import XCTest
@testable import ShowsKit

final class LiveEditsTests: XCTestCase {
    // what livestate.mjs writes: a modified file, an untracked one, a deleted one (null hash and time), a binary
    static let json = #"""
    {"generated":"2026-11-19T20:00:00.000Z","worktrees":[
     {"name":"live-edits","path":"/Users/x/live-edits","branch":"work/live-edits","head":"abc123","files":[
      {"path":"a.txt","status":"M","mtime":"2026-11-19T19:59:30.250Z","sha256":"aa","added":1,"deleted":1,"binary":false,"state":"UNBUILT"},
      {"path":"gone.txt","status":"D","mtime":null,"sha256":null,"added":0,"deleted":2,"binary":false,"state":"UNKNOWN"},
      {"path":"new.txt","status":"?","mtime":"2026-11-19T19:58:00.000Z","sha256":"bb","added":4,"deleted":0,"binary":false,"state":"BUILT"},
      {"path":"pic.bin","status":"?","mtime":"2026-11-19T19:50:00.000Z","sha256":"cc","added":0,"deleted":0,"binary":true,"state":"UNKNOWN"}]},
     {"name":"intake","path":"/Users/x/intake","branch":"work/intake","head":"def456","files":[
      {"path":"z.swift","status":"M","mtime":"2026-11-19T19:59:50.000Z","sha256":"dd","added":9,"deleted":3,"binary":false,"state":"UNBUILT"}]}]}
    """#

    func manifest() throws -> LiveManifest { try JSONDecoder().decode(LiveManifest.self, from: Data(Self.json.utf8)) }

    func testDecodesWhatTheMacWrites() throws {
        let m = try manifest()
        XCTAssertEqual(m.generated, "2026-11-19T20:00:00.000Z")
        XCTAssertEqual(m.worktrees.map(\.name), ["live-edits", "intake"])
        let f = m.worktrees[0].files
        XCTAssertEqual(f.map(\.path), ["a.txt", "gone.txt", "new.txt", "pic.bin"])
        XCTAssertEqual([f[0].added, f[0].deleted], [1, 1]); XCTAssertEqual(f[0].status, "M"); XCTAssertEqual(f[0].state, "UNBUILT")
        XCTAssertNil(f[1].mtime); XCTAssertEqual(f[1].status, "D")
        XCTAssertTrue(f[3].binary)
        XCTAssertEqual(m.worktrees[0].branch, "work/live-edits")
    }

    func testToleratesMissingAndExtraKeys() throws {
        let d = Data(#"{"worktrees":[{"name":"w","files":[{"path":"p","status":"M","future":1}],"more":true}],"generated":null}"#.utf8)
        let m = try JSONDecoder().decode(LiveManifest.self, from: d)
        XCTAssertNil(m.generated); XCTAssertEqual(m.worktrees[0].files[0].added, 0); XCTAssertEqual(m.worktrees[0].branch, "")
        XCTAssertEqual(m.worktrees[0].files[0].state, "UNKNOWN"); XCTAssertFalse(m.worktrees[0].files[0].binary)
    }

    func testEmptyManifestIsValid() throws {
        let m = try JSONDecoder().decode(LiveManifest.self, from: Data(#"{"generated":null,"worktrees":[]}"#.utf8))
        XCTAssertTrue(m.worktrees.isEmpty); XCTAssertNil(m.generatedDate)
    }

    func testEditedParsesFractionalAndPlainTimes() throws {
        let f = try manifest().worktrees[0].files
        XCTAssertEqual(f[0].edited?.timeIntervalSince1970 ?? 0, 1_795_118_370.25, accuracy: 0.001)   // 2026-11-19T19:59:30.250Z
        XCTAssertNil(f[1].edited)
        XCTAssertNotNil(LiveFile.parse("2026-11-19T19:59:30Z")); XCTAssertNil(LiveFile.parse("yesterday"))
        XCTAssertEqual(try manifest().generatedDate?.timeIntervalSince1970 ?? 0, 1_795_118_400, accuracy: 0.001)
    }

    func testRowOrderIsNewestEditFirst() throws {
        let s = try manifest().sorted
        XCTAssertEqual(s.worktrees.map(\.name), ["intake", "live-edits"], "the worktree edited most recently leads")
        XCTAssertEqual(s.worktrees[1].files.map(\.path), ["a.txt", "new.txt", "pic.bin", "gone.txt"], "newest first; a deleted file has no time and goes last")
        let tie = LiveWorktree(name: "t", branch: "", head: "", files: [
            LiveFile(path: "b", status: "M", mtime: "2026-11-19T19:00:00.000Z"), LiveFile(path: "a", status: "M", mtime: "2026-11-19T19:00:00.000Z")])
        XCTAssertEqual(LiveManifest(generated: nil, worktrees: [tie]).sorted.worktrees[0].files.map(\.path), ["a", "b"], "equal times keep a stable order")
    }

    // ---- age label: boundaries on both sides, same as livestate.mjs ageLabel -------------------------------------------
    func testAgeBoundaries() {
        XCTAssertEqual(LiveAge.of(0), .justNow); XCTAssertEqual(LiveAge.of(59.999), .justNow)
        XCTAssertEqual(LiveAge.of(60), .minutes(1)); XCTAssertEqual(LiveAge.of(179), .minutes(2))
        XCTAssertEqual(LiveAge.of(3599.999), .minutes(59)); XCTAssertEqual(LiveAge.of(3600), .hours(1))
        XCTAssertEqual(LiveAge.of(86399.999), .hours(23)); XCTAssertEqual(LiveAge.of(86400), .days(1))
        XCTAssertEqual(LiveAge.of(-5), .justNow, "a clock a little ahead never shows a negative age")
    }

    // ---- the pair link (twin of editor/src/hubsync.js tokenFromHash) ---------------------------------------------------
    func testPairToken() {
        let t = String(repeating: "ab12", count: 16)   // 64 characters, like the hub's token
        XCTAssertEqual(LiveHub.pairToken(from: "https://recense.local/#pair=\(t)"), t)
        XCTAssertEqual(LiveHub.pairToken(from: "  https://recense.local/#pair=\(t)\n"), t, "paste often carries spaces and a newline")
        XCTAssertEqual(LiveHub.pairToken(from: "#pair=\(t)&x=1"), t)
        XCTAssertEqual(LiveHub.pairToken(from: t), t, "the bare token works too")
        XCTAssertNil(LiveHub.pairToken(from: "https://recense.local/#pair=short"))
        XCTAssertNil(LiveHub.pairToken(from: "https://recense.local/"))
        XCTAssertNil(LiveHub.pairToken(from: "hello world"))
        XCTAssertNil(LiveHub.pairToken(from: ""))
        XCTAssertNil(LiveHub.pairToken(from: "https://recense.local/#pair=\(t)extra words here"), "text that is not a link or a token is refused")
        XCTAssertEqual(LiveHub.pairToken(from: "https://recense.local/#pair=" + String(repeating: "a", count: 128)), String(repeating: "a", count: 128))
        XCTAssertNil(LiveHub.pairToken(from: "https://recense.local/#pair=" + String(repeating: "a", count: 129)))
    }

    // ---- the hub address: https only, so the token never travels in the clear -------------------------------------------
    func testHubAddress() {
        XCTAssertEqual(LiveHub.baseURL(from: "recense.local")?.absoluteString, "https://recense.local")
        XCTAssertEqual(LiveHub.baseURL(from: "https://recense.local/")?.absoluteString, "https://recense.local")
        XCTAssertEqual(LiveHub.baseURL(from: " https://mac.recense.local:8443 ")?.absoluteString, "https://mac.recense.local:8443")
        XCTAssertEqual(LiveHub.baseURL(from: "https://192.168.1.20")?.absoluteString, "https://192.168.1.20")
        XCTAssertNil(LiveHub.baseURL(from: "http://recense.local"), "plain http is refused")
        XCTAssertNil(LiveHub.baseURL(from: "")); XCTAssertNil(LiveHub.baseURL(from: "a b")); XCTAssertNil(LiveHub.baseURL(from: "https://"))
        XCTAssertEqual(LiveHub.endpoint(base: LiveHub.baseURL(from: "recense.local")!, "/api/live").absoluteString, "https://recense.local/api/live")
        XCTAssertEqual(LiveHub.defaultAddress, "https://recense.local")
    }

    func testRequestsCarryTheToken() throws {
        let base = try XCTUnwrap(LiveHub.baseURL(from: "recense.local"))
        let g = LiveHub.request(base: base, path: "/api/live", token: "tok", body: nil)
        XCTAssertEqual(g.httpMethod, "GET"); XCTAssertEqual(g.value(forHTTPHeaderField: "Authorization"), "Bearer tok"); XCTAssertNil(g.httpBody)
        XCTAssertEqual(g.timeoutInterval, 8, "a Mac that is not there gives up in 8 s; the list shows the last copy meanwhile")
        let p = LiveHub.request(base: base, path: "/api/live/snapshot", token: "tok", body: ["worktree": "live-edits"])
        XCTAssertEqual(p.httpMethod, "POST"); XCTAssertEqual(p.timeoutInterval, 130, "a snapshot can take a while on the Mac (the hub allows 120 s)")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(p.httpBody)) as? [String: String], ["worktree": "live-edits"])
    }

    // ---- why a refresh failed: a Mac out of reach and a device that does not trust the Mac look different to the person ----
    func testReachFromErrors() {
        XCTAssertEqual(LiveHub.reach(for: URLError(.timedOut)), .unreachable)
        XCTAssertEqual(LiveHub.reach(for: URLError(.cannotFindHost)), .unreachable, "recense.local did not resolve: not on the same Wi-Fi")
        XCTAssertEqual(LiveHub.reach(for: URLError(.notConnectedToInternet)), .unreachable)
        XCTAssertEqual(LiveHub.reach(for: URLError(.cannotConnectToHost)), .unreachable)
        XCTAssertEqual(LiveHub.reach(for: URLError(.serverCertificateUntrusted)), .untrusted)
        XCTAssertEqual(LiveHub.reach(for: URLError(.serverCertificateHasUnknownRoot)), .untrusted)
        XCTAssertEqual(LiveHub.reach(for: URLError(.secureConnectionFailed)), .untrusted)
        XCTAssertEqual(LiveHub.reach(for: URLError(.cancelled)), .cancelled, "a refresh that a newer one replaced is not an error")
        XCTAssertEqual(LiveHub.reach(for: NSError(domain: "x", code: 1)), .unreachable)
    }

    // ---- what the hub answers to a snapshot ---------------------------------------------------------------------------
    func testSnapshotReply() {
        let made = Data(#"{"ok":true,"status":"made","worktree":"w","sha":"aaaa","state":"UNBUILT","files":3,"zip":true}"#.utf8)
        XCTAssertEqual(LiveSnapshotReply.decode(status: 200, data: made), .made(files: 3, state: "UNBUILT", zip: true))
        let refused = Data(#"{"ok":false,"status":"refused","worktree":"w","reason":"secret","path":"notes.txt"}"#.utf8)
        XCTAssertEqual(LiveSnapshotReply.decode(status: 200, data: refused), .refused(reason: "secret", path: "notes.txt"))
        XCTAssertEqual(LiveSnapshotReply.decode(status: 200, data: Data(#"{"status":"refused","reason":"clean"}"#.utf8)), .refused(reason: "clean", path: nil))
        XCTAssertEqual(LiveSnapshotReply.decode(status: 401, data: Data(#"{"error":"no token"}"#.utf8)), .unauthorized, "a wrong token asks to pair again")
        XCTAssertEqual(LiveSnapshotReply.decode(status: 404, data: Data(#"{"error":"x"}"#.utf8)), .gone, "the worktree is clean now or was removed")
        XCTAssertEqual(LiveSnapshotReply.decode(status: 500, data: Data(#"{"status":"failed","error":"the snapshot did not finish (exit 127)"}"#.utf8)),
                       .failed("the snapshot did not finish (exit 127)"))
        XCTAssertEqual(LiveSnapshotReply.decode(status: 200, data: Data("not json".utf8)), .failed("unreadable answer"))
        XCTAssertEqual(LiveSnapshotReply.decode(status: 503, data: Data()), .failed("unreadable answer"))
    }

    // ---- the offline copy ----------------------------------------------------------------------------------------------
    func testLastCopyIsKeptAndDamageIsNotFatal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sub/live.json")
        XCTAssertNil(LiveCache.load(from: file), "nothing yet")
        XCTAssertTrue(LiveCache.save(Data(Self.json.utf8), to: file))
        XCTAssertEqual(LiveCache.load(from: file)?.worktrees.count, 2)
        try Data("{\"generated\":".utf8).write(to: file)   // a copy cut short never replaces an empty screen with a crash
        XCTAssertNil(LiveCache.load(from: file))
        XCTAssertFalse(LiveCache.save(Data("not a manifest".utf8), to: file), "only a readable manifest becomes the last copy")
        XCTAssertNil(LiveCache.load(from: file), "the refused save did not touch the damaged file either way")
    }

    func testChannelNamesAreValid() {
        for e in ["live.manifest.written", "live.manifest.skipped", "live.snapshot.made", "live.snapshot.refused", "live.view.refreshed"] {
            XCTAssertNotNil(DebugChannel.line(feature: "live", event: e, fields: ["source": "hub"]), e)
        }
        XCTAssertEqual(LiveSource.allCases.map(\.rawValue), ["lan", "hub", "r2", "cache"], "the spec's live.view.refreshed sources")
    }
}
