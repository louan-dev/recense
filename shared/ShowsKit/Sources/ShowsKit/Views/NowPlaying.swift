// The mini-player bar and Now Playing. Now Playing hosts our player (passed in by the app) and, under it,
// Clicked / Not yet: one record per episode, the retelling loop's measurement. Tapping the chosen one again clears it.
import SwiftUI

struct MiniPlayer: View {
    let model: ShowsModel

    var body: some View {
        if let e = model.playing {
            Button { model.nowPlayingOpen = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "waveform").font(.title3)
                    Text(e.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: 680)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now playing: \(e.title). Open")
        }
    }
}

struct NowPlaying<Player: View>: View {
    let model: ShowsModel
    let player: (Episode) -> Player

    var body: some View {
        NavigationStack {
            if let e = model.playing {
                VStack(spacing: 0) {
                    player(e).frame(maxWidth: .infinity, maxHeight: .infinity)
                    VerdictBar(chosen: e.state?.verdictValue) { v in Task { await model.setVerdict(v, for: e) } }
                }
                .navigationTitle(e.title)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.nowPlayingOpen = false } } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 600)
        #endif
    }
}

struct VerdictBar: View {
    let chosen: Verdict?
    let choose: (Verdict?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            button(.clicked, "Clicked", "lightbulb")
            button(.notYet, "Not yet", "arrow.triangle.2.circlepath")
        }
        .padding(16)
        .frame(maxWidth: 680)
    }

    private func button(_ v: Verdict, _ title: String, _ symbol: String) -> some View {
        Button { choose(chosen == v ? nil : v) } label: {
            Label(title, systemImage: chosen == v ? symbol + ".fill" : symbol)
                .font(.title3).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(chosen == v ? .accentColor : .secondary)
        .accessibilityAddTraits(chosen == v ? .isSelected : [])
    }
}
