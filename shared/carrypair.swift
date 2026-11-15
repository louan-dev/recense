// Derived from Spec: FEAT-09 (P1 pair once)
import Foundation
import CryptoKit

// Pairing by numeric comparison, as Bluetooth's Secure Simple Pairing does it: both devices show the same six digits
// only if nobody sat between them. One side commits to its nonce before it sees the other's, so a device in the middle
// gets one guess in a million instead of grinding keys until the codes match. Pure: messages in, messages out; the
// link (FEAT-02) carries them, the Keychain keeps the keys. No network, no account.

enum PairMessage: Codable, Equatable, Sendable {
    case hello(key: Data, name: String)    // long-term X25519 public key
    case commit(Data)                      // the committer's SHA-256 over its nonce, before seeing the other's
    case nonce(Data)
    case group(Data)                       // the group secret, sealed (ChaChaPoly) after both people tapped "They match"
    case refuse(String)
}

enum PairFailure: Error, Equatable, Sendable {
    case outOfOrder, badCommit, badKey, otherGroup, unsealed
}

struct CarryPairSession {
    let me: Curve25519.KeyAgreement.PrivateKey
    let name: String
    private(set) var theirKey: Data?
    private(set) var theirName: String?
    private var myNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    private var theirNonce: Data?
    private var theirCommit: Data?

    init(me: Curve25519.KeyAgreement.PrivateKey, name: String, nonce: Data? = nil) {
        self.me = me; self.name = name
        if let nonce { myNonce = nonce }
    }

    var myKey: Data { me.publicKey.rawRepresentation }
    /// The side with the greater public key commits; the other reveals first. Both work it out alone.
    var commits: Bool { theirKey.map { myKey.lexicographicallyPrecedes($0) == false } ?? false }

    func hello() -> PairMessage { .hello(key: myKey, name: name) }

    static func commitment(_ committer: Data, _ other: Data, _ nonce: Data) -> Data {
        Data(SHA256.hash(data: Data("recense.pair.commit.v1".utf8) + committer + other + nonce))
    }

    /// Feed one message from the other device; get back what to send (or nothing yet).
    mutating func receive(_ m: PairMessage) throws -> PairMessage? {
        switch m {
        case .hello(let key, let n):
            guard theirKey == nil else { throw PairFailure.outOfOrder }
            guard (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: key)) != nil, key != myKey else { throw PairFailure.badKey }
            theirKey = key; theirName = n
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
        case .group, .refuse:
            throw PairFailure.outOfOrder                           // handled by openGroup / the glue
        }
    }

    private func shared() throws -> SharedSecret {
        guard let k = theirKey, let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: k) else { throw PairFailure.outOfOrder }
        return try me.sharedSecretFromKeyAgreement(with: pub)
    }

    /// Ordered as (key of the side that reveals first, its nonce, committer's key, its nonce): the same bytes on both.
    private func transcript() throws -> Data {
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

/// `Recense/.carry/peers.json`: who is paired. Public keys and names only; no secrets.
struct CarryPeer: Codable, Equatable, Sendable {
    var name: String
    var key: Data
    var paired: String
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
    } catch { check(false, "the pairing exchange ran without error (\(error))") }
    return ok
}
