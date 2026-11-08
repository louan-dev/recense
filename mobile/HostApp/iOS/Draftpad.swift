// Draftpad on iPad and iPhone: the same editor as the Mac (editor/dist/editor.html, bundled), on the same
// draftpad.md and draftpad.ink.json in the Obsidian vault, saved through the same 3-way merge (strip/notesync.swift),
// so an edit from the Mac or from Obsidian is merged, never overwritten. Embeds load through the same recense-file:
// scheme (strip/embedfiles.swift): vault files directly, web files from a cache, so they open offline after the first time.
//
// Whiteboard & Apple Pencil Pro:
// - Type and write with an Apple Pencil Pro on the same surface with no mode switch and no Done button.
// - Ink sits on the words and moves with them, stored as plain JSON anchored to lines of text in draftpad.ink.json.
// - Squeeze or double-tap on Apple Pencil Pro wakes the ink palette under its pill (again: puts it to sleep), with
//   Freeform-grade haptics. A swipe in from the left or right screen edge brings out that wing.
import SwiftUI
import ShowsKit
import WebKit
import AVFoundation
import EventKit
import NaturalLanguage
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
    var eventsNote: URL? { vault?.appendingPathComponent("draftpad.events.json") }
    var wingsNote: URL? { vault?.appendingPathComponent("draftpad.wings.json") }

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
    private let eventStore = EKEventStore()
    private var syncedEventIds = Set<String>()
    var onAudioAction: (([String: Any]) -> Void)?

    init(file: DraftpadFile) {
        self.file = file
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        if let v = file.vault {
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("embeds")
            let f = EmbedFiles(vault: v, cache: cache)
            cfg.setURLSchemeHandler(f, forURLScheme: "recense-file")
            files = f
        }
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        for name in ["editor", "link", "ui", "ink", "audio", "calendar", "wings"] {
            cfg.userContentController.add(Weak(self), name: name)
        }
        if let p = file.eventsNote?.path,
           let raw = coordinatedRead(p),
           let data = raw.data(using: .utf8),
           let ids = try? JSONSerialization.jsonObject(with: data) as? [String] {
            syncedEventIds = Set(ids)
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
        if let wp = file.wingsNote?.path, let wingsJSON = coordinatedRead(wp), !wingsJSON.isEmpty {
            call("setWingsState(\(jsLiteral(wingsJSON)))")
        }
        call("setCalendarAdded(\(jsLiteral(syncedEventIdsJSON)))")
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
            // Handwriting to read for Find (shared/inkocr.swift): one group of strokes, as a PNG.
            if let d = m.body as? [String: Any], let o = d["inkOCR"] as? [String: Any],
               let id = o["id"] as? String, let png = o["png"] as? String {
                InkOCR.read(pngBase64: png) { [weak self] text in self?.call("setInkText(\(jsLiteral(id)), \(jsLiteral(text)))") }
                return
            }
            // The ink palette's eyedropper: the system colour picker (its eyedropper samples anything on screen).
            if let d = m.body as? [String: Any], d["sampleColor"] as? Bool == true { pickColor(); return }
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
                    speak(summaryText)
                }
                onAudioAction?(d)
            }
        case "calendar":
            if let d = m.body as? [String: Any],
               (d["action"] as? String) == "addEvents",
               let items = d["events"] as? [[String: Any]] {
                saveEvents(items)
            }
        case "wings":
            guard let wp = file.wingsNote?.path else { return }
            if let json = m.body as? String {
                coordinatedWrite(json, to: wp)
            } else if let d = m.body as? [String: Any],
                      (d["action"] as? String) == "saveState",
                      let state = d["state"] {
                // wings.js posts the state already as a JSON string; data(withJSONObject:) on a String throws an
                // Objective-C exception that try? can't catch, so moving a card crashed the app. An object is accepted too.
                let json = (state as? String) ?? (JSONSerialization.isValidJSONObject(state)
                    ? (try? JSONSerialization.data(withJSONObject: state)).flatMap { String(data: $0, encoding: .utf8) } : nil)
                if let json = json { coordinatedWrite(json, to: wp) }
            }
        default:
            guard let s = m.body as? String else { return }
            lastPosted = s
            saveTimer?.invalidate()
            saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in self?.saveNow() }
        }
    }

    /// The page's dates come from JavaScript's toISOString(), which always has milliseconds ("…T21:00:00.000Z").
    /// ISO8601DateFormatter's default options return nil for those, so every save failed silently (E2 review).
    private static let isoDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func pageDate(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        return isoDate.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Saves the events the owner confirmed in the Agenda card (never on its own), and reports each one back to the
    /// page: saved, or the reason in words. An id counts as saved only after EventKit accepted it.
    private func saveEvents(_ items: [[String: Any]]) {
        eventStore.requestWriteOnlyAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                for item in items {
                    guard let id = item["id"] as? String else { continue }
                    if self.syncedEventIds.contains(id) { self.reportCalendar(id, true, ""); continue }
                    guard granted else { self.reportCalendar(id, false, "Calendar access is off (Settings > Privacy & Security > Calendars > Recense)"); continue }
                    guard let cal = self.eventStore.defaultCalendarForNewEvents else {
                        self.reportCalendar(id, false, "no default calendar"); continue
                    }
                    guard let title = item["title"] as? String, !title.isEmpty,
                          let start = DraftpadWeb.pageDate(item["startISO"] as? String) else {
                        self.reportCalendar(id, false, "couldn't read the date"); continue
                    }
                    let ev = EKEvent(eventStore: self.eventStore)
                    ev.calendar = cal
                    ev.title = title
                    ev.startDate = start
                    ev.endDate = DraftpadWeb.pageDate(item["endISO"] as? String) ?? start.addingTimeInterval(3600)
                    ev.isAllDay = (item["allDay"] as? Bool) == true
                    ev.notes = item["rawLine"] as? String
                    do {
                        try self.eventStore.save(ev, span: .thisEvent)
                        self.syncedEventIds.insert(id)
                        self.persistSyncedEventIds()
                        self.reportCalendar(id, true, "")
                    } catch {
                        self.reportCalendar(id, false, error.localizedDescription)
                    }
                }
            }
        }
    }

    private var syncedEventIdsJSON: String {
        guard let data = try? JSONSerialization.data(withJSONObject: Array(syncedEventIds).sorted()),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private func persistSyncedEventIds() {
        let json = syncedEventIdsJSON
        if let p = file.eventsNote?.path { coordinatedWrite(json, to: p) }
    }

    private func reportCalendar(_ id: String, _ ok: Bool, _ message: String) {
        call("calendarResult(\(jsLiteral(id)), \(ok), \(jsLiteral(message)))")
    }

    /// Speaks in the text's own language with the best installed voice for it (E2 review #6). Every utterance goes
    /// through here, so a neural voice can replace the system ones in one place later.
    func speak(_ text: String) {
        if speechSynthesizer.isSpeaking { speechSynthesizer.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.voice = DraftpadWeb.bestVoice(for: text)
        speechSynthesizer.speak(u)
    }

    static func bestVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let lang = r.dominantLanguage?.rawValue else { return nil }
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: lang)
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

    /// A swipe in from the screen's left or right edge brings that wing out (owner, 11-08: the edge swipe, not a hold).
    func openWing(_ side: String) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        call("openWing(\(jsLiteral(side)))")
    }

    func setAudioTranscript(_ json: String) { call("setAudioTranscript(\(jsLiteral(json)))") }

    private var colorDelegate: ColorPick?
    /// Opens the system colour picker over the page; the colour chosen replaces the palette's selected one.
    func pickColor() {
        guard let top = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController
        else { return }
        var shown = top
        while let p = shown.presentedViewController { shown = p }
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        let d = ColorPick { [weak self] c in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            let hex = String(format: "#%02x%02x%02x", Int((min(max(r, 0), 1) * 255).rounded()),
                             Int((min(max(g, 0), 1) * 255).rounded()), Int((min(max(b, 0), 1) * 255).rounded()))
            self?.call("setPickedColor(\(jsLiteral(hex)))")
        }
        colorDelegate = d
        picker.delegate = d
        shown.present(picker, animated: true)
    }
    func updateAudioTime(_ sec: Double) { call("updateAudioTime(\(sec))") }
    func executeVoiceCommand(_ phrase: String) { call("voiceCommand(\(jsLiteral(phrase)))") }

    func stop() { pollTimer?.invalidate(); flushAndSave() }
}

