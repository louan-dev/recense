// Derived from Spec: FEAT-09 (P2 what changed, P3 settling)
import Foundation
import CryptoKit

// Carry's meaning layer: pure rules, no radios, no files. The glue scans (Carry.verify), keeps the op logs and
// moves bytes (shared/pieces over the FEAT-02 link); this file only decides. Homes are their folder strings
// ("library/Music", "downloads", "trash"), as CarryLine writes them, so the rules need nothing but Foundation.

/// One file as a scan saw it (CarryLine without what the rules don't need).
struct CarryFile: Codable, Equatable, Hashable, Sendable {
    var home: String
    var path: String
    var size: Int64
    var sha256: String
    var key: String { CarrySync.key(home, path) }
}

/// What changed. There is no delete: "delete forever" stays on the device where it was done.
enum CarryOpKind: String, Codable, CaseIterable, Sendable { case put, move, trash, restore }

/// One line of `Recense/.carry/ops/<device>.jsonl`. home/path is where the file was; toHome/to where it went.
struct CarryOp: Codable, Equatable, Sendable {
    var seq: Int
    var device: String
    var at: Int64                 // unix seconds
    var op: CarryOpKind
    var home: String
    var path: String
    var toHome: String? = nil
    var to: String? = nil
    var sha256: String
    var size: Int64
    /// A put's previous sha at this key on the sending device (the version it was edited from). nil: a new file,
    /// or an op from a device older than T-0106 (then a differing copy is kept beside, as before).
    var parent: String? = nil
    var toKey: String? { toHome.flatMap { h in to.map { CarrySync.key(h, $0) } } }
}

/// What the glue must do for one op. Nothing is ever overwritten or deleted.
enum CarryAction: Equatable, Sendable {
    case nothing
    case fetch(key: String, sha256: String)                     // bring these bytes to this place
    case replace(key: String, old: String, new: String)          // old version → trash/ (with origin), new lands
    case merge(key: String, base: String, mine: String, theirs: String) // text: notesync merge3; no clean merge → keepBoth
    case keepBoth(key: String, sibling: String, sha256: String)  // theirs lands beside mine
    case move(from: String, to: String)                          // move / trash / restore, replayed locally
}

enum CarrySync {
    static let trashHome = "trash"
    // `jsonl` is here for FEAT-15's seats (one line per listening position, append-only): line-merging two
    // devices' lines keeps both, where choosing a winner would drop one device's place in a piece.
    static let textExtensions: Set<String> = ["md", "markdown", "txt", "jsonl"]

    static func key(_ home: String, _ path: String) -> String { home + "/" + path }

    // Derived from Spec: BUG-19 (T-0087)
    /// The highest seq of a peer's log this device has fully settled: every op at or below it is placed or needed
    /// nothing. An op still waiting for its bytes holds it back, so the next "seen" asks for that op again.
    static func settledThrough(received: Int, pending: [Int]) -> Int {
        min(received, pending.min().map { $0 - 1 } ?? received)
    }

    // Derived from Spec: BUG-25 (T-0111, T-0108, T-0092)
    /// Where an op's bytes belong, on either side of the link.
    static func resultKey(_ op: CarryOp) -> String { op.toKey ?? key(op.home, op.path) }

