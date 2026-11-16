// Derived from Spec: BUG-09 · what the Lock Screen and Control Center show for Recense's own player.
import Foundation
import MediaPlayer

enum NowPlayingInfo {
    static let skipBack: Double = 15     // the in-app buttons' steps, so both places do the same
    static let skipForward: Double = 30

    /// FEAT-19 Gap B: whether the audio session is ours alone (.playback, no mixing). Only a non-mixing session is made
    /// the Now Playing app, so while Recense plays its own file the Lock Screen shows our title and scrubber; it mixes
    /// only while Listen hears another app's sound (never stop it) or when nothing of ours is loaded.
    static func ownsSession(holdsFile: Bool, hearingOutside: Bool) -> Bool { holdsFile && !hearingOutside }

    /// "library/Music/Player check.m4a" → ("Player check", "Music"); "downloads/x.mp4" → ("x", "Inbox"): the folder keeps its name (FEAT-06), the label says Inbox (owner 2026-11-15).
    static func names(for path: String) -> (title: String, album: String) {
        let ns = path as NSString
        let title = (ns.lastPathComponent as NSString).deletingPathExtension
        let folder = (ns.deletingLastPathComponent as NSString).lastPathComponent
        let album = folder.isEmpty ? "Recense" : folder == "downloads" ? "Inbox" : folder.prefix(1).uppercased() + folder.dropFirst()
        return (title.isEmpty ? "Recense" : title, album)
    }

    /// The dictionary for MPNowPlayingInfoCenter. No duration until it is known (no empty 0:00 bar).
    static func info(path: String, time: Double, duration: Double?, playing: Bool) -> [String: Any] {
        let n = names(for: path)
        var d: [String: Any] = [
            MPMediaItemPropertyTitle: n.title,
            MPMediaItemPropertyAlbumTitle: n.album,
            MPMediaItemPropertyArtist: "Recense",
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        let t = time.isFinite ? max(0, time) : 0
        if let du = duration, du.isFinite, du > 0 {
            d[MPMediaItemPropertyPlaybackDuration] = du
            d[MPNowPlayingInfoPropertyElapsedPlaybackTime] = min(t, du)
        } else {
            d[MPNowPlayingInfoPropertyElapsedPlaybackTime] = t
        }
        return d
    }
}
