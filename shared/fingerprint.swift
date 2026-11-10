// Recense's acoustic fingerprint, one copy for the Mac and the iPhone and iPad (2026-11-10). Compiled by both apps:
// the Mac through strip/Sources/recense/fingerprint.swift (a link to this file; strip/recense.swift adds `read`, which
// decodes a file with the Mac's own decoder), the iOS app through the synchronized shared/ group.
import Foundation
import Accelerate

// ---------- content identity: the same recording, whatever the source ----------
// A transcript is keyed by address, so the same song from YouTube, a downloaded mp3 or Music was transcribed and
// translated again from scratch — a day's quota spent on something already done. Each piece's audio gets a
// fingerprint instead (Haitsma–Kalker, the Philips scheme): one 32-bit word per 128 ms, each bit the sign of how
// the (log) energy difference between two neighbouring bands (33 bands, 300–2000 Hz) changed since the frame before.
// Re-encoding (YouTube's AAC vs. an mp3), level and EQ barely move those signs; a different recording flips half.
enum Fingerprint {
    static let sr = 16000.0, frame = 4096, hop = 2048, phases = 4
    static let step = Double(hop) / sr                  // seconds per word
    static let maxSeconds = 600.0                       // what's kept: a song whole, a long piece's first 10 min
    static let edges: [Int] = (0...33).map { Int(300 * pow(2000.0 / 300, Double($0) / 33) / sr * Double(frame)) }

    /// One word per hop from `start` samples in.
    static func words(_ s: [Float], start: Int = 0) -> [UInt32] {
        let n = (s.count - start - frame) / hop + 1
        guard n > 1, let setup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: frame)
        vDSP_hann_window(&window, vDSP_Length(frame), Int32(vDSP_HANN_NORM))
        var x = [Float](repeating: 0, count: frame), re = [Float](repeating: 0, count: frame / 2),
            im = [Float](repeating: 0, count: frame / 2), power = [Float](repeating: 0, count: frame / 2)
        var prev: [Float] = [], out: [UInt32] = []
        out.reserveCapacity(n)
        for f in 0..<n {
            s.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + start + f * hop, 1, window, 1, &x, 1, vDSP_Length(frame)) }
            re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { i in
                var z = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                x.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &z, 1, vDSP_Length(frame / 2)) }
                vDSP_fft_zrip(setup, &z, 1, 12, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&z, 1, &power, 1, vDSP_Length(frame / 2))
            } }
            let e = (0..<33).map { m in log(power[edges[m]..<edges[m + 1]].reduce(0, +) + 1e-9) }   // log: gain and EQ cancel
            if !prev.isEmpty {
                var w: UInt32 = 0
                for m in 0..<32 where (e[m] - e[m + 1]) - (prev[m] - prev[m + 1]) > 0 { w |= 1 << m }
                out.append(w)
            }
            prev = e
        }
        return out
    }

    /// The words of `s` (16 kHz mono) at each of `phases` sub-hop offsets: a match can then line up within 32 ms.
    static func phased(_ s: [Float]) -> [[UInt32]] { (0..<phases).map { words(s, start: $0 * hop / phases) } }

    /// Where `q` sits best in `ref`: the word index there and the share of bits that differ.
    static func locate(_ q: ArraySlice<UInt32>, in ref: [UInt32]) -> (at: Int, ber: Double) {
        guard q.count > 0, ref.count >= q.count else { return (0, 1) }
        var best = (at: 0, errors: Int.max)
        let qa = Array(q)
        ref.withUnsafeBufferPointer { r in
            for j in 0...(r.count - qa.count) {
                var e = 0
                for k in 0..<qa.count { e += (qa[k] ^ r[j + k]).nonzeroBitCount; if e >= best.errors { break } }
                if e < best.errors { best = (j, e) }
            }
        }
        return (best.at, Double(best.errors) / Double(32 * qa.count))
    }

    /// Whether the new audio (phased words of its first `maxSeconds`) is the recording `ref` holds, and if so its
    /// offset (new time − ref time). Two stretches of ~15 s, far apart and with sound in them, must both match
    /// closely (≤ 30 % bits off; another recording gives ~50 %) at the same offset — one alone could be a shared
    /// sample or an intro.
    static func offset(_ new: [[UInt32]], in ref: [UInt32]) -> (shift: Double, ber: Double)? {
        let w = 120, n = new[0].count
        guard n >= 2 * w, ref.count >= w else { return nil }
        var found: [(shift: Double, ber: Double)] = []
        for share in [0.3, 0.7] {
            var q0 = min(n - w, max(0, Int(Double(n) * share) - w / 2))
            // Silence is all zero words, which match any other silence: start where there's sound.
            while q0 + w < n, new[0][q0..<(q0 + w)].filter({ $0 == 0 }).count > w / 10 { q0 += w / 4 }
            guard q0 + w <= n else { return nil }
            var best: (shift: Double, ber: Double) = (0, 1)
            for (p, words) in new.enumerated() where words.count >= q0 + w {
                let (at, ber) = locate(words[q0..<(q0 + w)], in: ref)
                if ber < best.ber { best = ((Double(q0 * hop + p * hop / phases) - Double(at * hop)) / sr, ber) }
            }
            found.append(best)
        }
        guard found.allSatisfy({ $0.ber <= 0.3 }), abs(found[0].shift - found[1].shift) < 0.3 else { return nil }
        return ((found[0].shift + found[1].shift) / 2, max(found[0].ber, found[1].ber))
    }

    /// Where live sound sits in a known recording: what "hear ahead" needs to light the transcript on time. `live` is
    /// the phased words (`phased`) of the most recent 15-20 s heard (16 kHz mono); one stretch of 120 words (~15.4 s)
    /// with sound in it, the latest there is, is placed in `ref` at each phase, so the answer is good to 32 ms.
    /// It gives shift = live time − ref time, in seconds, live time counted from `live`'s first sample, and the share
    /// of bits that differ; nil when there's too little sound or no place matches (more than 30 % bits off).
    /// One stretch could be an intro or a jingle the recording shares with others, so a single answer is a guess:
    /// the caller adds its buffer's start on its own clock and trusts the place only once two calls in a row agree
    /// within 0.1 s.
    static func locateLive(_ live: [[UInt32]], in ref: [UInt32]) -> (shift: Double, ber: Double)? {
        let w = 120
        // The later phases start a little in and can hold a word less: take the stretch all of them have.
        guard let n = live.map(\.count).min(), n >= w, ref.count >= w else { return nil }
        // Silence is all zero words, which match any other silence: step back from the newest until there's sound.
        func quiet(_ q0: Int) -> Bool { live[0][q0..<(q0 + w)].filter({ $0 == 0 }).count > w / 10 }
        var q0 = n - w
        while q0 > 0, quiet(q0) { q0 = max(0, q0 - w / 4) }
        guard !quiet(q0) else { return nil }
        var best: (shift: Double, ber: Double) = (0, 1)
        for (p, words) in live.enumerated() {
            let (at, ber) = locate(words[q0..<(q0 + w)], in: ref)
            if ber < best.ber { best = ((Double(q0 * hop + p * hop / phases) - Double(at * hop)) / sr, ber) }
        }
        return best.ber <= 0.3 ? best : nil
    }

    static func encode(_ w: [UInt32]) -> String { w.withUnsafeBytes { Data($0) }.base64EncodedString() }
    static func decode(_ s: String) -> [UInt32] {
        guard let d = Data(base64Encoded: s) else { return [] }
        return d.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    }
}
