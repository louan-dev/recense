// Recense's ears, one engine for the Mac and the iPhone and iPad (milestone 3, 2026-11-08). Compiled by both apps:
// the Mac through strip/Sources/recense/speechcore.swift (a link to this file; strip/speech.swift builds on it), the iOS
// app through the synchronized shared/ group, and the broadcast extension by its own entry in the Xcode project.
//
// Apple's SpeechAnalyzer (macOS 26 / iOS 26): offline at the moment of use, every word timed. The language's model is
// fetched once, at setup (AssetInventory), and then lives on the device. Two modules:
//   SpeechTranscriber      English and French (the long-form model)
//   DictationTranscriber   Vietnamese (SpeechTranscriber has none), and the one that takes a custom language model
// Where SpeechAnalyzer isn't there (iOS 18-25, an SDK before 26), `SpeechLegacy` hears with SFSpeechRecognizer on the
// device instead: word times too (its segments), less accurate, and never sent anywhere (requiresOnDeviceRecognition).
//
//   SpeechCore     the words and phrases (plain types, every OS), tidy, the locale for a language code
//   SpeechEngine   which module hears a language, its model made ready, a file (or a stretch of it) heard
//   SpeechLive     a live stream heard as it comes (the broadcast extension: whatever plays on the iPhone)
//   SpeechAhead    a file heard in two-minute stretches ahead of the playhead (the app's own playback)
//   SpeechLegacy   SFSpeechRecognizer, on the device, for what SpeechAnalyzer can't reach
import Foundation
import AVFoundation
import CoreMedia
#if canImport(Speech)
import Speech
#endif

enum SpeechCore {
    /// A word as heard, timed in seconds from the audio's start. `c`: how sure the recognizer was (0-1);
    /// `heard`: what the recognizer wrote, when a lesson wrote another word over it (the Mac's Lexicon).
    struct W: Codable, Equatable, Sendable {
        var text: String; var start: Double; var end: Double; var c: Double = 1; var lang: String; var heard: String? = nil
    }
    /// A run of words the voice says without stopping.
    struct Phrase: Codable, Equatable, Sendable {
        var start: Double; var end: Double; var text: String; var alts: [String] = []; var words: [W]
    }
    enum Module: String, Sendable { case speech = "apple.speechtranscriber", dictation = "apple.dictationtranscriber" }

    /// Where the engine's notes go (the Mac points it at Recense's log).
    nonisolated(unsafe) static var note: (String) -> Void = { print("speech: " + $0) }

    /// The locale asked for a language code (en, fr, vi): the region Recense's listener hears first.
    static func locale(_ lang: String) -> Locale {
        Locale(identifier: ["en": "en-US", "fr": "fr-FR", "vi": "vi-VN"][lang] ?? lang)
    }
    /// "en-US" → "en"; "vi_VN" → "vi".
    static func code(_ identifier: String) -> String {
        String(identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(identifier)).lowercased()
    }

    /// A model hearing speech in a language it doesn't know may write one word of its own over all of it ("Bonjour",
    /// timed over a whole English sentence): a word longer than 1.5 s keeps only its last 0.6 s, and phrases are cut
    /// where the voice really stops (2.5 s of nothing, or a pause after a thought), so a line is a breath, not a word.
    static func tidy(_ phrases: [Phrase]) -> [Phrase] {
        var out: [Phrase] = []
        for p in phrases where !p.words.isEmpty {
            let ws = p.words.map { w -> W in var x = w; if x.end - x.start > 1.5 { x.start = x.end - 0.6 }; return x }
            var cur: [W] = []
            func flush(_ whole: Bool) {
                guard let a = cur.first, let b = cur.last else { return }
                out.append(Phrase(start: a.start, end: b.end, text: cur.map(\.text).joined(separator: " "), alts: whole ? p.alts : [], words: cur))
                cur = []
            }
            for w in ws {
                // a slow song pauses 0.8 s between its words; cutting there made every word its own line (notes 20261029 item 21)
                if let last = cur.last {
                    let gap = w.start - last.end, ends = last.text.range(of: "[.!?…;:,]$", options: .regularExpression) != nil
                    if gap > 2.5 || (gap > 0.8 && (ends || cur.count >= 12)) { flush(false) }
                }
                cur.append(w)
            }
            flush(out.last.map { $0.start < p.start } ?? true && cur.count == ws.count)
        }
        return out
    }

