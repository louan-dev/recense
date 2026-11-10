// The device's own SSH key and the servers' pinned host keys.
// Each device makes its own Ed25519 key once and never sends the private half anywhere; the owner adds the public line
// to the Mac's ~/.ssh/authorized_keys. A server's host key is pinned the first time and must match every time after.
import Crypto
import Foundation
import NIOSSH
#if canImport(Security)
import Security
#endif

/// Where the 32 private-key bytes live.
public protocol KeyStore {
    func load() -> Data?
    func save(_ data: Data) throws
}

public final class MemoryKeyStore: KeyStore {
    private var data: Data?
    public init(_ data: Data? = nil) { self.data = data }
    public func load() -> Data? { data }
    public func save(_ data: Data) throws { self.data = data }
}

public struct FileKeyStore: KeyStore {
    public let url: URL
    public init(_ url: URL) { self.url = url }
    public func load() -> Data? { try? Data(contentsOf: url) }
    public func save(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

#if canImport(Security)
/// The Keychain, this device only: the key never leaves it, not even in an encrypted backup.
public struct KeychainKeyStore: KeyStore {
    public let service: String, account: String
    public init(service: String = "local.recense.ssh", account: String = "device-ed25519") {
        self.service = service; self.account = account
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func load() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    public func save(_ data: Data) throws {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw SSHError.keyStore(Int(status)) }
    }
}
#endif

public struct DeviceKey {
    let raw: Curve25519.Signing.PrivateKey
    public let comment: String

    /// The key in `store`, made and saved there the first time.
    public static func loadOrCreate(store: KeyStore, comment: String) throws -> DeviceKey {
        if let d = store.load() { return DeviceKey(raw: try Curve25519.Signing.PrivateKey(rawRepresentation: d), comment: comment) }
        let k = Curve25519.Signing.PrivateKey()
        try store.save(k.rawRepresentation)
        return DeviceKey(raw: k, comment: comment)
    }

    var nio: NIOSSHPrivateKey { NIOSSHPrivateKey(ed25519Key: raw) }

    /// The line the owner adds to ~/.ssh/authorized_keys on the Mac.
    public var publicLine: String { "\(String(openSSHPublicKey: nio.publicKey)) \(comment)" }
}

/// Host keys seen before, by "host:port". Trust on first use; a changed key is refused, never silently replaced.
public protocol PinStore: AnyObject {
    func pin(for server: String) -> String?
    func setPin(_ key: String, for server: String)
}

public final class MemoryPinStore: PinStore {
    private var pins: [String: String]
    public init(_ pins: [String: String] = [:]) { self.pins = pins }
    public func pin(for server: String) -> String? { pins[server] }
    public func setPin(_ key: String, for server: String) { pins[server] = key }
}

/// Plain JSON beside hosts.json, so it is readable and travels with the Recense folder.
public final class FilePinStore: PinStore {
    public let url: URL
    private let lock = NSLock()
    public init(_ url: URL) { self.url = url }
    private func read() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }
    public func pin(for server: String) -> String? { lock.lock(); defer { lock.unlock() }; return read()[server] }
    public func setPin(_ key: String, for server: String) {
        lock.lock(); defer { lock.unlock() }
        var p = read(); p[server] = key
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(p).write(to: url, options: .atomic)
    }
}
