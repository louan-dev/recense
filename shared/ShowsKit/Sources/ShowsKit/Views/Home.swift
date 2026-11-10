// Home: Up Next (big cards that snap one by one) and Recently Played (rows that snap), like Podcasts' Home.
import SwiftUI

/// Something the app played that the catalog doesn't hold (Recense's Listen episodes), for Recently Played. Owner
/// 11-10: newer media bumps what played before down to Recently Played; merged with the catalog's by when each played.
public struct RecentItem: Identifiable {
    public let id: String
    public let at: Int64          // ms since 1970, as HLC.wall
    public let row: AnyView
    public init(id: String, at: Int64, row: AnyView) { self.id = id; self.at = at; self.row = row }
}

/// The app's RecentItems, kept current by the app (ShowsRoot's `extras`).
@MainActor @Observable
public final class HomeExtras {
    public var recent: [RecentItem] = []
    public init() {}
}

/// One Recently Played row: the catalog's or the app's.
enum Recent: Identifiable {
    case entry(FeedEntry), extra(RecentItem)
    var id: String { switch self { case .entry(let e): "e:" + e.id; case .extra(let x): "x:" + x.id } }
    var at: Int64 { switch self { case .entry(let e): e.position?.at.wall ?? 0; case .extra(let x): x.at } }
    /// Newest first, the catalog's and the app's together.
    static func merged(_ es: [FeedEntry], _ xs: [RecentItem], limit: Int = 12) -> [Recent] {
        Array((es.map(Recent.entry) + xs.map(Recent.extra)).sorted { ($0.at, $0.id) > ($1.at, $1.id) }.prefix(limit))
    }
}

struct HomeView: View {
    let model: ShowsModel
    var top: AnyView? = nil   // the app's own card, first (ShowsRoot's `home`)
    var extras: HomeExtras? = nil

    var body: some View {
        let recent = Recent.merged(model.recentlyPlayed, extras?.recent ?? [])
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if let top { top }
                if top == nil, model.upNext.isEmpty && recent.isEmpty {
                    Text("Nothing to play yet. What lands in New appears here.")
                        .font(.title3).foregroundStyle(.secondary).padding(.horizontal, Theme.gutter).padding(.top, 20)
                }
                if !model.upNext.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader("Up Next") { EntryList(model: model, feed: .upNext, title: "Up Next") }
                        Rail(items: model.upNext) { UpNextCard(model: model, entry: $0) }
                    }
                }
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader("Recently Played") { EntryList(model: model, feed: .recentlyPlayed, title: "Recently Played", extras: extras) }
                        Rail(items: recent, fraction: 0.88, maxWidth: 480) { r in
                            switch r {
                            case .entry(let e): EntryRow(model: model, entry: e)
                            case .extra(let x): x.row
                            }
                        }
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
    var extras: HomeExtras? = nil   // Recently Played only: the app's own rows, merged in
    @StateObject private var page = Rows()

    final class Rows: ObservableObject { @Published var entries: [FeedEntry] = [] }

    var body: some View {
        let rows = feed == .recentlyPlayed ? Recent.merged(page.entries, extras?.recent ?? [], limit: .max) : page.entries.map(Recent.entry)
        List {
            if rows.isEmpty { Text("Nothing here yet.").foregroundStyle(.secondary) }
            ForEach(rows) { r in
                switch r {
                case .entry(let e):
                    EntryRow(model: model, entry: e, art: 72)
                        .swipeActions(edge: .trailing) { swipeSave(e.episode) }
                        .swipeActions(edge: .leading) { swipePlayed(e.episode) }
                        .listRowSeparator(.visible)
                case .extra(let x):
                    x.row.listRowSeparator(.visible)
                }
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
