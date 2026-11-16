// Derived from Spec: FEAT-09 (P1 pair once)
import Foundation
import CryptoKit

// Pairing by numeric comparison, as Bluetooth's Secure Simple Pairing does it: both devices show the same six digits
// only if nobody sat between them. One side commits to its nonce before it sees the other's, so a device in the middle
// gets one guess in a million instead of grinding keys until the codes match. Pure: messages in, messages out; the
// link (FEAT-02) carries them, the Keychain keeps the keys. No network, no account.

enum PairMessage: Codable, Equatable, Sendable {
    case hello(key: Data, name: String, grouped: Bool? = nil, picked: Bool? = nil)   // long-term X25519 public key; grouped = already holds a
                                                                // group secret (BUG-17: decides which one side sends it)
    case commit(Data)                      // the committer's SHA-256 over its nonce, before seeing the other's
    case nonce(Data)
    case group(Data)                       // the group secret, sealed (ChaChaPoly) after both people tapped "They match"
    case refuse(String)
    case sameGroup(Data)                   // both already hold a group: its keyed fingerprint, never the secret (BUG-17)
    case passkeyCommit(round: Int, commit: Data)   // P1b: one bit of the typed code, committed (CarryPasskey)
    case passkeyNonce(round: Int, nonce: Data)     // P1b: the nonce that opens it
}

enum PairFailure: Error, Equatable, Sendable {
    case outOfOrder, badCommit, badKey, otherGroup, unsealed, refused
}

struct CarryPairSession {
    let me: Curve25519.KeyAgreement.PrivateKey
    let name: String
    private(set) var theirKey: Data?
    private(set) var theirName: String?
    private(set) var theirGrouped = false
    private var myNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    private var theirNonce: Data?
    private var theirCommit: Data?
    private var adopted: Data?          // P1b: the passkey rounds' transcript stands in for the nonces

    init(me: Curve25519.KeyAgreement.PrivateKey, name: String, nonce: Data? = nil) {
        self.me = me; self.name = name
        if let nonce { myNonce = nonce }
    }

    var myKey: Data { me.publicKey.rawRepresentation }
    /// The side with the greater public key commits; the other reveals first. Both work it out alone.
    var commits: Bool { theirKey.map { myKey.lexicographicallyPrecedes($0) == false } ?? false }

    func hello(grouped: Bool = false, picked: Bool? = nil) -> PairMessage {
        .hello(key: myKey, name: name, grouped: grouped, picked: picked)
    }

    /// P1b: after the 20 passkey rounds, their transcript keys the group seal and fingerprint (HKDF salt).
    mutating func adopt(transcript t: Data) { adopted = t }

    static func commitment(_ committer: Data, _ other: Data, _ nonce: Data) -> Data {
        Data(SHA256.hash(data: Data("recense.pair.commit.v1".utf8) + committer + other + nonce))
    }

