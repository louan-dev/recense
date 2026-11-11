import Cocoa
import CoreAudio
import AudioToolbox
import AVFoundation

// App ear (gauntlet P7, 2026-11-10): whatever plays in any app on this Mac gets a live transcript from that app's own
// sound. Until now Recense heard only what it could fetch as a file (QuickTime and Music's local files, a browser page
// yt-dlp could read, the Firefox bridge's bytes): Spotify, VLC, Podcasts, Apple Music's streams, afplay, a Safari or
// Chrome page with no downloadable address, got nothing ("Play something", or "Loading audio…" for ever).
// Here a Core Audio process tap takes a copy of the playing app's output (never the mic; the app still plays as it is:
// `.unmuted`), and Apple's SpeechAnalyzer hears it on this Mac (SpeechAuto: English, French or Vietnamese, whichever
// is spoken). Times are seconds of the app's own sound since the tap started, so every word is timed to the voice.
// Needs macOS 14.2 for the tap (System Audio Recording permission) and macOS 26 for the ears.

enum AppEar {
    struct Player: Equatable { let pid: pid_t; let name: String; let bundle: String }

    /// Processes whose sound is never a transcript: system sounds, alerts, speech Recense itself makes.
    static let unheard = ["com.apple.coreaudiod", "com.apple.systemsound", "com.apple.notificationcenterui", "com.apple.NotificationCenter",
                          "com.apple.accessibility", "com.apple.speech", "com.apple.CoreSpeech", "com.apple.SpeechSynthesis",
                          "com.apple.siri", "com.apple.assistant", "com.apple.FaceTime", "com.apple.avconferenced", "local.recense"]
    static func listenable(_ bundle: String) -> Bool { !unheard.contains { bundle.hasPrefix($0) } }

    /// Which playing app is heard: the one Recense already follows, else the frontmost, else the one that started last
    /// (the end of `playing`, which keeps the order apps were first heard in).
    static func choose(_ playing: [Player], followed: String?, front: pid_t?) -> Player? {
        if let f = followed, let p = playing.first(where: { $0.bundle == f }) { return p }
        if let front, let p = playing.first(where: { $0.pid == front }) { return p }
        return playing.last
    }

    /// The apps sending sound to an output right now, each named by the app it belongs to (a browser plays from a
    /// helper: Chrome's audio service and Firefox's content processes are its children; Safari's WebKit processes
    /// aren't anyone's child, and belong to Safari when it runs). A command-line player (afplay) is its own app.
    static func playing() -> [Player] {
        guard #available(macOS 14.2, *) else { return [] }
        var out: [Player] = []
        let me = getpid()
        for o in processObjects() {
            var run = UInt32(0), pid = pid_t(-1)
            guard get(o, kAudioProcessPropertyIsRunningOutput, &run), run != 0, get(o, kAudioProcessPropertyPID, &pid), pid > 0, pid != me else { continue }
            var b: CFString = "" as CFString
            let bundle = get(o, kAudioProcessPropertyBundleID, &b) ? b as String : ""
            guard let p = owner(pid, bundle), p.pid != me, listenable(p.bundle), !out.contains(where: { $0.pid == p.pid }) else { continue }
            out.append(p)
        }
        return out
    }

