// Derived from Spec: FEAT-09 · the P2/P3 rules, no radios.
// swiftc -O shared/notesync.swift shared/carrysync.swift mobile/ios/Tests/carrysync/main.swift -o "$TMPDIR/carrysync" && "$TMPDIR/carrysync"
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failed += 1; print("FAIL L\(line): \(what)") }
}
let utc = TimeZone(identifier: "UTC")!
let M = "library/Music", S = "library/Study", T = "trash"
func f(_ h: String, _ p: String, _ sha: String) -> CarryFile { CarryFile(home: h, path: p, size: 1, sha256: sha) }

// FEAT-07 P0 · a rename in the Music list (Homes.rename) is one move, so every paired device replays the new name
do {
    let ops = CarrySync.ops(last: [f(M, "Faili.m4a", "F")], now: [f(M, "Faili (live).m4a", "F")], trashOrigins: [:],
                            device: "iphone", nextSeq: 1, at: 1)
    check(ops.count == 1 && ops[0].op == .move && ops[0].path == "Faili.m4a" && ops[0].to == "Faili (live).m4a",
          "a rename is one move: \(ops.map { "\($0.op) \($0.path) → \($0.to ?? "")" })")
    let k = CarrySync.key(M, "Faili.m4a"), nk = CarrySync.key(M, "Faili (live).m4a")
    check(CarrySync.decide(ops[0], local: [k: "F"], base: [:], deviceName: "Mac", zone: utc) == .move(from: k, to: nk),
          "the other device renames it too")
}

// P2 · scan diff → ops
do {
    let last = [f(M, "a.m4a", "A"), f(M, "b.m4a", "B"), f(S, "c.pdf", "C"), f(S, "d.md", "D1"), f(M, "gone.m4a", "G"),
                f(T, "old.m4a", "O")]
    let now = [f(M, "a.m4a", "A"),                       // same
               f(M, "sub/b.m4a", "B"),                   // moved
               f(T, "c.pdf", "C"),                       // trashed (origin recorded)
               f(S, "d.md", "D2"),                       // changed
               f(M, "new.m4a", "N"),                     // new
               f(M, "old.m4a", "O")]                     // restored out of trash
                                                         // gone.m4a: deleted forever → no op
    let ops = CarrySync.ops(last: last, now: now, trashOrigins: ["c.pdf": "library/Study/c.pdf"],
                            device: "ipad", nextSeq: 7, at: 100)
    func has(_ k: CarryOpKind, _ h: String, _ p: String, _ th: String? = nil, _ tp: String? = nil) -> Bool {
        ops.contains { $0.op == k && $0.home == h && $0.path == p && $0.toHome == th && $0.to == tp }
    }
    check(ops.count == 5, "five ops, got \(ops.count): \(ops.map { "\($0.op) \($0.path)" })")
    check(has(.trash, S, "c.pdf", T, "c.pdf"), "trash")
    check(has(.restore, T, "old.m4a", M, "old.m4a"), "restore")
    check(has(.move, M, "b.m4a", M, "sub/b.m4a"), "move")
    check(has(.put, S, "d.md"), "put changed")
    check(has(.put, M, "new.m4a"), "put new")
    check(!ops.contains { $0.path.contains("gone") }, "delete forever leaves no op")
    check(ops.map(\.seq) == Array(7..<12), "seq numbers follow on")
    check(ops.allSatisfy { $0.device == "ipad" && $0.at == 100 }, "device and time stamped")
    // a scan with nothing new is quiet
    check(CarrySync.ops(last: now, now: now, trashOrigins: [:], device: "ipad", nextSeq: 1, at: 1).isEmpty, "no change → no op")
    // trash without a recorded origin is not invented
    let t2 = CarrySync.ops(last: [f(S, "x.pdf", "X")], now: [f(T, "x.pdf", "X")], trashOrigins: [:], device: "d", nextSeq: 1, at: 1)
    check(t2.isEmpty, "no origin → no trash op (and trash/ files are never put)")
}

