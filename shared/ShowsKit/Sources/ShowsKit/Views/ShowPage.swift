// A show's page, like a Podcasts show page: its art and title, Play, its seasons, then its episodes. Each row slides
// (swipe): left → right deletes a file Recense keeps (FEAT-07 P0), right → left Save and Played; the same actions are in its ··· and context menus, so none depends on a gesture alone.
import SwiftUI

struct ShowPage: View {
    let model: ShowsModel
    let show: Show
    // @StateObject, not @State: the Mac builds with the Command Line Tools, which lack SwiftUI's macro plugin (README)
    @StateObject private var page = PageState()

    final class PageState: ObservableObject {
        @Published var season: String?          // nil = every season
        @Published var episodes: [Episode] = []
        @Published var all = false               // "See All" pressed: every episode, not the first ten
        @Published var adding = false            // FEAT-13: "+" opened the file picker
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
                    Text("Episodes").font(.title2.bold()).listRowSeparator(.hidden)
                    if page.episodes.isEmpty { Text("No episodes.").foregroundStyle(.secondary) }
                    ForEach(page.all ? page.episodes : Array(page.episodes.prefix(ShowFacts.firstRows))) { e in
                        EpisodeRow(model: model, episode: e)
                            // slide left → right deletes (owner 2026-11-15, FEAT-07 P0); Played and Save on the other side
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if model.canChange(e) {
                                    Button(role: .destructive) { model.delete(e) } label: { Label("Delete", systemImage: "trash") }
                                } else { playedButton(e) }
                            }
                            .swipeActions(edge: .trailing) { saveButton(e); if model.canChange(e) { playedButton(e) } }
                            .contextMenu { EpisodeActions(model: model, episode: e) }
                    }
                    if !page.all && page.episodes.count > ShowFacts.firstRows {
                        Button("See All (\(page.episodes.count))") { page.all = true }
                            .font(.title3).foregroundStyle(Theme.accent)
                    }
                }
                .listStyle(.plain)
                .frame(maxWidth: Theme.readable)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(show.title)
        .toolbar {
            if model.canAdd(to: show) {
                ToolbarItem(placement: .primaryAction) {
                    Button { page.adding = true } label: { Label("Add Files", systemImage: "plus") }
                }
            }
        }
        .fileImporter(isPresented: $page.adding, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.add(urls, to: show)
            case .failure(let e): model.problem = "Couldn't open the files: \(e.localizedDescription)"
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .tint(Theme.accent)
        .task(id: "\(page.season ?? "")#\(model.revision)#\(model.gate.isOpen)") {
            page.episodes = await model.episodes(of: show, season: page.season)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Artwork(title: show.title, corner: 16).frame(maxWidth: 240)
            Text(show.title).font(.title2.bold()).multilineTextAlignment(.center)
            if let src = ShowFacts.source(show) { Text(src).font(.title3).foregroundStyle(.secondary) }
            if let first = page.episodes.first {
                Button { model.play(first) } label: {
                    Label(show.serial ? "First Episode" : "Latest Episode", systemImage: "play.fill")
                        .font(.headline).padding(.horizontal, 22).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(.primary)
            }
            if let facts = ShowFacts.line(page.episodes) {
                Text(facts).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func saveButton(_ e: Episode) -> some View {
        let on = e.state?.isStarred ?? false
        return Button { Task { await model.setStarred(!on, for: e) } } label: {
            Label(on ? "Unsave" : "Save", systemImage: on ? "bookmark.slash" : "bookmark")
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

    // FEAT-13: a video's frame, a PDF's page, the image; none for audio. @StateObject: the Mac's tools lack @State's macro
    @StateObject private var art = Thumb()
    final class Thumb: ObservableObject { @Published var image: CGImage? }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let thumb = art.image {
                Image(decorative: thumb, scale: 1).resizable().scaledToFill()
                    .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            details
        }
        .task(id: episode.item.path) {
            art.image = await model.thumbnail(for: episode, side: 64)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Fmt.ago(max(episode.item.added, episode.item.mtime))).font(.subheadline).foregroundStyle(.secondary)
            Text(episode.title).font(.title3.weight(.semibold)).lineLimit(3)
            if let s = episode.summary { Text(s).font(.body).foregroundStyle(.secondary).lineLimit(2) }
            HStack(spacing: 10) {
                PlayCapsule(entry: FeedEntry(episode: episode, showTitle: "", position: nil),
                            playing: model.isPlaying(episode),
                            looping: model.loopOne && model.playing?.id == episode.id) { model.playOrPause(episode) }
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

