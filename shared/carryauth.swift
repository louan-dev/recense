// Derived from Spec: SEC-02 (carry peer auth: a paired device proves its key, not its name)
// Pure: messages in, messages out; no radio, no Keychain, CryptoKit only. The glue (carrymanager.swift) keeps one
// CarryAuthSession per connection, sends `hello` on connect, and lets only `pair` and `auth` through until the peer's
// proof checks out. After that every carry message rides `sealed`; a plain `seen`/`ops`/`gone` is dropped.
// The handshake is Noise-KK-like (described, not copied): both long-term keys are known from pairing, both sides add
// a fresh key per session, so a key stolen later cannot open sessions recorded before (forward secrecy).
import Foundation
import CryptoKit

enum CarryAuthMessage: Codable, Equatable, Sendable {
    case hello(key: Data, eph: Data, nonce: Data)   // long-term key, this session's fresh key, 32 random bytes
    case proof(Data)                                // HMAC(kConfirm, tag ‖ role ‖ th)
}

/// `{n, box}`: box = ChaChaPoly(JSON(CarryFrame)) under the sender's direction key, nonce 0x00000000 ‖ n.
struct CarrySealed: Codable, Equatable, Sendable { var n: UInt64; var box: Data }
struct CarryFrame: Codable, Equatable, Sendable { var type: String; var payload: Data }

enum CarryAuthFailure: Error, Equatable, Sendable { case unknownKey, badKey, outOfOrder, badProof, notAuthenticated, replayed, unsealed }

private func carryRandom(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }   // the system's secure generator

private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    a.count == b.count && zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}

/// One connection's handshake and its sealed channel (§2.3, §2.4).
struct CarryAuthSession {
    static let thTag = Data("recense.carry.th.v1".utf8), info = Data("recense.carry.session.v1".utf8)
    static let proofTag = Data("recense.carry.proof.v1".utf8), sealedTag = Data("recense.carry.sealed.v1".utf8)

    let me: Curve25519.KeyAgreement.PrivateKey
    private let eph: Curve25519.KeyAgreement.PrivateKey
    private let nonce: Data
    private(set) var peer: CarryPeer?          // their trust-store entry, once their hello's key is trusted
    private(set) var authenticated = false     // their proof checked out
    private(set) var gotHello = false
    private var th = Data(), role: UInt8 = 0
    private var confirm: SymmetricKey?, sendKey: SymmetricKey?, recvKey: SymmetricKey?
    private var sent: UInt64 = 0, last: UInt64 = 0

    init(me: Curve25519.KeyAgreement.PrivateKey, eph: Curve25519.KeyAgreement.PrivateKey = .init(), nonce: Data? = nil) {
        self.me = me; self.eph = eph; self.nonce = nonce ?? carryRandom(32)
    }

    var myKey: Data { me.publicKey.rawRepresentation }
    var hello: CarryAuthMessage { .hello(key: myKey, eph: eph.publicKey.rawRepresentation, nonce: nonce) }