    static func owner(_ pid: pid_t, _ bundle: String) -> Player? {
        if bundle.hasPrefix("com.apple.WebKit."),
           let s = (NativeSources.safari.lazy.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }).first {
            return Player(pid: s.processIdentifier, name: s.localizedName ?? "Safari", bundle: s.bundleIdentifier ?? "")
        }
        var p = pid
        for _ in 0..<6 {
            if let a = NSRunningApplication(processIdentifier: p), a.activationPolicy == .regular {
                return Player(pid: p, name: a.localizedName ?? a.bundleIdentifier ?? "app", bundle: a.bundleIdentifier ?? "")
            }
            let up = parent(of: p)
            guard up > 1 else { break }
            p = up
        }
        // no app above it: a command-line player is heard as itself; a background agent with a bundle isn't media
        guard bundle.isEmpty else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, 256)
        let n = String(cString: name)
        return Player(pid: pid, name: n.isEmpty ? "pid \(pid)" : n, bundle: n)
    }

    /// Of the apps with an output open, the ones actually sounding. An app can hold a stream open in silence (Claude's
    /// and other Electron helpers, iPhone Mirroring): Core Audio calls it running all the same, and the ear chose it (it
    /// was frontmost) and stayed on its silence while another app played. Each gets a copy of its sound for `wait`
    /// seconds (no ears, never the mic); those louder than −60 dBFS are returned. `refused`: no permission to tap.
    @available(macOS 14.2, *)
    @MainActor static func audible(_ ps: [Player], wait: Double = 0.6) async -> (players: [Player], refused: Bool) {
        let taps = ps.map { p -> (Player, AppTap) in (p, AppTap(pid: p.pid, probe: true)) }
        await withTaskGroup(of: Void.self) { g in for (_, t) in taps { g.addTask { _ = await t.startAsync { _, _ in } } } }
        try? await Task.sleep(for: .seconds(wait))
        for (_, t) in taps { t.stop() }
        return (taps.filter { $0.1.heard }.map(\.0), !taps.isEmpty && taps.allSatisfy { $0.1.refused })
    }

    /// A followed player whose audio can't be fetched (a stream with no address, no connection, a page yt-dlp can't
    /// read): it has no words, and its load failed, or still loads after 15 s. Then the app's own sound is heard instead.
    static func stuck(hasLines: Bool, state: String, for s: Double) -> Bool {
        !hasLines && (["need-bytes", "failed"].contains(state) || state == "loading" && s > 15)
    }

    static func processObjects() -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var n = UInt32(0), sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &n) == noErr, n > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(n) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &n, &list) == noErr else { return [] }
        return list
    }
    static func get<T>(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector, _ v: inout T) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var n = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(o, &a, 0, nil, &n, &v) == noErr
    }
    /// Of several players that answer to one name (two afplays), the one started last: an older one is about to end.
    static func newest(_ matches: [Player], started: (pid_t) -> Double = startTime) -> Player? {
        matches.max { started($0.pid) < started($1.pid) }
    }
    /// When `p` started, in seconds since 1970 (0 if it's gone).
    static func startTime(_ p: pid_t) -> Double {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, p]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let t = info.kp_proc.p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1e6
    }
    static func parent(of p: pid_t) -> pid_t {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, p]
        return sysctl(&mib, 4, &info, &size, nil, 0) == 0 ? info.kp_eproc.e_ppid : -1
    }
}

/// Phrases as they arrive (SpeechAnalyzer's volatile guesses, then its final words) made into Lines: the final words
/// stay; the latest guess shows after them until its stretch is final. One sentence a line (splitWords).
struct LiveLines {
    /// Ids from here up are guesses (volatile): drawn dim until their stretch is final.
    static let guessBase = 1_000_000
    private(set) var finals: [SpeechCore.Phrase] = []
    private var guess: SpeechCore.Phrase?
    private(set) var version = 0
    private var cache: [Line] = [], cached = -1

    /// How far into the sound the shown words reach, and when (`at`, tap seconds): [audio end, shown at], guesses
    /// included. The lag of the first visible text is `shown at − a word's end` at the first entry that reaches it.
    private(set) var shown: [[Double]] = []

    mutating func add(_ p: SpeechCore.Phrase, final: Bool, at: Double = 0) {
        version += 1
        if let e = p.words.last?.end, e > (shown.last?[0] ?? 0) { shown.append([e, at]) }
        if final {
            if !p.words.isEmpty { finals.append(p); finals.sort { $0.start < $1.start } }
            if let g = guess, g.end <= p.end + 0.05 { guess = nil }   // its stretch is final now
        } else { guess = p }
    }

