// Draftpad on iPad and iPhone: the same editor as the Mac (editor/dist/editor.html, bundled), on the same
// draftpad.md in the Obsidian vault, saved through the same 3-way merge (strip/notesync.swift), so an edit from the
// Mac or from Obsidian is merged, never overwritten. Embeds load through the same recense-file: scheme
// (strip/embedfiles.swift): vault files directly, web files from a cache, so they open offline after the first time.
//
// Apple Pencil:
// - Write into the text with Scribble: iPadOS turns handwriting into typed text in the editor.
// - Ink: squeeze (Apple Pencil Pro), double-tap (2nd generation and Pro) or the pencil button opens the ink layer.
//   Draw with the Pencil (fingers still scroll); the tool palette follows the Pencil Pro (barrel roll, squeeze for
//   the compact palette). Done saves the drawing next to draftpad.md, in "Draftpad ink/", as a PNG (what the editor
//   and Obsidian show) plus its PencilKit .drawing, and puts ![](<Draftpad ink/…png>) under the cursor's line.
import SwiftUI
import WebKit
import PencilKit
import UniformTypeIdentifiers

func log(_ s: String) { NSLog("draftpad: %@", s) }

// MARK: The file

/// The vault folder you picked once (a security-scoped bookmark), and draftpad.md inside it.
final class DraftpadFile: ObservableObject {
    static let key = "draftpadVaultBookmark"
    @Published private(set) var vault: URL?
    private(set) var base = ""          // what this device last read or wrote: the merge's base
    var note: URL? { vault?.appendingPathComponent("draftpad.md") }

    init() {
        guard let d = UserDefaults.standard.data(forKey: Self.key) else { return }
        var stale = false
        if let u = try? URL(resolvingBookmarkData: d, bookmarkDataIsStale: &stale), u.startAccessingSecurityScopedResource() {
            vault = u
            if stale, let fresh = try? u.bookmarkData() { UserDefaults.standard.set(fresh, forKey: Self.key) }
        }
    }

    func choose(_ folder: URL) {
        guard folder.startAccessingSecurityScopedResource() else { return }
        if let d = try? folder.bookmarkData() { UserDefaults.standard.set(d, forKey: Self.key) }
        vault = folder
    }

    /// The file as it is now (coordinated, so iCloud downloads it first if needed); it becomes the base.
    func load() -> String {
        guard let p = note?.path else { return "" }
        let s = coordinatedRead(p) ?? ""
        base = s
        return s
    }

    /// Saves `mine`, merging any edit that reached the file meanwhile. Returns the text the editor should show when
    /// that differs from `mine` (a merge, or a newer file adopted), else nil.
    func save(_ mine: String) -> String? {
        guard let p = note?.path else { return nil }
        let now = coordinatedRead(p)
        let theirs = now == base ? nil : now
        switch planNoteSave(base: base, mine: mine, theirs: theirs) {
        case .write(let t):
            if t != (theirs ?? base) { coordinatedWrite(t, to: p) }
            base = t
            return t == mine ? nil : t
        case .adopt(let t):
            base = t
            return t
        case .conflict(let m, let other):
            coordinatedWrite(m, to: p)
            coordinatedWrite(other, to: conflictSiblingPath(p))
            base = m
            log("the same lines changed here and on another device; theirs kept beside the note")
            return nil
        }
    }

    /// Writes a drawing into "Draftpad ink/" and returns the vault-relative path of its PNG.
    func saveInk(_ drawing: PKDrawing) -> String? {
        guard let vault = vault, !drawing.bounds.isEmpty else { return nil }
        let dir = vault.appendingPathComponent("Draftpad ink")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmmss"
        let name = f.string(from: Date())
        // Dark ink on paper, so the drawing reads the same in the dark editor, in Obsidian and in a light theme.
        let bounds = drawing.bounds.insetBy(dx: -16, dy: -16)
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { ink = drawing.image(from: bounds, scale: 2) }
        let png = UIGraphicsImageRenderer(size: bounds.size).pngData { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: bounds.size))
            ink.draw(at: .zero)
        }
        let pngURL = dir.appendingPathComponent("\(name).png")
        var ok = false
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: pngURL, options: .forReplacing, error: &err) { u in
            ok = (try? png.write(to: u)) != nil
        }
        try? drawing.dataRepresentation().write(to: dir.appendingPathComponent("\(name).drawing"))
        return ok ? "Draftpad ink/\(name).png" : nil
    }
}

