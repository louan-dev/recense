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
    /// SEC-02 invariant 13: found, not found, or failed; an error never reads as "nothing stored".
    static func load(_ account: String) -> CarryStored {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                 kSecAttrAccount as String: account, kSecReturnData as String: true,
                                 kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        return CarryStored.from(status, out as? Data)
    }
    @discardableResult
    static func save(_ data: Data, _ account: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return CarryStored.save(update: { SecItemUpdate(base as CFDictionary, attrs as CFDictionary) },   // invariant 14
                                add: { SecItemAdd(base.merging(attrs) { $1 } as CFDictionary, nil) })
    }
}

@MainActor final class CarryManager: NSObject, ObservableObject {
    static let shared = CarryManager()

    @Published private(set) var peers: [CarryPeer] = []         // SEC-02: the trust store (Keychain peers.v2) only
    @Published private(set) var needsPairing: [String] = []     // SEC-02 §2.6: "Pair again to keep carrying"
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
    // Derived from Spec: SEC-02 · every per-peer state above is keyed by the trust-store name, never displayName
    private var mirror: [CarryPeer] = []                        // peers.json: a readable copy, never read for trust
    private var auth: [MCPeerID: CarryAuthSession] = [:]        // one handshake per connection (§2.3)
    private var authDeadline = CarryDeadlines<MCPeerID>()       // its 10 s token, one per session (invariant 15)
    private var pendingAuth: [MCPeerID: [CarryAuthMessage]] = [:]   // a not-yet-trusted key's hello (and what follows it), while pairing
    private var refusedNames: Set<String> = []                  // a known name that sent an unknown key or no proof
    private var stagedFrom: [String: String] = [:]              // staged key → the authenticated peer that sent the bytes
    private var placing: Set<String> = []                       // keys whose staged bytes are being hashed (§2.4)
    private var trustWritable = true                            // false while peers.v2 can't be read (invariant 13)
    private var identityUnread = false                          // this launch's key is a stand-in: pair nothing with it
    private var groupUnread = false                             // the group secret could not be read: pair nothing
    private var wantsLink = false                               // start() was asked for while the key was unread
    private var gate: CarryKeychainGate {                       // invariant 19
        CarryKeychainGate(identityUnread: identityUnread, groupUnread: groupUnread, trustWritable: trustWritable)
    }

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
        let id = Self.readIdentity()   // SEC-02 invariants 13, 19: never replace a key this launch could not read
        identity = id.key; identityUnread = id.unread
        let keychainError: String? = id.unread ? Self.unreadable : nil
        let g = CarryKeychain.load("group")
        group = g.data
        groupUnread = g.failed   // invariant 19: a pairing must not save over a secret it could not read
        super.init()
        if let keychainError { lastError = keychainError }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: opsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        reloadFromDisk()   // SEC-02 §2.6: trust comes from peers.v2 only; old peers.json entries need pairing again
        lastSent = (try? Data(contentsOf: lastSentURL)).flatMap { try? JSONDecoder().decode([CarryFile].self, from: $0) } ?? []
        appliedSeq = (try? Data(contentsOf: appliedURL)).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        sweepStaging(maxAge: 0)   // T-0092: nothing waits in memory yet; unsettled ops are asked for again
        wire()
        watchHomes()
    }

    private func wire() {
        t.isPaired = { [weak self] _, context in   // SEC-02 §2.2: a trusted key and its proof, never a name
            guard let self else { return false }
            self.reloadFromDisk()
            return CarryInvite.accepts(context, me: self.identity, trusted: self.peers) != nil
        }
        t.inviteContext = { [weak self] peer in   // the name picks whom to invite; the handshake proves who it is
            guard let self else { return nil }
            self.reloadFromDisk()
            guard let p = self.peers.first(where: { $0.name == peer.displayName }) else { return nil }
            return try? CarryInvite.context(me: self.identity, peer: p.key)
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
            case "auth": self?.receiveAuth(data, from: peer)
            case "sealed": self?.receiveSealed(data, from: peer)
            default: break   // SEC-02 §2.4: a plain seen/ops/gone is dropped, no fallback
            }
        }
        t.onReceive = { [weak self] url, name, peer in self?.landed(url, named: name, from: peer) }
        t.onReceiveFailed = { [weak self] name, peer, error in
            self?.lastError = "a file from \(peer.displayName) did not arrive (\(Self.decode(name) ?? name)): \(error.localizedDescription)"
        }
    }

    func start() {
        wantsLink = true
        guard gate.canAuth else { lastError = Self.unreadable; return }   // invariant 19: never advertise a stand-in key
        t.advertise(); t.browse()
        if !isLookingToPair { status = needsPairing.isEmpty ? "Looking for devices" : Self.pairAgain(needsPairing) }
    }
    static func pairAgain(_ names: [String]) -> String { "Pair \(names.joined(separator: ", ")) again to keep carrying" }
    func stop() { wantsLink = false; t.stop(); stopPairing(); status = "Off" }

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
        guard gate.canPair else { lastError = Self.unreadable; return }   // invariant 19
        isLookingToPair = true; lastError = nil; start(); status = "Pairing"
        for peer in t.session.connectedPeers { startFlow(peer) }   // already connected: no `.connected` will come
    }

    /// "Stop Pairing": ends the pairing only; the link stays on for carrying.
    func stopPairing() {
        isLookingToPair = false; flows = [:]; picked = [:]; pairingCode = nil; pairingWith = nil; askingCode = false
        if status == "Pairing" { status = "Looking for devices" }
        for peer in pendingAuth.keys { armAuthTimeout(peer) }   // invariant 15: a held stranger is judged, not kept
    }

    /// The owner picked a nearby device by name.
    func invite(_ peer: MCPeerID) {
        guard gate.canPair else { lastError = Self.unreadable; return }   // invariant 19
        isLookingToPair = true
        picked = PairPrompt.pick(picked, peer.displayName, at: Date())   // T-0123: before the early return
        if t.session.connectedPeers.contains(peer) { startFlow(peer); return }
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
                flows[peer] = nil; auth[peer] = nil; pendingAuth[peer] = nil
                let was = PairPrompt.Shown(pairingWith: pairingWith, askingCode: askingCode, pairingCode: pairingCode)
                let now = PairPrompt.disconnected(was, peer: peer.displayName)   // T-0121: its peer left, the prompt goes
                if now != was { pairingWith = now.pairingWith; askingCode = now.askingCode; pairingCode = now.pairingCode }
                if pairedConnected.isEmpty { trigger(.disconnected) }
            }
            return
        }
        startFlow(peer)
        reloadFromDisk()
        startAuth(peer)   // SEC-02 §2.3: carry starts only once this peer proves its key (receiveAuth)
    }

    // MARK: SEC-02 · the handshake on every connection, then sealed messages only

    private func startAuth(_ peer: MCPeerID) {
        guard auth[peer] == nil, gate.canAuth else { return }   // invariant 19: a stand-in key proves nothing
        let s = CarryAuthSession(me: identity)
        auth[peer] = s
        _ = authDeadline.begin(peer)   // invariant 15: earlier sessions' timers go dead
        try? t.send(s.hello, type: "auth", to: peer)
        armAuthTimeout(peer)
    }

    /// §2.6: no valid proof within 10 s (outside pairing): this device is listed to pair again; an older build is named.
    /// Invariant 15: the timer belongs to the session it was armed for; a reconnect's session is not judged by it.
    private func armAuthTimeout(_ peer: MCPeerID) {
        guard let token = authDeadline.token(peer) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.authDeadline.live(peer, token), let s = self.auth[peer] else { return }
            switch CarryAuthTimeout.verdict(authenticated: s.authenticated, gotHello: s.gotHello, held: self.pendingAuth[peer] != nil,
                                            pairing: self.isLookingToPair, connected: self.t.session.connectedPeers.contains(peer)) {
            case .badProof: self.refuse(peer, CarryAuthFailure.badProof)
            case .unknownKey: self.refuse(peer, CarryAuthFailure.unknownKey)   // pairing ended unpaired
            case .noAnswer: self.t.drop(peer); self.lastError = "\(peer.displayName) did not answer securely: update Recense on \(peer.displayName)"
            case nil: break
            }
        }
    }

    private func receiveAuth(_ data: Data, from peer: MCPeerID) {
        guard let m = try? JSONDecoder().decode(CarryAuthMessage.self, from: data) else { return }
        if auth[peer] == nil, t.session.connectedPeers.contains(peer) { startAuth(peer) }   // it beat our `.connected`
        guard var s = auth[peer] else { return }
        if pendingAuth[peer] != nil { pendingAuth[peer]?.append(m); return }   // held behind its hello, in order
        reloadFromDisk()
        do {
            let reply = try s.receive(m, trusted: peers)
            auth[peer] = s
            if let reply { try t.send(reply, type: "auth", to: peer) }
            if s.authenticated, let p = s.peer {
                if refusedNames.remove(p.name) != nil { reloadFromDisk() }
                trigger(.connected)
            }
        } catch CarryAuthFailure.unknownKey where isLookingToPair || flows[peer] != nil {
            pendingAuth[peer] = [m]  // pairing with it: its key is trusted once the pairing finishes (§2.3 step 2)
        } catch CarryAuthFailure.outOfOrder {
            // a duplicate; the session goes on
        } catch { refuse(peer, error) }
    }

    /// No channel: disconnect it. A name this device knows is listed under "Needs pairing again" (§2.6).
    private func refuse(_ peer: MCPeerID, _ error: Error) {
        let name = peer.displayName
        auth[peer] = nil; pendingAuth[peer] = nil
        t.drop(peer)
        if peers.contains(where: { $0.name == name }) || mirror.contains(where: { $0.name == name }) {
            refusedNames.insert(name); reloadFromDisk()
        }
        lastError = (error as? CarryAuthFailure) == .unknownKey
            ? "\(name) has a key this device doesn't know (reset, or not the device it says): pair it again to carry"
            : "\(name) did not prove its key: pair it again to carry"
    }

    /// The trust-store name of a peer that proved a key still trusted, or nil.
    private func trustedName(_ peer: MCPeerID) -> String? {
        guard let s = auth[peer], s.authenticated, let p = s.peer, peers.contains(where: { $0.key == p.key }) else { return nil }
        return p.name
    }

    private func sendSealed<T: Encodable>(_ value: T, type: String, to peer: MCPeerID) throws {
        guard var s = auth[peer] else { throw CarryAuthFailure.notAuthenticated }
        let box = try s.seal(type, try JSONEncoder().encode(value))
        auth[peer] = s
        try t.send(box, type: "sealed", to: peer)
    }

    /// §2.4: a frame that does not open, comes twice, or comes from a peer not (or no longer) trusted is dropped.
    private func receiveSealed(_ data: Data, from peer: MCPeerID) {
        guard var s = auth[peer], let box = try? JSONDecoder().decode(CarrySealed.self, from: data),
              let f = try? s.open(box) else { return }
        auth[peer] = s
        reloadFromDisk()   // forgotten meanwhile by another process (the Terminal's `recense carry forget`)
        guard let name = trustedName(peer) else { auth[peer] = nil; t.drop(peer); return }
        switch f.type {
        case "seen": receiveSeen(f.payload, from: peer, as: name)
        case "ops": receiveOps(f.payload, as: name)
        case "gone": receiveGone(f.payload, as: name)
        case "forget": receiveForget(from: peer, as: name)
        default: break
        }
    }

    // MARK: SEC-02 §2.5 · Forget <device> (Devices row or menu, "Forget Device" by voice, `recense carry forget`)

    /// Every entry named `name` leaves the trust store and peers.json. A connected one is told first (a sealed
    /// `forget`), then disconnected. Files, ops logs and appliedSeq stay; bytes still owed by it are discarded.
    /// No forwarding to the owner's other devices (open question 1): a stolen device could unpair the real ones.
    /// Returns whether a sealed `forget` was sent (§2.5, invariant 18): the CLI has no link, so it never is there.
    @discardableResult
    func forget(_ name: String) -> Bool {
        reloadFromDisk()
        let keys = Set((peers + mirror).filter { $0.name == name }.map(\.key))
        guard !keys.isEmpty || refusedNames.contains(name) else { lastError = "\(name) is not paired"; return false }
        guard gate.canForget else { lastError = Self.unreadable; return false }   // invariant 19: before telling the peer
        var told = false
        for (peer, s) in auth where s.peer.map({ keys.contains($0.key) }) ?? false {
            if s.authenticated, (try? sendSealed(Data(), type: "forget", to: peer)) != nil { told = true }
            auth[peer] = nil
            Task { @MainActor [weak self] in   // after the forget has left
                try? await Task.sleep(nanoseconds: 1_000_000_000); self?.t.drop(peer)
            }
        }
        lastError = nil; status = "Forgot \(name)"
        untrust(keys, name: name)
        return told
    }

    private func receiveForget(from peer: MCPeerID, as name: String) {
        guard let key = auth[peer]?.peer?.key else { return }
        auth[peer] = nil
        untrust([key], name: name)
        t.drop(peer)
        lastError = "\(name) unpaired this device"
    }

    /// The identity key: the stored one, a new one only when none is stored, or a stand-in while it can't be read.
    private static func readIdentity() -> (key: Curve25519.KeyAgreement.PrivateKey, unread: Bool) {
        switch CarryIdentityRead.from(CarryKeychain.load("identity")) {
        case .use(let d): if let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d) { return (k, false) }
        case .unread: return (Curve25519.KeyAgreement.PrivateKey(), true)
        case .make: break
        }
        let k = Curve25519.KeyAgreement.PrivateKey()
        CarryKeychain.save(k.rawRepresentation, "identity")
        return (k, false)
    }

    static let unreadable = "the Keychain could not be read: pairings are kept as they were, nothing is saved until it can be"

    /// Invariant 13: writes peers.v2 only when it was read (or is truly absent); never over pairings it could not see.
    private func saveTrust(_ list: [CarryPeer]) -> Bool {
        guard trustWritable, !identityUnread else { lastError = Self.unreadable; return false }
        guard let d = try? JSONEncoder().encode(list), CarryKeychain.save(d, "peers.v2") else {
            lastError = "saving the trust store failed"; return false
        }
        return true
    }

    private func untrust(_ keys: Set<Data>, name: String) {
        guard saveTrust(keys.reduce(peers) { CarryTrust.forgetting($0, key: $1) }) else { return }
        try? JSONEncoder().encode(keys.reduce(mirror) { CarryTrust.forgetting($0, key: $1) }).write(to: peersURL, options: .atomic)
        refusedNames.remove(name)
        for (k, w) in waiting where w.peer == name { waiting[k] = nil; pendingActions[k] = nil; discardStaged(k) }
        reloadFromDisk()
    }

    // MARK: Automatic carry (FEAT-09 P4, T-0084): connect, a change, the front; never on the main thread's time

    private var pairedConnected: [MCPeerID] {
        t.session.connectedPeers.filter { trustedName($0) != nil }   // SEC-02: proven keys, never names
    }

    /// The app came to the front (iOS scenePhase .active).
    func cameToFront() {
        if identityUnread { reloadFromDisk() }   // invariant 19: iOS before first unlock; read the key again
        trigger(.foreground)
    }

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
    /// SEC-02: trust is the Keychain's `peers.v2`; peers.json is only the mirror, so its old entries need pairing again.
    func reloadFromDisk() {
        if identityUnread, auth.isEmpty, flows.isEmpty {   // invariant 19: read the real key again, then use it
            let id = Self.readIdentity()
            if !id.unread {
                identity = id.key; identityUnread = false
                if wantsLink { start() }
            }
        }
        mirror = (try? Data(contentsOf: peersURL)).flatMap { try? JSONDecoder().decode([CarryPeer].self, from: $0) } ?? []
        let trust = CarryTrust.load(CarryKeychain.load("peers.v2"), mirror: mirror, previous: peers)   // invariant 13
        trustWritable = trust.writable
        if trust.trusted != peers { peers = trust.trusted }
        if trust.writable {   // invariant 13: a failed read keeps the list as it was
            let names = CarryTrust.listed(needsPairing: trust.needsPairing, refused: refusedNames, trusted: trust.trusted)   // invariant 16
            if names != needsPairing { needsPairing = names }
        }
        let g = CarryKeychain.load("group")
        if let d = g.data { group = d }
        if g.failed != groupUnread { groupUnread = g.failed }   // a failed read keeps the last group, refuses pairing
        let unread = !trustWritable || groupUnread || identityUnread
        if unread { lastError = Self.unreadable } else if lastError == Self.unreadable { lastError = nil }   // recovered
    }

    private func startFlow(_ peer: MCPeerID) {
        guard gate.canPair else { if isLookingToPair { lastError = Self.unreadable }; return }   // invariant 19
        guard isLookingToPair, flows[peer] == nil else { return }
        guard PairPrompt.owns(pairingWith, peer.displayName) else { return }   // T-0120: one prompt at a time
        reloadFromDisk()
        // P1b: the device on which the owner picked the other's name shows the code; the other asks for it
        let f = CarryPairFlow(me: identity, name: P2PTransport.deviceName(), group: group,
                              picked: picked[peer.displayName] != nil)
        flows[peer] = f
        apply(f.start(), peer)
    }

    private func receivePair(_ data: Data, from peer: MCPeerID) {
        guard gate.canPair else { lastError = Self.unreadable; return }   // invariant 19
        guard let m = try? JSONDecoder().decode(PairMessage.self, from: data) else { return }
        if flows[peer] == nil { startFlow(peer) }   // their hello can beat our own `.connected` callback
        guard var f = flows[peer] else { return }
        do {
            let step = try f.receive(m)
            flows[peer] = f
            apply(step, peer)
        } catch PairFailure.outOfOrder {
            // T-0118: a stale or duplicate message (the BUG-17 echo); the flow goes on
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
        // T-0120: the code goes only to the flow that asked for it, never to whichever flow comes first
        guard let peer = flows.keys.first(where: { $0.displayName == pairingWith }),
              var f = flows[peer] else { lastError = "nothing is waiting for a code"; return }
        // T-0119: spoken or any script's digits become ASCII; anything else asks again instead of ending the pairing
        guard let digits = CarryPasskey.normalize(code) else {
            lastError = "That wasn't six digits. Type or say the six digits shown on \(peer.displayName)."; return
        }
        lastError = nil
        do {
            let step = try f.enter(digits)
            flows[peer] = f
            askingCode = false
            status = "Checking the code with \(peer.displayName)"
            apply(step, peer)
        } catch { fail(peer, error) }
    }

    private func apply(_ step: CarryPairFlow.Step, _ peer: MCPeerID) {
        do { for m in step.send { try t.send(m, type: "pair", to: peer) } } catch { fail(peer, error); return }
        guard PairPrompt.owns(pairingWith, peer.displayName) else { return }   // T-0120
        if let c = step.code {
            pairingCode = c; pairingWith = peer.displayName; codeIsCompare = flows[peer]?.passkey == nil
            if !codeIsCompare { status = "Type \(c) on \(peer.displayName)" }
        }
        if step.wantsCode { askingCode = true; pairingWith = peer.displayName }
        if let p = step.paired { finish(peer, p) }
    }

    private func fail(_ peer: MCPeerID, _ error: Error) {
        let e = error as? PairFailure
        // T-0118: tell the peer only when this side really failed; never echo its refusal back
        if e?.tellsPeer ?? true { try? t.send(PairMessage.refuse("\(e.map { "\($0)" } ?? "failed")"), type: "pair", to: peer) }
        flows[peer] = nil
        picked = PairPrompt.failed(picked, peer.displayName)   // T-0123: the next pick alone decides who shows
        guard PairPrompt.owns(pairingWith, peer.displayName) else { return }   // T-0120: another flow's prompt stays
        pairingCode = nil; pairingWith = nil; askingCode = false
        switch e {
        case .otherGroup: lastError = "\(peer.displayName) already belongs to a different pairing; not merged"
        case .badCommit, .refused: lastError = "Code didn't match. Pick \(peer.displayName) again for a new code."
        default: lastError = "pairing with \(peer.displayName) failed: \(error)"
        }
    }

    private func finish(_ peer: MCPeerID, _ p: CarryPairFlow.Paired) {
        reloadFromDisk()   // keep what another process wrote since; replace only this device's entry
        let entry = CarryPeer(name: peer.displayName, key: p.key, paired: Homes.now())
        // SEC-02 §2.1: the trust store first (the Keychain, this device only), then its readable mirror
        var saved = false
        if gate.canPair { saved = saveTrust(CarryPeer.replacing(peers, with: entry)) } else { lastError = Self.unreadable }
        if saved {   // invariants 13, 19: no write over unread pairings; the group only after peers.v2
            group = p.group
            CarryKeychain.save(p.group, "group")
            do { try JSONEncoder().encode(CarryPeer.replacing(mirror, with: entry)).write(to: peersURL, options: .atomic) }
            catch { lastError = "saving peers.json failed: \(error)" }
        }
        refusedNames.remove(entry.name)
        reloadFromDisk()
        flows[peer] = nil
        pairingCode = nil; pairingWith = nil; askingCode = false; isLookingToPair = false; picked = [:]
        status = saved ? "Paired with \(peer.displayName)" : "Pairing with \(peer.displayName) not saved"
        // SEC-02 §2.3: its hello, held while it was a stranger, is answered now; then the 10 s for its proof
        for h in pendingAuth.removeValue(forKey: peer) ?? [] { if let d = try? JSONEncoder().encode(h) { receiveAuth(d, from: peer) } }
        startAuth(peer)
        armAuthTimeout(peer)
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
        guard !peers.isEmpty else { lastError = needsPairing.isEmpty ? "no paired device yet" : Self.pairAgain(needsPairing); return }
        guard !pairedConnected.isEmpty else { lastError = "no paired device is connected right now"; return }
        trigger(.tapped)
    }

    /// One carry. The scan (hashing) runs off the main thread, so playing, reading and writing never wait on it.
    private func carry() async {
        defer { trigger(.finished) }
        reloadFromDisk()
        let targets = pairedConnected
        guard !targets.isEmpty else { return }
        sweepStaging(maxAge: CarrySync.orphanAge)   // T-0092
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
            for peer in targets {
                guard let name = trustedName(peer) else { continue }
                try sendSealed(appliedSeq[name] ?? 0, type: "seen", to: peer)   // SEC-02 §2.4: sealed, counted
            }
            lastCarryAt = Date(); lastError = nil
            status = ops.isEmpty ? "Up to date" : "Settling \(ops.count) change\(ops.count == 1 ? "" : "s")"
            if !waiting.isEmpty { status += " · waiting for \(waiting.count) file\(waiting.count == 1 ? "" : "s")" }   // BUG-19
        } catch { lastError = "carry failed: \(error)" }
    }


    private func receiveSeen(_ data: Data, from peer: MCPeerID, as name: String) {
        guard let since = try? JSONDecoder().decode(Int.self, from: data) else { return }
        var log = myOps()
        if let moved = CarrySync.renumber(log, peerSaw: since) {   // T-0110: this log was reset (a reinstall)
            do { try CarrySync.encode(moved).write(to: opsLogURL(Homes.device), atomically: true, encoding: .utf8); log = moved }
            catch { lastError = "renumbering the carry log failed: \(error)"; return }
        }
        let mine = log.filter { $0.seq > since }
        guard !mine.isEmpty else { return }
        try? sendSealed(mine, type: "ops", to: peer)
        // Each key's bytes once; a key with no bytes left is answered "gone", so the peer stops waiting (BUG-25, T-0108)
        let reply = CarrySync.answer(mine) { FileManager.default.fileExists(atPath: Homes.root.appendingPathComponent($0).path) }
        if !reply.gone.isEmpty { try? sendSealed(reply.gone, type: "gone", to: peer) }
        for key in reply.send {
            t.send(fileAt: Homes.root.appendingPathComponent(key), named: Self.encode(key), to: peer) { [weak self] error in
                if let error { self?.lastError = "sending to \(name) failed: \(error)" }
            }
        }
    }

    /// The peer has no bytes for these keys any more: settle them as done, after the ops sent before them (T-0108).
    private func receiveGone(_ data: Data, as name: String) {
        guard let keys = try? JSONDecoder().decode([String].self, from: data) else { return }
        let before = settling
        settling = Task { [weak self] in
            await before?.value
            guard let self else { return }
            for k in keys where self.waiting[k]?.peer == name {
                self.waiting[k] = nil; self.pendingActions[k] = nil; self.discardStaged(k)
            }
            self.advance(name)
        }
    }

    /// Removes staged bytes that no op waits for (T-0092). maxAge 0 at launch, `CarrySync.orphanAge` before a carry.
    private func sweepStaging(maxAge: TimeInterval) {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let staged = urls.map { (name: $0.lastPathComponent,
                                 modified: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
        let expecting = Set((Array(pendingActions.keys) + placing).map(CarrySync.stagingName))   // invariant 17
        for name in CarrySync.orphans(staged, expecting: expecting, now: Date(), maxAge: maxAge) {
            try? fm.removeItem(at: stagingDir.appendingPathComponent(name))
        }
    }

    /// Ops from a peer, settled in the order they arrive. The scan that decides them (it hashes every file) runs off the
    /// main thread, as `carry()`'s does (T-0107): on a big library it froze the screen and risked iOS's watchdog. One batch
    /// after another, so a later batch never settles before an earlier one.
    private var settling: Task<Void, Never>?
    private func receiveOps(_ data: Data, as name: String) {
        guard let ops = try? JSONDecoder().decode([CarryOp].self, from: data) else { return }
        let before = settling
        settling = Task { [weak self] in
            await before?.value
            guard let lines = try? await Task.detached(priority: .utility, operation: { try Carry.verify(reuse: true) }).value else {
                self?.lastError = "carry verify failed while settling"; return
            }
            self?.settle(ops, local: lines, as: name)
        }
    }

    private func settle(_ ops: [CarryOp], local: [CarryLine], as name: String) {
        let localShas = Dictionary(uniqueKeysWithValues: local.map { (CarrySync.key($0.home, $0.path), $0.sha256) })
        for (op, action) in CarrySync.decideAll(ops, local: localShas, base: [:]) {   // T-0106: in order, on the disk as it will be
            let key = CarrySync.resultKey(op)
            switch action {
            case .nothing: discardStaged(key); pendingActions[key] = nil; waiting[key] = nil
            case .move: do { try CarryApply.apply(action) } catch { lastError = "replaying a move failed: \(error)" }
                        discardStaged(key); pendingActions[key] = nil; waiting[key] = nil
            case .fetch, .replace, .keepBoth:
                pendingActions[key] = action; waiting[key] = (name, op.seq); tryPlace(key)
            case .merge: break   // unreachable with an empty base; text conflicts still settle as keepBoth
            }
        }
        received[name] = max(received[name] ?? 0, ops.map(\.seq).max() ?? 0)
        advance(name)
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

    private func stagedURL(_ key: String) -> URL { stagingDir.appendingPathComponent(CarrySync.stagingName(key)) }   // T-0111
    private func discardStaged(_ key: String) { try? FileManager.default.removeItem(at: stagedURL(key)); stagedFrom[key] = nil }

    /// Places a staged file's bytes once its action is known — whichever of (op, bytes) arrived second.
    /// The actual file-system work is `CarryApply.apply` (shared/carryapply.swift): one implementation, tested
    /// without radios there, called here and (for `.move`, no bytes needed) from `receiveOps` directly.
    /// SEC-02 §2.4: only bytes from the peer whose op waits for them, and only when their SHA-256 is that op's.
    /// The hash runs off the main thread (T-0107), on a copy moved aside so a later arrival cannot swap it meanwhile.
    private func tryPlace(_ key: String) {
        guard let action = pendingActions[key], let w = waiting[key], stagedFrom[key] == w.peer, !placing.contains(key) else { return }
        let staged = stagedURL(key), checking = staged.appendingPathExtension("check")
        try? FileManager.default.removeItem(at: checking)
        guard (try? FileManager.default.moveItem(at: staged, to: checking)) != nil else { return }
        stagedFrom[key] = nil
        placing.insert(key)
        Task { @MainActor [weak self] in
            let sha = (try? await Task.detached(priority: .utility) { try Homes.sha256(checking) }.value) ?? ""
            guard let self else { return }
            self.placing.remove(key)
            defer { try? FileManager.default.removeItem(at: checking) }
            guard self.pendingActions[key] == action, self.waiting[key]?.peer == w.peer else { return }   // settled or forgotten
            do {
                _ = try CarryApply.place(action, bytesAt: checking, sha: sha)
                self.pendingActions[key] = nil
                if let w = self.waiting.removeValue(forKey: key) { self.advance(w.peer) }
            } catch {   // stays owed: the next "seen" asks for it again
                self.lastError = "placing \(key) failed: \(error)"; self.pendingActions[key] = nil
            }
        }
    }

    private func landed(_ url: URL, named name: String, from peer: MCPeerID) {
        guard let who = trustedName(peer) else { try? FileManager.default.removeItem(at: url); return }   // SEC-02: proven peers only
        guard let key = Self.decode(name), CarrySync.safeKey(key) else {
            try? FileManager.default.removeItem(at: url); lastError = "a file from \(who) had no usable name"; return
        }
        let staged = stagedURL(key)
        do {
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: url, to: staged)
        } catch { lastError = "staging from \(who) failed: \(error)"; return }
        stagedFrom[key] = who
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
    fileprivate func receiveOpsForTest(_ data: Data, from peer: MCPeerID) { receiveOps(data, as: peer.displayName) }
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
