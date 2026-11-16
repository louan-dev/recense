// Derived from Spec: FEAT-20 (P1, route A): a song opened on iPhone or iPad lit syllable by syllable, as on the Mac.
// The Mac separated its voice (Demucs) and measured it (keep/<key>/features.json); this reads that measure (this
// device's copy first, then the Mac's through the Worker, saved here) and times the words to it with Gallery's own
// cadence.js (bundled beside this file, a checked copy of library/src/client/cadence.js), in JavaScriptCore.
// No voice measured (a podcast, the Mac away on first open): the lines are left as they came, lit by their own times.
// Status: coded, not compiled, device check owed.
import Foundation
import ShowsKit

@MainActor enum SongVoice {
    /// This device's copies of the measured voices, one JSON file per media path.
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Recense/voices")

    /// The engine, made on first use and kept (nil when cadence.js isn't in the bundle or won't run).
    private static var engine: SongLight.Engine?? = .none
    private static func shared() -> SongLight.Engine? {
        if case .some(let e) = engine { return e }
        let e = Bundle.main.url(forResource: "cadence", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { SongLight.Engine(script: $0) }
        engine = .some(e)
        return e
    }

    /// The lines timed to the song's voice, or the same lines when there is no voice to follow.
    static func fit(path: String, _ lines: [TranscriptLine]) async -> [TranscriptLine] {
        guard !lines.isEmpty, let f = await SongLight.voice(path: path, dir: dir, fetch: { await siteData($0) }),
              let e = shared() else { return lines }
        return e.fit(lines, features: f) ?? lines
    }
}