// no delete op exists
check(CarryOpKind.allCases.map(\.rawValue) == ["put", "move", "trash", "restore"], "ops are put, move, trash, restore only")

// P3 · settling, one op at a time
do {
    let put = CarryOp(seq: 1, device: "ipad", at: 1_731_600_300, op: .put, home: M, path: "a.m4a", sha256: "NEW", size: 1)
    let k = "library/Music/a.m4a"
    check(CarrySync.decide(put, local: [:], base: [:], deviceName: "iPad", zone: utc) == .fetch(key: k, sha256: "NEW"), "missing → fetch")
    check(CarrySync.decide(put, local: [k: "NEW"], base: [:], deviceName: "iPad", zone: utc) == .nothing, "same bytes → nothing")
    check(CarrySync.decide(put, local: [k: "OLD"], base: [k: "OLD"], deviceName: "iPad", zone: utc)
          == .replace(key: k, old: "OLD", new: "NEW"), "unchanged since base → old to trash, new lands")
    let sib = "library/Music/a (iPad 2024-11-14 1605).m4a"
    check(CarrySync.decide(put, local: [k: "MINE"], base: [k: "OLD"], deviceName: "iPad", zone: utc)
          == .keepBoth(key: k, sibling: sib, sha256: "NEW"), "both changed, audio → keep both")
    check(CarrySync.decide(put, local: [k: "MINE"], base: [:], deviceName: "iPad", zone: utc)
          == .keepBoth(key: k, sibling: sib, sha256: "NEW"), "both new, no base → keep both")
    check(CarrySync.decide(put, local: [k: "MINE", sib: "NEW"], base: [k: "OLD"], deviceName: "iPad", zone: utc) == .nothing,
          "keep both replayed → nothing")
    var md = put; md.home = S; md.path = "notes.md"
    let mk = "library/Study/notes.md"
    check(CarrySync.decide(md, local: [mk: "MINE"], base: [mk: "B"], deviceName: "iPad", zone: utc)
          == .merge(key: mk, base: "B", mine: "MINE", theirs: "NEW"), "both changed, text → 3-way merge")

    let mv = CarryOp(seq: 2, device: "ipad", at: 1, op: .move, home: M, path: "a.m4a", toHome: M, to: "x/a.m4a", sha256: "A", size: 1)
    let dk = "library/Music/x/a.m4a"
    check(CarrySync.decide(mv, local: [k: "A"], base: [:], deviceName: "iPad", zone: utc) == .move(from: k, to: dk), "move replayed")
    check(CarrySync.decide(mv, local: [dk: "A"], base: [:], deviceName: "iPad", zone: utc) == .nothing, "move done → nothing")
    check(CarrySync.decide(mv, local: [k: "EDITED"], base: [:], deviceName: "iPad", zone: utc) == .fetch(key: dk, sha256: "A"),
          "mine edited → mine stays, theirs lands at the new place")
    if case .keepBoth(let key, _, _) = CarrySync.decide(mv, local: [k: "A", dk: "OTHER"], base: [:], deviceName: "iPad", zone: utc) {
        check(key == dk, "occupied destination → sibling beside it")
    } else { check(false, "occupied destination → keep both") }

    let tr = CarryOp(seq: 3, device: "ipad", at: 1, op: .trash, home: M, path: "a.m4a", toHome: T, to: "a.m4a", sha256: "A", size: 1)
    check(CarrySync.decide(tr, local: [k: "A"], base: [:], deviceName: "iPad", zone: utc) == .move(from: k, to: "trash/a.m4a"), "trash replayed")
    check(CarrySync.decide(tr, local: [k: "EDITED"], base: [:], deviceName: "iPad", zone: utc) == .nothing, "mine edited → not trashed")
    check(CarrySync.decide(tr, local: [:], base: [:], deviceName: "iPad", zone: utc) == .nothing, "trash never fetches")
}

