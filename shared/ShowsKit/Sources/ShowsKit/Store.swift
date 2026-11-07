// The catalog-store contract (B0.5): what the skin reads (CatalogReading) and what sync writes (CatalogWriting).
// B1 builds the real store (the pool on disk + the changes feed + a durable outbox) in its own file in this package,
// and it must pass the same contract tests as MemoryCatalog (Tests/ShowsKitTests/ContractTests.swift). B2's views
// take `any CatalogStore`, so they run on MemoryCatalog (previews, tests) until B1 lands.
// Changes to the protocols go through the coordinator.

import CryptoKit
import Foundation

public struct Query: Hashable, Sendable {
    public var text: String
    public var filter: Filter?
    public var space: SpaceID?
    public var includeLocked: Bool     // false unless the Face ID / Touch ID gate is open
    public init(text: String = "", filter: Filter? = nil, space: SpaceID? = nil, includeLocked: Bool = false) {
        self.text = text; self.filter = filter; self.space = space; self.includeLocked = includeLocked
    }
}

public enum CatalogError: Error, Equatable { case notFound(String) }

/// What the skin reads. Everything works with no network: it is the device's own catalog.
public protocol CatalogReading: Sendable {
    func spaces() async -> [Space]
    /// A space's shows that have at least one episode (empty shows are hidden); in Library, New first. Locked shows are
    /// listed, flagged: the views gate them.
    func shows(in space: SpaceID) async throws -> [Show]
    /// A show's episodes, in its order (Rules.ordered); one season's when `season` is given. Throws notFound.
    func episodes(of show: String, season: String?) async throws -> [Episode]
    /// Names and titles containing the text (B1 adds transcripts and extracted text through the local index), under a
    /// filter bar and a space when given. Locked items only when the query says the gate is open.
    func search(_ q: Query) async throws -> [PoolItem]
    func item(key: ContentKey) async -> PoolItem?
    func state(of key: ContentKey) async -> ItemState?
    /// One record per device, newest first.
    func positions(of key: ContentKey) async -> [ListenPosition]
    /// Yields once after every change to what the reads return.
    func updates() async -> AsyncStream<Void>
}

/// What sync writes. Every write is idempotent: the same page or the same opId twice changes nothing.
public protocol CatalogWriting: Sendable {
    nonisolated var device: String { get }
    /// The seq to ask the feed from next, per root; nil before the first page.
    func cursor(root: String) async -> Int?
    /// Applies one changes page asked with `since`. A page whose `since` isn't this root's cursor (a replay, or out of
    /// order) is ignored: returns false. Applies only create, modify, move and delete (CatalogEvent.applied).
    @discardableResult func apply(_ page: ChangesPage, root: String, since: Int?) async throws -> Bool
    /// A change made on this device: stamped, given the next seq, applied here at once, and queued to send.
    @discardableResult func enqueue(_ change: OutboxOp.Change) async throws -> OutboxOp
    /// A change made on another device (relayed by the Worker): applied once; false when its opId was seen.
    @discardableResult func receive(_ op: OutboxOp) async throws -> Bool
    /// What waits to be sent, in seq order. It survives a restart (B1's store keeps it on disk).
    func pending() async -> [OutboxOp]
    /// The Worker took these: they leave the outbox. Unknown ids are ignored.
    func acknowledge(_ opIds: [String]) async
}

public typealias CatalogStore = CatalogReading & CatalogWriting

