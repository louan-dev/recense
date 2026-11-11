// Tests for HostApp/iOS/ListenEars.swift: which ear hears, and the once-per-stop prompt. Run on the Mac:
//   swiftc -O mobile/HostApp/iOS/ListenEars.swift mobile/ios/Tests/ears/main.swift -o "$TMPDIR/ears" && "$TMPDIR/ears"
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failed += 1 } }

// Every input, its output written down (2 × 3 × 2 × 2 × 2 = 48 rows).
// broadcast, route, paused, mic allowed, other audio  →  ear, feed the mic's sound, prompt due
typealias Row = (Bool, Ears.Route, Bool, Bool, Bool, Ears.Ear, Bool, Bool)
let table: [Row] = [
    (false, .speaker   , false, false, false,   .none     , false, true ),
    (false, .speaker   , false, false, true ,   .none     , false, true ),
    (false, .speaker   , false, true , false,   .none     , false, true ),
    (false, .speaker   , false, true , true ,   .none     , false, true ),
    (false, .speaker   , true , false, false,   .none     , false, false),
    (false, .speaker   , true , false, true ,   .none     , false, false),
    (false, .speaker   , true , true , false,   .none     , false, false),
    (false, .speaker   , true , true , true ,   .none     , false, false),
    (false, .headphones, false, false, false,   .none     , false, true ),
    (false, .headphones, false, false, true ,   .none     , false, true ),
    (false, .headphones, false, true , false,   .none     , false, true ),
    (false, .headphones, false, true , true ,   .none     , false, true ),
    (false, .headphones, true , false, false,   .none     , false, false),
    (false, .headphones, true , false, true ,   .none     , false, false),
    (false, .headphones, true , true , false,   .none     , false, false),
    (false, .headphones, true , true , true ,   .none     , false, false),
    (false, .other     , false, false, false,   .none     , false, true ),
    (false, .other     , false, false, true ,   .none     , false, true ),
    (false, .other     , false, true , false,   .none     , false, true ),
    (false, .other     , false, true , true ,   .none     , false, true ),
    (false, .other     , true , false, false,   .none     , false, false),
    (false, .other     , true , false, true ,   .none     , false, false),
    (false, .other     , true , true , false,   .none     , false, false),
    (false, .other     , true , true , true ,   .none     , false, false),
    (true , .speaker   , false, false, false,   .broadcast, false, false),
    (true , .speaker   , false, false, true ,   .broadcast, false, false),
    (true , .speaker   , false, true , false,   .broadcast, false, false),
    (true , .speaker   , false, true , true ,   .broadcast, false, false),
    (true , .speaker   , true , false, false,   .none     , false, false),
    (true , .speaker   , true , false, true ,   .none     , false, false),
    (true , .speaker   , true , true , false,   .none     , false, false),
    (true , .speaker   , true , true , true ,   .none     , false, false),
    (true , .headphones, false, false, false,   .broadcast, false, false),
    (true , .headphones, false, false, true ,   .broadcast, false, false),
    (true , .headphones, false, true , false,   .broadcast, false, false),
    (true , .headphones, false, true , true ,   .broadcast, false, false),
    (true , .headphones, true , false, false,   .none     , false, false),
    (true , .headphones, true , false, true ,   .none     , false, false),
    (true , .headphones, true , true , false,   .none     , false, false),
    (true , .headphones, true , true , true ,   .none     , false, false),
    (true , .other     , false, false, false,   .broadcast, false, false),
    (true , .other     , false, false, true ,   .broadcast, false, false),
    (true , .other     , false, true , false,   .broadcast, false, false),
    (true , .other     , false, true , true ,   .broadcast, false, false),
    (true , .other     , true , false, false,   .none     , false, false),
    (true , .other     , true , false, true ,   .none     , false, false),
    (true , .other     , true , true , false,   .none     , false, false),
    (true , .other     , true , true , true ,   .none     , false, false),
]
check(table.count == 48, "the table covers every input (48 rows)")
var wrong = 0
for (b, r, p, m, o, ear, feed, prompt) in table {
    let got = Ears.decide(.init(broadcast: b, route: r, paused: p, micAllowed: m, otherAudio: o))
    if got != .init(ear: ear, feed: feed, prompt: prompt) {
        wrong += 1
        print("  row broadcast=\(b) route=\(r) paused=\(p) mic=\(m) other=\(o): got \(got)")
    }
}
check(wrong == 0, "decide matches every row of the truth table")
check(!table.contains { $0.2 && ($0.5 != .none || $0.7) }, "paused: never an ear, never a prompt")
// no mic as a media ear on iPhone/iPad (owner, 2026-11-10): the table, and every input computed afresh
check(!table.contains { $0.5 == .mic || $0.6 }, "the table never picks the mic, never feeds it")
var micPicked = 0
for b in [false, true] { for r in [Ears.Route.speaker, .headphones, .other] { for p in [false, true] {
    for m in [false, true] { for o in [false, true] {
        let c = Ears.decide(.init(broadcast: b, route: r, paused: p, micAllowed: m, otherAudio: o))
        for running in [false, true] { for front in [false, true] {
            let r2 = Ears.reachable(c, micRunning: running, foreground: front)
            if c.ear == .mic || c.feed || r2.ear == .mic || r2.feed { micPicked += 1 }
        } }
    } }
} } }
check(micPicked == 0, "no input, in front or behind, mic running or not, yields the mic")
// regression (S3b stand-in heard the room): speaker, mic allowed, another app playing, no broadcast → no mic,
// and the prompt to start the broadcast instead
check(Ears.decide(.init(broadcast: false, route: .speaker, paused: false, micAllowed: true, otherAudio: true))
      == .init(ear: .none, feed: false, prompt: true), "speaker + mic allowed + other audio, no broadcast: no ear, the prompt")

