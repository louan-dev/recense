// Home: Up Next (big cards that snap one by one) and Recently Played (rows that snap), like Podcasts' Home.
import SwiftUI

struct HomeView: View {
    let model: ShowsModel
    var top: AnyView? = nil   // the app's own card, first (ShowsRoot's `home`)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if let top { top }
                if top == nil, model.upNext.isEmpty && model.recentlyPlayed.isEmpty {
                    Text("Nothing to play yet. What lands in New appears here.")
                        .font(.title3).foregroundStyle(.secondary).padding(.horizontal, Theme.gutter).padding(.top, 20)
                }
                if !model.upNext.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader("Up Next") { EntryList(model: model, feed: .upNext, title: "Up Next") }
                        Rail(items: model.upNext) { UpNextCard(model: model, entry: $0) }
                    }
                }
                if !model.recentlyPlayed.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader("Recently Played") { EntryList(model: model, feed: .recentlyPlayed, title: "Recently Played") }
                        Rail(items: model.recentlyPlayed, fraction: 0.88, maxWidth: 480) { EntryRow(model: model, entry: $0) }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .recenseScreen("Home")
    }
}

/// A whole feed as a list (Up Next ›, Saved, Downloaded, Latest Episodes). Rows swipe for Save and Played; the same
/// actions are in each row's ··· and context menus.
struct EntryList: View {
    let model: ShowsModel
    let feed: Feed
    let title: String
    @StateObject private var page = Rows()

    final class Rows: ObservableObject { @Published var entries: [FeedEntry] = [] }

    var body: some View {
        List {
            if page.entries.isEmpty { Text("Nothing here yet.").foregroundStyle(.secondary) }
            ForEach(page.entries) { e in
                EntryRow(model: model, entry: e, art: 72)
                    .swipeActions(edge: .trailing) { swipeSave(e.episode) }
                    .swipeActions(edge: .leading) { swipePlayed(e.episode) }
                    .listRowSeparator(.visible)
            }
        }
        .listStyle(.plain)
        .frame(maxWidth: Theme.readable)
        .frame(maxWidth: .infinity)
        .recenseScreen(title)
        .task(id: "\(model.revision)#\(model.gate.isOpen)") { page.entries = await model.entries(feed) }
    }

    private func swipeSave(_ e: Episode) -> some View {
        let on = e.state?.isStarred ?? false
        return Button { Task { await model.setStarred(!on, for: e) } } label: {
            Label(on ? "Remove" : "Save", systemImage: on ? "bookmark.slash" : "bookmark")
        }.tint(Theme.accent)
    }

    private func swipePlayed(_ e: Episode) -> some View {
        let done = e.state?.finishedAt != nil
        return Button { Task { await model.setFinished(!done, for: e) } } label: {
            Label(done ? "Unplayed" : "Played", systemImage: done ? "circle" : "checkmark.circle")
        }.tint(.blue)
    }
}