extension Rules {
    /// A folder's id when the catalog has none: "d" + 24 hex of SHA-256(path + "/"), fp.js's folderId rule.
    public static func folderID(_ path: String) -> String {
        "d" + SHA256.hash(data: Data((path + "/").utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
    }
    /// A file's id when the catalog has none: "h" + 24 hex of SHA-256(path), fp.js's fileId rule.
    public static func fileID(_ path: String) -> String {
        "h" + SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
    }

    /// The position to offer as "Continue from <device>": the newest record from another device, when it is newer
    /// than this device's own and more than 5 seconds away from it. Never applied without the listener's tap.
    public static func continueFrom(_ all: [ListenPosition], here device: String) -> ListenPosition? {
        let mine = all.filter { $0.device == device }.max { $0.at < $1.at }
        guard let other = all.filter({ $0.device != device }).max(by: { $0.at < $1.at }) else { return nil }
        if let mine, mine.at > other.at || abs(mine.seconds - other.seconds) <= 5 { return nil }
        return other
    }
}

/// The reference store: everything in memory. For tests and SwiftUI previews, and the behaviour B1's store matches.
/// Catalog paths are pool paths here (root "pool"); how Main and archive mount into the pool is B1's to decide.
public actor MemoryCatalog: CatalogStore {
    public nonisolated let device: String
    private var clock: HLCClock
    private var items: [String: PoolItem] = [:]                 // by id
    private var manifests: [String: ShowManifest] = [:]         // by show folder
    private var transcripts: [ContentKey: TranscriptStatus] = [:]
    private var states: [ContentKey: ItemState] = [:]
    private var listens: [ContentKey: [String: ListenPosition]] = [:]
    private var cursors: [String: Int] = [:]
    private var outbox: [OutboxOp] = []
    private var seen: Set<String> = []                          // every opId applied here
    private var nextSeq = 1
    private var watchers: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(device: String, items: [PoolItem] = [], manifests: [String: ShowManifest] = [:],
                transcripts: [ContentKey: TranscriptStatus] = [:], states: [ItemState] = [], listens: [ListenPosition] = [],
                wall: Int64? = nil) {
        self.device = device
        var c = HLCClock(node: device)
        if let wall { _ = c.now(wall: wall) }
        self.clock = c
        for i in items { self.items[i.id] = i }
        self.manifests = manifests
        self.transcripts = transcripts
        for st in states { self.states[st.key] = st }
        for p in listens { self.listens[p.key, default: [:]][p.device] = p }
    }

    // MARK: reading

    public func spaces() -> [Space] { Space.all }

    public func shows(in space: SpaceID) throws -> [Show] {
        var byFolder: [String: (Placement, [PoolItem])] = [:]
        for i in items.values where !i.dir {
            guard let p = Rules.place(i.path), p.space == space else { continue }
            byFolder[p.showFolder, default: (p, [])].1.append(i)
        }
        return byFolder.map { folder, v in makeShow(folder, space: v.0.space, files: v.1) }
            .sorted { a, b in
                if (a.id == Show.newID) != (b.id == Show.newID) { return a.id == Show.newID }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
    }

    public func episodes(of show: String, season: String?) throws -> [Episode] {
        let files = items.values.filter { !$0.dir }.compactMap { i in Rules.place(i.path).map { (i, $0) } }
        let folder = show == Show.newID ? Zone.inbox.folder : files.first { folderID($0.1.showFolder) == show }?.1.showFolder
        guard let folder else { throw CatalogError.notFound(show) }
        let mine = files.filter { $0.1.showFolder == folder }
        let s = makeShow(folder, space: mine.first?.1.space ?? .library, files: mine.map(\.0))
        let m = manifests[folder]
        let eps = mine.compactMap { i, p -> Episode? in
            let sid = p.seasonFolder.map(folderID)
            if let season, sid != season { return nil }
            let rel = String(i.path.dropFirst(folder.count + 1))
            let e = m?.episodes.first { $0.file == rel }
            let st = i.key.flatMap { states[$0] }
            let title = (st?.title?.value ?? nil) ?? e?.title ?? (i.name as NSString).deletingPathExtension
            return Episode(item: i, show: s.id, season: sid, n: e?.n, title: title, duration: e?.duration, summary: e?.summary,
                           transcript: i.key.flatMap { transcripts[$0] } ?? .none, state: st)
        }
        return Rules.ordered(eps, serial: s.serial)
    }

    public func search(_ q: Query) -> [PoolItem] {
        let t = q.text.trimmingCharacters(in: .whitespaces)
        return items.values.filter { i in
            guard !i.dir, q.includeLocked || !i.locked else { return false }
            if let f = q.filter, !Rules.matches(f, i, transcribed: i.key.map { transcripts[$0] == .ready } ?? false) { return false }
            if let sp = q.space, Rules.place(i.path)?.space != sp { return false }
            if t.isEmpty { return true }
            let title = i.key.flatMap { states[$0]?.title?.value ?? nil } ?? ""
            return i.name.localizedStandardContains(t) || title.localizedStandardContains(t)
        }.sorted { $0.path < $1.path }
    }

    public func item(key: ContentKey) -> PoolItem? { items.values.filter { $0.key == key }.min { $0.path < $1.path } }
    public func state(of key: ContentKey) -> ItemState? { states[key] }
    public func positions(of key: ContentKey) -> [ListenPosition] { (listens[key] ?? [:]).values.sorted { $0.at > $1.at } }

    public func updates() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, cont) = AsyncStream<Void>.makeStream()
        watchers[id] = cont
        cont.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
        return stream
    }
    private func drop(_ id: UUID) { watchers[id] = nil }
    private func changed() { for c in watchers.values { c.yield() } }

    // MARK: writing

    public func cursor(root: String) -> Int? { cursors[root] }

    public func apply(_ page: ChangesPage, root: String, since: Int?) -> Bool {
        guard since == cursors[root] else { return false }
        for ev in page.events {
            switch ev.applied {
            case .create?, .modify?:
                var i = items[ev.id] ?? PoolItem(id: ev.id, path: ev.path, dir: ev.dir ?? false, local: false)
                i.path = ev.path; i.size = ev.size ?? i.size; i.mtime = ev.mtime ?? i.mtime
                if i.added == 0 { i.added = ev.mtime ?? 0 }
                i.kind = i.dir ? .other : Kind(path: ev.path)
                items[ev.id] = i
            case .move?:
                if var i = items[ev.id] { i.path = ev.path; i.kind = i.dir ? .other : Kind(path: ev.path); items[ev.id] = i }
            case .delete?:
                items[ev.id] = nil
            default: break
            }
        }
        cursors[root] = page.seq
        changed()
        return true
    }

    public func enqueue(_ change: OutboxOp.Change) -> OutboxOp {
        let op = OutboxOp(seq: nextSeq, device: device, at: clock.now(), change: change)
        nextSeq += 1
        applyLocal(op)
        outbox.append(op)
        changed()
        return op
    }

    public func receive(_ op: OutboxOp) -> Bool {
        guard !seen.contains(op.opId) else { return false }
        _ = clock.receive(op.at)
        applyLocal(op)
        changed()
        return true
    }

    public func pending() -> [OutboxOp] { outbox.sorted { $0.seq < $1.seq } }
    public func acknowledge(_ opIds: [String]) { let s = Set(opIds); outbox.removeAll { s.contains($0.opId) } }

    // MARK: inside

    private func applyLocal(_ op: OutboxOp) {
        seen.insert(op.opId)
        let now = op.at.wall / 1000
        switch op.change {
        case let .put(path, key, size, mtime):
            let id = Rules.fileID(path)
            if items.values.contains(where: { $0.path == path }) { return }   // never overwrite
            items[id] = PoolItem(id: id, path: path, key: key, size: size, mtime: mtime, added: now, local: op.device == device)
        case let .folder(path):
            let id = Rules.folderID(path)
            if items[id] == nil { items[id] = PoolItem(id: id, path: path, dir: true, mtime: now, added: now) }
        case let .move(id, _, to):
            if var i = items[id] { i.path = to; i.kind = i.dir ? .other : Kind(path: to); items[id] = i }
        case let .delete(id, path):
            if var i = items[id], i.zone != .trash { i.path = Zone.trash.folder + "/" + path; items[id] = i }
        case let .state(s):
            states[s.key] = states[s.key].map { $0.merged(s) } ?? s
        case let .listen(p):
            if let had = listens[p.key]?[p.device], had.at >= p.at { return }
            listens[p.key, default: [:]][p.device] = p
        }
    }

    private func folderID(_ folder: String) -> String {
        folder == Zone.inbox.folder ? Show.newID : (items.values.first { $0.dir && $0.path == folder }?.id ?? Rules.folderID(folder))
    }

    private func makeShow(_ folder: String, space: SpaceID, files: [PoolItem]) -> Show {
        if folder == Zone.inbox.folder {
            return Show(id: Show.newID, space: .library, folder: folder, title: "New", episodeCount: files.count)
        }
        let seasons = Set(files.compactMap { Rules.place($0.path)?.seasonFolder }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Season(id: folderID($0), folder: $0, title: ($0 as NSString).lastPathComponent) }
        let m = manifests[folder]
        return Show(id: folderID(folder), space: space, folder: folder, title: m?.title ?? (folder as NSString).lastPathComponent,
                    seasons: seasons, episodeCount: files.count, locked: Rules.locked(folder), licensed: m?.licensed == true,
                    serial: m != nil, lang: m?.lang)
    }
}
