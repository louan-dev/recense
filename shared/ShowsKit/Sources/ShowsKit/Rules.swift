// The rules that turn pool paths into the skin, the same on every device (B0.5 contract; changes via the coordinator).

import Foundation

/// Where a pool file sits in the skin.
public struct Placement: Hashable, Sendable {
    public var space: SpaceID
    public var showFolder: String     // the show's pool path; "inbox" for New
    public var seasonFolder: String?  // the season's pool path, when the file is in a subfolder of the show
}

public enum Rules {
    // MARK: Locks

    /// A Matters or Raven folder anywhere in the path (the same test as library/chau/show.mjs refusePath): it opens
    /// only with Face ID / Touch ID and never reaches a link, a feed or a guest build.
    public static func locked(_ path: String) -> Bool {
        path.split(separator: "/").contains { ["matters", "raven"].contains($0.lowercased()) }
    }

    // MARK: Layout

    /// The folders under library/ that are spaces, not shows. Raven's clients sit in Matters too.
    static let spaceFolders: [String: SpaceID] = ["study": .study, "folio": .folio, "matters": .matters, "raven": .matters]

    /// Where a file shows up, or nil: not a file of a show (keep/, .trash/, a dotfile such as .show.json or a .folder-
    /// marker, or a file loose in library/ or in a space's own folder; those are found by search and the filter bars).
    ///   inbox/…                                → New (Library)
    ///   library/<show>/<file>                  → Library, no season
    ///   library/<show>/<season>/…/<file>       → Library, season = the first subfolder (deeper folders fold into it)
    ///   library/Study|Folio/<show>/…           → that space, the same below it
    ///   library/Matters|Raven/<client>/…       → Matters; the client is the show
    /// Real folder names never change; only titles do.
    public static func place(_ path: String) -> Placement? {
        let parts = path.split(separator: "/").map(String.init)
        guard let top = parts.first, parts.count >= 2, let name = parts.last, !name.hasPrefix(".") else { return nil }
        if top == Zone.inbox.folder { return Placement(space: .library, showFolder: Zone.inbox.folder, seasonFolder: nil) }
        guard top == Zone.library.folder else { return nil }
        var rest = Array(parts.dropFirst())                   // under library/
        var space = SpaceID.library, base = [top]
        if let s = spaceFolders[rest[0].lowercased()] { space = s; base.append(rest[0]); rest.removeFirst() }
        guard rest.count >= 2 else { return nil }             // loose: no show folder above the file
        let show = (base + [rest[0]]).joined(separator: "/")
        let season = rest.count >= 3 ? show + "/" + rest[1] : nil
        return Placement(space: space, showFolder: show, seasonFolder: season)
    }

    // MARK: Expiry

    public static let newKeepDays: Int64 = 14
    public static let finishedKeepDays: Int64 = 3

    /// Never expire, whatever folder they arrived in: a guard on names, not a classifier.
    static let keptWords = try! NSRegularExpression(pattern: #"\b(study|pli|raven|matters|law)\b"#, options: [.caseInsensitive])

    /// Whether an item's media bytes may leave this device now. Only media in New expires: 14 days after it arrived,
    /// or 3 days after it was finished. Starred items, and anything whose path names Study, PLI, Raven, Matters or law,
    /// never expire. Its catalog entry, transcript and notes always stay (keep/ is never swept).
    public static func evictable(_ item: PoolItem, state: ItemState?, now: Int64) -> Bool {
        guard item.zone == .inbox, item.local, !item.dir, item.kind.isMedia, !(state?.isStarred ?? false) else { return false }
        let p = item.path
        if keptWords.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)) != nil { return false }
        let day: Int64 = 86_400
        if now - item.added >= newKeepDays * day { return true }
        if let f = state?.finishedAt, now - f >= finishedKeepDays * day { return true }
        return false
    }

    // MARK: Filter bars

    /// Whether an item belongs under a filter bar. `transcribed`: keep/ has a transcript for its key.
    public static func matches(_ f: Filter, _ item: PoolItem, transcribed: Bool) -> Bool {
        guard !item.dir else { return false }
        switch f {
        case .new: return item.zone == .inbox
        case .downloads: return item.local && (item.zone == .inbox || item.zone == .library)
        case .recensed: return transcribed && item.zone != .trash
        case .screenshots:
            return item.kind == .image && item.zone != .trash
                && (item.name.range(of: #"^(Screenshot|Screen Shot|Simulator Screen Shot)"#, options: .regularExpression) != nil
                    || item.path.split(separator: "/").contains { $0.lowercased() == "screenshots" })
        case .videos: return item.kind == .video && item.zone != .trash
        case .media: return item.kind.isMedia && item.zone != .trash
        case .trash: return item.zone == .trash
        }
    }

    // MARK: Order

    /// Serial shows: n ascending (no n last, by name). Others: newest first (by mtime, then name).
    public static func ordered(_ eps: [Episode], serial: Bool) -> [Episode] {
        eps.sorted { a, b in
            if serial {
                switch (a.n, b.n) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.item.name.localizedStandardCompare(b.item.name) == .orderedAscending
                }
            }
            if a.item.mtime != b.item.mtime { return a.item.mtime > b.item.mtime }
            return a.item.name.localizedStandardCompare(b.item.name) == .orderedAscending
        }
    }
}

/// The search bars over the catalog (they are not shows). Trash is reached by Library › ··· › Recently Deleted.
public enum Filter: String, Codable, CaseIterable, Sendable { case new, downloads, recensed, screenshots, videos, media, trash }
