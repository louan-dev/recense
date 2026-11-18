// Derived from Spec: FEAT-10 (amendment 2026-11-18) · one language list; Follow in and Heard in read back.
import XCTest
@testable import ShowsKit

final class LangsTests: XCTestCase {
    func testFollowInIsThreeLanguagesDefaultFrench() {
        XCTAssertEqual(Langs.codes, ["en", "fr", "vi"])
        XCTAssertEqual(Langs.codes.map(Langs.name), ["English", "Français", "Tiếng Việt"])
        XCTAssertEqual(Langs.follow(kept: nil), "fr")
        XCTAssertEqual(Langs.follow(kept: "auto"), "fr", "auto is no longer a target")
        XCTAssertEqual(Langs.follow(kept: "vi"), "vi")
        XCTAssertEqual(Langs.follow(kept: "off"), "off")
        XCTAssertEqual(Langs.follow(kept: "de"), "fr")
    }

    func testHeardInIsAutoDetectOrALanguage() {
        XCTAssertEqual(Langs.heard(kept: nil), "auto")
        XCTAssertEqual(Langs.heard(kept: "off"), "auto")
        XCTAssertEqual(Langs.heard(kept: "fr"), "fr")
        XCTAssertEqual(Langs.locale("vi"), "vi-VN")
    }

    func testControlWordsInEnglishFrenchVietnamese() {
        for w in Langs.Word.allCases {
            let all = ["en", "fr", "vi"].map { Langs.say(w, in: $0) }
            XCTAssertEqual(Set(all).count, 3, "\(w): \(all)")
        }
        XCTAssertEqual(Langs.say(.followIn, in: "fr"), "Suivre en")
        XCTAssertEqual(Langs.say(.heardIn, in: "vi"), "Nghe bằng")
        XCTAssertEqual(Langs.say(.autoDetect, in: "de"), "Auto-detect", "other languages read English")
        XCTAssertEqual(Langs.spoken(.followIn, "Français", chosen: true, in: "en"), "Follow in: Français, selected")
        XCTAssertEqual(Langs.spoken(.heardIn, "English", chosen: false, in: "fr"), "Entendu en: English")
    }

    @MainActor func testModelReadsTheRetiredAutoAsFrench() {
        let d = UserDefaults.standard
        let (oldT, oldH) = (d.string(forKey: "recense.translateInto"), d.string(forKey: "recense.heardIn"))
        defer { d.set(oldT, forKey: "recense.translateInto"); d.set(oldH, forKey: "recense.heardIn") }
        d.set("auto", forKey: "recense.translateInto"); d.removeObject(forKey: "recense.heardIn")
        let m = ShowsModel(store: MemoryCatalog.sample(device: "ipad"), gate: Gate { _ in nil })
        XCTAssertEqual(m.translateInto, "fr")
        XCTAssertEqual(m.heardIn, "auto")
        var heard = 0
        m.heardInChanged = { heard += 1 }
        m.heardIn = "vi"; m.heardIn = "vi"
        XCTAssertEqual(heard, 1, "a change, once")
        XCTAssertEqual(d.string(forKey: "recense.heardIn"), "vi")
    }
}
