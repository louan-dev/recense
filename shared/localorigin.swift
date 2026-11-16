// Derived from Spec: UI-12 P1 (Mac) and P2 (iOS/iPadOS) · the editor at a local path.
// Coded, not compiled (written with no Swift toolchain); `recense selftest` (localOriginSelftest) is the first compile.
//
// The device serves the editor to itself: http://127.0.0.1:47823/ opens the same page the apps embed
// (editor/dist/pwa/), in any browser on this device, with no network. Loopback only: the listener's required local
// endpoint is 127.0.0.1 and it accepts local connections only; it never binds 0.0.0.0, so nothing on the LAN can reach
// it (the loopback interface is required, and each connection's peer is checked again before it is read). Every
// answer closes its connection (no keep-alive, nothing held open).
//
// The page posts exactly what it posts to the apps (`webkit.messageHandlers.{editor,ink,matter}`), queued in its outbox
// (editor/src/webstore.js) and drained here. Each entry lands through notesync.swift the way App.saveNow lands the
// native editor's text: `planNoteSave(base:mine:theirs:)`, coordinated reads and writes, a sibling for a real conflict.
import Foundation
#if canImport(Network)
import Network
#endif

/// One HTTP request, as much of it as the editor's page needs.
struct OriginRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String]   // names lowercased
    var body: Data
}

/// One HTTP answer. Always `Connection: close`.
struct OriginResponse: Equatable {
    var status: Int
    var type: String = "text/plain; charset=utf-8"
    var body: Data = Data()
    var extra: [(String, String)] = []

    static func == (a: OriginResponse, b: OriginResponse) -> Bool {
        a.status == b.status && a.type == b.type && a.body == b.body && a.extra.map { $0.0 + ":" + $0.1 } == b.extra.map { $0.0 + ":" + $0.1 }
    }

    static func text(_ status: Int, _ s: String) -> OriginResponse { OriginResponse(status: status, body: Data(s.utf8)) }

    static func json(_ obj: Any) -> OriginResponse {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return OriginResponse(status: 200, type: "application/json", body: d, extra: [("Cache-Control", "no-store")])
    }

    var reason: String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    func bytes() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        var d = Data((head + "\r\n").utf8)
        d.append(body)
        return d
    }
}

enum LocalOrigin {
    /// The one address it ever binds. Never 0.0.0.0, never a LAN address.
    static let bindHost = "127.0.0.1"
    static let defaultPort: UInt16 = 47823
    /// `RECENSE_ORIGIN_PORT` overrides the port for one launch (tests, a clash); the default stays stable so the
    /// page's origin (and with it its service worker and its IndexedDB outbox) is the same on every launch.
    static var port: UInt16 {
        ProcessInfo.processInfo.environment["RECENSE_ORIGIN_PORT"].flatMap { UInt16($0) } ?? defaultPort
    }
    static func url(port: UInt16 = port) -> String { "http://\(bindHost):\(port)/" }

    static let maxHead = 64 * 1024
    static let maxBody = 32 * 1024 * 1024

    /// The files the page is made of (editor/dist/pwa/). Nothing else is ever read from disk by a GET.
    static let pageFiles: [String: String] = [
        "index.html": "text/html; charset=utf-8",
        "sw.js": "text/javascript; charset=utf-8",
        "manifest.webmanifest": "application/manifest+json",
        "icon.svg": "image/svg+xml",
    ]

    enum Parsed: Equatable { case complete(OriginRequest), incomplete, bad(Int) }

