// The pieces Home, New and Library are made of: Up Next's big cards, Recently Played's rows, show tiles, the play
// capsule and each episode's ··· menu (every action there too, so none depends on a swipe).
import SwiftUI

/// "▶ 43m", or "▶ ━━ 2m" with the part already heard.
struct PlayCapsule: View {
    let entry: FeedEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                if let p = entry.progress {
                    ProgressView(value: p).frame(width: 44).tint(Theme.accent)
                }
                if let r = entry.remaining { Text(entry.progress == nil ? Fmt.length(r) : Fmt.length(r) + " left") }
                else { Text("Play") }
            }
            .font(.headline)
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("Play \(entry.episode.title)")
    }
}

struct EpisodeMenu: View {
    let model: ShowsModel
    let episode: Episode

    var body: some View {
        Menu {
            EpisodeActions(model: model, episode: episode)
        } label: {
            Image(systemName: "ellipsis").font(.title3.bold()).frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }
}

/// Play, Star, Played: the same list in the ··· menu, the context menu and the swipe actions.
struct EpisodeActions: View {
    let model: ShowsModel
    let episode: Episode

    var body: some View {
        let starred = episode.state?.isStarred ?? false
        let played = episode.state?.finishedAt != nil
        Button { model.play(episode) } label: { Label("Play", systemImage: "play") }
        Button { Task { await model.setStarred(!starred, for: episode) } } label: {
            Label(starred ? "Remove from Saved" : "Save", systemImage: starred ? "bookmark.slash" : "bookmark")
        }
        Button { Task { await model.setFinished(!played, for: episode) } } label: {
            Label(played ? "Mark as Unplayed" : "Mark as Played", systemImage: played ? "circle" : "checkmark.circle")
        }
    }
}

/// Up Next: the show's art on its own colour, what it is, the title, and the play capsule.
struct UpNextCard: View {
    let model: ShowsModel
    let entry: FeedEntry

    var body: some View {
        let (_, deep) = Theme.hues(entry.showTitle)
        VStack(alignment: .leading, spacing: 10) {
            Artwork(title: entry.showTitle).frame(maxWidth: 210).frame(maxWidth: .infinity).padding(.bottom, 8)
            Text(caption).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Text(entry.episode.title).font(.title3.weight(.semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                PlayCapsule(entry: entry) { model.play(entry.episode) }
                Spacer()
                if !entry.episode.item.local {
                    Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundStyle(.secondary).accessibilityLabel("Not on this device yet")
                }
                EpisodeMenu(model: model, episode: entry.episode)
            }
        }
        .padding(20)
        .frame(height: 470)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous).fill(deep.opacity(0.28)))
        )
        .contextMenu { EpisodeActions(model: model, episode: entry.episode) }
    }

    private var caption: String {
        if let p = entry.position { return "\(entry.showTitle) · \(Fmt.ago(p.at.wall / 1000))" }
        return "New · \(Fmt.ago(entry.episode.item.added))"
    }
}

/// Recently Played and the episode lists: art at the left, when, the title, the play capsule.
struct EntryRow: View {
    let model: ShowsModel
    let entry: FeedEntry
    var art: CGFloat = 110

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Artwork(title: entry.showTitle, corner: 8).frame(width: art)
            VStack(alignment: .leading, spacing: 6) {
                Text(when).font(.subheadline).foregroundStyle(.secondary)
                Text(entry.episode.title).font(.title3).lineLimit(2)
                HStack {
                    PlayCapsule(entry: entry) { model.play(entry.episode) }
                    Spacer()
                    EpisodeMenu(model: model, episode: entry.episode)
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu { EpisodeActions(model: model, episode: entry.episode) }
    }

    private var when: String {
        if let p = entry.position { return Fmt.ago(p.at.wall / 1000) }
        return Fmt.ago(max(entry.episode.item.added, entry.episode.item.mtime))
    }
}

/// A show in a grid or a rail: its art, its title, a line under it.
struct ShowTile: View {
    let show: Show
    let detail: String
    let locked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Artwork(title: show.title)
                .overlay(alignment: .topTrailing) {
                    if locked { Image(systemName: "lock.fill").padding(8).foregroundStyle(.white) }
                }
            Text(show.title).font(.headline).lineLimit(2).padding(.top, 4)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    static func count(_ s: Show) -> String { s.episodeCount == 1 ? "1 episode" : "\(s.episodeCount) episodes" }
}

/// A horizontal row of cards that snaps card by card, with the screen's margins.
struct Rail<Item: Identifiable, Card: View>: View {
    let items: [Item]
    var fraction: CGFloat = 0.84
    var maxWidth: CGFloat = 420
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(items) { i in
                    card(i).containerRelativeFrame(.horizontal) { w, _ in min(w * fraction, maxWidth) }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, Theme.gutter, for: .scrollContent)
        .scrollIndicators(.hidden)
    }
}

extension View {
    /// The floating capsule look, where the system has no tab-bar accessory slot.
    func floating() -> some View {
        self.background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary))
            .padding(.horizontal, 16).padding(.bottom, 6)
            .frame(maxWidth: Theme.readable)
    }
}
