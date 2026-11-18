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
import CoreServices
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
    @Published var askingCode = false                       // P1b: type the code shown on `pairingWith`
    @Published var codeIsCompare = false                    // P1 (older peer): compare and tap They Match
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
    private var schedule = CarrySchedule()           // automatic carry (FEAT-09 P4, T-0084)
    private let clock0 = Date()
    private var wake: Task<Void, Never>?             // the one sleeper, until `schedule.due`
    private var watching = false
    #if os(macOS)
    private var stream: FSEventStreamRef?
    #endif
    private var lastSent: [CarryFile] = []   // this device's own scan as of the last "Carry now"
    private var appliedSeq: [String: Int] = [:]      // peer display name → highest of THEIR seq I've already settled
    private var pendingActions: [String: CarryAction] = [:]   // destination key → what to do once its bytes land
    private var waiting: [String: (peer: String, seq: Int)] = [:]   // destination key → the op whose bytes are owed (BUG-19)
    private var received: [String: Int] = [:]                 // peer → highest seq of its ops seen this run

    private var dir: URL { Carry.dir }
    private var peersURL: URL { dir.appendingPathComponent("peers.json") }
    private var lastSentURL: URL { dir.appendingPathComponent("last-sent.json") }
    // BUG-19: v1 (applied.json) counted ops applied before their bytes landed; a fresh name asks every peer
    // for its whole log once more, which settles idempotently (CarrySync.decide skips what is already here).
    private var appliedURL: URL { dir.appendingPathComponent("applied-v2.json") }
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
        watchHomes()
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
        t.onReceive = { [weak self] url, name, peer in self?.landed(url, named: name, from: peer) }
        t.onReceiveFailed = { [weak self] name, peer, error in
            self?.lastError = "a file from \(peer.displayName) did not arrive (\(Self.decode(name) ?? name)): \(error.localizedDescription)"
        }
    }

    func start() { t.advertise(); t.browse(); if !isLookingToPair { status = "Looking for devices" } }
    func stop() { t.stop(); stopPairing(); status = "Off" }

    // MARK: Pairing — tap "Pair a device" on both screens, in either order (a picked device is invited again, BUG-17)

    /// Nearby devices the owner may pick while pairing: every one but this device itself (the Terminal's
    /// `recense carry pair` sees the running app under the same name). A listed peer stays pickable, so a pairing
    /// that finished on one side only can be redone (BUG-17).
    /// One row per name, the newest found (owner: "it should only show mac pro once … there should not be two").
    var pairCandidates: [MCPeerID] {
        CarryInvites.newestPerName(nearby.filter { $0.displayName != P2PTransport.deviceName() }, name: \.displayName)
    }

    /// "Pair a device": opens this device to the next stranger that connects (or that it finds and invites).
    func beginPairing() {
        isLookingToPair = true; lastError = nil; start(); status = "Pairing"
        for peer in t.session.connectedPeers { startFlow(peer) }   // already connected: no `.connected` will come
    }

    /// "Stop Pairing": ends the pairing only; the link stays on for carrying.
    func stopPairing() {
        isLookingToPair = false; flows = [:]; picked = [:]; pairingCode = nil; pairingWith = nil; askingCode = false
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
            if state == .notConnected {
                flows[peer] = nil
                if pairedConnected.isEmpty { trigger(.disconnected) }
            }
            return
        }
        startFlow(peer)
        reloadFromDisk()
        if peers.contains(where: { $0.name == peer.displayName }) { trigger(.connected) }
    }

    // MARK: Automatic carry (FEAT-09 P4, T-0084): connect, a change, the front; never on the main thread's time

    private var pairedConnected: [MCPeerID] {
        t.session.connectedPeers.filter { p in peers.contains { $0.name == p.displayName } }
    }

    /// The app came to the front (iOS scenePhase .active).
    func cameToFront() { trigger(.foreground) }

    private func trigger(_ e: CarrySchedule.Event) {
        let now = Date().timeIntervalSince(clock0)
        schedule.handle(e, at: now)
        arm()
    }

    private func arm() {
        wake?.cancel()
        guard let due = schedule.due else { return }
        let wait = max(0, due - Date().timeIntervalSince(clock0))
        wake = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self, !Task.isCancelled else { return }
            if self.schedule.tick(at: Date().timeIntervalSince(self.clock0)) { await self.carry() } else { self.arm() }
        }
    }

    /// Homes changed: the app's own writes (`Homes.changed`, both platforms) and, on the Mac, anything else
    /// that writes into a home under ~/Recense (Finder, a download) through FSEvents. Only homes count (T-0091).
    private func watchHomes() {
        guard !watching else { return }
        watching = true
        NotificationCenter.default.addObserver(forName: Homes.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trigger(.changed) }
        }
        #if os(macOS)
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, n, paths, _, _ in
            guard let info else { return }
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let root = Homes.root.resolvingSymlinksInPath().path, homes = Home.allCases.map(\.folder)
            guard list.prefix(n).contains(where: { CarryWatch.counts($0, root: root, homes: homes) }) else { return }   // T-0091
            let me = Unmanaged<CarryManager>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.trigger(.changed) } }
        }
        if let s = FSEventStreamCreate(nil, cb, &ctx, [Homes.root.path] as CFArray,
                                       FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                       FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)) {
            FSEventStreamSetDispatchQueue(s, .main)
            FSEventStreamStart(s)
            stream = s
        }
        #endif
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
        // P1b: the device on which the owner picked the other's name shows the code; the other asks for it
        let f = CarryPairFlow(me: identity, name: P2PTransport.deviceName(), group: group,
                              picked: picked[peer.displayName] != nil)
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

    /// P1b: the owner typed the six digits shown on the other device (touch, keyboard, voice or the CLI).
    func enterCode(_ code: String) {
        guard let peer = flows.keys.first(where: { $0.displayName == pairingWith }) ?? flows.keys.first,
              var f = flows[peer] else { lastError = "nothing is waiting for a code"; return }
        do {
            let step = try f.enter(code)
            flows[peer] = f
            askingCode = false
            status = "Checking the code with \(peer.displayName)"
            apply(step, peer)
        } catch { fail(peer, error) }
    }

    private func apply(_ step: CarryPairFlow.Step, _ peer: MCPeerID) {
        do { for m in step.send { try t.send(m, type: "pair", to: peer) } } catch { fail(peer, error); return }
        if let c = step.code {
            pairingCode = c; pairingWith = peer.displayName; codeIsCompare = flows[peer]?.passkey == nil
            if !codeIsCompare { status = "Type \(c) on \(peer.displayName)" }
        }
        if step.wantsCode { askingCode = true; pairingWith = peer.displayName }
        if let p = step.paired { finish(peer, p) }
    }

    private func fail(_ peer: MCPeerID, _ error: Error) {
        let e = error as? PairFailure
        if e != .refused { try? t.send(PairMessage.refuse("\(e.map { "\($0)" } ?? "failed")"), type: "pair", to: peer) }
        flows[peer] = nil; pairingCode = nil; pairingWith = nil; askingCode = false
        switch e {
        case .otherGroup: lastError = "\(peer.displayName) already belongs to a different pairing; not merged"
        case .badCommit, .refused: lastError = "Code didn't match. Pick \(peer.displayName) again for a new code."
        default: lastError = "pairing with \(peer.displayName) failed: \(error)"
        }
    }

    private func finish(_ peer: MCPeerID, _ p: CarryPairFlow.Paired) {
        group = p.group
        CarryKeychain.save(p.group, "group")
        reloadFromDisk()   // keep what another process wrote since; replace only this device's entry
        peers = CarryPeer.replacing(peers, with: CarryPeer(name: peer.displayName, key: p.key, paired: Homes.now()))
        do { try JSONEncoder().encode(peers).write(to: peersURL, options: .atomic) }
        catch { lastError = "saving peers.json failed: \(error)" }
        flows[peer] = nil
        pairingCode = nil; pairingWith = nil; askingCode = false; isLookingToPair = false; picked = [:]
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

    /// "Carry Now": the visible retry. Runs at once, or right after the carry already running.
    func carryNow() {
        reloadFromDisk()
        guard !peers.isEmpty else { lastError = "no paired device yet"; return }
        guard !pairedConnected.isEmpty else { lastError = "no paired device is connected right now"; return }
        trigger(.tapped)
    }

    /// One carry. The scan (hashing) runs off the main thread, so playing, reading and writing never wait on it.
    private func carry() async {
        defer { trigger(.finished) }
        reloadFromDisk()
        let targets = pairedConnected
        guard !targets.isEmpty else { return }
        status = "Carrying"
        do {
            let lines = try await Task.detached(priority: .utility) { try Carry.verify(reuse: true) }.value
            let now = lines.map { CarryFile(home: $0.home, path: $0.path, size: $0.size, sha256: $0.sha256) }
            let mine = myOps()
            let ops = CarrySync.ops(last: lastSent, now: now, trashOrigins: trashOrigins(), device: Homes.device,
                                    nextSeq: (mine.map(\.seq).max() ?? 0) + 1, at: Int64(Date().timeIntervalSince1970))
            try appendOps(ops)
            lastSent = now
            try JSONEncoder().encode(now).write(to: lastSentURL, options: .atomic)
            for peer in targets { try t.send(appliedSeq[peer.displayName] ?? 0, type: "seen", to: peer) }
            lastCarryAt = Date(); lastError = nil
            status = ops.isEmpty ? "Up to date" : "Settling \(ops.count) change\(ops.count == 1 ? "" : "s")"
            if !waiting.isEmpty { status += " · waiting for \(waiting.count) file\(waiting.count == 1 ? "" : "s")" }   // BUG-19
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

    /// Ops from a peer, settled in the order they arrive. The scan that decides them (it hashes every file) runs off the
    /// main thread, as `carry()`'s does (T-0107): on a big library it froze the screen and risked iOS's watchdog. One batch
    /// after another, so a later batch never settles before an earlier one.
    private var settling: Task<Void, Never>?
    private func receiveOps(_ data: Data, from peer: MCPeerID) {
        guard let ops = try? JSONDecoder().decode([CarryOp].self, from: data) else { return }
        let before = settling
        settling = Task { [weak self] in
            await before?.value
            guard let lines = try? await Task.detached(priority: .utility, operation: { try Carry.verify(reuse: true) }).value else {
                self?.lastError = "carry verify failed while settling"; return
            }
            self?.settle(ops, local: lines, from: peer)
        }
    }

    private func settle(_ ops: [CarryOp], local: [CarryLine], from peer: MCPeerID) {
        let localShas = Dictionary(uniqueKeysWithValues: local.map { (CarrySync.key($0.home, $0.path), $0.sha256) })
        for op in ops.sorted(by: { $0.seq < $1.seq }) {
            let action = CarrySync.decide(op, local: localShas, base: [:], deviceName: Homes.device)
            let key = resultKey(op)
            switch action {
            case .nothing: discardStaged(key); pendingActions[key] = nil; waiting[key] = nil
            case .move: do { try CarryApply.apply(action) } catch { lastError = "replaying a move failed: \(error)" }
                        discardStaged(key); pendingActions[key] = nil; waiting[key] = nil
            case .fetch, .replace, .keepBoth:
                pendingActions[key] = action; waiting[key] = (peer.displayName, op.seq); tryPlace(key)
            case .merge: break   // unreachable with an empty base; text conflicts still settle as keepBoth
            }
        }
        received[peer.displayName] = max(received[peer.displayName] ?? 0, ops.map(\.seq).max() ?? 0)
        advance(peer.displayName)
    }

    /// appliedSeq moves only past ops fully settled: an op still owed its bytes is asked for again on the next
    /// "seen" (the next carry, or the next connect). Never counted applied before it is (BUG-19).
    private func advance(_ peer: String) {
        guard let got = received[peer] else { return }
        let owed = waiting.values.filter { $0.peer == peer }.map(\.seq)
        let through = CarrySync.settledThrough(received: got, pending: owed)
        if through > (appliedSeq[peer] ?? 0) {
            appliedSeq[peer] = through
            try? JSONEncoder().encode(appliedSeq).write(to: appliedURL, options: .atomic)
        }
        status = owed.isEmpty ? "Up to date with \(peer)" : "Waiting for \(owed.count) file\(owed.count == 1 ? "" : "s") from \(peer)"
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
            _ = try CarryApply.apply(action, bytesAt: staged)
            pendingActions[key] = nil
            if let w = waiting.removeValue(forKey: key) { advance(w.peer) }
        } catch {   // stays owed: the next "seen" asks for it again
            lastError = "placing \(key) failed: \(error)"; discardStaged(key); pendingActions[key] = nil
        }
    }

    private func landed(_ url: URL, named name: String, from peer: MCPeerID) {
        guard let key = Self.decode(name) else {
            try? FileManager.default.removeItem(at: url); lastError = "a file from \(peer.displayName) had no usable name"; return
        }
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

// `recense carry pair` (Mac CLI): the terminal equivalent of tapping "Pair a Device…" (FEAT-09 P1/P1b). Opens this
// device to the next stranger (re-inviting until it answers, BUG-17). It invites, so it shows the six digits to type
// on the other device (P1b); if the other device picked first, it asks for that device's code instead. An older
// peer still compares codes (P1): Enter stands for "They Match".
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
    while cm.pairingCode == nil && !cm.askingCode {
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
    let who = cm.pairingWith!
    if cm.askingCode {                       // FEAT-09 P1b: the other device shows the code
        print("Type the code shown on \(who), then Enter:")
        cm.enterCode(readLine() ?? "")
    } else if !cm.codeIsCompare {            // P1b: this side shows it (it picked the other)
        print("Type this code on \(who): \(cm.pairingCode!)")
    } else {                                 // P1, an older peer: compare and confirm
        print("Code with \(who): \(cm.pairingCode!)")
        print("Check the same code is on the other screen, then press Enter to confirm (Ctrl-C to cancel):")
        _ = readLine()
        cm.confirmMatch(for: who)
    }
    while cm.pairingWith != nil {
        if let e = cm.lastError { fputs("carry pair: \(e)\n", stderr); exit(1) }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    print("Paired with \(who).")
    exit(0)
}

// Regression guard: T-0129 / the comment at receiveOps above ("one batch after another, so a later batch
// never settles before an earlier one"). Drives the real receiveOps→settle chain, no radios: two batches
// land back-to-back, as two MultipeerConnectivity messages would, before the first has had any chance to
// finish its off-main-thread hash scan.
extension CarryManager {
    fileprivate func receiveOpsForTest(_ data: Data, from peer: MCPeerID) { receiveOps(data, from: peer) }
    fileprivate var settlingForTest: Task<Void, Never>? { settling }
}

@MainActor func carrymanagerOrderingSelftest() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String) { print("\(pass ? "ok  " : "FAIL") carrymanager, \(what)"); ok = ok && pass }
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("recense-carrymanager-\(UUID().uuidString)")
    setenv("RECENSE_HOME", dir.appendingPathComponent("Recense").path, 1)
    defer { unsetenv("RECENSE_HOME"); try? fm.removeItem(at: dir) }
    try? Homes.ensure()

    let a = Homes.url(.study).appendingPathComponent("a.md")
    try? fm.createDirectory(at: a.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data("hello".utf8).write(to: a)
    let sha = (try? Homes.sha256(a)) ?? ""
    try? Homes.record(try Homes.entry(for: a, in: .study), in: .study)

    let cm = CarryManager()
    let peer = MCPeerID(displayName: "test-peer")
    let now = Int64(Date().timeIntervalSince1970)
    let op1 = CarryOp(seq: 1, device: "test-peer", at: now, op: .move, home: "library/Study", path: "a.md",
                       toHome: "library/Study", to: "b.md", sha256: sha, size: 5)
    let op2 = CarryOp(seq: 2, device: "test-peer", at: now, op: .move, home: "library/Study", path: "b.md",
                       toHome: "library/Study", to: "c.md", sha256: sha, size: 5)
    let e = JSONEncoder()
    guard let data1 = try? e.encode([op1]), let data2 = try? e.encode([op2]) else { check(false, "ops encode"); return ok }

    cm.receiveOpsForTest(data1, from: peer)
    cm.receiveOpsForTest(data2, from: peer)   // arrives right behind the first, before its scan could finish

    var done = false
    Task { await cm.settlingForTest?.value; done = true }
    let deadline = Date().addingTimeInterval(5)
    while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(done, "both batches settle within 5s")

    check(!fm.fileExists(atPath: Homes.url(.study).appendingPathComponent("a.md").path), "a.md is gone")
    check(!fm.fileExists(atPath: Homes.url(.study).appendingPathComponent("b.md").path), "b.md (the in-between name) never lingers")
    check((try? String(contentsOf: Homes.url(.study).appendingPathComponent("c.md"))) == "hello",
          "the file reaches c.md with its bytes intact — op2 saw op1's move, not a stale scan")
    return ok
}