// what to send: only what the other side hasn't seen
do {
    let a = (1...3).map { CarryOp(seq: $0, device: "mac", at: 0, op: .put, home: M, path: "\($0)", sha256: "", size: 0) }
    let b = (1...2).map { CarryOp(seq: $0, device: "ipad", at: 0, op: .put, home: M, path: "i\($0)", sha256: "", size: 0) }
    let w = CarrySync.wanted(a + b, theySaw: ["mac": 2])
    check(w.map { "\($0.device)\($0.seq)" } == ["ipad1", "ipad2", "mac3"], "wanted: \(w.map { "\($0.device)\($0.seq)" })")
}

// the log on disk round-trips
do {
    let ops = [CarryOp(seq: 1, device: "mac", at: 5, op: .move, home: M, path: "a b/ü.m4a", toHome: S, to: "c.m4a", sha256: "x", size: 9),
               CarryOp(seq: 2, device: "mac", at: 6, op: .put, home: M, path: "n.m4a", sha256: "y", size: 3)]
    let text = CarrySync.encode(ops)
    check(text.split(separator: "\n").count == 2 && text.hasSuffix("\n"), "one line per op")
    check(CarrySync.decode(text) == ops, "round trip")
    check(CarrySync.decode(text + "{broken\n") == ops, "a torn last line is skipped, not fatal")
}

// replaying the same ops twice changes nothing (a fake disk)
do {
    var disk: [String: String] = ["library/Music/a.m4a": "A", "library/Study/n.md": "MINE"]
    let base = ["library/Study/n.md": "B"]
    let ops = [CarryOp(seq: 1, device: "ipad", at: 1_731_600_300, op: .put, home: M, path: "b.m4a", sha256: "B", size: 1),
               CarryOp(seq: 2, device: "ipad", at: 1_731_600_300, op: .put, home: M, path: "a.m4a", sha256: "A2", size: 1),
               CarryOp(seq: 3, device: "ipad", at: 1, op: .move, home: M, path: "b.m4a", toHome: M, to: "s/b.m4a", sha256: "B", size: 1),
               CarryOp(seq: 4, device: "ipad", at: 1, op: .trash, home: M, path: "s/b.m4a", toHome: T, to: "b.m4a", sha256: "B", size: 1)]
    var seen: [String: Int] = [:]                       // the seen vector, kept beside the log
    func apply() {
        for op in CarrySync.wanted(ops, theySaw: seen) {
            defer { seen[op.device] = max(seen[op.device] ?? 0, op.seq) }
            switch CarrySync.decide(op, local: disk, base: base, deviceName: "iPad", zone: utc) {
            case .nothing, .merge: break
            case .fetch(let k, let s): disk[k] = s
            case .replace(let k, let old, let new): disk["trash/" + (k as NSString).lastPathComponent + "~" + old] = old; disk[k] = new
            case .keepBoth(_, let sib, let s): disk[sib] = s
            case .move(let a, let b): disk[b] = disk.removeValue(forKey: a)
            }
        }
    }
    apply(); let once = disk; apply()
    check(disk == once, "replay twice = no change")
    // without the seen vector a late put would come back after its own move and trash: the vector is the guard
    seen = [:]; apply()
    check(disk != once, "replay without the seen vector brings a trashed file back (why the vector is kept)")
    check(once["trash/b.m4a"] == "B" && once["library/Music/s/b.m4a"] == nil, "put → move → trash lands in trash")
    check(once["library/Music/a.m4a"] == "A" && once["library/Music/a (iPad 2024-11-14 1605).m4a"] == "A2",
          "a put over a file with no agreed base keeps both, mine untouched")
}

// notesync: Draftpad's sibling name is unchanged, carry's names the device and keeps the extension
do {
    let d = Date(timeIntervalSince1970: 1_730_839_860) // 2024-11-05 20:51 UTC
    check(conflictSiblingPath("v/draftpad.md", d, zone: utc) == "v/draftpad (other device 2024-11-05 2051).md", "draftpad name kept")
    check(conflictSiblingPath("v/lecture.m4a", d, device: "iPad", zone: utc) == "v/lecture (iPad 2024-11-05 2051).m4a", "carry name")
    let m = merge3(base: "a\nb\nc", mine: "a\nB\nc", theirs: "a\nb\nc\nd")
    check(m == "a\nB\nc\nd", "markdown merge keeps both sides' lines: \(m ?? "nil")")
}

