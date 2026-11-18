// Derived from Spec: FEAT-10 (amendment 2026-11-18) · Recense's one language list for Swift: codes, names, locales,
// and the words the language controls say. Foundation only, so a harness compiles it beside shared/translateplan.swift.
import Foundation

public enum Langs {
    /// Follow in's order: English · Français · Tiếng Việt.
    public static let codes = ["en", "fr", "vi"]
    public static let auto = "auto"
    public static let off = "off"
    /// Follow in when nothing (or the retired "auto") is kept: the owner's Daily French priority.
    public static let followDefault = "fr"

    public static func isLang(_ code: String) -> Bool { codes.contains(code) }

    /// The endonym: what the language calls itself.
    public static func name(_ code: String) -> String {
        ["en": "English", "fr": "Français", "vi": "Tiếng Việt"][code] ?? code
    }

    /// The recognizer's locale: "vi" → "vi-VN".
    public static func locale(_ code: String) -> String {
        ["en": "en-US", "fr": "fr-FR", "vi": "vi-VN"][code] ?? code
    }

    /// A kept Follow in choice, read back: a language or "off" stays; "auto", nothing or anything else → French.
    public static func follow(kept: String?) -> String {
        guard let k = kept, isLang(k) || k == off else { return followDefault }
        return k
    }

    /// A kept Heard in choice, read back: a language stays; anything else → Auto-detect.
    public static func heard(kept: String?) -> String {
        guard let k = kept, isLang(k) else { return auto }
        return k
    }

    public enum Word: String, CaseIterable, Sendable { case languages, followIn, heardIn, autoDetect, off, selected }

    /// A control's words in `ui` (en / fr / vi; anything else → English).
    public static func say(_ w: Word, in ui: String = uiLang) -> String {
        let t: [Word: (String, String, String)] = [
            .languages: ("Languages", "Langues", "Ngôn ngữ"),
            .followIn: ("Follow in", "Suivre en", "Theo dõi bằng"),
            .heardIn: ("Heard in", "Entendu en", "Nghe bằng"),
            .autoDetect: ("Auto-detect", "Détection auto", "Tự nhận diện"),
            .off: ("Off", "Désactivé", "Tắt"),
            .selected: ("selected", "sélectionné", "đã chọn"),
        ]
        let (en, fr, vi) = t[w]!
        return ui == "fr" ? fr : ui == "vi" ? vi : en
    }

    /// The device's first preferred language among en / fr / vi, else English.
    public static var uiLang: String {
        for p in Locale.preferredLanguages {
            let c = String(p.prefix(2))
            if isLang(c) { return c }
        }
        return "en"
    }

    /// VoiceOver for one item: "Follow in: Français, selected".
    public static func spoken(_ section: Word, _ item: String, chosen: Bool, in ui: String = uiLang) -> String {
        "\(say(section, in: ui)): \(item)" + (chosen ? ", \(say(.selected, in: ui))" : "")
    }
}
