import AppKit
import WebKit

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
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        menu.addItem(.separator())
        extraItems().forEach { menu.addItem($0) }
    }
}

final class EditorHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let web: EditorWebView
    /// The editor's text as last posted by the page or set by native: what a save writes.
    private(set) var text = ""
    private var loaded = false
    /// Called on the main thread with the full text after each (debounced) change in the page.
    var onChange: ((String) -> Void)?
    /// Where the page came from, for the log: the CodeMirror core, or the stand-in.
    private(set) var source = ""

    /// The page bounced at its first or last page (the host plays the strip's bounce).
    var onBounce: (() -> Void)?
    let files: EmbedFiles

    init(frame: NSRect, vault: URL, cache: URL) {
        let cfg = WKWebViewConfiguration()
        files = EmbedFiles(vault: vault, cache: cache)
        cfg.setURLSchemeHandler(files, forURLScheme: "recense-file")
        web = EditorWebView(frame: frame, configuration: cfg)
        super.init()
        cfg.userContentController.add(WeakHandler(self), name: "editor")
        cfg.userContentController.add(WeakHandler(self), name: "link")
        cfg.userContentController.add(WeakHandler(self), name: "ui")
        web.navigationDelegate = self
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
        if m.name == "ui" { if (m.body as? String) == "bounce" { onBounce?() }; return }
        // The bridge posts the full text; a {text: …} object is accepted too.
        let s = (m.body as? String) ?? ((m.body as? [String: Any])?["text"] as? String)
        guard let s = s, s != text else { return }
        text = s
        onChange?(s)
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        loaded = true
        call("setTheme('dark')")
        call("setFontSize(18)")
        call("setText(\(jsString(text)))")
        log("editor: new editor loaded (\(source))")
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
