// What the broadcast extension (ios/Broadcast) heard, handed to the app: the latest line goes into the shared Keychain
// group (the only container a free Personal Team signs for both) and a Darwin notification says "read it".
// The app sets which language to hear the same way. Compiled into the app and the extension.
import Foundation
import Security

enum Captions {
    static let group = "48RZ72DNP3.com.chauphan.galleryfiles"
    static let changed = "com.chauphan.galleryfiles.caption" as CFString
    static let stateChanged = "com.chauphan.galleryfiles.broadcast" as CFString

    struct Line: Codable, Equatable {
        var n: Int          // which utterance; a new n starts a new line
        var text: String
        var final: Bool
        var locale: String  // what was heard, e.g. "fr-FR"
    }

    // on: the broadcast is running, while beat (written every 2 s by the extension) is fresh: an extension iOS ended
    // without broadcastFinished leaves on = true behind. stop: the app asks the extension to end the broadcast.
    // heard: the language it listens for (set by the app)
    struct State: Codable {
        var on = false; var beat: Date?; var stop = false; var heard = Locale.current.identifier; var error: String?
        var live: Bool { on && (beat.map { Date().timeIntervalSince($0) < 6 } ?? false) }
    }

    static func put(_ line: Line) { write("line", line); post(changed) }
    static func line() -> Line? { read("line") }
    static func put(_ s: State) { write("state", s); post(stateChanged) }
    static func state() -> State { read("state") ?? State() }

    static func observe(_ name: CFString, _ f: @escaping () -> Void) {
        handlers[name as String] = f
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, name, _, _ in
            guard let n = name?.rawValue as String? else { return }
            DispatchQueue.main.async { Captions.handlers[n]?() }
        }, name, nil, .deliverImmediately)
    }
    nonisolated(unsafe) private static var handlers: [String: () -> Void] = [:]

    private static func post(_ name: CFString) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name), nil, nil, true)
    }

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "gallery-captions",
         kSecAttrAccount as String: key, kSecAttrAccessGroup as String: group]
    }
    private static func write<T: Encodable>(_ key: String, _ v: T) {
        guard let d = try? JSONEncoder().encode(v) else { return }
        if SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: d] as CFDictionary) == errSecItemNotFound {
            var q = query(key)
            q[kSecValueData as String] = d
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(q as CFDictionary, nil)
        }
    }
    private static func read<T: Decodable>(_ key: String) -> T? {
        var q = query(key)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}
