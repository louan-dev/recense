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

    /// FEAT-19 P4: WebKit plays an embedded recording only through byte ranges (it asks `bytes=0-1` first), so a
    /// `Range` request gets 206 and just those bytes; anything else gets the whole file, as before.
    private func serve(_ task: WKURLSchemeTask, _ file: URL) {
        guard live.contains(ObjectIdentifier(task)) else { return }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return fail(task, 404) }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let asked = task.request.value(forHTTPHeaderField: "Range")
        var headers = ["Content-Type": mime, "Accept-Ranges": "bytes"]
        var status = 200
        var body = data
        switch ByteRange.parse(asked, size: data.count) {
        case .whole: break
        case .unsatisfiable:
            headers["Content-Range"] = "bytes */\(data.count)"
            return finish(task, HTTPURLResponse(url: task.request.url!, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: headers)!, Data())
        case .part(let r):
            status = 206
            body = data.subdata(in: r)
            headers["Content-Range"] = ByteRange.contentRange(r, size: data.count)
        }
        headers["Content-Length"] = "\(body.count)"
        finish(task, HTTPURLResponse(url: task.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, body)
    }

    private func finish(_ task: WKURLSchemeTask, _ r: HTTPURLResponse, _ body: Data) {
        task.didReceive(r); task.didReceive(body); task.didFinish()
        live.remove(ObjectIdentifier(task))
    }

    private func fail(_ task: WKURLSchemeTask, _ code: Int) {
        guard live.contains(ObjectIdentifier(task)) else { return }
        task.didReceive(HTTPURLResponse(url: task.request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!)
        task.didFinish()
        live.remove(ObjectIdentifier(task))
    }
}

/// A `Range: bytes=…` header against a file of `size` bytes (RFC 9110 §14.1.2; one range, as WebKit asks).
/// Pure: tested by mobile/ios/Tests/byterange.
enum ByteRange: Equatable {
    case whole
    case part(Range<Int>)
    case unsatisfiable

    static func parse(_ header: String?, size: Int) -> ByteRange {
        guard let h = header?.trimmingCharacters(in: .whitespaces), h.lowercased().hasPrefix("bytes=") else { return .whole }
        let spec = h.dropFirst(6)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .whole }   // several ranges: the whole file
        let a = spec[..<dash].trimmingCharacters(in: .whitespaces), b = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if a.isEmpty {   // bytes=-N: the last N bytes
            guard let n = Int(b), n > 0, size > 0 else { return .unsatisfiable }
            return .part(max(0, size - n)..<size)
        }
        guard let start = Int(a), start >= 0 else { return .whole }
        guard start < size else { return .unsatisfiable }
        if b.isEmpty { return .part(start..<size) }
        guard let end = Int(b), end >= start else { return .whole }
        return .part(start..<min(end + 1, size))
    }

    static func contentRange(_ r: Range<Int>, size: Int) -> String { "bytes \(r.lowerBound)-\(r.upperBound - 1)/\(size)" }
}
