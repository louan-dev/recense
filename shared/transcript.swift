import Foundation
import NaturalLanguage
#if canImport(ShowsKit)
import ShowsKit
#endif

// The transcript, one copy for the Mac and iOS (moved here from strip/recense.swift, 2026-11-08): what Recense plays
// (a Line of timed Words, its translation as EnWords that point back at the words they come from) and the rules that
// read which language a phrase is in. Draftpad's Recense layer makes the same Lines from typed text
// (shared/recensetext.swift), so Follow, Learn, the light, the wing card and export work on written words unchanged.

struct Word: Codable {
    var text: String; let start: Double; let end: Double
    var lang: String? = nil   // the language Whisper heard it in (ISO 639-1), when the word is written in that language's script
    var c: Double? = nil      // how sure the recognizer was of it (0–1; on-device ears)
    var heard: String? = nil  // what the recognizer wrote, where a correction it was taught wrote this instead (Lexicon)
    var syl: [Syl]? = nil     // a sung word's syllables on the voice's own (Cadence.align, cadence.swift)
    var un: Bool? = nil       // written but not sung: Cadence found no voice for it, so it's never lit
    var tm: Pin? = nil        // timed by the listener's ear (corrections field "time"): wins over Cadence (Cadence.pin)
    /// The same word, timed again (what it was heard as goes with it; its syllables don't: they were the old times').
    func timed(_ s: Double, _ e: Double) -> Word { Word(text: text, start: s, end: e, lang: lang, c: c, heard: heard, tm: tm) }
}
/// A word as the listener timed it (notes 20261029 row 35; Gallery's corrections.js `pinsOf`): lit from s to e, its light
/// shaped by k (−1 lingers at the start and hurries at the end, 1 the reverse, 0 even).
struct Pin: Codable, Equatable {
    let s: Double; let e: Double; let k: Double
    /// The light traced by a finger as the word was sung (rows 40, 44): how much is lit at evenly spaced moments from
    /// s to e (0 … 1, never going back); it outranks k (Gallery's corrections.js `traceOf`).
    var c: [Double]? = nil
    static func trace(_ v: Any?) -> [Double]? {
        guard let a = v as? [Any], (2...32).contains(a.count) else { return nil }
        var m = 0.0, out: [Double] = []
        for x in a {
            guard let d = (x as? NSNumber)?.doubleValue, d.isFinite else { return nil }
            m = max(m, min(1, max(0, d))); out.append((m * 100).rounded() / 100)
        }
        return out
    }
}
/// A syllable of a sung word: where it ends in the word's letters (code points), and when its note is sung.
struct Syl: Codable { let c: Int; let s: Double; let e: Double }
struct EnWord: Codable { let w: String; let s: [Int] }
struct Line: Codable {
    let id: Int
    let words: [Word]
    var english: [EnWord]?   // nil while translating; [] when the speech is already English
    var draft: Bool? = nil   // older transcripts: translated on this Mac while Groq's quota was out (kept as it is now)
    var fixed: Bool? = nil   // a listener corrected its text (Gallery's `fixed`): Cadence lights its words even where it finds no voice for them
    var start: Double { words.first?.start ?? 0 }
    var end: Double { words.last?.end ?? 0 }
}

/// The script a language is written in (ISO 15924; the CJK scripts as one, Nastaliq as Arabic).
func scriptOf(language code: String) -> String? {
    let s = Locale.Language(identifier: Locale.Language(identifier: code).maximalIdentifier).script?.identifier
    return s.map(scriptFamily)
}
func scriptFamily(_ s: String) -> String { ["Hans", "Hant", "Hani", "Jpan", "Kore", "Hang", "Hira", "Kana"].contains(s) ? "CJK" : s == "Aran" ? "Arab" : s }

/// The script a word or phrase is written in, by most of its letters.
func scriptOf(text: String) -> String? {
    var n: [String: Int] = [:]
    for u in text.unicodeScalars where u.properties.isAlphabetic {
        let v = u.value
        let s: String
        switch v {
        case 0x41...0x2AF, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF: s = "Latn"     // with ɛ ɔ ɲ ɣ (Bambara, Kabyle)
        case 0x370...0x3FF, 0x1F00...0x1FFF: s = "Grek"
        case 0x400...0x52F: s = "Cyrl"
        case 0x530...0x58F: s = "Armn"
        case 0x590...0x5FF: s = "Hebr"
        case 0x600...0x6FF, 0x750...0x77F, 0x8A0...0x8FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: s = "Arab"
        case 0x900...0x97F: s = "Deva"
        case 0x980...0x9FF: s = "Beng"
        case 0xA00...0xA7F: s = "Guru"
        case 0xA80...0xAFF: s = "Gujr"
        case 0xB80...0xBFF: s = "Taml"
        case 0xC00...0xC7F: s = "Telu"
        case 0xC80...0xCFF: s = "Knda"
        case 0xD00...0xD7F: s = "Mlym"
        case 0xE00...0xE7F: s = "Thai"
        case 0x10A0...0x10FF: s = "Geor"
        case 0x1200...0x139F, 0x2D80...0x2DDF, 0xAB00...0xAB2F: s = "Ethi"
        case 0x700...0x74F: s = "Syrc"
        case 0x780...0x7BF: s = "Thaa"
        case 0xB00...0xB7F: s = "Orya"
        case 0xD80...0xDFF: s = "Sinh"
        case 0xE80...0xEFF: s = "Laoo"
        case 0xF00...0xFFF: s = "Tibt"
        case 0x1000...0x109F: s = "Mymr"
        case 0x1780...0x17FF: s = "Khmr"
        case 0x1800...0x18AF: s = "Mong"
        case 0x2C80...0x2CFF: s = "Copt"
        case 0x2D30...0x2D7F: s = "Tfng"
        case 0x1100...0x11FF, 0x3040...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF: s = "CJK"
        default: continue
        }
        n[s, default: 0] += 1
    }
    return n.max { $0.value < $1.value }?.key
}

