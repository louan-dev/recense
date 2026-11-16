// Derived from Spec: FEAT-20 (moved verbatim from strip/recense.swift, 2026-11-16: one copy for the Mac, iPhone and iPad)
import Foundation
import Accelerate

/// Loudness of 10 ms frames of 16 kHz audio, in dB.
public func frameDB(_ s: [Float]) -> [Float] {
    guard s.count >= 160 else { return [] }
    return stride(from: 0, to: s.count - 159, by: 160).map { k in
        var e: Float = 0
        for x in s[k..<(k + 160)] { e += x * x }
        return 10 * log10(e / 160 + 1e-10)
    }
}


// ---------- the voice's shape: what the light follows inside a word ----------
/// A song's voice measured frame by frame (100 a second) on its vocal stem, cached as <key>.features.json and kept in
/// keep/<key>/features.json. The karaoke light reads it (Cadence); anything that draws the voice (energy, pitch,
/// vibrato, sustain) can read the same file. One value per frame in each array, all the same length:
///   db       loudness, dB × 10 (0 = full scale)
///   onset    how sharply the sound changes (positive spectral flux), 0–100 against the song's strongest (its 99th percentile)
///   pitch    f0 as a MIDI note × 100 (6900 = A4, 440 Hz), 0 where nothing is pitched
///   clarity  how periodic the frame is, 0–100 (YIN: 100 × (1 − aperiodicity))
///   voiced   1 where the voice sounds (`floor` dB or more on the stem), else 0: consonants too, so not the same as pitch > 0
public final class Features: Codable {
    public var format = 1
    public var source: String            // "vocals": the Demucs stem (the light follows only that: a mix's loudness is the band's)
    public var hop = 0.01                // seconds a frame
    public var floor: Double             // dB from which a frame is voice
    public var db: [Int], onset: [Int], pitch: [Int], clarity: [Int], voiced: [Int]

    public init(source: String, floor: Double, db: [Int], onset: [Int], pitch: [Int], clarity: [Int], voiced: [Int]) {
        self.source = source; self.floor = floor; self.db = db; self.onset = onset; self.pitch = pitch; self.clarity = clarity; self.voiced = voiced
    }


    public var count: Int { db.count }
    public func frame(_ t: Double) -> Int { max(0, min(count - 1, Int((t / hop).rounded(.down)))) }
    public func time(_ k: Int) -> Double { Double(k) * hop }
    public func isVoiced(_ k: Int) -> Bool { k >= 0 && k < count && voiced[k] == 1 }
    public func sustained(_ k: Int) -> Bool { isVoiced(k) && (k..<(k + 8)).filter(isVoiced).count >= 5 }   // a voice, not a click
    /// Voiced in 95 % or more of the frames within a second either side (cadence.js `saturated`).
    public func saturated(_ k: Int) -> Bool {
        let lo = max(0, k - 100), hi = min(count, k + 100)
        return hi > lo && Double((lo..<hi).filter { voiced[$0] == 1 }.count) >= Double(hi - lo) * 0.95
    }
    /// In [a, b]: the frame where the loudness rises most, its next 150 ms over its last (dB × 10), by 4 dB or more
    /// (cadence.js `rise`; the first of equals).
    public func rise(_ a: Int, _ b: Int) -> Int? {
        var best: Int? = nil, br = 40.0
        let lo = max(15, a), hi = min(count - 15, b)
        guard lo <= hi else { return nil }
        for k in lo...hi {
            var before = 0, after = 0
            for j in 1...15 { before += db[k - j]; after += db[k + j - 1] }
            let r = Double(after - before) / 15
            if r > br { br = r; best = k }
        }
        return best
    }

    /// Frames where the voice comes back after a silence (a breath, a pause, a stop consonant's closure) and goes on:
    /// the frame, and how long it was quiet before (seconds), in [a, b).
    public func entries(_ a: Double, _ b: Double) -> [(k: Int, gap: Double)] {
        var out: [(k: Int, gap: Double)] = []
        let lo = max(1, frame(a)), hi = min(count, Int((b / hop).rounded(.up)))
        guard lo < hi else { return out }
        for k in lo..<hi where voiced[k] == 1 && voiced[k - 1] == 0 && sustained(k) {
            var g = 0
            while k - g - 1 >= 0 && voiced[k - g - 1] == 0 && g < 200 { g += 1 }
            out.append((k, Double(g) * hop))
        }
        return out
    }

