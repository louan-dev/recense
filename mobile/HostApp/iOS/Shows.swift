// The Podcasts-style skin (shared/ShowsKit, B2), opened from the sidebar's "Shows (preview)". It runs on the sample
// pool until B1's pool store lands; our player joins Now Playing in B3.
import SwiftUI
import ShowsKit

struct ShowsPreview: View {
    let close: () -> Void
    @State private var model = ShowsModel(store: MemoryCatalog.sample(device: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"))

    var body: some View {
        ShowsRoot(model: model, close: close) { _ in
            VStack(spacing: 12) {
                Image(systemName: "play.rectangle").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
                Text("Our player plays here from B3, offline, from this device.").font(.title3)
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            }
            .padding(24)
        }
    }
}
