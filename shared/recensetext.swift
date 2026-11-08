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

    /// The Source lens: Lines with their translation (only the sentences that need one; English stays as it is when
    /// the target is English).
    static func source(_ sentences: [Sentence], target requested: String?) async -> [String: Any] {
        var ls = lines(sentences)
        let all = sentences.map(\.text).joined(separator: " ")
        let src = dominantLanguage(all)?.code ?? "en"
        let dst = target(for: src, requested: requested)
        let need = sentences.indices.filter { i in
            let words = ls[i].words.map(\.text)
            return dst == "en" ? needsTranslation(words, among: [src]) : (dominantLanguage(sentences[i].text)?.code ?? src) != dst
        }
        var missing = ""
        // Translate per source language, so a mixed page asks each installed pair for its own sentences.
        var byLang: [String: [Int]] = [:]
        for i in need { byLang[dominantLanguage(sentences[i].text)?.code ?? src, default: []].append(i) }
        for (lang, idx) in byLang where lang != dst {
            if let out = await translate(idx.map { sentences[$0].text }, from: lang, to: dst) {
                for (k, i) in idx.enumerated() { ls[i].english = out[k].split(separator: " ").map { EnWord(w: String($0), s: []) } }
            } else {
                missing = "Translation \(languageName(lang)) → \(languageName(dst)) isn't installed: Settings › General › Language & Region › Translation Languages"
            }
        }
        for i in sentences.indices where ls[i].english == nil && !need.contains(i) { ls[i].english = [] }
        let lineJSON = (try? JSONEncoder().encode(ls)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
        return ["source": src, "target": dst, "keys": sentences.map(\.key), "lines": lineJSON, "missing": missing]
    }

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

    /// Gist and Reformat for one section, citing sentence keys. nil when the model can't (the page goes extractive).
    static func lenses(_ section: Section) async -> [String: Any]? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) { return await modelLenses(section) }
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
    @available(macOS 26.0, iOS 26.0, *)
    static func gistSchema() throws -> GenerationSchema {
        try GenerationSchema(root: DynamicGenerationSchema(name: "Gist", properties: [
            field("title", "A chapter title for this stretch of notes: 2 to 6 words, no quotes", DynamicGenerationSchema(type: String.self)),
            cited("whole", "One sentence that sums up the whole stretch, citing every sentence it draws on"),
            field("lines", "One line per paragraph, in order: what that paragraph says, in new words",
                  DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "Cited"), minimumElements: 1, maximumElements: 6))
        ]), dependencies: [citedSchema])
    }
    @available(macOS 26.0, iOS 26.0, *)
    static func iracSchema() throws -> GenerationSchema {
        try GenerationSchema(root: DynamicGenerationSchema(name: "IRAC", properties: [
            cited("issue", "The legal question the notes raise, phrased as a question ending with ?"),
            cited("rule", "The rule of law that answers it: statute, article or case, as the notes state it"),
            cited("application", "The facts applied to that rule, in new words, not copied"),
            cited("conclusion", "The answer to the question, in one sentence")
        ]), dependencies: [citedSchema])
    }

    static let instructions = """
        You organize a law student's own notes. Use only what the sentences say; never invent facts, cases or \
        articles. Every line cites the ids of the sentences it comes from. Write in the language most of the \
        sentences are in.
        """

    @available(macOS 26.0, iOS 26.0, *)
    static func modelLenses(_ section: Section) async -> [String: Any]? {
        let text = section.sentences.map(\.text).joined(separator: " ")
        let lang = dominantLanguage(text)?.code ?? "en"
        guard modelUnavailable(lang: lang).isEmpty else { return nil }
        // Short ids in the prompt (s1, s2 …), mapped back to the page's keys: the model echoes them reliably (M0).
        let ids = section.sentences.indices.map { "s\($0 + 1)" }
        let toKey = Dictionary(uniqueKeysWithValues: zip(ids, section.sentences.map(\.key)))
        // One line per sentence, a blank line between paragraphs (Gist writes a line per paragraph).
        var page = ""
        for (i, (id, x)) in zip(ids, section.sentences).enumerated() {
            if i > 0 { page += x.p != section.sentences[i - 1].p ? "\n\n" : "\n" }
            page += "[\(id)] \(x.text)"
        }
        func cite(_ c: GeneratedContent, role: String? = nil) throws -> [String: Any] {
            let from = (try c.value([String].self, forProperty: "from")).compactMap { toKey[$0.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))] }
            var o: [String: Any] = ["text": try c.value(String.self, forProperty: "text"), "from": from]
            if let role { o["role"] = role }
            return o
        }
        // Greedy, and capped: without a cap the model can run on until it overflows its 4,096-token context (seen in
        // M1's spike: 112 s, then an error). ~1,500 words in plus 700 out fits.
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 700)
        do {
            let g = try await LanguageModelSession(instructions: instructions)
                .respond(to: "Write the gist of these notes.\n\(page)", schema: try gistSchema(), options: options).content
            var out: [String: Any] = [
                "key": section.key, "engine": "model", "lang": lang,
                "title": try g.value(String.self, forProperty: "title"),
                "whole": try cite(try g.value(GeneratedContent.self, forProperty: "whole")),
                "gist": try g.value([GeneratedContent].self, forProperty: "lines").map { try cite($0) }
            ]
            if (section.kind ?? "irac") == "irac" {
                let r = try await LanguageModelSession(instructions: instructions)
                    .respond(to: "Reformat these notes as IRAC.\n\(page)", schema: try iracSchema(), options: options).content
                out["reformat"] = ["kind": "irac", "lines": try ["issue", "rule", "application", "conclusion"].map {
                    try cite(try r.value(GeneratedContent.self, forProperty: $0), role: $0)
                }]
            }
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
            Task { @MainActor in
                for s in sections {
                    let lang = dominantLanguage(s.sentences.map(\.text).joined(separator: " "))?.code ?? "en"
                    let why = modelUnavailable(lang: lang)
                    let res = why.isEmpty ? await lenses(s) : nil
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
