import Foundation

// Derived from Spec: FEAT-39 (P2 transfer). Two token-guarded calls for the iPad's "Live edits" screen:
//   GET  /api/live            the manifest the Mac's watcher keeps current (sync/src/livestate.mjs, ~/Recense/live/live.json)
//   POST /api/live/snapshot   {"worktree": "<name>"} → runs `live.zsh snapshot --json <name>` and says what it filed
// The logic (what is listed, the skip list, the snapshot) is livestate.mjs; this file only carries it over the LAN.
// No network in here, so it can be tested by itself.

typealias HubLiveRunner = (_ args: [String]) -> (status: Int32, out: String)

/// The manifest as the watcher wrote it. No file yet means nothing is uncommitted anywhere, not an error.
func hubLiveManifest(path: String) -> HubReply {
    guard let data = FileManager.default.contents(atPath: path) else {
        return HubReply(status: 200, body: ["generated": NSNull(), "worktrees": [Any]()])
    }
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["worktrees"] is [Any] else {
        return HubReply(status: 503, body: ["status": "wait", "error": "the manifest can't be read right now"])
    }
    return HubReply(status: 200, body: obj)
}

/// The one worktree a snapshot may name: a name the manifest lists. Never a path, never anything else.
func hubLiveWorktreeName(body: Data, manifestPath: String) -> String? {
    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let name = obj["worktree"] as? String,
          !name.isEmpty,
          let data = FileManager.default.contents(atPath: manifestPath),
          let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = m["worktrees"] as? [[String: Any]]
    else { return nil }
    return list.contains(where: { ($0["name"] as? String) == name }) ? name : nil
}

func hubLiveSnapshot(body: Data, manifestPath: String, script: String, run: HubLiveRunner) -> HubReply {
    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], obj["worktree"] is String
    else { return HubReply(status: 400, body: ["error": "need {worktree}"]) }
    guard let name = hubLiveWorktreeName(body: body, manifestPath: manifestPath)
    else { return HubReply(status: 404, body: ["error": "that worktree has no listed changes"]) }
    // the name travels as its own argument, never inside a shell string
    let r = run(["/bin/zsh", script, "snapshot", "--json", name])
    let line = r.out.split(separator: "\n").last.map(String.init) ?? ""
    guard let d = line.data(using: .utf8), let reply = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let st = reply["status"] as? String, st == "made" || st == "refused"
    else { return HubReply(status: 500, body: ["status": "failed", "error": "the snapshot did not finish (exit \(r.status))"]) }
    return HubReply(status: 200, body: reply)
}

