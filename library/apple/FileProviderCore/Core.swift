// FileProviderCore: what the File Provider extension and the host app share, on macOS and iOS
// (docs/architecture.md §6). The Worker's read-only feed (src/fp.js), the item ids, and the local item store.
import Foundation
import CryptoKit

public enum Gallery {
    // macOS: a team-prefixed App Group, no profile needed. iOS: a free team gets App Groups with no group in them,
    // so the app and the extension share only a Keychain group (the profile grants 48RZ72DNP3.*)
    public static let appGroup = "48RZ72DNP3.gallery"
    public static let keychainGroup = "48RZ72DNP3.com.chauphan.galleryfiles"
    public static let base = URL(string: "https://gallery.improvdiplomat.workers.dev/main/api/fp/archive/")!
    // the domain shows this folder of the archive bucket as its root
    public static let rootPath = "chauphan"

    // where the extension keeps its item store (macOS: shared with the host app; iOS: the extension's own)
    public static var container: URL {
        #if os(macOS)
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)!
        #else
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
        #endif
    }
    // this device's Access service token, put here by the host app (the extension can't read the login keychain)
    public static var tokenFile: URL { container.appendingPathComponent("token.json") }
}

// the same ids as src/fp.js: a folder's is "d" + 24 hex of sha-256(path + "/")
public func folderId(_ path: String) -> String {
    let d = SHA256.hash(data: Data((path + "/").utf8)).map { String(format: "%02x", $0) }.joined()
    return "d" + d.prefix(24)
}

public func parentPath(_ path: String) -> String {
    guard let i = path.lastIndex(of: "/") else { return "" }
    return String(path[..<i])
}

public struct Record: Codable, Equatable {
    public var id: String
    public var path: String
    public var dir: Bool
    public var size: Int64?
    public var etag: String?
    public var mtime: Int?
    public var name: String { String(path.split(separator: "/").last ?? "") }
    // nil: the domain's root; else the parent folder's id, or "root" when the parent is the root
    public var parent: String { parentPath(path) == Gallery.rootPath ? "root" : folderId(parentPath(path)) }
}

public struct Event: Codable {
    public var op: String
    public var id: String
    public var path: String
    public var dir: Bool
    public var size: Int64?
    public var etag: String?
    public var mtime: Int?

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        op = try c.decode(String.self, forKey: .op); id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path); dir = try c.decode(Bool.self, forKey: .dir)
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        size = (try? c.decodeIfPresent(Double.self, forKey: .size)).flatMap { $0.map { Int64($0) } }
        mtime = (try? c.decodeIfPresent(Double.self, forKey: .mtime)).flatMap { $0.map { Int($0) } }
    }
    public var record: Record { Record(id: id, path: path, dir: dir, size: size, etag: etag, mtime: mtime) }
}

public enum FeedError: Error {
    case offline, notSignedIn, expired, notFound, server(Int)
}

public final class Feed {
    let session: URLSession
    let token: (id: String, secret: String)?

    public init() {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
        if let d = Token.read(),
           let t = try? JSONDecoder().decode([String: String].self, from: d),
           let id = t["id"], let secret = t["secret"] {
            token = (id, secret)
        } else {
            token = nil
        }
    }

