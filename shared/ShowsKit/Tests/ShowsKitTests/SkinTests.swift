// B2: the skin's model, gate and views, over the sample pool.
import Foundation
import SwiftUI
import XCTest
@testable import ShowsKit

@MainActor
final class SkinTests: XCTestCase {
    func open() -> Gate { Gate { _ in nil } }
    func refused() -> Gate { Gate { _ in "No Face ID." } }

    func testSpacesAndShowsLoad() async {
        let m = ShowsModel(store: MemoryCatalog.sample(device: "ipad"), gate: refused())
        await m.reload()
        XCTAssertEqual(m.spaces.map(\.id), [.library, .study, .folio, .matters])
        XCTAssertEqual(m.shows[.library]?.first?.title, "New", "New sits first in Library")
        XCTAssertEqual(m.shows[.library]?.first?.episodeCount, 2)
        let mpep = m.shows[.study]?.first { $0.title == "MPEP" }
        XCTAssertEqual(mpep?.seasons.map(\.title), ["Chapter 700", "Chapter 2100"], "seasons in natural order")
        XCTAssertEqual(m.shows[.matters]?.first?.locked, true)
    }

    func testEpisodesInOrderAndBySeason() async throws {
        let m = ShowsModel(store: MemoryCatalog.sample(device: "ipad"), gate: refused())
        await m.reload()
        let mpep = try XCTUnwrap(m.shows[.study]?.first { $0.title == "MPEP" })
        let all = await m.episodes(of: mpep, season: nil)
        XCTAssertEqual(all.map(\.n), [1, 2, 3, 4, 5], "a manifest makes the show serial")
        XCTAssertEqual(all.first?.title, "2106 Patent subject matter eligibility")
        let ch700 = try XCTUnwrap(mpep.seasons.first { $0.title == "Chapter 700" })
        let one = await m.episodes(of: mpep, season: ch700.id)
        XCTAssertEqual(one.map(\.n), [5])
    }

    func testGateKeepsMattersShutUntilUnlocked() async throws {
        let shut = ShowsModel(store: MemoryCatalog.sample(device: "ipad"), gate: refused())
        await shut.reload()
        let client = try XCTUnwrap(shut.shows[.matters]?.first)
        let matters = try XCTUnwrap(shut.spaces.first { $0.id == .matters })
        XCTAssertTrue(shut.isLocked(matters))
        let none = await shut.episodes(of: client, season: nil)
        XCTAssertEqual(none.count, 0, "no rows while locked")
        await shut.gate.unlock()
        XCTAssertFalse(shut.gate.isOpen)
        XCTAssertEqual(shut.gate.message, "No Face ID.", "a refusal says why")

        let m = ShowsModel(store: MemoryCatalog.sample(device: "ipad"), gate: open())
        await m.reload()
        await m.gate.unlock()
        XCTAssertTrue(m.gate.isOpen)
        XCTAssertFalse(m.isLocked(matters))
        let rows = await m.episodes(of: client, season: nil)
        XCTAssertEqual(rows.map(\.title), ["Call notes"])
        m.gate.lock()
        XCTAssertTrue(m.isLocked(client), "locking again shuts it")
    }

    func testVerdictIsOneStampedRecordThatSyncs() async throws {
        let store = MemoryCatalog.sample(device: "ipad")
        let m = ShowsModel(store: store, gate: refused())
        await m.reload()
        let mpep = try XCTUnwrap(m.shows[.study]?.first { $0.title == "MPEP" })
        let eps = await m.episodes(of: mpep, season: nil)
        let e = try XCTUnwrap(eps.first)
        m.play(e)
        XCTAssertTrue(m.nowPlayingOpen)

        await m.setVerdict(.notYet, for: e)
        await m.setVerdict(.clicked, for: e)
        let k = try XCTUnwrap(e.item.key)
        let won = await store.state(of: k)
        XCTAssertEqual(won?.verdictValue, .clicked, "the later tap wins")
        XCTAssertEqual(m.playing?.state?.verdictValue, .clicked, "Now Playing shows it at once")
        let ops = await store.pending()
        XCTAssertEqual(ops.count, 2, "each tap waits in the outbox, offline")
        guard case .state(let s)? = ops.last?.change else { return XCTFail("a state op") }
        XCTAssertEqual(s.verdictValue, .clicked)
        XCTAssertNil(s.starred, "only the field that changed travels")

        await m.setVerdict(nil, for: e)
        let cleared = await store.state(of: k)
        XCTAssertNil(cleared?.verdictValue)
        XCTAssertNotNil(cleared?.verdict, "cleared is a stamped value, so it syncs too")

        await m.setStarred(true, for: e)
        await m.setFinished(true, for: e)
        let marked = await store.state(of: k)
        XCTAssertEqual(marked?.isStarred, true)
        XCTAssertNotNil(marked?.finishedAt)
    }

