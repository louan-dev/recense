// When the floating window shows: opens as Recense is left, rests as a thin strip while quiet, full on play (T-0002,
// 11-12; iOS opens it only at the leave, so the 11-10 "autoshows on play outside app" waits for the sound at rest). No Dock.
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
        var hid: Bool            // Recense hid it on a pause behind
        var left: Double = 9     // seconds since Recense was left: as it's left iOS opens the window by itself, and a
                                 // second start in that moment failed and read as "refused" (11-10), so wait `settle`
        var canStart = false     // iPad windows: Recense is still active but another app has the focus, so iOS lets
                                 // it open and close the window itself (iPad log 11-10 19:29: "front playing" for 2 min
                                 // under a full-screen Firefox, and the window never came)
    }

    /// Recense is in front: active, and on iPad also holding the focus (its window is key). An iPad app another app's
    /// window covers stays active (iPadOS windows), so `active` alone said "in front" under Firefox (11-10).
    static func front(active: Bool, pad: Bool, key: Bool) -> Bool { active && (!pad || key) }

    /// Seconds of silence before the window hides (owner's bar: hidden within 0.5 s of pause; decided 10 times a
    /// second, so it's gone 0.3–0.45 s after). A gap between two tracks may blink it; it's back on the next sound.
    static let hideAfter = 0.3
    /// How long Recense stays awake behind other apps with nothing playing, to show the window when one plays.
    static let stayAwake = 600.0
    /// How long after Recense is left before it opens the window itself (iOS's own opening comes first).
    static let settle = 1.0

    /// Whether Recense keeps its silent sound going: in front iOS keeps it running anyway; behind, while the window is
    /// open, while it hears, or until `stayAwake` of quiet, so it sees the next play (11-10 iPhone log: asleep behind,
    /// `awake=false` on every line, so no play or pause behind was ever seen).
    static func awake(front: Bool, open: Bool, hearing: Bool, quiet: Double) -> Bool {
        front || open || hearing || quiet < stayAwake
    }

    /// Whether iOS should open the window as Recense is left: every time, unless Listen is paused. iOS opens it only
    /// at that moment, and YouTube or a podcast usually starts after it (T-0002, owner 11-12: "does not float outside
    /// app"), so it opens at rest and wakes on the first sound.
    static func autoOpen(paused: Bool) -> Bool { !paused }

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

    /// iOS won't open the window from behind (iPhone 11-10 19:19:42: AVKitErrorDomain -1001 with Recense awake and the
    /// window possible), so once it's up behind it stays up, and a pause there rests it instead of closing it: a thin
    /// dark strip, back to full captions on the next sound.
    /// `reopens`: iOS was seen reopening it from behind (Reshow.works); until then it rests instead of closing.
    static func rest(front: Bool, open: Bool, reopens: Bool, quiet: Double, paused: Bool, canStart: Bool = false) -> Bool {
        !front && open && !reopens && !canStart && !paused && quiet >= hideAfter && quiet < stayAwake
    }

    static func decide(_ n: Now) -> Act {
        if n.paused || n.front { return n.open ? .hide : .none }   // in Recense, Home shows the transcript instead
        let reopens = n.canStart || n.reshow != .refused   // "refused" was measured behind; an active iPad app may start it
        // closing behind is safe only where it was seen to reopen; otherwise it rests, until a long quiet (battery)
        let closes = n.canStart || n.reshow == .works
        if n.playing { return !n.open && !n.tried && reopens && (n.hid || n.left >= settle) ? .show : .none }
        // the sound paused behind: hide, unless iOS can't bring it back on play, so captions are never lost
        if n.open, n.quiet >= hideAfter, closes || n.quiet >= stayAwake { return .hide }
        return .none
    }
}
