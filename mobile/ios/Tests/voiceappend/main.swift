// Derived from Spec: FEAT-08 (P2). A spoken passage lands at the end of draftpad.md as its own passage through
// planBlindSave, keeps its seed, and is never lost when the note cannot be read; its passage goes into draftpad.matter.json,
// and a sidecar another writer changed is merged by the page before it is written. Run on the Mac:
//   swiftc -O shared/notesync.swift shared/voiceappend.swift mobile/ios/Tests/voiceappend/main.swift -o "$TMPDIR/voiceappend" && "$TMPDIR/voiceappend"
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failed += 1 } }

// The plan: one blank line before the spoken passage, whatever the note ends with.
func joined(_ p: BlindSave) -> String? { if case .recovered(_, let j) = p { return j }; return nil }
check(joined(VoiceAppend.plan("said", now: .text("note"))) == "note\n\nsaid", "after a note with no newline")
check(joined(VoiceAppend.plan("said", now: .text("note\n"))) == "note\n\nsaid", "after a note ending in a newline")
check(joined(VoiceAppend.plan("said", now: .text("note\n\n"))) == "note\n\nsaid", "after a note ending in a blank line")
check(joined(VoiceAppend.plan("  said \n", now: .text(""))) == "said", "an empty note: the passage alone")
check(joined(VoiceAppend.plan("said", now: .missing)) == "said", "no note yet: the passage starts it")
check(VoiceAppend.plan("said", now: .unreadable) == .wait, "a note that cannot be read is never written")
check(joined(VoiceAppend.plan("  ", now: .text("note"))) == "note", "silence adds nothing")
check(joined(VoiceAppend.plan("Tòa tuyên hợp đồng vô hiệu.", now: .text("Le contrat"))) == "Le contrat\n\nTòa tuyên hợp đồng vô hiệu.", "Vietnamese after French, every diacritic")

// The passage goes into draftpad.matter.json beside the note (editor/src/matter.js shape), and every passage stays.
let old = #"{"log":[{"id":"t1:1:5:Mac"}],"passages":{"t1":{"born":"type","id":"t1"}},"version":1}"#
let body = "typed on the Mac\n\nspoken on the walk"
let added = VoiceAppend.addPassage(to: old, text: " spoken on the walk \n", body: body, device: "iphone", at: Date(timeIntervalSince1970: 2), id: "X")
let obj = (try? JSONSerialization.jsonObject(with: Data(added.utf8))) as? [String: Any]
let passages = obj?["passages"] as? [String: Any] ?? [:]
check(passages["t1"] != nil && (obj?["log"] as? [Any])?.count == 1, "the old passage and log stay")
let vo = passages["vo-x"] as? [String: Any] ?? [:]
let forms = vo["forms"] as? [String: Any] ?? [:]
let seedObj = vo["seed"] as? [String: Any] ?? [:]
check(vo["born"] as? String == "voice" && seedObj["input"] as? String == "voice" && seedObj["device"] as? String == "iphone"
      && seedObj["time"] as? Int == 2000, "born voice; seed: voice, iphone, ms time")
let typeForm = forms["type"] as? [String: Any] ?? [:]
check(typeForm["quote"] as? String == "spoken on the walk" && typeForm["prefix"] as? String == "typed on the Mac\n\n", "its words point into the body")
let entry = ((forms["voice"] as? [String: Any])?["spoken"] as? [[String: Any]])?.first ?? [:]
check((entry["typed"] as? [String: Any])?["quote"] as? String == "spoken on the walk", "already typed: Make text never types it twice")
check((entry["words"] as? [[String: String]])?.map { $0["w"]! } == ["spoken", "on", "the", "walk"], "its words")
if CommandLine.arguments.contains("--print") { print(VoiceAppend.addPassage(to: nil, text: "spoken on the walk", body: body, device: "iphone", at: Date(timeIntervalSince1970: 2), id: "X")) }
check(((try? JSONSerialization.jsonObject(with: Data(VoiceAppend.addPassage(to: "garbage", text: "a", body: "a", device: "mac", at: Date()).utf8))) as? [String: Any])?["version"] as? Int == 1,
      "a broken sidecar starts fresh ({version:1})")
check(VoiceAppend.quote("walk", endingAt: "a walk.") == nil, "no quote when the words are not at the end")
let longPre = String(repeating: "é", count: 40) + "x"
check(VoiceAppend.quote("x", endingAt: longPre)?["prefix"] == String(repeating: "é", count: 32), "32 units of context, as matter.js")

// The whole path on disk: note, sidecar, and the unreadable case.
let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recense-voiceappend-\(getpid())")
let vault = dir.appendingPathComponent("vault"), unsaved = dir.appendingPathComponent("unsaved")
try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let note = vault.appendingPathComponent("draftpad.md")
try? "typed on the Mac\n".write(to: note, atomically: true, encoding: .utf8)
let r = VoiceAppend.append("spoken on the walk", vault: vault, device: "iphone", unsavedDir: unsaved)
check(r == .added("typed on the Mac\n\nspoken on the walk"), "added to the note")
check((try? String(contentsOf: note, encoding: .utf8)) == "typed on the Mac\n\nspoken on the walk", "the note on disk")
check((try? String(contentsOf: vault.appendingPathComponent("draftpad.matter.json"), encoding: .utf8))?.contains("\"born\":\"voice\"") == true, "its passage on disk")
_ = VoiceAppend.append("second aside", vault: vault, device: "iphone", unsavedDir: unsaved)
let s2 = (try? String(contentsOf: vault.appendingPathComponent("draftpad.matter.json"), encoding: .utf8)) ?? ""
check(s2.components(separatedBy: "\"born\":\"voice\"").count == 3, "two asides, two passages")
check((try? String(contentsOf: note, encoding: .utf8)) == "typed on the Mac\n\nspoken on the walk\n\nsecond aside", "in order on the page")

// Unreadable: an iCloud placeholder without the file. The text waits in the unsaved folder, the note is not written.
let v2 = dir.appendingPathComponent("v2"); try? FileManager.default.createDirectory(at: v2, withIntermediateDirectories: true)
try? "".write(to: v2.appendingPathComponent(".draftpad.md.icloud"), atomically: true, encoding: .utf8)
if case .kept(let f) = VoiceAppend.append("kept safe", vault: v2, device: "iphone", unsavedDir: unsaved) {
    check((try? String(contentsOf: f, encoding: .utf8)) == "\nkept safe", "kept in the unsaved folder")
    check(Unsaved.join(note: "the note", texts: ["\nkept safe"]) == "the note\n\nkept safe", "and joins later as its own passage")
    check(!FileManager.default.fileExists(atPath: v2.appendingPathComponent("draftpad.md").path), "the note was not created over the placeholder")
} else { check(false, "kept in the unsaved folder") }

// The page's sidecar never writes over one another writer changed: the host hands it to the page to merge first.
check(MatterWrite.plan(json: "P", disk: nil, seen: nil) == .write, "no file yet: write")
check(MatterWrite.plan(json: "P2", disk: "P1", seen: "P1") == .write, "the file is ours: write")
check(MatterWrite.plan(json: "P2", disk: "D", seen: "P1") == .mergeFirst("D"), "the intent or another device wrote: merge first")
check(MatterWrite.plan(json: "U", disk: "D", seen: "D") == .write, "after the page merged it: write the union")
check(MatterWrite.plan(json: "D", disk: "D", seen: nil) == .write, "same as the file: write (no loop)")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