// MARK: The editor

final class DraftpadWeb: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    let web: WKWebView
    let file: DraftpadFile
    private var files: EmbedFiles?
    private var loaded = false
    private var saveTimer: Timer?
    private var pollTimer: Timer?
    private var lastPosted: String?

    init(file: DraftpadFile) {
        self.file = file
        let cfg = WKWebViewConfiguration()
        if let v = file.vault {
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("embeds")
            let f = EmbedFiles(vault: v, cache: cache)
            cfg.setURLSchemeHandler(f, forURLScheme: "recense-file")
            files = f
        }
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        for name in ["editor", "link", "ui"] { cfg.userContentController.add(Weak(self), name: name) }
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        if let page = Bundle.main.url(forResource: "editor", withExtension: "html") {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    /// Message handlers are kept strongly by WebKit; this proxy keeps the editor collectable.
    private final class Weak: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ t: WKScriptMessageHandler) { target = t }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            target?.userContentController(c, didReceive: m)
        }
    }

    func call(_ js: String, _ done: ((Any?) -> Void)? = nil) {
        guard loaded else { done?(nil); return }
        web.evaluateJavaScript("window.recenseEditor && window.recenseEditor.\(js)") { v, _ in done?(v) }
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        loaded = true
        call("setTheme('dark')")
        call("setFontSize(\(UIDevice.current.userInterfaceIdiom == .pad ? 19 : 17))")
        call("setText(\(jsLiteral(file.load())))")
        call("showPage(0)")
        // Another device's edit (the Mac, Obsidian) reaches the file through iCloud: merge it in while open.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.pollExternal() }
    }

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(["file", "about", "", "recense-file"].contains(a.request.url?.scheme ?? "") ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { loaded = false; w.reload() }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        switch m.name {
        case "link":
            if let s = m.body as? String, let u = URL(string: s), ["https", "http", "mailto"].contains(u.scheme ?? "") {
                UIApplication.shared.open(u)
            }
        case "ui":
            if (m.body as? String) == "bounce" { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(); return }
            if let d = m.body as? [String: Any], let kind = d["haptic"] as? String {
                switch kind {
                case "snap": UIImpactFeedbackGenerator(style: .light).impactOccurred()
                case "edge": UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                case "open": UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                default: break
                }
            }
        default:
            guard let s = m.body as? String else { return }
            lastPosted = s
            saveTimer?.invalidate()
            saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in self?.saveNow() }
        }
    }

    func saveNow() {
        saveTimer?.invalidate(); saveTimer = nil
        guard let mine = lastPosted else { return }
        if let shown = file.save(mine) { call("setText(\(jsLiteral(shown)))") }
    }

    /// The page's text right now (skipping its 300 ms debounce), then a save; used before leaving and on a poll.
    func flushAndSave() {
        call("getText()") { [weak self] v in
            guard let self = self else { return }
            if let s = v as? String { self.lastPosted = s }
            self.saveNow()
        }
    }

    private func pollExternal() {
        guard saveTimer == nil, let p = file.note?.path, let now = coordinatedRead(p), now != file.base else { return }
        flushAndSave()
        if lastPosted == nil { if let shown = file.save(file.base) { call("setText(\(jsLiteral(shown)))") } }
    }

    func step(_ delta: Int) {
        call("step(\(delta))") { v in
            if (v as? String) == "bounce" { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
    }

    func insertInk(_ path: String) { call("insertBlock(\(jsLiteral("![](<\(path)>)")))") }

    func stop() { pollTimer?.invalidate(); flushAndSave() }
}

/// A Swift string as a JavaScript string literal.
func jsLiteral(_ s: String) -> String {
    let d = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
    return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
}

// MARK: Pencil

/// The web view, with Apple Pencil's squeeze and double-tap wired to the ink layer.
struct EditorSurface: UIViewRepresentable {
    let web: WKWebView
    let onPencil: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPencil) }

    func makeUIView(context: Context) -> WKWebView {
        let i = UIPencilInteraction(delegate: context.coordinator)
        web.addInteraction(i)
        return web
    }
    func updateUIView(_ v: WKWebView, context: Context) { context.coordinator.onPencil = onPencil }

    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        var onPencil: () -> Void
        init(_ f: @escaping () -> Void) { onPencil = f }
        func pencilInteraction(_ i: UIPencilInteraction, didReceiveSqueeze s: UIPencilInteraction.Squeeze) {
            if s.phase == .ended { onPencil() }
        }
        func pencilInteraction(_ i: UIPencilInteraction, didReceiveTap t: UIPencilInteraction.Tap) { onPencil() }
    }
}

