// The skin's root, laid out like Podcasts on iOS 26 (owner's screenshots, 11-07): Home, New and Library tabs plus a
// search tab; on the iPad and the Mac the tabs can become a sidebar. The mini-player floats above the tab bar; Now
// Playing is a sheet that hosts our player (the app passes it in: the web player, B3). The app's own screens
// (Draftpad, Listen, Archive…) come in as `places`, rows in Library.
import SwiftUI

/// macOS 15 and later: the tab API it uses (the Mac strip itself stays on macOS 14 for CGWindowListCreateImage).
@available(macOS 15, *)
public struct ShowsRoot<Player: View>: View {
    @Bindable var model: ShowsModel
    let places: [Place]
    let player: (Episode) -> Player
    let home: AnyView?
    let extras: HomeExtras?
    @Environment(\.scenePhase) private var phase

    /// - home: the app's own card at the top of Home (the iPhone's and iPad's "Now Playing", 11-10); nil: none.
    /// - extras: what the app itself played, merged into Home's Recently Played by when it played (11-10).
    public init(model: ShowsModel, places: [Place] = [], home: AnyView? = nil, extras: HomeExtras? = nil, @ViewBuilder player: @escaping (Episode) -> Player) {
        self.model = model; self.places = places; self.home = home; self.extras = extras; self.player = player
    }

    public var body: some View {
        tabs
            .modifier(MiniPlayerHost(model: model))
            .sheet(isPresented: $model.nowPlayingOpen) { NowPlaying(model: model, player: player) }
            .task { await model.run() }
            .alert("Couldn't do that", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
                Button("OK") { model.problem = nil }
            } message: { Text(model.problem ?? "") }
            .onChange(of: phase) { _, p in if p != .active { model.lock() } }
            .tint(Theme.accent)
    }

    private var tabs: some View {
        TabView(selection: $model.tab) {
            Tab("Home", systemImage: "house.fill", value: ShowsModel.Tab.home) {
                NavigationStack { HomeView(model: model, top: home, extras: extras).toolbar { ProfileButton(model: model) } }.tint(Theme.accent).modifier(TabMini(model: model))
            }
            Tab("New", systemImage: "square.grid.2x2.fill", value: ShowsModel.Tab.new) {
                NavigationStack { NewView(model: model).toolbar { ProfileButton(model: model) } }.tint(Theme.accent).modifier(TabMini(model: model))
            }
            Tab("Library", systemImage: "square.stack.fill", value: ShowsModel.Tab.library) {
                NavigationStack { LibraryView(model: model, places: places).toolbar { ProfileButton(model: model) } }.tint(Theme.accent).modifier(TabMini(model: model))
            }
            Tab(value: ShowsModel.Tab.search, role: .search) {
                NavigationStack { SearchView(model: model) }.tint(Theme.accent).modifier(TabMini(model: model))
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

/// iOS 26: the mini-player sits in the tab bar's accessory slot, as in Podcasts. Elsewhere each tab floats it (TabMini).
struct MiniPlayerHost: ViewModifier {
    let model: ShowsModel

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            content.tabViewBottomAccessory { MiniPlayer(model: model) }
        } else { content }
        #else
        content
        #endif
    }
}

/// Before iOS 26, and on the Mac: the mini-player floats at the bottom of each tab's page, above the tab bar.
struct TabMini: ViewModifier {
    let model: ShowsModel

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26, *) { content } else {
            content.safeAreaInset(edge: .bottom) { MiniPlayer(model: model).floating() }
        }
        #else
        content.safeAreaInset(edge: .bottom) { MiniPlayer(model: model).floating() }
        #endif
    }
}

/// The circle at the top right of Home and New: this device, and the Matters lock.
struct ProfileButton: ToolbarContent {
    let model: ShowsModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Text("Recense on \(model.store.device)")
                Text("Shows are a sample until the pool (B1)")
                if model.gate.isOpen {
                    Button { model.lock() } label: { Label("Lock Matters", systemImage: "lock") }
                } else {
                    Button { Task { await model.unlock("Matters") } } label: { Label("Unlock Matters", systemImage: "faceid") }
                }
            } label: {
                Image(systemName: "person.crop.circle.fill").font(.title2).symbolRenderingMode(.hierarchical)
            }
            .accessibilityLabel("You")
        }
    }
}

/// A space or show behind the gate.
struct LockedView: View {
    let model: ShowsModel
    let title: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text("\(title) is locked").font(.title2)
            Button { Task { await model.unlock(title) } } label: {
                Label("Unlock with Face ID or Touch ID", systemImage: "faceid").font(.title3).padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            if let m = model.gate.message { Text(m).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: 420)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum Fmt {
    /// "1d ago", "3h ago".
    static func ago(_ secs: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(secs)).formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
    }
    /// "43m", "1h 5m".
    static func length(_ s: Double) -> String {
        Duration.seconds(max(60, s)).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
    static func day(_ secs: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(secs)).formatted(.dateTime.day().month(.wide))
    }
}
