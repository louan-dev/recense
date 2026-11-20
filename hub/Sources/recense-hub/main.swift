import Foundation

// Derived from Spec: FEAT-18 (H1), FEAT-39 (P2). recense-hub [serve|pair|selftest] [--port N] [--shell DIR] [--note FILE] [--name mac] [--live FILE] [--live-script FILE] [--conf DIR] [--no-mdns]
// A headless helper: serves Draftpad at https://recense.local and keeps the note in step between devices. It is never
// the only copy of anything; every device keeps its own.

let home = NSHomeDirectory()
var args = Array(CommandLine.arguments.dropFirst())
let command = args.first.flatMap { ["serve", "pair", "selftest"].contains($0) ? $0 : nil } ?? "serve"
if args.first == command { args.removeFirst() }

func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let env = ProcessInfo.processInfo.environment
let confDir = opt("--conf") ?? env["HUB_CONF"] ?? home + "/.config/recense/hub"   // certificate and token; another folder lets a test run a hub of its own
let port = UInt16(opt("--port") ?? env["HUB_PORT"] ?? "443") ?? 443
let shell = opt("--shell") ?? env["HUB_SHELL"] ?? home + "/Developer/recense/editor/dist/pwa"
let notePath = opt("--note") ?? env["HUB_NOTE"]
    ?? home + "/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian/draftpad.md"
let hubName = opt("--name") ?? env["HUB_NAME"] ?? "mac"
let liveFile = opt("--live") ?? env["HUB_LIVE"] ?? home + "/Recense/live/live.json"
let liveScript = opt("--live-script") ?? env["HUB_LIVE_SCRIPT"] ?? home + "/Developer/recense/sync/bin/live.zsh"

func readToken() -> String {
    let path = confDir + "/token"
    if let t = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let t = bytes.map { String(format: "%02x", $0) }.joined()
    try? FileManager.default.createDirectory(atPath: confDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: path, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600])
    return t
}

switch command {
case "selftest":
    let ok = hubNoteSelftest() && hubLiveSelftest() && notesyncSelftest()
    print(ok ? "hub selftest ok" : "hub selftest FAILED")
    exit(ok ? 0 : 1)

case "pair":
    print("https://recense.local/#pair=\(readToken())")

default:
    let p12 = confDir + "/tls.p12"
    let pass = (try? String(contentsOfFile: confDir + "/tls.p12.pass", encoding: .utf8)) ?? ""
    guard let identity = HubServer.identity(p12: p12, passphrase: pass) else {
        FileHandle.standardError.write(Data("hub: no certificate at \(p12). Run: zsh hub/scripts/hub-ca.zsh \(hubName)\n".utf8))
        exit(2)
    }
    guard FileManager.default.fileExists(atPath: shell + "/index.html") else {
        FileHandle.standardError.write(Data("hub: no page at \(shell)/index.html (run npm run build in editor/)\n".utf8))
        exit(2)
    }
    let server = HubServer(port: port, shell: shell, notePath: notePath, token: readToken(), name: hubName,
                           liveFile: liveFile, liveScript: liveScript)
    do { try server.start(identity: identity) } catch {
        FileHandle.standardError.write(Data("hub: could not listen on \(port): \(error)\n".utf8)); exit(1)
    }
    print("hub: https on port \(port), page \(shell), note \(notePath)")
    let bonjour = HubBonjour(queue: DispatchQueue(label: "recense.hub.mdns"))
    if !args.contains("--no-mdns") {
        if !bonjour.start(names: ["recense.local", "\(hubName).recense.local"], port: port) {
            FileHandle.standardError.write(Data("hub: names not announced (no network address?); the hub still answers by address\n".utf8))
        }
    }
    withExtendedLifetime(bonjour) { dispatchMain() }
}
