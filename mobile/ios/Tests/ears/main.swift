// Tests for HostApp/iOS/ListenEars.swift: which ear hears, and the once-per-stop prompt. Run on the Mac:
//   swiftc -O mobile/HostApp/iOS/ListenEars.swift mobile/ios/Tests/ears/main.swift -o "$TMPDIR/ears" && "$TMPDIR/ears"
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failed += 1 } }

// Every input, its output written down (2 × 3 × 2 × 2 = 24 rows). No mic: it's not an ear (owner, 2026-11-10).
// broadcast, route, paused, other audio  →  ear, prompt due
typealias Row = (Bool, Ears.Route, Bool, Bool, Ears.Ear, Bool)
let table: [Row] = [
    (false, .speaker   , false, false,   .none     , true ),
    (false, .speaker   , false, true ,   .none     , true ),
    (false, .speaker   , true , false,   .none     , false),
    (false, .speaker   , true , true ,   .none     , false),
    (false, .headphones, false, false,   .none     , true ),
    (false, .headphones, false, true ,   .none     , true ),
    (false, .headphones, true , false,   .none     , false),
    (false, .headphones, true , true ,   .none     , false),
    (false, .other     , false, false,   .none     , true ),
    (false, .other     , false, true ,   .none     , true ),
    (false, .other     , true , false,   .none     , false),
    (false, .other     , true , true ,   .none     , false),
    (true , .speaker   , false, false,   .broadcast, false),
    (true , .speaker   , false, true ,   .broadcast, false),
    (true , .speaker   , true , false,   .none     , false),
    (true , .speaker   , true , true ,   .none     , false),
    (true , .headphones, false, false,   .broadcast, false),
    (true , .headphones, false, true ,   .broadcast, false),
    (true , .headphones, true , false,   .none     , false),
    (true , .headphones, true , true ,   .none     , false),
    (true , .other     , false, false,   .broadcast, false),
    (true , .other     , false, true ,   .broadcast, false),
    (true , .other     , true , false,   .none     , false),
    (true , .other     , true , true ,   .none     , false),
]
check(table.count == 24, "the table covers every input (24 rows)")
var wrong = 0
for (b, r, p, o, ear, prompt) in table {
    let got = Ears.decide(.init(broadcast: b, route: r, paused: p, otherAudio: o))
    if got != .init(ear: ear, prompt: prompt) {
        wrong += 1
        print("  row broadcast=\(b) route=\(r) paused=\(p) other=\(o): got \(got)")
    }
}
check(wrong == 0, "decide matches every row of the truth table")
check(!table.contains { $0.2 && ($0.4 != .none || $0.5) }, "paused: never an ear, never a prompt")
// regression (S3b stand-in heard the room): speaker, another app playing, no broadcast → no ear, the prompt to start it
check(Ears.decide(.init(broadcast: false, route: .speaker, paused: false, otherAudio: true))
      == .init(ear: .none, prompt: true), "speaker + other audio, no broadcast: no ear, the prompt")

// where the sound goes, from AVAudioSession.Port raw values
check(Ears.route(["Speaker"]) == .speaker, "built-in speaker")
check(Ears.route(["Receiver"]) == .speaker, "earpiece counts as the device's own speaker")
check(Ears.route(["BluetoothA2DPOutput"]) == .headphones, "AirPods (A2DP)")
check(Ears.route(["Headphones"]) == .headphones, "wired headphones")
check(Ears.route(["BluetoothLE"]) == .headphones && Ears.route(["BluetoothHFP"]) == .headphones, "Bluetooth LE and HFP")
check(Ears.route(["AirPlay"]) == .other && Ears.route(["CarAudio"]) == .other, "AirPlay and car: elsewhere")
check(Ears.route([]) == .speaker, "no output listed: the device's own speaker")

// one prompt per stop
let heads = Ears.decide(.init(broadcast: false, route: .headphones, paused: false, otherAudio: true))
let cast = Ears.decide(.init(broadcast: true, route: .headphones, paused: false, otherAudio: true))
let paused = Ears.decide(.init(broadcast: false, route: .headphones, paused: true, otherAudio: true))
// regression 11-11 (gauntlet's review): a launch with no broadcast showed the prompt and also sent "stopped hearing",
// though nothing had been heard. The page prompts; only a stop where hearing ended sends the notification.
var fresh = Ears.Prompts()
fresh.update(before: .none, now: heads)
check(fresh.shows(heads), "a launch with no broadcast shows the prompt on the page")
check(!fresh.notify(heads), "a launch with no broadcast sends no notification")
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
check(!pr.notify(heads), "Resume with no broadcast sends no notification (the owner is in Recense)")

let data = try! JSONEncoder().encode(pr)
check((try? JSONDecoder().decode(Ears.Prompts.self, from: data)) == pr, "the prompt state survives a relaunch (Codable)")
let before = #"{"stop":2,"dismissed":1,"notified":2}"#.data(using: .utf8)!
check((try? JSONDecoder().decode(Ears.Prompts.self, from: before))?.ended == nil, "a state saved before 11-11 still loads")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
