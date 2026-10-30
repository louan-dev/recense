// Gallery Files (macOS): puts the archive in Finder's sidebar as a File Provider location and keeps it current, and
// opened by hand shows Gallery's window with the assistant (Window.swift). At login it has no window; it stays running
// (login item) and every 60 s tells the system to ask the extension what changed
// (there's no push without a paid account: docs/architecture.md §3).
//   "Gallery Files.app/Contents/MacOS/GalleryFiles" remove   takes the location out of Finder (R2 is untouched)
import AppKit
import FileProvider

let domain: NSFileProviderDomain = {
    let d = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("chauphan"), displayName: "Chauphan")
    d.supportsSyncingTrash = false  // read-only: deleting is refused anyway, and R2's trash is the Worker's
    return d
}()

func log(_ s: String) { FileHandle.standardError.write(Data("\(Date()) \(s)\n".utf8)) }

// this Mac's Access service token, from the login Keychain (gallery-access, written by `security`: reading it through
// `security` needs no prompt) into the App Group, the only place the sandboxed extension can read it
func handOverToken() -> Bool {
    func read(_ account: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "gallery-access", "-a", account, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !s.isEmpty ? s : nil
    }
    guard let id = read("client-id"), let secret = read("client-secret") else { return false }
    let file = Gallery.tokenFile
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let d = try? JSONEncoder().encode(["id": id, "secret": secret]),
          FileManager.default.createFile(atPath: file.path, contents: d, attributes: [.posixPermissions: 0o600]) else { return false }
    return true
}

if CommandLine.arguments.dropFirst().first == "remove" {
    let done = DispatchSemaphore(value: 0)
    NSFileProviderManager.remove(domain) { e in log(e.map { "remove failed: \($0)" } ?? "removed"); done.signal() }
    done.wait()
    exit(0)
}

guard handOverToken() else {
    log("no gallery-access token in the Keychain")
    exit(1)
}
NSFileProviderManager.add(domain) { e in
    log(e.map { "add failed: \($0)" } ?? "Chauphan is in Finder")
}

Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
    NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { e in if let e { log("signal: \(e)") } }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let galleryWindow = GalleryWindow()
app.delegate = galleryWindow
app.run()
