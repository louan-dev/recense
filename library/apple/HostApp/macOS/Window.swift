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

    // ---------- toolbar ----------
    private let ids: [NSToolbarItem.Identifier] = [.init("back"), .init("forward"), .flexibleSpace, .init("shared"), .init("ask")]
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        switch id.rawValue {
        case "back": item.label = "Back"; item.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back"); item.action = #selector(back)
        case "forward": item.label = "Forward"; item.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward"); item.action = #selector(forward)
        case "shared": item.label = "Shared"; item.toolTip = "Shared links and Activity (⌘3)"; item.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: "Shared"); item.action = #selector(shared)
        case "ask": item.label = "Assistant"; item.toolTip = "Ask about what’s open (⌘K)"; item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Assistant"); item.action = #selector(ask)
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
