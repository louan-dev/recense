// The ShowsKit contract (B0.5, 2026-11-06): the types both lanes build on. Plan: starry-squishing-knuth.md.
// Changes to this file go through the coordinator: B1 (the pool and catalog) and B2 (the skin) both depend on it.
//
// The device pool:   Recense/{inbox,library,keep,.trash}/…     paths below are relative to Recense/
//   inbox/            what just arrived; shown in the app as the show "New" (never "Inbox")
//   library/          shows: library/<show>/[<season>/]<file>, library/Study/<show>/…, library/Folio/<show>/…,
//                     library/Matters/<client>/… (Rules.swift, Layout)
//   keep/             transcripts and notes, kept forever: keep/<key>/asr.json …, keep/listen/<device>/<key>.json
//   .trash/           deletes, kept 30 days
// Wire format: JSON, camelCase keys, times in whole seconds (event-log.md §2) except HLC wall time (milliseconds).
// Every type here encodes to the same JSON on the Mac, on iOS and (for the outbox) in the Worker.

import CryptoKit
import Foundation

// MARK: - Content key

/// A file's key by its content, so the same recording is one item wherever it is: the first 24 hex of
/// SHA-256("fp:<bytes>:<sha256 of the first 64 KiB>:<sha256 of the last 64 KiB>"). The same function as the Mac's
/// `ContentKey` (strip/recense.swift) and the Worker's `fingerprintKey` (library/src/transcript.js); the test vector
/// in ContractTests is checked against both.
public struct ContentKey: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public static let span = 65_536
    public let rawValue: String

    /// 24 lowercase hex, or nil.
    public init?(rawValue: String) {
        guard rawValue.count == 24, rawValue.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        self.rawValue = rawValue
    }

    public static func of(size: Int, head: Data, tail: Data) -> ContentKey {
        let h = { (d: Data) in SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        let s = SHA256.hash(data: Data("fp:\(size):\(h(head)):\(h(tail))".utf8)).map { String(format: "%02x", $0) }.joined()
        return ContentKey(rawValue: String(s.prefix(24)))!
    }

    /// nil for an empty or unreadable file.
    public static func ofFile(_ url: URL) -> ContentKey? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size > 0,
              (try? fh.seek(toOffset: 0)) != nil, let head = try? fh.read(upToCount: span),
              (try? fh.seek(toOffset: size > UInt64(span) ? size - UInt64(span) : 0)) != nil,
              let tail = try? fh.read(upToCount: span)
        else { return nil }
        return of(size: Int(size), head: head, tail: tail)
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let k = ContentKey(rawValue: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a content key: \(s)"))
        }
        self = k
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public static func < (a: ContentKey, b: ContentKey) -> Bool { a.rawValue < b.rawValue }
    public var description: String { rawValue }
}

// MARK: - Hybrid logical clock

/// A hybrid logical clock stamp (Kulkarni et al., 2014): wall time in ms, a counter for events in the same ms or
/// behind a faster peer, and the device that made it. Ordered by (wall, n, node): a total order every device agrees
/// on, so "newest wins" picks the same value everywhere even when the clocks disagree.
public struct HLC: Hashable, Comparable, Codable, Sendable {
    public var wall: Int64
    public var n: Int
    public var node: String

    public init(wall: Int64, n: Int = 0, node: String) { self.wall = wall; self.n = n; self.node = node }
    public static let zero = HLC(wall: 0, n: 0, node: "")
    public static func < (a: HLC, b: HLC) -> Bool { (a.wall, a.n, a.node) < (b.wall, b.n, b.node) }
}

/// One device's clock. `now` for a local event; `receive` when a stamp arrives from another device, so every
/// later local stamp sorts after it.
public struct HLCClock: Sendable {
    public private(set) var last: HLC
    public init(node: String, last: HLC? = nil) { self.last = last ?? HLC(wall: 0, n: 0, node: node) }

    public static func wallNow() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

    public mutating func now(wall: Int64 = HLCClock.wallNow()) -> HLC {
        last = wall > last.wall ? HLC(wall: wall, n: 0, node: last.node) : HLC(wall: last.wall, n: last.n + 1, node: last.node)
        return last
    }

    public mutating func receive(_ r: HLC, wall: Int64 = HLCClock.wallNow()) -> HLC {
        let w = max(wall, last.wall, r.wall)
        let n: Int
        if w == last.wall && w == r.wall { n = max(last.n, r.n) + 1 }
        else if w == last.wall { n = last.n + 1 }
        else if w == r.wall { n = r.n + 1 }
        else { n = 0 }
        last = HLC(wall: w, n: n, node: last.node)
        return last
    }
}