    /// Their hello → this side's proof; their proof → nil once it checks out. Anything else throws.
    mutating func receive(_ m: CarryAuthMessage, trusted: [CarryPeer]) throws -> CarryAuthMessage? {
        switch m {
        case .hello(let key, let theirEph, let theirNonce):
            guard !gotHello else { throw CarryAuthFailure.outOfOrder }
            guard key != myKey, theirNonce.count == 32,
                  let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: key),
                  let ephPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirEph) else { throw CarryAuthFailure.badKey }
            guard let p = trusted.first(where: { $0.key == key }) else { throw CarryAuthFailure.unknownKey }
            guard let ss = try? me.sharedSecretFromKeyAgreement(with: pub),
                  let es = try? eph.sharedSecretFromKeyAgreement(with: ephPub) else { throw CarryAuthFailure.badKey }
            gotHello = true
            let ikm = ss.withUnsafeBytes { Data($0) } + es.withUnsafeBytes { Data($0) }
            let mine = myKey + eph.publicKey.rawRepresentation + nonce, theirs = key + theirEph + theirNonce
            let low = myKey.lexicographicallyPrecedes(key)           // ordered by static key bytes: the same on both sides
            role = low ? 0 : 1
            th = Data(SHA256.hash(data: Self.thTag + (low ? mine + theirs : theirs + mine)))
            let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: th, info: Self.info, outputByteCount: 96)
                .withUnsafeBytes { Data($0) }
            let kConfirm = SymmetricKey(data: okm.prefix(32)), lowHigh = SymmetricKey(data: okm.dropFirst(32).prefix(32)),
                highLow = SymmetricKey(data: okm.suffix(32))
            confirm = kConfirm; sendKey = low ? lowHigh : highLow; recvKey = low ? highLow : lowHigh
            peer = p
            return .proof(Data(HMAC<SHA256>.authenticationCode(for: Self.proofTag + Data([role]) + th, using: kConfirm)))
        case .proof(let mac):
            guard let confirm, peer != nil, !authenticated else { throw CarryAuthFailure.outOfOrder }
            guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Self.proofTag + Data([role ^ 1]) + th, using: confirm)
            else { throw CarryAuthFailure.badProof }
            authenticated = true
            return nil
        }
    }

    private static func nonce(_ n: UInt64) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: Data(count: 4) + withUnsafeBytes(of: n.bigEndian) { Data($0) })   // 12 bytes, always valid
    }

    /// Only once their proof checked out: nothing is ever sent to a peer that has not proven its key.
    mutating func seal(_ type: String, _ payload: Data) throws -> CarrySealed {
        guard authenticated, let sendKey else { throw CarryAuthFailure.notAuthenticated }
        sent += 1
        let body = try JSONEncoder().encode(CarryFrame(type: type, payload: payload))
        let box = try ChaChaPoly.seal(body, using: sendKey, nonce: Self.nonce(sent), authenticating: Self.sealedTag)
        return CarrySealed(n: sent, box: box.ciphertext + box.tag)
    }

    /// A frame opens once, in order (n > last), with the other direction's key; a failed one never moves the counter.
    mutating func open(_ s: CarrySealed) throws -> CarryFrame {
        guard authenticated, let recvKey else { throw CarryAuthFailure.notAuthenticated }
        guard s.n > last else { throw CarryAuthFailure.replayed }
        let box = Data(s.box)
        guard box.count >= 16,
              let sb = try? ChaChaPoly.SealedBox(nonce: Self.nonce(s.n), ciphertext: box.dropLast(16), tag: box.suffix(16)),
              let body = try? ChaChaPoly.open(sb, using: recvKey, authenticating: Self.sealedTag),
              let f = try? JSONDecoder().decode(CarryFrame.self, from: body) else { throw CarryAuthFailure.unsealed }
        last = s.n
        return f
    }
}

/// §2.2 · the invitation's context: a pre-filter only (a replayed context gets a connection, then fails the handshake).
enum CarryInvite {
    static func context(me: Curve25519.KeyAgreement.PrivateKey, peer: Data, nonce: Data = carryRandom(16)) throws -> Data {
        me.publicKey.rawRepresentation + nonce + (try CarryPairSession.invitationProof(me: me, peer: peer, nonce: nonce))
    }

    /// The trusted peer this context comes from, or nil: then no auto-accept (pairing mode may still ask the owner).
    static func accepts(_ context: Data?, me: Curve25519.KeyAgreement.PrivateKey, trusted: [CarryPeer]) -> CarryPeer? {
        guard let c = context.map({ Data($0) }), c.count == 80 else { return nil }
        let key = Data(c.prefix(32)), nonce = Data(c.dropFirst(32).prefix(16)), proof = Data(c.suffix(32))
        guard let p = trusted.first(where: { $0.key == key }),
              let want = try? CarryPairSession.invitationProof(me: me, peer: key, nonce: nonce),
              constantTimeEqual(want, proof) else { return nil }
        return p
    }
}

/// §2.1, §2.6 · the trust store (Keychain `local.recense.carry` / `peers.v2`) decides trust; peers.json is a mirror.
enum CarryTrust {
    /// No peers.v2 yet (the first launch with SEC-02) or one that can't be read: nobody is trusted. Mirror entries
    /// without a trusted key are listed "Pair again to keep carrying"; their files, logs and appliedSeq stay as they are.
    static func load(v2: Data?, mirror: [CarryPeer]) -> (trusted: [CarryPeer], needsPairing: [CarryPeer]) {
        let trusted = v2.flatMap { try? JSONDecoder().decode([CarryPeer].self, from: $0) } ?? []
        return (trusted, mirror.filter { m in !trusted.contains { $0.key == m.key } })
    }

    static func forgetting(_ list: [CarryPeer], key: Data) -> [CarryPeer] { list.filter { $0.key != key } }
}