    /// Bytes received so far → a whole request, "keep reading", or an error status.
    static func parse(_ data: Data) -> Parsed {
        let sep = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: sep) else { return data.count > maxHead ? .bad(413) : .incomplete }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .bad(400) }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return .bad(400) }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { return .bad(400) }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .bad(400) }   // the page always sends a length
        let length = headers["content-length"].flatMap { Int($0) } ?? 0
        guard length >= 0, length <= maxBody else { return .bad(413) }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        let rawPath = String(first[1])
        let path = String(rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        return .complete(OriginRequest(method: String(first[0]), path: path, headers: headers, body: Data(body)))
    }

    /// The two names this origin answers to. Anything else (a DNS-rebinding name that resolves to 127.0.0.1) is refused.
    static func allowedHosts(_ port: UInt16) -> Set<String> { ["\(bindHost):\(port)", "localhost:\(port)"] }
    static func allowedOrigins(_ port: UInt16) -> Set<String> { ["http://\(bindHost):\(port)", "http://localhost:\(port)"] }

    /// Every request, pure apart from the files it reads and the vault it writes. `pageDir`: the bundle's copy of
    /// editor/dist/pwa/. `vault`: the folder holding draftpad.md (the same one the native editor saves into).
    static func respond(_ r: OriginRequest, port: UInt16, pageDir: URL?, vault: URL,
                        wrote: (String) -> Void = { _ in }) -> OriginResponse {
        guard let host = r.headers["host"], allowedHosts(port).contains(host.lowercased()) else {
            return .text(403, "this origin answers to 127.0.0.1 only")
        }
        if r.path.hasPrefix("/ui12/") {
            // The API: same origin only. A POST from another page in this browser carries its own Origin and is refused;
            // no CORS header is ever sent, so another origin cannot read an answer either.
            if r.method != "GET" {
                guard let o = r.headers["origin"], allowedOrigins(port).contains(o.lowercased()) else {
                    return .text(403, "same origin only")
                }
            } else if let o = r.headers["origin"], !allowedOrigins(port).contains(o.lowercased()) {
                return .text(403, "same origin only")
            }
            switch (r.method, r.path) {
            case ("GET", "/ui12/state"): return .json(DraftpadChannels.state(vault: vault))
            case ("POST", "/ui12/drain"):
                guard let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
                      let entries = obj["entries"] as? [[String: Any]] else { return .text(400, "expected {entries: [...]}") }
                let answers = entries.map { DraftpadChannels.settle($0, vault: vault, wrote: wrote) }
                return .json(["answers": answers])
            default: return .text(r.method == "GET" || r.method == "POST" ? 404 : 405, "no such call")
            }
        }
        guard r.method == "GET" || r.method == "HEAD" else { return .text(405, "read only") }
        let name = r.path == "/" ? "index.html" : String(r.path.dropFirst())
        guard let type = pageFiles[name], let dir = pageDir,
              let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return .text(404, "not here") }
        var res = OriginResponse(status: 200, type: type, body: r.method == "HEAD" ? Data() : data)
        res.extra = [("Cache-Control", "no-cache")]
        if name == "sw.js" { res.extra.append(("Service-Worker-Allowed", "/")) }
        return res
    }
}

/// The page's three channels and the files they land in. One table, so FEAT-08's sidecar rides the same path as ink.
enum DraftpadChannels {
    static let files: [String: String] = [
        "editor": "draftpad.md",
        "ink": "draftpad.ink.json",
        "matter": "draftpad.matter.json",   // FEAT-08 (lane draftpad-matter): the page's own mergeMatter unions it
    ]

    /// GET /ui12/state: each channel's file as it is now ("" when there is none yet). `unreadable` lists a file that
    /// exists but cannot be read now (an evicted iCloud file, T-0114): the page must not treat it as blank.
    static func state(vault: URL) -> [String: Any] {
        var out: [String: Any] = [:]
        var unreadable: [String] = []
        for (ch, name) in files {
            switch readNote(vault.appendingPathComponent(name).path) {
            case .text(let s): out[ch] = s
            case .missing: out[ch] = ""
            case .unreadable: unreadable.append(ch)
            }
        }
        return ["channels": out, "unreadable": unreadable.sorted()]
    }

