// Derived from Spec: T-0005
// Way 1: seek into a stored transcript using an audio fingerprint match, so captions for any app stay word-for-word
// and in sync after the first fingerprint match, re-matched every few seconds.
import Foundation

enum CaptionSeek {
    // The ref-clock time (seconds into the stored recording) that the end of `live` corresponds to.
    // `live` is the phased fingerprint words of the most recent ~15 s of system audio (Fingerprint.phased);
    // `ref` is the stored fingerprint for the known recording (Fingerprint.words / Fingerprint.decode).
    // Returns nil when the buffer is too short, too silent, or the BER exceeds Fingerprint's 0.30 threshold.
    // The caller re-runs every few seconds and trusts the result only after two consecutive calls agree
    // within 0.1 s (a single match might hit a repeated sample or a jingle shared between recordings).
    static func refTime(live: [[UInt32]], ref: [UInt32]) -> Double? {
        guard let (shift, _) = Fingerprint.locateLive(live, in: ref) else { return nil }
        let n = live.map(\.count).min() ?? 0
        return Double(n) * Fingerprint.step - shift
    }

    // The index of the word playing at `refNow` seconds in the stored recording.
    // `starts` is `words.map(\.start)`: sorted ascending, one entry per word.
    // Returns the last index whose start ≤ refNow, or 0 when refNow is before all words.
    static func wordIndex(at refNow: Double, starts: [Double]) -> Int {
        guard starts.count > 1 else { return 0 }
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= refNow { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
