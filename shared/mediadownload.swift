// Downloads: keep a copy of a piece of media on this device, as audio, audio+video or video only (owner, 2026-11-10).
// Everything lands in Recense/downloads/ (the places lane's folder contract) with downloads/manifest.json beside it:
// one entry per file with its source, mode, size and SHA-256, so every device can check it holds the same bytes.
// The Mac downloads with yt-dlp + ffmpeg (both free and open source, already used for Recense's own audio);
// a direct media link (an MP3, an MP4) is fetched as it is. Any file put into downloads/ some other way (Pulltube,
// Finder, AirDrop) is adopted into the manifest by `adopt()`. Other devices ask the Mac through downloads/.queue/:
// one small JSON file per request, plain files so any transport (sync, AirDrop, rclone) can carry them.
// The model half (modes, manifest, queue) is shared; the engine half (Process) is the Mac's.
import Foundation
import CryptoKit

enum DownloadMode: String, Codable, CaseIterable, Sendable {
    case audio, av, video

    var label: String { switch self { case .audio: "Audio"; case .av: "Audio + Video"; case .video: "Video" } }

    /// yt-dlp's format choice. Video is H.264 and audio AAC, the codecs every iPhone, iPad and Mac plays natively
    /// (checked 11-10 with ffprobe on a CC BY test video); the audio mode is the one Recense already uses.
    var ytdlpArgs: [String] { ytdlpArgs(maxHeight: 1080) }

    func ytdlpArgs(maxHeight h: Int) -> [String] {
        switch self {
        case .audio: ["-f", "bestaudio[ext=m4a]/bestaudio/best", "-x", "--audio-format", "m4a"]
        case .av:    ["-f", "bv*[vcodec^=avc1][height<=\(h)]+ba[ext=m4a]/b[ext=mp4][height<=\(h)]/bv*[height<=\(h)]+ba/b",
                      "--merge-output-format", "mp4"]
        case .video: ["-f", "bv*[vcodec^=avc1][height<=\(h)]/bv*[height<=\(h)]/bv*", "--remux-video", "mp4"]
        }
    }
}

struct DownloadEntry: Codable, Equatable, Sendable {
    var name: String        // the file's name where it lives: downloads/, or library/Music/ once settled (FEAT-12)
    var source: String      // the page or link it came from ("" when adopted with no known source)
    var mode: DownloadMode
    var bytes: Int64
    var sha256: String
    var saved: String       // ISO 8601
    var via: String         // "yt-dlp", "direct" or "adopted"
    var subtitles: [String]? = nil   // sidecar .vtt files beside it (en, vi, fr), the site's own captions
    var codecs: String? = nil        // as ffprobe read them, e.g. "h264,aac"
}

/// Pulltube-style choices (studied 11-10 in Pulltube 1.8.6: quality 360-2160, trim by timecodes, subtitles).
struct DownloadOptions: Sendable {
    var maxHeight = 1080
    var section: String? = nil       // "1:00-2:30": only that stretch
    var subtitles = true
}

struct DownloadRequest: Codable, Equatable, Sendable {
    var id: String
    var url: String
    var mode: DownloadMode
    var from: String        // the asking device's name
    var asked: String       // ISO 8601
}

