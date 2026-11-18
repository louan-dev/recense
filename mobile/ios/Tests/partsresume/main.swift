// Regression guard: FEAT-31 P1 — a failure or a kill at part N resumes at part N+1; NoSuchUpload restarts; complete
// deletes the record; a failure leaves it. A fake transport stands in for the Worker.
import Foundation

nonisolated(unsafe) var failed = false
func check(_ ok: Bool, _ what: String, _ got: Any = "") { print("\(ok ? "ok  " : "FAIL") partsresume, \(what)\(ok ? "" : " — got \(got)")"); if !ok { failed = true } }

final class Fake: @unchecked Sendable {
    var calls: [String] = []            // "start", "part 3", "complete", "abort"
    var failPart: Int? = nil            // every attempt at this part fails
    var gone = false                    // R2 doesn't know the upload id
    var completeCode: Int? = nil        // the Worker refuses `complete` with this status
    var startCount = 0
    func call(_ extra: [String: String], _ method: String, _ body: Data?, _ from: URL?) async throws -> Data {
        let a = extra["action"] ?? ""
        if a == "start" { startCount += 1; calls.append("start"); return Data("up-\(startCount)".utf8) }
        if gone { throw FeedError.uploadGone }
        if a == "part", let n = Int(extra["part"] ?? "") {
            if n == failPart { throw FeedError.server(500) }
            calls.append("part \(n)"); return Data("etag\(n)".utf8)
        }
        if a == "complete", let c = completeCode { calls.append("complete"); throw FeedError.server(c) }
        calls.append(a); return Data("{}".utf8)
    }
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("partsresume-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let store = PartStore(dir: dir.appendingPathComponent("parts"))
// 40 MiB at 16 MiB a part = 3 parts
let file = dir.appendingPathComponent("big.bin")
FileManager.default.createFile(atPath: file.path, contents: Data(count: 40 << 20))
let feed = Feed()
let q = ["path": "Raven/big.bin"]
let key = PartStore.key(path: "Raven/big.bin", size: 40 << 20, mtime: Int(((try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0))

func run(_ f: Fake) async -> Error? {
    do { try await feed.putParts(q, file: file, size: 40 << 20, store: store, retryUnit: 1_000_000, call: f.call); return nil } catch { return error }
}

let sem = DispatchSemaphore(value: 0)
Task {
    // (d) a failure at part 3 keeps the record with parts 1-2
    let a = Fake(); a.failPart = 3
    let e1 = await run(a)
    check(e1 != nil && !a.calls.contains("abort"), "a failed part is thrown and nothing is aborted", a.calls)
    check(store.load(key)?.parts.map(\.partNumber) == [1, 2], "the failure leaves parts 1-2 on disk", store.load(key) as Any)
    // (a) the next attempt resumes at part 3, with no new start
    let b = Fake()
    let e2 = await run(b)
    check(e2 == nil && b.calls == ["part 3", "complete"], "the next attempt carries on from part 3", b.calls)
    // (c) complete deleted the record
    check(store.load(key) == nil, "complete deletes the record")
    // (b) R2 forgot the upload: the record goes, the error is thrown, the attempt after starts fresh
    let c = Fake(); c.failPart = 2
    _ = await run(c)
    let d = Fake(); d.gone = true
    let e3 = await run(d)
    check(e3 as? FeedError == .uploadGone && store.load(key) == nil, "NoSuchUpload drops the record", e3 as Any)
    let f = Fake()
    let e4 = await run(f)
    check(e4 == nil && f.calls.first == "start" && f.calls.contains("part 1"), "and the attempt after restarts from part 1", f.calls)
    // an old record is not trusted
    let g = Fake(); g.failPart = 2; _ = await run(g)
    if var r = store.load(key) { r.started = Date().addingTimeInterval(-7 * 86_400); store.save(key, r) }
    check(store.load(key) == nil, "a record older than 6 days is dropped")
    // review 1: the file is rewritten (same size, same modification date) between attempts: the old parts are not reused
    let h1 = Fake(); h1.failPart = 3; _ = await run(h1)
    let when = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date ?? Date()
    var bytes = Data(count: 40 << 20); bytes[0] = 7
    try? bytes.write(to: file)
    try? FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: file.path)
    let h2 = Fake()
    let e5 = await run(h2)
    check(e5 == nil && h2.calls.first == "abort" && h2.calls.contains("start") && h2.calls.contains("part 1"), "a rewritten file with the same size and date restarts, it never reuses old parts", h2.calls)
    // review 7: the Worker refuses `complete` (400): the parts are given back (abort) and the record dropped
    let i1 = Fake(); i1.completeCode = 400
    let e6 = await run(i1)
    check(e6 as? FeedError == .server(400) && i1.calls.contains("abort") && store.load(key) == nil, "a refused complete aborts and drops the record", i1.calls)
    sem.signal()
}
sem.wait()
exit(failed ? 1 : 0)
