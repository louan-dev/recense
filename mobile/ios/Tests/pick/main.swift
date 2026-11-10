// Tests for the live language check's rules (shared/speechcore.swift: SpeechCore.Doubt, pick, sureness, loud). Run:
//   swiftc -O shared/speechcore.swift mobile/ios/Tests/pick/main.swift -o "$TMPDIR/pick" && "$TMPDIR/pick"
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failed += 1 } }
typealias W = SpeechCore.W
func words(_ t: String, _ lang: String, c: Double = 0.9) -> [W] {
    t.split(separator: " ").enumerated().map { W(text: String($1), start: Double($0) * 0.4, end: Double($0) * 0.4 + 0.35, c: c, lang: lang) }
}

// when to check
var d = SpeechCore.Doubt()
d.tick(sound: 2.9, seconds: 2.9); check(!d.due(), "no first check before 3 s of sound")
d.tick(sound: 0.1, seconds: 0.1); check(d.due(), "first check at 3 s of sound")
d.checked(speech: true)
d.tick(sound: 10, seconds: 10); d.heard(words("one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen", "en")); check(!d.due(), "sure words at a normal pace: no doubt")
var f = SpeechCore.Doubt(); f.checks = 1; f.tick(sound: 10, seconds: 10); f.heard(words("two words", "en")); check(f.due(), "few words over 10 s of sound: doubt (the wrong language writes little)")
var u = SpeechCore.Doubt(); u.checks = 1; u.tick(sound: 10, seconds: 10); u.heard(words("a b c d e f g h i j k l m n o p q r s t", "en", c: 0.3)); check(u.due(), "unsure words: doubt")
var mm = SpeechCore.Doubt(); mm.checks = 1; for _ in 0..<60 { mm.tick(sound: 1, seconds: 1); mm.heard(words("one two three", "en")) }; check(mm.due(), "a minute of sound: check anyway")
var m = SpeechCore.Doubt(); m.checked(speech: false); m.tick(sound: 10, seconds: 10); check(!m.due(), "music (no speech found): waits 16 s, not 8")
m.tick(sound: 6, seconds: 6); check(m.due(), "music: checks again at 16 s")
for _ in 0..<6 { m.checked(speech: false) }; m.tick(sound: 119, seconds: 119); check(!m.due(), "music keeps backing off, up to 2 minutes")
m.tick(sound: 1, seconds: 1); check(m.due(), "never longer than 2 minutes")

// doubt reads the last seconds, not everything since the last check (11-10: 40 s of good English hid Vietnamese heard
// by the English model for a minute, so no check came)
var w = SpeechCore.Doubt(); w.tick(sound: 3, seconds: 3); w.checked(speech: true)
for _ in 0..<40 { w.tick(sound: 1, seconds: 1); w.heard(words("one two three", "en")) }   // 40 s of good English
check(!w.due(), "40 s of sure English at 3 words a second: no doubt")
for _ in 0..<10 { w.tick(sound: 1, seconds: 1) }                                          // then 10 s with no words
check(w.due(), "then 10 s of sound with no words: doubt (the recent window, not the average since the check)")

// which language
check(SpeechCore.pick(["en": 1.0, "fr": 0.2, "vi": 3.0], current: "en") == "vi", "a clear winner is taken")
check(SpeechCore.pick(["en": 2.0, "fr": 0.2, "vi": 2.6], current: "en") == nil, "a close one is not (no flip on a word or two)")
check(SpeechCore.pick(["en": 0, "fr": 0, "vi": 0], current: "en") == nil, "nothing heard anywhere: stay")
check(SpeechCore.pick(["en": 3.0, "vi": 1.0], current: "en") == nil, "the current one is surest: stay")
check(SpeechCore.pick(["fr": 1.0], current: "en") == "fr", "the current language heard nothing at all: the one that heard something")

// sureness reads the words' language among the candidates
let en = SpeechCore.sureness(words("the court held that the contract was void and the plaintiff appealed", "en"), "en", among: SpeechCore.auto)
let enAsVi = SpeechCore.sureness(words("the court held that the contract was void and the plaintiff appealed", "vi", c: 0.4), "vi", among: SpeechCore.auto)
check(en > 3 * enAsVi, "English words read as English score far above the same words claimed as Vietnamese")
check(SpeechCore.sureness([], "en", among: SpeechCore.auto) == 0, "no words: 0")

// sound
var tone = (0..<16000).map { Float(sin(Double($0) * 0.1) * 0.1) }, quiet = [Float](repeating: 0.0001, count: 16000)
check(abs(SpeechCore.loud(&tone, 16000, rate: 16000) - 1) < 0.03, "a second of sound is a second")
check(SpeechCore.loud(&quiet, 16000, rate: 16000) == 0, "near silence is not sound")
var soft = (0..<16000).map { Float(sin(Double($0) * 0.1) * 0.003) }  // about -54 dBFS: quiet speech
check(SpeechCore.loud(&soft, 16000, rate: 16000) > 0.95, "quiet speech (-54 dBFS) is sound (regression 11-10: checks came 10x late)")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
