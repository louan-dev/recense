// Gallery's window on the Mac: the whole site (/main, /main/archive, the player) through SchemeHandler (Player.swift),
// so this Mac's Access token goes with every request and no sign-in page appears, with an Assistant button that opens
// the site's assistant sidebar on whatever page is open. Opening the app shows the window; at login it stays in the
// background for Finder (main.swift). Closing the window hides the Dock icon again; the app keeps running.
import AppKit
import WebKit

final class GalleryWindow: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, WKUIDelegate, WKNavigationDelegate {
    private var window: NSWindow?
    private var web: WKWebView?
    private var atLogin = false
    private weak var selectButton: NSButton?

    func applicationWillFinishLaunching(_ n: Notification) {
        let e = NSAppleEventManager.shared().currentAppleEvent
        atLogin = e?.eventID == kAEOpenApplication && e?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        NSApp.mainMenu = menu()
    }

    func applicationDidFinishLaunching(_ n: Notification) { if !atLogin { show() } }

    // opening the app again (Finder, Spotlight, Dock) while it runs
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { show(); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    @objc func show() {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let web = galleryWebView()
            web.uiDelegate = self
            web.navigationDelegate = self
            web.allowsBackForwardNavigationGestures = true
            // the toolbar's … and Select stand in for the page's own (notes 20261029 item 16)
            web.configuration.userContentController.addUserScript(WKUserScript(
                source: "const s = document.createElement('style'); s.textContent = '.bar #mbtn, .bar #sel { display: none !important }'; document.documentElement.appendChild(s);",
                injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            web.load(URLRequest(url: galleryURL("/main")))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Gallery"
            w.contentView = web
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("Gallery")
            let bar = NSToolbar(identifier: "Gallery")
            bar.delegate = self
            bar.displayMode = .iconOnly
            w.toolbar = bar
            w.toolbarStyle = .unified
            if !w.setFrameUsingName("Gallery") { w.center() }
            window = w
            self.web = web
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ n: Notification) { NSApp.setActivationPolicy(.accessory) }

    // the page's own Ask button (src/client/assistant.js); a page without it (a public share) has no assistant
    @objc func ask() {
        show()
        web?.evaluateJavaScript("document.getElementById('aibtn')?.click(); !!document.getElementById('aibtn')") { r, _ in
            if (r as? Bool) != true { self.web?.load(URLRequest(url: galleryURL("/main", ["ask": "1"]))) }
        }
    }
    @objc func back() { web?.goBack() }
    @objc func forward() { web?.goForward() }
    @objc func reload() { web?.reload() }
    @objc func home() { web?.load(URLRequest(url: galleryURL("/main"))) }
    @objc func archive() { web?.load(URLRequest(url: galleryURL("/main/archive"))) }
    // every live share link as an album, and their Activity (src/shared.js; notes item 15)
    @objc func shared() { show(); web?.load(URLRequest(url: galleryURL("/main/shared"))) }

    // ---------- the … menu and Select (the site's header: page/gallery.js .bar; notes 20261029 item 16) ----------
    // Select mode, the sheets and the writes are the page's own; Download and AirDrop are the Mac's.
    private func page(_ js: String, _ done: ((Any?) -> Void)? = nil) {
        web?.evaluateJavaScript("(() => { const $ = (id) => document.getElementById(id); \(js) })()") { r, _ in done?(r) }
    }
    private func paintSelect(_ r: Any?) { selectButton?.title = (r as? String) == "Cancel" ? "Cancel" : "Select" }
    // the page's own menu row, when this page has it (Invite, Add Media and New Folder are Main's)
    private func row(_ id: String, _ what: String) {
        page("const b = $('\(id)'); if (!b || b.hidden) return false; b.click(); return true") { r in
            if (r as? Bool) != true { self.tell("\(what) isn’t here", "Open a folder in Main to use \(what).") }
        }
    }
    private func tell(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }

    @objc func toggleSelect() { page("const b = $('sel'); if (!b) return null; b.click(); return b.textContent", paintSelect) }
    @objc func selectAll() {
        page("const b = $('sel'), a = $('selall'); if (!b) return null; if (b.textContent === 'Select') b.click(); if (a && a.textContent === 'Select All') a.click(); return b.textContent", paintSelect)
    }
    @objc func deselect() { page("const a = $('selall'); if (a && !a.hidden && a.textContent === 'Deselect All') a.click()") }
    @objc func shareLink() { row("m-share", "Create Share Link") }
    @objc func invite() { row("m-inv", "Invite") }
    @objc func addMedia() { row("m-add", "Add Media") }
    @objc func newFolder() { row("m-dir", "New Folder") }
    @objc func download() { picked { urls in
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    } }
    @objc func airDrop() { picked(into: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) { urls in
        guard let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: urls) else {
            return self.tell("AirDrop isn’t available", "Turn on Wi-Fi and Bluetooth, then try again.")
        }
        s.perform(withItems: urls)
    } }

    // the picked items' files, fetched with this Mac's token: into Downloads for Download, a temporary folder for AirDrop
    private func picked(into dir: URL? = nil, _ then: @escaping ([URL]) -> Void) {
        page("const s = window.gallerySelection ? window.gallerySelection() : []; return s.map((f) => [f.name, f.src || '/f/' + G.id + '/' + f.n])") { r in
            let list = (r as? [[String]] ?? []).filter { $0.count == 2 }
            guard !list.isEmpty else { return self.tell("Nothing is selected", "Click Select, pick some items, then try again.") }
            Task { @MainActor in
                do { then(try await self.fetch(list, into: dir ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])) }
                catch { self.tell("Couldn’t download", "Check the connection and try again.") }
            }
        }
    }
    private func fetch(_ list: [[String]], into fetchInto: URL) async throws -> [URL] {
        try FileManager.default.createDirectory(at: fetchInto, withIntermediateDirectories: true)
        guard let t = Token.read().flatMap({ try? JSONDecoder().decode([String: String].self, from: $0) }),
              let id = t["id"], let secret = t["secret"] else { throw FeedError.notSignedIn }
        var out: [URL] = []
        for item in list {
            guard let u = URL(string: "https://\(Gallery.base.host!)\(item[1])?dl=1") else { continue }
            var r = URLRequest(url: u)
            r.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
            r.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
            let (tmp, response) = try await URLSession.shared.download(for: r)
            guard let h = response as? HTTPURLResponse, h.url?.host == Gallery.base.host, (200...299).contains(h.statusCode) else { throw FeedError.server(-1) }
            // never over a file already in Downloads: "name 2.ext", as Safari does
            let name = (item[0] as NSString).lastPathComponent, base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            var to = fetchInto.appendingPathComponent(name), n = 2
            while FileManager.default.fileExists(atPath: to.path) {
                to = fetchInto.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : "." + ext)); n += 1
            }
            try FileManager.default.moveItem(at: tmp, to: to)
            out.append(to)
        }
        return out
    }

    private func moreMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ symbol: String, _ a: Selector) {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: ""); i.target = self
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: t); m.addItem(i)
        }
        add("Select", "checkmark.circle", #selector(selectAll)); add("Deselect", "circle", #selector(deselect))
        m.addItem(.separator())
        add("Download", "arrow.down.circle", #selector(download)); add("AirDrop", "airplayaudio", #selector(airDrop))
        add("Create Share Link", "link", #selector(shareLink)); add("Invite", "person.badge.plus", #selector(invite))
        m.addItem(.separator())
        add("Add Media", "plus", #selector(addMedia)); add("New Folder", "folder.badge.plus", #selector(newFolder))
        return m
    }

    // a new page starts out of Select mode
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { selectButton?.title = "Select" }

    // ---------- toolbar ----------
    private let ids: [NSToolbarItem.Identifier] = [.init("back"), .init("forward"), .flexibleSpace, .init("ask"), .space, .init("more"), .space, .init("select"), .space]
    // as the iOS top bar (notes item 16): blue bulb, then …, then Select, spaced, and a gap at the end so the … menu opens inside the window; Shared lives under Collections now
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { ids + [.init("shared")] }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        if id.rawValue == "more" {
            let m = NSMenuToolbarItem(itemIdentifier: id)
            m.label = "More"; m.toolTip = "Select, share, add"
            m.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")?.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor]))
            m.menu = moreMenu(); m.showsIndicator = false
            return m
        }
        if id.rawValue == "select" {
            // blue text, as the site's Select (and Select All) are
            let b = NSButton(title: "Select", target: self, action: #selector(toggleSelect))
            b.isBordered = false; b.contentTintColor = .controlAccentColor; b.font = .systemFont(ofSize: 13)
            b.attributedTitle = NSAttributedString(string: "Select", attributes: [.foregroundColor: NSColor.controlAccentColor, .font: NSFont.systemFont(ofSize: 13)])
            selectButton = b
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Select"; item.view = b
            return item
        }
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        switch id.rawValue {
        case "back": item.label = "Back"; item.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back"); item.action = #selector(back)
        case "forward": item.label = "Forward"; item.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward"); item.action = #selector(forward)
        case "shared": item.label = "Shared"; item.toolTip = "Shared links and Activity (⌘3)"; item.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: "Shared"); item.action = #selector(shared)
        case "ask": item.label = "Assistant"; item.toolTip = "Ask about what’s open (⌘K)"; item.image = NSImage(systemSymbolName: "lightbulb", accessibilityDescription: "Assistant")?.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor])); item.action = #selector(ask)
        default: return nil
        }
        item.isBordered = true
        return item
    }

    // ---------- the page asking for things ----------
    // links that open a new window (an invite's .ics, a share link): Gallery's own pages here, anything else in the browser
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url {
            if u.scheme == SchemeHandler.scheme { w.load(URLRequest(url: u)) } else { NSWorkspace.shared.open(u) }
        }
        return nil
    }

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = a.request.url, a.targetFrame?.isMainFrame != false else { return decisionHandler(.allow) }
        if ["http", "https", "mailto", "sms", "tel"].contains(u.scheme ?? "") { NSWorkspace.shared.open(u); return decisionHandler(.cancel) }
        decisionHandler(.allow)
    }

    // the upload tile and drag-and-drop's file picker
    func webView(_ w: WKWebView, runOpenPanelWith p: WKOpenPanelParameters, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = p.allowsMultipleSelection
        panel.canChooseDirectories = p.allowsDirectories
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = m; a.runModal(); completionHandler()
    }

    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = m; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt p: String, defaultText d: String?, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert(); a.messageText = p; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        let field = NSTextField(string: d ?? ""); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24); a.accessoryView = field
        completionHandler(a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    // ---------- menus (a window app needs Edit for copy and paste in the assistant's box) ----------
    private func menu() -> NSMenu {
        let bar = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title); items.forEach(m.addItem)
            let top = NSMenuItem(); top.submenu = m; bar.addItem(top)
        }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; i.target = target; return i
        }
        add("Gallery", [item("Hide Gallery", #selector(NSApplication.hide(_:)), "h"), .separator(),
                        item("Quit Gallery", #selector(NSApplication.terminate(_:)), "q")])
        add("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
                     item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                     item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a")])
        add("View", [item("Assistant", #selector(ask), "k", target: self), .separator(),
                     item("Main", #selector(home), "1", target: self), item("Archive", #selector(archive), "2", target: self),
                     item("Shared", #selector(shared), "3", target: self), .separator(),
                     item("Back", #selector(back), "[", target: self), item("Forward", #selector(forward), "]", target: self),
                     item("Reload", #selector(reload), "r", target: self),
                     item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])])
        add("Window", [item("Show Gallery", #selector(show), "0", target: self), item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                       item("Close", #selector(NSWindow.performClose(_:)), "w")])
        return bar
    }
}
