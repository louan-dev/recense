// Derived from Spec: FEAT-09 P3/P4 · carries out one already-decided CarrySync.decide() action against this
// device's homes. Pure file-system work, no radio and no singleton, so `carrymanagerSelftest()` can exercise it
// directly (the real path — the network exchange that produces these actions — is still device-only per FEAT-02).
import Foundation

/// The versions a 3-way text merge needs back (FEAT-22 P2, FEAT-09 P3).
/// - Text snapshots live content-addressed in `Recense/.carry/base/<sha256>`: a peer's edit names the sha it was edited from
///   (`CarryOp.parent`), and that text is the common ancestor. Taken for every text file this device sends and every one that lands.
/// - The index `base-sha.json` (key → sha) is the last version that **landed from a peer**; it changes only then. This device's own
///   unsent or unconfirmed edit is never the agreed base, or a peer's concurrent edit would replace it instead of merging with it.
/// Read fresh, written immediately; never cached in memory, so there is only one copy to go stale.
enum CarryBase {
    private static var dir: URL { Carry.dir.appendingPathComponent("base", isDirectory: true) }
    private static var indexURL: URL { Carry.dir.appendingPathComponent("base-sha.json") }
    static let maxTextBytes = 5_000_000   // a bigger "text" file is not merged; it keeps both like a non-text file

    static func load() -> [String: String] {
        (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// Call once a key's bytes are known to be agreed: they just landed clean from a peer (fetch, replace, a successful merge).
    /// Never for `keepBoth` (no single agreed version yet) and never for this device's own `put`.
    static func record(_ key: String, sha: String, fileAt url: URL) {
        var base = load()
        base[key] = sha
        try? JSONEncoder().encode(base).write(to: indexURL, options: .atomic)
        snapshot(sha: sha, fileAt: url, key: key)
    }

    /// Keeps the text of one version under its sha. Only if the file still has that sha: it may have been edited again since.
    static func snapshot(sha: String, fileAt url: URL, key: String? = nil) {
        guard CarrySync.isText(key ?? url.lastPathComponent),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size <= maxTextBytes,
              (try? Homes.sha256(url)) == sha, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: dir.appendingPathComponent(sha), atomically: true, encoding: .utf8)
    }

    static func text(for sha: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(sha), encoding: .utf8) }

    /// Drops snapshots nobody can name any more: not in the index, and untouched for `days`.
    static func prune(days: Int = 30, now: Date = Date()) {
        let keep = Set(load().values)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where !keep.contains(f.lastPathComponent) {
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(m) > Double(days) * 86_400 { try? FileManager.default.removeItem(at: f) }
        }
    }
}

enum CarryApply {
    enum Failure: Error { case noBytes, badKey(String), hashMismatch(String) }

    // Derived from Spec: SEC-02 §2.4 (bytes check)
    /// The SHA-256 the authenticated op promised for these bytes; nil for an action that carries none.
    static func expectedSha(_ action: CarryAction) -> String? {
        switch action {
        case .fetch(_, let s), .keepBoth(_, _, let s): return s
        case .replace(_, _, let new): return new
        case .merge(_, _, _, let theirs): return theirs
        case .nothing, .move: return nil
        }
    }

    /// Places staged bytes only when their SHA-256 (`sha`, hashed by the caller off the main thread) is the op's.
    /// A mismatch throws before any file call; the caller discards the bytes and the op stays owed.
    @discardableResult
    static func place(_ action: CarryAction, bytesAt: URL, sha: String) throws -> String? {
        guard let want = expectedSha(action), want == sha else { throw Failure.hashMismatch(sha) }
        return try apply(action, bytesAt: bytesAt)
    }

    /// Where a key ("home/path") lands on disk and which home it belongs to. `keep/<key>/note.md` and `lines.json` (FEAT-22 P1)
    /// have no Home (no manifest index, no trash/ entry): `home` is nil and the file is placed by path alone.
    private static func locate(_ key: String) -> (url: URL, home: Home?)? {
        let folders = Home.allCases.map(\.folder) + [CarryKeep.folder]
        guard let split = CarrySync.split(key, homes: folders) else { return nil }
        if split.home == CarryKeep.folder {
            guard CarryKeep.carries(key) || CarryKeep.isSibling(key) else { return nil }   // only the two files, or a conflict sibling of one
            return (Homes.root.appendingPathComponent(key), nil)
        }
        guard let home = Home.allCases.first(where: { $0.folder == split.home }) else { return nil }
        return (Homes.root.appendingPathComponent(key), home)
    }

