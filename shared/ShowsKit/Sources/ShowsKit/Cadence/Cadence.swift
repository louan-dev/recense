// Derived from Spec: FEAT-20 (moved verbatim from strip/recense.swift, 2026-11-16: one copy for the Mac, iPhone and iPad)
import Foundation
import CoreGraphics

/// A word and the stretch of media time in which it's spoken.
public struct Beat {
    public let text: String; public let start: Double; public let end: Double
    public var syl: [Syl]? = nil; public var un = false; public var k: Double? = nil; public var c: [Double]? = nil
    public init(text: String, start: Double, end: Double, syl: [Syl]? = nil, un: Bool = false, k: Double? = nil, c: [Double]? = nil) {
        self.text = text; self.start = start; self.end = end; self.syl = syl; self.un = un; self.k = k; self.c = c
    }
    /// A word as the light reads it: its syllables, whether it's sung, and the listener's pin (k, traced c).
    public init(_ w: Word) { self.init(text: w.text, start: w.start, end: w.end, syl: w.syl, un: w.un ?? false, k: w.tm?.k, c: w.tm?.c) }
}


/// Word times from Whisper and the lyrics say roughly where words start and nothing of how they're sung: the light
/// wiped each word at an even pace, finished a held note early and sat on it until the next word. With the song's
/// Features, a word starts on its onset, lasts as long as the voice holds it (into the next word when it runs on,
/// to the breath when it stops), and the light inside it moves as the voice spends itself (loudness over the floor):
/// slower through a held note, still through a breath.
public enum Cadence {
    /// Can a song's words be trusted enough to show them? (item 22; the same rule as Gallery's cadence.js
    /// `confidence`.) Not where many voices sing at once (a choir) or few words were heard surely, unless the song's
    /// own lyrics were found and its lines are theirs. Speech is never turned off.
    ///   dense  a single voice holds its notes: pitch rarely jumps > 1.5 semitones frame to frame (≤ 5 %) and runs
    ///          on (median ≥ 8 frames); a choir hops between voices (Whitacre: 7.3 %, 4 frames).
    ///          Dense: jumps ≥ 6 % with runs ≤ 6 frames, or jumps ≥ 9 %. Unknown without the voice.
    ///   rate   words heard a minute: under 15 with no voice measured. `duration` 0: over what's heard so far.
    public static func confidence<L: CadenceLine>(_ lines: [L], _ f: Features?, duration: Double) -> (off: Bool, dense: Bool?) {
        let ls = lines.filter { !$0.words.isEmpty }
        var speech = 0, lyric = 0, heard = 0, words = 0, last = 0.0
        for l in ls {
            if l.cadenceID < 2_000_000 { speech += 1 } else if l.cadenceID < 3_000_000 { lyric += 1 } else if l.cadenceID < 4_000_000 { heard += 1 }
            words += l.words.count; last = max(last, l.words.last?.end ?? 0)
        }
        let song = lyric + heard > speech, fromLyrics = lyric > 0 && lyric >= heard
        let d = duration > 0 ? duration : last, rate = d > 0 ? Double(words) / d * 60 : 0
        var dense: Bool? = nil
        if let f, f.source == "vocals" {
            let p = f.pitch, v = f.voiced, n = min(p.count, v.count)
            func on(_ k: Int) -> Bool { v[k] == 1 && p[k] > 0 }
            var pitched = 0, pairs = 0, jumps = 0, run = 0, runs: [Int] = []
            for k in 0..<n {
                if on(k) {
                    pitched += 1; run += 1
                    if k + 1 < n && on(k + 1) { pairs += 1; if abs(p[k + 1] - p[k]) > 150 { jumps += 1 } }
                } else if run > 0 { runs.append(run); run = 0 }
            }
            if run > 0 { runs.append(run) }
            if pitched >= 500 && pairs > 0 {
                runs.sort()
                let j = Double(jumps) / Double(pairs), r = runs[runs.count / 2]
                dense = (j >= 0.06 && r <= 6) || j >= 0.09
            }
        }
        return (song && !fromLyrics && (dense.map { $0 } ?? (rate < 15)), dense)
    }

    /// The measured voice of what's playing (set every frame on the main thread); nil: the light runs by the clock.
    public nonisolated(unsafe) static var track: Features? { didSet { if track !== oldValue { curves = [:]; notes = [:]; top = nil } } }
    public nonisolated(unsafe) static var curves: [String: [Float]] = [:]
    public nonisolated(unsafe) static var notes: [String: Double] = [:]   // a word's middle note (MIDI × 100)
    public nonisolated(unsafe) static var top: Double? = nil              // the voice's loud end (95th percentile, dB)

