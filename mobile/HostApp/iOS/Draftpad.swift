// Draftpad on iPad and iPhone: the same editor as the Mac (editor/dist/editor.html, bundled), on the same
// draftpad.md and draftpad.ink.json in the Obsidian vault, saved through the same 3-way merge (strip/notesync.swift),
// so an edit from the Mac or from Obsidian is merged, never overwritten. Embeds load through the same recense-file:
// scheme (strip/embedfiles.swift): vault files directly, web files from a cache, so they open offline after the first time.
//
// Whiteboard & Apple Pencil Pro:
// - Type and write with an Apple Pencil Pro on the same surface with no mode switch and no Done button.
// - Ink sits on the words and moves with them, stored as plain JSON anchored to lines of text in draftpad.ink.json.
// - Squeeze or double-tap on Apple Pencil Pro toggles the eraser and reveals the pure-dot colour/tool palette with
//   Freeform-grade haptics.
import SwiftUI
import ShowsKit
import WebKit
import AVFoundation
import UniformTypeIdentifiers

func log(_ s: String) { NSLog("draftpad: %@", s) }

// MARK: The file

/// The vault folder you picked once (a security-scoped bookmark), with draftpad.md and draftpad.ink.json inside it.
final class DraftpadFile: ObservableObject {
    static let key = "draftpadVaultBookmark"
    @Published private(set) var vault: URL?
    private(set) var base = ""          // what this device last read or wrote: the merge's base
    private(set) var lastInk = ""       // what this device last read or wrote for draftpad.ink.json
    var note: URL? { vault?.appendingPathComponent("draftpad.md") }
    var inkNote: URL? { vault?.appendingPathComponent("draftpad.ink.json") }

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

    /// Reads the line-anchored ink sidecar JSON from the vault folder.
    func loadInk() -> String {
        guard let p = inkNote?.path else { return "" }
        let s = coordinatedRead(p) ?? ""
        lastInk = s
        return s
    }

    /// Writes the line-anchored ink sidecar JSON to the vault folder.
    func saveInkJSON(_ json: String) {
        guard let p = inkNote?.path, json != lastInk else { return }
        coordinatedWrite(json, to: p)
        lastInk = json
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
    private let speechSynthesizer = AVSpeechSynthesizer()
    var onAudioAction: (([String: Any]) -> Void)?

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
        for name in ["editor", "link", "ui", "ink", "audio"] {
            cfg.userContentController.add(Weak(self), name: name)
        }
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
        let initialInk = file.loadInk()
        if !initialInk.isEmpty {
            call("setInk(\(jsLiteral(initialInk)))")
        }
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
                case "snap": UISelectionFeedbackGenerator().selectionChanged()
                case "shapeSnap": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                case "edge": UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                case "open", "squeeze": UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                case "erase": UIImpactFeedbackGenerator(style: .light).impactOccurred()
                default: break
                }
            }
        case "ink":
            if let json = m.body as? String {
                file.saveInkJSON(json)
            } else if let obj = m.body as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: obj),
                      let json = String(data: data, encoding: .utf8) {
                file.saveInkJSON(json)
            }
        case "audio":
            if let d = m.body as? [String: Any] {
                if (d["action"] as? String) == "speakSummary", let summaryText = d["text"] as? String, !summaryText.isEmpty {
                    if speechSynthesizer.isSpeaking { speechSynthesizer.stopSpeaking(at: .immediate) }
                    let utterance = AVSpeechUtterance(string: summaryText)
                    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                    speechSynthesizer.speak(utterance)
                }
                onAudioAction?(d)
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
        if saveTimer == nil, let p = file.note?.path, let now = coordinatedRead(p), now != file.base {
            flushAndSave()
            if lastPosted == nil { if let shown = file.save(file.base) { call("setText(\(jsLiteral(shown)))") } }
        }
        if let inkPath = file.inkNote?.path, let remoteInk = coordinatedRead(inkPath), !remoteInk.isEmpty, remoteInk != file.lastInk {
            call("mergeInk(\(jsLiteral(remoteInk)))") { [weak self] merged in
                guard let self = self,
                      let obj = merged,
                      let data = try? JSONSerialization.data(withJSONObject: obj),
                      let json = String(data: data, encoding: .utf8) else { return }
                self.file.saveInkJSON(json)
            }
        }
    }

    func step(_ delta: Int) {
        call("step(\(delta))") { v in
            if (v as? String) == "bounce" { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
    }

    func handlePencilAction(_ action: String) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        call("onPencilAction(\(jsLiteral(action)))")
    }

    func setAudioTranscript(_ json: String) { call("setAudioTranscript(\(jsLiteral(json)))") }
    func updateAudioTime(_ sec: Double) { call("updateAudioTime(\(sec))") }
    func executeVoiceCommand(_ phrase: String) { call("voiceCommand(\(jsLiteral(phrase)))") }

    func stop() { pollTimer?.invalidate(); flushAndSave() }
}

/// A Swift string as a JavaScript string literal.
func jsLiteral(_ s: String) -> String {
    let d = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
    return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
}

// MARK: Pencil

/// The unified whiteboard web view, with Apple Pencil Pro squeeze and double-tap wired directly to the inline ink layer.
struct EditorSurface: UIViewRepresentable {
    let web: WKWebView
    let onPencilAction: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPencilAction) }

    func makeUIView(context: Context) -> WKWebView {
        let i = UIPencilInteraction(delegate: context.coordinator)
        web.addInteraction(i)
        return web
    }
    func updateUIView(_ v: WKWebView, context: Context) { context.coordinator.onPencilAction = onPencilAction }

    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        var onPencilAction: (String) -> Void
        init(_ f: @escaping (String) -> Void) { onPencilAction = f }
        func pencilInteraction(_ i: UIPencilInteraction, didReceiveSqueeze s: UIPencilInteraction.Squeeze) {
            if s.phase == .ended { onPencilAction("squeeze") }
        }
        func pencilInteraction(_ i: UIPencilInteraction, didReceiveTap t: UIPencilInteraction.Tap) {
            onPencilAction("doubleTap")
        }
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
            Image(systemName: "square.and.pencil").font(.system(size: 52, weight: .light)).foregroundStyle(Theme.accent)
            Text("Choose your Obsidian vault folder once. Draftpad opens draftpad.md in it, the same file as the Mac.")
                .font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            Button("Choose the vault folder") { picking = true }.buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .recenseScreen("Draftpad")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
            if case .success(let u) = r { file.choose(u) }
        }
    }
}

struct DraftpadEditor: View {
    @ObservedObject var file: DraftpadFile
    @StateObject private var editor: DraftpadWebBox
    @Environment(\.scenePhase) private var phase

    init(file: DraftpadFile) {
        self.file = file
        _editor = StateObject(wrappedValue: DraftpadWebBox(file: file))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            EditorSurface(web: editor.web.web) { action in
                editor.web.handlePencilAction(action)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: phase) { _, p in if p != .active { editor.web.flushAndSave() } }
        .onDisappear { editor.web.stop() }
    }
}

/// Holds the editor for the life of the screen.
final class DraftpadWebBox: ObservableObject {
    let web: DraftpadWeb
    init(file: DraftpadFile) { web = DraftpadWeb(file: file) }
}