/// The ink layer: a PencilKit canvas over the page with the system tool palette. Fingers scroll; the Pencil draws.
struct InkLayer: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let c = PKCanvasView()
        c.drawingPolicy = .pencilOnly
        c.backgroundColor = UIColor.black.withAlphaComponent(0.12)
        c.isOpaque = false
        c.drawing = drawing
        c.delegate = context.coordinator
        c.overrideUserInterfaceStyle = .dark
        let picker = PKToolPicker()
        picker.setVisible(true, forFirstResponder: c)
        picker.addObserver(c)
        context.coordinator.picker = picker
        DispatchQueue.main.async { c.becomeFirstResponder() }
        return c
    }
    func updateUIView(_ c: PKCanvasView, context: Context) {}

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let parent: InkLayer
        var picker: PKToolPicker?
        init(_ p: InkLayer) { parent = p }
        func canvasViewDrawingDidChange(_ c: PKCanvasView) { parent.drawing = c.drawing }
    }
}

// MARK: The screen

struct DraftpadView: View {
    @StateObject private var file = DraftpadFile()
    var body: some View {
        if file.vault == nil { ChooseVault(file: file) } else { DraftpadEditor(file: file) }
    }
}

/// First run: pick the Obsidian vault folder (Files › iCloud Drive › Obsidian › Obsidian) once.
struct ChooseVault: View {
    @ObservedObject var file: DraftpadFile
    @State private var picking = false
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.pencil").font(.system(size: 44, weight: .light))
            Text("Draftpad").font(.title2.bold())
            Text("Choose your Obsidian vault folder once. Draftpad opens draftpad.md in it, the same file as the Mac.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            Button("Choose the vault folder") { picking = true }.buttonStyle(.borderedProminent)
        }
        .padding()
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
            if case .success(let u) = r { file.choose(u) }
        }
    }
}

struct DraftpadEditor: View {
    @ObservedObject var file: DraftpadFile
    @StateObject private var editor: DraftpadWebBox
    @State private var inking = false
    @State private var drawing = PKDrawing()
    @Environment(\.scenePhase) private var phase

    init(file: DraftpadFile) {
        self.file = file
        _editor = StateObject(wrappedValue: DraftpadWebBox(file: file))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            EditorSurface(web: editor.web.web) { toggleInk() }
            if inking { InkLayer(drawing: $drawing).ignoresSafeArea(edges: .bottom) }
        }
        .navigationTitle("Draftpad").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if inking {
                    Button("Cancel", role: .cancel) { drawing = PKDrawing(); inking = false }
                    Button("Done") { finishInk() }.bold()
                } else {
                    Button { editor.web.step(-1) } label: { Label("Newer page", systemImage: "chevron.left") }
                        .keyboardShortcut("[", modifiers: .command)
                    Button { editor.web.step(1) } label: { Label("Older page", systemImage: "chevron.right") }
                        .keyboardShortcut("]", modifiers: .command)
                    Button { toggleInk() } label: { Label("Draw", systemImage: "pencil.tip.crop.circle") }
                }
            }
        }
        .onChange(of: phase) { _, p in if p != .active { editor.web.flushAndSave() } }
        .onDisappear { editor.web.stop() }
    }

    func toggleInk() { if inking { finishInk() } else { drawing = PKDrawing(); inking = true } }

    func finishInk() {
        if let path = file.saveInk(drawing) { editor.web.insertInk(path) }
        drawing = PKDrawing()
        inking = false
    }
}

/// Holds the editor for the life of the screen.
final class DraftpadWebBox: ObservableObject {
    let web: DraftpadWeb
    init(file: DraftpadFile) { web = DraftpadWeb(file: file) }
}
