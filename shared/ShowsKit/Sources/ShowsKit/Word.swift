// Derived from Spec: FEAT-04 (P1, one word type)
// A timed word, the one type every embodiment uses (moved here from shared/transcript.swift, 2026-11-12, and
// ShowsKit's TranscriptWord folded into it): the Mac's transcript, iOS Listen and the transcript view all read it.
// start and end are seconds into the recording (the content's own clock), never the wall clock.
import Foundation

public struct Word: Codable, Hashable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var lang: String? = nil   // the language it was heard in (ISO 639-1), when the word is written in that language's script
    public var c: Double? = nil      // how sure the recognizer was of it (0–1; on-device ears)
    public var heard: String? = nil  // what the recognizer wrote, where a correction it was taught wrote this instead (Lexicon)
    public var syl: [Syl]? = nil     // a sung word's syllables on the voice's own (Cadence.align, cadence.swift)
    public var un: Bool? = nil       // written but not sung: Cadence found no voice for it, so it's never lit
    public var tm: Pin? = nil        // timed by the listener's ear (corrections field "time"): wins over Cadence (Cadence.pin)
    public init(text: String, start: Double, end: Double, lang: String? = nil, c: Double? = nil, heard: String? = nil,
                syl: [Syl]? = nil, un: Bool? = nil, tm: Pin? = nil) {
        self.text = text; self.start = start; self.end = end; self.lang = lang; self.c = c; self.heard = heard
        self.syl = syl; self.un = un; self.tm = tm
    }
    /// The same word, timed again (what it was heard as goes with it; its syllables don't: they were the old times').
    public func timed(_ s: Double, _ e: Double) -> Word { Word(text: text, start: s, end: e, lang: lang, c: c, heard: heard, tm: tm) }
    /// The same word, every time in it moved by d seconds (its syllables and pin too): a change of clock, not a retiming.
    public func shifted(by d: Double) -> Word {
        var w = self; w.start += d; w.end += d
        w.syl = syl?.map { Syl(c: $0.c, s: $0.s + d, e: $0.e + d) }
        w.tm = tm.map { Pin(s: $0.s + d, e: $0.e + d, k: $0.k, c: $0.c) }
        return w
    }
}

/// A word as the listener timed it (notes 20261029 row 35; Gallery's corrections.js `pinsOf`): lit from s to e, its light
/// shaped by k (−1 lingers at the start and hurries at the end, 1 the reverse, 0 even).
public struct Pin: Codable, Hashable, Sendable {
    public let s: Double; public let e: Double; public let k: Double
    /// The light traced by a finger as the word was sung (rows 40, 44): how much is lit at evenly spaced moments from
    /// s to e (0 … 1, never going back); it outranks k (Gallery's corrections.js `traceOf`).
    public var c: [Double]? = nil
    public init(s: Double, e: Double, k: Double, c: [Double]? = nil) { self.s = s; self.e = e; self.k = k; self.c = c }
    public static func trace(_ v: Any?) -> [Double]? {
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
public struct Syl: Codable, Hashable, Sendable {
    public let c: Int; public let s: Double; public let e: Double
    public init(c: Int, s: Double, e: Double) { self.c = c; self.s = s; self.e = e }
}
