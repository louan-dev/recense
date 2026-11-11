// When the floating window shows (owner 11-10: "autoshows on play outside app and autohides on pause"; no Dock).
// Pure rules, no UIKit, so Tests/floating checks every case: swiftc Floating.swift Tests/floating/main.swift.
import Foundation

enum Floating {
    /// Can iOS reopen the window from behind (Recense not in front) when the sound plays again? Apple documents
    /// starting Picture in Picture only from the front, so it's measured on the device and kept: unknown until the
    /// first try, then works or refused.
    enum Reshow: String { case unknown, works, refused }

    enum Act: Equatable { case none, show, hide }

    struct Now {
        var front: Bool          // Recense is the app in front
        var playing: Bool        // another app's sound plays (isOtherAudioPlaying)
        var paused: Bool         // Listen's one Pause
        var open: Bool           // the window is showing
        var quiet: Double        // seconds since the other app's sound stopped (0 while it plays)
        var reshow: Reshow
        var tried: Bool          // already tried to reopen during this stretch of sound
        var hid: Bool            // Recense hid it on a pause behind (only that one is reopened: as Recense is left,
                                 // iOS opens it by itself, and a second start then failed and read as "refused", 11-10)
    }

    /// Seconds of silence before the window hides: a gap between two tracks or a buffering stall isn't a pause.
    static let hideAfter = 3.0
    /// How long Recense stays awake behind after hiding it, to bring it back when the sound plays again.
    static let stayAwake = 600.0

    /// Whether iOS should open the window as Recense is left: only while something plays.
    static func autoOpen(playing: Bool, paused: Bool) -> Bool { playing && !paused }

    /// Give the window its content back: a hide detaches it, and iOS can't open a window with none as Recense is left
    /// (iPhone log 11-10 17:44–17:47: hidden in front, then "behind playing closed" on every leave).
    static func reattach(open: Bool, attached: Bool, closing: Bool) -> Bool { !open && !attached && !closing }

    /// How far ahead the window's pictures are drawn and stamped (longer than the 1 s tick that draws them).
    static let ahead = 1.5

    /// When the lit line changes in the next `ahead` seconds after `now`, in the light's time: each word's start,
    /// once each, in order. Each gets its own picture, stamped for that moment, so the window shows it on the refresh the
    /// word starts on instead of at the next 10-a-second redraw (owner 11-10: "time each word light to the moment the
    /// screen actually shows it").
    static func onsets(_ starts: [Double], after now: Double, ahead: Double = ahead) -> [Double] {
        Array(Set(starts.filter { $0 > now && $0 <= now + ahead })).sorted()
    }

    static func decide(_ n: Now) -> Act {
        if n.paused || n.front { return n.open ? .hide : .none }   // in Recense, Home shows the transcript instead
        if n.playing { return !n.open && n.hid && !n.tried && n.reshow != .refused ? .show : .none }
        // the sound paused behind: hide, unless iOS can't bring it back on play, so captions are never lost
        if n.open, n.quiet >= hideAfter, n.reshow != .refused { return .hide }
        return .none
    }
}
