// Derived from Spec: FEAT-39 (P2 the iPad view). The reading side of Live edits: the manifest the Mac's watcher writes
// (sync/src/livestate.mjs, the home of what is listed and what is skipped), the order rows come in, the age label, the pair
// link, the hub address and the offline copy. Foundation only; the screen and the network call are mobile/HostApp/iOS/LiveEdits.swift.
import Foundation

/// Where a Live edits list came from (the spec's `live.view.refreshed` source). Only `hub` and `cache` are built so far.
public enum LiveSource: String, CaseIterable { case lan, hub, r2, cache }

public struct LiveFile: Codable, Equatable {
    public var path: String
    public var status: String        // M modified, A added, D deleted, ? untracked
    public var mtime: String?        // ISO UTC; null for a deleted file
    public var added: Int
    public var deleted: Int
    public var binary: Bool
    public var state: String         // BUILT | UNBUILT | UNKNOWN

    public init(path: String, status: String, mtime: String? = nil, added: Int = 0, deleted: Int = 0, binary: Bool = false, state: String = "UNKNOWN") {
        self.path = path; self.status = status; self.mtime = mtime; self.added = added; self.deleted = deleted; self.binary = binary; self.state = state
    }

    /// Tolerant on purpose: a key a newer Mac adds is ignored, a key an older Mac lacks gets its quiet default.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "M"
        mtime = try c.decodeIfPresent(String.self, forKey: .mtime)
        added = try c.decodeIfPresent(Int.self, forKey: .added) ?? 0
        deleted = try c.decodeIfPresent(Int.self, forKey: .deleted) ?? 0
        binary = try c.decodeIfPresent(Bool.self, forKey: .binary) ?? false
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "UNKNOWN"
    }

    public var edited: Date? { mtime.flatMap(LiveFile.parse) }

    public static func parse(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter(); withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}

public struct LiveWorktree: Codable, Equatable {
    public var name: String
    public var branch: String
    public var head: String
    public var files: [LiveFile]

    public init(name: String, branch: String, head: String, files: [LiveFile]) { self.name = name; self.branch = branch; self.head = head; self.files = files }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        head = try c.decodeIfPresent(String.self, forKey: .head) ?? ""
        files = try c.decodeIfPresent([LiveFile].self, forKey: .files) ?? []
    }

    public var newestEdit: Date? { files.compactMap(\.edited).max() }
}

public struct LiveManifest: Codable, Equatable {
    public var generated: String?
    public var worktrees: [LiveWorktree]

    public init(generated: String?, worktrees: [LiveWorktree]) { self.generated = generated; self.worktrees = worktrees }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        generated = try c.decodeIfPresent(String.self, forKey: .generated)
        worktrees = try c.decodeIfPresent([LiveWorktree].self, forKey: .worktrees) ?? []
    }

    /// "as of" on the screen: when the Mac last wrote this list.
    public var generatedDate: Date? { generated.flatMap(LiveFile.parse) }

    /// Newest edit first, in both levels; a file with no time (deleted) goes last; equal times keep a stable order by name.
    public var sorted: LiveManifest {
        func before(_ a: Date?, _ b: Date?, _ na: String, _ nb: String) -> Bool {
            switch (a, b) {
            case let (x?, y?): return x != y ? x > y : na < nb
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return na < nb
            }
        }
        var out = self
        out.worktrees = worktrees.map { w in
            var w = w; w.files = w.files.sorted { before($0.edited, $1.edited, $0.path, $1.path) }; return w
        }.sorted { before($0.newestEdit, $1.newestEdit, $0.name, $1.name) }
        return out
    }
}

/// How long ago, in the spec's steps: under 60 s "just now", then minutes, hours, days. The same boundaries as `ageLabel` in
/// sync/src/livestate.mjs (which words the Mac's note); the screen words it in the person's language.
public enum LiveAge: Equatable {
    case justNow, minutes(Int), hours(Int), days(Int)