    /// One outbox entry `{channel, base, mine}` → its answer `{channel, status, text?, sibling?}`.
    /// - editor: `planNoteSave` exactly as App.saveNow (write / adopt / clean merge / conflict sibling).
    /// - ink, matter: written when the file still equals the entry's base (or there is none, or it already equals mine);
    ///   otherwise `stale` with the file, which the page unions with its own copy and sends again.
    /// - unreadable now: `wait` — nothing is written, the entry stays queued.
    static func settle(_ e: [String: Any], vault: URL, wrote: (String) -> Void = { _ in }) -> [String: Any] {
        guard let ch = e["channel"] as? String, let name = files[ch],
              let mine = e["mine"] as? String else { return ["status": "refused"] }
        let base = e["base"] as? String ?? ""
        let path = vault.appendingPathComponent(name).path
        let now = readNote(path)
        if case .unreadable = now { return ["channel": ch, "status": "wait"] }
        let theirs: String? = { if case .text(let t) = now { return t }; return nil }()
        if ch == "editor" {
            switch planNoteSave(base: base, mine: mine, theirs: theirs) {
            case .write(let t):
                if t != theirs { guard coordinatedWrite(t, to: path) else { return ["channel": ch, "status": "wait"] }; wrote(name) }
                return ["channel": ch, "status": t == mine ? "written" : "merged", "text": t]
            case .adopt(let t):
                return ["channel": ch, "status": "adopted", "text": t]
            case .conflict(let m, let other):
                let sib = freeSiblingPath(path)
                guard coordinatedWrite(other, to: sib), coordinatedWrite(m, to: path) else { return ["channel": ch, "status": "wait"] }
                wrote(name)
                return ["channel": ch, "status": "conflict", "text": m, "sibling": (sib as NSString).lastPathComponent]
            }
        }
        let current = theirs ?? ""
        if current == mine { return ["channel": ch, "status": "written"] }
        if current.isEmpty || current == base {
            guard coordinatedWrite(mine, to: path) else { return ["channel": ch, "status": "wait"] }
            wrote(name)
            return ["channel": ch, "status": "written"]
        }
        return ["channel": ch, "status": "stale", "text": current]
    }
}

#if canImport(Network)
/// The listener. One per app; `start()` is idempotent. All file work runs on its own queue; `onWrite` is called on the
/// main queue with the file name after a write, so the app can show it (App.pollExternal) and carry it (P4).
final class LocalOriginServer {
    static let shared = LocalOriginServer()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "recense.localorigin")
    private(set) var port: UInt16 = LocalOrigin.port
    var vault: URL?
    var pageDir: URL?
    var onWrite: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    func start(vault: URL, pageDir: URL?) {
        queue.async { [self] in
            self.vault = vault; self.pageDir = pageDir
            guard listener == nil, let p = NWEndpoint.Port(rawValue: port) else { return }
            let params = NWParameters.tcp
            params.acceptLocalOnly = true
            params.requiredInterfaceType = .loopback
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(LocalOrigin.bindHost), port: p)
            do {
                let l = try NWListener(using: params)
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                l.stateUpdateHandler = { [weak self] s in
                    switch s {
                    case .ready: self?.say("local origin: \(LocalOrigin.url(port: self?.port ?? 0)) (loopback only)")
                    case .failed(let e): self?.say("local origin failed: \(e)"); self?.stopNow()
                    default: break
                    }
                }
                listener = l
                l.start(queue: queue)
            } catch { say("local origin could not start: \(error)") }
        }
    }

    func stop() { queue.async { [self] in stopNow() } }
    private func stopNow() { listener?.cancel(); listener = nil }

    private func say(_ s: String) { let f = onLog; DispatchQueue.main.async { f?(s) } }

    /// Only a peer on this device is served (belt and braces: the listener already binds loopback only).
    static func isLoopback(_ e: NWEndpoint) -> Bool {
        guard case .hostPort(let h, _) = e else { return false }
        switch h {
        case .ipv4(let a): return a == IPv4Address.loopback
        case .ipv6(let a): return a == IPv6Address.loopback
        case .name(let n, _): return n == "localhost" || n == LocalOrigin.bindHost
        @unknown default: return false
        }
    }

    private func accept(_ c: NWConnection) {
        guard Self.isLoopback(c.endpoint) else { c.cancel(); return }
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ got: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            guard let self else { c.cancel(); return }
            var acc = got
            if let data { acc.append(data) }
            switch LocalOrigin.parse(acc) {
            case .complete(let req): self.send(c, self.answer(req))
            case .bad(let status): self.send(c, .text(status, "bad request"))
            case .incomplete:
                if done || err != nil { c.cancel() } else { self.read(c, acc) }
            }
        }
    }

    private func answer(_ r: OriginRequest) -> OriginResponse {
        guard let vault else { return .text(503, "no vault yet") }
        let notify = onWrite
        return LocalOrigin.respond(r, port: port, pageDir: pageDir, vault: vault,
                                   wrote: { name in DispatchQueue.main.async { notify?(name) } })
    }

    private func send(_ c: NWConnection, _ r: OriginResponse) {
        c.send(content: r.bytes(), completion: .contentProcessed { _ in c.cancel() })   // answer, then let go
    }
}
#endif

