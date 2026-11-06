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
    public static let rootPath = "archive"

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

public enum FeedError: Error, Equatable {
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

    // the owner's writes (Add Media, New Folder; src/fp.js): never over anything already there (409)
    public func put(_ path: String, file: URL, mtime: Date? = nil) async throws {
        var q = ["path": path]
        if let mtime { q["mtime"] = String(Int(mtime.timeIntervalSince1970)) }
        var r = try request("file", q)
        r.httpMethod = "PUT"
        r.timeoutInterval = 600
        r.setValue("1", forHTTPHeaderField: "x-gallery")
        let (_, response) = try await session.upload(for: r, fromFile: file)
        try check(response, nil)
    }

    public func folder(_ path: String) async throws {
        var r = try request("folder", ["path": path])
        r.httpMethod = "POST"
        r.setValue("1", forHTTPHeaderField: "x-gallery")
        let (_, response) = try await session.data(for: r)
        try check(response, nil)
    }

    // a file deleted in Finder or Files: the Worker moves it to the trash (src/fp.js); already gone is fine
    public func delete(_ path: String) async throws {
        var r = try request("item", ["path": path])
        r.httpMethod = "DELETE"
        r.setValue("1", forHTTPHeaderField: "x-gallery")
        let (_, response) = try await session.data(for: r)
        do { try check(response, nil) } catch FeedError.notFound {}
    }

    // the file's bytes, downloaded to a temporary file, keeping its name (for Download and AirDrop)
    public func download(_ path: String) async throws -> URL {
        let tmp: URL = try await withCheckedThrowingContinuation { k in _ = content(path) { k.resume(with: $0) } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let named = dir.appendingPathComponent((path as NSString).lastPathComponent)
        try FileManager.default.moveItem(at: tmp, to: named)
        return named
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

// Gallery's share links, made the way the web makes them (POST /main/api/link?action=fromMain, then one copy per
// file), from the archive (from=archive). The link is https://<host>/s/<id>: the same page and player for whoever opens it.
public enum Share {
    struct Made: Decodable { let id: String; let count: Int; let url: String }

    static func call(_ query: String, _ body: Data?) async throws -> Data {
        guard let d = Token.read(), let t = try? JSONDecoder().decode([String: String].self, from: d),
              let id = t["id"], let secret = t["secret"] else { throw FeedError.notSignedIn }
        var r = URLRequest(url: URL(string: "https://\(Gallery.base.host!)/main/api/link?\(query)")!)
        r.httpMethod = "POST"
        r.httpBody = body
        r.timeoutInterval = 600  // one copy can be a big video
        r.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
        r.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        r.setValue("1", forHTTPHeaderField: "x-gallery")  // the Worker's same-site check for clients with no Origin
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        let (data, response) = try await URLSession.shared.data(for: r)
        guard let h = response as? HTTPURLResponse, h.url?.host == Gallery.base.host else { throw FeedError.notSignedIn }
        guard (200...299).contains(h.statusCode) else { throw FeedError.server(h.statusCode) }
        return data
    }

    // paths are inside archive/; progress(done, total) after each file is in the link
    public static func link(_ paths: [String], days: Int, progress: @escaping (Int, Int) -> Void) async throws -> URL {
        let body = try JSONEncoder().encode(["paths": paths])
        let made = try JSONDecoder().decode(Made.self, from: try await call("action=fromMain&from=archive&days=\(days)", body))
        progress(0, made.count)
        for i in 0..<made.count {
            _ = try await call("action=copy&id=\(made.id)&i=\(i)", nil)
            progress(i + 1, made.count)
        }
        return URL(string: "https://\(Gallery.base.host!)\(made.url)")!
    }
}