/// Reports the colour once the picker closes (one pick, not every drag of its sliders).
final class ColorPick: NSObject, UIColorPickerViewControllerDelegate {
    let done: (UIColor) -> Void
    init(_ f: @escaping (UIColor) -> Void) { done = f }
    func colorPickerViewControllerDidFinish(_ p: UIColorPickerViewController) { done(p.selectedColor) }
}

/// A Swift string as a JavaScript string literal.
func jsLiteral(_ s: String) -> String {
    let d = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
    return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
}

// MARK: Pencil

/// The unified whiteboard web view, with Apple Pencil Pro squeeze and double-tap wired directly to the inline ink layer
/// (they wake the ink palette), and a swipe in from either screen edge opening that side's wing. The edge swipes are
/// native screen-edge recognizers, so they win over the web page's scrolling and paging.
struct EditorSurface: UIViewRepresentable {
    let web: WKWebView
    var onEdge: (String) -> Void = { _ in }
    let onPencilAction: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPencilAction, onEdge) }

    func makeUIView(context: Context) -> WKWebView {
        let i = UIPencilInteraction(delegate: context.coordinator)
        web.addInteraction(i)
        for edge in [UIRectEdge.left, .right] {
            let g = UIScreenEdgePanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.edgePan(_:)))
            g.edges = edge
            g.delegate = context.coordinator
            web.addGestureRecognizer(g)
        }
        return web
    }
    func updateUIView(_ v: WKWebView, context: Context) {
        context.coordinator.onPencilAction = onPencilAction
        context.coordinator.onEdge = onEdge
    }

    final class Coordinator: NSObject, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
        var onPencilAction: (String) -> Void
        var onEdge: (String) -> Void
        private var fired = false
        init(_ f: @escaping (String) -> Void, _ e: @escaping (String) -> Void) { onPencilAction = f; onEdge = e }
        /// One wing per swipe, once the finger has come 40 pt in from the edge.
        @objc func edgePan(_ g: UIScreenEdgePanGestureRecognizer) {
            switch g.state {
            case .began: fired = false
            case .changed:
                let dx = g.translation(in: g.view).x
                if !fired, g.edges == .left ? dx > 40 : dx < -40 { fired = true; onEdge(g.edges == .left ? "left" : "right") }
            default: break
            }
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { false }
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
            EditorSurface(web: editor.web.web, onEdge: { editor.web.openWing($0) }) { action in
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
