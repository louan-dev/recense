// What the skin's views read and do, over any CatalogStore (MemoryCatalog now, B1's pool store next).
// Every action is a stamped change through the store's outbox, so it works offline and syncs later.
import Foundation
import Observation

@MainActor @Observable
public final class ShowsModel {
    public let store: any CatalogStore
    public let gate: Gate
    public var space: SpaceID = .library
    public private(set) var spaces: [Space] = Space.all
    public private(set) var shows: [SpaceID: [Show]] = [:]
    /// Goes up after every store change; views that load their own rows reload on it.
    public private(set) var revision = 0
    public var playing: Episode?
    public var nowPlayingOpen = false
    public var problem: String?
    private var clock: HLCClock

    public init(store: any CatalogStore, gate: Gate? = nil) {
        self.store = store
        self.gate = gate ?? Gate()
        self.clock = HLCClock(node: store.device)
    }

    /// Loads, then reloads on every change, until the view goes away.
    public func run() async {
        let changes = await store.updates()   // watch first, so a change during the first load isn't missed
        await reload()
        for await _ in changes { await reload() }
    }

    public func reload() async {
        spaces = await store.spaces()
        var next: [SpaceID: [Show]] = [:]
        for s in spaces { next[s.id] = (try? await store.shows(in: s.id)) ?? [] }
        shows = next
        if let p = playing, let key = p.item.key { playing?.state = await store.state(of: key) }
        revision += 1
    }

    public func isLocked(_ space: Space) -> Bool { space.locked && !gate.isOpen }
    public func isLocked(_ show: Show) -> Bool { show.locked && !gate.isOpen }

    /// A show's episodes; none while it is locked and the gate is shut.
    public func episodes(of show: Show, season: String?) async -> [Episode] {
        guard !isLocked(show) else { return [] }
        do { return try await store.episodes(of: show.id, season: season) } catch { problem = "\(error)"; return [] }
    }

    public func play(_ e: Episode) {
        playing = e
        nowPlayingOpen = true
    }

    // MARK: the listener's marks (stamped, field by field)

    public func setVerdict(_ v: Verdict?, for e: Episode) async {
        await mark(e) { k, at in ItemState(key: k, verdict: Stamped(v, at: at)) }
    }

    public func setStarred(_ on: Bool, for e: Episode) async {
        await mark(e) { k, at in ItemState(key: k, starred: Stamped(on, at: at)) }
    }

    public func setFinished(_ done: Bool, for e: Episode) async {
        let when: Int64? = done ? HLCClock.wallNow() / 1000 : nil
        await mark(e) { k, at in ItemState(key: k, finished: Stamped(when, at: at)) }
    }

    private func mark(_ e: Episode, _ make: (ContentKey, HLC) -> ItemState) async {
        guard let k = e.item.key else { problem = "This file isn't read yet; try again in a moment."; return }
        do {
            _ = try await store.enqueue(.state(make(k, clock.now())))
            if playing?.id == e.id { playing?.state = await store.state(of: k) }
        } catch { problem = "\(error)" }
    }
}

public extension Space {
    /// SF Symbol for the sidebar and the tabs.
    var symbol: String {
        switch id {
        case .library: "books.vertical"
        case .study: "graduationcap"
        case .folio: "doc.text"
        case .matters: "briefcase"
        }
    }
}
