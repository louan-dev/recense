// The app's browser, shaped like Files (docs/architecture.md §10): a sidebar with the archive's top folders, then any
// folder as icons or a list, searched and sorted like Files. It reads the same feed as the Files extension. Opening a
// file shows it in Gallery's own player (PlayerView), in its folder, so next and previous work as on the web.
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class Folder: ObservableObject {
    let path: String
    @Published var items: [Record] = []
    @Published var error: String?
    @Published var loading = false
    private let feed = Feed()

    init(_ path: String) { self.path = path }

    func load() {
        guard !loading else { return }
        loading = true
        error = nil
        var all: [Record] = []
        func page(_ cursor: String?) {
            feed.items(path, cursor: cursor) { result in
                Task { @MainActor in
                    switch result {
                    case .success(let (records, next)):
                        all += records
                        if let next { page(next) } else { self.items = all; self.loading = false }
                    case .failure(let e):
                        self.error = (e as? FeedError).map(Self.say) ?? "Couldn’t load this folder."
                        self.loading = false
                    }
                }
            }
        }
        page(nil)
    }

    static func say(_ e: FeedError) -> String {
        switch e {
        case .offline: return "You’re offline."
        case .notSignedIn: return "This iPad isn’t signed in to Gallery."
        case .notFound: return "This folder isn’t there any more."
        default: return "Gallery isn’t answering right now."
        }
    }
}

enum Sort: String, CaseIterable { case name = "Name", date = "Date", size = "Size" }

