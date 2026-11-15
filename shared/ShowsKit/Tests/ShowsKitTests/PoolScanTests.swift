// Player P1 S3 (2026-11-13): Home shows what is on this device. Regression: it showed invented sample shows.
import XCTest
@testable import ShowsKit

final class PoolScanTests: XCTestCase {
    private func pool(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pool-\(UUID().uuidString)")
        for f in files {
            let u = root.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(f.utf8).write(to: u)
        }
        return root
    }

    func testListsThePoolsFilesOnlyWithKeys() throws {
        let root = try pool([
            "library/Bài giảng/Tuần 1.m4a", "library/Study/MPEP/2106.m4a", "downloads/archive/Cours/Séance 3.mp3",
            "downloads/.partial", "library/.show.json", "keep/abc/asr.json", "trash/old.m4a", "Recense.log",
        ])
        let items = PoolScan.items(root: root)
        XCTAssertEqual(items.map(\.path), ["downloads/archive/Cours/Séance 3.mp3", "library/Bài giảng/Tuần 1.m4a", "library/Study/MPEP/2106.m4a"])
        XCTAssertTrue(items.allSatisfy { $0.local && $0.key != nil && $0.id == Rules.fileID($0.path) })
        XCTAssertEqual(items[0].kind, .audio)
    }

    func testDownloadsAreNew() {
        XCTAssertEqual(Rules.place("downloads/archive/Cours/Séance 3.mp3")?.showFolder, Zone.inbox.folder)
        XCTAssertNil(Rules.place("downloads"))
    }

    func testHomeShowsWhatIsOnTheDevice() async throws {
        let root = try pool(["downloads/archive/Cours/Séance 3.mp3", "library/Bài giảng/Tuần 1.m4a"])
        let store = MemoryCatalog(device: "iphone")
        await store.replaceLocal(PoolScan.items(root: root))
        let model = await ShowsModel(store: store)
        await model.reload()
        let up = await model.upNext.map(\.episode.title)
        XCTAssertEqual(up, ["Séance 3"])                       // New's unplayed arrival
        let shows = try await store.shows(in: .library).map(\.title)
        XCTAssertTrue(shows.contains("Bài giảng"))
    }

    func testARescanKeepsMarksAndDropsGoneFiles() async throws {
        let root = try pool(["downloads/a.m4a", "downloads/b.m4a"])
        let store = MemoryCatalog(device: "iphone")
        await store.replaceLocal(PoolScan.items(root: root))
        let a = try XCTUnwrap(PoolScan.items(root: root).first)
        try await store.enqueue(.state(ItemState(key: a.key!, starred: Stamped(true, at: HLC(wall: 1, node: "iphone")))))
        try FileManager.default.removeItem(at: root.appendingPathComponent("downloads/b.m4a"))
        await store.replaceLocal(PoolScan.items(root: root))
        let left = try await store.search(Query()).map(\.path)
        XCTAssertEqual(left, ["downloads/a.m4a"])
        let starred = await store.state(of: a.key!)?.isStarred
        XCTAssertEqual(starred, true)
    }
}
