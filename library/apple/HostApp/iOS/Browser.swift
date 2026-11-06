// The app's browser, shaped like Files (docs/architecture.md §10): a sidebar with the archive's top folders, then any
// folder as icons or a list, searched and sorted like Files. It reads the same feed as the Files extension. Opening a
// file shows it in Gallery's own player (PlayerView), in its folder, so next and previous work as on the web.
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Vision
import CoreImage

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
    var inArchive: String { String(path.dropFirst(Gallery.rootPath.count + 1)) }  // the path inside archive/
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
    static let main = "\u{0}main"
    static let listen = "\u{0}listen"
    static let data = "\u{0}data"
    static let exhibits = "\u{0}exhibits"
    @State private var picked: String? = Gallery.rootPath

    // a rounded square card for a place; tapping it opens the place
    private func place(_ name: String, _ symbol: String, _ tag: String) -> some View {
        Button { picked = tag } label: {
            VStack(alignment: .leading) {
                Image(systemName: symbol).font(.system(size: 28, weight: .light))
                Spacer()
                Text(name).font(.headline)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aspectRatio(1, contentMode: .fit)
            .foregroundStyle(picked == tag ? Color.accentColor : .primary)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(picked == tag ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        NavigationSplitView {
            // Ask and Listen on top, then Main, Archive and Data as cards in a 2-column grid, then Exhibits (notes 20261029 item 16)
            List(selection: $picked) {
                Section("Locations") {
                    Label("Ask", systemImage: "lightbulb").tag(Browser.assistant)
                    Label("Listen", systemImage: "captions.bubble").tag(Browser.listen)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        place("Main", "square.grid.2x2", Browser.main)
                        place("Archive", "icloud", Gallery.rootPath)
                        // the Mac's offsite disks (Photos, Messages, Mail), the archive's Data folder
                        place("Data", "externaldrive", Browser.data)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
                    // the Exhibits suite (header, front card, carousel), moved here out of Main
                    Label("Exhibits", systemImage: "rectangle.stack").tag(Browser.exhibits)
                }
            }
            .navigationTitle("Galleries")
        } detail: {
            NavigationStack {
                if picked == Browser.main {
                    MainView()
                } else if picked == Browser.assistant {
                    PlayerView(url: galleryURL("/main/archive", ["ask": "1"])).ignoresSafeArea(edges: .bottom)
                        .navigationTitle("Ask").navigationBarTitleDisplayMode(.inline)
                } else if picked == Browser.data {
                    PlayerView(url: galleryURL("/main/archive", ["p": "Data"])).ignoresSafeArea(edges: .bottom)
                        .navigationTitle("Data").navigationBarTitleDisplayMode(.inline)
                } else if picked == Browser.exhibits {
                    PlayerView(url: galleryURL("/main", ["exhibits": "1"])).ignoresSafeArea(edges: .bottom)
                        .navigationTitle("Exhibits").navigationBarTitleDisplayMode(.inline)
                } else if picked == Browser.listen {
                    ListenView()
                } else if picked == Browser.shared {
                    // the site's Shared section, with its own top bar (back, Shared, + ⋯) and Personal | Shared | Activity (notes item 15)
                    PlayerView(url: galleryURL("/main/shared")).ignoresSafeArea(edges: .bottom)
                        .navigationTitle("").navigationBarTitleDisplayMode(.inline)  // only the way back to the sidebar
                } else if let picked { FolderView(path: picked).id(picked) }
            }
        }
    }
}

// Main (the owner's gallery, gallery-main), as the site shows it, with its Assistant: This folder is Main, with All
struct MainView: View {
    @State private var asking = false
    var body: some View {
        PlayerView(url: galleryURL("/main")).ignoresSafeArea(edges: .bottom)
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { asking = true } label: { Label("Ask", systemImage: "lightbulb") }.labelStyle(.iconOnly).foregroundStyle(.white)
                        .keyboardShortcut("k")
                }
            }
            .sheet(isPresented: $asking) {
                NavigationStack {
                    PlayerView(url: galleryURL("/main", ["ask": "1"])).ignoresSafeArea(edges: .bottom)
                        .navigationTitle("Ask").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { asking = false } } }
                }
                .presentationDetents([.medium, .large])
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
    // the site's header (notes 20261029 item 16): the … menu, then Select; Select mode picks files
    @State private var selecting = false
    @State private var picked: Set<String> = []
    @State private var status: String?
    @State private var sending: SharedFiles?
    @State private var saving: SharedFiles?
    @State private var linkFor: LinkUse?
    @State private var naming = false
    @State private var newName = ""
    @State private var photos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var covers: [String: UIImage] = [:]
    @State private var shownCovers: [String: UIImage] = [:]  // covers with their text blurred at each card's level
    @State private var coverLevels: [String: String] = [:]
    @State private var editingCover: CoverTarget?  // Edit Cover: which card's cover and blur (notes 20261029 item 16)
    private let feed = Feed()

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
            } else if folder.path == Gallery.rootPath && !asList {
                // the Archive's front page: each folder a rounded square card wearing its first picture, 2 columns
                // that scroll down (notes 20261029 item 16); inside a folder the grid stays as it is
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(shown, id: \.id) { r in r.dir ? AnyView(card(r)) : AnyView(tile(r)) }
                    }
                    .padding(16)
                }
                .task { await loadCovers() }
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
        .navigationTitle(selecting ? (picked.isEmpty ? "Select Items" : "\(picked.count) Selected") : title)
        .searchable(text: $query)
        .refreshable { folder.load() }
        .toolbar {
            // the assistant, on this folder ("This folder"; it has an All switch)
            ToolbarItem(placement: .primaryAction) {
                Button { asking = true } label: { Label("Ask", systemImage: "lightbulb") }.labelStyle(.iconOnly).foregroundStyle(.white)
                    .keyboardShortcut("k")  // ⌘K, as on the Mac
            }
            ToolbarItem(placement: .primaryAction) { more }
            // Select sits right of the … menu, as on the site; Cancel leaves Select mode
            ToolbarItem(placement: .primaryAction) {
                Button(selecting ? "Cancel" : "Select") { selecting.toggle(); if !selecting { picked = [] } }
                    .disabled(shown.isEmpty && !selecting)
            }
        }
        .alert("New Folder", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") { makeFolder(newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(linkFor?.title ?? "", isPresented: Binding(get: { linkFor != nil }, set: { if !$0 { linkFor = nil } }), titleVisibility: .visible) {
            ForEach([(1, "1 Day"), (7, "7 Days"), (30, "30 Days")], id: \.0) { days, name in
                Button(name) { if let use = linkFor { makeLink(use, days: days) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text(linkFor?.message ?? "") }
        .photosPicker(isPresented: $photos, selection: $photoItems, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            addPhotos(items)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { addFiles(urls) }
        }
        .sheet(item: $sending) { ActivityView(items: $0.urls).presentationDetents([.medium, .large]) }
        .sheet(item: $saving) { ExportView(urls: $0.urls) }
        .sheet(item: $editingCover) { t in
            CoverEditor(folders: shown.filter { $0.dir && $0.name != "Data" }.map(\.name), folder: t.folder) {
                covers = [:]; shownCovers = [:]
                Task { await loadCovers() }
            }
        }
        .task { folder.load() }
        .overlay(alignment: .bottom) {
            if let l = linking {
                Label(l.total > 1 ? "Making the link… \(l.done) of \(l.total)" : "Making the link…", systemImage: "link")
                    .font(.footnote).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule()).padding(.bottom, 24)
            } else if let status {
                Text(status).font(.footnote).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule()).padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $asking) {
            NavigationStack {
                PlayerView(url: galleryURL("/main/archive", ["p": folder.path == Gallery.rootPath ? nil : String(folder.path.dropFirst(Gallery.rootPath.count + 1)), "ask": "1"]))
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Ask").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { asking = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $shared) { l in ActivityView(items: l.note.map { [$0, l.url] as [Any] } ?? [l.url]).presentationDetents([.medium, .large]) }
        .alert("Something went wrong", isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } })) {
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

    private var title: String { folder.path == Gallery.rootPath ? "Archive" : String(folder.path.split(separator: "/").last ?? "") }
    private var files: [Record] { shown.filter { !$0.dir } }
    // what an action works on: the picked files and folders, else every file here (a folder is shared whole; notes item 16)
    private var chosen: [Record] { picked.isEmpty ? files : shown.filter { picked.contains($0.id) } }

    // the … menu: the site's (page/gallery.js), wired to the archive (src/fp.js) and the system's own sheets
    private var more: some View {
        Menu {
            Section {
                Button { selecting = true; picked = Set(shown.map(\.id)) } label: { Label("Select", systemImage: "checkmark.circle") }
                    .disabled(shown.isEmpty)
                Button { picked = [] } label: { Label("Deselect", systemImage: "circle") }
                    .disabled(picked.isEmpty)
            }
            Section {
                Button { fetch(chosen.filter { !$0.dir }) { saving = SharedFiles(urls: $0) } } label: { Label("Download", systemImage: "arrow.down.circle") }
                Button { fetch(chosen.filter { !$0.dir }) { sending = SharedFiles(urls: $0) } } label: { Label("AirDrop", systemImage: "airplayaudio") }
                Button { linkFor = .copy } label: { Label("Create Share Link", systemImage: "link") }
                Button { linkFor = .invite } label: { Label("Invite", systemImage: "person.badge.plus") }
            }
            .disabled(chosen.isEmpty)
            if folder.path == Gallery.rootPath, let first = (shown.first { $0.dir && picked.contains($0.id) } ?? shown.first { $0.dir && $0.name != "Data" }) {
                Button { editingCover = CoverTarget(folder: first.name) } label: { Label("Edit Cover", systemImage: "photo.on.rectangle") }
            }
            Section {
                Menu {
                    Button { photos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                    Button { importing = true } label: { Label("Files", systemImage: "folder") }
                } label: { Label("Add Media", systemImage: "plus") }
                Button { newName = ""; naming = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
            }
            Section {
                Picker("View", selection: $asList) {
                    Label("Icons", systemImage: "square.grid.2x2").tag(false)
                    Label("List", systemImage: "list.bullet").tag(true)
                }
                Picker("Sort By", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
        } label: { Image(systemName: "ellipsis.circle") }
    }

    private func say(_ text: String?, for seconds: Double = 2.4) {
        status = text
        guard text != nil else { return }
        Task { try? await Task.sleep(for: .seconds(seconds)); if status == text { status = nil } }
    }

    // the files' bytes, to hand to Save to Files or the share sheet (AirDrop)
    private func fetch(_ rs: [Record], then: @escaping ([URL]) -> Void) {
        guard !rs.isEmpty, status == nil else { return }
        Task {
            var urls: [URL] = []
            do {
                for (i, r) in rs.enumerated() {
                    status = rs.count > 1 ? "Downloading \(i + 1) of \(rs.count)…" : "Downloading…"
                    urls.append(try await feed.download(r.path))
                }
                status = nil
                then(urls)
            } catch {
                status = nil
                failed = "Couldn’t download \(rs.count > 1 ? "them" : "it"). Check the connection and try again."
            }
        }
    }

    private func makeLink(_ use: LinkUse, days: Int) {
        let rs = chosen
        guard linking == nil, !rs.isEmpty else { return }
        linking = (0, rs.count)
        Task {
            do {
                var paths: [String] = []
                for r in rs { paths += r.dir ? try await Folder.files(in: r.path) : [r.inArchive] }
                guard !paths.isEmpty else { throw FeedError.notFound }
                let url = try await Share.link(paths, days: days) { done, total in
                    Task { @MainActor in linking = (done, total) }
                }
                linking = nil
                switch use {
                case .copy:
                    UIPasteboard.general.url = url
                    say("Link copied. \(rs.count) \(rs.count == 1 ? "item" : "items") shared for \(days) \(days == 1 ? "day" : "days")")
                case .invite:
                    // whoever opens it can comment and like under their name (src/public.js guestCommentApi)
                    shared = SharedLink(url: url, note: "Come see \(rs.count == 1 ? rs[0].name : title) on Gallery. Leave a comment if you like:")
                }
            } catch {
                linking = nil
                failed = "Couldn’t make the link. Check the connection and try again."
            }
        }
    }

    private func makeFolder(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { failed = "That name can’t be used."; return }
        Task {
            do {
                try await feed.folder(folder.path + "/" + name)
                folder.load()
                say("Made “\(name)”")
            } catch {
                failed = (error as? FeedError) == .server(409) ? "Something called “\(name)” is already here." : "Couldn’t make the folder. Check the connection and try again."
            }
        }
    }

    // into this folder; a name already here gets " 2", " 3"…, never replaces anything
    private func upload(_ files: [(url: URL, mtime: Date?)]) async {
        var done = 0
        for (i, f) in files.enumerated() {
            status = files.count > 1 ? "Uploading \(i + 1) of \(files.count)…" : "Uploading…"
            let base = (f.url.lastPathComponent as NSString).deletingPathExtension, ext = f.url.pathExtension
            for n in 1...20 {
                let name = (n == 1 ? base : "\(base) \(n)") + (ext.isEmpty ? "" : "." + ext)
                do { try await feed.put(folder.path + "/" + name, file: f.url, mtime: f.mtime); done += 1; break }
                catch FeedError.server(409) { continue }
                catch { break }
            }
        }
        status = nil
        folder.load()
        if done < files.count { failed = "\(files.count - done) of \(files.count) didn’t upload. Check the connection and try again." }
        else { say("Added \(done) \(done == 1 ? "item" : "items")") }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) {
        Task {
            var got: [(url: URL, mtime: Date?)] = []
            for item in items {
                if let p = try? await item.loadTransferable(type: PickedFile.self) { got.append((p.url, nil)) }
            }
            await upload(got)
        }
    }

    private func addFiles(_ urls: [URL]) {
        Task {
            var got: [(url: URL, mtime: Date?)] = []
            for u in urls {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                if let copy = try? PickedFile.copy(u) {
                    got.append((copy, (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate))
                }
            }
            await upload(got)
        }
    }

    @ViewBuilder private func open(_ r: Record, @ViewBuilder _ label: () -> some View) -> some View {
        Group {
            if selecting {
                Button { if picked.contains(r.id) { picked.remove(r.id) } else { picked.insert(r.id) } } label: {
                    label()
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: picked.contains(r.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(Color.accentColor).background(Circle().fill(.background))
                        }
                }
                .buttonStyle(.plain)
            }
            else if r.dir { NavigationLink(value: r.path) { label() }.buttonStyle(.plain) }
            else { Button { playing = r } label: { label() }.buttonStyle(.plain) }
        }
        .contextMenu {
            Menu {
                ForEach([(1, "1 Day"), (7, "7 Days"), (30, "30 Days")], id: \.0) { days, name in
                    Button(name) { share(r, days: days) }
                }
            } label: { Label(r.dir ? "Share Folder Link" : "Share Link", systemImage: "square.and.arrow.up") }
            if r.dir && folder.path == Gallery.rootPath && r.name != "Data" {
                Button { editingCover = CoverTarget(folder: r.name) } label: { Label("Edit Cover", systemImage: "photo.on.rectangle") }
            }
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

    private func card(_ r: Record) -> some View {
        open(r) {
            ZStack(alignment: .bottomLeading) {
                Color(.secondarySystemBackground)
                if let im = shownCovers[r.name] ?? covers[r.name] {
                    Image(uiImage: im).resizable().scaledToFill()
                } else {
                    Image(systemName: r.symbol).font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                Text(r.name).font(.headline).foregroundStyle(.white).lineLimit(1).padding(12)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if selecting { Image(systemName: picked.contains(r.id) ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(.white, Color.accentColor).padding(10) }
            }
            .contentShape(Rectangle())
        }
    }

    // each top folder's cover (the one chosen in Edit Cover, else its first picture) and its blur level, from
    // /main/archive?covers=1 (a video folder keeps its icon)
    private func loadCovers() async {
        guard covers.isEmpty else { return }
        struct Cover: Decodable { let src: String; let video: Bool?; let blur: String? }
        struct Covers: Decodable { let covers: [String: Cover] }
        guard let j = await siteData("/main/archive?covers=1"), let c = try? JSONDecoder().decode(Covers.self, from: j) else { return }
        for (name, cv) in c.covers where cv.video != true {
            if let data = await siteData(cv.src), let im = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 400, height: 400)) {
                covers[name] = im; coverLevels[name] = cv.blur ?? "medium"; shownCovers[name] = blurText(im, cv.blur ?? "medium")
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

struct SharedLink: Identifiable { let url: URL; var note: String? = nil; var id: URL { url } }
struct SharedFiles: Identifiable { let urls: [URL]; let id = UUID() }

enum LinkUse {
    case copy, invite
    var title: String { self == .copy ? "Create Share Link" : "Invite" }
    var message: String {
        self == .copy ? "The link goes to the clipboard. It works for anyone who has it until it expires."
            : "Send the link in Messages or Mail. Whoever opens it can comment and like, under the name they give."
    }
}

// a picked photo or video, or a file from Files, copied into this app's temporary folder under its own name
struct PickedFile: Transferable {
    let url: URL
    static func copy(_ from: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let to = dir.appendingPathComponent(from.lastPathComponent)
        try FileManager.default.copyItem(at: from, to: to)
        return to
    }
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { PickedFile(url: try copy($0.file)) }
        FileRepresentation(importedContentType: .image) { PickedFile(url: try copy($0.file)) }
    }
}

// Save to Files, for Download
struct ExportView: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController { UIDocumentPickerViewController(forExporting: urls, asCopy: true) }
    func updateUIViewController(_ c: UIDocumentPickerViewController, context: Context) {}
}

// the iOS share sheet (Messages, Mail, AirDrop, Copy)
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}

extension Folder {
    // the files directly in a folder, as paths inside archive/, every page of them
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

/// A request to the site with the app's access token (GET, or POST with a JSON body)
func siteData(_ path: String, post body: [String: Any]? = nil) async -> Data? {
    guard let d = Token.read(), let t = try? JSONDecoder().decode([String: String].self, from: d),
          let id = t["id"], let secret = t["secret"], let host = Gallery.base.host,
          let u = URL(string: "https://\(host)\(path)") else { return nil }
    var r = URLRequest(url: u)
    r.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
    r.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
    if let body {
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
    }
    guard let (data, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    return data
}

struct CoverTarget: Identifiable { let folder: String; var id: String { folder } }

/// Edit Cover (notes 20261029 item 16): pick the picture an Archive card wears and how much its text is blurred,
/// as the site's panel does; saved to /main/api/cards for the app and the site alike.
struct CoverEditor: View {
    let folders: [String]
    @State var folder: String
    var saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    struct Pic: Decodable, Identifiable { let path: String; let name: String; let src: String; let video: Bool?; var id: String { path } }
    struct Card: Decodable { let file: String?; let blur: String? }
    struct Listing: Decodable { let card: Card; let files: [Pic] }
    @State private var pics: [Pic] = []
    @State private var thumbs: [String: UIImage] = [:]
    @State private var file: String?
    @State private var original: String?
    @State private var blur = "medium"
    @State private var preview: UIImage?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if folders.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack { ForEach(folders, id: \.self) { f in
                                Button(f) { folder = f }.buttonStyle(.bordered).tint(f == folder ? .accentColor : .gray)
                            } }.padding(.horizontal)
                        }
                    }
                    ZStack {
                        Color(.secondarySystemBackground)
                        if let preview { Image(uiImage: preview).resizable().scaledToFill() }
                    }
                    .frame(width: 180, height: 180).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    Picker("Blur", selection: $blur) {
                        Text("Off").tag("off"); Text("Low").tag("low"); Text("Medium").tag("medium"); Text("High").tag("high")
                    }
                    .pickerStyle(.segmented).padding(.horizontal)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                        ForEach(pics.filter { $0.video != true }) { p in
                            Button { file = p.path } label: {
                                ZStack { Color(.secondarySystemBackground); if let im = thumbs[p.path] { Image(uiImage: im).resizable().scaledToFill() } }
                                    .aspectRatio(1, contentMode: .fit).clipped()
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: (file ?? pics.first?.path) == p.path ? 3 : 0))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .task { if thumbs[p.path] == nil, let d = await siteData(p.src), let im = UIImage(data: d)?.preparingThumbnail(of: CGSize(width: 300, height: 300)) { thumbs[p.path] = im; redraw() } }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.vertical)
            }
            .navigationTitle("Edit Cover").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save() }.disabled(saving) }
            }
            .task(id: folder) { await load() }
            .onChange(of: blur) { redraw() }
            .onChange(of: file) { redraw() }
        }
    }

    private func load() async {
        pics = []; preview = nil
        var q = URLComponents(); q.queryItems = [.init(name: "place", value: "archive"), .init(name: "folder", value: folder)]
        guard let d = await siteData("/main/api/cards?" + (q.percentEncodedQuery ?? "")), let l = try? JSONDecoder().decode(Listing.self, from: d) else { return }
        pics = l.files; file = l.card.file; original = l.card.file; blur = l.card.blur ?? "medium"
    }

    private func redraw() {
        let p = file ?? pics.first { $0.video != true }?.path
        preview = p.flatMap { thumbs[$0] }.map { blurText($0, blur) }
    }

    private func save() {
        saving = true
        var body: [String: Any] = ["place": "archive", "folder": folder, "blur": blur]
        if let file, file != original { body["file"] = file }
        Task {
            _ = await siteData("/main/api/cards", post: body)
            saved(); dismiss()
        }
    }
}

/// A cover's text blurred, its art and colours kept (notes 20261029 item 16): Vision finds the lines of text,
/// only those boxes take the blur, so you can tell there is writing without reading it.
func blurText(_ im: UIImage, _ level: String) -> UIImage {
    let radius: Double = ["low": 3, "medium": 6, "high": 11][level] ?? 0
    guard radius > 0, let cg = im.cgImage else { return im }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .fast
    req.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: cg, orientation: .up).perform([req])
    let boxes = (req.results ?? []).map(\.boundingBox)
    guard !boxes.isEmpty else { return im }
    let base = CIImage(cgImage: cg), ext = base.extent
    let blurred = base.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: ext)
    // the mask: white where text is, a little larger than each line, softened at its edge
    var mask = CIImage(color: .black).cropped(to: ext)
    for b in boxes {
        let r = VNImageRectForNormalizedRect(b, Int(ext.width), Int(ext.height)).insetBy(dx: -6, dy: -4)
        mask = CIImage(color: .white).cropped(to: r).composited(over: mask)
    }
    mask = mask.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: ext)
    let out = blurred.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: mask])
    guard let done = CIContext().createCGImage(out, from: ext) else { return im }
    return UIImage(cgImage: done)
}