    /// 16 kHz mono audio measured. Pitch by YIN (70–1000 Hz, 32 ms window), onsets by spectral flux (512-point FFT).
    public static func measure(_ s: [Float], source: String) -> Features {
        let dbs = frameDB(s), n = dbs.count
        let sorted = dbs.sorted()
        let quiet = sorted.isEmpty ? -100 : Double(sorted[sorted.count / 10]), loud = sorted.isEmpty ? 0 : Double(sorted[sorted.count * 95 / 100])
        // the loudness gate refine() uses on a stem (on a mix, the one it uses there)
        let floor = source == "vocals" ? max(quiet + 12, loud - 30) : quiet + max(10, 0.35 * (loud - quiet))

        // onsets: rise of log magnitude summed over 0–5 kHz, frame to frame
        let N = 512, half = N / 2, log2n = vDSP_Length(9), bins = 160
        let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(fft) }
        var window = [Float](repeating: 0, count: N); vDSP_hann_window(&window, vDSP_Length(N), Int32(vDSP_HANN_NORM))
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half), mags = [Float](repeating: 0, count: half)
        var buf = [Float](repeating: 0, count: N), prev = [Float](repeating: 0, count: bins)
        var flux = [Float](repeating: 0, count: n)
        for k in 0..<n {
            let c = k * 160 + 80
            for j in 0..<N { let i = c - half + j; buf[j] = i >= 0 && i < s.count ? s[i] * window[j] : 0 }
            re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { m in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: m.baseAddress!)
                buf.withUnsafeBufferPointer { b in
                    b.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            } }
            var f: Float = 0
            for b in 1..<bins {
                let l = log1p(1000 * sqrt(mags[b]))
                if k > 0 { f += max(0, l - prev[b]) }
                prev[b] = l
            }
            flux[k] = f
        }
        // n is 0 for audio shorter than one frame (160 samples); indexing then crashed Recense while idle (R15)
        let top = n > 0 ? flux.sorted()[min(n - 1, n * 99 / 100)] : 0

        // pitch: YIN on frames with voice in them
        let W = 512, tmin = 16, tmax = 228, need = W + tmax
        var seg = [Float](repeating: 0, count: need), sq = [Double](repeating: 0, count: need + 1)
        var r = [Float](repeating: 0, count: tmax + 1), cmnd = [Double](repeating: 1, count: tmax + 1)
        var pitch = [Int](repeating: 0, count: n), clarity = [Int](repeating: 0, count: n)
        for k in 0..<n where Double(dbs[k]) >= floor - 6 {
            let a = k * 160 + 80 - need / 2
            for j in 0..<need { let i = a + j; seg[j] = i >= 0 && i < s.count ? s[i] : 0 }
            for j in 0..<need { sq[j + 1] = sq[j] + Double(seg[j] * seg[j]) }
            seg.withUnsafeBufferPointer { p in vDSP_conv(p.baseAddress!, 1, p.baseAddress!, 1, &r, 1, vDSP_Length(tmax + 1), vDSP_Length(W)) }
            let e0 = sq[W]
            guard e0 > 1e-6 else { continue }
            var run = 0.0
            for t in 1...tmax {
                let d = max(0, e0 + (sq[t + W] - sq[t]) - 2 * Double(r[t]))
                run += d
                cmnd[t] = run > 0 ? d * Double(t) / run : 1
            }
            var best = tmin
            if let first = (tmin...tmax).first(where: { cmnd[$0] < 0.15 }) {
                best = first
                while best < tmax && cmnd[best + 1] < cmnd[best] { best += 1 }
            } else { best = (tmin...tmax).min { cmnd[$0] < cmnd[$1] }! }
            let ap = cmnd[best]
            clarity[k] = Int((100 * max(0, 1 - ap)).rounded())
            guard ap < 0.35, best > tmin, best < tmax else { continue }
            let y0 = cmnd[best - 1], y1 = cmnd[best], y2 = cmnd[best + 1], den = y0 - 2 * y1 + y2
            let tau = Double(best) + (abs(den) > 1e-9 ? 0.5 * (y0 - y2) / den : 0)
            pitch[k] = Int((100 * (69 + 12 * log2(16000 / tau / 440))).rounded())
        }
        return Features(source: source, floor: (floor * 10).rounded() / 10,
                        db: dbs.map { Int(($0 * 10).rounded()) },
                        onset: flux.map { top > 0 ? Int(min(100, 100 * $0 / top).rounded()) : 0 },
                        pitch: pitch, clarity: clarity, voiced: dbs.map { Double($0) >= floor ? 1 : 0 })
    }
}
