import Cocoa
import CoreAudio
import AudioToolbox
import AVFoundation
import Accelerate

/// Note 30: Recense's own sound for players its bridge can't reshape (QuickTime, Music, Safari, Chrome, a Firefox page
/// whose file can't be taken). A Core Audio process tap takes the followed app's output (muting the original while
/// tapped), and an AVAudioEngine plays it again through the tray's chain: the same three bands as the bridge
/// (low shelf 160 Hz, peak 1 kHz, high shelf 5 kHz, Q 0.7), a trim that takes back the EQ's highest boost, Key
/// (time-pitch at rate 1), Space (reverb), and a peak limiter, at the tap's own sample rate. It runs only while the
/// sound isn't flat and a player is followed; a watchdog drops the tap (so the original plays again) when no frames
/// arrive for a second. Needs macOS 14.2 and the Audio Capture permission.
final class SoundEngine {
    enum State: Equatable { case off, on, unsupported, denied, failed }
    private(set) var state: State = .off
    var onState: ((State) -> Void)?
    private var pid: pid_t?
    private var sound: [String: Any] = [:]
    private var impl: AnyObject?   // SoundTap on 14.2+

    static var available: Bool { if #available(macOS 14.2, *) { return true } else { return false } }

    static func flat(_ s: [String: Any]) -> Bool {
        let eq = s["eq"] as? [String: Any] ?? [:]
        let n = { (x: Any?) in (x as? NSNumber)?.doubleValue ?? 0 }
        return n(eq["low"]) == 0 && n(eq["mid"]) == 0 && n(eq["high"]) == 0 && n(s["key"]) == 0 && n(s["mix"]) == 0 && n(s["vox"]) == 0 && n(s["chords"]) == 0
    }

    /// Follow this process (nil stops) with this sound; a flat sound stops too, so the original is never muted for nothing.
    func run(pid p: pid_t?, sound s: [String: Any]) {
        sound = s
        guard let p, !SoundEngine.flat(s) else { stop(); return }
        guard #available(macOS 14.2, *) else { set(.unsupported); return }
        if let t = impl as? SoundTap, pid == p, t.alive { t.apply(s); return }
        stop()
        pid = p
        let t = SoundTap(pid: p)
        t.onDead = { [weak self] why in DispatchQueue.main.async { self?.stop(); self?.set(why) } }
        guard t.start() else { set(t.why); return }
        t.apply(s, now: true)   // a new tap starts on the tray's sound, not on flat
        impl = t
        set(.on)
    }

    /// Seconds between the app's own sound and what this chain plays to the speakers (0 when off): the light
    /// subtracts it, so the words stay on the sound heard through EQ, Key and Space (item 22).
    var latency: Double {
        if #available(macOS 14.2, *), let t = impl as? SoundTap, t.alive { return t.latency }
        return 0
    }

    /// The chord detector's 12-bin chroma of what the chain plays (nil: not running), as keylabel.js chromaOfSpectrum.
    var chroma: [Double]? {
        if #available(macOS 14.2, *) { return (impl as? SoundTap)?.chroma() }
        return nil
    }

    func stop() {
        if #available(macOS 14.2, *) { (impl as? SoundTap)?.stop() }
        impl = nil; pid = nil
        if state == .on { set(.off) }
    }

    private func set(_ s: State) { guard s != state else { return }; state = s; onState?(s) }
}

/// One frame-ring between the tap's IO thread and the engine's render thread (interleaved floats).
private final class Ring {
    private var buf: [Float]
    private var r = 0, w = 0, count = 0
    private var lock = os_unfair_lock()
    private var stamp = Date().timeIntervalSinceReferenceDate
    let ch: Int
    /// When the tap last delivered frames (read off the IO thread under the lock).
    /// Frames written and not yet played: part of the delay between the app's sound and what is heard.
    var waiting: Int { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return count / max(1, ch) }
    var lastWrite: TimeInterval { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return stamp }
    init(frames: Int, ch: Int) { self.ch = ch; buf = [Float](repeating: 0, count: frames * ch) }
    func write(_ p: UnsafePointer<Float>, _ n: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let cap = buf.count
        for i in 0..<n { buf[w] = p[i]; w = (w + 1) % cap }
        count = min(cap, count + n)
        if count == cap { r = w }   // overrun: keep the newest
        stamp = Date().timeIntervalSinceReferenceDate
    }
    /// Fills `n` samples, silence for what isn't there (an underrun is a dropout, never noise).
    func read(_ p: UnsafeMutablePointer<Float>, _ n: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let cap = buf.count, k = min(n, count)
        for i in 0..<k { p[i] = buf[r]; r = (r + 1) % cap }
        count -= k
        if k < n { for i in k..<n { p[i] = 0 } }
    }
}

@available(macOS 14.2, *)
private final class SoundTap {
    let pid: pid_t
    var onDead: ((SoundEngine.State) -> Void)?
    private(set) var why: SoundEngine.State = .failed
    private(set) var alive = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let engine = AVAudioEngine()
    private let eq = AVAudioUnitEQ(numberOfBands: 3)
    private let pitch = AVAudioUnitTimePitch()
    private let reverb = AVAudioUnitReverb()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private var ring: Ring?
    private var scratch: UnsafeMutablePointer<Float>?
    private var vox: VoxCut?
    private var room: String?
    private var watchdog: Timer?
    private var ramp: Timer?
    private var target: [Float] = [0, 0, 0, 0]   // low, mid, high (dB), trim (dB)
    private var desc: CATapDescription?
    private var objs: Set<AudioObjectID> = []