    func testVerdictMergesAndReadsOldRecords() throws {
        let k = key("a")
        let x = ItemState(key: k, verdict: Stamped(.notYet, at: HLC(wall: 1, node: "iphone")))
        let y = ItemState(key: k, starred: Stamped(true, at: HLC(wall: 1, node: "mac")), verdict: Stamped(.clicked, at: HLC(wall: 2, node: "mac")))
        XCTAssertEqual(x.merged(y), y.merged(x))
        XCTAssertEqual(x.merged(y).verdictValue, .clicked)
        let old = #"{"key":"aaaaaaaaaaaaaaaaaaaaaaaa","starred":{"value":true,"at":{"wall":1,"n":0,"node":"mac"}}}"#
        let read = try JSONDecoder().decode(ItemState.self, from: Data(old.utf8))
        XCTAssertNil(read.verdict, "a record from before B2 still reads")
        XCTAssertEqual(try JSONDecoder().decode(ItemState.self, from: JSONEncoder().encode(x.merged(y))), x.merged(y))
    }

    func testNoKeyMeansAProblemNotACrash() async {
        let store = MemoryCatalog(device: "ipad", items: [PoolItem(id: "x", path: "inbox/unread.m4a")])
        let m = ShowsModel(store: store, gate: refused())
        let e = Episode(item: PoolItem(id: "x", path: "inbox/unread.m4a"), show: Show.newID, title: "unread")
        await m.setVerdict(.clicked, for: e)
        XCTAssertNotNil(m.problem)
        let queued = await store.pending()
        XCTAssertEqual(queued.count, 0)
    }

