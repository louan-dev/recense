// Derived from Spec: FEAT-07 P0
// Rename and Delete for the skin's rows, over the homes (shared/homes.swift), one copy for the Mac, iPhone and iPad.
// A rename renames the file in place, so Carry's next scan is a move (same SHA-256, new path) every paired device
// replays; a delete puts it in Trash with its origin, so Restore works and Carry replays the trash. No network.
import Foundation
import CoreGraphics
import QuickLookThumbnailing
import ShowsKit

@MainActor final class HomeFiles: EpisodeFiles, ShowFolderFiles {
    /// The host reads the pool again after a change (the catalog then shows the new name, or no row).
    var rescan: () -> Void

    /// This device's saved transcripts (iOS); a move takes the moved file's copy along. Nil on the Mac (keep/ is by content).
    var transcripts: TranscriptCache?

    init(rescan: @escaping () -> Void) { self.rescan = rescan }

    /// "library/Music/Faili.m4a" → (Music, "Faili.m4a"): the home a pool path sits in, Trash never.
    nonisolated static func place(_ poolPath: String) -> (home: Home, path: String)? {
        for h in Home.allCases where h != .trash {
            let prefix = h.folder + "/"
            if poolPath.hasPrefix(prefix), poolPath.count > prefix.count { return (h, String(poolPath.dropFirst(prefix.count))) }
        }
        return nil
    }

    func canChange(_ e: ShowsKit.Episode) -> Bool {
        guard let p = Self.place(e.item.path) else { return false }
        return FileManager.default.fileExists(atPath: Homes.url(p.home).appendingPathComponent(p.path).path)
    }

    func rename(_ e: ShowsKit.Episode, to name: String) throws {
        guard let p = Self.place(e.item.path) else { throw Homes.Failure.missing(e.item.path) }
        try Homes.rename(try Homes.entry(at: p.path, in: p.home), to: name, in: p.home)
        rescan()
    }

    func delete(_ e: ShowsKit.Episode) throws {
        guard let p = Self.place(e.item.path) else { throw Homes.Failure.missing(e.item.path) }
        try Homes.remove(try Homes.entry(at: p.path, in: p.home), from: p.home)
        rescan()
    }

    // MARK: FEAT-13, the show page: "+", Move to…, thumbnails

    /// A show's folder → its home and the subfolder inside it ("library/Music/Chopin" → Music, "Chopin"); Trash never.
    nonisolated static func folder(_ poolFolder: String) -> (home: Home, sub: String)? {
        for h in Home.allCases where h != .trash {
            if poolFolder == h.folder { return (h, "") }
            if poolFolder.hasPrefix(h.folder + "/") { return (h, String(poolFolder.dropFirst(h.folder.count + 1))) }
        }
        return nil
    }

    func canAdd(to show: ShowsKit.Show) -> Bool { Self.folder(show.folder) != nil }

    func add(_ files: [URL], to show: ShowsKit.Show) throws {
        guard let (h, sub) = Self.folder(show.folder) else { throw Homes.Failure.missing(show.folder) }
        defer { rescan() }   // the ones that landed show even if a later one fails
        for f in files {
            let scoped = f.startAccessingSecurityScopedResource()
            defer { if scoped { f.stopAccessingSecurityScopedResource() } }
            // a file another app's provider won't let go of (iCloud Drive, a server) arrives as a copy; it stays there too
            do { _ = try Homes.add(f, to: h, move: true, subfolder: sub) } catch { _ = try Homes.add(f, to: h, move: false, subfolder: sub) }
        }
    }

