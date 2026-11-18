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
    check((try? c.receive(r.hello())) == .some(nil), "the same hello again is ignored (BUG-17 echo)")
    do { _ = try c.receive(CarryPairSession(me: Key(), name: "x").hello()); check(false, "a different second hello must fail") }
    catch { check(error as? PairFailure == .outOfOrder, "a hello from a different key is out of order") }
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
    for (mac, phone) in [(macGroup, nil), (nil, nil), (nil, macGroup), (macGroup, macGroup)] as [(Data?, Data?)] {
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

// Regression guard: BUG-17 · already connected, one side starts first: its hello reaches a device that is not
// looking yet and is dropped; the other side starts later. Both must still reach a code and pair (the owner's iPad, 17:4x).
do {
    let macGroup = Data(repeating: 7, count: 32)
    for macFirst in [true, false] {
        var a = CarryPairFlow(me: Key(), name: "Mac", group: macGroup), b = CarryPairFlow(me: Key(), name: "iPad", group: nil)
        var toA: [PairMessage] = [], toB: [PairMessage] = []
        var paired: [String: CarryPairFlow.Paired] = [:], codes: [String: String] = [:]
        if macFirst { _ = a.start(); toA = b.start().send } else { _ = b.start(); toB = a.start().send }   // the first hello is lost
        try pump(&a, &b, &toA, &toB, paired: &paired, codes: &codes)
        check(codes["a"] != nil && codes["a"] == codes["b"], "a lost first hello still ends in one code on both (mac first: \(macFirst))")
        let ta = try a.confirm(), tb = try b.confirm()
        toB += ta.send; toA += tb.send; paired["a"] = ta.paired ?? paired["a"]; paired["b"] = tb.paired ?? paired["b"]
        try pump(&a, &b, &toA, &toB, paired: &paired, codes: &codes)
        check(paired["a"] != nil && paired["b"]?.group == macGroup, "and both pair (mac first: \(macFirst))")
    }
}
// Owner rule (BUG-17): "it should only show mac pro once each time it pairs, there should not be two".
check(CarryInvites.newestPerName(["Mac#1", "iPad", "Mac#2"], name: { String($0.prefix(3)) }) == ["iPad", "Mac#2"], "one row per name, the newest kept")

// Derived from Spec: FEAT-09 P1b (pair by typing the code, T-0086): one side shows six digits, the other types them
struct Leg {
    var f: CarryPairFlow
    var inbox: [PairMessage] = []
    var code: String?            // shown on this screen
    var wants = false            // this screen asks for the code
    var paired: CarryPairFlow.Paired?
    var failure: PairFailure?
    mutating func take(_ s: CarryPairFlow.Step, to other: inout Leg) {
        other.inbox += s.send
        if let c = s.code { code = c }
        if s.wantsCode { wants = true }
        if let p = s.paired { paired = p }
    }
}
/// Delivers until quiet. A side that throws refuses, as the glue does; `typed` is what the owner types on the asking side.
func passkey(_ a: inout Leg, _ b: inout Leg, typed: (String) -> String) {
    var typedDone = false
    func step(_ x: inout Leg, _ y: inout Leg) -> Bool {
        guard x.failure == nil, !x.inbox.isEmpty else { return false }
        let m = x.inbox.removeFirst()
        do { x.take(try x.f.receive(m), to: &y) }
        catch { x.failure = error as? PairFailure; y.inbox.append(.refuse("pairing failed")) }
        return true
    }
    var moved = true
    while moved {
        moved = false
        while step(&b, &a) || step(&a, &b) { moved = true }
        if !typedDone, a.wants != b.wants, let shown = (a.wants ? b.code : a.code) {
            typedDone = true; moved = true
            do {
                if a.wants { a.take(try a.f.enter(typed(shown)), to: &b) } else { b.take(try b.f.enter(typed(shown)), to: &a) }
            } catch { if a.wants { a.failure = error as? PairFailure; b.inbox.append(.refuse("x")) } else { b.failure = error as? PairFailure; a.inbox.append(.refuse("x")) } }
        }
    }
}
func legs(macPicked: Bool, phonePicked: Bool, mac: Data? = nil, phone: Data? = nil) -> (Leg, Leg) {
    var a = Leg(f: CarryPairFlow(me: Key(), name: "Mac", group: mac, picked: macPicked))
    var b = Leg(f: CarryPairFlow(me: Key(), name: "iPhone", group: phone, picked: phonePicked))
    a.take(a.f.start(), to: &b); b.take(b.f.start(), to: &a)
    return (a, b)
}
do {
    let g = Data(repeating: 9, count: 32)
    for (mp, pp) in [(true, false), (false, true), (true, true), (false, false)] {
        for (mac, phone) in [(g, nil), (nil, nil), (nil, g), (g, g)] as [(Data?, Data?)] {
            var (a, b) = legs(macPicked: mp, phonePicked: pp, mac: mac, phone: phone)
            passkey(&a, &b) { $0 }
            let what = "mac picked \(mp), phone picked \(pp), mac group \(mac != nil), phone group \(phone != nil)"
            check((a.code != nil) != (b.code != nil), "exactly one side shows a code (\(what))")
            check(a.wants != b.wants && (a.wants == (b.code != nil)), "the other side asks for it (\(what))")
            if mp != pp { check((mp ? a.code : b.code) != nil, "the side that picked shows the code (\(what))") }
            check((a.code ?? b.code)?.count == 6 && (a.code ?? b.code)!.allSatisfy(\.isNumber), "six digits (\(what))")
            check(a.paired != nil && b.paired != nil && a.failure == nil && b.failure == nil, "the right code pairs both (\(what))")
            check(a.paired?.group == b.paired?.group && a.paired?.group != nil, "one group on both (\(what))")
            if let m = mac ?? phone { check(a.paired?.group == m, "an existing group is kept (\(what))") }
            check(a.paired?.name == "iPhone" && b.paired?.name == "Mac", "names saved (\(what))")
        }
    }
    // a wrong code refuses both, wherever the digits differ
    for wrong in ["000000", "999999"] as [String] {
        var (a, b) = legs(macPicked: true, phonePicked: false)
        passkey(&a, &b) { $0 == wrong ? "123456" : wrong }
        check(a.paired == nil && b.paired == nil, "a wrong code pairs neither (\(wrong))")
        check(a.failure != nil || b.failure != nil, "a wrong code refuses (\(wrong)): \(String(describing: a.failure)) \(String(describing: b.failure))")
        check([a.failure, b.failure].contains(.refused) || (a.failure != nil && b.failure != nil), "the other side learns it was refused")
    }
    // every last digit matters: one digit off is refused
    do {
        var (a, b) = legs(macPicked: true, phonePicked: false)
        passkey(&a, &b) { c in String(c.dropLast()) + String((Int(String(c.last!))! + 1) % 10) }
        check(a.paired == nil && b.paired == nil, "the last digit off by one pairs neither")
    }
    // a malformed code is refused at once
    do {
        var (a, b) = legs(macPicked: true, phonePicked: false)
        while let m = b.inbox.first { b.inbox.removeFirst(); b.take(try b.f.receive(m), to: &a) }
        check(b.wants, "the typer asks for the code")
        check((try? b.f.enter("12a45")) == nil && (try? b.f.enter("1234567")) == nil, "not six digits: refused")
    }
    // a device in the middle with its own keys, relaying every round message: both honest sides refuse
    do {
        var a = Leg(f: CarryPairFlow(me: Key(), name: "Mac", group: nil, picked: true))
        var b = Leg(f: CarryPairFlow(me: Key(), name: "iPhone", group: nil, picked: false))
        let mk = Key()
        let mHello = PairMessage.hello(key: mk.publicKey.rawRepresentation, name: "Mac", grouped: false, picked: true)
        let mHelloToA = PairMessage.hello(key: mk.publicKey.rawRepresentation, name: "iPhone", grouped: false, picked: false)
        func swap(_ ms: [PairMessage], toA: Bool) -> [PairMessage] { ms.map { if case .hello = $0 { return toA ? mHelloToA : mHello }; return $0 } }
        a.take(a.f.start(), to: &b); b.take(b.f.start(), to: &a)
        a.inbox = swap(a.inbox, toA: true); b.inbox = swap(b.inbox, toA: false)
        var typed = false
        for _ in 0..<500 {
            var outA: [PairMessage] = [], outB: [PairMessage] = []
            if a.failure == nil, !a.inbox.isEmpty { let m = a.inbox.removeFirst(); var sink = Leg(f: b.f)
                do { a.take(try a.f.receive(m), to: &sink); outB = sink.inbox } catch { a.failure = error as? PairFailure } }
            if b.failure == nil, !b.inbox.isEmpty { let m = b.inbox.removeFirst(); var sink = Leg(f: a.f)
                do { b.take(try b.f.receive(m), to: &sink); outA = sink.inbox } catch { b.failure = error as? PairFailure } }
            if !typed, b.wants, let c = a.code { typed = true; var sink = Leg(f: a.f)
                do { b.take(try b.f.enter(c), to: &sink); outA += sink.inbox } catch { b.failure = error as? PairFailure } }
            b.inbox += swap(outB, toA: false); a.inbox += swap(outA, toA: true)
            if a.inbox.isEmpty && b.inbox.isEmpty && (typed || a.failure != nil || b.failure != nil) { break }
        }
        check(a.paired == nil && b.paired == nil, "a relaying device in the middle pairs neither side")
        check(b.failure == .badCommit && b.f.passkey?.finished != true && a.f.passkey?.finished != true,
              "the rounds themselves refuse a relay (not just the seal after): \(String(describing: b.failure))")
    }
    // a new attempt draws a new code
    var seen = Set<String>()
    for _ in 0..<8 { var (a, b) = legs(macPicked: true, phonePicked: false); passkey(&a, &b) { $0 }; if let c = a.code { seen.insert(c) } }
    check(seen.count >= 7, "each attempt draws a fresh code: \(seen.count) of 8 distinct")
    // an older peer (no `picked` in its hello) still pairs by comparing codes
    do {
        var a = CarryPairFlow(me: Key(), name: "Mac", group: nil, picked: true), b = CarryPairFlow(me: Key(), name: "iPhone", group: nil)
        var toB = a.start().send, toA = b.start().send
        var paired: [String: CarryPairFlow.Paired] = [:], codes: [String: String] = [:]
        try pump(&a, &b, &toA, &toB, paired: &paired, codes: &codes)
        check(codes["a"] != nil && codes["a"] == codes["b"], "an older peer: both compare the same code")
    }
    check(CarryPasskey.rounds == 20, "20 rounds, one per bit of a code below 2^20")
}

// Regression guard: BUG-26 (T-0118) · only a real failure tells the peer to stop; a stale or duplicate message is ignored
do {
    check(!PairFailure.outOfOrder.endsFlow && !PairFailure.outOfOrder.tellsPeer, "a duplicate hello keeps both flows")
    check(PairFailure.badCommit.endsFlow && PairFailure.badCommit.tellsPeer, "a wrong code ends both sides")
    check(PairFailure.otherGroup.tellsPeer, "another group ends both sides")
    check(PairFailure.refused.endsFlow && !PairFailure.refused.tellsPeer, "a refusal is not echoed back")
}

// Regression guard: BUG-26 (T-0119) · spoken and non-ASCII digits become the six ASCII digits; anything else asks again
do {
    check(CarryPasskey.normalize("123456") == "123456", "plain")
    check(CarryPasskey.normalize("123 456") == "123456", "spaced")
    check(CarryPasskey.normalize("one two three four five six") == "123456", "spoken English")
    check(CarryPasskey.normalize("một hai ba bốn năm sáu") == "123456", "spoken Vietnamese")
    check(CarryPasskey.normalize("Zero oh nine 8 7 6") == "009876", "mixed words and digits")
    check(CarryPasskey.normalize("١٢٣٤٥٦") == "123456", "Arabic-Indic digits")
    check(CarryPasskey.normalize("１２３４５６") == "123456", "full-width digits")
    check(CarryPasskey.normalize("12345") == nil, "five digits: ask again")
    check(CarryPasskey.normalize("one two banana") == nil, "an unknown word: ask again")
    check(CarryPasskey.normalize("") == nil, "empty: ask again")
}

// Regression guard: BUG-26 (T-0120) · one pairing prompt at a time, owned by one peer
do {
    check(PairPrompt.owns(nil, "iPad"), "a free prompt goes to the first flow")
    check(PairPrompt.owns("iPad", "iPad"), "the owner keeps it")
    check(!PairPrompt.owns("iPad", "iPhone"), "a second device can't take it over")
}

// Regression guard: SEC-02 §4.12 (T-0121) · the prompt's own peer leaving clears it; another peer leaving clears nothing
do {
    let asking = PairPrompt.Shown(pairingWith: "iPad", askingCode: true, pairingCode: nil)
    check(PairPrompt.disconnected(asking, peer: "iPad") == PairPrompt.Shown(), "the prompt's peer left: code prompt cleared")
    let showing = PairPrompt.Shown(pairingWith: "iPad", askingCode: false, pairingCode: "123456")
    check(PairPrompt.disconnected(showing, peer: "iPad") == PairPrompt.Shown(), "the prompt's peer left: shown code cleared")
    check(PairPrompt.disconnected(asking, peer: "iPhone") == asking, "another peer leaving clears nothing")
    check(PairPrompt.disconnected(PairPrompt.Shown(), peer: "iPad") == PairPrompt.Shown(), "no prompt: nothing changes")
}

// Regression guard: SEC-02 §4.12 (T-0123) · after a failed code, re-picking from the other side makes that side show
do {
    let t0 = Date()
    var macPicked = PairPrompt.pick([:], "iPhone", at: t0)          // first try: the Mac picked
    var phonePicked: [String: Date] = [:]
    check(macPicked["iPhone"] == t0, "a pick is recorded")
    macPicked = PairPrompt.failed(macPicked, "iPhone")              // the code failed: both sides end the pick
    phonePicked = PairPrompt.failed(phonePicked, "Mac")
    check(macPicked.isEmpty, "a failed code ends the pick")
    phonePicked = PairPrompt.pick(phonePicked, "Mac", at: t0.addingTimeInterval(5))   // re-picked while still connected
    var (a, b) = legs(macPicked: macPicked["iPhone"] != nil, phonePicked: phonePicked["Mac"] != nil)
    passkey(&a, &b) { $0 }
    check(b.code != nil && a.code == nil && a.wants, "the side that re-picked shows the code")
    check(a.paired != nil && b.paired != nil, "and both pair")
    let again = PairPrompt.pick(phonePicked, "Mac", at: t0.addingTimeInterval(9))
    check(again["Mac"] == t0.addingTimeInterval(9), "re-picking an already-picked device updates its time")
}

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