    var lines: [Line] {
        mutating get {
            if cached == version { return cache }
            let done = finals.last?.end ?? 0
            var out: [Line] = [], id = 1
            for p in finals {
                for ws in splitWords(p.words.map(LiveLines.word)) { out.append(Line(id: id, words: ws, english: [])); id += 1 }
            }
            if let g = guess {
                let ws = g.words.filter { $0.start >= done - 0.05 }.map(LiveLines.word)
                for part in splitWords(ws) where !part.isEmpty { out.append(Line(id: LiveLines.guessBase + id, words: part, english: [])); id += 1 }
            }
            cache = out; cached = version
            return out
        }
    }
    static func word(_ w: SpeechCore.W) -> Word { Word(text: w.text, start: w.start, end: w.end, lang: w.lang, c: w.c) }
}

/// A copy of one app's sound (and its helpers'), mono, as it plays. The app is never muted.
@available(macOS 14.2, *)
final class AppTap {
    let pid: pid_t
    private(set) var rate = 48000.0
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var desc: CATapDescription?
    private var objs: Set<AudioObjectID> = []
    private let lock = NSLock()
    private var frames = 0, loudAt = 0
    private var began: Date?
    /// Seconds of the app's sound taken so far: the clock every word is timed on.
    var seconds: Double { lock.withLock { Double(frames) / rate } }
    /// Seconds since anything louder than −60 dBFS came through (a tap that only hears silence: another audio tool
    /// such as SoundSource holds the app's sound).
    var quiet: Double { lock.withLock { AppTap.quiet(frames: frames, loudAt: loudAt, rate: rate, since: began) } }
    /// No frame at all since the tap began counts as silence by the clock: a stalled Core Audio (11-11: coreaudiod took
    /// 90 s to start the device, then sent nothing) must read as silence, never as "live" with no words.
    static func quiet(frames: Int, loudAt: Int, rate: Double, since: Date?, now: Date = Date()) -> Double {
        frames == 0 ? since.map { max(0, now.timeIntervalSince($0)) } ?? 0 : Double(frames - loudAt) / rate
    }
    /// Anything louder than −60 dBFS came through since the tap began.
    var heard: Bool { lock.withLock { loudAt > 0 } }
    var refused = false
    private var mono: UnsafeMutablePointer<Float>?
    private let probe: Bool

    init(pid: pid_t, probe: Bool = false) { self.pid = pid; self.probe = probe }