    /// Feed one message from the other device; get back what to send (or nothing yet).
    mutating func receive(_ m: PairMessage) throws -> PairMessage? {
        switch m {
        case .hello(let key, let n, let grouped, _):
            if let k = theirKey { if k == key { return nil }; throw PairFailure.outOfOrder }   // the same hello again: ignored (BUG-17 echo)
            guard (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: key)) != nil, key != myKey else { throw PairFailure.badKey }
            theirKey = key; theirName = n; theirGrouped = grouped ?? false
            return commits ? .commit(Self.commitment(myKey, key, myNonce)) : nil
        case .commit(let c):
            guard theirKey != nil, !commits, theirCommit == nil else { throw PairFailure.outOfOrder }
            theirCommit = c
            return .nonce(myNonce)                                 // revealed only after their commitment arrived
        case .nonce(let n):
            guard let k = theirKey, theirNonce == nil else { throw PairFailure.outOfOrder }
            if commits { theirNonce = n; return .nonce(myNonce) }
            guard let c = theirCommit, Self.commitment(k, myKey, n) == c else { throw PairFailure.badCommit }
            theirNonce = n
            return nil
        case .group, .refuse, .sameGroup, .passkeyCommit, .passkeyNonce:
            throw PairFailure.outOfOrder                           // handled by openGroup / CarryPasskey / the glue
        }
    }

    private func shared() throws -> SharedSecret {
        guard let k = theirKey, let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: k) else { throw PairFailure.outOfOrder }
        return try me.sharedSecretFromKeyAgreement(with: pub)
    }

    /// Ordered as (key of the side that reveals first, its nonce, committer's key, its nonce): the same bytes on both.
    private func transcript() throws -> Data {
        if let adopted { return adopted }
        guard let k = theirKey, let n = theirNonce else { throw PairFailure.outOfOrder }
        return commits ? k + n + myKey + myNonce : myKey + myNonce + k + n
    }

    /// The six digits both screens show. Nil until both nonces are in.
    func code() -> String? {
        guard let t = try? transcript(), let s = try? shared() else { return nil }
        let h = Array(SHA256.hash(data: Data("recense.pair.v1".utf8) + t + s.withUnsafeBytes { Data($0) }))
        let n = (UInt32(h[0]) << 24 | UInt32(h[1]) << 16 | UInt32(h[2]) << 8 | UInt32(h[3])) % 1_000_000
        return String(format: "%06u", n)
    }

    private func groupKey() throws -> SymmetricKey {
        try shared().hkdfDerivedSymmetricKey(using: SHA256.self, salt: try transcript(),
                                    sharedInfo: Data("recense.group.v1".utf8), outputByteCount: 32)
    }

    /// After both people tapped "They match": who sends the group secret, and what. Rules: the one that has it sends;
    /// if neither has one, the committer makes it; two different groups never merge (refused).
    func offerGroup(mine: Data?, theirsExists: Bool) throws -> (message: PairMessage, secret: Data)? {
        switch (mine, theirsExists) {
        case (let g?, false): return (.group(try ChaChaPoly.seal(g, using: groupKey()).combined), g)
        case (nil, false) where commits:
            let g = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            return (.group(try ChaChaPoly.seal(g, using: groupKey()).combined), g)
        case (_?, true): throw PairFailure.otherGroup              // both already belong somewhere: see verifyGroup
        default: return nil                                        // wait for theirs
        }
    }

    func openGroup(_ m: PairMessage) throws -> Data {
        guard case .group(let sealed) = m else { throw PairFailure.outOfOrder }
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed),
              let g = try? ChaChaPoly.open(box, using: groupKey()) else { throw PairFailure.unsealed }
        return g
    }

    /// Both devices already hold a group secret: they may pair only if it is the same group. Compared by a keyed
    /// fingerprint, so neither secret crosses the link.
    func groupFingerprint(_ g: Data) throws -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("recense.group.same.v1".utf8) + (try transcript()), using: SymmetricKey(data: g)))
    }

    /// The proof a paired device puts in its invitation: this nonce, keyed by our pairwise secret. A device not in
    /// peers.json can't make it (FEAT-09 P1 invariant).
    static func invitationProof(me: Curve25519.KeyAgreement.PrivateKey, peer: Data, nonce: Data) throws -> Data {
        guard let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer) else { throw PairFailure.badKey }
        let k = try me.sharedSecretFromKeyAgreement(with: pub)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("recense.invite.v1".utf8), outputByteCount: 32)
        return Data(HMAC<SHA256>.authenticationCode(for: nonce, using: k))
    }
}

// Derived from Spec: BUG-17 (FEAT-09 P1, both sides finish)
/// One side's whole pairing, the owner's tap included. Pure: the glue (carrymanager.swift) sends `send`, shows
/// `code`, and saves `paired`. Two rules BUG-17 found missing:
/// - their sealed group may arrive before this side's own "They match": hold it, open it on the tap — never drop it,
///   never accept it without the tap;
/// - `hello` says who already holds a group, so exactly one side sends one (the holder, else the committer).
struct CarryPairFlow {
    struct Paired: Equatable { let key: Data; let name: String; let group: Data }
    struct Step: Equatable {
        var send: [PairMessage] = []
        var code: String?           // show these six digits
        var wantsCode = false       // P1b: ask the owner to type the code shown on the other device
        var paired: Paired?
    }

    private(set) var session: CarryPairSession
    let mine: Data?                         // this device's group secret, if it already has one
    private(set) var confirmed = false
    private(set) var done = false
    private var held: PairMessage?          // their sealed group, waiting for this side's own tap
    private var codeShown = false
    private var echoed = false              // our hello sent again on the first of theirs (BUG-17)
    let picked: Bool?                       // P1b: the owner picked the other's name here; nil = an older build
    private(set) var passkey: CarryPasskey?   // P1b: set once both hellos carry `picked`

    init(me: Curve25519.KeyAgreement.PrivateKey, name: String, group: Data?, nonce: Data? = nil, picked: Bool? = nil) {
        session = CarryPairSession(me: me, name: name, nonce: nonce); mine = group; self.picked = picked
    }

    private var hello: PairMessage { session.hello(grouped: mine != nil, picked: picked) }
    func start() -> Step { Step(send: [hello]) }

