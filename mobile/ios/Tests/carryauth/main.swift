// Derived from Spec: SEC-02 §4 · carry peer auth (handshake, sealed frames, invitation, revocation, migration), no radios.
// swiftc -O shared/carrypair.swift shared/carryauth.swift mobile/ios/Tests/carryauth/main.swift -o "$TMPDIR/carryauth" && "$TMPDIR/carryauth"
// Invariant 10 (safe keys) is in Tests/carrysync (CarrySync.split), 11 (bytes check) in `recense selftest` (CarryApply).
import Foundation
import CryptoKit

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { failed += 1; print("FAIL L\(line): \(what)") } }
typealias Key = Curve25519.KeyAgreement.PrivateKey
func peer(_ name: String, _ k: Key) -> CarryPeer { CarryPeer(name: name, key: k.publicKey.rawRepresentation, paired: "2026-11-18") }

/// One side of a connection: its session, its trust store, the first error it hit.
struct Side {
    var s: CarryAuthSession
    var trust: [CarryPeer]
    var error: CarryAuthFailure?
    init(_ me: Key, trusts: [CarryPeer]) { s = CarryAuthSession(me: me); trust = trusts }
}
func deliver(_ m: CarryAuthMessage, to x: inout Side) -> CarryAuthMessage? {
    guard x.error == nil else { return nil }
    do { return try x.s.receive(m, trusted: x.trust) } catch { x.error = error as? CarryAuthFailure; return nil }
}
/// Both hellos, then both proofs, as the link carries them. `relay` may change any message in flight.
func shake(_ a: inout Side, _ b: inout Side, aFirst: Bool = true,
           relay: (_ toB: Bool, CarryAuthMessage) -> CarryAuthMessage = { $1 }) {
    let ha = a.s.hello, hb = b.s.hello
    var pa: CarryAuthMessage?, pb: CarryAuthMessage?
    if aFirst { pb = deliver(relay(true, ha), to: &b); pa = deliver(relay(false, hb), to: &a) }
    else { pa = deliver(relay(false, hb), to: &a); pb = deliver(relay(true, ha), to: &b) }
    if let pa { _ = deliver(relay(true, pa), to: &b) }
    if let pb { _ = deliver(relay(false, pb), to: &a) }
}
func flip(_ d: Data, at i: Int) -> Data { var c = Data(d); c[c.startIndex + i] ^= 1; return c }

