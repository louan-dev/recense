// Derived from Spec: FEAT-09 (the glue: starts the link, runs pairing, pushes new files to paired devices)
// Ties the link (P2PTransport, FEAT-02) and pairing (carrypair.swift) into one thing a screen can drive: see
// nearby devices, pair one, press "Carry now". One copy, used by the Mac menu (strip/app.swift) and the iOS
// Devices screen (mobile/HostApp/iOS/Devices.swift) — no second orchestrator.
//
// Scope of this slice, said plainly: "Carry now" pushes every file that is new or changed since the last carry,
// to every paired device currently connected. It does NOT yet replay a move, a trash or a restore from one
// device onto another, and it does not yet run carrysync.swift's P2/P3 settling (append-only ops log, conflict
// merge, keep-both siblings) — that is the rest of FEAT-09 P4, still open, and this file does not pretend
// otherwise. What it does do — a file dropped into a home reaches every paired, reachable device — is exactly
// the gap FEAT-06 P4 named and the owner hit.
//
// Known simplification: files move over the link's own resource transfer (`P2PTransport.send(fileAt:)`), not
// through `shared/pieces`'s resumable chunks. A dropped link restarts that file's send from the top rather than
// resuming — fine for the sizes Homes carries today.
// Known gap: if two devices are each already in a *different* group, pairing refuses rather than merging them
// (no wire message yet compares group fingerprints before the secret is sent). Cannot happen on a first pairing.
import Foundation
import CryptoKit
import MultipeerConnectivity

