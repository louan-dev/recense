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
        var moved = entry
        moved.path = Homes.relative(dest, to: Homes.url(to.home))
        if from.home == to.home {
            try Homes.write(Homes.index(from.home).map { $0.path == entry.path ? moved : $0 }, to: from.home)
        } else {
            try Homes.forget(entry.path, in: from.home)
            try Homes.record(moved, in: to.home)
        }
        rescan()
    }

    func thumbnail(for e: ShowsKit.Episode, side: CGFloat) async -> CGImage? {
        guard [.video, .pdf, .image].contains(e.item.kind) else { return nil }
        let url = Homes.root.appendingPathComponent(e.item.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let r = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 3, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: r).cgImage
    }
}