    init(pid: pid_t) { self.pid = pid }

    func start() -> Bool {
        let objs = SoundTap.audioObjects(for: pid)
        guard !objs.isEmpty else { return fail(.failed) }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)

        let desc = CATapDescription(stereoMixdownOfProcesses: objs)
        self.desc = desc; self.objs = Set(objs)
        desc.uuid = UUID()
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        let err = AudioHardwareCreateProcessTap(desc, &tapID)
        // no Audio Capture permission shows up as a refused tap
        guard err == noErr, tapID != kAudioObjectUnknown else { return fail(err == OSStatus(kAudioHardwareIllegalOperationError) ? .denied : .failed) }

        // the tap's format: its sample rate is the one played at (no resampling of ours)
        var asbd = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr, asbd.mSampleRate > 0 else { return fail(.failed) }
        let ch = Int(max(1, asbd.mChannelsPerFrame))

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Recense Sound",
            kAudioAggregateDeviceUIDKey: "recense.sound.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID) == noErr else { return fail(.failed) }

        let ring = Ring(frames: Int(asbd.mSampleRate / 4), ch: ch)   // 250 ms of room; a few ms is used
        self.ring = ring
        let st = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggID, nil) { _, input, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let b = abl.first, let d = b.mData else { return }
            ring.write(d.assumingMemoryBound(to: Float.self), Int(b.mDataByteSize) / MemoryLayout<Float>.size)
        }
        guard st == noErr, AudioDeviceStart(aggID, ioProc) == noErr else { return fail(.failed) }