    /// The words of `phrases` that start in [from, to), regrouped by phrase (a stretch heard with a margin each side
    /// keeps only its own words, so neighbouring stretches meet without a word twice or a word cut in half).
    static func clip(_ phrases: [Phrase], from: Double, to: Double) -> [Phrase] {
        phrases.compactMap { p in
            let ws = p.words.filter { $0.start >= from && $0.start < to }
            guard let a = ws.first, let b = ws.last else { return nil }
            return ws.count == p.words.count ? p : Phrase(start: a.start, end: b.end, text: ws.map(\.text).joined(separator: " "), alts: [], words: ws)
        }
    }

    /// Every phrase moved by `dt` seconds (a stretch heard from its own start, placed in the whole recording).
    static func shift(_ phrases: [Phrase], by dt: Double) -> [Phrase] {
        guard dt != 0 else { return phrases }
        return phrases.map { p in
            var q = p; q.start += dt; q.end += dt
            q.words = p.words.map { var w = $0; w.start += dt; w.end += dt; return w }
            return q
        }
    }

    /// A ReplayKit or capture sample buffer as a PCM buffer (app audio comes big-endian on some iOS versions: swapped).
    static func pcm(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb), var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        let big = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        if big { asbd.mFormatFlags &= ~kAudioFormatFlagIsBigEndian }
        guard frames > 0, let fmt = AVAudioFormat(streamDescription: &asbd), let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList) == noErr else { return nil }
        if big, asbd.mBitsPerChannel == 16 {
            for b in UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList) {
                guard let p = b.mData?.assumingMemoryBound(to: UInt16.self) else { continue }
                for i in 0..<Int(b.mDataByteSize) / 2 { p[i] = p[i].byteSwapped }
            }
        }
        return buf
    }
}

/// Turns buffers of any format into the one the analyzer wants, keeping its state between them (a stream).
final class SpeechConverter {
    let format: AVAudioFormat
    private var converter: AVAudioConverter?
    init(to format: AVAudioFormat) { self.format = format }

    func convert(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buf.format == format { return buf }
        if converter == nil || converter!.inputFormat != buf.format { converter = AVAudioConverter(from: buf.format, to: format) }
        guard let converter else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * format.sampleRate / buf.format.sampleRate) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
        var given = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return buf
        }
        return err == nil && out.frameLength > 0 ? out : nil
    }
}

/// Results arriving from the analyzer's task, gathered under a lock.
final class SpeechBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SpeechCore.Phrase] = []
    func add(_ p: SpeechCore.Phrase) { lock.lock(); items.append(p); lock.unlock() }
    var all: [SpeechCore.Phrase] { lock.lock(); defer { lock.unlock() }; return items }
}

#if compiler(>=6.2) && canImport(Speech)
@available(macOS 26, iOS 26, *)
@MainActor enum SpeechEngine {
    /// The module that hears a language here, and its locale; nil: neither does.
    static var modules: [String: (SpeechCore.Module, Locale)?] = [:]
    static func module(_ lang: String) async -> (SpeechCore.Module, Locale)? {
        if let m = modules[lang] { return m }
        let want = SpeechCore.locale(lang)
        var m: (SpeechCore.Module, Locale)?
        if SpeechTranscriber.isAvailable, let l = await SpeechTranscriber.supportedLocale(equivalentTo: want) { m = (.speech, l) }
        else if let l = await DictationTranscriber.supportedLocale(equivalentTo: want) { m = (.dictation, l) }
        modules[lang] = m
        if m == nil { SpeechCore.note("no on-device model for \(lang)") }
        return m
    }

    /// Every language code SpeechAnalyzer can hear on this device (installed or not), both modules.
    static func languages() async -> [String] {
        let s = SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocales : []
        let d = await DictationTranscriber.supportedLocales
        return Set((s + d).map { SpeechCore.code($0.identifier(.bcp47)) }).sorted()
    }

    static func probe(_ m: SpeechCore.Module, _ l: Locale) -> any SpeechModule {
        m == .speech ? SpeechTranscriber(locale: l, preset: .transcription) : DictationTranscriber(locale: l, preset: .longDictation)
    }

