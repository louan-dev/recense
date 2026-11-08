import Foundation
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif
#if os(macOS)
import IOKit.ps
#elseif canImport(UIKit)
import UIKit
#endif

/// Recense what you typed (Draftpad's Recense layer; brief: .handoff/coordinator/recense-the-text-brief.md), one copy for
/// the Mac and iOS. The page (editor/src/recense.js) cuts a page into sections of at most ~1,500 words and keys every
/// sentence by its hash; this file answers with, all on the device:
/// · the Source lines: each sentence as a transcript Line (shared/transcript.swift), its language read per phrase, and
///   its translation from Apple's Translation with the languages installed (line-level until M2's word map);
/// · the model lenses from Apple's on-device model (FoundationModels, 4,096-token context, Vietnamese supported: M0
///   spike): Gist (the chapter title, a one-line gist and a line per paragraph) and Reformat as IRAC, each line citing
///   its source sentences. The page checks every citation and drops a line that fails.
/// With no model (Apple Intelligence off, or the language unsupported) it says so and the page's extractive lenses,
/// labelled as such, stand in. Nothing here touches the network.
enum RecenseText {
    struct Sentence: Codable { let key: String; let text: String; var p: Int? = nil }   // p: its paragraph
    struct Section: Codable { let key: String; let sentences: [Sentence]; var kind: String? = nil }

    // MARK: Source lines

    /// Each sentence as a Line: its words, each tagged with the sentence's language when written in its script.
    static func lines(_ sentences: [Sentence]) -> [Line] {
        sentences.enumerated().map { i, s in
            // Split at spaces, punctuation kept on its word, as transcripts and the page (typedlines.js) have them.
            var words = s.text.split(whereSeparator: \.isWhitespace).map { Word(text: String($0), start: 0, end: 0) }
            if let lang = dominantLanguage(s.text)?.code, scriptOf(text: s.text) == scriptOf(language: lang) {
                for k in words.indices { words[k].lang = lang }
            }
            return Line(id: i, words: words, english: nil)
        }
    }

    /// English is read into Vietnamese, everything else into English, unless the page picked a language.
    static func target(for source: String, requested: String?) -> String {
        if let r = requested, !r.isEmpty, r != source { return r }
        return source == "en" ? "vi" : "en"
    }

