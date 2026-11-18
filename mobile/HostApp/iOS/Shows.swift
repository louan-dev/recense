// The app's root (B2 redo, 11-07): the Podcasts-style shell from shared/ShowsKit, with the app's own screens as
// Library rows (Places.swift). It runs on the sample pool until B1's pool store lands; our player fills Now Playing in
// B3. The old sidebar (Browser.swift) is kept, unused, until the owner confirms the new shell.
import SwiftUI
import ShowsKit

struct RecenseRoot: View {
    @State private var launchPlace: Place?
    @State private var sampleClock: SampleTransport?   // held here: the model's transport is weak
    @State private var extras = HomeExtras()   // Listen's earlier episodes, in Home's Recently Played
    @ObservedObject private var listen = Listener.shared
    // player P1 (11-11): the invented sample pool only for simulator checks; on the owner's devices Home holds what is
    // real (an empty catalog until the pool store, S3), so no row looks playable that isn't
    @State private var model = ShowsModel(store: RecenseRoot.store())
    @Environment(\.scenePhase) private var phase

    // Derived from Spec: BUG-16
    static func sweepDownloads() {
        Task.detached(priority: .utility) {
            _ = try? Downloads.sweep()
            await MainActor.run { Playback.rescan() }
        }
    }

    /// FEAT-07 P0 Rename and Delete, FEAT-13 "+" and Move to… on the rows; a moved file keeps its saved transcript.
    static func homeFiles() -> HomeFiles {
        let f = HomeFiles { Playback.rescan() }
        f.transcripts = PlaybackEars.cache
        return f
    }

    static func store() -> MemoryCatalog {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        return ProcessInfo.processInfo.environment["RECENSE_TRANSCRIPT"] == "sample" ? .sample(device: device) : MemoryCatalog(device: device)
    }

    var body: some View {
        ShowsRoot(model: model, places: RecensePlaces.all, home: AnyView(VStack(alignment: .leading, spacing: 30) {
            ListeningCard()
            if model.upNext.isEmpty && model.recentlyPlayed.isEmpty && extras.recent.isEmpty {
                HomeEmpty()
            }
        }), extras: extras) { e in NativePlayerView(episode: e) }
        // owner 11-10: the newest listening is Now Playing; a newer one bumps it down to Recently Played
        .onChange(of: listen.episodes.map { "\($0.key)\($0.updated)" } + [listen.episode?.key ?? ""], initial: true) { recentFromListen() }
        .onAppear {
            Playback.model = model
            model.files = Self.homeFiles()
            NativePlayer.shared.saved = { [model] path in
                Playback.rescan()
                Playback.landed(path)
                if model.playing?.item.path == path { PlaybackEars.shared.saved(model) }
            }
            // FEAT-10: the owner changed Translate Into; replan with what's already heard
            model.translateIntoChanged = { [model] in PlaybackTranslator.shared.run(model, lang: Listener.shared.lang) }
        }
        .task { if ProcessInfo.processInfo.environment["RECENSE_TRANSCRIPT"] != "sample" { Self.sweepDownloads() } }
        // BUG-16: what AirDrop, Files or a browser put in downloads/ is adopted on every return; audio settles into Music
        .onChange(of: phase) { _, p in if p == .active { Self.sweepDownloads() } }
        .onAppear {   // simulator checks: SIMCTL_CHILD_RECENSE_TAB=new|library|search opens that tab
            switch ProcessInfo.processInfo.environment["RECENSE_TAB"] {
            case "new": model.tab = .new
            case "library": model.tab = .library
            case "search": model.tab = .search
            default: break
            }
            if let id = ProcessInfo.processInfo.environment["RECENSE_PLACE"] { launchPlace = RecensePlaces.all.first { $0.id == id } }
        }
        .task {   // simulator checks: SIMCTL_CHILD_RECENSE_TRANSCRIPT=sample opens Now Playing on the sample transcript, playing
            guard ProcessInfo.processInfo.environment["RECENSE_TRANSCRIPT"] == "sample" else { return }
            await model.reload()
            guard let e = model.recentlyPlayed.first?.episode ?? model.upNext.first?.episode else { return }
            sampleClock = SampleTransport(at: 8)
            model.transport = sampleClock
            model.play(e)
            model.transcript = TranscriptLine.sample
            model.showsTranscript = true
        }
        // the playing episode heard on this device for its transcript (Ears.swift)
        .onChange(of: model.playing?.id) { _, _ in
            guard ProcessInfo.processInfo.environment["RECENSE_TRANSCRIPT"] == nil else { return }
            Playback.follow()   // an episode from Home, New or Library plays in our player too
            PlaybackEars.shared.follow(model)
        }
        .fullScreenCover(item: $launchPlace) { p in
            NavigationStack { p.screen() }.tint(Theme.accent)   // simulator checks: SIMCTL_CHILD_RECENSE_PLACE=<id>
        }
    }
}

/// The old sidebar's "Shows (preview)" entry opens the same root; it goes when Browser.swift does.
struct ShowsPreview: View {
    let close: () -> Void
    var body: some View { RecenseRoot() }
}

extension RecenseRoot {
    /// Every heard episode but the one Now Playing shows, as Recently Played rows, by when it was last heard.
    private func recentFromListen() {
        extras.recent = listen.episodes.filter { $0.key != listen.episode?.key && !$0.sentences.isEmpty }.map {
            RecentItem(id: "listen:" + $0.key, at: Int64($0.updated), row: AnyView(ListenEpisodeRow(e: $0)))
        }
    }
}

/// Home with nothing in it yet (player P1, 11-11): it says so and offers the way in, a visible button.
/// (Add Files joins when the pool store reads Recense/downloads/, S3: until then an added file wouldn't show here.)
struct HomeEmpty: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nothing here yet").font(.title2.weight(.semibold))
            Text("Your files are in the Archive.").font(.title3).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // a view link on Home's own stack: a file played from there opens Now Playing over it
            NavigationLink { FolderView(path: Gallery.rootPath) } label: { Label("Open Archive", systemImage: "icloud") }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
        }
        .padding(.horizontal, Theme.gutter)
        .frame(maxWidth: Theme.readable, alignment: .leading)
    }
}