    /// The voice under the light at `t` (notes 33), all 0 at rest:
    ///   swell  0…1  loud and clear, more so the longer a note is held: a belt is full and bright
    ///   lift   pt   the note against the word's middle one (a semitone is 1.5 pt, ±6): the contour bends the light
    ///   shiver −1…1 the note against its last quarter second (±50 cents): vibrato, a gentle oscillation
    ///   thin   0…1  voice with little tone and little body, or a sudden break in the pitch: breathy, soft, cracking
    ///   soft   0…1  a clear vowel flowing (a feathered edge); an attack, a consonant, keeps the edge crisp
    public struct Voice {
        public var swell: CGFloat = 0, lift: CGFloat = 0, shiver: CGFloat = 0, thin: CGFloat = 0, soft: CGFloat = 0
        public init() {}
    }

    public static func voice(_ b: Beat, _ t: Double) -> Voice? {
        guard let f = track, f.source == "vocals", f.count > 20, t >= b.start else { return nil }
        let k = f.frame(t)
        func mean(_ a: [Int], _ r: ClosedRange<Int>, pitched: Bool = false) -> Double? {
            var sum = 0, n = 0
            for i in max(0, r.lowerBound)...min(f.count - 1, r.upperBound) where !pitched || a[i] > 0 { sum += a[i]; n += 1 }
            return n == 0 ? nil : Double(sum) / Double(n)
        }
        if top == nil {
            let v = (0..<f.count).filter(f.isVoiced).map { f.db[$0] }.sorted()
            top = v.isEmpty ? f.floor + 20 : Double(v[v.count * 95 / 100])
        }
        var out = Voice()
        guard f.isVoiced(k) else { out.thin = 0.35; return out }
        let e = min(1.15, max(0, ((mean(f.db, k - 3...k + 3) ?? f.floor) - f.floor) / max(6, top! - f.floor)))
        let clear = (mean(f.clarity, k - 3...k + 3) ?? 0) / 100
        let note = f.pitch[k]
        // held: how long the note has run on unbroken (up to 0.8 s)
        var held = 0
        while held < 80, k - held - 1 >= 0, f.pitch[k - held - 1] > 0, abs(f.pitch[k - held - 1] - note) < 150 { held += 1 }
        out.swell = CGFloat(min(1, e * (0.55 + 0.45 * clear) + (note > 0 ? 0.3 * Double(held) / 80 : 0)))
        out.thin = CGFloat(min(1, max(0, 0.55 - clear) * 1.8 * max(0, 1.1 - e)))
        if note > 0, k >= 3, f.pitch[k - 3] > 0, abs(f.pitch[k - 3] - note) > 300 { out.thin = max(out.thin, 0.8) }   // a crack
        if note > 0 {
            let key = "\(b.start)|\(b.end)"
            let mid: Double
            if let m = notes[key] { mid = m } else {
                mid = mean(f.pitch, f.frame(b.start)...f.frame(max(b.start, b.end)), pitched: true) ?? Double(note)
                if notes.count > 4000 { notes = [:] }
                notes[key] = mid
            }
            out.lift = CGFloat(max(-6, min(6, (Double(note) - mid) / 100 * 1.5)))
            if let local = mean(f.pitch, k - 12...k + 12, pitched: true), held >= 12 { out.shiver = CGFloat(max(-1, min(1, (Double(note) - local) / 50))) }
            out.soft = CGFloat(clear > 0.6 ? min(1, Double(held) / 15) * (1 - min(1, Double(f.onset[k]) / 60)) : 0)
        }
        return out
    }