    /// Whether the locale's model is already on this device.
    static func installed(_ m: SpeechCore.Module, _ l: Locale) async -> Bool {
        let have = m == .speech ? await SpeechTranscriber.installedLocales : await DictationTranscriber.installedLocales
        return have.contains { $0.identifier(.bcp47) == l.identifier(.bcp47) }
    }

    /// The locale's model on this device, downloaded once (the one moment this needs a connection; `download: false`
    /// never fetches: the broadcast extension uses what the app installed) and reserved. The system lets an app hold a
    /// few locales (5 on the Mac): a new one lets go of the one used longest ago, `keep` (the listener's own) last.
    static var ready: Set<String> = []
    static var used: [String: Date] = [:]
    static func prepare(_ m: SpeechCore.Module, _ l: Locale, keep: Set<String> = [], download: Bool = true) async -> Bool {
        let id = m.rawValue + "|" + l.identifier
        used[l.identifier(.bcp47)] = Date()
        if ready.contains(id) { return true }
        let held = await AssetInventory.reservedLocales
        if held.count >= AssetInventory.maximumReservedLocales, !held.contains(where: { $0.identifier(.bcp47) == l.identifier(.bcp47) }) {
            let old = held.min { a, b in
                let oa = keep.contains(a.language.languageCode?.identifier ?? ""), ob = keep.contains(b.language.languageCode?.identifier ?? "")
                return oa != ob ? !oa : (used[a.identifier(.bcp47)] ?? .distantPast) < (used[b.identifier(.bcp47)] ?? .distantPast)
            }
            if let old, await AssetInventory.release(reservedLocale: old) {
                ready = ready.filter { !$0.hasSuffix("|" + old.identifier) }
                SpeechCore.note("let go of the \(old.identifier) model to make room for \(l.identifier)")
            }
        }
        if !(await installed(m, l)) {
            guard download else { SpeechCore.note("the \(l.identifier) model isn't on this device yet"); return false }
            do {
                if let r = try await AssetInventory.assetInstallationRequest(supporting: [probe(m, l)]) {
                    SpeechCore.note("downloading the \(l.identifier) model (\(m.rawValue))")
                    try await r.downloadAndInstall()
                }
            } catch { SpeechCore.note("the \(l.identifier) model isn't here and couldn't be fetched: \(error.localizedDescription)"); return false }
        }
        _ = try? await AssetInventory.reserve(locale: l)
        ready.insert(id)
        return true
    }

    /// The module for one hearing, and the task that hands on each result (`final` false: a live guess that a later
    /// result replaces). `live`: volatile results, for a stream heard as it comes.
    static func make(_ m: SpeechCore.Module, _ l: Locale, _ lang: String, live: Bool, custom: SFSpeechLanguageModel.Configuration?,
                     each: @escaping @Sendable (SpeechCore.Phrase, Bool) -> Void) -> (any SpeechModule, Task<Void, Error>) {
        let attrs: Set<SpeechTranscriber.ResultAttributeOption> = [.audioTimeRange, .transcriptionConfidence]
        switch m {
        case .speech:
            let t = SpeechTranscriber(locale: l, transcriptionOptions: [], reportingOptions: live ? [.volatileResults] : [.alternativeTranscriptions],
                                      attributeOptions: attrs)
            return (t, Task { for try await r in t.results { each(phrase(r.range, r.text, r.alternatives, lang), r.isFinal) } })
        case .dictation:
            var hints = Set<DictationTranscriber.ContentHint>()
            if let custom { hints.insert(.customizedLanguage(modelConfiguration: custom)) }
            let t = DictationTranscriber(locale: l, contentHints: hints, transcriptionOptions: [.punctuation],
                                         reportingOptions: live ? [.volatileResults] : [.alternativeTranscriptions],
                                         attributeOptions: [.audioTimeRange, .transcriptionConfidence])
            return (t, Task { for try await r in t.results { each(phrase(r.range, r.text, r.alternatives, lang), r.isFinal) } })
        }
    }

