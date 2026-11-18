// Derived from Spec: FEAT-10 (amended 2026-11-18) · which transcript lines get which translation, in playhead order
// (pure: no translator, no views). The language list is ShowsKit's Langs; a harness compiles Langs.swift beside this.
import Foundation
import NaturalLanguage
#if canImport(ShowsKit)
import ShowsKit
#endif

enum TranslatePlan {
    static let languages = Langs.codes
    /// Follow in: the three languages, then Off. "auto" is no longer a target (Langs.follow reads a kept one as French).
    static let choices = Langs.codes + [Langs.off]
    /// Lines after the playhead's go to the translator this many at a time.
    static let chunk = 8

    /// The line's language among en / vi / fr; a line too short or unclear takes `fallback` (the file's language).
    static func detect(_ text: String, fallback: String) -> String {
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.english, .vietnamese, .french]
        r.processString(text)
        // under three words ("Okay.", "Cảm ơn") any guess is noise: the file's language is the better bet
        guard text.split(separator: " ").count >= 3, let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p >= 0.6 else {
            return languages.contains(fallback) ? fallback : "en"
        }
        return lang.rawValue
    }

    /// A line's language: Heard in's override, or under Auto-detect the line's own (`detect`).
    static func source(_ text: String, heard: String, detect: (String) -> String) -> String {
        Langs.isLang(heard) ? heard : detect(text)
    }

    /// Where a line in `source` goes for this choice; nil = no translation shown (off, or already in the target).
    static func target(source: String, choice: String) -> String? {
        let t = Langs.follow(kept: choice)
        guard t != Langs.off, t != source else { return nil }
        return t
    }

    struct Job: Equatable { var source: String; var target: String; var ids: [String]; var texts: [String] }

    /// For each line: a kept translation to show, nil to clear (already in the target), or a job for the translator.
    /// "off" plans nothing: the view hides translations, nothing is removed.
    /// Jobs come in playhead order: the line at `playhead` (an index into `lines`) alone, then the lines after it
    /// `chunk` at a time, then the lines before it, nearest first; each job one language pair. No playhead = from the top.
    static func plan(_ lines: [(id: String, text: String)], choice: String, kept: [String: String], playhead: Int? = nil,
                     detect: (String) -> String) -> (fills: [String: String?], jobs: [Job]) {
        guard target(source: "", choice: choice) != nil else { return ([:], []) }
        var fills: [String: String?] = [:]
        var todo: [(i: Int, src: String, dst: String)] = []
        for (i, l) in lines.enumerated() where !l.text.trimmingCharacters(in: .whitespaces).isEmpty {
            let src = detect(l.text)
            guard let dst = target(source: src, choice: choice) else { fills[l.id] = .some(nil); continue }
            if let k = kept[key(dst, l.text)] { fills[l.id] = k; continue }
            todo.append((i, src, dst))
        }
        let p = min(max(playhead ?? 0, 0), max(lines.count - 1, 0))
        let now = todo.filter { $0.i == p }, ahead = todo.filter { $0.i > p }
        let behind = Array(todo.filter { $0.i < p }.reversed())
        var jobs = runs(now, size: 1, lines) + runs(ahead, size: chunk, lines)
        // before the playhead: nearest chunk first, each chunk read in its own (forward) order
        jobs += runs(behind, size: chunk, lines).map {
            Job(source: $0.source, target: $0.target, ids: $0.ids.reversed(), texts: $0.texts.reversed())
        }
        return (fills, jobs)
    }

    /// The lines `size` at a time, in order; inside each window one job per language pair (first seen first).
    private static func runs(_ todo: [(i: Int, src: String, dst: String)], size: Int,
                             _ lines: [(id: String, text: String)]) -> [Job] {
        var jobs: [Job] = []
        var at = 0
        while at < todo.count {
            var window: [Job] = []
            for t in todo[at..<min(at + size, todo.count)] {
                if let w = window.firstIndex(where: { $0.source == t.src && $0.target == t.dst }) {
                    window[w].ids.append(lines[t.i].id); window[w].texts.append(lines[t.i].text)
                } else {
                    window.append(Job(source: t.src, target: t.dst, ids: [lines[t.i].id], texts: [lines[t.i].text]))
                }
            }
            jobs += window
            at += size
        }
        return jobs
    }

    static func key(_ target: String, _ text: String) -> String { target + "|" + text }

    static func name(_ lang: String) -> String {
        lang == Langs.off ? Langs.say(.off) : lang == Langs.auto ? Langs.say(.autoDetect) : Langs.name(lang)
    }

    static func missing(_ source: String, _ target: String) -> String {
        "\(name(source)) → \(name(target)) isn't installed: Settings › General › Language & Region › Translation Languages"
    }
}