    /// The lines with their words timed to the voice. Gallery runs the same rules (gallery/src/client/cadence.js),
    /// so the web player and the iOS app light the same word at the same moment as Recense: change one, change the other.
    public static func fit<L: CadenceLine>(_ lines: [L], _ f: Features) -> [L] {
        guard f.source == "vocals", f.count > 20 else { return lines }
        // decided on times to the millisecond, as Gallery keeps them (its cadence.js runs these same rules)
        let ms = { (x: Double) in (x * 1000).rounded() / 1000 }
        let flat = lines.flatMap(\.words).map { $0.timed(ms($0.start), ms($0.end)) }, n = flat.count
        guard n > 0 else { return lines }
        // an onset counts when it stands out among the voice's own (its 60th percentile, at least a tenth of the strongest)
        let peaks = (1..<(f.count - 1)).filter { f.isVoiced($0) && f.onset[$0] > 0 && f.onset[$0] >= f.onset[$0 - 1] && f.onset[$0] >= f.onset[$0 + 1] }
            .map { f.onset[$0] }.sorted()
        let strong = max(10, peaks.isEmpty ? 10 : peaks[peaks.count * 6 / 10])
        // the next word sung after each, in its line or the next
        var next = [Double](repeating: .infinity, count: n)
        for i in stride(from: n - 2, through: 0, by: -1) { next[i] = flat[i + 1].start > flat[i].start ? flat[i + 1].start : next[i + 1] }
        var s = flat.map(\.start), e = flat.map(\.end), legato = [Bool](repeating: false, count: n)
        // a line's first word, or one after a pause in what was heard
        var opens = [Bool](repeating: false, count: n), at = 0
        for l in lines { if !l.words.isEmpty { opens[at] = true }; at += l.words.count }
        for i in 1..<max(1, n) where flat[i - 1].end < flat[i].start - 0.15 { opens[i] = true }
        for i in 0..<n {
            let w = flat[i], after = min(next[i], w.start + 8), lower = i > 0 ? s[i - 1] + 0.03 : 0
            // Where its voice comes in, when the recognizer's start is plainly off (item 22: the light lagged the song):
            //  · run into the word before it (heard starting before that one ended), over a silence of 200 ms or more:
            //    it starts where the voice comes back after that silence, if it then sings on for 0.25 s ("Soro-soro"
            //    heard from 31.9 s in Sororité, over the end of the line before; sung from 32.9 s)
            //  · opening a line or following a pause (or after a breath of 100 ms or more), heard inside a voice that
            //    came in less than 0.4 s before: it starts where that voice came in. A recognizer times a sung word by
            //    its vowel, late (Whisper by 0.1 s at the median, the on-device ears by 0.2 s), and a light that trails
            //    the voice shows far sooner than one that leads it.
            // Never later than heard otherwise: a long word may be a held note of its own ("Reuss" over 1.3 s at 105 s),
            // and a leap inside one is as likely its own next syllable as the end of the note before it.
            var entry: Double? = nil
            let end = min(w.end, after), hk = f.frame(w.start)
            if i > 0, w.start < flat[i - 1].end + 0.05 {
                var quiet = 0
                for k in hk..<max(hk, f.frame(end - 0.25)) {
                    if !f.isVoiced(k) { quiet += 1; continue }
                    if quiet >= 20, f.sustained(k), (k..<min(f.count, k + 25)).filter(f.isVoiced).count >= 20 { entry = f.time(k); break }
                    quiet = 0
                }
            }
            if entry == nil, f.isVoiced(hk), let c = f.entries(max(lower + 0.12, w.start - 0.4), w.start).last,
               c.gap >= (opens[i] ? 0.05 : 0.1) {
                entry = f.time(c.k)
            }
            //  · a line opening inside a voice that never falls silent (a stem the orchestra bleeds into: Variations at
            //    1:13, voiced in every frame for seconds): the loudness says where the singer comes in, where it rises
            //    most (4 dB or more), from just before the heard start to 0.6 s after; the words after it follow it on
            if entry == nil, opens[i], f.saturated(hk),
               let k = f.rise(f.frame(max(lower, w.start - 0.12)), f.frame(min(w.end - 0.05, w.start + 0.6))) {
                entry = f.time(k)
            }
            if let entry { s[i] = entry }
            // else the onset nearest the recognizer's start, as strong as can be: within 120 ms, or from silence up to
            // 350 ms late (a late entry)
            let reach = f.isVoiced(f.frame(w.start)) ? 0.12 : 0.35
            let lo = f.frame(max(lower, w.start - 0.12)), hi = f.frame(min(after - 0.08, w.start + reach))
            if entry == nil, lo <= hi {
                let score = { (k: Int) in Double(f.onset[k]) * (1 - abs(f.time(k) - w.start) / 0.4) }
                if let k = (lo...hi).filter({ k in f.onset[k] >= strong && f.sustained(k) && (k == 0 || f.onset[k] >= f.onset[k - 1])
                                                && (k + 1 >= f.count || f.onset[k] >= f.onset[k + 1]) }).max(by: { score($0) < score($1) }) {
                    s[i] = f.time(k)
                }
            }
            s[i] = max(s[i], lower)
            // held while the voice holds it: any voice up to Whisper's end (consonants too), then one note running on
            // unbroken (pitched in most of any 100 ms: vibrato, a melisma's steps; a stray pitched frame on a consonant
            // doesn't count), not a new syllable after a consonant (an ad-lib, a backing line) — into the next word
            // when it runs on into it, else to where it stops
            let stop = f.frame(after), own = f.frame(min(w.end, after))
            let note = { (k: Int) in f.isVoiced(k) && f.pitch[k] > 0 }
            var k = f.frame(s[i]), last = -1, quiet = 0, broke = false
            while k < stop {
                if k < own {
                    if f.isVoiced(k) { last = k; quiet = 0 } else { quiet += 1; if quiet >= 15 { broke = true; break } }
                } else if note(k) { last = k }
                else if (max(own, k - 9)...k).filter(note).count <= 3 && k - own >= 6 { broke = true; break }
                k += 1
            }
            if last < 0 { e[i] = min(w.end, after) }                                   // no voice under it: as it was
            else if !broke && after < .infinity { e[i] = after; legato[i] = after == next[i] }
            else { e[i] = f.time(last + 1) }
            e[i] = min(max(e[i], s[i] + 0.05), s[i] + 8)
        }
        // a word ends where the next starts, once those have moved
        for i in 0..<n where next[i] < .infinity {
            guard let j = (i + 1..<n).first(where: { flat[$0].start > flat[i].start }) else { continue }
            e[i] = legato[i] ? max(s[i] + 0.05, s[j]) : min(e[i], max(s[i] + 0.05, s[j]))
        }
        // then a song's words hung on the voice's own syllables (cadence.swift): the audio decides when each is sung
        // and for how long; a written word that isn't sung is marked so
        let (syl, un) = align(lines, f, flat, &s, &e)
        var i = 0
        return lines.map { l in
            l.with(words: l.words.map { w in
                defer { i += 1 }
                var x = w.timed(ms(s[i]), ms(e[i])); x.syl = syl[i].map { $0.map { Syl(c: $0.c, s: ms($0.s), e: ms($0.e)) } }
                if un[i] { x.un = true }
                return x
            })
        }
    }

