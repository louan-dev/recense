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
/// The load and save rules are shared with the Mac (shared/draftpadfile.swift, BUG-29); this class holds the vault.
final class DraftpadFile: ObservableObject {
    static let key = "draftpadVaultBookmark"
    @Published private(set) var vault: URL? { didSet { open() } }
    private(set) var noteFile: DraftpadNote?   // draftpad.md: load, save, the merge's base (T-0114, BUG-29)
    private(set) var ink: DraftpadInk?         // draftpad.ink.json: never written over strokes not read here (T-0125)
    var base: String { noteFile?.base ?? "" }
    var pending: Bool { noteFile?.pending ?? false }
    var note: URL? { vault?.appendingPathComponent("draftpad.md") }
    var inkNote: URL? { vault?.appendingPathComponent("draftpad.ink.json") }
    /// FEAT-08 · the sidecar of the one page (seeds, linked forms, crossings log; editor/src/matter.js).
    var matterNote: URL? { vault?.appendingPathComponent("draftpad.matter.json") }
    private(set) var lastMatter = ""    // what this device last read or wrote for draftpad.matter.json
    var eventsNote: URL? { vault?.appendingPathComponent("draftpad.events.json") }
    var wingsNote: URL? { vault?.appendingPathComponent("draftpad.wings.json") }

    init() {
        guard let d = UserDefaults.standard.data(forKey: Self.key) else { return }
        var stale = false
        if let u = try? URL(resolvingBookmarkData: d, bookmarkDataIsStale: &stale), u.startAccessingSecurityScopedResource() {
            vault = u
            if stale, let fresh = try? u.bookmarkData() { UserDefaults.standard.set(fresh, forKey: Self.key) }
        }
        open()   // didSet does not run inside init
    }

    // What was typed while the note could not be read or written is kept on this device, one file per launch
    // (DraftpadNote, Unsaved).
    private let launch = Date()
    static var unsavedFolder: URL { DraftpadNote.unsavedFolder }   // also used by AddToDraftpadIntent (FEAT-08)

    private func open() {
        guard let n = note, let i = inkNote else { noteFile = nil; ink = nil; return }
        let f = DraftpadNote(path: n.path, launch: launch)
        f.say = { log($0) }
        noteFile = f
        ink = DraftpadInk(path: i.path)
    }

    func choose(_ folder: URL) {
        guard folder.startAccessingSecurityScopedResource() else { return }
        if let d = try? folder.bookmarkData() { UserDefaults.standard.set(d, forKey: Self.key) }
        vault = folder
    }

    /// The file as it is now; it becomes the base (DraftpadNote.load: an unreadable note is never a blank one).
    func load() -> String { noteFile?.load() ?? "" }

    /// The ink sidecar for the page: "" when there is none yet, nil when it can't be read now (T-0125).
    func loadInk() -> String? { ink?.load() }

    /// FEAT-08 · coded, not compiled; device check owed.
    func loadMatter() -> String {
        guard let p = matterNote?.path else { return "" }
        let s = coordinatedRead(p) ?? ""
        lastMatter = s
        return s
    }

    /// The file on disk was seen (handed to the page to merge); the next write of the union goes ahead.
    func sawMatter(_ disk: String) { lastMatter = disk }

    func saveMatterJSON(_ json: String) {
        guard let p = matterNote?.path, !json.isEmpty, json != lastMatter else { return }
        coordinatedWrite(json, to: p)
        lastMatter = json
    }

    /// Saves `mine` (DraftpadNote.save, shared with the Mac). Returns the text the editor should show when that differs
    /// from `mine` (a merge, or a newer file adopted), else nil.
    func save(_ mine: String) -> String? { noteFile?.save(mine) }
}

// MARK: The editor

