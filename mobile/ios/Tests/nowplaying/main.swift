// Regression guard: BUG-09 · the Lock Screen's Now Playing dictionary.
// swiftc -O mobile/HostApp/iOS/NowPlayingInfo.swift mobile/ios/Tests/nowplaying/main.swift -o "$TMPDIR/nowplaying" && "$TMPDIR/nowplaying"
import Foundation
import MediaPlayer

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { failed += 1; print("FAIL L\(line): \(what)") } }

let n = NowPlayingInfo.names(for: "library/Music/Player check.m4a")
check(n.title == "Player check" && n.album == "Music", "names: \(n)")
check(NowPlayingInfo.names(for: "downloads/x.mp4") == ("x", "Downloads"), "downloads album")

let a = NowPlayingInfo.info(path: "library/Music/a.m4a", time: 7, duration: 13, playing: false)
check(a[MPMediaItemPropertyPlaybackDuration] as? Double == 13, "duration carried")
check(a[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 7, "elapsed carried")
check(a[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0, "paused → rate 0")
check(a[MPMediaItemPropertyTitle] as? String == "a", "title")

let b = NowPlayingInfo.info(path: "library/Music/a.m4a", time: 99, duration: 13, playing: true)
check(b[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1, "playing → rate 1")
check(b[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 13, "elapsed clamped to duration")

let c = NowPlayingInfo.info(path: "x.m4a", time: -.infinity, duration: nil, playing: true)
check(c[MPMediaItemPropertyPlaybackDuration] == nil, "unknown duration → no bar")
check(c[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 0, "non-finite time → 0")
check(NowPlayingInfo.skipBack == 15 && NowPlayingInfo.skipForward == 30, "skip steps match the in-app buttons")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
