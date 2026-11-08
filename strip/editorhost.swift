import AppKit
import WebKit
import AVFoundation
import EventKit
import NaturalLanguage

// The new editor in the pad layer (D13, D33): a WKWebView running the CodeMirror core, editor/dist/editor.html,
// copied into the bundle by build.sh. It speaks the bridge in .handoff/editor/INBOX.md (bar 8):
//   native → page: window.recenseEditor.setText(s), getText(), focus(), setTheme('dark'|'light'), setFontSize(px)
//   page → native: window.webkit.messageHandlers.editor.postMessage(fullText), debounced 300 ms
// The page never touches the file. Native keeps it: every save goes through App.saveNow → notesync.swift
// (coordinated write and 3-way merge), the same path as the classic pad.
// Until the core lands, a small stand-in page with the same bridge runs instead, so the wiring and sync can be tested.

/// Which pad the top layer shows. Classic stays the default until the owner tries the new one.
enum EditorKind: String { case classic, new }
var editorKind: EditorKind {
    get { EditorKind(rawValue: UserDefaults.standard.string(forKey: "editor") ?? "") ?? .classic }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "editor") }
}

// D4, safe version: new pages go on top of draftpad.md, with no pass that reorders the file. The classic strip
// shows the file's pages bottom-up, so a page it adds at its newest end lands at the top of the file.
func stripPages(_ file: String) -> [String] { Array(parsePages(file).reversed()) }
func fileText(_ stripPages: [String]) -> String { stripPages.reversed().joined(separator: pageJoiner) }
/// A new dated page on top of the file, for the new editor.
func withNewPageOnTop(_ file: String, _ d: Date = Date()) -> String {
    file.isEmpty ? dateStamp(d) + "\n\n" : dateStamp(d) + "\n\n" + pageJoiner + file
}

/// The date a page opens with ("Friday, November 6, 2026"), or nil for an undated page.
func pageDate(_ page: String) -> Date? {
    guard let first = page.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    else { return nil }
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEEE, MMMM d, yyyy"
    return f.date(from: first.trimmingCharacters(in: .whitespaces))
}

/// The one-time flip (owner, 11-06): the file becomes newest-first, so new text on top agrees with every app.
/// The pages written on top under D4 stay first. From the first dated page that something later is newer than,
/// the rest is grouped (a dated page plus the undated pages after it) and the groups are reversed. Nothing inside a
/// page changes and no page is lost; a file that is already newest-first comes back unchanged.
func newestFirst(_ file: String) -> String {
    let pages = parsePages(file)
    let dates = pages.map(pageDate)
    guard let start = dates.indices.first(where: { i in
        guard let d = dates[i] else { return false }
        return dates[(i + 1)...].contains { $0.map { $0 > d } ?? false }
    }) else { return file }
    var groups: [[String]] = []
    for i in start..<pages.count {
        if dates[i] != nil || groups.isEmpty { groups.append([pages[i]]) } else { groups[groups.count - 1].append(pages[i]) }
    }
    return (Array(pages[..<start]) + groups.reversed().flatMap { $0 }).joined(separator: pageJoiner)
}

/// A Swift string as a JavaScript string literal.
func jsString(_ s: String) -> String {
    let d = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
    return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
}

/// WKUserContentController keeps its handlers strongly; this proxy keeps the host collectable.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

/// Adds the pad's own entries to the right-click menu, so every action is reachable without a shortcut.
final class EditorWebView: WKWebView {
    var extraItems: () -> [NSMenuItem] = { [] }
    /// A wing panel's page acts on the first click, though its panel isn't key (wingpanels.swift).
    var clickThrough = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { clickThrough || super.acceptsFirstMouse(for: event) }
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        menu.addItem(.separator())
        extraItems().forEach { menu.addItem($0) }
    }
}

