// The skin's root: spaces as a sidebar on the iPad and the Mac, as tabs on the iPhone; the mini-player under every
// space; Now Playing as a sheet that hosts our player (the host app passes it in: the web player, B3).
import SwiftUI

public struct ShowsRoot<Player: View>: View {
    @Bindable var model: ShowsModel
    let player: (Episode) -> Player
    let close: (() -> Void)?
    @Environment(\.scenePhase) private var phase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var size
    #endif

    public init(model: ShowsModel, close: (() -> Void)? = nil, @ViewBuilder player: @escaping (Episode) -> Player) {
        self.model = model; self.player = player; self.close = close
    }

    private var compact: Bool {
        #if os(iOS)
        size == .compact
        #else
        false
        #endif
    }

    public var body: some View {
        Group { if compact { tabs } else { split } }
            .safeAreaInset(edge: .bottom) { MiniPlayer(model: model) }
            .sheet(isPresented: $model.nowPlayingOpen) { NowPlaying(model: model, player: player) }
            .task { await model.run() }
            .alert("Couldn't do that", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
                Button("OK") { model.problem = nil }
            } message: { Text(model.problem ?? "") }
            .onChange(of: phase) { _, p in if p != .active { model.gate.lock() } }
    }

    private var split: some View {
        NavigationSplitView {
            List(model.spaces, selection: Binding<SpaceID?>(get: { model.space }, set: { if let s = $0 { model.space = s } })) { s in
                Label(s.title, systemImage: s.locked ? "lock" : s.symbol).font(.title3).tag(s.id)
            }
            .navigationTitle("Recense")
        } detail: {
            if let s = model.spaces.first(where: { $0.id == model.space }) {
                NavigationStack { SpaceView(model: model, space: s).toolbar { closeButton } }.id(s.id)
            }
        }
    }

    private var tabs: some View {
        TabView(selection: $model.space) {
            ForEach(model.spaces) { s in
                NavigationStack { SpaceView(model: model, space: s).toolbar { closeButton } }
                    .tabItem { Label(s.title, systemImage: s.symbol) }
                    .tag(s.id)
            }
        }
    }

    @ToolbarContentBuilder private var closeButton: some ToolbarContent {
        if let close {
            ToolbarItem(placement: .cancellationAction) { Button("Close", action: close) }
        }
    }
}

/// One space: the Library grid, or the gate while it is locked.
struct SpaceView: View {
    let model: ShowsModel
    let space: Space

    var body: some View {
        Group {
            if model.isLocked(space) { LockedView(model: model, title: space.title) } else { LibraryGrid(model: model, space: space) }
        }
        .navigationTitle(space.title)
        .navigationDestination(for: Show.self) { ShowPage(model: model, show: $0) }
    }
}

struct LockedView: View {
    let model: ShowsModel
    let title: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text("\(title) is locked").font(.title2)
            Button { Task { await model.gate.unlock("Open \(title)") } } label: {
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