    public static func of(_ seconds: TimeInterval) -> LiveAge {
        guard seconds >= 60 else { return .justNow }      // also a negative age (a clock a little ahead) and NaN
        let m = Int(seconds / 60); if m < 60 { return .minutes(m) }
        let h = Int(seconds / 3600); if h < 24 { return .hours(h) }
        return .days(Int(seconds / 86400))
    }
}

public enum LiveReach: Equatable { case unreachable, untrusted, cancelled }

public enum LiveHub {
    public static let defaultAddress = "https://recense.local"

    /// The hub's address as typed: `recense.local`, `https://mac.recense.local:8443/`, an IP. https only, so the token never
    /// travels in the clear; no path, query or login in it.
    public static func baseURL(from text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace) else { return nil }
        guard var c = URLComponents(string: t.contains("://") ? t : "https://" + t), c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/"
        else { return nil }
        c.scheme = "https"; c.host = host; c.path = ""
        return c.url
    }

    public static func endpoint(base: URL, _ path: String) -> URL { URL(string: base.absoluteString + path) ?? base }

    /// The token from a pair link (`recense-hub pair` prints `https://recense.local/#pair=<token>`), from `pair=<token>`, or the
    /// bare token. Same alphabet and length (16 to 128) as `tokenFromHash` in editor/src/hubsync.js; text that is none of these is refused.
    public static func pairToken(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func match(_ pattern: String, in s: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
            return String(s[r])
        }
        if let bare = match(#"^([A-Za-z0-9_-]{16,128})$"#, in: t) { return bare }
        let fragment = t.firstIndex(of: "#").map { String(t[t.index(after: $0)...]) } ?? t
        return match(#"(?:^|&)pair=([A-Za-z0-9_-]{16,128})(?:&|$)"#, in: fragment)
    }

    /// Why a call failed, told apart because the person does something different about each: a Mac that is out of reach waits;
    /// a device that does not trust the Mac's certificate needs the hub's profile installed (FEAT-18).
    public static func reach(for error: Error) -> LiveReach {
        switch (error as? URLError)?.code {
        case .cancelled?: return .cancelled
        case .serverCertificateUntrusted?, .serverCertificateHasUnknownRoot?, .serverCertificateHasBadDate?, .serverCertificateNotYetValid?, .secureConnectionFailed?:
            return .untrusted
        default: return .unreachable
        }
    }

    /// GET with no body, POST with a JSON body. A Mac that is not there gives up in 8 s (the list shows the last copy meanwhile);
    /// a snapshot is allowed 130 s because the hub allows its helper 120.
    public static func request(base: URL, path: String, token: String, body: [String: String]?) -> URLRequest {
        var r = URLRequest(url: endpoint(base: base, path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: body == nil ? 8 : 130)
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        } else { r.httpMethod = "GET" }
        return r
    }
}

/// What the hub answered to "Make review snapshot".
public enum LiveSnapshotReply: Equatable {
    case made(files: Int, state: String, zip: Bool)
    case refused(reason: String, path: String?)   // clean, secret, size
    case unauthorized                              // the token is wrong: pair again
    case gone                                      // that worktree has no listed changes any more
    case failed(String)

    public static func decode(status: Int, data: Data) -> LiveSnapshotReply {
        if status == 401 { return .unauthorized }
        if status == 404 { return .gone }
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failed("unreadable answer") }
        switch o["status"] as? String {
        case "made": return .made(files: o["files"] as? Int ?? 0, state: o["state"] as? String ?? "UNBUILT", zip: o["zip"] as? Bool ?? false)
        case "refused": return .refused(reason: o["reason"] as? String ?? "unknown", path: o["path"] as? String)
        default:
            if let e = o["error"] as? String { return .failed(e) }
            return .failed("unreadable answer")
        }
    }
}

/// The last copy of the list, so the screen opens with the Mac out of reach.
public enum LiveCache {
    public static func load(from url: URL) -> LiveManifest? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LiveManifest.self, from: d)
    }

    /// Only a readable manifest becomes the last copy; a damaged answer never replaces a good one.
    @discardableResult public static func save(_ data: Data, to url: URL) -> Bool {
        guard (try? JSONDecoder().decode(LiveManifest.self, from: data)) != nil else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }
}
