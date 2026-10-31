// The app's browser, shaped like Files (docs/architecture.md §10): a sidebar with the archive's top folders, then any
// folder as icons or a list, searched and sorted like Files. It reads the same feed as the Files extension. Opening a
// file shows it in Gallery's own player (PlayerView), in its folder, so next and previous work as on the web.
import SwiftUI
import PhotosUI
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
    @StateObject private var top = Folder(Gallery.rootPath)
    @State private var picked: String? = Gallery.rootPath

    var body: some View {
        NavigationSplitView {
            List(selection: $picked) {
                Section("Locations") {
                    Label("Main", systemImage: "square.grid.2x2").tag(Browser.main)
                    Label("Archive", systemImage: "icloud").tag(Gallery.rootPath)
                    Label("Shared", systemImage: "person.2").tag(Browser.shared)
                    Label("Assistant", systemImage: "lightbulb").tag(Browser.assistant)
                    Label("Listen", systemImage: "captions.bubble").tag(Browser.listen)
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
                if picked == Browser.main {
                    MainView()
                } else if picked == Browser.assistant {
                    PlayerView(url: galleryURL("/main/archive", ["ask": "1"])).ignoresSafeArea(edges: .bottom)
                        .navigationTitle("Assistant").navigationBarTitleDisplayMode(.inline)
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
                    Button { asking = true } label: { Label("Assistant", systemImage: "lightbulb") }
                        .keyboardShortcut("k")
                }
            }
            .sheet(isPresented: $asking) {
                NavigationStack {
                    PlayerView(url: galleryURL("/main", ["ask": "1"])).ignoresSafeArea(edges: .bottom)
                        .navigationTitle("Assistant").navigationBarTitleDisplayMode(.inline)
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
                Button { asking = true } label: { Label("Assistant", systemImage: "lightbulb") }
                    .keyboardShortcut("k")  // ⌘K, as on the Mac
            }
            ToolbarItem(placement: .primaryAction) { more }
            // Select sits right of the … menu, as on the site; Cancel leaves Select mode
            ToolbarItem(placement: .primaryAction) {
                Button(selecting ? "Cancel" : "Select") { selecting.toggle(); if !selecting { picked = [] } }
                    .disabled(files.isEmpty && !selecting)
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
                    .navigationTitle("Assistant").navigationBarTitleDisplayMode(.inline)
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
    // what an action works on: the picked files, else every file here
    private var chosen: [Record] { picked.isEmpty ? files : files.filter { picked.contains($0.id) } }

    // the … menu: the site's (page/gallery.js), wired to the archive (src/fp.js) and the system's own sheets
    private var more: some View {
        Menu {
            Section {
                Button { selecting = true; picked = Set(files.map(\.id)) } label: { Label("Select", systemImage: "checkmark.circle") }
                    .disabled(files.isEmpty)
                Button { picked = [] } label: { Label("Deselect", systemImage: "circle") }
                    .disabled(picked.isEmpty)
            }
            Section {
                Button { fetch(chosen) { saving = SharedFiles(urls: $0) } } label: { Label("Download", systemImage: "arrow.down.circle") }
                Button { fetch(chosen) { sending = SharedFiles(urls: $0) } } label: { Label("AirDrop", systemImage: "airplayaudio") }
                Button { linkFor = .copy } label: { Label("Create Share Link", systemImage: "link") }
                Button { linkFor = .invite } label: { Label("Invite", systemImage: "person.badge.plus") }
            }
            .disabled(files.isEmpty)
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
                let url = try await Share.link(rs.map(\.inArchive), days: days) { done, total in
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
                Button { if picked.contains(r.id) { picked.remove(r.id) } else if !r.dir { picked.insert(r.id) } } label: {
                    label().opacity(r.dir ? 0.4 : 1)
                        .overlay(alignment: .topTrailing) {
                            if !r.dir {
                                Image(systemName: picked.contains(r.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(Color.accentColor).background(Circle().fill(.background))
                            }
                        }
                }
                .buttonStyle(.plain).disabled(r.dir)
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