    /// Moved in place, never overwriting: the same SHA-256 at a new path, so Carry's next scan replays it as a move.
    func move(_ e: ShowsKit.Episode, to show: ShowsKit.Show) throws {
        guard let from = Self.place(e.item.path), let to = Self.folder(show.folder) else { throw Homes.Failure.missing(e.item.path) }
        let entry = try Homes.entry(at: from.path, in: from.home)
        let dir = to.sub.isEmpty ? Homes.url(to.home) : Homes.url(to.home).appendingPathComponent(to.sub, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = Homes.file(entry, in: from.home)
        let dest = dir.appendingPathComponent(Homes.freeName(source.lastPathComponent, in: dir))
        try FileManager.default.moveItem(at: source, to: dest)
        defer { rescan() }   // the file has moved: the page shows where it is now, even if a manifest write fails below
        transcripts?.move(from: e.item.path, to: Homes.relative(dest, to: Homes.root))
        var moved = entry
        moved.path = Homes.relative(dest, to: Homes.url(to.home))
        if from.home == to.home {
            try Homes.write(Homes.index(from.home).map { $0.path == entry.path ? moved : $0 }, to: from.home)
        } else {
            try Homes.record(moved, in: to.home)   // recorded where it now is before it's forgotten where it was
            try Homes.forget(entry.path, in: from.home)
        }
    }

    func thumbnail(for e: ShowsKit.Episode, side: CGFloat) async -> CGImage? {
        guard [.video, .pdf, .image].contains(e.item.kind) else { return nil }
        let url = Homes.root.appendingPathComponent(e.item.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let r = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 3, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: r).cgImage
    }
}

/// FEAT-13 review 11-17: a move whose manifest write fails still rescans (the file did move), and a move into another
/// home is recorded there before the old home forgets it. Runs in `recense selftest`.
@MainActor func homeFilesSelftest() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String, _ got: Any = "") { print("\(pass ? "ok  " : "FAIL") homefiles, \(what)\(pass ? "" : " — got \(got)")"); ok = ok && pass }
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("recense-homefiles-\(UUID().uuidString)")
    setenv("RECENSE_HOME", dir.appendingPathComponent("Recense").path, 1)
    defer { unsetenv("RECENSE_HOME"); try? fm.removeItem(at: dir) }
    do {
        try Homes.ensure()
        let src = dir.appendingPathComponent("Bài 1.m4a"); try Data("a".utf8).write(to: src)
        _ = try Homes.add(src, to: .music, subfolder: "Bài giảng")
        var rescans = 0
        let files = HomeFiles { rescans += 1 }
        func episode(_ path: String) -> ShowsKit.Episode {
            ShowsKit.Episode(item: PoolItem(id: path, path: path), show: "s", title: (path as NSString).lastPathComponent)
        }
        func show(_ folder: String) -> ShowsKit.Show { ShowsKit.Show(id: folder, space: .library, folder: folder, title: folder, episodeCount: 1) }

        // pool paths as the app sees them: from the file system, so Vietnamese letters come decomposed (NFD), not as typed
        func pool(_ home: Home, _ rel: String) -> String { Homes.relative(Homes.url(home).appendingPathComponent(rel), to: Homes.root) }
        let before = pool(.music, "Bài giảng/Bài 1.m4a")
        let cache = TranscriptCache(dir: dir.appendingPathComponent("transcripts"))
        cache.write(before, [TranscriptLine(id: "0", start: 0, end: 1, text: "Xin chào")])
        files.transcripts = cache
        try files.move(episode(before), to: show("library/Study/Cours"))
        let after = pool(.study, "Cours/Bài 1.m4a")
        check(cache.read(after)?.first?.text == "Xin chào" && cache.read(before) == nil,
              "the saved transcript follows the moved file, so it still opens offline")
        check(fm.fileExists(atPath: Homes.url(.study).appendingPathComponent("Cours/Bài 1.m4a").path), "a move across homes lands in the show's folder")
        check(Homes.index(.study).contains { $0.path == "Cours/Bài 1.m4a" } && !Homes.index(.music).contains { $0.path.hasSuffix("Bài 1.m4a") },
              "the new home records it and the old one forgets it", Homes.index(.music).map(\.path))
        check(rescans == 1, "a move rescans once", rescans)

        // the destination manifest can't be written: the file still moves, and the page still rescans
        let index = Homes.indexURL(.legal)
        try Data("[]".utf8).write(to: index)
        try fm.setAttributes([.immutable: true], ofItemAtPath: index.path)
        defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: index.path) }
        rescans = 0
        do { try files.move(episode(after), to: show("library/Legal")); check(false, "a failed manifest write throws") }
        catch { check(true, "a failed manifest write throws") }
        check(rescans == 1, "a move that failed after the file moved still rescans", rescans)
        check(Homes.index(.study).contains { $0.path == "Cours/Bài 1.m4a" }, "the old home still knows it when the new one couldn't record it")
    } catch { check(false, "set up and move", error) }
    return ok
}
