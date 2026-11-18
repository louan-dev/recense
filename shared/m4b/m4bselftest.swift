// Derived from Spec: FEAT-01
// `recense selftest m4b`: ChapterPlan and the M4B writer (invariant 4: chapter count = heading count).
import Foundation

#if os(macOS)
import AVFoundation

func m4bSelftest() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String, _ got: Any = "") { print("\(pass ? "ok  " : "FAIL") m4b, \(what)\(pass ? "" : " — got \(got)")"); ok = ok && pass }

    // ChapterPlan
    let rows = [ChapterRow(text: "# One", start: 2, level: 1), ChapterRow(text: "body", start: 3), ChapterRow(text: "## Two", start: 5, level: 2),
                ChapterRow(text: "## Same instant", start: 5, level: 2), ChapterRow(text: "##", start: 8, level: 2), ChapterRow(text: "# Late", start: 99, level: 1)]
    let plan = ChapterPlan.make(rows: rows, duration: 10)
    check(plan.count == 3 && plan[0].title == "One" && plan[1].title == "Two" && plan[2].title == "Chapter 3", "titles lose their # and empty ones are numbered", plan.map(\.title))
    check(plan.first?.start == 0 && plan.last?.end == 10 && plan[0].end == plan[1].start && plan[1].end == plan[2].start, "first starts at 0, each ends where the next starts, last ends at the duration", plan)
    check(ChapterPlan.make(rows: [ChapterRow(text: "body", start: 1)], duration: 4) == [M4BChapter(title: "Chapter 1", start: 0, end: 4)], "no heading is one chapter")
    check(ChapterPlan.make(rows: rows, duration: 0).isEmpty, "no duration, no chapters")
    check(ChapterPlan.make(rows: [ChapterRow(text: "# B", start: 6, level: 1), ChapterRow(text: "# A", start: 1, level: 1)], duration: 9).map(\.title) == ["A", "B"], "sorted by start")
    check(M4BWriter.iso639_2("vi") == "vie" && M4BWriter.iso639_2("fr-CA") == "fra" && M4BWriter.iso639_2("xx") == "und" && M4BWriter.iso639_2("eng") == "eng", "language codes")

    // The writer: a 6 s tone, three chapters
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("recense-m4b-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let tone = dir.appendingPathComponent("tone.caf")
    do {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: tone, settings: fmt.settings)
        let n = AVAudioFrameCount(22050 * 6)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        for i in 0..<Int(n) { buf.floatChannelData![0][i] = 0.3 * sin(2 * .pi * 440 * Float(i) / 22050) }
        try file.write(from: buf)
    } catch { check(false, "make the tone", error); return false }

    let chapters = ChapterPlan.make(rows: [ChapterRow(text: "# Alpha", start: 0, level: 1), ChapterRow(text: "## Bêta", start: 2, level: 2), ChapterRow(text: "## Gamma", start: 4, level: 2)], duration: 6)
    let meta = M4BMetadata(title: "Tone", author: "Recense", language: "vi")
    func sync<T: Sendable>(_ f: @escaping @Sendable () async -> T) -> T {
        let box = Box<T>(); let sem = DispatchSemaphore(value: 0)
        Task.detached { box.value = await f(); sem.signal() }
        sem.wait(); return box.value!
    }
    // Regression guard: BUG-33 — two audiobooks of the same name in one minute are two files, neither replaced
    let r = sync { await (M4BWriter.write(audio: tone, chapters: chapters, metadata: meta, dir: dir, base: "20261118-1500 Tone"),
                          M4BWriter.write(audio: tone, chapters: chapters, metadata: meta, dir: dir, base: "20261118-1500 Tone")) }
    guard case .success(let a) = r.0, case .success(let b) = r.1 else { check(false, "two writes succeed", r); return false }
    check(a != b && fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path) && b.lastPathComponent == "20261118-1500 Tone 2.m4b", "same name twice gives two files, none replaced", [a.lastPathComponent, b.lastPathComponent])
    check(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".partial") }.isEmpty, "no .partial file is left behind")

    // Regression guard: BUG-33 — a writer error comes back as an error, not silence
    let bad = sync { await M4BWriter.write(audio: dir.appendingPathComponent("missing.wav"), chapters: chapters, metadata: meta, dir: dir, base: "x") }
    if case .failure(let e) = bad { check(!e.description.isEmpty, "a missing input returns an error message", e) } else { check(false, "a missing input returns an error") }
    let junk = dir.appendingPathComponent("junk.wav"); try? Data("not audio".utf8).write(to: junk)
    let bad2 = sync { await M4BWriter.write(audio: junk, chapters: chapters, metadata: meta, dir: dir, base: "y") }
    if case .failure(let e) = bad2 { check(!e.description.isEmpty && !fm.fileExists(atPath: dir.appendingPathComponent("y.m4b").path), "an unreadable input returns an error and leaves no file", e) } else { check(false, "an unreadable input returns an error") }

    // Chapter count through AVFoundation (always) and ffprobe (when present)
    let asset = AVURLAsset(url: a)
    let groups = sync { (try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["vi", "en"])) ?? [] }
    let titles = groups.map { g in g.items.first { $0.commonKey == .commonKeyTitle }?.stringValue ?? "" }
    check(groups.count == 3 && titles == ["Alpha", "Bêta", "Gamma"], "AVAsset reads 3 chapters with their titles", titles)
    check(abs(CMTimeGetSeconds(asset.duration) - 6) < 0.3, "duration about 6 s", CMTimeGetSeconds(asset.duration))
    let ffprobe = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"].first { fm.isExecutableFile(atPath: $0) }
    if let ffprobe {
        let p = Process(); p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "error", "-show_chapters", "-show_entries", "chapter=start_time:chapter_tags=title:stream=codec_name:stream_tags=language", "-of", "json", a.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); let out = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let s = String(decoding: out, as: UTF8.self)
        let n = s.components(separatedBy: "\"start_time\"").count - 1
        check(n == 3, "ffprobe counts 3 chapters", s)
        check(s.contains("\"vie\""), "ffprobe shows the vie language tag", s)
    } else { print("skip m4b, ffprobe not found (AVAsset check above stands in)") }
    return ok
}

private final class Box<T>: @unchecked Sendable { var value: T? }
#endif