/// A last-writer-wins field: the value with the greater stamp wins. The corrections rule, extended (plan: Sync).
public struct Stamped<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var value: Value
    public var at: HLC
    public init(_ value: Value, at: HLC) { self.value = value; self.at = at }
    public func merged(_ other: Stamped) -> Stamped { other.at > at ? other : self }
}

// MARK: - The pool

/// The four top folders of Recense/ on every device.
public enum Zone: String, Codable, CaseIterable, Sendable {
    case inbox, library, keep, trash
    /// The folder's real name (trash is a dot folder).
    public var folder: String { self == .trash ? ".trash" : rawValue }
    public init?(folder: String) { self.init(rawValue: folder == ".trash" ? "trash" : folder) }
}

public enum Kind: String, Codable, CaseIterable, Sendable {
    case audio, video, pdf, image, text, other
    public var isMedia: Bool { self == .audio || self == .video }

    public init(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "caf": self = .audio
        case "mp4", "m4v", "mov", "webm", "mkv": self = .video
        case "pdf": self = .pdf
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff": self = .image
        case "md", "txt", "rtf", "html", "docx", "doc", "pages", "srt", "vtt": self = .text
        default: self = .other
        }
    }
}

/// One file or folder in the pool, as the catalog knows it. Facts about the file only; what the listener did with it
/// is `ItemState`. `id` is the catalog's (fp.js: "h"/"d" + 24 hex, or the Worker's fid), stable across a rename made
/// through the Worker; `path` is a label.
public struct PoolItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var path: String          // relative to Recense/, the real names, e.g. "library/Study/MPEP/ch2100.pdf"
    public var dir: Bool
    public var key: ContentKey?      // nil for a folder, or a file not yet hashed
    public var size: Int64
    public var mtime: Int64          // whole seconds
    public var added: Int64          // when it entered the pool on any device (for New's expiry), whole seconds
    public var local: Bool           // its bytes are on this device
    public var kind: Kind

    public init(id: String, path: String, dir: Bool = false, key: ContentKey? = nil, size: Int64 = 0, mtime: Int64 = 0,
                added: Int64 = 0, local: Bool = true, kind: Kind? = nil) {
        self.id = id; self.path = path; self.dir = dir; self.key = key; self.size = size; self.mtime = mtime
        self.added = added; self.local = local; self.kind = kind ?? (dir ? .other : Kind(path: path))
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var zone: Zone? { path.split(separator: "/").first.flatMap { Zone(folder: String($0)) } }
    /// Matters or Raven anywhere in the path: opens only with Face ID / Touch ID, and is never shared (Rules.locked).
    public var locked: Bool { Rules.locked(path) }
}

/// What the listener did with an item, synced field by field (newest stamp wins). Keyed by content key, so a star
/// follows the recording wherever it is.
public struct ItemState: Codable, Hashable, Sendable {
    public var key: ContentKey
    public var starred: Stamped<Bool>?
    public var finished: Stamped<Int64?>?   // when it was played to the end, whole seconds; nil value = marked unplayed
    public var title: Stamped<String?>?     // the app's title; the real file name never changes

    public init(key: ContentKey, starred: Stamped<Bool>? = nil, finished: Stamped<Int64?>? = nil, title: Stamped<String?>? = nil) {
        self.key = key; self.starred = starred; self.finished = finished; self.title = title
    }

    public var isStarred: Bool { starred?.value ?? false }
    public var finishedAt: Int64? { finished?.value ?? nil }

    /// Field by field; the same on every device whatever order the two arrive in.
    public func merged(_ o: ItemState) -> ItemState {
        precondition(o.key == key, "merging the states of two different items")
        func pick<V>(_ a: Stamped<V>?, _ b: Stamped<V>?) -> Stamped<V>? {
            guard let a else { return b }
            guard let b else { return a }
            return a.merged(b)
        }
        return ItemState(key: key, starred: pick(starred, o.starred), finished: pick(finished, o.finished), title: pick(title, o.title))
    }
}

/// Where one device stopped in one item: keep/listen/<device>/<key>.json, one record per device per item. Another
/// device's newer record is offered as "Continue from <device>", never jumped to silently.
public struct ListenPosition: Codable, Hashable, Sendable {
    public var device: String
    public var key: ContentKey
    public var seconds: Double
    public var at: HLC

    public init(device: String, key: ContentKey, seconds: Double, at: HLC) {
        self.device = device; self.key = key; self.seconds = seconds; self.at = at
    }
    public var path: String { "keep/listen/\(device)/\(key.rawValue).json" }
}

// MARK: - The skin's model

/// Library · Study · Folio · Matters. Matters is locked (Face ID / Touch ID) and never shared.
public enum SpaceID: String, Codable, CaseIterable, Sendable { case library, study, folio, matters }

public struct Space: Identifiable, Codable, Hashable, Sendable {
    public var id: SpaceID
    public var title: String
    public var locked: Bool
    public init(id: SpaceID, title: String, locked: Bool) { self.id = id; self.title = title; self.locked = locked }

