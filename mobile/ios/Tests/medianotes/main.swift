// Derived from Spec: FEAT-23 P0 check 2 / P0c check 2 (hosts): typing in the note never changes draftpad.md;
// clearing the note leaves the media file. The shared files rule (shared/medianotefiles.swift). Run on the Mac:
//   swiftc -O shared/notesync.swift shared/medianotefiles.swift mobile/ios/Tests/medianotes/main.swift -o "$TMPDIR/medianotes" && "$TMPDIR/medianotes"
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failed += 1 } }

let fm = FileManager.default
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appendingPathComponent("recense-medianotes-\(getpid())")
let keep = root.appendingPathComponent("keep"), vault = root.appendingPathComponent("vault"), bin = root.appendingPathComponent("Trash")
for d in [keep, vault, bin] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
defer { try? fm.removeItem(at: root) }
let key = "0123456789abcdef01234567"
let draftpad = vault.appendingPathComponent("draftpad.md")
let transcript = keep.appendingPathComponent("\(key).v2.json")   // the flat transcript beside the note's folder
let media = root.appendingPathComponent("Music/Song.m4a")
try? fm.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
try! "the page".write(to: draftpad, atomically: true, encoding: .utf8)
try! "{\"lines\":[]}".write(to: transcript, atomically: true, encoding: .utf8)
try! Data([1, 2, 3]).write(to: media)
let bytes = { (u: URL) in (try? Data(contentsOf: u)) ?? Data() }
let draftBefore = bytes(draftpad), mediaBefore = bytes(media), transcriptBefore = bytes(transcript)
let toBin: (URL, URL?) -> Bool = { f, _ in (try? fm.moveItem(at: f, to: bin.appendingPathComponent(f.lastPathComponent))) != nil }
let note = MediaNoteFiles.url(key, MediaNoteFiles.text, keep: keep)

check(MediaNoteFiles.isKey(key) && !MediaNoteFiles.isKey(key.uppercased()) && !MediaNoteFiles.isKey(String(key.dropLast())), "a key is 24 lowercase hex")
check(MediaNoteFiles.payload(key: key, keep: keep).map { $0.contains("\"text\":\"\"") } == true, "no note yet: the page opens empty")
check(!fm.fileExists(atPath: note.path), "opening writes nothing (rule 8)")

MediaNoteFiles.handle(["action": "save", "key": key, "text": "first words\n"], keep: keep, trashFile: toBin)
check((try? String(contentsOf: note, encoding: .utf8)) == "first words\n", "a save writes keep/<key>/note.md")
check(fm.fileExists(atPath: transcript.path), "the note's folder sits beside the flat transcript; no collision")
MediaNoteFiles.handle(["action": "append", "key": key, "line": "[00:04](recense://\(key)?t=4) a line note"], keep: keep, trashFile: toBin)
check((try? String(contentsOf: note, encoding: .utf8)) == "first words\n[00:04](recense://\(key)?t=4) a line note\n", "a pane line note joins the note (A1 rule 9)")
MediaNoteFiles.handle(["action": "ink", "key": key, "json": "{\"version\":1,\"strokes\":[],\"removed\":[]}"], keep: keep, trashFile: toBin)
MediaNoteFiles.handle(["action": "matter", "key": key, "json": "{\"version\":1,\"passages\":{},\"log\":[]}"], keep: keep, trashFile: toBin)
check(bytes(draftpad) == draftBefore, "typing in the note never changes draftpad.md")

