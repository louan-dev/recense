// The lists the skin's Home, New and Library show, built only from CatalogReading's reads, so every store (MemoryCatalog
// now, B1's pool store next) has them with no code of its own. Locked shows join only when the gate is open.
import Foundation

public enum Feed: String, CaseIterable, Sendable {
    case upNext          // started and not finished (newest listen first), then unplayed arrivals in New
    case recentlyPlayed  // anything with a listen position, newest first
    case saved           // starred
    case downloaded      // media whose bytes are on this device
    case latest          // every episode, newest first
}

/// An episode with what a card shows beside it.
public struct FeedEntry: Identifiable, Hashable, Sendable {
    public var episode: Episode
    public var showTitle: String
    public var position: ListenPosition?     // the newest, from any device
    public var id: String { episode.id }

    /// Seconds left, when the length and a position are known.
    public var remaining: Double? {
        guard let d = episode.duration else { return nil }
        return max(0, d - (position?.seconds ?? 0))
    }
    public var progress: Double? {
        guard let d = episode.duration, d > 0, let p = position?.seconds else { return nil }
        return min(1, p / d)
    }
}

public extension CatalogReading {
    /// Every episode of every show the gate allows, with its show's title and newest position.
    func allEntries(includeLocked: Bool) async -> [FeedEntry] {
        var out: [FeedEntry] = []
        for space in await spaces() where includeLocked || !space.locked {
            for show in (try? await shows(in: space.id)) ?? [] where includeLocked || !show.locked {
                for e in (try? await episodes(of: show.id, season: nil)) ?? [] {
                    var pos: ListenPosition?
                    if let k = e.item.key { pos = await positions(of: k).first }
                    out.append(FeedEntry(episode: e, showTitle: show.title, position: pos))
                }
            }
        }
        return out
    }

    func feed(_ f: Feed, includeLocked: Bool = false, limit: Int = 50) async -> [FeedEntry] {
        let all = await allEntries(includeLocked: includeLocked)
        let finished: (FeedEntry) -> Bool = { $0.episode.state?.finishedAt != nil }
        let newest: (FeedEntry, FeedEntry) -> Bool = { ($0.episode.item.added, $0.id) > ($1.episode.item.added, $1.id) }
        let list: [FeedEntry]
        switch f {
        case .upNext:
            let started = all.filter { $0.position != nil && !finished($0) }.sorted { $0.position!.at > $1.position!.at }
            let fresh = all.filter { $0.position == nil && !finished($0) && $0.episode.show == Show.newID && $0.episode.item.kind.isMedia }
                .sorted(by: newest)
            list = started + fresh
        case .recentlyPlayed:
            list = all.filter { $0.position != nil }.sorted { $0.position!.at > $1.position!.at }
        case .saved:
            list = all.filter { $0.episode.state?.isStarred == true }.sorted(by: newest)
        case .downloaded:
            list = all.filter { $0.episode.item.local && $0.episode.item.kind.isMedia }.sorted(by: newest)
        case .latest:
            list = all.sorted(by: newest)
        }
        return Array(list.prefix(limit))
    }

    /// Shows by their newest episode, newest first, with when that was.
    func recentlyUpdated(includeLocked: Bool = false, limit: Int = 12) async -> [(show: Show, updated: Int64)] {
        var out: [(Show, Int64)] = []
        for space in await spaces() where includeLocked || !space.locked {
            for show in (try? await shows(in: space.id)) ?? [] where includeLocked || !show.locked {
                let eps = (try? await episodes(of: show.id, season: nil)) ?? []
                if let t = eps.map({ max($0.item.added, $0.item.mtime) }).max() { out.append((show, t)) }
            }
        }
        return Array(out.sorted { ($0.1, $0.0.id) > ($1.1, $1.0.id) }.prefix(limit)).map { (show: $0.0, updated: $0.1) }
    }
}
