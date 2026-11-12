// What the broadcast extension (ios/Broadcast) heard, handed to the app: the latest line goes into the shared Keychain
// group (the only container a free Personal Team signs for both) and a Darwin notification says "read it".
// The app sets which language to hear the same way. Compiled into the app and the extension.
import Foundation
import Security

enum Captions {
    /// State.heard for "follow whichever language is spoken" (S6).
    static let automatic = "auto"
    /// The shared Keychain group, read from how this build was signed (its first keychain-access-groups entry, the
    /// one iOS files an item under when none is named), so a build signed by another Apple ID (the guest, re-signed
    /// in Sideloadly) still reaches its own extension. Recense: "48RZ72DNP3.com.chauphan.galleryfiles", as before.
    static let group: String = {
        let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "recense.group",
                                    kSecAttrAccount as String: "probe"]
        var q = probe; q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        var st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound {
            var add = probe; add[kSecValueData as String] = Data(); add[kSecReturnAttributes as String] = true
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            st = SecItemAdd(add as CFDictionary, &out)
        }
        if st == errSecSuccess, let a = out as? [String: Any], let g = a[kSecAttrAccessGroup as String] as? String { return g }
        return "48RZ72DNP3.com.chauphan.galleryfiles"
    }()
    /// The group without its team prefix: the Darwin notifications' names ("com.chauphan.galleryfiles.caption").
    static var base: String { String(group.split(separator: ".", maxSplits: 1).last ?? "") }
    static let changed = (base + ".caption") as CFString
    static let stateChanged = (base + ".broadcast") as CFString

    struct Line: Codable, Equatable {
        var n: Int          // which utterance; a new n starts a new line
        var text: String
        var final: Bool
        var locale: String  // what was heard, e.g. "fr-FR"
        // SpeechAnalyzer's ears (shared/speechcore.swift): every word timed, in seconds from t0 (seconds since 1970
        // when the extension's stream began). nil from SFSpeechRecognizer, whose live words have no times.
        var words: [SpeechCore.W]? = nil
        var t0: Double? = nil
        var b: Double? = nil  // which broadcast (when it started, s since 1970): n starts again at each one
    }

    // on: the broadcast is running, while beat (written every 2 s by the extension) is fresh: an extension iOS ended
    // without broadcastFinished leaves on = true behind. stop: the app asks the extension to end the broadcast.
    // heard: the language it listens for (set by the app)
    struct State: Codable {
        var on = false; var beat: Date?; var stop = false; var heard = Locale.current.identifier; var error: String?
        // hold: Listen's Pause. The broadcast stays on and its ears rest, so iOS shows no "stopped" alert and Resume
        // needs no broadcast sheet (owner's iPad video 11-10). Optional: a state written before it decodes as nil.
        var hold: Bool? = nil
        // engine: which ears the extension hears with ("SpeechAnalyzer", "SFSpeechRecognizer"; "SpeechAnalyzer…" while a
        // broadcast with it runs, so one that iOS ended without a word, over the extension's 50 MB, is told apart).
        // analyzerFailed: when that happened; the extension then hears with SFSpeechRecognizer for a day.
        var engine: String? = nil; var analyzerFailed: Date? = nil
        var b: Double? = nil  // the running (or last) broadcast, as in Line.b
        // heard == "auto" (S6): the ears follow whichever of SpeechCore.auto is spoken; detected is the last one heard
        // ("en", "fr", "vi"), where the next hearing starts
        var detected: String? = nil
        var check: String? = nil  // the last language check (SpeechAuto.onNote), kept by the app in listen.checks
        var sooner: Bool? = nil  // "Show Words Sooner": fast: true on SpeechAuto (guesses in <1 s, finals slightly less accurate)
        var sound: Date? = nil  // last real sound the broadcast heard (T-0041: the floating window rests on a pause)
        var auto: Bool { heard == Captions.automatic }
        /// The language a hearing starts in: the chosen one, or under Automatic the last one heard.
        var start: String { auto ? (detected ?? "en") : heard }
        var live: Bool { on && (beat.map { Date().timeIntervalSince($0) < 6 } ?? false) }
    }

    static func put(_ line: Line) {
        write("line", line)
        // the ring keeps finished lines, and a growing one at most every 5 s (each write rewrites the whole ring)
        if line.final || Date().timeIntervalSince(ringAt[line.ringKey] ?? .distantPast) >= 5 {
            if ringAt.count > 400 { ringAt = [:] }  // 24/7: forget old lines' times
            ringAt[line.ringKey] = Date()
            var r = ring()
            r.add(Line(n: line.n, text: line.text, final: line.final, locale: line.locale, b: line.b))  // text only: small
            write("ring", r)
        }
        post(changed)
    }
    static func line() -> Line? { read("line") }
    static func ring() -> CaptionRing<Line> { read("ring") ?? CaptionRing() }
    nonisolated(unsafe) private static var ringAt: [String: Date] = [:]
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

extension Captions.Line: RingLine {
    var ringKey: String { "\(Int(b ?? 0)).\(n)" }
    var ringStamp: UInt64 { ringHash(text) }
    var ringSize: Int { text.utf8.count + locale.utf8.count + 64 }
}
