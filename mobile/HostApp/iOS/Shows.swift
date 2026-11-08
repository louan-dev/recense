// The app's root (B2 redo, 11-07): the Podcasts-style shell from shared/ShowsKit, with the app's own screens as
// Library rows (Places.swift). It runs on the sample pool until B1's pool store lands; our player fills Now Playing in
// B3. The old sidebar (Browser.swift) is kept, unused, until the owner confirms the new shell.
import SwiftUI
import ShowsKit

struct RecenseRoot: View {
    @State private var launchPlace: Place?
    @State private var sampleClock: SampleTransport?   // held here: the model's transport is weak
    @State private var model = ShowsModel(store: MemoryCatalog.sample(device: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"))

    var body: some View {
        ShowsRoot(model: model, places: RecensePlaces.all) { _ in
            VStack(spacing: 12) {
                Image(systemName: "play.rectangle").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
                Text("Our player plays here from B3, offline, from this device.").font(.title3)
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            }
            .padding(24)
        }
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
        .onChange(of: model.playing?.id) { _, _ in if ProcessInfo.processInfo.environment["RECENSE_TRANSCRIPT"] == nil { PlaybackEars.shared.follow(model) } }
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
