// Regression guard: BUG-29. Draftpad's one load/save (shared/draftpadfile.swift), used by the Mac and the iPhone/iPad:
// a note or ink sidecar that could not be read is never written over, a failed write never moves the base, ink on disk
// this host has not seen is merged first, and a conflict copy never replaces another. Run on the Mac, outside the
// sandbox (NSFileCoordinator):
//   swiftc -O shared/notesync.swift shared/draftpadfile.swift mobile/ios/Tests/draftpadfile/main.swift -o "$TMPDIR/draftpadfile" && "$TMPDIR/draftpadfile"
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failed += 1 } }

let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("recense-draftpadfile-\(getpid())")
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: dir) }
let p = { (n: String) in (dir as NSString).appendingPathComponent(n) }
let fm = FileManager.default
func disk(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

// A note whose reads and writes the test controls: `readFails` makes it unreadable (evicted, offline), `writeFails`
// makes the write fail; otherwise the real coordinated read and write.
var readFails = false, writeFails = false
func makeNote(_ path: String, unsaved: String) -> DraftpadNote {
    DraftpadNote(path: path, unsavedDir: URL(fileURLWithPath: unsaved), launch: Date(timeIntervalSince1970: 1_700_000_000),
                 read: { readFails ? .unreadable : readNote($0) },
                 write: { writeFails ? false : coordinatedWrite($0, to: $1) })
}

// 1. An unreadable note loads blank and is never written over; typed text is kept, the save is pending.
let n1 = p("one.md"), u1 = p("unsaved1")
try? "the whole note".write(toFile: n1, atomically: true, encoding: .utf8)
readFails = true
let d1 = makeNote(n1, unsaved: u1)
check(d1.load() == "" && !d1.readable, "an unreadable note loads blank and is marked unreadable")
check(d1.save("typed") == nil, "a save over it shows nothing new")
check(disk(n1) == "the whole note", "the note is not written over")
check(d1.pending && Unsaved.files(in: URL(fileURLWithPath: u1)).count == 1, "what was typed is kept, the save is pending")
// 2. Once it reads again: the note, then what was typed.
readFails = false
let shown1 = d1.save("typed")
check(disk(n1) == "the whole note\ntyped" && shown1 == "the whole note\ntyped", "readable again: the note, then what was typed")
check(d1.readable && !d1.pending && d1.base == "the whole note\ntyped", "the base is what the file holds")
check(Unsaved.files(in: URL(fileURLWithPath: u1)).isEmpty, "the kept text moved aside once it reached the note")

// 3. A failed write never moves the base.
let n3 = p("three.md"), u3 = p("unsaved3")
try? "a\nb\nc".write(toFile: n3, atomically: true, encoding: .utf8)
let d3 = makeNote(n3, unsaved: u3)
check(d3.load() == "a\nb\nc" && d3.base == "a\nb\nc", "a readable note loads as its text")
writeFails = true
check(d3.save("a\nb\nc\nmine") == nil, "a failed write shows nothing new")
check(d3.base == "a\nb\nc" && d3.pending, "a failed write leaves the base where it was, the save pending")
check(Unsaved.files(in: URL(fileURLWithPath: u3)).count == 1, "what was typed is kept safe")
writeFails = false
// Meanwhile another device added a line at the top; the base being right lets the two merge.
try? "phone\na\nb\nc".write(toFile: n3, atomically: true, encoding: .utf8)
let shown3 = d3.save("a\nb\nc\nmine")
check(disk(n3) == "phone\na\nb\nc\nmine" && shown3 == "phone\na\nb\nc\nmine", "the retry merges both edits; neither is lost")
check(!d3.pending && d3.base == "phone\na\nb\nc\nmine", "the base moves once the file holds the text")

// 4. A save reads the file every time, not only when the mtime changed.
let n4 = p("four.md")
try? "x\ny\nz".write(toFile: n4, atomically: true, encoding: .utf8)
let d4 = makeNote(n4, unsaved: p("unsaved4"))
_ = d4.load()
let stamp = (try? fm.attributesOfItem(atPath: n4))?[.modificationDate] as? Date
try? "X\ny\nz".write(toFile: n4, atomically: true, encoding: .utf8)
if let s = stamp { try? fm.setAttributes([.modificationDate: s], ofItemAtPath: n4) }
_ = d4.save("x\ny\nz\nmac")
check(disk(n4) == "X\ny\nz\nmac", "an edit that kept the mtime is still merged, not written over")

// 5. A conflict: theirs beside the note first, never over an earlier copy.
let n5 = p("five.md")
try? "a\nb\nc".write(toFile: n5, atomically: true, encoding: .utf8)
let d5 = makeNote(n5, unsaved: p("unsaved5"))
_ = d5.load()
try? "a\nPHONE\nc".write(toFile: n5, atomically: true, encoding: .utf8)
check(d5.save("a\nMAC\nc") == nil, "a conflict keeps mine in the editor")
check(disk(n5) == "a\nMAC\nc", "mine is in the note")
func copies() -> [String] {
    ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("five (other device ") }.sorted()
}
check(copies().count == 1 && disk(p(copies()[0])) == "a\nPHONE\nc", "theirs is kept beside the note")
try? "a\nPHONE2\nc".write(toFile: n5, atomically: true, encoding: .utf8)
_ = d5.save("a\nMAC2\nc")
check(copies().count == 2, "a second conflict in the same minute leaves a second copy; the first is not replaced")
check(Set(copies().compactMap { disk(p($0)) }) == ["a\nPHONE\nc", "a\nPHONE2\nc"], "both copies hold their own text")
writeFails = true
try? "a\nPHONE3\nc".write(toFile: n5, atomically: true, encoding: .utf8)
_ = d5.save("a\nMAC3\nc")
check(disk(n5) == "a\nPHONE3\nc" && d5.pending, "a conflict whose copy can't be written leaves the note as it is")
writeFails = false

