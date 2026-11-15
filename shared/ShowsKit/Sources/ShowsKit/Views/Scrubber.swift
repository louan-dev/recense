// Our scrubber, in the shared skin: the home bar's Time Seeking (library/src/client/homebar.js, beginSeek/applySeek/
// finishSeek) at the place iOS Podcasts puts its progress bar, under the transcript and over the play controls (13, 17,
// 40). Its behaviour is the home bar's:
//   - slide to move: the playhead moves with the finger from where it was (it never jumps to the finger);
//   - slide up while holding to go finer: ×4, ×16, ×64 (only while the window still spans 10 s or more);
//   - the media is asked to move at most every 90 ms and lands exactly where the finger let go;
//   - the time landed on shows for a moment (1.7 s).
// Added for the bar (owner, 11-08): a tap jumps to that place. Elapsed on the left, remaining on the right.
// VoiceOver: an adjustable value, 15 s a step. Reduce Motion: the bar doesn't grow while held.
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The rules, apart from the view, so they can be tested.
public enum ScrubMath {
    public static let zooms: [Double] = [1, 4, 16, 64]
    /// How far up (points) the finger goes for each finer level: under 1 unit ×1, 2.4 ×4, 4 ×16, beyond ×64.
    public static func level(up: Double, unit: Double, duration: Double) -> Int {
        let want = up < unit ? 0 : up < unit * 2.4 ? 1 : up < unit * 4 ? 2 : 3
        let most = zooms.indices.last { duration / zooms[$0] >= 10 } ?? 0
        return min(want, most)
    }
    /// The time under a drag: from `t0`, `dx` points along a bar `width` wide spanning `duration / zoom`.
    public static func time(t0: Double, dx: Double, width: Double, duration: Double, level: Int) -> Double {
        let span = duration / zooms[level]
        return min(duration, max(0, t0 + dx * span / max(1, width)))
    }
    /// A tap at `x` on a bar `width` wide.
    public static func jump(x: Double, width: Double, duration: Double) -> Double {
        min(duration, max(0, x / max(1, width) * duration))
    }
}

final class ScrubState: ObservableObject {
    @Published var held: Double?          // the drag's time, while dragging (the one playhead everything shows)
    @Published var landed: Double?        // the time landed on, shown for a moment
    var t0 = 0.0, x0 = 0.0, level = 0, lastSeek = Date.distantPast, pending: DispatchWorkItem?, hide: DispatchWorkItem?
    var moved = false
    var lastDetent = Date.distantPast
}

/// The detent on this device: the iPhone's Taptic Engine, the Mac's trackpad; at most one each 40 ms (rule 5).
/// Follows the system's haptics switch by itself (rule 6). A haptic never carries meaning alone (the marks show it).
enum Haptic {
    @MainActor static func play(_ d: TranscriptFind.Detent, state: ScrubState) {
        guard Date().timeIntervalSince(state.lastDetent) >= 0.04 else { return }
        state.lastDetent = Date()
        #if os(iOS)
        UIImpactFeedbackGenerator(style: d == .strong ? .heavy : d == .medium ? .medium : .light).impactOccurred()
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(d == .light ? .generic : d == .medium ? .alignment : .levelChange, performanceTime: .now)
        #endif
    }
}

struct Scrubber: View {
    let now: Double                        // the player's time when drawn (a value, so the bar redraws as it plays)
    let time: () -> Double?
    let duration: Double
    let seek: (Double) -> Void
    @ObservedObject var state: ScrubState
    /// FEAT-07: search hits as places on the track (rule 1), and the detent felt sliding across a place (rules 2, 5).
    var marks: [Double] = []
    var detent: ((Double, Double) -> TranscriptFind.Detent?)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(now: Double, time: @escaping () -> Double?, duration: Double, seek: @escaping (Double) -> Void, state: ScrubState,
         marks: [Double] = [], detent: ((Double, Double) -> TranscriptFind.Detent?)? = nil) {
        self.now = now; self.time = time; self.duration = duration; self.seek = seek; self.state = state
        self.marks = marks; self.detent = detent
    }

    public var body: some View {
        let t = state.held ?? now
        let f = duration > 0 ? min(1, max(0, t / duration)) : 0
        VStack(spacing: 6) {
            GeometryReader { g in
                let h: CGFloat = state.held != nil && !reduceMotion ? 10 : 5
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(0.85)).frame(width: max(h, g.size.width * f))
                    ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                        Capsule().fill(Theme.accent).frame(width: 3, height: h + 8)
                            .offset(x: duration > 0 ? g.size.width * min(1, max(0, m / duration)) - 1.5 : 0)
                    }
                }
                .frame(height: h)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(drag(width: g.size.width))
            }
            .frame(height: 24)
            HStack {
                Text(TranscriptLight.clock(t))
                Spacer()
                if let l = state.landed, state.held == nil { Text(TranscriptLight.clock(l)).foregroundStyle(.white) }
                else if state.held != nil && state.level > 0 { Text("×\(Int(ScrubMath.zooms[state.level])) finer") }
                Spacer()
                Text("−" + TranscriptLight.clock(max(0, duration - t)))
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.6))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(TranscriptLight.clock(t)) of \(TranscriptLight.clock(duration))")
        .accessibilityAdjustableAction { d in
            let now = time() ?? 0
            seek(min(duration, max(0, now + (d == .increment ? 15 : -15))))
        }
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                if state.held == nil {
                    state.t0 = time() ?? 0; state.x0 = v.startLocation.x; state.level = 0; state.moved = false
                    state.held = state.t0; state.landed = nil
                }
                if abs(v.translation.width) > 4 || abs(v.translation.height) > 4 { state.moved = true }
                guard state.moved else { return }
                let lvl = ScrubMath.level(up: max(0, -v.translation.height), unit: 44, duration: duration)
                if lvl != state.level { state.t0 = state.held ?? state.t0; state.x0 = v.location.x; state.level = lvl }  // rezoom where you are
                let t = ScrubMath.time(t0: state.t0, dx: v.location.x - state.x0, width: width, duration: duration, level: state.level)
                if let d = detent?(state.held ?? t, t) { Haptic.play(d, state: state) }
                state.held = t
                apply(t)
            }
            .onEnded { v in
                let t = state.moved ? (state.held ?? 0) : ScrubMath.jump(x: v.location.x, width: width, duration: duration)
                state.pending?.cancel()
                seek(t)                                  // land exactly where the finger let go
                state.held = nil; state.level = 0
                state.landed = t
                state.hide?.cancel()
                let h = DispatchWorkItem { [weak state] in state?.landed = nil }
                state.hide = h
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: h)
            }
    }

    /// The media moves at most every 90 ms, and always lands on the last value.
    private func apply(_ t: Double) {
        state.pending?.cancel()
        if Date().timeIntervalSince(state.lastSeek) > 0.09 { state.lastSeek = Date(); seek(t); return }
        let w = DispatchWorkItem { [weak state] in state?.lastSeek = Date(); seek(t) }
        state.pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: w)
    }
}