// Regression guard: UI-12 P1/P2 · no socket: parsing, routing, the origin checks and each channel's landing, on a temp vault.
func localOriginSelftest() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String, _ got: Any = "") {
        print("\(pass ? "ok  " : "FAIL") local origin, \(what)\(pass ? "" : " — got \(got)")"); ok = ok && pass
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("recense-origin-\(UUID().uuidString)")
    let vault = root.appendingPathComponent("vault"), page = root.appendingPathComponent("pwa")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    try? fm.createDirectory(at: page, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try? Data("<!doctype html>editor".utf8).write(to: page.appendingPathComponent("index.html"))
    try? Data("secret".utf8).write(to: root.appendingPathComponent("outside.txt"))
    let port: UInt16 = 47823
    let me = "127.0.0.1:\(port)", origin = "http://127.0.0.1:\(port)"
    func req(_ m: String, _ p: String, host: String = me, origin o: String? = origin, body: Any? = nil) -> OriginRequest {
        var h = ["host": host]
        if let o { h["origin"] = o }
        let b = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return OriginRequest(method: m, path: p, headers: h, body: b)
    }
    func go(_ r: OriginRequest) -> OriginResponse { LocalOrigin.respond(r, port: port, pageDir: page, vault: vault) }
    func answers(_ r: OriginResponse) -> [[String: Any]] {
        ((try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any])?["answers"] as? [[String: Any]] ?? []
    }
    func drain(_ entries: [[String: Any]]) -> [[String: Any]] { answers(go(req("POST", "/ui12/drain", body: ["entries": entries]))) }
    func file(_ n: String) -> String? { coordinatedRead(vault.appendingPathComponent(n).path) }

    check(LocalOrigin.bindHost == "127.0.0.1" && LocalOrigin.defaultPort == 47823, "binds 127.0.0.1 at a stable port, never 0.0.0.0")
    let raw = Data("POST /ui12/drain?x=1 HTTP/1.1\r\nHost: \(me)\r\nContent-Length: 2\r\n\r\n{}".utf8)
    check(LocalOrigin.parse(raw) == .complete(OriginRequest(method: "POST", path: "/ui12/drain", headers: ["host": me, "content-length": "2"], body: Data("{}".utf8))),
          "parses a whole request (query dropped)")
    check(LocalOrigin.parse(raw.prefix(raw.count - 1)) == .incomplete, "waits for the rest of the body")
    check(LocalOrigin.parse(Data("GARBAGE\r\n\r\n".utf8)) == .bad(400), "a broken request line is refused")
    check(String(decoding: OriginResponse.text(200, "x").bytes(), as: UTF8.self).contains("Connection: close"), "every answer closes its connection")

    let home = go(req("GET", "/", origin: nil))
    check(home.status == 200 && home.type.hasPrefix("text/html") && String(decoding: home.body, as: UTF8.self).contains("editor"), "/ serves the editor page", home.status)
    check(go(req("GET", "/../outside.txt", origin: nil)).status == 404 && go(req("GET", "/outside.txt", origin: nil)).status == 404,
          "nothing outside the page's own files is served")
    check(go(req("GET", "/", host: "evil.example:\(port)", origin: nil)).status == 403, "another Host name (DNS rebinding) is refused")
    check(go(req("POST", "/ui12/drain", origin: "https://evil.example", body: ["entries": []])).status == 403, "a POST from another origin is refused")
    check(go(req("POST", "/ui12/drain", origin: nil, body: ["entries": []])).status == 403, "a POST with no Origin is refused")
    check(go(req("GET", "/ui12/state", origin: "https://evil.example")).status == 403, "another origin cannot read the state")
    check(!String(decoding: go(req("GET", "/ui12/state")).bytes(), as: UTF8.self).lowercased().contains("access-control"), "no CORS header, ever")

    // editor: lands as App.saveNow lands it
    var a = drain([["channel": "editor", "base": "", "mine": "a\nb\nc"]])
    check(a.first?["status"] as? String == "written" && file("draftpad.md") == "a\nb\nc", "a first save writes draftpad.md", a)
    coordinatedWrite("phone\na\nb\nc", to: vault.appendingPathComponent("draftpad.md").path)   // another device's edit arrived
    a = drain([["channel": "editor", "base": "a\nb\nc", "mine": "a\nb\nc\nbrowser"]])
    check(a.first?["status"] as? String == "merged" && file("draftpad.md") == "phone\na\nb\nc\nbrowser", "both sides' lines merge (notesync 3-way)", a)
    a = drain([["channel": "editor", "base": "phone\na\nb\nc\nbrowser", "mine": "phone\na\nb\nc\nbrowser"]])
    check(a.first?["status"] as? String == "written", "nothing new: nothing written", a)
    coordinatedWrite("phone\na\nB1\nc\nbrowser", to: vault.appendingPathComponent("draftpad.md").path)
    a = drain([["channel": "editor", "base": "phone\na\nb\nc\nbrowser", "mine": "phone\na\nB2\nc\nbrowser"]])
    let sib = a.first?["sibling"] as? String ?? ""
    check(a.first?["status"] as? String == "conflict" && file("draftpad.md") == "phone\na\nB2\nc\nbrowser"
          && file(sib) == "phone\na\nB1\nc\nbrowser", "the same line changed both ways: mine in the note, theirs beside it", a)
    a = drain([["channel": "editor", "base": "phone\na\nB2\nc\nbrowser", "mine": "phone\na\nB2\nc\nbrowser"]])
    check(a.first?["status"] as? String == "written", "settled after the conflict", a)

    // ink / matter: compare-and-swap, the page unions
    a = drain([["channel": "ink", "base": "", "mine": "{\"v\":1}"], ["channel": "matter", "base": "", "mine": "{\"m\":1}"]])
    check(a.map { $0["status"] as? String ?? "" } == ["written", "written"] && file("draftpad.ink.json") == "{\"v\":1}"
          && file("draftpad.matter.json") == "{\"m\":1}", "ink and matter land in their own files", a)
    coordinatedWrite("{\"v\":2}", to: vault.appendingPathComponent("draftpad.ink.json").path)
    a = drain([["channel": "ink", "base": "{\"v\":1}", "mine": "{\"v\":3}"]])
    check(a.first?["status"] as? String == "stale" && a.first?["text"] as? String == "{\"v\":2}" && file("draftpad.ink.json") == "{\"v\":2}",
          "ink changed elsewhere: nothing written, the file goes back to the page to union", a)
    check(drain([["channel": "../x", "base": "", "mine": "x"]]).first?["status"] as? String == "refused", "an unknown channel is refused")

    let st = (try? JSONSerialization.jsonObject(with: go(req("GET", "/ui12/state")).body)) as? [String: Any]
    let chs = st?["channels"] as? [String: String]
    check(chs?["editor"] == "phone\na\nB2\nc\nbrowser" && chs?["ink"] == "{\"v\":2}", "the state returns each file as it is now", st ?? [:])
    return ok
}
