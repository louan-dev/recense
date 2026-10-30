import Foundation
import Accelerate

// ---------- voiceprints ----------
// How a stretch of voice sounds, for telling whether a word the recognizer heard is the one a listener once corrected:
// 13 MFCCs every 10 ms (25 ms Hann frames, 26 mel bands from 60 Hz to 7.6 kHz, an orthonormal DCT), the mean of each
// removed so the room, the microphone and the level cancel out. Two are compared by dynamic time warping, so the
// same word said faster or slower still lines up. Knows nothing about its host: 16 kHz mono samples in, a distance out.
// Platform reach: anywhere with Accelerate (no AppKit, no AVFoundation).
enum Voiceprint {
    static let rate = 16000.0, frame = 400, hop = 160, log2n: vDSP_Length = 9, bins = 257, bands = 26, coeffs = 13

    private static let window: [Float] = {
        var w = [Float](repeating: 0, count: frame)
        vDSP_hann_window(&w, vDSP_Length(frame), Int32(vDSP_HANN_NORM))
        return w
    }()
    private nonisolated(unsafe) static let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    /// The mel filters, bands × bins, row by row.
    private static let mel: [Float] = {
        func m(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func f(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let lo = m(60), hi = m(7600)
        let edges = (0...(bands + 1)).map { f(lo + (hi - lo) * Double($0) / Double(bands + 1)) * Double(bins - 1) * 2 / rate }
        var w = [Float](repeating: 0, count: bands * bins)
        for b in 0..<bands {
            let (l, c, r) = (edges[b], edges[b + 1], edges[b + 2])
            for k in 0..<bins {
                let x = Double(k)
                let v = x <= l || x >= r ? 0 : x <= c ? (x - l) / (c - l) : (r - x) / (r - c)
                w[b * bins + k] = Float(v)
            }
        }
        return w
    }()
    /// The DCT, coeffs × bands, orthonormal so every coefficient weighs alike.
    private static let dct: [Float] = {
        var d = [Float](repeating: 0, count: coeffs * bands)
        for k in 0..<coeffs {
            let s = k == 0 ? (1 / Double(bands)).squareRoot() : (2 / Double(bands)).squareRoot()
            for m in 0..<bands { d[k * bands + m] = Float(s * cos(Double.pi * Double(k) * (Double(m) + 0.5) / Double(bands))) }
        }
        return d
    }()

    /// The voiceprint of 16 kHz mono samples: one row of `coeffs` per 10 ms. Empty when there's under 50 ms.
    static func of(_ s: ArraySlice<Float>) -> [[Float]] {
        let x = Array(s)
        guard x.count >= 800 else { return [] }
        var pre = x
        for i in stride(from: x.count - 1, to: 0, by: -1) { pre[i] = x[i] - 0.97 * x[i - 1] }
        let n = 1 + (x.count - frame) / hop
        var logs: [[Float]] = [], buf = [Float](repeating: 0, count: 512), re = [Float](repeating: 0, count: 256),
            im = [Float](repeating: 0, count: 256), power = [Float](repeating: 0, count: bins),
            energies = [Float](repeating: 0, count: bands), out = [Float](repeating: 0, count: coeffs)
        logs.reserveCapacity(n)
        for f in 0..<n {
            for i in 0..<512 { buf[i] = i < frame ? pre[f * hop + i] * window[i] : 0 }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var z = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    buf.withUnsafeBufferPointer { b in
                        b.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: 256) { vDSP_ctoz($0, 2, &z, 1, 256) }
                    }
                    vDSP_fft_zrip(fft, &z, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            power[0] = re[0] * re[0]; power[256] = im[0] * im[0]
            for k in 1..<256 { power[k] = re[k] * re[k] + im[k] * im[k] }
            vDSP_mmul(mel, 1, power, 1, &energies, 1, vDSP_Length(bands), 1, vDSP_Length(bins))
            logs.append(energies.map { logf(max($0, 1e-10)) })
        }
        // Silence (a pause, the end of a sentence) is floored 50 dB under the stretch's loudest band, or its
        // nothingness would outweigh the voice: every word ending a sentence came out unlike every other.
        let floor = (logs.map { $0.max() ?? 0 }.max() ?? 0) - 11.5
        var rows: [[Float]] = []
        rows.reserveCapacity(n)
        for var l in logs {
            for b in 0..<bands { l[b] = max(l[b], floor) }
            vDSP_mmul(dct, 1, l, 1, &out, 1, vDSP_Length(coeffs), 1, vDSP_Length(bands))
            rows.append(out)
        }
        for k in 0..<coeffs {
            let mean = rows.reduce(0) { $0 + $1[k] } / Float(rows.count)
            for i in rows.indices { rows[i][k] -= mean }
        }
        return rows
    }

    /// How unlike two voiceprints are: the mean frame distance along the best alignment (0 = identical). Infinite
    /// when one lasts more than 2.2 times the other: no rate of speech makes those the same word.
    static func distance(_ a: [[Float]], _ b: [[Float]]) -> Float {
        let n = a.count, m = b.count
        guard n > 0, m > 0, Float(max(n, m)) / Float(min(n, m)) <= 2.2 else { return .infinity }
        let band = max(3, Int(0.35 * Float(max(n, m))))
        var prev = [Float](repeating: .infinity, count: m + 1), cur = prev
        prev[0] = 0
        for i in 1...n {
            for j in 0...m { cur[j] = .infinity }
            let mid = i * m / n
            for j in max(1, mid - band)...min(m, mid + band) {
                var d: Float = 0
                vDSP_distancesq(a[i - 1], 1, b[j - 1], 1, &d, vDSP_Length(coeffs))
                cur[j] = d.squareRoot() + min(prev[j], cur[j - 1], prev[j - 1])
            }
            swap(&prev, &cur)
        }
        return prev[m] / Float(n + m)
    }

    /// The voiceprint of a word at a–b (seconds) in `samples` starting at `origin`: normalised over the 1.5 s either
    /// side of it, so a word taught and a word heard are measured alike whatever surrounds them; `slack` seconds
    /// wider each way for a stretch to search in (the recognizer's word edges are off by a tenth of a second).
    static func of(_ samples: [Float], origin: Double, from a: Double, to b: Double, slack: Double = 0) -> [[Float]] {
        let lo = max(0, Int((a - 1.5 - origin) * rate)), hi = min(samples.count, Int((b + 1.5 - origin) * rate))
        guard hi - lo >= 800, b > a else { return [] }
        let rows = of(samples[lo..<hi]), t0 = origin + Double(lo) / rate
        let f0 = max(0, Int(((a - slack - t0) * 100).rounded())), f1 = min(rows.count, Int(((b + slack - t0) * 100).rounded()))
        return f1 > f0 ? Array(rows[f0..<f1]) : []
    }

    /// How unlike a word `q` is to the best match for it anywhere in the stretch `r` (free start and end): the mean
    /// frame distance along that match. What a heard word is checked with, against a taught one.
    static func search(_ q: [[Float]], in r: [[Float]]) -> Float {
        let n = q.count, m = r.count
        guard n > 0, m > 0, 2 * m >= n else { return .infinity }
        var prev = [Float](repeating: 0, count: m + 1), cur = [Float](repeating: .infinity, count: m + 1)
        var pl = [Int](repeating: 0, count: m + 1), cl = pl
        for i in 1...n {
            cur[0] = .infinity; cl[0] = 0
            for j in 1...m {
                var d: Float = 0
                vDSP_distancesq(q[i - 1], 1, r[j - 1], 1, &d, vDSP_Length(coeffs))
                var best = prev[j - 1], len = pl[j - 1]
                if prev[j] < best { best = prev[j]; len = pl[j] }
                if cur[j - 1] < best { best = cur[j - 1]; len = cl[j - 1] }
                cur[j] = best + d.squareRoot(); cl[j] = len + 1
            }
            swap(&prev, &cur); swap(&pl, &cl)
        }
        var out = Float.infinity
        for j in 1...m where prev[j].isFinite && pl[j] > 0 { out = min(out, prev[j] / Float(pl[j])) }
        return out
    }

    /// Stored as text: one signed byte per coefficient (a quarter of a unit each, ±31.75), base64.
    static func pack(_ v: [[Float]]) -> String {
        Data(v.flatMap { $0.map { UInt8(bitPattern: Int8(max(-127, min(127, ($0 * 4).rounded())))) } }).base64EncodedString()
    }
    static func unpack(_ s: String) -> [[Float]] {
        guard let d = Data(base64Encoded: s), d.count % coeffs == 0 else { return [] }
        let x = d.map { Float(Int8(bitPattern: $0)) / 4 }
        return stride(from: 0, to: x.count, by: coeffs).map { Array(x[$0..<($0 + coeffs)]) }
    }
}
