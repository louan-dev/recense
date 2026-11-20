// Derived from Spec: FEAT-39 (P2 the iPad view). Live edits: what changed on the Mac and is not committed yet, with how long ago
// each file was edited, and a button that files a review snapshot with the coordinator. Every rule (the manifest, the order,
// the age steps, the pair link, the hub address, the offline copy) is shared/ShowsKit/Sources/ShowsKit/LiveEdits.swift; what is
// listed and what is skipped is the Mac's sync/src/livestate.mjs. This file is the screen and the one network call.
// Offline: the last copy opens at once, marked "Mac not reachable"; nothing here blocks on the network.
#if GUEST
// Recense Guest shows nothing of the owner's Mac.
import SwiftUI
struct LiveEditsPlace: View { var body: some View { EmptyView() } }
#else
import Combine
import ShowsKit
import SwiftUI

/// The pair token lives in the Keychain, on this device only (it opens the Mac's hub).
private enum HubToken {
    static let service = "local.recense.hub", account = "token"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func load() -> String? {
        var out: AnyObject?
        guard SecItemCopyMatching(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 } as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    @discardableResult static func save(_ token: String) -> Bool {
        let data = Data(token.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        return SecItemAdd(query.merging([kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 } as CFDictionary, nil) == errSecSuccess
    }
    static func delete() { SecItemDelete(query as CFDictionary) }
}

@MainActor
final class LiveEditsModel: ObservableObject {
    enum Reach: Equatable { case ok, unreachable, untrusted, unauthorized }

    @Published private(set) var manifest: LiveManifest?
    @Published private(set) var asOf: Date?
    @Published private(set) var reach: Reach = .unreachable
    @Published private(set) var paired: Bool
    @Published private(set) var snapshotting: String?
    @Published private(set) var message: String?
    @Published private(set) var now = Date()
    @Published var address: String { didSet { UserDefaults.standard.set(address, forKey: "live.hubAddress") } }

    private let session = URLSession(configuration: .ephemeral)
    private var lastLogged = ""
    private static let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Recense/live-edits.json")

    init() {
        address = UserDefaults.standard.string(forKey: "live.hubAddress") ?? LiveHub.defaultAddress
        paired = HubToken.load() != nil
        if let m = LiveCache.load(from: Self.cacheURL) { manifest = m.sorted; asOf = m.generatedDate }   // the last copy, before any network
    }

    /// Paste on the pair section: the link `recense-hub pair` prints, or the bare token.
    func pair(from text: String?) {
        guard let token = text.flatMap(LiveHub.pairToken(from:)) else {
            message = String(localized: "That is not a pair link. On the Mac, run: recense-hub pair | pbcopy, then paste here."); return
        }
        guard HubToken.save(token) else { message = String(localized: "The pairing could not be saved on this device."); return }
        paired = true; message = nil; reach = .unreachable
        Task { await refresh() }
    }

    func forget() { HubToken.delete(); paired = false; message = nil }

    func refresh() async {
        defer { now = Date() }
        guard let token = HubToken.load() else { paired = false; return }
        paired = true
        guard let base = LiveHub.baseURL(from: address) else { reach = .unreachable; message = String(localized: "The Mac's address is not valid. Use something like https://recense.local."); return }
        do {
            let (data, response) = try await session.data(for: LiveHub.request(base: base, path: "/api/live", token: token, body: nil))
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200:
                guard LiveCache.save(data, to: Self.cacheURL), let m = LiveCache.load(from: Self.cacheURL) else { return }   // unreadable: keep what is shown
                manifest = m.sorted; asOf = m.generatedDate; reach = .ok; log(.hub)
            case 401: reach = .unauthorized
            default: return   // 503: the Mac is mid-write; the next pass reads it
            }
        } catch {
            switch LiveHub.reach(for: error) {
            case .cancelled: return
            case .untrusted: reach = .untrusted
            case .unreachable: reach = .unreachable
            }
            log(.cache)
        }
    }

    func snapshot(_ worktree: String) async {
        guard snapshotting == nil, let token = HubToken.load(), let base = LiveHub.baseURL(from: address) else { return }
        snapshotting = worktree; message = nil
        defer { snapshotting = nil; now = Date() }
        do {
            let (data, response) = try await session.data(for: LiveHub.request(base: base, path: "/api/live/snapshot", token: token, body: ["worktree": worktree]))
            switch LiveSnapshotReply.decode(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data) {
            case .made(let files, let state, let zip):
                message = String(localized: "Filed \(files) files from \(worktree) for review (\(state)\(zip ? ", with a zip" : "")). The coordinator will find it in its inbox.")
            case .refused(let reason, let path):
                switch reason {
                case "clean": message = String(localized: "Nothing to file: \(worktree) has no changes now.")
                case "secret": message = String(localized: "Not filed: a private key is in \(path ?? "a file"). Nothing left the Mac.")
                case "size": message = String(localized: "Not filed: the snapshot is over 25 MB.")
                default: message = String(localized: "Not filed (\(reason)).")
                }
            case .unauthorized: reach = .unauthorized
            case .gone: message = String(localized: "\(worktree) has no listed changes any more.")
            case .failed(let why): message = String(localized: "The Mac could not make the snapshot: \(why)")
            }
        } catch {
            message = LiveHub.reach(for: error) == .untrusted
                ? String(localized: "This device does not trust the Mac yet.")
                : String(localized: "The Mac did not answer. Nothing was filed.")
        }
    }

    private func log(_ source: LiveSource) {
        let key = source.rawValue + (manifest?.generated ?? "")
        guard key != lastLogged else { return }   // one line per change, not one per 10 s pass
        lastLogged = key
        DebugChannel.event("live", "live.view.refreshed", ["source": source.rawValue])
    }
}

struct LiveEditsPlace: View {
    @StateObject private var model = LiveEditsModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var forgetting = false

    private static let relative: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f }()

    var body: some View {
        List {
            if let message = model.message { Section { Text(message).font(.body) } }
            if !model.paired || model.reach == .unauthorized { pairSection }
            if model.paired {
                Section { Text(status).font(.callout).foregroundStyle(.secondary) }
                if let m = model.manifest {
                    if m.worktrees.isEmpty { Section { Text("Nothing is uncommitted on the Mac.").foregroundStyle(.secondary) } }
                    ForEach(m.worktrees, id: \.name) { w in
                        Section {
                            ForEach(w.files, id: \.path) { row($0) }
                            Button { Task { await model.snapshot(w.name) } } label: {
                                HStack { Label("Make Review Snapshot", systemImage: "square.and.arrow.up.on.square"); Spacer()
                                    if model.snapshotting == w.name { ProgressView() } }
                            }
                            .disabled(model.snapshotting != nil || model.reach != .ok)
                            .accessibilityLabel("Make review snapshot of \(w.name)")
                        } header: {
                            HStack { Text(w.branch.isEmpty ? w.name : w.branch); Spacer(); Text("\(w.files.count) files") }.textCase(nil).font(.headline)
                        }
                    }
                }
            }
            Section {
                TextField("Mac address", text: $model.address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .onSubmit { Task { await model.refresh() } }
            } header: { Text("Mac address") } footer: { Text("Usually \(LiveHub.defaultAddress), with the iPad on the same Wi-Fi as the Mac.") }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh() }
        .recenseScreen("Live edits")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MoreMenu {
                    Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!model.paired)
                    Button(role: .destructive) { forgetting = true } label: { Label("Forget the Mac", systemImage: "trash") }.disabled(!model.paired)
                }
            }
        }
        .confirmationDialog("Forget the Mac?", isPresented: $forgetting, titleVisibility: .visible) {
            Button("Forget the Mac", role: .destructive) { model.forget() }
        } message: { Text("The list stops updating until you paste a pair link again. Nothing on the Mac changes.") }
        .task(id: scenePhase == .active) {   // refresh while the screen is open: every 10 s, every 30 s when the Mac is out of reach
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(model.reach == .ok ? 10 : 30))
            }
        }
    }

    private var pairSection: some View {
        Section {
            Text("On the Mac, copy the pair link, then paste it here.")
            Text("recense-hub pair | pbcopy").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            PasteButton(payloadType: String.self) { model.pair(from: $0.first) }
        } header: { Text("Pair with your Mac") }
    }

    private var status: String {
        let when = model.asOf.map { $0.formatted(date: Calendar.current.isDateInToday($0) ? .omitted : .abbreviated, time: .shortened) }
        switch model.reach {
        case .ok: return String(localized: "As of \(when ?? "now"), from the Mac.")
        case .unreachable:
            return when.map { String(localized: "Mac not reachable. Showing the copy from \($0).") } ?? String(localized: "Mac not reachable, and no copy yet. Open this screen on the same Wi-Fi as the Mac.")
        case .untrusted: return String(localized: "This device does not trust the Mac yet. Install the Recense hub profile, then turn it on under Settings › General › About › Certificate Trust Settings.")
        case .unauthorized: return String(localized: "The Mac did not accept this pairing. Paste a new pair link above.")
        }
    }

    private func row(_ f: LiveFile) -> some View {
        let name = (f.path as NSString).lastPathComponent, folder = (f.path as NSString).deletingLastPathComponent
        return VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.title3)
            if !folder.isEmpty { Text(folder).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Text(age(f))
                Spacer()
                Text(f.binary ? String(localized: "binary") : "+\(f.added) \u{2212}\(f.deleted)").monospacedDigit()
            }.font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func age(_ f: LiveFile) -> String {
        guard let t = f.edited else { return f.status == "D" ? String(localized: "deleted") : "" }
        let ago: String
        switch LiveAge.of(model.now.timeIntervalSince(t)) {
        case .justNow: ago = String(localized: "just now")
        case .minutes(let n): ago = Self.relative.localizedString(from: DateComponents(minute: -n))
        case .hours(let n): ago = Self.relative.localizedString(from: DateComponents(hour: -n))
        case .days(let n): ago = Self.relative.localizedString(from: DateComponents(day: -n))
        }
        return f.status == "?" ? ago + " · " + String(localized: "new") : ago
    }
}
#endif
