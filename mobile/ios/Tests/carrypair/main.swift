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

// Regression guard: BUG-17 · both devices finish pairing, whichever order the taps and the sealed group arrive in.
/// Delivers every queued message both ways until quiet; returns what each side was asked to show or save.
func pump(_ a: inout CarryPairFlow, _ b: inout CarryPairFlow, _ toA: inout [PairMessage], _ toB: inout [PairMessage],
          paired: inout [String: CarryPairFlow.Paired], codes: inout [String: String]) throws {
    while !toA.isEmpty || !toB.isEmpty {
        if !toB.isEmpty { let s = try b.receive(toB.removeFirst()); toA += s.send; if let c = s.code { codes["b"] = c }; if let p = s.paired { paired["b"] = p } }
        if !toA.isEmpty { let s = try a.receive(toA.removeFirst()); toB += s.send; if let c = s.code { codes["a"] = c }; if let p = s.paired { paired["a"] = p } }
    }
}
enum Order { case aFirst, bFirst, bothBeforeDelivery }
func pairFlows(mac: Data?, phone: Data?, order: Order) throws -> (a: CarryPairFlow.Paired?, b: CarryPairFlow.Paired?, codes: [String: String]) {
    var a = CarryPairFlow(me: Key(), name: "Mac", group: mac), b = CarryPairFlow(me: Key(), name: "iPhone", group: phone)
    var toB = a.start().send, toA = b.start().send
    var paired: [String: CarryPairFlow.Paired] = [:], codes: [String: String] = [:]
    try pump(&a, &b, &toA, &toB, paired: &paired, codes: &codes)
    func tapA() throws { let s = try a.confirm(); toB += s.send; if let p = s.paired { paired["a"] = p } }
    func tapB() throws { let s = try b.confirm(); toA += s.send; if let p = s.paired { paired["b"] = p } }
    switch order {
    case .aFirst: try tapA(); try pump(&a, &b, &toA, &toB, paired: &paired, codes: &codes); try tapB()
    case .bFirst: try tapB(); try pump(&a, &b, &toA, &toB, paired: &paired, codes: &codes); try tapA()
    case .bothBeforeDelivery: try tapA(); try tapB()
    }
    try pump(&a, &b, &toA, &toB, paired: &paired, codes: &codes)
    return (paired["a"], paired["b"], codes)
}
do {
    let macGroup = Data(repeating: 7, count: 32)
    for (mac, phone) in [(macGroup, nil), (nil, nil), (nil, macGroup)] as [(Data?, Data?)] {
        for order in [Order.aFirst, .bFirst, .bothBeforeDelivery] {
            let r = try pairFlows(mac: mac, phone: phone, order: order)
            let what = "mac group \(mac != nil), phone group \(phone != nil), \(order)"
            check(r.codes["a"] != nil && r.codes["a"] == r.codes["b"], "both show the same code (\(what))")
            check(r.a != nil && r.b != nil, "BOTH sides finish pairing (\(what))")
            check(r.a?.group == r.b?.group, "both end in the same group (\(what))")
            if let g = mac ?? phone { check(r.a?.group == g, "the existing group is kept, not replaced (\(what))") }
            check(r.a?.name == "iPhone" && r.b?.name == "Mac", "each saves the other's name (\(what))")
        }
    }
    // The sealed group arriving before this side's own tap is held, not accepted: no tap, no pairing.
    var a = CarryPairFlow(me: Key(), name: "Mac", group: macGroup), b = CarryPairFlow(me: Key(), name: "iPhone", group: nil)
    var toB = a.start().send, toA = b.start().send
    var paired: [String: CarryPairFlow.Paired] = [:], codes: [String: String] = [:]
    try pump(&a, &b, &toA, &toB, paired: &paired, codes: &codes)
    toB += try a.confirm().send
    try pump(&a, &b, &toA, &toB, paired: &paired, codes: &codes)
    check(paired["b"] == nil, "the receiver does not pair before its own tap")
    do {   // the waiting side tapped twice before the group arrived: harmless
        var x = CarryPairFlow(me: Key(), name: "iPhone", group: nil), y = CarryPairFlow(me: Key(), name: "Mac", group: macGroup)
        var tx = y.start().send, ty = x.start().send, pd: [String: CarryPairFlow.Paired] = [:], cd: [String: String] = [:]
        try pump(&x, &y, &tx, &ty, paired: &pd, codes: &cd)
        let t1 = try x.confirm(), t2 = try x.confirm()
        check(t1 == CarryPairFlow.Step() && t2 == CarryPairFlow.Step(), "a second tap while waiting is harmless")
        tx += try y.confirm().send
        try pump(&x, &y, &tx, &ty, paired: &pd, codes: &cd)
        check(pd["a"]?.group == macGroup, "and the group still lands after it")
    }
    check(try b.confirm().paired?.group == macGroup, "its tap then opens the held group")
    // Two devices already in groups are refused, not merged.
    do { _ = try pairFlows(mac: macGroup, phone: Data(repeating: 8, count: 32), order: .aFirst); check(false, "two groups must refuse") }
    catch { check(error as? PairFailure == .otherGroup, "two existing groups are refused") }
    // An older peer's hello without `grouped` still decodes.
    let old = #"{"hello":{"key":"AQ==","name":"iPad"}}"#
    check((try? JSONDecoder().decode(PairMessage.self, from: Data(old.utf8))) == .hello(key: Data([1]), name: "iPad"), "an old hello decodes")
}

// Regression guard: BUG-17 · either device may start first: a picked device that has not answered is invited again.
do {
    let t0 = Date(timeIntervalSince1970: 1000)
    let picked = ["iPhone": t0, "iPad": t0]
    check(CarryInvites.due(picked: picked, nearby: ["iPhone", "iPad"], connected: [], now: t0 + 5).isEmpty, "not before the last invite's timeout")
    check(CarryInvites.due(picked: picked, nearby: ["iPhone", "iPad"], connected: [], now: t0 + 11) == ["iPad", "iPhone"], "both again after it")
    check(CarryInvites.due(picked: picked, nearby: ["iPhone"], connected: [], now: t0 + 30) == ["iPhone"], "only one still nearby")
    check(CarryInvites.due(picked: picked, nearby: ["iPhone", "iPad"], connected: ["iPhone"], now: t0 + 30) == ["iPad"], "never one already connected")
    check(CarryInvites.every > 10, "the interval outlasts the 10 s invite timeout")
}

// Regression guard: BUG-17 · a re-pair replaces only its own entry; one another process wrote is kept.
do {
    let a = CarryPeer(name: "iPhone", key: Data([1]), paired: "old"), b = CarryPeer(name: "iPad", key: Data([2]), paired: "cli")
    let r = CarryPeer.replacing([a, b], with: CarryPeer(name: "iPhone", key: Data([1]), paired: "new"))
    check(r.count == 2 && r.contains(b) && r.first { $0.name == "iPhone" }?.paired == "new", "replaces the same device, keeps the rest")
    check(CarryPeer.replacing([a], with: CarryPeer(name: "iPhone 2", key: Data([1]), paired: "x")).count == 1, "same key, renamed: still one entry")
}

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
