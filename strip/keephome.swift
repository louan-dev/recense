import Foundation
import CryptoKit

// ---------- transcripts' home (D19) ----------
// ~/Recense/keep/ is the main copy of every transcript on this Mac; R2's keep/ mirrors it (Keep, Store.sweep), and
// ~/Library/Caches/recense/ keeps media only. "A transcript" is each of an item's own files, under the names they had
// in the cache:
//   <key>.v2.json          the transcript (its English inside)
//   <key>.edits.json       the listener's corrections
//   <key>.tr.<lang>.json   its other languages
//   <key>.features.json    a song's measured voice
// Keep turns them into R2's per-item folders (<key>/asr.json, tr/<lang>.json, corrections.json) as it sends them.
// Nothing here is ever swept: a transcript stays on this Mac whether or not it has been mirrored.
// Read order: here → the cache (legacy; only until every transcript there is copied here and verified) → R2's keep/
// (Keep.restore, which writes what it fetches here). With the network off, a transcript opens from here.
// RECENSE_KEEP points it elsewhere; a test cache (RECENSE_CACHE) gets <cache>/keep, so a test never touches ~/Recense.
let keepDir: URL = {
    let env = ProcessInfo.processInfo.environment
    let d = env["RECENSE_KEEP"].map { URL(fileURLWithPath: $0) }
        ?? env["RECENSE_CACHE"].map { URL(fileURLWithPath: $0).appendingPathComponent("keep") }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Recense/keep")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}()

enum KeepHome {
    /// Written in keep once every transcript the cache had is verified here: from then on the cache isn't read.
    static let marker = ".migrated-from-caches"

    static func isTranscript(_ name: String) -> Bool {
        name.wholeMatch(of: #/[0-9a-f]{24}\.(v2|edits|features|tr\.[a-z]{2,3})\.json/#) != nil
    }

    static func migrated(_ keep: URL = keepDir) -> Bool {
        FileManager.default.fileExists(atPath: keep.appendingPathComponent(marker).path)
    }

    /// Where an item's file is read and written: here, unless only the cache has it and the move isn't verified yet.
    static func url(_ name: String, keep: URL = keepDir, cache: URL = cacheDir) -> URL {
        let k = keep.appendingPathComponent(name), fm = FileManager.default
        var dir: ObjCBool = false
        if (fm.fileExists(atPath: k.path, isDirectory: &dir) && !dir.boolValue) || migrated(keep) { return k }
        let c = cache.appendingPathComponent(name)
        return fm.fileExists(atPath: c.path) ? c : k
    }

    /// The transcripts in a folder, by name.
    static func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter(isTranscript)
    }

    struct Report: Equatable { var found = 0, copied = 0, verified = 0, removed = 0, replaced = 0; var failed: [String] = [] }

    /// Every transcript in the cache copied here once. Each is verified (same SHA-256) before its cache copy goes; one
    /// that can't be copied stays in the cache untouched. When the cache and keep hold different versions (a build
    /// from before this one wrote the cache meanwhile), the newer is the one kept here and the older is set aside in
    /// keep/.replaced/, verified the same way: nothing is deleted. When every one found is verified (count and
    /// checksums), the marker is written. Run again, it finds nothing left to do.
    @discardableResult
    static func migrate(from cache: URL = cacheDir, to keep: URL = keepDir) -> Report {
        let fm = FileManager.default
        var r = Report()
        try? fm.createDirectory(at: keep, withIntermediateDirectories: true)
        let mtime = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        for name in names(in: cache) {
            r.found += 1
            let c = cache.appendingPathComponent(name), k = keep.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: k.path, isDirectory: &isDir), !isDir.boolValue, let a = sha256(c), let b = sha256(k), a != b {
                // two versions: the older one set aside (moved, then checked), the newer one stays or comes here
                let cacheNewer = (mtime(c) ?? .distantPast) > (mtime(k) ?? .distantPast)
                let older = cacheNewer ? k : c, olderSha = cacheNewer ? b : a
                let aside = keep.appendingPathComponent(".replaced", isDirectory: true)
                let dest = aside.appendingPathComponent("\(name).\(Int((mtime(older) ?? Date()).timeIntervalSince1970))\(cacheNewer ? "" : ".from-caches")")
                try? fm.createDirectory(at: aside, withIntermediateDirectories: true)
                guard !fm.fileExists(atPath: dest.path), (try? fm.moveItem(at: older, to: dest)) != nil else { r.failed.append(name); continue }
                guard sha256(dest) == olderSha else { r.failed.append(name); continue }
                r.replaced += 1
                if !cacheNewer { r.verified += 1; r.removed += 1; continue }    // the cache's older copy is what moved
            }
            if !fm.fileExists(atPath: k.path) {
                guard (try? fm.copyItem(at: c, to: k)) != nil else { r.failed.append(name); continue }
                // the same modification date, so what was mirrored to R2 isn't sent again (Store.mirrored)
                if let m = mtime(c) { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: k.path) }
                r.copied += 1
            }
            guard let a = sha256(c), let b = sha256(k), a == b else { r.failed.append(name); continue }
            r.verified += 1
            guard (try? fm.removeItem(at: c)) != nil else { r.failed.append(name); continue }
            r.removed += 1
        }
        if r.failed.isEmpty, r.verified == r.found, !migrated(keep) {
            let note = "\(ISO8601DateFormatter().string(from: Date())) \(r.found) transcript(s) moved from \(cache.path), each verified by SHA-256\n"
            try? Data(note.utf8).write(to: keep.appendingPathComponent(marker))
        }
        return r
    }

    static func sha256(_ u: URL) -> String? {
        guard let d = try? Data(contentsOf: u) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
}