    /// The file at `dest` is about to be replaced: it goes to trash/ with its origin (a home), or, for a keep/ file, to
    /// `.carry/replaced/` under its own sha: never deleted, never overwritten.
    private static func setAside(_ dest: URL, _ home: Home?) throws {
        if let home {
            let existing = try Homes.entry(for: dest, in: home)
            _ = try Homes.remove(existing, from: home)
        } else {
            let sha = try Homes.sha256(dest)
            let dir = Carry.dir.appendingPathComponent("replaced", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let to = dir.appendingPathComponent(sha + "-" + dest.deletingLastPathComponent().lastPathComponent + "-" + dest.lastPathComponent)
            if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: dest) }   // the same bytes are already kept
            else { try FileManager.default.moveItem(at: dest, to: to) }
        }
    }

    private static func index(_ dest: URL, _ home: Home?) throws {
        if let home { try Homes.record(Homes.entry(for: dest, in: home), in: home) }
    }

    /// `.fetch`/`.replace`/`.keepBoth` need `bytesAt` (a file already on disk, moved into place — never copied,
    /// so a caller holding a staged download just hands over the URL). `.move` and `.nothing` need no bytes.
    @discardableResult
    static func apply(_ action: CarryAction, bytesAt: URL? = nil) throws -> String? {
        let fm = FileManager.default
        switch action {
        case .nothing:
            return nil
        case .move(let from, let to):
            let folders = Home.allCases.map(\.folder) + [CarryKeep.folder]
            guard let fromSplit = CarrySync.split(from, homes: folders), let toSplit = CarrySync.split(to, homes: folders),
                  let src = locate(from), let dst = locate(to)
            else { throw Failure.badKey(from) }
            try fm.createDirectory(at: dst.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: src.url, to: dst.url)
            if let fh = src.home { try? Homes.forget(fromSplit.path, in: fh) }
            if let th = dst.home { try Homes.record(Homes.entry(for: dst.url, in: th), in: th) }
            _ = toSplit
            return to
        case .fetch(let key, let sha):
            guard let bytesAt else { throw Failure.noBytes }
            guard let (dest, home) = locate(key) else { throw Failure.badKey(key) }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            // T-0109: .fetch was decided from a scan taken before these bytes arrived (a big file takes minutes), so a file
            // may sit at the key now. It goes to trash/ as .replace does, never deleted.
            if fm.fileExists(atPath: dest.path) {
                try setAside(dest, home)
            }
            try fm.moveItem(at: bytesAt, to: dest)
            try index(dest, home)
            CarryBase.record(key, sha: sha, fileAt: dest)
            return key
        case .replace(let key, _, let sha):
            guard let bytesAt else { throw Failure.noBytes }
            guard let (dest, home) = locate(key) else { throw Failure.badKey(key) }
            if fm.fileExists(atPath: dest.path) {
                try setAside(dest, home)
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: bytesAt, to: dest)
            try index(dest, home)
            CarryBase.record(key, sha: sha, fileAt: dest)
            return key
        case .keepBoth(_, let sibling, _):
            guard let bytesAt else { throw Failure.noBytes }
            guard let (dest, home) = locate(sibling) else { throw Failure.badKey(sibling) }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: bytesAt, to: dest)   // the original at `key` is never touched
            try index(dest, home)
            return sibling   // no base recorded: there is no single agreed version at `key` yet
        case .merge(let key, let base, _, let theirsSha):
            // Non-overlapping edits merge clean (notesync's own 3-way rule); truly overlapping ones, or any of the three
            // texts unreadable (the base was pruned, say), keep both instead, the same safe fallback a non-text conflict uses.
            // Never a silent overwrite, and never a throw that leaves the incoming bytes neither placed nor kept.
            guard let bytesAt else { throw Failure.noBytes }
            guard let (dest, home) = locate(key) else { throw Failure.badKey(key) }
            if let baseText = CarryBase.text(for: base), let mineText = try? String(contentsOf: dest, encoding: .utf8),
               let theirsText = try? String(contentsOf: bytesAt, encoding: .utf8),
               let merged = merge3(base: baseText, mine: mineText, theirs: theirsText) {
                // the merged text goes beside first, then this device's version goes to trash/ (origin recorded), then the merge lands:
                // a failure at any step leaves this device's version where it was or in trash/, never gone
                let tmp = dest.deletingLastPathComponent().appendingPathComponent(".merge-\(UUID().uuidString)")
                try merged.write(to: tmp, atomically: true, encoding: .utf8)
                do {
                    try setAside(dest, home)
                    try fm.moveItem(at: tmp, to: dest)
                } catch { try? fm.removeItem(at: tmp); throw error }
                try index(dest, home)
                CarryBase.snapshot(sha: theirsSha, fileAt: bytesAt, key: key)   // the peer's next edit names this as its parent (review 2b66a7a)
                try? fm.removeItem(at: bytesAt)
                // the merged text is this device's own new version, not yet agreed: keep its text for a later parent lookup, no index entry
                CarryBase.snapshot(sha: try Homes.sha256(dest), fileAt: dest)
                return key
            }
            let sib = conflictSiblingPath(key, Date(), device: Homes.device)
            guard let (sibDest, sibHome) = locate(sib) else { throw Failure.badKey(sib) }
            try fm.createDirectory(at: sibDest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: bytesAt, to: sibDest)
            try index(sibDest, sibHome)
            return sib
        }
    }
}

