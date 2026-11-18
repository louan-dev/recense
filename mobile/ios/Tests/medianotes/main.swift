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

let r = MediaNoteFiles.handle(["action": "trash", "key": key], keep: keep, trashFile: toBin)
check(r == "trashed 3", "clearing: note.md, note.ink.json, note.matter.json go to the Trash (\(r))")
check(fm.fileExists(atPath: bin.appendingPathComponent("note.md").path), "note.md is in the Trash, not deleted")
check(!fm.fileExists(atPath: keep.appendingPathComponent(key).path), "the empty folder goes")
check(bytes(media) == mediaBefore && bytes(transcript) == transcriptBefore, "the media file and its transcript are untouched")
check(bytes(draftpad) == draftBefore, "draftpad.md is untouched")
check(MediaNoteFiles.handle(["action": "save", "key": "../../etc", "text": "x"], keep: keep) == "", "a bad key writes nothing")
print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
