// Derived from Spec: FEAT-07 P0
// The Mac's Library window: ShowsKit's Library (its Music tile → the track list with play, pause, loop, rename and
// slide-to-delete), the same views the iPhone and iPad show. A track plays in QuickTime, which Recense's window
// already follows for the transcript; Rename and Delete go through shared/homefiles.swift (Carry replays them).
import AppKit
import SwiftUI
import ShowsKit

/// Play, pause, skip and loop in QuickTime Player, by Apple Events (the same route the window's own controls use).
@MainActor final class QuickTimeTransport: Transport {
    private(set) var isPlaying = false
    private var loops = false

    func open(_ url: URL, loop: Bool) {
        loops = loop
        let qt = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.QuickTimePlayerX")
        let c = NSWorkspace.OpenConfiguration(); c.activates = false
        if let qt {
            NSWorkspace.shared.open([url], withApplicationAt: qt, configuration: c) { _, _ in
                Task { @MainActor in self.run("play document 1"); self.setLoop(loop) }
            }
        } else { NSWorkspace.shared.open(url) }
        isPlaying = true
    }

    func toggle() { run(isPlaying ? "pause document 1" : "play document 1"); isPlaying.toggle() }
    func skip(_ seconds: Double) { run("set current time of document 1 to (current time of document 1) + (\(seconds))") }
    func setLoop(_ on: Bool) { loops = on; run("set looping of document 1 to \(on)") }

    private func run(_ body: String) {
        var e: NSDictionary?
        NSAppleScript(source: "tell application id \"com.apple.QuickTimePlayerX\"\n\(body)\nend tell")?.executeAndReturnError(&e)
        if let e { log("quicktime: \(e[NSAppleScript.errorMessage] ?? e)") }
    }
}

@available(macOS 15, *)
@MainActor final class MusicShelf {
    static let shared = MusicShelf()
    let model = ShowsModel(store: MemoryCatalog(device: "mac"))
    let player = QuickTimeTransport()
    private var window: NSWindow?

    private init() {
        model.transport = player
        model.files = HomeFiles { MusicShelf.shared.rescan() }
        model.loopChanged = { [unowned self] in player.setLoop(model.loopOne) }
    }

    func rescan() {
        guard let store = model.store as? MemoryCatalog else { return }
        let root = Homes.root
        Task.detached(priority: .utility) {
            await store.replaceLocal(PoolScan.items(root: root))
            await MainActor.run { MusicShelf.shared.model.changed() }
        }
    }

    /// A row's Play: the file in QuickTime, with the standing Loop.
    func played(_ e: ShowsKit.Episode?) {
        guard let e else { return }
        model.nowPlayingOpen = false
        player.open(Homes.root.appendingPathComponent(e.item.path), loop: model.loopOne)
    }

    func show() {
        try? Homes.ensure()
        rescan()
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Library"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: MusicShelfView(model: model))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w
    }
}

@available(macOS 15, *)
struct MusicShelfView: View {
    @Bindable var model: ShowsModel
    var body: some View {
        LibraryShelf(model: model)
            .onChange(of: model.playing?.id) { _, _ in MusicShelf.shared.played(model.playing) }
            .frame(minWidth: 420, minHeight: 520)
    }
}