// where the sound goes, from AVAudioSession.Port raw values
check(Ears.route(["Speaker"]) == .speaker, "built-in speaker")
check(Ears.route(["Receiver"]) == .speaker, "earpiece counts as the device's own speaker")
check(Ears.route(["BluetoothA2DPOutput"]) == .headphones, "AirPods (A2DP)")
check(Ears.route(["Headphones"]) == .headphones, "wired headphones")
check(Ears.route(["BluetoothLE"]) == .headphones && Ears.route(["BluetoothHFP"]) == .headphones, "Bluetooth LE and HFP")
check(Ears.route(["AirPlay"]) == .other && Ears.route(["CarAudio"]) == .other, "AirPlay and car: elsewhere")
check(Ears.route([]) == .speaker, "no output listed: the device's own speaker")

// one prompt per stop
let heads = Ears.decide(.init(broadcast: false, route: .headphones, paused: false, micAllowed: true, otherAudio: true))
let cast = Ears.decide(.init(broadcast: true, route: .headphones, paused: false, micAllowed: true, otherAudio: true))
let paused = Ears.decide(.init(broadcast: false, route: .headphones, paused: true, micAllowed: true, otherAudio: true))
var pr = Ears.Prompts()
pr.update(before: .broadcast, now: heads)                  // iOS ended the broadcast, headphones on
check(pr.shows(heads), "a stop shows the prompt")
check(pr.notify(heads) && !pr.notify(heads), "the notification goes once per stop")
pr.dismiss()
check(!pr.shows(heads), "dismissed: gone")
pr.update(before: .none, now: heads)                       // still nothing hearing: the same stop
check(!pr.shows(heads), "dismissed stays dismissed until the next stop")
pr.update(before: .none, now: cast)                        // the broadcast hears again
check(!pr.shows(cast), "while an ear hears, no prompt")
pr.update(before: .broadcast, now: heads)                  // the broadcast ended again: a new stop
check(pr.shows(heads) && pr.notify(heads), "a new stop prompts again, once")
pr.update(before: .none, now: cast)
pr.update(before: .broadcast, now: paused)                 // the owner's Pause is not a stop
check(!pr.shows(paused), "Pause never prompts")
let s = pr.stop
pr.update(before: .broadcast, now: paused)
check(pr.stop == s, "Pause doesn't count as a stop")
pr.dismiss()
pr.resumed()
check(pr.shows(heads), "Resume after Pause: the prompt can show again")

// a mic that is due but can't start (Recense in the background): every case written down
let none = Ears.Choice(ear: .none, feed: false, prompt: true)
let micFed = Ears.Choice(ear: .mic, feed: true, prompt: false)
let castC = Ears.Choice(ear: .broadcast, feed: false, prompt: false)
let quiet = Ears.Choice(ear: .none, feed: false, prompt: false)
// choice, mic running, in front  →  what hears
let reach: [(Ears.Choice, Bool, Bool, Ears.Choice)] = [
    (micFed, false, false, none),     // due, not running, behind: nothing hears, ask for the tap
    (micFed, false, true,  micFed),   // due, not running, in front: it starts
    (micFed, true,  false, micFed),   // already running behind: keeps hearing
    (micFed, true,  true,  micFed),
    (castC,  false, false, castC),    // the broadcast is never held back
    (castC,  true,  true,  castC),
    (none,   false, false, none),
    (quiet,  false, false, quiet),    // paused stays quiet
]
check(reach.allSatisfy { Ears.reachable($0.0, micRunning: $0.1, foreground: $0.2) == $0.3 }, "reachable: every row as written")

let data = try! JSONEncoder().encode(pr)
check((try? JSONDecoder().decode(Ears.Prompts.self, from: data)) == pr, "the prompt state survives a relaunch (Codable)")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
