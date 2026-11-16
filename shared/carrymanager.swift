// Derived from Spec: FEAT-09 (the glue: starts the link, runs pairing, pushes new files to paired devices)
// Ties the link (P2PTransport, FEAT-02) and pairing (carrypair.swift) into one thing a screen can drive: see
// nearby devices, pair one, press "Carry now". One copy, used by the Mac menu (strip/app.swift) and the iOS
// Devices screen (mobile/HostApp/iOS/Devices.swift) — no second orchestrator.
//
// "Carry now" now runs the real FEAT-09 P4 settling: each device keeps its own append-only ops log
// (`Recense/.carry/ops/<device>.jsonl`, carrysync.swift's CarrySync.ops/decide), and two paired, connected
// devices exchange "how much of yours have I applied" (`seen`), then the ops the other lacks (`ops`), then the
// bytes those ops need — so a move, a trash or a restore replays correctly on the other side, not just a plain
// file push. Conflict merge for text (3-way, against a remembered base) is still open: this slice always settles
// a real conflict the safe way (keep both, named siblings) rather than merging, because no base is tracked yet.
// That is the one thing still named honestly as not done, not the whole of P4.
//
// Known simplification: files move over the link's own resource transfer (`P2PTransport.send(fileAt:)`), not
// through `shared/pieces`'s resumable chunks. A dropped link restarts that file's send from the top rather than
// resuming — fine for the sizes Homes carries today.
// Known gap: if two devices are each already in a *different* group, pairing refuses rather than merging them
// (no wire message yet compares group fingerprints before the secret is sent). Cannot happen on a first pairing.
// Known gap: ops and the bytes they need can arrive in either order (two different MultipeerConnectivity
// channels) — handled by staging every incoming file under `.carry/incoming/` by its destination key and
// placing it only once the matching op has been decided, from whichever side arrives second.
import Foundation
import CryptoKit
import MultipeerConnectivity
#if canImport(AppKit)
import AppKit
#endif

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
    private var flows: [MCPeerID: CarryPairFlow] = [:]   // one pairing in progress per connected peer (BUG-17)
    private var picked: [String: Date] = [:]             // devices the owner picked → last invite sent (BUG-17)
    private var reinviting = false
    private var lastSent: [CarryFile] = []   // this device's own scan as of the last "Carry now"
    private var appliedSeq: [String: Int] = [:]      // peer display name → highest of THEIR seq I've already settled
    private var pendingActions: [String: CarryAction] = [:]   // destination key → what to do once its bytes land

    private var dir: URL { Carry.dir }
    private var peersURL: URL { dir.appendingPathComponent("peers.json") }
    private var lastSentURL: URL { dir.appendingPathComponent("last-sent.json") }
    private var appliedURL: URL { dir.appendingPathComponent("applied.json") }
    private var opsDir: URL { dir.appendingPathComponent("ops", isDirectory: true) }
    private var stagingDir: URL { dir.appendingPathComponent("incoming", isDirectory: true) }
    private func opsLogURL(_ device: String) -> URL { opsDir.appendingPathComponent("\(device).jsonl") }

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
        try? FileManager.default.createDirectory(at: opsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        peers = (try? Data(contentsOf: peersURL)).flatMap { try? JSONDecoder().decode([CarryPeer].self, from: $0) } ?? []
        lastSent = (try? Data(contentsOf: lastSentURL)).flatMap { try? JSONDecoder().decode([CarryFile].self, from: $0) } ?? []
        appliedSeq = (try? Data(contentsOf: appliedURL)).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        wire()
    }

    private func wire() {
        t.isPaired = { [weak self] peer in
            guard let self else { return false }
            self.reloadFromDisk()
            return self.peers.contains { $0.name == peer.displayName }
        }
        t.confirmUnpaired = { [weak self] _, reply in reply(self?.isLookingToPair ?? false) }
        t.onPeerFound = { [weak self] peer in
            guard let self, !self.nearby.contains(peer) else { return }
            self.nearby.append(peer)
        }
        t.onPeerLost = { [weak self] peer in self?.nearby.removeAll { $0 == peer } }
        t.onStateChange = { [weak self] peer, state in self?.connected(peer, state) }
        t.onMessage = { [weak self] type, data, peer in
            switch type {
            case "pair": self?.receivePair(data, from: peer)
            case "seen": self?.receiveSeen(data, from: peer)
            case "ops": self?.receiveOps(data, from: peer)
            default: break
            }
        }
        t.onReceive = { [weak self] url, peer in self?.landed(url, from: peer) }
    }

    func start() { t.advertise(); t.browse(); if !isLookingToPair { status = "Looking for devices" } }
    func stop() { t.stop(); stopPairing(); status = "Off" }

    // MARK: Pairing — tap "Pair a device" on both screens, in either order (a picked device is invited again, BUG-17)

    /// Nearby devices the owner may pick while pairing: every one but this device itself (the Terminal's
    /// `recense carry pair` sees the running app under the same name). A listed peer stays pickable, so a pairing
    /// that finished on one side only can be redone (BUG-17).
    var pairCandidates: [MCPeerID] { nearby.filter { $0.displayName != P2PTransport.deviceName() } }

    /// "Pair a device": opens this device to the next stranger that connects (or that it finds and invites).
    func beginPairing() {
        isLookingToPair = true; lastError = nil; start(); status = "Pairing"
        for peer in t.session.connectedPeers { startFlow(peer) }   // already connected: no `.connected` will come
    }

    /// "Stop Pairing": ends the pairing only; the link stays on for carrying.
    func stopPairing() {
        isLookingToPair = false; flows = [:]; picked = [:]; pairingCode = nil; pairingWith = nil
        if status == "Pairing" { status = "Looking for devices" }
    }

    /// The owner picked a nearby device by name.
    func invite(_ peer: MCPeerID) {
        isLookingToPair = true
        if t.session.connectedPeers.contains(peer) { startFlow(peer); return }
        picked[peer.displayName] = Date()
        t.invite(peer)
        guard !reinviting else { return }
        reinviting = true
        Task { @MainActor [weak self] in   // until paired or stopped: invite again whoever has not answered yet
            while let self, self.isLookingToPair {
                let connected = Set(self.t.session.connectedPeers.map(\.displayName))
                for name in CarryInvites.due(picked: self.picked, nearby: Set(self.nearby.map(\.displayName)),
                                             connected: connected, now: Date()) {
                    guard let p = self.nearby.first(where: { $0.displayName == name }) else { continue }
                    self.picked[name] = Date()
                    self.t.invite(p)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            self?.reinviting = false
        }
    }

    private func connected(_ peer: MCPeerID, _ state: MCSessionState) {
        guard state == .connected else {
            if state == .notConnected { flows[peer] = nil }
            return
        }
        startFlow(peer)
    }

    /// Runs the exchange only while "Pair a device" is on — for a listed peer too, which re-pairs it (BUG-17).
    /// peers.json and the Keychain's group are shared with any other Recense process on this device (the Terminal's
    /// `recense carry pair`): read them fresh before deciding anything, never trust the copy from launch (BUG-17).
    func reloadFromDisk() {
        if let d = try? Data(contentsOf: peersURL), let list = try? JSONDecoder().decode([CarryPeer].self, from: d),
           list != peers { peers = list }
        if let g = CarryKeychain.load("group") { group = g }
    }

    private func startFlow(_ peer: MCPeerID) {
        guard isLookingToPair, flows[peer] == nil else { return }
        reloadFromDisk()
        let f = CarryPairFlow(me: identity, name: P2PTransport.deviceName(), group: group)
        flows[peer] = f
        apply(f.start(), peer)
    }

    private func receivePair(_ data: Data, from peer: MCPeerID) {
        guard let m = try? JSONDecoder().decode(PairMessage.self, from: data) else { return }
        if flows[peer] == nil { startFlow(peer) }   // their hello can beat our own `.connected` callback
        guard var f = flows[peer] else { return }
        do {
            let step = try f.receive(m)
            flows[peer] = f
            apply(step, peer)
        } catch { fail(peer, error) }
    }

    /// The owner tapped "They match" on this screen.
    func confirmMatch(for peerName: String) {
        guard let peer = flows.keys.first(where: { $0.displayName == peerName }), var f = flows[peer] else { return }
        do {
            let step = try f.confirm()
            flows[peer] = f
            apply(step, peer)
            if step.paired == nil { status = "Waiting for \(peerName) to tap They Match" }
        } catch { fail(peer, error) }
    }

    private func apply(_ step: CarryPairFlow.Step, _ peer: MCPeerID) {
        do { for m in step.send { try t.send(m, type: "pair", to: peer) } } catch { fail(peer, error); return }
        if let c = step.code { pairingCode = c; pairingWith = peer.displayName }
        if let p = step.paired { finish(peer, p) }
    }

    private func fail(_ peer: MCPeerID, _ error: Error) {
        flows[peer] = nil; pairingCode = nil; pairingWith = nil
        lastError = error as? PairFailure == .otherGroup
            ? "\(peer.displayName) already belongs to a different pairing; not merged"
            : "pairing with \(peer.displayName) failed: \(error)"
    }

    private func finish(_ peer: MCPeerID, _ p: CarryPairFlow.Paired) {
        group = p.group
        CarryKeychain.save(p.group, "group")
        reloadFromDisk()   // keep what another process wrote since; replace only this device's entry
        peers = CarryPeer.replacing(peers, with: CarryPeer(name: peer.displayName, key: p.key, paired: Homes.now()))
        do { try JSONEncoder().encode(peers).write(to: peersURL, options: .atomic) }
        catch { lastError = "saving peers.json failed: \(error)" }
        flows[peer] = nil
        pairingCode = nil; pairingWith = nil; isLookingToPair = false; picked = [:]
        status = "Paired with \(peer.displayName)"
    }

    // MARK: Carry now — scan into this device's own ops log, then settle with every paired, connected device

    /// A fresh scan against the last one, turned into ops and appended to this device's own log (FEAT-09 P2).
    /// Where a file in `trash/` came from, for `CarrySync.ops`'s trash/restore detection.
    private func trashOrigins() -> [String: String] {
        Dictionary(uniqueKeysWithValues: Homes.index(.trash).compactMap { e -> (String, String)? in
            guard let tag = e.tags.first(where: { $0.hasPrefix("from:") }) else { return nil }
            return (e.path, String(tag.dropFirst("from:".count)))
        })
    }

    private func myOps() -> [CarryOp] {
        CarrySync.decode((try? String(contentsOf: opsLogURL(Homes.device), encoding: .utf8)) ?? "")
    }

    private func appendOps(_ ops: [CarryOp]) throws {
        guard !ops.isEmpty else { return }
        let h = FileHandle(forWritingAtPath: opsLogURL(Homes.device).path)
        if let h { defer { try? h.close() }; h.seekToEndOfFile(); h.write(Data(CarrySync.encode(ops).utf8)) }
        else { try CarrySync.encode(ops).write(to: opsLogURL(Homes.device), atomically: true, encoding: .utf8) }
    }

    func carryNow() {
        reloadFromDisk()
        guard !peers.isEmpty else { lastError = "no paired device yet"; return }
        let targets = t.session.connectedPeers.filter { p in peers.contains { $0.name == p.displayName } }
        guard !targets.isEmpty else { lastError = "no paired device is connected right now"; return }
        do {
            let now = (try Carry.verify()).map { CarryFile(home: $0.home, path: $0.path, size: $0.size, sha256: $0.sha256) }
            let mine = myOps()
            let ops = CarrySync.ops(last: lastSent, now: now, trashOrigins: trashOrigins(), device: Homes.device,
                                    nextSeq: (mine.map(\.seq).max() ?? 0) + 1, at: Int64(Date().timeIntervalSince1970))
            try appendOps(ops)
            lastSent = now
            try JSONEncoder().encode(now).write(to: lastSentURL, options: .atomic)
            for peer in targets { try t.send(appliedSeq[peer.displayName] ?? 0, type: "seen", to: peer) }
            lastCarryAt = Date(); lastError = nil
            status = ops.isEmpty ? "Up to date" : "Settling \(ops.count) change\(ops.count == 1 ? "" : "s")"
        } catch { lastError = "carry failed: \(error)" }
    }

    /// The resulting place an op settles at — where its bytes (if any) belong, on either side of the link.
    private func resultKey(_ op: CarryOp) -> String { op.toKey ?? CarrySync.key(op.home, op.path) }

    private func receiveSeen(_ data: Data, from peer: MCPeerID) {
        guard let since = try? JSONDecoder().decode(Int.self, from: data) else { return }
        let mine = myOps().filter { $0.seq > since }
        guard !mine.isEmpty else { return }
        try? t.send(mine, type: "ops", to: peer)
        for op in mine where op.op != .trash {   // trash never fetches (CarrySync.decide); nothing to send
            let url = Homes.root.appendingPathComponent(resultKey(op))
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            t.send(fileAt: url, named: Self.encode(resultKey(op)), to: peer) { [weak self] error in
                if let error { self?.lastError = "sending to \(peer.displayName) failed: \(error)" }
            }
        }
    }

    private func receiveOps(_ data: Data, from peer: MCPeerID) {
        guard let ops = try? JSONDecoder().decode([CarryOp].self, from: data) else { return }
        guard let local = try? Carry.verify() else { lastError = "carry verify failed while settling"; return }
        let localShas = Dictionary(uniqueKeysWithValues: local.map { (CarrySync.key($0.home, $0.path), $0.sha256) })
        for op in ops.sorted(by: { $0.seq < $1.seq }) {
            let action = CarrySync.decide(op, local: localShas, base: [:], deviceName: Homes.device)
            let key = resultKey(op)
            switch action {
            case .nothing: discardStaged(key)
            case .move: do { try CarryApply.apply(action) } catch { lastError = "replaying a move failed: \(error)" }
                        discardStaged(key)
            case .fetch, .replace, .keepBoth: pendingActions[key] = action; tryPlace(key)
            case .merge: break   // unreachable with an empty base; text conflicts still settle as keepBoth
            }
        }
        appliedSeq[peer.displayName] = max(appliedSeq[peer.displayName] ?? 0, ops.map(\.seq).max() ?? 0)
        try? JSONEncoder().encode(appliedSeq).write(to: appliedURL, options: .atomic)
        status = "Settled \(ops.count) change\(ops.count == 1 ? "" : "s") from \(peer.displayName)"
    }

    private func stagedURL(_ key: String) -> URL { stagingDir.appendingPathComponent(Self.encode(key)) }
    private func discardStaged(_ key: String) { try? FileManager.default.removeItem(at: stagedURL(key)) }

    /// Places a staged file's bytes once its action is known — whichever of (op, bytes) arrived second.
    /// The actual file-system work is `CarryApply.apply` (shared/carryapply.swift): one implementation, tested
    /// without radios there, called here and (for `.move`, no bytes needed) from `receiveOps` directly.
    private func tryPlace(_ key: String) {
        guard let action = pendingActions[key] else { return }
        let staged = stagedURL(key)
        guard FileManager.default.fileExists(atPath: staged.path) else { return }
        do {
            let placed = try CarryApply.apply(action, bytesAt: staged)
            pendingActions[key] = nil
            if let placed { status = "Settled \((placed as NSString).lastPathComponent)" }
        } catch { lastError = "placing \(key) failed: \(error)"; discardStaged(key); pendingActions[key] = nil }
    }

    private func landed(_ url: URL, from peer: MCPeerID) {
        guard let key = Self.decode(url.lastPathComponent) else { try? FileManager.default.removeItem(at: url); return }
        let staged = stagedURL(key)
        do {
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: url, to: staged)
        } catch { lastError = "staging from \(peer.displayName) failed: \(error)"; return }
        tryPlace(key)   // the matching op may already have arrived; if not, this waits for receiveOps to call it
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

// `recense carry pair` (Mac CLI): the terminal equivalent of tapping "Pair a Device…" (FEAT-09 P1). Opens this
// device to the next stranger (re-inviting until it answers, BUG-17), prints the six-digit code here, and
// waits for Enter in place of a tap on "They Match". The eye-compare step itself still needs the owner looking
// at both screens — that is the whole point of the code (FEAT-09 P1's defense against a device in the middle)
// and is not automatable here.
//
// The GUI's "Pair a device" only makes this device discoverable; the actual invite is sent when the owner taps
// a specific name in the "Looking for a device to pair" list (Devices.swift). A terminal has no such list to
// tap, so this invites the first not-yet-paired device it sees — fine for a CLI, since there is normally only
// one stranger nearby when you run this.
@MainActor
func runCarryPairCLI() async -> Never {
    setbuf(stdout, nil)   // flush every line immediately: the code and the Enter prompt must appear right away
    #if canImport(AppKit)
    // Two Recense processes on one Mac show the phone two Macs with the same name, and each keeps its own copy of
    // the pairing state (BUG-17, the owner's 17:30 run). While the app runs, pairing belongs to its menu.
    let me = ProcessInfo.processInfo.processIdentifier
    if NSRunningApplication.runningApplications(withBundleIdentifier: "local.recense").contains(where: { $0.processIdentifier != me }) {
        fputs("carry pair: Recense is running — pair from its menu instead: Recense › Devices › Pair a Device…\n", stderr)
        exit(2)
    }
    #endif
    let cm = CarryManager.shared
    print("Looking for a device to pair. On the other device, open Recense › Library › Devices › Pair a Device…")
    print("(either side may start first; this keeps trying until a code appears — Ctrl-C to cancel)")
    cm.beginPairing()
    var invited: MCPeerID?
    var waited = 0
    while cm.pairingCode == nil {
        if let e = cm.lastError { fputs("carry pair: \(e)\n", stderr); exit(1) }
        waited += 1
        if invited == nil, waited % 50 == 0 {   // every 15 s with nothing seen
            print("No device seen yet. On the iPhone or iPad: unlocked, Recense open on Library › Devices, Wi-Fi or Bluetooth on.")
        }
        if invited == nil, let peer = cm.pairCandidates.first {
            invited = peer
            print("Found \(peer.displayName) — inviting…")
            cm.invite(peer)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
    let code = cm.pairingCode!, who = cm.pairingWith!
    print("Code with \(who): \(code)")
    print("Check the same code is on the other screen, then press Enter to confirm (Ctrl-C to cancel):")
    _ = readLine()
    cm.confirmMatch(for: who)
    while cm.pairingWith != nil {
        if let e = cm.lastError { fputs("carry pair: \(e)\n", stderr); exit(1) }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    print("Paired with \(who).")
    exit(0)
}