    /// Both sides authenticated: by the six digits both people compared (P1), or by the 20 passkey rounds (P1b).
    private var ready: Bool { passkey.map(\.finished) ?? (session.code() != nil) }

    /// P1b: the owner typed the code shown on the other device. Typing starts the rounds.
    mutating func enter(_ code: String) throws -> Step {
        guard !done, var p = passkey, !p.shows else { throw PairFailure.outOfOrder }
        let out = try p.enter(code)
        passkey = p
        return Step(send: out)
    }

    mutating func receive(_ m: PairMessage) throws -> Step {
        guard !done else { throw PairFailure.outOfOrder }
        switch m {
        case .refuse: throw PairFailure.refused
        case .group, .sameGroup:
            guard ready, held == nil else { throw PairFailure.outOfOrder }
            if confirmed { return try open(m) }
            held = m
            return Step()
        default:
            var step = Step()
            // Already connected when one side started: its first hello reached a device that was not looking yet and
            // was dropped. Answering the first hello with ours again, ahead of anything else, means each side always
            // gets the other's hello first; the copy that did arrive is ignored (owner's iPad, 11-15 17:4x).
            if case .hello = m, !echoed { echoed = true; step.send.append(hello) }
            if case .passkeyCommit = m { return try round(m) }
            if case .passkeyNonce = m { return try round(m) }
            let reply = try session.receive(m)
            if case .hello(_, _, _, let theirs) = m, passkey == nil, let picked, let theirs, let k = session.theirKey {
                // P1b: the side the owner picked on shows; both or neither → the greater key shows. Both decide alone.
                let shows = picked != theirs ? picked : !session.myKey.lexicographicallyPrecedes(k)
                var p = CarryPasskey(shows: shows, myKey: session.myKey, theirKey: k)
                if shows { step.code = p.codeText; step.send.append(p.open()) } else { step.wantsCode = true }
                passkey = p
                return step
            }
            if passkey != nil { return step }       // numeric comparison's own messages are not used in P1b
            if let reply { step.send.append(reply) }
            if !codeShown, let c = session.code() { codeShown = true; step.code = c }
            return step
        }
    }

    /// P1b: one passkey message; after round 20 this side confirms by itself (no tap: the typed code was the tap).
    private mutating func round(_ m: PairMessage) throws -> Step {
        guard var p = passkey else { throw PairFailure.outOfOrder }
        let out = try p.receive(m)
        passkey = p
        guard p.finished else { return Step(send: out) }
        session.adopt(transcript: p.transcript)
        var step = try confirm()
        step.send = out + step.send          // the last nonce goes before any group
        return step
    }

    /// The owner tapped "They match" on this screen (P1), or the passkey rounds finished (P1b).
    mutating func confirm() throws -> Step {
        guard !done, ready else { throw PairFailure.outOfOrder }
        if confirmed { return Step() }             // a second tap while waiting for theirs changes nothing
        confirmed = true
        if let mine, session.theirGrouped {   // both already in a group: the same one pairs, a different one is refused
            let step = Step(send: [.sameGroup(try session.groupFingerprint(mine))])
            guard let h = held else { return step }
            var opened = try open(h); opened.send = step.send
            return opened
        }
        if let h = held { return try open(h) }
        guard let offer = try session.offerGroup(mine: mine, theirsExists: session.theirGrouped) else { return Step() }
        done = true
        return Step(send: [offer.message], paired: Paired(key: session.theirKey!, name: session.theirName ?? "", group: offer.secret))
    }

    private mutating func open(_ m: PairMessage) throws -> Step {
        if case .sameGroup(let theirs) = m {
            guard let mine, try session.groupFingerprint(mine) == theirs else { throw PairFailure.otherGroup }
            done = true
            return Step(paired: Paired(key: session.theirKey!, name: session.theirName ?? "", group: mine))
        }
        guard mine == nil else { throw PairFailure.otherGroup }   // two groups never merge (FEAT-09 P1)
        let g = try session.openGroup(m)
        done = true
        return Step(paired: Paired(key: session.theirKey!, name: session.theirName ?? "", group: g))
    }
}

// Derived from Spec: FEAT-09 P1b (pair by typing the code, T-0086)
/// Passkey entry, as Bluetooth LE Secure Connections does it (described, not copied): the shower draws six random
/// digits r < 10^6 < 2^20; for each bit r_i both sides commit with a fresh nonce, C = HMAC_N("recense.passkey.v1" ‖
/// PK_shower ‖ PK_typer ‖ r_i), then reveal: shower's commit, typer's commit, shower's nonce (typer checks), typer's
/// nonce (shower checks). A device in the middle must guess each bit before it is revealed. Pure; no radios.
struct CarryPasskey {
    static let rounds = 20
    static let tag = Data("recense.passkey.v1".utf8)
    let shows: Bool
    private let showerKey: Data, typerKey: Data
    private(set) var code: UInt32?
    private(set) var round = 0
    private(set) var finished = false
    private var myNonce = Data()
    private var theirCommit: Data?
    private var committed = false        // this side's commit for `round` is sent
    private var log = Data()             // every round's nonces, shower's first

