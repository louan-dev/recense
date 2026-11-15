// Derived from Spec: FEAT-09 P1 · pairing by numeric comparison, no radios.
// swiftc -O shared/carrypair.swift mobile/ios/Tests/carrypair/main.swift -o "$TMPDIR/carrypair" && "$TMPDIR/carrypair"
import Foundation
import CryptoKit

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { failed += 1; print("FAIL L\(line): \(what)") } }
typealias Key = Curve25519.KeyAgreement.PrivateKey

/// Runs the whole exchange between two sessions, as the link would.
func run(_ a: inout CarryPairSession, _ b: inout CarryPairSession) throws {
    var toB: [PairMessage] = [a.hello()], toA: [PairMessage] = [b.hello()]
    while !toA.isEmpty || !toB.isEmpty {
        if !toB.isEmpty { if let r = try b.receive(toB.removeFirst()) { toA.append(r) } }
        if !toA.isEmpty { if let r = try a.receive(toA.removeFirst()) { toB.append(r) } }
    }
}

// two honest devices show the same six digits
do {
    var a = CarryPairSession(me: Key(), name: "Mac"), b = CarryPairSession(me: Key(), name: "iPad")
    try run(&a, &b)
    check(a.code() != nil && a.code() == b.code(), "same code: \(a.code() ?? "nil") \(b.code() ?? "nil")")
    check(a.code()?.count == 6 && a.code()!.allSatisfy(\.isNumber), "six digits")
    check(a.commits != b.commits, "exactly one side commits")
    check(a.theirName == "iPad" && b.theirName == "Mac", "names exchanged")
    // a fresh run makes a fresh code (new nonces)
    var a2 = CarryPairSession(me: a.me, name: "Mac"), b2 = CarryPairSession(me: b.me, name: "iPad")
    try run(&a2, &b2)
    check(a2.code() == b2.code(), "second pairing also matches")

    // the group secret: the side that has it sends it, sealed; the other opens it
    let g = Data(repeating: 7, count: 32)
    let (msg, sent) = try a.offerGroup(mine: g, theirsExists: false)!
    check(sent == g, "the holder sends its own group")
    check(try b.openGroup(msg) == g, "the other opens the same group")
    if case .group(let sealed) = msg { check(!sealed.contains(g), "the secret never crosses in the clear") }
    // a third party with the sealed message can't open it
    var c = CarryPairSession(me: Key(), name: "x"), d = CarryPairSession(me: Key(), name: "y")
    try run(&c, &d)
    check((try? c.openGroup(msg)) == nil, "another pair can't open it")
    // neither has one: only the committer makes it
    let committer = a.commits ? a : b, other = a.commits ? b : a
    check(try other.offerGroup(mine: nil, theirsExists: false) == nil, "the revealer waits")
    let made = try committer.offerGroup(mine: nil, theirsExists: false)!
    check(try other.openGroup(made.message) == made.secret && made.secret.count == 32, "the committer makes and sends a new group")
    // both already in a group: compare fingerprints, never the secrets
    check(try a.groupFingerprint(g) == b.groupFingerprint(g), "same group → same fingerprint")
    check(try a.groupFingerprint(g) != b.groupFingerprint(Data(repeating: 8, count: 32)), "different groups → different fingerprints")
    do { _ = try a.offerGroup(mine: g, theirsExists: true); check(false, "two groups must be refused") }
    catch { check(error as? PairFailure == .otherGroup, "two groups refused") }

    // invitations: only a paired device can prove the nonce
    let nonce = Data("n-1".utf8)
    let p1 = try CarryPairSession.invitationProof(me: a.me, peer: b.myKey, nonce: nonce)
    let p2 = try CarryPairSession.invitationProof(me: b.me, peer: a.myKey, nonce: nonce)
    check(p1 == p2, "both sides compute the same proof")
    let stranger = try CarryPairSession.invitationProof(me: Key(), peer: b.myKey, nonce: nonce)
    check(stranger != p2, "a device not in peers.json can't make the proof")
}

// a device in the middle: it must reveal before seeing the honest committer's nonce, so it can't steer the code
do {
    // Honest A ↔ M (posing as B) and M (posing as A) ↔ honest B. M picks its keys and nonces freely,
    // but must commit (or reveal) before learning each honest side's nonce. Count how often the two codes agree.
    var agree = 0
    let tries = 300
    for _ in 0..<tries {
        var a = CarryPairSession(me: Key(), name: "A"), m1 = CarryPairSession(me: Key(), name: "B")
        var m2 = CarryPairSession(me: Key(), name: "A"), b = CarryPairSession(me: Key(), name: "B")
        try run(&a, &m1); try run(&m2, &b)
        if a.code() == b.code() { agree += 1 }
    }
    check(agree == 0, "in the middle, codes agree only by 1-in-a-million chance (\(agree)/\(tries))")
}

do {
    var r = CarryPairSession(me: Key(), name: "R"), c = CarryPairSession(me: Key(), name: "C")
    if r.myKey.lexicographicallyPrecedes(c.myKey) == false { swap(&r, &c) }   // r reveals, c commits
    _ = try r.receive(c.hello())
    let commit = try c.receive(r.hello())!
    let reveal = try r.receive(commit)!
    _ = try c.receive(reveal)
    do { _ = try c.receive(r.hello()); check(false, "second hello must fail") }
    catch { check(error as? PairFailure == .outOfOrder, "a second hello is out of order") }
    do { _ = try r.receive(.nonce(Data(repeating: 1, count: 32))); check(false, "forged nonce must fail") }
    catch { check(error as? PairFailure == .badCommit, "a nonce that doesn't match the commitment is refused") }
    do { var z = CarryPairSession(me: Key(), name: "z"); _ = try z.receive(.hello(key: Data([1, 2, 3]), name: "bad")); check(false, "bad key") }
    catch { check(error as? PairFailure == .badKey, "a malformed key is refused") }
}

// peers.json carries no secrets
do {
    let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
    let s = String(decoding: try e.encode(CarryPeer(name: "iPad", key: Data([1]), paired: "2026-11-14")), as: UTF8.self)
    check(s == #"{"key":"AQ==","name":"iPad","paired":"2026-11-14"}"#, "peers.json shape: \(s)")
}

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