    /// `each` gets mono frames at `rate`, on Core Audio's IO thread.
    func start(_ each: @escaping (UnsafePointer<Float>, Int) -> Void) -> Bool {
        let now = AppTap.objects(pid)
        guard !now.isEmpty else { return false }
        let d = CATapDescription(stereoMixdownOfProcesses: now)
        d.uuid = UUID(); d.muteBehavior = .unmuted; d.isPrivate = true
        desc = d; objs = Set(now)
        let err = AudioHardwareCreateProcessTap(d, &tapID)
        guard err == noErr, tapID != kAudioObjectUnknown else {
            refused = err == OSStatus(kAudioHardwareIllegalOperationError)
            if !probe { log("app ear: no tap on pid \(pid) (\(err))") }
            stop(); return false
        }
        var asbd = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fa = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tapID, &fa, 0, nil, &size, &asbd) == noErr, asbd.mSampleRate > 0 else { stop(); return false }
        rate = asbd.mSampleRate
        let ch = Int(max(1, asbd.mChannelsPerFrame)), interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        // The output device is the aggregate's clock: a tap alone gave a device whose IO never ran (P7, 11-11: 0 frames
        // in 3 min of afplay). Apple's tap sample and AudioCap set it as the main sub-device too.
        var agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Recense Ear",
            kAudioAggregateDeviceUIDKey: "recense.ear.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: d.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        if let out = AppTap.outputUID() {
            agg[kAudioAggregateDeviceMainSubDeviceKey] = out
            agg[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: out]]
        }
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID) == noErr else { stop(); return false }
        let mono = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
        self.mono = mono   // freed in stop(), once the IO block can no longer run
        let floor = Float(0.001)   // −60 dBFS
        let st = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggID, nil) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let b0 = abl.first, b0.mData != nil else { return }
            let n = min(16384, interleaved ? Int(b0.mDataByteSize) / MemoryLayout<Float>.size / ch : Int(b0.mDataByteSize) / MemoryLayout<Float>.size)
            guard n > 0 else { return }
            var loud = false
            for i in 0..<n {
                var v: Float = 0
                if interleaved { let p = b0.mData!.assumingMemoryBound(to: Float.self); for c in 0..<ch { v += p[i * ch + c] }; v /= Float(ch) }
                else { var k = 0; for b in abl { if let p = b.mData?.assumingMemoryBound(to: Float.self) { v += p[i]; k += 1 } }; v /= Float(max(1, k)) }
                mono[i] = v
                if abs(v) > floor { loud = true }
            }
            self.lock.withLock { self.frames += n; if loud { self.loudAt = self.frames } }
            each(mono, n)
        }
        guard st == noErr, AudioDeviceStart(aggID, ioProc) == noErr else { stop(); return false }
        lock.withLock { began = Date() }
        if !probe { log("app ear: tapping pid \(pid), \(now.count) process(es), \(Int(rate)) Hz × \(ch)") }
        return true
    }

    /// start() off the main thread: a stalled Core Audio takes 60 s to make the IO proc and 30 s to start the device
    /// (11-11), and the window must not freeze meanwhile.
    func startAsync(_ each: @escaping (UnsafePointer<Float>, Int) -> Void) async -> Bool {
        await withCheckedContinuation { c in DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: self.start(each)) } }
    }

    /// A browser opens a new content process for a new tab: the tap takes the app's current processes (as SoundTap).
    func refresh() {
        guard let desc, tapID != kAudioObjectUnknown else { return }
        let now = AppTap.objects(pid)
        guard !now.isEmpty, Set(now) != objs else { return }
        desc.processes = now
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var d: CATapDescription = desc
        let st = withUnsafeMutablePointer(to: &d) { AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0) }
        if st == noErr { objs = Set(now) }
    }

    func stop() {
        if let io = ioProc { AudioDeviceStop(aggID, io); AudioDeviceDestroyIOProcID(aggID, io); ioProc = nil }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
        mono?.deallocate(); mono = nil
    }
    deinit { stop() }

    /// The app's audio objects and its helpers' (SoundTap's rule: its children; for Safari, WebKit's processes).
    static func objects(_ pid: pid_t) -> [AudioObjectID] { AppAudio.objects(for: pid) }

    /// The UID of the device the system plays to (the aggregate's clock).
    static func outputUID() -> String? {
        var dev = AudioObjectID(kAudioObjectUnknown), n = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n, &dev) == noErr, dev != kAudioObjectUnknown else { return nil }
        var uid: CFString = "" as CFString
        n = UInt32(MemoryLayout<CFString>.size)
        a.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &n, &uid) == noErr else { return nil }
        return uid as String
    }
}

