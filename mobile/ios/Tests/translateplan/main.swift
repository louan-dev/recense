// Derived from Spec: FEAT-10 (amended 2026-11-18) · the translation plan, no translator.
// swiftc -O shared/ShowsKit/Sources/ShowsKit/Langs.swift shared/translateplan.swift mobile/ios/Tests/translateplan/main.swift -o "$TMPDIR/translateplan" && "$TMPDIR/translateplan"
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { failed += 1; print("FAIL L\(line): \(what)") } }

// each line's own language (NaturalLanguage, en/vi/fr only)
check(TranslatePlan.detect("The court held that the contract was void because the statute required writing.", fallback: "vi") == "en", "English")
check(TranslatePlan.detect("Tòa án phán quyết rằng hợp đồng vô hiệu vì luật yêu cầu văn bản.", fallback: "en") == "vi", "Vietnamese")
check(TranslatePlan.detect("La cour a jugé que le contrat était nul, néanmoins le demandeur a fait appel.", fallback: "en") == "fr", "French")
check(TranslatePlan.detect("Okay.", fallback: "vi") == "vi", "too short → the file's language")
check(TranslatePlan.detect("Hmm", fallback: "de") == "en", "fallback outside en/vi/fr → en")

// targets: Follow in (auto is no longer one: a kept "auto" reads as Français)
check(TranslatePlan.choices == ["en", "fr", "vi", "off"], "Follow in: three languages, then Off")
check(TranslatePlan.target(source: "en", choice: "auto") == "fr", "retired auto → French")
check(TranslatePlan.target(source: "fr", choice: "auto") == nil, "retired auto, French line → none")
check(TranslatePlan.target(source: "fr", choice: "vi") == "vi", "chosen")
check(TranslatePlan.target(source: "vi", choice: "vi") == nil, "already in the target → none")
check(TranslatePlan.target(source: "en", choice: "off") == nil, "off → none")

// Heard in: an override skips detection
check(TranslatePlan.source("The court held", heard: "vi", detect: { _ in "en" }) == "vi", "override wins")
check(TranslatePlan.source("The court held", heard: "auto", detect: { _ in "en" }) == "en", "Auto-detect detects")

// the plan
let lang = ["a": "en", "b": "vi", "c": "fr", "d": "en", "e": "vi"]
let lines = [("1", "a"), ("2", "b"), ("3", "c"), ("4", "d"), ("5", "e"), ("6", "  ")].map { (id: $0.0, text: $0.1) }
let p = TranslatePlan.plan(lines, choice: "en", kept: [TranslatePlan.key("en", "b"): "B-en"], detect: { lang[$0] ?? "en" })
check(p.fills["2"] == .some("B-en"), "kept translation reused")
check(p.fills["1"] == .some(nil) && p.fills["4"] == .some(nil), "lines already in English show none")
check(p.jobs == [TranslatePlan.Job(source: "fr", target: "en", ids: ["3"], texts: ["c"]),
                 TranslatePlan.Job(source: "vi", target: "en", ids: ["5"], texts: ["e"])], "no playhead: from the top: \(p.jobs)")
check(p.fills["6"] == nil && !p.jobs.contains { $0.ids.contains("6") }, "blank lines skipped")
let q = TranslatePlan.plan(lines, choice: "vi", kept: [:], detect: { lang[$0] ?? "en" })
check(q.fills["2"] == .some(nil) && q.fills["5"] == .some(nil), "lines already in Vietnamese show none")
check(Set(q.jobs.map { $0.source + ">" + $0.target }) == ["en>vi", "fr>vi"], "the rest go into Vietnamese")
let o = TranslatePlan.plan(lines, choice: "off", kept: [:], detect: { lang[$0] ?? "en" })
check(o.fills.isEmpty && o.jobs.isEmpty, "off removes nothing and translates nothing")

// playhead first: the current line alone, then after it 8 at a time, then before it, nearest chunk first
let many = (0..<30).map { (id: "L\($0)", text: "t\($0)") }
let h = TranslatePlan.plan(many, choice: "fr", kept: [:], playhead: 12, detect: { _ in "en" })
check(h.jobs.first?.ids == ["L12"], "the playhead's line goes first, alone: \(h.jobs.first?.ids ?? [])")
check(h.jobs[1].ids == (13...20).map { "L\($0)" }, "then the next 8 after it")
check(h.jobs[2].ids == (21...28).map { "L\($0)" } && h.jobs[3].ids == ["L29"], "then the rest after it")
check(h.jobs[4].ids == (4...11).map { "L\($0)" }, "then the 8 before it, read forward: \(h.jobs[4].ids)")
check(h.jobs[5].ids == (0...3).map { "L\($0)" } && h.jobs.count == 6, "then the top")
check(Set(h.jobs.flatMap(\.ids)).count == 30, "every line once")
let mixed = TranslatePlan.plan(lines, choice: "fr", kept: [:], playhead: 3, detect: { lang[$0] ?? "en" })
check(mixed.jobs.map(\.ids) == [["4"], ["5"], ["2"], ["1"]], "pairs split, nearest first: \(mixed.jobs.map(\.ids))")
check(TranslatePlan.name("fr") == "Français" && TranslatePlan.name("vi") == "Tiếng Việt", "endonyms from Langs")
check(TranslatePlan.missing("vi", "en") == "Tiếng Việt → English isn't installed: Settings › General › Language & Region › Translation Languages", "missing note")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
