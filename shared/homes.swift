// Derived from Spec: FEAT-06
// Homes: one layout on every device (the owner's folder contract, 2026-11-08). Mac: ~/Recense/. iPhone and iPad:
// Documents/Recense/, visible in the Files app. Under it: library/Music, library/Study, library/Legal,
// library/Audiobooks, library/Listen, downloads/ and trash/ — plain files, plus one small manifest per home
// (.recense-index.json: path, size, sha256, added, device, tags) so every device knows what exists even before the
// bytes arrive. Nothing is deleted unless the owner says so: remove() moves into .trash and records where the file
// came from; deleteForever() refuses to work anywhere but trash/. No network at any point: filesystem and CryptoKit.
// The folder shape, the chunked sha256 and adopt() are mediadownload.swift's, generalized here, not a second
// mechanism; ShowsKit keeps Kind (the one file-kind classifier) and PoolScan (the catalog's reader).
import Foundation
import CryptoKit
import ShowsKit

/// The homes of Recense/, in the order the owner lists them.
enum Home: String, Codable, CaseIterable, Sendable {
    case music, study, legal, audiobooks, listen, downloads, trash

    /// The folder, relative to Homes.root. Trash is visible (`trash/`): the owner must be able to see and put back
    /// what was removed. ShowsKit's `Zone.folder` still writes `.trash`; `Zone(folder:)` reads both (FEAT-06).
    var folder: String {
        switch self {
        case .music: "library/Music"
        case .study: "library/Study"
        case .legal: "library/Legal"
        case .audiobooks: "library/Audiobooks"
        case .listen: "library/Listen"
        case .downloads: "downloads"      // the same string as ShowsKit's Rules.downloads, where the catalog reads it
        case .trash: "trash"             // the owner's contract, and the folder Listen already uses; see FEAT-06
        }
    }

    var label: String {
        switch self {
        case .music: "Music"; case .study: "Study"; case .legal: "Legal"; case .audiobooks: "Audiobooks"
        case .listen: "Listen"; case .downloads: "Downloads"; case .trash: "Trash"
        }
    }
}

/// One file in a home, as that home's manifest knows it.
struct HomeEntry: Codable, Equatable, Sendable {
    var path: String        // relative to the home's folder (subfolders kept, e.g. "Chopin/nocturne.m4a")
    var size: Int64
    var sha256: String
    var added: String       // ISO 8601, when it landed on this device
    var device: String      // which device recorded it
    var tags: [String] = [] // free labels; a trashed file carries "from:<home folder>/<path>"
}

enum Homes {
    enum Failure: Error, CustomStringConvertible {
        case notTrash(Home)
        case noOrigin(String)
        case missing(String)
        case mismatch(String)

        var description: String {
            switch self {
            case .notTrash(let h): "Delete forever works only inside Trash (asked for \(h.label))"
            case .noOrigin(let p): "\(p) has no recorded origin to restore to"
            case .missing(let p): "\(p) is not on this device"
            case .mismatch(let p): "\(p) does not match the bytes that were recorded"
            }
        }
    }

    static let indexName = ".recense-index.json"

    /// Recense/. RECENSE_HOME points it elsewhere (tests never touch the real folder).
    static var root: URL {
        if let p = ProcessInfo.processInfo.environment["RECENSE_HOME"] { return URL(fileURLWithPath: p, isDirectory: true) }
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Recense", isDirectory: true)
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recense", isDirectory: true)
        #endif
    }

    static func url(_ home: Home) -> URL { root.appendingPathComponent(home.folder, isDirectory: true) }
    static func indexURL(_ home: Home) -> URL { url(home).appendingPathComponent(indexName) }
    static func file(_ entry: HomeEntry, in home: Home) -> URL { url(home).appendingPathComponent(entry.path) }

    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    /// This device's name, as it goes into a manifest entry.
    static var device: String {
        #if os(macOS)
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }

    /// Creates every home. Safe on every launch; needs no network.
    static func ensure() throws {
        for h in Home.allCases {
            try FileManager.default.createDirectory(at: url(h), withIntermediateDirectories: true)
        }
    }

    // MARK: the manifest

    static func index(_ home: Home) -> [HomeEntry] {
        guard let d = try? Data(contentsOf: indexURL(home)) else { return [] }
        return (try? JSONDecoder().decode([HomeEntry].self, from: d)) ?? []
    }

    static func write(_ entries: [HomeEntry], to home: Home) throws {
        try FileManager.default.createDirectory(at: url(home), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(entries.sorted { $0.added > $1.added }).write(to: indexURL(home), options: .atomic)
        NotificationCenter.default.post(name: Homes.changed, object: nil)
    }

    /// Posted after any home's manifest changes (add, move, rename, forget): automatic carry listens (FEAT-09 P4).
    static let changed = Notification.Name("local.recense.homes.changed")

    /// Adds, or replaces by path, one entry.
    static func record(_ entry: HomeEntry, in home: Home) throws {
        try write(index(home).filter { $0.path != entry.path } + [entry], to: home)
    }

    static func forget(_ path: String, in home: Home) throws {
        try write(index(home).filter { $0.path != path }, to: home)
    }

    /// Chunked, so a long audiobook costs one buffer, not its whole length in memory.
    static func sha256(_ url: URL) throws -> String {
        guard let h = FileHandle(forReadingAtPath: url.path) else { throw Failure.missing(url.lastPathComponent) }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func entry(for file: URL, in home: Home, tags: [String] = []) throws -> HomeEntry {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        return HomeEntry(path: relative(file, to: url(home)), size: size, sha256: try sha256(file),
                         added: now(), device: device, tags: tags)
    }

    static func relative(_ u: URL, to base: URL) -> String {
        let b = base.standardizedFileURL.resolvingSymlinksInPath().path
        let p = u.standardizedFileURL.resolvingSymlinksInPath().path
        return p.hasPrefix(b + "/") ? String(p.dropFirst(b.count + 1)) : u.lastPathComponent
    }

    // MARK: taking a file in

    /// Where a file goes when the owner doesn't choose: audio → Music (an audiobook → Audiobooks), a document → Study,
    /// anything else → Downloads. Kind(path:) stays ShowsKit's one classifier.
    static func home(for path: String) -> Home {
        let ext = (path as NSString).pathExtension.lowercased()
        if audiobookExtensions.contains(ext) { return .audiobooks }
        switch Kind(path: path) {
        case .audio: return .music
        case .pdf, .text: return .study
        case .video, .image, .other: return .downloads
        }
    }

    static let audiobookExtensions: Set<String> = ["m4b", "aa", "aax"]

    /// A name not yet taken in the home: "name 2.ext", as Finder and Safari do. Never overwrites.
    static func freeName(_ name: String, in home: Home, under subfolder: String = "") -> String {
        freeName(name, in: subfolder.isEmpty ? url(home) : url(home).appendingPathComponent(subfolder, isDirectory: true))
    }

    static func freeName(_ name: String, in dir: URL) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent(name).path) else { return name }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent("\(base) \(n)\(suffix)").path) { n += 1 }
        return "\(base) \(n)\(suffix)"
    }

    /// Takes a file into a home: moved by default (the owner's rule is move, never copy), given a free name rather
    /// than overwriting, its sha256 recorded as the bytes landed.
    @discardableResult
    static func add(_ source: URL, to home: Home? = nil, move: Bool = true, subfolder: String = "",
                    tags: [String] = []) throws -> HomeEntry {
        let fm = FileManager.default
        let h = home ?? self.home(for: source.lastPathComponent)
        let dir = subfolder.isEmpty ? url(h) : url(h).appendingPathComponent(subfolder, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = freeName(source.lastPathComponent, in: h, under: subfolder)
        let dest = dir.appendingPathComponent(name)
        if move { try fm.moveItem(at: source, to: dest) } else { try fm.copyItem(at: source, to: dest) }
        let e = try entry(for: dest, in: h, tags: tags)
        try record(e, in: h)
        return e
    }

    /// Files already in a home that its manifest doesn't know (dropped in by Finder, the Files app, AirDrop,
    /// Pulltube): recorded, once each. Returns what was added.
    @discardableResult
    static func adopt(_ home: Home) throws -> [HomeEntry] {
        let fm = FileManager.default
        try fm.createDirectory(at: url(home), withIntermediateDirectories: true)
        let known = Set(index(home).map(\.path))
        var added: [HomeEntry] = []
        guard let walk = fm.enumerator(at: url(home), includingPropertiesForKeys: [.isRegularFileKey],
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let u as URL in walk {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = relative(u, to: url(home))
            guard !known.contains(path), !u.lastPathComponent.hasSuffix(".part") else { continue }
            var e = try entry(for: u, in: home, tags: ["adopted"])
            e.path = path
            try record(e, in: home); added.append(e)
        }
        return added
    }

    /// Does the file still hold the bytes the manifest recorded?
    static func intact(_ entry: HomeEntry, in home: Home) -> Bool {
        (try? sha256(file(entry, in: home))) == entry.sha256
    }

    // MARK: remove, restore, delete forever

    /// "Remove": moves the file into .trash and records the home and path it came from. Nothing is deleted.
    @discardableResult
    static func remove(_ entry: HomeEntry, from home: Home) throws -> HomeEntry {
        guard home != .trash else { return entry }
        let fm = FileManager.default
        let source = file(entry, in: home)
        guard fm.fileExists(atPath: source.path) else { throw Failure.missing(entry.path) }
        try fm.createDirectory(at: url(.trash), withIntermediateDirectories: true)
        let name = freeName((entry.path as NSString).lastPathComponent, in: .trash)
        try fm.moveItem(at: source, to: url(.trash).appendingPathComponent(name))
        var trashed = entry
        trashed.path = name
        trashed.added = now()
        trashed.tags = entry.tags.filter { !$0.hasPrefix("from:") } + ["from:\(home.folder)/\(entry.path)"]
        try record(trashed, in: .trash)
        try forget(entry.path, in: home)
        return trashed
    }

    /// Puts a trashed file back where it came from.
    @discardableResult
    static func restore(_ entry: HomeEntry) throws -> HomeEntry {
        guard let tag = entry.tags.first(where: { $0.hasPrefix("from:") }) else { throw Failure.noOrigin(entry.path) }
        let origin = String(tag.dropFirst("from:".count))
        guard let home = Home.allCases.first(where: { origin == $0.folder || origin.hasPrefix($0.folder + "/") }) else {
            throw Failure.noOrigin(entry.path)
        }
        let fm = FileManager.default
        let back = String(origin.dropFirst(min(origin.count, home.folder.count + 1)))
        let dest = url(home).appendingPathComponent(back.isEmpty ? entry.path : back)
        let dir = dest.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let final = dir.appendingPathComponent(freeName(dest.lastPathComponent, in: dir))
        try fm.moveItem(at: file(entry, in: .trash), to: final)
        var put = entry
        put.path = relative(final, to: url(home))
        put.added = now()
        put.tags = entry.tags.filter { !$0.hasPrefix("from:") }
        try record(put, in: home)
        try forget(entry.path, in: .trash)
        return put
    }

    /// "Delete forever": only inside Trash, only on a file the owner named. Anywhere else it throws.
    static func deleteForever(_ entry: HomeEntry, from home: Home) throws {
        guard home == .trash else { throw Failure.notTrash(home) }
        try FileManager.default.removeItem(at: file(entry, in: .trash))
        try forget(entry.path, in: .trash)
    }
}

// MARK: - carry C0: the exit exists before anything relies on it (owner, 2026-11-11)

/// One line of ~/Recense/.carry/manifest.jsonl: what this device holds, in a format any tool can read.
struct CarryLine: Codable, Equatable, Sendable {
    var home: String        // the home's folder, e.g. "library/Music"
    var path: String        // relative to the home
    var size: Int64
    var mtime: Int64        // whole seconds
    var sha256: String
    var device: String
}

enum Carry {
    static var dir: URL { Homes.root.appendingPathComponent(".carry", isDirectory: true) }
    static var manifestURL: URL { dir.appendingPathComponent("manifest.jsonl") }

    /// Every file in every home, hashed. Append-only JSON Lines: one file per line, readable by any tool, diffable.
    /// `reuse` (automatic carry, FEAT-09 P4): a file whose size and mtime match the last manifest keeps its hash
    /// instead of being read again. Off for `move`, which must prove every byte.
    @discardableResult
    static func verify(reuse: Bool = false) throws -> [CarryLine] {
        let fm = FileManager.default
        var out: [CarryLine] = []
        var last: [String: CarryLine] = [:]
        if reuse, let text = try? String(contentsOf: manifestURL, encoding: .utf8) {
            for l in text.split(separator: "\n") {
                if let c = try? JSONDecoder().decode(CarryLine.self, from: Data(l.utf8)) { last[c.home + "/" + c.path] = c }
            }
        }
        for h in Home.allCases {
            guard let walk = fm.enumerator(at: Homes.url(h), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let u as URL in walk {
                guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      v.isRegularFile == true else { continue }
                let path = Homes.relative(u, to: Homes.url(h))
                let size = Int64(v.fileSize ?? 0), mtime = Int64(v.contentModificationDate?.timeIntervalSince1970 ?? 0)
                let was = last[h.folder + "/" + path]
                let sha = (was?.size == size && was?.mtime == mtime) ? was!.sha256 : try Homes.sha256(u)
                out.append(CarryLine(home: h.folder, path: path, size: size, mtime: mtime, sha256: sha, device: Homes.device))
            }
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try out.sorted { ($0.home, $0.path) < ($1.home, $1.path) }
            .map { String(decoding: try e.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
        try Data((body + (body.isEmpty ? "" : "\n")).utf8).write(to: manifestURL, options: .atomic)
        return out
    }

    struct Receipt: Codable, Sendable {
        var at: String
        var from: String
        var to: String
        var device: String
        var files: Int
        var bytes: Int64
        var mismatched: [String]
    }

    /// Copies every home into `dest`, verifies every sha256 after the copy, writes a receipt, and leaves the source
    /// in place. A file whose copy doesn't match is named in the receipt and in the thrown error; nothing is removed.
    @discardableResult
    static func move(to dest: URL) throws -> Receipt {
        let fm = FileManager.default
        let lines = try verify()
        var mismatched: [String] = [], bytes: Int64 = 0
        for l in lines {
            let source = Homes.root.appendingPathComponent(l.home).appendingPathComponent(l.path)
            let target = dest.appendingPathComponent(l.home).appendingPathComponent(l.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path), (try? Homes.sha256(target)) == l.sha256 { bytes += l.size; continue }
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
            if (try? Homes.sha256(target)) == l.sha256 { bytes += l.size } else { mismatched.append("\(l.home)/\(l.path)") }
        }
        let r = Receipt(at: Homes.now(), from: Homes.root.path, to: dest.path, device: Homes.device,
                        files: lines.count, bytes: bytes, mismatched: mismatched)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let stamp = r.at.replacingOccurrences(of: ":", with: "-")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try e.encode(r).write(to: dest.appendingPathComponent("carry-receipt-\(stamp).json"), options: .atomic)
        if !mismatched.isEmpty { throw Homes.Failure.mismatch(mismatched.joined(separator: ", ")) }
        return r
    }
}

// MARK: - selftest

/// `recense selftest`: the homes, their manifests, taking a file in, adopt, remove to Trash, restore, delete forever,
/// and carry C0 (verify + a verified move) — all in a scratch folder, with no network and no permissions.
func homesSelftest() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String, _ got: Any = "") { print("\(pass ? "ok  " : "FAIL") homes, \(what)\(pass ? "" : " — got \(got)")"); ok = ok && pass }
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("recense-homes-\(UUID().uuidString)")
    let scratch = dir.appendingPathComponent("in"), carried = dir.appendingPathComponent("carried")
    setenv("RECENSE_HOME", dir.appendingPathComponent("Recense").path, 1)
    defer { unsetenv("RECENSE_HOME"); try? fm.removeItem(at: dir) }
    try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    func drop(_ name: String, _ body: String = "bytes") -> URL {
        let u = scratch.appendingPathComponent(name)
        try? Data(body.utf8).write(to: u)
        return u
    }

    // the folders, exactly as the owner's contract names them
    do { try Homes.ensure() } catch { check(false, "ensure() creates the homes", error) }
    check(Home.allCases.allSatisfy { fm.fileExists(atPath: Homes.url($0).path) }, "every home exists after ensure()",
          Home.allCases.filter { !fm.fileExists(atPath: Homes.url($0).path) }.map(\.folder))
    check(Home.music.folder == "library/Music" && Home.downloads.folder == "downloads" && Home.trash.folder == "trash",
          "the contract's paths (library/Music, downloads, trash)", [Home.music.folder, Home.downloads.folder, Home.trash.folder])

    // one definition of downloads/: the folder Downloads writes to is the Downloads home
    if ProcessInfo.processInfo.environment["RECENSE_DOWNLOADS"] == nil {
        check(Downloads.root.standardizedFileURL.path == Homes.url(.downloads).standardizedFileURL.path,
              "downloads/ has one definition", Downloads.root.path)
    }

    // where a file goes when the owner doesn't choose
    check(Homes.home(for: "nocturne.m4a") == .music, "audio goes to Music", Homes.home(for: "nocturne.m4a"))
    check(Homes.home(for: "book.m4b") == .audiobooks, "an audiobook goes to Audiobooks", Homes.home(for: "book.m4b"))
    check(Homes.home(for: "ch2100.pdf") == .study && Homes.home(for: "notes.md") == .study, "documents go to Study")
    check(Homes.home(for: "clip.mp4") == .downloads, "anything else goes to Downloads", Homes.home(for: "clip.mp4"))

    // taking a file in: moved, hashed as it landed, one entry, and a second of the same name never overwrites
    var first: HomeEntry?
    do {
        first = try Homes.add(drop("nocturne.m4a", "one"))
        let second = try Homes.add(drop("nocturne.m4a", "two"))
        check(first?.path == "nocturne.m4a" && second.path == "nocturne 2.m4a", "a same-named file is kept beside, never over", second.path)
        check(Homes.index(.music).count == 2, "one manifest entry each", Homes.index(.music).count)
        check(first?.sha256 != second.sha256 && first?.sha256.count == 64, "the sha256 is of the bytes that landed")
        check(first.map { Homes.intact($0, in: .music) } == true, "the recorded bytes are the bytes on disk")
        check(!fm.fileExists(atPath: scratch.appendingPathComponent("nocturne.m4a").path), "add() moves, it doesn't copy")
        check(first?.device == Homes.device && !(first?.device ?? "").isEmpty, "the entry names the device it landed on")
    } catch { check(false, "add() takes a file in", error) }

    // adopt: a file dropped straight into a home is recorded once; a part file never is
    do {
        try Data("dropped".utf8).write(to: Homes.url(.music).appendingPathComponent("waltz.m4a"))
        try Data("half".utf8).write(to: Homes.url(.music).appendingPathComponent("rest.m4a.part"))
        let added = try Homes.adopt(.music), again = try Homes.adopt(.music)
        check(added.map(\.path) == ["waltz.m4a"], "adopt() records a dropped file", added.map(\.path))
        check(again.isEmpty, "adopt() run twice adds nothing", again.map(\.path))
    } catch { check(false, "adopt()", error) }

    // remove: into Trash, never deleted, and it remembers where it came from
    do {
        guard let e = Homes.index(.music).first(where: { $0.path == "nocturne.m4a" }) else { throw Homes.Failure.missing("nocturne.m4a") }
        let t = try Homes.remove(e, from: .music)
        check(fm.fileExists(atPath: Homes.file(t, in: .trash).path), "Remove moves the file into Trash", t.path)
        check(!fm.fileExists(atPath: Homes.url(.music).appendingPathComponent("nocturne.m4a").path), "it is gone from Music")
        check(!Homes.index(.music).contains { $0.path == "nocturne.m4a" }, "Music's manifest no longer lists it")
        check(t.tags.contains("from:library/Music/nocturne.m4a"), "Trash records where it came from", t.tags)
        check(t.sha256 == e.sha256, "the bytes are unchanged by the move")

        // delete forever: only inside Trash
        do { try Homes.deleteForever(t, from: .music); check(false, "deleteForever outside Trash throws", "it didn't") }
        catch { check(true, "deleteForever outside Trash throws") }

        // restore: back where it came from
        let back = try Homes.restore(t)
        check(back.path == "nocturne.m4a" && fm.fileExists(atPath: Homes.file(back, in: .music).path), "restore puts it back in Music", back.path)
        check(!fm.fileExists(atPath: Homes.file(t, in: .trash).path), "and it is out of Trash")

        // and only then, on a named file, forever
        let again = try Homes.remove(back, from: .music)
        try Homes.deleteForever(again, from: .trash)
        check(!fm.fileExists(atPath: Homes.file(again, in: .trash).path) && !Homes.index(.trash).contains { $0.path == again.path },
              "Delete forever, inside Trash, removes the named file")
    } catch { check(false, "remove / restore / delete forever", error) }

    // carry C0: the manifest is every file in every home, and a move is verified, receipted and leaves the source
    do {
        let lines = try Carry.verify()
        let onDisk = Set(lines.map { "\($0.home)/\($0.path)" })
        check(onDisk.contains("library/Music/waltz.m4a") && onDisk.contains("library/Music/nocturne 2.m4a"),
              "carry verify lists every file in every home", onDisk.sorted())
        check(lines.allSatisfy { $0.sha256.count == 64 && $0.size > 0 }, "every carry line carries its sha256 and size")
        let body = (try? String(decoding: Data(contentsOf: Carry.manifestURL), as: UTF8.self)) ?? ""
        check(body.split(separator: "\n").count == lines.count, "manifest.jsonl is one line per file", body.split(separator: "\n").count)
        // FEAT-09 P4: an unchanged file keeps its hash; a changed one is read again
        check(try Carry.verify(reuse: true) == lines, "verify(reuse:) gives the same lines for unchanged files")
        let w = Homes.root.appendingPathComponent("library/Music/waltz.m4a")
        let keep = try Data(contentsOf: w)
        try Data("changed".utf8).write(to: w)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: w.path)
        let changed = try Carry.verify(reuse: true).first { $0.path == "waltz.m4a" }
        check(changed?.sha256 == (try Homes.sha256(w)) && changed?.sha256 != lines.first { $0.path == "waltz.m4a" }?.sha256,
              "verify(reuse:) hashes a changed file again")
        try keep.write(to: w); _ = try Carry.verify()

        let r = try Carry.move(to: carried)
        check(r.mismatched.isEmpty && r.files == lines.count, "carry move copies and verifies every file", r.mismatched)
        check(fm.fileExists(atPath: carried.appendingPathComponent("library/Music/waltz.m4a").path), "the copy is laid out the same")
        check(fm.fileExists(atPath: Homes.url(.music).appendingPathComponent("waltz.m4a").path), "the source stays until the owner says otherwise")
        let receipts = ((try? fm.contentsOfDirectory(atPath: carried.path)) ?? []).filter { $0.hasPrefix("carry-receipt-") }
        check(receipts.count == 1, "it writes one receipt", receipts)
    } catch { check(false, "carry C0", error) }

    return ok
}
