// Where a heard sentence belongs in a transcript Listen already has (Layer A of "one transcript, never twice"):
// content left partway and resumed, rewound, or replayed from the start lands on the sentences it already has
// instead of adding them again; new stretches are spliced in after the last place it recognised. Text only: the
// engines still hear a replay (Layer B, acoustic fingerprints, stops that). Moved out of Listen.swift (its words(),
// overlap() and match()) so it has one home and mobile/ios/Tests/align/main.swift runs it on the Mac. Foundation only.
import Foundation

enum Align {
    /// The words of a sentence for comparing: lowercase, letters and digits, longer than one character.
    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 })
    }

    /// How much of the shorter one the other contains, 0...1.
    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        a.isEmpty || b.isEmpty ? 0 : Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }

    /// The sentence without case, spaces or punctuation: "Oui !" and "oui" are the same short sentence.
    static func plain(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Which stored sentence `text` is, or nil when it is new.
    /// - A sentence of 4 words or more: one that shares at least 70 % of its words; of several, the closest to `place`.
    /// - A shorter one ("Oui.", "Thank you."): only the sentence right after the last one recognised (`after`), and only
    ///   when it reads the same; a short sentence anywhere else is too common to say it was heard before.
    static func match(_ text: String, in stored: [String], place: Int, after: Int? = nil, besides: Int? = nil) -> Int? {
        let w = words(text)
        if w.count < 4 {
            guard let a = after, a + 1 < stored.count, a + 1 != besides, !plain(text).isEmpty, plain(stored[a + 1]) == plain(text) else { return nil }
            return a + 1
        }
        var best: (i: Int, score: Double)?
        for (i, s) in stored.enumerated() where i != besides {
            let o = words(s)
            // measured against the longer one: a short sentence whose words all occur in a long one is not that one
            // (it was, until 11-09, and new sentences were lost). A stored sentence left unfinished is the exception:
            // the whole one completes it.
            var score = Double(w.intersection(o).count) / Double(max(1, w.count, o.count))
            if score < 0.7, !complete(s), completes(text, s) { score = 0.7 }
            if score >= 0.7, best == nil || score > best!.score || (score == best!.score && abs(i - place) < abs(best!.i - place)) { best = (i, score) }
        }
        return best?.i
    }

    /// What a finished sentence that reads like stored sentence `j` does (owner's iPad videos 11-10: a song's chorus
    /// line matched its first time, and the light and every new line were pulled back there, mid-transcript).
    /// - next: it follows the last one recognised (`after`): merge, as before.
    /// - hold: kept as a new sentence at the end for now; `continues` says it extends the run held before.
    /// - merge: the held run proved a rewind or replay (`rewindNeeds` in a row, in order, or it reached `end`, where
    ///   the listening was when the run began): the held copies go and the light moves back to `j`.
    enum Fit: Equatable {
        case next, hold(continues: Bool), merge(continues: Bool)
        var holds: Bool { if case .hold = self { true } else { false } }
    }
    static let rewindNeeds = 3

    /// - run: the stored sentences the held copies matched, in order. end: where the listening was before them.
    static func fit(_ j: Int, after: Int?, end: Int, run: [Int], anchor: Int?) -> Fit {
        if run.isEmpty, let a = after, j == a + 1 { return .next }
        let continues = run.last.map { j == $0 + 1 } ?? false
        let length = continues ? run.count + 1 : 1
        let reached = j == (continues ? anchor ?? end : end)
        return reached || length >= rewindNeeds ? .merge(continues: continues) : .hold(continues: continues)
    }

    /// The marks that end a sentence, every script Listen hears (Listener.split() cuts on them).
    static let stops: Set<Character> = [".", "?", "!", "…", "。", "？", "！", "؟", "።", "፧", "།", "॥", "।"]

    /// Whether a sentence is finished (ends with a stop), so it can be compared with what was heard before.
    static func complete(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).last.map(stops.contains) ?? false
    }

    /// Whether `stored` sentence i is an unfinished version of `text` (the content was left mid-sentence): the new one
    /// is longer and holds nearly all of its words. The longer one is then kept.
    static func completes(_ text: String, _ old: String) -> Bool {
        let n = words(text), o = words(old)
        return n.count > o.count && !o.isEmpty && Double(n.intersection(o).count) / Double(o.count) >= 0.9
    }

    /// Whether the last sentences heard (`recent`, oldest first) continue another transcript: each must match there,
    /// in order, a few sentences apart at most, `need` of them in a row. Returns where the last one is.
    /// Two shows sharing an intro or a jingle (a sentence or two) never reach `need`, so they stay apart.
    static func continues(_ recent: [String], in stored: [String], need: Int = 3) -> Int? {
        let tail = recent.filter { words($0).count >= 4 }.suffix(need)
        guard tail.count == need else { return nil }
        var at: Int?
        for s in tail {
            guard let j = match(s, in: stored, place: at.map { $0 + 1 } ?? 0) else { return nil }
            if let a = at, !(a < j && j - a <= 3) { return nil }
            at = j
        }
        return at
    }
}