/// The live transcript of one app at a time, for the window (AppDelegate.renderLive) and `recense hear-app`.
@MainActor final class LiveEar {
    nonisolated static var available: Bool {
        #if compiler(>=6.2) && canImport(Speech)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }
    private(set) var player: AppEar.Player?
    private(set) var live = LiveLines()
    private(set) var lang = "en"
    private(set) var startedAt: Date?
    /// How late words arrive after they're said (seconds, the latest final): the gap a delayed replay would close.
    private(set) var lag = 0.0
    var onNote: ((String) -> Void)?
    private var tap: AnyObject?
    private var ears: AnyObject?
    private let feed = DispatchQueue(label: "recense.ear.feed")
    var running: Bool { tap != nil }
    /// No System Audio Recording permission (the last tap, or every probe, was refused).
    var denied = false
    var refused: Bool { if denied { return true }; if #available(macOS 14.2, *) { return (lastTap as? AppTap)?.refused ?? false }; return false }
    private var lastTap: AnyObject?
    var seconds: Double { if #available(macOS 14.2, *), let t = tap as? AppTap { return t.seconds }; return 0 }
    var quiet: Double { if #available(macOS 14.2, *), let t = tap as? AppTap { return t.quiet }; return 0 }
    var lines: [Line] { live.lines }

    /// Hears `p` from now on (in `first`, or whichever of English, French and Vietnamese is spoken). False: no tap
    /// (no permission, the app went quiet) or no on-device model.
    func start(_ p: AppEar.Player, first: String = "en", among: [String] = SpeechCore.auto, fast: Bool = true) async -> Bool {
        stop()
        #if compiler(>=6.2) && canImport(Speech)
        guard #available(macOS 26, *) else { return false }
        let a = await SpeechAuto.start(lang: first, among: among, fast: fast) { [weak self] ph, fin, l in
            Task { @MainActor in self?.heard(ph, fin, l) }
        }
        guard let a else { log("app ear: no on-device model for \(first)"); return false }
        a.onNote = { s in log("app ear: \(s)") }
        let t = AppTap(pid: p.pid)
        lastTap = t
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)
        let feed = self.feed
        var format = fmt
        guard await t.startAsync({ s, n in
            if format?.sampleRate != t.rate { format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: t.rate, channels: 1, interleaved: false) }
            guard let f = format, let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(n)) else { return }
            b.frameLength = AVAudioFrameCount(n)
            b.floatChannelData![0].update(from: s, count: n)
            feed.async { a.append(b) }
        }) else { a.cancel(); return false }
        tap = t; ears = a; player = p; lang = first; live = LiveLines(); startedAt = Date(); lag = 0
        log("app ear: hearing \(p.name) (\(p.bundle), pid \(p.pid)) in \(first) among \(among)")
        return true
        #else
        return false
        #endif
    }

    private func heard(_ p: SpeechCore.Phrase, _ final: Bool, _ l: String) {
        guard tap != nil else { return }
        lang = l
        if final, let e = p.words.last?.end { lag = max(0, seconds - e) }
        live.add(p, final: final, at: seconds)
        if final, !p.text.isEmpty { onNote?(p.text) }
    }

    func refresh() { if #available(macOS 14.2, *) { (tap as? AppTap)?.refresh() } }

    func stop() {
        #if compiler(>=6.2) && canImport(Speech)
        if #available(macOS 26, *) { (ears as? SpeechAuto)?.cancel() }
        #endif
        if #available(macOS 14.2, *) { (tap as? AppTap)?.stop() }
        if let p = player { log("app ear: stopped hearing \(p.name) after \(Int(seconds)) s, \(live.finals.count) phrases") }
        // RECENSE_EAR_OUT (config): each live transcript kept for measuring against the file transcript
        if let p = player, !cfg.earOut.isEmpty, !live.finals.isEmpty,
           let d = try? JSONSerialization.data(withJSONObject: json(), options: [.prettyPrinted, .sortedKeys]) {
            let f = URL(fileURLWithPath: cfg.earOut).appendingPathComponent("\(p.name)-\(Int(Date().timeIntervalSince1970)).json")
            try? d.write(to: f); log("app ear: wrote \(f.path)")
        }
        tap = nil; ears = nil; player = nil
    }

    /// The last words, then the ears let go (the command line's end).
    func finish() async {
        #if compiler(>=6.2) && canImport(Speech)
        if #available(macOS 14.2, *) { (tap as? AppTap)?.stop() }
        if #available(macOS 26, *), let a = ears as? SpeechAuto { await feedDrained(); await a.finish() }
        try? await Task.sleep(for: .milliseconds(300))   // the last results hop to the main actor
        #endif
        stop()
    }
    private func feedDrained() async { await withCheckedContinuation { c in feed.async { c.resume() } } }

    /// The transcript as keep/'s v2 shape needs it for comparing: lines of timed words.
    func json() -> [String: Any] {
        ["app": player?.bundle ?? "", "startedAt": startedAt?.timeIntervalSince1970 ?? 0, "language": lang, "lag": lag, "shown": live.shown,
         "lines": live.lines.filter { $0.id < LiveLines.guessBase }.map { l in
            ["id": l.id, "words": l.words.map { ["text": $0.text, "start": $0.start, "end": $0.end, "lang": $0.lang ?? lang] }] }]
    }
}

/// `recense hear-app [<app name | bundle id | pid>] [--seconds N] [--lang en|fr|vi] [--out file.json]`: hears what
/// that app (else whatever plays) is playing, from its own sound, on this Mac; prints each phrase as it's final and
/// writes the word-timed lines. Exit 1 when nothing was heard.
func hearAppCommand(_ a: [String]) -> Never {
    func value(_ flag: String) -> String? { a.firstIndex(of: flag).flatMap { a.index(after: $0) < a.count ? a[a.index(after: $0)] : nil } }
    let want = a.first.flatMap { $0.hasPrefix("-") ? nil : $0 }
    let seconds = value("--seconds").flatMap(Double.init) ?? 60, lang = value("--lang") ?? "en", out = value("--out")
    guard LiveEar.available else { fputs("hear-app needs macOS 26's on-device ears\n", stderr); exit(1) }
    Task { @MainActor in
        var p: AppEar.Player?
        let until = Date().addingTimeInterval(15)
        while p == nil, Date() < until {
            let all = AppEar.playing()
            if let want {
                let matches = all.filter { $0.bundle == want || $0.name.lowercased() == want.lowercased() || String($0.pid) == want }
                p = AppEar.newest(matches)
                if matches.count > 1, let p {
                    print("\(matches.count) players named \(want) (pids \(matches.map { String($0.pid) }.joined(separator: ", "))): hearing the newest, pid \(p.pid)")
                }
            } else if #available(macOS 14.2, *) {
                p = AppEar.choose(await AppEar.audible(all).players, followed: nil, front: NSWorkspace.shared.frontmostApplication?.processIdentifier)
            }
            if p == nil { try? await Task.sleep(for: .milliseconds(250)) }
        }
        guard let p else { fputs("nothing playing\(want.map { " in \($0)" } ?? "") within 15 s\n", stderr); exit(1) }
        let ear = LiveEar()
        let began = Date()
        ear.onNote = { print(String(format: "%6.1f  %@", ear.seconds, $0)); fflush(stdout) }
        guard await ear.start(p, first: lang, among: a.contains("--fixed") ? [] : SpeechCore.auto, fast: !a.contains("--single")) else {
            fputs(ear.refused ? "no System Audio Recording permission: System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording ▸ System Audio Recording Only\n"
                  : "couldn't hear \(p.name)\n", stderr)
            exit(1)
        }
        print("hearing \(p.name) (\(p.bundle)) for \(Int(seconds)) s, tap started \(String(format: "%.3f", began.timeIntervalSince1970))")
        while Date().timeIntervalSince(began) < seconds {
            try? await Task.sleep(for: .seconds(1))
            ear.refresh()
            if ear.quiet > 20 { print("(only silence for 20 s: stopping)"); break }
        }
        await ear.finish()
        let j = ear.json()
        let n = (j["lines"] as? [[String: Any]])?.reduce(0) { $0 + (($1["words"] as? [Any])?.count ?? 0) } ?? 0
        print(String(format: "%d words, last ones %.1f s after they were said", n, ear.lag))
        if let out, let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: out))
        }
        exit(n > 0 ? 0 : 1)
    }
    RunLoop.main.run()
    exit(0)
}

