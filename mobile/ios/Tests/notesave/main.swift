// Regression guard: T-0114. A note that could not be read at load must never be overwritten by what was typed over the
// blank editor; "no file yet" and "cannot read it now" are different answers. Pure rules in shared/notesync.swift. Run on the Mac:
//   swiftc -O shared/notesync.swift mobile/ios/Tests/notesave/main.swift -o "$TMPDIR/notesave" && "$TMPDIR/notesave"
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failed += 1 } }

let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("recense-notesave-\(getpid())")
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: dir) }
let p = { (n: String) in (dir as NSString).appendingPathComponent(n) }

// readNote: three different answers
try? "one\ntwo".write(toFile: p("a.md"), atomically: true, encoding: .utf8)
check(readNote(p("a.md")) == .text("one\ntwo"), "a readable note is its text")
try? "".write(toFile: p("empty.md"), atomically: true, encoding: .utf8)
check(readNote(p("empty.md")) == .text(""), "an empty note is empty text, not missing")
check(readNote(p("none.md")) == .missing, "no file at all is missing")
FileManager.default.createFile(atPath: p("bad.md"), contents: Data([0xff, 0xfe, 0xfd, 0x80]))
check(readNote(p("bad.md")) == .unreadable, "a file that exists but cannot be read is unreadable, not blank")
FileManager.default.createFile(atPath: p(".gone.md.icloud"), contents: Data())
check(readNote(p("gone.md")) == .unreadable, "an iCloud placeholder (evicted, offline) is unreadable, not missing")

// planBlindSave: the editor started blank because the load could not read the note
check(planBlindSave(mine: "typed", now: .unreadable) == .wait, "still unreadable: write nothing, keep what was typed safe")
check(planBlindSave(mine: "typed", now: .missing) == .recovered(seen: "", joined: "typed"), "the file really is not there: write what was typed")
check(planBlindSave(mine: "", now: .text("the note")) == .recovered(seen: "the note", joined: "the note"),
      "readable now, nothing typed: show the note, change nothing")
check(planBlindSave(mine: "typed", now: .text("the note")) == .recovered(seen: "the note", joined: "the note\ntyped"),
      "readable now, something typed: the note first, what was typed after it; neither is lost")
check(planBlindSave(mine: "typed", now: .text("the note\n")) == .recovered(seen: "the note\n", joined: "the note\ntyped"),
      "a note ending in a newline gets no blank line")
check(planBlindSave(mine: "same", now: .text("same")) == .recovered(seen: "same", joined: "same"), "typed the same as the note: written once")
check(planBlindSave(mine: "typed", now: .text("")) == .recovered(seen: "", joined: "typed"), "an empty note takes what was typed")

// Regression guard: T-0114 review F1. Typed text that could not reach the note is kept one file per launch (a second
// launch never replaces the first's), and joined after the note, in order, once the note reads; the files are moved aside
// only after that write succeeds.
let ud = URL(fileURLWithPath: p("support"))
let utc = TimeZone(identifier: "UTC")!
let l1 = Date(timeIntervalSince1970: 1_700_000_000), l2 = Date(timeIntervalSince1970: 1_700_000_100)
let u1 = Unsaved.file(in: ud, launch: l1, zone: utc), u2 = Unsaved.file(in: ud, launch: l2, zone: utc)
check(u1.lastPathComponent == "draftpad-unsaved 2023-11-14 221320.md", "the file is named by its launch")
Unsaved.keep("A", as: u1); Unsaved.keep("A2", as: u1)
check(Unsaved.files(in: ud).count == 1, "one launch keeps one file, the latest text replacing its own earlier one")
Unsaved.keep("B", as: u2)
check(Unsaved.files(in: ud).count == 2, "a second launch leaves a second file; the first is not replaced")
check(Unsaved.files(in: ud).compactMap { try? String(contentsOf: $0, encoding: .utf8) } == ["A2", "B"], "oldest launch first")
var wrote = ""
let rec = Unsaved.recover(note: "the note", in: ud) { wrote = $0; return true }
check(rec == "the note\nA2\nB" && wrote == rec, "the note, then each launch's text in order, is what gets written")
check(Unsaved.files(in: ud).isEmpty, "the files are moved aside once that write succeeded")
check(FileManager.default.fileExists(atPath: ud.appendingPathComponent("recovered").appendingPathComponent(u1.lastPathComponent).path),
      "moved to recovered/, not deleted")
let cText = "text typed while offline"
Unsaved.keep(cText, as: u1)
check(Unsaved.recover(note: "n", in: ud, write: { _ in false }) == nil && Unsaved.files(in: ud).count == 1, "a failed write leaves the files where they are")
check(Unsaved.join(note: "x\n\(cText)\ny", texts: [cText]) == "x\n\(cText)\ny", "text the note already holds is not added again")
check(Unsaved.recover(note: "x\n\(cText)\ny", in: ud, write: { _ in false }) == nil && Unsaved.files(in: ud).isEmpty,
      "files whose text the note already holds are moved aside with nothing to write")
check(Unsaved.join(note: "a banana and a cat", texts: ["a"]) == "a banana and a cat\na", "a short text is always added, never 'found' inside the note and lost")
Unsaved.keep("D", as: u2); Unsaved.settle(u2, in: ud)
check(Unsaved.files(in: ud).isEmpty, "a launch's file is settled once its text reached the note normally")
check(Unsaved.join(note: "", texts: ["only"]) == "only" && Unsaved.join(note: "n\n", texts: ["t"]) == "n\nt", "join: empty note, trailing newline")

// F2: a conflict copy never takes the name of one already there
let nn = p("n.md")
let s1 = freeSiblingPath(nn, l1, zone: utc)
check(s1.hasSuffix("n (other device 2023-11-14 2213).md"), "the conflict copy is named as before")
FileManager.default.createFile(atPath: s1, contents: Data("first".utf8))
let s2 = freeSiblingPath(nn, l1, zone: utc)
check(s2 != s1 && s2.hasSuffix(") 2.md"), "a second conflict in the same minute gets \" 2\", the first is not replaced")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
