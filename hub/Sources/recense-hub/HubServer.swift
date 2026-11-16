import Foundation
import Network
import Security

// Derived from Spec: FEAT-18 (H1a). HTTPS on the LAN: the Draftpad page, /api/health, and /api/note (needs the token).
// The port can be 443 because macOS lets a normal user bind it.

final class HubServer {
    let port: UInt16
    let shell: String
    let notePath: String
    let token: String
    let name: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "recense.hub")

    init(port: UInt16, shell: String, notePath: String, token: String, name: String) {
        self.port = port; self.shell = shell; self.notePath = notePath; self.token = token; self.name = name
    }

    static func identity(p12: String, passphrase: String) -> SecIdentity? {
        guard let data = FileManager.default.contents(atPath: p12) else { return nil }
        var items: CFArray?
        let opts: [String: Any] = [kSecImportExportPassphrase as String: passphrase]
        guard SecPKCS12Import(data as CFData, opts as CFDictionary, &items) == errSecSuccess,
              let arr = items as? [[String: Any]], let first = arr.first,
              let id = first[kSecImportItemIdentity as String] else { return nil }
        return (id as! SecIdentity)
    }

    func start(identity: SecIdentity) throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let params = NWParameters(tls: tls)
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { s in
            if case .failed(let e) = s { FileHandle.standardError.write(Data("hub: listener failed: \(e)\n".utf8)); exit(1) }
        }
        l.start(queue: queue)
        listener = l
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self = self else { return }
            var buf = buf
            if let d = data { buf.append(d) }
            if buf.count > 8 << 20 { self.send(c, 413, "text/plain", Data("too large".utf8)); return }
            if let req = HubRequest.parse(buf) {
                self.route(c, req)
            } else if err != nil || done {
                c.cancel()
            } else {
                self.read(c, buf)
            }
        }
    }

    private func route(_ c: NWConnection, _ r: HubRequest) {
        let path = r.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "/"
        if path == "/api/health", r.method == "GET" {
            return json(c, 200, ["ok": true, "name": name])
        }
        if path == "/api/note" {
            guard r.method == "POST" else { return json(c, 405, ["error": "POST only"]) }
            guard hubTokenOK(r.headers["authorization"], token: token) else { return json(c, 401, ["error": "no token"]) }
            guard let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any], let mine = obj["mine"] as? String
            else { return json(c, 400, ["error": "need {base, mine}"]) }
            let base = obj["base"] as? String
            let reply = hubSaveNote(path: notePath, base: base, mine: mine)
            return json(c, reply.status, reply.body)
        }
        guard r.method == "GET" || r.method == "HEAD" else { return json(c, 405, ["error": "GET only"]) }
        guard let file = hubShellFile(root: shell, urlPath: r.target),
              let data = FileManager.default.contents(atPath: file) else { return send(c, 404, "text/plain", Data("not found".utf8)) }
        send(c, 200, hubContentType(file), r.method == "HEAD" ? Data() : data, extra: ["Content-Length": "\(data.count)",
             "Cache-Control": "no-store", "Service-Worker-Allowed": "/"], headOnly: r.method == "HEAD")
    }

    private func json(_ c: NWConnection, _ status: Int, _ obj: [String: Any]) {
        let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        send(c, status, "application/json", d, extra: ["Cache-Control": "no-store"])
    }

    private func send(_ c: NWConnection, _ status: Int, _ type: String, _ body: Data, extra: [String: String] = [:], headOnly: Bool = false) {
        let text = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed",
                    413: "Payload Too Large", 500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(text)\r\nContent-Type: \(type)\r\nConnection: close\r\n"
        var h = extra
        if h["Content-Length"] == nil { h["Content-Length"] = "\(body.count)" }
        for (k, v) in h { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        if !headOnly { out.append(body) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

struct HubRequest {
    var method: String, target: String, headers: [String: String], body: Data

    /// nil until the whole request (headers and the announced body) has arrived.
    static func parse(_ buf: Data) -> HubRequest? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let need = Int(headers["content-length"] ?? "0") ?? 0
        let body = buf[end.upperBound...]
        guard body.count >= need else { return nil }
        return HubRequest(method: String(first[0]), target: String(first[1]), headers: headers, body: Data(body.prefix(need)))
    }
}
