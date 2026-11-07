// The Library grid: one card per show (New first, empty shows already hidden by the store).
import SwiftUI

struct LibraryGrid: View {
    let model: ShowsModel
    let space: Space

    var body: some View {
        let shows = model.shows[space.id] ?? []
        ScrollView {
            if shows.isEmpty {
                Text("Nothing here yet.").font(.title3).foregroundStyle(.secondary).padding(.top, 60)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)], spacing: 16) {
                ForEach(shows) { s in
                    NavigationLink(value: s) { ShowCard(show: s, locked: model.isLocked(s)) }
                        .buttonStyle(.plain)
                }
            }
            .padding(16)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }
}

struct ShowCard: View {
    let show: Show
    let locked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.quaternary)
                Image(systemName: locked ? "lock" : show.id == Show.newID ? "tray" : "square.stack")
                    .font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
            }
            .aspectRatio(1, contentMode: .fit)
            Text(show.title).font(.headline).lineLimit(2)
            Text(count).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(show.title), \(count)\(locked ? ", locked" : "")")
    }

    private var count: String { show.episodeCount == 1 ? "1 episode" : "\(show.episodeCount) episodes" }
}