    init(shows: Bool, myKey: Data, theirKey: Data) {
        self.shows = shows
        showerKey = shows ? myKey : theirKey; typerKey = shows ? theirKey : myKey
        if shows { code = UInt32.random(in: 0..<1_000_000) }   // fresh every attempt; the system's secure generator
    }

    var codeText: String? { code.map { String(format: "%06u", $0) } }
    var transcript: Data { Data(SHA256.hash(data: Data("recense.passkey.transcript.v1".utf8) + showerKey + typerKey + log)) }

    static func commitment(_ nonce: Data, shower: Data, typer: Data, bit: UInt8) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: tag + shower + typer + Data([bit]), using: SymmetricKey(data: nonce)))
    }

    private func bit(_ i: Int) -> UInt8 { UInt8((code! >> UInt32(i)) & 1) }

    private mutating func commit() -> PairMessage {
        myNonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        committed = true
        return .passkeyCommit(round: round, commit: Self.commitment(myNonce, shower: showerKey, typer: typerKey, bit: bit(round)))
    }

    /// The shower's first commitment, sent as soon as it knows the typer's key.
    mutating func open() -> PairMessage { commit() }

    /// The typer's six digits. Anything else is refused before a bit is spent.
    mutating func enter(_ text: String) throws -> [PairMessage] {
        guard !shows, code == nil else { throw PairFailure.outOfOrder }
        let digits = text.filter { !$0.isWhitespace }
        guard digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let v = UInt32(digits) else {
            throw PairFailure.badCommit
        }
        code = v
        return theirCommit != nil && !committed ? [commit()] : []
    }

    mutating func receive(_ m: PairMessage) throws -> [PairMessage] {
        guard !finished else { throw PairFailure.outOfOrder }
        switch m {
        case .passkeyCommit(let r, let c):
            guard r == round, theirCommit == nil, shows == committed else { throw PairFailure.outOfOrder }
            theirCommit = c
            if shows { return [.passkeyNonce(round: round, nonce: myNonce)] }   // revealed only after theirs is in
            return code != nil ? [commit()] : []                                  // the typer waits for the typed code
        case .passkeyNonce(let r, let n):
            guard r == round, let c = theirCommit, committed, code != nil else { throw PairFailure.outOfOrder }
            guard Self.commitment(n, shower: showerKey, typer: typerKey, bit: bit(round)) == c else { throw PairFailure.badCommit }
            var out: [PairMessage] = []
            log += shows ? myNonce + n : n + myNonce            // shower's nonce first, the same bytes on both
            if !shows { out.append(.passkeyNonce(round: round, nonce: myNonce)) }
            round += 1; theirCommit = nil; committed = false
            if round == Self.rounds { finished = true; return out }
            if shows { out.append(commit()) }
            return out
        default: throw PairFailure.outOfOrder
        }
    }
}

// Derived from Spec: BUG-17 (either device may start first)
/// A picked device that turned the invitation down (it was not looking yet) or let it lapse is invited again, so
/// the owner can start on either device first: no window to race. Pure: which picked names are due now.
enum CarryInvites {
    static let every: TimeInterval = 11   // past P2PTransport.invite's 10 s timeout, so two never overlap

    static func due(picked: [String: Date], nearby: Set<String>, connected: Set<String>, now: Date) -> [String] {
        picked.filter { nearby.contains($0.key) && !connected.contains($0.key) && now.timeIntervalSince($0.value) >= every }
            .keys.sorted()
    }

    /// Owner rule (BUG-17): each device shows once in the pair list. Two advertisers with one name (a second Recense
    /// process on the same Mac) collapse to the newest one found, which is the one still answering.
    static func newestPerName<T>(_ items: [T], name: (T) -> String) -> [T] {
        var seen = Set<String>(), out: [T] = []
        for i in items.reversed() where seen.insert(name(i)).inserted { out.append(i) }
        return out.reversed()
    }
}

/// `Recense/.carry/peers.json`: who is paired. Public keys and names only; no secrets.
struct CarryPeer: Codable, Equatable, Sendable {
    var name: String
    var key: Data
    var paired: String