/// `recense selftest`: who is heard, and phrases made into lines (no permission, no audio, no model needed).
func appEarSelftest() -> Bool {
    var all = true
    func check(_ ok: Bool, _ what: String) { all = all && ok; print("\(ok ? "ok  " : "FAIL") app ear, \(what)") }
    let safari = AppEar.Player(pid: 10, name: "Safari", bundle: "com.apple.Safari")
    let spotify = AppEar.Player(pid: 20, name: "Spotify", bundle: "com.spotify.client")
    let afplay = AppEar.Player(pid: 30, name: "afplay", bundle: "afplay")
    check(AppEar.choose([safari, spotify, afplay], followed: "com.spotify.client", front: 10) == spotify, "the followed app is heard first")
    check(AppEar.choose([safari, spotify, afplay], followed: nil, front: 10) == safari, "else the frontmost app")
    check(AppEar.choose([safari, spotify, afplay], followed: "org.videolan.vlc", front: 99) == afplay, "else the one that started last")
    check(AppEar.choose([], followed: nil, front: nil) == nil, "nothing playing: nothing heard")
    let oldPlay = AppEar.Player(pid: 31, name: "afplay", bundle: "afplay")
    check(AppEar.newest([oldPlay, afplay], started: { $0 == 31 ? 100 : 200 }) == afplay
          && AppEar.newest([afplay, oldPlay], started: { $0 == 31 ? 100 : 200 }) == afplay
          && AppEar.newest([], started: { _ in 0 }) == nil, "two players with one name: the newest is heard")
    check(AppEar.startTime(getpid()) > 0 && AppEar.startTime(getpid()) <= Date().timeIntervalSince1970, "a process's start time is read")
    check(!AppEar.listenable("com.apple.systemsoundserverd") && !AppEar.listenable("local.recense") && AppEar.listenable("com.spotify.client")
          && AppEar.listenable("afplay"), "system sounds and Recense's own aren't heard; Spotify and afplay are")
    check(AppEar.stuck(hasLines: false, state: "need-bytes", for: 0) && AppEar.stuck(hasLines: false, state: "failed", for: 0)
          && AppEar.stuck(hasLines: false, state: "loading", for: 16), "a followed stream whose audio can't be fetched is heard from its app")
    check(!AppEar.stuck(hasLines: true, state: "need-bytes", for: 30) && !AppEar.stuck(hasLines: false, state: "loading", for: 5)
          && !AppEar.stuck(hasLines: false, state: "ready", for: 30), "a transcript in hand (or one still loading) isn't replaced")
    func p(_ ws: [(String, Double, Double)]) -> SpeechCore.Phrase {
        let words = ws.map { SpeechCore.W(text: $0.0, start: $0.1, end: $0.2, lang: "fr") }
        return SpeechCore.Phrase(start: ws.first?.1 ?? 0, end: ws.last?.2 ?? 0, text: ws.map(\.0).joined(separator: " "), words: words)
    }
    var l = LiveLines()
    l.add(p([("Ma", 1.0, 1.2), ("sœur", 1.2, 1.6)]), final: false)
    check(l.lines.map { $0.words.map(\.text) } == [["Ma", "sœur"]] && l.lines[0].id >= 1_000_000, "a guess shows at once, as a guess")
    l.add(p([("Ma", 1.0, 1.2), ("sœur", 1.2, 1.7), ("chante", 1.8, 2.3)]), final: false)
    check(l.lines.count == 1 && l.lines[0].words.count == 3, "a newer guess replaces the older one")
    l.add(p([("Ma", 1.0, 1.2), ("sœur", 1.2, 1.7), ("chante.", 1.8, 2.3)]), final: true)
    check(l.lines.count == 1 && l.lines[0].id < 1_000_000 && l.lines[0].words.last?.text == "chante.", "the final words take the guess's place")
    l.add(p([("chante.", 1.8, 2.3), ("Et", 2.6, 2.8), ("moi", 2.8, 3.1)]), final: false)
    check(l.lines.map { $0.words.map(\.text) } == [["Ma", "sœur", "chante."], ["Et", "moi"]], "a guess shows only what isn't final yet")
    check(l.lines[1].words[0].start == 2.6 && l.lines[1].words[0].lang == "fr", "words keep their times and language")
    check(l.lines.allSatisfy { ($0.english ?? []).isEmpty }, "no line waits on a translation")
    var s = LiveLines()
    s.add(p([("Ma", 1.0, 1.2)]), final: false, at: 1.5)
    s.add(p([("Ma", 1.0, 1.2), ("sœur", 1.2, 1.7)]), final: false, at: 2.0)
    s.add(p([("Ma", 1.0, 1.2), ("sœur", 1.2, 1.7)]), final: true, at: 9.0)
    check(s.shown == [[1.2, 1.5], [1.7, 2.0]] && s.lines[0].id < LiveLines.guessBase,
          "a guess counts as shown when it arrives; its final, later, doesn't move that time")
    // two transcribers (SpeechLive fast): the quick one's words show as one guess until the sure finals cover their span
    let ahead = SpeechCore.Ahead()
    var t = LiveLines()
    func feed(_ g: SpeechCore.Phrase?) { if let g { t.add(g, final: false) } }
    func texts() -> [String] { t.lines.flatMap { $0.words.map(\.text) } }
    feed(ahead.guess(p([("Ma", 1.0, 1.2), ("sœur", 1.2, 1.7)]), final: true))
    feed(ahead.guess(p([("chante", 1.8, 2.3)]), final: false))
    check(texts() == ["Ma", "sœur", "chante"] && t.lines.allSatisfy { $0.id >= LiveLines.guessBase },
          "fast: its own finals and its latest guess show together, all as guesses")
    let sure = p([("Ma", 1.0, 1.2), ("sœur", 1.2, 1.7)])
    t.add(sure, final: true); feed(ahead.final(sure))
    check(texts() == ["Ma", "sœur", "chante"] && t.lines.first?.id ?? 0 < LiveLines.guessBase && t.lines.last?.id ?? 0 >= LiveLines.guessBase,
          "fast: a sure final replaces the guess over its span only, nothing shown twice")
    let whole = p([("chante.", 1.8, 2.3)])   // the next sure final: its own span, after the last
    t.add(whole, final: true)
    check(ahead.final(whole) == nil && texts() == ["Ma", "sœur", "chante."] && t.lines.allSatisfy { $0.id < LiveLines.guessBase },
          "fast: once the finals reach the guess, no guess is left")
    let long = p((0..<28).map { (i: Int) -> (String, Double, Double) in ("mot\(i)", Double(i) * 0.3, Double(i) * 0.3 + 0.25) })
    var m = LiveLines(); m.add(long, final: true)
    check(m.lines.count == 2 && m.lines.allSatisfy { $0.words.count <= 14 }, "a long phrase is cut into lines of one sentence's length")
    if #available(macOS 14.2, *) {
        let t0 = Date(timeIntervalSince1970: 1000)
        check(abs(AppTap.quiet(frames: 0, loudAt: 0, rate: 48000, since: t0, now: t0.addingTimeInterval(9)) - 9) < 0.01,
              "a tap that sends no frames reads as silence by the clock (stalled Core Audio)")
        check(AppTap.quiet(frames: 96000, loudAt: 48000, rate: 48000, since: t0, now: t0.addingTimeInterval(90)) == 1
              && AppTap.quiet(frames: 0, loudAt: 0, rate: 48000, since: nil) == 0, "else silence is counted in the app's own sound")
    }
    return all
}