    public static let all: [Space] = [
        Space(id: .library, title: "Library", locked: false),
        Space(id: .study, title: "Study", locked: false),
        Space(id: .folio, title: "Folio", locked: false),
        Space(id: .matters, title: "Matters", locked: true),
    ]
}

/// A season: a subfolder of a show's folder.
public struct Season: Identifiable, Codable, Hashable, Sendable {
    public var id: String        // the subfolder's catalog id
    public var folder: String    // its pool path
    public var title: String
    public init(id: String, folder: String, title: String) { self.id = id; self.folder = folder; self.title = title }
}

/// A show: a top-level folder (a client, in Matters). "New" is the inbox, shown as a show at the top of Library.
public struct Show: Identifiable, Codable, Hashable, Sendable {
    public static let newID = "new"

    public var id: String          // the folder's catalog id; "new" for the inbox
    public var space: SpaceID
    public var folder: String      // its pool path, the real name
    public var title: String       // .show.json's title, else the folder's name
    public var seasons: [Season]   // empty: every episode sits in the show's own folder
    public var episodeCount: Int   // files under it, seasons included; 0 = hidden
    public var locked: Bool        // Matters or Raven
    public var licensed: Bool      // .show.json licensed: true; never invited, never in a feed
    public var serial: Bool        // episodes in order (n ascending) rather than newest first
    public var lang: String?

    public init(id: String, space: SpaceID, folder: String, title: String, seasons: [Season] = [], episodeCount: Int,
                locked: Bool = false, licensed: Bool = false, serial: Bool = false, lang: String? = nil) {
        self.id = id; self.space = space; self.folder = folder; self.title = title; self.seasons = seasons
        self.episodeCount = episodeCount; self.locked = locked; self.licensed = licensed; self.serial = serial; self.lang = lang
    }

    /// Matters/Raven and licensed shows never reach a share link, a feed or a guest build.
    public var shareable: Bool { !locked && !licensed }
}

/// A show folder's .show.json, as library/chau/show.mjs writes it and library/src/feed.js reads it. A show with one
/// is serial (its episodes in n order, like its feed). Unknown fields are ignored; a manifest that doesn't decode
/// counts as licensed wherever sharing is decided (fail closed, as show.mjs's invite does).
public struct ShowManifest: Codable, Hashable, Sendable {
    public static let fileName = ".show.json"
    public struct Entry: Codable, Hashable, Sendable {
        public var n: Int?
        public var id: String?
        public var title: String?
        public var file: String
        public var duration: Double?
        public var summary: String?
        public init(n: Int? = nil, id: String? = nil, title: String? = nil, file: String, duration: Double? = nil, summary: String? = nil) {
            self.n = n; self.id = id; self.title = title; self.file = file; self.duration = duration; self.summary = summary
        }
    }
    public var title: String?
    public var description: String?
    public var lang: String?
    public var voice: String?
    public var updated: String?
    public var licensed: Bool?
    public var episodes: [Entry]
    public init(title: String? = nil, description: String? = nil, lang: String? = nil, licensed: Bool? = nil, episodes: [Entry]) {
        self.title = title; self.description = description; self.lang = lang; self.licensed = licensed; self.episodes = episodes
    }
}

public enum TranscriptStatus: String, Codable, Sendable { case none, transcribing, ready }

/// An episode: one file of a show, with what the views need beside it.
public struct Episode: Identifiable, Codable, Hashable, Sendable {
    public var item: PoolItem
    public var show: String          // Show.id
    public var season: String?       // Season.id
    public var n: Int?               // .show.json's n, if any
    public var title: String         // state's title, else .show.json's, else the file name without its extension
    public var duration: Double?     // seconds
    public var summary: String?
    public var transcript: TranscriptStatus
    public var state: ItemState?

    public init(item: PoolItem, show: String, season: String? = nil, n: Int? = nil, title: String, duration: Double? = nil,
                summary: String? = nil, transcript: TranscriptStatus = .none, state: ItemState? = nil) {
        self.item = item; self.show = show; self.season = season; self.n = n; self.title = title; self.duration = duration
        self.summary = summary; self.transcript = transcript; self.state = state
    }
    public var id: String { item.id }
}

// MARK: - The changes feed (what the Worker sends; library/src/fp.js, docs/specs/event-log.md §2)

/// One catalog event. Consumers apply only create, modify, move and delete; conflict and skip are information.
public struct CatalogEvent: Codable, Hashable, Sendable {
    public enum Op: String, Codable, Sendable { case create, modify, move, delete, conflict, skip, put, tombstone }
    public var op: Op
    public var id: String
    public var path: String
    public var dir: Bool?
    public var size: Int64?
    public var mtime: Int64?
    public var etag: String?
    public var md5: String?
    public var from: String?         // the old path, on move
    public var chain: String?

