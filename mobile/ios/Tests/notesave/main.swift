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

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
