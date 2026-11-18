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
        /// The glyph cores: the most common colour (r, g, b, a) in a rect, ignoring empty pixels. Antialiased edges vary;
        /// a stroke's inside is the painter's exact colour, so this is what the spec's ±3 is checked against.
        func core(_ r: CGRect) -> [Int]? {
            let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
            var count: [[Int]: Int] = [:]
            for y in max(0, Int(r.minY))..<min(h, Int(r.maxY)) {
                for x in max(0, Int(r.minX))..<min(w, Int(r.maxX)) {
                    let i = ((h - 1 - y) * w + x) * 4, a = Int(p[i + 3])
                    if a > 20 { count[[Int(p[i]) * 255 / a, Int(p[i + 1]) * 255 / a, Int(p[i + 2]) * 255 / a, a], default: 0] += 1 }
                }
            }
            return count.max { $0.value < $1.value }?.key
        }
    }

    private func near(_ c: [Int]?, _ want: [Int], _ tol: Int = 3) -> Bool {
        guard let c else { return false }
        return zip(c, want).allSatisfy { abs($0 - $1) <= tol }
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
        // spec FEAT-05 rule 2, ±3: spoken #F2F1F1, current gold #F5E399, upcoming white at 55 %
        XCTAssertTrue(near(c.core(first), [0xF2, 0xF1, 0xF1, 255]), "spoken core: \(String(describing: c.core(first)))")
        XCTAssertTrue(near(c.core(litPart), [0xF5, 0xE3, 0x99, 255]), "gold core: \(String(describing: c.core(litPart)))")
        let see = items.first { $0.text == "see" }!.rect
        XCTAssertTrue(near(c.core(see), [255, 255, 255, 140]), "upcoming core: \(String(describing: c.core(see)))")
        // the translation sits under the original, regular weight
        let tr = items.filter { $0.kind == .translation }
        XCTAssertFalse(tr.isEmpty); XCTAssertLessThan(tr.map(\.rect.maxY).max()!, items.filter { $0.kind == .original }.map(\.rect.minY).min()! + 0.5)
    }

    func testALineChangeShowsTheNewLineWholeAndGreyAtOnce() {
        let w = words("a new line begins here", from: 5)
        let line = Caption.Line(words: w, translationText: "une nouvelle ligne commence ici")
        var style = CaptionStyle(); style.shadow = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        for mode in [CaptionMode.follow, .learn] {
            let c = Canvas(), box = CGRect(x: 0, y: 0, width: 900, height: 240)
            CaptionPainter.draw(line, mode: mode, at: 4.99, in: c.ctx, box: box, style: style)
            let orig = CaptionPainter.layout(line, mode: mode, at: 4.99, in: box, style: style).items.filter { $0.kind == .original }
            XCTAssertEqual(orig.map(\.text), w.map(\.text), "\(mode): every word laid out before the first is heard")
            for it in orig { XCTAssertTrue(near(c.core(it.rect), [255, 255, 255, 140]), "\(mode) \(it.text) grey: \(String(describing: c.core(it.rect)))") }
        }
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

    // Regression guard: BUG-24 review 4 (11-18): a line too long even at 60 % was centred, so the word being said could
    // fall off the bottom of the floating window (the 11-10 fix kept the newest words at the bottom)
    func testAForcedLineKeepsTheWordBeingSaidInTheBox() {
        let text = (1...6).map { _ in "The sun goes down and the light turns cold over the water," }.joined(separator: " ")
        let w = words(text, step: 0.2), box = CGRect(x: 18, y: 12, width: 364, height: 164)
        var style = CaptionStyle(); style.size = 24
        for k in [3, 40, w.count - 2] {
            let t = w[k].start + 0.05
            let l = CaptionPainter.layout(Caption.Line(words: w, translationText: text), mode: .follow, at: t, in: box, style: style)
            let said = l.items.filter { $0.kind == .original }[k].rect
            XCTAssertTrue(said.minY >= box.minY - 0.5 && said.maxY <= box.maxY + 0.5, "word \(k) at \(said) is outside \(box)")
            XCTAssertTrue(l.items.allSatisfy { $0.rect.minY >= box.minY - 0.5 }, "nothing is cut at the foot")
        }
    }

    // ---------- option A (11-17): what the Mac's renderer carried, now in the one painter ----------

    func testRightToLeftScriptAndVisualOrderKeepALatinRunInItsOwnOrder() {
        XCTAssertTrue(Caption.rtl("كثيرا")); XCTAssertTrue(Caption.rtl("שלום")); XCTAssertFalse(Caption.rtl("chat"))
        XCTAssertTrue(Caption.rtl(words: ["و", "New", "York", "كثيرا"]), "opens in Arabic, a third or more Arabic")
        XCTAssertFalse(Caption.rtl(words: ["I", "love", "the", "word", "حب"]))
        let seen = Caption.visual(["أحب", "New", "York", "كثيرا"], rtl: true, text: { $0 })
        XCTAssertEqual(seen, ["كثيرا", "New", "York", "أحب"])
        XCTAssertEqual(Caption.visual(["a", "b"], rtl: false, text: { $0 }), ["a", "b"])
    }

    func testFollowRightToLeftLineRunsRightToLeft() {
        let w = words("أنا أحب القراءة")
        let l = CaptionPainter.layout(Caption.Line(words: w, translationText: "I love reading"), mode: .follow, at: 0,
                                      in: CGRect(x: 0, y: 0, width: 900, height: 240))
        let o = l.items.filter { $0.kind == .original }
        XCTAssertGreaterThan(o.first { $0.text == "أنا" }!.rect.minX, o.first { $0.text == "القراءة" }!.rect.minX, "first word on the right")
        let tr = l.items.filter { $0.kind == .translation }
        XCTAssertLessThan(tr.first { $0.text == "I" }!.rect.minX, tr.first { $0.text == "reading" }!.rect.minX, "English stays left to right")
    }

    func testBalanceSizesAndOpacityPerLanguageAndAHiddenSideTakesNoRoom() {
        let line = Caption.Line(words: words("le chat dort"), translationText: "the cat sleeps")
        let box = CGRect(x: 0, y: 0, width: 900, height: 240)
        var s = CaptionStyle(); s.balance = .init(l1: 1.2, l2: 0.8, a1: 0.7, a2: 0.5)
        let l = CaptionPainter.layout(line, mode: .follow, at: 0, in: box, style: s)
        let o = l.items.first { $0.kind == .original }!, t = l.items.first { $0.kind == .translation }!
        XCTAssertEqual(CTFontGetSize(o.font), 28 * 1.2, accuracy: 0.01); XCTAssertEqual(CTFontGetSize(t.font), 28 * 0.8, accuracy: 0.01)
        XCTAssertEqual(o.alpha, 0.7, accuracy: 1e-6); XCTAssertEqual(t.alpha, 0.5, accuracy: 1e-6)
        s.balance.a2 = 0
        XCTAssertTrue(CaptionPainter.layout(line, mode: .follow, at: 0, in: box, style: s).items.allSatisfy { $0.kind == .original }, "L2 hidden: no room")
        s.balance = .init(a1: 0)
        XCTAssertTrue(CaptionPainter.layout(line, mode: .follow, at: 0, in: box, style: s).items.allSatisfy { $0.kind == .translation }, "L1 hidden")
        let english = Caption.Line(words: words("the cat sleeps"), translation: [])
        XCTAssertEqual(CaptionPainter.layout(english, mode: .follow, at: 0, in: box, style: s).items.count, 3, "untranslated speech is never hidden")
        s.balance = .init(a2: 0)
        let learn = CaptionPainter.layout(line, mode: .learn, at: 10, in: box, style: s).items
        XCTAssertTrue(learn.allSatisfy { $0.kind == .original && $0.alpha == 1 }, "Learn, L2 hidden: nothing turns")
    }

    func testGuessDimsTheOriginalAndTranslatingWaitsInItsPlace() {
        let box = CGRect(x: 0, y: 0, width: 900, height: 240)
        var s = CaptionStyle(); s.guess = true; s.translating = "translating…"
        let pending = Caption.Line(words: words("le chat dort"), translation: nil)
        let l = CaptionPainter.layout(pending, mode: .follow, at: 0, in: box, style: s)
        XCTAssertTrue(l.items.filter { $0.kind == .original }.allSatisfy { abs($0.alpha - 0.5) < 1e-6 }, "a guess: half")
        let w = l.items.filter { $0.placeholder }
        XCTAssertEqual(w.map(\.text), ["translating…"]); XCTAssertEqual(w.first?.kind, .translation)
        s.translating = nil
        XCTAssertFalse(CaptionPainter.layout(pending, mode: .follow, at: 0, in: box, style: s).items.contains { $0.placeholder })
        // drawn white at 55 %, not as a spoken (white) phrase
        let c = Canvas(); s.translating = "translating…"; s.guess = false; s.shadow = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        CaptionPainter.draw(pending, mode: .follow, at: 0, in: c.ctx, box: box, style: s)
        let r = CaptionPainter.layout(pending, mode: .follow, at: 0, in: box, style: s).items.first { $0.placeholder }!.rect
        XCTAssertTrue(near(c.core(r), [255, 255, 255, 140]), "placeholder core: \(String(describing: c.core(r)))")
    }

    func testTwoPlacesTakenInTurnAndALongSilenceClearsThem() {
        let a = Caption.Line(words: words("one two", from: 0), translation: []), b = Caption.Line(words: words("three four", from: 1), translation: [])
        let c = Caption.Line(words: words("five six", from: 2), translation: []), far = Caption.Line(words: words("later on", from: 40), translation: [])
        let lines = [a, b, c, far]
        XCTAssertEqual(Caption.places(lines, at: 0.2, held: false).first { $0.line == 0 }?.place, 0)
        let mid = Caption.places(lines, at: 1.2, held: false)
        XCTAssertEqual(mid.first { $0.line == 1 }?.place, 1, "the next line takes the other place")
        XCTAssertNotNil(mid.first { $0.line == 0 }, "the line before stays while the light crosses the next")
        XCTAssertEqual(Caption.places(lines, at: 2.5, held: false).first { $0.line == 2 }?.place, 0, "then back to the top")
        XCTAssertTrue(Caption.places(lines, at: 25, held: false).isEmpty, "a long silence clears both")
        XCTAssertEqual(Caption.places(lines, at: 40.3, held: false).first { $0.line == 3 }?.place, 0, "after a silence: top again")
        XCTAssertFalse(Caption.places(lines, at: 7, held: true).isEmpty, "paused: never cleared")
        XCTAssertEqual(Caption.readBy(a), a.end + 0.6, accuracy: 1e-9)
    }

    func testDrawPlacesPutsTheTopPlaceAboveTheBottomAtOneSize() {
        let a = Caption.Line(words: words("one two", from: 0), translation: []), b = Caption.Line(words: words("three four", from: 1), translation: [])
        let box = CGRect(x: 0, y: 0, width: 900, height: 300)
        let boxes = CaptionPainter.placeBoxes(box)
        XCTAssertGreaterThan(boxes[0].minY, boxes[1].minY, "place 0 is the top (Core Graphics: y up)")
        XCTAssertLessThanOrEqual(boxes[0].height + boxes[1].height, box.height)
        let size = CaptionPainter.uniformSize([a, b], in: boxes[1], style: .init(), from: 10, to: 60)
        XCTAssertGreaterThan(size, 10); XCTAssertLessThanOrEqual(size, 60)
        let long = Caption.Line(words: words(Array(repeating: "longword", count: 30).joined(separator: " ")), translation: [])
        XCTAssertLessThan(CaptionPainter.uniformSize([a, long], in: boxes[1], style: .init(), from: 10, to: 60), size, "the longest line sets it")
        let c = Canvas(900, 300)
        var s = CaptionStyle(); s.size = size; s.shadow = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        CaptionPainter.drawPlaces([a, b], at: 1.2, held: false, in: c.ctx, box: box, style: s)
        XCTAssertNotNil(c.ink(boxes[0]), "top place drawn"); XCTAssertNotNil(c.ink(boxes[1]), "bottom place drawn")
    }
}
