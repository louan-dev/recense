// New: what just landed in Recense/inbox/ as wide featured cards (Podcasts' "NEW SEASON" row), then a rail of shows
// for each space (Podcasts' "Top Shows ›"). Matters' rail shows only while the gate is open.
import SwiftUI

struct NewView: View {
    let model: ShowsModel
    @StateObject private var page = Featured()

    final class Featured: ObservableObject { @Published var entries: [FeedEntry] = [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if page.entries.isEmpty {
                    Text("Nothing new. Send something to Recense and it lands here.")
                        .font(.title3).foregroundStyle(.secondary).padding(.horizontal, Theme.gutter).padding(.top, 20)
                } else {
                    Rail(items: page.entries, fraction: 0.88, maxWidth: 560) { FeaturedCard(model: model, entry: $0) }
                }
                ForEach(model.spaces.filter { !model.isLocked($0) }) { s in
                    let shows = (model.shows[s.id] ?? []).filter { $0.id != Show.newID && !model.isLocked($0) }
                    if !shows.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(s.title) { ShowsGrid(model: model, shows: shows, title: s.title) }
                            Rail(items: shows, fraction: 0.44, maxWidth: 220) { show in
                                NavigationLink { ShowPage(model: model, show: show) } label: {
                                    ShowTile(show: show, detail: ShowTile.count(show), locked: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .recenseScreen("New")
        .task(id: "\(model.revision)#\(model.gate.isOpen)") {
            page.entries = await model.entries(.latest).filter { $0.episode.show == Show.newID }
        }
    }
}

struct FeaturedCard: View {
    let model: ShowsModel
    let entry: FeedEntry

    var body: some View {
        Button { model.play(entry.episode) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Text(entry.episode.title).font(.title2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Artwork(title: entry.episode.title, seed: entry.episode.title, corner: Theme.artCorner, ratio: 16 / 10)
                    .padding(.top, 6)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { EpisodeActions(model: model, episode: entry.episode) }
    }

    private var eyebrow: String {
        let kind = entry.episode.item.kind == .video ? "VIDEO" : entry.episode.item.kind == .audio ? "AUDIO" : "NEW"
        return "\(kind) · \(Fmt.ago(entry.episode.item.added).uppercased())"
    }
}
