// Derived from Spec: BUG-33
// The bookkeeping every export and download needs so two of them never meet: names that are reserved while a job
// is still running (not only once its file exists), a free name that never overwrites, one export at a time,
// an honest failure message, and a sweep for temp folders nobody deleted. Foundation only: the Mac's M4B export
// (strip/recense.swift) and the iPhone's (mobile/HostApp/iOS/Player.swift) both use it.
import Foundation

enum ExportJobs {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reserved: Set<String> = []

    /// 20261118-1432, or -2, -3 … when that name is taken by a file in `dir` (any of `exts`) or by a job still running.
    /// The name is reserved at once: two exports begun in the same minute never share a stamp (M-B1).
    static func stamp(in dir: URL, exts: [String] = ["md", "vtt", "m4b"], now: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmm"
        let base = f.string(from: now)
        lock.lock(); defer { lock.unlock() }
        var name = base, n = 2
        while reserved.contains(name) || exts.contains(where: { FileManager.default.fileExists(atPath: dir.appendingPathComponent(name + "." + $0).path) }) {
            name = "\(base)-\(n)"; n += 1
        }
        reserved.insert(name)
        return name
    }

    /// `dir/base.ext`, or `dir/base 2.ext` … : a name no file has. Never overwrites (M-B2).
    static func freeURL(_ dir: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        func url(_ b: String) -> URL { ext.isEmpty ? dir.appendingPathComponent(b) : dir.appendingPathComponent(b).appendingPathExtension(ext) }
        var n = 2, u = url(base)
        while fm.fileExists(atPath: u.path) { u = url("\(base) \(n)"); n += 1 }
        return u
    }

    /// What the owner reads when ffmpeg fails: the last line it said, or that it was stopped for time (M-B4).
    static func failure(status: Int32, stderr: String, timedOut: Bool = false) -> String {
        let last = stderr.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        if timedOut { return "ffmpeg took too long and was stopped" + (last.isEmpty ? "" : ": " + last) }
        return "ffmpeg couldn't make the audiobook (exit \(status))" + (last.isEmpty ? "" : ": " + last)
    }

    /// Temp folders from an export that never cleaned up (a crash, a cancelled share sheet): gone after `olderThan`.
    @discardableResult
    static func sweepTemp(_ dir: URL, olderThan: TimeInterval, now: Date = Date()) -> Int {
        let fm = FileManager.default
        var n = 0
        for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if now.timeIntervalSince(m) >= olderThan, (try? fm.removeItem(at: u)) != nil { n += 1 }
        }
        return n
    }
}

/// One export at a time: ffmpeg on a long recording is heavy, and two at once raced for one working folder (M-B1).
actor ExportGate {
    static let shared = ExportGate()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func run<T: Sendable>(_ job: @Sendable () async -> T) async -> T {
        if busy { await withCheckedContinuation { waiting.append($0) } }
        busy = true
        let r = await job()
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        return r
    }
}

#if os(macOS)
/// `recense selftest`: the export bookkeeping (BUG-33).
func exportJobsSelftest() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String, _ got: Any = "") { print("\(pass ? "ok  " : "FAIL") exportjobs, \(what)\(pass ? "" : " — got \(got)")"); ok = ok && pass }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recense-export-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Regression guard: BUG-33 M-B1 — two exports begun in one minute, neither file written yet, get two stamps
    let a = ExportJobs.stamp(in: dir), b = ExportJobs.stamp(in: dir), c = ExportJobs.stamp(in: dir)
    check(Set([a, b, c]).count == 3 && b == a + "-2" && c == a + "-3", "three exports in one minute get three stamps", [a, b, c])
    try? Data("x".utf8).write(to: dir.appendingPathComponent(a + "-4.m4b"))
    let d = ExportJobs.stamp(in: dir)
    check(d == a + "-5", "a stamp whose file exists is skipped too", d)

    // Regression guard: BUG-33 M-B2 — a download in the same minute with the same title never overwrites
    let f1 = ExportJobs.freeURL(dir, base: "20261118-1432 Talk", ext: "m4a")
    try? Data("one".utf8).write(to: f1)
    let f2 = ExportJobs.freeURL(dir, base: "20261118-1432 Talk", ext: "m4a")
    check(f1.lastPathComponent == "20261118-1432 Talk.m4a" && f2.lastPathComponent == "20261118-1432 Talk 2.m4a", "a taken name gets 2, not an overwrite", f2.lastPathComponent)

    // Regression guard: BUG-33 M-B4 — a failure says what ffmpeg said, a timeout says so
    check(ExportJobs.failure(status: 1, stderr: "x\nInvalid data found when processing input\n").hasSuffix("Invalid data found when processing input"), "ffmpeg's last line reaches the owner")
    check(ExportJobs.failure(status: 255, stderr: "", timedOut: true).contains("too long") && !ExportJobs.failure(status: 15, stderr: "").contains("too long"), "a run stopped by its time limit reads as a timeout (by the watchdog, not by exit code)")

    // one at a time
    let sem = DispatchSemaphore(value: 0)
    final class Count: @unchecked Sendable {
        var now = 0, most = 0, done = 0; let l = NSLock()
        func enter() { l.lock(); now += 1; most = max(most, now); l.unlock() }
        func leave() -> Bool { l.lock(); defer { l.unlock() }; now -= 1; done += 1; return done == 4 }
    }
    let n = Count()
    for _ in 0..<4 {
        Task.detached {
            await ExportGate.shared.run {
                n.enter()
                try? await Task.sleep(nanoseconds: 20_000_000)
                if n.leave() { sem.signal() }
            }
        }
    }
    check(sem.wait(timeout: .now() + 10) == .success && n.most == 1, "exports run one at a time", n.most)

    // M-B5: temp folders left behind go after a day, a fresh one stays
    let old = dir.appendingPathComponent("old"), fresh = dir.appendingPathComponent("fresh")
    for u in [old, fresh] { try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: old.path)
    let swept = ExportJobs.sweepTemp(dir, olderThan: 86_400)
    check(swept >= 1 && !FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: fresh.path), "an old temp folder is swept, a fresh one stays", swept)
    return ok
}
#endif
