import Foundation
import XCTest
@testable import ShowsKit

let day: Int64 = 86_400
func key(_ c: Character) -> ContentKey { ContentKey(rawValue: String(repeating: c, count: 24))! }

final class ModelTests: XCTestCase {
    // Vectors from the Worker's own fingerprintKey (library/src/transcript.js), run in Node on the same bytes.
    func testContentKeyMatchesTheWorker() throws {
        let small = Data("hello".utf8)
        let big = Data((0..<200_000).map { UInt8($0 % 251) })
        XCTAssertEqual(ContentKey.of(size: 5, head: small, tail: small).rawValue, "64e2eb423663d0cf6086fe88")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = dir.appendingPathComponent("small.m4a"), b = dir.appendingPathComponent("big.m4a"), e = dir.appendingPathComponent("empty")
        try small.write(to: s); try big.write(to: b); try Data().write(to: e)
        XCTAssertEqual(ContentKey.ofFile(s)?.rawValue, "64e2eb423663d0cf6086fe88")
        XCTAssertEqual(ContentKey.ofFile(b)?.rawValue, "33b336ce731fc2aa115bcaad")
        XCTAssertNil(ContentKey.ofFile(e))
        XCTAssertNil(ContentKey(rawValue: "ABCDEFABCDEFABCDEFABCDEF"))
        XCTAssertNil(ContentKey(rawValue: "abc"))
        XCTAssertThrowsError(try JSONDecoder().decode([ContentKey].self, from: Data(#"["zz"]"#.utf8)))
    }

    func testClockIsMonotonicAndFollowsAFasterPeer() {
        var c = HLCClock(node: "iphone")
        let a = c.now(wall: 1000), b = c.now(wall: 1000), d = c.now(wall: 900)   // the wall clock stepped back
        XCTAssert(a < b && b < d, "\(a) \(b) \(d)")
        let peer = HLC(wall: 5000, n: 7, node: "mac")
        let r = c.receive(peer, wall: 1001)
        XCTAssert(r > peer)
        XCTAssert(c.now(wall: 1002) > r)
        XCTAssert(HLC(wall: 1, n: 0, node: "a") < HLC(wall: 1, n: 0, node: "b"), "ties break on the node: one order everywhere")
    }

    func testStateMergeIsTheSameInEitherOrder() {
        let k = key("a")
        let x = ItemState(key: k, starred: Stamped(true, at: HLC(wall: 2, node: "mac")), finished: Stamped(100, at: HLC(wall: 1, node: "mac")))
        let y = ItemState(key: k, starred: Stamped(false, at: HLC(wall: 1, node: "ipad")), finished: Stamped(nil, at: HLC(wall: 3, node: "ipad")),
                          title: Stamped("Ch. 2100", at: HLC(wall: 1, node: "ipad")))
        XCTAssertEqual(x.merged(y), y.merged(x))
        let m = x.merged(y)
        XCTAssertTrue(m.isStarred)
        XCTAssertNil(m.finishedAt, "marked unplayed later wins")
        XCTAssertEqual(m.title?.value, "Ch. 2100")
        let back = try! JSONDecoder().decode(ItemState.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m, "a cleared field (null) survives the round trip")
        XCTAssertNotNil(back.finished, "cleared is not the same as never set")
    }

    func testIdsFollowFpJs() {
        // vectors from fp.js's own fileId and folderId, run in Node
        XCTAssertEqual(Rules.fileID("a.m4a"), "hb69595b1bd6fb83603ac5481")
        XCTAssertEqual(Rules.folderID("Music"), "d2a1f54c5f4d6876640597f36")
    }

    // The outbox's JSON is what the Worker's /v1/commit will read (B4): frozen here.
    func testOutboxWireFormat() throws {
        let json = #"{"opId":"6f1c0e3a-0000-4000-8000-000000000001","seq":3,"device":"iphone","at":{"wall":1762400000000,"n":0,"node":"iphone"},"change":{"type":"put","path":"inbox/memo.m4a","key":"aaaaaaaaaaaaaaaaaaaaaaaa","size":5,"mtime":1762400000}}"#
        let op = try JSONDecoder().decode(OutboxOp.self, from: Data(json.utf8))
        XCTAssertEqual(op.change, .put(path: "inbox/memo.m4a", key: key("a"), size: 5, mtime: 1_762_400_000))
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let back = try JSONSerialization.jsonObject(with: enc.encode(op)) as! NSDictionary
        XCTAssertEqual(back, try JSONSerialization.jsonObject(with: Data(json.utf8)) as! NSDictionary)
        let all: [OutboxOp.Change] = [
            .folder(path: "library/Study"), .move(id: "h1", from: "inbox/a.m4a", to: "library/X/a.m4a"),
            .delete(id: "h1", path: "library/X/a.m4a"), .state(ItemState(key: key("b"), starred: Stamped(true, at: .zero))),
            .listen(ListenPosition(device: "ipad", key: key("b"), seconds: 12.5, at: HLC(wall: 9, node: "ipad"))),
        ]
        for c in all { XCTAssertEqual(try JSONDecoder().decode(OutboxOp.Change.self, from: enc.encode(c)), c) }
        XCTAssertThrowsError(try JSONDecoder().decode(OutboxOp.Change.self, from: Data(#"{"type":"rm"}"#.utf8)))
    }

    // The shape fp.js answers GET …/changes with, a v1 op name, and a held mass delete.
    func testChangesPageReadsTheWorkersAnswer() throws {
        let json = #"{"seq":12,"more":false,"held":{"deletes":140,"known":900,"at":1762400000000},"events":[{"op":"create","id":"h000000000000000000000000","path":"a.m4a","dir":false,"size":1,"etag":"\"e\"","md5":"x","mtime":1,"chain":"e704"},{"op":"move","id":"h1","path":"b.m4a","from":"a.m4a","dir":false},{"op":"delete","id":"d2","path":"Old","dir":true},{"op":"tombstone","id":"h3","path":"c.m4a"},{"op":"skip","id":"h4","path":"d.m4a"}]}"#
        let p = try JSONDecoder().decode(ChangesPage.self, from: Data(json.utf8))
        XCTAssertEqual(p.seq, 12)
        XCTAssertEqual(p.held?.deletes, 140)
        XCTAssertEqual(p.events.map(\.applied), [.create, .move, .delete, .delete, nil])
        XCTAssertEqual(p.events[1].from, "a.m4a")
    }

    // What library/chau/show.mjs writes (its extra fields are ignored).
    func testShowManifestReadsShowMjs() throws {
        let json = #"{"title":"Study Feed","description":"d","lang":"vi","voice":"Linh","updated":"2026-11-06T00:00:00.000Z","licensed":true,"episodes":[{"n":1,"id":"e1","title":"Offer","file":"01 Offer.m4a","duration":392,"summary":"s"}]}"#
        let m = try JSONDecoder().decode(ShowManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.licensed, true)
        XCTAssertEqual(m.episodes.first?.file, "01 Offer.m4a")
        XCTAssertEqual(m.episodes.first?.duration, 392)
    }
}

final class RulesTests: XCTestCase {
    func testLayout() {
        func p(_ s: String) -> [String?]? { Rules.place(s).map { [$0.space.rawValue, $0.showFolder, $0.seasonFolder] } }
        XCTAssertEqual(p("inbox/memo.m4a"), ["library", "inbox", nil])
        XCTAssertEqual(p("library/Podcasts/ep.mp3"), ["library", "library/Podcasts", nil])
        XCTAssertEqual(p("library/Podcasts/2025/ep.mp3"), ["library", "library/Podcasts", "library/Podcasts/2025"])
        XCTAssertEqual(p("library/Podcasts/2025/deep/ep.mp3"), ["library", "library/Podcasts", "library/Podcasts/2025"])
        XCTAssertEqual(p("library/Study/MPEP/ch2100.pdf"), ["study", "library/Study/MPEP", nil])
        XCTAssertEqual(p("library/study/MPEP/2100/ch2100.pdf"), ["study", "library/study/MPEP", "library/study/MPEP/2100"])
        XCTAssertEqual(p("library/Folio/Essays/a.md"), ["folio", "library/Folio/Essays", nil])
        XCTAssertEqual(p("library/Matters/Client A/call.m4a"), ["matters", "library/Matters/Client A", nil])
        XCTAssertEqual(p("library/Raven/Client B/call.m4a"), ["matters", "library/Raven/Client B", nil])
        for none in ["library/loose.m4a", "library/Study/loose.pdf", "library/Podcasts/.show.json", "keep/aaa/asr.json",
                     ".trash/inbox/a.m4a", "inbox", "elsewhere/a/b.m4a"] {
            XCTAssertNil(Rules.place(none), none)
        }
    }

    func testLocks() {
        XCTAssertTrue(Rules.locked("library/Matters/Client A/x.m4a"))
        XCTAssertTrue(Rules.locked("inbox/raven/x.m4a"))
        XCTAssertFalse(Rules.locked("library/Mattersmith/x.m4a"))
        XCTAssertFalse(Show(id: "d", space: .matters, folder: "library/Matters/A", title: "A", episodeCount: 1, locked: true).shareable)
        XCTAssertFalse(Show(id: "d", space: .study, folder: "library/Study/PLI", title: "PLI", episodeCount: 1, licensed: true).shareable)
    }

    func testExpiry() {
        let now: Int64 = 100 * day
        func item(_ path: String, added: Int64, local: Bool = true) -> PoolItem { PoolItem(id: "h", path: path, key: key("a"), added: added, local: local) }
        XCTAssertFalse(Rules.evictable(item("inbox/a.m4a", added: now - 13 * day), state: nil, now: now))
        XCTAssertTrue(Rules.evictable(item("inbox/a.m4a", added: now - 14 * day), state: nil, now: now))
        let done = ItemState(key: key("a"), finished: Stamped(now - 3 * day, at: .zero))
        XCTAssertTrue(Rules.evictable(item("inbox/a.m4a", added: now - day), state: done, now: now), "3 days after finished")
        let star = ItemState(key: key("a"), starred: Stamped(true, at: .zero))
        XCTAssertFalse(Rules.evictable(item("inbox/a.m4a", added: 0), state: star, now: now), "starred never expires")
        for kept in ["inbox/PLI week 3.m4a", "inbox/Contract Law 1.m4a", "inbox/Raven/call.m4a", "inbox/study/a.m4a"] {
            XCTAssertFalse(Rules.evictable(item(kept, added: 0), state: nil, now: now), kept)
        }
        XCTAssertTrue(Rules.evictable(item("inbox/lawn care.m4a", added: 0), state: nil, now: now), "a word, not a substring")
        XCTAssertFalse(Rules.evictable(item("library/Podcasts/a.m4a", added: 0), state: nil, now: now), "only New expires")
        XCTAssertFalse(Rules.evictable(item("inbox/scan.pdf", added: 0), state: nil, now: now), "only media expires")
        XCTAssertFalse(Rules.evictable(item("inbox/a.m4a", added: 0, local: false), state: nil, now: now), "nothing to evict")
    }

    func testFilters() {
        let shot = PoolItem(id: "1", path: "inbox/Screenshot 2026-11-06 at 9.png")
        let vid = PoolItem(id: "2", path: "library/Clips/a.mov", local: false)
        let gone = PoolItem(id: "3", path: ".trash/inbox/a.m4a")
        XCTAssertTrue(Rules.matches(.screenshots, shot, transcribed: false))
        XCTAssertTrue(Rules.matches(.new, shot, transcribed: false))
        XCTAssertTrue(Rules.matches(.videos, vid, transcribed: false))
        XCTAssertFalse(Rules.matches(.downloads, vid, transcribed: false))
        XCTAssertTrue(Rules.matches(.trash, gone, transcribed: true))
        XCTAssertFalse(Rules.matches(.recensed, gone, transcribed: true))
        XCTAssertFalse(Rules.matches(.media, gone, transcribed: false))
    }

    func testContinueFrom() {
        let k = key("a")
        let mine = ListenPosition(device: "mac", key: k, seconds: 10, at: HLC(wall: 1, node: "mac"))
        let ipad = ListenPosition(device: "ipad", key: k, seconds: 600, at: HLC(wall: 2, node: "ipad"))
        XCTAssertEqual(Rules.continueFrom([mine, ipad], here: "mac"), ipad)
        XCTAssertNil(Rules.continueFrom([mine, ipad], here: "ipad"), "its own record is the newest")
        let near = ListenPosition(device: "ipad", key: k, seconds: 13, at: HLC(wall: 2, node: "ipad"))
        XCTAssertNil(Rules.continueFrom([mine, near], here: "mac"), "within 5 s: nothing to offer")
    }
}

/// The store contract, through the protocols only, so any CatalogStore runs it. B1: call `CatalogContract.run` with a
/// fresh store of yours (device "mac", empty) in your own test case.
enum CatalogContract {
    static func ev(_ id: String, _ path: String, dir: Bool = false, mtime: Int64 = 1) -> CatalogEvent {
        CatalogEvent(op: .create, id: id, path: path, dir: dir, size: dir ? nil : 10, mtime: mtime)
    }

    static func run(_ s: some CatalogStore, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertEqual(s.device, "mac", file: file, line: line)
        try await assertEqual(await s.spaces().map(\.id), [.library, .study, .folio, .matters], file: file, line: line)

        // the feed: a page applies once, in order
        let first = ChangesPage(seq: 5, events: [
            ev("h1", "inbox/memo.m4a", mtime: 30), ev("h2", "library/Podcasts/2025/ep1.mp3", mtime: 10),
            ev("h3", "library/Podcasts/2025/ep2.mp3", mtime: 20), ev("h4", "library/Empty/.show.json"),
            ev("d5", "library/Empty", dir: true), ev("h6", "library/Matters/Client A/call.m4a"),
            ev("h7", "library/Study/MPEP/ch2100.pdf"),
        ], more: false)
        try await assertNil(await s.cursor(root: "pool"), file: file, line: line)
        let applied = try await s.apply(first, root: "pool", since: nil)
        XCTAssertTrue(applied, file: file, line: line)
        let replayed = try await s.apply(first, root: "pool", since: nil)
        XCTAssertFalse(replayed, "a replayed page changes nothing", file: file, line: line)
        let skipped = try await s.apply(ChangesPage(seq: 9, events: [ev("h9", "inbox/x.m4a")], more: false), root: "pool", since: 7)
        XCTAssertFalse(skipped, "out of order", file: file, line: line)
        try await assertEqual(await s.cursor(root: "pool"), 5, file: file, line: line)
        let gone = try await s.apply(ChangesPage(seq: 6, events: [CatalogEvent(op: .move, id: "h3", path: "library/Podcasts/2025/ep2 (final).mp3", dir: false, from: "library/Podcasts/2025/ep2.mp3")], more: false), root: "pool", since: 5)
        XCTAssertTrue(gone, file: file, line: line)

        // shows: New first, empty hidden, seasons from subfolders, locks flagged
        let lib = try await s.shows(in: .library)
        XCTAssertEqual(lib.map(\.title), ["New", "Podcasts"], file: file, line: line)
        XCTAssertEqual(lib[1].seasons.map(\.title), ["2025"], file: file, line: line)
        XCTAssertEqual(lib[1].episodeCount, 2, file: file, line: line)
        let matters = try await s.shows(in: .matters)
        XCTAssertEqual(matters.map(\.locked), [true], file: file, line: line)
        let eps = try await s.episodes(of: lib[1].id, season: nil)
        XCTAssertEqual(eps.map(\.title), ["ep2 (final)", "ep1"], "newest first; the move applied", file: file, line: line)
        let season = try await s.episodes(of: lib[1].id, season: lib[1].seasons[0].id)
        XCTAssertEqual(season.count, 2, file: file, line: line)
        do { _ = try await s.episodes(of: "d-none", season: nil); XCTFail("unknown show", file: file, line: line) } catch {}

        // search: locked items only behind the gate
        let calls = try await s.search(Query(text: "call"))
        XCTAssertEqual(calls.count, 0, file: file, line: line)
        let gated = try await s.search(Query(text: "call", includeLocked: true))
        XCTAssertEqual(gated.map(\.id), ["h6"], file: file, line: line)
        let study = try await s.search(Query(space: .study))
        XCTAssertEqual(study.map(\.id), ["h7"], file: file, line: line)

        // the outbox: seq order, stamped, applied here at once, acknowledged away
        let k = key("c")
        let o1 = try await s.enqueue(.state(ItemState(key: k, starred: Stamped(true, at: HLC(wall: 1, node: "mac")))))
        let o2 = try await s.enqueue(.listen(ListenPosition(device: "mac", key: k, seconds: 42, at: HLC(wall: 2, node: "mac"))))
        XCTAssertLessThan(o1.seq, o2.seq, file: file, line: line)
        XCTAssertLessThan(o1.at, o2.at, file: file, line: line)
        try await assertEqual(await s.pending().map(\.opId), [o1.opId, o2.opId], file: file, line: line)
        try await assertEqual(await s.state(of: k)?.isStarred, true, file: file, line: line)
        await s.acknowledge([o1.opId, "unknown"])
        try await assertEqual(await s.pending().map(\.opId), [o2.opId], file: file, line: line)

        // another device's op applies once
        let theirs = OutboxOp(device: "ipad", at: HLC(wall: 50, node: "ipad"),
                              change: .state(ItemState(key: k, starred: Stamped(false, at: HLC(wall: 50, node: "ipad")))))
        let took = try await s.receive(theirs)
        XCTAssertTrue(took, file: file, line: line)
        let again = try await s.receive(theirs)
        XCTAssertFalse(again, "the same opId twice", file: file, line: line)
        try await assertEqual(await s.state(of: k)?.isStarred, false, file: file, line: line)
        let older = OutboxOp(device: "ipad", at: HLC(wall: 3, node: "ipad"),
                             change: .state(ItemState(key: k, starred: Stamped(true, at: HLC(wall: 0, node: "ipad")))))
        _ = try await s.receive(older)
        try await assertEqual(await s.state(of: k)?.isStarred, false, "an older stamp loses", file: file, line: line)
        let mine = try await s.enqueue(.listen(ListenPosition(device: "mac", key: k, seconds: 43, at: HLC(wall: 4, node: "mac"))))
        XCTAssertGreaterThan(mine.at, theirs.at, "stamps after a received op sort after it", file: file, line: line)
        _ = try await s.receive(OutboxOp(device: "ipad", at: HLC(wall: 60, node: "ipad"),
                                         change: .listen(ListenPosition(device: "ipad", key: k, seconds: 900, at: HLC(wall: 60, node: "ipad")))))
        try await assertEqual(await s.positions(of: k).map(\.device), ["ipad", "mac"], file: file, line: line)
    }
}

final class MemoryCatalogTests: XCTestCase {
    func testContract() async throws { try await CatalogContract.run(MemoryCatalog(device: "mac")) }

    func testManifestTitlesAndSerialOrder() async throws {
        let m = ShowManifest(title: "Study Feed", licensed: true, episodes: [
            .init(n: 1, title: "Offer", file: "02 b.m4a", duration: 392), .init(n: 2, title: "Acceptance", file: "01 a.m4a"),
        ])
        let s = MemoryCatalog(device: "mac", items: [
            PoolItem(id: "h1", path: "library/Study/Feed/01 a.m4a", mtime: 9), PoolItem(id: "h2", path: "library/Study/Feed/02 b.m4a", mtime: 1),
        ], manifests: ["library/Study/Feed": m])
        let show = try await s.shows(in: .study)[0]
        XCTAssertEqual(show.title, "Study Feed")
        XCTAssertTrue(show.serial && show.licensed && !show.shareable)
        try await assertEqual(try await s.episodes(of: show.id, season: nil).map(\.title), ["Offer", "Acceptance"])
    }

    func testUpdatesYield() async throws {
        let s = MemoryCatalog(device: "mac")
        let stream = await s.updates()
        var it = stream.makeAsyncIterator()
        _ = await s.enqueue(.folder(path: "library/New Show"))
        let got: Void? = await it.next()
        XCTAssertNotNil(got)
    }

    func testDeleteGoesToTrashAndPutNeverOverwrites() async throws {
        let s = MemoryCatalog(device: "mac", items: [PoolItem(id: "h1", path: "inbox/a.m4a", key: key("a"))])
        _ = try await s.enqueue(.put(path: "inbox/a.m4a", key: key("b"), size: 1, mtime: 1))
        try await assertEqual(await s.item(key: key("a"))?.path, "inbox/a.m4a")
        try await assertNil(await s.item(key: key("b")), "a taken path is never replaced")
        _ = try await s.enqueue(.delete(id: "h1", path: "inbox/a.m4a"))
        try await assertEqual(await s.item(key: key("a"))?.path, ".trash/inbox/a.m4a")
        try await assertEqual(await s.search(Query(filter: .trash)).map(\.id), ["h1"])
        try await assertEqual(try await s.shows(in: .library).count, 0, "New is empty, so hidden")
    }
}

func assertEqual<T: Equatable>(_ a: @autoclosure () async throws -> T, _ b: @autoclosure () throws -> T, _ m: String = "",
                               file: StaticString = #filePath, line: UInt = #line) async throws {
    let x = try await a()
    XCTAssertEqual(x, try b(), m, file: file, line: line)
}

func assertNil<T>(_ a: @autoclosure () async throws -> T?, _ m: String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
    let x = try await a()
    XCTAssertNil(x, m, file: file, line: line)
}
