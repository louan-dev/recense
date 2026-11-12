// Tests for shared/CaptionSeek.swift: seek a transcript word by fingerprint position.
// Run on the Mac (needs Accelerate):
//   swiftc -O shared/fingerprint.swift shared/CaptionSeek.swift \
//          mobile/ios/Tests/captionseek/main.swift \
//          -o "$TMPDIR/captionseek" && "$TMPDIR/captionseek"
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failed += 1 } }
func near(_ name: String, _ a: Double, _ b: Double, tol: Double = 0.5) {
    check(abs(a - b) <= tol, "\(name): \(a) want ≈\(b) ±\(tol)")
}

// ---- synthetic word starts (0.5 s each) ----
let starts: [Double] = (0..<20).map { Double($0) * 0.5 }

// ---- wordIndex ----
check(CaptionSeek.wordIndex(at: 0.0,  starts: starts) == 0,  "word 0 at t=0.0")
check(CaptionSeek.wordIndex(at: 0.3,  starts: starts) == 0,  "word 0 at t=0.3")
check(CaptionSeek.wordIndex(at: 0.5,  starts: starts) == 1,  "word 1 at t=0.5")
check(CaptionSeek.wordIndex(at: 1.25, starts: starts) == 2,  "word 2 at t=1.25")
check(CaptionSeek.wordIndex(at: 9.5,  starts: starts) == 19, "word 19 at t=9.5")
check(CaptionSeek.wordIndex(at: -1.0, starts: starts) == 0,  "clamp before first word")

// ---- refTime round-trip via Fingerprint ----
// Build a synthetic 30-second reference recording: a frequency-swept chirp (300–2000 Hz),
// which produces distinct fingerprint words at every position (a pure sine is "silent" to the
// fingerprinter because its per-band energy doesn't change frame to frame).
let sr = Int(Fingerprint.sr)
let refDur = 35
let refAudio: [Float] = (0..<(sr * refDur)).map { i in
    let t = Float(i) / Float(sr)
    let f = 300 + 1700 * t / Float(refDur)   // sweep 300→2000 Hz over 30 s
    return sin(2 * .pi * f * t)
}
let refFP = Fingerprint.words(refAudio)

// A 15-second live window starting at exactly 10 s into the recording.
// locateLive needs ≥ 120 words (~15.4 s at Fingerprint.step ≈ 0.128 s/word); use 17 s.
let liveStart = 10 * sr
let liveDur = 17 * sr
let liveAudio = Array(refAudio[liveStart..<(liveStart + liveDur)])
let liveFP = Fingerprint.phased(liveAudio)

// locateLive places the live buffer; refTime = n * step − shift = 17-s live buffer's end in ref time.
// live starts at ref 10 s, so the buffer end is at ref 27 s.
if let t = CaptionSeek.refTime(live: liveFP, ref: refFP) {
    near("refTime end-of-window", t, 27.0, tol: 0.5)
    // word at (t − 17) ≈ ref 10 s → word 20 in our 0.5-s grid
    let startIdx = CaptionSeek.wordIndex(at: t - 17.0, starts: starts)
    check(startIdx == 19 || startIdx == 20, "wordIndex at live-window start ≈ word 20 (got \(startIdx))")
} else {
    failed += 1
    print("FAIL refTime returned nil for clean sine wave")
}

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