// Regression guard: FEAT-09 P3/P4 (carryNow's settling, the device-only half of FEAT-02's link). No radios: each
// action is applied directly, as receiveOps/tryPlace in shared/carrymanager.swift would once bytes land.
func carrymanagerSelftest() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String) { print("\(pass ? "ok  " : "FAIL") carrymanager, \(what)"); ok = ok && pass }
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("recense-carryapply-\(UUID().uuidString)")
    setenv("RECENSE_HOME", dir.appendingPathComponent("Recense").path, 1)
    defer { unsetenv("RECENSE_HOME"); try? fm.removeItem(at: dir) }
    try? Homes.ensure()
    func drop(_ bytes: String) -> URL {
        let u = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? Data(bytes.utf8).write(to: u)
        return u
    }
    func put(_ key: String, _ bytes: String) {
        let u = Homes.root.appendingPathComponent(key)
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(bytes.utf8).write(to: u)
        if let h = Home.allCases.first(where: { key.hasPrefix($0.folder + "/") }) {
            try? Homes.record(try Homes.entry(for: u, in: h), in: h)
        }
    }

    // fetch: the file arrives exactly where it belongs, recorded
    do {
        let r = try? CarryApply.apply(.fetch(key: "library/Music/a.m4a", sha256: "X"), bytesAt: drop("hello"))
        check(r == "library/Music/a.m4a", "fetch lands at the exact key")
        check((try? String(contentsOf: Homes.root.appendingPathComponent("library/Music/a.m4a"))) == "hello", "with the right bytes")
        check(Homes.index(.music).contains { $0.path == "a.m4a" }, "and is recorded in the home's index")
    }

    // fetch onto a file that appeared while the bytes were in flight (T-0109): it goes to trash/, never deleted
    do {
        put("library/Music/late.m4a", "appeared meanwhile")
        _ = try? CarryApply.apply(.fetch(key: "library/Music/late.m4a", sha256: "X"), bytesAt: drop("arrived"))
        check((try? String(contentsOf: Homes.root.appendingPathComponent("library/Music/late.m4a"))) == "arrived", "fetch over a file that appeared meanwhile lands the fetched bytes")
        let kept = Homes.index(.trash).first { $0.tags.contains("from:library/Music/late.m4a") }
        check(kept != nil, "and the file that was there is in trash/, not deleted")
        if let t = kept { check((try? String(contentsOf: Homes.url(.trash).appendingPathComponent(t.path))) == "appeared meanwhile", "with its own bytes intact") }
    }

    // replace: the old version is never deleted, only moved to trash — then the new one lands clean
    do {
        put("library/Study/n.md", "old")
        _ = try? CarryApply.apply(.replace(key: "library/Study/n.md", old: "o", new: "n"), bytesAt: drop("new"))
        check((try? String(contentsOf: Homes.root.appendingPathComponent("library/Study/n.md"))) == "new", "replace lands the new bytes")
        let trashed = Homes.index(.trash).first { $0.tags.contains("from:library/Study/n.md") }
        check(trashed != nil, "the old version is in trash/, not deleted")
        if let t = trashed { check((try? String(contentsOf: Homes.url(.trash).appendingPathComponent(t.path))) == "old", "with its own bytes intact") }
    }

    // keepBoth: a real conflict keeps both, the original untouched, never overwritten
    do {
        put("library/Study/m.md", "mine")
        _ = try? CarryApply.apply(.keepBoth(key: "library/Study/m.md", sibling: "library/Study/m (iPad 2026-11-15 0800).md", sha256: "T"),
                                   bytesAt: drop("theirs"))
        check((try? String(contentsOf: Homes.root.appendingPathComponent("library/Study/m.md"))) == "mine", "the original is untouched")
        check((try? String(contentsOf: Homes.root.appendingPathComponent("library/Study/m (iPad 2026-11-15 0800).md"))) == "theirs",
              "the sibling carries the other side's bytes")
    }

    // merge: both sides changed different lines → merges clean against the sha the peer edited from; no sibling, my old version in trash/
    do {
        let k = "library/Study/o.md", url = Homes.root.appendingPathComponent(k)
        put(k, "a\nb\nc")
        let baseSha = try! Homes.sha256(url)
        CarryBase.snapshot(sha: baseSha, fileAt: url)   // what this device sent: the peer's parent
        put(k, "a\nB\nc")                                // my own edit afterwards
        let r = try? CarryApply.apply(.merge(key: k, base: baseSha, mine: "m", theirs: "t"), bytesAt: drop("a\nb\nc\nd"))   // theirs appended a line
        check(r == k, "a clean merge lands at the same key")
        check((try? String(contentsOf: url)) == "a\nB\nc\nd", "with both edits present")
        check(!fm.fileExists(atPath: Homes.root.appendingPathComponent("library/Study/o (iPad 2026-11-15 0800).md").path), "no sibling was needed")
        check(CarryBase.load()[k] == nil, "the merged text is this device's own version: not an agreed base")
        check(CarryBase.text(for: (try? Homes.sha256(url)) ?? "") == "a\nB\nc\nd", "but its text is kept for a later parent lookup")
        let trashed = (try? fm.contentsOfDirectory(at: Homes.root.appendingPathComponent("trash"), includingPropertiesForKeys: nil)) ?? []
        check(trashed.contains { (try? String(contentsOf: $0)) == "a\nB\nc" }, "my version before the merge went to trash/, never gone")
    }

    // merge twice in a row on one key: the first merge keeps the peer's text, so its next edit (parent = that sha) merges too
    do {
        let k = "library/Study/mm.md", url = Homes.root.appendingPathComponent(k)
        put(k, "1\n2\n3\n4")
        let s0 = try! Homes.sha256(url); CarryBase.snapshot(sha: s0, fileAt: url)
        put(k, "1\nTWO\n3\n4")                                              // mine
        let t1 = drop("1\n2\n3\n4\n5"), t1sha = (try? Homes.sha256(t1)) ?? ""   // theirs adds a line
        _ = try? CarryApply.place(.merge(key: k, base: s0, mine: "m", theirs: t1sha), bytesAt: t1, sha: t1sha)
        check((try? String(contentsOf: url)) == "1\nTWO\n3\n4\n5", "first merge: both edits")
        put(k, "1\nTWO\nTHREE\n4\n5")                                      // mine again
        let t2 = drop("1\n2\n3\n4\n5\n6"), t2sha = (try? Homes.sha256(t2)) ?? ""  // theirs edits from t1
        let r = try? CarryApply.place(.merge(key: k, base: t1sha, mine: "m", theirs: t2sha), bytesAt: t2, sha: t2sha)
        check(r == k && (try? String(contentsOf: url)) == "1\nTWO\nTHREE\n4\n5\n6", "second merge on the same key merges too, not a sibling: \(r ?? "nil")")
    }

    // merge: the same line changed on both sides → neither wins silently, it keeps both like any other conflict
    do {
        let k = "library/Study/p.md", url = Homes.root.appendingPathComponent(k)
        put(k, "one line")
        let baseSha = try! Homes.sha256(url)
        CarryBase.snapshot(sha: baseSha, fileAt: url)
        put(k, "mine wins here")
        let r = try? CarryApply.apply(.merge(key: k, base: baseSha, mine: "m", theirs: "t"), bytesAt: drop("theirs wins here"))
        check(r?.contains("p (") == true, "an overlapping edit falls back to a sibling, not a silent pick")
        check((try? String(contentsOf: url)) == "mine wins here", "mine is untouched")
    }

    // merge: no base on hand for this sha (pruned, or never seen) → still keeps both, never throws the bytes away
    do {
        put("library/Study/q.md", "mine")
        let r = try? CarryApply.apply(.merge(key: "library/Study/q.md", base: "no-such-sha", mine: "m", theirs: "t"), bytesAt: drop("theirs"))
        check(r != nil, "a missing base still places the incoming bytes somewhere, rather than losing them")
    }

    // base-tracking changes what decide() itself returns: unchanged since the base → a clean replace, not keepBoth
    do {
        let k = "library/Study/r.md"
        put(k, "shared")
        let sha = try! Homes.sha256(Homes.root.appendingPathComponent(k))
        CarryBase.record(k, sha: sha, fileAt: Homes.root.appendingPathComponent(k))   // I haven't touched it since
        let local = Dictionary(uniqueKeysWithValues: (try! Carry.verify()).map { (CarrySync.key($0.home, $0.path), $0.sha256) })
        let op = CarryOp(seq: 1, device: "mac", at: 1, op: .put, home: "library/Study", path: "r.md", sha256: "new-from-peer", size: 1)
        let action = CarrySync.decide(op, local: local, base: CarryBase.load())
        check(action == .replace(key: k, old: sha, new: "new-from-peer"), "unmodified since the base → replace, not keepBoth: \(action)")
    }

    // FEAT-22 P1: of keep/ only <key>/note.md and <key>/lines.json travel; each lands, is set aside never deleted, and merges
    do {
        let root = Homes.root
        func read(_ rel: String) -> String? { try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) }
        put("keep/k1/note.md", "hello"); put("keep/k1/lines.json", "{}"); put("keep/k1/find.tsv", "x"); put("keep/k1.v2.json", "y"); put("keep/k1/audio.m4a", "z")
        let seen = Set(((try? Carry.verify()) ?? []).filter { $0.home == "keep" }.map { CarrySync.key($0.home, $0.path) })
        check(seen == ["keep/k1/note.md", "keep/k1/lines.json"], "keep: only note.md and lines.json are scanned (not find.tsv, the Mac's working file or the media): \(seen.sorted())")

        let f = try? CarryApply.apply(.fetch(key: "keep/k2/note.md", sha256: "X"), bytesAt: drop("from the Mac"))
        check(f == "keep/k2/note.md" && read("keep/k2/note.md") == "from the Mac", "keep: a note arrives at its key")

        put("keep/k3/note.md", "old")
        _ = try? CarryApply.apply(.replace(key: "keep/k3/note.md", old: "o", new: "n"), bytesAt: drop("new"))
        check(read("keep/k3/note.md") == "new", "keep: a replace lands")
        let aside = (try? fm.contentsOfDirectory(atPath: Carry.dir.appendingPathComponent("replaced").path)) ?? []
        check(aside.contains { (try? String(contentsOf: Carry.dir.appendingPathComponent("replaced/\($0)"))) == "old" }, "keep: the old note is set aside in .carry/replaced/, never deleted")

        let nk = "keep/k4/note.md", nurl = root.appendingPathComponent(nk)
        put(nk, "a\nb\nc"); let nsha = try! Homes.sha256(nurl); CarryBase.snapshot(sha: nsha, fileAt: nurl)
        put(nk, "a\nB\nc")
        let mt = drop("a\nb\nc\nd"), mtsha = (try? Homes.sha256(mt)) ?? ""
        let m = try? CarryApply.place(.merge(key: nk, base: nsha, mine: "m", theirs: mtsha), bytesAt: mt, sha: mtsha)
        check(m == nk && read(nk) == "a\nB\nc\nd", "keep: two devices' edits to one note merge (FEAT-22 P2 on the new key)")

        let lk = "keep/k5/lines.json"
        put(lk, "{\"a\":1}")
        let op = CarryOp(seq: 1, device: "ipad", at: 1, op: .put, home: "keep", path: "k5/lines.json", sha256: "T", size: 1, parent: "P")
        let act = CarrySync.decide(op, local: [lk: "MINE"], base: [:], zone: TimeZone(identifier: "UTC")!)
        var sib: String? = nil
        if case .keepBoth(_, let s, _) = act { sib = s }
        check(sib != nil, "keep: lines.json is never text-merged (a merge could break the JSON): it keeps both")
        if let sib { let r = try? CarryApply.apply(act, bytesAt: drop("{\"b\":2}")); check(r == sib && read(lk) == "{\"a\":1}" && read(sib) == "{\"b\":2}" && CarryKeep.isSibling(sib) && !CarryKeep.carries(sib), "keep: the conflict copy lands beside it and is not carried on") }

        var refused = false
        do { _ = try CarryApply.apply(.fetch(key: "keep/k6/find.tsv", sha256: "Y"), bytesAt: drop("index")) } catch { refused = true }
        check(refused && read("keep/k6/find.tsv") == nil, "keep: any other file (find.tsv) is refused, nothing lands")
    }

    // move: no bytes needed, the index follows the file (even across homes)
    do {
        put("downloads/clip.mp4", "video")
        let r = try? CarryApply.apply(.move(from: "downloads/clip.mp4", to: "library/Study/clip.mp4"))
        check(r == "library/Study/clip.mp4", "move reports its destination")
        check(!fm.fileExists(atPath: Homes.root.appendingPathComponent("downloads/clip.mp4").path), "gone from the old home")
        check(Homes.index(.downloads).contains { $0.path == "clip.mp4" } == false, "forgotten in the old home's index")
        check(Homes.index(.study).contains { $0.path == "clip.mp4" }, "recorded in the new home's index")
    }

    // nothing: no files touched, no error
    do { check((try? CarryApply.apply(.nothing)) == Optional<String?>.some(nil), "nothing is a safe no-op") }

    // fetch/replace/keepBoth without bytes is refused, never silently skipped
    do {
        var threw = false
        do { _ = try CarryApply.apply(.fetch(key: "x", sha256: "y")) } catch { threw = true }
        check(threw, "fetch without bytes throws rather than silently doing nothing")
    }

    // Regression guard: SEC-02 §4.11 · bytes whose SHA-256 differs from the op's are never placed
    do {
        let staged = drop("swapped"), real = (try? Homes.sha256(staged)) ?? ""
        var threw = false
        do { try CarryApply.place(.fetch(key: "library/Music/sw.m4a", sha256: String(repeating: "0", count: 64)), bytesAt: staged, sha: real) }
        catch { threw = true }
        check(threw && !fm.fileExists(atPath: Homes.root.appendingPathComponent("library/Music/sw.m4a").path),
              "bytes check: a hash that differs from the op's is refused and nothing lands")
        check(fm.fileExists(atPath: staged.path), "bytes check: the staged bytes stay for the caller to discard (the op stays owed)")
        let r = try? CarryApply.place(.fetch(key: "library/Music/sw.m4a", sha256: real), bytesAt: staged, sha: real)
        check(r == "library/Music/sw.m4a", "bytes check: the op's own hash lands")
    }

    // Regression guard: FEAT-22 P2 · a .merge goes through place() like every other action. The rescued code gave it no expected
    // sha, so place() refused every merge on the real path (only apply() was tested). The peer's bytes must hash to the op's sha.
    do {
        let k = "library/Study/pm.md", url = Homes.root.appendingPathComponent(k)
        put(k, "a\nb\nc")
        let baseSha = try! Homes.sha256(url)
        CarryBase.snapshot(sha: baseSha, fileAt: url)
        put(k, "a\nB\nc")
        let theirs = drop("a\nb\nc\nd"), theirsSha = (try? Homes.sha256(theirs)) ?? ""
        var refused = false
        do { try CarryApply.place(.merge(key: k, base: baseSha, mine: "m", theirs: theirsSha), bytesAt: theirs, sha: String(repeating: "0", count: 64)) }
        catch { refused = true }
        check(refused && (try? String(contentsOf: url)) == "a\nB\nc", "merge via place: bytes that do not hash to the op's sha are refused, my file untouched")
        let r = try? CarryApply.place(.merge(key: k, base: baseSha, mine: "m", theirs: theirsSha), bytesAt: theirs, sha: theirsSha)
        check(r == k && (try? String(contentsOf: url)) == "a\nB\nc\nd", "merge via place: the op's own hash merges both edits")
    }

    // Regression guard: SEC-02 §4.10 · a `..` key throws badKey before any file call
    do {
        let outside = Homes.root.deletingLastPathComponent().appendingPathComponent("escaped.txt")
        var bad = 0
        for action in [CarryAction.fetch(key: "library/Music/../../escaped.txt", sha256: "x"),
                       .keepBoth(key: "library/Music/a", sibling: "library/Music/../../escaped.txt", sha256: "x"),
                       .replace(key: "/library/Music/a", old: "o", new: "n")] {
            do { try CarryApply.apply(action, bytesAt: drop("evil")) } catch CarryApply.Failure.badKey { bad += 1 } catch {}
        }
        do { try CarryApply.apply(.move(from: "library/Music/a.m4a", to: "library/Music/../../escaped.txt")) }
        catch CarryApply.Failure.badKey { bad += 1 } catch {}
        check(bad == 4 && !fm.fileExists(atPath: outside.path), "a key with .. or a leading / throws badKey and nothing lands outside")
    }
    return ok
}