final class EditorHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let web: EditorWebView
    let vault: URL
    var inkPath: String { vault.appendingPathComponent("draftpad.ink.json").path }
    var eventsPath: String { vault.appendingPathComponent("draftpad.events.json").path }
    var wingsPath: String { vault.appendingPathComponent("draftpad.wings.json").path }
    /// The editor's text as last posted by the page or set by native: what a save writes.
    private(set) var text = ""
    private var loaded = false
    /// Called on the main thread with the full text after each (debounced) change in the page.
    var onChange: ((String) -> Void)?
    /// Called when the transcript sidecar posts a seek, bookmark, or annotation action.
    var onAudioAction: (([String: Any]) -> Void)?
    /// Where the page came from, for the log: the CodeMirror core, or the stand-in.
    private(set) var source = ""
    private let speechSynthesizer = AVSpeechSynthesizer()
    /// macOS's own iPhone Mirroring app (macOS 15+), opened from its wing card.
    static let iPhoneMirroring = URL(fileURLWithPath: "/System/Applications/iPhone Mirroring.app")
    private let eventStore = EKEventStore()
    private var syncedEventIds = Set<String>()

    /// The page bounced at its first or last page (the host plays the strip's bounce).
    var onBounce: (() -> Void)?
    let files: EmbedFiles
    /// nil for the editor; "left" or "right" for a wing panel's page (wingpanels.swift): the same bundled page,
    /// showing that one wing.
    let wingSide: String?
    /// The editor page hands its wings to the native panels (set before it loads).
    var nativeWings = false
    /// A page saved the wings' layout and cards (the JSON written to draftpad.wings.json): the other pages follow.
    var onWingsSaved: ((String) -> Void)?
    /// A page asks the host for a wing panel (open / close / toggle), a citation, a jump, or posts its layout.
    var onWingMessage: (([String: Any]) -> Void)?
    /// A calendar event was saved here: the other pages mark it added too.
    var onEventsSaved: (() -> Void)?
    /// The page finished loading (and has its text, wings state and calendar ids).
    var onLoad: (() -> Void)?

    init(frame: NSRect, vault: URL, cache: URL, wingSide: String? = nil) {
        self.vault = vault
        self.wingSide = wingSide
        let cfg = WKWebViewConfiguration()
        if let side = wingSide {
            cfg.userContentController.addUserScript(WKUserScript(
                source: "window.__RECENSE_WING_SIDE = \(jsString(side));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        cfg.websiteDataStore = .default()
        files = EmbedFiles(vault: vault, cache: cache)
        cfg.setURLSchemeHandler(files, forURLScheme: "recense-file")
        web = EditorWebView(frame: frame, configuration: cfg)
        super.init()
        for name in ["editor", "link", "ui", "ink", "audio", "calendar", "wings"] {
            cfg.userContentController.add(WeakHandler(self), name: name)
        }
        if let raw = coordinatedRead(eventsPath),
           let data = raw.data(using: .utf8),
           let ids = try? JSONSerialization.jsonObject(with: data) as? [String] {
            syncedEventIds = Set(ids)
        }
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        if let url = EditorHost.pageURL() {
            source = url.path
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            source = "stand-in"
            web.loadHTMLString(standInEditorHTML, baseURL: nil)
        }
    }

    /// RECENSE_EDITOR_HTML (one launch, for testing) or the copy in the bundle.
    static func pageURL() -> URL? {
        let fm = FileManager.default
        if let p = ProcessInfo.processInfo.environment["RECENSE_EDITOR_HTML"], fm.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        if let r = Bundle.main.resourceURL?.appendingPathComponent("editor/editor.html"), fm.fileExists(atPath: r.path) {
            return r
        }
        return nil
    }

    /// Shows `s` in the editor (the page gets it once it has loaded).
    func setText(_ s: String) {
        text = s
        if loaded { call("setText(\(jsString(s)))") }
    }

    func focus() { if loaded { call("focus()") } }

    /// One page deeper (+1) or back toward the top (-1); calls back with false at either end.
    func step(_ delta: Int, _ done: @escaping (Bool) -> Void) {
        guard loaded else { done(false); return }
        web.evaluateJavaScript("window.recenseEditor.step(\(delta))") { v, _ in done((v as? String) == "ok") }
    }

    func showPage(_ i: Int) { if loaded { call("showPage(\(i))") } }
    func setCursor(_ offset: Int) { if loaded { call("setCursor(\(offset))") } }
    func setAudioTranscript(_ json: String) { if loaded { call("setAudioTranscript(\(jsString(json)))") } }
    func updateAudioTime(_ sec: Double) { if loaded { call("updateAudioTime(\(sec))") } }
    func executeVoiceCommand(_ phrase: String) { if loaded { call("voiceCommand(\(jsString(phrase)))") } }

    private var flushing: [(String) -> Void] = []
    /// Asks the page for its text right now (skipping the 300 ms debounce), then calls back with it. One question at a
    /// time; if the page doesn't answer within a second (WebKit can suspend a page that's out of sight), it goes on
    /// with the last text the page posted, so a save is never stuck behind it.
    func flush(_ done: @escaping (String) -> Void) {
        guard loaded else { done(text); return }
        flushing.append(done)
        guard flushing.count == 1 else { return }
        var answered = false
        let finish = { [weak self] (s: String?) in
            guard let self = self, !answered else { return }
            answered = true
            if let s = s { self.text = s } else { log("editor: the page didn't answer; saving its last posted text") }
            let waiting = self.flushing; self.flushing = []
            waiting.forEach { $0(self.text) }
        }
        web.evaluateJavaScript("window.recenseEditor.getText()") { v, _ in finish(v as? String) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(nil) }
    }

    /// Runs `window.recenseEditor.<js>` once the page has loaded (wingpanels.swift).
    func send(_ js: String) { if loaded { call(js) } }
    func applyWingsState(_ json: String) { send("setWingsState(\(jsString(json)))") }
    /// Re-reads the saved event ids (another page may have added one) and shows them as added.
    func refreshCalendarAdded() {
        reloadSyncedEventIds()
        send("setCalendarAdded(\(jsString(syncedEventIdsJSON)))")
    }

    private func call(_ js: String) {
        web.evaluateJavaScript("window.recenseEditor && window.recenseEditor.\(js)") { _, err in
            if let err = err { log("editor: \(js.prefix(20))… failed: \(err.localizedDescription)") }
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if m.name == "link" {
            // ⌘-click on a link: web links open in the default browser; nothing else is opened.
            if let s = m.body as? String, let u = URL(string: s), ["https", "http", "mailto"].contains(u.scheme ?? "") {
                NSWorkspace.shared.open(u)
            }
            return
        }
        if m.name == "ui" {
            if (m.body as? String) == "bounce" { onBounce?(); return }
            // Handwriting to read for Find (shared/inkocr.swift): one group of strokes, as a PNG.
            if let d = m.body as? [String: Any], let o = d["inkOCR"] as? [String: Any],
               let id = o["id"] as? String, let png = o["png"] as? String {
                InkOCR.read(pngBase64: png) { [weak self] text in self?.send("setInkText(\(jsString(id)), \(jsString(text)))") }
                return
            }
            // The ink palette's eyedropper: macOS's own screen sampler; the colour picked replaces the selected one.
            if let d = m.body as? [String: Any], d["sampleColor"] as? Bool == true {
                NSColorSampler().show { [weak self] c in
                    guard let c = c?.usingColorSpace(.sRGB) else { return }
                    let hex = String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()),
                                     Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
                    self?.send("setPickedColor(\(jsString(hex)))")
                }
                return
            }
            if let d = m.body as? [String: Any], let kind = d["haptic"] as? String {
                let p = NSHapticFeedbackManager.defaultPerformer
                switch kind {
                case "snap", "shapeSnap": p.perform(.alignment, performanceTime: .now)
                case "edge": p.perform(.levelChange, performanceTime: .now); onBounce?()
                case "open", "squeeze", "erase": p.perform(.generic, performanceTime: .now)
                default: break
                }
            }
            return
        }
        if m.name == "ink" {
            if let json = m.body as? String {
                coordinatedWrite(json, to: inkPath)
            } else if let obj = m.body as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: obj),
                      let json = String(data: data, encoding: .utf8) {
                coordinatedWrite(json, to: inkPath)
            }
            return
        }
        if m.name == "audio" {
            if let d = m.body as? [String: Any] {
                if (d["action"] as? String) == "speakSummary", let summaryText = d["text"] as? String, !summaryText.isEmpty {
                    speak(summaryText)
                }
                onAudioAction?(d)
            }
            return
        }
        if m.name == "calendar" {
            if let d = m.body as? [String: Any],
               (d["action"] as? String) == "addEvents",
               let items = d["events"] as? [[String: Any]] {
                saveEvents(items)
            }
            return
        }
        if m.name == "wings" {
            if let d = m.body as? [String: Any], (d["action"] as? String) == "openApp",
               (d["app"] as? String) == "iphone-mirroring" {
                NSWorkspace.shared.openApplication(at: EditorHost.iPhoneMirroring, configuration: NSWorkspace.OpenConfiguration()) { _, err in
                    if let err = err { log("editor: iPhone Mirroring didn't open: \(err.localizedDescription)") }
                }
                return
            }
            if let d = m.body as? [String: Any], let a = d["action"] as? String, ["wing", "insert", "jumpToLine", "layout"].contains(a) {
                onWingMessage?(d); return
            }
            if let json = m.body as? String {
                coordinatedWrite(json, to: wingsPath)
                onWingsSaved?(json)
            } else if let d = m.body as? [String: Any] {
                if (d["action"] as? String) == "saveState", let state = d["state"] {
                    // wings.js posts the state already as a JSON string; an object is accepted too.
                    let json = (state as? String) ?? (JSONSerialization.isValidJSONObject(state)
                        ? (try? JSONSerialization.data(withJSONObject: state)).flatMap { String(data: $0, encoding: .utf8) } : nil)
                    if let json = json {
                        coordinatedWrite(json, to: wingsPath)
                        onWingsSaved?(json)
                    }
                }
            }
            return
        }
        // The bridge posts the full text; a {text: …} object is accepted too.
        let s = (m.body as? String) ?? ((m.body as? [String: Any])?["text"] as? String)
        guard let s = s, s != text else { return }
        text = s
        onChange?(s)
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
        eventStore.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.reloadSyncedEventIds()   // another page (a wing panel, the editor) may have saved one meanwhile
                for item in items {
                    guard let id = item["id"] as? String else { continue }
                    if self.syncedEventIds.contains(id) { self.reportCalendar(id, true, ""); continue }
                    guard granted else { self.reportCalendar(id, false, "Calendar access is off (System Settings > Privacy & Security > Calendars > Recense)"); continue }
                    guard let cal = self.eventStore.defaultCalendarForNewEvents else {
                        self.reportCalendar(id, false, "no default calendar"); continue
                    }
                    guard let title = item["title"] as? String, !title.isEmpty,
                          let start = EditorHost.pageDate(item["startISO"] as? String) else {
                        self.reportCalendar(id, false, "couldn't read the date"); continue
                    }
                    let ev = EKEvent(eventStore: self.eventStore)
                    ev.calendar = cal
                    ev.title = title
                    ev.startDate = start
                    ev.endDate = EditorHost.pageDate(item["endISO"] as? String) ?? start.addingTimeInterval(3600)
                    ev.isAllDay = (item["allDay"] as? Bool) == true
                    ev.notes = item["rawLine"] as? String
                    do {
                        try self.eventStore.save(ev, span: .thisEvent)
                        self.syncedEventIds.insert(id)
                        self.persistSyncedEventIds()
                        self.reportCalendar(id, true, "")
                        self.onEventsSaved?()
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

    private func reloadSyncedEventIds() {
        if let raw = coordinatedRead(eventsPath), let data = raw.data(using: .utf8),
           let ids = try? JSONSerialization.jsonObject(with: data) as? [String] {
            syncedEventIds.formUnion(ids)
        }
    }

    private func persistSyncedEventIds() {
        let json = syncedEventIdsJSON
        coordinatedWrite(json, to: eventsPath)
    }

    private func reportCalendar(_ id: String, _ ok: Bool, _ message: String) {
        call("calendarResult(\(jsString(id)), \(ok), \(jsString(message)))")
    }

    /// Speaks in the text's own language with the best installed voice for it (E2 review #6). Every utterance goes
    /// through here, so a neural voice can replace the system ones in one place later.
    func speak(_ text: String) {
        if speechSynthesizer.isSpeaking { speechSynthesizer.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.voice = EditorHost.bestVoice(for: text)
        speechSynthesizer.speak(u)
    }

    static func bestVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let lang = r.dominantLanguage?.rawValue else { return nil }
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: lang)
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        loaded = true
        call("setTheme('dark')")
        call("setFontSize(18)")
        call("setText(\(jsString(text)))")
        if nativeWings && wingSide == nil { call("setNativeWings(true)") }
        if wingSide == nil, let inkJSON = coordinatedRead(inkPath), !inkJSON.isEmpty {
            call("setInk(\(jsString(inkJSON)))")
        }
        if let wingsJSON = coordinatedRead(wingsPath), !wingsJSON.isEmpty {
            call("setWingsState(\(jsString(wingsJSON)))")
        }
        call("setCalendarAdded(\(jsString(syncedEventIdsJSON)))")
        if FileManager.default.fileExists(atPath: EditorHost.iPhoneMirroring.path) { call("enableWidget('iphone')") }
        log(wingSide.map { "editor: \($0) wing panel loaded" } ?? "editor: new editor loaded (\(source))")
        onLoad?()
    }

    /// The page's process died (memory pressure, a crash): load it again with the text native holds.
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
        log("editor: the page's process ended; reloading it")
        loaded = false
        w.reload()
    }

    /// Offline by rule: the page may load itself and nothing from the network.
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = a.request.url?.scheme ?? ""
        // Embeds load in frames from recense-file: (the vault, or the cache); the web is never loaded directly.
        decisionHandler(["file", "about", "", "recense-file"].contains(scheme) ? .allow : .cancel)
    }
}

/// The stand-in: a plain text area with the same bridge, used only while editor/dist/editor.html doesn't exist.
let standInEditorHTML = """
<!doctype html><meta charset="utf-8">
<style>
html,body{margin:0;height:100%;background:transparent}
textarea{box-sizing:border-box;width:100%;height:100%;border:0;outline:0;resize:none;padding:8px 18px;
background:transparent;color:#e8eef5;caret-color:#5fd3e6;font:18px/1.55 -apple-system,system-ui,sans-serif}
</style>
<textarea id="t" spellcheck="true" autofocus></textarea>
<script>
const t = document.getElementById('t'); let timer = null;
function post(){ const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editor;
  if (h) h.postMessage(t.value); }
t.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(post, 300); });
window.recenseEditor = {
  setText(s){ const a = t.selectionStart, b = t.selectionEnd; t.value = s;
    t.setSelectionRange(Math.min(a, s.length), Math.min(b, s.length)); },
  getText(){ return t.value; },
  focus(){ t.focus(); },
  setTheme(m){ t.style.color = m === 'light' ? '#1d232b' : '#e8eef5'; },
  setFontSize(px){ t.style.fontSize = px + 'px'; }
};
</script>
"""

func editorSelftest() -> Bool {
    let file = "Thursday, October 8, 2026\n\nold\n\n<!-- page -->\n\nMonday, November 2, 2026\n\nnewer"
    var strip = stripPages(file)
    let checks: [(String, Bool)] = [
        ("the strip round-trips the file byte for byte", fileText(strip) == file),
        ("the strip shows the file's newest end first", strip.first?.hasSuffix("newer") == true),
        ("a page the strip adds lands on top of the file", {
            strip.append("Friday, November 6, 2026\n\nnew")
            return fileText(strip).hasPrefix("Friday, November 6, 2026\n\nnew" + pageJoiner + "Thursday")
        }()),
        ("the new editor's new page goes on top", withNewPageOnTop(file, Date(timeIntervalSince1970: 0))
            .hasSuffix(pageJoiner + file)),
        ("the flip puts the newest page first and keeps every page", {
            let f = ["Friday, November 6, 2026\n\ntoday", "undated top", "Thursday, October 8, 2026\n\nold",
                     "Monday, October 12, 2026\n\nmid", "undated under mid", "Monday, November 2, 2026\n\nnew"]
                .joined(separator: pageJoiner)
            let out = newestFirst(f), p = parsePages(out)
            return p.map { $0.prefix(9) } == ["Friday, N", "undated t", "Monday, N", "Monday, O", "undated u", "Thursday,"]
                && p.sorted() == parsePages(f).sorted() && out.utf8.count == f.utf8.count
        }()),
        ("flipping twice changes nothing", {
            let f = ["Thursday, October 8, 2026\n\nold", "x", "Monday, November 2, 2026\n\nnew"].joined(separator: pageJoiner)
            return newestFirst(newestFirst(f)) == newestFirst(f) && newestFirst(file) != file
                && newestFirst(newestFirst(file)) == newestFirst(file)
        }()),
        ("text reaches the page intact", {
            let s = "quote \" back\\slash\nnewline </script> \u{2028} Tiếng Việt §"
            guard let d = "[\(jsString(s))]".data(using: .utf8),
                  let a = try? JSONSerialization.jsonObject(with: d) as? [String] else { return false }
            return a == [s]
        }()),
    ]
    var ok = true
    for (label, pass) in checks {
        print("\(pass ? "ok  " : "FAIL") editor, \(label)")
        ok = ok && pass
    }
    return ok
}

/// A card's "Choose…" (an <input type=file>): the Mac's own open panel. The file stays on this Mac; the page plays or
/// shows it from here.
extension EditorHost: WKUIDelegate {
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)    // the wing panel never takes focus; the open panel must
        p.begin { r in completionHandler(r == .OK ? p.urls : nil) }
    }
}

/// `recense selftest`: the handwriting reader (Vision, on device) gets a hand-lettered line back through the same
/// PNG-in-base64 path the page uses, so ⌘F can find ink.
func inkOCRSelftest() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String, _ got: Any = "") { print("\(pass ? "ok  " : "FAIL") ink ocr, \(what)\(pass ? "" : " — got \(got)")"); ok = ok && pass }
    let size = NSSize(width: 900, height: 160)
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
    let font = NSFont(name: "Bradley Hand", size: 72) ?? .systemFont(ofSize: 72)
    ("Contrat de vente" as NSString).draw(at: NSPoint(x: 30, y: 40), withAttributes: [.font: font, .foregroundColor: NSColor.black])
    img.unlockFocus()
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { check(false, "render sample"); return false }
    var text = ""
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        if let src = CGImageSourceCreateWithData(Data(base64Encoded: png.base64EncodedString())! as CFData, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) { text = InkOCR.recognize(cg) }
        done.signal()
    }
    done.wait()
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    check(folded.contains("contrat") && folded.contains("vente"), "reads a hand-lettered French line", text)
    return ok
}