/// `recense selftest`: where transcripts live, the move out of the cache, and the read order, in a scratch folder.
func keepSelftest() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String, _ got: Any = "") { print("\(pass ? "ok  " : "FAIL") keep, \(what)\(pass ? "" : " — got \(got)")"); ok = ok && pass }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("recense-keep-selftest-\(ProcessInfo.processInfo.processIdentifier)")
    try? fm.removeItem(at: root)
    defer { try? fm.removeItem(at: root) }
    let cache = root.appendingPathComponent("cache"), keep = root.appendingPathComponent("keep")
    try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
    let k = { (c: Character) in String(repeating: c, count: 24) }
    func put(_ dir: URL, _ name: String, _ body: String) { try? Data(body.utf8).write(to: dir.appendingPathComponent(name)) }
    func body(_ dir: URL, _ name: String) -> String? { (try? Data(contentsOf: dir.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) } }

    // the keep paths
    let env = ProcessInfo.processInfo.environment
    if env["RECENSE_KEEP"] == nil && env["RECENSE_CACHE"] == nil {
        check(keepDir.path == fm.homeDirectoryForCurrentUser.appendingPathComponent("Recense/keep").path, "transcripts live in ~/Recense/keep", keepDir.path)
    }
    let kinds = ["\(k("a")).v2.json", "\(k("a")).edits.json", "\(k("a")).tr.vi.json", "\(k("a")).tr.fr.json", "\(k("a")).features.json"]
    check(kinds.allSatisfy(KeepHome.isTranscript), "transcript, corrections, translations and features are kept", kinds.filter { !KeepHome.isTranscript($0) })
    let media = ["\(k("a")).m4a", "\(k("a"))-vocals.wav", "\(k("a")).prosody.json", "\(k("a")).raw.json", "library.json", "bookmarks.json"]
    check(!media.contains(where: KeepHome.isTranscript), "media and the rest stay in the cache", media.filter(KeepHome.isTranscript))

    // the read order: keep → cache (until the move is verified) → keep (new, or fetched back from R2 into it)
    put(cache, "\(k("b")).v2.json", "cache"); put(cache, "\(k("c")).v2.json", "cache-only")
    try? fm.createDirectory(at: keep, withIntermediateDirectories: true)
    put(keep, "\(k("b")).v2.json", "keep")
    check(KeepHome.url("\(k("b")).v2.json", keep: keep, cache: cache).deletingLastPathComponent().path == keep.path, "keep is read before the cache")
    check(KeepHome.url("\(k("c")).v2.json", keep: keep, cache: cache).deletingLastPathComponent().path == cache.path, "the cache is read while the move isn't verified")
    check(KeepHome.url("\(k("d")).v2.json", keep: keep, cache: cache).deletingLastPathComponent().path == keep.path, "a new transcript (or one fetched from R2) goes to keep")

    // the move: copied, verified, only then removed from the cache; a copy that can't be made, or differs, never removes
    try? fm.removeItem(at: keep); try? fm.removeItem(at: cache)
    try? fm.createDirectory(at: cache, withIntermediateDirectories: true); try? fm.createDirectory(at: keep, withIntermediateDirectories: true)
    for n in kinds { put(cache, n, "body of \(n)") }
    put(cache, "\(k("e")).m4a", "audio")
    // two versions (an older build wrote the cache meanwhile): the newer is kept, the older set aside, nothing deleted
    func age(_ dir: URL, _ name: String, _ days: Double) {
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86400)], ofItemAtPath: dir.appendingPathComponent(name).path)
    }
    put(cache, "\(k("f")).v2.json", "newer, in cache"); put(keep, "\(k("f")).v2.json", "older, in keep"); age(keep, "\(k("f")).v2.json", 2)
    put(cache, "\(k("9")).v2.json", "older, in cache"); put(keep, "\(k("9")).v2.json", "newer, in keep"); age(cache, "\(k("9")).v2.json", 2)
    try? fm.createDirectory(at: keep.appendingPathComponent("\(k("8")).v2.json"), withIntermediateDirectories: true)   // can't be written there
    put(cache, "\(k("8")).v2.json", "unmovable")
    let shas = Dictionary(uniqueKeysWithValues: kinds.map { ($0, KeepHome.sha256(cache.appendingPathComponent($0))) })
    let first = KeepHome.migrate(from: cache, to: keep)
    check(first.found == 8 && first.copied == 6 && first.verified == 7 && first.removed == 7 && first.replaced == 2 && first.failed == ["\(k("8")).v2.json"],
          "five moved, two versions settled, each verified; one left", first)
    check(kinds.allSatisfy { KeepHome.sha256(keep.appendingPathComponent($0)) == shas[$0]! && !fm.fileExists(atPath: cache.appendingPathComponent($0).path) },
          "each copy has the original's checksum, and the original is gone only then")
    let aside = Set(((try? fm.contentsOfDirectory(atPath: keep.appendingPathComponent(".replaced").path)) ?? [])
        .compactMap { body(keep.appendingPathComponent(".replaced"), $0) })
    check(body(keep, "\(k("f")).v2.json") == "newer, in cache" && body(keep, "\(k("9")).v2.json") == "newer, in keep"
          && aside == ["older, in keep", "older, in cache"], "two versions: the newer kept, the older set aside in .replaced", aside)
    check(body(cache, "\(k("8")).v2.json") == "unmovable", "one that can't be copied stays in the cache")
    check(body(cache, "\(k("e")).m4a") == "audio" && !fm.fileExists(atPath: keep.appendingPathComponent("\(k("e")).m4a").path), "media isn't moved")
    check(!KeepHome.migrated(keep), "not marked moved while one isn't verified")
    check(KeepHome.url("\(k("8")).v2.json", keep: keep, cache: cache).deletingLastPathComponent().path == cache.path, "so the cache is still read for it")
    let again = KeepHome.migrate(from: cache, to: keep)
    check(again.found == 1 && again.copied == 0 && again.removed == 0 && again.replaced == 0 && again.failed.count == 1, "run again, nothing new is copied, set aside or removed", again)
    // the obstacles cleared: the next run finishes and marks it
    try? fm.removeItem(at: keep.appendingPathComponent("\(k("8")).v2.json"))
    let last = KeepHome.migrate(from: cache, to: keep)
    check(last.found == 1 && last.removed == 1 && last.failed.isEmpty && KeepHome.migrated(keep), "the last one moves, and the move is marked done", last)
    check(KeepHome.migrate(from: cache, to: keep) == KeepHome.Report(), "done, it's idempotent: nothing found")
    put(cache, "\(k("7")).v2.json", "stray")
    check(KeepHome.url("\(k("7")).v2.json", keep: keep, cache: cache).deletingLastPathComponent().path == keep.path, "once marked, the cache isn't read")

    // D28: ⏯ drives Recense's loaded piece, however long its player has been quiet; other apps only with none loaded
    check(AppDelegate.playTarget(loaded: true, followed: "https://example.com/a.mp3") == .recense, "play: a loaded piece is played by Recense")
    check(AppDelegate.playTarget(loaded: false, followed: "") == .otherApps, "play: nothing loaded, the system ⏯ key")
    check(AppDelegate.playTarget(loaded: true, followed: "") == .otherApps, "play: no player followed, the system ⏯ key")
    return ok
}
