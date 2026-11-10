// SSH from Recense's terminal on every device (owner, 2026-11-10). One host list, ~/Recense/ssh/hosts.json, plain JSON
// so it travels with the Recense folder to the other devices. Each host has routes tried in order, the first that answers
// wins, so a connection works offline when it can and falls back online when it must:
//   lan       the same Wi-Fi or cable, by name or Bonjour (.local): no internet needed
//   tailscale WireGuard between the owner's own devices (self-hostable with Headscale; tailscale is optional)
//   tunnel    Cloudflare Tunnel (cloudflared access ssh): the last, online-only fallback, optional and replaceable
// Keys, not passwords: each device has its own key (the Mac's in ~/.ssh, the iPhone's in its Keychain).
// With no hosts.json, the Host entries in ~/.ssh/config are offered as LAN routes (read only, never rewritten).
import Foundation

struct SSHRoute: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case lan, tailscale, tunnel }
    var kind: Kind
    var address: String
    var port: Int = 22
}

struct SSHHost: Codable, Equatable, Sendable {
    var name: String
    var user: String
    var routes: [SSHRoute]
}

enum SSHHosts {
    static var file: URL {
        if let p = ProcessInfo.processInfo.environment["RECENSE_SSH_HOSTS"] { return URL(fileURLWithPath: p) }
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        #else
        let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        return home.appendingPathComponent("Recense/ssh/hosts.json")
    }

    static func load() -> [SSHHost] {
        if let d = try? Data(contentsOf: file), let h = try? JSONDecoder().decode([SSHHost].self, from: d) { return h }
        #if os(macOS)
        let cfg = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        return fromConfig((try? String(contentsOf: cfg, encoding: .utf8)) ?? "")
        #else
        return []
        #endif
    }

    static func save(_ hosts: [SSHHost]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(hosts).write(to: file, options: .atomic)
    }

    /// ~/.ssh/config's concrete Host entries (no wildcards) as one LAN route each.
    static func fromConfig(_ text: String) -> [SSHHost] {
        var out: [SSHHost] = [], cur: SSHHost?
        func flush() { if let c = cur { out.append(c) }; cur = nil }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let sp = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { continue }
            let key = line[..<sp].lowercased(), val = line[sp...].trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
            switch key {
            case "host":
                flush()
                if let n = val.split(separator: " ").first.map(String.init), !n.contains("*"), !n.contains("?") {
                    cur = SSHHost(name: n, user: NSUserName(), routes: [SSHRoute(kind: .lan, address: n)])
                }
            case "hostname": if cur != nil { cur!.routes[0].address = val }
            case "user": cur?.user = val
            case "port": if cur != nil, let p = Int(val) { cur!.routes[0].port = p }
            default: break
            }
        }
        flush()
        return out
    }

    /// Single-quoted for zsh.
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The zsh script the Mac's terminal runs: each route in order, a 3-second reachability probe, then ssh on the first
    /// that answers. A tunnel route is used only when cloudflared is installed.
    static func connectScript(_ h: SSHHost) -> String {
        var s = "print -r -- \(q("Connecting to \(h.name)…"))\n"
        for r in h.routes {
            let dest = q("\(h.user)@\(r.address)")
            let ssh = "exec /usr/bin/ssh -o ConnectTimeout=6 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -p \(r.port)"
            switch r.kind {
            case .lan, .tailscale:
                s += "if /usr/bin/nc -z -G 3 \(q(r.address)) \(r.port) 2>/dev/null; then print -r -- \(q("  via \(r.kind.rawValue) (\(r.address))")); \(ssh) \(dest); fi\n"
            case .tunnel:
                s += "if command -v cloudflared >/dev/null; then print -r -- \(q("  via tunnel (\(r.address))")); \(ssh) -o \(q("ProxyCommand=cloudflared access ssh --hostname %h")) \(dest); fi\n"
            }
        }
        s += "print -r -- \(q("No route to \(h.name) answered (\(h.routes.map(\.kind.rawValue).joined(separator: ", "))). Press Return."))\nread -r _\n"
        return s
    }
}

#if os(macOS)
/// `recense selftest`: the host list and the route order, no network.
func sshSelftest() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String, _ got: Any = "") { print("\(pass ? "ok  " : "FAIL") ssh, \(what)\(pass ? "" : " — got \(got)")"); ok = ok && pass }
    let cfg = """
    Host *
      ServerAliveInterval 30
    Host mini
      HostName mini.local
      User louan
      Port 2222
    Host pi # the garden
      HostName=10.0.0.9
    """
    let hosts = SSHHosts.fromConfig(cfg)
    check(hosts.map(\.name) == ["mini", "pi"], "~/.ssh/config's concrete hosts, no wildcard", hosts.map(\.name))
    check(hosts.first?.routes == [SSHRoute(kind: .lan, address: "mini.local", port: 2222)] && hosts.first?.user == "louan",
          "HostName, User and Port are read", hosts.first as Any)
    check(hosts.last?.routes.first?.address == "10.0.0.9", "Key=value form is read", hosts.last as Any)

    let h = SSHHost(name: "Mac", user: "me", routes: [SSHRoute(kind: .lan, address: "mac.local"),
                                                     SSHRoute(kind: .tailscale, address: "100.64.0.2"),
                                                     SSHRoute(kind: .tunnel, address: "ssh.example.org")])
    let s = SSHHosts.connectScript(h)
    let i = [s.range(of: "mac.local")?.lowerBound, s.range(of: "100.64.0.2")?.lowerBound, s.range(of: "ssh.example.org")?.lowerBound]
    check(i.allSatisfy { $0 != nil } && i[0]! < i[1]! && i[1]! < i[2]!, "routes are tried LAN, then Tailscale, then the tunnel")
    check(s.contains("ProxyCommand=cloudflared access ssh"), "the tunnel goes through cloudflared")
    check(SSHHosts.q("it's") == "'it'\\''s'", "quoting survives an apostrophe")

    // the script is valid zsh
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-n", "-c", s]
    try? p.run(); p.waitUntilExit()
    check(p.terminationStatus == 0, "the connect script parses")

    // hosts.json round trip
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("recense-ssh-\(UUID().uuidString)/hosts.json")
    setenv("RECENSE_SSH_HOSTS", tmp.path, 1)
    defer { unsetenv("RECENSE_SSH_HOSTS"); try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
    try? SSHHosts.save([h])
    check(SSHHosts.load() == [h], "hosts.json reads back")
    return ok
}
#endif