// A missing note is new: the first save writes it.
let n6 = p("six.md")
let d6 = makeNote(n6, unsaved: p("unsaved6"))
check(d6.load() == "" && d6.readable, "no file yet is a blank, readable note")
_ = d6.save("first")
check(disk(n6) == "first", "the first save writes it")

// 6-8. The ink sidecar.
check(DraftpadInk.plan(json: "J", disk: .unreadable, seen: "S") == .wait, "plan: unreadable sidecar: wait")
check(DraftpadInk.plan(json: "J", disk: .missing, seen: nil) == .write, "plan: no sidecar yet: write")
check(DraftpadInk.plan(json: "J", disk: .text(""), seen: nil) == .write, "plan: empty sidecar: write")
check(DraftpadInk.plan(json: "J", disk: .text("S"), seen: "S") == .write, "plan: the file is what this host saw: write")
check(DraftpadInk.plan(json: "J", disk: .text("J"), seen: nil) == .write, "plan: the file already holds it: write (no-op)")
check(DraftpadInk.plan(json: "J", disk: .text("D"), seen: "S") == .mergeFirst("D"), "plan: strokes not seen here: merge first")
check(DraftpadInk.plan(json: "J", disk: .text("D"), seen: nil) == .mergeFirst("D"), "plan: never read (unreadable at load): merge first")

let ip = p("draftpad.ink.json")
let ipad = #"{"version":1,"strokes":[{"id":"ipad1","at":1}],"removed":[]}"#
try? ipad.write(toFile: ip, atomically: true, encoding: .utf8)
var inkReadFails = true, inkWriteFails = false
let ink = DraftpadInk(path: ip, read: { inkReadFails ? .unreadable : readNote($0) },
                      write: { inkWriteFails ? false : coordinatedWrite($0, to: $1) })
check(ink.load() == nil && ink.seen == nil, "an unreadable sidecar loads as not seen, not as empty ink")
let mac = #"{"version":1,"strokes":[{"id":"mac1","at":2}],"removed":[]}"#
check(ink.save(mac) == .wait && disk(ip) == ipad, "a stroke while it is unreadable writes nothing over it")
check(ink.waiting == mac, "the stroke is kept for the retry")
inkReadFails = false
check(ink.retry() == .mergeFirst(ipad) && disk(ip) == ipad, "readable again: the retry merges the iPad's strokes first")
check(ink.seen == ipad, "the file is marked seen")
let union = #"{"version":1,"strokes":[{"id":"ipad1","at":1},{"id":"mac1","at":2}],"removed":[]}"#
check(ink.save(union) == .write && disk(ip) == union && ink.seen == union && ink.waiting == nil, "the union is written")
// another device adds a stroke; this host's next post holds only its own
let ipad2 = #"{"version":1,"strokes":[{"id":"ipad1","at":1},{"id":"mac1","at":2},{"id":"ipad2","at":3}],"removed":[]}"#
try? ipad2.write(toFile: ip, atomically: true, encoding: .utf8)
let mac2 = #"{"version":1,"strokes":[{"id":"ipad1","at":1},{"id":"mac1","at":2},{"id":"mac2","at":4}],"removed":[]}"#
check(ink.save(mac2) == .mergeFirst(ipad2) && disk(ip) == ipad2, "a post never writes over strokes this host has not seen")
check(ink.waiting == nil, "the post that missed them is dropped: the page merges and posts the union")
let union2 = #"{"version":1,"strokes":[{"id":"ipad1","at":1},{"id":"mac1","at":2},{"id":"ipad2","at":3},{"id":"mac2","at":4}],"removed":[]}"#
inkWriteFails = true
check(ink.save(union2) == .wait && ink.seen == ipad2 && ink.waiting == union2, "a failed write keeps the post and does not move seen")
inkWriteFails = false
check(ink.retry() == .write && disk(ip) == union2 && ink.waiting == nil, "the retry writes it")
check(ink.save(union2) == .write && ink.seen == union2, "posting what was just written writes nothing new")
let ink2 = DraftpadInk(path: p("none.ink.json"))
check(ink2.load() == "" && ink2.seen == "", "no sidecar yet loads as empty, seen")
check(DraftpadInk.json(from: ["version": 1]) == #"{"version":1}"# && DraftpadInk.json(from: "s") == "s" && DraftpadInk.json(from: nil) == nil,
      "the page's merged ink becomes JSON text")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
