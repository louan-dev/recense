// Which ear Listen hears with, decided again at every change (S3b): the broadcast (another app's sound itself, before
// the speaker or headphones), or none, with one "Tap once to keep hearing" per stop. The microphone is never an ear on
// iPhone or iPad (owner, 2026-11-10, "Yes, no mic"): it would hear the room, not the media; its code went 11-11.
// Pure logic, Foundation only, so mobile/ios/Tests/ears/main.swift runs it on the Mac. Run:
//   swiftc -O mobile/HostApp/iOS/ListenEars.swift mobile/ios/Tests/ears/main.swift -o "$TMPDIR/ears" && "$TMPDIR/ears"
import Foundation

enum Ears {
    enum Ear: String, Codable { case broadcast, none }

    /// Where the sound goes: the device's own speaker (or earpiece), headphones of any kind, or somewhere else
    /// (AirPlay, a car, a screen).
    enum Route: String, Codable { case speaker, headphones, other }

    /// AVAudioSession.Port raw values of the current route's outputs → where the sound goes.
    static func route(_ outputs: [String]) -> Route {
        let heads: Set<String> = ["Headphones", "BluetoothA2DPOutput", "BluetoothHFP", "BluetoothLE"]
        let speaker: Set<String> = ["Speaker", "Receiver"]
        if outputs.contains(where: heads.contains) { return .headphones }
        if !outputs.isEmpty, outputs.allSatisfy(speaker.contains) { return .speaker }
        return outputs.isEmpty ? .speaker : .other
    }

    struct Input: Equatable {
        var broadcast: Bool         // the broadcast extension is live
        var route: Route
        var paused: Bool            // the one Pause
        var otherAudio: Bool        // another app is playing sound
    }

    struct Choice: Equatable {
        var ear: Ear
        var prompt: Bool            // "Tap once to keep hearing" is due (shown once per stop, see Prompts)
    }

    static func decide(_ i: Input) -> Choice {
        if i.paused { return Choice(ear: .none, prompt: false) }
        if i.broadcast { return Choice(ear: .broadcast, prompt: false) }
        return Choice(ear: .none, prompt: true)
    }

    /// One prompt per stop. A stop is the moment hearing ends without the owner's Pause: the broadcast ended (iOS
    /// ended it, a restart), or headphones came on with no broadcast. Dismissed, it stays away until the next stop.
    struct Prompts: Codable, Equatable {
        var stop = 0                // which stop this is
        var dismissed: Int?         // the stop whose prompt was dismissed
        var notified: Int?          // the stop already sent as a notification
        var ended: Int?             // the last stop where hearing really ended: only that one is notified (11-11: a
                                    // launch or a Resume with no broadcast said "stopped hearing" though nothing had)

        /// Called with every new decision; `before` is the ear heard with until now.
        mutating func update(before: Ear, now: Choice) {
            if before != .none, now.ear == .none, now.prompt { stop += 1; ended = stop }
        }
        func shows(_ now: Choice) -> Bool { now.prompt && dismissed != stop }
        /// Whether to send the notification now: once per stop where hearing ended, only while the prompt shows.
        mutating func notify(_ now: Choice) -> Bool {
            guard shows(now), notified != stop, ended == stop else { return false }
            notified = stop
            return true
        }
        mutating func dismiss() { dismissed = stop }
        /// Resume after the owner's Pause: a fresh start, so a prompt dismissed before it can show again.
        mutating func resumed() { stop += 1 }
    }
}