let mac = Key(), ipad = Key(), iphone = Key()
let ops = Data(#"[{"seq":1,"op":"put","home":"library/Music","path":"a.m4a"}]"#.utf8)

// 1 · Honest pair: both orders authenticate, and sealed ops open byte-equal on the other side, both ways
for aFirst in [true, false] {
    var a = Side(mac, trusts: [peer("iPad", ipad)]), b = Side(ipad, trusts: [peer("Mac", mac)])
    shake(&a, &b, aFirst: aFirst)
    check(a.s.authenticated && b.s.authenticated && a.error == nil && b.error == nil, "honest pair authenticates (aFirst \(aFirst))")
    check(a.s.peer?.name == "iPad" && b.s.peer?.name == "Mac", "each names the other by its trust-store entry")
    do {
        let f = try a.s.seal("ops", ops)
        check(f.box.range(of: Data("a.m4a".utf8)) == nil, "the sealed box hides the payload")
        let got = try b.s.open(f)
        check(got == CarryFrame(type: "ops", payload: ops), "sealed ops open byte-equal (aFirst \(aFirst))")
        let back = try b.s.open(try a.s.seal("seen", Data("7".utf8)))
        check(back.type == "seen" && back.payload == Data("7".utf8), "a second frame opens too")
        check(try a.s.open(try b.s.seal("gone", Data("[]".utf8))).type == "gone", "and the other direction")
    } catch { check(false, "honest seal/open threw \(error)") }
}

// 2 · Wrong key: a hello whose key is not trusted gives no channel and no proof
do {
    var a = Side(mac, trusts: [peer("iPad", ipad)]), b = Side(ipad, trusts: [peer("iPhone", iphone)])
    var probe = b
    check(deliver(a.s.hello, to: &probe) == nil && probe.error == .unknownKey, "an unknown key gets no proof back")
    shake(&a, &b)
    check(!a.s.authenticated && !b.s.authenticated, "an unknown key: neither side has a channel")
    check(b.error == .unknownKey, "refused as unknownKey")
    var c = b
    check((try? c.s.seal("ops", ops)) == nil, "nothing can be sealed to a refused peer")
}

// 3 · Renamed impostor: its own key under a trusted name is refused, and the trusted entry is unchanged
do {
    let impostor = Key()
    let trust = [peer("iPad", ipad)]
    var a = Side(mac, trusts: trust), x = Side(impostor, trusts: [peer("Mac", mac)])
    shake(&a, &x)
    check(!a.s.authenticated && a.error == .unknownKey && a.trust == trust, "its own key: refused, the iPad's entry unchanged")
    // claiming the iPad's public key without its private key: the proof fails
    var a2 = Side(mac, trusts: trust), x2 = Side(impostor, trusts: [peer("Mac", mac)])
    shake(&a2, &x2) { toB, m in
        guard !toB, case .hello(_, let eph, let nonce) = m else { return m }
        return .hello(key: ipad.publicKey.rawRepresentation, eph: eph, nonce: nonce)
    }
    check(!a2.s.authenticated && a2.error == .badProof, "the iPad's key without its private half: badProof")
    check(a2.trust == trust, "the trusted entry is unchanged")
}

// 4 · Replay: twice opens once; a frame from session 1 fails in session 2; a frame reflected to its sender fails
do {
    var a = Side(mac, trusts: [peer("iPad", ipad)]), b = Side(ipad, trusts: [peer("Mac", mac)])
    shake(&a, &b)
    let f1 = try a.s.seal("ops", ops), f2 = try a.s.seal("seen", Data("1".utf8))
    check((try? b.s.open(f1)) != nil, "first delivery opens")
    check((try? b.s.open(f1)) == nil, "the same frame again is dropped")
    check((try? b.s.open(f2)) != nil, "the next frame still opens")
    check((try? b.s.open(f1)) == nil, "an older frame after a newer one is dropped (n ≤ last)")
    var a2 = Side(mac, trusts: [peer("iPad", ipad)]), b2 = Side(ipad, trusts: [peer("Mac", mac)])
    shake(&a2, &b2)
    check(a2.s.authenticated && b2.s.authenticated, "session 2 authenticates")
    check((try? b2.s.open(f1)) == nil, "a frame captured in session 1 fails in session 2")
    check((try? a.s.open(try a.s.seal("ops", ops))) == nil, "a frame reflected back to its sender fails")
    // a proof reflected back to its sender fails
    var r = Side(mac, trusts: [peer("iPad", ipad)]), q = Side(ipad, trusts: [peer("Mac", mac)])
    let mine = deliver(q.s.hello, to: &r)!
    _ = deliver(r.s.hello, to: &q)
    _ = deliver(mine, to: &r)
    check(!r.s.authenticated && r.error == .badProof, "its own proof reflected back: badProof")
} catch { check(false, "replay setup threw \(error)") }

// 5 · Tamper: one flipped bit in box, n or the proof is refused
do {
    var a = Side(mac, trusts: [peer("iPad", ipad)]), b = Side(ipad, trusts: [peer("Mac", mac)])
    shake(&a, &b)
    let f = try a.s.seal("ops", ops)
    for i in [0, f.box.count / 2, f.box.count - 1] {
        check((try? b.s.open(CarrySealed(n: f.n, box: flip(f.box, at: i)))) == nil, "a flipped bit in box (byte \(i)) is refused")
    }
    check((try? b.s.open(CarrySealed(n: f.n ^ 2, box: f.box))) == nil, "a changed n is refused")
    check((try? b.s.open(f)) != nil, "a refused forgery never moves the counter: the real frame still opens")
    var c = Side(mac, trusts: [peer("iPad", ipad)]), d = Side(ipad, trusts: [peer("Mac", mac)])
    shake(&c, &d) { toB, m in
        guard toB, case .proof(let p) = m else { return m }
        return .proof(flip(p, at: 5))
    }
    check(!d.s.authenticated && d.error == .badProof, "a flipped bit in the proof is refused")
} catch { check(false, "tamper setup threw \(error)") }

// 6 · Relay: replacing eph or nonce makes both proofs fail; relaying unchanged lets the middle read nothing
for part in ["eph", "nonce"] {
    let middle = Key()
    var a = Side(mac, trusts: [peer("iPad", ipad)]), b = Side(ipad, trusts: [peer("Mac", mac)])
    shake(&a, &b) { _, m in
        guard case .hello(let k, let eph, let nonce) = m else { return m }
        return part == "eph" ? .hello(key: k, eph: middle.publicKey.rawRepresentation, nonce: nonce)
                             : .hello(key: k, eph: eph, nonce: flip(nonce, at: 0))
    }
    check(!a.s.authenticated && !b.s.authenticated, "relay replaced \(part): neither side authenticates")
    check(a.error == .badProof && b.error == .badProof, "relay replaced \(part): both proofs fail")
}
do {
    var a = Side(mac, trusts: [peer("iPad", ipad), peer("iPhone", iphone)]), b = Side(ipad, trusts: [peer("Mac", mac)])
    shake(&a, &b)   // relayed unchanged
    let f = try a.s.seal("ops", ops)
    var a3 = Side(mac, trusts: [peer("iPhone", iphone)]), m = Side(iphone, trusts: [peer("Mac", mac)])
    shake(&a3, &m)  // the middle is even a trusted device with its own session to the Mac
    check(m.s.authenticated && (try? m.s.open(f)) == nil, "a relay with its own session cannot open the Mac↔iPad frame")
    check(f.box.range(of: Data("library/Music".utf8)) == nil, "the relayed bytes carry no plaintext")
} catch { check(false, "relay setup threw \(error)") }

// 7 · Revoked: after forget the same key's hello is refused; a received forget removes the sender
do {
    var trust = [peer("iPad", ipad), peer("iPhone", iphone)]
    trust = CarryTrust.forgetting(trust, key: ipad.publicKey.rawRepresentation)
    check(trust.map(\.name) == ["iPhone"], "forget removes only that key")
    var a = Side(mac, trusts: trust), b = Side(ipad, trusts: [peer("Mac", mac)])
    shake(&a, &b)
    check(!a.s.authenticated && a.error == .unknownKey, "a forgotten key is refused like a stranger")
    // the iPad forgets the Mac: its sealed forget opens on the Mac, which then drops the iPad's key
    var m = Side(mac, trusts: [peer("iPad", ipad)]), i = Side(ipad, trusts: [peer("Mac", mac)])
    shake(&m, &i)
    let got = try m.s.open(try i.s.seal("forget", Data()))
    check(got.type == "forget", "a sealed forget opens")
    if got.type == "forget", let who = m.s.peer { m.trust = CarryTrust.forgetting(m.trust, key: who.key) }
    check(m.trust.isEmpty, "a received forget removes the sender")
    var m2 = Side(mac, trusts: m.trust), i2 = Side(ipad, trusts: [peer("Mac", mac)])
    shake(&m2, &i2)
    check(!m2.s.authenticated && m2.error == .unknownKey, "and its next hello is refused")
} catch { check(false, "revoke setup threw \(error)") }

// 8 · Invitation: the right key and proof auto-accept; another key, a changed nonce or no context do not
do {
    let trust = [peer("Mac", mac)]
    let ctx = try CarryInvite.context(me: mac, peer: ipad.publicKey.rawRepresentation)
    check(ctx.count == 80, "context = key 32 ‖ nonce 16 ‖ proof 32")
    check(CarryInvite.accepts(ctx, me: ipad, trusted: trust)?.name == "Mac", "the right key and proof are accepted")
    let other = try CarryInvite.context(me: Key(), peer: ipad.publicKey.rawRepresentation)
    check(CarryInvite.accepts(other, me: ipad, trusted: trust) == nil, "another key: no auto-accept")
    check(CarryInvite.accepts(flip(ctx, at: 40), me: ipad, trusted: trust) == nil, "a changed nonce: no auto-accept")
    check(CarryInvite.accepts(flip(ctx, at: 70), me: ipad, trusted: trust) == nil, "a changed proof: no auto-accept")
    check(CarryInvite.accepts(nil, me: ipad, trusted: trust) == nil, "no context: no auto-accept")
    check(CarryInvite.accepts(ctx.prefix(79), me: ipad, trusted: trust) == nil, "a short context: no auto-accept")
    // another key copying the Mac's key bytes but not its proof
    var forged = Data(other); forged.replaceSubrange(0..<32, with: mac.publicKey.rawRepresentation)
    check(CarryInvite.accepts(forged, me: ipad, trusted: trust) == nil, "the Mac's key with another device's proof: refused")
    check(CarryInvite.accepts(ctx, me: iphone, trusted: trust) == nil, "an invitation made for the iPad does not open the iPhone")
} catch { check(false, "invitation setup threw \(error)") }

// 9 · Migration: peers.json entries and no peers.v2: nobody is trusted, each entry needs pairing again
do {
    let mirror = [peer("iPad", ipad), peer("iPhone", iphone)]
    let first = CarryTrust.load(v2: nil, mirror: mirror)
    check(first.trusted.isEmpty, "no peers.v2: nobody is trusted, even with keys in peers.json")
    check(first.needsPairing.map(\.name) == ["iPad", "iPhone"], "each old entry is listed as needing pairing")
    let v2 = try JSONEncoder().encode([peer("iPad", ipad)])
    let after = CarryTrust.load(v2: v2, mirror: mirror)
    check(after.trusted.map(\.name) == ["iPad"] && after.needsPairing.map(\.name) == ["iPhone"], "one re-paired: only the other still needs pairing")
    let broken = CarryTrust.load(v2: Data("not json".utf8), mirror: mirror)
    check(broken.trusted.isEmpty && broken.needsPairing.count == 2, "an unreadable peers.v2 trusts nobody")
    let empty = CarryTrust.load(v2: try JSONEncoder().encode([CarryPeer]()), mirror: [])
    check(empty.trusted.isEmpty && empty.needsPairing.isEmpty, "everyone forgotten: nothing listed")
} catch { check(false, "migration setup threw \(error)") }

// 13 · A Keychain read error is not "no peers": the pairings stay and nothing overwrites peers.v2
// Regression guard: SEC-02
do {
    let had = [peer("iPad", ipad), peer("iPhone", iphone)]
    check(CarryStored.from(errSecItemNotFound, nil) == .notFound, "not found is not found")
    check(CarryStored.from(errSecInteractionNotAllowed, nil).failed, "a locked Keychain is a failure, not empty")
    check(CarryStored.from(errSecSuccess, nil).failed, "success with no data is a failure")
    let locked = CarryTrust.load(.failed(errSecInteractionNotAllowed), mirror: had, previous: had)
    check(locked.trusted == had, "a failed read keeps the peers this process had")
    check(!locked.writable, "a failed read refuses to write peers.v2")
    check(locked.needsPairing.isEmpty, "and lists nobody as needing pairing")
    let none = CarryTrust.load(.notFound, mirror: had, previous: had)
    check(none.trusted.isEmpty && none.writable, "only not found starts empty, and may be written")
    let v2 = try JSONEncoder().encode([peer("iPad", ipad)])
    let ok = CarryTrust.load(.found(v2), mirror: had, previous: [])
    check(ok.trusted.map(\.name) == ["iPad"] && ok.writable, "found: read as before")
} catch { check(false, "13 setup threw \(error)") }

// 14 · A Keychain save updates in place: no delete-then-add window that can leave peers.v2 empty
// Regression guard: SEC-02
do {
    var calls: [String] = []
    func run(_ u: OSStatus, _ a: OSStatus) -> Bool {
        calls = []
        return CarryStored.save(update: { calls.append("update"); return u }, add: { calls.append("add"); return a })
    }
    check(run(errSecSuccess, errSecDuplicateItem) && calls == ["update"], "an existing item is updated, nothing added: \(calls)")
    check(run(errSecItemNotFound, errSecSuccess) && calls == ["update", "add"], "a missing item is added: \(calls)")
    check(!run(errSecInteractionNotAllowed, errSecSuccess) && calls == ["update"], "any other update error saves nothing: \(calls)")
    check(!run(errSecItemNotFound, errSecDuplicateItem), "a failed add is reported")
}

// A duplicate hello in one session is out of order, never a second channel
do {
    var a = Side(mac, trusts: [peer("iPad", ipad)]), b = Side(ipad, trusts: [peer("Mac", mac)])
    shake(&a, &b)
    check((try? a.s.receive(b.s.hello, trusted: a.trust)) == nil, "a second hello is refused")
    check(a.s.authenticated, "and the channel stays up")
}

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
