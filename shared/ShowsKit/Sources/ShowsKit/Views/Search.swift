// Search: names and titles now; transcripts and extracted text join through B1's local index. The filter bars
// (New, Downloads, Recensed, Screenshots, Videos, Media) sit under the field; Trash stays out of sight.
import SwiftUI

struct SearchView: View {
    let model: ShowsModel
    @StateObject private var page = Results()

    final class Results: ObservableObject {
        @Published var text = ""
        @Published var filter: Filter?
        @Published var items: [PoolItem] = []
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Filter.allCases.filter { $0 != .trash }, id: \.self) { f in
                            Button { page.filter = page.filter == f ? nil : f } label: { Text(Self.title(f)).font(.headline) }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .tint(page.filter == f ? Theme.accent : .secondary)
                                .accessibilityAddTraits(page.filter == f ? .isSelected : [])
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .listRowSeparator(.hidden)
            }
            if page.text.isEmpty && page.filter == nil {
                Text("Search your shows and episodes, or pick a filter.").foregroundStyle(.secondary)
            } else if page.items.isEmpty {
                Text("No results.").foregroundStyle(.secondary)
            }
            ForEach(page.items) { i in
                let e = Episode(item: i, show: "", title: (i.name as NSString).deletingPathExtension)
                Button { model.play(e) } label: {
                    HStack(spacing: 14) {
                        Artwork(title: e.title, corner: 8, named: false).frame(width: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(.title3).lineLimit(2)
                            Text((i.path as NSString).deletingLastPathComponent).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .searchable(text: $page.text, prompt: "Shows, episodes, files")
        .recenseScreen("Search")
        .task(id: "\(page.text)#\(page.filter?.rawValue ?? "")#\(model.revision)#\(model.gate.isOpen)") {
            guard !page.text.isEmpty || page.filter != nil else { page.items = []; return }
            page.items = (try? await model.store.search(Query(text: page.text, filter: page.filter, includeLocked: model.gate.isOpen))) ?? []
        }
    }

    static func title(_ f: Filter) -> String {
        switch f {
        case .new: "New"
        case .downloads: "Downloads"
        case .recensed: "Recensed"
        case .screenshots: "Screenshots"
        case .videos: "Videos"
        case .media: "Media"
        case .trash: "Recently Deleted"
        }
    }
}
