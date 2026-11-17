// Derived from Spec: FEAT-05 (P1): the caption's rules and the one painter's pixels.
import CoreGraphics
import XCTest
@testable import ShowsKit

final class CaptionTests: XCTestCase {
    private func words(_ text: String, from t0: Double = 0, step: Double = 0.4) -> [Word] {
        text.split(separator: " ").enumerated().map { i, s in
            Word(text: String(s), start: t0 + Double(i) * step, end: t0 + Double(i + 1) * step)
        }
    }

    // ---------- rules ----------

    func testProgressByClockSyllablesAndPin() {
        let b = Caption.Beat(text: "word", start: 1, end: 2)
        XCTAssertEqual(Caption.progress(b, 0.5), 0)
        XCTAssertEqual(Caption.progress(b, 1.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Caption.progress(b, 3), 1)
        let sung = Caption.Beat(text: "abcd", start: 0, end: 2, syl: [Syl(c: 2, s: 0, e: 1), Syl(c: 4, s: 1, e: 2)])
        XCTAssertEqual(Caption.progress(sung, 1), 0.5, accuracy: 1e-9)       // first syllable sung: half the letters
        let pinned = Caption.Beat(text: "x", start: 0, end: 1, k: 0)
        XCTAssertEqual(Caption.progress(pinned, 0.25), 0.25, accuracy: 1e-9)
        XCTAssertEqual(Caption.progress(b, 1.5, voice: { _, _ in 0.9 }), 0.9, accuracy: 1e-9)
    }

    func testTranslationBeatsRunForwardAndCoverTheLine() {
        let w = words("le chat noir dort")
        let line = Caption.Line(words: w, translation: [.init(w: "the", s: [0]), .init(w: "black", s: [2]), .init(w: "cat", s: [1]), .init(w: "sleeps", s: [3])])
        let b = Caption.translationBeats(line)
        XCTAssertEqual(b.count, 4)
        for k in 1..<b.count { XCTAssertGreaterThan(b[k].start, b[k - 1].start) }  // order differs, the light still steps forward
        XCTAssertGreaterThanOrEqual(b.last!.end, line.end)
    }

    func testUnalignedTranslationFollowsTheSameShareAsTranslationCadence() {
        let w = words("un deux trois quatre")
        let line = Caption.Line(words: w, translationText: "one two three four")
        XCTAssertEqual(Caption.translationBeats(line).map(\.start),
                       TranslationCadence.times(source: w, start: line.start, end: line.end, count: 4))
    }

    func testPhrasesCoverEveryWordOnceAndCutAtClauses() {
        let w = words("je pense, donc je suis")
        let line = Caption.Line(words: w, translationText: "I think, therefore I am")
        let ph = Caption.phrases(line)
        XCTAssertEqual(ph.first?.src.lowerBound, 0); XCTAssertEqual(ph.last?.src.upperBound, w.count)
        XCTAssertEqual(ph.last?.en.upperBound, 5)
        for k in 1..<ph.count { XCTAssertEqual(ph[k].src.lowerBound, ph[k - 1].src.upperBound) }
        XCTAssertTrue(ph.contains { $0.src.upperBound == 2 }, "cut after the comma: \(ph)")
    }

    func testTurnStartsWhenTheLightLeavesThePhraseAndTakesTurnTime() {
        let w = words("je pense, donc je suis")
        let line = Caption.Line(words: w, translationText: "I think, therefore I am")
        let beats = Caption.sourceBeats(w), p = Caption.phrases(line)[0]
        let from = beats[p.src.upperBound - 1].end
        XCTAssertEqual(Caption.turned(line, p, beats: beats, at: from - 0.01), 0)
        XCTAssertEqual(Caption.turned(line, p, beats: beats, at: from + Caption.turnTime / 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Caption.turned(line, p, beats: beats, at: from + 1), 1)
        XCTAssertEqual(Caption.turned(Caption.Line(words: w, translation: nil), p, beats: beats, at: from + 1), 0)
    }

    // ---------- the painter's pixels ----------

    private struct Canvas {
        let ctx: CGContext; let w: Int; let h: Int
        init(_ w: Int = 900, _ h: Int = 240) {
            self.w = w; self.h = h
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        /// The strongest-ink pixels' colour in a rect (CG coordinates), un-premultiplied: what the glyph cores show.
        func ink(_ r: CGRect) -> (r: Double, g: Double, b: Double, a: Double)? {
            let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
            var best: [(Double, Double, Double, Double)] = []
            for y in max(0, Int(r.minY))..<min(h, Int(r.maxY)) {
                for x in max(0, Int(r.minX))..<min(w, Int(r.maxX)) {
                    let i = ((h - 1 - y) * w + x) * 4, a = Double(p[i + 3])
                    if a > 200 { best.append((Double(p[i]) * 255 / a, Double(p[i + 1]) * 255 / a, Double(p[i + 2]) * 255 / a, a)) }
                }
            }
            guard !best.isEmpty else { return nil }
            let n = Double(best.count)
            return (best.map(\.0).reduce(0, +) / n, best.map(\.1).reduce(0, +) / n, best.map(\.2).reduce(0, +) / n, best.map(\.3).reduce(0, +) / n)
        }
    }

    private func isGold(_ c: (r: Double, g: Double, b: Double, a: Double)?) -> Bool {
        guard let c else { return false }
        return abs(c.r - 0xF5) < 12 && abs(c.g - 0xE3) < 12 && abs(c.b - 0x99) < 16
    }
    private func isWhite(_ c: (r: Double, g: Double, b: Double, a: Double)?) -> Bool {
        guard let c else { return false }
        return c.r > 225 && c.g > 225 && c.b > 225
    }

    func testFollowMidWordGoldEdgeSpokenWhiteUpcomingDim() {
        let w = words("Everything that you have prayed to see", step: 0.5)   // "prayed" is 2.0 … 2.5
        let line = Caption.Line(words: w, translationText: "Tout ce que tu as prié de voir")
        let c = Canvas(), box = CGRect(x: 0, y: 0, width: 900, height: 240)
        var style = CaptionStyle(); style.shadow = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        let t = 2.2                                                                   // 40 % through "prayed"
        CaptionPainter.draw(line, mode: .follow, at: t, in: c.ctx, box: box, style: style)
        let items = CaptionPainter.layout(line, mode: .follow, at: t, in: box, style: style).items
        let prayed = items.first { $0.text == "prayed" }!.rect, first = items.first { $0.text == "Everything" }!.rect
        let litPart = CGRect(x: prayed.minX, y: prayed.minY, width: prayed.width * 0.3, height: prayed.height)
        let darkPart = CGRect(x: prayed.minX + prayed.width * 0.55, y: prayed.minY, width: prayed.width * 0.45, height: prayed.height)
        XCTAssertTrue(isGold(c.ink(litPart)), "the heard part of the word is gold: \(String(describing: c.ink(litPart)))")
        XCTAssertNil(c.ink(darkPart), "the unheard part is dim (no glyph pixel near full alpha)")
        XCTAssertTrue(isWhite(c.ink(first)), "a spoken word is white")
        // the translation sits under the original, regular weight
        let tr = items.filter { $0.kind == .translation }
        XCTAssertFalse(tr.isEmpty); XCTAssertLessThan(tr.map(\.rect.maxY).max()!, items.filter { $0.kind == .original }.map(\.rect.minY).min()! + 0.5)
    }

    func testLearnTurnedPhraseIsTheTranslationAndTheRowStaysCentred() {
        let w = words("je pense, donc je suis", step: 0.4)
        let line = Caption.Line(words: w, translationText: "I think, therefore I am")
        let box = CGRect(x: 0, y: 0, width: 900, height: 240)
        let before = CaptionPainter.layout(line, mode: .learn, at: 0.1, in: box)
        let after = CaptionPainter.layout(line, mode: .learn, at: 10, in: box)
        XCTAssertTrue(before.items.allSatisfy { $0.kind == .original || $0.alpha == 0 })
        let shown = after.items.filter { $0.alpha > 0.99 }
        XCTAssertTrue(shown.allSatisfy { $0.kind == .translation }, "every phrase heard → all translation: \(shown.map(\.text))")
        XCTAssertEqual(shown.map(\.text).joined(separator: " "), "I think, therefore I am")
        // no gaps: neighbours are one space apart, and the row is centred
        let xs = shown.sorted { $0.rect.minX < $1.rect.minX }
        let mid = (xs.first!.rect.minX + xs.last!.rect.maxX) / 2
        XCTAssertEqual(mid, box.midX, accuracy: 1)
        for k in 1..<xs.count { XCTAssertLessThan(xs[k].rect.minX - xs[k - 1].rect.maxX, 20) }
    }

    func testReduceMotionSnapsTheWidth() {
        let w = words("je pense, donc je suis", step: 0.4)
        let line = Caption.Line(words: w, translationText: "I think, therefore I am")
        var s = CaptionStyle(); s.reduceMotion = true
        let beats = Caption.sourceBeats(w), p = Caption.phrases(line)[0]
        let mid = beats[p.src.upperBound - 1].end + Caption.turnTime * 0.25
        let a = CaptionPainter.layout(line, mode: .learn, at: mid, in: CGRect(x: 0, y: 0, width: 900, height: 240), style: s)
        let b = CaptionPainter.layout(line, mode: .learn, at: 0, in: CGRect(x: 0, y: 0, width: 900, height: 240), style: s)
        XCTAssertEqual(a.items.filter { $0.kind == .original }.map(\.rect.minX), b.items.filter { $0.kind == .original }.map(\.rect.minX))
    }

    func testALongLineShrinksBeforeItIsCut() {
        let w = words(Array(repeating: "longword", count: 40).joined(separator: " "))
        let l = CaptionPainter.layout(Caption.Line(words: w, translation: nil), mode: .follow, at: 0, in: CGRect(x: 0, y: 0, width: 600, height: 240))
        XCTAssertLessThan(l.scale, 1)
        XCTAssertEqual(l.items.count, 40)
    }
}
