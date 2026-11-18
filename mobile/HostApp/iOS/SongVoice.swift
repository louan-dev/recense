// Derived from Spec: FEAT-20 (P1, route A): a song opened on iPhone or iPad lit syllable by syllable, as on the Mac.
// The Mac separated its voice (Demucs) and measured it (keep/<key>/features.json); this reads that measure (this
// device's copy first, then the Mac's through the Worker, saved here) and times the words to it with the Mac's own
// Cadence (shared/ShowsKit/Cadence: one Swift copy for Mac, iPhone and iPad).
// No voice measured (a podcast, the Mac away on first open): the lines are left as they came, lit by their own times.
// Status: compiled; device check owed.
import Foundation
import ShowsKit

@MainActor enum SongVoice {
    /// This device's copies of the measured voices, one JSON file per media path.
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Recense/voices")

    /// The lines timed to the song's voice, or the same lines when there is no voice to follow.
    static func fit(path: String, _ lines: [TranscriptLine]) async -> [TranscriptLine] {
        guard !lines.isEmpty, let f = await SongLight.voice(path: path, dir: dir, fetch: { await siteData($0) })
              else { Cadence.track = nil; return lines }
        Cadence.track = SongLight.track(f)   // the song now shown: words without syllables follow its voice, as on the Mac
        return SongLight.fit(lines, features: f) ?? lines
    }
}