    /// DictationTranscriber fails with "RecogFailed" on speech in a language not its own (silence comes back empty):
    /// it heard nothing it can write, which is an empty hearing, not an error to retry forever.
    nonisolated static func nothing(_ e: Error) -> Bool { let n = e as NSError; return n.domain == "SFSpeechErrorDomain" && n.localizedDescription == "RecogFailed" }

    /// Silence put before every stretch: DictationTranscriber fails ("RecogFailed", nothing heard) on audio whose
    /// voice starts in its first instant. Measured on this Mac (macOS 27, 2026-11-08): a Vietnamese sentence from 0 s
    /// failed; with 0.5 s of silence before it, every word came back. A two-minute stretch cut mid-sentence is that case.
    nonisolated static let lead = 0.5

    /// Results moved back by the lead of silence (none earlier than 0).
    nonisolated static func unlead(_ phrases: [SpeechCore.Phrase]) -> [SpeechCore.Phrase] {
        SpeechCore.shift(phrases, by: -lead).map { p in
            var q = p; q.start = max(0, q.start); q.end = max(q.start, q.end)
            q.words = p.words.map { var w = $0; w.start = max(0, w.start); w.end = max(w.start, w.end); return w }
            return q
        }
    }

    /// A whole file heard in one language with one module (and a custom language model, when given).
    static func hear(_ file: AVAudioFile, _ lang: String, module m: SpeechCore.Module, _ l: Locale,
                     custom: SFSpeechLanguageModel.Configuration? = nil) async throws -> [SpeechCore.Phrase] {
        try await hear(file, frames: 0..<file.length, lang, module: m, l, custom: custom)
    }

    /// The stretch [from, to) of a media file (any format AVAudioFile reads: m4a, mp3, wav, caf), heard with a second's
    /// margin each side and clipped back, its times in the whole file's seconds.
    static func hear(url: URL, from: Double, to: Double, _ lang: String, module m: SpeechCore.Module, _ l: Locale) async throws -> [SpeechCore.Phrase] {
        let file = try AVAudioFile(forReading: url)
        let sr = file.processingFormat.sampleRate
        let a = max(0, from - 1), b = to + 1
        let first = AVAudioFramePosition(a * sr), end = min(file.length, AVAudioFramePosition(b * sr))
        guard end > first else { return [] }
        let heard = try await hear(file, frames: first..<end, lang, module: m, l, custom: nil)
        return SpeechCore.clip(SpeechCore.shift(heard, by: a), from: from, to: to)
    }

    /// Frames of a file, read and converted ten seconds at a time (a long stretch never sits in memory whole), after
    /// `lead` of silence; times from the first frame.
    static func hear(_ file: AVAudioFile, frames: Range<AVAudioFramePosition>, _ lang: String, module m: SpeechCore.Module, _ l: Locale,
                     custom: SFSpeechLanguageModel.Configuration?) async throws -> [SpeechCore.Phrase] {
        let box = SpeechBox()
        let (module, collect) = make(m, l, lang, live: false, custom: custom) { p, _ in box.add(p) }
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: file.processingFormat),
              let quiet = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(fmt.sampleRate * lead)) else { collect.cancel(); return [] }
        quiet.frameLength = quiet.frameCapacity       // a new buffer's samples are zero
        let conv = SpeechConverter(to: fmt)
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input.yield(AnalyzerInput(buffer: quiet))
        file.framePosition = frames.lowerBound
        let block = AVAudioFrameCount(file.processingFormat.sampleRate * 10)
        var left = frames.count
        while left > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block) {
            try file.read(into: buf, frameCount: AVAudioFrameCount(min(Int(block), left)))
            guard buf.frameLength > 0 else { break }
            left -= Int(buf.frameLength)
            if let c = conv.convert(buf) { input.yield(AnalyzerInput(buffer: c)) }
        }
        input.finish()
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .utility, modelRetention: .lingering))
        do {
            if let last = try await analyzer.analyzeSequence(stream) { try await analyzer.finalizeAndFinish(through: last) }
            else { await analyzer.cancelAndFinishNow() }
            try await collect.value
        } catch {
            collect.cancel(); rest()
            if nothing(error) { return [] }
            throw error
        }
        rest()
        return SpeechCore.tidy(unlead(box.all))
    }

    nonisolated static func phrase(_ range: CMTimeRange, _ text: AttributedString, _ alts: [AttributedString], _ lang: String) -> SpeechCore.Phrase {
        var ws: [SpeechCore.W] = []
        for run in text.runs {
            let t = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, let r = run.audioTimeRange else { continue }
            ws.append(SpeechCore.W(text: t, start: r.start.seconds, end: r.end.seconds, c: run.transcriptionConfidence ?? 1, lang: lang))
        }
        return SpeechCore.Phrase(start: range.start.seconds, end: range.end.seconds, text: String(text.characters).trimmingCharacters(in: .whitespaces),
                                 alts: alts.map { String($0.characters).trimmingCharacters(in: .whitespaces) }, words: ws)
    }

    /// The models stay warm between requests and are let go after three quiet minutes.
    static var resting: Task<Void, Never>?
    static func rest() {
        resting?.cancel()
        resting = Task { try? await Task.sleep(for: .seconds(180)); guard !Task.isCancelled else { return }; await SpeechModels.endRetention() }
    }

    /// What this device hears offline, per language asked: the module, its locale, whether the model is here.
    static func report(_ langs: [String]) async -> [String: String] {
        var out: [String: String] = [:]
        for lang in langs {
            guard let (m, l) = await module(lang) else { out[lang] = "none"; continue }
            out[lang] = "\(m == .speech ? "SpeechTranscriber" : "DictationTranscriber") \(l.identifier(.bcp47)) " + (await installed(m, l) ? "installed" : "not downloaded")
        }
        return out
    }
}

