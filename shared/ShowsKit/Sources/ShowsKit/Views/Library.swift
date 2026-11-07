// Library, laid out like Podcasts' Library: a list of rows (Shows, the spaces, Saved, Downloaded, Latest Episodes,
// then the app's own places), then "Recently Updated" as a two-column grid of shows. The ··· menu holds the rest.
import SwiftUI

struct LibraryView: View {
    let model: ShowsModel
    let places: [Place]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                row("Shows", "square.stack") { ShowsGrid(model: model, shows: model.allShows, title: "Shows") }
                ForEach(model.spaces.filter { $0.id != .library }) { s in
                    row(s.title, model.isLocked(s) ? "lock" : s.symbol) { SpaceScreen(model: model, space: s) }
                }
                row("Saved", "bookmark") { EntryList(model: model, feed: .saved, title: "Saved") }
                row("Downloaded", "arrow.down.circle") { EntryList(model: model, feed: .downloaded, title: "Downloaded") }
                row("Latest Episodes", "clock") { EntryList(model: model, feed: .latest, title: "Latest Episodes") }
                ForEach(places) { p in row(p.title, p.symbol) { p.screen() } }

                if !model.recentlyUpdated.isEmpty {
                    Text("Recently Updated").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, Theme.gutter).padding(.top, 34).padding(.bottom, 14)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)], spacing: 22) {
                        ForEach(model.recentlyUpdated) { u in
                            NavigationLink { ShowPage(model: model, show: u.show) } label: {
                                ShowTile(show: u.show, detail: "Updated \(Fmt.ago(u.updated))", locked: model.isLocked(u.show))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                }
            }
            .frame(maxWidth: Theme.readable + 2 * Theme.gutter)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 20)
        }
        .recenseScreen("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { Task { await model.reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    if model.gate.isOpen {
                        Button { model.lock() } label: { Label("Lock Matters", systemImage: "lock") }
                    } else {
                        Button { Task { await model.unlock("Matters") } } label: { Label("Unlock Matters", systemImage: "faceid") }
                    }
                } label: { Image(systemName: "ellipsis").font(.title3.bold()) }
                .accessibilityLabel("More")
            }
        }
    }

    private func row<D: View>(_ title: String, _ symbol: String, @ViewBuilder _ destination: @escaping () -> D) -> some View {
        VStack(spacing: 0) {
            NavigationLink { destination() } label: {
                HStack {
                    LibraryRow(title, symbol: symbol)
                    Image(systemName: "chevron.right").font(.headline).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Theme.gutter).padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, Theme.gutter + 50)
        }
    }
}

/// A space's shows, or its gate while it is locked.
struct SpaceScreen: View {
    let model: ShowsModel
    let space: Space

    var body: some View {
        if model.isLocked(space) {
            LockedView(model: model, title: space.title).recenseScreen(space.title)
        } else {
            ShowsGrid(model: model, shows: model.shows[space.id] ?? [], title: space.title)
        }
    }
}

struct ShowsGrid: View {
    let model: ShowsModel
    let shows: [Show]
    let title: String

    var body: some View {
        ScrollView {
            if shows.isEmpty {
                Text("No shows here yet.").font(.title3).foregroundStyle(.secondary).padding(.top, 40)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)], spacing: 22) {
                ForEach(shows) { s in
                    NavigationLink { ShowPage(model: model, show: s) } label: {
                        ShowTile(show: s, detail: ShowTile.count(s), locked: model.isLocked(s))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.gutter)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .recenseScreen(title)
    }
}
