// Derived from Spec: FEAT-07 (P2: the pill)
// One pill under the transcript. Its scrub face is our scrubber (hit marks on the track, detents under the finger);
// its find face searches the whole transcript (words and translation, accents ignored) as the lines arrive.
// Tap the magnifier → Find (the scrubber keeps its own touch for seeking: FEAT-07 rule 7); hold the find face
// 0.35 s, or tap its waveform, → back to scrubbing. Every move has a visible button; the ··· menu has Find too.
// Going to a hit plays from it (the view keeps following the voice); with no player (Listen), it scrolls there.
import SwiftUI

struct SearchPill<Scrub: View>: View {
    let lines: [TranscriptLine]
    @ObservedObject var state: TranscriptState
    let hits: [Int]
    let seek: ((Double) -> Void)?
    @ViewBuilder var scrubber: Scrub
    @FocusState private var typing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if state.finding { find } else { scrub }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: state.finding)
        .onChange(of: hits) { _, h in if let c = state.hit, !h.contains(c) { state.hit = nil } }
    }

    private var scrub: some View {
        HStack(spacing: 10) {
            Button { state.finding = true; typing = true } label: {
                Image(systemName: "magnifyingglass").font(.headline).frame(width: 36, height: 36)
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .disabled(lines.isEmpty)
            .accessibilityLabel("Find in Transcript")
            scrubber
        }
        .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var find: some View {
        HStack(spacing: 8) {
            Button { close() } label: { Image(systemName: "waveform").font(.headline).frame(width: 36, height: 36) }
                .buttonStyle(.plain).accessibilityLabel("Back to Scrubbing")
            TextField("Find in transcript", text: $state.query)
                .textFieldStyle(.plain).focused($typing).submitLabel(.search)
                .onSubmit { go(back: false) }
                .autocorrectionDisabled()
            if !state.query.isEmpty {
                Text(count).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                Button { go(back: true) } label: { Image(systemName: "chevron.up").frame(width: 32, height: 32) }
                    .buttonStyle(.plain).disabled(hits.isEmpty).accessibilityLabel("Previous Match")
                Button { go(back: false) } label: { Image(systemName: "chevron.down").frame(width: 32, height: 32) }
                    .buttonStyle(.plain).disabled(hits.isEmpty).accessibilityLabel("Next Match")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .onLongPressGesture(minimumDuration: 0.35) { close() }
    }

    private var count: String {
        if hits.isEmpty { return state.query.count < 2 ? "" : "No matches" }
        let i = state.hit.flatMap { hits.firstIndex(of: $0) }.map { $0 + 1 }
        return i.map { "\($0) of \(hits.count)" } ?? "\(hits.count) found"
    }

    private func go(back: Bool) {
        guard let h = TranscriptFind.step(hits, from: state.hit, back: back) else { return }
        state.hit = h
        if let seek { state.following = true; seek(lines[h].start) }   // plays from the hit; the view follows the voice
        else { state.following = false; state.jump = lines[h].id }      // live captions: scroll there
    }

    private func close() { state.finding = false; state.hit = nil; typing = false }
}
