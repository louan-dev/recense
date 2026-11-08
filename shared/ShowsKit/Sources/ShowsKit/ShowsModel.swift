// What the skin's views read and do, over any CatalogStore (MemoryCatalog now, B1's pool store next).
// Every action is a stamped change through the store's outbox, so it works offline and syncs later.
import Foundation
import Observation

/// Play, pause and skip, given by the host once our player can be driven from outside it (B3). Until then the
/// mini-player's play button opens Now Playing, and it shows no skip button.
@MainActor public protocol Transport: AnyObject {
    var isPlaying: Bool { get }
    func toggle()
    func skip(_ seconds: Double)
    /// Where the player is, in seconds, and how long the episode is: the transcript's playhead and the scrubber's.
    var time: Double { get }
    var duration: Double? { get }
    func seek(to seconds: Double)
}

/// A player that can't yet say where it is (B3's first cut) still drives play, pause and skip.
public extension Transport {
    var time: Double { 0 }
    var duration: Double? { nil }
    func seek(to seconds: Double) {}
}

public struct UpdatedShow: Identifiable, Hashable, Sendable {
    public var show: Show
    public var updated: Int64      // whole seconds
    public var id: String { show.id }
}

@MainActor @Observable
public final class ShowsModel {
    public enum Tab: Hashable, Sendable { case home, new, library, search }

    public let store: any CatalogStore
    public let gate: Gate
    public var tab: Tab = .home
    public private(set) var spaces: [Space] = Space.all
    public private(set) var shows: [SpaceID: [Show]] = [:]
    public private(set) var upNext: [FeedEntry] = []
    public private(set) var recentlyPlayed: [FeedEntry] = []
    public private(set) var recentlyUpdated: [UpdatedShow] = []
    /// Goes up after every store change; views that load their own rows reload on it.
    public private(set) var revision = 0
    public var playing: Episode?
    public var playingShow: String?
    public var nowPlayingOpen = false
    public var problem: String?
    public weak var transport: Transport?
    /// The playing episode's transcript, as far as it has been heard (the app's ears fill it: shared/speechcore.swift),
    /// and a word on how that's going ("Hearing 2:00 to 4:00…", "This device can't hear Vietnamese offline.").
    public var transcript: [TranscriptLine] = []
    public var transcriptNote: String?
    /// Now Playing shows the transcript (Podcasts' quote button) rather than the player.
    public var showsTranscript = false
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
        let open = gate.isOpen
        spaces = await store.spaces()
        var next: [SpaceID: [Show]] = [:]
        for s in spaces { next[s.id] = (try? await store.shows(in: s.id)) ?? [] }
        shows = next
        upNext = await store.feed(.upNext, includeLocked: open, limit: 12)
        recentlyPlayed = await store.feed(.recentlyPlayed, includeLocked: open, limit: 12)
        recentlyUpdated = await store.recentlyUpdated(includeLocked: open).map { UpdatedShow(show: $0.show, updated: $0.updated) }
        if let p = playing, let key = p.item.key { playing?.state = await store.state(of: key) }
        revision += 1
    }

    public func unlock(_ title: String) async {
        await gate.unlock("Open \(title)")
        if gate.isOpen { await reload() }
    }

    public func lock() {
        guard gate.isOpen else { return }
        gate.lock()
        Task { await reload() }
    }

    public func isLocked(_ space: Space) -> Bool { space.locked && !gate.isOpen }
    public func isLocked(_ show: Show) -> Bool { show.locked && !gate.isOpen }

    public var allShows: [Show] {
        spaces.filter { !isLocked($0) }.flatMap { shows[$0.id] ?? [] }.filter { !isLocked($0) }
    }

    public func showTitle(_ id: String) -> String? { shows.values.joined().first { $0.id == id }?.title }

    /// A show's episodes; none while it is locked and the gate is shut.
    public func episodes(of show: Show, season: String?) async -> [Episode] {
        guard !isLocked(show) else { return [] }
        do { return try await store.episodes(of: show.id, season: season) } catch { problem = "\(error)"; return [] }
    }

    public func entries(_ f: Feed) async -> [FeedEntry] { await store.feed(f, includeLocked: gate.isOpen, limit: 200) }

    public func play(_ e: Episode) {
        playing = e
        playingShow = showTitle(e.show)
        nowPlayingOpen = true
    }

    /// The mini-player's play button: our player's play/pause once B3 gives a transport, else open Now Playing.
    public func togglePlay() {
        if let transport { transport.toggle() } else { nowPlayingOpen = true }
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
    /// SF Symbol for Library's rows.
    var symbol: String {
        switch id {
        case .library: "books.vertical"
        case .study: "graduationcap"
        case .folio: "doc.text"
        case .matters: "briefcase"
        }
    }
}