    /// The Mac app builds ShowsKit with the Command Line Tools, which lack SwiftUI's macro plugin: @State, @Entry and
    /// #Preview fail there (11-07). @StateObject, @Observable and @Bindable are fine.
    func testNoSwiftUIMacros() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/ShowsKit")
        let files = FileManager.default.enumerator(at: src, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 5)
        let bad = try NSRegularExpression(pattern: #"^\s*[^/\s].*(@State\b(?!Object)|@Entry\b|#Preview\b)"#, options: [.anchorsMatchLines])
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            XCTAssertNil(bad.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "\(f.lastPathComponent) uses a SwiftUI macro")
        }
    }

    func testFeedsForHomeAndLibrary() async throws {
        let m = ShowsModel(store: MemoryCatalog.sample(device: "ipad"), gate: refused())
        await m.reload()
        XCTAssertEqual(m.upNext.first?.episode.title, "2106 Patent subject matter eligibility", "started and unfinished comes first")
        XCTAssertEqual(m.upNext.first?.remaining, 272)
        XCTAssertEqual(m.upNext.map(\.episode.title), ["2106 Patent subject matter eligibility", "Reading statutes in two languages",
                                                      "Voice memo, 6 November", "Lecture clip: treaty interpretation"],
                       "started and unfinished, newest listen first; then New's arrivals, newest first")
        XCTAssertEqual(m.recentlyPlayed.map(\.episode.title), ["2106 Patent subject matter eligibility", "Reading statutes in two languages"])
        XCTAssertEqual(m.recentlyPlayed.last?.showTitle, "Law and Language")
        let saved = await m.entries(.saved)
        XCTAssertEqual(saved.map(\.episode.title), ["2111 Claim interpretation"])
        let latest = await m.entries(.latest)
        XCTAssertFalse(latest.contains { $0.episode.item.locked }, "Matters stays out while locked")
        XCTAssertEqual(m.recentlyUpdated.first?.show.title, "New")

        let open = ShowsModel(store: MemoryCatalog.sample(device: "ipad"), gate: Gate { _ in nil })
        await open.unlock("Matters")
        let all = await open.entries(.latest)
        XCTAssertTrue(all.contains { $0.episode.title == "Call notes" }, "and joins once unlocked")
        open.lock()
        XCTAssertFalse(open.gate.isOpen)
    }

    func testMiniPlayerOpensNowPlayingUntilThereIsATransport() async {
        let m = ShowsModel(store: MemoryCatalog.sample(device: "ipad"), gate: refused())
        await m.reload()
        m.togglePlay()
        XCTAssertTrue(m.nowPlayingOpen, "no transport yet: play opens Now Playing")
        final class T: Transport { var isPlaying = false; var skipped = 0.0
            func toggle() { isPlaying.toggle() }; func skip(_ s: Double) { skipped += s } }
        let t = T(); m.transport = t; m.nowPlayingOpen = false
        m.togglePlay()
        XCTAssertTrue(t.isPlaying); XCTAssertFalse(m.nowPlayingOpen)
    }

    func testArtworkHuesAreStablePerName() {
        let a = Theme.hues("MPEP"), b = Theme.hues("MPEP"), c = Theme.hues("Folio")
        XCTAssertEqual("\(a.0)", "\(b.0)")
        XCTAssertNotEqual("\(a.0)", "\(c.0)")
    }

    /// Each view lays out and draws with real rows (a crash or a layout trap fails here).
    @available(macOS 15, *)
    func testViewsRender() async throws {
        let m = ShowsModel(store: MemoryCatalog.sample(device: "mac"), gate: refused())
        await m.reload()
        let mpep = try XCTUnwrap(m.shows[.study]?.first { $0.title == "MPEP" })
        let eps = await m.episodes(of: mpep, season: nil)
        let e = try XCTUnwrap(eps.first)
        m.play(e)
        let matters = try XCTUnwrap(m.spaces.first { $0.id == .matters })
        let views: [(String, AnyView)] = [
            ("root", AnyView(ShowsRoot(model: m, places: [Place(id: "d", title: "Draftpad", symbol: "square.and.pencil") { Text("pad") }]) { _ in Text("player") })),
            ("home", AnyView(NavigationStack { HomeView(model: m) })),
            ("new", AnyView(NavigationStack { NewView(model: m) })),
            ("library", AnyView(NavigationStack { LibraryView(model: m, places: []) })),
            ("search", AnyView(NavigationStack { SearchView(model: m) })),
            ("list", AnyView(NavigationStack { EntryList(model: m, feed: .latest, title: "Latest") })),
            ("grid", AnyView(NavigationStack { ShowsGrid(model: m, shows: m.allShows, title: "Shows") })),
            ("show", AnyView(NavigationStack { ShowPage(model: m, show: mpep) })),
            ("episode", AnyView(EpisodeRow(model: m, episode: e))),
            ("card", AnyView(UpNextCard(model: m, entry: try XCTUnwrap(m.upNext.first)))),
            ("played", AnyView(EntryRow(model: m, entry: try XCTUnwrap(m.recentlyPlayed.first)))),
            ("locked", AnyView(SpaceScreen(model: m, space: matters))),
            ("mini", AnyView(MiniPlayer(model: m))),
            ("now", AnyView(NowPlaying(model: m) { _ in Text("player") })),
            ("verdict", AnyView(VerdictBar(chosen: .clicked) { _ in })),
            ("artwork", AnyView(Artwork(title: "MPEP").frame(width: 160))),
            ("header", AnyView(NavigationStack { SectionHeader("Up Next") { Text("more") } })),
            ("row", AnyView(LibraryRow("Shows", symbol: "square.stack"))),
            ("place", AnyView(Place(id: "d", title: "Draftpad", symbol: "square.and.pencil") { Text("pad") }.screen())),
        ]
        for (name, v) in views {
            let r = ImageRenderer(content: v.frame(width: 390, height: 700))
            XCTAssertNotNil(r.cgImage, "\(name) draws")
        }
    }
}
