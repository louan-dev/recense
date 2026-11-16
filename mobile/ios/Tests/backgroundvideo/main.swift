// Derived from Spec: FEAT-19 (P2) · a video's sound plays on when the app leaves or the screen locks.
// swiftc -O mobile/HostApp/iOS/BackgroundVideo.swift mobile/ios/Tests/backgroundvideo/main.swift -o "$TMPDIR/bgvideo" && "$TMPDIR/bgvideo"
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { failed += 1; print("FAIL L\(line): \(what)") } }

// iOS pauses an AVPlayer still attached to a layer once the app is in the background: let go there, only there
check(BackgroundVideo.attached(.active), "on screen: the picture shows")
check(BackgroundVideo.attached(.inactive), "Control Center or a banner over the app: still seen, keep the picture")
check(!BackgroundVideo.attached(.background), "locked or left: the layer lets go, the sound plays on")

// the events that move it: entering the background lets go, coming back takes it again
check(BackgroundVideo.phase(after: .didEnterBackground) == .background, "background event")
check(BackgroundVideo.phase(after: .willEnterForeground) == .inactive, "foreground event: seen again")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
