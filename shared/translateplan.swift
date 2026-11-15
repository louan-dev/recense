// Derived from Spec: FEAT-10 · which transcript lines get which translation (pure: no translator, no views).
import Foundation
import NaturalLanguage

enum TranslatePlan {
    static let languages = ["en", "vi", "fr"]
    static let choices = ["auto", "en", "vi", "fr", "off"]

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

    /// Where a line in `source` goes for this choice; nil = no translation shown (off, or already in the target).
    static func target(source: String, choice: String) -> String? {
        let t: String
        switch choice {
        case "off": return nil
        case "auto": t = source == "en" ? "vi" : "en"
        default: t = choice
        }
        return t == source ? nil : t
    }

    struct Job: Equatable { var source: String; var target: String; var ids: [String]; var texts: [String] }

    /// For each line: a kept translation to show, nil to clear (already in the target), or a job for the translator.
    /// "off" plans nothing: the view hides translations, nothing is removed.
    static func plan(_ lines: [(id: String, text: String)], choice: String, kept: [String: String],
                     detect: (String) -> String) -> (fills: [String: String?], jobs: [Job]) {
        guard choice != "off" else { return ([:], []) }
        var fills: [String: String?] = [:], jobs: [String: Job] = [:], order: [String] = []
        for l in lines where !l.text.trimmingCharacters(in: .whitespaces).isEmpty {
            let src = detect(l.text)
            guard let dst = target(source: src, choice: choice) else { fills[l.id] = .some(nil); continue }
            if let k = kept[key(dst, l.text)] { fills[l.id] = k; continue }
            let pair = src + ">" + dst
            if jobs[pair] == nil { jobs[pair] = Job(source: src, target: dst, ids: [], texts: []); order.append(pair) }
            jobs[pair]!.ids.append(l.id); jobs[pair]!.texts.append(l.text)
        }
        return (fills, order.map { jobs[$0]! })
    }

    static func key(_ target: String, _ text: String) -> String { target + "|" + text }

    static func name(_ lang: String) -> String {
        ["en": "English", "vi": "Tiếng Việt", "fr": "Français", "auto": "Automatic", "off": "Off"][lang] ?? lang
    }

    static func missing(_ source: String, _ target: String) -> String {
        "\(name(source)) → \(name(target)) isn't installed: Settings › General › Language & Region › Translation Languages"
    }
}