    func request(_ endpoint: String, _ query: [String: String]) throws -> URLRequest {
        guard let token else { throw FeedError.notSignedIn }
        var u = URLComponents(url: Gallery.base.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        u.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var r = URLRequest(url: u.url!)
        r.setValue(token.id, forHTTPHeaderField: "CF-Access-Client-Id")
        r.setValue(token.secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        return r
    }

    // Access answers a missing or revoked token with a redirect to its sign-in page
    func check(_ response: URLResponse?, _ error: Error?) throws {
        if let e = error as? URLError {
            throw [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost].contains(e.code) ? FeedError.offline : FeedError.server(-1)
        }
        if error != nil { throw FeedError.offline }
        guard let h = response as? HTTPURLResponse else { throw FeedError.server(-1) }
        if h.url?.host != Gallery.base.host || h.statusCode == 401 || h.statusCode == 403 { throw FeedError.notSignedIn }
        if h.statusCode == 410 { throw FeedError.expired }
        if h.statusCode == 404 { throw FeedError.notFound }
        if !(200...299).contains(h.statusCode) { throw FeedError.server(h.statusCode) }
    }

    func json<T: Decodable>(_ endpoint: String, _ query: [String: String], _ type: T.Type, _ done: @escaping (Result<T, Error>) -> Void) {
        let r: URLRequest
        do { r = try request(endpoint, query) } catch { return done(.failure(error)) }
        session.dataTask(with: r) { data, response, error in
            do {
                try self.check(response, error)
                done(.success(try JSONDecoder().decode(T.self, from: data ?? Data())))
            } catch { done(.failure(error)) }
        }.resume()
    }

    public struct Page: Decodable {
        public struct Item: Decodable {
            let id: String; let name: String; let dir: Bool; let size: Int64?; let etag: String?; let mtime: Int?
            // a fractional mtime (rclone's) must not fail a whole folder
            public init(from d: Decoder) throws {
                let c = try d.container(keyedBy: K.self)
                id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
                dir = try c.decode(Bool.self, forKey: .dir); etag = try c.decodeIfPresent(String.self, forKey: .etag)
                size = (try? c.decodeIfPresent(Double.self, forKey: .size)).flatMap { $0.map { Int64($0) } }
                mtime = (try? c.decodeIfPresent(Double.self, forKey: .mtime)).flatMap { $0.map { Int($0) } }
            }
            enum K: String, CodingKey { case id, name, dir, size, etag, mtime }
        }
        let items: [Item]
        public let cursor: String?
    }

    // one page of a folder's children
    public func items(_ path: String, cursor: String?, _ done: @escaping (Result<([Record], String?), Error>) -> Void) {
        var q = ["path": path]
        if let cursor { q["cursor"] = cursor }
        json("items", q, Page.self) { r in
            done(r.map { p in
                (p.items.map { Record(id: $0.id, path: path + "/" + $0.name, dir: $0.dir, size: $0.size, etag: $0.etag, mtime: $0.mtime) }, p.cursor)
            })
        }
    }

    public struct Changes: Decodable { public let seq: Int; public let events: [Event]; public let more: Bool }

    public func changes(since: Int?, _ done: @escaping (Result<Changes, Error>) -> Void) {
        json("changes", since.map { ["since": String($0)] } ?? [:], Changes.self, done)
    }

    // the file's bytes, downloaded to a temporary file
    public func content(_ path: String, _ done: @escaping (Result<URL, Error>) -> Void) -> Progress {
        let r: URLRequest
        do { r = try request("content", ["path": path]) } catch { done(.failure(error)); return Progress() }
        let task = session.downloadTask(with: r) { url, response, error in
            do {
                try self.check(response, error)
                guard let url else { throw FeedError.server(-1) }
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.moveItem(at: url, to: kept)
                done(.success(kept))
            } catch { done(.failure(error)) }
        }
        task.resume()
        return task.progress
    }
}

// every item the extension has seen, by id, so item(for:) and fetchContents can find its path (kept in the App Group)
public final class Store {
    private var records: [String: Record] = [:]
    private let lock = NSLock()
    private let file = Gallery.container.appendingPathComponent("items.json")

    public init() {
        if let d = try? Data(contentsOf: file), let r = try? JSONDecoder().decode([String: Record].self, from: d) { records = r }
    }

    public subscript(id: String) -> Record? {
        lock.lock(); defer { lock.unlock() }
        return records[id]
    }

    public func put(_ rs: [Record]) {
        lock.lock()
        for r in rs { records[r.id] = r }
        let d = try? JSONEncoder().encode(records)
        lock.unlock()
        try? d?.write(to: file, options: .atomic)
    }

    public func remove(_ ids: [String]) {
        lock.lock()
        for id in ids { records[id] = nil }
        let d = try? JSONEncoder().encode(records)
        lock.unlock()
        try? d?.write(to: file, options: .atomic)
    }
}

// this device's Access service token. macOS: a file in the App Group (0600), put there by the host app.
// iOS: a Keychain item in the shared group, put there by the host app.
public enum Token {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "gallery-access",
                                       kSecAttrAccount as String: "token", kSecAttrAccessGroup as String: Gallery.keychainGroup]

    public static func read() -> Data? {
        #if os(macOS)
        return try? Data(contentsOf: Gallery.tokenFile)
        #else
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
        #endif
    }

    #if os(iOS)
    public static func write(_ d: Data) -> Bool {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = d
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    #endif
}
