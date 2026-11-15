// Derived from Spec: FEAT-07 P0
// Rename and Delete for the skin's rows, over the homes (shared/homes.swift), one copy for the Mac, iPhone and iPad.
// A rename renames the file in place, so Carry's next scan is a move (same SHA-256, new path) every paired device
// replays; a delete puts it in Trash with its origin, so Restore works and Carry replays the trash. No network.
import Foundation
import ShowsKit

@MainActor final class HomeFiles: EpisodeFiles {
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
}