enum Downloads {
    static let mediaExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "mp4", "m4v", "mov", "webm", "mkv"]
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv"]

    /// Recense/downloads/, the Downloads home (homes.swift, FEAT-06): one folder, one definition.
    /// RECENSE_DOWNLOADS points it elsewhere (tests never touch the real folder).
    static var root: URL {
        if let p = ProcessInfo.processInfo.environment["RECENSE_DOWNLOADS"] { return URL(fileURLWithPath: p, isDirectory: true) }
        return Homes.url(.downloads)
    }
    static var manifestURL: URL { root.appendingPathComponent("manifest.json") }
    static var queueDir: URL { root.appendingPathComponent(".queue", isDirectory: true) }

    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    // MARK: manifest

    static func manifest() -> [DownloadEntry] {
        guard let d = try? Data(contentsOf: manifestURL) else { return [] }
        return (try? JSONDecoder().decode([DownloadEntry].self, from: d)) ?? []
    }

    static func write(_ entries: [DownloadEntry]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(entries.sorted { $0.saved > $1.saved }).write(to: manifestURL, options: .atomic)
    }

    /// Adds (or replaces, by name) one entry.
    static func record(_ entry: DownloadEntry) throws {
        var all = manifest().filter { $0.name != entry.name }
        all.append(entry)
        try write(all)
    }

    static func sha256(_ url: URL) throws -> String {
        let h = FileHandle(forReadingAtPath: url.path)
        guard let h else { throw CocoaError(.fileReadNoSuchFile) }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func entry(for file: URL, source: String, mode: DownloadMode, via: String) throws -> DownloadEntry {
        let bytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        return DownloadEntry(name: file.lastPathComponent, source: source, mode: mode, bytes: bytes,
                             sha256: try sha256(file), saved: now(), via: via)
    }

    /// A name not yet taken in downloads/: "name 2.ext", as Safari and Finder do.
    static func freeName(_ name: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent(name).path) else { return name }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: root.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")).path) { n += 1 }
        return "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// Media files in downloads/ the manifest doesn't know (put there by Pulltube, Finder, AirDrop): recorded, with the
    /// mode read from the extension. Returns what was added.
    @discardableResult
    static func adopt() throws -> [DownloadEntry] {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let known = Set(manifest().map(\.name))
        var added: [DownloadEntry] = []
        // downloads/ itself and downloads/Pulltube/ (set as a destination in Pulltube; its files keep that subfolder)
        let pull = root.appendingPathComponent(pulltubeFolder, isDirectory: true)
        let found = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            + ((try? fm.contentsOfDirectory(at: pull, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
        for f in found where ready(f) {
            let ext = f.pathExtension.lowercased()
            let name = f.deletingLastPathComponent().standardizedFileURL == pull.standardizedFileURL
                ? pulltubeFolder + "/" + f.lastPathComponent : f.lastPathComponent
            guard mediaExtensions.contains(ext), !known.contains(name), !f.lastPathComponent.hasSuffix(".part") else { continue }
            var e = try entry(for: f, source: "", mode: videoExtensions.contains(ext) ? .av : .audio, via: "adopted")
            e.name = name
            try record(e); added.append(e)
        }
        return added
    }

    static let pulltubeFolder = "Pulltube"

    // Derived from Spec: BUG-16
    /// A file another app is still writing waits: one changed in the last 3 s, or a browser's partial name.
    static func ready(_ f: URL, now: Date = Date()) -> Bool {
        let n = f.lastPathComponent.lowercased()
        if [".part", ".crdownload", ".download", ".opdownload", ".tmp"].contains(where: { n.hasSuffix($0) }) { return false }
        let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return now.timeIntervalSince(m) >= quiet
    }
    /// How long a file must be left alone before it's taken (tests set 0 for files they just wrote).
    nonisolated(unsafe) static var quiet: TimeInterval = 3

    /// What lands in downloads/ by any route (Pulltube, Finder, AirDrop, a browser): recorded, and audio settled into
    /// Music, with no command run (BUG-16). The Mac's watcher runs this on every change to the folder; iOS on launch
    /// and on return to the app. The Mac also probes codecs first (adoptAndCheck).
    @discardableResult
    static func sweep() throws -> [DownloadEntry] {
        var out: [DownloadEntry] = []
        sweepStale()
        for e in try adopt() { out.append(try settle(e)) }
        // a file adopted before BUG-16 was fixed (recorded, never settled) settles now
        for e in manifest() where e.mode == .audio && FileManager.default.fileExists(atPath: root.appendingPathComponent(e.name).path) {
            if !out.contains(where: { $0.sha256 == e.sha256 }) { out.append(try settle(e)) }
        }
        return out
    }

    /// The file an entry names (entries in Pulltube/ keep that subfolder in their name). An audio entry settles
    /// into the Music home (FEAT-12); until that move happens its bytes are still in downloads/, so this checks
    /// Music first and falls back to downloads/ — correct whichever side of `settle()` the entry is on.
    static func file(_ e: DownloadEntry) -> URL {
        guard e.mode == .audio else { return root.appendingPathComponent(e.name) }
        let musicPath = Homes.url(.music).appendingPathComponent(e.name)
        return FileManager.default.fileExists(atPath: musicPath.path) ? musicPath : root.appendingPathComponent(e.name)
    }

    /// Audio downloads don't stay in downloads/ (FEAT-12): once recorded, they move straight into the Music home,
    /// taking any subtitle sidecars with them. av/video stays in downloads/ for the owner to review, as today.
    @discardableResult
    static func settle(_ e: DownloadEntry) throws -> DownloadEntry {
        guard e.mode == .audio else { return e }
        let from = root.appendingPathComponent(e.name)
        guard FileManager.default.fileExists(atPath: from.path) else { return e }   // already settled
        let moved = try Homes.add(from, to: .music)
        let musicDir = Homes.url(.music)
        // Derived from Spec: BUG-33 (D3): Music may rename the file (a name taken); its sidecars take the new base
        let oldBase = (e.name as NSString).deletingPathExtension.components(separatedBy: "/").last ?? ""
        let newBase = ((moved.path as NSString).lastPathComponent as NSString).deletingPathExtension
        var subs: [String] = []
        for sub in e.subtitles ?? [] {
            let subFrom = root.appendingPathComponent(sub)
            guard FileManager.default.fileExists(atPath: subFrom.path) else { continue }
            let name = subFrom.lastPathComponent
            let renamed = !oldBase.isEmpty && name.hasPrefix(oldBase) ? newBase + name.dropFirst(oldBase.count) : Substring(name)
            // a free name (never over another file); listed only when it really moved
            let want = musicDir.appendingPathComponent(String(renamed))
            let dest = ExportJobs.freeURL(musicDir, base: want.deletingPathExtension().lastPathComponent, ext: want.pathExtension)
            if (try? FileManager.default.moveItem(at: subFrom, to: dest)) != nil { subs.append(dest.lastPathComponent) }
        }
        var out = e
        if e.subtitles != nil { out.subtitles = subs }
        out.name = moved.path
        try write(manifest().filter { $0.name != e.name } + [out])
        return out
    }

    /// Offline first: the same link in the same mode already here, with its bytes intact, is used without the network.
    static func existing(_ link: String, mode: DownloadMode) -> DownloadEntry? {
        let key = canonical(link)
        return manifest().first { e in
            canonical(e.source) == key && e.mode == mode && FileManager.default.fileExists(atPath: file(e).path)
                && (try? sha256(file(e))) == e.sha256
        }
    }

    // Derived from Spec: BUG-33 (D2)
    /// One key for one video however the link is spelled: youtu.be/ID, youtube.com/watch?v=ID&t=5, /shorts/ID,
    /// /embed/ID and /live/ID are all "yt:ID". Any other link is its own key.
    static func canonical(_ link: String) -> String {
        guard let u = URL(string: link), let host = u.host?.lowercased() else { return link }
        func id(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
        let parts = u.pathComponents.filter { $0 != "/" }
        if host == "youtu.be", let v = id(parts.first) { return "yt:" + v }
        if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com" {
            if parts.first == "watch",
               let v = id(URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value) { return "yt:" + v }
            if ["shorts", "embed", "live", "v"].contains(parts.first ?? ""), parts.count > 1, let v = id(parts[1]) { return "yt:" + v }
        }
        return link
    }

    // Derived from Spec: BUG-33 (D4)
    /// Room needed before a download starts (the size isn't known beforehand); tests set a number to prove the wait.
    nonisolated(unsafe) static var minFree: Int64 = 500 << 20
    nonisolated(unsafe) static var freeSpaceOverride: Int64? = nil
    static func freeSpace() -> Int64? {
        if let o = freeSpaceOverride { return o }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// How many fetches or queue runs are going now; the stale sweep waits while any is (a .part may be reopened).
    nonisolated(unsafe) private static var activeCount = 0
    private static let activeLock = NSLock()
    static var isBusy: Bool { activeLock.lock(); defer { activeLock.unlock() }; return activeCount > 0 }
    static func begin() { activeLock.lock(); activeCount += 1; activeLock.unlock() }
    static func end() { activeLock.lock(); activeCount -= 1; activeLock.unlock() }

    /// Unfinished downloads (.part, .part-Frag3, .ytdl, .crdownload) nobody has touched for a day are removed, so they
    /// stop being skipped forever. Not while a download is running, and never one whose [id] a queued request is
    /// still waiting for (an offline request resumes that .part). Returns how many.
    @discardableResult
    static func sweepStale(olderThan age: TimeInterval = 86_400, now: Date = Date()) -> Int {
        guard !isBusy else { return 0 }
        let fm = FileManager.default
        let waiting = Set(queued().map { canonical($0.1.url) })
        let unfinished = try! NSRegularExpression(pattern: #"(\.part(-Frag\d+)?|\.ytdl|\.crdownload|\.download)$"#, options: .caseInsensitive)
        var n = 0
        for dir in [root, root.appendingPathComponent(pulltubeFolder)] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                let name = f.lastPathComponent
                guard unfinished.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else { continue }
                let ids = name.components(separatedBy: "[").dropFirst().compactMap { $0.components(separatedBy: "]").first }
                if ids.contains(where: { waiting.contains("yt:" + $0) }) { continue }
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
                if now.timeIntervalSince(m) >= age, (try? fm.removeItem(at: f)) != nil { n += 1 }
            }
        }
        return n
    }

    /// Would retrying later help? (no connection, DNS, timeouts: yes; a removed video or a bad link: no)
    static func isOffline(_ error: Error) -> Bool {
        #if os(macOS)
        if case Failure.noSpace = error { return true }       // not enough room is a wait, like no connection (BUG-33 D4)
        #endif
        if let u = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
                    .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff].contains(u.code)
        }
        let s = String(describing: error).lowercased()
        return ["nodename nor servname", "getaddrinfo", "network is unreachable", "timed out", "no route to host",
                "connection refused", "temporary failure in name resolution", "internet connection appears to be offline"]
            .contains { s.contains($0) }
    }

    // MARK: queue (other devices ask the Mac)

    static func ask(_ url: String, mode: DownloadMode, from device: String) throws -> DownloadRequest {
        let r = DownloadRequest(id: UUID().uuidString, url: url, mode: mode, from: device, asked: now())
        try FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(r).write(to: queueDir.appendingPathComponent(r.id + ".json"), options: .atomic)
        return r
    }

    static func queued() -> [(URL, DownloadRequest)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: queueDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { f in
            (try? Data(contentsOf: f)).flatMap { try? JSONDecoder().decode(DownloadRequest.self, from: $0) }.map { (f, $0) }
        }.sorted { $0.1.asked < $1.1.asked }
    }

    /// Is this link a media file itself (fetched as it is), rather than a page yt-dlp has to read?
    static func isDirectMedia(_ url: URL) -> Bool {
        url.scheme.map { ["http", "https", "file"].contains($0) } == true && mediaExtensions.contains(url.pathExtension.lowercased())
    }
}

#if os(macOS)
import AppKit
import Network

private let connection = NWPathMonitor()
private var draining = false
private var watchers: [DispatchSourceFileSystemObject] = []
private var pending: DispatchWorkItem?

extension Downloads {
    enum Failure: Error, CustomStringConvertible {
        case noTool(String), failed(String), noSpace(String), queued
        var description: String {
            switch self {
            case .noTool(let t): "\(t) isn't installed (brew install \(t))"
            case .failed(let m): m
            case .noSpace(let m): m
            case .queued: "queued: it downloads when the connection and the room are back (recense download --queue)"
            }
        }
    }

    static func tool(_ name: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/"].map { $0 + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Downloads `link` in `mode` into downloads/ and records it. A direct media link is fetched as it is.
    static func fetch(_ link: String, mode: DownloadMode, options: DownloadOptions = DownloadOptions(),
                      queueWhenOffline: Bool = true) async throws -> DownloadEntry {
        guard let url = URL(string: link) else { throw Failure.failed("not a link: \(link)") }
        // 1. already on this device (no network)
        if options.section == nil, let e = existing(link, mode: mode) { return e }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 2. from the source: resumable, retried; 3. offline, it waits in the queue and never blocks
        begin(); defer { end() }
        do {
            if let free = freeSpace(), free < minFree {
                throw Failure.noSpace("not enough free space to download yet (\(free >> 20) MiB left, \(minFree >> 20) MiB needed): it waits in the queue")
            }
            var e = try await fromSource(url, link: link, mode: mode, options: options)
            e = try await makePlayable(e)
            if options.subtitles, url.scheme?.hasPrefix("http") == true, !isDirectMedia(url) {
                e.subtitles = await subtitles(link, beside: file(e))
            }
            try record(e); e = try settle(e); return e
        } catch where queueWhenOffline && isOffline(error) {
            _ = try ask(link, mode: mode, from: Host.current().localizedName ?? "Mac")
            throw Failure.queued
        }
    }

    static func fromSource(_ url: URL, link: String, mode: DownloadMode, options: DownloadOptions) async throws -> DownloadEntry {
        if isDirectMedia(url) {
            let tmp: URL
            if url.isFileURL { tmp = url } else { tmp = try await URLSession.shared.download(from: url).0 }
            let dest = root.appendingPathComponent(freeName(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent))
            if url.isFileURL { try FileManager.default.copyItem(at: tmp, to: dest) } else { try FileManager.default.moveItem(at: tmp, to: dest) }
            return try entry(for: dest, source: link, mode: mode, via: "direct")
        }
        guard let ytdlp = tool("yt-dlp") else { throw Failure.noTool("yt-dlp") }
        guard let ffmpeg = tool("ffmpeg") else { throw Failure.noTool("ffmpeg") }
        // The title as published, the id so two videos with one title never collide; .part files until done.
        let suffix = mode == .video ? " (video)" : ""
        let args = ["-q", "--no-warnings", "--no-playlist", "--no-simulate", "--restrict-filenames", "--trim-filenames", "120",
                    "--ffmpeg-location", (ffmpeg as NSString).deletingLastPathComponent,
                    "-P", root.path, "-o", "%(title)s [%(id)s]\(suffix).%(ext)s",
                    // Pulltube's speed and resilience, from yt-dlp itself: parallel fragments, resume, retries
                    "-N", "8", "--continue", "--retries", "20", "--fragment-retries", "20",
                    // the file describes itself on any device, offline: title, artist, date, chapters, cover
                    "--embed-metadata", "--embed-chapters"] + (mode == .video ? [] : ["--embed-thumbnail"])
            + (options.section.map { ["--download-sections", "*" + $0] } ?? [])
            + ["--print", "after_move:filepath"] + mode.ytdlpArgs(maxHeight: options.maxHeight) + [link]
        let (status, out, err) = try await run(ytdlp, args, timeout: 3600)
        let path = out.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard status == 0, !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw Failure.failed("yt-dlp couldn't download it: " + (err.split(separator: "\n").last.map(String.init) ?? "exit \(status)"))
        }
        var e = try entry(for: URL(fileURLWithPath: path), source: link, mode: mode, via: "yt-dlp")
        e.name = URL(fileURLWithPath: path).standardizedFileURL.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
        return e
    }

    /// The site's own captions in English, Vietnamese and French, saved beside the file as .vtt (best effort: a
    /// failure here never fails the download). They seed the transcript before Recense hears a word.
    static func subtitles(_ link: String, beside media: URL) async -> [String] {
        guard let ytdlp = tool("yt-dlp") else { return [] }
        let base = media.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " (video)", with: "")
        let dir = media.deletingLastPathComponent()
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        _ = try? await run(ytdlp, ["-q", "--no-warnings", "--no-playlist", "--skip-download", "--write-subs", "--write-auto-subs",
                                   "--sub-langs", "en.*,vi.*,fr.*,-live_chat", "--convert-subs", "vtt",
                                   "--ffmpeg-location", (tool("ffmpeg").map { ($0 as NSString).deletingLastPathComponent } ?? "/opt/homebrew/bin"),
                                   "-P", dir.path, "-o", base + ".%(ext)s", link], timeout: 300)
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        return after.subtracting(before).filter { $0.hasSuffix(".vtt") }.sorted()
    }

    /// The streams ffprobe reads in a file, e.g. ["h264", "aac"], and whether it has video and audio.
    static func probe(_ f: URL) async -> (codecs: [String], video: Bool, audio: Bool) {
        guard let ffprobe = tool("ffprobe"),
              let (s, out, _) = try? await run(ffprobe, ["-v", "error", "-show_entries", "stream=codec_type,codec_name",
                                                       "-of", "csv=p=0", f.path], timeout: 60), s == 0 else { return ([], false, false) }
        var codecs: [String] = [], video = false, audio = false
        for line in out.split(separator: "\n") {
            let p = line.split(separator: ","); guard p.count >= 2 else { continue }
            if p[0] == "mjpeg" || p[0] == "png" { continue }        // embedded cover art, not a video stream
            codecs.append(String(p[0]))
            if p[1] == "video" { video = true } else if p[1] == "audio" { audio = true }
        }
        return (codecs, video, audio)
    }

    /// Codecs every iPhone, iPad and Mac plays without an extra app.
    static let playableCodecs: Set<String> = ["h264", "hevc", "aac", "mp3", "alac", "flac", "opus", "ac3", "eac3", "pcm_s16le"]

    /// A file in a codec AVFoundation can't play (VP9, AV1 in WebM or MKV) becomes H.264/AAC MP4 on the Mac's hardware
    /// encoder, so every device plays it offline; the original goes to the Trash. Also reads the real mode and codecs.
    static func makePlayable(_ e: DownloadEntry) async throws -> DownloadEntry {
        let f = file(e)
        let p = await probe(f)
        var e = e
        e.codecs = p.codecs.joined(separator: ",")
        if p.video { e.mode = p.audio ? .av : .video } else if p.audio { e.mode = .audio }
        guard !p.codecs.isEmpty, !p.codecs.allSatisfy(playableCodecs.contains), let ffmpeg = tool("ffmpeg") else { return e }
        let out = f.deletingPathExtension().appendingPathExtension("mp4")
        let dest = out.path == f.path ? f.deletingPathExtension().appendingPathExtension("converted.mp4") : out
        let (s, _, err) = try await run(ffmpeg, ["-y", "-v", "error", "-i", f.path, "-map", "0:v?", "-map", "0:a?",
                                                 "-c:v", "h264_videotoolbox", "-b:v", "8M", "-c:a", "aac", "-b:a", "192k",
                                                 "-movflags", "+faststart", dest.path], timeout: 7200)
        guard s == 0 else { throw Failure.failed("couldn't convert \(f.lastPathComponent): \(err.prefix(200))") }
        try? FileManager.default.trashItem(at: f, resultingItemURL: nil)
        var c = try entry(for: dest, source: e.source, mode: e.mode, via: e.via)
        c.name = (e.name as NSString).deletingLastPathComponent.isEmpty ? dest.lastPathComponent
            : (e.name as NSString).deletingLastPathComponent + "/" + dest.lastPathComponent
        c.codecs = (await probe(dest)).codecs.joined(separator: ",")
        return c
    }

    /// adopt(), then each new file's real mode and codecs from ffprobe, converted when a device couldn't play it.
    static func adoptAndCheck() async throws -> [DownloadEntry] {
        var out: [DownloadEntry] = []
        for e in try adopt() {
            var c = try await makePlayable(e)
            if c.name != e.name { try write(manifest().filter { $0.name != e.name }) }
            try record(c)
            c = try settle(c)
            out.append(c)
        }
        return out
    }

    // Derived from Spec: BUG-16
    /// Watches downloads/ and downloads/Pulltube/: whatever lands there is adopted and audio settles into Music, 3 s
    /// after the folder stops changing (a file still being written waits for the next pass). Runs once at launch too.
    static func watchFolder(log: @escaping (String) -> Void = { NSLog("recense: \($0)") }) {
        let fm = FileManager.default
        try? fm.createDirectory(at: root.appendingPathComponent(pulltubeFolder), withIntermediateDirectories: true)
        func pass() {
            pending?.cancel()
            let w = DispatchWorkItem {
                Task.detached {
                    do {
                        let got = try await adoptAndCheck()
                        // a file adopted before (recorded, never settled) settles too
                        for e in try sweep() where !got.contains(where: { $0.sha256 == e.sha256 }) { log("settled \(e.name)") }
                        for e in got { log("adopted \(e.name) → \(e.mode == .audio ? "Music" : "downloads")") }
                    } catch { log("downloads sweep: \(error)") }
                }
            }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: w)
        }
        try? fm.createDirectory(at: queueDir, withIntermediateDirectories: true)
        for dir in [root, root.appendingPathComponent(pulltubeFolder), queueDir] {
            let isQueue = dir == queueDir
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
            src.setEventHandler { if isQueue { kickDrain() } else { pass() } }
            src.setCancelHandler { close(fd) }
            src.resume()
            watchers.append(src)
        }
        pass()
    }

    /// When the Mac (re)gains a connection, the queue is run: a request made offline, here or on another device, goes
    /// without anyone pressing anything. Runs at launch too, once the first path arrives.
    static func watchConnection() {
        connection.pathUpdateHandler = { _ in kickDrain() }
        connection.start(queue: DispatchQueue(label: "recense.downloads.connection"))
        // D1: a request dropped while online (or by another device) goes within a minute, not at the next network change
        DispatchQueue.main.async {
            queueTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in kickDrain() }
            kickDrain()
        }
    }

    // Derived from Spec: BUG-33 (D1)
    /// Told when a queued request failed for good (the file is in .queue/failed/): the app turns it into a notice.
    nonisolated(unsafe) static var onFailure: (@Sendable (DownloadRequest, Error) -> Void)? = nil
    /// Runs the queue when there is something in it and no run is going; the timer, the folder watcher and the
    /// connection monitor all call this, so a request never waits for a network change.
    /// Every access to `draining` is on the main queue, so two runs never overlap on one .part.
    static func kickDrain() {
        DispatchQueue.main.async {
            guard !draining, !queued().isEmpty, connection.currentPath.status == .satisfied else { return }
            draining = true
            Task.detached {
                _ = await drain(log: { NSLog("recense: \($0)") })
                DispatchQueue.main.async { draining = false }
            }
        }
    }
    nonisolated(unsafe) private static var queueTimer: Timer?

    /// Runs every queued request (oldest first); a done or failed one leaves the queue, a failure logged in .queue/failed/.
    static func drain(log: (String) -> Void = { print($0) }) async -> Int {
        begin(); defer { end() }
        var done = 0
        for (file, r) in queued() {
            do {
                let e = try await fetch(r.url, mode: r.mode, queueWhenOffline: false)
                log("downloaded \(e.name) (\(r.mode.label), for \(r.from))"); done += 1
                try? FileManager.default.removeItem(at: file)
            } catch where isOffline(error) {
                log("still offline: \(r.url) stays queued"); break     // the rest would fail the same way
            } catch {
                log("couldn't download \(r.url): \(error)")
                let failed = queueDir.appendingPathComponent("failed", isDirectory: true)
                try? FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: file, to: failed.appendingPathComponent(file.lastPathComponent))
                onFailure?(r, error)
            }
        }
        return done
    }

    /// Pulltube (a paid Mac app, optional): opens the link there. Set Pulltube's download folder to
    /// ~/Recense/downloads and `adopt()` records whatever it saves. Returns false when Pulltube isn't installed.
    @discardableResult
    static func openInPulltube(_ link: String) -> Bool {
        guard let url = URL(string: link),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mymixapps.pulltube") else { return false }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) async throws -> (Int32, String, String) {
        let r = try await runChecked(exe, args, timeout: timeout)
        return (r.status, r.out, r.err)
    }

    /// Like run, and says whether the time limit stopped it. stdout and stderr are read at the same time, so a tool
    /// that writes more than a pipe holds (64 KB) to either never blocks.
    static func runChecked(_ exe: String, _ args: [String], timeout: TimeInterval) async throws -> (status: Int32, out: String, err: String, timedOut: Bool) {
        try await Task.detached {
            let p = Process(), out = Pipe(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
            p.standardOutput = out; p.standardError = err
            try p.run()
            final class Flags: @unchecked Sendable { var stopped = false; var err = Data() }
            let fl = Flags()
            let watchdog = DispatchWorkItem { if p.isRunning { fl.stopped = true; p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            defer { watchdog.cancel() }
            let g = DispatchGroup(); g.enter()
            DispatchQueue.global().async { fl.err = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
            let o = out.fileHandleForReading.readDataToEndOfFile()
            g.wait()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: fl.err, as: UTF8.self), fl.stopped)
        }.value
    }
}

/// `recense selftest`: downloads' model, no network (a temporary downloads/ folder).
func downloadsSelftest() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String, _ got: Any = "") { print("\(pass ? "ok  " : "FAIL") downloads, \(what)\(pass ? "" : " — got \(got)")"); ok = ok && pass }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recense-downloads-\(UUID().uuidString)")
    setenv("RECENSE_DOWNLOADS", dir.path, 1)
    // FEAT-12: settle() moves audio into the Music home, so Homes.root needs its own temp folder too — otherwise
    // this test would move real files into the owner's actual ~/Recense/library/Music.
    let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent("recense-home-\(UUID().uuidString)")
    setenv("RECENSE_HOME", homeDir.appendingPathComponent("Recense").path, 1)
    defer {
        unsetenv("RECENSE_DOWNLOADS"); try? FileManager.default.removeItem(at: dir)
        unsetenv("RECENSE_HOME"); try? FileManager.default.removeItem(at: homeDir)
    }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    Downloads.quiet = 0; defer { Downloads.quiet = 3 }
    Downloads.freeSpaceOverride = 1 << 40; defer { Downloads.freeSpaceOverride = nil }   // this Mac's real free space must not decide the test

    check(DownloadMode.audio.ytdlpArgs.contains("m4a") && DownloadMode.audio.ytdlpArgs.contains("-x"), "audio stays the m4a extraction Recense uses")
    check(DownloadMode.av.ytdlpArgs.joined(separator: " ").contains("avc1") && DownloadMode.av.ytdlpArgs.contains("mp4"), "audio+video asks for H.264 in mp4")
    check(!DownloadMode.video.ytdlpArgs.contains("+ba"), "video only asks for no audio")
    check(Downloads.isDirectMedia(URL(string: "https://example.org/ep/1.mp3?x=1")!), "an MP3 link is fetched as it is")
    check(!Downloads.isDirectMedia(URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!), "a video page goes to yt-dlp")

    // adopt: a file dropped in (as Pulltube saves) is recorded once, with the right SHA-256; partial downloads are not
    let f = dir.appendingPathComponent("clip.mp4"), part = dir.appendingPathComponent("other.mp4.part")
    try? Data("recense".utf8).write(to: f); try? Data("x".utf8).write(to: part)
    let added = (try? Downloads.adopt()) ?? []
    check(added.count == 1 && added.first?.name == "clip.mp4", "adopt records a dropped-in file", added.map(\.name))
    // (printf recense | shasum -a 256)
    check(added.first?.sha256 == "6df1d104124f428c24deb32d17cb7aa8f2e089ca6b1a8a34bf7801ecc9013d01",
          "the manifest holds the file's SHA-256", added.first?.sha256 ?? "")
    check(added.first?.mode == .av && added.first?.via == "adopted", "a dropped-in mp4 counts as audio+video")
    check((try? Downloads.adopt())?.isEmpty == true, "adopt never records a file twice")
    check(Downloads.manifest().count == 1, "manifest.json reads back", Downloads.manifest().count)

    // freeName never overwrites
    check(Downloads.freeName("clip.mp4") == "clip 2.mp4", "a second clip.mp4 becomes clip 2.mp4", Downloads.freeName("clip.mp4"))

    // queue: a request written by another device reads back, oldest first
    let r = try? Downloads.ask("https://www.youtube.com/watch?v=aqz-KE-bpKQ", mode: .video, from: "iPhone")
    check(Downloads.queued().map(\.1) == [r].compactMap { $0 }, "a queued request reads back", Downloads.queued().map(\.1))

    // direct fetch from a file link (the real path for an MP3 or MP4 link, without the network)
    let src = FileManager.default.temporaryDirectory.appendingPathComponent("recense-src-\(UUID().uuidString).m4a")
    try? Data("sound".utf8).write(to: src)
    defer { try? FileManager.default.removeItem(at: src) }
    let sem = DispatchSemaphore(value: 0); var got: DownloadEntry?
    Task.detached { got = try? await Downloads.fetch(src.absoluteString, mode: .audio); sem.signal() }
    sem.wait()
    check(got?.via == "direct" && FileManager.default.fileExists(atPath: Downloads.file(got!).path),
          "a direct link lands in downloads/", got as Any)
    check(Downloads.manifest().count == 2, "and is in the manifest", Downloads.manifest().map(\.name))

    // FEAT-12: an audio download settles into Music, not downloads/ — it moved, it isn't duplicated
    check(got?.mode == .audio && !FileManager.default.fileExists(atPath: dir.appendingPathComponent(got?.name ?? "-").path),
          "an audio download leaves downloads/ once settled")
    check(FileManager.default.fileExists(atPath: Homes.url(.music).appendingPathComponent(got?.name ?? "-").path),
          "and lands in the Music home")

    // offline first: the same link and mode again is served from the device, no second file
    let sem2 = DispatchSemaphore(value: 0); var again: DownloadEntry?
    Task.detached { again = try? await Downloads.fetch(src.absoluteString, mode: .audio); sem2.signal() }
    sem2.wait()
    check(again?.name == got?.name && Downloads.manifest().count == 2, "a second ask uses the copy already here", again as Any)
    check(Downloads.existing(src.absoluteString, mode: .video) == nil, "another mode is a new download")

    // a dropped connection queues for later; a dead link doesn't
    check(Downloads.isOffline(URLError(.notConnectedToInternet)), "no internet counts as offline")
    check(Downloads.isOffline(Downloads.Failure.failed("yt-dlp couldn't download it: [Errno 8] nodename nor servname provided")), "a DNS failure counts as offline")
    check(!Downloads.isOffline(Downloads.Failure.failed("yt-dlp couldn't download it: Video unavailable")), "a removed video isn't retried")

    // Pulltube's folder: what it saves into downloads/Pulltube/ is adopted with that subfolder in its name
    let pt = dir.appendingPathComponent("Pulltube", isDirectory: true)
    try? FileManager.default.createDirectory(at: pt, withIntermediateDirectories: true)
    try? Data("pt".utf8).write(to: pt.appendingPathComponent("talk.m4a"))
    let ptAdded = (try? Downloads.adopt()) ?? []
    check(ptAdded.map(\.name) == ["Pulltube/talk.m4a"] && ptAdded.first?.mode == .audio, "a Pulltube download is adopted", ptAdded.map(\.name))
    check(FileManager.default.fileExists(atPath: Downloads.file(ptAdded.first ?? got!).path), "and its entry finds the file")

    // FEAT-12: adoptAndCheck() settles a Pulltube audio drop into Music too, not just a direct fetch
    try? Data("pt2".utf8).write(to: pt.appendingPathComponent("another.m4a"))
    let sem3 = DispatchSemaphore(value: 0); var adoptedSettled: DownloadEntry?
    Task.detached {
        adoptedSettled = (try? await Downloads.adoptAndCheck())?.first { $0.via == "adopted" && $0.name.hasSuffix("another.m4a") }
        sem3.signal()
    }
    sem3.wait()
    check(adoptedSettled?.mode == .audio && FileManager.default.fileExists(atPath: Downloads.file(adoptedSettled ?? got!).path)
          && !FileManager.default.fileExists(atPath: pt.appendingPathComponent("another.m4a").path),
          "adoptAndCheck settles a Pulltube audio drop into Music too", adoptedSettled as Any)

    // quality: the height cap reaches yt-dlp's format choice
    check(DownloadMode.av.ytdlpArgs(maxHeight: 720).joined().contains("height<=720") &&
          !DownloadMode.av.ytdlpArgs(maxHeight: 720).joined().contains("1080"), "--max 720 caps the height")
    // Regression guard: BUG-16 — an audio file dropped into downloads/ by another app reaches Music with no command run;
    // one still being written (changed under 3 s ago) waits for the next pass
    do {
        let song = dir.appendingPathComponent("Туманы.m4a"), fresh = dir.appendingPathComponent("fresh.m4a")
        try Data("song".utf8).write(to: song)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: song.path)
        try Data("writing".utf8).write(to: fresh)
        Downloads.quiet = 3; defer { Downloads.quiet = 0 }
        let swept = try Downloads.sweep()
        check(swept.contains { $0.name == "Туманы.m4a" } && FileManager.default.fileExists(atPath: Homes.url(.music).appendingPathComponent("Туманы.m4a").path)
              && !FileManager.default.fileExists(atPath: song.path), "a dropped-in song settles into Music by itself", swept.map(\.name))
        check(FileManager.default.fileExists(atPath: fresh.path) && !swept.contains { $0.name == "fresh.m4a" },
              "a file still being written waits", swept.map(\.name))
        try? FileManager.default.removeItem(at: fresh)
    } catch { check(false, "BUG-16 sweep", error) }

    // Regression guard: BUG-33 D2 — one video, many link spellings, one key (and one file)
    let ids = ["https://youtu.be/aqz-KE-bpKQ", "https://www.youtube.com/watch?v=aqz-KE-bpKQ&t=5s", "https://m.youtube.com/shorts/aqz-KE-bpKQ"]
    check(Set(ids.map(Downloads.canonical)) == ["yt:aqz-KE-bpKQ"], "youtu.be, watch?v= and shorts are one video", ids.map(Downloads.canonical))
    check(Downloads.canonical("https://example.org/a.mp3") == "https://example.org/a.mp3", "any other link is its own key")
    let vid = dir.appendingPathComponent("Talk [aqz-KE-bpKQ].mp4"); try? Data("v".utf8).write(to: vid)
    if var ve = try? Downloads.entry(for: vid, source: ids[0], mode: .av, via: "yt-dlp") {
        ve.name = vid.lastPathComponent; try? Downloads.record(ve)
        check(Downloads.existing(ids[1], mode: .av)?.name == vid.lastPathComponent, "the other spelling finds the copy already here")
    } else { check(false, "D2 entry") }

    // Regression guard: BUG-33 D4 — no room means the request waits in the queue (not failed/, not announced);
    // a day-old .part is swept, a fresh one stays, and one a queued request still needs survives
    for (f, _) in Downloads.queued() { try? FileManager.default.removeItem(at: f) }
    final class Told: @unchecked Sendable { var n = 0 }
    let told = Told()
    Downloads.onFailure = { _, _ in told.n += 1 }; defer { Downloads.onFailure = nil }
    Downloads.freeSpaceOverride = 100 << 20
    let semSp = DispatchSemaphore(value: 0); var spErr: Error?
    Task.detached { do { _ = try await Downloads.fetch("https://example.org/never.mp4", mode: .av) } catch { spErr = error }; semSp.signal() }
    semSp.wait()
    let failedDir = Downloads.queueDir.appendingPathComponent("failed")
    check(String(describing: spErr as Any).contains("queued") && Downloads.queued().count == 1
          && ((try? FileManager.default.contentsOfDirectory(atPath: failedDir.path)) ?? []).isEmpty && told.n == 0,
          "a download with no room waits in the queue, never failed/", (spErr as Any, Downloads.queued().count, told.n))
    for (f, _) in Downloads.queued() { try? FileManager.default.removeItem(at: f) }
    Downloads.freeSpaceOverride = 1 << 40
    let oldPart = dir.appendingPathComponent("old.mp4.part"), newPart = dir.appendingPathComponent("new.mp4.part")
    let frag = dir.appendingPathComponent("old.mp4.part-Frag7"), keep = dir.appendingPathComponent("Talk [zzzzzzzzzzz].mp4.part")
    for u in [oldPart, newPart, frag, keep] { try? Data("p".utf8).write(to: u) }
    for u in [oldPart, frag, keep] { try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: u.path) }
    _ = try? Downloads.ask("https://youtu.be/zzzzzzzzzzz", mode: .av, from: "iPhone")
    Downloads.sweepStale()
    check(!FileManager.default.fileExists(atPath: oldPart.path) && !FileManager.default.fileExists(atPath: frag.path)
          && FileManager.default.fileExists(atPath: newPart.path), "a day-old .part and .part-Frag are swept, a fresh one stays")
    check(FileManager.default.fileExists(atPath: keep.path), "an old .part a queued request still needs survives")
    Downloads.begin(); try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: newPart.path)
    check(Downloads.sweepStale() == 0 && FileManager.default.fileExists(atPath: newPart.path), "nothing is swept while a download runs")
    Downloads.end()
    for (f, _) in Downloads.queued() { try? FileManager.default.removeItem(at: f) }
    for u in [newPart, keep] { try? FileManager.default.removeItem(at: u) }

    // Regression guard: BUG-33 M-B4 — a tool writing 200 KB to stderr must not block (stderr is read at the same time)
    let semR = DispatchSemaphore(value: 0); var runRes: (Int32, String, String)?; let t0 = Date()
    Task.detached { runRes = try? await Downloads.run("/bin/sh", ["-c", "yes x | head -c 200000 >&2; echo out"], timeout: 20); semR.signal() }
    check(semR.wait(timeout: .now() + 15) == .success && runRes?.2.count == 200_000 && Date().timeIntervalSince(t0) < 5, "200 KB of stderr doesn't block the run", runRes?.2.count as Any)
    let semT = DispatchSemaphore(value: 0); var tr: (status: Int32, out: String, err: String, timedOut: Bool)?
    Task.detached { tr = try? await Downloads.runChecked("/bin/sleep", ["30"], timeout: 0.5); semT.signal() }
    check(semT.wait(timeout: .now() + 15) == .success && tr?.timedOut == true, "a run stopped by its time limit says so", tr as Any)

    // Regression guard: BUG-33 D3 — Music renames a taken name; the .vtt sidecars follow
    do {
        try Data("other".utf8).write(to: Homes.url(.music).appendingPathComponent("Clash.m4a"))
        try Data("new".utf8).write(to: dir.appendingPathComponent("Clash.m4a"))
        try Data("WEBVTT".utf8).write(to: dir.appendingPathComponent("Clash.en.vtt"))
        var ce = try Downloads.entry(for: dir.appendingPathComponent("Clash.m4a"), source: "", mode: .audio, via: "adopted")
        ce.subtitles = ["Clash.en.vtt"]
        let st = try Downloads.settle(ce)
        let base = ((st.name as NSString).lastPathComponent as NSString).deletingPathExtension
        check(base != "Clash" && st.subtitles == [base + ".en.vtt"]
              && FileManager.default.fileExists(atPath: Homes.url(.music).appendingPathComponent(base + ".en.vtt").path), "a renamed song takes its subtitles with it", st.subtitles as Any)
    } catch { check(false, "D3 settle", error) }

    // Regression guard: BUG-33 D1 — a request that fails for good leaves the queue, lands in failed/ and is announced
    do {
        for (f, _) in Downloads.queued() { try? FileManager.default.removeItem(at: f) }   // the earlier test's request must not hit the network
        _ = try Downloads.ask("", mode: .audio, from: "iPhone")
        final class Seen: @unchecked Sendable { var n = 0 }
        let seen = Seen()
        Downloads.onFailure = { _, _ in seen.n += 1 }; defer { Downloads.onFailure = nil }
        let semD = DispatchSemaphore(value: 0)
        Task.detached { _ = await Downloads.drain(log: { _ in }); semD.signal() }
        semD.wait()
        let failed = (try? FileManager.default.contentsOfDirectory(atPath: Downloads.queueDir.appendingPathComponent("failed").path)) ?? []
        check(seen.n == 1 && failed.count == 1, "a failed request is announced and kept in failed/", (seen.n, failed))
    } catch { check(false, "D1 ask", error) }
    return ok
}
#endif
