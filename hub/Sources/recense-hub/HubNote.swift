import Foundation

// Derived from Spec: FEAT-18 (H1b). One note save, decided by the same rules as the apps (shared/notesync.swift):
// a save never writes over a note it could not read, and a real conflict keeps both versions (mine in the file,
// theirs beside it). No network in here, so it can be tested by itself.

struct HubReply { var status: Int; var body: [String: Any] }

func hubSaveNote(path: String, base: String?, mine: String) -> HubReply {
    let now = readNote(path)
    guard let base = base else {
        switch planBlindSave(mine: mine, now: now) {
        case .wait:
            return HubReply(status: 503, body: ["status": "wait", "error": "the note can't be read right now"])
        case .recovered(let seen, let joined):
            if joined != seen, !coordinatedWrite(joined, to: path) { return writeFailed() }
            return HubReply(status: 200, body: ["status": "recovered", "text": joined, "base": joined])
        }
    }
    let theirs: String?
    switch now {
    case .unreadable: return HubReply(status: 503, body: ["status": "wait", "error": "the note can't be read right now"])
    case .missing: theirs = nil
    case .text(let t): theirs = t
    }
    switch planNoteSave(base: base, mine: mine, theirs: theirs) {
    case .write(let t):
        if t != theirs, !coordinatedWrite(t, to: path) { return writeFailed() }
        return HubReply(status: 200, body: ["status": "saved", "text": t, "base": t])
    case .adopt(let t):
        return HubReply(status: 200, body: ["status": "adopt", "text": t, "base": t])
    case .conflict(let m, let t):
        let sibling = freeSiblingPath(path)
        guard coordinatedWrite(t, to: sibling) else { return writeFailed() }
        guard coordinatedWrite(m, to: path) else { return writeFailed() }
        return HubReply(status: 200, body: ["status": "conflict", "text": m, "base": m,
                                            "sibling": (sibling as NSString).lastPathComponent])
    }
}

private func writeFailed() -> HubReply {
    HubReply(status: 500, body: ["status": "failed", "error": "the note could not be written"])
}

/// Constant-time token check, so a wrong guess leaks nothing about the right one.
func hubTokenOK(_ header: String?, token: String) -> Bool {
    guard let h = header, h.hasPrefix("Bearer ") else { return false }
    let a = Array(h.dropFirst(7).utf8), b = Array(token.utf8)
    guard a.count == b.count, !b.isEmpty else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
}

/// A request path may only name a file inside the shell folder.
func hubShellFile(root: String, urlPath: String) -> String? {
    var p = urlPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "/"
    p = p.removingPercentEncoding ?? p
    if p.hasSuffix("/") { p += "index.html" }
    if p.contains("..") || p.contains("\0") { return nil }
    let full = (root as NSString).appendingPathComponent(String(p.dropFirst()))
    let resolved = (full as NSString).standardizingPath
    guard resolved.hasPrefix((root as NSString).standardizingPath + "/") else { return nil }
    return resolved
}

func hubContentType(_ path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "html": return "text/html; charset=utf-8"
    case "js": return "text/javascript; charset=utf-8"
    case "css": return "text/css; charset=utf-8"
    case "json", "webmanifest": return "application/manifest+json"
    case "svg": return "image/svg+xml"
    case "png": return "image/png"
    default: return "application/octet-stream"
    }
}

func hubNoteSelftest() -> Bool {
    var ok = true
    func check(_ name: String, _ cond: Bool) { if !cond { print("FAIL \(name)"); ok = false } }
    let dir = NSTemporaryDirectory() + "hubtest-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let note = dir + "/draftpad.md"

    // a note that does not exist yet is created
    var r = hubSaveNote(path: note, base: nil, mine: "first")
    check("create", r.status == 200 && r.body["status"] as? String == "recovered" && (try? String(contentsOfFile: note)) == "first")
    // a clean save
    r = hubSaveNote(path: note, base: "first", mine: "first\nsecond")
    check("save", r.body["status"] as? String == "saved" && (try? String(contentsOfFile: note)) == "first\nsecond")
    // the file moved on and this browser changed nothing: adopt, write nothing
    try? "first\nsecond\nfrom the Mac".write(toFile: note, atomically: true, encoding: .utf8)
    r = hubSaveNote(path: note, base: "first\nsecond", mine: "first\nsecond")
    check("adopt", r.body["status"] as? String == "adopt" && r.body["text"] as? String == "first\nsecond\nfrom the Mac")
    // a first contact with a scrap never replaces the note: the note, then what was typed
    r = hubSaveNote(path: note, base: nil, mine: "a browser scrap")
    check("blind", r.body["text"] as? String == "first\nsecond\nfrom the Mac\na browser scrap")
    // both sides changed the same line: mine stays in the file, theirs goes beside it
    try? "one\ntwo\nthree".write(toFile: note, atomically: true, encoding: .utf8)
    try? "one\nTWO (mac)\nthree".write(toFile: note, atomically: true, encoding: .utf8)
    r = hubSaveNote(path: note, base: "one\ntwo\nthree", mine: "one\ntwo (phone)\nthree")
    let sib = r.body["sibling"] as? String
    check("conflict", r.body["status"] as? String == "conflict" && sib != nil
          && (try? String(contentsOfFile: note)) == "one\ntwo (phone)\nthree"
          && (try? String(contentsOfFile: dir + "/" + (sib ?? "x"))) == "one\nTWO (mac)\nthree")
    // the token
    check("token ok", hubTokenOK("Bearer abc123", token: "abc123"))
    check("token wrong", !hubTokenOK("Bearer abc124", token: "abc123"))
    check("token none", !hubTokenOK(nil, token: "abc123") && !hubTokenOK("Bearer x", token: ""))
    // the shell cannot be escaped
    check("shell index", hubShellFile(root: dir, urlPath: "/") == dir + "/index.html")
    check("shell up", hubShellFile(root: dir, urlPath: "/../etc/passwd") == nil)
    check("shell encoded up", hubShellFile(root: dir, urlPath: "/%2e%2e/etc/passwd") == nil)
    return ok
}