/// Whether the spelling can tell this language from the others written in its script.
func spellingTells(_ code: String) -> Bool {
    if scriptOf(language: code) == "Arab" { return false }
    let r = NLLanguageRecognizer()          // a language NaturalLanguage has no model of is never its answer
    r.languageConstraints = [NLLanguage(code)]; r.processString("abc")
    return !r.languageHypotheses(withMaximum: 1).isEmpty
}

/// The language a run of heard words is in: the spelling's guess, unless the sound named another language of the
/// same script that the spelling can't tell apart (Dari read as Urdu) — or the spelling has no guess at all.
func phraseLanguage(_ words: [Word]) -> (code: String, p: Double)? {
    let text = words.map(\.text).joined(separator: " ")
    let guess = words.count >= 2 || text.count >= 8 ? dominantLanguage(text) : nil
    var tags: [String: Int] = [:]
    for w in words { if let l = w.lang { tags[l, default: 0] += 1 } }
    let heard = tags.max { $0.value < $1.value }.flatMap { 2 * $0.value >= words.count ? ($0.key, Double($0.value) / Double(words.count)) : nil }
    guard let heard else { return guess }
    guard let g = guess, g.code != heard.0 else { return heard }
    if scriptOf(language: g.code) == scriptOf(language: heard.0), !spellingTells(g.code) || !spellingTells(heard.0) { return heard }
    return g
}

// ---------- languages of the text itself (on-device, NaturalLanguage) ----------
// Whisper names one language per request and may silently translate into it, so what each line is actually in
// is read from its words.

/// ISO 639-1 code of the language a text is most likely in, among `among` (any language when empty).
func dominantLanguage(_ text: String, among: [String] = []) -> (code: String, p: Double)? {
    let r = NLLanguageRecognizer()
    if !among.isEmpty { r.languageConstraints = among.map { NLLanguage($0) } }
    r.processString(text)
    guard let (l, p) = r.languageHypotheses(withMaximum: 1).first else { return nil }
    return (String(l.rawValue.prefix(2)), p)
}

/// Every language a line is sung in: each run of three words is identified on its own, so a line that switches
/// mid-breath ("Lo que pasó, ya no duele tanto, I think that I could move on") reports both.
func lineLanguages(_ words: [String], among: [String]) -> Set<String> {
    guard words.count > 3 else { return dominantLanguage(words.joined(separator: " "), among: among).map { [$0.code] } ?? [] }
    var out = Set<String>()
    for i in 0...(words.count - 3) {
        if let (c, p) = dominantLanguage(words[i..<(i + 3)].joined(separator: " "), among: among), p >= 0.7 { out.insert(c) }
    }
    return out.isEmpty ? (dominantLanguage(words.joined(separator: " "), among: among).map { [$0.code] } ?? []) : out
}

/// A line needs a translation unless all of it is English. The song's languages only narrow the guess: they come
/// from lyrics or from what Whisper heard, and either can be English where the singing isn't (a translated lyrics
/// page, Whisper drifting into translating), which once left "Me dejas sin palabras" with no English under it.
func needsTranslation(_ words: [String], among: [String]) -> Bool {
    let text = words.joined(separator: " ")
    guard text.contains(where: \.isLetter) else { return false }
    if let free = dominantLanguage(text), free.code != "en", free.p >= 0.6 { return true }
    let l = lineLanguages(words, among: Array(Set(among + ["en"])))
    return !(l == ["en"])
}

/// A stretch of a page or an episode with a title: from Recense's lenses (a recensed chapter) or the writer's own heading.
/// `from` names the source sentences it covers (Draftpad's sentence keys); `start` is where it begins in seconds when
/// read aloud or played (0 until timed).
struct Chapter: Codable, Equatable {
    var title: String
    var from: [String]
    var start: Double = 0
}

/// One line a lens wrote (Gist, Reformat…): its text and the source sentences it comes from. Empty `from` means Recense
/// added it (a question, a hypothetical): it is labelled "added", never passed off as the writer's.
struct LensLine: Codable, Equatable {
    var text: String
    var from: [String]
    var role: String? = nil     // Reformat's part: "issue", "rule", "application", "conclusion", "date", "term"…
}

/// A language code as its English name ("vi" → "Vietnamese").
func languageName(_ code: String) -> String { Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code }

#if canImport(ShowsKit)
extension Line {
    /// The same line for ShowsKit's TranscriptView (the one mapping), so a recensed page plays as an episode does.
    func transcriptLine(key: String? = nil, chapter: String? = nil) -> TranscriptLine {
        TranscriptLine(id: key ?? String(id), start: start, end: end, text: words.map(\.text).joined(separator: " "),
                       words: words.map { TranscriptWord(text: $0.text, start: $0.start, end: $0.end) },
                       translation: english.flatMap { $0.isEmpty ? nil : $0.map(\.w).joined(separator: " ") }, chapter: chapter)
    }
}
#endif
