// Gallery's own page and player, inside the app (docs/architecture.md §10). The page loads from gallery://app/…, and
// every request it makes (the page, its scripts, /main/archive/f/… media with Range) goes through SchemeHandler,
// which sends it to the Worker with this device's Access token. WebKit never sees the token and no login page appears.
import SwiftUI
import WebKit
#if os(iOS)
import AVFoundation
#endif
// (also compiled into the Mac app: macos/build.sh)

final class SchemeHandler: NSObject, WKURLSchemeHandler, URLSessionDataDelegate {
    static let scheme = "gallery"
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)  // WebKit wants its scheme tasks answered on the main thread
    // each running request and the page's task it answers; bodies stream through (a memo can be 1.4 GB)
    private var running: [Int: (WKURLSchemeTask, URL)] = [:]
    private var byTask: [ObjectIdentifier: URLSessionDataTask] = [:]
    private let lock = NSLock()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let token = Token.read().flatMap({ try? JSONDecoder().decode([String: String].self, from: $0) }),
              let id = token["id"], let secret = token["secret"], let asked = task.request.url,
              var parts = URLComponents(url: asked, resolvingAgainstBaseURL: false) else {
            return task.didFailWithError(URLError(.userAuthenticationRequired))
        }
        parts.scheme = "https"
        parts.host = Gallery.base.host
        var r = task.request
        r.url = parts.url
        r.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
        r.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        // the page's origin is gallery://app, which the Worker's same-site check (access.js sameSite) would refuse;
        // it's our own page, so it goes as the apps do: no Origin, x-gallery: 1
        if r.value(forHTTPHeaderField: "Origin") != nil {
            r.setValue(nil, forHTTPHeaderField: "Origin")
            r.setValue("1", forHTTPHeaderField: "x-gallery")
        }
        let t = session.dataTask(with: r)
        lock.lock(); running[t.taskIdentifier] = (task, asked); byTask[ObjectIdentifier(task)] = t; lock.unlock()
        t.resume()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock()
        let t = byTask.removeValue(forKey: ObjectIdentifier(task))
        if let t { running[t.taskIdentifier] = nil }
        lock.unlock()
        t?.cancel()
    }

    private func page(_ t: URLSessionTask, done: Bool = false) -> (WKURLSchemeTask, URL)? {
        lock.lock(); defer { lock.unlock() }
        guard let p = running[t.taskIdentifier] else { return nil }
        if done { running[t.taskIdentifier] = nil; byTask[ObjectIdentifier(p.0)] = nil }
        return p
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let (task, asked) = page(dataTask), let h = response as? HTTPURLResponse else { return completionHandler(.cancel) }
        // answered as if the page's own origin served it, so relative links stay on gallery://
        task.didReceive(HTTPURLResponse(url: asked, statusCode: h.statusCode, httpVersion: "HTTP/1.1",
                                        headerFields: h.allHeaderFields as? [String: String])!)
        completionHandler(.allow)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        page(dataTask)?.0.didReceive(data)
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let (t, _) = page(task, done: true) else { return }  // WebKit stopped it
        if let error { t.didFailWithError(error) } else { t.didFinish() }
    }

    // Access sends a missing token to its sign-in page: never follow that inside the app
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.host == Gallery.base.host ? request : nil)
    }
}

// a page of Gallery's site, loaded through SchemeHandler (iOS and the Mac app's window)
func galleryURL(_ path: String, _ query: [String: String?] = [:]) -> URL {
    var u = URLComponents(string: "\(SchemeHandler.scheme)://app\(path)")!
    let q = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name }
    if !q.isEmpty { u.queryItems = q }
    return u.url!
}