/// The Keychain, this device only. The identity key never leaves it; the one group secret every paired device of
/// this owner's shares is stored only here too, never in a plain file.
private enum CarryKeychain {
    static let service = "local.recense.carry"
    static func load(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                 kSecAttrAccount as String: account, kSecReturnData as String: true,
                                 kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    @discardableResult
    static func save(_ data: Data, _ account: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

@MainActor final class CarryManager: NSObject, ObservableObject {
    static let shared = CarryManager()

    @Published private(set) var peers: [CarryPeer] = []
    @Published private(set) var nearby: [MCPeerID] = []   // seen while browsing, not yet necessarily paired
    @Published var pairingCode: String?                    // non-nil once both nonces are in: show, ask "They match"
    @Published var pairingWith: String?                     // their display name, while `pairingCode` is shown
    @Published var isLookingToPair = false                  // "Pair a device" tapped: accept the next stranger
    @Published var lastCarryAt: Date?
    @Published var status = "Off"
    @Published var lastError: String?

    private let t = P2PTransport.shared
    private var identity: Curve25519.KeyAgreement.PrivateKey
    private var group: Data?
    private var pairSessions: [MCPeerID: CarryPairSession] = [:]
    private var lastSent: [CarryFile] = []   // this device's own scan as of the last "Carry now"

    private var dir: URL { Carry.dir }
    private var peersURL: URL { dir.appendingPathComponent("peers.json") }
    private var lastSentURL: URL { dir.appendingPathComponent("last-sent.json") }

    override init() {
        if let d = CarryKeychain.load("identity"), let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d) {
            identity = k
        } else {
            let k = Curve25519.KeyAgreement.PrivateKey()
            CarryKeychain.save(k.rawRepresentation, "identity")
            identity = k
        }
        group = CarryKeychain.load("group")
        super.init()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        peers = (try? Data(contentsOf: peersURL)).flatMap { try? JSONDecoder().decode([CarryPeer].self, from: $0) } ?? []
        lastSent = (try? Data(contentsOf: lastSentURL)).flatMap { try? JSONDecoder().decode([CarryFile].self, from: $0) } ?? []
        wire()
    }

    private func wire() {
        t.isPaired = { [weak self] peer in self?.peers.contains { $0.name == peer.displayName } ?? false }
        t.confirmUnpaired = { [weak self] _, reply in reply(self?.isLookingToPair ?? false) }
        t.onPeerFound = { [weak self] peer in
            guard let self, !self.nearby.contains(peer) else { return }
            self.nearby.append(peer)
        }
        t.onPeerLost = { [weak self] peer in self?.nearby.removeAll { $0 == peer } }
        t.onStateChange = { [weak self] peer, state in self?.connected(peer, state) }
        t.onMessage = { [weak self] type, data, peer in if type == "pair" { self?.receivePair(data, from: peer) } }
        t.onReceive = { [weak self] url, peer in self?.landed(url, from: peer) }
    }

    func start() { t.advertise(); t.browse(); status = "Looking for devices" }
    func stop() { t.stop(); isLookingToPair = false; status = "Off" }

    // MARK: Pairing — tap "Pair a device" on both screens within P2PTransport's own 10 s invite timeout

    /// "Pair a device": opens this device to the next stranger that connects (or that it finds and invites).
    func beginPairing() { isLookingToPair = true; start() }

    /// The owner picked a nearby, not-yet-paired device by name.
    func invite(_ peer: MCPeerID) { isLookingToPair = true; t.invite(peer) }

    private func connected(_ peer: MCPeerID, _ state: MCSessionState) {
        guard state == .connected else {
            if state == .notConnected { pairSessions[peer] = nil }
            return
        }
        guard !peers.contains(where: { $0.name == peer.displayName }) else { return }   // already paired: nothing to do
        guard isLookingToPair, pairSessions[peer] == nil else { return }
        let s = CarryPairSession(me: identity, name: P2PTransport.deviceName())
        pairSessions[peer] = s
        try? t.send(s.hello(), type: "pair", to: peer)
    }

    private func receivePair(_ data: Data, from peer: MCPeerID) {
        guard var s = pairSessions[peer], let m = try? JSONDecoder().decode(PairMessage.self, from: data) else { return }
        do {
            let reply = try s.receive(m)
            pairSessions[peer] = s
            if let reply { try t.send(reply, type: "pair", to: peer) }
            if let code = s.code(), pairingCode == nil { pairingCode = code; pairingWith = peer.displayName }
            if case .group = m { try finishPairing(peer, opening: m) }
        } catch { lastError = "pairing with \(peer.displayName) failed: \(error)" }
    }

    /// The owner tapped "They match" on this screen.
    func confirmMatch(for peerName: String) {
        guard let peer = pairSessions.keys.first(where: { $0.displayName == peerName }), let s = pairSessions[peer] else { return }
        do {
            guard let offer = try s.offerGroup(mine: group, theirsExists: false) else { return }   // waiting for theirs
            try t.send(offer.message, type: "pair", to: peer)
            try finish(peer, key: s.theirKey!, group: offer.secret)
        } catch { lastError = "could not finish pairing with \(peerName): \(error)" }
    }

    private func finishPairing(_ peer: MCPeerID, opening m: PairMessage) throws {
        guard let s = pairSessions[peer] else { return }
        if group != nil { lastError = "\(peer.displayName) already belongs to a different pairing; not merged"; return }
        try finish(peer, key: s.theirKey!, group: try s.openGroup(m))
    }

    private func finish(_ peer: MCPeerID, key: Data, group g: Data) throws {
        group = g
        CarryKeychain.save(g, "group")
        peers.append(CarryPeer(name: peer.displayName, key: key, paired: Homes.now()))
        try JSONEncoder().encode(peers).write(to: peersURL, options: .atomic)
        pairSessions[peer] = nil
        pairingCode = nil; pairingWith = nil; isLookingToPair = false
    }

    // MARK: Carry now — push every new or changed file to every paired, connected device

    func carryNow() {
        guard !peers.isEmpty else { lastError = "no paired device yet"; return }
        let targets = t.session.connectedPeers.filter { p in peers.contains { $0.name == p.displayName } }
        guard !targets.isEmpty else { lastError = "no paired device is connected right now"; return }
        do {
            let now = (try Carry.verify()).map { CarryFile(home: $0.home, path: $0.path, size: $0.size, sha256: $0.sha256) }
            let before = Dictionary(uniqueKeysWithValues: lastSent.map { ($0.key, $0.sha256) })
            let news = now.filter { before[$0.key] != $0.sha256 }
            for f in news {
                let url = Homes.root.appendingPathComponent(f.home).appendingPathComponent(f.path)
                let name = Self.encode(f.key)
                for peer in targets {
                    t.send(fileAt: url, named: name, to: peer) { [weak self] error in
                        if let error { self?.lastError = "sending \(f.path) to \(peer.displayName) failed: \(error)" }
                    }
                }
            }
            lastSent = now
            try JSONEncoder().encode(now).write(to: lastSentURL, options: .atomic)
            lastCarryAt = Date(); lastError = nil
            status = news.isEmpty ? "Up to date" : "Sent \(news.count) file\(news.count == 1 ? "" : "s")"
        } catch { lastError = "carry failed: \(error)" }
    }

    private func landed(_ url: URL, from peer: MCPeerID) {
        guard let key = Self.decode(url.lastPathComponent),
              let split = CarrySync.split(key, homes: Home.allCases.map(\.folder)),
              let home = Home.allCases.first(where: { $0.folder == split.home })
        else { try? FileManager.default.removeItem(at: url); return }
        let leaf = (split.path as NSString).lastPathComponent
        let renamed = url.deletingLastPathComponent().appendingPathComponent(leaf)
        do {
            if renamed != url {
                try? FileManager.default.removeItem(at: renamed)
                try FileManager.default.moveItem(at: url, to: renamed)
            }
            try Homes.add(renamed, to: home, move: true, subfolder: (split.path as NSString).deletingLastPathComponent)
            status = "Received \(leaf) from \(peer.displayName)"
        } catch { lastError = "landing \(leaf) from \(peer.displayName) failed: \(error)" }
    }

    /// `MCSession`'s resource name is a filename, so a carry key ("library/Music/song.m4a") rides base64url —
    /// no slashes, no surprises on either filesystem.
    private static func encode(_ key: String) -> String {
        Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }
    private static func decode(_ name: String) -> String? {
        var s = name.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s).flatMap { String(data: $0, encoding: .utf8) }
    }
}