    /// How much of the voice in a word has been spent at each frame from its start (0…1, one more value than frames).
    public static func curve(_ f: Features, _ start: Double, _ end: Double) -> [Float]? {
        let a = f.frame(start), b = min(f.count, max(a + 1, Int((end / f.hop).rounded())))
        guard b - a >= 3 else { return nil }
        let fl = Float(f.floor)
        let w = (a..<b).map { k in f.voiced[k] == 1 ? min(30, max(1, Float(f.db[k]) / 10 - fl + 1)) : 0 }
        let mean = w.reduce(0, +) / Float(w.count)
        guard mean > 0 else { return nil }
        var acc: [Float] = [0], sum: Float = 0
        for x in w { sum += max(x, 0.03 * mean); acc.append(sum) }        // a breath inside a word all but holds the light
        return acc.map { $0 / sum }
    }

    /// How far through a word the light is at t (0…1): by the voice spent, or the clock where nothing was measured.
    /// A sung word timed syllable by syllable sweeps through its letters without stopping: each syllable's letters are
    /// spread over the time it's sung, up to where the next comes in (or 0.25 s past its end, so a breath isn't swept
    /// through), so the light slows on a held "on" and hurries through a quick var-i-a (gallery.js `fillOf`).
    public static func progress(_ b: Beat, _ t: Double) -> Double {
        if let c = b.c, c.count > 1 {        // traced by a finger: joined straight between its moments (cadence.js `fill`)
            let u = max(0, min(1, (t - b.start) / max(0.05, b.end - b.start))) * Double(c.count - 1)
            let j = min(c.count - 2, Int(u))
            return c[j] + (c[j + 1] - c[j]) * (u - Double(j))
        }
        if let k = b.k {                     // timed by the listener: one sweep shaped by k (cadence.js `fill`)
            let u = max(0, min(1, (t - b.start) / max(0.05, b.end - b.start)))
            return pow(u, pow(2, -1.5 * k))
        }
        if let syl = b.syl, !syl.isEmpty, !b.text.isEmpty {
            let n = Double(b.text.unicodeScalars.count)
            var c0 = 0.0
            for (k, y) in syl.enumerated() {
                let end = k + 1 < syl.count ? min(syl[k + 1].s, y.e + 0.25) : y.e
                if t < y.s { return c0 / n }
                if t < end { return min(1, (c0 + (Double(y.c) - c0) * (t - y.s) / max(0.05, end - y.s)) / n) }
                c0 = Double(y.c)
            }
            return 1
        }
        let clock = (t - b.start) / max(0.05, b.end - b.start)
        guard let f = track else { return clock }
        let key = "\(b.start)|\(b.end)"
        let c: [Float]
        if let m = curves[key] { c = m }
        else {
            guard let m = curve(f, b.start, b.end) else { return clock }
            if curves.count > 4000 { curves = [:] }
            curves[key] = m; c = m
        }
        let x = (t - f.time(f.frame(b.start))) / f.hop, i = Int(x.rounded(.down))
        guard i >= 0 else { return 0 }
        guard i + 1 < c.count else { return 1 }
        return Double(c[i] + (c[i + 1] - c[i]) * Float(x - Double(i)))
    }
}
