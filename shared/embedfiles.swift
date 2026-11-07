import Foundation
import WebKit
import CryptoKit
import UniformTypeIdentifiers

// Shared by Recense on the Mac (editorhost.swift) and Draftpad on iPad and iPhone (mobile/HostApp/iOS).
/// `recense-file://vault/<path>` serves a file next to draftpad.md; `recense-file://remote/<url>` serves a web file
/// from the cache, downloading it the first time. So an embed opened once opens again with no network.
final class EmbedFiles: NSObject, WKURLSchemeHandler {
    let vault: URL
    let cache: URL
    let maxBytes = 100 << 20
    private var live = Set<ObjectIdentifier>()

    init(vault: URL, cache: URL) { self.vault = vault.standardizedFileURL; self.cache = cache }

    /// The cached copy of a web file: its SHA-256 plus the original extension.
    func cachedURL(for remote: URL) -> URL {
        let h = SHA256.hash(data: Data(remote.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = remote.pathExtension.isEmpty ? "bin" : remote.pathExtension.lowercased()
        return cache.appendingPathComponent("\(h).\(ext)")
    }

    /// A vault path that stays inside the vault (no `..` escapes), or nil.
    func vaultURL(_ rel: String) -> URL? {
        let u = vault.appendingPathComponent(rel).standardizedFileURL
        return u.path.hasPrefix(vault.path + "/") ? u : nil
    }

    /// What a `recense-file:` URL points at: a local file, or a remote one to fetch into `local`.
    func resolve(_ url: URL) -> (local: URL, remote: URL?)? {
        let rest = url.absoluteString.dropFirst("recense-file://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let kind = rest[..<slash], tail = String(rest[rest.index(after: slash)...])
        guard let decoded = tail.removingPercentEncoding else { return nil }
        switch kind {
        case "vault": return vaultURL(decoded).map { ($0, nil) }
        case "remote":
            guard let r = URL(string: decoded), r.scheme == "https" || r.scheme == "http" else { return nil }
            return (cachedURL(for: r), r)
        default: return nil
        }
    }

    func webView(_ w: WKWebView, start task: WKURLSchemeTask) {
        live.insert(ObjectIdentifier(task))
        guard let url = task.request.url, let (local, remote) = resolve(url) else { return fail(task, 400) }
        if FileManager.default.fileExists(atPath: local.path) { return serve(task, local) }
        guard let remote = remote else { return fail(task, 404) }
        URLSession.shared.downloadTask(with: remote) { [weak self] tmp, resp, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                let size = (tmp.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] } as? Int) ?? 0
                guard ok, let tmp = tmp, size <= self.maxBytes else {
                    log("embed: couldn't fetch \(remote.host ?? "?") (offline, or too big); it shows once it's cached")
                    return self.fail(task, 504)
                }
                try? FileManager.default.createDirectory(at: self.cache, withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: tmp, to: local)
                self.serve(task, local)
            }
        }.resume()
    }

    func webView(_ w: WKWebView, stop task: WKURLSchemeTask) { live.remove(ObjectIdentifier(task)) }

    private func serve(_ task: WKURLSchemeTask, _ file: URL) {
        guard live.contains(ObjectIdentifier(task)) else { return }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return fail(task, 404) }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let r = HTTPURLResponse(url: task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
        task.didReceive(r); task.didReceive(data); task.didFinish()
        live.remove(ObjectIdentifier(task))
    }

    private func fail(_ task: WKURLSchemeTask, _ code: Int) {
        guard live.contains(ObjectIdentifier(task)) else { return }
        task.didReceive(HTTPURLResponse(url: task.request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!)
        task.didFinish()
        live.remove(ObjectIdentifier(task))
    }
}
