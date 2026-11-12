// Derived from Spec: FEAT-04
// One place per device for a screenshot or something removed from inside Recense, so both land in
// the same `Recense/<kind>/` folder on Mac, iPhone and iPad — the "places" folder contract, same
// manifest.json + sha256 shape `shared/mediadownload.swift` already uses for `Recense/downloads/`
// (that file stays the `downloads` destination; this one adds `screenshots` and `trash` alongside it,
// reusing the shape, not the code, since Downloads carries media-download-specific baggage this
// doesn't need). See docs/specs/FEAT-04-global-destination.md.
import Foundation
import CryptoKit

enum DestinationKind: String, Codable, CaseIterable, Sendable {
    case screenshots, trash
}

struct DestinationEntry: Codable, Equatable, Sendable {
    var name: String     // the file's name inside its kind's folder
    var source: String   // where it came from ("" when swept with no known source)
    var bytes: Int64
    var sha256: String
    var saved: String     // ISO 8601
    var via: String       // "swept", "trash", or "adopted"
}

enum Destinations {
    /// Recense/<kind>/. RECENSE_<KIND>_DIR (e.g. RECENSE_SCREENSHOTS_DIR) points it elsewhere for tests.
    static func root(_ kind: DestinationKind) -> URL {
        let envKey = "RECENSE_\(kind.rawValue.uppercased())_DIR"
        if let p = ProcessInfo.processInfo.environment[envKey] { return URL(fileURLWithPath: p, isDirectory: true) }
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Recense/\(kind.rawValue)", isDirectory: true)
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recense/\(kind.rawValue)", isDirectory: true)
        #endif
    }
    static func manifestURL(_ kind: DestinationKind) -> URL { root(kind).appendingPathComponent("manifest.json") }

    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    static func manifest(_ kind: DestinationKind) -> [DestinationEntry] {
        guard let d = try? Data(contentsOf: manifestURL(kind)) else { return [] }
        return (try? JSONDecoder().decode([DestinationEntry].self, from: d)) ?? []
    }

    static func write(_ kind: DestinationKind, _ entries: [DestinationEntry]) throws {
        try FileManager.default.createDirectory(at: root(kind), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(entries.sorted { $0.saved > $1.saved }).write(to: manifestURL(kind), options: .atomic)
    }

    /// Adds (or replaces, by name) one entry.
    static func record(_ kind: DestinationKind, _ entry: DestinationEntry) throws {
        var all = manifest(kind).filter { $0.name != entry.name }
        all.append(entry)
        try write(kind, all)
    }

    static func sha256(_ url: URL) throws -> String {
        guard let h = FileHandle(forReadingAtPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A name not yet taken in this kind's folder: "name 2.ext", as Safari and Finder do.
    static func freeName(_ kind: DestinationKind, _ name: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root(kind).appendingPathComponent(name).path) else { return name }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: root(kind).appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")).path) { n += 1 }
        return "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// Files in this kind's folder the manifest doesn't know (dropped there outside Recense):
    /// recorded as "adopted". Returns what was added. D2: never deletes; only records what is already there.
    @discardableResult
    static func adopt(_ kind: DestinationKind) throws -> [DestinationEntry] {
        let fm = FileManager.default
        try fm.createDirectory(at: root(kind), withIntermediateDirectories: true)
        let known = Set(manifest(kind).map(\.name))
        let found = (try? fm.contentsOfDirectory(at: root(kind), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var added: [DestinationEntry] = []
        for f in found where !known.contains(f.lastPathComponent) {
            let bytes = (try? fm.attributesOfItem(atPath: f.path)[.size] as? NSNumber)?.int64Value ?? 0
            let e = DestinationEntry(name: f.lastPathComponent, source: "", bytes: bytes,
                                     sha256: try sha256(f), saved: now(), via: "adopted")
            try record(kind, e); added.append(e)
        }
        return added
    }

    /// Moves `file` into Recense/trash/ instead of destroying it (D2). Returns the trashed copy's entry.
    /// Regression guard: an item removed from inside Recense is recoverable, never gone outright.
    @discardableResult
    static func trash(_ file: URL, source: String) throws -> DestinationEntry {
        let fm = FileManager.default
        try fm.createDirectory(at: root(.trash), withIntermediateDirectories: true)
        let name = freeName(.trash, file.lastPathComponent)
        let dest = root(.trash).appendingPathComponent(name)
        let bytes = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        let digest = try sha256(file)
        try fm.moveItem(at: file, to: dest)
        let e = DestinationEntry(name: name, source: source, bytes: bytes, sha256: digest, saved: now(), via: "trash")
        try record(.trash, e)
        return e
    }
}