// Regression guard: BUG-19 (ops counted applied before their bytes landed; T-0087)
do {
    check(CarrySync.settledThrough(received: 8, pending: []) == 8, "nothing waiting: settled through the last op")
    check(CarrySync.settledThrough(received: 8, pending: [3, 4, 5, 6, 7, 8]) == 2,
          "six songs waiting for bytes: settled only through op 2, so the next seen asks for 3 on")
    check(CarrySync.settledThrough(received: 8, pending: [8]) == 7, "the last op waiting holds 8 back")
    check(CarrySync.settledThrough(received: 0, pending: []) == 0, "nothing received")
    check(CarrySync.settledThrough(received: 8, pending: [1]) == 0, "the first op waiting holds everything back")
}

// Derived from Spec: FEAT-09 P4 (automatic carry, T-0084) · CarrySchedule: events in, "run now" out
do {
    /// Steps the clock in 0.1 s ticks from `from` to `to`; returns the times a carry started (each runs `dur` s).
    func runs(_ s: inout CarrySchedule, from: Double, to: Double, dur: Double = 0.3, events: [(Double, CarrySchedule.Event)]) -> [Double] {
        var out: [Double] = [], ends: [Double] = [], ev = events.sorted { $0.0 < $1.0 }
        var t = from
        while t <= to + 1e-9 {
            while let e = ev.first, e.0 <= t + 1e-9 { s.handle(e.1, at: e.0); ev.removeFirst() }
            if let e = ends.first, e <= t + 1e-9 { s.handle(.finished, at: t); ends.removeFirst() }
            if s.tick(at: t) { out.append(t); ends.append(t + dur) }
            t = (t * 10 + 1).rounded() / 10
        }
        return out
    }
    var s = CarrySchedule()
    var r = runs(&s, from: 0, to: 10, events: [(1, .connected)])
    check(r.count == 1 && r[0] >= 1 && r[0] <= 3, "a paired peer connects → one carry within 2 s: \(r)")

    s = CarrySchedule()
    r = runs(&s, from: 0, to: 20, events: [(0, .connected)] + (0..<10).map { (5 + Double($0) * 0.5, .changed) })
    check(r.count == 2 && abs(r[1] - (9.5 + CarrySchedule.quiet)) < 0.15, "ten changes 0.5 s apart → one carry, 2 s after the last: \(r)")

    s = CarrySchedule()
    r = runs(&s, from: 0, to: 20, dur: 3, events: [(0, .connected), (1, .changed), (1.2, .changed), (1.4, .foreground)])
    check(r.count == 2, "triggers during a carry → exactly one follow-up: \(r)")

    s = CarrySchedule()
    r = runs(&s, from: 0, to: 20, events: [(0, .connected), (8, .foreground)])
    check(r.count == 2 && r[1] >= 8 && r[1] <= 10, "coming to the front → a carry: \(r)")

    s = CarrySchedule()
    r = runs(&s, from: 0, to: 20, events: [(1, .changed), (2, .foreground)])
    check(r.isEmpty, "no paired peer connected → no carry: \(r)")

    s = CarrySchedule()
    r = runs(&s, from: 0, to: 20, events: [(0, .connected), (4, .disconnected), (5, .changed)])
    check(r.count == 1, "after the last peer leaves, a change waits: \(r)")

    s = CarrySchedule()
    r = runs(&s, from: 0, to: 5, events: [(1, .tapped)])
    check(r == [1], "Carry Now runs at once, connected or not (it shows its own result): \(r)")
    check(CarrySchedule.connectDelay <= 2 && CarrySchedule.quiet == 2, "the spec's 2 s")
}

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