    // Derived from Spec: BUG-17 (two processes, one file)
    /// A re-pair replaces the entry with the same name or key; every other entry — including one another process
    /// (the Terminal's `recense carry pair`) wrote since this one last read the file — is kept.
    static func replacing(_ list: [CarryPeer], with new: CarryPeer) -> [CarryPeer] {
        list.filter { $0.name != new.name && $0.key != new.key } + [new]
    }
}

// Regression guard: FEAT-09 P1 (the full suite lives in mobile/ios/Tests/carrypair/main.swift; this is the
// condensed version `recense selftest` can run with no radios).
func carrypairSelftest() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String) { print("\(pass ? "ok  " : "FAIL") carrypair, \(what)"); ok = ok && pass }
    var a = CarryPairSession(me: Curve25519.KeyAgreement.PrivateKey(), name: "Mac")
    var b = CarryPairSession(me: Curve25519.KeyAgreement.PrivateKey(), name: "iPad")
    do {
        var toB: [PairMessage] = [a.hello()], toA: [PairMessage] = [b.hello()]
        while !toA.isEmpty || !toB.isEmpty {
            if !toB.isEmpty, let r = try b.receive(toB.removeFirst()) { toA.append(r) }
            if !toA.isEmpty, let r = try a.receive(toA.removeFirst()) { toB.append(r) }
        }
        check(a.code() != nil && a.code() == b.code() && a.code()?.count == 6, "both sides show the same six-digit code")
        let g = Data(repeating: 7, count: 32)
        let (msg, _) = try a.offerGroup(mine: g, theirsExists: false)!
        check(try b.openGroup(msg) == g, "the group secret arrives sealed and opens on the other side")
        let nonce = Data("n".utf8)
        let p1 = try CarryPairSession.invitationProof(me: a.me, peer: b.myKey, nonce: nonce)
        let p2 = try CarryPairSession.invitationProof(me: b.me, peer: a.myKey, nonce: nonce)
        check(p1 == p2, "an invitation's proof is the same computed from either side")
        // Regression guard: BUG-17 — the side that waits for the group must finish too, after its own tap.
        var fa = CarryPairFlow(me: Curve25519.KeyAgreement.PrivateKey(), name: "Mac", group: g)
        var fb = CarryPairFlow(me: Curve25519.KeyAgreement.PrivateKey(), name: "iPhone", group: nil)
        var qb = fa.start().send, qa = fb.start().send
        while !qa.isEmpty || !qb.isEmpty {
            if !qb.isEmpty { qa += try fb.receive(qb.removeFirst()).send }
            if !qa.isEmpty { qb += try fa.receive(qa.removeFirst()).send }
        }
        let sent = try fa.confirm()
        var got: CarryPairFlow.Paired?
        for m in sent.send { got = try fb.receive(m).paired ?? got }
        let tapped = try fb.confirm()
        check(sent.paired != nil && got == nil && tapped.paired?.group == g, "the waiting side holds the group until its own tap, then pairs")
        // P1b: the side that picked shows six digits; typing them on the other pairs both; a wrong code pairs neither
        for wrong in [false, true] {
            var ps = CarryPairFlow(me: Curve25519.KeyAgreement.PrivateKey(), name: "Mac", group: g, picked: true)
            var pt = CarryPairFlow(me: Curve25519.KeyAgreement.PrivateKey(), name: "iPad", group: nil, picked: false)
            var toT = ps.start().send, toS = pt.start().send
            var code: String?, asks = false, done: [CarryPairFlow.Paired] = [], refused = false
            func run() {
                while !refused && (!toT.isEmpty || !toS.isEmpty) {
                    do {
                        if !toT.isEmpty { let st = try pt.receive(toT.removeFirst()); toS += st.send; asks = asks || st.wantsCode; if let p = st.paired { done.append(p) } }
                        if !toS.isEmpty { let st = try ps.receive(toS.removeFirst()); toT += st.send; code = st.code ?? code; if let p = st.paired { done.append(p) } }
                    } catch { refused = true }
                }
            }
            run()
            if let c = code, asks {
                let typed = wrong ? String(format: "%06d", (Int(c)! + 1) % 1_000_000) : c
                if let st = try? pt.enter(typed) { toS += st.send } else { refused = true }
                run()
            }
            if wrong { check(done.isEmpty && refused, "typed code: a wrong code is refused, neither pairs") }
            else { check(code != nil && asks && done.count == 2 && done.allSatisfy { $0.group == g }, "typed code: the right code pairs both, one group") }
        }
    } catch { check(false, "the pairing exchange ran without error (\(error))") }
    return ok
}
