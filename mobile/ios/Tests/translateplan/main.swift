// Derived from Spec: FEAT-10 · the translation plan, no translator.
// swiftc -O shared/translateplan.swift mobile/ios/Tests/translateplan/main.swift -o "$TMPDIR/translateplan" && "$TMPDIR/translateplan"
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { failed += 1; print("FAIL L\(line): \(what)") } }

// each line's own language (NaturalLanguage, en/vi/fr only)
check(TranslatePlan.detect("The court held that the contract was void because the statute required writing.", fallback: "vi") == "en", "English")
check(TranslatePlan.detect("Tòa án phán quyết rằng hợp đồng vô hiệu vì luật yêu cầu văn bản.", fallback: "en") == "vi", "Vietnamese")
check(TranslatePlan.detect("La cour a jugé que le contrat était nul, néanmoins le demandeur a fait appel.", fallback: "en") == "fr", "French")
check(TranslatePlan.detect("Okay.", fallback: "vi") == "vi", "too short → the file's language")
check(TranslatePlan.detect("Hmm", fallback: "de") == "en", "fallback outside en/vi/fr → en")

// targets
check(TranslatePlan.target(source: "en", choice: "auto") == "vi", "auto: en → vi")
check(TranslatePlan.target(source: "fr", choice: "auto") == "en", "auto: fr → en")
check(TranslatePlan.target(source: "vi", choice: "auto") == "en", "auto: vi → en")
check(TranslatePlan.target(source: "fr", choice: "vi") == "vi", "chosen")
check(TranslatePlan.target(source: "vi", choice: "vi") == nil, "already in the target → none")
check(TranslatePlan.target(source: "en", choice: "off") == nil, "off → none")

// the plan
let lang = ["a": "en", "b": "vi", "c": "fr", "d": "en", "e": "vi"]
let lines = [("1", "a"), ("2", "b"), ("3", "c"), ("4", "d"), ("5", "e"), ("6", "  ")].map { (id: $0.0, text: $0.1) }
let p = TranslatePlan.plan(lines, choice: "auto", kept: [TranslatePlan.key("vi", "d"): "D-vi"], detect: { lang[$0] ?? "en" })
check(p.fills["4"] == .some("D-vi"), "kept translation reused")
check(p.jobs == [TranslatePlan.Job(source: "en", target: "vi", ids: ["1"], texts: ["a"]),
                 TranslatePlan.Job(source: "vi", target: "en", ids: ["2", "5"], texts: ["b", "e"]),
                 TranslatePlan.Job(source: "fr", target: "en", ids: ["3"], texts: ["c"])], "grouped by pair, in order: \(p.jobs)")
check(p.fills["6"] == nil && !p.jobs.contains { $0.ids.contains("6") }, "blank lines skipped")
let q = TranslatePlan.plan(lines, choice: "vi", kept: [:], detect: { lang[$0] ?? "en" })
check(q.fills["2"] == .some(nil) && q.fills["5"] == .some(nil), "lines already in Vietnamese show none")
check(Set(q.jobs.map { $0.source + ">" + $0.target }) == ["en>vi", "fr>vi"], "the rest go into Vietnamese")
let o = TranslatePlan.plan(lines, choice: "off", kept: [:], detect: { lang[$0] ?? "en" })
check(o.fills.isEmpty && o.jobs.isEmpty, "off removes nothing and translates nothing")
check(TranslatePlan.missing("vi", "en") == "Tiếng Việt → English isn't installed: Settings › General › Language & Region › Translation Languages", "missing note")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
