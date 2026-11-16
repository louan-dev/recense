// Derived from Spec: FEAT-19 (P2) · a video's sound plays on when the app leaves or the screen locks.
// iOS pauses an AVPlayer that is still attached to an AVPlayerLayer once the app is in the background (Apple,
// "Playing audio from a video asset in the background"). So the video view lets go of the player there and takes it
// back when the app is seen again; the picture resumes where the sound is. Pure: no UIKit, tested on the Mac.
import Foundation

enum BackgroundVideo {
    enum Phase: Equatable { case active, inactive, background }
    enum Event { case didEnterBackground, willEnterForeground }

    /// Whether the video layer holds the player in this phase. Inactive (Control Center, a banner) is still seen.
    static func attached(_ phase: Phase) -> Bool { phase != .background }

    static func phase(after event: Event) -> Phase {
        switch event {
        case .didEnterBackground: return .background
        case .willEnterForeground: return .inactive
        }
    }
}