    /// Lines translated on the device, in order; nil when the pair isn't installed (or the OS is older than 26).
    static func translate(_ texts: [String], from: String, to: String) async -> [String]? {
        guard !texts.isEmpty else { return [] }
        #if canImport(Translation)
        if #available(macOS 26.0, iOS 26.0, *) {
            let src = Locale.Language(identifier: from), dst = Locale.Language(identifier: to)
            guard await LanguageAvailability().status(from: src, to: dst) == .installed else { return nil }
            let session = TranslationSession(installedSource: src, target: dst)
            do {
                let reqs = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
                var out = texts.map { _ in "" }
                for r in try await session.translations(from: reqs) {
                    if let i = Int(r.clientIdentifier ?? ""), i < out.count { out[i] = r.targetText }
                }
                return out
            } catch { return nil }
        }
        #endif
        return nil
    }

    /// The Source lens: each sentence's translation, chosen per sentence: English → Vietnamese, anything else →
    /// English, unless the page picked a language (then every sentence not already in it goes into it).
    static func source(_ sentences: [Sentence], target requested: String?) async -> [String: Any] {
        var ls = lines(sentences)
        let all = sentences.map(\.text).joined(separator: " ")
        let src = dominantLanguage(all)?.code ?? "en"
        let langs = sentences.map { dominantLanguage($0.text)?.code ?? src }
        let dsts = langs.map { target(for: $0, requested: requested) }
        var missing = ""
        // One request per language pair, so a mixed page asks each installed pair for its own sentences.
        var byPair: [String: [Int]] = [:]
        for i in sentences.indices where langs[i] != dsts[i] { byPair["\(langs[i])>\(dsts[i])", default: []].append(i) }
        for (pair, idx) in byPair {
            let lr = pair.split(separator: ">").map(String.init)
            if let out = await translate(idx.map { sentences[$0].text }, from: lr[0], to: lr[1]) {
                for (k, i) in idx.enumerated() { ls[i].english = out[k].split(separator: " ").map { EnWord(w: String($0), s: []) } }
            } else {
                missing = "Translation \(languageName(lr[0])) → \(languageName(lr[1])) isn't installed: Settings › General › Language & Region › Translation Languages"
            }
        }
        for i in sentences.indices where ls[i].english == nil { ls[i].english = [] }
        let lineJSON = (try? JSONEncoder().encode(ls)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
        return ["source": src, "targets": dsts, "keys": sentences.map(\.key), "lines": lineJSON, "missing": missing]
    }

    /// The section's sentences not written in `lang`, translated into it (installed pairs only): the citation check
    /// reads a lens line in `lang` against these, so an English line about a Vietnamese sentence can be verified.
    static func sourceIn(_ lang: String, _ sentences: [Sentence]) async -> [String: String] {
        var byLang: [String: [Sentence]] = [:]
        for x in sentences {
            let l = dominantLanguage(x.text)?.code ?? lang
            if l != lang { byLang[l, default: []].append(x) }
        }
        var out: [String: String] = [:]
        for (l, xs) in byLang {
            guard let tr = await translate(xs.map(\.text), from: l, to: lang) else { continue }
            for (x, t) in zip(xs, tr) { out[x.key] = t }
        }
        return out
    }

    /// A line written partly in another language: two or more 3-word stretches read confidently as another language.
    /// (One is noise, or a case name kept as it is.)
    static func isMixed(_ text: String, lang: String, among: [String]) -> Bool {
        let w = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard w.count >= 3 else { return false }
        var other = 0
        for i in 0...(w.count - 3) {
            if let (c, p) = dominantLanguage(w[i..<(i + 3)].joined(separator: " "), among: among), p >= 0.8, c != lang { other += 1 }
        }
        return other >= 2
    }

    /// The other language for Retell: English ⇄ Vietnamese, anything else → English.
    static func otherLanguage(_ lang: String) -> String { lang == "en" ? "vi" : "en" }

    // MARK: Model lenses

    /// Whether the on-device model can write lenses for this language now ("" when it can, else the reason).
    static func modelUnavailable(lang: String) -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let m = SystemLanguageModel.default
            guard case .available = m.availability else { return "Apple Intelligence is off" }
            return m.supportsLocale(Locale(identifier: lang)) ? "" : "\(languageName(lang)) isn't supported by the on-device model"
        }
        #endif
        return "needs macOS or iOS 26"
    }

    /// The asked-for lenses for one section, citing sentence keys. nil when the model can't (the page goes extractive).
    static func lenses(_ section: Section, want: Set<String> = ["gist", "reformat"]) async -> [String: Any]? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) { return await modelLenses(section, want: want) }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    /// The lens shapes for guided generation. Built as schemas at run time rather than with @Generable, because the Mac
    /// app compiles with the Command Line Tools, which ship no macro plugins; each field still carries its guide (the
    /// description the model reads), exactly what @Guide would have generated.
    @available(macOS 26.0, iOS 26.0, *)
    static func field(_ name: String, _ guide: String, _ s: DynamicGenerationSchema) -> DynamicGenerationSchema.Property {
        DynamicGenerationSchema.Property(name: name, description: guide, schema: s)
    }
    @available(macOS 26.0, iOS 26.0, *)
    static func cited(_ name: String, _ guide: String) -> DynamicGenerationSchema.Property {
        field(name, guide, DynamicGenerationSchema(referenceTo: "Cited"))
    }
    @available(macOS 26.0, iOS 26.0, *)
    static var citedSchema: DynamicGenerationSchema {
        DynamicGenerationSchema(name: "Cited", properties: [
            field("text", "The text of this line, in your own words, short", DynamicGenerationSchema(type: String.self)),
            field("from", "The ids of the sentences it comes from, like s2; only ids that appear in the notes",
                  DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self)))
        ])
    }
    /// Paragraph groups: the sentence indices of each paragraph, in order.
    static func paragraphs(_ sentences: [Sentence]) -> [[Int]] {
        var out: [[Int]] = []
        for i in sentences.indices {
            if i == 0 || sentences[i].p != sentences[i - 1].p { out.append([]) }
            out[out.count - 1].append(i)
        }
        return out
    }
    static let gistChunk = 6       // paragraphs per Gist call: 6 short lines + title + page gist fit in 700 tokens
    static let retellChunk = 4     // two lines a paragraph

    /// Gist: one field per paragraph (p1 … pN), so the answer has exactly one line for each; on the first call also
    /// the chapter title and the page gist (up to three lines).
    @available(macOS 26.0, iOS 26.0, *)
    static func gistSchema(paragraphs ps: [[Int]], first: Bool, pageLines: Int, lang: String) throws -> GenerationSchema {
        let name = languageName(lang)
        var props: [DynamicGenerationSchema.Property] = []
        // The title first: it is short, and a capped answer must still have it (M2 check: put last, it was cut off).
        if first { props.append(field("title", "A chapter title for these notes, in \(name): 2 to 6 words, no quotes", DynamicGenerationSchema(type: String.self))) }
        // Paragraph lines next, then the page gist that joins them: written in that order, the page lines connect the
        // paragraphs instead of copying them (M2 check: written first, the paragraph lines repeated them word for word).
        for (n, idx) in ps.enumerated() {
            let ids = idx.map { "s\($0 + 1)" }.joined(separator: ", ")
            props.append(cited("p\(n + 1)", "Paragraph \(n + 1) (sentences \(ids)) in one short line in \(name), in your own sentence but keeping the notes' key terms (names, legal terms, numbers); cite only \(ids)"))
        }
        if first {
            props.append(field("page", "The whole stretch in \(pageLines) short lines, in \(name), each joining ideas from different paragraphs, using the notes' key terms and nothing they don't say; never repeat a paragraph line",
                               DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "Cited"), minimumElements: pageLines, maximumElements: pageLines)))
        }
        return try GenerationSchema(root: DynamicGenerationSchema(name: "Gist", properties: props), dependencies: [citedSchema])
    }
    @available(macOS 26.0, iOS 26.0, *)
    static func iracSchema(lang: String) throws -> GenerationSchema {
        let name = languageName(lang)
        return try GenerationSchema(root: DynamicGenerationSchema(name: "IRAC", properties: [
            cited("issue", "The legal question the notes raise, in \(name), phrased as a question ending with ?"),
            cited("rule", "The rule of law that answers it, in \(name): statute, article or case, as the notes state it"),
            cited("application", "The facts applied to that rule, in \(name), in new words, not copied"),
            cited("conclusion", "The answer to the question, in \(name), in one sentence")
        ]), dependencies: [citedSchema])
    }
    /// Retell: per paragraph, the same idea in plain words (the notes' language) and retold, not translated, in the
    /// other language.
    @available(macOS 26.0, iOS 26.0, *)
    static func retellSchema(paragraphs ps: [[Int]], lang: String, other: String) throws -> GenerationSchema {
        let (l, o) = (languageName(lang), languageName(other))
        var props: [DynamicGenerationSchema.Property] = []
        for (n, idx) in ps.enumerated() {
            let ids = idx.map { "s\($0 + 1)" }.joined(separator: ", ")
            props.append(cited("p\(n + 1)", "Paragraph \(n + 1) (sentences \(ids)) said again in plain everyday \(l), as to a friend; cite only \(ids)"))
            props.append(cited("p\(n + 1)\(other)", "The same idea retold for a \(o) speaker, written entirely in \(o) (not a word-for-word translation); cite only \(ids)"))
        }
        return try GenerationSchema(root: DynamicGenerationSchema(name: "Retell", properties: props), dependencies: [citedSchema])
    }
    /// Ask: retrieval questions, each with its answer, both citing the sentences that hold the answer.
    @available(macOS 26.0, iOS 26.0, *)
    static func askSchema(lang: String, count: Int) throws -> GenerationSchema {
        let name = languageName(lang)
        let qa = DynamicGenerationSchema(name: "QA", properties: [
            cited("question", "A question in \(name) that the notes answer, testing understanding, not wording; ends with ?"),
            cited("answer", "Its answer in \(name), short, from the notes only")
        ])
        return try GenerationSchema(root: DynamicGenerationSchema(name: "Ask", properties: [
            field("items", "\(count) questions with answers", DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "QA"), minimumElements: 1, maximumElements: count))
        ]), dependencies: [citedSchema, qa])
    }
    /// Reapply: the rule the notes state, and a new set of facts (invented: shown as "added") that tests it.
    @available(macOS 26.0, iOS 26.0, *)
    static func reapplySchema(lang: String) throws -> GenerationSchema {
        let name = languageName(lang)
        return try GenerationSchema(root: DynamicGenerationSchema(name: "Reapply", properties: [
            cited("rule", "The rule of law the notes state, in \(name), as they state it"),
            field("facts", "A new, short set of facts in \(name) (different people, a different setting) where that rule decides the outcome; 2 or 3 sentences",
                  DynamicGenerationSchema(type: String.self)),
            field("question", "The question to answer about those facts, in \(name), ending with ?", DynamicGenerationSchema(type: String.self))
        ]), dependencies: [citedSchema])
    }

    static func instructions(_ lang: String) -> String {
        """
        You organize a law student's own notes. Use only what the sentences say; never invent facts, cases or \
        articles unless asked for new facts. Every line cites the ids of the sentences it comes from. Write every \
        line entirely in \(languageName(lang)): translate words from other languages, never mix two languages in \
        one line. Names of cases and statutes stay as they are.
        """
    }

    /// The lenses the page asked for (`want`: gist, reformat, retell, ask, reapply), each line citing the page's
    /// sentence keys, with `mixed: true` on a line written in more than one language (the page drops it) and the
    /// translations the citation check needs. nil when the model can't run.
    @available(macOS 26.0, iOS 26.0, *)
    static func modelLenses(_ section: Section, want: Set<String>) async -> [String: Any]? {
        let text = section.sentences.map(\.text).joined(separator: " ")
        let lang = dominantLanguage(text)?.code ?? "en"
        guard modelUnavailable(lang: lang).isEmpty else { return nil }
        let other = otherLanguage(lang)
        let langs = Array(Set(section.sentences.compactMap { dominantLanguage($0.text)?.code } + [lang, other]))
        // Short ids in the prompt (s1, s2 …), mapped back to the page's keys: the model echoes them reliably (M0).
        let ids = section.sentences.indices.map { "s\($0 + 1)" }
        let toKey = Dictionary(uniqueKeysWithValues: zip(ids, section.sentences.map(\.key)))
        let ps = paragraphs(section.sentences)
        func page(_ group: [[Int]]? = nil) -> String {
            let paras = group ?? ps
            return paras.enumerated().map { n, idx in
                "Paragraph \(n + 1):\n" + idx.map { "[s\($0 + 1)] \(section.sentences[$0].text)" }.joined(separator: "\n")
            }.joined(separator: "\n\n")
        }
        func cite(_ c: GeneratedContent, role: String? = nil, para: Int? = nil, lineLang: String = lang) throws -> [String: Any] {
            // The model sometimes writes its citation ids into the line too ("…; [s1]"): they belong in `from` only.
            let t = (try c.value(String.self, forProperty: "text"))
                .replacingOccurrences(of: #"\s*[;,]?\s*\[?\bs\d+(\s*,\s*s\d+)*\]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let from = (try c.value([String].self, forProperty: "from")).compactMap { toKey[$0.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))] }
            var o: [String: Any] = ["text": t, "from": from, "lang": lineLang]
            if isMixed(t, lang: lineLang, among: langs) { o["mixed"] = true }
            if let role { o["role"] = role }
            if let para { o["para"] = para }
            return o
        }
        // Greedy, and capped: without a cap the model can run on until it overflows its 4,096-token context (M1's
        // spike: 112 s, then an error). ~1,500 words in plus 700 out fits.
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 700)
        func ask(_ prompt: String, _ schema: GenerationSchema) async throws -> GeneratedContent {
            try await LanguageModelSession(instructions: instructions(lang)).respond(to: prompt, schema: schema, options: options).content
        }
        let paraOf = ps.map { section.sentences[$0[0]].p ?? 0 }
        var out: [String: Any] = ["key": section.key, "engine": "model", "lang": lang, "other": other]
        do {
            if want.contains("gist") {
                var lines: [[String: Any]] = []
                for start in stride(from: 0, to: ps.count, by: gistChunk) {
                    let group = Array(ps[start..<min(ps.count, start + gistChunk)])
                    let first = start == 0
                    let pageLines = min(3, section.sentences.count)
                    let g = try await ask("Write the gist of these notes: \(group.count) paragraph lines.\n\(page(group))",
                                          try gistSchema(paragraphs: group, first: first, pageLines: pageLines, lang: lang))
                    if first {
                        // Either may be cut off by the token cap: the page fills the gap from the notes (settle in lenses.js).
                        out["title"] = (try? g.value(String.self, forProperty: "title")) ?? ""
                        out["page"] = ((try? g.value([GeneratedContent].self, forProperty: "page")) ?? []).compactMap { try? cite($0) }
                    }
                    for n in group.indices { lines.append(try cite(try g.value(GeneratedContent.self, forProperty: "p\(n + 1)"), para: paraOf[start + n])) }
                }
                out["gist"] = lines
            }
            if want.contains("reformat"), (section.kind ?? "irac") == "irac" {
                let r = try await ask("Reformat these notes as IRAC.\n\(page())", try iracSchema(lang: lang))
                out["reformat"] = ["kind": "irac", "lines": try ["issue", "rule", "application", "conclusion"].map {
                    try cite(try r.value(GeneratedContent.self, forProperty: $0), role: $0)
                }]
            }
            if want.contains("retell") {
                var lines: [[String: Any]] = []
                for start in stride(from: 0, to: ps.count, by: retellChunk) {
                    let group = Array(ps[start..<min(ps.count, start + retellChunk)])
                    let r = try await ask("Retell these notes, paragraph by paragraph.\n\(page(group))", try retellSchema(paragraphs: group, lang: lang, other: other))
                    for n in group.indices {
                        lines.append(try cite(try r.value(GeneratedContent.self, forProperty: "p\(n + 1)"), role: "plain", para: paraOf[start + n]))
                        lines.append(try cite(try r.value(GeneratedContent.self, forProperty: "p\(n + 1)\(other)"), role: "other", para: paraOf[start + n], lineLang: other))
                    }
                }
                out["retell"] = ["lines": lines]
                out["sourceOther"] = await sourceIn(other, section.sentences)
            }
            if want.contains("ask") {
                let a = try await ask("Write questions that test whether someone understood these notes.\n\(page())",
                                      try askSchema(lang: lang, count: min(5, max(2, ps.count + 1))))
                var lines: [[String: Any]] = []
                for item in try a.value([GeneratedContent].self, forProperty: "items") {
                    lines.append(try cite(try item.value(GeneratedContent.self, forProperty: "question"), role: "question"))
                    lines.append(try cite(try item.value(GeneratedContent.self, forProperty: "answer"), role: "answer"))
                }
                out["ask"] = ["lines": lines]
            }
            if want.contains("reapply"), (section.kind ?? "irac") == "irac" {
                let r = try await ask("State the rule in these notes, then invent new facts that test it.\n\(page())", try reapplySchema(lang: lang))
                out["reapply"] = ["lines": [
                    try cite(try r.value(GeneratedContent.self, forProperty: "rule"), role: "rule"),
                    ["text": try r.value(String.self, forProperty: "facts"), "from": [String](), "role": "facts", "lang": lang, "added": true],
                    ["text": try r.value(String.self, forProperty: "question"), "from": [String](), "role": "question", "lang": lang, "added": true]
                ]]
            }
            out["sourceIn"] = await sourceIn(lang, section.sentences)
            return out
        } catch {
            NSLog("recense: lens call failed: \(error)")
            return ["key": section.key, "engine": "none", "why": "the on-device model failed: \(error.localizedDescription)"]
        }
    }
    #endif

    // MARK: Recensed pages (saved pages only: an unsaved page's lenses stay in the app's cache and go with it)

    static func recensedDir(_ vault: URL) -> URL { vault.appendingPathComponent("Recensed", isDirectory: true) }

    /// Every recensed page, newest first: [{pageId, title, updated}] as JSON.
    static func listJSON(vault: URL?) -> String {
        guard let vault, let names = try? FileManager.default.contentsOfDirectory(atPath: recensedDir(vault).path) else { return "[]" }
        var items: [[String: Any]] = []
        for n in names where n.hasSuffix(".json") {
            guard let raw = coordinatedRead(recensedDir(vault).appendingPathComponent(n).path), let d = raw.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            items.append(["pageId": o["pageId"] ?? "", "title": o["title"] ?? "", "updated": o["updated"] ?? ""])
        }
        items.sort { ($0["updated"] as? String ?? "") > ($1["updated"] as? String ?? "") }
        return json(items)
    }

    static func json(_ o: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    // MARK: The page's messages

    /// On power, and the battery's charge (100 with no battery): recensing at rest runs on power or above 30 %.
    static func powerNow() -> (onPower: Bool, percent: Int) {
        #if os(macOS)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (true, 100) }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue, cur * 100 / max)
        }
        return (true, 100)
        #elseif canImport(UIKit)
        let dev = UIDevice.current
        dev.isBatteryMonitoringEnabled = true
        let level = dev.batteryLevel
        return (dev.batteryState == .charging || dev.batteryState == .full, level < 0 ? 100 : Int(level * 100))
        #else
        return (true, 100)
        #endif
    }

    /// Handles the Recense layer's messages on the page's `ui` channel. Returns true when it was one of them.
    static func handle(_ d: [String: Any], vault: URL?, js: @escaping (String) -> Void, quote: @escaping (String) -> String) -> Bool {
        func decode<T: Decodable>(_ v: Any?, _ t: T.Type) -> T? {
            guard let v, JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) else { return nil }
            return try? JSONDecoder().decode(t, from: d)
        }
        if let r = d["recenseSections"] as? [String: Any], let id = r["id"] as? String,
           let sections = decode(r["sections"], [Section].self) {
            let want = Set((r["lenses"] as? [String]) ?? ["gist", "reformat"])
            Task { @MainActor in
                for s in sections {
                    let lang = dominantLanguage(s.sentences.map(\.text).joined(separator: " "))?.code ?? "en"
                    let why = modelUnavailable(lang: lang)
                    let res = why.isEmpty ? await lenses(s, want: want) : nil
                    js("setRecenseSection(\(quote(id)), \(quote(json(res ?? ["key": s.key, "engine": "none", "why": why.isEmpty ? "the model gave no answer" : why]))))")
                }
                js("recenseDone(\(quote(id)))")
            }
            return true
        }
        if let r = d["recenseSource"] as? [String: Any], let id = r["id"] as? String,
           let sentences = decode(r["sentences"], [Sentence].self) {
            Task { @MainActor in
                let out = await source(sentences, target: r["target"] as? String)
                js("setRecenseSource(\(quote(id)), \(quote(json(out))))")
            }
            return true
        }
        if let r = d["recenseSave"] as? [String: Any], let pageId = r["pageId"] as? String, let body = r["json"] as? String {
            let safe = pageId.filter { $0.isLetter || $0.isNumber }
            if let vault, !safe.isEmpty {
                let dir = recensedDir(vault)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                _ = coordinatedWrite(body, to: dir.appendingPathComponent("\(safe).json").path)
            }
            js("setRecensedList(\(quote(listJSON(vault: vault))))")
            return true
        }
        if d["recensedList"] as? Bool == true { js("setRecensedList(\(quote(listJSON(vault: vault))))"); return true }
        // The wing card's typed line: the Mac forwards it to its wing panels before this; elsewhere the page's own wings
        // already show it.
        if d.keys.contains("recenseCard") { return true }
        if d["powerState"] as? Bool == true {
            let p = powerNow()
            js("setPowerState(\(p.onPower), \(p.percent))")
            return true
        }
        return false
    }
}