/// Runs a program, reads its one-line answer, gives up after two minutes.
func hubLiveProcessRunner(_ args: [String]) -> (status: Int32, out: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (127, "") }
    var data = Data(); let done = DispatchSemaphore(value: 0)
    DispatchQueue(label: "recense.hub.live.read").async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
    if done.wait(timeout: .now() + 120) == .timedOut { p.terminate(); _ = done.wait(timeout: .now() + 5); return (124, "") }
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func hubLiveSelftest() -> Bool {
    var ok = true
    func check(_ name: String, _ cond: Bool) { if !cond { print("FAIL \(name)"); ok = false } }
    let dir = NSTemporaryDirectory() + "hublive-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let manifest = dir + "/live.json"

    // no manifest yet: an empty list, not an error
    var r = hubLiveManifest(path: manifest)
    check("missing", r.status == 200 && (r.body["worktrees"] as? [Any])?.isEmpty == true && r.body["generated"] is NSNull)
    // a manifest comes back as written
    let text = #"{"generated":"2026-11-19T20:00:00.000Z","worktrees":[{"name":"live-edits","path":"/x","branch":"work/live-edits","head":"abc","files":[{"path":"a.txt","status":"M","mtime":"2026-11-19T19:59:00.000Z","added":1,"deleted":0,"state":"UNBUILT"}]}]}"#
    try? text.write(toFile: manifest, atomically: true, encoding: .utf8)
    r = hubLiveManifest(path: manifest)
    let wts = r.body["worktrees"] as? [[String: Any]]
    check("read", r.status == 200 && r.body["generated"] as? String == "2026-11-19T20:00:00.000Z" && wts?.first?["name"] as? String == "live-edits"
          && ((wts?.first?["files"] as? [[String: Any]])?.first?["path"] as? String) == "a.txt")
    // a half-written or damaged file asks the reader to wait; it never reaches the iPad as an empty list
    try? "{\"generated\":".write(toFile: manifest, atomically: true, encoding: .utf8)
    r = hubLiveManifest(path: manifest)
    check("damaged", r.status == 503 && r.body["status"] as? String == "wait")
    try? text.write(toFile: manifest, atomically: true, encoding: .utf8)

    // which worktree a snapshot may name: only one the manifest lists
    func name(_ s: String) -> String? { hubLiveWorktreeName(body: Data(s.utf8), manifestPath: manifest) }
    check("name listed", name(#"{"worktree":"live-edits"}"#) == "live-edits")
    check("name unknown", name(#"{"worktree":"other"}"#) == nil)
    check("name path", name(#"{"worktree":"/Users/x/live-edits"}"#) == nil && name(#"{"worktree":"../live-edits"}"#) == nil)
    check("name empty", name(#"{"worktree":""}"#) == nil && name(#"{}"#) == nil && name(#"{"worktree":7}"#) == nil && name("nope") == nil)
    check("name injection", name(#"{"worktree":"live-edits; rm -rf ~"}"#) == nil)

    // the snapshot call: arguments, the three answers, the two failures
    var seen: [String] = []
    var calls = 0
    func snap(_ body: String, out: String, status: Int32 = 0) -> HubReply {
        hubLiveSnapshot(body: Data(body.utf8), manifestPath: manifest, script: "/live.zsh") { a in calls += 1; seen = a; return (status, out) }
    }
    r = snap(#"{"worktree":"live-edits"}"#, out: #"{"ok":true,"status":"made","worktree":"live-edits","sha":"aaaa","state":"UNBUILT","files":3,"zip":false}"# + "\n")
    check("made", r.status == 200 && r.body["status"] as? String == "made" && r.body["files"] as? Int == 3 && r.body["state"] as? String == "UNBUILT")
    check("args", seen == ["/bin/zsh", "/live.zsh", "snapshot", "--json", "live-edits"])
    r = snap(#"{"worktree":"live-edits"}"#, out: #"{"ok":false,"status":"refused","worktree":"live-edits","reason":"secret","path":"notes.txt"}"#, status: 2)
    check("refused", r.status == 200 && r.body["status"] as? String == "refused" && r.body["reason"] as? String == "secret")
    calls = 0
    r = snap(#"{"worktree":"other"}"#, out: "")
    check("unknown not run", r.status == 404 && calls == 0)
    r = snap("not json", out: "")
    check("bad body", r.status == 400 && calls == 0)
    r = snap(#"{"worktree":"live-edits"}"#, out: "node: command not found\n", status: 127)
    check("garbage", r.status == 500 && r.body["status"] as? String == "failed")
    r = snap(#"{"worktree":"live-edits"}"#, out: "", status: 124)
    check("timeout", r.status == 500 && (r.body["error"] as? String)?.contains("124") == true)
    r = snap(#"{"worktree":"live-edits"}"#, out: #"{"status":"weird"}"#)
    check("unknown status", r.status == 500)

    // the real runner: one line out, the exit status back, a missing program is a failure not a crash
    let echo = hubLiveProcessRunner(["/bin/echo", "hello"])
    check("runner out", echo.status == 0 && echo.out == "hello\n")
    check("runner missing", hubLiveProcessRunner(["/nonexistent/program"]).status == 127)
    check("runner status", hubLiveProcessRunner(["/usr/bin/false"]).status == 1)
    return ok
}