_ = MediaNoteFiles.payload(key: key, keep: keep)   // the page empties the note it shows: opened after the line note
let r = MediaNoteFiles.handle(["action": "trash", "key": key], keep: keep, trashFile: toBin)
check(r == "trashed 3", "clearing: note.md, note.ink.json, note.matter.json go to the Trash (\(r))")
check(fm.fileExists(atPath: bin.appendingPathComponent("note.md").path), "note.md is in the Trash, not deleted")
check(!fm.fileExists(atPath: keep.appendingPathComponent(key).path), "the empty folder goes")
check(bytes(media) == mediaBefore && bytes(transcript) == transcriptBefore, "the media file and its transcript are untouched")
check(bytes(draftpad) == draftBefore, "draftpad.md is untouched")
check(MediaNoteFiles.handle(["action": "save", "key": "../../etc", "text": "x"], keep: keep) == "", "a bad key writes nothing")
// review 2: a note write that fails is kept in the Unsaved folder and written by the next retry
let roKeep = root.appendingPathComponent("rokeep"), unsaved = root.appendingPathComponent("Unsaved")
try? fm.createDirectory(at: roKeep.appendingPathComponent(key), withIntermediateDirectories: true)
try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roKeep.appendingPathComponent(key).path)
let failedSave = MediaNoteFiles.handle(["action": "save", "key": key, "text": "words that must not be lost"], keep: roKeep, unsaved: unsaved)
check(failedSave.hasPrefix("could not write; kept in"), "a failed note write is kept (\(failedSave))")
let parked = MediaNoteFiles.pending(unsaved)
check(parked.count == 1 && (try? String(contentsOf: parked[0], encoding: .utf8)) == "words that must not be lost", "the text is in the Unsaved file")
check(MediaNoteFiles.retry(keep: roKeep, unsaved: unsaved) == 0 && MediaNoteFiles.pending(unsaved).count == 1, "still read-only: the retry keeps it waiting")
try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roKeep.appendingPathComponent(key).path)
check(MediaNoteFiles.retry(keep: roKeep, unsaved: unsaved) == 1, "writable again: the retry writes it")
check((try? String(contentsOf: MediaNoteFiles.url(key, MediaNoteFiles.text, keep: roKeep), encoding: .utf8)) == "words that must not be lost", "note.md holds the kept words")
check(MediaNoteFiles.pending(unsaved).isEmpty && fm.fileExists(atPath: unsaved.appendingPathComponent("recovered").path), "settled into recovered/, not deleted")
// Regression guard: FEAT-23 review-2 item 1
// a parked save is never replayed blind: note.md changed since the page opened it (a carry, a later append) stays,
// and the parked text goes beside it as carry's conflict sibling.
let k1 = root.appendingPathComponent("keep1"), u1 = root.appendingPathComponent("Unsaved1")
let n1 = MediaNoteFiles.url(key, MediaNoteFiles.text, keep: k1)
try? fm.createDirectory(at: n1.deletingLastPathComponent(), withIntermediateDirectories: true)
try! "opened".write(to: n1, atomically: true, encoding: .utf8)
_ = MediaNoteFiles.payload(key: key, keep: k1)
try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: n1.deletingLastPathComponent().path)
check(MediaNoteFiles.handle(["action": "save", "key": key, "text": "parked words"], keep: k1, unsaved: u1).hasPrefix("could not write; kept in"), "item 1: the save is parked")
try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: n1.deletingLastPathComponent().path)
try! "newer".write(to: n1, atomically: true, encoding: .utf8)   // carry brings another device's note meanwhile
check(MediaNoteFiles.retry(keep: k1, unsaved: u1, device: "Test") == 1, "item 1: the retry settles the parked save")
check((try? String(contentsOf: n1, encoding: .utf8)) == "newer", "item 1: the newer note.md is not overwritten")
let sibs1 = ((try? fm.contentsOfDirectory(atPath: n1.deletingLastPathComponent().path)) ?? []).filter { $0.hasPrefix("note (Test ") && $0.hasSuffix(".md") }
check(sibs1.count == 1 && (try? String(contentsOf: n1.deletingLastPathComponent().appendingPathComponent(sibs1[0]), encoding: .utf8)) == "parked words", "item 1: the parked text is in the conflict sibling (\(sibs1))")
// Regression guard: FEAT-23 review-2 item 2
// an open note's save never overwrites a note.md that changed since the page opened it (a carried iPad edit):
// both texts stay under keep/<key>/, and later autosaves update the same sibling instead of making more.
let k2 = root.appendingPathComponent("keep2")
let n2 = MediaNoteFiles.url(key, MediaNoteFiles.text, keep: k2), d2 = n2.deletingLastPathComponent()
try? fm.createDirectory(at: d2, withIntermediateDirectories: true)
try! "opened".write(to: n2, atomically: true, encoding: .utf8)
_ = MediaNoteFiles.payload(key: key, keep: k2)
check(MediaNoteFiles.handle(["action": "save", "key": key, "text": "opened, typed"], keep: k2, device: "Test") == "wrote note.md", "item 2: unchanged on disk: the save writes note.md")
try! "theirs".write(to: n2, atomically: true, encoding: .utf8)   // carry replaces it with the iPad's edit
let r2 = MediaNoteFiles.handle(["action": "save", "key": key, "text": "mine"], keep: k2, device: "Test")
check(r2.hasPrefix("kept beside"), "item 2: changed on disk: kept beside (\(r2))")
MediaNoteFiles.handle(["action": "save", "key": key, "text": "mine, more"], keep: k2, device: "Test")
let sibs2 = ((try? fm.contentsOfDirectory(atPath: d2.path)) ?? []).filter { $0.hasPrefix("note (Test ") }
check((try? String(contentsOf: n2, encoding: .utf8)) == "theirs", "item 2: theirs stays note.md")
check(sibs2.count == 1 && (try? String(contentsOf: d2.appendingPathComponent(sibs2[0]), encoding: .utf8)) == "mine, more", "item 2: mine is in one sibling, kept current (\(sibs2))")
let t2 = MediaNoteFiles.handle(["action": "trash", "key": key], keep: k2, trashFile: toBin)
check(t2.hasPrefix("trashed 0") && (try? String(contentsOf: n2, encoding: .utf8)) == "theirs", "item 2: emptying the page never trashes a note.md it did not see (\(t2))")
// Regression guard: FEAT-23 review-2 item 3
// parked writes replay in the order they happened, whatever their action: a line note parked after a save joins it.
let k3 = root.appendingPathComponent("keep3"), u3 = root.appendingPathComponent("Unsaved3")
let n3 = MediaNoteFiles.url(key, MediaNoteFiles.text, keep: k3), d3 = n3.deletingLastPathComponent()
try? fm.createDirectory(at: d3, withIntermediateDirectories: true)
try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: d3.path)
MediaNoteFiles.handle(["action": "save", "key": key, "text": "T1\n"], keep: k3, unsaved: u3)
usleep(5_000)
MediaNoteFiles.handle(["action": "append", "key": key, "line": "L"], keep: k3, unsaved: u3)
check(MediaNoteFiles.pending(u3).count == 2, "item 3: both parked")
try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d3.path)
MediaNoteFiles.retry(keep: k3, unsaved: u3, device: "Test")
check((try? String(contentsOf: n3, encoding: .utf8)) == "T1\nL\n", "item 3: the save, then the later line note (\((try? String(contentsOf: n3, encoding: .utf8)) ?? "nil"))")
check(MediaNoteFiles.pending(u3).isEmpty, "item 3: both settled")
print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