        // the engine: source (from the ring) → EQ → Key → Space → limiter → out, at the tap's rate
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: AVAudioChannelCount(ch)) else { return fail(.failed) }
        // scratch allocated once: the render thread must never allocate
        let maxFrames = 8192
        let tmp = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * ch)
        tmp.initialize(repeating: 0, count: maxFrames * ch)
        scratch = tmp
        let vox = VoxCut(sampleRate: asbd.mSampleRate)
        self.vox = vox
        let src = AVAudioSourceNode(format: fmt) { _, _, frames, abl -> OSStatus in
            let out = UnsafeMutableAudioBufferListPointer(abl), n = min(Int(frames), maxFrames)
            ring.read(tmp, n * ch)
            vox.process(tmp, n, ch)   // the extractor first: it works on the recording's own stereo
            for (c, b) in out.enumerated() where c < ch {   // deinterleave
                let d = b.mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<n { d[i] = tmp[i * ch + c] }
            }
            return noErr
        }
        let kinds: [AVAudioUnitEQFilterType] = [.lowShelf, .parametric, .highShelf]
        for (i, f) in [160, 1000, 5000].enumerated() {
            let b = eq.bands[i]
            b.filterType = kinds[i]; b.frequency = Float(f); b.bandwidth = 1.9   // octaves ≈ Q 0.7
            b.gain = 0; b.bypass = false
        }
        eq.globalGain = 0
        pitch.rate = 1; pitch.overlap = 8
        reverb.wetDryMix = 0
        for n in [src, eq, pitch, reverb, limiter] as [AVAudioNode] { engine.attach(n) }
        engine.connect(src, to: eq, format: fmt)
        engine.connect(eq, to: pitch, format: fmt)
        engine.connect(pitch, to: reverb, format: fmt)
        engine.connect(reverb, to: limiter, format: fmt)
        engine.connect(limiter, to: engine.mainMixerNode, format: fmt)
        // the chord detector listens to what is played (8192-point spectrum, as Gallery's analyser), off the render thread
        let sr = asbd.mSampleRate
        limiter.installTap(onBus: 0, bufferSize: 8192, format: fmt) { [weak self] buf, _ in
            guard let self, let d = buf.floatChannelData, buf.frameLength > 0 else { return }
            let c = SoundTap.chromaOf(d, Int(buf.frameLength), Int(buf.format.channelCount), sr)
            os_unfair_lock_lock(&self.chromaLock); self.lastChroma = c; os_unfair_lock_unlock(&self.chromaLock)
        }
        do { try engine.start() } catch { return fail(.failed) }

        alive = true
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.alive else { return }
            // a stuck tap (or engine) must never leave the original muted
            if Date().timeIntervalSinceReferenceDate - (self.ring?.lastWrite ?? 0) > 1 || !self.engine.isRunning { self.stop(); self.onDead?(.failed); return }
            self.refresh()
        }
        return true
    }

    /// The processes are a list taken when the tap starts; a browser plays a newly opened tab (or a reloaded page) from a
    /// content process that wasn't making sound then, which went untapped: heard as it is, no EQ or Key, until something
    /// restarted the tap (item 21). So the list is kept current, on the running tap.
    private func refresh() {
        guard let desc else { return }
        let now = SoundTap.audioObjects(for: pid)
        guard !now.isEmpty, Set(now) != objs else { return }
        desc.processes = now
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var d: CATapDescription = desc
        let st = withUnsafeMutablePointer(to: &d) { AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0) }
        log("sound: tap now takes \(now.count) processes (was \(objs.count))\(st == noErr ? "" : ", error \(st)")")
        if st == noErr { objs = Set(now) } else { stop(); onDead?(.failed) }   // a fresh tap takes the new list
    }

    private var chromaLock = os_unfair_lock()
    private var lastChroma: [Double]?
    var latency: Double {
        let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
        var l = engine.outputNode.presentationLatency
        for u in [eq, pitch, reverb, limiter] as [AVAudioUnit] where !u.auAudioUnit.shouldBypassEffect { l += u.auAudioUnit.latency }
        if let ring, sr > 0 { l += Double(ring.waiting) / sr }
        if let vox, vox.amount != 0, sr > 0 { l += Double(VoxCut.LAT) / sr }
        return max(0, min(1, l))
    }
    func chroma() -> [Double]? { os_unfair_lock_lock(&chromaLock); defer { os_unfair_lock_unlock(&chromaLock) }; return lastChroma }

    /// 12 pitch classes from a Hann-windowed spectrum (55 Hz – 2 kHz, each bin's magnitude to its nearest note, A = 9).
    static func chromaOf(_ d: UnsafePointer<UnsafeMutablePointer<Float>>, _ n: Int, _ ch: Int, _ sr: Double) -> [Double] {
        var N = 1; while N * 2 <= min(n, 8192) { N *= 2 }
        var x = [Float](repeating: 0, count: N), zero = [Float](repeating: 0, count: N)
        for i in 0..<N { var v: Float = 0; for c in 0..<ch { v += d[c][n - N + i] }; x[i] = v / Float(ch) * Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(N))) }
        var re = [Float](repeating: 0, count: N), im = [Float](repeating: 0, count: N)
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(N), .FORWARD) else { return Array(repeating: 0, count: 12) }
        vDSP_DFT_Execute(setup, x, zero, &re, &im)
        vDSP_DFT_DestroySetup(setup)
        var chroma = [Double](repeating: 0, count: 12)
        let lo = max(1, Int(ceil(55 * Double(N) / sr))), hi = min(N / 2 - 1, Int(2000 * Double(N) / sr))
        guard lo <= hi else { return chroma }
        for b in lo...hi {
            let m = Double((re[b] * re[b] + im[b] * im[b]).squareRoot())
            let pc = (Int((12 * log2(Double(b) * sr / Double(N) / 440)).rounded()) + 9) % 12
            chroma[(pc + 12) % 12] += m
        }
        return chroma
    }

    /// The tray's values, glided over ~60 ms so a drag never clicks.
    func apply(_ s: [String: Any], now: Bool = false) {
        let n = { (x: Any?) in Float((x as? NSNumber)?.doubleValue ?? 0) }
        let e = s["eq"] as? [String: Any] ?? [:]
        let g = [n(e["low"]), n(e["mid"]), n(e["high"])]
        // trim: take back the highest boost (shelves and the peak barely overlap at Q 0.7), so a boost never clips
        let trim = -max(0, g.max() ?? 0, g[0] > 0 && g[1] > 0 ? (g[0] + g[1]) * 0.6 : 0, g[1] > 0 && g[2] > 0 ? (g[1] + g[2]) * 0.6 : 0)
        target = g + [trim]
        if now { for i in 0..<3 { eq.bands[i].gain = g[i] }; eq.globalGain = trim }
        vox?.amount = max(-1, min(1, n(s["vox"])))   // the extractor: −1 the vocals out, 1 the vocals alone
        pitch.pitch = max(-2400, min(2400, n(s["key"]) * 100))   // Key in semitones
        pitch.bypass = n(s["key"]) == 0
        let room = s["room"] as? String ?? "room"
        if room != self.room { reverb.loadFactoryPreset(room == "hall" ? .largeHall : .mediumRoom); self.room = room }   // reloading each drag resets the tail
        reverb.wetDryMix = min(100, abs(n(s["mix"])))   // a reversed room has no native match: the forward one plays
        if ramp == nil {
            ramp = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                var done = true
                for i in 0..<3 {
                    let c = self.eq.bands[i].gain, d = self.target[i] - c
                    self.eq.bands[i].gain = abs(d) < 0.05 ? self.target[i] : c + d * 0.45   // ~50 ms: heard at once, no click
                    if abs(d) >= 0.05 { done = false }
                }
                let c = self.eq.globalGain, d = self.target[3] - c
                self.eq.globalGain = abs(d) < 0.05 ? self.target[3] : c + d * (d < 0 ? 0.6 : 0.2)   // down fast, up slow
                if abs(d) >= 0.05 { done = false }
                if done { t.invalidate(); self.ramp = nil }
            }
        }
    }

    func stop() {
        guard alive || aggID != kAudioObjectUnknown || tapID != kAudioObjectUnknown else { return }
        alive = false
        watchdog?.invalidate(); watchdog = nil
        ramp?.invalidate(); ramp = nil
        limiter.removeTap(onBus: 0)
        lastChroma = nil
        engine.stop()
        if let io = ioProc { AudioDeviceStop(aggID, io); AudioDeviceDestroyIOProcID(aggID, io); ioProc = nil }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        // destroying the tap is what unmutes the original
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }

    /// The audio objects of an app and of its helpers: a browser plays from its content processes, not its own.
    /// Helpers are the app's children (Firefox, Chromium) or, for Safari, WebKit's WebContent (shared by every WebKit app).
    static func audioObjects(for app: pid_t) -> [AudioObjectID] {
        func get<T>(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector, _ v: inout T) -> Bool {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var n = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(o, &a, 0, nil, &n, &v) == noErr
        }
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var n = UInt32(0), sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &n) == noErr, n > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(n) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &n, &list) == noErr else { return [] }
        let safari = NSRunningApplication(processIdentifier: app)?.bundleIdentifier?.hasPrefix("com.apple.Safari") == true
        return list.filter { o in
            var p: pid_t = -1
            guard get(o, kAudioProcessPropertyPID, &p), p > 0 else { return false }
            if p == app || parent(of: p) == app { return true }
            guard safari else { return false }
            var b: CFString = "" as CFString
            return get(o, kAudioProcessPropertyBundleID, &b) && (b as String).hasPrefix("com.apple.WebKit.WebContent")
        }
    }
    private static func parent(of p: pid_t) -> pid_t {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, p]
        return sysctl(&mib, 4, &info, &size, nil, 0) == 0 ? info.kp_eproc.e_ppid : -1
    }

    private func fail(_ s: SoundEngine.State) -> Bool { why = s; stop(); return false }
    deinit { stop(); scratch?.deallocate() }
}


