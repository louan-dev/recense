// Gallery's own page and player, inside the app (docs/architecture.md §10). The page loads from gallery://app/…, and
// every request it makes (the page, its scripts, /main/archive/f/… media with Range) goes through SchemeHandler,
// which sends it to the Worker with this device's Access token. WebKit never sees the token and no login page appears.
import SwiftUI
import WebKit

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

// one archive folder in Gallery's page, opened straight onto a file when there is one
struct PlayerView: UIViewRepresentable {
    let folder: String  // inside chauphan/
    let open: String?   // the file's path inside chauphan/

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(SchemeHandler(), forURLScheme: SchemeHandler.scheme)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        var u = URLComponents(string: "\(SchemeHandler.scheme)://app/main/archive")!
        u.queryItems = [URLQueryItem(name: "p", value: folder)] + (open.map { [URLQueryItem(name: "open", value: $0)] } ?? [])
        web.load(URLRequest(url: u.url!))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
}
