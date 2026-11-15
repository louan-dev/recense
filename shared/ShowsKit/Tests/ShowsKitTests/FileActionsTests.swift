// FEAT-13: "+" adds into the show's folder, Move to… moves between shows; FEAT-07's Rename and Delete stay as they are.
// The fake does what shared/homefiles.swift does: change the files on disk; the test then rescans the pool.
import XCTest
import CoreGraphics
@testable import ShowsKit

@MainActor
private final class DiskFiles: EpisodeFiles, ShowFolderFiles {
    let root: URL
    let store: MemoryCatalog
    init(root: URL, store: MemoryCatalog) { self.root = root; self.store = store }

    func rescan() async { await store.replaceLocal(PoolScan.items(root: root)) }
    func free(_ name: String, in dir: URL) -> URL {
        var u = dir.appendingPathComponent(name), n = 2
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: u.path) { u = dir.appendingPathComponent("\(base) \(n).\(ext)"); n += 1 }
        return u
    }

    func canChange(_ e: Episode) -> Bool { true }
    func rename(_ e: Episode, to name: String) throws {}
    func delete(_ e: Episode) throws {}

    func canAdd(to show: Show) -> Bool { show.folder.hasPrefix("library/") }
    func add(_ files: [URL], to show: Show) throws {
        let dir = root.appendingPathComponent(show.folder)
        for f in files { try FileManager.default.moveItem(at: f, to: free(f.lastPathComponent, in: dir)) }
    }
    func move(_ e: Episode, to show: Show) throws {
        let from = root.appendingPathComponent(e.item.path)
        try FileManager.default.moveItem(at: from, to: free(from.lastPathComponent, in: root.appendingPathComponent(show.folder)))
    }
    func thumbnail(for e: Episode, side: CGFloat) async -> CGImage? { nil }
}

/// A host with only FEAT-07's Rename and Delete (as before FEAT-13): no "+", no Move to….
@MainActor
private final class RenameOnly: EpisodeFiles {
    func canChange(_ e: Episode) -> Bool { true }
    func rename(_ e: Episode, to name: String) throws {}
    func delete(_ e: Episode) throws {}
}

@MainActor
final class FileActionsTests: XCTestCase {
    private func setUp(_ files: [String]) async throws -> (ShowsModel, DiskFiles, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feat13-\(UUID().uuidString)")
        for f in files {
            let u = root.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(f.utf8).write(to: u)
        }
        let store = MemoryCatalog(device: "iphone")
        let disk = DiskFiles(root: root, store: store)
        await disk.rescan()
        let m = ShowsModel(store: store)
        m.files = disk
        await m.reload()
        return (m, disk, root)
    }

    private func show(_ m: ShowsModel, _ title: String) throws -> Show {
        try XCTUnwrap(m.shows[.library]?.first { $0.title == title }, "\(title) is a show")
    }

    private func titles(_ m: ShowsModel, _ title: String) async throws -> [String] {
        await m.episodes(of: try show(m, title), season: nil).map(\.title).sorted()
    }

    private func episode(_ m: ShowsModel, _ show: String, _ title: String) async throws -> Episode {
        let all = await m.episodes(of: try self.show(m, show), season: nil)
        return try XCTUnwrap(all.first { $0.title == title }, "\(title) is in \(show)")
    }

    func testPlusAddsTheFileToTheShowsFolderWithoutOverwriting() async throws {
        let (m, disk, root) = try await setUp(["library/Bài giảng/Tuần 1.m4a", "library/Cours/Séance 1.mp3"])
        let picked = FileManager.default.temporaryDirectory.appendingPathComponent("feat13-in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        let f = picked.appendingPathComponent("Tuần 1.m4a")
        try Data("new".utf8).write(to: f)
        let bg = try show(m, "Bài giảng")
        XCTAssertTrue(m.canAdd(to: bg), "+ shows on a folder the host takes files into")
        let before = m.revision
        m.add([f], to: bg)
        XCTAssertGreaterThan(m.revision, before, "the page reloads")
        await disk.rescan(); await m.reload()
        let got = try await titles(m, "Bài giảng")
        XCTAssertEqual(got, ["Tuần 1", "Tuần 1 2"], "a clash gets a new name; the old file stays")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("library/Bài giảng/Tuần 1.m4a"), encoding: .utf8),
                       "library/Bài giảng/Tuần 1.m4a", "never overwrites")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path), "moved, not copied")
        XCTAssertNil(m.problem)
    }

    func testMoveToTakesTheEpisodeIntoTheOtherShow() async throws {
        let (m, disk, _) = try await setUp(["library/Bài giảng/Tuần 1.m4a", "library/Bài giảng/Tuần 2.m4a", "library/Cours/Séance 1.mp3"])
        let e = try await episode(m, "Bài giảng", "Tuần 2")
        XCTAssertEqual(m.destinations(for: e).map(\.title), ["Cours"], "the other shows in the space, not itself, not New")
        m.move(e, to: try show(m, "Cours"))
        await disk.rescan(); await m.reload()
        do { let t = try await titles(m, "Bài giảng"); XCTAssertEqual(t, ["Tuần 1"]) }
        do { let t = try await titles(m, "Cours"); XCTAssertEqual(t, ["Séance 1", "Tuần 2"]) }
    }

    func testAFailedActionNamesTheFile() async throws {
        let (m, _, root) = try await setUp(["library/Cours/Séance 1.mp3", "library/Thèmes/Một.mp3"])
        let e = try await episode(m, "Cours", "Séance 1")
        try FileManager.default.removeItem(at: root.appendingPathComponent(e.item.path))
        m.move(e, to: try show(m, "Thèmes"))
        XCTAssertTrue(m.problem?.hasPrefix("Couldn't move Séance 1") == true, m.problem ?? "no problem shown")
    }

    func testAHostWithoutFolderWorkShowsNoPlusAndNoMove() async throws {
        let m = ShowsModel(store: MemoryCatalog.sample(device: "ipad"))
        await m.reload()
        let any = try XCTUnwrap(m.shows[.library]?.first { $0.id != Show.newID })
        XCTAssertFalse(m.canAdd(to: any), "no host: no +")
        m.files = RenameOnly()
        XCTAssertFalse(m.canAdd(to: any), "Rename and Delete only: still no +")
        let eps = await m.episodes(of: any, season: nil)
        let e = try XCTUnwrap(eps.first)
        XCTAssertEqual(m.destinations(for: e), [], "and no Move to…")
    }
}
