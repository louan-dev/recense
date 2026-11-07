// A show's page, like a Podcasts show page: its art and title, Play, its seasons, then its episodes. Each row slides
// (swipe) for Save and Played; the same actions are in its ··· and context menus, so none depends on a gesture alone.
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
                    header.listRowSeparator(.hidden)
                    if !show.seasons.isEmpty {
                        Picker("Season", selection: $page.season) {
                            Text("All seasons").tag(String?.none)
                            ForEach(show.seasons) { Text($0.title).tag(String?.some($0.id)) }
                        }
                        .pickerStyle(.menu)
                        .font(.title3)
                    }
                    if page.episodes.isEmpty { Text("No episodes.").foregroundStyle(.secondary) }
                    ForEach(page.episodes) { e in
                        EpisodeRow(model: model, episode: e)
                            .swipeActions(edge: .leading) { playedButton(e) }
                            .swipeActions(edge: .trailing) { saveButton(e) }
                            .contextMenu { EpisodeActions(model: model, episode: e) }
                    }
                }
                .listStyle(.plain)
                .frame(maxWidth: Theme.readable)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(show.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .tint(Theme.accent)
        .task(id: "\(page.season ?? "")#\(model.revision)#\(model.gate.isOpen)") {
            page.episodes = await model.episodes(of: show, season: page.season)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Artwork(title: show.title, corner: 16).frame(maxWidth: 240)
            Text(show.title).font(.title.bold()).multilineTextAlignment(.center)
            Text(ShowTile.count(show)).font(.subheadline).foregroundStyle(.secondary)
            if let first = page.episodes.first {
                Button { model.play(first) } label: {
                    Label(show.serial ? "Play from the start" : "Play latest", systemImage: "play.fill")
                        .font(.headline).padding(.horizontal, 18).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func saveButton(_ e: Episode) -> some View {
        let on = e.state?.isStarred ?? false
        return Button { Task { await model.setStarred(!on, for: e) } } label: {
            Label(on ? "Remove" : "Save", systemImage: on ? "bookmark.slash" : "bookmark")
        }
        .tint(Theme.accent)
    }

    private func playedButton(_ e: Episode) -> some View {
        let done = e.state?.finishedAt != nil
        return Button { Task { await model.setFinished(!done, for: e) } } label: {
            Label(done ? "Unplayed" : "Played", systemImage: done ? "circle" : "checkmark.circle")
        }
        .tint(.blue)
    }
}

struct EpisodeRow: View {
    let model: ShowsModel
    let episode: Episode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Fmt.ago(max(episode.item.added, episode.item.mtime))).font(.subheadline).foregroundStyle(.secondary)
            Text(episode.title).font(.title3.weight(.semibold)).lineLimit(3)
            if let s = episode.summary { Text(s).font(.body).foregroundStyle(.secondary).lineLimit(2) }
            HStack(spacing: 10) {
                PlayCapsule(entry: FeedEntry(episode: episode, showTitle: "", position: nil)) { model.play(episode) }
                if episode.transcript == .transcribing { Text("Transcribing…").font(.subheadline).foregroundStyle(.secondary) }
                if episode.transcript == .ready { Image(systemName: "text.quote").foregroundStyle(.secondary).accessibilityLabel("Transcript") }
                if episode.state?.isStarred == true { Image(systemName: "bookmark.fill").foregroundStyle(Theme.accent).accessibilityLabel("Saved") }
                if episode.state?.finishedAt != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Played") }
                if let v = episode.state?.verdictValue { Text(v == .clicked ? "Clicked" : "Not yet").font(.subheadline).foregroundStyle(.secondary) }
                Spacer()
                EpisodeMenu(model: model, episode: episode)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