@MainActor func galleryWebView() -> WKWebView {
    let config = WKWebViewConfiguration()
    config.setURLSchemeHandler(SchemeHandler(), forURLScheme: SchemeHandler.scheme)
    config.mediaTypesRequiringUserActionForPlayback = []
    #if os(iOS)
    config.allowsInlineMediaPlayback = true
    config.userContentController.addUserScript(WKUserScript(source: RouteLatency.script(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
    config.userContentController.add(Exporter.shared, name: "galleryExport")
    config.userContentController.add(LinkHandler.shared, name: "galleryLink")
    let web = WKWebView(frame: .zero, configuration: config)
    RouteLatency.watch(web)
    return web
    #else
    return WKWebView(frame: .zero, configuration: config)
    #endif
}

#if os(iOS)
/// WebKit reports no output latency (AudioContext.outputLatency reads 0), so through AirPods or a car the light and the
/// notation ran ~0.2 s ahead of the voice on the iPhone while the Mac was in step (Sororité, the Vietnamese ballad).
/// The audio route's own latency is handed to the page (gallery.js heard()), again whenever the route changes.
@MainActor enum RouteLatency {
    static var value: Double {
        let s = AVAudioSession.sharedInstance()
        return max(0, min(1, s.outputLatency + s.ioBufferDuration))
    }
    static func script() -> String { "globalThis.galleryOutputLatency=\(value);" }
    private static var observer: NSObjectProtocol?
    private static let webs = NSHashTable<WKWebView>.weakObjects()
    static func watch(_ web: WKWebView) {
        webs.add(web)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { for w in webs.allObjects { w.evaluateJavaScript(script()) } }
        }
    }
}
#endif

#if os(iOS)
/// The page's Export as MD and Export as M4B (gallery.js exportMd / exportM4b). A blob link saves nothing in WebKit
/// here, so the page hands the file over and the app offers Save to Files. The M4B is made on the iPhone: the file
/// from the archive, re-encoded to AAC with its title and the transcript (the same note as Export as MD) as lyrics.
/// A share's Copy Link / Open: the page runs on gallery://, so the app turns its path into the site's https link,
/// puts it on the clipboard or opens it in Safari (notes 20261029 item 16)
@MainActor final class LinkHandler: NSObject, WKScriptMessageHandler {
    static let shared = LinkHandler()
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let b = m.body as? [String: Any], let path = b["path"] as? String,
              let url = URL(string: "https://\(Gallery.base.host ?? "")" + path) else { return }
        if b["op"] as? String == "open" { UIApplication.shared.open(url) } else { UIPasteboard.general.url = url }
    }
}

@MainActor final class Exporter: NSObject, WKScriptMessageHandler {
    static let shared = Exporter()

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let b = m.body as? [String: Any] else { return }
        Task {
            do {
                switch b["kind"] as? String {
                case "file":
                    let name = (b["name"] as? String ?? "Export.md").replacingOccurrences(of: "/", with: "-")
                    let url = try Self.dir().appendingPathComponent(name)
                    try (b["text"] as? String ?? "").write(to: url, atomically: true, encoding: .utf8)
                    present(url)
                case "m4b":
                    guard let path = b["path"] as? String else { return }
                    present(try await Self.m4b(path, title: b["title"] as? String ?? "Audiobook", lyrics: b["md"] as? String ?? ""))
                default: return
                }
            } catch { alert("Couldn’t export: \(error.localizedDescription)") }
        }
    }

    private static func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func m4b(_ path: String, title: String, lyrics: String) async throws -> URL {
        let src = try await Feed().download(path)
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        let asset = AVURLAsset(url: src)
        guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw URLError(.cannotDecodeContentData) }
        let d = try dir(), m4a = d.appendingPathComponent("audio.m4a")
        func item(_ id: AVMetadataIdentifier, _ v: String) -> AVMetadataItem {
            let i = AVMutableMetadataItem(); i.identifier = id; i.value = v as NSString; return i
        }
        s.metadata = [item(.commonIdentifierTitle, title), item(.iTunesMetadataSongName, title)]
            + (lyrics.isEmpty ? [] : [item(.iTunesMetadataLyrics, lyrics)])
        try await s.export(to: m4a, as: .m4a)
        let out = d.appendingPathComponent(title.replacingOccurrences(of: "/", with: "-") + ".m4b")
        try FileManager.default.moveItem(at: m4a, to: out)
        return out
    }

    private func top() -> UIViewController? {
        var t = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let p = t?.presentedViewController { t = p }
        return t
    }
    private func present(_ url: URL) { top()?.present(UIDocumentPickerViewController(forExporting: [url], asCopy: true), animated: true) }
    private func alert(_ text: String) {
        let a = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        top()?.present(a, animated: true)
    }
}

// one archive folder in Gallery's page, opened straight onto a file when there is one; or any page (the Assistant)
struct PlayerView: UIViewRepresentable {
    let url: URL

    init(folder: String, open: String?) {  // inside archive/
        url = galleryURL("/main/archive", ["p": folder, "open": open])
    }
    init(url: URL) { self.url = url }

    func makeUIView(context: Context) -> WKWebView {
        let web = galleryWebView()
        web.isOpaque = false
        web.backgroundColor = .black
        web.uiDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    func makeCoordinator() -> Dialogs { Dialogs() }

    /// Without a UI delegate WKWebView answers the page's alert/confirm/prompt silently (confirm → false), so
    /// "Delete this comment?" never deleted anything on the iPhone (item 18).
    final class Dialogs: NSObject, WKUIDelegate {
        private func show(_ a: UIAlertController, from w: WKWebView, else fallback: () -> Void) {
            var top = w.window?.rootViewController
            while let p = top?.presentedViewController { top = p }
            guard let top else { return fallback() }
            top.present(a, animated: true)
        }
        func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let a = UIAlertController(title: nil, message: m, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            show(a, from: w, else: completionHandler)
        }
        func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let a = UIAlertController(title: nil, message: m, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            show(a, from: w) { completionHandler(false) }
        }
        func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt p: String, defaultText d: String?, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let a = UIAlertController(title: nil, message: p, preferredStyle: .alert)
            a.addTextField { $0.text = d }
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
            show(a, from: w) { completionHandler(nil) }
        }
    }
}
#endif