/// A live stream heard as it comes: the broadcast extension's audio of whatever plays, or a microphone. Words are timed
/// from the stream's first buffer. `each` gets every result: a live guess (final false) that the next result replaces,
/// then the final words of that stretch. `append` may be called from any thread.
@available(macOS 26, iOS 26, *)
final class SpeechLive: @unchecked Sendable {
    let lang: String
    let module: SpeechCore.Module
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let conv: SpeechConverter
    private let analyzer: SpeechAnalyzer
    private let collect: Task<Void, Error>
    private let lock = NSLock()

    private init(lang: String, module: SpeechCore.Module, input: AsyncStream<AnalyzerInput>.Continuation, conv: SpeechConverter,
                 analyzer: SpeechAnalyzer, collect: Task<Void, Error>) {
        self.lang = lang; self.module = module; self.input = input; self.conv = conv; self.analyzer = analyzer; self.collect = collect
    }

    /// nil: this device has no SpeechAnalyzer model for the language (or, with `download: false`, it isn't installed).
    @MainActor static func start(lang: String, download: Bool, each: @escaping @Sendable (SpeechCore.Phrase, Bool) -> Void) async throws -> SpeechLive? {
        guard let (m, l) = await SpeechEngine.module(lang), await SpeechEngine.prepare(m, l, download: download) else { return nil }
        let (module, collect) = SpeechEngine.make(m, l, lang, live: true, custom: nil) { p, fin in
            each(SpeechEngine.unlead([p])[0], fin)
        }
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { collect.cancel(); return nil }
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        try await analyzer.start(inputSequence: stream)
        // the same lead of silence as a file (SpeechEngine.lead), its time taken off every result
        if let quiet = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(fmt.sampleRate * SpeechEngine.lead)) {
            quiet.frameLength = quiet.frameCapacity; input.yield(AnalyzerInput(buffer: quiet))
        }
        return SpeechLive(lang: lang, module: m, input: input, conv: SpeechConverter(to: fmt), analyzer: analyzer, collect: collect)
    }

    func append(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if let c = conv.convert(buf) { input.yield(AnalyzerInput(buffer: c)) }
    }

    /// The last words finalized, then the stream let go.
    func finish() async {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = try? await collect.value
    }
    func cancel() { input.finish(); collect.cancel(); Task { await analyzer.cancelAndFinishNow() } }
}
#endif

#if canImport(Speech)
/// SFSpeechRecognizer on the device: the fallback where SpeechAnalyzer isn't there. Never sent anywhere.
enum SpeechLegacy {
    static func hears(_ lang: String) -> Bool {
        SFSpeechRecognizer(locale: SpeechCore.locale(lang))?.supportsOnDeviceRecognition == true
    }

