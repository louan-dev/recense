// The show page: its seasons, then the episode list. Each row slides (swipe) for Star and Played, and the same
// actions are in its context menu, so none depends on a gesture alone.
import SwiftUI

struct ShowPage: View {
    let model: ShowsModel
    let show: Show
    // @StateObject, not @State: the Mac builds with the Command Line Tools, which lack SwiftUI's macro plugin (README)
    @StateObject private var page = PageState()

    final class PageState: ObservableObject {
        @Published var season: String?          // nil = every season
        @Published var episodes: [Episode] = []
    }

    var body: some View {
        Group {
            if model.isLocked(show) {
                LockedView(model: model, title: show.title)
            } else {
                List {
                    if !show.seasons.isEmpty {
                        Picker("Season", selection: $page.season) {
                            Text("All").tag(String?.none)
                            ForEach(show.seasons) { Text($0.title).tag(String?.some($0.id)) }
                        }
                        .font(.title3)
                    }
                    if page.episodes.isEmpty { Text("No episodes.").foregroundStyle(.secondary) }
                    ForEach(page.episodes) { e in
                        Button { model.play(e) } label: { EpisodeRow(episode: e) }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .leading) { playedButton(e) }
                            .swipeActions(edge: .trailing) { starButton(e) }
                            .contextMenu { starButton(e); playedButton(e) }
                    }
                }
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(show.title)
        .task(id: "\(page.season ?? "")#\(model.revision)#\(model.gate.isOpen)") {
            page.episodes = await model.episodes(of: show, season: page.season)
        }
    }

    private func starButton(_ e: Episode) -> some View {
        let on = e.state?.isStarred ?? false
        return Button { Task { await model.setStarred(!on, for: e) } } label: {
            Label(on ? "Unstar" : "Star", systemImage: on ? "star.slash" : "star")
        }
        .tint(.yellow)
    }

    private func playedButton(_ e: Episode) -> some View {
        let done = e.state?.finishedAt != nil
        return Button { Task { await model.setFinished(!done, for: e) } } label: {
            Label(done ? "Mark unplayed" : "Mark played", systemImage: done ? "circle" : "checkmark.circle")
        }
        .tint(.blue)
    }
}

struct EpisodeRow: View {
    let episode: Episode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(episode.title).font(.title3).lineLimit(3)
            HStack(spacing: 8) {
                if let d = episode.duration { Text(Duration.seconds(d).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) }
                if episode.transcript == .transcribing { Text("Transcribing…") }
                if episode.transcript == .ready { Image(systemName: "text.quote").accessibilityLabel("Transcript") }
                if episode.state?.isStarred == true { Image(systemName: "star.fill").accessibilityLabel("Starred") }
                if episode.state?.finishedAt != nil { Image(systemName: "checkmark.circle.fill").accessibilityLabel("Played") }
                if let v = episode.state?.verdictValue { Text(v == .clicked ? "Clicked" : "Not yet") }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