    public init(op: Op, id: String, path: String, dir: Bool? = nil, size: Int64? = nil, mtime: Int64? = nil,
                etag: String? = nil, md5: String? = nil, from: String? = nil, chain: String? = nil) {
        self.op = op; self.id = id; self.path = path; self.dir = dir; self.size = size; self.mtime = mtime
        self.etag = etag; self.md5 = md5; self.from = from; self.chain = chain
    }

    /// v1 names (put, tombstone) read as v2, forever (event-log.md §2).
    public var applied: Op? {
        switch op {
        case .create, .modify, .move, .delete: return op
        case .put: return .modify
        case .tombstone: return .delete
        case .conflict, .skip: return nil
        }
    }
}

/// GET /main/api/fp/<root>/changes?since=<seq>: the events after `since` and the seq to ask from next. 410 means
/// `since` is older than the log kept: list the root again (…/items) and start from the new seq.
public struct ChangesPage: Codable, Hashable, Sendable {
    public struct Held: Codable, Hashable, Sendable { public var deletes: Int; public var known: Int?; public var at: Int64? }
    public var seq: Int
    public var events: [CatalogEvent]
    public var more: Bool
    public var held: Held?           // a mass delete waits for the owner: remove nothing meanwhile
    public init(seq: Int, events: [CatalogEvent], more: Bool, held: Held? = nil) {
        self.seq = seq; self.events = events; self.more = more; self.held = held
    }
}

// MARK: - The outbox

/// One change this device made, waiting to reach the others. Sent in `seq` order to the Worker's /v1/commit (B4);
/// `opId` makes a retry safe: each opId applies once, on the Worker and in every store.
public struct OutboxOp: Identifiable, Codable, Hashable, Sendable {
    public var opId: String          // a UUID, lowercase
    public var seq: Int              // this device's order; the store assigns it on enqueue
    public var device: String
    public var at: HLC
    public var change: Change

    public init(opId: String = UUID().uuidString.lowercased(), seq: Int = 0, device: String, at: HLC, change: Change) {
        self.opId = opId; self.seq = seq; self.device = device; self.at = at; self.change = change
    }
    public var id: String { opId }

    /// Files never overwrite (an edit is a new version under a new key); deletes go to .trash.
    public enum Change: Hashable, Sendable {
        case put(path: String, key: ContentKey, size: Int64, mtime: Int64)   // send this pool file's bytes to path
        case folder(path: String)
        case move(id: String, from: String, to: String)
        case delete(id: String, path: String)                                // into .trash/, kept 30 days
        case state(ItemState)                                                // stamped fields, merged on arrival
        case listen(ListenPosition)
    }
}

extension OutboxOp.Change: Codable {
    // Flat JSON with a "type" field, the shape the Worker reads: {"type":"put","path":…,"key":…,"size":…,"mtime":…}
    private enum K: String, CodingKey { case type, path, key, size, mtime, id, from, to, state, listen }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .type) {
        case "put": self = .put(path: try c.decode(String.self, forKey: .path), key: try c.decode(ContentKey.self, forKey: .key),
                                size: try c.decode(Int64.self, forKey: .size), mtime: try c.decode(Int64.self, forKey: .mtime))
        case "folder": self = .folder(path: try c.decode(String.self, forKey: .path))
        case "move": self = .move(id: try c.decode(String.self, forKey: .id), from: try c.decode(String.self, forKey: .from),
                                  to: try c.decode(String.self, forKey: .to))
        case "delete": self = .delete(id: try c.decode(String.self, forKey: .id), path: try c.decode(String.self, forKey: .path))
        case "state": self = .state(try c.decode(ItemState.self, forKey: .state))
        case "listen": self = .listen(try c.decode(ListenPosition.self, forKey: .listen))
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown outbox op \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case let .put(path, key, size, mtime):
            try c.encode("put", forKey: .type); try c.encode(path, forKey: .path); try c.encode(key, forKey: .key)
            try c.encode(size, forKey: .size); try c.encode(mtime, forKey: .mtime)
        case let .folder(path): try c.encode("folder", forKey: .type); try c.encode(path, forKey: .path)
        case let .move(id, from, to):
            try c.encode("move", forKey: .type); try c.encode(id, forKey: .id); try c.encode(from, forKey: .from); try c.encode(to, forKey: .to)
        case let .delete(id, path): try c.encode("delete", forKey: .type); try c.encode(id, forKey: .id); try c.encode(path, forKey: .path)
        case let .state(s): try c.encode("state", forKey: .type); try c.encode(s, forKey: .state)
        case let .listen(p): try c.encode("listen", forKey: .type); try c.encode(p, forKey: .listen)
        }
    }
}
