// The mini-player and Now Playing. The mini-player shows what plays, else the last thing played (as Podcasts does);
// its play button drives our player once B3 gives a transport, and opens Now Playing until then. Now Playing hosts our
// player (passed in by the app) and, under it, Clicked / Not yet: one record per episode, the retelling loop's
// measurement. Tapping the chosen one again clears it.
import SwiftUI

struct MiniPlayer: View {
    let model: ShowsModel

    private var shown: (episode: Episode, show: String)? {
        if let e = model.playing { return (e, model.playingShow ?? model.showTitle(e.show) ?? "") }
        if let r = model.recentlyPlayed.first { return (r.episode, r.showTitle) }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            if let s = shown {
                Button {
                    if model.playing == nil { model.play(s.episode) } else { model.nowPlayingOpen = true }
                } label: {
                    HStack(spacing: 12) {
                        Artwork(title: s.show, corner: 6, named: false).frame(width: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.episode.title).font(.headline).lineLimit(1)
                            Text(Fmt.day(max(s.episode.item.added, s.episode.item.mtime))).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(s.episode.title). Open Now Playing")
                Button {
                    if model.playing == nil { model.play(s.episode) } else { model.togglePlay() }
                } label: {
                    Image(systemName: model.transport?.isPlaying == true ? "pause.fill" : "play.fill").font(.title2)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.transport?.isPlaying == true ? "Pause" : "Play")
                if let t = model.transport {
                    Button { t.skip(30) } label: { Image(systemName: "goforward.30").font(.title2).frame(width: 44, height: 44) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Forward 30 seconds")
                }
            } else {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                Text("Nothing playing").font(.headline).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }
}

struct NowPlaying<Player: View>: View {
    let model: ShowsModel
    let player: (Episode) -> Player

    var body: some View {
        NavigationStack {
            if let e = model.playing {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        Artwork(title: model.playingShow ?? e.title, corner: 10).frame(width: 72)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(.title3.weight(.semibold)).lineLimit(2)
                            if let s = model.playingShow { Text(s).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, Theme.gutter).padding(.vertical, 12)
                    .frame(maxWidth: Theme.readable)
                    player(e).frame(maxWidth: .infinity, maxHeight: .infinity)
                    VerdictBar(chosen: e.state?.verdictValue) { v in Task { await model.setVerdict(v, for: e) } }
                }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { model.nowPlayingOpen = false } }
                    ToolbarItem(placement: .primaryAction) { EpisodeMenu(model: model, episode: e) }
                }
            }
        }
        .tint(Theme.accent)
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
        .frame(maxWidth: Theme.readable)
    }

    private func button(_ v: Verdict, _ title: String, _ symbol: String) -> some View {
        Button { choose(chosen == v ? nil : v) } label: {
            Label(title, systemImage: chosen == v && v == .clicked ? symbol + ".fill" : symbol)
                .font(.title3).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(chosen == v ? Theme.accent : .secondary)
        .accessibilityAddTraits(chosen == v ? .isSelected : [])
    }
}
