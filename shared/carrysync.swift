// Derived from Spec: FEAT-09 (P2 what changed, P3 settling)
import Foundation

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
    static let textExtensions: Set<String> = ["md", "markdown", "txt"]

    static func key(_ home: String, _ path: String) -> String { home + "/" + path }

    // Derived from Spec: BUG-19 (T-0087)
    /// The highest seq of a peer's log this device has fully settled: every op at or below it is placed or needed
    /// nothing. An op still waiting for its bytes holds it back, so the next "seen" asks for that op again.
    static func settledThrough(received: Int, pending: [Int]) -> Int {
        min(received, pending.min().map { $0 - 1 } ?? received)
    }

    static func split(_ key: String, homes: [String]) -> (home: String, path: String)? {
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
            if let b = before[k], b.sha256 != f.sha256 { emit(.put, f, nil) }
        }
        // whatever is left in `gone` was deleted forever (or outside Recense): no op, by design
        for i in out.indices { out[i].seq = nextSeq + i }
        return out
    }

    // MARK: P3 · settling

    /// Ops the other side lacks, given what it has seen ({device: last seq}).
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
                       deviceName: String, zone: TimeZone = .current) -> CarryAction {
        let here = key(op.home, op.path)
        switch op.op {
        case .put:
            guard let mine = local[here] else { return .fetch(key: here, sha256: op.sha256) }
            if mine == op.sha256 { return .nothing }
            if let b = base[here], b == mine { return .replace(key: here, old: mine, new: op.sha256) }
            if isText(op.path), let b = base[here] { return .merge(key: here, base: b, mine: mine, theirs: op.sha256) }
            let s = sibling(here, device: deviceName, at: op.at, zone: zone)
            return local[s] == op.sha256 ? .nothing : .keepBoth(key: here, sibling: s, sha256: op.sha256)
        case .move, .trash, .restore:
            guard let dest = op.toKey else { return .nothing }
            if local[dest] == op.sha256 { return .nothing }                        // already there
            if local[here] == op.sha256 {
                if local[dest] == nil { return .move(from: here, to: dest) }
                let s = sibling(dest, device: deviceName, at: op.at, zone: zone)   // a different file sits there
                return local[s] == op.sha256 ? .nothing : .keepBoth(key: dest, sibling: s, sha256: op.sha256)
            }
            // mine changed (or isn't here): nothing of mine moves. A trash never fetches; move/restore bring
            // their bytes to the new place, so nothing on either side is lost.
            if op.op == .trash { return .nothing }
            if local[dest] == nil { return .fetch(key: dest, sha256: op.sha256) }
            let s = sibling(dest, device: deviceName, at: op.at, zone: zone)
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
    switch CarrySync.decide(put, local: [:], base: [:], deviceName: "iPad", zone: utc) {
    case .fetch(let key, let sha): check(key == k && sha == "NEW", "a file this device lacks is fetched")
    default: check(false, "a file this device lacks is fetched")
    }
    switch CarrySync.decide(put, local: [k: "MINE"], base: [k: "OLD"], deviceName: "iPad", zone: utc) {
    case .keepBoth: check(true, "both sides changed a non-text file → both are kept")
    default: check(false, "both sides changed a non-text file → both are kept")
    }

    let ops2 = CarrySync.encode([put])
    check(CarrySync.decode(ops2) == [put], "the op log round-trips through JSON Lines")
    return ok
}