extension Record {
    var inArchive: String { String(path.dropFirst(Gallery.rootPath.count + 1)) }  // the path inside chauphan/
    var type: UTType { dir ? .folder : UTType(filenameExtension: (name as NSString).pathExtension) ?? .data }
    var symbol: String {
        if dir { return "folder.fill" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        return "doc"
    }
    var date: Date? { mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    var detail: String {
        let d = date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        guard !dir, let size else { return d }
        return d + " · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct Browser: View {
    static let assistant = "\u{0}assistant"  // a sidebar tag no folder path can be
    static let shared = "\u{0}shared"
    @StateObject private var top = Folder(Gallery.rootPath)
    @State private var picked: String? = Gallery.rootPath

    var body: some View {
        NavigationSplitView {
            List(selection: $picked) {
                Section("Locations") {
                    Label("Chauphan", systemImage: "icloud").tag(Gallery.rootPath)
                    Label("Shared", systemImage: "person.2").tag(Browser.shared)
                    Label("Assistant", systemImage: "sparkles").tag(Browser.assistant)
                }
                Section("Folders") {
                    ForEach(top.items.filter(\.dir), id: \.id) { f in
                        Label(f.name, systemImage: "folder").tag(f.path)
                    }
                }
            }
            .navigationTitle("Gallery")
            .task { top.load() }
        } detail: {
            NavigationStack {
                if picked == Browser.assistant {
                    PlayerView(url: galleryURL("/main/archive", ["ask": "1"])).ignoresSafeArea(edges: .bottom)
                        .navigationTitle("Assistant").navigationBarTitleDisplayMode(.inline)
                } else if picked == Browser.shared {
                    // the site's Shared section, with its own top bar (back, Shared, + ⋯) and Personal | Shared | Activity (notes item 15)
                    PlayerView(url: galleryURL("/main/shared")).ignoresSafeArea(edges: .bottom)
                        .navigationTitle("").navigationBarTitleDisplayMode(.inline)  // only the way back to the sidebar
                } else if let picked { FolderView(path: picked).id(picked) }
            }
        }
    }
}

struct FolderView: View {
    @StateObject private var folder: Folder
    @State private var query = ""
    @State private var sort = Sort.name
    @AppStorage("asList") private var asList = false
    @State private var playing: Record?
    @State private var linking: (done: Int, total: Int)?
    @State private var shared: SharedLink?
    @State private var failed: String?
    @State private var asking = false

    init(path: String) { _folder = StateObject(wrappedValue: Folder(path)) }

    private var shown: [Record] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let hit = q.isEmpty ? folder.items : folder.items.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return hit.sorted { a, b in
            if a.dir != b.dir { return a.dir }  // folders first, as Files does
            switch sort {
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .date: return (a.mtime ?? 0) > (b.mtime ?? 0)
            case .size: return (a.size ?? 0) > (b.size ?? 0)
            }
        }
    }

    var body: some View {
        Group {
            if let error = folder.error, folder.items.isEmpty {
                ContentUnavailableView(error, systemImage: "icloud.slash", description: Text("Pull to try again."))
            } else if folder.loading && folder.items.isEmpty {
                ProgressView()
            } else if asList {
                List(shown, id: \.id) { r in row(r) }.listStyle(.plain)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 24)], spacing: 28) {
                        ForEach(shown, id: \.id) { r in tile(r) }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle(folder.path == Gallery.rootPath ? "Chauphan" : String(folder.path.split(separator: "/").last ?? ""))
        .searchable(text: $query)
        .refreshable { folder.load() }
        .toolbar {
            // the assistant, on this folder ("This folder"; it has an All switch)
            ToolbarItem(placement: .primaryAction) {
                Button { asking = true } label: { Label("Assistant", systemImage: "sparkles") }
                    .keyboardShortcut("k")  // ⌘K, as on the Mac
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("View", selection: $asList) {
                        Label("Icons", systemImage: "square.grid.2x2").tag(false)
                        Label("List", systemImage: "list.bullet").tag(true)
                    }
                    Picker("Sort By", selection: $sort) {
                        ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { folder.load() }
        .overlay(alignment: .bottom) {
            if let l = linking {
                Label(l.total > 1 ? "Making the link… \(l.done) of \(l.total)" : "Making the link…", systemImage: "link")
                    .font(.footnote).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule()).padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $asking) {
            NavigationStack {
                PlayerView(url: galleryURL("/main/archive", ["p": folder.path == Gallery.rootPath ? nil : String(folder.path.dropFirst(Gallery.rootPath.count + 1)), "ask": "1"]))
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Assistant").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { asking = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $shared) { ActivityView(items: [$0.url]).presentationDetents([.medium, .large]) }
        .alert("Couldn’t make the link", isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failed ?? "") }
        .navigationDestination(for: String.self) { FolderView(path: $0) }
        .fullScreenCover(item: $playing) { r in
            PlayerView(folder: parentPath(r.inArchive), open: r.inArchive)
                .ignoresSafeArea()
                .overlay(alignment: .topLeading) {
                    Button { playing = nil } label: {
                        Image(systemName: "xmark").font(.body.weight(.semibold)).padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(.leading, 16).padding(.top, 8)
                }
        }
    }

    @ViewBuilder private func open(_ r: Record, @ViewBuilder _ label: () -> some View) -> some View {
        Group {
            if r.dir { NavigationLink(value: r.path) { label() }.buttonStyle(.plain) }
            else { Button { playing = r } label: { label() }.buttonStyle(.plain) }
        }
        .contextMenu {
            Menu {
                ForEach([(1, "1 Day"), (7, "7 Days"), (30, "30 Days")], id: \.0) { days, name in
                    Button(name) { share(r, days: days) }
                }
            } label: { Label(r.dir ? "Share Folder Link" : "Share Link", systemImage: "square.and.arrow.up") }
        }
    }

    // a Gallery link, as the web makes one: a file, or every file directly in a folder
    private func share(_ r: Record, days: Int) {
        guard linking == nil else { return }
        linking = (0, 1)
        Task {
            do {
                let paths = r.dir ? try await Folder.files(in: r.path) : [r.inArchive]
                guard !paths.isEmpty else { throw FeedError.notFound }
                let url = try await Share.link(paths, days: days) { done, total in
                    Task { @MainActor in linking = (done, total) }
                }
                linking = nil
                shared = SharedLink(url: url)
            } catch {
                linking = nil
                failed = (error as? FeedError) == .notFound ? "There are no files in this folder." : "Check the connection and try again."
            }
        }
    }

    private func tile(_ r: Record) -> some View {
        open(r) {
            VStack(spacing: 6) {
                Image(systemName: r.symbol)
                    .font(.system(size: r.dir ? 64 : 44, weight: .light))
                    .foregroundStyle(r.dir ? Color.accentColor : .secondary)
                    .frame(height: 80)
                Text(r.name).font(.footnote).lineLimit(2).multilineTextAlignment(.center)
                Text(r.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
    }

    private func row(_ r: Record) -> some View {
        open(r) {
            HStack(spacing: 12) {
                Image(systemName: r.symbol).font(.title2).foregroundStyle(r.dir ? Color.accentColor : .secondary).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name).lineLimit(1)
                    Text(r.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if r.dir { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
            .contentShape(Rectangle())
        }
    }
}

extension Record: Identifiable {}

struct SharedLink: Identifiable { let url: URL; var id: URL { url } }

// the iOS share sheet (Messages, Mail, AirDrop, Copy)
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}

extension Folder {
    // the files directly in a folder, as paths inside chauphan/, every page of them
    static func files(in path: String) async throws -> [String] {
        let feed = Feed()
        var out: [String] = []
        var cursor: String? = nil
        repeat {
            let (records, next): ([Record], String?) = try await withCheckedThrowingContinuation { k in
                feed.items(path, cursor: cursor) { k.resume(with: $0) }
            }
            out += records.filter { !$0.dir }.map(\.inArchive)
            cursor = next
        } while cursor != nil
        return out
    }
}
