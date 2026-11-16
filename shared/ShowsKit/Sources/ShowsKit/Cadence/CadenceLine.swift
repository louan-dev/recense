// Derived from Spec: FEAT-20
// What Cadence needs of a line, so the Mac's Line and iOS's TranscriptLine both run the one copy of its rules.
import Foundation

public protocol CadenceLine {
    /// The line's number as Recense writes it: under 2 000 000 speech, 2 000 000 + a song's lyrics, 3 000 000 + heard,
    /// 4 000 000 + a listener's edit (Cadence.edited), + 1 000 000 more for a line an edit cut short.
    var cadenceID: Int { get }
    var words: [Word] { get }
    /// A listener corrected its text (Gallery's `fixed`).
    var fixed: Bool? { get }
    /// It has a translation in words (the Mac's `english` not empty): its syllables are cut by no one language.
    var translated: Bool { get }
    func with(words: [Word]) -> Self
}

extension Cadence {
    /// Shown lines an edit made: its id + edited. An automatic line an edit cut short: its own id + edited + cutShort.
    public static let edited = 4_000_000, cutShort = 1_000_000
}