    /// A staged file's name: SHA-256 of the key, 64 hex bytes. base64 of a long Vietnamese key passed the 255-byte
    /// file-name limit, so the move into staging threw and the file stayed owed forever (T-0111).
    static func stagingName(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The answer to a peer's "seen": each result key's bytes once (a put edited three times sent the file three
    /// times), and the keys this device can no longer fill ("delete forever" after the put). The receiver clears
    /// those, so one op that can never be filled no longer stalls the log and resends it all (T-0108).
    static func answer(_ ops: [CarryOp], exists: (String) -> Bool) -> (send: [String], gone: [String]) {
        var seen = Set<String>(), send: [String] = [], gone: [String] = []
        for op in ops.sorted(by: { $0.seq < $1.seq }) where op.op != .trash {   // trash never fetches
            let k = resultKey(op)
            guard seen.insert(k).inserted else { continue }
            if exists(k) { send.append(k) } else { gone.append(k) }
        }
        return (send, gone)
    }

    /// Staged bytes that no op waits for. Bytes can land before their op, so a running device keeps them
    /// `orphanAge`; at launch nothing waits in memory and the unsettled ops are asked for again, so all go (T-0092).
    static let orphanAge: TimeInterval = 600
    static func orphans(_ staged: [(name: String, modified: Date)], expecting: Set<String>, now: Date,
                        maxAge: TimeInterval) -> [String] {
        // SEC-02 invariant 17: `<name>.check` is the copy being hashed; it is expected whenever `<name>` is
        staged.filter { f in
            let base = f.name.hasSuffix(".check") ? String(f.name.dropLast(".check".count)) : f.name
            return !expecting.contains(base) && now.timeIntervalSince(f.modified) >= maxAge
        }.map(\.name)
    }

    // Derived from Spec: SEC-02 §2.4 (key safety)
    /// A key names a place inside ~/Recense/ only: no empty, `.` or `..` component, no leading `/`, no `\`, no NUL.
    static func safeKey(_ key: String) -> Bool {
        guard !key.isEmpty, !key.hasPrefix("/"), !key.contains("\\"), !key.contains("\u{0}") else { return false }
        return key.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func split(_ key: String, homes: [String]) -> (home: String, path: String)? {
        guard safeKey(key) else { return nil }   // SEC-02: every op key and resource name passes here
        // longest home first: "library/Music/a.m4a" must not split as "library" + "Music/a.m4a"
        for h in homes.sorted(by: { $0.count > $1.count }) where key.hasPrefix(h + "/") {
            return (h, String(key.dropFirst(h.count + 1)))
        }
        return nil
    }

    // MARK: P2 · a fresh scan against the last one → this device's new ops

    /// `trashOrigins`: trash path → the "home/path" it came from (Homes' `from:` tag), for the files in trash/ now.
    static func ops(last: [CarryFile], now: [CarryFile], trashOrigins: [String: String],
                    device: String, nextSeq: Int, at: Int64) -> [CarryOp] {
        let before = Dictionary(last.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let after = Dictionary(now.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var gone = Set(before.keys.filter { after[$0] == nil })
        var made = Set(after.keys.filter { before[$0] == nil })
        var out: [CarryOp] = []
        func emit(_ k: CarryOpKind, _ from: CarryFile, _ to: CarryFile?) {
            out.append(CarryOp(seq: 0, device: device, at: at, op: k, home: from.home, path: from.path,
                               toHome: to?.home, to: to?.path, sha256: (to ?? from).sha256, size: (to ?? from).size))
        }
        // trash: a new file in trash/ whose recorded origin just went, with the same bytes
        for k in made.sorted() {
            guard let f = after[k], f.home == trashHome, let origin = trashOrigins[f.path],
                  gone.contains(origin), let was = before[origin], was.sha256 == f.sha256 else { continue }
            emit(.trash, was, f); gone.remove(origin); made.remove(k)
        }
        // restore: a file left trash/ and the same bytes appeared outside it
        for k in made.sorted() {
            guard let f = after[k], f.home != trashHome,
                  let g = gone.sorted().first(where: { before[$0]!.home == trashHome && before[$0]!.sha256 == f.sha256 })
            else { continue }
            emit(.restore, before[g]!, f); gone.remove(g); made.remove(k)
        }
        // move: the same bytes at a new place, the old place gone (outside trash/)
        for k in made.sorted() {
            guard let f = after[k], f.home != trashHome,
                  let g = gone.sorted().first(where: { before[$0]!.home != trashHome && before[$0]!.sha256 == f.sha256 })
            else { continue }
            emit(.move, before[g]!, f); gone.remove(g); made.remove(k)
        }
        // put: new places, and places whose bytes changed. trash/ only changes by trash and restore.
        for k in made.sorted() where after[k]!.home != trashHome { emit(.put, after[k]!, nil) }
        for (k, f) in after.sorted(by: { $0.key < $1.key }) where f.home != trashHome {
            if let b = before[k], b.sha256 != f.sha256 { emit(.put, f, nil); out[out.count - 1].parent = b.sha256 }
        }
        // whatever is left in `gone` was deleted forever (or outside Recense): no op, by design
        for i in out.indices { out[i].seq = nextSeq + i }
        return out
    }

    // MARK: P3 · settling

    /// Ops the other side lacks, given what it has seen ({device: last seq}).
    /// One batch, in seq order, each op decided against the disk as the ops before it leave it (T-0106):
    /// put A→B then B→C replaces twice instead of keeping the second as a copy beside B.
    static func decideAll(_ ops: [CarryOp], local: [String: String], base: [String: String],
                          zone: TimeZone = .current) -> [(op: CarryOp, action: CarryAction)] {
        var disk = local
        return ops.sorted { $0.seq < $1.seq }.map { op in
            let a = decide(op, local: disk, base: base, zone: zone)
            switch a {
            case .fetch(let k, let sha), .replace(let k, _, let sha): disk[k] = sha
            case .keepBoth(_, let sib, let sha): disk[sib] = sha
            case .move(let from, let to): disk[to] = disk.removeValue(forKey: from)
            case .nothing, .merge: break
            }
            return (op, a)
        }
    }

    /// A peer has applied `peerSaw` of this device's ops but the log holds fewer: the log was reset (a reinstall
    /// keeps the Keychain identity, so pairing survives, but the app folder and its log go; T-0110). Every op moves
    /// above what the peer saw, so it asks for them again. nil: nothing to renumber.
    static func renumber(_ mine: [CarryOp], peerSaw: Int) -> [CarryOp]? {
        guard !mine.isEmpty, peerSaw > (mine.map(\.seq).max() ?? 0) else { return nil }
        return mine.map { var o = $0; o.seq += peerSaw; return o }
    }

    static func wanted(_ ops: [CarryOp], theySaw: [String: Int]) -> [CarryOp] {
        ops.filter { $0.seq > (theySaw[$0.device] ?? 0) }.sorted { ($0.device, $0.seq) < ($1.device, $1.seq) }
    }

    /// The sibling for a non-text conflict: "lecture (iPad 2026-11-14 1605).m4a", beside the file.
    static func sibling(_ key: String, device: String, at: Int64, zone: TimeZone = .current) -> String {
        conflictSiblingPath(key, Date(timeIntervalSince1970: TimeInterval(at)), device: device, zone: zone)
    }

    static func isText(_ path: String) -> Bool { textExtensions.contains((path as NSString).pathExtension.lowercased()) }

    /// One op against this device. `local`: "home/path" → sha256 now; `base`: the last sha both sides agreed on.
    static func decide(_ op: CarryOp, local: [String: String], base: [String: String],
                       zone: TimeZone = .current) -> CarryAction {
        let here = key(op.home, op.path)
        switch op.op {
        case .put:
            guard let mine = local[here] else { return .fetch(key: here, sha256: op.sha256) }
            if mine == op.sha256 { return .nothing }
            if let b = base[here], b == mine { return .replace(key: here, old: mine, new: op.sha256) }
            if let p = op.parent, p == mine { return .replace(key: here, old: mine, new: op.sha256) }   // T-0106: they edited my version
            // a text conflict: merge against the version the peer edited from, else the last version that landed here.
            // The apply step keeps both when that text is gone or the edits overlap, so a wrong guess never loses a line.
            if isText(op.path), let b = op.parent ?? base[here] { return .merge(key: here, base: b, mine: mine, theirs: op.sha256) }
            let s = sibling(here, device: op.device, at: op.at, zone: zone)
            return local[s] == op.sha256 ? .nothing : .keepBoth(key: here, sibling: s, sha256: op.sha256)
        case .move, .trash, .restore:
            guard let dest = op.toKey else { return .nothing }
            if local[dest] == op.sha256 { return .nothing }                        // already there
            if local[here] == op.sha256 {
                if local[dest] == nil { return .move(from: here, to: dest) }
                let s = sibling(dest, device: op.device, at: op.at, zone: zone)   // a different file sits there
                return local[s] == op.sha256 ? .nothing : .keepBoth(key: dest, sibling: s, sha256: op.sha256)
            }
            // mine changed (or isn't here): nothing of mine moves. A trash never fetches; move/restore bring
            // their bytes to the new place, so nothing on either side is lost.
            if op.op == .trash { return .nothing }
            if local[dest] == nil { return .fetch(key: dest, sha256: op.sha256) }
            let s = sibling(dest, device: op.device, at: op.at, zone: zone)
            return local[s] == op.sha256 ? .nothing : .keepBoth(key: dest, sibling: s, sha256: op.sha256)
        }
    }

    // MARK: the op log on disk (JSON Lines, one op per line, append-only)

    static func encode(_ ops: [CarryOp]) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ops.map { String(decoding: (try? e.encode($0)) ?? Data(), as: UTF8.self) + "\n" }.joined()
    }

    static func decode(_ text: String) -> [CarryOp] {
        let d = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? d.decode(CarryOp.self, from: Data($0.utf8)) }
    }
}

// Regression guard: FEAT-09 P2/P3 (the full suite lives in mobile/ios/Tests/carrysync/main.swift; this is the
// condensed version `recense selftest` can run with no radios, no files).
func carrysyncSelftest() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String) { print("\(pass ? "ok  " : "FAIL") carrysync, \(what)"); ok = ok && pass }
    let utc = TimeZone(identifier: "UTC")!
    let M = "library/Music"
    func f(_ p: String, _ sha: String) -> CarryFile { CarryFile(home: M, path: p, size: 1, sha256: sha) }

    let ops = CarrySync.ops(last: [f("a.m4a", "A")], now: [f("sub/a.m4a", "A")], trashOrigins: [:], device: "ipad", nextSeq: 1, at: 1)
    check(ops.count == 1 && ops[0].op == .move, "a renamed file becomes one move op")
    check(CarryOpKind.allCases.map(\.rawValue) == ["put", "move", "trash", "restore"], "there is no delete op")

    let put = CarryOp(seq: 1, device: "ipad", at: 1, op: .put, home: M, path: "a.m4a", sha256: "NEW", size: 1)
    let k = "library/Music/a.m4a"
    switch CarrySync.decide(put, local: [:], base: [:], zone: utc) {
    case .fetch(let key, let sha): check(key == k && sha == "NEW", "a file this device lacks is fetched")
    default: check(false, "a file this device lacks is fetched")
    }
    switch CarrySync.decide(put, local: [k: "MINE"], base: [k: "OLD"], zone: utc) {
    case .keepBoth: check(true, "both sides changed a non-text file → both are kept")
    default: check(false, "both sides changed a non-text file → both are kept")
    }

    let ops2 = CarrySync.encode([put])
    check(CarrySync.decode(ops2) == [put], "the op log round-trips through JSON Lines")
    return ok
}

// Derived from Spec: FEAT-09 P4 (automatic carry, T-0084)
/// When to carry. Pure: events in, "run now" out; the caller owns the clock and the one Task that sleeps until `due`.
/// - A paired peer connects, or the app comes to the front: carry after `connectDelay`.
/// - A home changes: carry after `quiet` seconds with no further change (debounced).
/// - Carry Now: at once, connected or not (it reports its own result).
/// - One carry at a time; triggers during a carry fold into one follow-up after it.
/// - No paired peer connected: automatic triggers wait (Carry Now still runs).
/// Which file events start an automatic carry (T-0091). Only the carried homes count: other writes under the
/// root (keep/, the Gallery transcript cache, saved every few seconds; .carry/ itself) re-ran carry every ~4 s.
enum CarryWatch {
    static func counts(_ path: String, root: String, homes: [String]) -> Bool {
        let r = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(r) else { return false }
        let rel = path.dropFirst(r.count)
        if rel.hasPrefix(CarryKeep.folder + "/") { return CarryKeep.carries(String(rel)) }   // FEAT-22 P1: two files only, never the cache (T-0091)
        return homes.contains { rel == $0 || rel.hasPrefix($0 + "/") }
    }
}

// Derived from Spec: FEAT-22 P1 · carry takes a media item's note and transcript. Of `keep/` only
// `keep/<key>/note.md` and `keep/<key>/lines.json` travel. The Mac's working files (`<key>.v2.json`, `<key>.tr.*.json`), the search
// index `find.tsv` and anything else stay put: they are derived or Mac-only, and the cache was written every few seconds (T-0091).
enum CarryKeep {
    static let folder = "keep"
    static let files: Set<String> = ["note.md", "lines.json"]

