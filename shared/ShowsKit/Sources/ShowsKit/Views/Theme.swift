// The skin's look, shared by every screen of both apps (ShowsKit's views and the app's own places: Draftpad, Listen,
// Archive, Ask…), so the whole app reads as one: the Podcasts-style layout the owner chose (11-07 screenshots).
// Calm: one accent, large text, generous gutters, no motion that isn't asked for. Follows the system's light/dark.
import SwiftUI

public enum Theme {
    /// The one accent: icons in Library's rows, the selected tab, play buttons.
    public static let accent = Color(red: 0.64, green: 0.45, blue: 1.0)
    /// Side margin of every screen, and the gap between cards.
    public static let gutter: CGFloat = 20
    public static let cardCorner: CGFloat = 22
    public static let artCorner: CGFloat = 12
    /// Long text never runs wider than this (narrow columns, little lateral scanning).
    public static let readable: CGFloat = 680

    /// A card's fill: a lifted surface on the page background.
    public static var card: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    /// A show's colours when it has no cover: chosen from its name, the same on every device.
    public static func hues(_ seed: String) -> (Color, Color) {
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let a = Double(h % 360) / 360, b = (a + 0.08).truncatingRemainder(dividingBy: 1)
        return (Color(hue: a, saturation: 0.55, brightness: 0.62), Color(hue: b, saturation: 0.65, brightness: 0.38))
    }
}

/// A show's or episode's square artwork: its cover when it has one (B1), else its colours and its name.
public struct Artwork: View {
    let title: String
    let seed: String
    let corner: CGFloat
    let ratio: CGFloat
    let named: Bool

    /// `named: false` for thumbnails too small to read a name on (the mini-player, search rows).
    public init(title: String, seed: String? = nil, corner: CGFloat = Theme.artCorner, ratio: CGFloat = 1, named: Bool = true) {
        self.title = title; self.seed = seed ?? title; self.corner = corner; self.ratio = ratio; self.named = named
    }

    public var body: some View {
        let (a, b) = Theme.hues(seed)
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(alignment: .bottomLeading) {
                if named { Text(title).font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(.white)
                    .lineLimit(3).minimumScaleFactor(0.6).padding(12) }
            }
            .aspectRatio(ratio, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

/// "Up Next ›": a section's title, a link when it leads somewhere.
public struct SectionHeader<Destination: View>: View {
    let title: String
    let destination: Destination?

    public init(_ title: String, @ViewBuilder destination: () -> Destination) { self.title = title; self.destination = destination() }

    public var body: some View {
        Group {
            if let destination {
                NavigationLink { destination } label: { label(chevron: true) }.buttonStyle(.plain)
            } else { label(chevron: false) }
        }
        .padding(.horizontal, Theme.gutter)
    }

    private func label(chevron: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.title2.bold())
            if chevron { Image(systemName: "chevron.right").font(.title3.bold()).foregroundStyle(.secondary) }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

public extension SectionHeader where Destination == EmptyView {
    init(_ title: String) { self.title = title; self.destination = nil }
}

/// One row of Library's list: an accent icon, a title, a chevron.
public struct LibraryRow: View {
    let title: String
    let symbol: String
    let detail: String?

    public init(_ title: String, symbol: String, detail: String? = nil) { self.title = title; self.symbol = symbol; self.detail = detail }

    public var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Theme.accent).frame(width: 34)
            Text(title).font(.title3)
            Spacer()
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// A place the app adds to Library (Draftpad, Listen, Archive, Ask…): its row, and the screen it opens.
public struct Place: Identifiable {
    public let id: String
    public let title: String
    public let symbol: String
    public let screen: () -> AnyView

    public init<V: View>(id: String, title: String, symbol: String, @ViewBuilder screen: @escaping () -> V) {
        self.id = id; self.title = title; self.symbol = symbol; self.screen = { AnyView(screen()) }
    }
}

public extension View {
    /// What every screen wears: the accent, a large title, the page background.
    func recenseScreen(_ title: String) -> some View {
        self.navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .tint(Theme.accent)
    }
}