final class DraftpadWeb: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// BUG-31: set by EditorSurface; turns the screen-edge recognizers off while an ink tool is chosen.
    var onPagesLocked: ((Bool) -> Void)?
    let web: WKWebView
    let file: DraftpadFile
    // UI-04 P3: held so the Pencil haptic isn't dropped with a generator freed mid-play.
    private var canvasHaptic: AnyObject?
    private var files: EmbedFiles?
    private var loaded = false
    private var saveTimer: Timer?
    private var pollTimer: Timer?
    private var lastPosted: String?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let voice = ReadAloud()   // playlists and the Recensed view (shared/draftpadlibrary.swift)
    private let eventStore = EKEventStore()
    private var syncedEventIds = Set<String>()
    var onAudioAction: (([String: Any]) -> Void)?
    /// FEAT-23 · the media note shown instead of draftpad.md, or nil; and the open note was emptied (A1 rule 3).
    private(set) var openNoteKey: String?
    var onNoteEmptied: (() -> Void)?
    /// keep/ on this device: Documents/Recense/keep. Carry brings note.md from other devices (main 8935ad0), so writes go
    /// through MediaNoteFiles' base check, never blind.
    static var keep: URL { Homes.root.appendingPathComponent("keep", isDirectory: true) }

    // Derived from Spec: FEAT-23 P0 (glue only; the rules are editor/src/medianote.js)
    /// Shows item `key`'s note in this one editor instead of draftpad.md (rule 3). False when the key is not one, the
    /// page is not loaded, or a note file cannot be read now (a note is never shown blank over its words).
    @discardableResult
    func openNote(key: String, title: String = "", trigger: String = "note-button", layout: String = "note") -> Bool {
        if openNoteKey == key { return true }   // review 12: already shown; no swap, no reload
        guard loaded, let payload = MediaNoteFiles.payload(key: key, keep: Self.keep, title: title, trigger: trigger, layout: layout) else {
            log("note \(key.prefix(8))… not opened")
            return false
        }
        openNoteKey = key
        call("openNote(\(jsLiteral(key)), \(jsLiteral(payload)))")
        return true
    }

    /// Puts draftpad.md back; the page flushes the note first.
    func closeNote() {
        guard openNoteKey != nil else { return }
        openNoteKey = nil
        call("closeNote()")
    }

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
        for name in ["editor", "link", "ui", "ink", "matter", "note", "audio", "calendar", "wings"] {
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
        // UI-07 · the editor picks its own font and box per device and orientation (editor/src/devicelayout.js).
        call("setText(\(jsLiteral(file.load())))")
        if let initialInk = file.loadInk(), !initialInk.isEmpty {   // nil: unreadable now; the poll merges it once it reads
            call("setInk(\(jsLiteral(initialInk)))")
        }
        let initialMatter = file.loadMatter()
        if !initialMatter.isEmpty { call("setMatter(\(jsLiteral(initialMatter)))") }   // FEAT-08
        // Derived from Spec: FEAT-08 P5 — a crossing's device is the carry name ("iPhone", "iPad" without the entitlement).
        call("setMatterDevice(\(jsLiteral(P2PTransport.deviceName())))")
        if let wp = file.wingsNote?.path, let wingsJSON = coordinatedRead(wp), !wingsJSON.isEmpty {
            call("setWingsState(\(jsLiteral(wingsJSON)))")
        }
        call("setCalendarAdded(\(jsLiteral(syncedEventIdsJSON)))")
        for c in DraftpadLibrary.loadCalls(vault: file.vault, quote: jsLiteral) { call(c) }
        call("reopen()")   // UI-06 R1: the page you were last on
        // Another device's edit (the Mac, Obsidian) reaches the file through iCloud: merge it in while open.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.pollExternal() }
    }

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(["file", "about", "", "recense-file"].contains(a.request.url?.scheme ?? "") ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { loaded = false; openNoteKey = nil; w.reload() }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        switch m.name {
        case "link":
            if let s = m.body as? String, let u = URL(string: s), ["https", "http", "mailto"].contains(u.scheme ?? "") {
                UIApplication.shared.open(u)
            }
        case "ui":
            if (m.body as? String) == "bounce" { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(); return }
            // Recense what you typed (shared/recensetext.swift): lenses, translations, Recensed/<id>.json, power.
            if let d = m.body as? [String: Any],
               RecenseText.handle(d, vault: file.vault, js: { [weak self] in self?.call($0) }, quote: jsLiteral) { return }
            // Page library: playlists file, expired pages to the archive, read-aloud (shared/draftpadlibrary.swift).
            if let d = m.body as? [String: Any],
               DraftpadLibrary.handle(d, vault: file.vault, voice: voice, js: { [weak self] in self?.call($0) }, quote: jsLiteral) { return }
            // Handwriting to read for Find (shared/inkocr.swift): one group of strokes, as a PNG.
            if let d = m.body as? [String: Any], let o = d["inkOCR"] as? [String: Any],
               let id = o["id"] as? String, let png = o["png"] as? String {
                InkOCR.read(pngBase64: png) { [weak self] text in self?.call("setInkText(\(jsLiteral(id)), \(jsLiteral(text)))") }
                return
            }
            // The ink palette's eyedropper: the system colour picker (its eyedropper samples anything on screen).
            if let d = m.body as? [String: Any], d["sampleColor"] as? Bool == true { pickColor(); return }
            // Derived from Spec: BUG-31 — an ink tool is chosen: the edge swipes hold still (the page bar's wing button stays).
            if let d = m.body as? [String: Any], let locked = d["pagesLocked"] as? Bool { onPagesLocked?(locked); return }
            if let d = m.body as? [String: Any], let kind = d["haptic"] as? String {
                switch kind {
                case "snap": UISelectionFeedbackGenerator().selectionChanged()
                // UI-04 P3: the Pencil Pro's own haptic where the nib lifted (iOS 17.5+); else the old tap.
                // Coded, not compiled here (no Swift toolchain in the lane); device check owed.
                case "shapeSnap":
                    if #available(iOS 17.5, *), let x = (d["x"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue {
                        let g = (canvasHaptic as? UICanvasFeedbackGenerator) ?? UICanvasFeedbackGenerator(view: web)
                        canvasHaptic = g
                        g.pathCompleted(at: CGPoint(x: x, y: y))
                    } else {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                case "edge": UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                case "open", "squeeze": UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                case "erase": UIImpactFeedbackGenerator(style: .light).impactOccurred()
                default: break
                }
            }
        case "ink":
            if let json = DraftpadInk.json(from: m.body) { saveInk(json) }
        case "matter":   // FEAT-08
            guard let json = m.body as? String else { break }
            guard let mp = file.matterNote?.path else { break }
            switch MatterWrite.plan(json: json, disk: readNote(mp), seen: file.lastMatter) {
            case .mergeFirst(let disk):
                file.sawMatter(disk)
                call("mergeMatter(\(jsLiteral(disk)))")   // the page unions it and posts the union back here
            case .write: file.saveMatterJSON(json)
            case .wait: log("draftpad.matter.json can't be read now; nothing written over it (T-0176)")
            }
        case "note":   // FEAT-23 · keep/<key>/note.md and its sidecars (shared/medianotefiles.swift)
            if let d = m.body as? [String: Any] {
                let r = MediaNoteFiles.handle(d, keep: Self.keep, trashFallback: Homes.url(.trash), unsaved: DraftpadNote.unsavedFolder)
                if r.hasPrefix("could not") || r.hasPrefix("trashed") { log("note \(r)") }
                if (d["action"] as? String) == "trash", (d["key"] as? String) == openNoteKey { onNoteEmptied?() }
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
            // "Don't add" in the calendar sheet: kept as "x:<id>" in the same file, so no device asks again.
            if let d = m.body as? [String: Any], (d["action"] as? String) == "dismiss", let ids = d["ids"] as? [String] {
                reloadSyncedEventIds()
                syncedEventIds.formUnion(ids.map { "x:" + $0 })
                persistSyncedEventIds()
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
                    ev.notes = (item["notes"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? item["rawLine"] as? String
                    if let place = item["location"] as? String, !place.isEmpty { ev.location = place }
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

    /// The Mac (or another device) may have added or refused one meanwhile: merge the file in before writing it.
    private func reloadSyncedEventIds() {
        if let p = file.eventsNote?.path, let raw = coordinatedRead(p), let data = raw.data(using: .utf8),
           let ids = try? JSONSerialization.jsonObject(with: data) as? [String] {
            syncedEventIds.formUnion(ids)
        }
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
        u.voice = bestVoice(lang: nil, text: text)
        speechSynthesizer.speak(u)
    }

    /// Runs `work` inside a background task, so leaving the app never cuts a save short (BUG-29); `work` calls `done`.
    private static func keepAlive(_ work: (@escaping () -> Void) -> Void) {
        var id = UIBackgroundTaskIdentifier.invalid
        let done = { if id != .invalid { UIApplication.shared.endBackgroundTask(id); id = .invalid } }
        id = UIApplication.shared.beginBackgroundTask(withName: "Draftpad save", expirationHandler: done)
        work(done)
    }

    func saveNow() {
        saveTimer?.invalidate(); saveTimer = nil
        guard let mine = lastPosted else { return }
        Self.keepAlive { done in
            if let shown = file.save(mine) { call("setText(\(jsLiteral(shown)))") }
            done()
        }
        if Listener.shared.on { Listener.shared.noteSaved() }   // T-0043
    }

    /// The page's text right now (skipping its 300 ms debounce), then a save; used before leaving and on a poll.
    func flushAndSave() {
        Self.keepAlive { done in
            call("getText()") { [weak self] v in
                defer { done() }
                guard let self = self else { return }
                if let s = v as? String { self.lastPosted = s }
                self.saveNow()
            }
        }
    }

    /// One ink post (T-0125): written, or the file's strokes not seen here merged into the page first, then the union saved.
    private func saveInk(_ json: String) {
        guard let ink = file.ink, case .mergeFirst(let disk) = ink.save(json) else { return }
        mergeInk(disk)
    }

    private func mergeInk(_ disk: String) {
        // a merge that doesn't come back (page not loaded, no ink layer, the call failed) leaves the file unseen, so the
        // next post merges it again instead of writing over it (BUG-29 review 1); `call` answers nil when not loaded
        call("mergeInk(\(jsLiteral(disk)))") { [weak self] merged in
            guard let self = self else { return }
            if let json = DraftpadInk.json(from: merged) { self.saveInk(json) } else { self.file.ink?.unsee() }
        }
    }

    // The poll reads the files off the main thread (a coordinated read can wait on iCloud); the decisions stay on main.
    private let pollQueue = DispatchQueue(label: "draftpad.poll", qos: .utility)
    private var polling = false

    private func pollExternal() {
        guard !polling else { return }
        polling = true
        let np = file.note?.path, ip = file.inkNote?.path, mp = file.matterNote?.path
        pollQueue.async { [weak self] in
            let note = np.flatMap { coordinatedRead($0) }
            let ink = ip.map { readNote($0) }
            let matter = mp.flatMap { coordinatedRead($0) }
            DispatchQueue.main.async { self?.polled(note: note, ink: ink, matter: matter) }
        }
    }

    private func polled(note now: String?, ink: NoteRead?, matter remote: String?) {
        polling = false
        MediaNoteFiles.retry(keep: Self.keep, unsaved: DraftpadNote.unsavedFolder, device: Homes.device)   // FEAT-23: parked note words
        if saveTimer == nil, file.pending { flushAndSave() }   // T-0114: a save that couldn't reach the file is tried again
        if saveTimer == nil, let now = now, now != file.base {
            flushAndSave()
            if lastPosted == nil { if let shown = file.save(file.base) { call("setText(\(jsLiteral(shown)))") } }
        }
        if let i = file.ink {
            if i.waiting != nil {   // T-0125: a post the sidecar couldn't take yet
                if case .mergeFirst(let d)? = i.retry() { mergeInk(d) }
            } else if case .text(let r)? = ink, !r.isEmpty, r != i.seen {   // another device's strokes: union them in
                i.saw(r)
                mergeInk(r)
            }
        }
        // FEAT-08 · another device's sidecar: union it (src/matter.js mergeMatter), keep the result.
        if let remote = remote, !remote.isEmpty, remote != file.lastMatter {
            call("mergeMatter(\(jsLiteral(remote)))") { [weak self] merged in
                if let json = merged as? String { self?.file.saveMatterJSON(json) }
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

    // Derived from Spec: UI-04 P1 — every squeeze phase goes to the editor with the hover point; the editor
    // times the 250 ms tap/hold split and plays the haptic, so no impact here.
    func handleSqueeze(_ phase: String, at p: CGPoint) {
        call("onPencilSqueeze(\(jsLiteral(phase)), \(Double(p.x)), \(Double(p.y)))")
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
    var onSqueeze: (String, CGPoint) -> Void = { _, _ in }
    let onPencilAction: (String) -> Void
    var registerLock: (@escaping (Bool) -> Void) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onPencilAction, onEdge, onSqueeze) }

    func makeUIView(context: Context) -> WKWebView {
        let i = UIPencilInteraction(delegate: context.coordinator)
        web.addInteraction(i)
        for edge in [UIRectEdge.left, .right] {
            let g = UIScreenEdgePanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.edgePan(_:)))
            g.edges = edge
            g.delegate = context.coordinator
            web.addGestureRecognizer(g)
            context.coordinator.edgeGestures.append(g)
        }
        let c = context.coordinator
        registerLock { locked in c.edgeGestures.forEach { $0.isEnabled = !locked } }
        return web
    }
    func updateUIView(_ v: WKWebView, context: Context) {
        context.coordinator.onPencilAction = onPencilAction
        context.coordinator.onEdge = onEdge
        context.coordinator.onSqueeze = onSqueeze
    }

    final class Coordinator: NSObject, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
        var onPencilAction: (String) -> Void
        var onEdge: (String) -> Void
        var onSqueeze: (String, CGPoint) -> Void
        private var fired = false
        var edgeGestures: [UIScreenEdgePanGestureRecognizer] = []
        init(_ f: @escaping (String) -> Void, _ e: @escaping (String) -> Void, _ q: @escaping (String, CGPoint) -> Void) {
            onPencilAction = f; onEdge = e; onSqueeze = q
        }
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
            // Derived from Spec: UI-04 P1 — respect the system's squeeze setting; forward every phase.
            if UIPencilInteraction.preferredSqueezeAction == .ignore { return }
            let name: String
            switch s.phase {
            case .began: name = "began"
            case .changed: name = "changed"
            case .ended: name = "ended"
            case .cancelled: name = "cancelled"
            @unknown default: return
            }
            onSqueeze(name, s.hoverPose?.location ?? .zero)
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
            EditorSurface(web: editor.web.web, onEdge: { editor.web.openWing($0) },
                          onSqueeze: { editor.web.handleSqueeze($0, at: $1) },
                          onPencilAction: { editor.web.handlePencilAction($0) },
                          registerLock: { editor.web.onPagesLocked = $0 })
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
