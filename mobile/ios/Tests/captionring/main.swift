// Tests for HostApp/iOS/CaptionRing.swift (the listen lane's S1: no line lost while the app sleeps or is killed).
// Run on the Mac:
//   swiftc -O mobile/HostApp/iOS/CaptionRing.swift mobile/ios/Tests/captionring/main.swift -o "$TMPDIR/captionring" && "$TMPDIR/captionring"
import Foundation

struct L: RingLine, Equatable {
    var b: Int; var n: Int; var text: String
    var ringKey: String { "\(b).\(n)" }
    var ringStamp: UInt64 { ringHash(text) }
    var ringSize: Int { text.utf8.count + 64 }
}

var failed = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failed += 1 } }

// wrap-around: past the line cap the oldest go, the newest stay, in order
var r = CaptionRing<L>()
for n in 0..<250 { r.add(L(b: 1, n: n, text: "line \(n)"), maxLines: 200) }
check(r.lines.count == 200, "wrap-around keeps 200 lines")
check(r.lines.first?.n == 50 && r.lines.last?.n == 249, "wrap-around drops the oldest, keeps order")

// byte cap: oldest go until the ring fits; a single line over the cap still stays
var big = CaptionRing<L>()
for n in 0..<10 { big.add(L(b: 1, n: n, text: String(repeating: "x", count: 1000)), maxBytes: 5000) }
check(big.lines.reduce(0) { $0 + $1.ringSize } <= 5000, "byte cap holds")
check(big.lines.last?.n == 9, "byte cap keeps the newest")
var huge = CaptionRing<L>()
huge.add(L(b: 1, n: 0, text: String(repeating: "y", count: 9000)), maxBytes: 5000)
check(huge.lines.count == 1, "a line alone over the byte cap is still kept")

// duplicate line number: a line that grows replaces its older version, once
var d = CaptionRing<L>()
d.add(L(b: 1, n: 3, text: "Bonjour"))
d.add(L(b: 1, n: 4, text: "Ça va"))
d.add(L(b: 1, n: 3, text: "Bonjour à tous."))
check(d.lines.count == 2, "duplicate n replaces, not adds")
check(d.lines.last == L(b: 1, n: 3, text: "Bonjour à tous."), "the newer version is kept, at the end")
// the same n in another broadcast is another line
d.add(L(b: 2, n: 3, text: "Xin chào"))
check(d.lines.count == 3, "same n, other broadcast: kept apart")

// app killed mid-run: it had taken lines 0-4 (seen, saved as strings in UserDefaults); the extension heard 5-9 and
// grew line 4 meanwhile. After relaunch exactly the missed lines and the grown one come back, then nothing more.
var k = CaptionRing<L>()
var seen: [String: UInt64] = [:]
for n in 0..<5 { let l = L(b: 7, n: n, text: "said \(n)"); k.add(l); seen[l.ringKey] = l.ringStamp }
let saved = seen.mapValues { String($0) }                     // what the app stored before it was killed
k.add(L(b: 7, n: 4, text: "said 4, and more"))
for n in 5..<10 { k.add(L(b: 7, n: n, text: "said \(n)")) }
var back = saved.compactMapValues { UInt64($0) }              // what the relaunched app reads back
let missed = k.unseen(back)
check(missed.map(\.n) == [4, 5, 6, 7, 8, 9], "relaunch takes the grown line and the missed ones")
for l in missed { back[l.ringKey] = l.ringStamp }
check(k.unseen(back).isEmpty, "taken once: nothing comes back twice")

// the ring survives its Keychain round trip
let data = try! JSONEncoder().encode(k)
let again = try! JSONDecoder().decode(CaptionRing<L>.self, from: data)
check(again.lines == k.lines, "JSON round trip")
check(ringHash("Bonjour") == ringHash("Bonjour") && ringHash("Bonjour") != ringHash("bonjour"), "stable hash")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