    private static func parts(_ rel: String) -> [Substring] { rel.split(separator: "/", omittingEmptySubsequences: false) }

    /// `rel` is relative to the Recense folder: "keep/<key>/note.md".
    static func carries(_ rel: String) -> Bool {
        let c = parts(rel)
        return c.count == 3 && c[0] == folder && !c[1].isEmpty && !c[1].hasPrefix(".") && files.contains(String(c[2]))
    }

    /// A conflict copy of one of the two files that carry itself made ("lines (iPad 2026-11-18 1405).json"): placed, never carried on.
    static func isSibling(_ rel: String) -> Bool {
        let c = parts(rel)
        guard c.count == 3, c[0] == folder, !c[1].isEmpty, !c[1].hasPrefix(".") else { return false }
        let name = String(c[2])
        return files.contains { f in
            let stem = (f as NSString).deletingPathExtension, ext = (f as NSString).pathExtension
            return name.hasPrefix(stem + " (") && name.hasSuffix("." + ext)
        }
    }
}

struct CarrySchedule {
    static let connectDelay: Double = 0.5
    static let quiet: Double = 2

    enum Event { case connected, disconnected, changed, foreground, tapped, finished }

    private(set) var connected = false
    private(set) var running = false
    private(set) var due: Double?
    private var pending = false
    private var forced = false

    mutating func handle(_ e: Event, at t: Double) {
        switch e {
        case .connected:    connected = true; want(t + Self.connectDelay, soonest: true)
        case .disconnected: connected = false; if !forced { due = nil; pending = false }
        case .changed:      if connected { want(t + Self.quiet, soonest: false) }
        case .foreground:   if connected { want(t + Self.connectDelay, soonest: true) }
        case .tapped:       forced = true; if running { pending = true } else { due = t }
        case .finished:
            running = false
            if pending { pending = false; due = t + Self.connectDelay }
        }
    }

    /// True when a carry should start now; the caller then runs it and sends `.finished`.
    mutating func tick(at t: Double) -> Bool {
        guard !running, let d = due, t >= d - 1e-9, connected || forced else { return false }
        running = true; due = nil; forced = false
        return true
    }

    private mutating func want(_ at: Double, soonest: Bool) {
        if running { pending = true; return }
        if let d = due, soonest { due = min(d, at) } else { due = at }   // a change pushes the run back
    }
}