/// The extractor (SPEC 30; notes 32: Recense's tray has all of Gallery's), Gallery's Center Cut (player-key.js "pdc-vox")
/// ported: each 4096-frame window of both channels goes to the frequency domain (one complex transform carries the two),
/// and in every bin the part the channels share, the centre where the voice almost always is, is estimated (their sum,
/// scaled down by how much they differ there). Below 0 it comes out of both channels, the lowest notes (bass, kick) left
/// in: an instrumental. Above 0 it is kept alone, without those lows: the voice. Hann in and out, 4 overlapping. At 0
/// nothing is done (no latency); it starts afresh when turned on. Render-thread safe: everything is allocated up front.
final class VoxCut {
    static let N = 4096, HOP = 1024, HALF = 2048, LAT = 4096 - 1024
    /// −1 … 1, written on the main thread, read on the render thread
    var amount: Float = 0
    private var running = false
    private let fwd: vDSP_DFT_Setup, inv: vDSP_DFT_Setup
    private let win, keepLow, voice: UnsafeMutablePointer<Float>
    private let inL, inR, acL, acR, oL, oR, re, im, ore, oim: UnsafeMutablePointer<Float>
    private var rover = VoxCut.LAT

    init(sampleRate sr: Double) {
        let N = VoxCut.N
        fwd = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(N), .FORWARD)!
        inv = vDSP_DFT_zop_CreateSetup(fwd, vDSP_Length(N), .INVERSE)!
        func buf(_ n: Int) -> UnsafeMutablePointer<Float> { let p = UnsafeMutablePointer<Float>.allocate(capacity: n); p.initialize(repeating: 0, count: n); return p }
        win = buf(N); keepLow = buf(VoxCut.HALF + 1); voice = buf(VoxCut.HALF + 1)
        inL = buf(N); inR = buf(N); acL = buf(N); acR = buf(N); oL = buf(VoxCut.HOP); oR = buf(VoxCut.HOP)
        re = buf(N); im = buf(N); ore = buf(N); oim = buf(N)
        for i in 0..<N { win[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(N))) }
        // a raised-cosine step from 0 at f0 to 1 at f1
        func ramp(_ f: Double, _ f0: Double, _ f1: Double) -> Float { f <= f0 ? 0 : f >= f1 ? 1 : Float(0.5 - 0.5 * cos(Double.pi * (f - f0) / (f1 - f0))) }
        for k in 0...VoxCut.HALF {
            let f = Double(k) * sr / Double(N)
            keepLow[k] = ramp(f, 90, 180)   // how much of the centre comes out: none below 90 Hz, all above 180
            voice[k] = ramp(f, 60, 120)     // how much of the centre the voice alone keeps: none below 60 Hz
        }
    }
    deinit {
        vDSP_DFT_DestroySetup(fwd); vDSP_DFT_DestroySetup(inv)
        for p in [win, keepLow, voice, inL, inR, acL, acR, oL, oR, re, im, ore, oim] { p.deallocate() }
    }

    private func clear() {
        inL.update(repeating: 0, count: VoxCut.N); inR.update(repeating: 0, count: VoxCut.N)
        acL.update(repeating: 0, count: VoxCut.N); acR.update(repeating: 0, count: VoxCut.N)
        oL.update(repeating: 0, count: VoxCut.HOP); oR.update(repeating: 0, count: VoxCut.HOP)
        rover = VoxCut.LAT
    }

    /// `n` interleaved frames of `ch` channels, in place (stereo only: a mono recording is all centre).
    func process(_ x: UnsafeMutablePointer<Float>, _ n: Int, _ ch: Int) {
        guard ch == 2 else { return }
        if amount == 0 { running = false; return }
        if !running { clear(); running = true }
        for i in 0..<n {
            inL[rover] = x[2 * i]; inR[rover] = x[2 * i + 1]
            x[2 * i] = oL[rover - VoxCut.LAT]; x[2 * i + 1] = oR[rover - VoxCut.LAT]
            rover += 1
            if rover >= VoxCut.N { frame(); rover = VoxCut.LAT }
        }
    }

    private func frame() {
        let N = VoxCut.N, H = VoxCut.HALF, a = amount
        for i in 0..<N { re[i] = inL[i] * win[i]; im[i] = inR[i] * win[i] }
        vDSP_DFT_Execute(fwd, re, im, ore, oim)
        for k in 0...H {
            // the two channels out of the one transform: L = (Z[k] + Z*[N−k]) / 2, R = (Z[k] − Z*[N−k]) / 2i
            let j = (N - k) & (N - 1)
            let zr = ore[k], zi = oim[k], cr = ore[j], ci = -oim[j]
            let Lr = 0.5 * (zr + cr), Li = 0.5 * (zi + ci), Rr = 0.5 * (zi - ci), Ri = 0.5 * (cr - zr)
            let Sr = Lr + Rr, Si = Li + Ri, Dr = Lr - Rr, Di = Li - Ri
            let s2 = Sr * Sr + Si * Si, d2 = Dr * Dr + Di * Di
            let al = s2 > 1e-30 ? max(0, 0.5 - 0.5 * (d2 / s2).squareRoot()) : 0
            let Cr = al * Sr, Ci = al * Si
            var lr: Float, li: Float, rr: Float, ri: Float
            if a <= 0 {
                let m = -a * keepLow[k]
                lr = Lr - m * Cr; li = Li - m * Ci; rr = Rr - m * Cr; ri = Ri - m * Ci
            } else {
                let u = 1 - a, w = a * voice[k]
                lr = u * Lr + w * Cr; li = u * Li + w * Ci; rr = u * Rr + w * Cr; ri = u * Ri + w * Ci
            }
            // both channels back into one spectrum, Z = L + iR, over both halves
            re[k] = lr - ri; im[k] = li + rr
            if k > 0 && k < H { re[N - k] = lr + ri; im[N - k] = rr - li }
        }
        vDSP_DFT_Execute(inv, re, im, ore, oim)
        let scale = Float(1 / (1.5 * Double(N)))   // the inverse gives N times the frame; Hann² 4 times over sums to 1.5
        for i in 0..<N { acL[i] += win[i] * ore[i] * scale; acR[i] += win[i] * oim[i] * scale }
        oL.update(from: acL, count: VoxCut.HOP); oR.update(from: acR, count: VoxCut.HOP)
        let keep = (N - VoxCut.HOP) * MemoryLayout<Float>.size   // (no arrays here: the render thread never allocates)
        memmove(acL, acL + VoxCut.HOP, keep); memmove(acR, acR + VoxCut.HOP, keep)
        memmove(inL, inL + VoxCut.HOP, keep); memmove(inR, inR + VoxCut.HOP, keep)
        acL.advanced(by: N - VoxCut.HOP).update(repeating: 0, count: VoxCut.HOP)
        acR.advanced(by: N - VoxCut.HOP).update(repeating: 0, count: VoxCut.HOP)
    }
}
