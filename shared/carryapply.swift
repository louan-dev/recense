// Derived from Spec: FEAT-09 P3/P4 · carries out one already-decided CarrySync.decide() action against this
// device's homes. Pure file-system work, no radio and no singleton, so `carrymanagerSelftest()` can exercise it
// directly (the real path — the network exchange that produces these actions — is still device-only per FEAT-02).
import Foundation

enum CarryApply {
    enum Failure: Error { case noBytes, badKey(String) }

    /// Where a key ("home/path") lands on disk and which home it belongs to.
    private static func locate(_ key: String) -> (url: URL, home: Home)? {
        let folders = Home.allCases.map(\.folder)
        guard let split = CarrySync.split(key, homes: folders), let home = Home.allCases.first(where: { $0.folder == split.home })
        else { return nil }
        return (Homes.root.appendingPathComponent(key), home)
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
            let folders = Home.allCases.map(\.folder)
            guard let fromSplit = CarrySync.split(from, homes: folders), let toSplit = CarrySync.split(to, homes: folders),
                  let fh = Home.allCases.first(where: { $0.folder == fromSplit.home }),
                  let th = Home.allCases.first(where: { $0.folder == toSplit.home })
            else { throw Failure.badKey(from) }
            let src = Homes.root.appendingPathComponent(from), dst = Homes.root.appendingPathComponent(to)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: src, to: dst)
            try? Homes.forget(fromSplit.path, in: fh)
            try Homes.record(Homes.entry(for: dst, in: th), in: th)
            return to
        case .fetch(let key, _):
            guard let bytesAt else { throw Failure.noBytes }
            guard let (dest, home) = locate(key) else { throw Failure.badKey(key) }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            // T-0109: .fetch was decided from a scan taken before these bytes arrived (a big file takes minutes), so a file
            // may sit at the key now. It goes to trash/ as .replace does, never deleted.
            if fm.fileExists(atPath: dest.path) {
                let existing = try Homes.entry(for: dest, in: home)
                _ = try Homes.remove(existing, from: home)
            }
            try fm.moveItem(at: bytesAt, to: dest)
            try Homes.record(Homes.entry(for: dest, in: home), in: home)
            return key
        case .replace(let key, _, _):
            guard let bytesAt else { throw Failure.noBytes }
            guard let (dest, home) = locate(key) else { throw Failure.badKey(key) }
            if fm.fileExists(atPath: dest.path) {
                let existing = try Homes.entry(for: dest, in: home)
                _ = try Homes.remove(existing, from: home)   // into trash/, origin recorded — never silently lost
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: bytesAt, to: dest)
            try Homes.record(Homes.entry(for: dest, in: home), in: home)
            return key
        case .keepBoth(_, let sibling, _):
            guard let bytesAt else { throw Failure.noBytes }
            guard let (dest, home) = locate(sibling) else { throw Failure.badKey(sibling) }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: bytesAt, to: dest)   // the original at `key` is never touched
            try Homes.record(Homes.entry(for: dest, in: home), in: home)
            return sibling
        case .merge:
            throw Failure.badKey("merge is unreachable without a tracked base (carrymanager passes base: [:])")
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
    return ok
}