    /// A whole file, its words timed by the recognizer's segments.
    static func hear(url: URL, _ lang: String) async throws -> [SpeechCore.Phrase] {
        guard let r = SFSpeechRecognizer(locale: SpeechCore.locale(lang)), r.supportsOnDeviceRecognition else { return [] }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        let words: [SpeechCore.W] = try await withCheckedThrowingContinuation { c in
            var done = false
            r.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let error { done = true; c.resume(throwing: error); return }
                guard let result, result.isFinal else { return }
                done = true
                c.resume(returning: Self.words(result.bestTranscription.segments, lang: lang))
            }
        }
        guard let a = words.first, let b = words.last else { return [] }
        return SpeechCore.tidy([SpeechCore.Phrase(start: a.start, end: b.end, text: words.map(\.text).joined(separator: " "), words: words)])
    }

    /// The recognizer gives punctuation as its own segments ("gros ," "d' installer"): glued back to the word before.
    static func words(_ segs: [SFTranscriptionSegment], lang: String) -> [SpeechCore.W] {
        var out: [SpeechCore.W] = []
        for s in segs {
            let t = s.substring.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if let last = out.last, t.range(of: #"^[,.?!;:…]+$"#, options: .regularExpression) != nil || last.text.hasSuffix("'") {
                out[out.count - 1].text += t; out[out.count - 1].end = max(last.end, s.timestamp + s.duration); continue
            }
            out.append(SpeechCore.W(text: t, start: s.timestamp, end: s.timestamp + s.duration, c: Double(s.confidence), lang: lang))
        }
        return out
    }
}

/// A media file heard in two-minute stretches, the stretch under the playhead first, then the ones after it, then any
/// before (the way the Mac's transcribeLoop stays ahead of what plays). SpeechAnalyzer where there is one; else
/// SFSpeechRecognizer hears the whole file once. `changed` gets every phrase heard so far, in time order.
@MainActor final class SpeechAhead {
    let url: URL
    let lang: String
    let duration: Double
    nonisolated static let stretch = 120.0
    private(set) var phrases: [SpeechCore.Phrase] = []
    private(set) var done: Set<Int> = []
    private(set) var problem: String?
    var playhead: () -> Double = { 0 }
    var changed: ([SpeechCore.Phrase]) -> Void = { _ in }
    private var task: Task<Void, Never>?

    init(url: URL, lang: String, duration: Double) { self.url = url; self.lang = lang; self.duration = duration }

    var count: Int { max(1, Int((duration / Self.stretch).rounded(.up))) }
    var finished: Bool { done.count >= count }

    func start() { guard task == nil else { return }; task = Task { await loop() } }
    func stop() { task?.cancel(); task = nil }

    /// The next stretch to hear: the playhead's, then after it, then before it.
    nonisolated static func next(playhead: Double, count: Int, done: Set<Int>) -> Int? {
        let here = min(count - 1, max(0, Int(playhead / stretch)))
        return (here..<count).first { !done.contains($0) } ?? (0..<here).first { !done.contains($0) }
    }

    private func loop() async {
        #if compiler(>=6.2)
        if #available(macOS 26, iOS 26, *), let (m, l) = await SpeechEngine.module(lang), await SpeechEngine.prepare(m, l) {
            while !Task.isCancelled, let k = Self.next(playhead: playhead(), count: count, done: done) {
                let a = Double(k) * Self.stretch, b = min(duration, a + Self.stretch)
                do {
                    let heard = try await SpeechEngine.hear(url: url, from: a, to: b, lang, module: m, l)
                    phrases.removeAll { $0.start >= a && $0.start < b }
                    phrases = (phrases + heard).sorted { $0.start < $1.start }
                    done.insert(k)
                    changed(phrases)
                } catch { problem = error.localizedDescription; SpeechCore.note("stretch \(k) not heard: \(problem!)"); return }
            }
            return
        }
        #endif
        guard SpeechLegacy.hears(lang) else { problem = "This device can't hear \(lang) offline."; return }
        do { phrases = try await SpeechLegacy.hear(url: url, lang); done = Set(0..<count); changed(phrases) }
        catch { problem = error.localizedDescription }
    }
}
#endif
