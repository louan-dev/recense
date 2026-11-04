import Cocoa
import CoreAudio
import AudioToolbox
import AVFoundation
import os
import Network
import CryptoKit
import ServiceManagement
import NaturalLanguage
import SwiftUI
import WebKit
import Translation
import Accelerate
import SoundAnalysis
import Vision

// Recense v2
// Follows whatever QuickTime, Music, Safari/Chromium (Apple Events) or Firefox (bridge extension) is playing,
// transcribes the whole file ahead with word timestamps, translates with word alignment, and highlights each
// original word — and its English counterpart — against the player's own clock. Only exact sync, no guessing.

// ---------- logging ----------
let logURL = ProcessInfo.processInfo.environment["RECENSE_CACHE"].map { URL(fileURLWithPath: $0).appendingPathComponent("recense.log") }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/recense.log")
func log(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}

// ---------- config (~/.config/recense/config, KEY=VALUE; env vars override) ----------
enum Bookmarks {
    struct Mark: Codable { var t: Double; var note: String }   // note: the bookmark's name
    static let url = cacheDir.appendingPathComponent("bookmarks.json")
    static var all: [String: [Mark]] = (try? JSONDecoder().decode([String: [Mark]].self, from: Data(contentsOf: url))) ?? [:]
    static func save() { if let d = try? JSONEncoder().encode(all) { try? d.write(to: url, options: .atomic) } }
}

struct Config {
    // Optional: a translator of the owner's own (an OpenAI-compatible server: LM Studio, Ollama, llama.cpp on this Mac),
    // asked only for the language pairs Apple's Translation doesn't have. Off unless TRANSLATE_BASE is set; never Groq.
    var translateBase = "", translateKey = "", translateModel = ""
    var language = "", delay = 8.0, syncOffset = 0.0
    var geniusToken = ""                       // optional: finds a song's lyrics from the words sung when its title doesn't
    var r2Account = "", r2Key = "", r2Secret = "", r2Bucket = "recense-tmp"   // optional: offsite, self-deleting media cache
    static func load() -> Config {
        var kv: [String: String] = [:]
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/recense/config")
        for line in ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n") {
            let p = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if p.count == 2, !p[0].hasPrefix("#") { kv[p[0]] = p[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        }
        for (k, v) in ProcessInfo.processInfo.environment { kv[k] = v }
        var c = Config()
        c.translateBase = kv["TRANSLATE_BASE"] ?? ""
        if c.translateBase.contains("groq.com") { c.translateBase = "" }     // a rate-limited free tier stalls the job
        c.translateKey = kv["TRANSLATE_KEY"] ?? ""
        c.translateModel = kv["TRANSLATE_MODEL"] ?? ""
        c.language = kv["WHISPER_LANGUAGE"] ?? ""
        c.delay = Double(kv["SUBTITLE_DELAY"] ?? "") ?? c.delay
        c.syncOffset = Double(kv["SYNC_OFFSET"] ?? "") ?? 0
        c.geniusToken = kv["GENIUS_TOKEN"] ?? ""
        c.r2Account = kv["R2_ACCOUNT_ID"] ?? ""; c.r2Key = kv["R2_ACCESS_KEY_ID"] ?? ""; c.r2Secret = kv["R2_SECRET_ACCESS_KEY"] ?? ""
        c.r2Bucket = kv["R2_BUCKET"] ?? c.r2Bucket
        return c
    }
}
let cfg = Config.load()

func err(_ s: String) -> NSError { NSError(domain: "recense", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }

func wav(_ s: [Float], sr: Int) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    let bytes = UInt32(s.count * 2)
    d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVEfmt ".data(using: .ascii)!)
    u32(16); u16(1); u16(1); u32(UInt32(sr)); u32(UInt32(sr * 2)); u16(2); u16(16)
    d.append("data".data(using: .ascii)!); u32(bytes)
    for f in s { u16(UInt16(bitPattern: Int16(max(-1, min(1, f)) * 32767))) }
    return d
}

/// Sends a request to the owner's own translator (Config.translateBase) and reads its JSON reply.
func send(_ req: URLRequest) async throws -> [String: Any] {
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 200 { return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }
    var msg = String(data: data.prefix(300), encoding: .utf8) ?? "request failed"
    if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let e = j["error"] as? [String: Any], let m = e["message"] as? String { msg = m }
    throw err("HTTP \(code): \(msg)")
}

/// The secondary translator: a model of the owner's own (Config.translateBase), asked only for the lines Apple's
/// Translation can't take (a pair it doesn't have). No quota to wait out: unreachable, it rests a minute.
@MainActor enum Models {
    static var restUntil = Date.distantPast
    static func pick() -> String? { cfg.translateBase.isEmpty || restUntil > Date() ? nil : cfg.translateModel }
    static func rest() { restUntil = Date().addingTimeInterval(60); log("translator at \(cfg.translateBase) unreachable: resting a minute") }
}

/// Translates consecutive lines in one JSON request, into English or (`to`) another language: Vietnamese and French
/// are translated from the original, with the same prompt. Lines the model drops or garbles come back nil so the
/// caller can retry just those, instead of failing the whole batch.
func translateBatch(_ lines: [[String]], languages: [String?] = [], context: String, model: String, to target: String = "en") async throws -> [Int: [EnWord]] {
    let input = lines.enumerated().map { l in
        let lang = l.offset < languages.count ? languages[l.offset].map { " (\($0))" } ?? "" : ""
        return "L\(l.offset)\(lang): " + l.element.enumerated().map { "\($0.offset):\($0.element)" }.joined(separator: " ")
    }.joined(separator: "\n")
    let name = languageName(target), key = target == "en" ? "en" : "t"
    let system = """
    Translate each subtitle line into natural, complete \(name) and align it word by word.
    Input lines look like "L0: 0:mot 1:mot" (index:word). Reply with JSON only, one key per input line:
    {"L0":{"\(key)":"The \(name) words.","src":"0 1 2,3"},"L1":{...}}
    "\(key)" is the full \(name) translation. "src" has exactly one item per \(name) word (space-separated, \
    same order): the index of the source word it translates, several joined by commas, or - if none \
    ("0 1 2,3": spaces between \(name) words, commas only within one). \
    Translate every source word of the line — never shorten, summarise or skip. A line may start or end \
    mid-sentence; translate only what is in it. A line may switch language mid-line (song lyrics often mix \
    e.g. Spanish and English in one breath): keep the words already in \(name) exactly as they are, each \
    mapped to its own index, translate the rest, and keep the order in which they are sung. \
    "L0 (Persian):" names the language the line was heard in (from the sound, so a dialect is named by its nearest \
    language: Dari and Hazaragi as Persian): translate each part from the language it is in.
    """
    let user = (context.isEmpty ? "" : "Context (previous line, do not translate): \(context)\n") + input
    let total = lines.reduce(0) { $0 + $1.count }
    // ask for no more than the reply needs (Vietnamese takes more words, and more tokens a word, than English)
    let per = target == "vi" ? 9 : target == "en" ? 5 : 6
    let j = try await chatJSON(system, user, model: model, maxTokens: 60 + per * total + (model.contains("gpt-oss") ? 1000 : 0))
    var out: [Int: [EnWord]] = [:]
    for (k, src) in lines.enumerated() {
        guard let o = j["L\(k)"] as? [String: Any], let text = o[key] as? String else { continue }
        let en = text.split(separator: " ").map(String.init)
        let map = alignment(o["src"], words: en.count)
        let words = en.enumerated().compactMap { i, w -> EnWord? in
            let clean = w.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
                         .trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { return nil }
            return EnWord(w: clean, s: (i < map.count ? map[i] : []).filter { $0 >= 0 && $0 < src.count })
        }
        // A translation far shorter than its source means the model dropped content: retry it.
        if words.count * 2 + 1 < src.count { continue }
        out[k] = words
    }
    return out
}

/// The source indices of each English word, from the reply's "src" ("0 1 2,3", or an array). Models sometimes
/// comma-separate the words ("0,1,2,3"), which read as one word claiming the whole line; an alignment whose
/// length can't be matched to the English is no alignment at all.
func alignment(_ v: Any?, words n: Int) -> [[Int]] {
    let ints = { (x: Any) -> [Int] in
        if let i = x as? Int { return [i] }
        if let a = x as? [Any] { return a.compactMap { $0 as? Int } }
        return "\(x)".split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
    if let a = v as? [Any] { return a.count == n ? a.map(ints) : [] }
    let items = ((v as? String) ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    if items.count == 1, n > 1 {
        let parts = items[0].split(separator: ",")
        return parts.count == n ? parts.map { Int($0).map { [$0] } ?? [] } : []
    }
    return abs(items.count - n) <= 1 ? items.map(ints) : []
}

func chatJSON(_ system: String, _ user: String, model: String, maxTokens: Int) async throws -> [String: Any] {
    var payload: [String: Any] = [
        "model": model, "temperature": 0, "max_tokens": maxTokens,
        "response_format": ["type": "json_object"],
        "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
    ]
    // reasoning only slows a local model down: keep it off or minimal
    if model.contains("qwen") { payload["reasoning_effort"] = "none" }
    if model.contains("gpt-oss") { payload["reasoning_effort"] = "low" }
    var req = URLRequest(url: URL(string: cfg.translateBase + "/chat/completions")!)
    req.httpMethod = "POST"; req.timeoutInterval = 120
    req.httpBody = try JSONSerialization.data(withJSONObject: payload)
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !cfg.translateKey.isEmpty { req.setValue("Bearer \(cfg.translateKey)", forHTTPHeaderField: "Authorization") }
    let r = try await send(req)
    guard let content = ((r["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String,
          let j = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
    else { throw err("bad translation response") }
    return j
}

// ---------- on-device translation (Apple's Translation, macOS 15+): how every line is translated ----------
// On this Mac, free, no quota, offline: a whole podcast is translated as fast as it's transcribed (Groq's free daily
// quotas used to run out a few hours in and hold the job for hours; since 2026-10-30 no translation goes to Groq).
// Without word alignment (a line in the same language is its own alignment). A pair Apple doesn't have goes to the
// owner's own translator (Models) if one is set, else the line keeps its original only ("…").
// A session only exists inside a SwiftUI view's translationTask, so 1-point views host them and the work runs there.
// One session per language pair, each in a view of its own, kept while it has work and closed a minute after its last
// job. One session used to be switched from pair to pair (fr>en, en>vi, ja>en… as the lines changed language), and it
// sat in the subtitle window, which is hidden, shown and moved into Recense's page: each switch and each move had
// Translation host a new remote view, their Mach ports were never all given back, and Recense grew slower until macOS
// killed it (EXC_RESOURCE, 305,834 ports, after ~20 hours). The views now live in a window of their own that is never
// hidden or moved. Only languages already downloaded are used: that window can't show the download sheet, and a
// session waiting on it would hold its pair forever.
@available(macOS 15.0, *)
@MainActor final class OnDevice: ObservableObject {
    static let shared = OnDevice()
    @Published var pairs: [String] = []   // the sessions open: "<from>>" + "<to>" ("fr>en")
    struct Job { let id: Int; let texts: [String]; let lang: String; let done: CheckedContinuation<[String]?, Never> }
    var jobs: [Job] = [], nextJob = 0
    var failed: Set<String> = []          // pairs it can't do: unsupported, not downloaded, or Translation gave up
    var missing: Set<String> = []         // of those, the ones a download in System Settings would give it
    var used: [String: Date] = [:]        // a pair's last job
    private var window: NSPanel?

    static func languages(_ pair: String) -> (Locale.Language, Locale.Language) {
        let p = pair.split(separator: ">").map(String.init)
        return (.init(identifier: p[0]), .init(identifier: p.count > 1 ? p[1] : "en"))
    }

    func translate(_ texts: [String], from src: String, to target: String = "en") async -> [String]? {
        let lang = src + ">" + target
        guard !failed.contains(lang) else { return nil }
        if !pairs.contains(lang) {
            let status = await LanguageAvailability().status(from: .init(identifier: src), to: .init(identifier: target))
            guard status == .installed else {
                failed.insert(lang)
                if status == .supported { missing.insert(lang) }
                log("on-device translation: \(src) to \(target) \(status == .unsupported ? "isn't supported" : "isn't downloaded (System Settings › General › Language & Region › Translation Languages)")")
                return nil
            }
        }
        nextJob += 1
        let id = nextJob
        // A job nothing has picked up in 60 s gives up.
        Task { try? await Task.sleep(for: .seconds(60)); self.finish(id, nil) }
        return await withCheckedContinuation { c in
            jobs.append(Job(id: id, texts: texts, lang: lang, done: c))
            used[lang] = Date()
            if !pairs.contains(lang) { pairs.append(lang) }
            openWindow()
        }
    }

    func finish(_ id: Int, _ out: [String]?) {
        guard let k = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs.remove(at: k).done.resume(returning: out)
    }

    /// One pair's translation task: its jobs, until a minute passes without one (then its view goes, and the session).
    func serve(_ session: TranslationSession, pair: String) async {
        while !Task.isCancelled {
            guard let job = jobs.first(where: { $0.lang == pair }) else {
                if Date().timeIntervalSince(used[pair] ?? .distantPast) > 60 { pairs.removeAll { $0 == pair }; return }
                try? await Task.sleep(for: .milliseconds(150)); continue
            }
            used[pair] = Date()
            do {
                let rs = try await session.translations(from: job.texts.enumerated().map { .init(sourceText: $0.element, clientIdentifier: String($0.offset)) })
                var out = job.texts.map { _ in "" }
                for r in rs { if let i = Int(r.clientIdentifier ?? ""), i < out.count { out[i] = r.targetText } }
                finish(job.id, out)
            } catch {
                if Task.isCancelled { return }
                log("on-device translation (\(pair)): \(error.localizedDescription)")
                failed.insert(pair)
                for j in jobs where j.lang == pair { finish(j.id, nil) }
                pairs.removeAll { $0 == pair }; return
            }
        }
    }

    /// The sessions' window: 1 point, see-through and click-through, on every Space; ordered in once, never hidden.
    private func openWindow() {
        guard window == nil, let sc = NSScreen.screens.first else { return }
        let w = NSPanel(contentRect: NSRect(x: sc.frame.minX, y: sc.frame.minY, width: 1, height: 1),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.ignoresMouseEvents = true
        w.level = .statusBar; w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: OnDeviceHost())
        w.orderFrontRegardless()
        window = w
    }
}

@available(macOS 15.0, *)
struct OnDeviceHost: View {
    @ObservedObject var m = OnDevice.shared
    var body: some View {
        ZStack { ForEach(m.pairs, id: \.self) { PairSession(pair: $0) } }.frame(width: 1, height: 1)
    }
}

@available(macOS 15.0, *)
struct PairSession: View {
    let pair: String
    var body: some View {
        let (from, to) = OnDevice.languages(pair)
        Color.clear.frame(width: 1, height: 1)
            .translationTask(source: from, target: to) { session in await OnDevice.shared.serve(session, pair: pair) }
    }
}

/// Lines translated on this Mac into English (or `to`: Vietnamese, French), as words without alignment. A line already
/// in that language (or in none: numbers, a cry) is itself, word for word. Missing: the lines it can't do (older macOS,
/// a pair Apple's Translation doesn't have or hasn't downloaded).
/// Each line from its own language (`languages`, by sound and spelling; else the spelling's guess).
@MainActor func translateOnDevice(_ lines: [[String]], languages: [String?] = [], to target: String = "en") async -> [Int: [EnWord]] {
    let texts = lines.map { $0.joined(separator: " ") }
    var groups: [String: [Int]] = [:]
    var r: [Int: [EnWord]] = [:]
    for (k, t) in texts.enumerated() {
        if let l = (k < languages.count ? languages[k] : nil) ?? dominantLanguage(t)?.code, l != target { groups[l, default: []].append(k) }
        else { r[k] = lines[k].enumerated().map { EnWord(w: $0.element, s: [$0.offset]) } }
    }
    guard #available(macOS 15.0, *) else { return r }
    for (lang, ks) in groups {
        guard let out = await OnDevice.shared.translate(ks.map { texts[$0] }, from: lang, to: target) else { continue }
        for (k, t) in zip(ks, out) where !t.isEmpty { r[k] = t.split(separator: " ").map { EnWord(w: String($0), s: []) } }
    }
    return r
}

// ---------- subtitle model ----------
struct Word: Codable {
    var text: String; let start: Double; let end: Double
    var lang: String? = nil   // the language Whisper heard it in (ISO 639-1), when the word is written in that language's script
    var c: Double? = nil      // how sure the recognizer was of it (0–1; on-device ears)
    var heard: String? = nil  // what the recognizer wrote, where a correction it was taught wrote this instead (Lexicon)
    var syl: [Syl]? = nil     // a sung word's syllables on the voice's own (Cadence.align, cadence.swift)
    var un: Bool? = nil       // written but not sung: Cadence found no voice for it, so it's never lit
    var tm: Pin? = nil        // timed by the listener's ear (corrections field "time"): wins over Cadence (Cadence.pin)
    /// The same word, timed again (what it was heard as goes with it; its syllables don't: they were the old times').
    func timed(_ s: Double, _ e: Double) -> Word { Word(text: text, start: s, end: e, lang: lang, c: c, heard: heard, tm: tm) }
}
/// A word as the listener timed it (notes 20261029 row 35; Gallery's corrections.js `pinsOf`): lit from s to e, its light
/// shaped by k (−1 lingers at the start and hurries at the end, 1 the reverse, 0 even).
struct Pin: Codable, Equatable {
    let s: Double; let e: Double; let k: Double
    /// The light traced by a finger as the word was sung (rows 40, 44): how much is lit at evenly spaced moments from
    /// s to e (0 … 1, never going back); it outranks k (Gallery's corrections.js `traceOf`).
    var c: [Double]? = nil
    static func trace(_ v: Any?) -> [Double]? {
        guard let a = v as? [Any], (2...32).contains(a.count) else { return nil }
        var m = 0.0, out: [Double] = []
        for x in a {
            guard let d = (x as? NSNumber)?.doubleValue, d.isFinite else { return nil }
            m = max(m, min(1, max(0, d))); out.append((m * 100).rounded() / 100)
        }
        return out
    }
}
/// A syllable of a sung word: where it ends in the word's letters (code points), and when its note is sung.
struct Syl: Codable { let c: Int; let s: Double; let e: Double }
struct EnWord: Codable { let w: String; let s: [Int] }
struct Line: Codable {
    let id: Int
    let words: [Word]
    var english: [EnWord]?   // nil while translating; [] when the speech is already English
    var draft: Bool? = nil   // older transcripts: translated on this Mac while Groq's quota was out (kept as it is now)
    var fixed: Bool? = nil   // a listener corrected its text (Gallery's `fixed`): Cadence lights its words even where it finds no voice for them
    var start: Double { words.first?.start ?? 0 }
    var end: Double { words.last?.end ?? 0 }
}

func isEnglish(_ l: String) -> Bool { ["english", "en"].contains(l.lowercased()) }

// ---------- corrections ----------
// What the listener fixed in the window, kept apart from the transcript (<key>.edits.json, mirrored to
// keep/<key>/corrections.json; Keep):
// the pipeline may remake every line — a redo, the lyrics chosen again, a newer song pipeline — and an edit still shows
// over whatever it made. An edit owns a stretch of time (the line as shown when it was corrected): the automatic words
// in it are hidden and the listener's shown instead, timed over the words they replaced. No words hides the stretch
// (something Whisper invented).
struct Edit: Codable {
    var id: Int
    var a: Double, b: Double          // the stretch it owns, in transcript time
    var from: String                  // the words as the pipeline had them
    var words: [Word]                 // the listener's
    var lang: String?                 // the language they're in: the glossary they taught
    var terms: [String] = []          // what they taught it
    var at: Double? = nil             // when (ms): an override older than this never takes the line over (Corrections)
    var taught: [String: String]? = nil   // what it taught this recording's glossary (wrong → right), forgotten on reset
}
struct Edits: Codable {
    var edits: [Edit] = []
    var english: [String: [EnWord]] = [:]   // translations of the shown lines the transcript itself doesn't have, by their words
    var last: Int?                          // the last edit id given: a corrected line never shows under an id it had before
    // Shared with Gallery (Corrections): its viewers' fixes, by segment, and this recording's glossary.
    var version: Int? = nil
    var updatedAt: Double? = nil            // ms
    var overrides: [Override]? = nil
    var glossary: [String: String]? = nil   // wrong (lower case) → right; "" = forgotten
}

/// Shown lines an edit made: its id + edited. An automatic line an edit cut short: its own id + edited + cutShort.
let edited = 4_000_000, cutShort = 1_000_000

/// The native language (Gallery spec §1): the language of the trailing line under the original, English until it is
/// set. A line shows a correction in it (tr.<lang>), else its translation into it (Episode.native, tr/<lang>.json),
/// else its English. Kept until changed.
enum NativeLang {   // read and set on the main thread (the window, and the lines it shows)
    static let all: [(code: String, name: String)] = [("en", "English"), ("vi", "Vietnamese"), ("fr", "French")]
    nonisolated(unsafe) private(set) static var current: String = {
        let v = UserDefaults.standard.string(forKey: "nativeLang") ?? "en"
        return all.contains { $0.code == v } ? v : "en"
    }()
    static func set(_ v: String) {
        guard all.contains(where: { $0.code == v }) else { return }
        current = v
        UserDefaults.standard.set(v, forKey: "nativeLang")
    }
}

/// The reader's two settings, from the menu bar menu (read and set on the main thread). Text Size scales both lines.
/// Balance is a crossfader between the original (L1) and the trailing language (L2): at the centre they are the same
/// size; toward one side that side grows (1.15× → 1.3×) while the other shrinks (0.8× → 0.6×) and dims (0.7 → 0.4),
/// and the end detent hides the other line altogether.
enum Reader {
    static let sizes: ClosedRange<Double> = 0.7...1.6
    nonisolated(unsafe) private(set) static var scale: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "textScale") as? Double ?? 1
        return CGFloat(min(max(v, sizes.lowerBound), sizes.upperBound))
    }()
    nonisolated(unsafe) private(set) static var balance: Double = min(max(UserDefaults.standard.double(forKey: "balance"), -1), 1)  // −1 L1 … +1 L2
    nonisolated(unsafe) private(set) static var stamp = 0     // changes with either, so the window draws again
    static func set(scale v: Double) {
        scale = CGFloat(min(max((v * 20).rounded() / 20, sizes.lowerBound), sizes.upperBound))
        UserDefaults.standard.set(Double(scale), forKey: "textScale"); stamp += 1
    }
    /// Snaps to the centre and to the two end detents.
    static func set(balance v: Double) {
        let b = min(max(v, -1), 1)
        balance = abs(b) < 0.06 ? 0 : abs(b) > 0.94 ? (b < 0 ? -1 : 1) : b
        UserDefaults.standard.set(balance, forKey: "balance"); stamp += 1
    }
    struct Mix { var l1: CGFloat = 1, l2: CGFloat = 1, a1: CGFloat = 1, a2: CGFloat = 1 }
    /// The vertical bar (homebar.js): the original language's prominence, 0…1, and the two opacities the page worked
    /// out for it (a1 the original, a2 the trailing language); nil at rest, where Balance decides. Both 0: blank.
    /// Never kept across launches or tracks: Learn is the default view (a stray swipe left 0.43 stored, and the
    /// translation sat lit under the notation from then on).
    nonisolated(unsafe) private(set) static var prominence: (p: Double, a1: CGFloat, a2: CGFloat)? = {
        UserDefaults.standard.removeObject(forKey: "prominence")
        return nil
    }()
    static func set(prominence p: Double?, a1: Double?, a2: Double?) {
        if let p, let a1, let a2 {
            prominence = (p, CGFloat(min(max(a1, 0), 1)), CGFloat(min(max(a2, 0), 1)))
        } else {
            prominence = nil
        }
        stamp += 1
    }
    /// 100% on the vertical bar: a blank canvas, for listening blind.
    static var blank: Bool { prominence.map { $0.a1 == 0 && $0.a2 == 0 } ?? false }
    /// How far toward one side (0…1) → the near side's size, the far side's size and the far side's opacity.
    static func side(_ m: Double) -> (near: CGFloat, far: CGFloat, alpha: CGFloat) {
        if m >= 1 { return (1.3, 0.6, 0) }
        if m <= 0.5 { let k = CGFloat(m / 0.5); return (1 + 0.15 * k, 1 - 0.2 * k, 1 - 0.3 * k) }
        let k = CGFloat((m - 0.5) / 0.44); return (1.15 + 0.15 * min(1, k), 0.8 - 0.2 * min(1, k), 0.7 - 0.3 * min(1, k))
    }
    static var mix: Mix {
        if let p = prominence { return Mix(l1: 1, l2: 1, a1: p.a1, a2: p.a2) }
        let s = side(abs(balance))
        return balance <= 0 ? Mix(l1: s.near, l2: s.far, a1: 1, a2: s.alpha) : Mix(l1: s.far, l2: s.near, a1: s.alpha, a2: 1)
    }
}

/// A slider row for a menu (Text Size, Balance): a caption, the end marks and the slider between them.
final class ReaderRow: NSView {
    let slider: NSSlider
    var onChange: ((Double) -> Void)?
    init(caption: String, left: NSView, right: NSView, value: Double, min lo: Double, max hi: Double, ticks: Int) {
        slider = NSSlider(value: value, minValue: lo, maxValue: hi, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        let cap = NSTextField(labelWithString: caption)
        cap.font = .menuFont(ofSize: 0); cap.textColor = .labelColor
        slider.controlSize = .small; slider.isContinuous = true
        slider.numberOfTickMarks = ticks; slider.allowsTickMarkValuesOnly = false
        slider.target = self; slider.action = #selector(moved)
        for v in [cap, left, slider, right] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            cap.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            cap.widthAnchor.constraint(equalToConstant: 62),
            cap.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.leadingAnchor.constraint(equalTo: cap.trailingAnchor, constant: 2),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 4),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 4),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func moved() { onChange?(slider.doubleValue) }
    static func mark(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: size, weight: weight); l.textColor = .secondaryLabelColor
        return l
    }
    static func step(_ s: String, size: CGFloat, _ go: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: s, go: go)
        b.isBordered = false; b.font = .systemFont(ofSize: size, weight: .medium); b.contentTintColor = .secondaryLabelColor
        return b
    }
}
final class ClosureButton: NSButton {
    var go: () -> Void
    init(title: String, go: @escaping () -> Void) {
        self.go = go
        super.init(frame: .zero)
        self.title = title; target = self; action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func fire() { go() }
}

/// The transcript as shown: the automatic lines with every edit laid over them; its trailing line in English, or in
/// `lang` where a correction or a translation (`native`: the line before Gallery's corrections, then after) has one.
@MainActor func applyEdits(_ lines: [Line], _ e: Edits, lang: String = "en", native: ((Line, Line) -> [EnWord]?)? = nil) -> [Line] {
    Corrections.apply(applyOwnEdits(lines, e), e, lang: lang, native: native)
}

/// Recense's own edits (time stretches) laid over the automatic lines.
@MainActor func applyOwnEdits(_ lines: [Line], _ e: Edits) -> [Line] {
    guard !e.edits.isEmpty else { return lines }
    func owned(_ w: Word) -> Bool { let m = (w.start + w.end) / 2; return e.edits.contains { m >= $0.a && m <= $0.b } }
    var out: [Line] = []
    for l in lines {
        let kept = l.words.filter { !owned($0) }
        if kept.count == l.words.count { out.append(l); continue }
        guard !kept.isEmpty else { continue }
        let text = kept.map(\.text).joined(separator: " ")
        out.append(Line(id: l.id + edited + cutShort, words: kept, english: l.english?.isEmpty == true ? [] : e.english[text] ?? Library.recall(text)))
    }
    for x in e.edits where !x.words.isEmpty {
        let text = x.words.map(\.text).joined(separator: " ")
        out.append(Line(id: edited + x.id, words: x.words, english: e.english[text] ?? Library.recall(text)))
    }
    return out.sorted { $0.start < $1.start }
}

// ---------- glossary ----------
// The words listeners had to correct, per language, given to Whisper as its prompt (the spellings it's to expect): a
// name or a rare word fixed once comes out right in everything transcribed after. Only words a correction brought in
// that weren't in what Whisper wrote, and no little ones. glossary.json, mirrored to keep/ with the library.
@MainActor enum Glossary {
    struct Term: Codable { var n: Int; var last: Date }
    static let url = cacheDir.appendingPathComponent("glossary.json")
    static var terms = (try? JSONDecoder().decode([String: [String: Term]].self, from: Data(contentsOf: url))) ?? [:]

    nonisolated static func fold(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// What a correction teaches: its words that aren't in the line it corrected (by their letters), of four letters
    /// or more, or with a digit, or capitalised past the first word.
    nonisolated static func learned(from: String, to words: [String]) -> [String] {
        let had = Set(from.split(separator: " ").map { fold(String($0)) })
        var out: [String] = []
        for (i, w) in words.enumerated() {
            let t = w.trimmingCharacters(in: .punctuationCharacters.union(.symbols)), f = fold(t)
            guard !f.isEmpty, !had.contains(f), !out.contains(t) else { continue }
            if f.count >= 4 || t.contains(where: \.isNumber) || (i > 0 && t.first?.isUppercase == true) { out.append(t) }
        }
        return out
    }

    static func add(_ ts: [String], lang: String) {
        for t in ts { var x = terms[lang]?[t] ?? Term(n: 0, last: Date()); x.n += 1; x.last = Date(); terms[lang, default: [:]][t] = x }
        if !ts.isEmpty { save() }
    }
    static func remove(_ ts: [String], lang: String) {
        for t in ts { guard var x = terms[lang]?[t] else { continue }; x.n -= 1; terms[lang]?[t] = x.n > 0 ? x : nil }
        if terms[lang]?.isEmpty == true { terms[lang] = nil }
        if !ts.isEmpty { save() }
    }

    /// Whisper's prompt for a request in this language. It reads only the end of a long prompt (224 tokens), so the
    /// terms most corrected (then most recently) go last; a script that isn't Latin costs more tokens a letter.
    static func prompt(_ lang: String?) -> String? {
        guard let lang, let ts = terms[lang], !ts.isEmpty else { return nil }
        let cap = scriptOf(language: lang) == "Latn" ? 600 : 200
        var out: [String] = [], len = 0
        for t in ts.sorted(by: { ($0.value.n, $0.value.last) > ($1.value.n, $1.value.last) }).map(\.key) where len + t.count + 2 <= cap {
            out.append(t); len += t.count + 2
        }
        return out.reversed().joined(separator: ", ")
    }

    static func save() { if let d = try? JSONEncoder().encode(terms) { try? d.write(to: url, options: .atomic) } }

    /// keep/'s copy merged in: every term, at the higher count.
    static func merge(_ d: Data) -> Bool {
        guard let r = try? JSONDecoder().decode([String: [String: Term]].self, from: d) else { return false }
        var changed = false
        for (lang, ts) in r { for (t, x) in ts where (terms[lang]?[t]?.n ?? 0) < x.n { terms[lang, default: [:]][t] = x; changed = true } }
        if changed { save() }
        return changed
    }
}

// ---------- corrections shared with Gallery ----------
// Gallery (the Worker over gallery-main) lets anyone viewing a file fix its transcript, in this same file
// (keep/<key>.edits.json): overrides by segment ({segId, start, end, field: text | tr.<lang>, to, src, updatedAt}) and
// a glossary for this recording (wrong → right, whole words, in the case of the word replaced). The rules are
// Gallery's (src/corrections.js), so both show the same words: Recense's own edits first, then each override on its
// segment (the line with that id, else the line covering ≥ 50 % of its span, never one corrected here after it),
// the latest winning; then the glossary on every line no one corrected. A correction is never undone by the ASR.
struct Override: Codable, Equatable {
    var segId: String; var start: Double; var end: Double
    var field: String; var to: String; var src: String; var updatedAt: Double
}

@MainActor enum Corrections {
    nonisolated static let edge = CharacterSet.letters.union(.decimalDigits).inverted
    /// A word as the glossary knows it: its letters and digits, without what's around them, in lower case.
    nonisolated static func fold(_ w: String) -> String { w.precomposedStringWithCanonicalMapping.trimmingCharacters(in: edge).lowercased() }
    nonisolated static func parts(_ w: String) -> (String, String, String) {
        let s = w.precomposedStringWithCanonicalMapping
        guard let a = s.firstIndex(where: { !$0.unicodeScalars.allSatisfy(edge.contains) }),
              let b = s.lastIndex(where: { !$0.unicodeScalars.allSatisfy(edge.contains) }) else { return (s, "", "") }
        return (String(s[..<a]), String(s[a...b]), String(s[s.index(after: b)...]))
    }
    nonisolated static func caseLike(_ orig: String, _ right: String) -> String {
        if orig.count > 1 && orig == orig.uppercased() && orig != orig.lowercased() { return right.uppercased() }
        if let f = orig.first, String(f) == String(f).uppercased(), String(f) != String(f).lowercased() { return right.prefix(1).uppercased() + right.dropFirst() }
        return right
    }
    nonisolated static func gloss(_ w: String, _ g: [String: String]) -> String {
        let (pre, core, post) = parts(w)
        guard let right = g[core.lowercased()], !right.isEmpty else { return w }
        return pre + caseLike(core, right) + post
    }
    /// (a run typed the way Chinese, Thai or Tibetan are written, without spaces, cut into words: cutUnspaced)
    nonisolated static func words(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).flatMap { cutUnspaced(String($0)) } }

    /// What an edit teaches: each word replaced by one other (a run changed word for word), wrong → right as typed.
    nonisolated static func learned(from: String, to: String) -> [(String, String)] {
        let a = words(from), b = words(to), fa = a.map(fold), fb = b.map(fold), m = a.count, n = b.count
        var L = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) { L[i][j] = fa[i] == fb[j] ? L[i + 1][j + 1] + 1 : max(L[i + 1][j], L[i][j + 1]) }
        }
        var out: [(String, String)] = [], i = 0, j = 0, del: [String] = [], ins: [String] = []
        func hunk() {
            if del.count == ins.count {
                for (d, x) in zip(del, ins) {
                    let wrong = fold(d), right = parts(x).1
                    if !wrong.isEmpty && !right.isEmpty && wrong != fold(right) { out.append((wrong, right)) }
                }
            }
            del = []; ins = []
        }
        while i < m || j < n {
            if i < m && j < n && fa[i] == fb[j] { hunk(); i += 1; j += 1 }
            else if j < n && (i == m || L[i][j + 1] >= L[i + 1][j]) { ins.append(b[j]); j += 1 }
            else { del.append(a[i]); i += 1 }
        }
        hunk()
        return out
    }

    /// Taught into a glossary; taught back the other way, the earlier lesson is forgotten. What it taught is returned.
    @discardableResult
    nonisolated static func teach(_ g: inout [String: String], from: String, to: String) -> [String: String] {
        var taught: [String: String] = [:]
        for (wrong, right) in learned(from: from, to: to) {
            let back = fold(right)
            if let had = g[back], !had.isEmpty, fold(had) == wrong { g[back] = "" } else { g[wrong] = right; taught[wrong] = right }
        }
        return taught
    }

    /// The line an override is for (index), or nil.
    static func target(_ lines: [Line], _ o: Override, _ byId: [String: Int], _ e: Edits) -> Int? {
        if let i = byId[o.segId] { return i }
        let a = o.start, b = o.end
        var best: Int?, most = 0.0
        for (k, l) in lines.enumerated() where !l.words.isEmpty {
            if l.id >= edited && l.id < edited + cutShort, (e.edits.first { $0.id == l.id - edited }?.at ?? 0) > o.updatedAt { continue }
            let s = l.start, en = l.end
            let ov = b > a ? min(en, b) - max(s, a) : ((a + b) / 2 >= s && (a + b) / 2 <= en ? 1 : 0)
            let share = b > a ? ov / (b - a) : ov
            if share >= 0.5 && ov > most { most = ov; best = k }
        }
        return best
    }

    /// A "time" override's words: JSON [[word index, start, end, sweep, trace?], …] (Gallery's corrections.js `pinsOf`,
    /// same checks).
    nonisolated static func pins(_ to: String) -> [Int: Pin] {
        guard let a = try? JSONSerialization.jsonObject(with: Data(to.utf8)) as? [[Any]] else { return [:] }
        var out: [Int: Pin] = [:]
        for y in a.prefix(200) where y.count >= 3 {
            let x = y.prefix(4).map { ($0 as? NSNumber)?.doubleValue ?? .nan }
            let i = Int(exactly: x[0]) ?? -1, s = x[1], e = x[2], k = x.count > 3 && x[3].isFinite ? x[3] : 0
            guard i >= 0, s >= 0, e > s, e - s <= 30 else { continue }
            out[i] = Pin(s: s, e: e, k: max(-1, min(1, k)), c: Pin.trace(y.count > 4 ? y[4] : nil))
        }
        return out
    }

    /// Overrides, then the glossary, over the lines (Recense's own edits already laid over them). The trailing line
    /// is English, or in `lang`: a correction in it first, else `native`'s translation, else the English.
    static func apply(_ lines: [Line], _ e: Edits, lang: String = "en", native: ((Line, Line) -> [EnWord]?)? = nil) -> [Line] {
        let g = (e.glossary ?? [:]).filter { !$0.value.isEmpty }
        let ovs = (e.overrides ?? []).enumerated().sorted { ($0.element.updatedAt, $0.offset) < ($1.element.updatedAt, $1.offset) }.map(\.element)
        guard !ovs.isEmpty || !g.isEmpty || (lang != "en" && native != nil) else { return lines }
        var byId: [String: Int] = [:]
        for (i, l) in lines.enumerated() where byId[String(l.id)] == nil { byId[String(l.id)] = i }
        var text: [Int: String] = [:], tr: [Int: [String: String]] = [:], time: [Int: [Int: Pin]] = [:]
        for o in ovs {
            guard let i = target(lines, o, byId, e) else { continue }
            if o.field == "text" { text[i] = o.to } else if o.field == "time" { time[i] = pins(o.to) }
            else if o.field.hasPrefix("tr.") { tr[i, default: [:]][String(o.field.dropFirst(3))] = o.to }
        }
        var out: [Line] = []
        for (i, l) in lines.enumerated() {
            var n = l
            if let t = text[i] {
                let ws = words(t)
                if ws.isEmpty { continue }           // corrected to nothing: words the ASR made up
                let english = ws.count == l.words.count ? l.english : l.english.map { $0.map { EnWord(w: $0.w, s: []) } }
                n = Line(id: l.id, words: Episode.correct(ws, over: l.words), english: english, draft: l.draft, fixed: true)
            } else if !g.isEmpty && !(l.id >= edited && l.id < edited + cutShort) {
                n = Line(id: l.id, words: l.words.map { var w = $0; w.text = gloss($0.text, g); return w },
                         english: l.english, draft: l.draft)
            }
            if let p = time[i], !p.isEmpty {
                n = Line(id: n.id, words: n.words.enumerated().map { k, w in var x = w; x.tm = p[k]; return x },
                         english: n.english, draft: n.draft, fixed: n.fixed)
            }
            if lang != "en", let nl = tr[i]?[lang], !words(nl).isEmpty {
                n.english = words(nl).map { EnWord(w: $0, s: []) }
            } else if lang != "en", let t = native?(l, n) {
                n.english = t
            } else if let en = tr[i]?["en"] { n.english = words(en).map { EnWord(w: $0, s: []) } }
            out.append(n)
        }
        return out
    }

    /// Where the listener cleared a line (corrected to nothing, or an edit of theirs left with no words): their word that
    /// nobody speaks or sings there, so the window shows [Ambient Sounds] over it, whatever the sound classifier hears.
    static func blanked(_ lines: [Line], _ e: Edits) -> [ClosedRange<Double>] {
        var out = e.edits.filter { $0.words.isEmpty && $0.b > $0.a }.map { $0.a...$0.b }
        let ovs = (e.overrides ?? []).enumerated().sorted { ($0.element.updatedAt, $0.offset) < ($1.element.updatedAt, $1.offset) }.map(\.element)
        var byId: [String: Int] = [:]
        for (i, l) in lines.enumerated() where byId[String(l.id)] == nil { byId[String(l.id)] = i }
        var text: [Int: String] = [:]
        for o in ovs where o.field == "text" { if let i = target(lines, o, byId, e) { text[i] = o.to } }
        for (i, t) in text where words(t).isEmpty && !lines[i].words.isEmpty { out.append(lines[i].start...max(lines[i].start, lines[i].end)) }
        return out
    }

    /// keep/'s copy and this Mac's: overrides per segment and field (the latest wins, a tie goes to keep/'s), the
    /// glossary by word (the newer file's on a clash, forgotten words included), the higher version. Recense's own
    /// fields stay this Mac's.
    nonisolated static func merged(_ local: Edits, _ remote: Edits) -> Edits {
        var m = local
        var by: [String: Override] = [:], order: [String] = []
        for o in (local.overrides ?? []) + (remote.overrides ?? []) {
            let k = o.segId + "|" + o.field
            if let had = by[k] { if o.updatedAt >= had.updatedAt { by[k] = o } } else { by[k] = o; order.append(k) }
        }
        m.overrides = order.compactMap { by[$0] }
        let newer = (remote.updatedAt ?? 0) > (local.updatedAt ?? 0)
        var g = local.glossary ?? [:]
        for (k, v) in remote.glossary ?? [:] where g[k] == nil || newer { g[k] = v }
        m.glossary = g
        m.version = max(local.version ?? 0, remote.version ?? 0)
        m.updatedAt = max(local.updatedAt ?? 0, remote.updatedAt ?? 0)
        return m
    }
    nonisolated static func sameShared(_ a: Edits, _ b: Edits) -> Bool {
        (a.overrides ?? []) == (b.overrides ?? []) && (a.glossary ?? [:]) == (b.glossary ?? [:]) && (a.version ?? 0) == (b.version ?? 0)
    }

    /// This recording's corrected words, for Whisper's prompt.
    static func promptTerms(_ e: Edits) -> String? {
        var out: [String] = [], len = 0
        for t in Set((e.glossary ?? [:]).values.filter { !$0.isEmpty }).sorted() where len + t.count + 2 <= 300 { out.append(t); len += t.count + 2 }
        return out.isEmpty ? nil : out.joined(separator: ", ")
    }
}

// keep/<key>/corrections.json is written by Gallery too (conditionally, on its etag), so this Mac never sends its copy
// over it blind: keep/'s is merged in first and the merge sent back on the same etag (once more on a clash). An item
// with only the old keep/<key>.edits.json has it copied to corrections.json first (Keep).
@MainActor enum CorrectionSync {
    static var pending: [String: Task<Void, Never>] = [:]
    static let live = NSHashTable<Episode>.weakObjects()   // open pieces: told when keep/'s fixes arrive

    static func url(_ key: String) -> URL { cacheDir.appendingPathComponent(key + ".edits.json") }

    /// keep/'s copy and its etag (an old <key>.edits.json copied to <key>/corrections.json first).
    static func fetch(_ key: String) async -> (Edits?, String?) {
        if let (d, etag) = await Keep.get(Keep.corrections(key)) { return (try? JSONDecoder().decode(Edits.self, from: d), etag) }
        guard let (d, _) = await Keep.get(key + ".edits.json") else { return (nil, nil) }
        if let etag = await Keep.put(Keep.corrections(key), d, ifAbsent: true) {
            log("corrections: \(key) moved to the per-item layout")
            return (try? JSONDecoder().decode(Edits.self, from: d), etag.isEmpty ? nil : etag)
        }
        guard let (n, etag) = await Keep.get(Keep.corrections(key)) else { return (nil, nil) }   // moved over meanwhile
        return (try? JSONDecoder().decode(Edits.self, from: n), etag)
    }

    /// Sent a second after the last change.
    static func schedule(_ key: String) {
        guard Store.r2 else { return }
        pending[key]?.cancel()
        pending[key] = Task { try? await Task.sleep(for: .seconds(1)); guard !Task.isCancelled else { return }; await push(key) }
    }

    static func push(_ key: String, again: Bool = false) async {
        guard Store.r2, let d = try? Data(contentsOf: url(key)), var local = try? JSONDecoder().decode(Edits.self, from: d) else { return }
        let (remote, etag) = await fetch(key)
        if let remote { local = Corrections.merged(local, remote) }
        local.version = (remote?.version ?? local.version ?? 0) + 1
        guard let out = try? JSONEncoder().encode(local) else { return }
        var r = Store.request("PUT", Keep.corrections(key), dir: "keep")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let etag { r.setValue(etag, forHTTPHeaderField: "If-Match") } else if remote == nil { r.setValue("*", forHTTPHeaderField: "If-None-Match") }
        guard let (_, resp) = try? await URLSession.shared.upload(for: r, from: out), let h = resp as? HTTPURLResponse else { return }
        if h.statusCode == 412 { if !again { await push(key, again: true) }; return }
        guard h.statusCode == 200 else { log("corrections: keep/ refused \(Keep.corrections(key)) (\(h.statusCode))"); return }
        try? out.write(to: url(key), options: .atomic)
        if let m = (try? url(key).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 {
            Store.mirrored[key + ".edits.json"] = m
        }
        tell(key, local)
    }

    /// keep/'s fixes into an open piece (Gallery's viewers may have corrected it since this Mac last looked).
    static func pull(_ ep: Episode) async {
        guard !ep.dry else { return }
        let (remote, _) = await fetch(ep.key)
        guard let remote else { return }
        let m = Corrections.merged(ep.edits, remote)
        guard !Corrections.sameShared(m, ep.edits) else { return }
        let had = Set((ep.edits.overrides ?? []).map { "\($0.segId)|\($0.field)|\($0.updatedAt)" })
        ep.teach(overrides: (m.overrides ?? []).filter { !had.contains("\($0.segId)|\($0.field)|\($0.updatedAt)") }, before: ep.edits)
        ep.edits = m
        ep.saveEdits(push: false)
        log("corrections: \((remote.overrides ?? []).count) fix(es) from Gallery laid over \(ep.key)")
    }

    static func tell(_ key: String, _ e: Edits) {
        for ep in live.allObjects where ep.key == key && !ep.dry && !Corrections.sameShared(ep.edits, e) {
            var x = ep.edits; x.overrides = e.overrides; x.glossary = e.glossary; x.version = e.version; x.updatedAt = e.updatedAt
            ep.edits = x
        }
    }
}

// ---------- languages by sound and by spelling ----------
// Whisper names a language by its sound, one per request; NaturalLanguage by the spelling, per phrase. Each is blind
// where the other sees: Whisper can't follow a switch inside a request (it translates the rest into the first
// language), and NaturalLanguage can't tell Arabic-script languages apart — on this macOS it reads Persian and Dari
// as Arabic or Urdu, at full confidence. So a phrase's language is the spelling's guess, except where the spelling
// can't know and the sound can.

/// ISO 639-1 code for a language as Whisper names it ("Persian", "english", "fa").
func languageCode(_ name: String) -> String? {
    let n = name.lowercased().trimmingCharacters(in: .whitespaces)
    if n.count == 2 { return n }
    if n.count == 3, n != "und", n.allSatisfy({ $0.isASCII && $0.isLetter }) { return n }    // no two-letter code: Kabyle, Cantonese
    if let c = languageCodes[n] { return c }
    let aliases = ["castilian": "es", "valencian": "ca", "flemish": "nl", "moldavian": "ro", "moldovan": "ro", "sinhalese": "si",
                   "haitian creole": "ht", "letzeburgesch": "lb", "pushto": "ps", "panjabi": "pa", "burmese": "my", "mandarin": "zh"]
    let en = Locale(identifier: "en")
    let c = aliases[n] ?? Locale.LanguageCode.isoLanguageCodes.map(\.identifier).first { $0.count == 2 && en.localizedString(forLanguageCode: $0)?.lowercased() == n }
    languageCodes[n] = c
    return c
}
nonisolated(unsafe) var languageCodes: [String: String?] = [:]

/// "Persian" for "fa": how a language is named to the translation model.
func languageName(_ code: String) -> String { Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code }

/// The script a language is written in (ISO 15924; the CJK scripts as one, Nastaliq as Arabic).
func scriptOf(language code: String) -> String? {
    let s = Locale.Language(identifier: Locale.Language(identifier: code).maximalIdentifier).script?.identifier
    return s.map(scriptFamily)
}
func scriptFamily(_ s: String) -> String { ["Hans", "Hant", "Hani", "Jpan", "Kore", "Hang", "Hira", "Kana"].contains(s) ? "CJK" : s == "Aran" ? "Arab" : s }

/// The script a word or phrase is written in, by most of its letters.
func scriptOf(text: String) -> String? {
    var n: [String: Int] = [:]
    for u in text.unicodeScalars where u.properties.isAlphabetic {
        let v = u.value
        let s: String
        switch v {
        case 0x41...0x2AF, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF: s = "Latn"     // with ɛ ɔ ɲ ɣ (Bambara, Kabyle)
        case 0x370...0x3FF, 0x1F00...0x1FFF: s = "Grek"
        case 0x400...0x52F: s = "Cyrl"
        case 0x530...0x58F: s = "Armn"
        case 0x590...0x5FF: s = "Hebr"
        case 0x600...0x6FF, 0x750...0x77F, 0x8A0...0x8FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: s = "Arab"
        case 0x900...0x97F: s = "Deva"
        case 0x980...0x9FF: s = "Beng"
        case 0xA00...0xA7F: s = "Guru"
        case 0xA80...0xAFF: s = "Gujr"
        case 0xB80...0xBFF: s = "Taml"
        case 0xC00...0xC7F: s = "Telu"
        case 0xC80...0xCFF: s = "Knda"
        case 0xD00...0xD7F: s = "Mlym"
        case 0xE00...0xE7F: s = "Thai"
        case 0x10A0...0x10FF: s = "Geor"
        case 0x1200...0x139F, 0x2D80...0x2DDF, 0xAB00...0xAB2F: s = "Ethi"
        case 0x700...0x74F: s = "Syrc"
        case 0x780...0x7BF: s = "Thaa"
        case 0xB00...0xB7F: s = "Orya"
        case 0xD80...0xDFF: s = "Sinh"
        case 0xE80...0xEFF: s = "Laoo"
        case 0xF00...0xFFF: s = "Tibt"
        case 0x1000...0x109F: s = "Mymr"
        case 0x1780...0x17FF: s = "Khmr"
        case 0x1800...0x18AF: s = "Mong"
        case 0x2C80...0x2CFF: s = "Copt"
        case 0x2D30...0x2D7F: s = "Tfng"
        case 0x1100...0x11FF, 0x3040...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF: s = "CJK"
        default: continue
        }
        n[s, default: 0] += 1
    }
    return n.max { $0.value < $1.value }?.key
}

/// Whether the spelling can tell this language from the others written in its script.
func spellingTells(_ code: String) -> Bool {
    if scriptOf(language: code) == "Arab" { return false }
    let r = NLLanguageRecognizer()          // a language NaturalLanguage has no model of is never its answer
    r.languageConstraints = [NLLanguage(code)]; r.processString("abc")
    return !r.languageHypotheses(withMaximum: 1).isEmpty
}

/// The language a run of heard words is in: the spelling's guess, unless the sound named another language of the
/// same script that the spelling can't tell apart (Dari read as Urdu) — or the spelling has no guess at all.
func phraseLanguage(_ words: [Word]) -> (code: String, p: Double)? {
    let text = words.map(\.text).joined(separator: " ")
    let guess = words.count >= 2 || text.count >= 8 ? dominantLanguage(text) : nil
    var tags: [String: Int] = [:]
    for w in words { if let l = w.lang { tags[l, default: 0] += 1 } }
    let heard = tags.max { $0.value < $1.value }.flatMap { 2 * $0.value >= words.count ? ($0.key, Double($0.value) / Double(words.count)) : nil }
    guard let heard else { return guess }
    guard let g = guess, g.code != heard.0 else { return heard }
    if scriptOf(language: g.code) == scriptOf(language: heard.0), !spellingTells(g.code) || !spellingTells(heard.0) { return heard }
    return g
}

// ---------- languages of the text itself (on-device, NaturalLanguage) ----------
// Whisper names one language per request and may silently translate into it, so what each line is actually in
// is read from its words.

/// ISO 639-1 code of the language a text is most likely in, among `among` (any language when empty).
func dominantLanguage(_ text: String, among: [String] = []) -> (code: String, p: Double)? {
    let r = NLLanguageRecognizer()
    if !among.isEmpty { r.languageConstraints = among.map { NLLanguage($0) } }
    r.processString(text)
    guard let (l, p) = r.languageHypotheses(withMaximum: 1).first else { return nil }
    return (String(l.rawValue.prefix(2)), p)
}

/// Every language a line is sung in: each run of three words is identified on its own, so a line that switches
/// mid-breath ("Lo que pasó, ya no duele tanto, I think that I could move on") reports both.
func lineLanguages(_ words: [String], among: [String]) -> Set<String> {
    guard words.count > 3 else { return dominantLanguage(words.joined(separator: " "), among: among).map { [$0.code] } ?? [] }
    var out = Set<String>()
    for i in 0...(words.count - 3) {
        if let (c, p) = dominantLanguage(words[i..<(i + 3)].joined(separator: " "), among: among), p >= 0.7 { out.insert(c) }
    }
    return out.isEmpty ? (dominantLanguage(words.joined(separator: " "), among: among).map { [$0.code] } ?? []) : out
}

/// A line needs a translation unless all of it is English. The song's languages only narrow the guess: they come
/// from lyrics or from what Whisper heard, and either can be English where the singing isn't (a translated lyrics
/// page, Whisper drifting into translating), which once left "Me dejas sin palabras" with no English under it.
func needsTranslation(_ words: [String], among: [String]) -> Bool {
    let text = words.joined(separator: " ")
    guard text.contains(where: \.isLetter) else { return false }
    if let free = dominantLanguage(text), free.code != "en", free.p >= 0.6 { return true }
    let l = lineLanguages(words, among: Array(Set(among + ["en"])))
    return !(l == ["en"])
}

/// What Whisper writes for a stretch of music it hears no words in ("[Music]", and "موسیقی" when it's decided on
/// Persian): a whole segment of just this is no lyric.
let musicTags: Set<String> = ["music", "musik", "musique", "música", "musica", "muziek", "muzyka", "музыка", "موسیقی", "موسيقى",
                               "音乐", "音楽", "음악", "संगीत", "müzik", "μουσική", "מוזיקה"]

let hallucinations = ["sous-titres", "sous-titrage", "amara.org", "merci d'avoir regardé", "thanks for watching"]

/// Whisper's silence hallucinations: a segment that is only one of these, in any case and with any punctuation, is
/// dropped (owner, 2026-10-27, SPEC 24). The one list to extend; entries are compared through `hallucinationKey`.
let silenceHallucinations: Set<String> = Set([
    "Thank you.", "Thanks for watching!", "Um", "Thank you for watching.", "Subtitles by the Amara.org community",
    "Visions, diaspora", "Visions diaspora", "[BLANK_AUDIO]", "[Music]", "[Applause]",
].map(hallucinationKey))
/// Lower case, letters, digits, brackets and underscores only, single spaces: "Visions, diaspora." → "visions diaspora".
func hallucinationKey(_ s: String) -> String {
    String(s.lowercased().map { $0.isLetter || $0.isNumber || "[]_".contains($0) ? $0 : " " })
        .split(separator: " ").joined(separator: " ")
}

/// What Whisper writes when music has no words in it: stock phrases ("Thank you.", "I'm sorry.", "um"), a count
/// ("1, 2, 3"), a lone word. Real singing has more singing round it; these, on a song heard without lyrics, don't.
let fillerPhrases: Set<String> = [
    "thank you", "thank you very much", "thanks", "thank you so much", "thank you for watching", "thanks for watching",
    "you", "i'm sorry", "sorry", "um", "uh", "hmm", "mm", "oh", "ah", "bye", "bye bye", "okay", "ok", "so",
    "takk", "takk for meg", "tack", "tak", "danke", "merci", "gracias", "grazie", "obrigado", "obrigada", "dziękuję",
    "спасибо", "продолжение следует", "ありがとうございました", "ご視聴ありがとうございました", "谢谢", "谢谢观看", "감사합니다",
]
func isFiller(_ l: Line) -> Bool {
    let t = l.words.map(\.text).joined(separator: " ").lowercased()
        .replacingOccurrences(of: "’", with: "'")
        .filter { $0.isLetter || $0 == " " || $0 == "'" }
        .split(separator: " ").joined(separator: " ")
    return t.isEmpty || l.words.count == 1 || fillerPhrases.contains(t)
}
/// A song's heard lines without the filler that has no real singing within 10 s of it.
func dropFillers(_ lines: [Line]) -> [Line] {
    let real = lines.filter { !isFiller($0) }
    return lines.filter { l in !isFiller(l) || real.contains { $0.start < l.end + 10 && $0.end > l.start - 10 } }
}

struct LoopState: Equatable { var track = false, ab = false; var a: Double?, b: Double? }

enum Cmd { case playPause, play(Bool), skip(Double), seek(Double), speed(Double), loop(LoopState), scrub(Bool), volume(Double) }

/// Labels ignore the mouse so clicks and drags reach the subtitle area behind them.
final class PassLabel: NSTextField { override func hitTest(_ p: NSPoint) -> NSView? { nil } }

final class RecenseKeyPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    // Titled windows are kept below the menu bar; the strip hangs from the very top of the screen.
    override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect { r }
    override func keyDown(with e: NSEvent) { if onKey?(e) != true { super.keyDown(with: e) } }
}

/// Watches the pointer entering / leaving / moving over the window (the mode switch shows, the home bar wakes).
final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    var onMove: (() -> Void)?
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }
    override func mouseMoved(with e: NSEvent) { onMove?() }
}

/// SPEC 70: a Gallery video's picture, behind the subtitles, the whole window. Muted (what's heard is the page's own
/// player) and kept on that player's clock: it plays, pauses, changes speed and seeks with it. A shade over it keeps
/// the white lines readable. It never takes the pointer: clicks and scrolls go to the subtitles as before.
final class VideoBackdrop: NSView {
    let player = AVPlayer()
    private let picture = AVPlayerLayer()
    private let shade = CALayer()
    private(set) var url: URL?
    private var seeking = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        picture.player = player; picture.videoGravity = .resizeAspect
        shade.backgroundColor = NSColor(white: 0, alpha: 0.4).cgColor
        layer?.addSublayer(picture); layer?.addSublayer(shade)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.frame = bounds; shade.frame = bounds
        CATransaction.commit()
    }
    /// The file to show (nil: none, the window as before).
    func show(_ u: URL?) {
        guard u != url else { return }
        url = u; seeking = false
        player.replaceCurrentItem(with: u.map { AVPlayerItem(url: $0) })
        isHidden = u == nil
    }
    /// Called every frame with the followed player's time: a drift past a third of a second (any, while paused, so a
    /// scrub shows its frame) is a seek; otherwise only the rate is matched.
    func follow(_ t: Double, rate: Double, paused: Bool) {
        guard url != nil, let item = player.currentItem, item.status == .readyToPlay else { return }
        let dur = item.duration.seconds
        let target = dur.isFinite && dur > 0 ? min(max(0, t), dur) : max(0, t)
        let r: Float = paused ? 0 : Float(rate)
        if player.rate != r { player.rate = r }
        guard !seeking, abs(player.currentTime().seconds - target) > (paused ? 0.04 : 0.33) else { return }
        seeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async { self?.seeking = false }
        }
    }
}

/// Blank space: a click toggles play/pause, a drag moves the window; a double-click or a right-click is for the line.
final class SubtitleArea: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onTextClick: (() -> Void)?                 // a tap on the words themselves (the editor), as in Gallery
    var isText: ((NSPoint) -> Bool)?               // window coordinates
    var onRightClick: ((NSEvent) -> Void)?
    var onScroll: ((NSEvent) -> Bool)?             // Learning's barrel turns with a scroll; true: taken
    override func rightMouseDown(with e: NSEvent) { onRightClick?(e) }
    override func scrollWheel(with e: NSEvent) { if onScroll?(e) != true { super.scrollWheel(with: e) } }
    private var down: NSEvent?
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { down = e; window?.makeKey() }    // the space bar plays / pauses here
    override func mouseDragged(with e: NSEvent) {
        Recense.delegate?.kick()                  // dragging the subtitles: draw at full rate
        guard let d = down else { return }
        if hypot(e.locationInWindow.x - d.locationInWindow.x, e.locationInWindow.y - d.locationInWindow.y) > 3 {
            down = nil; window?.performDrag(with: d)
        }
    }
    override func mouseUp(with e: NSEvent) {
        if down != nil, e.clickCount == 1 {
            if isText?(e.locationInWindow) == true, let t = onTextClick { t() } else { onClick?() }
        }
        down = nil
    }
}

func clock(_ t: Double) -> String {
    guard t.isFinite else { return "--:--" }
    let s = Int(max(0, t).rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// ---------- the home bar and the vertical bar: Gallery's, one implementation ----------
//
// Not a port: Gallery's own homebar.js and homebar.css (../gallery/gallery/src/client), copied into the app by
// build.sh and run in a transparent web view over the subtitles (homebar/index.html is the host page). Any change
// to the bar is made there, once, for both apps (SPEC P2).
//
//   horizontal: hover → bookmarks · a firm press → bookmark this moment · click → the barrel: language, text size,
//               Loop · A · B, speed, Retranscribe · Export as MD · M4B · hold → Time Seeking
//   vertical:   the original language's prominence (two fingers or a drag) · hover → the bookmarks · press → reset
//
// The page only takes the pointer where the bar is (it posts those rects); everywhere else the subtitles have it.

/// The owner of RecenseHomeBar's always-on tracking area, so WebKit's own tracking stays untouched.
final class PointerPass: NSResponder {
    private weak var bar: RecenseHomeBar?
    init(_ b: RecenseHomeBar) { bar = b; super.init() }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with e: NSEvent) { bar?.pass(e) }
    override func mouseMoved(with e: NSEvent) { bar?.pass(e) }
    override func mouseExited(with e: NSEvent) { bar?.pass(nil) }
}

/// A script message handler that doesn't keep its web view alive.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}

final class RecenseHomeBar: WKWebView, WKScriptMessageHandler, WKNavigationDelegate {
    /// The control line: the stroke is centred this far above the window's foot (the page's --cl).
    static let line: CGFloat = 10                // as Recense's R2 home bar: its stroke ~9.5 pt above the foot (SPEC 68)
    static var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var onCmd: ((Cmd) -> Void)?
    var say: ((String) -> Void)?
    /// Everything else the bar asks for: "lang" (v), "size" (v), "prominence" (v, a1, a2), "bookmark", "jump" (t),
    /// "retranscribe", "export" (as: "md" | "m4b").
    var onAction: ((String, [String: Any]) -> Void)?
    private(set) var open = false
    var onOpen: ((Bool) -> Void)?
    private var hits: [CGRect] = []          // where the bar takes the pointer, in the page's coordinates
    private var ready = false, queued: [String] = []

    init() {
        let cfg = WKWebViewConfiguration()
        super.init(frame: .zero, configuration: cfg)
        cfg.userContentController.add(WeakScriptHandler(self), name: "recense")
        // Inside Recense both bars sit out at the edges, as Recense's own do: the stroke near the foot, the vertical bar
        // at the right edge. In the strip (.strip) the stroke sits a little higher, so A and B's names under it
        // fit, and the time ruler is compact: the open bar stays inside the zone below the lines (Overlay.barZone).
        cfg.userContentController.addUserScript(WKUserScript(source: """
            document.head.insertAdjacentHTML('beforeend', '<style>:root{--cl:calc(\(Int(RecenseHomeBar.line))px + var(--foot,0px))} .p-ctrl{right:-10px;bottom:var(--foot,0px)} :root.strip{--cl:calc(\(Int(RecenseHomeBar.line))px + var(--foot,0px))} .strip .p-hbseek{height:46px} .strip .p-skhint{display:none} .strip .p-skread{bottom:28px;font-size:15px;line-height:18px}</style>')
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        setValue(false, forKey: "drawsBackground")
        navigationDelegate = self
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("homebar"),
           FileManager.default.fileExists(atPath: dir.appendingPathComponent("homebar.js").path) {
            loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        } else {
            log("homebar: Resources/homebar is missing (build.sh copies it from Gallery)")
        }
        watchSwipes()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let w = swipeWatch { NSEvent.removeMonitor(w) } }

    // ----- the pointer: only where the bar is -----
    override func hitTest(_ p: NSPoint) -> NSView? {
        guard !isHidden, let s = superview else { return nil }
        let q = convert(p, from: s)
        // While the bar is open, every two-finger swipe over it goes to the bar (its slides), even where the page's
        // last report of its shape (every 250 ms) hasn't caught up; otherwise the swipe stutters into the subtitles.
        if open, NSApp.currentEvent?.type == .scrollWheel, bounds.contains(q) { return super.hitTest(p) }
        let y = isFlipped ? q.y : bounds.height - q.y
        return hits.contains { $0.contains(CGPoint(x: q.x, y: y)) } ? super.hitTest(p) : nil
    }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    // ----- hover while another app has the keyboard (item 31) -----
    // WebKit only hears the pointer in the key window, so with Obsidian (say) in front the bars never unfolded or
    // tucked away, and clicking Recense to wake them plays / pauses. An always-on tracking area hands the pointer to
    // the page itself (Recense.hover) whenever this window isn't key; once it is, WebKit's own events take over.
    private lazy var hoverPass = PointerPass(self)
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === hoverPass }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: hoverPass))
    }
    fileprivate func pass(_ e: NSEvent?) {
        guard window?.isKeyWindow != true else { return }
        guard let e else { run("Recense.hover(null)"); return }
        let q = convert(e.locationInWindow, from: nil)
        let y = isFlipped ? q.y : bounds.height - q.y
        run("Recense.hover(\(Int(q.x)),\(Int(y)))")
    }
    /// SPEC 19: once the window is clicked, space plays / pauses wherever the pointer is, the bar included: WebKit
    /// would otherwise keep the space it was focused by. Typing in the bar's own fields still gets it.
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 49, e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty,
           !(window?.firstResponder is NSText), let w = window as? RecenseKeyPanel, w.onKey?(e) == true { return }
        super.keyDown(with: e)
    }
    // While the line is being edited its field keeps the keyboard: a click on the editor's tools must not end the typing.
    private(set) var editing = false
    override var acceptsFirstResponder: Bool { !editing && super.acceptsFirstResponder }
    func editor(_ on: Bool) { editing = on; call("editor", on) }

    // ----- two fingers on the trackpad (SPEC 60) -----
    // A swipe's fingers resting on the trackpad send no events, so the page can't tell them from lifted ones; the
    // swipe's phases can. A swipe that starts over the bar is the bar's from the fingers coming down to the end of
    // its glide, wherever AppKit would route its later events (the bar unfolds and folds under it): the page hears
    // "down" before the swipe's first wheel and "up" once they lift, so a swipe-and-hold keeps the ruler up, and
    // its place, until then. The glide after a lift (momentum) isn't the fingers: it never reaches the page, where
    // it would start a second seek after the one the lift ended (or turn the subtitles' barrel underneath).
    private var fingersDown = false
    private var ownsSwipe = false
    private var swipeWatch: Any?

    private func watchSwipes() {
        swipeWatch = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self else { return e }
            if e.phase.isEmpty && e.momentumPhase.isEmpty { return e }   // a mouse's wheel: no fingers to follow
            if e.phase.contains(.mayBegin) || e.phase.contains(.began) { self.ownsSwipe = self.isUnder(e) }
            guard self.ownsSwipe else { return e }
            if e.momentumPhase.isEmpty { self.swipe(e) }
            return nil
        }
    }

    private func isUnder(_ e: NSEvent) -> Bool {
        guard !isHidden, e.window === window, let root = window?.contentView else { return false }
        guard let hit = root.hitTest(root.superview?.convert(e.locationInWindow, from: nil) ?? e.locationInWindow) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }

    private func swipe(_ e: NSEvent) {
        if e.phase.contains(.began) || e.phase.contains(.changed) { fingers(true) }
        super.scrollWheel(with: e)
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) { fingers(false) }
    }

    private func fingers(_ down: Bool) {
        guard down != fingersDown else { return }
        fingersDown = down
        run("Recense.fingers(\(down))")
    }

    // swipes that start over the bar come through watchSwipes; this is for any AppKit hands the bar itself
    override func scrollWheel(with e: NSEvent) {
        if !e.momentumPhase.isEmpty { return }
        if e.phase.isEmpty { super.scrollWheel(with: e) } else { swipe(e) }
    }

    // ----- the page -----
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let b = m.body as? [String: Any], let k = b["k"] as? String else { return }
        let num = { (n: String) in (b[n] as? NSNumber)?.doubleValue }
        switch k {
        case "ready":
            ready = true
            queued.forEach { evaluateJavaScript($0) }; queued = []
        case "hits":
            hits = (b["r"] as? [[NSNumber]] ?? []).compactMap { r in
                r.count == 4 ? CGRect(x: r[0].doubleValue, y: r[1].doubleValue, width: r[2].doubleValue, height: r[3].doubleValue) : nil
            }
        case "open": open = b["on"] as? Bool ?? false; onOpen?(open)
        case "say": if let t = b["t"] as? String { say?(t) }
        case "cmd":
            switch b["c"] as? String {
            case "playPause": onCmd?(.playPause)
            case "skip": onCmd?(.skip(num("d") ?? 0))
            case "seek": onCmd?(.seek(num("t") ?? 0))
            case "speed": onCmd?(.speed(num("v") ?? 1))
            case "scrub": onCmd?(.scrub(b["on"] as? Bool ?? false))
            case "loop": onCmd?(.loop(LoopState(track: b["track"] as? Bool ?? false, ab: b["ab"] as? Bool ?? false, a: num("a"), b: num("b"))))
            case "volume": if let v = num("v") { onCmd?(.volume(v)) }
            default: break
            }
        default: onAction?(k, b)
        }
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {}

    /// Runs `js` in the page, or as soon as it is ready.
    func run(_ js: String) {
        if ready { evaluateJavaScript(js) } else { queued.append(js) }
    }
    func call(_ fn: String, _ arg: Any) {
        guard let d = try? JSONSerialization.data(withJSONObject: arg, options: [.fragmentsAllowed]), let s = String(data: d, encoding: .utf8) else { return }
        run("Recense.\(fn)(\(s))")
    }

    // ----- what the window asks of it -----
    func closeTools() -> Bool { guard open else { return false }; open = false; run("Recense.close()"); return true }
    func captureA() { run("Recense.key('a')") }
    func captureB() { run("Recense.key('b')") }
    func pressLoop() { run("Recense.key('l')") }
    func speedStep(_ d: Int) { run("Recense.key('\(d < 0 ? "<" : ">")')") }
    private var wokeAt = 0.0
    func wake() {   // (the window calls this on every pointer move: a few times a second is plenty)
        let now = CACurrentMediaTime()
        guard now - wokeAt > 0.25 else { return }
        wokeAt = now
        run("Recense.wake()")
    }

    func report(time t: Double, duration d: Double, paused p: Bool, rate: Double, loop l: LoopState, volume: Double? = nil) {
        call("report", ["time": t, "duration": d.isFinite ? d : 0, "paused": p, "rate": rate,
                        "loop": ["track": l.track, "ab": l.ab, "a": l.a.map { $0 as Any } ?? NSNull(), "b": l.b.map { $0 as Any } ?? NSNull()],
                        "volume": volume.map { $0 as Any } ?? NSNull()])
    }
    /// The language, text size, prominence and this media's bookmarks, as the page should show them.
    func state(_ s: [String: Any]) { call("state", s) }
}

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }

/// Gallery's toast: a short word on what a control just did, high in the window, gone after a moment.
final class Toast: NSView {
    var text = ""
    var hideWork: DispatchWorkItem?
    override var isFlipped: Bool { true }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    var pill: CGRect {
        let w = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 32
        return CGRect(x: bounds.midX - w / 2, y: 0, width: w, height: 34.75)
    }
    func say(_ s: String) {
        text = s; needsDisplay = true
        NSAnimationContext.runAnimationGroup { $0.duration = RecenseHomeBar.still ? 0 : 0.25; animator().alphaValue = 1 }
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = RecenseHomeBar.still ? 0 : 0.25; self?.animator().alphaValue = 0 }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: w)
    }
    override func draw(_ dirty: NSRect) {
        guard !text.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = pill, shape = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        // the glass edge's drop shadow, outside the pill only
        ctx.saveGState()
        let out = NSBezierPath(rect: bounds.insetBy(dx: -60, dy: -60)); out.append(shape); out.windingRule = .evenOdd; out.addClip()
        let sh = NSShadow(); sh.shadowOffset = NSSize(width: 0, height: -8); sh.shadowBlurRadius = 22; sh.shadowColor = rgba(0, 0, 0, 0.28); sh.set()
        NSColor.black.setFill(); shape.fill()
        ctx.restoreGState()
        ctx.saveGState(); shape.addClip()
        rgba(20, 20, 22, 0.58).setFill(); shape.fill()
        NSGradient(colors: [rgba(255, 255, 255, 0.09), rgba(255, 255, 255, 0.02)])!.draw(in: r, angle: 90)
        do {   // the sheen: light catching the top-left
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.minY); ctx.scaleBy(x: r.width * 1.4, y: r.height * 1.7)
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [rgba(255, 255, 255, 0.17).cgColor, rgba(255, 255, 255, 0.05).cgColor, rgba(255, 255, 255, 0).cgColor] as CFArray, locations: [0, 0.42, 0.64])!
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [.drawsAfterEndLocation])
            ctx.restoreGState()
        }
        for (dy, a) in [(0.5, 0.45), (-0.5, 0.10)] as [(CGFloat, CGFloat)] {
            let p = NSBezierPath(rect: r.insetBy(dx: -2, dy: -2)); p.append(NSBezierPath(roundedRect: r.offsetBy(dx: 0, dy: dy), xRadius: r.height / 2, yRadius: r.height / 2))
            p.windingRule = .evenOdd; rgba(255, 255, 255, a).setFill(); p.fill()
        }
        rgba(255, 255, 255, 0.22).setStroke()
        let ring = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: r.height / 2, yRadius: r.height / 2); ring.lineWidth = 0.5; ring.stroke()
        ctx.restoreGState()
        let sh2 = NSShadow(); sh2.shadowOffset = NSSize(width: 0, height: -1); sh2.shadowBlurRadius = 2; sh2.shadowColor = rgba(0, 0, 0, 0.4)
        let a = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white, .shadow: sh2])
        a.draw(at: CGPoint(x: r.midX - a.size().width / 2, y: r.midY + (font.ascender + font.descender) / 2 - font.ascender))
    }
}

/// The line on screen, corrected where it stands: Return keeps what's typed (nothing hides the line), Esc leaves it
/// as it was, and Reset to Auto (on a corrected line) brings back what the pipeline made. Clicking away keeps it.
final class LineEditor: NSView, NSTextFieldDelegate {
    enum Result { case save(String), reset, cancel, move(Int, String) }   // move: saved, then the line `n` away
    /// Notes 24: the whole transcript on a vertical barrel, the edited line in the middle; the lines before it above,
    /// those after it below, smaller and fainter the farther they are. Scroll (or click one) to edit another line.
    private var rows: [PassLabel] = []
    private var rowOffsets: [Int] = []
    private var scrollAcc: CGFloat = 0
    let field = NSTextField(string: "")
    let hint = PassLabel(labelWithString: "Return saves  ·  Esc cancels  ·  empty hides the line")
    let resetButton = NSButton(title: "Reset to Auto", target: nil, action: nil)
    let timingButton = NSButton(title: "Timing…", target: nil, action: nil)
    var onTiming: (() -> Void)?            // the line's words timed by ear (TimingPanel); set by whoever began the edit
    private var done: ((Result) -> Void)?
    var editing: Bool { done != nil }

    init() {
        super.init(frame: .zero)
        field.isBordered = false; field.isBezeled = false; field.focusRingType = .none
        field.drawsBackground = true; field.backgroundColor = NSColor(white: 1, alpha: 0.09)
        field.textColor = .white; field.alignment = .center
        field.usesSingleLineMode = false; field.cell?.wraps = true; field.cell?.isScrollable = false
        field.wantsLayer = true; field.layer?.cornerRadius = 8; field.layer?.masksToBounds = true
        field.delegate = self
        hint.font = .systemFont(ofSize: 11); hint.textColor = NSColor(white: 1, alpha: 0.45)
        resetButton.bezelStyle = .recessed; resetButton.controlSize = .small; resetButton.font = .systemFont(ofSize: 11)
        resetButton.refusesFirstResponder = true      // pressing it mustn't end the typing first (that would save it)
        resetButton.target = self; resetButton.action = #selector(resetPressed)
        timingButton.bezelStyle = .recessed; timingButton.controlSize = .small; timingButton.font = .systemFont(ofSize: 11)
        timingButton.refusesFirstResponder = true
        timingButton.target = self; timingButton.action = #selector(timingPressed)
        for v in [field, hint, resetButton, timingButton] { addSubview(v) }
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func begin(_ text: String, edited: Bool, size: CGFloat, above: [String] = [], below: [String] = [],
               done: @escaping (Result) -> Void) {
        self.done = done
        rows.forEach { $0.removeFromSuperview() }; rows = []; rowOffsets = []; scrollAcc = 0
        let reach = 14   // as many as the window holds (layout hides the rest): the whole transcript, a turn away
        for (k, t) in above.suffix(reach).reversed().enumerated() { addRow(t, -(k + 1), size) }
        for (k, t) in below.prefix(reach).enumerated() { addRow(t, k + 1, size) }
        field.font = .systemFont(ofSize: size, weight: .semibold)
        field.stringValue = text
        resetButton.isHidden = !edited
        isHidden = false
        layout()
        window?.makeKey()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }

    func finish(_ r: Result) {
        guard let d = done else { return }
        done = nil
        isHidden = true
        window?.makeFirstResponder(nil)
        d(r)
    }
    @objc func resetPressed() { finish(.reset) }
    /// The typing is saved as Return would, then the line's timing opens over the window.
    @objc func timingPressed() { let f = onTiming; finish(.save(field.stringValue)); f?() }
    private func addRow(_ t: String, _ off: Int, _ size: CGFloat) {
        let d = CGFloat(abs(off))
        let l = PassLabel(labelWithString: t.isEmpty ? "…" : t)
        l.font = .systemFont(ofSize: max(10, size * pow(0.82, d)), weight: .medium)
        l.textColor = NSColor(white: 1, alpha: max(0.12, 0.62 - 0.13 * d))
        l.alignment = .center; l.lineBreakMode = .byTruncatingTail; l.maximumNumberOfLines = 1
        addSubview(l); rows.append(l); rowOffsets.append(off)
    }
    func move(_ n: Int) { finish(.move(n, field.stringValue)) }
    override func scrollWheel(with e: NSEvent) {
        guard editing, !rows.isEmpty else { return super.scrollWheel(with: e) }
        scrollAcc += e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 12)
        guard abs(scrollAcc) > 36 else { return }
        let n = scrollAcc > 0 ? -1 : 1        // content follows the fingers: down shows the lines before
        scrollAcc = 0
        if rowOffsets.contains(n) { move(n) }
    }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let i = rows.firstIndex(where: { !$0.isHidden && $0.frame.insetBy(dx: 0, dy: -3).contains(p) }) { move(rowOffsets[i]) }
        else { super.mouseDown(with: e) }
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { finish(.save(field.stringValue)); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { finish(.cancel); return true }
        return false
    }
    func controlTextDidChange(_ n: Notification) { needsLayout = true }
    func controlTextDidEndEditing(_ n: Notification) { finish(.save(field.stringValue)) }

    override func layout() {
        super.layout()
        let w = max(100, bounds.width - 56)
        let h = min(max(30, bounds.height - 44), (field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w - 16, height: 1000)).height ?? 30) + 14)
        var hs = hint.intrinsicContentSize; hs.width += 4
        let bs = resetButton.isHidden ? .zero : resetButton.intrinsicContentSize
        let row = hs.width + (resetButton.isHidden ? 0 : 14 + bs.width), y = (bounds.height - h - 30) / 2 + 30
        field.frame = NSRect(x: 28, y: y, width: w, height: h)
        hint.frame = NSRect(x: (bounds.width - row) / 2, y: y - 8 - max(hs.height, bs.height) / 2 - hs.height / 2, width: hs.width, height: hs.height)
        resetButton.frame = NSRect(x: hint.frame.maxX + 14, y: y - 8 - max(hs.height, bs.height) / 2 - bs.height / 2, width: bs.width, height: bs.height)
        let ts = timingButton.intrinsicContentSize
        timingButton.isHidden = onTiming == nil
        timingButton.frame = NSRect(x: (resetButton.isHidden ? hint.frame.maxX : resetButton.frame.maxX) + 10, y: y - 8 - max(hs.height, ts.height) / 2 - ts.height / 2, width: ts.width, height: ts.height)
        // the barrel: lines before stack up from the field, lines after down from the hint
        var up = field.frame.maxY + 6, down = min(hint.frame.minY, resetButton.isHidden ? hint.frame.minY : resetButton.frame.minY) - 6
        for (l, off) in zip(rows, rowOffsets).sorted(by: { abs($0.1) < abs($1.1) }) {
            let h = l.intrinsicContentSize.height
            let r = off < 0 ? NSRect(x: 28, y: up, width: w, height: h) : NSRect(x: 28, y: down - h, width: w, height: h)
            if off < 0 { up += h + 4 } else { down -= h + 4 }
            l.frame = r; l.isHidden = r.minY < 0 || r.maxY > bounds.height
        }
    }
}

final class Overlay: NSObject, NSWindowDelegate {
    let panel: RecenseKeyPanel
    let words = WordsView()
    let status = PassLabel(labelWithString: "")
    let skipAd = NSButton(title: "Skip Ad", target: nil, action: nil)   // shown while the followed player plays an ad (SPEC 37)
    var onSkipAd: (() -> Void)?
    let spoken = NSColor.white, current = NSColor(red: 1, green: 0.84, blue: 0.2, alpha: 1)
    let upcoming = NSColor(white: 1, alpha: 0.35), ahead = NSColor(white: 1, alpha: 0.35)   // the ghost: preloaded at 35 % (item 20)
    let meaning = NSColor(white: 1, alpha: 0.8)    // Learning: a heard phrase's English, a step quieter than the original
    var lastKey = ""
    var onCmd: ((Cmd) -> Void)?
    var onToggle: (() -> Void)?
    var onBookmark: (() -> Void)?
    /// The home bar's own asks the window can't answer: "bookmark", "jump" (t), "retranscribe", "export" (as).
    var onBarAction: ((String, [String: Any]) -> Void)?
    /// This media's bookmarks, for the home bar's hover slide and the vertical bar's list.
    var bookmarks: () -> [Bookmarks.Mark] = { [] }
    var barSent = ""                                     // the state the home bar last got

    enum Mode: Int { case bilingual = 0, learning = 1 }
    var mode = Mode(rawValue: UserDefaults.standard.integer(forKey: "viewMode")) ?? .bilingual
    let modeCtl = NSSegmentedControl(labels: ["Follow", "Learn"], trackingMode: .selectOne, target: nil, action: nil)
    // the native language (Gallery spec §1), beside the mode switch and shown with it: one click, no menu
    let langCtl = NSSegmentedControl(labels: NativeLang.all.map { $0.code.uppercased() }, trackingMode: .selectOne, target: nil, action: nil)
    let area = SubtitleArea()
    let video = VideoBackdrop()                // SPEC 70: a Gallery video's picture, behind everything
    var fit = (key: "", scale: CGFloat(1))     // font scale that makes the current line fit the window
    var fits: [String: CGFloat] = [:]          // Learning: the few lines too long for their place, and their scale
    var browserControls = false
    let homeBar = RecenseHomeBar()
    /// Why the followed player can't take the sound tray's EQ, Key and Reverb (SPEC 54), or nil: the page's tray says so.
    var soundNo: String? { didSet { if soundNo != oldValue { homeBar.call("sound", soundNo ?? NSNull()) } } }
    let toast = Toast()
    /// The chord detector's chord, directly above the lines (SPEC 40)
    let chord = PassLabel(labelWithString: "")
    func showChord(_ t: String?) {
        chord.stringValue = t ?? ""
        chord.isHidden = (t ?? "").isEmpty
    }
    var modeWork: DispatchWorkItem?
    let editor = LineEditor()
    var onEdit: ((_ clicked: Bool) -> Void)?             // correct the line on screen (a double-click has played or paused first)
    var onReset: (() -> Void)?                           // the line on screen back to what the pipeline made
    var onRetranscribe: (() -> Void)?                    // Recense.app's menu commands, now that Recense lives in Recense
    var onExport: (() -> Void)?
    var lineState: (() -> (editable: Bool, edited: Bool))?
    // Learning's barrel (spec §6): one line in view; the lines either side ride a drum out of sight and roll in as the
    // line changes, and show while a scroll turns it to pick a line.
    var drum = -1.0                                      // the drum's position, in lines; -1 until the first frame
    var drumSpread = 0.0                                 // 0: only the line in view shows; 1: its neighbours too
    var drumHold: (j: Int, until: Double)?               // a line just picked, kept in view while the player catches up
    var drumTurning: DispatchWorkItem?                   // a scroll turning the drum, until its events stop
    var drumFrame = 0.0, drumPitch: CGFloat = 60, drumCount = 0
    var onPick: ((Int) -> Void)?                         // play from line j of the lines last drawn
    var drumLine: Int? { mode == .learning && drum >= 0 && drumCount > 0 ? min(drumCount - 1, Int(drum.rounded())) : nil }

    var minimized: Bool { hostedRoot == nil && (panel.isMiniaturized || !panel.isVisible) }

    /// The strip keeps one shape: the lines above, and below them a zone of their own for the home bar, as tall as
    /// the bar is open (its slides, or the time ruler, compacted to fit). The strip used to grow 60 points while the
    /// bar was open: the page moved under the pointer, so hover, swipes and the hold that opens the ruler kept being
    /// cut short, and the ruler was drawn over the lines.
    static let stripHeight: CGFloat = 164, barZone: CGFloat = 78
    var inStrip = false
    /// The strip starts over the menu bar (and a notch): its lines start below that, and the strip grows by as much (notes 47).
    static func stripTop(_ sc: NSScreen) -> CGFloat {
        max(26, sc.frame.maxY - sc.visibleFrame.maxY, sc.safeAreaInsets.top) + 22
    }
    static func stripHeight(_ sc: NSScreen) -> CGFloat { stripHeight + stripTop(sc) - 26 }
    func hideStrip() { panel.orderOut(nil); onToggle?() }
    func toggleStrip() { panel.isVisible ? hideStrip() : showStrip() }

    /// Opened from Recense: a see-through strip from the top of the screen (over the menu bar) to about the bottom of a
    /// browser's address bar, as wide as Recense's card; dark enough to read the subtitles, light enough to see behind.
    func showStrip() {
        guard let sc = NSScreen.main else { return }
        let w = timeSize.width, h = Overlay.stripHeight(sc)
        inStrip = true
        areaTop.constant = Overlay.stripTop(sc)
        wordsFoot.constant = -Overlay.barZone
        homeBar.run("document.documentElement.classList.add('strip')")
        panel.backgroundColor = NSColor(white: 0.04, alpha: 0.55)
        panel.styleMask.remove(.resizable); panel.isMovable = false      // locked: only the strip's Recense button moves it
        panel.setFrame(NSRect(x: (sc.frame.midX - w / 2).rounded(), y: sc.frame.maxY - h, width: w, height: h), display: true)
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.orderFrontRegardless()
        lastKey = ""; fits = [:]
    }

    /// Inside Recense: the window's whole interface moves onto Recense's Recense page (nil moves it back to the panel).
    var hostedRoot: NSView?
    private var panelWasVisible = false
    lazy var areaTop = area.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 26)
    lazy var areaFoot = area.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor)
    lazy var barFoot = homeBar.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor)
    /// The lines' foot: clear of the stroke; in the strip, clear of the whole open bar (barZone).
    lazy var wordsFoot = words.bottomAnchor.constraint(equalTo: area.bottomAnchor, constant: -(RecenseHomeBar.line + 10))
    /// Editing (gallery notes 20261029 row 40): the window stretches down; what plays keeps the top, the editor is a
    /// pane under it, and the home bar stays at the foot with all it does, as Gallery's player does.
    lazy var editorTop = editor.topAnchor.constraint(equalTo: words.bottomAnchor, constant: 8)
    lazy var editorFoot: NSLayoutConstraint = {
        // (gives way while not editing, when the lines reach the foot and the editor is hidden)
        let c = editor.bottomAnchor.constraint(equalTo: area.bottomAnchor, constant: -(RecenseHomeBar.line + 30)); c.priority = .defaultHigh; return c
    }()
    static let editorPane: CGFloat = 300

    func host(in container: NSView?, frame: NSRect = .zero) {
        if let c = container {
            guard hostedRoot == nil, let root = panel.contentView else { return }
            panelWasVisible = panel.isVisible
            panel.contentView = NSView(); panel.orderOut(nil)
            root.frame = frame; root.autoresizingMask = [.width, .height]
            c.addSubview(root, positioned: .below, relativeTo: nil)
            hostedRoot = root
        } else if let root = hostedRoot {
            root.removeFromSuperview(); hostedRoot = nil
            panel.contentView = root
            if panelWasVisible { panel.orderFrontRegardless() }
        }
        lastKey = ""; fits = [:]
    }

    override init() {
        let screen = NSScreen.main!.visibleFrame
        // item 31: room for everything ported from Gallery's player (two lines + notation, home bar, vertical bar, the
        // sound tray's 240 pt sliders): 960 × 420, a 16 : 7 strip that still sits under a video
        let w: CGFloat = min(960, screen.width - 80), h: CGFloat = min(420, screen.height - 80)
        panel = RecenseKeyPanel(contentRect: NSRect(x: screen.midX - w / 2, y: screen.minY + 40, width: w, height: h),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()
        panel.title = "Recense"
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        // row 31: no traffic lights; the strip's Recense button and CC Off already open and close it
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(b)?.isHidden = true }
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .statusBar; panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = NSColor(white: 0.04, alpha: 0.86)
        panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: 520, height: 220)
        panel.delegate = self
        panel.setFrameAutosaveName("RecenseWindow2")   // item 31: the new size once, then the listener's own

        let root = HoverView()
        root.onHover = { [weak self] inside in self?.hover(inside) }
        root.onMove = { [weak self] in self?.homeBar.wake() }
        // a click on the subtitles plays or pauses; while the home bar is open it only folds the bar back
        area.onClick = { [weak self] in
            guard let self, !self.homeBar.closeTools() else { return }
            self.onCmd?(.playPause)
        }
        area.onTextClick = { [weak self] in self?.onEdit?(false) }      // tap the words: correct them; around them: play / pause
        area.isText = { [weak self] p in
            guard let self else { return false }
            let q = self.words.convert(p, from: nil)
            return self.words.inkRects.contains { $0.insetBy(dx: -6, dy: -3).contains(q) }
        }
        area.onRightClick = { [weak self] e in self?.lineMenu(e) }
        area.onScroll = { [weak self] e in self?.scrollDrum(e) ?? false }
        status.font = .systemFont(ofSize: 11); status.textColor = NSColor(white: 1, alpha: 0.5)
        status.alignment = .center; status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        skipAd.bezelStyle = .rounded; skipAd.controlSize = .small; skipAd.isHidden = true
        skipAd.toolTip = "Skip the ad in the page's player: its own Skip button when it shows one, otherwise to the ad's end"
        skipAd.target = self; skipAd.action = #selector(skipAdPressed)
        modeCtl.segmentStyle = .rounded; modeCtl.controlSize = .small
        modeCtl.selectedSegment = mode.rawValue
        modeCtl.toolTip = "Follow: the original language with its English under it.  Learn: one line at a time, on a barrel that rolls on to the next line as it comes; the original is what's coming, and each phrase turns into its English once it's been heard, so the meaning follows behind in English order. Scroll over the line to pick another and play from it.  (M)"
        modeCtl.target = self; modeCtl.action = #selector(modeChanged)
        modeCtl.alphaValue = 0
        langCtl.segmentStyle = .rounded; langCtl.controlSize = .small
        langCtl.selectedSegment = NativeLang.all.firstIndex { $0.code == NativeLang.current } ?? 0
        for (i, l) in NativeLang.all.enumerated() { langCtl.setToolTip("Native language: \(l.name)", forSegment: i) }
        langCtl.target = self; langCtl.action = #selector(langChanged)
        langCtl.alphaValue = 0
        homeBar.onCmd = { [weak self] c in self?.onCmd?(c) }
        homeBar.say = { [weak self] s in self?.toast.say(s) }
        homeBar.onAction = { [weak self] k, b in self?.barAction(k, b) }
        homeBar.isHidden = true
        toast.alphaValue = 0

        panel.contentView = root               // first: areaFoot and barFoot anchor to the panel's content view
        chord.font = .systemFont(ofSize: 15, weight: .semibold); chord.textColor = NSColor(white: 1, alpha: 0.85)
        chord.alignment = .center; chord.isHidden = true
        for v in [video, area, editor, status, skipAd, homeBar, modeCtl, langCtl, toast, chord] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        words.translatesAutoresizingMaskIntoConstraints = false; area.addSubview(words)
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: root.topAnchor, constant: 34),   // row 31: under the top row, not on the wake strip
            status.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -180),
            skipAd.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4),
            skipAd.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            modeCtl.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            modeCtl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            langCtl.centerYAnchor.constraint(equalTo: modeCtl.centerYAnchor),
            langCtl.trailingAnchor.constraint(equalTo: modeCtl.leadingAnchor, constant: -8),
            chord.topAnchor.constraint(equalTo: area.topAnchor, constant: 2),
            chord.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toast.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            toast.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toast.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toast.heightAnchor.constraint(equalToConstant: 64),
            video.topAnchor.constraint(equalTo: root.topAnchor),
            video.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            video.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            areaTop,
            area.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            area.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            areaFoot,
            editorTop, editorFoot,
            editor.leadingAnchor.constraint(equalTo: area.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            words.topAnchor.constraint(equalTo: area.topAnchor),
            wordsFoot,
            words.leadingAnchor.constraint(equalTo: area.leadingAnchor, constant: 28),
            words.trailingAnchor.constraint(equalTo: area.trailingAnchor, constant: -28),
            // the whole window, for the time ruler and the vertical bar at the right; it only takes the pointer
            // where the bar actually is
            homeBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            homeBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            barFoot,
            homeBar.topAnchor.constraint(equalTo: area.topAnchor),
        ])
        // (on-device translation has its own window: OnDevice)
        panel.onKey = { [weak self] e in self?.key(e) ?? false }
        // Inside Recense the strip starts hidden: the strip's Recense icon brings it up, so the icon's first press shows
        // it instead of hiding a panel already up at launch.
    }

    @objc func modeChanged() { setMode(Mode(rawValue: modeCtl.selectedSegment) ?? .bilingual) }
    @objc func langChanged() {
        let i = langCtl.selectedSegment
        guard NativeLang.all.indices.contains(i) else { return }
        NativeLang.set(NativeLang.all[i].code)
        fits = [:]; lastKey = ""   // re-render the current line with its trailing line in the new language
        pushBar()
    }

    // ----- the home bar's asks (homebar.js) -----
    func barAction(_ k: String, _ b: [String: Any]) {
        let num = { (n: String) in (b[n] as? NSNumber)?.doubleValue }
        switch k {
        case "lang":
            guard let v = b["v"] as? String, let i = NativeLang.all.firstIndex(where: { $0.code == v }) else { return }
            langCtl.selectedSegment = i
            langChanged()
        case "size":
            Reader.set(scale: num("v") ?? 1)
            fits = [:]; lastKey = ""
            pushBar()
        case "prominence":
            Reader.set(prominence: num("v"), a1: num("a1"), a2: num("a2"))
            fits = [:]; lastKey = ""
        case "view":   // the editor's Follow · Learn (SPEC 57)
            setMode(b["v"] as? String == "learn" ? .learning : .bilingual)
            pushBar()
        default: onBarAction?(k, b)
        }
    }

    /// The language, text size, prominence and bookmarks, sent to the bar when any of them changes.
    func pushBar(force: Bool = false) {
        let marks = bookmarks()
        let s: [String: Any] = [
            "lang": NativeLang.current, "size": Double(Reader.scale),
            "sizeMin": Reader.sizes.lowerBound, "sizeMax": Reader.sizes.upperBound,
            "prominence": Reader.prominence.map { $0.p as Any } ?? NSNull(),
            "bookmarks": marks.map { ["t": $0.t, "note": $0.note] },
            "view": mode == .learning ? "learn" : "follow",
        ]
        let sig = "\(NativeLang.current)|\(Reader.scale)|\(Reader.prominence?.p ?? -1)|\(mode.rawValue)|" + marks.map { "\($0.t)\($0.note)" }.joined(separator: ",")
        guard force || sig != barSent else { return }
        barSent = sig
        homeBar.state(s)
    }
    func setMode(_ m: Mode) {
        mode = m; modeCtl.selectedSegment = m.rawValue
        Prosody.learning = m == .learning
        drum = -1; drumHold = nil
        UserDefaults.standard.set(m.rawValue, forKey: "viewMode")
        lastKey = ""   // re-render the current line in the new mode
    }

    // ----- the mode switch shows while the pointer is over the window -----
    func hover(_ inside: Bool) {
        modeWork?.cancel()
        if inside { showMode(true); return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.showMode(false)
        }
        modeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
    }
    /// The EN · VI · FR and Follow · Learn switches no longer show on hover (SPEC 15, 57): both live in the transcript
    /// editor's tools now. The controls stay, unseen, as the state the M key and the editor change.
    func showMode(_ on: Bool) {
        modeCtl.isHidden = true; langCtl.isHidden = true
    }

    func key(_ e: NSEvent) -> Bool {
        let c = e.charactersIgnoringModifiers?.lowercased()
        if c == "m" { setMode(mode == .bilingual ? .learning : .bilingual); return true }
        if c == "e" { onEdit?(false); return true }
        guard browserControls else { return false }
        switch e.keyCode {
        case 53: return homeBar.closeTools()        // esc: fold the home bar
        case 49: onCmd?(.playPause)                 // space: pause, and again to play
        case 123: onCmd?(.skip(-10))                // ←
        case 124: onCmd?(.skip(10))                 // →
        default:
            switch c {
            case "a": homeBar.captureA()
            case "b": homeBar.captureB()
            case "l": homeBar.pressLoop()           // Track loop on / off
            case "k": onBookmark?(); return true    // bookmark this moment
            case "<", ",", "[": homeBar.speedStep(-1)
            case ">", ".", "]": homeBar.speedStep(1)
            default: return false
            }
        }
        homeBar.wake()
        return true
    }

    /// The home bar shows while a player is followed; idle, it goes. The mode switch is always there.
    @objc func skipAdPressed() { onSkipAd?() }
    func setSkipAd(_ on: Bool) { if skipAd.isHidden == on { skipAd.isHidden = !on } }

    func setControls(_ on: Bool) {
        browserControls = on
        if !on { _ = homeBar.closeTools() }
        homeBar.isHidden = !on
        if on { pushBar(force: true) }
    }

    /// The home bar hears the time 30 times a second, and at once when anything else changes: once per frame (120 Hz on
    /// this display) it kept the main thread and the page's process busy for a ruler that can't show the difference.
    private var barState: (duration: Double, paused: Bool, rate: Double, loop: LoopState, volume: Double?, at: Double)?
    func update(time: Double, duration: Double, paused: Bool, rate: Double, loop: LoopState, volume: Double? = nil) {
        guard browserControls, panel.isVisible else { return }
        let now = CACurrentMediaTime()
        if let s = barState, s.duration == duration, s.paused == paused, s.rate == rate, s.loop == loop, s.volume == volume,
           now - s.at < 1.0 / 30 {
            return pushBar()
        }
        barState = (duration, paused, rate, loop, volume, now)
        homeBar.report(time: time, duration: duration, paused: paused, rate: rate, loop: loop, volume: volume)
        pushBar()   // (only when something changed: the bookmarks of a new media, say)
    }

    // ----- correcting the line on screen -----
    /// The editor (SPEC 57): the line's own field where the lines were, and the transcript's tools (language, Follow ·
    /// Learn, Clear, Download, Share, Retranscribe, Export as MD and M4B, bookmarks) where the home bar was.
    private var editSession: (barHidden: Bool, frame: NSRect, foot: CGFloat)?
    func beginEdit(_ text: String, edited: Bool, above: [String] = [], below: [String] = [],
                   done: @escaping (LineEditor.Result) -> Void) {
        let first = editSession == nil
        if first { editSession = (homeBar.isHidden, panel.frame, wordsFoot.constant) }  // notes 19: Return restores this size
        let (barHidden, frame, foot) = editSession!
        if first {
            // the lines playing keep the band they had; the editor's pane goes under them, the window growing down
            // for it (within the screen); inside Recense's page, the pane takes what it can of the lower part
            let pane = Overlay.editorPane
            if hostedRoot == nil, let vf = (panel.screen ?? NSScreen.main)?.visibleFrame {
                let grow = min(pane, max(0, frame.minY - vf.minY))
                if grow > 0 { panel.setFrame(NSRect(x: frame.minX, y: frame.minY - grow, width: frame.width, height: frame.height + grow), display: true) }
                wordsFoot.constant = foot - (grow < pane ? max(grow, min(pane, area.bounds.height * 0.55)) : pane)
            } else { wordsFoot.constant = foot - area.bounds.height * 0.55 }
            editor.wantsLayer = true
            editor.layer?.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 0.94).cgColor
            editor.layer?.cornerRadius = 14
            lastKey = ""; fit.key = ""   // the lines fit again to their smaller band
        }
        homeBar.isHidden = false
        pushBar(force: true)
        homeBar.editor(true)
        editor.begin(text, edited: edited, size: min(26, max(400, panel.frame.width) / 38), above: above, below: below) { [weak self] r in
            guard let self else { return }
            var handled = false
            if case .move = r { done(r); handled = true; if self.editor.editing { return } }   // the barrel turned: still editing
            self.editSession = nil
            self.wordsFoot.constant = foot
            self.editor.layer?.backgroundColor = nil
            self.homeBar.editor(false)
            self.homeBar.isHidden = barHidden && !self.browserControls
            self.lastKey = ""; self.fit.key = ""
            if !handled { done(r) }   // a move past the last line was already saved and resumed
            if self.hostedRoot == nil {
                let sc = NSScreen.main
                let back = self.inStrip && sc != nil
                    ? NSRect(x: frame.minX, y: sc!.frame.maxY - Overlay.stripHeight(sc!), width: frame.width, height: Overlay.stripHeight(sc!)) : frame
                if self.panel.frame != back { self.panel.setFrame(back, display: true) }
            }
        }
    }
    func lineMenu(_ e: NSEvent) {
        guard !editor.editing, let st = lineState?() else { return }
        let m = NSMenu(); m.autoenablesItems = false
        let ed = m.addItem(withTitle: st.edited ? "Edit Correction…" : "Edit Line…", action: #selector(editFromMenu), keyEquivalent: "e")
        ed.keyEquivalentModifierMask = []; ed.target = self; ed.isEnabled = st.editable
        let rs = m.addItem(withTitle: "Reset Line to Auto", action: #selector(resetFromMenu), keyEquivalent: "")
        rs.target = self; rs.isEnabled = st.editable && st.edited
        m.addItem(.separator())
        m.addItem(withTitle: "Retranscribe…", action: #selector(retranscribeFromMenu), keyEquivalent: "").target = self
        m.addItem(withTitle: "Export Transcript…", action: #selector(exportFromMenu), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(m, with: e, for: area)
    }
    @objc func editFromMenu() { onEdit?(false) }
    @objc func resetFromMenu() { onReset?() }
    @objc func retranscribeFromMenu() { onRetranscribe?() }
    @objc func exportFromMenu() { onExport?() }
    func windowDidResignKey(_ n: Notification) { if editor.editing { editor.finish(.save(editor.field.stringValue)) } }

    // close hides instead of quitting; bring it back from the CC menu
    func windowShouldClose(_ sender: NSWindow) -> Bool { panel.orderOut(nil); onToggle?(); return false }
    func windowDidMiniaturize(_ n: Notification) { onToggle?() }
    func windowDidDeminiaturize(_ n: Notification) { onToggle?() }

    /// CC On / CC Off. The window is a non-activating panel, which macOS won't miniaturize (miniaturize did
    /// nothing, so "Minimize Subtitles" never did what it said): off hides it outright, on brings it back in place.
    @objc func toggle() {
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        else if !panel.isVisible { panel.orderFrontRegardless() }
        else { panel.orderOut(nil) }
        onToggle?()
    }

    /// Sound with no words (an instrumental, the music between verses, a room): [Ambient Sounds], the way captions
    /// say it, held for as long as the sound lasts and until the next word is spoken.
    func renderAmbient() {
        if blankCanvas() { return }
        let key = "ambient/\(Int(area.bounds.width))"
        guard key != lastKey else { return }
        lastKey = key
        let w = max(400, panel.frame.width)
        words.places = nil; words.drum = nil
        words.blocks = [[.init(top: .init(text: "[Ambient Sounds]", font: .systemFont(ofSize: min(36, w / 25), weight: .medium),
                                          color: NSColor(white: 1, alpha: 0.75)))]]
    }

    /// The vertical bar at 100%: nothing on screen at all. True while it is.
    func blankCanvas() -> Bool {
        guard Reader.blank else { return false }
        if lastKey != "blank" { words.places = nil; words.drum = nil; words.blocks = []; lastKey = "blank" }
        return true
    }

    func setStatus(_ s: String) { if status.stringValue != s { status.stringValue = s }; status.isHidden = s.isEmpty }

    /// Bilingual: the original over its English, both lit as they're spoken. No English when the speech is English.
    func render(_ line: Line?, at t: Double, upcomingOnly: Bool = false) {
        if blankCanvas() { return }
        guard let line else {
            if lastKey != "none" { words.places = nil; words.drum = nil; words.blocks = []; lastKey = "none" }
            return
        }
        let english = line.english
        let width = max(400, panel.frame.width)
        let box = area.bounds.size
        let translated = english.map { !$0.isEmpty } ?? false
        // Redraw every frame while time moves (the light is continuous); nothing to do while paused.
        let key = "\(line.id)/\(upcomingOnly ? -1 : Int((t * 1000).rounded()))/\(english?.count ?? -1)/\(Int(width))x\(Int(box.height))/r\(Reader.stamp)"
        guard key != lastKey else { return }
        lastKey = key

        let at = upcomingOnly ? -Double.infinity : t
        // A long line shrinks to fit rather than being cut off. The largest size that fits is found once per line and
        // window size, whatever Text Size is, and Text Size goes no further than it: so A⁺ only ever makes the words
        // bigger, up to what fits, and A⁻ smaller (notes 36; notes 2026-10-26: text above 100% never cut off).
        let fitKey = "\(line.id)/\(english?.count ?? -1)/\(Int(box.width))x\(Int(box.height))/r\(Reader.stamp)"
        let room = box.width - 56
        var blocks: [[WordsView.Cell]] = []
        // Text Size and Balance (menu bar menu): each line its own size and opacity; the hidden side takes no room
        let mx = Reader.mix, unit = min(36, width / 28), want = unit * Reader.scale
        let showL1 = mx.a1 > 0 || !translated, showL2 = mx.a2 > 0
        func build(_ base: CGFloat) -> Bool {
            let big = NSFont.systemFont(ofSize: base * mx.l1, weight: .semibold)
            let small = NSFont.systemFont(ofSize: base * mx.l2, weight: .regular)
            blocks = showL1 ? [sourceBeats(line).map { .init(top: dim(ink($0, at: at, font: big), translated ? mx.a1 : 1)) }] : []
            if let english, translated {
                if showL2 { blocks.append(englishBeats(line, english).map { .init(top: dim(ink($0, at: at, font: small), mx.a2)) }) }
            } else if english == nil, showL2 {
                blocks.append([.init(top: .init(text: "translating…", font: small, color: upcoming))])
            }
            let fits = blocks.joined().allSatisfy { WordsView.width($0) <= room }    // a word is never cut off at the sides
            return WordsView.height(blocks, width: room) <= box.height - 4 && fits
        }
        if fit.key == fitKey {
            _ = build(min(want, fit.scale))
        } else {
            var cap = unit * 1.6                                                     // Text Size's top (homebar sizeMax)
            while !build(cap) && cap > unit * 0.4 { cap *= 0.92 }
            fit = (fitKey, cap)
            if want < cap { _ = build(want) }
        }
        words.places = nil; words.drum = nil
        words.blocks = blocks
    }

    /// Learning: the original is lit as it's spoken, and once the light has left a phrase, the phrase turns into its
    /// English where it stands: ahead of the light is always the original (to read and say along), behind it what was
    /// just said, in English, reading in English order since a phrase turns whole. Every phrase turns the same way,
    /// the last of a line too. One line at a time (`learningLine`), on a barrel: the drum rolls on to the next line as
    /// it comes, the lines either side out of sight unless a scroll is turning it. One size for every line, set by the
    /// window; only a line too long for two rows is made smaller. Reduce Motion: no roll, the next line is just there.
    /// Learning (SPEC 59, items 27 and 33): two lines per page, the original first and the chosen language trailing it
    /// (each heard phrase turns into it in place). The lines take the two places in turn (`learningPlaces`): while the
    /// light crosses the bottom line the top one stays; when it has crossed it, the next line fades in at the top, and so
    /// on. Every line is drawn at one size, the transcript's (`uniformSize`), from its first line to its last.
    func renderLearning(_ lines: [Line], at t: Double, held: Bool) {
        if blankCanvas() { return }
        let room = words.bounds.width, tall = words.bounds.height
        guard room > 50, tall > 20 else { return }
        drumCount = 0; drum = -1                        // (the one-line barrel of §6 is retired: no drum to turn)
        let shown = learningPlaces(lines, at: t, held: held)
        guard !shown.isEmpty else {
            if lastKey != "none" { words.drum = nil; words.places = nil; words.blocks = []; lastKey = "none" }
            return
        }
        let key = "places/r\(Reader.stamp)/\(Int((t * 1000).rounded()))/" +
            shown.map { "\($0.line):\($0.place):\(Int($0.alpha * 100)):\(lines[$0.line].english?.count ?? -1)" }.joined(separator: ",") + "/\(Int(room))x\(Int(tall))"
        guard key != lastKey else { return }
        lastKey = key
        let size = uniformSize(lines, room: room, tall: tall)
        var places: [WordsView.Place?] = [nil, nil]
        for s in shown where places[s.place] == nil || places[s.place]!.alpha < CGFloat(s.alpha) {
            var p = place(lines[s.line], at: t, size: size)
            p.alpha = CGFloat(s.alpha)
            places[s.place] = p
        }
        words.drum = nil
        words.places = places
    }

    /// The transcript's one size (SPEC 59): the window's size times Text Size, made smaller only as far as the line that
    /// needs the most room needs to fit in half the window (one place), never below 55%; every line then shares it, so no
    /// line is bigger or smaller than another. Each line's need is measured once (per width, size and language).
    var needs: [String: CGFloat] = [:]
    var caps: [String: CGFloat] = [:]
    func uniformSize(_ lines: [Line], room: CGFloat, tall: CGFloat) -> CGFloat {
        let unit = min(36, max(400, panel.frame.width) / 28), base = unit * Reader.scale
        let placeH = max(20, tall / 2 - WordsView.blockGap / 2)
        if needs.count > 4000 { needs.removeAll() }
        if caps.count > 200 { caps.removeAll() }
        // how much a line would have to shrink to fit one place at `size` (1: it fits)
        func need(_ line: Line, _ size: CGFloat) -> CGFloat {
            let k = "\(line.id)/\(line.english?.count ?? -1)/\(Int(size * 10))/\(Int(room))/\(Int(placeH))/\(NativeLang.current)/\(Reader.mix.l1)/\(Reader.mix.l2)/\(Reader.prominence == nil)"
            if let n = needs[k] { return n }
            let pl = place(line, at: -1, size: size), cells = pl.cells + pl.under
            let h = WordsView.height(pl, width: room)
            let tooWide = cells.map(WordsView.width).max() ?? 0
            let n = min(1, h > 0 ? placeH / h : 1, tooWide > 0 ? room / tooWide : 1)
            needs[k] = n
            return n
        }
        // The largest size at which every line fits one place, whatever Text Size is (never below 55%): Text Size
        // magnifies up to it and no further, so A⁺ never makes the words smaller (notes 36) and the top line is never
        // cut off (notes 2026-10-26). Every line then shares the one size (SPEC 59).
        let ck = "\(lines.count)/\(lines.first?.id ?? -1)/\(lines.last?.id ?? -1)/\(lines.reduce(0) { $0 + ($1.english?.count ?? 0) })/\(Int(unit * 10))/\(Int(room))/\(Int(placeH))/\(NativeLang.current)/\(Reader.mix.l1)/\(Reader.mix.l2)/\(Reader.prominence == nil)"
        let cap: CGFloat
        if let c = caps[ck] { cap = c } else {
            let fits = { (size: CGFloat) in lines.allSatisfy { need($0, size) >= 1 } }
            var lo = unit * 0.55, hi = unit * 1.6
            if fits(hi) { lo = hi } else if fits(lo) {
                for _ in 0..<7 { let mid = (lo + hi) / 2; if fits(mid) { lo = mid } else { hi = mid } }
            }
            cap = lo
            caps[ck] = cap
        }
        return min(base, cap)
    }

    /// A scroll over the line in Learning (a wheel, two fingers on a trackpad) turns the drum row for row; when its
    /// events stop, the line in view is played from. Sideways scrolling is left alone.
    func scrollDrum(_ e: NSEvent) -> Bool {
        guard mode == .learning, !editor.editing, drumCount > 0, drum >= 0, !e.modifierFlags.contains(.control) else { return false }
        let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 16
        let dx = e.scrollingDeltaX * k, dy = e.scrollingDeltaY * k        // AppKit's signs: opposite to the web's
        guard abs(dy) > abs(dx) else { return abs(dx) == 0 && abs(dy) == 0 && drumTurning != nil }
        drum = min(max(0, drum - Double(dy / max(20, drumPitch))), Double(drumCount - 1))
        drumTurning?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.drumTurning = nil
            self.pickDrum(Int(self.drum.rounded()))
        }
        drumTurning = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: w)
        lastKey = ""
        return true
    }
    func pickDrum(_ j: Int) {
        guard drumCount > 0 else { return }
        let j = min(max(0, j), drumCount - 1)
        drumHold = (j, CACurrentMediaTime() + 0.7)
        lastKey = ""
        onPick?(j)
    }

    /// A line in one of Learning's places. At rest its phrases turn into the trailing language in place; with the vertical
    /// bar's prominence set it is Gallery's (notes 34): the original on top at its opacity, the trailing language whole
    /// under it at its own, nothing turning. Under 50% the light crosses the trailing language's phrases while the
    /// original is pronounced (SPEC 47); from 50% it crosses the original's words.
    func place(_ line: Line, at t: Double, size: CGFloat) -> WordsView.Place {
        guard let pr = Reader.prominence, let en = line.english, !en.isEmpty, en.map(\.w) != ["…"] else {
            return .init(cells: phraseCells(line, at: t, size: size), alpha: 1)
        }
        let big = NSFont.systemFont(ofSize: size, weight: .semibold), small = NSFont.systemFont(ofSize: size, weight: .regular)
        let src = sourceBeats(line), trailLit = pr.p < 0.5
        let top: [WordsView.Cell] = pr.a1 > 0 ? src.map { b in
            .init(top: dim(ink(trailLit ? Beat(text: b.text, start: b.start, end: b.start, un: b.un) : b, at: t, font: big), pr.a1))
        } : []
        var under: [WordsView.Cell] = []
        if pr.a2 > 0 {
            for p in phrases(line, en) {
                let first = src[p.src.lowerBound], last = src[p.src.upperBound - 1]
                let span = Beat(text: en[p.en].map(\.w).joined(separator: " "), start: first.start, end: last.end)
                under.append(.init(top: trailLit ? dim(ink(span, at: t, font: small, before: meaning, after: meaning), pr.a2)
                                                 : .init(text: span.text, font: small, color: meaning.withAlphaComponent(meaning.alphaComponent * pr.a2))))
            }
        }
        if top.isEmpty { return .init(cells: under, alpha: 1) }
        return .init(cells: top, alpha: 1, under: under)
    }

    /// A line in Learning: its phrases, each turning into its English as the light leaves its last word. Its English
    /// is as big as the original; the lighter weight tells it apart in the same line.
    func phraseCells(_ line: Line, at t: Double, size: CGFloat) -> [WordsView.Cell] {
        // Balance: the original and its English share a slot, each at its own size and opacity; L2 hidden, no turning
        let mx = Reader.mix
        let big = NSFont.systemFont(ofSize: size * mx.l1, weight: .semibold), small = NSFont.systemFont(ofSize: size * mx.l2, weight: .regular)
        let src = sourceBeats(line)
        guard let en = line.english, !en.isEmpty, en.map(\.w) != ["…"], mx.a2 > 0 else {     // English speech, no translation (yet), or L2 hidden
            return src.map { .init(top: ink($0, at: t, font: NSFont.systemFont(ofSize: size, weight: .semibold))) }
        }
        let parts = phrases(line, en)
        // SPEC 47, as in Gallery: prominence under 50%, the light follows the chosen language. Each phrase turns into
        // it as the original starts to be pronounced, and the light wipes across it over the time the original is
        // spoken; the original gets no wipe. 50% to 90%: the original's words, as at rest; past 90% the canvas is blank.
        if let pr = Reader.prominence, pr.p < 0.5 {
            return parts.map { p in
                let first = src[p.src.lowerBound], last = src[p.src.upperBound - 1]
                let span = Beat(text: en[p.en].map(\.w).joined(separator: " "), start: first.start, end: last.end)
                return .init(words: src[p.src].map { dim(ink(Beat(text: $0.text, start: $0.start, end: $0.start), at: t, font: big), mx.a1) },
                             turn: dim(ink(span, at: t, font: small, before: meaning, after: meaning), mx.a2),
                             turned: CGFloat(min(1, max(0, (t - first.start + turnTime) / turnTime))))
            }
        }
        return parts.map { p in
            .init(words: src[p.src].map { dim(ink($0, at: t, font: big), mx.a1) },
                  turn: .init(text: en[p.en].map(\.w).joined(separator: " "), font: small, color: meaning.withAlphaComponent(meaning.alphaComponent * mx.a2)),
                  turned: CGFloat(min(1, max(0, (t - src[p.src.upperBound - 1].end) / turnTime))))
        }
    }

    /// A word against media time, so the motion scales with playback speed on its own: it brightens just before
    /// it's spoken, a light wipes across it over exactly the time it's spoken (as the voice spends itself, Cadence), its onset flashes gold and settles
    /// (so the rhythm reads as pulses), then it eases into `after` over `fade` seconds.
    /// A word at `a` of its opacity (Balance's quieter side).
    func dim(_ k: WordsView.Ink, _ a: CGFloat) -> WordsView.Ink {
        guard a < 1 else { return k }
        var k = k
        k.color = k.color.withAlphaComponent(k.color.alphaComponent * a)
        k.lit = k.lit.map { $0.withAlphaComponent($0.alphaComponent * a) }
        k.glow *= a
        k.voice?.swell *= a
        return k
    }

    func ink(_ b: Beat, at t: Double, font: NSFont, before: NSColor? = nil, after: NSColor? = nil, fade: Double = 0.2) -> WordsView.Ink {
        var k = plainInk(b, at: t, font: font, before: before, after: after, fade: fade)
        guard !b.un, let m = Prosody.mark(b.text, b.start) else { return k }
        // the ribbon is preloaded as a ghost; the light fills it as far as the voice has gone, and across a gap from the
        // moment the word ends to the moment the next one starts, so a link fills exactly as it is sounded
        k.figure = m.line; k.tie = m.tie; k.joins = m.line.joins; k.start = b.start; k.end = b.end
        k.liaisonTail = m.tie != nil
        k.liaisonHead = Prosody.live?.marks.values.contains { $0.tie?.next == m.line.flat } ?? false
        k.drawn = t >= b.end ? 1 : t < b.start ? 0 : max(0.001, CGFloat(Cadence.progress(b, t)))
        k.tied = t < b.end ? 0 : m.next > b.end + 0.01 ? CGFloat(min(1, (t - b.end) / (m.next - b.end))) : 1
        return k
    }

    func plainInk(_ b: Beat, at t: Double, font: NSFont, before: NSColor? = nil, after: NSColor? = nil, fade: Double = 0.2) -> WordsView.Ink {
        let pale = mix(current, spoken, 0.6)
        // written but not sung (Cadence's `un`): never lit, no glow (gallery.js paintWord)
        if b.un { return .init(text: b.text, font: font, color: before ?? upcoming) }
        if t >= b.end { return .init(text: b.text, font: font, color: mix(pale, after ?? spoken, (t - b.end) / fade)) }
        if t < b.start {
            let near = max(0, 1 - (b.start - t) / 0.2)
            return .init(text: b.text, font: font, color: before ?? mix(upcoming, ahead, near))
        }
        let dur = max(0.05, b.end - b.start)
        let env = exp(-(t - b.start) / max(0.06, min(0.3, dur * 0.5)))
        return .init(text: b.text, font: font, color: before ?? ahead, lit: mix(pale, current, env),
                     wipe: CGFloat(Cadence.progress(b, t)), glow: CGFloat(env))   // steady: shaped frame by frame it flickered (item 20)
    }
}

/// The subtitles, drawn word by word: the light wipes across a word without the text being laid out again, so
/// nothing shifts while it moves. In Learning mode a heard phrase turns into its English in the same place.
final class WordsView: NSView {
    /// A word as drawn this frame: its colour, and the light's colour over the first `wipe` of it.
    struct Ink {
        var text: String, font: NSFont, color: NSColor
        var lit: NSColor? = nil, wipe: CGFloat = 0, glow: CGFloat = 0, kern: CGFloat = 0
        /// How the voice sounds under the light right now (notes 33); nil: the plain light.
        var voice: Cadence.Voice? = nil
        /// Its prosody notation (the line under the word, Gallery's prosogram) and how much of it the voice has drawn;
        /// its tie to the next word, and how far across the gap the voice has carried it. nil: no notation.
        var figure: Prosody.WordLine? = nil, drawn: CGFloat = 0, tie: Prosody.Link? = nil, tied: CGFloat = 0, joins = false
        var start: Double? = nil, end: Double? = nil      // when it is sung (for the chords placed along it)
        /// a made liaison leaves this word on its last letter / lands on this word's first: those letters turn turquoise
        /// as the light reaches them, like the tie under them
        var liaisonTail = false, liaisonHead = false
    }
    /// A run of words drawn together, and what it turns into (`turned` of the way): its slot is wide enough for
    /// either, so nothing moves, before, during or after. Learning's phrases are runs; everything else is a word to a cell.
    struct Cell {
        var words: [Ink], turn: Ink? = nil, turned: CGFloat = 0
        init(words: [Ink], turn: Ink? = nil, turned: CGFloat = 0) { self.words = words; self.turn = turn; self.turned = turned }
        init(top: Ink, turn: Ink? = nil, turned: CGFloat = 0) { self.init(words: [top], turn: turn, turned: turned) }
    }
    struct Row { var cells: [(cell: Cell, w: CGFloat)] = []; var width: CGFloat = 0 }
    /// A line in one of Learning's two places, and how far it has faded in.
    struct Place {
        var cells: [Cell]; var alpha: CGFloat
        /// the trailing language on its own row(s) under the original (the vertical bar's prominence set, notes 34)
        var under: [Cell] = []
    }
    /// How tall a place is: its rows, and the trailing language's under them.
    static func height(_ p: Place, width: CGFloat) -> CGFloat {
        let top = CGFloat(rows(p.cells, width: width).count) * rowHeight(p.cells)
        guard !p.under.isEmpty else { return top }
        return top + blockGap / 2 + CGFloat(rows(p.under, width: width).count) * rowHeight(p.under)
    }
    /// A line on Learning's drum: how far round it is from the front (radians, + below) and how far it has faded in.
    struct Roll { var cells: [Cell]; var alpha: CGFloat; var turn: CGFloat }

    /// Paragraphs, top to bottom (Bilingual: the original, then the English).
    var blocks: [[Cell]] = [] { didSet { needsDisplay = true } }
    /// Learning: the line above and the line below, drawn instead of `blocks`. The upper one sits on the middle and the
    /// lower one hangs from it, so a line that wraps grows away from the other and neither ever moves.
    var places: [Place?]? = nil { didSet { needsDisplay = true } }
    /// Learning's barrel, drawn instead of either: the lines on the drum (far ones first) and its row pitch.
    var drum: (rolls: [Roll], pitch: CGFloat)? = nil { didSet { needsDisplay = true } }
    static let blockGap: CGFloat = 10, glowColor = NSColor(red: 1, green: 0.84, blue: 0.2, alpha: 1)

    override var isFlipped: Bool { true }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    static func lineHeight(_ f: NSFont) -> CGFloat { ceil(f.ascender - f.descender + f.leading) }
    static func width(_ k: Ink) -> CGFloat { (k.text as NSString).size(withAttributes: [.font: k.font, .kern: k.kern]).width }
    static func space(_ f: NSFont) -> CGFloat { (" " as NSString).size(withAttributes: [.font: f]).width }
    /// What goes between two words: a space, none between words of Chinese, Thai or Tibetan (unspaced).
    static func sep(_ a: Ink, _ b: Ink) -> CGFloat { unspaced(a.text, b.text) || unspaced(b.text, a.text) ? 0 : space(a.font) }
    static func width(_ run: [Ink]) -> CGFloat { run.map(width).reduce(0, +) + zip(run, run.dropFirst()).map { sep($0, $1) }.reduce(0, +) }
    /// ...and between two phrases (cells) of a row
    static func gap(_ a: Cell, _ b: Cell, _ g: CGFloat) -> CGFloat {
        guard let x = a.words.last, let y = b.words.first else { return g }
        return sep(x, y) == 0 && sep(b.words.last ?? y, a.words.first ?? x) == 0 ? 0 : g
    }
    static func width(_ c: Cell) -> CGFloat { max(width(c.words), c.turn.map(width) ?? 0) }
    static func gap(_ cells: [Cell]) -> CGFloat { cells.first?.words.first.map { space($0.font) } ?? 0 }
    static func rowHeight(_ cells: [Cell]) -> CGFloat {
        guard let f = cells.first?.words.first?.font else { return 0 }
        return lineHeight(f) + (cells.contains { $0.words.contains { $0.figure != nil } } ? lane(f) : 0)
    }
    /// Room for one line of chord or note names above the ribbon, and how many lines the toggle asks for.
    static func above(_ f: NSFont) -> CGFloat {
        let m = Prosody.drawn
        return CGFloat((m.contains("c") ? 1 : 0) + (m.contains("n") ? 1 : 0)) * ceil(f.pointSize * 0.4)
    }
    /// The room under a row for its notation (the toggle's All Off: none).
    static func lane(_ f: NSFont) -> CGFloat {
        let m = Prosody.drawn
        guard !m.isEmpty else { return 0 }
        return (m.contains("p") ? ceil(f.pointSize * 1.9) : ceil(f.pointSize * 0.15)) + above(f)   // the score's lane, as Gallery's
    }
    static let liaison = NSColor(red: 64 / 255, green: 224 / 255, blue: 208 / 255, alpha: 1)   // as Gallery: ties only
    /// Where a word's notation sits at u (0…1 across it) and height h (−1…1): under its text, in the row's lane.
    static func notePoint(_ k: Ink, at p: NSPoint, u: Float, h: Float) -> CGPoint {
        let lh = lineHeight(k.font), amp = k.font.pointSize * 0.26
        return CGPoint(x: p.x + width(k) * CGFloat(u), y: p.y + lh + above(k.font) + ceil(k.font.pointSize * 0.8) * 0.45 - amp * CGFloat(max(-1, min(1, h))))
    }
    /// Chord and note names above the ribbon, under the words (item 20): the chord progression heard so far where each
    /// chord began, and each syllable's sung note; ghosted ahead of the light, full once it is reached.
    func drawNames(_ words: [(Ink, NSPoint)]) {
        guard let first = words.first?.0, words.contains(where: { $0.0.figure != nil }) else { return }
        let m = Prosody.drawn, s = first.font.pointSize, f = NSFont.systemFont(ofSize: max(9, s * 0.3), weight: .semibold)
        let step = ceil(s * 0.4), top = words[0].1.y + Self.lineHeight(first.font)
        var taken: [Int: [ClosedRange<CGFloat>]] = [:]
        func put(_ text: String, x: CGFloat, line: Int, color: NSColor, lit: Bool) {
            let t = NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: color.withAlphaComponent(lit ? 0.95 : 0.4)])
            let w = t.size().width, r = (x - w / 2 - 3)...(x + w / 2 + 3)
            if taken[line, default: []].contains(where: { $0.overlaps(r) }) { return }
            taken[line, default: []].append(r)
            t.draw(at: NSPoint(x: x - w / 2, y: top + CGFloat(line) * step))
        }
        var line = 0
        if m.contains("c") {
            // a chord at the x the light had reached when it was heard
            for ch in Prosody.chords {
                var at: CGFloat? = nil
                for (k, p) in words where k.figure != nil {
                    guard let st = k.start, let en = k.end else { continue }
                    if ch.t >= st - 0.3 && ch.t < en { at = p.x + Self.width(k) * CGFloat(max(0, min(1, (ch.t - st) / max(0.05, en - st)))) }
                }
                if let x = at { put(ch.text, x: x, line: line, color: NSColor(red: 143 / 255, green: 196 / 255, blue: 1, alpha: 1), lit: ch.t <= Prosody.now) }
            }
            line += 1
        }
        if m.contains("n") {
            for (k, p) in words {
                guard let notes = k.figure?.notes else { continue }
                for q in notes where q.count == 2 {
                    let x = p.x + Self.width(k) * CGFloat(q[0])
                    put(Prosody.noteName(q[1], lang: NativeLang.current), x: x, line: line, color: Self.sung, lit: CGFloat(q[0]) <= k.drawn)
                }
            }
        }
    }
    static let ghost = NSColor(red: 160 / 255, green: 172 / 255, blue: 190 / 255, alpha: 1)
    static let sung = NSColor(red: 236 / 255, green: 226 / 255, blue: 200 / 255, alpha: 1)
    /// The row's notation (item 20): Gallery's own prosogram (segments, glides, ties, rests, dynamics), drawn whole for
    /// this row by prosogram.js in the prosody engine, laid under the words as a 35 % ghost from the moment the line
    /// is on screen; the light sweeps through it with the words, full behind it and gold at its head.
    func drawScore(_ words: [(Ink, NSPoint)]) {
        guard !Prosody.drawn.isEmpty, let g = NSGraphicsContext.current?.cgContext else { return }
        let figs = words.filter { $0.0.figure != nil }
        guard let first = figs.first else { return }
        drawNames(words)
        guard Prosody.mode.contains("p") else { return }
        let font = first.0.font, s = font.pointSize, pad = ceil(s)
        let x0 = figs.map { $0.1.x }.min()! - pad, x1 = figs.map { $0.1.x + Self.width($0.0) }.max()! + pad
        let top = first.1.y + Self.lineHeight(font) + Self.above(font)
        guard let pic = Prosody.score(size: s, width: x1 - x0, cells: figs.map { (flat: $0.0.figure!.flat, x: $0.1.x - x0, w: Self.width($0.0)) },
                                      ready: { [weak self] in self?.needsDisplay = true }) else { return }
        let rect = NSRect(x: x0, y: top, width: x1 - x0, height: s * 1.9), img = pic.prosody
        // the score's symbols (fermatas, rests, dynamics, articulations) are lit from the start: read ahead, not as heard
        defer { pic.symbols.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
        // how far the light has gone: through a word at its progress, across a gap over the time between two words
        var light = -CGFloat.infinity
        for (i, (k, p)) in figs.enumerated() {
            let w = Self.width(k)
            if k.drawn > 0 { light = max(light, p.x + w * min(1, k.drawn)) }
            if k.drawn >= 1 {
                if i + 1 < figs.count { let nx = figs[i + 1].1.x; light = max(light, p.x + w + (nx - p.x - w) * min(1, k.tied)) }
                else { light = .infinity }
            }
        }
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.35, respectFlipped: true, hints: nil)
        pic.ties.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.35, respectFlipped: true, hints: nil)
        guard light > -.infinity else { return }
        let head = light == .infinity ? rect.maxX : light
        g.saveGState()
        g.clip(to: CGRect(x: rect.minX, y: rect.minY, width: max(0, head - rect.minX), height: rect.height))
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        // the liaison ties fill in turquoise behind the light, never touched by its gold head
        pic.ties.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        g.restoreGState()
        // a word's ties ease from turquoise into white once it is sung, as the gold does (0.45 s, as the letters)
        for (i, (k, p)) in figs.enumerated() {
            // from when the voice has sung through the tie (the next word's end), as Gallery's prosogram.js
            guard let en = (i + 1 < figs.count ? figs[i + 1].0.end : nil) ?? k.end else { continue }
            let settle = CGFloat(max(0, min(1, (Prosody.now - en) / 0.45)))
            guard settle > 0 else { continue }
            let x1 = i + 1 < figs.count ? figs[i + 1].1.x + Self.width(figs[i + 1].0) * 0.5 : rect.maxX
            g.saveGState()
            g.clip(to: CGRect(x: p.x, y: rect.minY, width: max(0, x1 - p.x), height: rect.height))
            g.beginTransparencyLayer(auxiliaryInfo: nil)
            pic.ties.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            g.setBlendMode(.sourceIn); g.setFillColor(NSColor.white.withAlphaComponent(settle).cgColor); g.fill(rect)
            g.endTransparencyLayer()
            g.restoreGState()
        }
        guard light != .infinity else { return }
        let gold = CGRect(x: head - 1.6 * s, y: rect.minY, width: 1.6 * s, height: rect.height)
        g.saveGState(); g.clip(to: gold)
        g.beginTransparencyLayer(auxiliaryInfo: nil)
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        g.setBlendMode(.sourceIn)
        let grad = CGGradient(colorsSpace: nil, colors: [Self.glowColor.withAlphaComponent(0).cgColor, Self.glowColor.cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(grad, start: CGPoint(x: gold.minX, y: 0), end: CGPoint(x: gold.maxX, y: 0), options: [])
        g.endTransparencyLayer()
        g.restoreGState()
    }

    static func rows(_ cells: [Cell], width room: CGFloat) -> [Row] {
        let gap = gap(cells)
        var out: [Row] = [], cur = Row()
        for c in cells {
            let w = width(c), g = cur.cells.last.map { Self.gap($0.cell, c, gap) } ?? 0
            if !cur.cells.isEmpty, cur.width + g + w > room { out.append(cur); cur = Row() }
            cur.width += cur.cells.isEmpty ? w : g + w; cur.cells.append((c, w))
        }
        if !cur.cells.isEmpty { out.append(cur) }
        return out
    }

    static func height(_ blocks: [[Cell]], width room: CGFloat) -> CGFloat {
        let used = blocks.filter { !$0.isEmpty }
        return used.map { b in
            let n = CGFloat(rows(b, width: room).count)
            return n * rowHeight(b)
        }.reduce(0, +) + CGFloat(max(0, used.count - 1)) * blockGap
    }

    /// Where text was drawn last frame (this view's flipped coordinates; not Learning's drum): a tap there edits the line.
    private(set) var inkRects: [NSRect] = []

    override func draw(_ dirty: NSRect) {
        inkRects = []
        if let drum {
            // Each line sits on a drum whose rows are `pitch` apart, 30° round from each other: off the front it moves
            // up or down, flattens and recedes, the way a picker's wheel does.
            let r = drum.pitch / 2 / tan(15 * .pi / 180), eye = 4 * r
            for roll in drum.rolls where roll.alpha > 0 && !roll.cells.isEmpty {
                guard let g = NSGraphicsContext.current?.cgContext else { break }
                let rows = Self.rows(roll.cells, width: bounds.width), gap = Self.gap(roll.cells), h = Self.rowHeight(roll.cells)
                let depth = eye / (eye + r * (1 - cos(roll.turn)))
                g.saveGState()
                g.translateBy(x: bounds.midX, y: bounds.height / 2 + r * sin(roll.turn) * depth)
                g.scaleBy(x: depth, y: depth * cos(roll.turn))
                g.translateBy(x: -bounds.midX, y: -CGFloat(rows.count) * h / 2)
                var y: CGFloat = 0
                Self.faded(roll.alpha) { for row in rows { draw(row, at: y, gap: gap, h: h); y += h } }
                g.restoreGState()
            }
            return
        }
        if let places {
            for (i, p) in places.enumerated() {
                guard let p, p.alpha > 0, !p.cells.isEmpty else { continue }
                let rows = Self.rows(p.cells, width: bounds.width), gap = Self.gap(p.cells), h = Self.rowHeight(p.cells)
                var y = i == 0 ? bounds.height / 2 - Self.blockGap / 2 - Self.height(p, width: bounds.width) : bounds.height / 2 + Self.blockGap / 2
                Self.faded(p.alpha) {
                    for r in rows { draw(r, at: y, gap: gap, h: h); y += h }
                    guard !p.under.isEmpty else { return }
                    y += Self.blockGap / 2
                    let uh = Self.rowHeight(p.under), ug = Self.gap(p.under)
                    for r in Self.rows(p.under, width: bounds.width) { draw(r, at: y, gap: ug, h: uh); y += uh }
                }
            }
            return
        }
        let used = blocks.filter { !$0.isEmpty }
        var y = max(0, (bounds.height - Self.height(used, width: bounds.width)) / 2)
        for (bi, b) in used.enumerated() {
            if bi > 0 { y += Self.blockGap }
            let gap = Self.gap(b), h = Self.rowHeight(b)
            for r in Self.rows(b, width: bounds.width) { draw(r, at: y, gap: gap, h: h); y += h }
        }
    }

    /// Text in a script read right to left (Persian, Arabic, Urdu, Hebrew, Syriac, Thaana, N'Ko).
    static func rtl(_ s: String) -> Bool { ["Arab", "Hebr", "Syrc", "Thaa", "Nkoo"].contains(scriptOf(text: s) ?? "") }
    /// A phrase reads right to left when most of its letters do, or it opens in Arabic and they're at least a third
    /// (an Arabic line with a name in Latin letters does, "و New York كثيرا"; an English line with one Arabic word doesn't).
    static func rtl(_ c: Cell) -> Bool {
        var r = 0, l = 0, first: Bool? = nil
        for k in c.words {
            let n = k.text.unicodeScalars.filter { $0.properties.isAlphabetic }.count
            if n > 0, first == nil { first = rtl(k.text) }
            if rtl(k.text) { r += n } else { l += n }
        }
        return r > 0 && (r >= l || (first == true && 2 * r >= l))
    }
    /// Words in the order they're seen left to right. A right-to-left phrase runs backwards, but a run of words read
    /// left to right inside it ("New York", and a number after them) keeps its own order, as the bidi algorithm lays
    /// out a line (a number after Arabic words, or a comma between them, goes with the Arabic).
    static func visual<T>(_ xs: [T], rtl: Bool, text: (T) -> String) -> [T] {
        guard rtl else { return xs }
        // each word: r (read right to left), l (left to right), n (a number), o (a mark)
        let kind: [Character] = xs.map { x in
            let t = text(x)
            if Self.rtl(t) { return "r" }
            if t.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) { return "l" }
            return t.unicodeScalars.contains(where: { $0.properties.numericType != nil }) ? "n" : "o"
        }
        var lt = [Bool](repeating: false, count: xs.count), last: Character = "r"
        for i in xs.indices {
            switch kind[i] { case "l": lt[i] = true; last = "l"; case "r": last = "r"; case "n": lt[i] = last == "l"; default: break }
        }
        for i in xs.indices where kind[i] == "o" {     // between two words read left to right, it reads with them
            let a = xs[..<i].indices.last { kind[$0] != "o" }, b = xs[(i + 1)...].indices.first { kind[$0] != "o" }
            lt[i] = a.map { lt[$0] } == true && b.map { lt[$0] } == true
        }
        var out: [T] = [], run: [T] = []
        for i in xs.indices.reversed() {
            if lt[i] { run.insert(xs[i], at: 0) } else { out += run; run = []; out.append(xs[i]) }
        }
        return out + run
    }

    /// Right-to-left words run right to left: a row of single words (the original over its English) all the way
    /// across, and inside a phrase (Learning, whose phrases stay in English reading order) its own words.
    func draw(_ r: Row, at y: CGFloat, gap: CGFloat, h: CGFloat) {
        var x = (bounds.width - r.width) / 2
        if drum == nil { inkRects.append(NSRect(x: x, y: y, width: r.width, height: h)) }
        let one = r.cells.allSatisfy { $0.cell.words.count == 1 }
        let flow = one ? Self.visual(r.cells, rtl: Self.rtl(Cell(words: r.cells.flatMap(\.cell.words))), text: { $0.cell.words[0].text }) : r.cells
        var ribbon: [(Ink, NSPoint)] = []        // the row's words in reading order, for its one ribbon
        defer { if !flow.contains(where: { Self.rtl($0.cell) }) { drawScore(ribbon) } }
        for (i, (c, w)) in flow.enumerated() {
            let rtl = Self.rtl(c)
            // A soft edge sweeps across the phrase the way the light did, the words dissolving ahead of it and their
            // translation surfacing behind it, in place (never a phrase laid over its translation, which is a blur).
            let raw = c.turn == nil ? 0 : c.turned, p = raw * raw * (3 - 2 * raw)
            let feather = min(w, 1.5 * h)                     // a soft gap between the two, moving the way the words are read
            let edge = rtl ? x + w + feather - (w + 2 * feather) * p : x - feather + (w + 2 * feather) * p
            let slot = NSRect(x: x - 24, y: y - 24, width: w + 48, height: h + 48)
            // a phrase of Chinese or Thai leans on the one it's glued to (it is as wide as its English), and its English
            // keeps a space from its neighbour's
            let before = i > 0 && Self.gap(flow[i - 1].cell, c, gap) == 0, after = i + 1 < flow.count && Self.gap(c, flow[i + 1].cell, gap) == 0
            if p < 1 {
                Self.sweep(slot, from: rtl ? edge - feather : edge, to: rtl ? edge : edge + feather, keepLeft: rtl, whole: p == 0) {
                    let slack = w - Self.width(c.words)
                    var wx = x + (before ? 0 : after ? slack : slack / 2)
                    let seen = Self.visual(c.words, rtl: rtl, text: \.text)
                    for (j, k) in seen.enumerated() {
                        let at = NSPoint(x: wx, y: y)
                        draw(k, at: at, alpha: 1)
                        if p == 0 { ribbon.append((k, at)) }     // a phrase turning into its translation takes its ribbon with it
                        wx += Self.width(k) + (j + 1 < seen.count ? Self.sep(k, seen[j + 1]) : 0)
                    }
                }
            }
            if let u = c.turn, p > 0 {
                Self.sweep(slot, from: rtl ? edge : edge - feather, to: rtl ? edge + feather : edge, keepLeft: !rtl, whole: p == 1) {
                    let apart = ((before ? 1 : 0) - (after ? 1 : 0)) * Self.space(u.font) / 2
                    draw(u, at: NSPoint(x: x + (w - Self.width(u)) / 2 + apart, y: y), alpha: 1)
                }
            }
            x += w + (i + 1 < flow.count ? Self.gap(c, flow[i + 1].cell, gap) : gap)
        }
    }

    /// Draws `body` at `alpha` as one picture (the halves of a lit word and a sweep's two sides don't show through
    /// each other).
    static func faded(_ alpha: CGFloat, _ body: () -> Void) {
        guard alpha < 1, let g = NSGraphicsContext.current?.cgContext else { return body() }
        g.saveGState(); defer { g.restoreGState() }
        g.setAlpha(alpha)
        g.beginTransparencyLayer(auxiliaryInfo: nil)
        g.setAlpha(1)
        body()
        g.endTransparencyLayer()
    }

    /// Draws `body` faded out across [x0, x1]: kept left of it or right of it (all of it when `whole`).
    static func sweep(_ r: NSRect, from x0: CGFloat, to x1: CGFloat, keepLeft: Bool, whole: Bool, _ body: () -> Void) {
        guard !whole, let g = NSGraphicsContext.current?.cgContext else { return body() }
        g.saveGState(); defer { g.restoreGState() }
        g.clip(to: r)
        g.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        g.setBlendMode(.destinationIn)
        let on = CGColor(gray: 0, alpha: 1), off = CGColor(gray: 0, alpha: 0)
        let ramp = CGGradient(colorsSpace: nil, colors: (keepLeft ? [on, off] : [off, on]) as CFArray, locations: [0, 1])!
        g.drawLinearGradient(ramp, start: CGPoint(x: x0, y: 0), end: CGPoint(x: x1, y: 0),
                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        g.endTransparencyLayer()
    }

    func draw(_ k: Ink, at p: NSPoint, alpha: CGFloat) {
        drawBody(k, at: p, alpha: alpha)
        guard k.liaisonTail || k.liaisonHead, k.drawn > 0, !Self.rtl(k.text), k.text.count > 1 else { return }
        // the liaison's letters, turquoise up to the light (gold stays the light everywhere else)
        let w = Self.width(k), ch = Array(k.text), reach = p.x + w * min(1, k.drawn), pad: CGFloat = 20
        func at(_ i: Int) -> CGFloat { p.x + (String(ch.prefix(i)) as NSString).size(withAttributes: [.font: k.font, .kern: k.kern]).width }
        var spans: [(CGFloat, CGFloat)] = []
        if k.liaisonHead { spans.append((p.x - pad, at(1))) }
        if k.liaisonTail { var i = ch.count - 1; while i > 0, !ch[i].isLetter { i -= 1 }; spans.append((at(i), at(i + 1))) }
        // once the word is sung, the turquoise eases into the word's own colour the way the gold does (0.45 s)
        let settle = k.end.map { CGFloat(max(0, min(1, (Prosody.now - $0) / 0.45))) } ?? 0
        guard settle < 1 else { return }
        let tq = Self.liaison.blended(withFraction: settle, of: k.color.withAlphaComponent(1)) ?? Self.liaison
        let a: [NSAttributedString.Key: Any] = [.font: k.font, .foregroundColor: tq.withAlphaComponent(k.color.alphaComponent > 0.3 || k.lit != nil ? 1 : 0.6), .kern: k.kern]
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        for (x0, x1) in spans where min(x1, reach) > x0 {
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: x0, y: p.y - pad, width: min(x1, reach) - x0, height: Self.lineHeight(k.font) + 2 * pad).clip()
            NSAttributedString(string: k.text, attributes: a).draw(at: p)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawBody(_ k: Ink, at p: NSPoint, alpha: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        let plain = NSAttributedString(string: k.text, attributes: [.font: k.font, .foregroundColor: k.color, .kern: k.kern])
        guard let lit = k.lit, k.wipe > 0 else { return plain.draw(at: p) }
        // Each side of the light's edge is drawn once, so no paler copy shows round the lit letters' edges. The light
        // crosses the word the way it's read.
        let w = Self.width(k), pad: CGFloat = 20, h = Self.lineHeight(k.font) + 2 * pad, rtl = Self.rtl(k.text)
        let edge = rtl ? p.x + w * (1 - min(1, k.wipe)) : p.x + w * min(1, k.wipe)
        // The voice shapes the light (notes 33): a vowel's edge flows (feathered), a consonant's is crisp; a held or
        // belted note swells it, fuller and brighter; the pitch contour lifts or bends it, vibrato makes it shiver;
        // a breathy, soft or cracking moment leaves it thin and pale.
        let v = k.voice ?? .init(), scale = k.font.pointSize / 28
        let feather = k.wipe < 1 ? (2 + 16 * v.soft) * scale : 0
        let unlitFrom = rtl ? edge + feather : edge - feather
        let unlit = rtl ? NSRect(x: p.x - pad, y: p.y - pad, width: unlitFrom - p.x + pad, height: h) : NSRect(x: unlitFrom, y: p.y - pad, width: p.x + w + pad - unlitFrom, height: h)
        let litBox = rtl ? NSRect(x: edge, y: p.y - pad, width: p.x + w - edge + pad, height: h) : NSRect(x: p.x - pad, y: p.y - pad, width: edge - p.x + pad, height: h)
        NSGraphicsContext.saveGraphicsState()
        unlit.clip()
        plain.draw(at: p)
        NSGraphicsContext.restoreGraphicsState()
        let lift: CGFloat = 0   // the light never moves with the pitch or vibrato (the owner found it shaking)
        let litAt = NSPoint(x: p.x, y: p.y - lift)
        var a: [NSAttributedString.Key: Any] = [.font: k.font, .foregroundColor: lit.withAlphaComponent(lit.alphaComponent * (1 - 0.5 * v.thin)), .kern: k.kern]
        if v.swell > 0.02 { a[.strokeWidth] = -3.2 * v.swell; a[.strokeColor] = lit }   // fuller strokes
        let shine = max(k.glow, 0.85 * v.swell) * (1 - 0.75 * v.thin)
        if shine > 0.01 {
            let g = NSShadow(); g.shadowColor = Self.glowColor.withAlphaComponent(min(0.85, 0.55 * shine + 0.25 * v.swell))
            g.shadowBlurRadius = (4 + 8 * k.glow + 12 * v.swell) * scale; g.shadowOffset = .zero
            a[.shadow] = g
        }
        let box = litBox.offsetBy(dx: 0, dy: -lift).union(litBox)
        Self.sweep(box, from: rtl ? edge + feather : edge - feather, to: edge, keepLeft: !rtl, whole: feather < 0.5) {
            NSGraphicsContext.saveGraphicsState()
            box.clip()
            NSAttributedString(string: k.text, attributes: a).draw(at: litAt)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

func mix(_ a: NSColor, _ b: NSColor, _ f: Double) -> NSColor {
    let a = a.usingColorSpace(.sRGB)!, b = b.usingColorSpace(.sRGB)!, f = CGFloat(min(1, max(0, f)))
    return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * f,
                   green: a.greenComponent + (b.greenComponent - a.greenComponent) * f,
                   blue: a.blueComponent + (b.blueComponent - a.blueComponent) * f,
                   alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * f)
}

/// A word and the stretch of media time in which it's spoken.
struct Beat { let text: String; let start: Double; let end: Double; var syl: [Syl]? = nil; var un = false; var k: Double? = nil; var c: [Double]? = nil }

func sourceBeats(_ line: Line) -> [Beat] {
    line.words.enumerated().map { i, w in
        let next = i + 1 < line.words.count ? line.words[i + 1].start : .infinity
        return Beat(text: w.text, start: w.start, end: max(w.start + 0.05, min(w.end, next)), syl: w.syl, un: w.un == true, k: w.tm.flatMap { $0.c != nil || abs($0.k) <= 0.05 && w.syl?.isEmpty == false ? nil : $0.k }, c: w.tm?.c)
    }
}

/// English words take the time of the original words they translate, whatever the language. Word order differs between the two,
/// so those times are made to run forward (pool adjacent violators), and words left sharing one moment are
/// spread evenly over the speech they came from — the light steps one word at a time and never leaps.
func englishBeats(_ line: Line, _ en: [EnWord]) -> [Beat] {
    let orig = line.words, m = orig.count, n = en.count
    guard m > 0, n > 0 else { return [] }
    var s: [Double] = [], e: [Double] = []
    for (i, w) in en.enumerated() {
        let src = sources(w, of: m)
        let idx = src.isEmpty ? [min(m - 1, Int(Double(i) * Double(m) / Double(n)))] : src
        s.append(idx.map { orig[$0].start }.min()!); e.append(idx.map { orig[$0].end }.max()!)
    }
    var blocks: [(v: Double, n: Int)] = []
    for x in s {
        blocks.append((x, 1))
        while blocks.count > 1, blocks[blocks.count - 2].v > blocks[blocks.count - 1].v {
            let b = blocks.removeLast(), a = blocks.removeLast()
            blocks.append(((a.v * Double(a.n) + b.v * Double(b.n)) / Double(a.n + b.n), a.n + b.n))
        }
    }
    var start: [Double] = [], i = 0
    for (k, b) in blocks.enumerated() {
        let next = k + 1 < blocks.count ? blocks[k + 1].v : line.end
        let spoken = e[i..<(i + b.n)].max()! - b.v
        let span = b.n == 1 ? 0 : max(0.1 * Double(b.n), min(next - b.v, spoken))
        for j in 0..<b.n { start.append(b.v + span * Double(j) / Double(b.n)) }
        i += b.n
    }
    for k in 1..<max(1, n) { start[k] = max(start[k], start[k - 1] + 0.02) }
    return (0..<n).map { k in
        let next = k + 1 < n ? start[k + 1] : .infinity
        let end = k + 1 < n ? min(next, max(start[k] + 0.08, e[k])) : max(start[k] + 0.15, line.end)
        return Beat(text: en[k].w, start: start[k], end: max(start[k] + 0.05, end))
    }
}

/// The original words an English word translates. One claiming most of a long line is a misread alignment
/// (an older build took "0,1,2,…" for one word), not a translation of it: it counts as unknown.
func sources(_ w: EnWord, of m: Int) -> [Int] {
    let s = w.s.filter { $0 >= 0 && $0 < m }
    return m > 3 && s.count > max(2, m / 2) ? [] : s
}

/// Learning mode's phrases: a run of original words and the run of English that translates it, so a heard phrase
/// can turn into its English and the line reads as English behind and the original ahead, each in its own order.
/// The models' word alignment can't place the cuts (they mostly just number the words 0 1 2 …): a phrase ends
/// where the speech pauses or a clause ends, rarely on a short word that leans on the next (le, de, il), and its
/// English is cut at the same share of the English, a little behind rather than ahead (English ahead of the
/// voice would give away what hasn't been said), never after "the" or "of". A real alignment keeps a cut from
/// parting a word from its translation.
struct Phrase { let src: Range<Int>; let en: Range<Int> }

func phrases(_ line: Line, _ en: [EnWord]) -> [Phrase] {
    let words = line.words.map(\.text), m = words.count, n = en.count
    guard m > 1, n > 1 else { return [Phrase(src: 0..<m, en: 0..<n)] }
    let s = en.map { sources($0, of: m) }
    let aligned = s.allSatisfy { !$0.isEmpty } && !s.enumerated().allSatisfy { $0.element == [$0.offset] }
    func shares(_ w: [String]) -> [Double] {
        var c = [0.0]; for x in w { c.append(c.last! + Double(x.count + 1)) }
        return c.map { $0 / c.last! }
    }
    let po = shares(words), pe = shares(en.map(\.w))
    // Where the English is cut when the original is cut before word i, and what that cut costs.
    var cut: [Int: (k: Int, cost: Double)] = [:]
    for i in 1..<m {
        var best: (k: Int, cost: Double)?
        for k in 1..<n {
            if aligned, s[..<k].contains(where: { $0.max()! >= i }) || s[k...].contains(where: { $0.min()! < i }) { continue }
            var c = abs(pe[k] - (po[i] - 0.04)) * 4 + (leansOnEnglish(en[k - 1].w) ? 0.6 : 0)
            if endsClause(words[i - 1]) && endsClause(en[k - 1].w) { c -= 0.5 }
            if best.map({ c < $0.cost }) ?? true { best = (k, c) }
        }
        guard var b = best else { continue }
        if endsClause(words[i - 1]) { b.cost -= 1.2 }
        if line.words[i].start - line.words[i - 1].end >= 0.25 { b.cost -= 0.8 }
        if leansOn(words[i - 1]) { b.cost += 0.8 }
        if !aligned { b.cost += 0.5 }     // a guessed cut can be a word out: fewer of them
        cut[i] = b
    }
    // The cheapest run of cuts, with phrases of three or four words where it can.
    let size = [0, 2, 0.5, 0, 0.1, 0.7]
    var path: [(at: Int, k: Int, cost: Double, from: Int)] = [(0, 0, 0, -1)]
    for j in cut.keys.sorted() + [m] {
        let (k, c) = j < m ? (cut[j]!.k, cut[j]!.cost) : (n, 0)
        let options = path.indices.filter { path[$0].k < k }.map { i -> (from: Int, cost: Double) in
            let len = j - path[i].at
            return (i, path[i].cost + (len < size.count ? size[len] : 0.7 + Double(len - 5)) + c)
        }
        if let o = options.min(by: { $0.cost < $1.cost }) { path.append((j, k, o.cost, o.from)) }
    }
    var out: [Phrase] = [], i = path.count - 1
    while i > 0 { let p = path[i], q = path[p.from]; out.insert(Phrase(src: q.at..<p.at, en: q.k..<p.k), at: 0); i = p.from }
    return out
}

/// A word that ends a clause: a comma, a full stop, a question mark (before any closing quote).
/// (and the stops of Chinese, Arabic and Ge'ez: ，。；：？！、 ، ؛ ؟ ። ፣ ፤ ፧)
func endsClause(_ w: String) -> Bool {
    w.trimmingCharacters(in: CharacterSet(charactersIn: "\"'»”’)」』")).last.map { ",.;:?!…，。；：？！、،؛؟።፣፤፧".contains($0) } ?? false
}
/// A short word that leans on the next one, in whatever language: le, de, il, und, a (a Chinese or Thai word is short
/// without leaning).
func leansOn(_ w: String) -> Bool { !endsClause(w) && !w.unicodeScalars.contains(where: isUnspaced) && w.filter(\.isLetter).count <= 3 }
let leaningEnglish: Set<String> = ["a", "an", "the", "of", "to", "in", "on", "at", "by", "for", "from", "with", "into", "about",
                                   "as", "and", "or", "but", "if", "than", "that", "which", "who", "whose", "this", "these",
                                   "those", "my", "your", "his", "her", "its", "our", "their", "i", "you", "he", "she", "it",
                                   "we", "they", "is", "are", "was", "were", "be", "been", "am", "do", "does", "did", "have",
                                   "has", "had", "will", "would", "shall", "should", "can", "could", "may", "might", "must", "not", "no"]
func leansOnEnglish(_ w: String) -> Bool { !endsClause(w) && leaningEnglish.contains(w.lowercased().filter { $0.isLetter || $0 == "'" }) }

/// How long a heard phrase takes to turn into its English, from the moment the light leaves its last word. The same
/// for every phrase, the last of a line too, and short: every moment of the turn is one less to read it in.
let turnTime = 0.3

/// How long a phrase's English needs on screen to be read: a moment to find it, and a little per word.
func readingTime(words n: Int) -> Double { 0.7 + 0.28 * Double(n) }

/// When a line has been read: its last phrase has turned and had its reading time (a line with nothing to turn
/// into, a moment after it's spoken).
func readBy(_ line: Line) -> Double {
    guard let en = line.english, !en.isEmpty, en.map(\.w) != ["…"], let end = sourceBeats(line).last?.end else { return line.end + 0.6 }
    let key = "\(line.id)/\(end)/" + en.map(\.w).joined(separator: " ")       // asked for every frame: phrases are found once
    if let r = readTimes[key] { return r }
    if readTimes.count > 2000 { readTimes.removeAll() }
    let r = end + turnTime + readingTime(words: phrases(line, en).last!.en.count)
    readTimes[key] = r
    return r
}
var readTimes: [String: Double] = [:]

/// Learning's two places (SPEC 59), one over the other, which the lines take in turn. The light crosses the bottom
/// line; when it has crossed it, that line stays and the next one fades in slowly at the top, where the line before it
/// was (once that one has been read); the light crosses the top line; then the next fades in at the bottom; and so on. A
/// line always arrives a moment before it is spoken. A long silence clears both; paused, the screen never clears.
/// (Gallery's gallery.js learningPlaces is the same.)
func learningPlaces(_ lines: [Line], at t: Double, held: Bool) -> [(line: Int, place: Int, alpha: Double)] {
    let n = lines.count
    guard n > 0 else { return [] }
    let lead = 0.5, fadeOut = 0.15, fadeIn = 0.4
    func opens(_ k: Int) -> Bool { k == 0 || lines[k].start - lines[k - 1].end >= 12 }
    func place(_ j: Int) -> Int { var k = j; while !opens(k) { k -= 1 }; return (j - k) % 2 }
    func clears(_ j: Int) -> Double { max(lines[j].end + 2.5, readBy(lines[j])) }
    func from(_ j: Int) -> Double {
        if opens(j) { return lines[j].start - 4 }
        if opens(j - 1) { return min(lines[j - 1].end, lines[j].start - lead) }
        let freed = readBy(lines[j - 2]), spoken = min(lines[j - 2].end, lines[j].start - fadeOut - fadeIn)
        return max(min(max(lines[j - 1].end, freed), lines[j].start - lead), spoken)
    }
    func until(_ j: Int) -> Double {
        if j + 1 == n || opens(j + 1) { return clears(j) }
        if j + 2 == n || opens(j + 2) { return clears(j + 1) }
        return from(j + 2)
    }
    var lo = 0, hi = n - 1, now = 0
    while lo <= hi { let m = (lo + hi) / 2; if lines[m].start <= t { now = m; lo = m + 1 } else { hi = m - 1 } }
    var shown: [(line: Int, place: Int, alpha: Double)] = []
    for j in max(0, now - 2)...min(n - 1, now + 2) {
        let a = min((t - from(j) - fadeOut) / fadeIn, (until(j) + fadeOut - t) / fadeOut)
        if a > 0 { shown.append((j, place(j), min(1, a))) }
    }
    if shown.isEmpty, held, t >= lines[now].start, t <= clears(now) + 3 { return [(now, place(now), 1)] }
    return shown
}

/// Learning, one line at a time (spec §6): the line in view at `t`. A line comes a moment before it's spoken, once the
/// line before it has been read, but never after its own first word.
func learningLine(_ lines: [Line], at t: Double) -> Int {
    guard !lines.isEmpty else { return 0 }
    func from(_ j: Int) -> Double { j == 0 ? -.infinity : min(lines[j].start - 0.1, max(lines[j].start - 0.5, readBy(lines[j - 1]))) }
    var j = lines.lastIndex { $0.start - 0.5 <= t } ?? 0
    while j > 0, from(j) > t { j -= 1 }
    return j
}

// ---------- browser mode: whole-episode transcription keyed to the player's own clock ----------
func decodeChunk(_ file: URL, from a: Double, to b: Double) throws -> [Float] {
    let f = try AVAudioFile(forReading: file)
    let sr = f.processingFormat.sampleRate
    let start = AVAudioFramePosition(max(0, a) * sr), end = min(f.length, AVAudioFramePosition(b * sr))
    guard end > start else { return [] }
    f.framePosition = start
    let n = AVAudioFrameCount(end - start)
    guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n) else { return [] }
    try f.read(into: buf, frameCount: n)
    let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    guard let conv = AVAudioConverter(from: f.processingFormat, to: out),
          let ob = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * 16000 / sr) + 4096)
    else { return [] }
    conv.downmix = true          // left + right; without it the converter keeps only the left channel
    var fed = false, e: NSError?
    conv.convert(to: ob, error: &e) { _, st in
        if fed { st.pointee = .endOfStream; return nil }
        fed = true; st.pointee = .haveData; return buf
    }
    if let e { throw e }
    return Array(UnsafeBufferPointer(start: ob.floatChannelData![0], count: Int(ob.frameLength)))
}

/// Splits long Whisper segments so a line fits the overlay, preferring breaks after punctuation.
func splitWords(_ w: [Word], max: Int = 14) -> [[Word]] {
    guard w.count > max else { return [w] }
    let parts = (w.count + max - 1) / max, target = w.count / parts
    var out: [[Word]] = [], cur: [Word] = []
    for (i, x) in w.enumerated() {
        cur.append(x)
        let left = w.count - i - 1
        let punct = x.text.last.map { ",.;:?!".contains($0) } ?? false
        if left > 2, out.count < parts - 1, (cur.count >= target && punct) || cur.count >= max { out.append(cur); cur = [] }
    }
    if !cur.isEmpty { out.append(cur) }
    return out
}

/// A sung phrase too long for one line, split where the singer breathes: at its longest pause (≥ 0.2 s), again
/// and again, so each line is a line of the song rather than a count of words — unpunctuated lyrics (Persian, as
/// Whisper writes it) otherwise break mid-phrase, and translate as fragments. Without such a pause, by count.
func breathSplit(_ w: [Word], max: Int = 8) -> [[Word]] {
    guard w.count > max else { return [w] }
    let k = (2..<(w.count - 1)).max { w[$0].start - w[$0 - 1].end < w[$1].start - w[$1 - 1].end }!
    guard w[k].start - w[k - 1].end >= 0.2 else { return splitWords(w, max: 12) }
    return breathSplit(Array(w[..<k]), max: max) + breathSplit(Array(w[k...]), max: max)
}

let cacheDir: URL = {
    let d = ProcessInfo.processInfo.environment["RECENSE_CACHE"].map { URL(fileURLWithPath: $0) }   // tests: a cache of their own
        ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("recense")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}()

/// Media files are keyed by address without the query (signed URLs change their tokens on every visit).
/// A page keeps the parameters that pick what plays (watch?v=…) and drops the ones that only steer the player.
func cacheKey(_ url: String, page: Bool = false) -> String {
    var base = url.split(separator: "?").first.map(String.init) ?? url
    if page, var c = URLComponents(string: url) {
        let steer: Set<String> = ["t", "start", "end", "time_continue", "autoplay", "loop", "controls", "si", "feature", "pp",
                                  "ab_channel", "index", "enablejsapi", "origin", "widgetid", "widget_referrer", "iv_load_policy",
                                  "showinfo", "title", "rel", "mute", "muted", "playsinline", "modestbranding", "fs", "cc_load_policy",
                                  "color", "disablekb", "hl", "playlist", "version", "wmode", "html5", "embeds_referring_euri",
                                  "embeds_referring_origin", "source_ve_path", "list", "forigin", "aoriginsup", "gporigin", "vf", "jsapicallback"]
        let kept = (c.queryItems ?? []).filter { !steer.contains($0.name.lowercased()) && !$0.name.lowercased().hasPrefix("utm_") }
            .sorted { $0.name < $1.name }
        c.queryItems = kept.isEmpty ? nil : kept; c.fragment = nil
        base = c.string ?? base
    }
    return SHA256.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
}

/// A file's key by its content, so the same recording is one item wherever it is (a file on this Mac, the same file in
/// Gallery's Main): cacheKey of "fp:<bytes>:<sha256 of the first 64 KiB>:<sha256 of the last 64 KiB>" (the two
/// stretches overlap, or are the whole file, when it is under 128 KiB). Gallery's Worker computes the same
/// (src/transcript.js, fingerprintKey). A transcript made before, under the address's key, is still found by that key.
enum ContentKey {
    static let span = 65_536
    @MainActor static var known: [String: String] = [:]     // address → content key, for addresses read remotely
    static func key(size: Int, head: Data, tail: Data) -> String {
        let h = { (d: Data) in SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        return cacheKey("fp:\(size):\(h(head)):\(h(tail))")
    }
    static func ofFile(_ u: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: u) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size > 0,
              (try? fh.seek(toOffset: 0)) != nil, let head = try? fh.read(upToCount: span),
              (try? fh.seek(toOffset: size > UInt64(span) ? size - UInt64(span) : 0)) != nil, let tail = try? fh.read(upToCount: span)
        else { return nil }
        return key(size: Int(size), head: head, tail: tail)
    }
    /// The content key, unless only the address's older key has a transcript on this Mac. The empty stub a failed fetch
    /// leaves (no lines, not complete) is no transcript: it held a re-uploaded Gallery file on 0 lines (notes 38).
    @MainActor static func choose(_ fp: String, legacy: String) -> String {
        let has = { (k: String) in FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent(k + ".v2.json").path) }
        guard !has(fp), has(legacy), let c = Episode.Cache.read(legacy), c.complete == true || !c.lines.isEmpty else { return fp }
        return legacy
    }
}

/// Play/pause for whatever is playing anywhere: the same system event as the keyboard's ⏯ key (as Recense's wake strip).
func recensePressPlayPause() {
    let NX_KEYTYPE_PLAY: Int32 = 16
    for down in [true, false] {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
        let data1 = Int((NX_KEYTYPE_PLAY << 16) | ((down ? 0xa : 0xb) << 8))
        NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                           context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
    }
}

func audioExt(_ type: String, _ url: String) -> String {
    let s = (type + " " + (url.split(separator: "?").first.map(String.init) ?? url)).lowercased()
    if s.contains("ogg") || s.contains("opus") { return "ogg" }
    if s.contains("wav") { return "wav" }
    if s.contains("m4a") || s.contains("mp4") || s.contains("aac") { return "m4a" }
    return "mp3"
}

// ---------- lyrics (songs) ----------
// Whisper alone can't be trusted with sung words: it mishears under instruments, invents lines, and slips into
// translating when a singer switches language. A song's published lyrics are the truth; Whisper only identifies
// which lyrics they are (with the title) and times each word (with the voice). Lyrics come from LRCLIB (free,
// no key); candidates are found by title, by artist and by the words sung, then the one that matches what was
// actually sung is chosen — a title is never trusted on its own.

/// "Artist - Title [Official Music Video].mp3" → "Artist - Title"
func cleanTitle(_ s: String) -> String {
    var t = (s as NSString).deletingPathExtension == s ? s : (s as NSString).deletingPathExtension
    for pat in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"(?i)\b(official|music|lyric|lyrics|video|audio|hd|4k|visualizer)\b"#,
                #"\s+[-|–—]\s+(YouTube|SoundCloud|Vimeo|Spotify)\s*$"#, #"\s*\|.*$"#] {
        t = t.replacingOccurrences(of: pat, with: " ", options: .regularExpression)
    }
    t = t.replacingOccurrences(of: #"\s+[-–—](\s+[-–—])+\s+"#, with: " - ", options: .regularExpression)   // "Kefaya - - Title"
    return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
}

func lrclib(_ path: String, _ q: [String: String]) async -> Any? {
    guard var c = URLComponents(string: "https://lrclib.net/api/" + path) else { return nil }
    c.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
    for attempt in 0..<5 {
        guard let u = c.url, let (d, r) = try? await URLSession.shared.data(from: u) else { return nil }
        if (r as? HTTPURLResponse)?.statusCode == 503 { try? await Task.sleep(for: .seconds(1.5 * Double(attempt + 1))); continue }  // "server busy"
        return try? JSONSerialization.jsonObject(with: d)
    }
    return nil
}

func lyricLines(_ hit: [String: Any]) -> [String]? {
    var text = hit["plainLyrics"] as? String ?? ""
    if text.isEmpty, let synced = hit["syncedLyrics"] as? String {
        text = synced.replacingOccurrences(of: #"\[[0-9:.]+\]\s?"#, with: "", options: .regularExpression)
    }
    let l = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    return l.isEmpty ? nil : l
}

/// Lyrics that could be this song: everything LRCLIB has at its length (within 10 s) for the title as shown, the
/// title as published (a site may show it translated: "lo que pasó" → "what happened"), and the artist alone.
/// Nearest length first. A podcast or lecture never matches.
func lyricsCandidates(titles: [String], duration: Double) async -> [[String]] {
    guard duration > 30, duration < 1200 else { return [] }
    var queries: [String] = []
    for t in titles.map(cleanTitle) where t.count >= 3 {
        queries.append(t)
        if let artist = t.components(separatedBy: " - ").first, artist != t, artist.count >= 2 { queries.append(artist) }
    }
    var hits: [(d: Double, lines: [String])] = [], seen = Set<String>()
    for q in NSOrderedSet(array: queries).array as! [String] {
        for h in (await lrclib("search", ["q": q]) as? [[String: Any]]) ?? [] {
            let d = abs((h["duration"] as? Double ?? 0) - duration)
            guard d <= 10, let l = lyricLines(h) else { continue }
            let sig = Episode.norm(l.prefix(6).joined(separator: " ")).joined(separator: " ")
            if seen.insert(sig).inserted { hits.append((d, l)) }
        }
    }
    return hits.sorted { $0.d < $1.d }.prefix(8).map(\.lines)
}

/// Songs whose lyrics contain these sung phrases (Genius searches lyrics text; needs GENIUS_TOKEN, free at
/// genius.com/api-clients), with their lyrics from LRCLIB. For when the title names nothing LRCLIB knows.
func lyricsBySung(_ phrases: [String], duration: Double) async -> [[String]] {
    guard !cfg.geniusToken.isEmpty else { return [] }
    var out: [[String]] = [], tried = Set<String>()
    for phrase in phrases.prefix(3) {
        guard var c = URLComponents(string: "https://api.genius.com/search") else { continue }
        c.queryItems = [URLQueryItem(name: "q", value: phrase)]
        var req = URLRequest(url: c.url!); req.setValue("Bearer \(cfg.geniusToken)", forHTTPHeaderField: "Authorization")
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let hits = (j["response"] as? [String: Any])?["hits"] as? [[String: Any]] else { continue }
        for h in hits.prefix(3) {
            guard let r = h["result"] as? [String: Any], let title = r["title"] as? String,
                  let artist = (r["primary_artist"] as? [String: Any])?["name"] as? String,
                  tried.insert("\(artist)|\(title)").inserted else { continue }
            for hit in (await lrclib("search", ["track_name": title, "artist_name": artist]) as? [[String: Any]]) ?? []
            where abs((hit["duration"] as? Double ?? 0) - duration) <= 10 {
                if let l = lyricLines(hit) { out.append(l); break }
            }
        }
    }
    if !out.isEmpty { log("genius: \(out.count) candidate(s) from the words sung") }
    return out
}

@MainActor final class Episode {
    var chunkLen = 120.0
    var url: String                    // a stream's blob: address changes on every reload or loop; its key doesn't
    let source: String                 // this address's own key
    let key: String                    // the transcript's: the source's own, or the one its recording already has
    let shift: Double                  // source time − transcript time, when the recording was heard before elsewhere
    var playDuration: Double?          // the source's own length, when it plays another source's transcript
    var identified = false, identifying = false
    var onIdentified: (() -> Void)?    // its recording turned out to have a transcript already: load that instead
    var file: URL?
    var duration = 0.0
    var lines: [Line] = [] { didSet { _shown = nil; _display = nil; _sung = nil; _blanked = nil } }   // as the pipeline made them
    var edits = Edits() { didSet { _shown = nil; _display = nil; _sung = nil; _blanked = nil } }       // the listener's corrections, over them
    /// Its translations beyond the English (vi, fr), by segment (<key>.tr.<lang>.json, keep/<key>/tr/<lang>.json).
    var native: [String: TrFile] = [:] { didSet { _display = nil; _sung = nil } }
    /// A song's voice, measured on its stem (<key>.features.json, keep/<key>/features.json): what the light follows.
    var features: Features? { didSet { _sung = nil } }
    private var _sung: [Line]?
    private var _sungLang = ""
    private var _shown: [Line]?
    private var _blanked: [ClosedRange<Double>]?
    /// Stretches the listener cleared (Corrections.blanked): [Ambient Sounds] there.
    var blanked: [ClosedRange<Double>] {
        if let b = _blanked { return b }
        let b = Corrections.blanked(applyOwnEdits(lines, edits), edits); _blanked = b
        return b
    }
    private var _display: [Line]?
    private var _displayLang = ""       // the native language _display was made in
    /// What is exported and translated: the lines with the listener's edits laid over them, with their English.
    var shown: [Line] {
        if let s = _shown { return s }
        let s = applyEdits(lines, edits); _shown = s; return s
    }
    /// What the window shows: the same lines, the trailing line in the native language where it has a translation
    /// into it (a correction of one first), else the English.
    var display: [Line] {
        let lang = NativeLang.current
        guard lang != "en" else { return shown }
        if let d = _display, _displayLang == lang { return d }
        let f = native[lang]
        let d = applyEdits(lines, edits, lang: lang) { pre, post in Keep.words(f, pre.id, [lineKey(pre), lineKey(post)]) }
        _display = d; _displayLang = lang
        return d
    }
    /// What the window draws: `display` with its words timed to the voice (Cadence) once the song's is measured.
    /// Corrections are still made to `display`'s lines (same ids), so an edit's stretch is the line as transcribed.
    var sung: [Line] {
        let lang = NativeLang.current
        if let s = _sung, _sungLang == lang { return s }
        let s = Cadence.pin(features.map { Cadence.fit(display, $0) } ?? display); _sung = s; _sungLang = lang
        return s
    }
    var done: [Bool] = []
    var failures = 0
    var tasks: [Task<Void, Never>] = []
    var stopped = false                // replaced by other media: its loops end and it never writes the cache again
    var nextId = 1_000_000
    let position: () -> Double

    let page: String?
    let referer: String?               // the page an embedded player sits in
    var title: String?                 // song/video title, for the lyrics lookup
    let music: Bool                    // played in Music: a song, lyrics or not
    var lyrics: [String] = []          // the song's lyric lines: the candidate that matches what's sung
    var lyricOptions: [[String]] = []  // every lyrics found that could be this song
    var lyricsChecked = false
    var lyricsVerified = false         // chosen by the words sung, after the first pass — not by title alone
    var language: String?              // forced on Whisper: the lyrics' only language (it can't drift into translating)
    var publishedTitle: String?        // the title as the site published it (yt-dlp), when the page shows it translated
    var redone: [[Double]] = []        // stretches transcribed again on their own (wrong language, unmatched)
    var offsite: [String] = []         // media files moved to the R2 cache (Store)
    var complete = false               // transcribed, lyrics chosen and second pass done: the audio isn't needed again
    var songPipeline = 0               // 4: vocal stem, lyrics chosen by content, language checked per phrase
    var cuts: [Int: Double] = [:]      // chunk k starts at cuts[k]

    /// A blob:/MediaSource stream has no URL of its own that lasts, so it's keyed by the page playing it.
    static func key(_ url: String, page: String?) -> String {
        if url.hasPrefix("blob:") || url.hasPrefix("mediasource:"), let page { return cacheKey(page, page: true) }
        if let k = ContentKey.known[url] { return k }
        if let u = URL(string: url), u.isFileURL, let k = ContentKey.ofFile(u) { return ContentKey.choose(k, legacy: cacheKey(url)) }
        return cacheKey(url)
    }

    init(url: String, page: String?, referer: String? = nil, title: String?, music: Bool = false, position: @escaping () -> Double) {
        self.url = url; self.page = page; self.referer = referer; self.title = title; self.music = music
        source = Episode.key(url, page: page)
        let alias = Library.resolve(source)
        key = alias?.key ?? source; shift = alias?.shift ?? 0; playDuration = alias?.d
        let shift = self.shift
        self.position = { position() - shift }
        loadAmbience()
        features = Features.read(key)
        if let c = Cache.read(key) {
            lines = c.lines; done = c.done; duration = c.duration
            lyricsChecked = c.lyricsChecked9 ?? false; lyrics = c.lyrics ?? []; heard = c.heard ?? []
            songPipeline = c.songPipeline ?? 0; lyricOptions = c.lyricOptions ?? []; lyricsVerified = c.lyricsVerified ?? false
            language = c.language; publishedTitle = c.publishedTitle; redone = c.redone ?? []; offsite = c.offsite ?? []
            engine = c.engine; lexiconSeen = c.lexicon ?? 0
            complete = (c.complete ?? false) && [0, 4].contains(c.songPipeline ?? 0)   // a newer song pipeline redoes it
            if !lyricsChecked { lyrics = []; lyricOptions = []; lyricsVerified = false; language = nil }
            // "…" means translation gave up on the line, usually only because a daily quota ran out: try again.
            for i in lines.indices where lines[i].english.map({ $0.count == 1 && $0[0].w == "…" }) == true { lines[i].english = nil }
            // Lines an older build took for English: they get their translation now.
            for i in lines.indices where lines[i].english?.isEmpty == true {
                if let l = dominantLanguage(lineKey(lines[i])), l.code != "en", l.p >= 0.6 { lines[i].english = nil }
            }
            // Words an older build showed for an instrumental ("Thank you.", "um"): never sung.
            if isSong && lyricsVerified && lyrics.isEmpty { lines = dropFillers(lines) }
            // Lined up again once with this build's rules (item 22: the unheard opening words, a split word, "Reuss"),
            // for songs finished before them; keepIds keeps the line ids, so corrections stay on their lines.
            let realigned = "recense.realigned22"
            var once = Set(UserDefaults.standard.stringArray(forKey: realigned) ?? [])
            if complete, isSong, !lyrics.isEmpty, !heard.isEmpty, !dry, !once.contains(key) {
                let before = lines.count
                lines = alignLyrics()
                once.insert(key); UserDefaults.standard.set(Array(once), forKey: realigned)
                save()
                log("lined up \(key) again with the lyrics: \(before) → \(lines.count) lines")
            }
            nextId = (lines.map(\.id).filter { $0 < 2_000_000 }.max() ?? nextId) + 1
            Library.absorb(lines)
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cacheDir.appendingPathComponent(key + ".v2.json").path)
            log("loaded cached transcript for \(url.prefix(80)): \(lines.count) lines")
        }
        if let d = try? Data(contentsOf: editsURL), var e = try? JSONDecoder().decode(Edits.self, from: d) {
            e.english = e.english.filter { $0.value.map(\.w) != ["…"] }      // given up on, as above: tried again
            edits = e
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: editsURL.path)
            if !e.edits.isEmpty { log("\(e.edits.count) edit(s) laid over the transcript") }
        }
        for lang in Keep.others {
            guard let d = try? Data(contentsOf: Keep.trURL(key, lang)), var f = try? JSONDecoder().decode(TrFile.self, from: d) else { continue }
            f.lines = f.lines.filter { $0.value.text != "…" }           // given up on, as above: tried again
            native[lang] = f
        }
        // Gallery's viewers may have corrected it in keep/ since (a replay sets `dry` before this runs, and stays off R2)
        CorrectionSync.live.add(self)
        Task { [weak self] in if let self { await CorrectionSync.pull(self) } }
    }

    var editsURL: URL { cacheDir.appendingPathComponent(key + ".edits.json") }
    func saveEdits(push: Bool = true) {
        guard !dry, let d = try? JSONEncoder().encode(edits) else { return }
        try? d.write(to: editsURL, options: .atomic)
        if push { CorrectionSync.schedule(key) }
    }

    /// A line's words as the listener timed them ([word index: Pin], transcript time): one "time" override for the
    /// line (Gallery's corrections.js `pinsOf` shape), the latest wins; none left removes the timing. `push` when settled.
    func setTiming(_ line: Line, _ pins: [Int: Pin], push: Bool) {
        let r3 = { (x: Double) in (x * 1000).rounded() / 1000 }
        let a = pins.keys.sorted().map { i -> String in
            let p = pins[i]!
            let c = p.c.map { ",[" + $0.map(fmt).joined(separator: ",") + "]" } ?? ""
            return "[\(i),\(fmt(r3(p.s))),\(fmt(r3(p.e))),\(fmt((p.k * 100).rounded() / 100))\(c)]"
        }
        let to = a.isEmpty ? "" : "[" + a.joined(separator: ",") + "]"
        var o = edits.overrides ?? []
        o.removeAll { $0.segId == String(line.id) && $0.field == "time" }
        o.append(Override(segId: String(line.id), start: line.start, end: line.end, field: "time", to: to, src: "main",
                          updatedAt: (Date().timeIntervalSince1970 * 1000).rounded()))
        edits.overrides = o
        saveEdits(push: push)
    }
    /// A number as JavaScript's JSON writes it (83.1, 84, -0.5), so Gallery's check of the override reads it the same.
    private func fmt(_ x: Double) -> String { x == x.rounded() && abs(x) < 1e15 ? String(Int(x)) : String(x) }

    /// A shown line the listener corrected, or one an edit cut short.
    static func isEdited(_ l: Line) -> Bool { l.id >= edited }

    /// The listener's correction of a shown line: its words become `text` (none: the line is hidden), timed over the
    /// words they replace. A line corrected again keeps the stretch and the automatic words of the first time.
    func correct(_ line: Line, to text: String) {
        let line = shown.first { $0.id == line.id } ?? line     // (the window's line may carry another language)
        let new = Corrections.words(text)
        let prior = line.id >= edited && line.id < edited + cutShort ? edits.edits.first { $0.id == line.id - edited } : nil
        let from = prior?.from ?? lineKey(line)
        let lang = prior?.lang ?? languagesOf(line).first
        // what the recognizer heard there (a line corrected before: the pipeline's words under that correction)
        let asr = prior.map { p in lines.flatMap(\.words).filter { w in let m = (w.start + w.end) / 2; return m >= p.a && m <= p.b } } ?? line.words
        if let prior { drop(prior) }
        guard new.joined(separator: " ") != from else { saveEdits(); return }   // back to what the pipeline had
        teach(asr, to: new, lang: lang)
        let terms = Glossary.learned(from: from, to: new)
        if let lang { Glossary.add(terms, lang: lang) }
        // this recording's glossary (shared with Gallery): each word replaced by one other, from the line as shown
        var g = edits.glossary ?? [:]
        let taught = Corrections.teach(&g, from: lineKey(line), to: new.joined(separator: " "))
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        edits.glossary = g; edits.updatedAt = now
        let words = new.isEmpty ? [] : Episode.correct(new, over: line.words)
        let id = max(edits.last ?? 0, edits.edits.map(\.id).max() ?? 0) + 1
        edits.last = id
        edits.edits.append(Edit(id: id, a: prior?.a ?? line.start, b: prior?.b ?? line.end, from: from, words: words, lang: lang, terms: terms,
                                at: now, taught: taught.isEmpty ? nil : taught))
        // Speech that was English is English still; anything else is translated like any line (Library first).
        if line.english?.isEmpty == true, !new.isEmpty { edits.english[new.joined(separator: " ")] = [] }
        saveEdits()
        log("edit \(clock(line.start)): \(from.prefix(60)) → \(new.joined(separator: " ").prefix(60))\(terms.isEmpty ? "" : " (glossary \(lang ?? "?"): \(terms.joined(separator: ", ")))")")
        wakeTranslation()
    }

    /// Back to what the pipeline made: the edit that made this line, or every edit that cut it short.
    func reset(_ line: Line) {
        guard Episode.isEdited(line) else { return }
        if line.id < edited + cutShort { if let e = edits.edits.first(where: { $0.id == line.id - edited }) { drop(e) } }
        else if let orig = lines.first(where: { $0.id == line.id - edited - cutShort }) {
            for e in edits.edits where e.a < orig.end && e.b > orig.start { drop(e) }
        }
        saveEdits()
        log("edit \(clock(line.start)) reset to the automatic transcript")
        wakeTranslation()
    }

    /// Clear (SPEC 57): every line hidden at once, each as a correction (one save, one push), so an instrumental heard
    /// as words goes blank and any line can still be brought back (Reset to Auto, or Gallery's Changes).
    func clearAll() {
        let all = shown.filter { !$0.words.isEmpty }
        guard !all.isEmpty else { return }
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        for line in all {
            let prior = line.id >= edited && line.id < edited + cutShort ? edits.edits.first { $0.id == line.id - edited } : nil
            if let prior { drop(prior) }
            let id = max(edits.last ?? 0, edits.edits.map(\.id).max() ?? 0) + 1
            edits.last = id
            edits.edits.append(Edit(id: id, a: prior?.a ?? line.start, b: prior?.b ?? line.end, from: prior?.from ?? lineKey(line), words: [],
                                    lang: prior?.lang ?? languagesOf(line).first, terms: [], at: now))
        }
        edits.updatedAt = now
        saveEdits()
        log("clear: \(all.count) lines hidden")
    }

    /// What a correction teaches the ears (Lexicon), with how it sounded there: the recording around the words.
    func teach(_ heard: [Word], to new: [String], lang: String?) {
        guard !heard.isEmpty, !dry else { return }
        let src = vocals ?? file, lo = max(0, (heard.first?.start ?? 0) - 1.8), hi = (heard.last?.end ?? 0) + 1.8, shift = self.shift, key = self.key
        Task {
            var audio: (samples: [Float], origin: Double)?
            if let src, let s = try? await Task.detached(operation: { try decodeChunk(src, from: lo + shift, to: hi + shift) }).value, !s.isEmpty {
                audio = (s, lo)
            }
            Lexicon.learn(heard, to: new, lang: lang, key: key, audio: audio)
        }
    }

    /// Gallery's viewers' corrections (overrides that just arrived) teach the ears as this window's do.
    func teach(overrides: [Override], before: Edits) {
        let base = applyOwnEdits(lines, before)
        var byId: [String: Int] = [:]
        for (i, l) in base.enumerated() where byId[String(l.id)] == nil { byId[String(l.id)] = i }
        for o in overrides where o.field == "text" {
            guard let i = Corrections.target(base, o, byId, before) else { continue }
            let l = base[i]
            teach(l.words, to: Corrections.words(o.to), lang: languagesOf(l).first)
        }
    }

    private func drop(_ e: Edit) {
        if let l = e.lang { Glossary.remove(e.terms, lang: l) }
        Lexicon.forget(key: key, a: e.a, b: e.b, lang: e.lang)
        if let t = e.taught, var g = edits.glossary {
            for (wrong, right) in t where g[wrong] == right { g[wrong] = "" }   // forgotten (kept as such, so a merge doesn't bring it back)
            edits.glossary = g; edits.updatedAt = (Date().timeIntervalSince1970 * 1000).rounded()
        }
        edits.edits.removeAll { $0.id == e.id }
    }

    struct Cache: Codable {
        let lines: [Line]; let done: [Bool]; let duration: Double
        var lyricsChecked9: Bool?; var lyrics: [String]?; var heard: [Word]?; var songPipeline: Int?
        var lyricOptions: [[String]]?; var lyricsVerified: Bool?; var language: String?; var publishedTitle: String?
        var redone: [[Double]]?; var offsite: [String]?; var complete: Bool?
        var engine: String?; var lexicon: Int?      // the ears that heard it; the lexicon version it was last checked against
        static func read(_ key: String) -> Cache? {
            (try? Data(contentsOf: cacheDir.appendingPathComponent(key + ".v2.json"))).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
        }
    }
    var dry = false                    // a replay: nothing is written
    /// Retranscribe: translated afresh (no line taken from the translations remembered from other pieces), with the
    /// language it was asked in (Gallery's selected language, or the window's) done before the other one.
    var retranslate = false, firstLang: String?
    /// While the loops run, the transcript and its translations are written every 10 s at most: a save after every
    /// batch rewrote megabytes on the main thread a few times a second (the subtitles hitched; macOS flagged the disk
    /// writes). save() and stop() write what's due at once.
    private var due: (transcript: Bool, langs: Set<String>, work: DispatchWorkItem?) = (false, [], nil)
    func saveSoon(_ lang: String? = nil) {
        if let lang { due.langs.insert(lang) } else { due.transcript = true }
        guard due.work == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.due.work = nil
                if self.due.transcript { self.save() } else { self.saveDueNative() }
            }
        }
        due.work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: w)
    }
    private func saveDueNative() {
        let langs = due.langs; due.langs = []
        for l in langs { saveNative(l) }
    }
    func save() {
        guard !stopped && !dry else { return }
        due.transcript = false; saveDueNative()
        let c = Cache(lines: lines, done: done, duration: duration, lyricsChecked9: lyricsChecked, lyrics: lyrics,
                      heard: heard, songPipeline: songPipeline, lyricOptions: lyricOptions, lyricsVerified: lyricsVerified,
                      language: language, publishedTitle: publishedTitle, redone: redone, offsite: offsite,
                      complete: complete, engine: engine, lexicon: lexiconSeen)
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: cacheDir.appendingPathComponent(key + ".v2.json")) }
        Library.flush()
    }

    var audioFile: URL? {
        try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(key + ".") && $0.pathExtension != "json" }
    }

    /// Download the audio ourselves; returns false when only the page can read it (cookies, blob: URLs).
    /// A finished transcript needs no audio, so none is fetched for it unless `audio` (an export) asks.
    func fetch(audio: Bool = false) async -> Bool {
        if let f = audioFile { return attach(f) }
        // (a spoken transcript with a stretch never asked for on its own: the audio again, to ask)
        let gaps = !isSong && duration > 0 && !unasked().isEmpty
        if complete && !audio && !gaps {
            if tasks.isEmpty && !stopped { tasks = [Task { await self.translateLoop() }] }
            // A finished transcript of a file on this Mac that the library hasn't seen: filed (reading it is free), and
            // if the recording already has a transcript from another source, that one is used from the next play.
            if let u = URL(string: url), u.isFileURL, key == source, Library.index.pieces[source] == nil,
               let d = (try? AVAudioFile(forReading: u)).map({ Double($0.length) / $0.processingFormat.sampleRate }) {
                let src = source, t = title
                Task { if let a = await Library.identify(src, file: u, duration: d, title: t, finishedOnly: true) { Library.alias(src, a) } }
            }
            return true
        }
        if let u = URL(string: url), u.isFileURL { return await local(u) }
        if let f = await Store.restore(offsite.filter { !$0.contains("-vocals") }) {
            if attach(f) { return true }
            // R2's copy doesn't decode: it was the end of the road (the episode failed with its transcript loaded). It's
            // forgotten and the audio is fetched anew below, from the page or yt-dlp.
            offsite.removeAll { $0 == f.lastPathComponent }; save()
        }
        // The transcript's own audio is gone and this source's runs at another time: it would mistime every chunk.
        if abs(shift) >= 0.05 { return false }
        if await download() { return true }
        if await fromGallery() { return true }
        if let page, await ytdlp(page) { return true }
        // An embedded player's own address may mean nothing to yt-dlp; the page it's embedded in often does.
        if let referer, referer != page, await ytdlp(referer) { return true }
        return false
    }

    /// Streams (YouTube, HLS, most video sites) have no single file to download: yt-dlp pulls the audio
    /// from the page instead.
    func ytdlp(_ page: String) async -> Bool {
        guard let u = URL(string: page), ["http", "https"].contains(u.scheme ?? ""), !isListPage(u),
              let bin = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return false }
        log("yt-dlp: \(page.prefix(120))")
        let out = cacheDir.appendingPathComponent(key).path
        // Embeds often only play for the site they're embedded in.
        let referer = self.referer.flatMap { $0 != page && $0.hasPrefix("http") ? $0 : nil }
        let (ok, published): (Bool, String) = await Task.detached {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: bin)
            // The title as published, not as the page shows it (sites translate titles: "lo que pasó" → "what happened").
            p.arguments = ["-q", "--no-playlist", "-f", "bestaudio[ext=m4a]/bestaudio/best", "-x", "--audio-format", "m4a",
                           "--no-simulate", "-O", "%(title)s",
                           "--ffmpeg-location", "/opt/homebrew/bin", "-o", out + ".%(ext)s"]
                + (referer.map { ["--referer", $0] } ?? []) + [page]
            p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return (false, "") }
            // A page that turns out to hold a whole list would otherwise download for hours.
            let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: watchdog)
            defer { watchdog.cancel() }
            let title = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return (p.terminationStatus == 0, title.trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
        if !published.isEmpty, published != "NA", published != title { publishedTitle = published }
        guard ok, let f = audioFile else { log("yt-dlp couldn't get audio"); return false }
        return attach(f)
    }

    /// YouTube pages that list videos (search results, channels, the home page): given one, yt-dlp downloads every
    /// video in it, and none of them is necessarily the one playing.
    func isListPage(_ u: URL) -> Bool {
        guard let h = u.host?.lowercased(), h == "youtube.com" || h.hasSuffix(".youtube.com") else { return false }
        let p = u.path
        return !(p == "/watch" || ["/shorts/", "/embed/", "/live/", "/v/"].contains { p.hasPrefix($0) })
    }

    func download() async -> Bool {
        guard let u = URL(string: url), ["http", "https"].contains(u.scheme ?? "") else { return false }
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: u)
            let http = resp as? HTTPURLResponse
            guard http?.statusCode == 200 else { return false }
            let dest = cacheDir.appendingPathComponent(key + "." + audioExt(http?.mimeType ?? "", url))
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return attach(dest)
        } catch { log("download failed: \(error.localizedDescription)"); return false }
    }

    /// A file playing in Gallery ("gallery:files/<path>"): fetched from Gallery's bucket, as GalleryJob does (yt-dlp
    /// on the Gallery page found no audio, so Recense had nothing to transcribe or follow).
    func fromGallery() async -> Bool {
        guard url.hasPrefix("gallery:files/"), Store.r2 else { return false }
        let path = String(url.dropFirst("gallery:".count))
        let ext = (path as NSString).pathExtension.lowercased()
        let dest = cacheDir.appendingPathComponent(key + "." + (ext.isEmpty ? "mp3" : ext))
        try? FileManager.default.removeItem(at: dest)
        // a video the window shows is downloaded once (galleryVideo): its sound is taken from that same copy
        if let v = await galleryVideo(), (try? FileManager.default.linkItem(at: v, to: dest)) != nil { return await local(dest) }
        guard let (tmp, resp) = try? await URLSession.shared.download(for: Store.signed("GET", GalleryJob.objectPath(path))),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { log("gallery: couldn't download \(path)"); return false }
        guard (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else { return false }
        return await local(dest)               // a video's sound is pulled out of it there
    }

    // ---- SPEC 70: a video in Gallery's Main is shown in the window, not only heard ----
    /// Where a shown video is kept: only the piece playing has one there (Gallery keeps them all). A folder, so
    /// Store.sweep (files only) never sends it to tmp/ or takes it while it plays.
    static let videoDir = cacheDir.appendingPathComponent("video", isDirectory: true)
    /// The video file the window shows, once downloaded (nil: no picture, audio or a site's player).
    var video: URL?
    private var videoTask: Task<URL?, Never>?
    /// A Gallery video ("gallery:files/<path>.mov|mp4|m4v|webm|mkv"): the file itself, from Gallery's bucket as
    /// fromGallery gets it, into videoDir. Asked for at load whether or not the transcript needs the audio, and only
    /// once per piece (fromGallery waits on the same download).
    func galleryVideo() async -> URL? {
        if let t = videoTask { return await t.value }
        guard url.hasPrefix("gallery:files/"), Store.r2 else { return nil }
        let path = String(url.dropFirst("gallery:".count))
        let ext = (path as NSString).pathExtension.lowercased()
        guard GalleryJob.videoExt.contains(ext) else { return nil }
        let dir = Episode.videoDir, dest = dir.appendingPathComponent(key + "." + ext)
        let t = Task<URL?, Never> {
            let fm = FileManager.default
            if !fm.fileExists(atPath: dest.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                guard let (tmp, resp) = try? await URLSession.shared.download(for: Store.signed("GET", GalleryJob.objectPath(path))),
                      (resp as? HTTPURLResponse)?.statusCode == 200 else { log("gallery: couldn't download the video \(path)"); return nil }
                try? fm.removeItem(at: dest)
                guard (try? fm.moveItem(at: tmp, to: dest)) != nil else { return nil }
            }
            return dest
        }
        videoTask = t
        let u = await t.value
        if !stopped { video = u }
        return u
    }

    func receive(_ bytes: Data, type: String) -> Bool {
        let dest = cacheDir.appendingPathComponent(key + "." + audioExt(type, url))
        do { try bytes.write(to: dest) } catch { return false }
        return attach(dest)
    }

    /// A file a native player has open: read it in place, or pull the audio out of a video into the cache.
    func local(_ u: URL) async -> Bool {
        let meta = (try? await AVURLAsset(url: u).load(.commonMetadata)) ?? []
        func tag(_ k: AVMetadataKey) async -> String? {
            guard let i = AVMetadataItem.metadataItems(from: meta, withKey: k, keySpace: .common).first else { return nil }
            return try? await i.load(.stringValue)
        }
        if let t = await tag(.commonKeyTitle) {
            // Tags come untidy ("Kefaya -"): as "Kefaya - - Title" the song looked like no song once its lyrics were ruled out.
            let artist = await tag(.commonKeyArtist).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -–—|,;:")) }.flatMap { $0.isEmpty ? nil : $0 }
            title = artist.map { t.localizedCaseInsensitiveContains($0) ? t : "\($0) - \(t)" } ?? t
        }
        else if title == nil { title = u.lastPathComponent }
        if (try? AVAudioFile(forReading: u)) != nil { return attach(u) }
        let dest = cacheDir.appendingPathComponent(key + ".m4a")
        guard let ex = AVAssetExportSession(asset: AVURLAsset(url: u), presetName: AVAssetExportPresetAppleM4A) else { return false }
        ex.outputURL = dest; ex.outputFileType = .m4a
        await ex.export()
        guard ex.status == .completed else { log("audio export failed: \(ex.error?.localizedDescription ?? "?")"); return false }
        return attach(dest)
    }

    func attach(_ f: URL) -> Bool {
        guard let af = try? AVAudioFile(forReading: f) else {
            let head = (try? FileHandle(forReadingFrom: f))?.readData(ofLength: 16) ?? Data()
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            log("can't decode \(f.lastPathComponent) (\(size) bytes, starts \(head.map { String(format: "%02x", $0) }.joined()))")
            if f.path.hasPrefix(cacheDir.path) { try? FileManager.default.removeItem(at: f) }
            return false
        }
        file = f
        duration = Double(af.length) / af.processingFormat.sampleRate
        loadAmbience(f)
        loadVoices(f)
        let n = Int((duration / chunkLen).rounded(.up))
        if done.count != n && !(complete && key != source) { done = Array(repeating: false, count: n); lines = []; heard = []; complete = false }
        if tasks.isEmpty && !stopped { tasks = [Task { await self.transcribeLoop() }, Task { await self.translateLoop() }] }
        return true
    }

    func stop() { tasks.forEach { $0.cancel() }; tasks = []; due.work?.cancel(); due.work = nil; save(); stopped = true }

    // ---- sound between the words: [Ambient Sounds] ----
    // The loudness of the audio every quarter second (dBFS + 100, 0…100), worked out once from the file and kept
    // beside the transcript (<key>.ambience), so a transcript whose audio is gone still knows where the music is.
    var ambience: [UInt8]?
    static let ambienceStep = 0.25, ambienceFloor = -50.0     // quieter than this is silence
    var ambienceURL: URL { cacheDir.appendingPathComponent(key + ".ambience") }

    func loadAmbience(_ f: URL? = nil) {
        if ambience != nil { return }
        if let d = try? Data(contentsOf: ambienceURL), !d.isEmpty { ambience = [UInt8](d); return }
        guard let f else { return }
        let out = ambienceURL
        Task.detached(priority: .utility) {
            guard let af = try? AVAudioFile(forReading: f) else { return }
            let sr = af.processingFormat.sampleRate, hop = AVAudioFrameCount(sr * 0.25)   // ambienceStep
            guard let buf = AVAudioPCMBuffer(pcmFormat: af.processingFormat, frameCapacity: hop) else { return }
            var env: [UInt8] = []
            while (try? af.read(into: buf, frameCount: hop)) != nil, buf.frameLength > 0, let ch = buf.floatChannelData {
                var ms: Float = 0
                vDSP_measqv(ch[0], 1, &ms, vDSP_Length(buf.frameLength))
                let db = 10 * log10(Double(max(ms, 1e-12)))
                env.append(UInt8(max(0, min(100, db + 100))))
            }
            try? Data(env).write(to: out)
            let done = env
            await MainActor.run { [weak self] in self?.ambience = done }
        }
    }

    /// Sound (music, a room, anything above silence) at t, give or take half a second. Unknown loudness counts as sound.
    func sounding(_ t: Double) -> Bool {
        guard let a = ambience, !a.isEmpty else { return true }
        let i = Int(t / Episode.ambienceStep), floor = UInt8(Episode.ambienceFloor + 100)
        let lo = max(0, i - 2), hi = min(a.count - 1, i + 2)
        guard lo <= hi else { return false }
        return a[lo...hi].contains { $0 > floor }
    }

    var progress: Double { done.isEmpty ? 0 : Double(done.filter { $0 }.count) / Double(done.count) }

    // ---- is a line or [Ambient Sounds] right to show here ----
    // [Ambient Sounds] says "no words here", so it needs a reason to say it: Apple's sound classifier (SoundAnalysis)
    // hears each half second once, from the file, and keeps beside the transcript (<key>.voices, 1 = a voice: speech,
    // singing, a choir…) where a voice is. Where it hears one and no line is up (words left untranscribed, a voice under
    // the music), the window holds its line or stays empty instead of claiming there are none.
    var voices: [UInt8]?
    nonisolated static let voicesStep = 0.5
    var voicesURL: URL { cacheDir.appendingPathComponent(key + ".voices") }

    func loadVoices(_ f: URL) {
        if voices != nil { return }
        if let d = try? Data(contentsOf: voicesURL), !d.isEmpty { voices = [UInt8](d); return }
        let out = voicesURL
        Task.detached(priority: .utility) {
            guard let az = try? SNAudioFileAnalyzer(url: f), let rq = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return }
            rq.windowDuration = CMTime(seconds: 1, preferredTimescale: 1000)
            rq.overlapFactor = 0.5
            let ob = VoiceObserver()
            guard (try? az.add(rq, withObserver: ob)) != nil else { return }
            _ = await az.analyze()
            let env = ob.env
            guard !env.isEmpty else { return }
            try? Data(env).write(to: out)
            await MainActor.run { [weak self] in self?.voices = env }
        }
    }

    /// A voice at t, give or take half a second; nil: not heard yet.
    func voiced(_ t: Double) -> Bool? {
        guard let v = voices, !v.isEmpty else { return nil }
        let i = Int(t / Episode.voicesStep), lo = max(0, i - 1), hi = min(v.count - 1, i + 1)
        guard lo <= hi else { return false }
        return v[lo...hi].contains(1)
    }

    /// A line whose words the picture already shows (a screen recording of a transcript, burned-in captions): it stays
    /// heard, editable and exported, but nothing is laid over the words already there. Vision reads the frame in the
    /// line's middle once per line; until it has, the line shows.
    var inPicture: [Int: Bool] = [:]
    lazy var pictureURL: URL? = {
        guard let u = URL(string: url), u.isFileURL else { return nil }
        return ["mov", "mp4", "m4v", "mkv", "webm", "avi"].contains(u.pathExtension.lowercased()) ? u : nil
    }()

    func shownInPicture(_ l: Line) -> Bool {
        if let b = inPicture[l.id] { return b }
        guard let u = pictureURL, l.words.count >= 2 else { inPicture[l.id] = false; return false }
        inPicture[l.id] = false                                   // asked once; the answer replaces it
        let at = (l.start + l.end) / 2 + shift, id = l.id
        let want = Set(l.words.map { Episode.bare($0.text) }.filter { $0.count > 1 })
        guard want.count >= 2 else { return false }
        Task.detached(priority: .utility) {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: u))
            g.appliesPreferredTrackTransform = true
            g.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
            g.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
            guard let cg = try? await g.image(at: CMTime(seconds: at, preferredTimescale: 600)).image else { return }
            let rq = VNRecognizeTextRequest()
            rq.recognitionLevel = .accurate; rq.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: cg).perform([rq])
            let seen = Set((rq.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .flatMap { $0.split(whereSeparator: { $0.isWhitespace }) }.map { Episode.bare(String($0)) })
            // most of the line's words on screen at the moment it's said: the picture already says it
            let shown = Double(want.intersection(seen).count) / Double(want.count) >= 0.6
            await MainActor.run { [weak self] in
                self?.inPicture[id] = shown
                if shown { log("line \(id) already in the picture: no overlay over it") }
            }
        }
        return false
    }

    nonisolated static func bare(_ w: String) -> String {
        w.lowercased().folding(options: [.diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    /// Kept in Gallery's Music folder: music whatever its title says (Battaglia.mp3, an 18-minute sutra), never a lecture.
    var inMusicFolder: Bool { url.hasPrefix("gallery:files/Music/") }

    /// Lyrics found, played in Music, kept in Music, a music-video title, or "Artist - Title" at song length.
    var isSong: Bool {
        let t = cleanTitle(title ?? "")
        // Once transcribed as a song (its voice alone, against lyrics), it stays one: ruling out the wrong lyrics
        // mustn't skip the second pass, or leave the words heard so far out of the lines.
        return !lyrics.isEmpty || music || inMusicFolder || songPipeline == 4 || (looksLikeMusic(title ?? "") && duration < 900)
            || (duration > 60 && duration < 480 && t.range(of: #"^[^-–—|]{2,40} [-–—] [^-–—|]{2,80}$"#, options: .regularExpression) != nil)
    }

    /// What's keeping lines untranslated, for the window's status line: a pair of languages Apple's Translation
    /// has but this Mac hasn't downloaded (its download sheet can't show from Recense's hidden sessions).
    var limitStatus: String? {
        guard #available(macOS 15.0, *), Models.pick() == nil, let pair = OnDevice.shared.missing.sorted().first,
              lines.contains(where: { $0.english?.first?.w == "…" }) else { return nil }
        let p = pair.split(separator: ">").map { languageName(String($0)) }
        return "To translate \(p[0]) to \(p.last ?? ""): System Settings › General › Language & Region › Translation Languages"
    }

    // Transcribe the chunk being played first, then onward, then anything earlier.
    func transcribeLoop() async {
        // Before anything is spent: has this recording been heard before, from another source? A transcript begun
        // before the library existed is filed too, and dropped for a finished one of the same recording.
        if !identified, key == source, Library.index.pieces[source] == nil, let f = file {
            identified = true; identifying = true
            let fresh = !done.contains(true) && lines.isEmpty && heard.isEmpty
            let a = await Library.identify(source, file: f, duration: duration, title: title)
            identifying = false
            // A finished transcript beats finishing a second one; a half-made one only takes over a fresh start.
            if let a, !stopped, fresh || Cache.read(a.key)?.complete == true {
                Library.alias(source, a)
                // This source's own download: the transcript's audio when it's the very same, else not needed.
                if f.path.hasPrefix(cacheDir.path) {
                    let dest = cacheDir.appendingPathComponent(a.key + "." + f.pathExtension)
                    let canonHas = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path))?
                        .contains { $0.hasPrefix(a.key + ".") && !$0.hasSuffix(".json") } ?? false
                    if abs(a.shift) < 0.05 && !canonHas { try? FileManager.default.moveItem(at: f, to: dest) }
                    else { try? FileManager.default.removeItem(at: f) }
                }
                stopped = true                   // its own (empty) transcript is never written
                onIdentified?()
                return
            }
        }
        while !Task.isCancelled && !stopped {
            if !lyricsChecked { await checkLyrics(); continue }
            // A song is transcribed from its isolated voice and timed against its lyrics; a transcript of it made
            // any other way (older versions, the full mix) is done again.
            if isSong && songPipeline != 4 {
                songPipeline = 4
                lines = []; heard = []; redone = []; complete = false; done = done.map { _ in false }
            }
            // Finished before (a replay whose audio is still here): nothing to separate or transcribe again.
            // (a spoken transcript with a stretch Whisper skipped gets that stretch asked for again, once).
            if complete && !done.isEmpty && !done.contains(false) {
                await relisten()
                if isSong { save(); await measureVoice(); return }
                guard let src = file, let h = await skipped(src) else { save(); await measureVoice(); return }
                await fill(h, src: src); try? await Task.sleep(for: .seconds(pace)); continue
            }
            if isSong && vocals == nil && !vocalsTried { vocalsTried = true; await separateVocals(); continue }
            let p = min(Int(max(0, position()) / chunkLen), done.count)
            let order = Array(p..<done.count) + Array(0..<min(p, done.count))
            guard let src = vocals ?? file else { save(); return }
            guard let i = order.first(where: { !done[$0] }) else {
                // Second pass, songs only: pick the lyrics by what was sung, then transcribe again, on its own, each
                // phrase that came out in the wrong language or matches nothing.
                if !isSong, !done.isEmpty, let h = await skipped(src) {
                    await fill(h, src: src); try? await Task.sleep(for: .seconds(pace)); continue
                }
                guard isSong, !done.isEmpty else { complete = !done.isEmpty; save(); if complete { await measureVoice() }; return }
                if !lyricsVerified { await verifyLyrics(); continue }
                guard !instrumental, let w = suspects().first else { complete = true; save(); await measureVoice(); return }
                await redo(w, src: src)
                try? await Task.sleep(for: .seconds(pace))
                continue
            }
            let a = await cut(i), b = await cut(i + 1)
            // A few seconds either side: Whisper drops the first seconds of a request that opens mid-speech, and
            // the last of one that ends mid-sentence; only words starting in a..<b are kept, so none come twice.
            var lo = max(0, a - 3)
            let hi = min(duration, b + 3)
            do {
                var samples = try await Task.detached { try decodeChunk(src, from: lo, to: hi) }.value
                // Whisper decides a request's language from its first 30 s. On a vocal stem an intro is silence, and
                // silence reads as English: the Dari verse after it came back translated. So the request starts
                // with the voice.
                if vocals != nil, let v = Episode.voiceOnset(samples), v > 3 {
                    let drop = Int((v - 1) * 16000)
                    samples.removeFirst(drop); lo += Double(drop) / 16000
                }
                // On a clean vocal a lyrics prompt only makes Whisper write lyrics where nothing is sung.
                let t = try await whisper(samples, lo, hi, prompt: vocals == nil ? lyricPrompt(lo, hi) : nil,
                                          language: isSong ? language : nil, keep: [a, b.isFinite ? b : duration + 1])
                guard !stopped, i < done.count else { return }
                add(t, samples: samples, offset: lo, keep: a..<b)
                done[i] = true; failures = 0
                log("episode chunk \(i + 1)/\(done.count) transcribed")
                save()
            } catch {
                failures += 1
                log("chunk \(i) error: \(error.localizedDescription)")
                try? await Task.sleep(for: .seconds(min(30, 3 * failures)))
            }
            try? await Task.sleep(for: .seconds(pace))
        }
    }

    /// One Whisper request for lo–hi of the song. With RECENSE_RAW set, every reply is also kept, as Whisper sent it,
    /// in <cache>/<key>.raw.json: a track's transcription studied (and replayed) offline, without spending quota again.
    /// `keep` is a first-pass chunk's own stretch, `redo` the suspect stretch a second-pass request is for.
    /// Without a prompt of its own, a request is prompted with the glossary of the language it's in.
    func whisper(_ samples: [Float], _ lo: Double, _ hi: Double, prompt: String? = nil, language: String?,
                 keep: [Double]? = nil, redo: [Double]? = nil) async throws -> [String: Any] {
        if let captured {      // a replay: the reply Whisper gave this very request, if it was ever made
            guard let e = captured.last(where: { e in
                (e["language"] as? String ?? "") == (language ?? "") && abs((e["from"] as? Double ?? -9) - lo) < 0.05
                    && abs((e["to"] as? Double ?? -9) - hi) < 0.05 }), let t = e["reply"] as? [String: Any]
            else { missed.append(String(format: "%.2f–%.2f [%@]", lo, hi, language ?? "auto")); throw err("not captured") }
            return t
        }
        // This Mac's own ears, always: no quota, no connection. Apple's for every language they have, the open ears
        // (Omnilingual, on this Mac) for every other and to tell which language it is, the canon for recited texts
        // (speech.swift). Never Groq (since 2026-10-30).
        guard OnDeviceASR.enabled else { throw err("this Mac can't transcribe: Recense needs macOS 26 and Recense built with its SDK") }
        // A stretch asked again (a few seconds a line was misheard in) is too short to tell its language by: it's
        // heard as the song is sung, and what it's heard as doesn't become the song's language
        guard let t = try await OnDeviceASR.transcribe(samples, language: language, languages: hearing(),
                                                         prefer: redo != nil ? songLanguages().first ?? spokenLanguage : spokenLanguage) else {
            throw err("this Mac can't hear \(language.map(languageName) ?? "this language") yet: the open ears aren't installed (~/.local/share/recense/omni)")
        }
        if redo == nil, let l = (t["language"] as? String).flatMap(languageCode) { spokenLanguage = l }
        engine = t["engine"] as? String
        if ProcessInfo.processInfo.environment["RECENSE_RAW"] != nil {
            let f = cacheDir.appendingPathComponent(key + ".raw.json")
            var all = (try? Data(contentsOf: f)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            var e: [String: Any] = ["from": lo, "to": hi, "language": language ?? "", "stem": vocals != nil, "reply": t]
            e["keep"] = keep; e["redo"] = redo
            all.append(e)
            if let d = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: f) }
        }
        return t
    }

    var spokenLanguage: String?        // the language Whisper heard last: the glossary a request without a language gets
    var engine: String?                // the ears that heard it last (OnDeviceASR's module)
    var lexiconSeen = 0                // the lexicon version its lines were last checked against (relisten)

    /// The languages this recording may be in, for ears that must be told: the one it's in when known, the reader's
    /// own, then every language Recense translates between.
    func hearing() -> [String] {
        var out: [String] = []
        let all: [String?] = [language, languageCode(cfg.language), NativeLang.current] + NativeLang.all.map { $0.code }
        for l in all { if let l, !out.contains(l) { out.append(l) } }
        return out
    }

    /// A finished transcript, played again: where a lesson taught since (Lexicon) has its mistake in a line, that line
    /// is heard against it once more, and translated again if it changed. Speech only: a song's lines follow its lyrics.
    func relisten() async {
        guard !isSong, lexiconSeen != Lexicon.version, !dry, let src = vocals ?? file else { return }
        let seen = Lexicon.version
        var changed = 0
        for i in lines.indices where Lexicon.mayApply(lines[i].words) {
            let l = lines[i], lo = max(0, l.start - 1.8)
            guard let s = try? await Task.detached(operation: { try decodeChunk(src, from: lo, to: l.end + 1.8) }).value, !stopped, i < lines.count,
                  lines[i].id == l.id else { continue }
            let ws = Lexicon.recall(l.words, samples: s, origin: lo, key: key)
            guard ws.map(\.text) != l.words.map(\.text) else { continue }
            lines[i] = Line(id: l.id, words: ws, english: l.english?.isEmpty == true ? [] : nil)
            changed += 1
        }
        lexiconSeen = seen
        if changed > 0 { log("relisten: \(changed) line(s) of \(key) rewritten by the lexicon"); save(); wakeTranslation() }
    }
    var captured: [[String: Any]]?     // a replay's captured Whisper replies (RECENSE_RAW), served instead of asking the ears
    var missed: [String] = []          // a replay's requests that were never captured
    var pace = 0.05                    // seconds between requests; none in a replay

    /// Where the voice starts in 16 kHz stem audio (seconds), if anywhere: the first moment with voice in most of
    /// the second after it.
    nonisolated static func voiceOnset(_ samples: [Float]) -> Double? {
        let db = frameDB(samples), sorted = db.sorted()
        guard sorted.count > 200 else { return nil }
        let thr = max(sorted[sorted.count / 10] + 12, sorted[sorted.count * 95 / 100] - 30)
        var n = db.prefix(100).filter { $0 >= thr }.count
        for i in 0..<(db.count - 100) {
            if n >= 60 { return Double(i) / 100 }
            n += (db[i + 100] >= thr ? 1 : 0) - (db[i] >= thr ? 1 : 0)
        }
        return nil
    }

    /// Chunk k starts at the quietest 300 ms within 6 s of k × chunkLen, so no word is cut in two. Both
    /// neighbouring chunks use the same cut, so every word lands in exactly one of them — none twice, none lost.
    func cut(_ k: Int) async -> Double {
        if k <= 0 { return 0 }
        if k >= done.count { return .infinity }
        if let c = cuts[k] { return c }
        let nominal = Double(k) * chunkLen
        var best = nominal
        if let src = vocals ?? file,
           let s = try? await Task.detached(operation: { try decodeChunk(src, from: nominal - 6, to: nominal + 6) }).value {
            let db = frameDB(s)
            if db.count > 60 {
                var sum = db[0..<30].reduce(0, +), low = sum, at = 0
                for i in 30..<db.count {
                    sum += db[i] - db[i - 30]
                    if sum < low { low = sum; at = i - 29 }
                }
                best = nominal - 6 + Double(at + 15) / 100
            }
        }
        cuts[k] = best
        return best
    }

    var vocals: URL?                   // a song's voice alone (Demucs): what Whisper hears instead of the mix
    var vocalsTried = false
    var separating = false

    /// A song's voice measured (Features) for the light to follow: keep/'s copy when there is one, else measured on its
    /// vocal stem — this Mac's, R2's while it lasts, or separated again from the audio here. Never from the mix: its
    /// loudness is the band's.
    func measureVoice() async {
        guard features == nil, !instrumental, !stopped, !dry else { return }
        if let (d, _) = await Keep.get(Keep.features(key)), let f = try? JSONDecoder().decode(Features.self, from: d) {
            try? d.write(to: Features.url(key)); features = f; return
        }
        guard isSong else { return await measureSpeech() }
        if vocals == nil, let f = await Store.restore(offsite.filter { $0.contains("-vocals") }) { vocals = f }
        if vocals == nil, file != nil, !vocalsTried { vocalsTried = true; await separateVocals() }
        guard let stem = vocals, !stopped else { return }
        let length = duration + 1, t0 = Date()
        let f: Features? = await Task.detached(priority: .utility) {
            guard let s = try? decodeChunk(stem, from: 0, to: length), !s.isEmpty else { return nil }
            return Features.measure(s, source: "vocals")
        }.value
        guard let f, !stopped else { return }
        f.write(key); features = f
        log(String(format: "measured the voice of %@ in %.1f s", key, Date().timeIntervalSince(t0)))
        await Keep.pushFeatures(key)
    }

    /// Speech (not a song) measured on its own sound, the mix being the voice: features.json with source "speech", for
    /// the prosody notation under the words (Gallery's prosogram draws it as speech; the light and Cadence only take a
    /// song's "vocals"). Read 5 minutes at a time, so an hour's lecture never holds its whole decoded audio (row 21).
    static let speechLimit = 5400.0
    func measureSpeech() async {
        guard let src = file, duration > 0, duration <= Episode.speechLimit, !stopped else { return }
        let length = duration + 1, t0 = Date()
        let f: Features? = await Task.detached(priority: .utility) {
            var s: [Float] = []
            var a = 0.0
            while a < length {
                guard let c = try? decodeChunk(src, from: a, to: min(length, a + 300)) else { return nil }
                s += c; a += 300
                if c.isEmpty { break }
            }
            return s.isEmpty ? nil : Features.measure(s, source: "speech")
        }.value
        guard let f, !stopped else { return }
        f.write(key); features = f
        log(String(format: "measured the speech of %@ in %.1f s", key, Date().timeIntervalSince(t0)))
        await Keep.pushFeatures(key)
    }

    /// Strips the instruments so Whisper hears only the singing (≈45 s for a 4-minute song on the GPU).
    func separateVocals() async {
        let out = cacheDir.appendingPathComponent(key + "-vocals.wav")
        if FileManager.default.fileExists(atPath: out.path) { vocals = out; return }
        if let f = await Store.restore(offsite.filter { $0.contains("-vocals") }) { vocals = f; return }
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/recense/demucs/bin/demucs").path
        guard let file, FileManager.default.isExecutableFile(atPath: bin) else { log("demucs not installed — transcribing the full mix"); return }
        separating = true; defer { separating = false }
        log("separating vocals")
        let t0 = Date()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("recense-stems-" + key)
        let ok: Bool = await Task.detached {
            for device in ["mps", "cpu"] {                    // the GPU, else the CPU if an op isn't supported there
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = ["-n", "htdemucs", "--two-stems=vocals", "-d", device, "-o", tmp.path,
                               "--filename", "{stem}.{ext}", file.path]
                // Demucs reads anything but WAV through ffmpeg, which a launchd app's PATH (/usr/bin:/bin) doesn't
                // reach: every m4a, mp3 and flac failed here ("FFmpeg is not installed") until 2026-10-30.
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
                p.environment = env
                let err = Pipe()
                p.standardOutput = FileHandle.nullDevice; p.standardError = err
                do { try p.run() } catch { return false }
                let said = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 { return true }
                let last = String(decoding: said, as: UTF8.self).split(separator: "\n").last { !$0.contains("%|") } ?? ""
                log("demucs (\(device)) failed: \(last.prefix(200))")
            }
            return false
        }.value
        let made = tmp.appendingPathComponent("htdemucs/vocals.wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Whisper and the loudness gate only ever read 16 kHz mono: kept at that, the stem is a tenth of the size.
        let length = duration + 1
        let small: Bool = ok ? await Task.detached {
            guard let s = try? decodeChunk(made, from: 0, to: length), !s.isEmpty else { return false }
            return (try? wav(s, sr: 16000).write(to: out)) != nil
        }.value : false
        guard small else { log("vocal separation failed — transcribing the full mix"); return }
        vocals = out
        cuts = [:]                                            // cut on the voice's own pauses
        log("vocals separated in \(Int(Date().timeIntervalSince(t0))) s")
    }

    func checkLyrics() async {
        lyricsChecked = true
        let titles = Array(NSOrderedSet(array: [title, publishedTitle].compactMap { $0 }).array as! [String])
        log("looking up lyrics: \(titles.map(cleanTitle).joined(separator: " / "))")
        lyricOptions = await lyricsCandidates(titles: titles, duration: duration)
        lyrics = lyricOptions.first ?? []           // the nearest in length, until the singing picks one
        lyricsVerified = false
        // Whisper is held to the lyrics' language only when every candidate agrees on one: a long piece otherwise
        // drifts into translating ("Il mondo brucia" came out in English from 0:55).
        // Nor to a language read from Arabic-script lyrics: the spelling can't say which (Persian reads as Arabic or Urdu),
        // and Whisper held to the wrong one writes nonsense.
        let only = Set(lyricOptions.map { Episode.onlyLanguage($0) ?? "?" })
        language = only.count == 1 && only.first != "?" && spellingTells(only.first!) ? only.first : nil
        if lyricOptions.isEmpty { log("no lyrics found yet (\(Int(duration)) s): choosing by the words sung after the first pass") }
        else { log("lyrics: \(lyricOptions.count) candidate(s), language \(language ?? "mixed/unsure")") }
    }

    /// After the first pass: the lyrics are the candidate that best matches what was sung — or, when none does,
    /// songs found by the words sung themselves. Below 35 % of heard words landing in lyric lines, none is this song.
    func verifyLyrics() async {
        var options = lyricOptions
        func best() -> (score: Double, lyrics: [String]) {
            options.map { (matchScore($0), $0) }.max { $0.0 < $1.0 } ?? (0, [])
        }
        var b = best()
        if b.score < 0.35 {
            let found = await lyricsBySung(confidentPhrases(), duration: duration)
            options += found; lyricOptions = options
            b = best()
        }
        lyricsVerified = true
        lyrics = b.score >= 0.35 ? b.lyrics : []
        log(lyrics.isEmpty ? "no lyrics match what's sung (best \(Int(b.score * 100)) %): showing what was heard"
                           : "lyrics chosen by what's sung: \(Int(b.score * 100)) % of heard words match")
        let lang = Episode.onlyLanguage(lyrics).flatMap { spellingTells($0) ? $0 : nil }
        if let forced = language, forced != lang, !unforcedRetry {
            // The language was forced from lyrics that aren't this song's: hear the whole song again, freely.
            unforcedRetry = true
            log("forced language \(forced) was wrong (lyrics say \(lang ?? "none")): transcribing again")
            language = lang
            lines = []; heard = []; redone = []; complete = false; done = done.map { _ in false }
            save(); return
        }
        language = lang
        lines = lyrics.isEmpty ? heardLines(translations()) : alignLyrics()
        save()
    }
    var unforcedRetry = false

    /// The longest phrases heard, as search queries for the lyrics they come from.
    func confidentPhrases() -> [String] {
        let langs = songLanguages()
        return sentences(heard, pause: 0.7).filter { $0.count >= 4 && $0.count <= 14 }
            .filter { ph in langs.isEmpty || language(of: ph).map { langs.contains($0.code) } ?? false }
            .map { $0.map(\.text).joined(separator: " ") }
            .sorted { $0.count > $1.count }
    }

    /// The languages a text list is in, with their share of the words (lines of three words or more).
    static func languageShares(_ texts: [String]) -> [(code: String, share: Double)] {
        var n: [String: Int] = [:]
        for t in texts {
            let w = t.split(separator: " ").count
            if w >= 3, let (c, _) = dominantLanguage(t) { n[c, default: 0] += w }
        }
        let total = Double(max(1, n.values.reduce(0, +)))
        return n.map { ($0.key, Double($0.value) / total) }.sorted { $0.share > $1.share }
    }

    /// The one language lyrics are written in (90 % of their words), or nil when they mix languages.
    static func onlyLanguage(_ lyrics: [String]) -> String? {
        guard let top = languageShares(lyrics).first, top.share >= 0.9 else { return nil }
        return top.code
    }

    /// The languages this song is sung in, with their share of it: from its lyrics' spelling, else from each phrase heard
    /// (phraseLanguage). A language the spelling can't name (Arabic script) is the one Whisper heard in that script.
    // Recomputing this runs NaturalLanguage over the whole song; inside Recense that stalled the main thread, so it is
    // kept until the words heard or the lyrics change.
    private var sharesMemo: (heard: Int, lyrics: Int, v: [(code: String, share: Double)])?
    func languageShares() -> [(code: String, share: Double)] {
        if let m = sharesMemo, m.heard == heard.count, m.lyrics == lyrics.count { return m.v }
        let v = computeLanguageShares()
        sharesMemo = (heard.count, lyrics.count, v)
        return v
    }
    private func computeLanguageShares() -> [(code: String, share: Double)] {
        var n: [String: Double] = [:]
        if lyrics.isEmpty {
            for ph in sentences(heard, pause: 0.7) where ph.count >= 3 { if let l = language(of: ph) { n[l.code, default: 0] += Double(ph.count) } }
            let total = max(1, n.values.reduce(0, +))
            return n.map { ($0.key, $0.value / total) }.sorted { $0.share > $1.share }
        }
        for s in Episode.languageShares(lyrics) { n[bySound(s.code) ?? s.code, default: 0] += s.share }
        return n.map { ($0.key, $0.value) }.sorted { $0.share > $1.share }
    }

    /// A phrase's language (phraseLanguage), named by what Whisper heard in its script where the spelling can't tell:
    /// Dari words heard inside an English request carry no tag of their own, and read as Arabic or Urdu.
    func language(of words: [Word]) -> (code: String, p: Double)? {
        guard let l = phraseLanguage(words) else { return nil }
        return (bySound(l.code) ?? l.code, l.p)
    }

    /// The languages this song is sung in (10 % of it or more).
    func songLanguages() -> [String] { languageShares().filter { $0.share >= 0.1 }.map(\.code) }

    /// The one language this song is sung in, when it's sung in one: a stretch asked again is heard in it.
    var soleLanguage: String? { let l = songLanguages(); return l.count == 1 ? l[0] : nil }

    /// A language as the spelling guessed it, or — where the spelling can't tell (Persian read as Urdu) — the language
    /// Whisper heard most in that script; nil if it heard none.
    func bySound(_ code: String) -> String? {
        if spellingTells(code) { return code }
        let script = scriptOf(language: code)
        var n: [String: Int] = [:]
        for w in heard { if let l = w.lang, scriptOf(language: l) == script { n[l, default: 0] += 1 } }
        return n.max { $0.value < $1.value }?.key
    }

    nonisolated static func norm(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    }

    /// Without a vocal stem, the part of the lyrics this stretch most likely sings, as a prompt (Whisper reads
    /// ~224 tokens of it): under the instruments it otherwise hears little.
    func lyricPrompt(_ a: Double, _ b: Double) -> String? {
        guard !lyrics.isEmpty, duration > 0 else { return nil }
        let n = Double(lyrics.count)
        var i = max(0, Int((a / duration - 0.15) * n)), out = ""
        let end = min(lyrics.count, Int((b / duration + 0.15) * n) + 1)
        while i < end, out.count + lyrics[i].count < 700 { out += lyrics[i] + "\n"; i += 1 }
        return out
    }

    var heard: [Word] = []

    /// Translations already made, by line text: re-timing a song's lines never loses them.
    func translations() -> [String: [EnWord]] {
        Dictionary(lines.compactMap { l in l.english.map { (lineKey(l), $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// Lyric words (L), and the sung occurrences of lyric lines found among the heard words, in time order.
    struct Occurrence { var line: Int; var idx: [Int] = []; var hw: [Int] = []; var good = 0 }
    final class Alignment {
        var words: [String] = [], wordLine: [Int] = []   // lyric words, and the line each is in
        var occ: [Occurrence] = []
        var good: Int { occ.reduce(0) { $0 + $1.good } }
    }

    /// Heard words aligned to lyrics in order, but the alignment may jump back (or ahead) to the start of any lyric
    /// line: a chorus written once and sung three times shows three times, a line sung twice in a row shows twice.
    /// Each run of consecutive words within one lyric line is one sung occurrence of that line; one that's mostly
    /// misheard, or a lone word of a longer line, isn't kept.
    func align(_ lyrics: [String]) -> Alignment? {
        let al = Alignment()
        var starts: [Int] = [], lineLen: [Int] = [], keys: [String] = []
        for (i, l) in lyrics.enumerated() {
            starts.append(al.words.count)
            let ws = l.split(separator: " ").map(String.init)
            lineLen.append(ws.count)
            for w in ws { al.words.append(w); al.wordLine.append(i); keys.append(Episode.norm(w).joined()) }
        }
        let lineLetters = lyrics.indices.map { i in (starts[i]..<(starts[i] + lineLen[i])).reduce(0) { $0 + keys[$1].count } }
        let H = heard.map { Episode.norm($0.text).joined() }
        let n = al.words.count, m = H.count
        guard n > 0, m > 0 else { return nil }
        func sim(_ a: String, _ b: String) -> Double {
            if a.isEmpty || b.isEmpty { return 0 }
            if a == b { return 2 }
            if min(a.count, b.count) <= 2 { return 0 }                  // "il" isn't "it", "e" isn't "a"
            if a.hasPrefix(b) || b.hasPrefix(a) { return 1.5 }
            if Episode.edits(a, b) <= max(1, min(a.count, b.count) / 3) { return 1.5 }
            // A sung word misheard by its onset keeps its rhyme ("Ous" for "Reuss", a doubled letter sung as one): a
            // weaker match, enough to place the line where it was sung instead of dropping its first word.
            let x = Episode.squeeze(a), y = Episode.squeeze(b)
            return min(x.count, y.count) >= 3 && x.suffix(2) == y.suffix(2) && Episode.edits(x, y) <= max(x.count, y.count) / 2 ? 1 : 0
        }
        // Scores: match +2 (near +1.5), misheard word -0.6, heard word not in the lyrics -1,
        // lyric word not heard -0.7, jump to a line start -1.5.
        let W = n + 1, NEG = -1e9
        var dp = [Double](repeating: NEG, count: (m + 1) * W)
        var op = [UInt8](repeating: 0, count: (m + 1) * W)   // 0 start, 1 jump, 2 skip lyric, 3 skip heard, 4 match, 5 misheard
        var from = [Int32](repeating: 0, count: (m + 1) * W)
        for s in starts { dp[s] = 0 }
        for j in 0...m {
            let row = j * W
            var best = row
            for c in row...(row + n) where dp[c] > dp[best] { best = c }
            for s in starts where dp[best] - 1.5 > dp[row + s] { dp[row + s] = dp[best] - 1.5; op[row + s] = 1; from[row + s] = Int32(best - row) }
            for i in 0..<n where dp[row + i] - 0.7 > dp[row + i + 1] { dp[row + i + 1] = dp[row + i] - 0.7; op[row + i + 1] = 2 }
            if j == m { break }
            let next = row + W
            for i in 0...n {
                let v = dp[row + i]
                guard v > NEG / 2 else { continue }
                if v - 1 > dp[next + i] { dp[next + i] = v - 1; op[next + i] = 3 }
                if i < n {
                    let sc = sim(keys[i], H[j]), x = v + (sc > 0 ? sc : -0.6)
                    if x > dp[next + i + 1] { dp[next + i + 1] = x; op[next + i + 1] = sc > 0 ? 4 : 5 }
                }
            }
        }
        var i = (0...n).max { dp[m * W + $0] < dp[m * W + $1] }!, j = m
        var pairs: [(lw: Int, hw: Int, good: Bool)?] = []   // nil: a jump
        walk: while true {
            let c = j * W + i
            switch op[c] {
            case 1: pairs.append(nil); i = Int(from[c])
            case 2: i -= 1
            case 3: j -= 1
            case 4, 5: pairs.append((i - 1, j - 1, op[c] == 4)); i -= 1; j -= 1
            default: break walk
            }
        }
        pairs.reverse()
        var open = false
        for p in pairs {
            guard let p else { open = false; continue }
            let li = al.wordLine[p.lw]
            if !open || al.occ[al.occ.count - 1].line != li || p.lw <= al.occ[al.occ.count - 1].idx.last! { al.occ.append(Occurrence(line: li)); open = true }
            al.occ[al.occ.count - 1].idx.append(p.lw); al.occ[al.occ.count - 1].hw.append(p.hw)
            if p.good { al.occ[al.occ.count - 1].good += 1 }
        }
        // Kept: at least two words matched (or the whole of a one-word line), half the words sung, and more than a
        // couple of little words ("e il" alone could be anything).
        al.occ = al.occ.filter { o in
            let letters = zip(o.idx, o.hw).filter { keys[$0.0] == H[$0.1] || sim(keys[$0.0], H[$0.1]) > 0 }.reduce(0) { $0 + keys[$1.0].count }
            return o.good >= min(2, lineLen[o.line]) && Double(o.good) >= 0.5 * Double(o.idx.count) && letters >= min(6, lineLetters[o.line])
        }
        return al
    }

    /// Share of the heard words that land in lyric lines.
    func matchScore(_ lyrics: [String]) -> Double {
        guard !heard.isEmpty, let al = align(lyrics) else { return 0 }
        return Double(al.good) / Double(heard.count)
    }

    /// Lines are the lyric lines, timed by the words Whisper heard (see align). A misheard word takes the lyric's
    /// spelling; heard words that aren't in the lyrics (ad-libs, Whisper's inventions) are dropped. Only the part
    /// of a line actually sung is shown; lyric words Whisper missed inside it are spread between their neighbours.
    /// Lyric lines skipped between two sung lines, where something was sung that matched nothing (a phrase Whisper
    /// misheard beyond recognition, often where the singer switches language), are laid over that singing.
    /// If the lyrics don't fit what's sung at all (wrong song), what Whisper heard is shown.
    func alignLyrics() -> [Line] {
        let old = translations()
        guard let al = align(lyrics) else { return heardLines(old) }
        if heard.count >= 20, Double(al.good) < 0.35 * Double(heard.count) { return heardLines(old) }   // not this song's lyrics
        var lineStart: [Int] = [], at = 0
        for l in lyrics { lineStart.append(at); at += l.split(separator: " ").count }
        var sung: [[Word]] = []
        let matched = Set(al.occ.flatMap(\.hw))
        for o in al.occ {
            var t: [Int: Word] = [:]
            for (x, h) in zip(o.idx, o.hw) {
                t[x] = heard[h]
                // A lyric word heard as two ("Soro-soro," as "Soro," "soro,"), matched by its second half: it starts
                // with the first, which nothing else took (a line shown a word late otherwise).
                if h > 0, !matched.contains(h - 1), heard[h - 1].start >= heard[h].start - 2 {
                    let key = Episode.norm(al.words[x]).joined(), two = Episode.norm(heard[h - 1].text + " " + heard[h].text).joined()
                    if key.count >= 4, Episode.norm(heard[h].text).joined().count < key.count, Episode.edits(two, key) <= key.count / 4 {
                        t[x] = heard[h].timed(heard[h - 1].start, heard[h].end)
                    }
                }
            }
            var lo = o.idx.first!
            let hi = o.idx.last!
            // The line's opening words, unheard (the first word of a sung phrase is the one a recognizer most often
            // misses): sung just before its first heard word, never before the line before it ended. The light then
            // starts the line where it starts instead of a word into it (Cadence.fit puts them on the voice).
            let ls = lineStart[o.line]
            if lo > ls, let first = t[lo] {
                let k = Double(lo - ls), prevEnd = sung.last?.last?.end ?? 0
                let span = min(first.start - prevEnd - 0.05, 0.35 * k + 0.3)
                if span >= 0.12 * k {
                    let st = first.start - span
                    for x in ls..<lo { t[x] = Word(text: al.words[x], start: st + span * Double(x - ls) / k, end: st + span * Double(x - ls + 1) / k) }
                    lo = ls
                }
            }
            var words: [Word] = []
            for x in lo...hi {
                let floor = words.last.map { $0.start + 0.02 } ?? 0
                if let w = t[x] { words.append(Word(text: al.words[x], start: max(w.start, floor), end: max(w.end, floor + 0.05), lang: w.lang)); continue }
                let p = (lo..<x).last { t[$0] != nil }!, q = ((x + 1)...hi).first { t[$0] != nil }!
                let step = max(0.05, (t[q]!.start - t[p]!.end) / Double(q - p))
                let st = max(floor, t[p]!.end + step * Double(x - p - 1))
                words.append(Word(text: al.words[x], start: st, end: st + step))
            }
            sung.append(words)
        }
        // Skipped lyric lines over unmatched singing, between consecutive occurrences (and before the first, after the last).
        let used = Set(al.occ.flatMap(\.hw))
        filled = []
        let same = lyrics.map { Episode.norm($0).joined(separator: " ") }
        var prevHW = -1, prevLine = -1
        for k in 0...al.occ.count {
            let nextHW = k < al.occ.count ? al.occ[k].hw.first! : heard.count
            var nextLine = k < al.occ.count ? al.occ[k].line : lyrics.count
            // A chorus written out twice: a jump back to its first copy is the next line of this copy.
            if nextLine <= prevLine, nextLine < lyrics.count, let j = ((prevLine + 1)..<lyrics.count).first(where: { same[$0] == same[nextLine] }) { nextLine = j }
            if prevLine + 1 < nextLine, prevHW + 1 < nextHW {
                let free = ((prevHW + 1)..<nextHW).filter { !used.contains($0) }.map { heard[$0] }
                // Lines sung in the last 30 s aren't what's missing (an outro jumps back, then sings its last line).
                let recent = Set(al.occ.filter { o in free.first.map { heard[o.hw[0]].start > $0.start - 30 && heard[o.hw[0]].start < $0.start } ?? false }.map(\.line))
                let missing = ((prevLine + 1)..<nextLine).filter { !recent.contains($0) }.map { lyrics[$0].split(separator: " ").map(String.init) }
                let n = missing.reduce(0) { $0 + $1.count }
                // Only where the amount sung fits the lines (a singer may also just skip lines).
                if free.count >= 2, Double(n) >= 0.4 * Double(free.count), Double(n) <= 2.5 * Double(free.count) {
                    sung += Episode.layOver(missing, free)
                    filled.formUnion(((prevHW + 1)..<nextHW).filter { !used.contains($0) })
                }
            }
            if k < al.occ.count { prevHW = al.occ[k].hw.last!; prevLine = al.occ[k].line }
        }
        sung.sort { $0[0].start < $1[0].start }
        let langs = songLanguages()
        let ids = Episode.keepIds(sung, lines)
        return sung.enumerated().map { k, words in
            let text = words.map(\.text)
            return Line(id: ids[k], words: words, english: needsTranslation(text, among: langs) ? old[text.joined(separator: " ")] : [])
        }
    }

    /// Ids for lyric lines aligned again: a line that was there before (the same words, within 3 s) keeps its id, so a
    /// correction made on it (Gallery's overrides find their line by id) never lands on another line when the song is
    /// aligned again (a line found that wasn't, a better match); a new line takes 2 000 000 + its place, else the next
    /// number no line has had.
    nonisolated static func keepIds(_ sung: [[Word]], _ before: [Line]) -> [Int] {
        let prev = before.filter { $0.id >= 2_000_000 && $0.id < 3_000_000 }
        var ids = [Int?](repeating: nil, count: sung.count), used = Set<Int>()
        for (k, words) in sung.enumerated() {
            let text = words.map(\.text).joined(separator: " "), s = words[0].start
            if let m = prev.filter({ lineKey($0) == text && !used.contains($0.id) && abs($0.start - s) < 3 })
                .min(by: { abs($0.start - s) < abs($1.start - s) }) { ids[k] = m.id; used.insert(m.id) }
        }
        let had = Set(prev.map(\.id))
        var next = 2_000_000 + max(sung.count, (had.max() ?? 1_999_999) - 1_999_999)
        return sung.indices.map { k in
            if let id = ids[k] { return id }
            let own = 2_000_000 + k
            if !had.contains(own) && !used.contains(own) { used.insert(own); return own }
            while had.contains(next) || used.contains(next) { next += 1 }
            used.insert(next); return next
        }
    }

    var filled = Set<Int>()            // heard words a skipped lyric line was laid over (alignLyrics)

    /// Lyric lines timed over the heard words that sang them: each lyric word goes where the same share of the
    /// characters falls in what was heard, so the words follow the voice's own rhythm.
    static func layOver(_ lines: [[String]], _ heard: [Word]) -> [[Word]] {
        let hc = heard.map { Double($0.text.count + 1) }, totalH = hc.reduce(0, +)
        let totalL = Double(lines.joined().reduce(0) { $0 + $1.count + 1 })
        func time(_ x: Double) -> Double {           // character position in the heard words → time
            var at = 0.0
            for (w, c) in zip(heard, hc) {
                if x <= at + c { return w.start + (x - at) / c * (w.end - w.start) }
                at += c
            }
            return heard.last!.end
        }
        var out: [[Word]] = [], x = 0.0
        for l in lines {
            var words: [Word] = []
            for w in l {
                let c = Double(w.count + 1) * totalH / totalL
                let s = max(time(x), (words.last?.start ?? out.last?.last?.start ?? -1) + 0.02)
                words.append(Word(text: w, start: s, end: max(s + 0.05, time(x + c - 1))))
                x += c
            }
            out.append(words)
        }
        return out
    }

    /// A correction timed over the words it replaces (corrections.js: layOver): a word the listener left as it was
    /// keeps the time it was heard at, so the light stays on the voice; only the runs between those are spread
    /// (layOver over the heard words they replace, or over the gap if they replaced none).
    static func correct(_ words: [String], over heard: [Word]) -> [Word] {
        guard !words.isEmpty, !heard.isEmpty else { return [] }
        func fold(_ t: String) -> String { t.precomposedStringWithCompatibilityMapping.lowercased().filter { $0.isLetter || $0.isNumber } }
        let a = words.map(fold), b = heard.map { fold($0.text) }
        var L = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                L[i][j] = !a[i].isEmpty && a[i] == b[j] ? L[i + 1][j + 1] + 1 : max(L[i + 1][j], L[i][j + 1])
            }
        }
        var out: [Word] = [], i = 0, j = 0, i0 = 0, j0 = 0
        func flush(_ i1: Int, _ j1: Int) {
            let ws = Array(words[i0..<i1])
            guard !ws.isEmpty else { return }
            var hs = Array(heard[j0..<j1])
            if hs.isEmpty {
                let s = j0 > 0 ? heard[j0 - 1].end : heard[0].start
                let e = j0 < heard.count ? heard[j0].start : heard.last!.end
                hs = [Word(text: ws.joined(separator: " "), start: s, end: max(e, s + 0.05 * Double(ws.count)))]
            }
            out += layOver([ws], hs)[0]
        }
        while i < a.count && j < b.count {
            if !a[i].isEmpty && a[i] == b[j] {
                flush(i, j)
                out.append(Word(text: words[i], start: heard[j].start, end: heard[j].end))
                i += 1; j += 1; i0 = i; j0 = j
            } else if L[i + 1][j] >= L[i][j + 1] { i += 1 } else { j += 1 }
        }
        flush(words.count, heard.count)
        return out
    }

    /// A song shown as heard: lines break where the voice pauses.
    func heardLines(_ old: [String: [EnWord]]) -> [Line] {
        var out: [Line] = []
        let langs = songLanguages()
        for sentence in sentences(heard, pause: 0.7) {
            for part in breathSplit(sentence) {
                let text = part.map(\.text)
                out.append(Line(id: 3_000_000 + out.count, words: part,
                                english: needsTranslation(text, among: langs) ? old[text.joined(separator: " ")] : []))
            }
        }
        // A stock phrase in a language the song isn't sung in ("Thank you." over Dari singing) is Whisper's, wherever it is.
        return dropFillers(out.filter { l in !isFiller(l) || langs.isEmpty || language(of: l.words).map { langs.contains($0.code) } ?? true })
    }

    /// A song heard all the way through with no lyrics matching it and nothing sung once the filler is gone.
    var instrumental: Bool { isSong && lyricsVerified && lyrics.isEmpty && lines.isEmpty && !done.isEmpty && !done.contains(false) }

    /// A word with its doubled letters sung as one ("reuss" → "reus").
    nonisolated static func squeeze(_ s: String) -> String {
        var out = ""
        for c in s where c != out.last { out.append(c) }
        return out
    }

    nonisolated static func edits(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]; row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    /// Stretches of a song to transcribe again, each on its own (≤ 25 s, so Whisper decides its language afresh
    /// and can't carry a translation over from what came before): phrases in a language the lyrics aren't in,
    /// phrases that match no lyric line, and — without lyrics — phrases in the song's minority language (where
    /// Whisper slips into translating). Each stretch is done once; one the listener corrected never is.
    func suspects() -> [(a: Double, b: Double)] {
        guard !heard.isEmpty, redone.reduce(0, { $0 + $1[1] - $1[0] }) < 0.6 * duration, redone.count < 16 else { return [] }
        let shares = languageShares()
        let langs = shares.filter { $0.share >= 0.1 }.map(\.code)
        var used = Set<Int>()
        if !lyrics.isEmpty { _ = alignLyrics(); used = Set(align(lyrics)?.occ.flatMap(\.hw) ?? []).union(filled) }
        var flagged: [(a: Double, b: Double)] = [], at = 0
        for ph in sentences(heard, pause: 0.7) {
            let range = at..<(at + ph.count); at += ph.count
            let a = ph.first!.start, b = ph.last!.end
            if redone.contains(where: { $0[0] < b && $0[1] > a }) || edits.edits.contains(where: { $0.a < b && $0.b > a }) { continue }
            let lang = ph.count >= 3 ? language(of: ph) : nil
            let foreign = lang.map { $0.p >= 0.8 && !langs.isEmpty && !langs.contains($0.code) } ?? false
            var bad: Bool
            if !lyrics.isEmpty {
                bad = foreign || (ph.count >= 2 && Double(range.filter { used.contains($0) }.count) < 0.5 * Double(ph.count))
            } else {
                let minority = lang.map { l in l.p >= 0.8 && langs.count > 1 && (shares.first { $0.code == l.code }?.share ?? 0) < 0.35 } ?? false
                bad = foreign || minority
            }
            if bad { flagged.append((a, b)) }
        }
        // Singing nothing was heard in: on a vocal stem, a stretch of voice with (almost) no words. A long request
        // misses whole verses (a language it didn't expect, a melisma); a short one alone often hears them.
        for v in voiceStretches() where !redone.contains(where: { $0[0] < v.b && $0[1] > v.a }) && !edits.edits.contains(where: { $0.a < v.b && $0.b > v.a }) {
            let inside = heard.filter { $0.start >= v.a - 0.3 && $0.start < v.b }
            if inside.reduce(0, { $0 + $1.end - $1.start }) < 0.3 * (v.b - v.a) { flagged.append(v) }
        }
        flagged.sort { $0.a < $1.a }
        var out: [(a: Double, b: Double)] = []
        for f in flagged {
            if let last = out.last, f.a - last.b < 2, f.b - last.a <= 25 { out[out.count - 1].b = f.b } else { out.append(f) }
        }
        return out
    }

    /// The stretches of a song's vocal stem with a voice in them, ≤ 20 s each (a longer one is cut at its quietest
    /// moment), once per song. None without a stem: under the instruments loudness says nothing about singing.
    var voice: [(a: Double, b: Double)]?
    func voiceStretches() -> [(a: Double, b: Double)] {
        if let voice { return voice }
        guard let v = vocals, let s = try? decodeChunk(v, from: 0, to: duration) else { return [] }
        let db = frameDB(s), sorted = db.sorted()
        guard sorted.count > 1000 else { voice = []; return [] }
        let thr = max(sorted[sorted.count / 10] + 12, sorted[sorted.count * 95 / 100] - 30)
        // voiced: half of the surrounding 300 ms is loud; stretches closer than 0.8 s are one
        var on = [Bool](repeating: false, count: db.count), run = 0
        for i in db.indices { run += db[i] >= thr ? 1 : 0; if i >= 30 { run -= db[i - 30] >= thr ? 1 : 0 }; if run >= 15 { on[max(0, i - 15)] = true } }
        var spans: [(a: Int, b: Int)] = [], at: Int? = nil
        for i in on.indices {
            if on[i], at == nil { at = i }
            if !on[i] || i == on.count - 1, let a = at { if let l = spans.last, a - l.b < 80 { spans[spans.count - 1].b = i } else { spans.append((a, i)) }; at = nil }
        }
        var out: [(a: Double, b: Double)] = []
        for sp in spans where sp.b - sp.a >= 150 {
            var a = sp.a
            while sp.b - a > 2000 {                      // cut at the quietest 300 ms between 12 and 18 s in
                var best = a + 1200, low = Float.infinity
                for i in (a + 1200)..<(a + 1800) { let e = db[i..<(i + 30)].reduce(0, +); if e < low { low = e; best = i + 15 } }
                out.append((Double(a) / 100, Double(best) / 100)); a = best
            }
            out.append((Double(a) / 100, Double(sp.b) / 100))
        }
        voice = out
        return out
    }

    /// Transcribes one suspect stretch again, alone. With lyrics, the version that lands more words in lyric
    /// lines wins — Whisper's own guess of the language first, then each other language of the lyrics. Without,
    /// the new version replaces the old unless it lost most of the words.
    /// A stretch of a spoken transcript Whisper skipped: on chanting, or speech over music, it may stop writing
    /// partway through a request (a whole minute missing after 15:03, the rest of the chunk). Any 15 s or more with (a few at a chunk's cut)
    /// no word, and audio that isn't silence, never asked for on its own before (`redone`); at most 120 s at a time.
    func skipped(_ src: URL) async -> (a: Double, b: Double)? {
        for (a, b) in unasked() {
            let db = (try? await Task.detached { frameDB(try decodeChunk(src, from: a, to: b)) }.value) ?? []
            if db.isEmpty || Double(db.filter { $0 > -45 }.count) / Double(db.count) < 0.3 { redone.append([a, b]); continue }
            return (a, b)
        }
        return nil
    }

    /// Every 15 s or more with no word that hasn't been asked for on its own yet, at most 120 s each.
    func unasked() -> [(Double, Double)] {
        let ws = lines.flatMap(\.words).sorted { $0.start < $1.start }
        var gaps: [(Double, Double)] = []
        var at = 0.0
        for w in ws { gaps.append((at, w.start)); at = max(at, w.end) }
        gaps.append((at, duration))
        return gaps.compactMap { (from, to) in
            var a = from
            for r in redone where r.count == 2 && r[0] <= a + 0.5 && r[1] > a { a = r[1] }   // asked already
            let b = min(to, a + 120)
            // at a chunk's cut (made before requests were padded) a pause of a few seconds is words lost, not a pause
            let atCut = (Int(a / chunkLen)...Int(b / chunkLen) + 1).contains { k in k > 0 && Double(k) * chunkLen > a - 6 && Double(k) * chunkLen < b + 6 }
            return b - a >= 15 || (b - a >= 2.5 && atCut) ? (a, b) : nil
        }
    }

    /// Asks Whisper for a skipped stretch on its own, and keeps the words that start in it.
    func fill(_ w: (a: Double, b: Double), src: URL) async {
        let lo = max(0, w.a - 3), hi = min(duration, w.b + 3)
        if let samples = try? await Task.detached(operation: { try decodeChunk(src, from: lo, to: hi) }).value, !samples.isEmpty {
            do {
                let t = try await whisper(samples, lo, hi, language: soleLanguage, redo: [w.a, w.b])
                let before = lines.count
                add(t, samples: samples, offset: lo, keep: (w.a + 0.01)..<w.b)
                if lines.count > before { wakeTranslation() }   // the loop may have finished before these came
                log("skipped \(clock(w.a))–\(clock(w.b)) asked again: \(lines.count - before) line(s)")
            } catch let e as URLError {
                log("skipped stretch: network error \(e.code.rawValue), asked again shortly")
                try? await Task.sleep(for: .seconds(10))
                return                                         // not marked: the connection, not the audio
            } catch { log("skipped stretch error: \(error.localizedDescription)") }
        }
        redone.append([w.a, w.b]); save()
    }

    func redo(_ w: (a: Double, b: Double), src: URL) async {
        let lo = max(0, w.a - 0.6), hi = min(duration, w.b + 0.6)
        guard let samples = try? await Task.detached(operation: { try decodeChunk(src, from: lo, to: hi) }).value, !samples.isEmpty
        else { redone.append([w.a, w.b]); return }
        let outside = heard.filter { $0.start < w.a - 0.05 || $0.start > w.b + 0.05 }
        let before = heard.count - outside.count, base = lyrics.isEmpty ? 0 : matchScore(lyrics)
        var tries: [String?] = [language ?? soleLanguage], best: (score: Double, words: [Word])?
        var k = 0
        while k < tries.count, !stopped {
            if k > 0 { try? await Task.sleep(for: .seconds(pace)) }
            do {
                let t = try await whisper(samples, lo, hi, language: tries[k], redo: [w.a, w.b])
                let words = heardWords(t, samples: samples, offset: lo).words.filter { $0.start >= w.a - 0.25 && $0.start <= w.b + 0.25 }
                let saved = heard
                heard = (outside + words).sorted { $0.start < $1.start }
                let score = lyrics.isEmpty ? Double(words.count) : matchScore(lyrics)
                heard = saved
                log("redo \(clock(w.a))–\(clock(w.b)) [\(tries[k] ?? "auto")]: \(words.map(\.text).joined(separator: " ").prefix(80))")
                if score > (best?.score ?? -1) { best = (score, words) }
                if k == 0, tries[k] == nil, !lyrics.isEmpty, score <= base {
                    let heardLang = language(of: words)?.code
                    for l in songLanguages() where l != heardLang && tries.count < 3 { tries.append(l) }
                }
            } catch { log("redo error: \(error.localizedDescription)"); break }
            k += 1
        }
        redone.append([w.a, w.b])
        if let best, lyrics.isEmpty ? best.words.count * 2 >= before : best.score > base {
            heard = (outside + best.words).sorted { $0.start < $1.start }
        }
        lines = lyrics.isEmpty ? heardLines(translations()) : alignLyrics()
        save()
    }

    /// The words of one transcription, timed against the audio Whisper got (16 kHz `samples` from `offset`):
    /// silence hallucinations and segments Whisper itself doubts are dropped.
    func heardWords(_ t: [String: Any], samples: [Float], offset: Double, firstPass: Bool = false) -> (words: [Word], english: Bool) {
        let english = isEnglish((t["language"] as? String) ?? cfg.language)
        let lang = languageCode((t["language"] as? String) ?? ""), script = lang.flatMap { scriptOf(language: $0) }
        let segs = ((t["segments"] as? [[String: Any]]) ?? []).compactMap { s -> (start: Double, nsp: Double, lp: Double)? in
            guard let a = s["start"] as? Double else { return nil }
            return (a, (s["no_speech_prob"] as? Double) ?? 0, (s["avg_logprob"] as? Double) ?? 0)
        }.sorted { $0.start < $1.start }
        var raw: [Word] = []
        for w in (t["words"] as? [[String: Any]]) ?? [] {
            // "...word": Whisper marking a phrase it joined midway, not part of the word
            guard let text = (w["word"] as? String)?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^[.…]+"#, with: "", options: .regularExpression),
                  !text.isEmpty, text.contains(where: { $0.isLetter || $0.isNumber }),          // "¶¶", "♪": music, not words
                  let s = w["start"] as? Double, let e = w["end"] as? Double else { continue }
            let wl = (w["lang"] as? String) ?? lang, ws = (w["lang"] as? String).flatMap { scriptOf(language: $0) } ?? script
            var x = Word(text: text, start: offset + s, end: offset + e, lang: ws != nil && scriptOf(text: text) == ws ? wl : nil)
            x.c = w["probability"] as? Double; x.heard = w["heard"] as? String
            raw.append(x)
        }
        raw = Episode.withoutTranslation(raw, lang: lang)
        var bySeg = Array(repeating: [Word](), count: segs.count)
        for w in raw {
            guard let k = segs.lastIndex(where: { $0.start <= w.start - offset + 0.01 }) ?? (segs.isEmpty ? nil : 0) else { continue }
            bySeg[k].append(w)
        }
        let clean = vocals != nil      // a vocal stem: silence is real silence, so loudness decides what was sung
        var words: [Word] = []
        for (k, seg) in segs.enumerated() where !bySeg[k].isEmpty {
            // Whisper's own rule: no speech only when it's also unsure of the words (music under a voice raises
            // no_speech_prob on its own). On a vocal stem, loudness decides instead (refine).
            if !clean && seg.nsp > 0.6 && seg.lp < -1 { continue }
            // On a stem, a segment of a long first-pass request that Whisper itself doubts (its own threshold for a
            // failed decode) is a guess — standard Persian invented over Dari singing, two dozen words in a second.
            // Left out, its stretch is unheard voice, and the second pass asks for it alone.
            if clean && firstPass && isSong && seg.lp < -1 { continue }
            let text = bySeg[k].map(\.text).joined(separator: " ").lowercased()
            if hallucinations.contains(where: { text.contains($0) }) { continue }
            if silenceHallucinations.contains(hallucinationKey(text)) { continue }     // a standalone stock phrase
            if musicTags.contains(text.filter { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)) { continue }
            words += bySeg[k].filter { $0.start < duration }
        }
        words = refine(words, db: frameDB(samples), offset: offset, gate: clean)
        // Without a stem, Whisper stretches a sung word back over the intro before it; no word is held this long.
        if isSong && !clean { words = words.map { $0.end - $0.start > 1.5 ? $0.timed($0.end - 0.6, $0.end) : $0 } }
        // What corrections taught (Lexicon), where this hearing makes the same mistake and the evidence agrees.
        let alts = ((t["segments"] as? [[String: Any]]) ?? []).compactMap { s -> (a: Double, b: Double, texts: [String])? in
            guard let a = s["start"] as? Double, let b = s["end"] as? Double, let x = s["alternatives"] as? [String], x.count > 1 else { return nil }
            return (offset + a, offset + b, x)
        }
        words = Lexicon.recall(words, samples: samples, origin: offset, key: key, alts: alts)
        return (words, english)
    }

    /// When Whisper hears a language other than the one it decided on, it may write the stretch twice, over the same
    /// seconds: translated into its language, and as sung in another script ("This is a cure for the people's pain"
    /// over "دوای درد مردم انقلابه"). The translation is the run in the reply's language — only taken as one when the
    /// spelling can vouch for it (a transliteration is never mistaken for it).
    nonisolated static func withoutTranslation(_ words: [Word], lang: String?) -> [Word] {
        guard let lang, let script = scriptOf(language: lang), spellingTells(lang) else { return words }
        var runs: [(script: String?, r: Range<Int>)] = []        // same script, no pause over 1.5 s
        for (i, w) in words.enumerated() {
            let s = scriptOf(text: w.text)
            if let last = runs.last, last.script == s || s == nil, w.start - words[i - 1].end < 1.5 { runs[runs.count - 1].r = last.r.lowerBound..<(i + 1) }
            else { runs.append((s, i..<(i + 1))) }
        }
        func span(_ r: Range<Int>) -> (a: Double, b: Double) { (words[r].map(\.start).min()!, words[r].map(\.end).max()!) }
        var drop = Set<Int>()
        for run in runs where run.script == script {
            let mine = span(run.r)
            let text = words[run.r].map(\.text).joined(separator: " ")
            guard let g = dominantLanguage(text), g.code == lang, g.p >= 0.8 else { continue }
            let under = runs.contains { o in
                guard let os = o.script, os != script else { return false }
                let theirs = span(o.r), overlap = min(mine.b, theirs.b) - max(mine.a, theirs.a)
                return overlap > 0.5 * min(mine.b - mine.a, theirs.b - theirs.a)
            }
            if under { drop.formUnion(run.r) }
        }
        return words.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    /// Adds one chunk's transcription; words are kept when they start inside `keep`, the chunk's own stretch.
    func add(_ t: [String: Any], samples: [Float], offset: Double, keep: Range<Double>) {
        let (all, english) = heardWords(t, samples: samples, offset: offset, firstPass: true)
        let words = all.filter { keep.contains($0.start) }
        if isSong {
            heard = (heard + words).sorted { $0.start < $1.start }
            lines = lyrics.isEmpty ? heardLines(translations()) : alignLyrics()
            return
        }
        for sentence in sentences(words) {
            for part in splitWords(sentence, max: 18) {
                // Whisper names one language per piece; a line in another (a quote, a switch) is judged on its own.
                let text = part.map(\.text)
                let dom = text.count >= 4 ? dominantLanguage(text.joined(separator: " ")) : nil
                let en = english ? !(dom.map { $0.code != "en" && $0.p >= 0.6 } ?? false)
                                 : (dom.map { $0.code == "en" && $0.p >= 0.9 } ?? false)
                lines.append(Line(id: nextId, words: part, english: en ? [] : nil)); nextId += 1
            }
        }
        lines.sort { $0.start < $1.start }
    }

    /// Whole sentences translate far better than Whisper's arbitrary segments, so lines follow sentence ends.
    func sentences(_ w: [Word], pause: Double = 1.2) -> [[Word]] {
        var out: [[Word]] = [], cur: [Word] = []
        for (i, x) in w.enumerated() {
            cur.append(x)
            let core = x.text.trimmingCharacters(in: CharacterSet(charactersIn: "»\"”’)"))
            let ends = core.last.map { ".?!…".contains($0) } ?? false
            let gap = i + 1 < w.count && w[i + 1].start - x.end > pause
            if ends || gap { out.append(cur); cur = [] }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// The languages a line is in, main one first: by sound and spelling (phraseLanguage), plus any other the spelling
    /// finds in a run of it (a switch mid-line); a language the spelling can't name is the one Whisper heard.
    func languagesOf(_ l: Line) -> [String] {
        let text = l.words.map(\.text)
        guard text.joined().contains(where: \.isLetter) else { return [] }
        var out = phraseLanguage(l.words).flatMap { bySound($0.code) }.map { [$0] } ?? []
        if text.count > 3 {
            for c in lineLanguages(text, among: Array(Set(songLanguages() + ["en"]))) { if let c = bySound(c), !out.contains(c) { out.append(c) } }
        }
        return out
    }

    // Translate lines just ahead of the playhead first, in batches, on this Mac (Apple's Translation): no quota, so
    // nothing ever waits. A pair Apple can't do goes to the owner's own translator if one is set (Models); a line
    // neither can take, or that keeps coming back empty, gets a placeholder so it never blocks the lines after it.
    // The lines are the ones shown: a corrected line is translated as corrected, a hidden one not at all.
    func translateLoop() async {
        translating = true; defer { translating = false }
        var fails = 0
        var tries: [String: Int] = [:]
        while !Task.isCancelled && !stopped {
            let p = position(), lines = shown
            // The window shows the listener's language where it has a line, else the English: the lines about to be
            // heard get the listener's language first.
            if nativeBehind(p, lines), await nativeStep() { continue }
            let ahead = lines.firstIndex { $0.end >= p - 3 && $0.english == nil }
            guard let s = ahead ?? lines.firstIndex(where: { $0.english == nil }) else {
                // the English has nothing to do: Vietnamese and French, the native language first
                if await nativeStep() { continue }
                if complete && nativeDone { save(); return }
                try? await Task.sleep(for: .seconds(complete ? 30 : 0.5)); continue
            }
            let open = { (l: Line) in l.english == nil }
            let size = (tries[lineKey(lines[s])] ?? 0) > 0 ? 1 : 10
            var idx: [Int] = [], texts: [String] = []
            for i in s..<lines.count where open(lines[i]) && idx.count < size && !texts.contains(lineKey(lines[i])) {
                idx.append(i); texts.append(lineKey(lines[i]))
            }
            // Lines translated before, in this piece or any other: nothing to do.
            let known = retranslate ? [] : texts.compactMap { t in Library.recall(t).map { (t, $0) } }
            if !known.isEmpty {
                for (t, e) in known { give(t, e, draft: nil, open) }
                saveSoon(); continue
            }
            let words = idx.map { lines[$0].words.map(\.text) }
            var en = await translateOnDevice(words, languages: idx.map { languagesOf(lines[$0]).first })
            guard !stopped else { return }
            let left = texts.indices.filter { en[$0] == nil }
            if !left.isEmpty, let model = Models.pick() {
                do {
                    let out = try await translateBatch(left.map { words[$0] },
                                                       languages: left.map { let l = languagesOf(lines[idx[$0]]); return l.isEmpty ? nil : l.map(languageName).joined(separator: " and ") },
                                                       context: s > 0 ? lineKey(lines[s - 1]) : "", model: model)
                    guard !stopped else { return }
                    for (j, k) in left.enumerated() { if let e = out[j] { en[k] = e } }
                    fails = 0
                } catch let e as URLError {
                    log("translator: \(e.localizedDescription)"); Models.rest()
                } catch {
                    fails += 1
                    log("translate error: \(error.localizedDescription)")
                    try? await Task.sleep(for: .seconds(min(30, 2 * fails)))
                }
            }
            for (k, text) in texts.enumerated() {
                var e = en[k]
                if e == nil {
                    tries[text, default: 0] += 1
                    if tries[text]! >= 2 { e = [EnWord(w: "…", s: [])] }
                }
                // Lines are matched by text: a song's lines may have been re-timed meanwhile, and a chorus
                // translated once is translated everywhere it's sung.
                if let e { give(text, e, draft: nil, open) }
                if let e = en[k] { Library.remember(text, e) }
            }
            saveSoon()
        }
    }
    var translating = false

    // ---- Vietnamese and French ----
    // Translated from the original (not from the English), with the same prompt, once the English has nothing left
    // to do: playback needs the English first. The native language goes first, then the other. On this Mac, as the
    // English is; a pair Apple can't do goes to the owner's own translator, else a placeholder.
    // Kept by segment with the words each was made from: a line remade or corrected since is translated again.
    var nativeTries: [String: Int] = [:]

    /// A line of the next minute has no translation into the listener's language (not English) yet.
    func nativeBehind(_ p: Double, _ lines: [Line]) -> Bool {
        let lang = NativeLang.current
        guard lang != "en", !dry else { return false }
        let f = native[lang]
        return lines.contains { l in
            l.end >= p - 3 && l.start < p + 60 && !l.words.isEmpty && f?.lines[String(l.id)]?.src != lineKey(l)
        }
    }

    /// Every language translated over the whole transcript.
    var nativeDone: Bool { Keep.others.allSatisfy { native[$0]?.complete == true } }

    func saveNative(_ lang: String) {
        guard !dry, let f = native[lang], let d = Keep.encode(f) else { return }
        try? d.write(to: Keep.trURL(key, lang), options: .atomic)
    }

    /// One batch of Vietnamese or French. false: nothing it can do now (all done).
    func nativeStep() async -> Bool {
        guard !dry, !stopped else { return false }
        var order = [firstLang ?? NativeLang.current].filter { $0 != "en" }
        for l in Keep.others where !order.contains(l) { order.append(l) }
        let p = position()
        let lines = shown.filter { !$0.words.isEmpty }
        for lang in order {
            var f = native[lang] ?? TrFile(lang: lang)
            let have = { (l: Line) in f.lines[String(l.id)].flatMap { $0.src == lineKey(l) ? $0 : nil } }
            let todo = lines.indices.filter { have(lines[$0]) == nil }
            let whole = complete && todo.isEmpty
            if f.complete != whole || native[lang] == nil { f.complete = whole; native[lang] = f; saveNative(lang) }
            guard !todo.isEmpty else { continue }
            let from = todo.firstIndex { lines[$0].end >= p - 3 } ?? 0
            var batch: [Int] = []
            for i in todo[from...] + todo[..<from] where batch.count < 10 && !batch.contains(where: { lineKey(lines[$0]) == lineKey(lines[i]) }) { batch.append(i) }
            // nothing to translate in a line already in that language, or with no words in any
            var send: [Int] = []
            for i in batch {
                let l = lines[i], letters = l.words.contains { $0.text.contains(where: \.isLetter) }
                if !letters || languagesOf(l) == [lang] { f.lines[String(l.id)] = TrLine(src: lineKey(l), text: nil, same: true) } else { send.append(i) }
            }
            func store() {
                f.complete = complete && !lines.contains { l in f.lines[String(l.id)].map { $0.src != lineKey(l) } ?? true }
                native[lang] = f; saveSoon(lang)
            }
            guard !send.isEmpty else { store(); return true }
            let texts = send.map { lines[$0].words.map(\.text) }
            var out = await translateOnDevice(texts, languages: send.map { languagesOf(lines[$0]).first }, to: lang)
            guard !stopped else { return false }
            let left = send.indices.filter { out[$0] == nil }
            if !left.isEmpty, let model = Models.pick() {
                do {
                    let more = try await translateBatch(left.map { texts[$0] },
                                                        languages: left.map { let l = languagesOf(lines[send[$0]]); return l.isEmpty ? nil : l.map(languageName).joined(separator: " and ") },
                                                        context: send[0] > 0 ? lineKey(lines[send[0] - 1]) : "", model: model, to: lang)
                    for (j, k) in left.enumerated() { if let w = more[j] { out[k] = w } }
                } catch let e as URLError {
                    log("translator (\(lang)): \(e.localizedDescription)"); Models.rest()
                } catch {
                    log("translate (\(lang)) error: \(error.localizedDescription)")
                }
            }
            guard !stopped else { return false }
            for (k, i) in send.enumerated() {
                let l = lines[i], id = String(l.id), t = lang + "|" + lineKey(l)
                if let w = out[k] { f.lines[id] = TrLine(src: lineKey(l), text: w.map(\.w).joined(separator: " "), words: w); continue }
                nativeTries[t, default: 0] += 1
                // neither can take it: a placeholder (tried again next time the line changes)
                if nativeTries[t]! >= 2 { f.lines[id] = TrLine(src: lineKey(l), text: "…") }
            }
            store(); return true
        }
        return false
    }

    /// A translation for every open line with these words: the transcript's own, and those only the edits show.
    func give(_ text: String, _ e: [EnWord], draft: Bool?, _ open: (Line) -> Bool) {
        for i in lines.indices where open(lines[i]) && lineKey(lines[i]) == text { lines[i].english = e; lines[i].draft = draft }
        if shown.contains(where: { Episode.isEdited($0) && open($0) && lineKey($0) == text }) { edits.english[text] = e; saveEdits() }
    }

    /// A correction may leave a line to translate after the translation loop has finished.
    func wakeTranslation() {
        if !translating && !stopped { tasks.append(Task { await self.translateLoop() }) }
    }
}

/// A retranscription retranslates too: the Vietnamese and French this Mac has are set aside with the transcript (a
/// line whose words came out the same would otherwise keep its old translation).
@MainActor func setAsideTranslations(_ key: String) {
    for lang in Keep.others {
        let f = Keep.trURL(key, lang), to = FileManager.default.temporaryDirectory.appendingPathComponent("recense-redo-\(key).tr.\(lang).json")
        try? FileManager.default.removeItem(at: to); try? FileManager.default.moveItem(at: f, to: to)
    }
}

func lineKey(_ l: Line) -> String { l.words.map(\.text).joined(separator: " ") }

func looksLikeMusic(_ t: String) -> Bool {
    t.range(of: #"(?i)(\bofficial (music )?video\b|\bofficial audio\b|\blyric video\b|\blyrics\b|\bvisuali[sz]er\b|\bremix\b|\bfeat\.|\bft\.|\(audio\)|\[audio\])"#,
            options: .regularExpression) != nil
}

/// Loudness of 10 ms frames of 16 kHz audio, in dB.
func frameDB(_ s: [Float]) -> [Float] {
    guard s.count >= 160 else { return [] }
    return stride(from: 0, to: s.count - 159, by: 160).map { k in
        var e: Float = 0
        for x in s[k..<(k + 160)] { e += x * x }
        return 10 * log10(e / 160 + 1e-10)
    }
}

/// Whisper's word times, tightened against the audio. A word after a pause starts where the voice actually
/// starts (Whisper tends to begin it early, over the silence) and a word before a pause ends where the voice
/// stops (not where the next one begins). Inside running speech nothing moves. On a vocal stem (`gate`) every
/// word is tightened, and a "word" with no voice under it at all is dropped: Whisper heard it in silence.
func refine(_ words: [Word], db: [Float], offset: Double, gate: Bool) -> [Word] {
    guard db.count > 20, !words.isEmpty else { return words }
    let sorted = db.sorted()
    let quiet = sorted[sorted.count / 10], loud = sorted[sorted.count * 95 / 100]
    let thr = gate ? max(quiet + 12, loud - 30) : quiet + max(10, 0.35 * (loud - quiet))
    func voiced(_ i: Int) -> Bool { i >= 0 && i < db.count && db[i] >= thr }
    func sustained(_ i: Int) -> Bool { voiced(i) && (i..<(i + 8)).filter(voiced).count >= 5 }   // a voice, not a click
    var out: [Word] = []
    for (k, w) in words.enumerated() {
        let a = Int(((w.start - offset) * 100).rounded(.down)), b = max(a, Int(((w.end - offset) * 100).rounded(.up)))
        let pauseBefore = k == 0 || words[k - 1].end < w.start - 0.15
        let pauseAfter = k == words.count - 1 || words[k + 1].start > w.end + 0.15
        let from = gate && pauseBefore ? max(0, a - 5) : max(0, a)   // only after a pause may a word start earlier
        var first = from <= b ? (from...b).first(where: sustained) : nil
        if gate && first == nil && (from <= b ? (from...b).first(where: voiced) : nil) == nil { continue }
        if pauseBefore, w.end - w.start > 1.2, from < b {
            // Whisper stretched the word back over what came before it (an intro, a breath): take the stretch
            // of voice that runs into the word's end, not a stray sound at its start.
            var j = min(b, db.count - 1)
            while j >= from && !voiced(j) { j -= 1 }
            if j >= from {
                var onset = j, gap = 0
                while j > from { j -= 1; if voiced(j) { onset = j; gap = 0 } else { gap += 1; if gap >= 25 { break } } }
                first = onset
            }
        }
        var s = w.start, e = w.end
        if let f = first, gate || pauseBefore, f <= a + 80 || w.end - w.start > 1.2 { s = offset + Double(f) / 100 }
        if let f = first, gate || pauseAfter {
            // from the onset, follow the voice until it's been quiet for 250 ms
            var i = f, last = f, quietRun = 0
            while i <= b + (gate ? 5 : 0), i < db.count {
                if voiced(i) { last = i; quietRun = 0 } else { quietRun += 1; if quietRun >= 25 { break } }
                i += 1
            }
            e = min(e + 0.05, offset + Double(last + 1) / 100 + 0.05)
        }
        if gate && pauseBefore { s = max(s, e - 2.5) }        // a sung word opening a phrase is never held longer
        s = max(s, (out.last?.start ?? -1) + 0.01)
        out.append(w.timed(s, max(e, s + 0.05)))
    }
    return out
}

// ---------- the voice's shape: what the light follows inside a word ----------
/// A song's voice measured frame by frame (100 a second) on its vocal stem, cached as <key>.features.json and kept in
/// keep/<key>/features.json. The karaoke light reads it (Cadence); anything that draws the voice (energy, pitch,
/// vibrato, sustain) can read the same file. One value per frame in each array, all the same length:
///   db       loudness, dB × 10 (0 = full scale)
///   onset    how sharply the sound changes (positive spectral flux), 0–100 against the song's strongest (its 99th percentile)
///   pitch    f0 as a MIDI note × 100 (6900 = A4, 440 Hz), 0 where nothing is pitched
///   clarity  how periodic the frame is, 0–100 (YIN: 100 × (1 − aperiodicity))
///   voiced   1 where the voice sounds (`floor` dB or more on the stem), else 0: consonants too, so not the same as pitch > 0
final class Features: Codable {
    var format = 1
    var source: String            // "vocals": the Demucs stem (the light follows only that: a mix's loudness is the band's)
    var hop = 0.01                // seconds a frame
    var floor: Double             // dB from which a frame is voice
    var db: [Int], onset: [Int], pitch: [Int], clarity: [Int], voiced: [Int]

    init(source: String, floor: Double, db: [Int], onset: [Int], pitch: [Int], clarity: [Int], voiced: [Int]) {
        self.source = source; self.floor = floor; self.db = db; self.onset = onset; self.pitch = pitch; self.clarity = clarity; self.voiced = voiced
    }

    static func url(_ key: String) -> URL { cacheDir.appendingPathComponent(key + ".features.json") }
    static func read(_ key: String) -> Features? { (try? Data(contentsOf: url(key))).flatMap { try? JSONDecoder().decode(Features.self, from: $0) } }
    func write(_ key: String) { if let d = try? JSONEncoder().encode(self) { try? d.write(to: Features.url(key)) } }

    var count: Int { db.count }
    func frame(_ t: Double) -> Int { max(0, min(count - 1, Int((t / hop).rounded(.down)))) }
    func time(_ k: Int) -> Double { Double(k) * hop }
    func isVoiced(_ k: Int) -> Bool { k >= 0 && k < count && voiced[k] == 1 }
    func sustained(_ k: Int) -> Bool { isVoiced(k) && (k..<(k + 8)).filter(isVoiced).count >= 5 }   // a voice, not a click
    /// Voiced in 95 % or more of the frames within a second either side (cadence.js `saturated`).
    func saturated(_ k: Int) -> Bool {
        let lo = max(0, k - 100), hi = min(count, k + 100)
        return hi > lo && Double((lo..<hi).filter { voiced[$0] == 1 }.count) >= Double(hi - lo) * 0.95
    }
    /// In [a, b]: the frame where the loudness rises most, its next 150 ms over its last (dB × 10), by 4 dB or more
    /// (cadence.js `rise`; the first of equals).
    func rise(_ a: Int, _ b: Int) -> Int? {
        var best: Int? = nil, br = 40.0
        let lo = max(15, a), hi = min(count - 15, b)
        guard lo <= hi else { return nil }
        for k in lo...hi {
            var before = 0, after = 0
            for j in 1...15 { before += db[k - j]; after += db[k + j - 1] }
            let r = Double(after - before) / 15
            if r > br { br = r; best = k }
        }
        return best
    }

    /// Frames where the voice comes back after a silence (a breath, a pause, a stop consonant's closure) and goes on:
    /// the frame, and how long it was quiet before (seconds), in [a, b).
    func entries(_ a: Double, _ b: Double) -> [(k: Int, gap: Double)] {
        var out: [(k: Int, gap: Double)] = []
        let lo = max(1, frame(a)), hi = min(count, Int((b / hop).rounded(.up)))
        guard lo < hi else { return out }
        for k in lo..<hi where voiced[k] == 1 && voiced[k - 1] == 0 && sustained(k) {
            var g = 0
            while k - g - 1 >= 0 && voiced[k - g - 1] == 0 && g < 200 { g += 1 }
            out.append((k, Double(g) * hop))
        }
        return out
    }

    /// 16 kHz mono audio measured. Pitch by YIN (70–1000 Hz, 32 ms window), onsets by spectral flux (512-point FFT).
    static func measure(_ s: [Float], source: String) -> Features {
        let dbs = frameDB(s), n = dbs.count
        let sorted = dbs.sorted()
        let quiet = sorted.isEmpty ? -100 : Double(sorted[sorted.count / 10]), loud = sorted.isEmpty ? 0 : Double(sorted[sorted.count * 95 / 100])
        // the loudness gate refine() uses on a stem (on a mix, the one it uses there)
        let floor = source == "vocals" ? max(quiet + 12, loud - 30) : quiet + max(10, 0.35 * (loud - quiet))

        // onsets: rise of log magnitude summed over 0–5 kHz, frame to frame
        let N = 512, half = N / 2, log2n = vDSP_Length(9), bins = 160
        let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(fft) }
        var window = [Float](repeating: 0, count: N); vDSP_hann_window(&window, vDSP_Length(N), Int32(vDSP_HANN_NORM))
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half), mags = [Float](repeating: 0, count: half)
        var buf = [Float](repeating: 0, count: N), prev = [Float](repeating: 0, count: bins)
        var flux = [Float](repeating: 0, count: n)
        for k in 0..<n {
            let c = k * 160 + 80
            for j in 0..<N { let i = c - half + j; buf[j] = i >= 0 && i < s.count ? s[i] * window[j] : 0 }
            re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { m in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: m.baseAddress!)
                buf.withUnsafeBufferPointer { b in
                    b.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            } }
            var f: Float = 0
            for b in 1..<bins {
                let l = log1p(1000 * sqrt(mags[b]))
                if k > 0 { f += max(0, l - prev[b]) }
                prev[b] = l
            }
            flux[k] = f
        }
        let top = flux.sorted()[min(n - 1, max(0, n * 99 / 100))]

        // pitch: YIN on frames with voice in them
        let W = 512, tmin = 16, tmax = 228, need = W + tmax
        var seg = [Float](repeating: 0, count: need), sq = [Double](repeating: 0, count: need + 1)
        var r = [Float](repeating: 0, count: tmax + 1), cmnd = [Double](repeating: 1, count: tmax + 1)
        var pitch = [Int](repeating: 0, count: n), clarity = [Int](repeating: 0, count: n)
        for k in 0..<n where Double(dbs[k]) >= floor - 6 {
            let a = k * 160 + 80 - need / 2
            for j in 0..<need { let i = a + j; seg[j] = i >= 0 && i < s.count ? s[i] : 0 }
            for j in 0..<need { sq[j + 1] = sq[j] + Double(seg[j] * seg[j]) }
            seg.withUnsafeBufferPointer { p in vDSP_conv(p.baseAddress!, 1, p.baseAddress!, 1, &r, 1, vDSP_Length(tmax + 1), vDSP_Length(W)) }
            let e0 = sq[W]
            guard e0 > 1e-6 else { continue }
            var run = 0.0
            for t in 1...tmax {
                let d = max(0, e0 + (sq[t + W] - sq[t]) - 2 * Double(r[t]))
                run += d
                cmnd[t] = run > 0 ? d * Double(t) / run : 1
            }
            var best = tmin
            if let first = (tmin...tmax).first(where: { cmnd[$0] < 0.15 }) {
                best = first
                while best < tmax && cmnd[best + 1] < cmnd[best] { best += 1 }
            } else { best = (tmin...tmax).min { cmnd[$0] < cmnd[$1] }! }
            let ap = cmnd[best]
            clarity[k] = Int((100 * max(0, 1 - ap)).rounded())
            guard ap < 0.35, best > tmin, best < tmax else { continue }
            let y0 = cmnd[best - 1], y1 = cmnd[best], y2 = cmnd[best + 1], den = y0 - 2 * y1 + y2
            let tau = Double(best) + (abs(den) > 1e-9 ? 0.5 * (y0 - y2) / den : 0)
            pitch[k] = Int((100 * (69 + 12 * log2(16000 / tau / 440))).rounded())
        }
        return Features(source: source, floor: (floor * 10).rounded() / 10,
                        db: dbs.map { Int(($0 * 10).rounded()) },
                        onset: flux.map { top > 0 ? Int(min(100, 100 * $0 / top).rounded()) : 0 },
                        pitch: pitch, clarity: clarity, voiced: dbs.map { Double($0) >= floor ? 1 : 0 })
    }
}

/// Word times from Whisper and the lyrics say roughly where words start and nothing of how they're sung: the light
/// wiped each word at an even pace, finished a held note early and sat on it until the next word. With the song's
/// Features, a word starts on its onset, lasts as long as the voice holds it (into the next word when it runs on,
/// to the breath when it stops), and the light inside it moves as the voice spends itself (loudness over the floor):
/// slower through a held note, still through a breath.
enum Cadence {
    /// Can a song's words be trusted enough to show them? (item 22; the same rule as Gallery's cadence.js
    /// `confidence`.) Not where many voices sing at once (a choir) or few words were heard surely, unless the song's
    /// own lyrics were found and its lines are theirs. Speech is never turned off.
    ///   dense  a single voice holds its notes: pitch rarely jumps > 1.5 semitones frame to frame (≤ 5 %) and runs
    ///          on (median ≥ 8 frames); a choir hops between voices (Whitacre: 7.3 %, 4 frames).
    ///          Dense: jumps ≥ 6 % with runs ≤ 6 frames, or jumps ≥ 9 %. Unknown without the voice.
    ///   rate   words heard a minute: under 15 with no voice measured. `duration` 0: over what's heard so far.
    static func confidence(_ lines: [Line], _ f: Features?, duration: Double) -> (off: Bool, dense: Bool?) {
        let ls = lines.filter { !$0.words.isEmpty }
        var speech = 0, lyric = 0, heard = 0, words = 0, last = 0.0
        for l in ls {
            if l.id < 2_000_000 { speech += 1 } else if l.id < 3_000_000 { lyric += 1 } else if l.id < 4_000_000 { heard += 1 }
            words += l.words.count; last = max(last, l.words.last?.end ?? 0)
        }
        let song = lyric + heard > speech, fromLyrics = lyric > 0 && lyric >= heard
        let d = duration > 0 ? duration : last, rate = d > 0 ? Double(words) / d * 60 : 0
        var dense: Bool? = nil
        if let f, f.source == "vocals" {
            let p = f.pitch, v = f.voiced, n = min(p.count, v.count)
            func on(_ k: Int) -> Bool { v[k] == 1 && p[k] > 0 }
            var pitched = 0, pairs = 0, jumps = 0, run = 0, runs: [Int] = []
            for k in 0..<n {
                if on(k) {
                    pitched += 1; run += 1
                    if k + 1 < n && on(k + 1) { pairs += 1; if abs(p[k + 1] - p[k]) > 150 { jumps += 1 } }
                } else if run > 0 { runs.append(run); run = 0 }
            }
            if run > 0 { runs.append(run) }
            if pitched >= 500 && pairs > 0 {
                runs.sort()
                let j = Double(jumps) / Double(pairs), r = runs[runs.count / 2]
                dense = (j >= 0.06 && r <= 6) || j >= 0.09
            }
        }
        return (song && !fromLyrics && (dense.map { $0 } ?? (rate < 15)), dense)
    }

    /// The measured voice of what's playing (set every frame on the main thread); nil: the light runs by the clock.
    nonisolated(unsafe) static var track: Features? { didSet { if track !== oldValue { curves = [:]; notes = [:]; top = nil } } }
    nonisolated(unsafe) static var curves: [String: [Float]] = [:]
    nonisolated(unsafe) static var notes: [String: Double] = [:]   // a word's middle note (MIDI × 100)
    nonisolated(unsafe) static var top: Double? = nil              // the voice's loud end (95th percentile, dB)

    /// The voice under the light at `t` (notes 33), all 0 at rest:
    ///   swell  0…1  loud and clear, more so the longer a note is held: a belt is full and bright
    ///   lift   pt   the note against the word's middle one (a semitone is 1.5 pt, ±6): the contour bends the light
    ///   shiver −1…1 the note against its last quarter second (±50 cents): vibrato, a gentle oscillation
    ///   thin   0…1  voice with little tone and little body, or a sudden break in the pitch: breathy, soft, cracking
    ///   soft   0…1  a clear vowel flowing (a feathered edge); an attack, a consonant, keeps the edge crisp
    struct Voice { var swell: CGFloat = 0, lift: CGFloat = 0, shiver: CGFloat = 0, thin: CGFloat = 0, soft: CGFloat = 0 }

    static func voice(_ b: Beat, _ t: Double) -> Voice? {
        guard let f = track, f.source == "vocals", f.count > 20, t >= b.start else { return nil }
        let k = f.frame(t)
        func mean(_ a: [Int], _ r: ClosedRange<Int>, pitched: Bool = false) -> Double? {
            var sum = 0, n = 0
            for i in max(0, r.lowerBound)...min(f.count - 1, r.upperBound) where !pitched || a[i] > 0 { sum += a[i]; n += 1 }
            return n == 0 ? nil : Double(sum) / Double(n)
        }
        if top == nil {
            let v = (0..<f.count).filter(f.isVoiced).map { f.db[$0] }.sorted()
            top = v.isEmpty ? f.floor + 20 : Double(v[v.count * 95 / 100])
        }
        var out = Voice()
        guard f.isVoiced(k) else { out.thin = 0.35; return out }
        let e = min(1.15, max(0, ((mean(f.db, k - 3...k + 3) ?? f.floor) - f.floor) / max(6, top! - f.floor)))
        let clear = (mean(f.clarity, k - 3...k + 3) ?? 0) / 100
        let note = f.pitch[k]
        // held: how long the note has run on unbroken (up to 0.8 s)
        var held = 0
        while held < 80, k - held - 1 >= 0, f.pitch[k - held - 1] > 0, abs(f.pitch[k - held - 1] - note) < 150 { held += 1 }
        out.swell = CGFloat(min(1, e * (0.55 + 0.45 * clear) + (note > 0 ? 0.3 * Double(held) / 80 : 0)))
        out.thin = CGFloat(min(1, max(0, 0.55 - clear) * 1.8 * max(0, 1.1 - e)))
        if note > 0, k >= 3, f.pitch[k - 3] > 0, abs(f.pitch[k - 3] - note) > 300 { out.thin = max(out.thin, 0.8) }   // a crack
        if note > 0 {
            let key = "\(b.start)|\(b.end)"
            let mid: Double
            if let m = notes[key] { mid = m } else {
                mid = mean(f.pitch, f.frame(b.start)...f.frame(max(b.start, b.end)), pitched: true) ?? Double(note)
                if notes.count > 4000 { notes = [:] }
                notes[key] = mid
            }
            out.lift = CGFloat(max(-6, min(6, (Double(note) - mid) / 100 * 1.5)))
            if let local = mean(f.pitch, k - 12...k + 12, pitched: true), held >= 12 { out.shiver = CGFloat(max(-1, min(1, (Double(note) - local) / 50))) }
            out.soft = CGFloat(clear > 0.6 ? min(1, Double(held) / 15) * (1 - min(1, Double(f.onset[k]) / 60)) : 0)
        }
        return out
    }

    /// The lines with their words timed to the voice. Gallery runs the same rules (gallery/src/client/cadence.js),
    /// so the web player and the iOS app light the same word at the same moment as Recense: change one, change the other.
    static func fit(_ lines: [Line], _ f: Features) -> [Line] {
        guard f.source == "vocals", f.count > 20 else { return lines }
        // decided on times to the millisecond, as Gallery keeps them (its cadence.js runs these same rules)
        let ms = { (x: Double) in (x * 1000).rounded() / 1000 }
        let flat = lines.flatMap(\.words).map { $0.timed(ms($0.start), ms($0.end)) }, n = flat.count
        guard n > 0 else { return lines }
        // an onset counts when it stands out among the voice's own (its 60th percentile, at least a tenth of the strongest)
        let peaks = (1..<(f.count - 1)).filter { f.isVoiced($0) && f.onset[$0] > 0 && f.onset[$0] >= f.onset[$0 - 1] && f.onset[$0] >= f.onset[$0 + 1] }
            .map { f.onset[$0] }.sorted()
        let strong = max(10, peaks.isEmpty ? 10 : peaks[peaks.count * 6 / 10])
        // the next word sung after each, in its line or the next
        var next = [Double](repeating: .infinity, count: n)
        for i in stride(from: n - 2, through: 0, by: -1) { next[i] = flat[i + 1].start > flat[i].start ? flat[i + 1].start : next[i + 1] }
        var s = flat.map(\.start), e = flat.map(\.end), legato = [Bool](repeating: false, count: n)
        // a line's first word, or one after a pause in what was heard
        var opens = [Bool](repeating: false, count: n), at = 0
        for l in lines { if !l.words.isEmpty { opens[at] = true }; at += l.words.count }
        for i in 1..<max(1, n) where flat[i - 1].end < flat[i].start - 0.15 { opens[i] = true }
        for i in 0..<n {
            let w = flat[i], after = min(next[i], w.start + 8), lower = i > 0 ? s[i - 1] + 0.03 : 0
            // Where its voice comes in, when the recognizer's start is plainly off (item 22: the light lagged the song):
            //  · run into the word before it (heard starting before that one ended), over a silence of 200 ms or more:
            //    it starts where the voice comes back after that silence, if it then sings on for 0.25 s ("Soro-soro"
            //    heard from 31.9 s in Sororité, over the end of the line before; sung from 32.9 s)
            //  · opening a line or following a pause (or after a breath of 100 ms or more), heard inside a voice that
            //    came in less than 0.4 s before: it starts where that voice came in. A recognizer times a sung word by
            //    its vowel, late (Whisper by 0.1 s at the median, the on-device ears by 0.2 s), and a light that trails
            //    the voice shows far sooner than one that leads it.
            // Never later than heard otherwise: a long word may be a held note of its own ("Reuss" over 1.3 s at 105 s),
            // and a leap inside one is as likely its own next syllable as the end of the note before it.
            var entry: Double? = nil
            let end = min(w.end, after), hk = f.frame(w.start)
            if i > 0, w.start < flat[i - 1].end + 0.05 {
                var quiet = 0
                for k in hk..<max(hk, f.frame(end - 0.25)) {
                    if !f.isVoiced(k) { quiet += 1; continue }
                    if quiet >= 20, f.sustained(k), (k..<min(f.count, k + 25)).filter(f.isVoiced).count >= 20 { entry = f.time(k); break }
                    quiet = 0
                }
            }
            if entry == nil, f.isVoiced(hk), let c = f.entries(max(lower + 0.12, w.start - 0.4), w.start).last,
               c.gap >= (opens[i] ? 0.05 : 0.1) {
                entry = f.time(c.k)
            }
            //  · a line opening inside a voice that never falls silent (a stem the orchestra bleeds into: Variations at
            //    1:13, voiced in every frame for seconds): the loudness says where the singer comes in, where it rises
            //    most (4 dB or more), from just before the heard start to 0.6 s after; the words after it follow it on
            if entry == nil, opens[i], f.saturated(hk),
               let k = f.rise(f.frame(max(lower, w.start - 0.12)), f.frame(min(w.end - 0.05, w.start + 0.6))) {
                entry = f.time(k)
            }
            if let entry { s[i] = entry }
            // else the onset nearest the recognizer's start, as strong as can be: within 120 ms, or from silence up to
            // 350 ms late (a late entry)
            let reach = f.isVoiced(f.frame(w.start)) ? 0.12 : 0.35
            let lo = f.frame(max(lower, w.start - 0.12)), hi = f.frame(min(after - 0.08, w.start + reach))
            if entry == nil, lo <= hi {
                let score = { (k: Int) in Double(f.onset[k]) * (1 - abs(f.time(k) - w.start) / 0.4) }
                if let k = (lo...hi).filter({ k in f.onset[k] >= strong && f.sustained(k) && (k == 0 || f.onset[k] >= f.onset[k - 1])
                                                && (k + 1 >= f.count || f.onset[k] >= f.onset[k + 1]) }).max(by: { score($0) < score($1) }) {
                    s[i] = f.time(k)
                }
            }
            s[i] = max(s[i], lower)
            // held while the voice holds it: any voice up to Whisper's end (consonants too), then one note running on
            // unbroken (pitched in most of any 100 ms: vibrato, a melisma's steps; a stray pitched frame on a consonant
            // doesn't count), not a new syllable after a consonant (an ad-lib, a backing line) — into the next word
            // when it runs on into it, else to where it stops
            let stop = f.frame(after), own = f.frame(min(w.end, after))
            let note = { (k: Int) in f.isVoiced(k) && f.pitch[k] > 0 }
            var k = f.frame(s[i]), last = -1, quiet = 0, broke = false
            while k < stop {
                if k < own {
                    if f.isVoiced(k) { last = k; quiet = 0 } else { quiet += 1; if quiet >= 15 { broke = true; break } }
                } else if note(k) { last = k }
                else if (max(own, k - 9)...k).filter(note).count <= 3 && k - own >= 6 { broke = true; break }
                k += 1
            }
            if last < 0 { e[i] = min(w.end, after) }                                   // no voice under it: as it was
            else if !broke && after < .infinity { e[i] = after; legato[i] = after == next[i] }
            else { e[i] = f.time(last + 1) }
            e[i] = min(max(e[i], s[i] + 0.05), s[i] + 8)
        }
        // a word ends where the next starts, once those have moved
        for i in 0..<n where next[i] < .infinity {
            guard let j = (i + 1..<n).first(where: { flat[$0].start > flat[i].start }) else { continue }
            e[i] = legato[i] ? max(s[i] + 0.05, s[j]) : min(e[i], max(s[i] + 0.05, s[j]))
        }
        // then a song's words hung on the voice's own syllables (cadence.swift): the audio decides when each is sung
        // and for how long; a written word that isn't sung is marked so
        let (syl, un) = align(lines, f, flat, &s, &e)
        var i = 0
        return lines.map { l in
            Line(id: l.id, words: l.words.map { w in
                defer { i += 1 }
                var x = w.timed(ms(s[i]), ms(e[i])); x.syl = syl[i].map { $0.map { Syl(c: $0.c, s: ms($0.s), e: ms($0.e)) } }
                if un[i] { x.un = true }
                return x
            }, english: l.english, draft: l.draft, fixed: l.fixed)
        }
    }

    /// How much of the voice in a word has been spent at each frame from its start (0…1, one more value than frames).
    static func curve(_ f: Features, _ start: Double, _ end: Double) -> [Float]? {
        let a = f.frame(start), b = min(f.count, max(a + 1, Int((end / f.hop).rounded())))
        guard b - a >= 3 else { return nil }
        let fl = Float(f.floor)
        let w = (a..<b).map { k in f.voiced[k] == 1 ? min(30, max(1, Float(f.db[k]) / 10 - fl + 1)) : 0 }
        let mean = w.reduce(0, +) / Float(w.count)
        guard mean > 0 else { return nil }
        var acc: [Float] = [0], sum: Float = 0
        for x in w { sum += max(x, 0.03 * mean); acc.append(sum) }        // a breath inside a word all but holds the light
        return acc.map { $0 / sum }
    }

    /// How far through a word the light is at t (0…1): by the voice spent, or the clock where nothing was measured.
    /// A sung word timed syllable by syllable sweeps through its letters without stopping: each syllable's letters are
    /// spread over the time it's sung, up to where the next comes in (or 0.25 s past its end, so a breath isn't swept
    /// through), so the light slows on a held "on" and hurries through a quick var-i-a (gallery.js `fillOf`).
    static func progress(_ b: Beat, _ t: Double) -> Double {
        if let c = b.c, c.count > 1 {        // traced by a finger: joined straight between its moments (cadence.js `fill`)
            let u = max(0, min(1, (t - b.start) / max(0.05, b.end - b.start))) * Double(c.count - 1)
            let j = min(c.count - 2, Int(u))
            return c[j] + (c[j + 1] - c[j]) * (u - Double(j))
        }
        if let k = b.k {                     // timed by the listener: one sweep shaped by k (cadence.js `fill`)
            let u = max(0, min(1, (t - b.start) / max(0.05, b.end - b.start)))
            return pow(u, pow(2, -1.5 * k))
        }
        if let syl = b.syl, !syl.isEmpty, !b.text.isEmpty {
            let n = Double(b.text.unicodeScalars.count)
            var c0 = 0.0
            for (k, y) in syl.enumerated() {
                let end = k + 1 < syl.count ? min(syl[k + 1].s, y.e + 0.25) : y.e
                if t < y.s { return c0 / n }
                if t < end { return min(1, (c0 + (Double(y.c) - c0) * (t - y.s) / max(0.05, end - y.s)) / n) }
                c0 = Double(y.c)
            }
            return 1
        }
        let clock = (t - b.start) / max(0.05, b.end - b.start)
        guard let f = track else { return clock }
        let key = "\(b.start)|\(b.end)"
        let c: [Float]
        if let m = curves[key] { c = m }
        else {
            guard let m = curve(f, b.start, b.end) else { return clock }
            if curves.count > 4000 { curves = [:] }
            curves[key] = m; c = m
        }
        let x = (t - f.time(f.frame(b.start))) / f.hop, i = Int(x.rounded(.down))
        guard i >= 0 else { return 0 }
        guard i + 1 < c.count else { return 1 }
        return Double(c[i] + (c[i + 1] - c[i]) * Float(x - Double(i)))
    }
}

// ---------- content identity: the same recording, whatever the source ----------
// A transcript is keyed by address, so the same song from YouTube, a downloaded mp3 or Music was transcribed and
// translated again from scratch — a day's quota spent on something already done. Each piece's audio gets a
// fingerprint instead (Haitsma–Kalker, the Philips scheme): one 32-bit word per 128 ms, each bit the sign of how
// the (log) energy difference between two neighbouring bands (33 bands, 300–2000 Hz) changed since the frame before.
// Re-encoding (YouTube's AAC vs. an mp3), level and EQ barely move those signs; a different recording flips half.
enum Fingerprint {
    static let sr = 16000.0, frame = 4096, hop = 2048, phases = 4
    static let step = Double(hop) / sr                  // seconds per word
    static let maxSeconds = 600.0                       // what's kept: a song whole, a long piece's first 10 min
    static let edges: [Int] = (0...33).map { Int(300 * pow(2000.0 / 300, Double($0) / 33) / sr * Double(frame)) }

    /// One word per hop from `start` samples in.
    static func words(_ s: [Float], start: Int = 0) -> [UInt32] {
        let n = (s.count - start - frame) / hop + 1
        guard n > 1, let setup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: frame)
        vDSP_hann_window(&window, vDSP_Length(frame), Int32(vDSP_HANN_NORM))
        var x = [Float](repeating: 0, count: frame), re = [Float](repeating: 0, count: frame / 2),
            im = [Float](repeating: 0, count: frame / 2), power = [Float](repeating: 0, count: frame / 2)
        var prev: [Float] = [], out: [UInt32] = []
        out.reserveCapacity(n)
        for f in 0..<n {
            s.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + start + f * hop, 1, window, 1, &x, 1, vDSP_Length(frame)) }
            re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { i in
                var z = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                x.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &z, 1, vDSP_Length(frame / 2)) }
                vDSP_fft_zrip(setup, &z, 1, 12, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&z, 1, &power, 1, vDSP_Length(frame / 2))
            } }
            let e = (0..<33).map { m in log(power[edges[m]..<edges[m + 1]].reduce(0, +) + 1e-9) }   // log: gain and EQ cancel
            if !prev.isEmpty {
                var w: UInt32 = 0
                for m in 0..<32 where (e[m] - e[m + 1]) - (prev[m] - prev[m + 1]) > 0 { w |= 1 << m }
                out.append(w)
            }
            prev = e
        }
        return out
    }

    /// The first `maxSeconds` of a file at 16 kHz mono, decoded two minutes at a time (whole, a long piece in its
    /// own format would take hundreds of MB).
    static func read(_ f: URL) -> [Float] {
        var out: [Float] = [], a = 0.0
        while a < maxSeconds, let s = try? decodeChunk(f, from: a, to: min(maxSeconds, a + 120)), !s.isEmpty { out += s; a += 120 }
        return out
    }

    /// The words of `s` (16 kHz mono) at each of `phases` sub-hop offsets: a match can then line up within 32 ms.
    static func phased(_ s: [Float]) -> [[UInt32]] { (0..<phases).map { words(s, start: $0 * hop / phases) } }

    /// Where `q` sits best in `ref`: the word index there and the share of bits that differ.
    static func locate(_ q: ArraySlice<UInt32>, in ref: [UInt32]) -> (at: Int, ber: Double) {
        guard q.count > 0, ref.count >= q.count else { return (0, 1) }
        var best = (at: 0, errors: Int.max)
        let qa = Array(q)
        ref.withUnsafeBufferPointer { r in
            for j in 0...(r.count - qa.count) {
                var e = 0
                for k in 0..<qa.count { e += (qa[k] ^ r[j + k]).nonzeroBitCount; if e >= best.errors { break } }
                if e < best.errors { best = (j, e) }
            }
        }
        return (best.at, Double(best.errors) / Double(32 * qa.count))
    }

    /// Whether the new audio (phased words of its first `maxSeconds`) is the recording `ref` holds, and if so its
    /// offset (new time − ref time). Two stretches of ~15 s, far apart and with sound in them, must both match
    /// closely (≤ 30 % bits off; another recording gives ~50 %) at the same offset — one alone could be a shared
    /// sample or an intro.
    static func offset(_ new: [[UInt32]], in ref: [UInt32]) -> (shift: Double, ber: Double)? {
        let w = 120, n = new[0].count
        guard n >= 2 * w, ref.count >= w else { return nil }
        var found: [(shift: Double, ber: Double)] = []
        for share in [0.3, 0.7] {
            var q0 = min(n - w, max(0, Int(Double(n) * share) - w / 2))
            // Silence is all zero words, which match any other silence: start where there's sound.
            while q0 + w < n, new[0][q0..<(q0 + w)].filter({ $0 == 0 }).count > w / 10 { q0 += w / 4 }
            guard q0 + w <= n else { return nil }
            var best: (shift: Double, ber: Double) = (0, 1)
            for (p, words) in new.enumerated() where words.count >= q0 + w {
                let (at, ber) = locate(words[q0..<(q0 + w)], in: ref)
                if ber < best.ber { best = ((Double(q0 * hop + p * hop / phases) - Double(at * hop)) / sr, ber) }
            }
            found.append(best)
        }
        guard found.allSatisfy({ $0.ber <= 0.3 }), abs(found[0].shift - found[1].shift) < 0.3 else { return nil }
        return ((found[0].shift + found[1].shift) / 2, max(found[0].ber, found[1].ber))
    }

    static func encode(_ w: [UInt32]) -> String { w.withUnsafeBytes { Data($0) }.base64EncodedString() }
    static func decode(_ s: String) -> [UInt32] {
        guard let d = Data(base64Encoded: s) else { return [] }
        return d.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    }
}

// ---------- library: what was done once is never paid for again ----------
// Three things grow here, each kept once however often it comes back:
// - pieces: the fingerprint of every recording that owns a transcript. New audio is checked against them before
//   anything is spent on it; a match makes its source an alias of that transcript (with the time offset between
//   the two), so a song played from YouTube, then from the mp3, then in Music is one transcript, done once.
// - aliases: source key → the transcript it plays, found from then on without even fetching the audio.
// - memory: every translation made, by the line's words — a chorus, a live version or cover of a song heard
//   before, a podcast's recurring intro cost nothing the second time. Apple's Translation's lines and those that
//   passed translateBatch's checks go in; older drafts and given-up lines ("…") never do.
// It's exact recall, not a model trained on its own output: that would drift on its own mistakes and could never be
// checked. Both files are mirrored to keep/ in R2 (never expires) and merged back on launch, so nothing is lost
// with this Mac's cache.
@MainActor enum Library {
    struct Piece: Codable { var d: Double; var fp: String; var title: String? }
    struct Alias: Codable { var key: String; var shift: Double; var d: Double }   // shift: source time − transcript time
    struct Index: Codable { var pieces: [String: Piece] = [:]; var aliases: [String: Alias] = [:]; var tried: Set<String>? }
    static let indexURL = cacheDir.appendingPathComponent("library.json"), memoryURL = cacheDir.appendingPathComponent("translations.json")
    static var index = (try? JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))) ?? Index()
    static var memory = (try? JSONDecoder().decode([String: [EnWord]].self, from: Data(contentsOf: memoryURL))) ?? [:]
    static var dirty = (index: false, memory: false), written = Date.distantPast
    static var words: [String: [UInt32]] = [:]          // decoded fingerprints

    /// The transcript a source plays, and how far its clock runs ahead of that transcript's.
    static func resolve(_ src: String) -> Alias? { index.aliases[src] }

    static func fingerprint(_ key: String) -> [UInt32] {
        if let w = words[key] { return w }
        let w = index.pieces[key].map { Fingerprint.decode($0.fp) } ?? []
        words[key] = w
        return w
    }

    /// Lengths two copies of one recording can differ by (an intro, an outro, an ad).
    static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= max(30, 0.2 * min(a, b)) }

    /// Fingerprints the new audio, files it, and returns the transcript it already has under another key, if any:
    /// a finished one, or one being made from the very same audio (any offset would make its chunks mean other times).
    static func identify(_ src: String, file: URL, duration: Double, title: String?, finishedOnly: Bool = false) async -> Alias? {
        let phased = await Task.detached { Fingerprint.phased(Fingerprint.read(file)) }.value
        guard let own = phased.first, own.count > 240 else { return nil }
        let refs = index.pieces.filter { $0.key != src && close($0.value.d, duration) }.map { ($0.key, fingerprint($0.key)) }
        let hits = await Task.detached {
            refs.compactMap { k, w in Fingerprint.offset(phased, in: w).map { (key: k, shift: $0.shift, ber: $0.ber) } }.sorted { $0.ber < $1.ber }
        }.value
        index.pieces[src] = Piece(d: duration, fp: Fingerprint.encode(own), title: title); words[src] = own; dirty.index = true
        for h in hits {
            await Store.restoreTranscript(h.key)
            guard let c = Episode.Cache.read(h.key) else { continue }
            let d = index.pieces[h.key]?.d ?? c.duration
            let same = abs(h.shift) < 0.05 && abs(d - duration) < 1
            guard c.complete == true || (same && !finishedOnly) else { continue }
            log(String(format: "heard before: same recording as %@ (%+.2f s, %.0f%% bits off) — its transcript is reused", h.key, h.shift, h.ber * 100))
            return Alias(key: h.key, shift: h.shift, d: duration)
        }
        flush()
        return nil
    }

    static func alias(_ src: String, _ a: Alias) {
        index.aliases[src] = a
        index.pieces[src] = nil; words[src] = nil          // one recording, one fingerprint
        dirty.index = true; flush(force: true)
    }

    static func memoKey(_ text: String) -> String { text.lowercased() }
    static func recall(_ text: String) -> [EnWord]? { memory[memoKey(text)] }
    static func remember(_ text: String, _ en: [EnWord]) {
        guard !en.isEmpty, !(en.count == 1 && en[0].w == "…"), memory[memoKey(text)] == nil else { return }
        memory[memoKey(text)] = en; dirty.memory = true
    }
    /// Every model translation in a transcript.
    static func absorb(_ lines: [Line]) {
        for l in lines where l.draft != true { if let e = l.english { remember(lineKey(l), e) } }
    }

    /// Written every two minutes at most (at once when forced: a new alias, quitting), encoded off the main thread.
    /// library.json is megabytes of fingerprints and translations.json more than one: rewritten every 20 s while
    /// translating, they stalled the subtitles each time and wrote ~200 KB/s (macOS flagged Recense's disk writes).
    static let writer = DispatchQueue(label: "recense.library", qos: .utility)
    static func flush(force: Bool = false) {
        guard dirty.index || dirty.memory, force || Date().timeIntervalSince(written) > 120 else { return }
        let idx = dirty.index ? index : nil, mem = dirty.memory ? memory : nil, iu = indexURL, mu = memoryURL
        dirty = (false, false); written = Date()
        let write: @Sendable () -> Void = {
            if let idx, let d = try? JSONEncoder().encode(idx) { try? d.write(to: iu, options: .atomic) }
            if let mem, let d = try? JSONEncoder().encode(mem) { try? d.write(to: mu, options: .atomic) }
        }
        if force { writer.sync(execute: write) } else { writer.async(execute: write) }
    }

    /// keep/'s copies merged in (another Mac's, or this one's before its cache was cleared): union, this Mac wins.
    static func pull() async {
        guard Store.r2 else { return }
        for (name, local) in [("library.json", indexURL), ("translations.json", memoryURL), ("glossary.json", Glossary.url), ("lexicon.json", Lexicon.url)] {
            guard let (d, resp) = try? await URLSession.shared.data(for: Store.request("GET", name, dir: "keep")),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
            if local == Glossary.url { _ = Glossary.merge(d); continue }
            if local == Lexicon.url { _ = Lexicon.merge(d); continue }
            if local == indexURL, let r = try? JSONDecoder().decode(Index.self, from: d) {
                let before = index.pieces.count + index.aliases.count
                index.pieces.merge(r.pieces) { a, _ in a }; index.aliases.merge(r.aliases) { a, _ in a }
                index.tried = (index.tried ?? []).union(r.tried ?? [])
                for k in index.aliases.keys { index.pieces[k] = nil }
                if index.pieces.count + index.aliases.count != before { dirty.index = true }
            }
            if local == memoryURL, let r = try? JSONDecoder().decode([String: [EnWord]].self, from: d) {
                let before = memory.count
                memory.merge(r) { a, _ in a }
                if memory.count != before { dirty.memory = true }
            }
        }
        flush(force: true)
    }

    /// Sends a changed library file (or the glossary) to keep/ (from the sweep).
    static func mirror() async {
        flush(force: true)
        for u in [indexURL, memoryURL, Glossary.url, Lexicon.url] {
            guard let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970,
                  Store.mirrored[u.lastPathComponent] != m else { continue }
            if await Store.upload(u, dir: "keep") { Store.mirrored[u.lastPathComponent] = m }
        }
    }

    /// Once per transcript made before the library existed: its translations go into memory, and if it's finished
    /// and its audio is still on this Mac or in tmp/, its fingerprint is filed — a transcript already made twice
    /// (two sources of one recording) becomes an alias of the first.
    static func backfill() async {
        var keys = Set(((try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? [])
            .filter { $0.hasSuffix(".v2.json") }.map { String($0.prefix(24)) })
        keys.formUnion(await Store.keepKeys())
        let fresh = keys.subtracting(index.tried ?? []).subtracting(index.pieces.keys).subtracting(index.aliases.keys)
        guard !fresh.isEmpty else { return }
        log("library: filing \(fresh.count) earlier transcript(s)")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("recense-library")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for key in fresh.sorted() {
            index.tried = (index.tried ?? []).union([key]); dirty.index = true
            await Store.restoreTranscript(key)
            guard let c = Episode.Cache.read(key) else { continue }
            absorb(c.lines)
            guard c.complete == true else { continue }
            let local = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(key + ".") && !$0.lastPathComponent.contains("json") && !$0.lastPathComponent.contains("-vocals") }
            var audio = local
            if audio == nil {
                for name in (c.offsite ?? []).filter({ !$0.contains("-vocals") }) {
                    guard let (tmp, resp) = try? await URLSession.shared.download(for: Store.request("GET", name)),
                          (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
                    let dest = scratch.appendingPathComponent(name)
                    try? FileManager.default.removeItem(at: dest)
                    if (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil { audio = dest; break }
                }
            }
            guard let audio else { continue }
            let d = (try? AVAudioFile(forReading: audio)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? c.duration
            if let a = await identify(key, file: audio, duration: d, title: nil, finishedOnly: true) { alias(key, a) }
            if audio.path.hasPrefix(scratch.path) { try? FileManager.default.removeItem(at: audio) }
            flush()
        }
        flush(force: true)
        log("library: \(index.pieces.count) recording(s), \(index.aliases.count) alias(es), \(memory.count) remembered translation(s)")
    }
}

// ---------- keep/: every transcript in R2, one folder per item ----------
// Every item with sound Recense transcribes — a page's video or podcast, a song in Music, a lecture or a voice memo
// on this Mac, a file in Gallery's Main — is kept the same way, in a folder named by its key: the first 24 hex of
// SHA-256 (cacheKey) of
//   a media address                        its URL without the query (a file on this Mac: its file:// URL)
//   a stream with no lasting address       the page playing it (blob:, mediasource:), without the parameters that
//                                          only steer the player (Episode.key)
//   a file (on this Mac, in Gallery's Main) its content: ContentKey (GalleryJob; the Worker computes the same);
//                                          one transcribed before by its address ("gallery:files/<path>", file://)
//                                          keeps that key
// A recording already transcribed from another source is an alias of that one instead (library.json).
//   keep/<key>/asr.json          the original only: { format, complete, duration, segments: [{ id, start, end, text,
//                                lang?, words }], recense: { what this Mac needs to pick the work up again } }
//   keep/<key>/tr/<lang>.json    en, vi, fr, each written on its own: { lang, complete, updatedAt, lines: { <id>:
//                                { src, text, words?, draft?, same? } } } (src: the words it was made from; same: the
//                                line is in that language already; draft: made on this Mac, a model redoes it)
//   keep/<key>/corrections.json  the listener's edits and Gallery's corrections (Edits; CorrectionSync)
//   keep/<key>/history/<v>.json  Gallery's last 20 versions of corrections.json
//   keep/locks/<key>             Gallery asking for a transcript (GalleryJob): one folder, as it is listed every minute
//   keep/library.json, translations.json, glossary.json   this Mac's library (Library, Glossary)
// This Mac's cache keeps its own shape (<key>.v2.json with the English inside, <key>.edits.json, <key>.tr.vi.json,
// <key>.tr.fr.json); each part goes to keep/ only when it changed, so a language translated again never touches the
// others or the original. The flat files of before (keep/<key>.v2.json, keep/<key>.edits.json) are still read: the
// first read of one writes it out in this layout, never over a file already there and never deleting the old one.
struct TrLine: Codable { var src: String; var text: String?; var words: [EnWord]? = nil; var draft: Bool? = nil; var same: Bool? = nil }
struct TrFile: Codable { var lang: String; var complete: Bool? = nil; var updatedAt: Double? = nil; var lines: [String: TrLine] = [:] }

@MainActor enum Keep {
    struct Segment: Codable { let id: Int; let start: Double; let end: Double; let text: String; var lang: String?; let words: [Word] }
    struct Meta: Codable {
        var done: [Bool]?; var lyricsChecked9: Bool?; var lyrics: [String]?; var heard: [Word]?; var songPipeline: Int?
        var lyricOptions: [[String]]?; var lyricsVerified: Bool?; var language: String?; var publishedTitle: String?
        var redone: [[Double]]?; var offsite: [String]?
        var engine: String?; var lexicon: Int?
    }
    struct ASR: Codable { var format = 1; var complete: Bool?; var duration: Double; var segments: [Segment]; var recense: Meta? }

    static let others = ["vi", "fr"]          // translated after the English (NativeLang.all)
    static func asr(_ key: String) -> String { "\(key)/asr.json" }
    static func tr(_ key: String, _ lang: String) -> String { "\(key)/tr/\(lang).json" }
    static func corrections(_ key: String) -> String { "\(key)/corrections.json" }
    static func features(_ key: String) -> String { "\(key)/features.json" }
    static func trURL(_ key: String, _ lang: String) -> URL { cacheDir.appendingPathComponent("\(key).tr.\(lang).json") }

    static func encode<T: Encodable>(_ v: T) -> Data? {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return try? e.encode(v)
    }
    static func digest(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// The language most of a line's words were heard in.
    nonisolated static func lang(of words: [Word]) -> String? {
        var n: [String: Int] = [:]
        for w in words { if let l = w.lang { n[l, default: 0] += 1 } }
        return n.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// A cached transcript as asr.json and tr/en.json (nil when no line has its English yet).
    static func split(_ c: Episode.Cache) -> (ASR, TrFile?) {
        let segs = c.lines.map { Segment(id: $0.id, start: $0.start, end: $0.end, text: lineKey($0), lang: lang(of: $0.words), words: $0.words) }
        let meta = Meta(done: c.done, lyricsChecked9: c.lyricsChecked9, lyrics: c.lyrics, heard: c.heard, songPipeline: c.songPipeline,
                        lyricOptions: c.lyricOptions, lyricsVerified: c.lyricsVerified, language: c.language, publishedTitle: c.publishedTitle,
                        redone: c.redone, offsite: c.offsite, engine: c.engine, lexicon: c.lexicon)
        var en = TrFile(lang: "en", complete: !c.lines.contains { $0.english == nil })
        for l in c.lines {
            guard let e = l.english else { continue }
            en.lines[String(l.id)] = e.isEmpty ? TrLine(src: lineKey(l), text: nil, same: true)
                : TrLine(src: lineKey(l), text: e.map(\.w).joined(separator: " "), words: e, draft: l.draft)
        }
        return (ASR(complete: c.complete, duration: c.duration, segments: segs, recense: meta), en.lines.isEmpty ? nil : en)
    }

    /// A translation's words for a line made from `texts` (any of them), nil when it has none for them.
    nonisolated static func words(_ f: TrFile?, _ id: Int, _ texts: [String]) -> [EnWord]? {
        guard let t = f?.lines[String(id)], texts.contains(t.src) else { return nil }
        if t.same == true { return [] }
        if let w = t.words, !w.isEmpty { return w }
        let ws = (t.text ?? "").split(whereSeparator: \.isWhitespace).map { EnWord(w: String($0), s: []) }
        return ws.isEmpty ? nil : ws
    }

    /// asr.json and its English as a cached transcript.
    static func join(_ a: ASR, _ en: TrFile?) -> Episode.Cache {
        let lines = a.segments.map { s -> Line in
            let text = s.words.map(\.text).joined(separator: " ")
            return Line(id: s.id, words: s.words, english: words(en, s.id, [text]), draft: en?.lines[String(s.id)]?.draft)
        }
        let m = a.recense
        return Episode.Cache(lines: lines, done: m?.done ?? [], duration: a.duration, lyricsChecked9: m?.lyricsChecked9, lyrics: m?.lyrics,
                             heard: m?.heard, songPipeline: m?.songPipeline, lyricOptions: m?.lyricOptions, lyricsVerified: m?.lyricsVerified,
                             language: m?.language, publishedTitle: m?.publishedTitle, redone: m?.redone, offsite: m?.offsite, complete: a.complete,
                             engine: m?.engine, lexicon: m?.lexicon)
    }

    // ---- R2 ----

    /// keep/<name>'s body, nil when there is none (or R2 can't be reached).
    static func get(_ name: String) async -> (Data, String?)? {
        guard Store.r2, let (d, resp) = try? await URLSession.shared.data(for: Store.request("GET", name, dir: "keep")),
              let h = resp as? HTTPURLResponse, h.statusCode == 200 else { return nil }
        return (d, h.value(forHTTPHeaderField: "ETag"))
    }
    /// Puts keep/<name>; `ifAbsent`: only where there is none yet. The new etag ("" when R2 gave none), nil when refused.
    @discardableResult
    static func put(_ name: String, _ body: Data, ifAbsent: Bool = false, ifMatch: String? = nil) async -> String? {
        guard Store.r2 else { return nil }
        var r = Store.request("PUT", name, dir: "keep")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let ifMatch { r.setValue(ifMatch, forHTTPHeaderField: "If-Match") } else if ifAbsent { r.setValue("*", forHTTPHeaderField: "If-None-Match") }
        guard let (_, resp) = try? await URLSession.shared.upload(for: r, from: body), let h = resp as? HTTPURLResponse, h.statusCode == 200 else { return nil }
        return h.value(forHTTPHeaderField: "ETag") ?? ""
    }

    /// What was last sent to each name (a digest of it without its time): one unchanged isn't sent again.
    static var sent: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "r2KeepSent") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "r2KeepSent") }
    }
    /// Sends keep/<name> when what `make` makes (given no time) differs from what was last sent; given the time to stamp.
    static func send(_ name: String, _ make: (Double?) -> Data?) async -> Bool {
        guard let plain = make(nil) else { return false }
        let h = digest(plain)
        if sent[name] == h { return true }
        guard let body = make((Date().timeIntervalSince1970 * 1000).rounded()), await put(name, body) != nil else { return false }
        sent[name] = h
        return true
    }

    /// This Mac's transcript of an item to keep/: asr.json and tr/en.json, each only when it changed.
    @discardableResult
    static func pushTranscript(_ key: String) async -> Bool {
        guard Store.r2, let c = Episode.Cache.read(key) else { return false }
        // The stub a failed fetch leaves (no lines, not complete) is not a transcript: sent, it told Gallery and
        // GalleryJob the file had one, and it was never transcribed (notes 38).
        guard c.complete == true || !c.lines.isEmpty else { return false }
        let (a, en) = split(c)
        var ok = await send(asr(key)) { _ in encode(a) }
        if let en { ok = await send(tr(key, "en")) { t in var f = en; f.updatedAt = t; return encode(f) } && ok }
        return ok
    }

    /// A song's measured voice (Features) to keep/<key>/features.json, when it changed.
    @discardableResult
    static func pushFeatures(_ key: String) async -> Bool {
        guard Store.r2, let d = try? Data(contentsOf: Features.url(key)) else { return false }
        return await send(features(key)) { _ in d }
    }

    /// A translation (vi, fr) to keep/<key>/tr/<lang>.json once it covers the whole transcript; never before, so
    /// Gallery never shows half of one. Sent when it changed.
    @discardableResult
    static func pushTranslation(_ key: String, _ lang: String) async -> Bool {
        guard Store.r2, let d = try? Data(contentsOf: trURL(key, lang)), let f = try? JSONDecoder().decode(TrFile.self, from: d) else { return false }
        guard f.complete == true else { return false }
        return await send(tr(key, lang)) { t in var x = f; x.updatedAt = t; return encode(x) }
    }

    /// An item this Mac no longer has, fetched back from keep/ (before it loads): its transcript, the listener's
    /// edits, and its translations. An old flat transcript is written out in the new layout (Gallery reads that).
    static func restore(_ key: String) async {
        guard Store.r2 else { return }
        let fm = FileManager.default, json = cacheDir.appendingPathComponent(key + ".v2.json")
        if !fm.fileExists(atPath: json.path) {
            if let (d, _) = await get(asr(key)), let a = try? JSONDecoder().decode(ASR.self, from: d) {
                let en = await get(tr(key, "en")).flatMap { try? JSONDecoder().decode(TrFile.self, from: $0.0) }
                if let out = try? JSONEncoder().encode(join(a, en)), (try? out.write(to: json)) != nil {
                    mark(json)
                    // what keep/ has is what this Mac has: not sent back
                    let (a2, en2) = split(join(a, en))
                    if let x = encode(a2) { sent[asr(key)] = digest(x) }
                    if let en2, let x = encode(en2) { sent[tr(key, "en")] = digest(x) }
                    log("restored transcript \(key) from R2")
                }
            } else if let (d, _) = await get(key + ".v2.json"), let c = try? JSONDecoder().decode(Episode.Cache.self, from: d), (try? d.write(to: json)) != nil {
                mark(json)
                log("restored transcript \(key).v2.json from R2 (old layout)")
                await migrate(key, c)
            }
        }
        let edits = CorrectionSync.url(key)
        if !fm.fileExists(atPath: edits.path), let e = await CorrectionSync.fetch(key).0, let out = try? JSONEncoder().encode(e), (try? out.write(to: edits)) != nil {
            mark(edits)
            log("restored corrections of \(key) from R2")
        }
        for lang in others where !fm.fileExists(atPath: trURL(key, lang).path) {
            guard let (d, _) = await get(tr(key, lang)), (try? JSONDecoder().decode(TrFile.self, from: d)) != nil, (try? d.write(to: trURL(key, lang))) != nil else { continue }
            mark(trURL(key, lang))
        }
    }

    /// An old flat transcript written out as asr.json and tr/en.json, only where there are none yet.
    static func migrate(_ key: String, _ c: Episode.Cache) async {
        let (a, en) = split(c)
        if let d = encode(a) { await put(asr(key), d, ifAbsent: true) }
        if var en { en.updatedAt = (Date().timeIntervalSince1970 * 1000).rounded(); if let d = encode(en) { await put(tr(key, "en"), d, ifAbsent: true) } }
        log("keep: \(key) moved to the per-item layout")
    }

    /// A file just fetched from keep/: counted as mirrored as it is.
    static func mark(_ u: URL) {
        if let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate { Store.mirrored[u.lastPathComponent] = m.timeIntervalSince1970 }
    }

    /// What keep/ has of each item: key → its parts ("asr", "tr/en", "tr/vi", "corrections", and "v2", "edits" for
    /// the old flat files). nil when R2 can't be listed.
    nonisolated static func parts(_ names: some Sequence<String>) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for n in names {
            if let m = n.firstMatch(of: #/^keep/([0-9a-f]{24})/(asr|corrections|features)\.json$/#) { out[String(m.1), default: []].insert(String(m.2)) }
            else if let m = n.firstMatch(of: #/^keep/([0-9a-f]{24})/tr/([a-z]{2,3})\.json$/#) { out[String(m.1), default: []].insert("tr/" + m.2) }
            else if let m = n.firstMatch(of: #/^keep/([0-9a-f]{24})\.(v2|edits)\.json$/#) { out[String(m.1), default: []].insert(String(m.2)) }
        }
        return out
    }
    static func listing() async -> [String: Set<String>]? {
        guard Store.r2, let names = await Store.list("keep/") else { return nil }
        return parts(names.keys)
    }
}

// ---------- storage: only what's in use stays on this Mac ----------
// Media (downloaded audio, a video's extracted sound, vocal stems) is needed only while a piece plays, is
// transcribed or is exported. Once another piece takes over, it moves to tmp/ in the R2 bucket recense-tmp, whose
// lifecycle rule deletes each file `tmpDays` after its upload — or, without R2 configured, it's deleted outright
// (never via the Trash): it can always be fetched or separated again. tmpDays is retuned daily (tuneExpiry) to the
// longest stay that keeps the bucket inside R2's free storage at the rate media has been arriving. Transcripts are what's costly to remake (a day's Groq
// quota, and the lyric choice and re-timing a song took), so each is mirrored to keep/, which never expires, and
// fetched back when a piece returns: on this Mac one stays a week unused once mirrored (30 days if not).
// Exports' chapter files go after a day (sweepExports); the log is kept short.
enum Store {
    // A test cache (RECENSE_CACHE) stays off R2: nothing pulled in from keep/, nothing of it mirrored there.
    static var r2: Bool { !cfg.r2Account.isEmpty && !cfg.r2Key.isEmpty && !cfg.r2Secret.isEmpty && ProcessInfo.processInfo.environment["RECENSE_CACHE"] == nil }
    @MainActor static var busy = Set<String>()       // files an export is reading

    /// An S3 (SigV4) request for <dir>/<name> in the bucket: tmp/ expires after `tmpDays`, keep/ never.
    static func request(_ method: String, _ name: String, dir: String = "tmp") -> URLRequest {
        signed(method, "/\(cfg.r2Bucket)/\(dir)/\(name)")
    }

    /// An S3 (SigV4) request for a path in the R2 account, with its query given as name → value.
    static func signed(_ method: String, _ path: String, query: [String: String] = [:]) -> URLRequest {
        let host = "\(cfg.r2Account).r2.cloudflarestorage.com"
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        let q = query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: safe)!)" }.joined(separator: "&")
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = f.string(from: Date()), day = String(stamp.prefix(8)), scope = "\(day)/auto/s3/aws4_request"
        let hex = { (d: any Sequence<UInt8>) in d.map { String(format: "%02x", $0) }.joined() }
        let canonical = "\(method)\n\(path)\n\(q)\nhost:\(host)\nx-amz-content-sha256:UNSIGNED-PAYLOAD\nx-amz-date:\(stamp)\n\n"
            + "host;x-amz-content-sha256;x-amz-date\nUNSIGNED-PAYLOAD"
        let toSign = "AWS4-HMAC-SHA256\n\(stamp)\n\(scope)\n" + hex(SHA256.hash(data: Data(canonical.utf8)))
        var k = SymmetricKey(data: Data("AWS4\(cfg.r2Secret)".utf8))
        for part in [day, "auto", "s3", "aws4_request"] { k = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: k))) }
        let sig = hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: k))
        var r = URLRequest(url: URL(string: "https://\(host)\(path)" + (q.isEmpty ? "" : "?" + q))!)
        r.httpMethod = method; r.timeoutInterval = 300
        r.setValue("UNSIGNED-PAYLOAD", forHTTPHeaderField: "x-amz-content-sha256")
        r.setValue(stamp, forHTTPHeaderField: "x-amz-date")
        r.setValue("AWS4-HMAC-SHA256 Credential=\(cfg.r2Key)/\(scope), SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=\(sig)",
                   forHTTPHeaderField: "Authorization")
        return r
    }

    static func upload(_ f: URL, dir: String = "tmp") async -> Bool {
        guard r2, let (_, resp) = try? await URLSession.shared.upload(for: request("PUT", f.lastPathComponent, dir: dir), fromFile: f),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        if dir == "tmp", let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
            var d = arrivals; d[day, default: 0] += Double(size); arrivals = d
        }
        return true
    }

    // ---- how long tmp/ keeps media ----
    // R2 bills storage by the month's average, past 10 GB free. Each file expires a fixed time after its upload (not
    // a periodic wipe, which would also take what came an hour before it), so the bucket holds about inflow × days:
    // the stay is the longest that keeps that, plus keep/, under 80 % of the free 10 GB. Inflow is everything put
    // in tmp/ (audio and vocal stems) measured over the last 14 days, or the last 3 when they were busier, so a
    // busy spell shortens the stay the next day and older files go at once. Lyrics, metadata and the timing
    // fixes are in the transcripts in keep/ (counted, never expired); .md/.vtt/.m4b live in the iCloud vault and
    // an export's chapter files are deleted here after a day (sweepExports): none of those is in tmp/.
    static let freeBytes = 10e9, budget = 0.8, maxDays = 90

    /// Bytes put in tmp/ per day ("2026-10-20"), the last 30 days.
    static var arrivals: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "r2Arrivals") as? [String: Double] ?? [:] }
        set {
            let cut = String(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30 * 86400)).prefix(10))
            UserDefaults.standard.set(newValue.filter { $0.key >= cut }, forKey: "r2Arrivals")
        }
    }
    static var tmpDays: Int {
        get { max(1, UserDefaults.standard.integer(forKey: "r2TmpDays")) }
        set { UserDefaults.standard.set(newValue, forKey: "r2TmpDays") }
    }

    /// Once a day: the stay that fits the free tier, set on the bucket when it changes.
    static func tuneExpiry() async {
        let ud = UserDefaults.standard, now = Date()
        guard r2, now.timeIntervalSince1970 - ud.double(forKey: "r2TunedAt") > 86400 else { return }
        if ud.double(forKey: "r2Since") == 0 { ud.set(now.timeIntervalSince1970, forKey: "r2Since") }
        let known = (now.timeIntervalSince1970 - ud.double(forKey: "r2Since")) / 86400 + 1   // days measured so far
        func rate(_ n: Double) -> Double {
            let cut = String(ISO8601DateFormatter().string(from: now.addingTimeInterval(-(n - 1) * 86400)).prefix(10))
            return arrivals.filter { $0.key >= cut }.values.reduce(0, +) / max(1, min(n, known.rounded(.down)))
        }
        guard let keep = await prefixBytes("keep/") else { return }
        let inflow = max(rate(14), rate(3))
        let days = inflow > 0 ? min(maxDays, max(1, Int((freeBytes * budget - keep) / inflow))) : maxDays
        ud.set(now.timeIntervalSince1970, forKey: "r2TunedAt")
        guard days != tmpDays || ud.double(forKey: "r2RuleSet") == 0 else { return }
        if await setExpiry(days) {
            ud.set(1, forKey: "r2RuleSet")
            log("storage: tmp/ keeps media \(days) days (\(Int(inflow / 1e6)) MB/day in, keep/ \(Int(keep / 1e6)) MB, free up to \(Int(freeBytes / 1e9)) GB)")
            tmpDays = days
        }
    }

    /// The objects under a prefix, name → bytes (ListObjectsV2, a page of 1,000 at a time).
    static func list(_ prefix: String) async -> [String: Double]? {
        var out: [String: Double] = [:], token: String?
        repeat {
            var q = ["list-type": "2", "prefix": prefix]
            if let token { q["continuation-token"] = token }
            guard let (d, resp) = try? await URLSession.shared.data(for: signed("GET", "/\(cfg.r2Bucket)", query: q)),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let x = String(decoding: d, as: UTF8.self)
            for m in x.matches(of: #/<Key>([^<]+)</Key>.*?<Size>(\d+)</Size>/#) { out[String(m.1)] = Double(m.2) ?? 0 }
            token = x.contains("<IsTruncated>true") ? x.firstMatch(of: #/<NextContinuationToken>([^<]+)</#)?.1.description : nil
        } while token != nil
        return out
    }
    static func prefixBytes(_ prefix: String) async -> Double? { await list(prefix).map { $0.values.reduce(0, +) } }
    /// The key of every transcript in keep/ (keep/<key>/asr.json, or an old keep/<key>.v2.json).
    static func keepKeys() async -> Set<String> {
        guard r2 else { return [] }
        return Set(Keep.parts((await list("keep/") ?? [:]).keys).filter { $0.value.contains("asr") || $0.value.contains("v2") }.keys)
    }

    /// Replaces the bucket's lifecycle: tmp/ expires `days` after upload; unfinished uploads are cleaned up.
    static func setExpiry(_ days: Int) async -> Bool {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
        <Rule><ID>Default Multipart Abort Rule</ID><Status>Enabled</Status><Filter><Prefix></Prefix></Filter>\
        <AbortIncompleteMultipartUpload><DaysAfterInitiation>7</DaysAfterInitiation></AbortIncompleteMultipartUpload></Rule>\
        <Rule><ID>expire-tmp</ID><Status>Enabled</Status><Filter><Prefix>tmp/</Prefix></Filter><Expiration><Days>\(days)</Days></Expiration>\
        <AbortIncompleteMultipartUpload><DaysAfterInitiation>1</DaysAfterInitiation></AbortIncompleteMultipartUpload></Rule></LifecycleConfiguration>
        """
        var r = signed("PUT", "/\(cfg.r2Bucket)", query: ["lifecycle": ""])
        r.httpBody = Data(xml.utf8)
        r.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        r.setValue(Data(Insecure.MD5.hash(data: Data(xml.utf8))).base64EncodedString(), forHTTPHeaderField: "Content-MD5")
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return false }
        if (resp as? HTTPURLResponse)?.statusCode == 200 { return true }
        log("storage: couldn't set tmp/ expiry: \(String(decoding: d.prefix(200), as: UTF8.self))")
        return false
    }

    /// When each transcript was last mirrored (its modification date then): one unchanged since isn't sent again.
    static var mirrored: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "r2Mirrored") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "r2Mirrored") }
    }

    /// A transcript this Mac no longer has, fetched back from keep/ (before the piece loads it), with the listener's
    /// edits of it and its translations (loaded together, so pruned together; Keep.restore).
    static func restoreTranscript(_ key: String) async {
        guard r2 else { return }
        await Keep.restore(key)
    }

    /// The first of these media files R2 still has, downloaded back into the cache.
    static func restore(_ names: [String]) async -> URL? {
        guard r2 else { return nil }
        for name in names {
            guard let (tmp, resp) = try? await URLSession.shared.download(for: request("GET", name)),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let dest = cacheDir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            guard (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else { continue }
            log("restored \(name) from R2")
            return dest
        }
        return nil
    }

    /// Everything in the cache that isn't in use leaves: media to R2 (or deleted), stale transcripts deleted.
    @MainActor static func sweep(keep: String?) async {
        let fm = FileManager.default
        let props: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey]
        var freed = 0, moved = 0
        for u in (try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: props)) ?? [] {
            let name = u.lastPathComponent, key = String(name.prefix(24))
            guard let v = try? u.resourceValues(forKeys: Set(props)), v.isDirectory != true,
                  name.count > 25, key.allSatisfy(\.isHexDigit), key != keep, !busy.contains(u.path) else { continue }
            let age = Date().timeIntervalSince(v.contentModificationDate ?? .distantPast)
            if name.hasSuffix(".json") {
                let m = (v.contentModificationDate ?? .distantPast).timeIntervalSince1970
                // each to its place in the item's folder in keep/ (Keep), whatever the item
                if mirrored[name] != m, age > 60 {
                    // corrections are written in keep/ by Gallery too: merged with keep/'s copy, never sent over it blind
                    if name.hasSuffix(".edits.json") { await CorrectionSync.push(key) }
                    else if name.hasSuffix(".v2.json") { if await Keep.pushTranscript(key) { mirrored[name] = m } }
                    else if name.hasSuffix(".features.json") { if await Keep.pushFeatures(key) { mirrored[name] = m } }
                    else if let lang = name.firstMatch(of: #/\.tr\.([a-z]{2,3})\.json$/#)?.1 {
                        // a translation goes once it covers the whole transcript (until then it is kept here)
                        if await Keep.pushTranslation(key, String(lang)) { mirrored[name] = m }
                    }
                }
                // Edits and translations go only after their transcript: it's when the transcript is missing that all
                // are fetched back.
                let partner = !name.hasSuffix(".v2.json") && fm.fileExists(atPath: cacheDir.appendingPathComponent(key + ".v2.json").path)
                if !partner, age > (mirrored[name] == m ? 7 : 30) * 86400 { try? fm.removeItem(at: u); mirrored[name] = nil }
                continue
            }
            guard age > 60 else { continue }                       // still being written
            if await upload(u) {
                moved += 1
                let j = cacheDir.appendingPathComponent(key + ".v2.json")
                if let d = try? Data(contentsOf: j), var c = try? JSONDecoder().decode(Episode.Cache.self, from: d) {
                    c.offsite = Array(Set((c.offsite ?? []) + [name]))
                    if let e = try? JSONEncoder().encode(c) { try? e.write(to: j) }
                }
            }
            try? fm.removeItem(at: u)
            freed += v.fileSize ?? 0
        }
        for n in ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"] { try? fm.removeItem(at: cacheDir.appendingPathComponent(n)) }
        // Stems left by a separation that was interrupted.
        for u in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        where u.lastPathComponent.hasPrefix("recense-stems-") && !(keep.map { u.lastPathComponent.hasSuffix($0) } ?? false) {
            try? fm.removeItem(at: u)
        }
        if let size = (try? logURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 5 << 20,
           let h = try? FileHandle(forReadingFrom: logURL) {
            try? h.seek(toOffset: UInt64(size - (1 << 20)))
            let tail = h.readDataToEndOfFile(); try? h.close()
            try? tail.write(to: logURL)
        }
        if freed > 0 { log("storage: freed \(freed >> 20) MB\(r2 ? ", \(moved) file(s) to R2 for \(tmpDays) day(s)" : "")") }
        await Library.mirror()
        await tuneExpiry()
    }
}

// ---------- tiny localhost HTTP server for the browser extension ----------
final class Server {
    var listener: NWListener
    let port: UInt16
    let handle: (String, [String: String], Data) async -> [String: Any]
    final class Conn { var buf = Data() }

    static func listener(_ port: UInt16) throws -> NWListener {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        return try NWListener(using: params)
    }

    init(port: UInt16, handle: @escaping (String, [String: String], Data) async -> [String: Any]) throws {
        self.port = port
        listener = try Server.listener(port)
        self.handle = handle
    }

    /// The port is Recense's alone. When it's taken (the Recense being replaced still letting go of it, or a standalone
    /// Recense.app left running), a new listener tries again every 3 s until it gets it, instead of the extension's
    /// position reports going nowhere until the next launch.
    func start() {
        listener.newConnectionHandler = { [weak self] c in
            c.start(queue: .main); self?.receive(c, Conn())
        }
        listener.stateUpdateHandler = { [weak self] st in
            log("server: \(st)")
            guard case .failed = st, let self else { return }
            self.listener.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let l = try? Server.listener(self.port) else { return }
                self.listener = l; self.start()
            }
        }
        listener.start(queue: .main)
    }

    func receive(_ c: NWConnection, _ st: Conn) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4 << 20) { [weak self] data, _, fin, error in
            guard let self else { return }
            if let data { st.buf.append(data) }
            if let r = st.buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: st.buf[..<r.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                var len = 0
                for h in head.dropFirst() {
                    let kv = h.split(separator: ":", maxSplits: 1)
                    if kv.count == 2, kv[0].lowercased() == "content-length" { len = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
                }
                if st.buf.count - r.upperBound >= len {
                    let body = Data(st.buf[r.upperBound..<(r.upperBound + len)])
                    let target = head[0].split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    let comps = URLComponents(string: target)
                    var q: [String: String] = [:]
                    comps?.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
                    let method = head[0].split(separator: " ").first ?? ""
                    Task { @MainActor in
                        let out = method == "OPTIONS" ? [:] : await self.handle(comps?.path ?? "/", q, body)
                        let json = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
                        var resp = Data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\n" +
                                         "Access-Control-Allow-Headers: *\r\nAccess-Control-Allow-Private-Network: true\r\n" +
                                         "Content-Length: \(json.count)\r\nConnection: close\r\n\r\n").utf8)
                        resp.append(json)
                        c.send(content: resp, completion: .contentProcessed { _ in c.cancel() })
                    }
                    return
                }
            }
            if fin || error != nil { c.cancel(); return }
            self.receive(c, st)
        }
    }
}

// ---------- app ----------
/// Menu bar icon: a rounded screen holding two subtitle lines — the original, and fainter beneath it,
/// the translation. A template image, so it follows the menu bar's light/dark tint.
// ---------- export ----------
// Markdown and audiobooks land in the Obsidian vault: it's iCloud Drive, so the notes open in Obsidian on
// every device and the .m4b plays from Files, next to the transcript that times it (opened in readAlongURL).
let exportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian")
let readAlongURL = "https://claude.ai/artifact/VA69HKAKdYTWk7MRg1omMs"

/// Exports are named by when they were made, 20261019-1432 (a colon isn't allowed in iCloud file names);
/// a second export in the same minute gets -2.
func exportStamp() -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmm"
    let base = f.string(from: Date())
    var name = base, n = 2
    while ["md", "vtt", "m4b"].contains(where: { FileManager.default.fileExists(atPath: exportDir.appendingPathComponent(name + "." + $0).path) }) {
        name = "\(base)-\(n)"; n += 1
    }
    return name
}

func vttTime(_ t: Double) -> String {
    let ms = Int((max(0, t) * 1000).rounded())
    return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
}

func safeName(_ s: String) -> String {
    let t = s.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n")).joined(separator: " ")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    return String((t.isEmpty ? "Recense" : t).prefix(120))
}

func lineText(_ l: Line) -> String { joinWords(l.words.map(\.text)) }

/// Scripts written without spaces between words (Chinese, Japanese, Thai, Lao, Khmer, Burmese, Tibetan): the ears hand
/// their words over cut (speech.swift: heardOpen), and they're joined with nothing between them, a space only after a
/// Tibetan shad. Gallery's corrections.js and gallery.js (unspaced, joinWords, tokens) are the same.
func isUnspaced(_ u: Unicode.Scalar) -> Bool {
    switch u.value {
    case 0x0E00...0x0EFF, 0x0F00...0x0FFF, 0x1000...0x109F, 0x1780...0x17FF, 0x2E80...0x2FFF, 0x3000...0x30FF, 0x3100...0x312F,
         0x31A0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x3134F: return true
    default: return false
    }
}
func unspaced(_ a: String, _ b: String) -> Bool {
    guard let x = a.unicodeScalars.last, let y = b.unicodeScalars.first else { return false }
    return isUnspaced(x) && isUnspaced(y) && !(0x0F0D...0x0F11).contains(x.value) && x.value != 0x0F14
}
/// A line's words as it's written (and no space before a stop or comma: Latin, Arabic ، ؛ ؟, Ge'ez ። ፣ ፤).
func joinWords(_ ws: [String]) -> String {
    var s = ""
    for w in ws { s += s.isEmpty || unspaced(s, w) ? w : " " + w }
    return s.replacingOccurrences(of: #"\s+([,.…،؛؟።፣፤፥፦፧])"#, with: "$1", options: .regularExpression)
}
/// A run in one of those scripts cut into words, each keeping what follows it up to the next (a stop, a tsheg): nothing
/// written is dropped.
func cutUnspaced(_ t: String, lang: String? = nil) -> [String] {
    guard t.unicodeScalars.contains(where: isUnspaced) else { return [t] }
    let tok = NLTokenizer(unit: .word)
    tok.string = t
    if let lang, lang != "und" { tok.setLanguage(NLLanguage(lang)) }
    var at: [String.Index] = []
    tok.enumerateTokens(in: t.startIndex..<t.endIndex) { r, _ in at.append(r.lowerBound); return true }
    guard !at.isEmpty else { return [t] }
    at[0] = t.startIndex
    return at.indices.map { i in String(t[at[i]..<(i + 1 < at.count ? at[i + 1] : t.endIndex)]).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}
func englishText(_ l: Line) -> String? {
    guard let en = l.english, !en.isEmpty else { return nil }
    return en.map(\.w).joined(separator: " ")
}

func transcriptMarkdown(_ title: String, _ lines: [Line], source: String, duration: Double, complete: Double) -> String {
    var md = "---\ntitle: \"\(title.replacingOccurrences(of: "\"", with: "'"))\"\nsource: \"\(source)\"\nduration: \(clock(duration))\nexported: \(ISO8601DateFormatter().string(from: Date()))\n"
    if complete < 1 { md += "transcribed: \(Int(complete * 100))%\n" }
    md += "---\n\n# \(title)\n\n"
    for l in lines {
        md += "**\(clock(l.start))** \(lineText(l))\n"
        if let en = englishText(l) { md += "> \(en)\n" }
        md += "\n"
    }
    return md
}

/// WebVTT with a timestamp on every word (karaoke cues): players that read sidecar subtitles show it in
/// time with the audiobook, and a read-along viewer can seek to any word.
func transcriptVTT(_ lines: [Line]) -> String {
    var v = "WEBVTT\n\n"
    for (i, l) in lines.enumerated() where !l.words.isEmpty {
        v += "\(i + 1)\n\(vttTime(l.start)) --> \(vttTime(max(l.end, l.start + 0.3)))\n"
        v += l.words.enumerated().map { j, w in (j == 0 ? "" : "<\(vttTime(w.start))>") + "<c>\(w.text)</c>" }.joined(separator: " ")
        if let en = englishText(l) { v += "\n" + en }
        v += "\n\n"
    }
    return v
}

/// Chapter cuts about every ten minutes, each at the gap before the line nearest the mark.
func chapterStarts(_ lines: [Line], duration: Double, every: Double = 600) -> [Double] {
    var starts = [0.0], mark = every
    while mark < duration - every / 3 {
        guard let l = lines.min(by: { abs($0.start - mark) < abs($1.start - mark) }), l.start > starts.last! + every / 2
        else { mark += every; continue }
        starts.append(max(0, l.start - 0.15)); mark = l.start + every
    }
    return starts
}

func menuBarIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let frame = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3.5, width: 15, height: 11), xRadius: 3.25, yRadius: 3.25)
        frame.lineWidth = 1.3
        NSColor.black.setStroke(); frame.stroke()
        for (y, w, a) in [(8.6, 8.0, 1.0), (6.2, 4.5, 0.45)] as [(CGFloat, CGFloat, CGFloat)] {
            let l = NSBezierPath()
            l.move(to: NSPoint(x: 9 - w / 2, y: y)); l.line(to: NSPoint(x: 9 + w / 2, y: y))
            l.lineWidth = 1.3; l.lineCapStyle = .round
            NSColor.black.withAlphaComponent(a).setStroke(); l.stroke()
        }
        return true
    }
    img.isTemplate = true
    img.accessibilityDescription = "Recense"
    return img
}

// ---------- native players and browsers over Apple Events ----------
// Read like the Firefox extension reports: what's playing, the exact position, play state. Window controls
// go back the same way, so these sync as tightly as Firefox — no delay, no muting. Browsers aren't matched
// by site: any <audio>/<video> on any page in any tab counts.
struct NativeReport {
    let app: String        // "quicktime", "music", or a browser's bundle id
    let key: String        // what the episode is keyed by: a file URL or the media's src
    let target: String     // where commands go: QuickTime document name, or "window tab" in a browser
    var page: String? = nil
    var title: String? = nil
    let t: Double, playing: Bool, rate: Double, dur: Double, looping: Bool
    var at = 0.0           // when the player was at `t`: midway through the Apple Event round trip
    var vol: Double? = nil // its own volume, 0…1 (0 when muted)
}

final class NativeSources {
    static let players: [(id: String, name: String, poll: String)] = [
        ("com.apple.QuickTimePlayerX", "quicktime", """
            tell application id "com.apple.QuickTimePlayerX"
                set ds to documents
                if ds is {} then return {}
                set d to item 1 of ds
                repeat with x in ds
                    if playing of x then set d to contents of x
                end repeat
                set f to file of d
                if f is missing value then return {}
                return {POSIX path of f, current time of d, playing of d, rate of d, duration of d, looping of d, name of d, audio volume of d, muted of d}
            end tell
            """),
        ("com.apple.Music", "music", """
            tell application id "com.apple.Music"
                if player state is stopped then return {}
                try
                    set f to location of current track
                on error
                    return {}
                end try
                if f is missing value then return {}
                return {POSIX path of f, player position, player state is playing, 1.0, duration of current track, song repeat is one, (artist of current track) & " - " & (name of current track), (sound volume) / 100, mute}
            end tell
            """),
    ]
    static let safari = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    static let chromium = ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
                           "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium", "com.operasoftware.Opera"]

    /// Runs in the page: the playing media element (else the one we last followed). Single quotes only,
    /// so it can sit inside an AppleScript string.
    static let probe = "(() => { const ms = [...document.querySelectorAll('video,audio')]; " +
        "const m = ms.find(x => !x.paused && !x.ended && x.readyState > 2 && !x.muted && x.volume > 0) || (ms.includes(window.__bsMedia) ? window.__bsMedia : null); " +
        "if (!m || !m.currentSrc) return ''; window.__bsMedia = m; " +
        // A YouTube preview (search results, a channel page, the mini-player) plays another video than the page's.
        "const yt = m.closest('.html5-video-player'), v = yt && yt.getVideoData ? yt.getVideoData().video_id : ''; " +
        "return JSON.stringify({ src: m.currentSrc, page: v ? 'https://www.youtube.com/watch?v=' + v : location.href, title: document.title, t: m.currentTime, paused: m.paused || m.seeking || m.readyState < 3, " +
        "rate: m.playbackRate, dur: m.duration, loop: m.loop, vol: m.muted ? 0 : m.volume }); })()"

    let q = DispatchQueue(label: "native-sources")
    var scripts: [String: NSAppleScript] = [:]
    var busy = false, lastScan = 0.0
    var hot: [String: String] = [:]            // browser id -> "window tab" holding media
    var follow = ""                            // the followed player, as AppDelegate names it ("app|target")
    var logged: Set<String> = []

    func running(_ id: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }

    /// Never launches anything: only apps already running are asked. Browsers' tabs are all scanned once a
    /// second; the tab holding media is then read on every poll.
    func poll(_ done: @escaping ([NativeReport]) -> Void) {
        guard !busy else { return }
        busy = true
        let players = NativeSources.players.filter { running($0.id) }
        let browsers = (NativeSources.safari + NativeSources.chromium).filter { running($0) }
        let scan = CACurrentMediaTime() - lastScan > 1
        if scan { lastScan = CACurrentMediaTime() }
        let follow = self.follow
        q.async {
            var out: [NativeReport] = []
            for a in players {
                let t0 = Date().timeIntervalSince1970
                let res = self.run(a.name, a.poll)
                let t1 = Date().timeIntervalSince1970
                if t1 - t0 > 1 { log("\(a.name) took \(String(format: "%.1f", t1 - t0)) s to answer") }
                guard let d = res, d.numberOfItems >= 7, let path = d.atIndex(1)?.stringValue else { continue }
                let vol = d.numberOfItems >= 9 ? (d.atIndex(9)?.booleanValue == true ? 0 : d.atIndex(8)?.doubleValue) : nil
                out.append(NativeReport(app: a.name, key: URL(fileURLWithPath: path).absoluteString,
                                        target: d.atIndex(7)?.stringValue ?? "", title: d.atIndex(7)?.stringValue,
                                        t: d.atIndex(2)?.doubleValue ?? 0,
                                        playing: d.atIndex(3)?.booleanValue ?? false, rate: d.atIndex(4)?.doubleValue ?? 1,
                                        dur: d.atIndex(5)?.doubleValue ?? 0, looping: d.atIndex(6)?.booleanValue ?? false, at: (t0 + t1) / 2,
                                        vol: vol))
            }
            for b in browsers {
                var found: [NativeReport] = []
                // the followed tab is read on every poll, playing or paused; elsewhere, the tab that plays
                let mine = follow.hasPrefix(b + "|") ? String(follow.dropFirst(b.count + 1)) : nil
                if scan { found = self.browserScan(b) }
                else if let t = mine ?? self.hot[b], let r = self.browserRead(b, target: t) { found = [r] }
                if scan { self.hot[b] = (found.first { $0.target == mine } ?? found.first { $0.playing } ?? found.first { $0.target == self.hot[b] } ?? found.first)?.target }
                out += found
            }
            DispatchQueue.main.async { self.busy = false; done(out) }
        }
    }

    private func tell(_ b: String, _ body: String) -> String { "tell application id \"\(b)\"\n\(body)\nend tell" }
    private func js(_ b: String, _ code: String, in target: String) -> String {
        let parts = target.split(separator: " ")
        let tab = "tab \(parts.last ?? "1") of window id \(parts.first ?? "0")"
        return NativeSources.safari.contains(b) ? "do JavaScript \"\(code)\" in \(tab)" : "execute \(tab) javascript \"\(code)\""
    }

    private func browserScan(_ b: String) -> [NativeReport] {
        let run = NativeSources.safari.contains(b) ? "do JavaScript js in t" : "execute t javascript js"
        let src = tell(b, """
            set js to "\(NativeSources.probe)"
            set out to {}
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    try
                        set r to \(run)
                        if r is not missing value and r is not "" then set end of out to ((id of w) as text) & " " & i & (character id 9) & r
                    on error m number n
                        if n is not -1728 then set end of out to "!" & n & " " & m
                    end try
                end repeat
            end repeat
            return out
            """)
        guard let d = self.run("scan " + b, src) else { return [] }
        return (0..<d.numberOfItems).compactMap { i in
            let s = d.atIndex(i + 1)?.stringValue ?? ""
            // A tab the page's JavaScript can't be run in (Safari's "Allow JavaScript from Apple Events" off, permission denied)
            if s.hasPrefix("!") { if logged.insert(b + s).inserted { log("scan \(b): \(s.dropFirst().prefix(200))") }; return nil }
            guard let sep = s.firstIndex(of: "\t") else { return nil }
            return report(b, target: String(s[..<sep]), json: String(s[s.index(after: sep)...]))
        }
    }

    private func browserRead(_ b: String, target: String) -> NativeReport? {
        let t0 = Date().timeIntervalSince1970
        guard let s = run("read " + b + target, tell(b, "return " + js(b, NativeSources.probe, in: target)))?.stringValue else { return nil }
        var r = report(b, target: target, json: s)
        r?.at = (t0 + Date().timeIntervalSince1970) / 2
        return r
    }

    private func report(_ b: String, target: String, json: String) -> NativeReport? {
        guard let j = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let src = j["src"] as? String else { return nil }
        let dur = j["dur"] as? Double ?? 0
        return NativeReport(app: b, key: src, target: target, page: j["page"] as? String, title: j["title"] as? String, t: j["t"] as? Double ?? 0,
                            playing: !(j["paused"] as? Bool ?? true), rate: j["rate"] as? Double ?? 1,
                            dur: dur.isFinite ? dur : 0, looping: j["loop"] as? Bool ?? false, vol: j["vol"] as? Double)
    }

    /// Carries out a window command (same shape the extension gets) in the player.
    func exec(_ app: String, target: String, _ c: [String: Any], rate: Double) {
        let num = { (x: Double) in String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), x) }
        let op = c["op"] as? String ?? ""
        let nativeLoop = (c["track"] as? Bool ?? false) && !(c["ab"] as? Bool ?? false)
        var body = ""
        switch app {
        case "quicktime":
            let n = target.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let d = "(first document whose name is \"\(n)\")"
            switch op {
            case "play": body = "play \(d)\nset rate of \(d) to \(num(rate))"
            case "pause": body = "pause \(d)"
            case "seek": body = "set current time of \(d) to \(num(c["t"] as? Double ?? 0))"
            case "rate": body = "if playing of \(d) then set rate of \(d) to \(num(c["r"] as? Double ?? 1))"
            case "loop": body = "set looping of \(d) to \(nativeLoop)"
            case "volume": body = "set muted of \(d) to false\nset audio volume of \(d) to \(num(c["v"] as? Double ?? 1))"
            default: return
            }
            body = tell("com.apple.QuickTimePlayerX", body)
        case "music":
            switch op {
            case "play": body = "play"
            case "pause": body = "pause"
            case "seek": body = "set player position to \(num(c["t"] as? Double ?? 0))"
            case "loop": body = "set song repeat to \(nativeLoop ? "one" : "off")"
            case "volume": body = "set mute to false\nset sound volume to \(Int(((c["v"] as? Double ?? 1) * 100).rounded()))"
            default: return       // Music has no speed control
            }
            body = tell("com.apple.Music", body)
        default:                  // a browser tab
            let m = "window.__bsMedia"
            let code: String
            switch op {
            case "play": code = "\(m).play()"
            case "pause": code = "\(m).pause()"
            case "seek": code = "\(m).currentTime = \(num(c["t"] as? Double ?? 0))"
            case "rate": code = "\(m).preservesPitch = true; \(m).playbackRate = \(num(c["r"] as? Double ?? 1))"
            case "loop": code = "\(m).loop = \(nativeLoop)"
            case "volume": code = "\(m).muted = false; \(m).volume = \(num(c["v"] as? Double ?? 1))"
            default: return
            }
            body = tell(app, js(app, "if (\(m)) { \(code); } ''", in: target))
        }
        q.async { var e: NSDictionary?; _ = NSAppleScript(source: body)?.executeAndReturnError(&e)
            if let e { log("\(app) command failed: \(e[NSAppleScript.errorMessage] ?? e)") } }
    }

    private func run(_ name: String, _ src: String) -> NSAppleEventDescriptor? {
        if scripts[name] == nil { let s = NSAppleScript(source: src); s?.compileAndReturnError(nil); scripts[name] = s }
        var e: NSDictionary?
        let r = scripts[name]?.executeAndReturnError(&e)
        if let e, (e[NSAppleScript.errorNumber] as? Int) != -1728 {
            let msg = "\(name.prefix(40)) poll failed: \(e[NSAppleScript.errorMessage] ?? e)"
            if logged.insert(msg).inserted { log(msg) }      // once each, not 20 times a second
        }
        return r
    }
}

// ---------- Gallery: transcripts for the audio and video in Main ----------
// Gallery (a Cloudflare Worker over the gallery-main bucket, same R2 account) shows these transcripts under its
// players. While nothing plays here, Recense takes the next file in gallery-main/files/ with no transcript and
// transcribes it like any other source: its address is "gallery:files/<path>", its key its content's (ContentKey), and
// the transcript goes to its folder in keep/ like any other item's (Keep): the original and its English first, then
// its Vietnamese and French. Files transcribed before those existed get them too, one at a time, while idle. The Worker computes the same key (and follows library.json's aliases when
// the recording was already transcribed from somewhere else). One file at a time.
@MainActor enum GalleryJob {
    static let bucket = "gallery-main"
    static let audioExt: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aif", "aiff", "caf"]
    static let videoExt: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv"]
    static var running = false
    /// Files given up on (undecodable, failed twice): not tried again until the file changes (its size is part of the entry).
    static var skipped: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "gallerySkipped") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "gallerySkipped") }
    }

    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    static func objectPath(_ key: String) -> String {
        "/\(bucket)/" + key.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: unreserved)! }.joined(separator: "/")
    }

    /// A file's content key (ContentKey), from two ranged reads; remembered by path and size so a listing costs nothing.
    static var fingerprints: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "galleryFingerprints") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "galleryFingerprints") }
    }
    static func contentKey(_ path: String, size: Int? = nil) async -> String? {
        if let size, let k = fingerprints["\(path)|\(size)"] { return k }
        func range(_ r: String) async -> (Data, Int)? {
            var q = Store.signed("GET", objectPath("files/" + path)); q.setValue("bytes=" + r, forHTTPHeaderField: "Range")
            guard let (d, resp) = try? await URLSession.shared.data(for: q), let h = resp as? HTTPURLResponse, [200, 206].contains(h.statusCode)
            else { return nil }
            let total = (h.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last).flatMap { Int($0) } ?? d.count
            return (d, total)
        }
        guard let (head, total) = await range("0-\(ContentKey.span - 1)") else { return nil }
        let tail = total <= ContentKey.span ? head : await range("\(total - ContentKey.span)-\(total - 1)")?.0
        guard let tail else { return nil }
        let k = ContentKey.key(size: total, head: head, tail: tail)
        fingerprints["\(path)|\(total)"] = k
        return k
    }
    /// The key a Gallery file's transcript is under: its content key, or the path's older key where only that one has
    /// a transcript (in keep/, or on this Mac). Registered for its address, so Episode uses the same.
    static func itemKey(_ path: String, size: Int? = nil, listing: [String: Set<String>]? = nil) async -> String? {
        let src = "gallery:files/" + path, legacy = cacheKey(src)
        guard let fp = await contentKey(path, size: size) else { return nil }
        let has = { (k: String) in listing?[k].map { $0.contains("asr") || $0.contains("v2") } ?? false }
        var k = ContentKey.choose(fp, legacy: legacy)
        if !has(fp) && has(legacy) && !stub(legacy) { k = legacy }
        ContentKey.known[src] = k
        return k
    }

    /// An empty transcript this Mac sent to keep/ before pushTranscript refused them (notes 38): counted as none.
    static func stub(_ k: String) -> Bool {
        guard let c = Episode.Cache.read(k) else { return false }
        return c.complete != true && c.lines.isEmpty
    }

    /// Every audio/video file under files/, path (after files/) → bytes.
    static func media() async -> [String: Int]? {
        var out: [String: Int] = [:], token: String?
        func unescape(_ s: Substring) -> String {
            s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
        }
        repeat {
            var q = ["list-type": "2", "prefix": "files/"]
            if let token { q["continuation-token"] = token }
            guard let (d, resp) = try? await URLSession.shared.data(for: Store.signed("GET", "/\(bucket)", query: q)),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let x = String(decoding: d, as: UTF8.self)
            for m in x.matches(of: #/<Key>([^<]+)</Key>.*?<Size>(\d+)</Size>/#) {
                let path = String(unescape(m.1).dropFirst("files/".count))
                let ext = (path as NSString).pathExtension.lowercased()
                if audioExt.contains(ext) || videoExt.contains(ext), !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                    out[path] = Int(m.2) ?? 0
                }
            }
            token = x.contains("<IsTruncated>true") ? x.firstMatch(of: #/<NextContinuationToken>([^<]+)</#)?.1.description : nil
        } while token != nil
        return out
    }

    /// Transcribes Gallery's files that have none yet, one by one, for as long as `idle()` holds.
    static func run(idle: @escaping @MainActor () -> Bool) async {
        guard Store.r2, !running, idle() else { return }
        running = true; defer { running = false }
        guard let files = await media(), !files.isEmpty, let listing = await Keep.listing() else { return }
        let have = Set(listing.filter { $0.value.contains("asr") || $0.value.contains("v2") }.keys)
        defer { Task { await translateMissing(files, listing, idle: idle); await measureMissing(files, listing, idle: idle) } }
        var todo: [(key: String, value: Int)] = []
        for (path, size) in files.sorted(by: { $0.key < $1.key }) where !skipped.contains("\(path)|\(size)") {
            guard let k = await itemKey(path, size: size, listing: listing) else { continue }
            if (!have.contains(k) || stub(k)) && Library.resolve(k) == nil { todo.append((path, size)) }
        }
        guard !todo.isEmpty else { return }
        log("gallery: \(todo.count) file(s) to transcribe")
        for (path, size) in todo {
            guard idle() else { log("gallery: paused (something is playing)"); return }
            // a file someone asked for (Retranscribe, or opened in Gallery) goes before the rest: it waited behind
            // 353 voice memos for hours
            guard !asked else { log("gallery: paused for a file asked for"); return }
            if await transcribe(path, idle: idle) == false { skipped.insert("\(path)|\(size)") }
        }
    }

    // ---- asked for by Gallery's viewers ----
    // Opening a file with no transcript in Gallery leaves a request, keep/locks/<key> { state, at, beat, path, src,
    // redo, progress }, which every viewer of it shares (it lapses 15 minutes after its last beat). Polled every
    // minute: taken while nothing plays here (kept alive meanwhile), beaten with the progress while transcribing,
    // deleted once <key>.v2.json is in keep/, marked failed (nothing partial written) when it can't be done.
    static var serving = false
    static var asked = false             // a request waits for the backfill (run) to step aside
    static var current: String?          // the file being transcribed

    static func lock(_ own: String) async -> [String: Any]? {
        guard let (d, resp) = try? await URLSession.shared.data(for: Store.request("GET", own, dir: "keep/locks")),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    static func setLock(_ own: String, _ l: [String: Any]?) async {
        var r = Store.request(l == nil ? "DELETE" : "PUT", own, dir: "keep/locks")
        if let l, let d = try? JSONSerialization.data(withJSONObject: l) { r.httpBody = d; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        _ = try? await URLSession.shared.data(for: r)
    }
    static func beat(_ own: String, state: String, progress: Double? = nil) async {
        guard var l = await lock(own), l["state"] as? String != "failed" else { return }
        l["state"] = state; l["beat"] = (Date().timeIntervalSince1970 * 1000).rounded()
        if let progress { l["progress"] = (progress * 100).rounded() / 100 }
        await setLock(own, l)
    }

    static func serve(idle: @escaping @MainActor () -> Bool) async {
        guard Store.r2, !serving else { return }
        serving = true; defer { serving = false }
        asked = false                    // set again below while a request still waits
        guard let names = await Store.list("keep/locks/")?.keys, !names.isEmpty else { return }
        for name in names.sorted() {
            let own = String(name.dropFirst("keep/locks/".count))
            guard own.count == 24, let l = await lock(own), let path = l["path"] as? String,
                  l["state"] as? String != "failed", current != path else { continue }
            if cacheKey("gallery:files/" + path) != own {
                guard let cur = await contentKey(path) else { continue }
                // The file was replaced since it was asked for: its request named the old content and was skipped every
                // minute while Gallery showed it queued. Dropped; Gallery asks again under the new key (notes 38).
                guard cur == own else { log("gallery: \(path) changed since it was asked for; request dropped"); await setLock(own, nil); continue }
            }
            let now = Date().timeIntervalSince1970 * 1000, last = (l["beat"] as? Double) ?? (l["at"] as? Double) ?? 0
            // Asked for while it plays here (Retranscribe is pressed with the file open in Gallery): never idle, so
            // the request used to wait forever. The playing episode does the work and the lock follows it.
            if let ep = Recense.delegate?.episode, ep.url == "gallery:files/" + path {
                if l["redo"] as? Bool == true {
                    log("gallery: asked for \(path) (retranscribe, playing here)")
                    var n = l; n["redo"] = false; n["state"] = "running"; n["progress"] = 0
                    n["beat"] = (now).rounded(); await setLock(own, n)
                    Recense.delegate?.restartFresh(lang: l["lang"] as? String)
                } else if ep.complete {
                    ep.save(); _ = await Keep.pushTranscript(Library.resolve(ep.key)?.key ?? ep.key); await setLock(own, nil)
                } else {
                    await beat(own, state: "running", progress: ep.done.isEmpty ? 0 : Double(ep.done.filter { $0 }.count) / Double(ep.done.count))
                }
                continue
            }
            if l["state"] as? String == "running" && now - last < 15 * 60_000 { continue }     // another Mac has it
            guard !running && idle() else { asked = running; await beat(own, state: "queued"); continue }   // waits, kept alive
            log("gallery: asked for \(path)\(l["redo"] as? Bool == true ? " (retranscribe)" : "")")
            running = true; asked = false
            let ok = await transcribe(path, redo: l["redo"] as? Bool == true, asked: true, idle: idle, lang: l["lang"] as? String)
            if ok == true { await setLock(own, nil) }                                          // an older viewer's lock by path
            running = false
            return                                                                              // one at a time
        }
    }

    /// One file: fetched into the cache (a video's sound only), transcribed and translated, sent to keep/.
    /// nil = stopped part way (to be picked up again later); false = this file can't be done.
    /// `redo` (Retranscribe in Gallery): made again from scratch, its corrections kept and its glossary the prompt;
    /// the transcript it had stays in keep/ until the new one is done; translated again, `lang` (Gallery's) first.
    static func transcribe(_ path: String, redo: Bool = false, asked: Bool? = nil, idle: (@MainActor () -> Bool)? = nil, lang: String? = nil) async -> Bool? {
        let src = "gallery:files/" + path
        guard let key = await itemKey(path, listing: await Keep.listing()) else { log("gallery: couldn't read \(path)"); return nil }
        let ext = (path as NSString).pathExtension.lowercased(), video = videoExt.contains(ext)
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        log("gallery: \(path)")
        current = path; defer { current = nil }
        var asked = asked
        if asked == nil { asked = await lock(key) != nil }
        if asked == true { await beat(key, state: "running", progress: 0) }
        func failed(_ why: String) async { if asked == true { await setLock(key, ["state": "failed", "error": why, "at": (Date().timeIntervalSince1970 * 1000).rounded(), "path": path]) } }

        let have = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path))?
            .contains { $0.hasPrefix(key + ".") && !$0.hasSuffix(".json") } ?? false
        if !have {
            guard let (tmp, resp) = try? await URLSession.shared.download(for: Store.signed("GET", objectPath("files/" + path))),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { log("gallery: couldn't download \(path)"); await failed("couldn't download"); return nil }
            if video {
                let out = cacheDir.appendingPathComponent(key + ".m4a")
                let ok: Bool = await Task.detached {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
                    p.arguments = ["-nostdin", "-loglevel", "error", "-y", "-i", tmp.path, "-vn", "-c:a", "aac", "-b:a", "160k", out.path]
                    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                    do { try p.run() } catch { return false }
                    p.waitUntilExit()
                    return p.terminationStatus == 0
                }.value
                try? FileManager.default.removeItem(at: tmp)
                guard ok else { log("gallery: no sound in \(path)"); await failed("no sound"); return false }
            } else {
                let dest = cacheDir.appendingPathComponent(key + "." + ext)
                try? FileManager.default.removeItem(at: dest)
                guard (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else { await failed("couldn't store it"); return nil }
            }
        }

        // a retranscription starts from nothing: the transcript this Mac has is set aside (back if this fails)
        let tkey = Library.resolve(key)?.key ?? key, json = cacheDir.appendingPathComponent(tkey + ".v2.json")
        let aside = FileManager.default.temporaryDirectory.appendingPathComponent("recense-redo-\(tkey).json")
        let setAside = redo && (try? FileManager.default.moveItem(at: json, to: aside)) != nil
        if redo { setAsideTranslations(tkey) }

        let ep = Episode(url: src, page: nil, title: name, music: !video) { 0 }
        if redo { ep.retranslate = true; ep.firstLang = lang }
        func restore() {
            guard setAside else { return }
            try? FileManager.default.removeItem(at: json); try? FileManager.default.moveItem(at: aside, to: json)
            for lang in Keep.others {      // and its translations, set aside with it
                let to = FileManager.default.temporaryDirectory.appendingPathComponent("recense-redo-\(tkey).tr.\(lang).json")
                if FileManager.default.fileExists(atPath: to.path) {
                    try? FileManager.default.removeItem(at: Keep.trURL(tkey, lang)); try? FileManager.default.moveItem(at: to, to: Keep.trURL(tkey, lang))
                }
            }
        }
        guard await ep.fetch() else { log("gallery: can't decode \(path)"); restore(); await failed("can't decode"); return false }
        let t0 = Date()
        var lastBeat = Date()
        func progress() async {
            guard asked == true, Date().timeIntervalSince(lastBeat) >= 60 else { return }
            lastBeat = Date()
            await beat(key, state: "running", progress: ep.done.isEmpty ? 0 : Double(ep.done.filter { $0 }.count) / Double(ep.done.count))
        }
        // transcribed (or found to be a recording already transcribed elsewhere: then it is an alias, and done)
        while !ep.complete && !ep.stopped && Date().timeIntervalSince(t0) < 4 * 3600 {
            try? await Task.sleep(for: .seconds(10))
            await progress()
        }
        // then its English, for a while
        let t1 = Date()
        while !ep.stopped && ep.lines.contains(where: { $0.english == nil }) && Date().timeIntervalSince(t1) < 1800 {
            try? await Task.sleep(for: .seconds(10))
            await progress()
        }
        // a retranscription that heard nothing (the Whitacre's, over the full mix: 22 lines became none) never
        // replaces the transcript it had
        let emptied = setAside && ep.complete && ep.lines.isEmpty && Library.resolve(key) == nil
        if emptied { log("gallery: \(path) heard nothing this time: its transcript is kept"); ep.stopped = true }
        let done = !emptied && (ep.complete || Library.resolve(key) != nil)
        let out = Library.resolve(key)?.key ?? key
        // only a finished transcript goes to keep/: Gallery never shows half of one as if it were done
        if done && ep.complete && !ep.stopped {
            ep.save()
            await Keep.pushTranscript(out)
            await setLock(key, nil)                  // Gallery shows it from here; its Vietnamese and French follow
            await translations(ep, idle: idle)
        }
        ep.stop()
        await Library.mirror()
        if done {
            if setAside { try? FileManager.default.removeItem(at: aside) }
            await Keep.pushTranscript(out)
            for lang in Keep.others { await Keep.pushTranslation(out, lang) }
            await setLock(key, nil)
        } else {
            restore()
            await failed("unfinished")
        }
        log("gallery: \(path) \(done ? "done" : "unfinished")")
        return done ? true : nil
    }

    /// An item's Vietnamese and French, for up to half an hour (given `idle`, while nothing plays here); each sent to keep/ once it covers the whole transcript.
    static func translations(_ ep: Episode, idle: (@MainActor () -> Bool)? = nil) async {
        let t0 = Date()
        while !ep.stopped && !ep.nativeDone && Date().timeIntervalSince(t0) < 1800 && (idle?() ?? true) {
            try? await Task.sleep(for: .seconds(10))
        }
        for lang in Keep.others where ep.native[lang]?.complete == true { await Keep.pushTranslation(ep.key, lang) }
    }

    static var translated = Set<String>()     // items whose translations were tried since launch

    /// Files transcribed before Vietnamese and French were made: their translations, one item at a time while idle.
    /// Songs in keep/ whose voice was never measured (Features), measured while nothing plays from their vocal stem,
    /// while R2's tmp/ still has it (a song played again is measured as it plays). Each is tried once a run.
    /// A song with no stem anywhere (its separation failed: Demucs had no ffmpeg until 2026-10-30, so no notation or
    /// cadence) is separated again here from Gallery's file, then measured.
    static var measured = Set<String>()
    static func measureMissing(_ files: [String: Int], _ listing: [String: Set<String>], idle: @escaping @MainActor () -> Bool) async {
        guard !running, idle(), let tmp = await Store.list("tmp/") else { return }
        running = true; defer { running = false }
        var paths: [String: String]? = nil          // key → Gallery path, worked out once, when it's first needed
        for (key, parts) in listing.sorted(by: { $0.key < $1.key })
        where (parts.contains("asr") || parts.contains("v2")) && !parts.contains("features") && !measured.contains(key) {
            guard idle() else { return }
            measured.insert(key)
            let name = key + "-vocals.wav", local = cacheDir.appendingPathComponent(name)
            let here = FileManager.default.fileExists(atPath: local.path)
            guard here || tmp["tmp/" + name] != nil, let stem = here ? local : await Store.restore([name]) else {
                if paths == nil {
                    var m: [String: String] = [:]
                    for (p, size) in files where audioExt.contains((p as NSString).pathExtension.lowercased()) {
                        if let k = await itemKey(p, size: size, listing: listing) { m[Library.resolve(k)?.key ?? k] = p }
                    }
                    paths = m
                }
                guard let path = paths?[key], idle() else { continue }
                await Store.restoreTranscript(key)
                let ep = Episode(url: "gallery:files/" + path, page: nil, title: nil, music: false) { 0 }
                // (a song: an hour-long lecture also carries songPipeline 4, and would hold the GPU for an hour)
                // (Music-folder pieces run longer: a sutra, a suite; up to 40 minutes)
                if ep.complete, ep.isSong, !ep.instrumental, ep.duration > 0, ep.duration < (ep.inMusicFolder ? 2400 : 900), await ep.fetch(audio: true) {
                    await ep.measureVoice()                // separates, measures, sends features.json to keep/
                    if ep.features != nil { log("gallery: separated and measured the voice of \(path)") }
                } else if ep.complete, !ep.isSong, !ep.instrumental, ep.duration > 0, ep.duration <= Episode.speechLimit, await ep.fetch(audio: true) {
                    await ep.measureVoice()                // speech: measured on its own sound (measureSpeech)
                    if ep.features != nil { log("gallery: measured the speech of \(path)") }
                }
                ep.stop()
                continue
            }
            let f: Features? = await Task.detached(priority: .utility) {
                guard let s = try? decodeChunk(stem, from: 0, to: 3600), !s.isEmpty else { return nil }
                return Features.measure(s, source: "vocals")
            }.value
            if !here { try? FileManager.default.removeItem(at: stem) }      // R2 still has it
            guard let f else { continue }
            f.write(key)
            if await Keep.pushFeatures(key) { log("gallery: measured the voice of \(key)") }
        }
    }

    static func translateMissing(_ files: [String: Int], _ listing: [String: Set<String>], idle: @escaping @MainActor () -> Bool) async {
        guard !running else { return }
        running = true; defer { running = false }
        for path in files.keys.sorted() {
            guard idle() else { return }
            let src = "gallery:files/" + path
            guard let own = await itemKey(path, size: files[path], listing: listing) else { continue }
            let key = Library.resolve(own)?.key ?? own
            guard let parts = listing[key], parts.contains("asr") || parts.contains("v2"),
                  Keep.others.contains(where: { !parts.contains("tr/" + $0) }), !translated.contains(key) else { continue }
            translated.insert(key)
            await Store.restoreTranscript(key)
            let ep = Episode(url: src, page: nil, title: nil, music: audioExt.contains((path as NSString).pathExtension.lowercased())) { 0 }
            guard ep.complete else { ep.stop(); continue }
            log("gallery: translating \(path) into Vietnamese and French")
            ep.tasks = [Task { await ep.translateLoop() }]
            await translations(ep, idle: idle)
            if !ep.nativeDone { translated.remove(key) }   // stopped by time or play: picked up again later
            ep.stop()
            await Keep.pushTranscript(ep.key)       // its English may have been finished too
            for lang in Keep.others { await Keep.pushTranslation(ep.key, lang) }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var overlay: Overlay!, menu: NSMenu!
    var statusUntil = Date.distantPast
    var sigint: DispatchSourceSignal?, sigterm: DispatchSourceSignal?
    var server: Server?
    var episode: Episode?
    var episodeState = ""                      // loading | ready | need-bytes | failed
    var browserMode = false                    // a player with exact sync has the window
    var exportItem: NSMenuItem!
    var globalPaused = true     // the system's ⏯ state as last pressed here (macOS 15.4+ won't say what is playing)
    let bookmarksMenu = NSMenu()

    struct Pos { var url = ""; var t = 0.0; var rate = 1.0; var paused = true; var dur = 0.0; var sent = 0.0; var received = Date.distantPast; var pausedAt = Date.distantPast; var source = "browser"; var path = ""
        var vol: Double? = nil         // the player's own volume, 0…1 (0 when muted); nil: it doesn't say (an older bridge)
        var ad = false }               // the bridge says an ad is playing (SPEC 17): shown as one, never transcribed
    var pos = Pos()
    /// Track loop is a standing choice, like QuickTime's ⌥⌘L: it carries over to the next track, file, tab or
    /// player (and across launches) until it's turned off. A and B belong to one track and are cleared.
    var loop = LoopState(track: UserDefaults.standard.bool(forKey: "loopTrack")) {
        didSet { if loop.track != oldValue.track { UserDefaults.standard.set(loop.track, forKey: "loopTrack") } }
    }
    var scrubbing = false { didSet { kick() } }                    // the home bar's time ruler is out: A–B holds off
    var pendingCmds: [[String: Any]] = []    // delivered to the extension with its next position report
    /// The sound tray's EQ, Key and Reverb (SPEC 54), made by the bridge in the followed page (content.js): as the tray last
    /// set it, numbered so every page that reports another number is sent it again (a new tab, a reload, a restart).
    var sound: [String: Any] = ["eq": ["low": 0, "mid": 0, "high": 0], "key": 0, "mix": 0, "room": "room"]
    var soundV = 0
    var fxNo: String?                         // the followed page can't take it: "cors", "gallery", "audio"
    let soundEngine = SoundEngine()           // note 30: the tray's sound for players the bridge can't reshape
    var nativeLast: (pid: pid_t?, v: Int) = (nil, -1)
    var fxKeySaid = false
    var cmdSeq = 0 { didSet { kick() } }
    var lastPush = Date.distantPast   // reports from before the page ran command #cmdSeq are stale
    var deliveredAt = 0.0                     // when queued commands last went to the page
    var expectPaused: Bool?                   // what the play button shows until the page confirms
    let native = NativeSources()
    var nativeRate = 1.0                      // QuickTime's rate is 0 while paused; this is the speed to play at

    /// The player's position right now, extrapolated from its last report.
    var mediaTime: Double {
        pos.paused ? pos.t : pos.t + (Date().timeIntervalSince1970 - pos.sent) * pos.rate
    }

    /// mediaTime eased frame to frame: report jitter is absorbed instead of making the light twitch
    /// backwards; seeks, pauses and big corrections snap.
    var shownT = 0.0, lastFrame = 0.0
    func smoothTime() -> Double {
        let target = mediaTime, now = CACurrentMediaTime()
        let dt = min(0.1, now - lastFrame); lastFrame = now
        let predicted = shownT + dt * pos.rate
        if pos.paused || abs(target - predicted) > 0.25 { shownT = target }
        else { shownT = max(shownT, predicted + (target - predicted) * 0.15) }
        return shownT
    }

    /// The followed player is still there (playing or paused): its subtitles and controls stay up, so it can be
    /// played again from the window or the menu however long it sat paused. Another player takes over by playing.
    /// A paused page's timers may be throttled to a report every few seconds (a background tab): it keeps the window
    /// longer. A stream that just changed address (YouTube re-creates its blob: URL every few seconds) keeps it
    /// while /media confirms it's the same piece, instead of blanking the window for that round trip.
    /// An episode whose audio couldn't be fetched still shows the transcript it has (cached, or from keep/): only one
    /// with no lines at all leaves the window to "no transcribed speech".
    var browserActive: Bool {
        guard let ep = episode, episodeState != "failed" || !ep.lines.isEmpty, reported else { return false }
        return ep.url == pos.url || (browserMode && Date().timeIntervalSince(addressChanged) < 3)
    }
    var addressChanged = Date.distantPast
    /// The followed player is still there: it reported lately. A browser tab playing the transcribed piece may go quiet
    /// for 5–15 s (Firefox throttles a tab whose window is covered or in the background); it's followed through that
    /// on the clock, or the window flipped to "Play something" and back every few seconds (notes row 36). A pause is
    /// reported at once, so only a closed tab is followed on for those seconds.
    var reported: Bool {
        let quiet = pos.paused ? 30 : pos.source == "browser" && episode?.url == pos.url ? 20 : 2.5
        return Date().timeIntervalSince(pos.received) < quiet
    }

    // ----- two players at once -----
    // The player started last is the one being watched: it takes the window, and one that was already playing never
    // takes it back (they used to trade it on every report, reloading the subtitles back and forth several times a
    // second). Pausing doesn't give the turn away: the paused player keeps the window until another one starts.
    var owner = ""                             // the followed player: "app|document or tab", or "browser|piece" (bridge)
    var ownerStart: Date?                      // when it last started playing; nil if it never played while followed
    var playingSince: [String: (since: Date, seen: Date)] = [:]
    let launched = Date()
    /// A player's report: since when it has been playing, or nil while it isn't. A few seconds without playing
    /// (paused, buffering, gone) and its next play counts as a new start. Whatever was playing when Recense
    /// started counts as playing from long before, so nothing changes hands at launch.
    @discardableResult func heard(_ id: String, playing: Bool) -> Date? {
        let now = Date()
        playingSince = playingSince.filter { now.timeIntervalSince($0.value.seen) < 3 }
        guard playing else { return nil }
        let since = playingSince[id]?.since ?? (now.timeIntervalSince(launched) < 3 ? .distantPast : now)
        playingSince[id] = (since, now)
        if id == owner { ownerStart = since }
        return since
    }
    /// May this player have the window? The followed one may; another one if it started playing after the followed
    /// one last did, or the followed one never played, or has gone quiet.
    var mediaPage: [String: String] = [:]      // a stream's page, from its /media request
    func mayTake(_ id: String, since: Date?) -> Bool {
        if id == owner || owner.isEmpty || Date().timeIntervalSince(pos.received) > (pos.paused ? 30 : 2.5) { return true }
        guard let since else { return false }
        guard let start = ownerStart else { return true }
        return since > start
    }
    func follow(_ id: String, since: Date?) {
        if id != owner { owner = id; ownerStart = since; native.follow = id }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        overlay = Overlay()
        overlay.onCmd = { [weak self] c in self?.command(c) }
        overlay.onSkipAd = { [weak self] in self?.skipAd() }
        overlay.onBookmark = { [weak self] in self?.addBookmark() }
        overlay.bookmarks = { [weak self] in self.map { Bookmarks.all[$0.bookmarkKey] ?? [] } ?? [] }
        overlay.onBarAction = { [weak self] k, b in
            guard let self else { return }
            switch k {
            case "bookmark": self.addBookmark()
            case "jump": if let t = (b["t"] as? NSNumber)?.doubleValue { self.command(.seek(t)) }
            case "retranscribe": self.retranscribe()
            case "export": self.export(audiobook: b["as"] as? String == "m4b")
            case "download": self.downloadPlayed()
            case "clear": self.clearTranscript()
            case "timing": if let l = self.editable { self.timeLine(l) } else { self.overlay.toast.say("Edit a line, then Timing") }
            case "share": self.shareSource()
            case "fx": self.setSound(b)
            case "chroma?": self.wantChords()          // the tray's chord detector asks (4 a second while it is on)
            case "chord":
                let t = b["t"] as? String
                Prosody.heard(chord: t, key: self.episode?.key ?? "")
                // with notation on screen the progression is drawn in the lane under the words (item 20)
                self.overlay.showChord(Prosody.mode.contains("c") && Prosody.live != nil ? nil : t)
            case "notation":
                if let m = b["m"] as? String, ["p", "c", "n", "pc", "pn", "cn", ""].contains(m) { Prosody.mode = m; self.overlay.lastKey = "" }
            default: break
            }
        }
        overlay.onEdit = { [weak self] clicked in self?.edit(clicked: clicked) }
        // Learning's barrel picked line j: play from it (transcript time back to the player's, as frame() maps it)
        overlay.onPick = { [weak self] j in
            guard let self, let ep = self.episode, ep.shown.indices.contains(j) else { return }
            self.command(.seek(ep.shown[j].start - 0.05 - cfg.syncOffset * self.pos.rate + ep.shift))
        }
        overlay.onReset = { [weak self] in self?.resetLine() }
        overlay.onRetranscribe = { [weak self] in self?.retranscribe() }
        overlay.onExport = { [weak self] in self?.exportTranscript() }
        overlay.lineState = { [weak self] in (self?.editable != nil, self?.editable.map(Episode.isEdited) ?? false) }
        overlay.setControls(false)
        // No status item of its own: Recense shows this menu as "Recense" in its menu bar.
        let m = NSMenu(title: "Recense")
        // SPEC 32: CC On/Off plays or pauses the player in whatever tab Recense follows (it no longer hides the window).
        let cc = m.addItem(withTitle: "CC Off", action: #selector(toggleCC), keyEquivalent: "m")
        cc.target = self
        ccItem = cc
        let ly = m.addItem(withTitle: "Hide Captions for This Track", action: #selector(toggleLyrics), keyEquivalent: "")
        ly.target = self
        lyricsItem = ly
        // Text Size and Balance: two compact rows, applied as they move
        let redraw = { [weak self] in self?.overlay.lastKey = ""; self?.overlay.fits = [:] }
        var sizeRow: ReaderRow!
        let smaller = ReaderRow.step("A−", size: 11) { Reader.set(scale: Double(Reader.scale) - 0.1); sizeRow.slider.doubleValue = Double(Reader.scale); redraw() }
        let larger = ReaderRow.step("A+", size: 15) { Reader.set(scale: Double(Reader.scale) + 0.1); sizeRow.slider.doubleValue = Double(Reader.scale); redraw() }
        sizeRow = ReaderRow(caption: "Text Size", left: smaller, right: larger, value: Double(Reader.scale),
                            min: Reader.sizes.lowerBound, max: Reader.sizes.upperBound, ticks: 0)
        sizeRow.onChange = { v in Reader.set(scale: v); redraw() }
        let l1 = ReaderRow.mark("L1", size: 11, weight: .semibold), l2 = ReaderRow.mark("L2", size: 11, weight: .semibold)
        l1.toolTip = "The original"; l2.toolTip = "The trailing language (EN | VI | FR)"
        let balRow = ReaderRow(caption: "Balance", left: l1, right: l2, value: Reader.balance, min: -1, max: 1, ticks: 5)
        balRow.slider.toolTip = "Toward L1: the original grows and the trailing line recedes; all the way, it's hidden. Toward L2, the other way round. Centre: the same size."
        balRow.onChange = { v in
            Reader.set(balance: v)
            if balRow.slider.doubleValue != Reader.balance { balRow.slider.doubleValue = Reader.balance }   // the detents
            redraw()
        }
        for r in [sizeRow!, balRow] { let it = NSMenuItem(); it.view = r; m.addItem(it) }
        m.addItem(.separator())
        exportItem = m.addItem(withTitle: "Export Transcript…", action: #selector(exportTranscript), keyEquivalent: "e")
        exportItem.target = self
        m.addItem(withTitle: "Bookmarks", action: nil, keyEquivalent: "").submenu = bookmarksMenu
        // Inside Recense: no Open at Login, Restart or Quit (they would act on Recense), and Recense owns the signals.
        m.autoenablesItems = false; m.delegate = self
        menu = m

        log(OnDeviceASR.enabled ? "speech: transcribing on this Mac (SpeechAnalyzer\(OpenEars.installed ? " + open ears" : ""), no Groq)"
                                : "speech: this Mac can't transcribe (needs macOS 26 and Recense built with its SDK): transcripts already made still play")
        OnDeviceASR.startup()
        do {
            let s = try Server(port: 47123) { [weak self] p, q, b in await self?.handle(p, q, b) ?? [:] }
            s.start(); server = s
        } catch { log("server error: \(error.localizedDescription)") }

        // Draw in step with the display (also while menus or drags are tracking); a slow timer keeps
        // mode switching alive while the window is hidden and the display link is idle.
        sweepExports()
        // Media leaves this Mac once it's no longer in use (Store); checked now and every 6 hours.
        URLCache.shared = URLCache(memoryCapacity: 8 << 20, diskCapacity: 0)
        let sweep = { [weak self] in _ = Task { await Store.sweep(keep: self?.episode?.key) } }
        // keep/'s library merged in before this Mac's is mirrored over it; then earlier transcripts are filed.
        Task { [weak self] in await Library.pull(); await Store.sweep(keep: self?.episode?.key); await Library.backfill() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in sweep() }
        // Gallery's media, transcribed while nothing plays here (checked every 15 minutes)
        let gallery = { [weak self] in
            _ = Task { await GalleryJob.run { self?.galleryIdle ?? false } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { gallery() }
        Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { _ in gallery() }
        // and what Gallery's viewers asked for (keep/locks/), every minute
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            _ = Task { await GalleryJob.serve { self?.galleryIdle ?? false } }
        }
        // Handoff (handoff.swift): the transcript and place shared with Gallery's Listen on the iPhone and iPad
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { _ = Task { await Handoff.tick(self) } } }
        }
        let link = overlay.panel.contentView!.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        let slow = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.overlay.minimized == true { self?.frame() } }
        }
        RunLoop.main.add(slow, forMode: .common)
        pollLoop()
    }

    // Inside Recense the idle cost must stay near zero (SL1): players are polled at 20 Hz and the display link runs only
    // while something plays or the subtitles are on screen; otherwise one poll a second, enough to notice a player start.
    /// Nothing being transcribed here, so GalleryJob may work: no episode, a finished one, or one that has no audio to
    /// work on (its fetch failed: a YouTube stream yt-dlp couldn't get). That last one used to count as busy for as
    /// long as it stayed the episode, and new Gallery files waited for hours (notes 38).
    var galleryIdle: Bool {
        guard let ep = episode else { return true }
        return ep.complete || ep.stopped || (ep.file == nil && episodeState != "loading")
    }
    var displayLink: CADisplayLink?
    var wasBusy: Bool?
    var wasWorking: Bool?
    var kickedAt = Date.distantPast, pollTimer: Timer?
    var busy: Bool {
        (!pos.paused && reported) || scrubbing || Date().timeIntervalSince(kickedAt) < 3
    }
    /// A command or a drag: back to 20 Hz at once, and for a few seconds after.
    func kick() {
        kickedAt = Date()
        if let t = pollTimer, t.timeInterval > 0.5 { t.fire() }
    }
    func pollLoop() {
        nativeTick()
        let on = busy
        if on != wasBusy { wasBusy = on; log("players polled \(on ? "20 times a second" : "once a second") (playing: \(!pos.paused))") }
        displayLink?.isPaused = !on
        // SPEC 20: the mark is lit while Recense works (a player followed, a transcription running) and dimmed when idle.
        let working = on || GalleryJob.current != nil
        if working != wasWorking {
            wasWorking = working
            NotificationCenter.default.post(name: Recense.workingChanged, object: nil, userInfo: ["working": working])
        }
        if !on { frame() }                        // paused: still draw what changed (a seek, a transcript loaded)
        pollTimer?.invalidate()
        let t = Timer(timeInterval: on ? 0.05 : 1.0, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.pollLoop() } }
        pollTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    @objc func tick(_ l: CADisplayLink) { frame() }

    var loginItem: NSMenuItem!
    @objc func toggleLogin() { setLogin(SMAppService.mainApp.status != .enabled) }
    func setLogin(_ on: Bool) {
        do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
        catch { log("login item: \(error.localizedDescription)") }
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    @objc func toggleOverlay() { overlay.toggle() }

    /// One row, Play while paused and Pause while playing. Like Recense's wake strip, it is the system's ⏯ key, so it
    /// plays or pauses whatever is playing anywhere; a player Recense is following is told directly (and named).
    func menuNeedsUpdate(_ m: NSMenu) {
        let has = !pos.url.isEmpty && Date().timeIntervalSince(pos.received) < 5
        let paused = has ? (expectPaused ?? pos.paused) : globalPaused
        exportItem.isEnabled = episode?.shown.isEmpty == false
        bookmarksMenu.removeAllItems()
        let add = bookmarksMenu.addItem(withTitle: "Add Bookmark…", action: #selector(addBookmark), keyEquivalent: "k")
        add.target = self; add.isEnabled = has
        let marks = has ? Bookmarks.all[bookmarkKey] ?? [] : []
        if !marks.isEmpty { bookmarksMenu.addItem(.separator()) }
        for (i, b) in marks.enumerated() {
            let it = bookmarksMenu.addItem(withTitle: (b.note.isEmpty ? "" : b.note + "  —  ") + clock(b.t), action: #selector(jumpBookmark(_:)), keyEquivalent: "")
            it.target = self; it.tag = i
            let del = bookmarksMenu.addItem(withTitle: "Delete " + clock(b.t), action: #selector(deleteBookmark(_:)), keyEquivalent: "")
            del.target = self; del.tag = i; del.isAlternate = true; del.keyEquivalentModifierMask = .option
        }
    }

    // ----- bookmarks: a moment (+ a note) per media, kept across launches -----
    var bookmarkKey: String { episode?.source ?? pos.url }
    func clock(_ t: Double) -> String { let s = Int(t); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60) }
    @objc func addBookmark() {
        guard !pos.url.isEmpty else { return }
        let t = mediaTime, key = bookmarkKey
        let a = NSAlert()
        a.messageText = "Bookmark \(clock(t))"
        a.informativeText = "Name:"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        NSApp.activate(ignoringOtherApps: true)
        var name = ""
        while name.isEmpty {            // a bookmark needs a name
            guard a.runModal() == .alertFirstButtonReturn else { return }
            name = f.stringValue.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { NSSound.beep() }
        }
        Bookmarks.all[key, default: []].append(.init(t: t, note: name))
        Bookmarks.all[key]!.sort { $0.t < $1.t }
        Bookmarks.save()
        overlay.toast.say("Bookmarked \(clock(t))")
    }
    /// Retranscribe (the home bar): the media on screen made again from scratch, its corrections kept. The
    /// transcript this Mac had is set aside (not deleted) and comes back if the new one can't be started.
    func retranscribe() {
        guard let ep = episode else { return overlay.toast.say("Nothing playing to retranscribe") }
        let a = NSAlert()
        a.messageText = "Retranscribe from the start?"
        a.informativeText = "The whole recording is transcribed and translated again. Your corrections are kept."
        a.addButton(withTitle: "Retranscribe"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        restartFresh(lang: NativeLang.current)
    }

    /// The playing recording transcribed and translated again from nothing, its transcript set aside (back if that
    /// fails); `lang` (the language Retranscribe was pressed in) is translated first.
    func restartFresh(lang: String? = nil) {
        guard let ep = episode else { return }
        // Stopped first: stop() writes what's due, and after the move it wrote the old transcript straight back, so
        // Retranscribe on a file playing here loaded it again and did nothing (notes 38).
        let (url, page, referer, title, music) = (ep.url, ep.page, ep.referer, ep.title, ep.music)
        ep.stop(); episode = nil
        let json = cacheDir.appendingPathComponent(ep.key + ".v2.json")
        let aside = FileManager.default.temporaryDirectory.appendingPathComponent("recense-redo-\(ep.key).json")
        try? FileManager.default.removeItem(at: aside)
        let setAside = (try? FileManager.default.moveItem(at: json, to: aside)) != nil
        setAsideTranslations(ep.key)
        log("retranscribe: \(ep.key)\(setAside ? " (set aside: \(aside.path))" : "")")
        overlay.toast.say("Retranscribing")
        Task {
            let state = await load(url, page: page, referer: referer, title: title, music: music, fresh: true, lang: lang)
            if state == "failed", setAside, !FileManager.default.fileExists(atPath: json.path) {
                try? FileManager.default.moveItem(at: aside, to: json)
                log("retranscribe: couldn't start, the transcript is back")
            }
        }
    }

    @objc func jumpBookmark(_ i: NSMenuItem) {
        guard let b = Bookmarks.all[bookmarkKey], b.indices.contains(i.tag) else { return }
        command(.seek(b[i.tag].t))
    }
    @objc func deleteBookmark(_ i: NSMenuItem) {
        guard var b = Bookmarks.all[bookmarkKey], b.indices.contains(i.tag) else { return }
        b.remove(at: i.tag); Bookmarks.all[bookmarkKey] = b.isEmpty ? nil : b; Bookmarks.save()
    }
    var sourceName: String {
        switch pos.source {
        case "browser": return "browser tab"
        case "quicktime": return "QuickTime Player"
        case "music": return "Music"
        default: return NSRunningApplication.runningApplications(withBundleIdentifier: pos.source).first?.localizedName ?? "player"
        }
    }
    @objc func playPause() { globalPlayPause() }
    /// The menu's CC On/Off (SPEC 32): ⏯ for the followed tab's player; the title says what pressing it does next.
    weak var ccItem: NSMenuItem?
    weak var lyricsItem: NSMenuItem?
    /// The listener's choice for a track the rule turned off (or on): key → shown. (item 22)
    var lyricsChoice: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: "recense.lyricsShown") as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "recense.lyricsShown") }
    }
    var lyricsGate: (key: String, lines: Int, voice: Bool, off: Bool)?
    /// Dense, complex tracks (a choir): their words start Off; the Recense menu shows them for this track.
    func lyricsOff(_ ep: Episode) -> Bool {
        if let c = lyricsChoice[ep.key] { return !c }
        if let g = lyricsGate, g.key == ep.key, g.lines == ep.lines.count, g.voice == (ep.features != nil) { return g.off }
        let off = Cadence.confidence(ep.lines, ep.features, duration: ep.complete ? ep.duration : 0).off
        lyricsGate = (ep.key, ep.lines.count, ep.features != nil, off)
        return off
    }
    @objc func toggleLyrics() {
        guard let ep = episode else { return }
        var c = lyricsChoice; c[ep.key] = lyricsOff(ep); lyricsChoice = c
        overlay.lastKey = ""
    }
    @objc func toggleCC() { ccTitle(paused: globalPlayPause()) }
    func ccTitle(paused: Bool) { let t = paused ? "CC On" : "CC Off"; if ccItem?.title != t { ccItem?.title = t } }
    /// The global ⏯ (Recense's strip button): the player Recense follows is played or paused directly, so the window
    /// changes with it at once; with none, the system's ⏯ key. Recense used to press the system key itself, which macOS
    /// may hand to another app than the one in the window. Returns whether it is paused now.
    @discardableResult func globalPlayPause() -> Bool {
        let has = !pos.url.isEmpty && Date().timeIntervalSince(pos.received) < 5
        if has { let paused = expectPaused ?? pos.paused; setPlaying(paused); globalPaused = !paused; kick(); return globalPaused }
        recensePressPlayPause()
        globalPaused.toggle()
        return globalPaused
    }

    /// Plays or pauses the player last followed, whether or not the window is showing its subtitles.
    /// Pause freezes the words at once. Play flips the button at once but holds the words until the player
    /// reports it's actually playing, so they never run ahead of audio that hasn't started yet.
    func setPlaying(_ play: Bool) {
        guard !pos.url.isEmpty else { return }
        pos.t = mediaTime; pos.sent = now(); pos.paused = true
        if !play { pos.pausedAt = Date() }
        expectPaused = !play
        push(["op": play ? "play" : "pause"])
    }

    /// The whole source, start to end, as a Markdown note or as an audiobook (Audiobook Builder makes the .m4b).
    @objc func exportTranscript() {
        guard let ep = episode, !ep.shown.isEmpty else { return }
        let title = cleanTitle(ep.title ?? URL(string: ep.url)?.lastPathComponent ?? "Recense")
        let a = NSAlert()
        a.messageText = "Export “\(title)”"
        a.informativeText = (ep.progress < 1 ? "Transcribed so far: \(Int(ep.progress * 100))% — the rest isn't in yet.\n\n" : "")
            + "Saved to the Obsidian vault (iCloud), on every device."
        a.addButton(withTitle: "Markdown")
        a.addButton(withTitle: "Audiobook")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        guard r != .alertThirdButtonReturn else { return }
        export(audiobook: r != .alertFirstButtonReturn)
    }

    /// Export as MD, or as M4B (the home bar asks for one or the other, so it doesn't ask again).
    /// The home bar's Download: the audio Recense played (its cached copy), into the export folder.
    func downloadPlayed() {
        guard let ep = episode, let src = ep.audioFile else { return overlay.toast.say("No audio to download yet") }
        do {
            try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
            let title = cleanTitle(ep.title ?? URL(string: ep.url)?.lastPathComponent ?? "Recense")
            let f = exportDir.appendingPathComponent(exportStamp() + " " + title).appendingPathExtension(src.pathExtension)
            try? FileManager.default.removeItem(at: f)
            try FileManager.default.copyItem(at: src, to: f)
            log("downloaded \(f.path)")
            NSWorkspace.shared.activateFileViewerSelecting([f])
        } catch { fail(error.localizedDescription) }
    }

    func export(audiobook: Bool) {
        guard let ep = episode, !ep.shown.isEmpty else { return overlay.toast.say("Nothing to export yet") }
        let title = cleanTitle(ep.title ?? URL(string: ep.url)?.lastPathComponent ?? "Recense")
        do { try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true) }
        catch { return fail("Can't create \(exportDir.path): \(error.localizedDescription)") }
        let lines = ep.shown.filter { !$0.words.isEmpty }
        let source = ep.page ?? ep.url
        let stamp = exportStamp()
        if !audiobook {
            let f = exportDir.appendingPathComponent(stamp + ".md")
            do { try transcriptMarkdown(title, lines, source: source, duration: ep.duration, complete: ep.progress).write(to: f, atomically: true, encoding: .utf8) }
            catch { return fail(error.localizedDescription) }
            log("exported \(f.path)")
            NSWorkspace.shared.activateFileViewerSelecting([f])
        } else {
            Task {
                // A finished transcript's audio may have left this Mac (Store): fetch it back for the chapters.
                if ep.file == nil { _ = await ep.fetch(audio: true) }
                guard let audio = ep.file else { return fail("The audio isn't downloaded yet.") }
                await exportAudiobook(stamp, title, lines, audio: audio, duration: ep.duration, source: source, complete: ep.progress)
            }
        }
    }

    /// Export as M4B (SPEC 57): one file is the endpoint. ffmpeg makes the audiobook in one pass: AAC, a chapter about
    /// every ten minutes (named after its first words), and the transcript inside it as a subtitle track (each line, then
    /// its trailing language), saved into the vault as <stamp>.m4b. No chapter files, no Audiobook Builder step and no
    /// sidecar are left beside it (Export as MD is its own button).
    func exportAudiobook(_ stamp: String, _ title: String, _ lines: [Line], audio: URL, duration: Double, source: String, complete: Double) async {
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return fail("ffmpeg is needed to make the audiobook (brew install ffmpeg).") }
        Store.busy.insert(audio.path); defer { Store.busy.remove(audio.path) }
        let work = cacheDir.appendingPathComponent("export/" + stamp)
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        // ffmetadata: the book's tags and its chapters (=, ;, #, \ and line breaks escaped)
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "=", with: "\\=")
            .replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: "#", with: "\\#").replacingOccurrences(of: "\n", with: " ") }
        let starts = chapterStarts(lines, duration: duration)
        var meta = ";FFMETADATA1\ntitle=\(esc(title))\nalbum=\(esc(title))\nartist=Recense\ngenre=Audiobook\ncomment=\(esc(source))\n"
        for (i, a) in starts.enumerated() {
            let b = i + 1 < starts.count ? starts[i + 1] : duration
            let first = lines.first { $0.start >= a }.map { lineText($0).split(separator: " ").prefix(6).joined(separator: " ") } ?? ""
            meta += "\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(Int(a * 1000))\nEND=\(Int(b * 1000))\ntitle=\(esc(String(format: "%02d", i + 1) + " " + first))\n"
        }
        let metaURL = work.appendingPathComponent("chapters.txt"), vtt = work.appendingPathComponent("transcript.vtt")
        let part = work.appendingPathComponent(stamp + ".m4b"), out = exportDir.appendingPathComponent(stamp + ".m4b")
        do {
            try meta.write(to: metaURL, atomically: true, encoding: .utf8)
            try transcriptVTT(lines).write(to: vtt, atomically: true, encoding: .utf8)
        } catch { return fail(error.localizedDescription) }
        overlay.setStatus("Exporting audiobook…"); statusUntil = Date().addingTimeInterval(1800)
        let ok: Bool = await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-v", "error", "-y", "-i", audio.path, "-f", "ffmetadata", "-i", metaURL.path, "-i", vtt.path,
                           "-map", "0:a:0", "-map", "2:s:0", "-map_metadata", "1", "-map_chapters", "1",
                           "-c:a", "aac", "-b:a", "128k", "-c:s", "mov_text", "-movflags", "+faststart", "-f", "ipod", part.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }.value
        overlay.setStatus(""); statusUntil = .distantPast
        guard ok else { return fail("ffmpeg couldn't make the audiobook.") }
        do {
            try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.moveItem(at: part, to: out)
        } catch { return fail(error.localizedDescription) }
        log("audiobook export: \(out.path) (\(starts.count) chapters, the transcript inside)")
        overlay.toast.say("Exported \(stamp).m4b")
        NSWorkspace.shared.activateFileViewerSelecting([out])
    }

    /// Gallery's Export as M4B (POST /export from the page, SPEC 57) for a file this window isn't playing: its transcript
    /// from keep/ and its audio from Gallery's bucket, as GalleryJob gets them; then the same one-pass audiobook.
    func exportGallery(_ path: String, title: String?) async {
        let src = "gallery:files/" + path
        guard Store.r2, let own = await GalleryJob.itemKey(path, listing: await Keep.listing())
        else { return fail("Recense can't reach Gallery's transcript of \(path).") }
        await Store.restoreTranscript(Library.resolve(own)?.key ?? own)
        let ep = Episode(url: src, page: nil, title: title, music: GalleryJob.audioExt.contains((path as NSString).pathExtension.lowercased())) { 0 }
        defer { ep.stop() }
        let lines = ep.shown.filter { !$0.words.isEmpty }
        guard !lines.isEmpty else { return fail("\(path) has no transcript yet.") }
        if ep.file == nil { _ = await ep.fetch(audio: true) }
        guard let audio = ep.file else { return fail("Couldn't fetch \(path) from Gallery.") }
        let name = cleanTitle(title ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        await exportAudiobook(exportStamp(), name, lines, audio: audio, duration: ep.duration, source: src, complete: ep.progress)
    }

    /// Waits for Audiobook Builder's .m4b to show up in the vault and stop growing, gives it the export's name,
    /// and deletes the chapter files. Anything left behind is swept a day later (sweepExports).
    func watchForAudiobook(_ stamp: String, work: URL, since: Date) {
        let target = exportDir.appendingPathComponent(stamp + ".m4b")
        var lastSize = -1, steady = 0
        let t = Timer(timeInterval: 5, repeats: true) { timer in
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
            // Audiobook Builder saves wherever its preferences say; the .m4b is moved into the vault from there.
            let abbDir = (UserDefaults(suiteName: "com.splasm.audiobookbuilder2")?.string(forKey: "saveAudiobooksToLocationPath"))
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            let built = Set([exportDir, abbDir].compactMap { $0?.standardizedFileURL })
                .flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: keys)) ?? [] }
                .filter { ["m4b", "m4a"].contains($0.pathExtension.lowercased()) }
                .compactMap { u -> (URL, Date, Int)? in
                    guard let v = try? u.resourceValues(forKeys: Set(keys)), let c = v.creationDate, c > since else { return nil }
                    return (u, c, v.fileSize ?? 0)
                }
                .max { $0.1 < $1.1 }
            if Date().timeIntervalSince(since) > 6 * 3600 { timer.invalidate(); return }
            guard let (u, _, size) = built, size > 0 else { return }
            steady = size == lastSize ? steady + 1 : 0; lastSize = size
            guard steady >= 3 else { return }       // 15 s without growing: Audiobook Builder is done writing
            timer.invalidate()
            if u.standardizedFileURL != target.standardizedFileURL, !fm.fileExists(atPath: target.path) {
                do { try fm.moveItem(at: u, to: target) } catch { log("rename \(u.lastPathComponent): \(error.localizedDescription)") }
            }
            try? fm.removeItem(at: work)
            log("audiobook built: \(target.lastPathComponent); chapter files deleted")
        }
        RunLoop.main.add(t, forMode: .common)
    }

    /// Chapter files from an export whose audiobook was never built go after a day.
    func sweepExports() {
        let dir = cacheDir.appendingPathComponent("export")
        for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(m) > 86400 { try? FileManager.default.removeItem(at: u) }
        }
    }

    func fail(_ s: String) {
        log("export: \(s)")
        let a = NSAlert(); a.messageText = "Export failed"; a.informativeText = s; a.runModal()
    }

    @objc func restart() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                       Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// Opening the app again (Finder, Spotlight, `open`) brings the subtitles back if they were closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if overlay.minimized { overlay.toggle() }
        return false
    }

    // ----- player controls (browser mode): sent to the extension, applied here at once so it feels instant -----
    // The extension keeps a /wait request open; a command answers it at once (no polling delay).
    var waiters: [Int: (url: String, c: CheckedContinuation<[[String: Any]], Never>)] = [:]
    var nextWaiter = 0
    func push(_ c: [String: Any]) {
        if pos.source != "browser" {
            if c["op"] as? String == "rate" { nativeRate = c["r"] as? Double ?? 1 }
            cmdSeq += 1; lastPush = Date()
            native.exec(pos.source, target: pos.path, c, rate: nativeRate)
            return
        }
        cmdSeq += 1; lastPush = Date()
        var c = c; c["seq"] = cmdSeq
        pendingCmds.append(c)
        // Only the followed tab runs them: a paused podcast in another tab must not start playing.
        let ws = waiters.filter { $0.value.url == pos.url }
        guard !ws.isEmpty else { return }
        let cmds = pendingCmds; pendingCmds = []; deliveredAt = now()
        for (id, w) in ws { waiters[id] = nil; w.c.resume(returning: cmds) }
    }
    func wait(_ url: String) async -> [[String: Any]] {
        if url == pos.url, !pendingCmds.isEmpty { defer { pendingCmds = []; deliveredAt = now() }; return pendingCmds }
        let id = nextWaiter; nextWaiter += 1
        return await withCheckedContinuation { c in
            waiters[id] = (url, c)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if let w = self?.waiters.removeValue(forKey: id) { w.c.resume(returning: []) }
            }
        }
    }
    func now() -> Double { Date().timeIntervalSince1970 }
    /// An ad the followed page is playing (SPEC 17 + 37): the window shows it as one, and Skip Ad has the bridge skip it.
    var adPlaying: Bool { pos.ad && pos.source == "browser" && Date().timeIntervalSince(pos.received) < 2.5 }
    func skipAd() {
        guard adPlaying else { return }
        push(["op": "skipAd"])
        overlay.toast.say("Skipping ad…")
    }

    func command(_ c: Cmd) {
        // (a player followed without a transcript takes the bar's commands too: its controls are up, see frame())
        guard browserMode || (!pos.url.isEmpty && Date().timeIntervalSince(pos.received) < (pos.paused ? 30 : 2.5)) else { return }
        let dur = episode?.playDuration ?? episode?.duration ?? pos.dur
        switch c {
        case .playPause: setPlaying(expectPaused ?? pos.paused)
        case .play(let on): setPlaying(on)
        case .skip(let d): command(.seek(mediaTime + d))
        case .seek(let t):
            let x = min(max(0, t), dur > 0 ? dur : t)
            pos.t = x; pos.sent = now()
            pendingCmds.removeAll { $0["op"] as? String == "seek" }   // only the latest seek matters while scrubbing
            push(["op": "seek", "t": x])
        case .speed(let r):
            pos.t = mediaTime; pos.sent = now(); pos.rate = r
            push(["op": "rate", "r": r])
        // Loop rules (Gallery's, applied by the home bar): A–B needs Track loop, so turning A–B on turns Track loop
        // on, and turning Track loop off turns A–B off. Clearing A/B leaves Track loop as it is. None of these seek.
        case .loop(let l): loop = l; sendLoop()
        case .scrub(let on): scrubbing = on; if loop.ab { sendLoop() }   // A–B stops jumping back while you seek
        // the player's own volume (QuickTime's, Music's, the tab's): the window shows it and sets it, unmuting
        case .volume(let v):
            let x = min(1, max(0, v))
            pos.vol = x
            push(["op": "volume", "v": x])
        }
    }
    // ----- the sound tray (SPEC 54, note 30): the tray is Recense's own controller. A Firefox page reshapes its own
    // sound through the bridge; any other player (and a page the bridge can't take) is reshaped natively by SoundEngine.
    /// The chord detector (SPEC 40 in Recense, notes 32): while the tray asks, the native chain runs (at unity if the
    /// sound is otherwise flat) and its chroma goes to the page; a second without asking and it stops.
    var chordsAsked = Date.distantPast
    var chordsT: Timer?
    func wantChords() {
        chordsAsked = Date()
        if sound["chords"] == nil {
            sound["chords"] = 1.0; soundV += 1; routeSound()
        }
        if let c = soundEngine.chroma { overlay.homeBar.call("chroma", c) }
        guard chordsT == nil else { return }
        chordsT = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                guard Date().timeIntervalSince(self.chordsAsked) > 1 else { return }
                t.invalidate(); self.chordsT = nil
                self.sound["chords"] = nil; self.soundV += 1; self.routeSound()
                self.overlay.showChord(nil)
            }
        }
    }
    func setSound(_ b: [String: Any]) {
        let num = { (x: Any?) in (x as? NSNumber)?.doubleValue ?? 0 }
        let eq = b["eq"] as? [String: Any] ?? [:]
        sound = ["eq": ["low": num(eq["low"]), "mid": num(eq["mid"]), "high": num(eq["high"])], "key": num(b["key"]),
                 "mix": num(b["mix"]), "room": b["room"] as? String ?? "room", "vox": num(b["vox"])]
        if chordsT != nil { sound["chords"] = 1.0 }
        soundV += 1
        fxKeySaid = false
        pendingCmds.removeAll { $0["op"] as? String == "fx" }
        if pos.source == "browser" { push(soundCmd()) }
        routeSound()
    }
    /// The app whose sound SoundEngine takes, or nil when the bridge does it (or nothing should be taken).
    var nativeSoundPID: pid_t? {
        // Held through a track change too: the new piece's episode loads a moment after its sound starts, and dropping
        // the chain meanwhile let the next track begin in its own key and EQ, then switch (item 21).
        let held = Date().timeIntervalSince(pos.received) < (pos.paused ? 30 : 5)
        guard browserMode || held, !SoundEngine.flat(sound) else { return nil }
        let ids: [String]
        switch pos.source {
        case "browser":
            // Recense's own sound (notes 30): Firefox's output is taken and shaped here, Gallery's page or not; the page's
            // chain (the bridge, or Gallery's) is only the fallback where the native one can't run
            guard SoundEngine.available, soundEngine.state != .denied || fxNo != nil else { return nil }
            ids = ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]
        case "quicktime": ids = ["com.apple.QuickTimePlayerX"]
        case "music": ids = ["com.apple.Music"]
        default: ids = [pos.source]
        }
        for id in ids { if let a = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { return a.processIdentifier } }
        return nil
    }
    /// Engages, retunes or drops the native chain when the followed app or the tray's sound changes (cheap otherwise).
    func routeSound() {
        if soundEngine.onState == nil {
            // the native chain came on or went (denied, failed): the page takes over or lets go, at once
            soundEngine.onState = { [weak self] _ in
                guard let self else { return }
                self.soundV += 1
                self.pendingCmds.removeAll { $0["op"] as? String == "fx" }
                if self.pos.source == "browser" { self.push(self.soundCmd()) }
            }
        }
        let p = nativeSoundPID
        guard p != nativeLast.pid || soundV != nativeLast.v else { return }
        nativeLast = (p, soundV)
        soundEngine.run(pid: p, sound: sound)
    }
    /// What the page is asked to do: nothing while the native chain carries the sound (never shaped twice), else the tray's.
    func soundCmd() -> [String: Any] {
        let native = soundEngine.state == .on || (nativeSoundPID != nil && soundEngine.state == .off)
        let s: [String: Any] = native ? ["eq": ["low": 0.0, "mid": 0.0, "high": 0.0], "key": 0.0, "mix": 0.0, "room": sound["room"] ?? "room", "vox": 0.0] : sound
        return s.merging(["op": "fx", "v": soundV]) { a, _ in a }
    }
    /// The commands for a page's report, with the sound when the page has another than the tray's.
    func soundFor(_ j: [String: Any], _ cmds: [[String: Any]]) -> [[String: Any]] {
        fxNo = j["fxNo"] as? String
        if j["fxKey"] as? Bool == false, !fxKeySaid { fxKeySaid = true; overlay.toast.say("Key isn’t available on this page") }
        guard let v = j["fxv"] as? Int, v != soundV, !cmds.contains(where: { $0["op"] as? String == "fx" }) else { return cmds }
        return cmds + [soundCmd()]   // (an older bridge sends no fxv and ignores "fx")
    }
    /// Why the tray's sound can't reach the followed player, in the tray's words ("EQ: …"), or nil.
    var soundBlock: String? {
        guard browserMode else { return nil }
        guard nativeSoundPID != nil else {
            if pos.source == "browser", fxNo == "gallery" { return "this Gallery is older than the tray's control of it: reload Gallery" }
            return nil
        }
        switch soundEngine.state {
        case .unsupported: return "reshaping this player's sound needs macOS 14.2 or later"
        case .denied: return "allow Recense under Privacy & Security › Audio Capture to reshape this player's sound"
        case .failed: return "this player's sound couldn't be taken (it plays as it is); move a slider to try again"
        case .on, .off: return nil
        }
    }

    func sendLoop() {
        pendingCmds.removeAll { $0["op"] as? String == "loop" }
        var c: [String: Any] = ["op": "loop", "track": loop.track, "ab": loop.ab && !scrubbing]
        if let a = loop.a { c["a"] = a }
        if let b = loop.b { c["b"] = b }
        // the episode's length: the page never loops an ad shown in the same player
        if let ep = episode, (ep.playDuration ?? ep.duration) > 0 { c["dur"] = ep.playDuration ?? ep.duration }
        push(c)
    }

    func handle(_ path: String, _ q: [String: String], _ body: Data) async -> [String: Any] {
        let j = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
        switch path {
        // Recense's strip ⏯ asks here first: a player Recense follows is played or paused directly (handled); anything
        // else is left to Recense's system ⏯ key, and Recense only notes the new state for its menu row.
        // Gallery's Export as M4B (SPEC 57): made here, where ffmpeg is; the file playing in this window, or any Gallery file.
        case "/export":
            guard j["as"] as? String == "m4b", let g = j["gallery"] as? String, g.hasPrefix("files/"), g.count > 6
            else { return ["handled": false, "reason": "Recense only makes M4B audiobooks"] }
            let path = String(g.dropFirst("files/".count))
            if let ep = episode, ep.url == "gallery:files/" + path { export(audiobook: true) }
            else { let title = j["title"] as? String; Task { await exportGallery(path, title: title) } }
            return ["handled": true]
        case "/playpause":
            let has = !pos.url.isEmpty && Date().timeIntervalSince(pos.received) < 5
            if has { let paused = expectPaused ?? pos.paused; setPlaying(paused); globalPaused = !paused }
            else { globalPaused.toggle() }
            return ["handled": has, "paused": has ? !(expectPaused ?? pos.paused) : globalPaused]
        case "/pos":
            guard let url = j["url"] as? String else { return ["state": "other"] }
            let ad = j["ad"] as? Bool ?? false    // an ad (SPEC 17): followed for Skip Ad, never loaded or transcribed
            // The followed stream at a new address (the bridge sends its page): the same piece, so nothing blinks.
            if !ad, let ep = episode, ep.url != url, let page = j["page"] as? String, ep.source == Episode.key(url, page: page) {
                if pos.url == ep.url { pos.url = url }
                ep.url = url; log("same media, new address: \(url.prefix(80))")
            }
            // Only a playing source takes the window from another one that's still reporting.
            if pos.source != "browser", Date().timeIntervalSince(pos.received) < 2.5, j["paused"] as? Bool ?? true {
                return ["state": "other"]
            }
            // A paused tab never takes the window either (it reports every 150 ms, forever), not even right
            // after launch: only what's being followed is kept while paused.
            if j["paused"] as? Bool ?? true, url != pos.url {
                return ["state": "other"]
            }
            let page = j["page"] as? String ?? mediaPage[url]      // bridge 2.1.2 sends the page only with /media
            let who = "browser|" + Episode.key(url, page: page)
            let since = heard(who, playing: !(j["paused"] as? Bool ?? true))
            if !mayTake(who, since: since) { return ["state": "other"] }
            // A report sent before our queued commands reached the page is stale: keep the optimistic
            // position the window already shows, and hand the commands over.
            // (only briefly: a reloaded extension restarts its count)
            // Without a seq (older bridge), a report sent before the page got our commands is stale too.
            let sentAt = (j["sent"] as? Double).map { $0 / 1000 } ?? now()
            let stale = (j["seq"] as? Int).map { $0 < cmdSeq && Date().timeIntervalSince(lastPush) < 2 }
                ?? (!pendingCmds.isEmpty || sentAt < deliveredAt + 0.05)
            if stale, episode?.url == url, pos.url == url {
                pos.received = Date()
                let cmds = pendingCmds; pendingCmds = []; if !cmds.isEmpty { deliveredAt = now() }
                return ["state": episodeState, "cmds": soundFor(j, cmds)]
            }
            let paused = j["paused"] as? Bool ?? true
            let sameMedia = (pos.source == "browser" && pos.url == url) || pos.url.isEmpty   // first report: adopt
            if paused && (!pos.paused || pos.url != url) { pos.pausedAt = Date() }
            let sent = (j["sent"] as? Double).map { $0 / 1000 } ?? Date().timeIntervalSince1970
            if url != pos.url { addressChanged = Date() }
            let flipped = paused != pos.paused || url != pos.url
            pos = Pos(url: url, t: j["t"] as? Double ?? 0, rate: j["rate"] as? Double ?? 1, paused: paused,
                      dur: j["dur"] as? Double ?? pos.dur, sent: sent, received: Date(), pausedAt: pos.pausedAt, vol: j["vol"] as? Double, ad: ad)
            // Played or paused from outside (the keyboard's ⏯, the page's own button): the window follows now, not
            // at the next once-a-second poll.
            if flipped { kick() }
            follow(who, since: since)
            expectPaused = nil
            if let l = j["loop"] as? Bool, !loop.ab, l != loop.track {
                if sameMedia { loop.track = l }          // toggled in the page itself
                else { sendLoop() }                      // new media: it picks up the standing loop
            }
            if ad {      // the episode stays as it is: the video's subtitles come back when it does
                let cmds = pendingCmds; pendingCmds = []; if !cmds.isEmpty { deliveredAt = now() }
                return ["state": "ad", "cmds": soundFor(j, cmds)]
            }
            guard episode?.url == url else { return ["need": "media"] }
            let cmds = pendingCmds; pendingCmds = []; if !cmds.isEmpty { deliveredAt = now() }
            return ["state": episodeState, "cmds": soundFor(j, cmds)]
        case "/wait":
            return ["cmds": await wait(j["url"] as? String ?? "")]
        case "/speech":                                // the ears, read-only (OnDeviceASR.report)
            return await OnDeviceASR.report()
        case "/media":
            guard let url = j["url"] as? String, j["ad"] as? Bool != true else { return ["state": "other"] }
            // a tab that may not have the window doesn't get its media loaded over the followed one's
            let who = "browser|" + Episode.key(url, page: j["page"] as? String)
            if let page = j["page"] as? String { mediaPage[url] = page }
            // the followed tab as its reports named it before its page was known
            let bare = "browser|" + Episode.key(url, page: nil)
            if owner == bare { owner = who; playingSince[who] = playingSince[bare] }
            if !mayTake(who, since: playingSince[who]?.since) { return ["state": "other"] }
            return ["state": await load(url, page: j["page"] as? String, referer: j["top"] as? String, title: j["title"] as? String)]
        case "/bytes":
            guard let ep = episode, ep.url == q["url"] else { return ["state": "stale"] }
            episodeState = !body.isEmpty && ep.receive(body, type: q["type"] ?? "") ? "ready" : "failed"
            log("bytes for episode: \(body.count) → \(episodeState)")
            return ["state": episodeState]
        default:
            return ["error": "unknown path"]
        }
    }

    /// fresh: made again from nothing (Retranscribe), so the transcript in keep/ isn't fetched back, and translated
    /// again, `lang` first.
    func load(_ url: String, page: String? = nil, referer: String? = nil, title: String? = nil, music: Bool = false, fresh: Bool = false, lang: String? = nil) async -> String {
        // A file playing in Gallery is known by its content key, which only GalleryJob learned: before it had run
        // (any time soon after launch) the file was keyed by its address and its transcript wasn't found.
        if url.hasPrefix("gallery:files/"), ContentKey.known[url] == nil {
            _ = await GalleryJob.itemKey(String(url.dropFirst("gallery:files/".count)), listing: await Keep.listing())
        }
        let src = Episode.key(url, page: page), key = Library.resolve(src)?.key ?? src
        if let ep = episode, ep.source == src, ep.key == key, episodeState != "failed" {
            // The same media at a new address (a stream reloaded, or looped by the page): keep everything, A–B too.
            if ep.url != url { ep.url = url; log("same media, new address: \(url.prefix(80))") }
            return episodeState
        }
        if !fresh, !FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent(key + ".v2.json").path) {
            await Store.restoreTranscript(key)
            if let ep = episode, ep.source == src, ep.key == key, episodeState != "failed" { ep.url = url; return episodeState }   // loaded meanwhile
        }
        if let old = episode {
            old.stop()
            // Again once the files it was still writing have settled (sweep skips anything under a minute old).
            Task { for s in [5, 70] { try? await Task.sleep(for: .seconds(s)); await Store.sweep(keep: self.episode?.key) } }
        }
        let ep = Episode(url: url, page: page, referer: referer, title: title, music: music) { [weak self] in (self?.mediaTime ?? 0) }
        if fresh { ep.retranslate = true; ep.firstLang = lang }
        ep.onIdentified = { [weak self, weak ep] in
            guard let self, let ep, self.episode === ep else { return }
            Task { _ = await self.load(ep.url, page: ep.page, referer: ep.referer, title: ep.title, music: ep.music) }
        }
        episode = ep; episodeState = "loading"
        loop.a = nil; loop.b = nil; loop.ab = false
        if Reader.prominence != nil { Reader.set(prominence: nil, a1: nil, a2: nil) } // each track opens in Learn
        log("media: \(url.prefix(120))")
        // SPEC 70: a Gallery video's picture, for the window; any other piece's video goes (Gallery has them all)
        Task {
            let v = await ep.galleryVideo()
            guard self.episode === ep else { return }
            let fm = FileManager.default
            for u in (try? fm.contentsOfDirectory(at: Episode.videoDir, includingPropertiesForKeys: nil)) ?? [] where u.lastPathComponent != v?.lastPathComponent {
                try? fm.removeItem(at: u)
            }
        }
        let t0 = Date()
        let ok = await ep.fetch()
        log("audio ready in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s: \(ok)")
        if episode === ep { episodeState = ok ? "ready" : (URL(string: url)?.isFileURL == true ? "failed" : "need-bytes") }
        return episodeState
    }

    /// Native player reports, ~20 a second. A player that starts playing takes the window (see mayTake); a paused
    /// one keeps it only if it had it (same 30 s grace as the browser).
    func nativeTick() {
        let seqAtPoll = cmdSeq
        native.poll { [weak self] reports in
            guard let self else { return }
            func id(_ r: NativeReport) -> String { "\(r.app)|\(r.target)" }
            var since: [String: Date] = [:]
            for r in reports { since[id(r)] = self.heard(id(r), playing: r.playing) }
            // the followed player, unless one started after it
            let newer = reports.filter { $0.playing && id($0) != self.owner && self.mayTake(id($0), since: since[id($0)]) }
            let pick = newer.max { (since[id($0)] ?? .distantPast) < (since[id($1)] ?? .distantPast) } ?? reports.first { id($0) == self.owner }
            guard let r = pick else { return }
            let browserPlaying = self.pos.source == "browser" && !self.pos.paused && Date().timeIntervalSince(self.pos.received) < 1
            if browserPlaying && !r.playing { return }
            // A poll that started before a window command can't reflect it yet.
            if seqAtPoll != self.cmdSeq { self.pos.received = Date(); return }
            let url = r.key
            let sameMedia = (self.pos.source == r.app && self.pos.url == url) || self.pos.url.isEmpty
            if r.playing && r.rate > 0 { self.nativeRate = r.rate }
            let paused = !r.playing
            if paused && (!self.pos.paused || self.pos.url != url) { self.pos.pausedAt = Date() }
            let flipped = paused != self.pos.paused || url != self.pos.url
            self.pos = Pos(url: url, t: r.t, rate: r.app == "quicktime" ? self.nativeRate : r.rate, paused: paused, dur: r.dur,
                           sent: r.at > 0 ? r.at : self.now(), received: Date(), pausedAt: self.pos.pausedAt, source: r.app, path: r.target,
                           vol: r.vol)
            if flipped { self.kick() }                // (as for the browser: the window follows at once)
            self.follow(id(r), since: since[id(r)])
            self.expectPaused = nil
            // Toggled in the player (⌥⌘L, Repeat One, the page) → the window follows; a newly opened track,
            // file or tab → it gets the standing loop.
            if !self.loop.ab, r.looping != self.loop.track {
                if sameMedia { self.loop.track = r.looping } else { self.sendLoop() }
            }
            // A–B: jump back at B (the browser does this in the page)
            if self.loop.ab, !self.scrubbing, let a = self.loop.a, let b = self.loop.b, r.playing, r.t >= b {
                self.cmdSeq += 1; self.native.exec(r.app, target: r.target, ["op": "seek", "t": a], rate: self.nativeRate)
            }
            // Only a playing source loads its media: a paused one never pulls the episode away from what was
            // just announced elsewhere.
            if self.episode?.url != url, r.playing || self.episode == nil {
                Task { _ = await self.load(url, page: r.page, title: r.title, music: r.app == "music") }
            }
        }
    }

    func setBrowserMode(_ on: Bool) {
        browserMode = on
        overlay.setControls(on)
        statusUntil = .distantPast; overlay.setStatus("")
        log(on ? "following \(pos.source)" : "idle")
    }

    func frame() {
        if browserActive != browserMode { setBrowserMode(!browserMode) }
        routeSound()
        overlay.soundNo = soundBlock
        ccTitle(paused: !browserMode || (expectPaused ?? pos.paused))
        // An ad in the followed player (the bridge says so): nothing is transcribed for it, and Skip Ad is offered.
        let ad = adPlaying
        overlay.setSkipAd(ad)
        // SPEC 70: a Gallery video followed here shows its picture behind the lines, on the page player's clock
        let clip = !ad && browserMode && !pos.url.isEmpty && pos.url == episode?.url ? episode?.video : nil
        overlay.video.show(clip)
        if clip != nil { overlay.video.follow(mediaTime, rate: pos.rate, paused: expectPaused ?? pos.paused) }
        if ad {
            editable = nil
            overlay.render(nil, at: 0)
            if !overlay.browserControls { overlay.setControls(true) }
            overlay.update(time: mediaTime, duration: pos.dur, paused: expectPaused ?? pos.paused, rate: pos.rate, loop: loop, volume: pos.vol)
            if Date() > statusUntil { overlay.setStatus("Ad playing — subtitles resume with the video") }
            return
        }
        if browserMode, let ep = episode {
            // A stream whose length isn't the transcribed audio's: an ad is playing in the page's player.
            let length = ep.playDuration ?? ep.duration
            if ep.url.hasPrefix("blob:"), pos.dur > 0, length > 0, abs(pos.dur - length) > 3 {
                overlay.render(nil, at: 0)
                overlay.update(time: mediaTime, duration: pos.dur, paused: expectPaused ?? pos.paused, rate: pos.rate, loop: loop, volume: pos.vol)
                if Date() > statusUntil { overlay.setStatus("Ad playing — subtitles resume with the video") }
                return
            }
            // The offset is heard time (media runs at `rate`); `shift` maps this source's clock onto a transcript
            // made from another source of the same recording.
            // ... less what Recense's own sound chain (EQ, Key, Space, the extractor) holds back, at the player's speed
            let t = smoothTime() + (cfg.syncOffset - soundEngine.latency) * pos.rate - ep.shift
            // a dense track (a choir): its words start Off, with Show in the Recense menu (item 22)
            let quiet = !ep.instrumental && lyricsOff(ep)
            lyricsItem?.title = quiet ? "Show Captions for This Track" : "Hide Captions for This Track"
            if quiet {
                editable = nil
                overlay.render(nil, at: t)
                overlay.update(time: mediaTime, duration: length > 0 ? length : pos.dur,
                               paused: expectPaused ?? pos.paused, rate: pos.rate, loop: loop, volume: pos.vol)
                if Date() > statusUntil { overlay.setStatus("Captions off · dense texture — Recense ▸ Show Captions for This Track") }
                return
            }
            // The line being spoken, held after it ends until the next one shows (unlit, 4 s ahead), so the window
            // never blinks empty between lines; only a real break (12 s or more) clears it. Paused, it never clears.
            Cadence.track = ep.features
            Prosody.now = t
            Prosody.ensure(key: ep.key, lines: ep.sung, features: ep.features, lang: ep.language.flatMap(languageCode) ?? ep.spokenLanguage ?? Prosody.language(ep.sung), song: ep.isSong)
            let held = expectPaused ?? pos.paused, lines = ep.sung   // the trailing line in the native language, timed to the voice
            let last = lines.last { $0.start - 0.15 <= t }, next = lines.first { $0.start - 0.15 > t }
            let breakAhead = (next?.start ?? .infinity) - (last?.end ?? -.infinity) >= 12
            editable = nil
            defer { if let e = editable { editable = ep.display.first { $0.id == e.id } ?? e } }   // corrected as transcribed
            // between the words: [Ambient Sounds] while there is sound, from the end of a line to the next one's start
            let speaking = last.map { t <= $0.end + 0.3 } ?? false
            // (only where no voice is heard: a voice with no line up isn't ambient, it's words not shown)
            // (or where the listener cleared the line: their word that nobody sings there)
            let ambient = !speaking && t >= 0 && (ep.blanked.contains { $0.contains(t) }
                || ep.sounding(t) && (ep.instrumental || ep.voiced(t) == false) && (ep.instrumental || ep.complete || next != nil))
            if ep.instrumental { if ambient { overlay.renderAmbient() } else { overlay.render(nil, at: t) } }
            else if ambient && overlay.mode != .learning { overlay.renderAmbient(); editable = nil }
            else if overlay.mode == .learning {
                overlay.renderLearning(lines, at: t, held: held)
                editable = overlay.drumLine.flatMap { lines.indices.contains($0) ? lines[$0] : nil } ?? last ?? next   // the line in view
            }
            // a line the picture already shows (a recording of a transcript, burned-in captions) gets nothing over it
            else if let last, t <= last.end + 2.5 { overlay.render(ep.shownInPicture(last) ? nil : last, at: t); editable = last }
            else if let next, next.start - t < 4 || (held && last == nil) { overlay.render(ep.shownInPicture(next) ? nil : next, at: t, upcomingOnly: true); editable = next }
            else if let last, held || !breakAhead { overlay.render(ep.shownInPicture(last) ? nil : last, at: t); editable = last }
            else { overlay.render(nil, at: t) }
            overlay.update(time: mediaTime, duration: length > 0 ? length : pos.dur,
                           paused: expectPaused ?? pos.paused, rate: pos.rate, loop: loop, volume: pos.vol)
            // the title bar carries progress, so it never covers the subtitles
            if Date() < statusUntil { return }
            if episodeState == "loading" || episodeState == "need-bytes" { overlay.setStatus("Loading audio…") }
            else if episodeState == "failed" { overlay.setStatus(ep.complete ? "" : "Audio unavailable — transcript so far") }
            else if ep.identifying { overlay.setStatus("Checking whether it was heard before…") }
            else if ep.separating { overlay.setStatus("Isolating vocals…") }
            else if let s = ep.limitStatus { overlay.setStatus(s) }
            else if ep.progress < 1 { overlay.setStatus("Transcribing… \(Int(ep.progress * 100))%") }
            else { overlay.setStatus("") }
            return
        }
        // Nothing with exact sync is playing: no guessing at other apps' audio.
        editable = nil
        overlay.render(nil, at: 0)
        // A player is reporting but there's no transcript (no speech, or its audio couldn't be fetched): the home bar
        // still follows it, so loop, speed and seek work and it's plain the player is being followed.
        let reporting = !pos.url.isEmpty && reported
        if overlay.browserControls != reporting { overlay.setControls(reporting) }
        if reporting {
            overlay.update(time: mediaTime, duration: pos.dur, paused: expectPaused ?? pos.paused, rate: pos.rate, loop: loop, volume: pos.vol)
            if Date() > statusUntil { overlay.setStatus("Following \(sourceName) — no transcribed speech") }
        } else if Date() > statusUntil { overlay.setStatus("Play something") }
    }

    var editable: Line?                       // the line on screen: what an edit corrects

    /// The line on screen, corrected in place; the player waits while it's typed. A double-click's first click has
    /// already played or paused, so what was playing before it plays again after.
    func edit(clicked: Bool) {
        guard browserMode, let line = editable, !overlay.editor.editing else { return }
        let paused = expectPaused ?? pos.paused, resume = clicked ? paused : !paused
        if !paused { setPlaying(false) }
        editLine(line, resume: resume)
    }
    /// One line of the whole transcript in the editor (notes 24), the others on its barrel; turning the barrel or
    /// clicking another line saves this one, plays from that one's start and edits it.
    func editLine(_ line: Line, resume: Bool) {
        guard let ep = episode else { return }
        let all = ep.shown
        let i = all.firstIndex { $0.id == line.id } ?? all.firstIndex { $0.start >= line.start - 0.01 } ?? max(0, all.count - 1)
        // shown as they're written (Chinese without spaces between its words; a correction is cut into words again)
        let above = all.indices.contains(i) ? all[..<i].map(lineText) : []
        let below = all.indices.contains(i) ? all[(i + 1)...].map(lineText) : []
        let shownText = lineText(line)
        overlay.editor.onTiming = { [weak self] in self?.timeLine(line) }
        overlay.beginEdit(shownText, edited: Episode.isEdited(line), above: Array(above), below: Array(below)) { [weak self, weak ep] r in
            guard let self, let ep, self.episode === ep else { return }
            @MainActor func save(_ text: String) {
                guard text.split(whereSeparator: \.isWhitespace).joined(separator: " ") != shownText,
                      Corrections.words(text).joined(separator: " ") != lineKey(line) else { return }
                ep.correct(line, to: text)
                self.overlay.toast.say(text.allSatisfy(\.isWhitespace) ? "Line hidden" : "Corrected")
            }
            switch r {
            case .save(let text): save(text)
            case .reset: ep.reset(line); self.overlay.toast.say("Back to auto")
            case .move(let n, let text):
                save(text)
                let now = ep.shown
                let hidden = !now.contains { abs($0.start - line.start) < 0.01 }
                let base = now.firstIndex { $0.start >= line.start - 0.01 } ?? now.count
                let j = base + n - (hidden && n > 0 ? 1 : 0)
                if now.indices.contains(j) {
                    let to = now[j]
                    self.command(.seek(to.start - 0.05 - cfg.syncOffset * self.pos.rate + ep.shift))
                    self.editable = to
                    self.editLine(to, resume: resume)
                    return
                }
            default: break
            }
            if resume { self.setPlaying(true) }
        }
    }
    /// Timing by ear (notes 20261029 rows 35, 40): the voice can't always tell how a word is sung, the listener can. A word
    /// of the line, then Start and End tapped as it is sung while that stretch plays round; Auto gives it back to Cadence. Saved as a corrections override (field "time", Gallery's own), so Gallery shows it too.
    var timing: TimingPanel?
    func timeLine(_ line: Line) {
        guard let ep = episode, let l = ep.sung.first(where: { $0.id == line.id }), !l.words.isEmpty else { return }
        timing?.close()
        let t = TimingPanel(l) { [weak self, weak ep] pins, push in
            guard let self, let ep, self.episode === ep else { return }
            ep.setTiming(l, pins, push: push)
            self.overlay.lastKey = ""
        }
        t.hear = { [weak self] a, b in
            guard let self, let ep = self.episode else { return }
            self.loopTimer?.invalidate()
            guard let a, let b else { self.loopTimer = nil; self.setPlaying(false); return }
            self.command(.seek(max(0, a - 0.8) - cfg.syncOffset * self.pos.rate + ep.shift)); self.setPlaying(true)
            self.loopTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let ep = self.episode, let (a, b) = t.span else { return }
                    let now = self.mediaTime - ep.shift
                    if now > b + 0.5 || now < a - 1.5 { self.command(.seek(max(0, a - 0.8) - cfg.syncOffset * self.pos.rate + ep.shift)) }
                }
            }
        }
        t.now = { [weak self] in guard let self, let ep = self.episode else { return 0 }; return self.mediaTime - ep.shift }
        // the lines sung again with the same words (a chorus, an ad-lib): this line's timing, at the same place in each
        let same = { (x: Line) in x.words.map { $0.text.lowercased().filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty } }
        t.repeats = ep.sung.filter { $0.id != l.id && $0.words.count == l.words.count && same($0) == same(l) && !same(l).isEmpty }
        t.toRepeats = { [weak self, weak ep] pins in
            guard let self, let ep, self.episode === ep else { return }
            for r in ep.sung where r.id != l.id && r.words.count == l.words.count && same(r) == same(l) {
                let d = r.start - l.start
                ep.setTiming(r, pins.mapValues { Pin(s: (($0.s + d) * 1000).rounded() / 1000, e: (($0.e + d) * 1000).rounded() / 1000, k: $0.k, c: $0.c) }, push: true)
            }
            self.overlay.lastKey = ""
            self.overlay.toast.say("Timed the same in its repeats")
        }
        t.onClose = { [weak self] in self?.loopTimer?.invalidate(); self?.loopTimer = nil; self?.timing = nil }
        timing = t
        t.show(over: overlay.panel)
    }
    var loopTimer: Timer?
    func resetLine() {
        guard let ep = episode, let line = editable, Episode.isEdited(line) else { return }
        ep.reset(line); overlay.lastKey = ""; overlay.toast.say("Back to auto")
    }

    /// The editor's Clear (SPEC 57): the whole transcript goes, after a confirmation; every line can come back.
    func clearTranscript() {
        guard let ep = episode, !ep.shown.isEmpty else { return overlay.toast.say("Nothing to clear") }
        if overlay.editor.editing { overlay.editor.finish(.cancel) }
        let a = NSAlert()
        a.messageText = "Clear the whole transcript?"
        a.informativeText = "Every line is hidden, as a correction: Reset to Auto (or Gallery's Changes) brings any line back."
        a.addButton(withTitle: "Clear"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        ep.clearAll()
        overlay.lastKey = ""
        overlay.toast.say("Cleared")
    }

    /// The editor's Share: the page (or file) the transcript belongs to, through macOS's share sheet.
    func shareSource() {
        guard let ep = episode else { return overlay.toast.say("Nothing to share") }
        let src = ep.page ?? ep.url
        let item: Any = src.hasPrefix("file://") ? (URL(string: src) as Any) : src.hasPrefix("gallery:") ? cleanTitle(ep.title ?? src) : (URL(string: src) as Any? ?? src)
        let picker = NSSharingServicePicker(items: [item])
        let v = overlay.homeBar
        picker.show(relativeTo: NSRect(x: v.bounds.midX - 1, y: 8, width: 2, height: 2), of: v, preferredEdge: .maxY)
    }

    func applicationWillTerminate(_ n: Notification) { episode?.save(); Library.flush(force: true) }
}

/// `Recense --replay <cache.v2.json> [official-lyrics.txt]` re-runs lyric choice and timing on a captured
/// transcript, offline (no Groq calls), and prints the lines and the stretches a second pass would redo — to check
/// a change against every track that went wrong before, instead of finding out on the next new track. With the
/// official lyrics (one line per line) it also scores the result: the share of words shown that are really in the
/// song, and the share of lyric lines shown at least once. With no lyrics in the capture, the official ones stand
/// in for a database hit. With the capture's Whisper replies (<name>.raw.json, RECENSE_RAW) and its vocal stem
/// (<name>.vocals.wav) beside it, the whole pipeline runs instead: the first pass from the replies, then the
/// second pass, each redo served the reply Whisper gave that request (a redo never captured is skipped, and listed).
@MainActor func replay(_ path: String, _ ref: String?) async {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let c = try? JSONDecoder().decode(Episode.Cache.self, from: d)
    else { print("can't read \(path)"); exit(1) }
    let official = ref.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        .map { $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    let ep = Episode(url: "replay:" + path, page: nil, title: nil, music: true) { 0 }
    ep.stopped = true; ep.duration = c.duration; ep.heard = c.heard ?? []; ep.lines = c.lines
    ep.vocals = URL(fileURLWithPath: "/dev/null")
    let base = path.replacingOccurrences(of: ".v2.json", with: "")
    let stem = URL(fileURLWithPath: base + ".vocals.wav")
    let raw = (try? Data(contentsOf: URL(fileURLWithPath: base + ".raw.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
    if let raw, FileManager.default.fileExists(atPath: stem.path) {
        ep.vocals = stem; ep.file = stem; ep.captured = raw; ep.pace = 0; ep.dry = true; ep.stopped = false
        ep.heard = []; ep.lines = []; ep.songPipeline = 4
        var chunks: [Double: [String: Any]] = [:]             // each chunk's last reply (a pass may have been redone)
        for e in raw { if let k = e["keep"] as? [Double] { chunks[k[0]] = e } }
        for (_, e) in chunks.sorted(by: { $0.key < $1.key }) {
            guard let k = e["keep"] as? [Double], let lo = e["from"] as? Double, let hi = e["to"] as? Double, let t = e["reply"] as? [String: Any],
                  let samples = try? decodeChunk(stem, from: lo, to: hi) else { continue }
            ep.add(t, samples: samples, offset: lo, keep: k[0]..<k[1])
        }
    }
    var options = c.lyricOptions ?? (c.lyrics.map { $0.isEmpty ? [] : [$0] } ?? [])
    if options.isEmpty, let official { options = [official] }
    var scored: [(Double, [String])] = []
    for o in options { scored.append((ep.matchScore(o), o)) }
    scored.sort { $0.0 > $1.0 }
    for (sc, o) in scored { print(String(format: "candidate %3d%%  %@", Int(sc * 100), o.first ?? "")) }
    ep.lyrics = (scored.first?.0 ?? 0) >= 0.35 ? scored[0].1 : []
    if ep.captured != nil {
        ep.lyricsVerified = true; ep.language = c.language
        while let w = ep.suspects().first { await ep.redo(w, src: stem) }
    }
    let lines = ep.lyrics.isEmpty ? ep.heardLines([:]) : ep.alignLyrics()
    print("languages: \(ep.songLanguages().joined(separator: ", "))  ·  \(ep.lyrics.isEmpty ? "as heard" : "lyrics")")
    let langs = ep.songLanguages()
    var elsewhere = 0                 // lines in a language the song isn't sung in: a translation Whisper made, or noise
    for l in lines {
        let lang = ep.languagesOf(l)
        if let m = lang.first, !langs.isEmpty, !langs.contains(m) { elsewhere += 1 }
        print(String(format: "%7.2f–%7.2f  %@%@", l.start, l.end, l.english == nil ? "[translate \(lang.joined(separator: "+"))] " : "", lineKey(l)))
    }
    for w in ep.suspects() { print(String(format: "redo %7.2f–%7.2f", w.a, w.b)) }
    if ep.captured != nil { print("redos replayed: \(ep.redone.count), not captured: \(ep.missed.count)\(ep.missed.isEmpty ? "" : " (" + ep.missed.joined(separator: ", ") + ")")") }
    print("lines in a language the song isn't sung in: \(elsewhere)")
    if let official {
        let vocab = Set(official.flatMap { Episode.norm($0) })
        let shown = lines.flatMap { Episode.norm(lineKey($0)) }
        let real = shown.filter { vocab.contains($0) }.count
        let text = " " + lines.map { Episode.norm(lineKey($0)).joined(separator: " ") }.joined(separator: " ") + " "
        let long = official.map { Episode.norm($0) }.filter { $0.count >= 3 }
        let found = long.filter { text.contains(" " + $0.joined(separator: " ") + " ") }.count
        print(String(format: "words in the song: %d%% (%d/%d) · lyric lines shown: %d%% (%d/%d)",
                     100 * real / max(1, shown.count), real, shown.count, 100 * found / max(1, long.count), found, long.count))
    }
}

/// `Recense --edits-selftest` (RECENSE_CACHE set): corrections laid over a transcript that the pipeline then remakes
/// (re-timed, split otherwise, emptied) still show; an empty one hides its line; they're read back from disk; one
/// corrected again keeps its stretch; reset brings the automatic words back; the glossary learns and forgets with them.
@MainActor func editsSelftest() -> Bool {
    func w(_ t: String, _ a: Double, _ b: Double) -> Word { Word(text: t, start: a, end: b, lang: "en") }
    func shown(_ ep: Episode) -> [String] { ep.shown.map(lineKey) }
    var ok = true
    func check(_ c: Bool, _ what: String, _ got: Any = "") { print("edits            \(c ? "pass " : "FAIL ") \(what)\(c ? "" : " — got \(got)")"); ok = ok && c }
    let auto = [Line(id: 1_000_001, words: [w("I", 0, 0.2), w("met", 0.3, 0.5), w("Kefya", 0.6, 1), w("today.", 1.1, 1.5)], english: []),
                Line(id: 1_000_002, words: [w("Thank", 3, 3.3), w("you.", 3.4, 3.8)], english: []),
                Line(id: 1_000_003, words: [w("See", 5, 5.3), w("you", 5.4, 5.6), w("soon.", 5.7, 6)], english: [])]
    Glossary.terms = [:]
    let ep = Episode(url: "selftest:edits", page: nil, title: nil) { 0 }
    ep.stopped = true; ep.edits = Edits(); ep.lines = auto
    ep.correct(ep.shown[0], to: "I met Kefaya today.")
    ep.correct(ep.shown[1], to: "")
    check(shown(ep) == ["I met Kefaya today.", "See you soon."], "shown over the transcript, an empty one hiding its line", shown(ep))
    check(Glossary.prompt("en") == "Kefaya", "the glossary learned the word Whisper missed", Glossary.prompt("en") ?? "nil")
    ep.lines = [Line(id: 2_000_000, words: [w("I", 0.05, 0.2), w("met", 0.3, 0.5)], english: []),
                Line(id: 2_000_001, words: [w("Kefir", 0.6, 1), w("today.", 1.1, 1.5), w("Thanks", 3, 3.3), w("you", 3.4, 3.8), w("See", 5, 5.3)], english: []),
                Line(id: 2_000_002, words: [w("you", 5.4, 5.6), w("soon.", 5.7, 6)], english: [])]
    check(shown(ep) == ["I met Kefaya today.", "See", "you soon."], "kept over a transcript remade (re-timed, split otherwise)", shown(ep))
    ep.lines = []
    check(shown(ep) == ["I met Kefaya today."], "kept over a transcript emptied for a redo", shown(ep))
    let again = Episode(url: "selftest:edits", page: nil, title: nil) { 0 }
    again.stopped = true; again.lines = auto
    check(shown(again) == ["I met Kefaya today.", "See you soon."], "read back from disk", shown(again))
    again.correct(again.shown[0], to: "I met Kefaya there.")
    check(shown(again) == ["I met Kefaya there.", "See you soon."] && again.edits.edits.count == 2, "corrected again, in its place", shown(again))
    again.reset(again.shown[0])
    check(shown(again) == ["I met Kefya today.", "See you soon."], "reset to auto", shown(again))
    check(Glossary.prompt("en") == nil, "the glossary forgot what the reset edit taught", Glossary.prompt("en") ?? "nil")
    return ok
}

/// Gallery's corrections laid over a transcript: the same cases as Gallery's test/transcript.test.mjs, and its
/// zero-error replay (every wrong line corrected shows right on every reload, and after a retranscription).
@MainActor func correctionsSelftest() -> Bool {
    var ok = true
    func check(_ c: Bool, _ what: String, _ got: Any = "") { print("corrections      \(c ? "pass " : "FAIL ") \(what)\(c ? "" : " — got \(got)")"); ok = ok && c }
    func line(_ id: Int, _ t: Double, _ text: String) -> Line {
        Line(id: id, words: text.split(separator: " ").enumerated().map { Word(text: String($0.element), start: t + Double($0.offset) * 0.5, end: t + Double($0.offset) * 0.5 + 0.4) }, english: [])
    }
    func ov(_ seg: String, _ a: Double, _ b: Double, _ to: String, _ at: Double, field: String = "text") -> Override {
        Override(segId: seg, start: a, end: b, field: field, to: to, src: "main", updatedAt: at)
    }
    let shown = { (l: [Line], e: Edits) in applyEdits(l, e).map(lineKey) }

    let asr = [line(1, 0, "bonjour tout le monde"), line(2, 3, "je suis a pari"), line(3, 6, "PARI pari Parisien")]
    var e = Edits(); e.overrides = [ov("1", 0, 1.9, "Bonjour à tous", 1)]; e.glossary = ["pari": "Paris"]
    check(shown(asr, e) == ["Bonjour à tous", "je suis a Paris", "PARIS Paris Parisien"], "by segId; glossary on the others, whole word, in case", shown(asr, e))
    let moved = [line(10, 0.2, "bonjour tout le monde"), line(11, 3, "je suis a pari")]
    check(shown(moved, e).first == "Bonjour à tous", "a remade line found by ≥ 50 % of the override's time", shown(moved, e))
    e.overrides = [ov("gone", 0, 0.3, "Bonjour à tous", 1)]
    check(shown(moved, e).first == "bonjour tout le monde", "under half of it: not that line", shown(moved, e))
    e = Edits(); e.overrides = [ov("2", 3, 5, " ", 1), ov("1", 0, 0, "Hi all", 1, field: "tr.en")]
    let out = applyEdits(asr, e)
    check(out.map(\.id) == [1, 3] && out[0].english?.map(\.w) == ["Hi", "all"], "corrected to nothing hides it; tr.en is its English", out.map(\.id))
    // Recense's own edit first, never taken over by an older override; a later one made on it wins
    e = Edits(edits: [Edit(id: 1, a: 3, b: 5, from: "je suis a pari", words: [Word(text: "je", start: 3, end: 3.4), Word(text: "suis", start: 3.5, end: 3.9),
                                                                             Word(text: "à", start: 4, end: 4.4), Word(text: "Paris", start: 4.5, end: 4.9)], lang: "fr", at: 50)])
    e.overrides = [ov("2", 3, 4.9, "older", 10)]
    check(shown(asr, e)[1] == "je suis à Paris", "Recense's later edit isn't taken over by an older override", shown(asr, e))
    e.overrides = [ov(String(edited + 1), 3, 4.9, "je suis à Paris !", 60)]
    check(shown(asr, e)[1] == "je suis à Paris !", "an override made on that line wins", shown(asr, e))

    check(Corrections.learned(from: "on a mange des crepes", to: "on a mangé des crêpes.").map { "\($0.0)>\($0.1)" } == ["mange>mangé", "crepes>crêpes"], "learned: each word replaced by one")
    check(Corrections.learned(from: "la tour effel", to: "la tour Eiffel de Paris").isEmpty, "learned: one word into three teaches nothing")
    var g: [String: String] = [:]
    Corrections.teach(&g, from: "je vais a pari", to: "je vais à Paris")
    Corrections.teach(&g, from: "à", to: "a")
    check(g == ["a": "", "pari": "Paris"], "taught back: forgotten", g)
    check(Corrections.gloss("«PARI»", g) == "«PARIS»" && Corrections.gloss("pari,", g) == "Paris," && Corrections.gloss("a", g) == "a", "gloss keeps what's around the word")

    var local = Edits(); local.overrides = [ov("1", 0, 1, "a", 5), ov("2", 2, 3, "b", 9)]; local.glossary = ["x": "y"]; local.updatedAt = 9; local.version = 3
    var remote = Edits(); remote.overrides = [ov("1", 0, 1, "A", 7), ov("2", 2, 3, "B", 3)]; remote.glossary = ["x": "", "z": "w"]; remote.updatedAt = 10; remote.version = 4
    let m = Corrections.merged(local, remote)
    check(m.overrides?.map(\.to) == ["A", "b"] && m.glossary == ["x": "", "z": "w"] && m.version == 4, "merge: latest per segment; the newer file's glossary on a clash", m.overrides?.map(\.to) ?? [])

    // zero-error replay
    let heard = ["je suis allé à pari hier", "la tour est belle", "nous avons vu la tour effel", "il fait beau", "pari est grande", "on a mange des crepes", "merci beaucoup", "thank you"]
    let truth = ["je suis allé à Paris hier", "la tour est belle", "nous avons vu la tour Eiffel", "il fait beau", "Paris est grande", "on a mangé des crêpes", "merci beaucoup"]
    func transcript(_ id0: Int, _ dt: Double) -> [Line] { heard.enumerated().map { line(id0 + $0.offset, Double($0.offset) * 4 + dt, $0.element) } }
    var doc = Edits(), edits = 0
    var lines = applyEdits(transcript(0, 0), doc)
    while let k = lines.indices.first(where: { k in k >= truth.count || lineKey(lines[k]) != truth[k] }) ?? (lines.count != truth.count ? lines.count : nil), edits < 10 {
        let l = lines[k], pos = Int((l.start / 4).rounded())
        let to = pos < truth.count ? truth[pos] : ""
        var gl = doc.glossary ?? [:]; Corrections.teach(&gl, from: lineKey(l), to: to); doc.glossary = gl
        doc.overrides = (doc.overrides ?? []) + [ov(String(l.id), l.start, l.end, to, Double(edits))]
        edits += 1
        lines = applyEdits(transcript(0, 0), doc)
    }
    check(edits == 4, "four lines corrected by hand, one by the glossary", edits)
    let data = try! JSONEncoder().encode(doc), back = try! JSONDecoder().decode(Edits.self, from: data)
    for replay in 0..<3 { check(applyEdits(transcript(0, 0), back).map(lineKey) == truth, "replay \(replay): 0 differences") }
    check(applyEdits(transcript(100, 0.15), back).map(lineKey) == truth, "retranscribed (new ids, timing off): 0 differences", applyEdits(transcript(100, 0.15), back).map(lineKey))
    // a file Gallery wrote (no Recense fields of its own besides the empty ones) reads back
    let gallery = #"{"edits":[],"english":{},"version":2,"updatedAt":5,"overrides":[{"segId":"1","start":0,"end":1.9,"field":"text","to":"Salut","src":"share","updatedAt":5}],"glossary":{"pari":"Paris"}}"#
    let gd = try? JSONDecoder().decode(Edits.self, from: Data(gallery.utf8))
    check(gd.map { shown(asr, $0) } == ["Salut", "je suis a Paris", "PARIS Paris Parisien"], "reads the file as Gallery writes it", gd.map { shown(asr, $0) } ?? [])

    // keep/<key>/: asr.json and tr/<lang>.json (Keep), the same as Gallery's src/layout.js
    let en = [EnWord(w: "Hello", s: [0]), EnWord(w: "everyone", s: [1, 2, 3])]
    var withEn = asr
    withEn[0].english = en; withEn[1].english = nil; withEn[2].english = [EnWord(w: "PARIS", s: [])]; withEn[2].draft = true
    let cache = Episode.Cache(lines: withEn, done: [true], duration: 9, lyrics: ["x"], complete: true)
    let (a, enFile) = Keep.split(cache)
    let rt = Keep.join(try! JSONDecoder().decode(Keep.ASR.self, from: Keep.encode(a)!), try! JSONDecoder().decode(TrFile.self, from: Keep.encode(enFile!)!))
    check(rt.lines.map { $0.english?.map(\.w) } == [["Hello", "everyone"], nil, ["PARIS"]] && rt.lines[0].english?[1].s == [1, 2, 3] && rt.lines[2].draft == true
          && rt.done == [true] && rt.lyrics == ["x"] && rt.complete == true && rt.lines.map(lineKey) == asr.map(lineKey),
          "a transcript split into asr.json + tr/en.json and joined back is the same", rt.lines.map { $0.english?.map(\.w) ?? [] })
    check(String(data: Keep.encode(a)!, encoding: .utf8)!.contains("english") == false && enFile?.complete == false, "asr.json is the original only; tr/en.json says it's not whole")
    let fromGallery = #"{"format":1,"complete":true,"duration":4,"segments":[{"id":1,"start":0,"end":0.9,"text":"un deux","lang":"fr","words":[{"text":"un","start":0,"end":0.4,"lang":"fr"},{"text":"deux","start":0.5,"end":0.9,"lang":"fr"}]}],"recense":{"done":[true,true],"songPipeline":4}}"#
    let ga = try? JSONDecoder().decode(Keep.ASR.self, from: Data(fromGallery.utf8))
    let gen = try? JSONDecoder().decode(TrFile.self, from: Data(#"{"lang":"en","complete":true,"updatedAt":1,"lines":{"1":{"src":"un deux","text":"one two"},"2":{"src":"x","same":true}}}"#.utf8))
    check(ga.map { Keep.join($0, gen).lines.first?.english?.map(\.w) == ["one", "two"] && Keep.join($0, gen).songPipeline == 4 } == true, "reads asr.json and tr/en.json as Gallery writes them (moving an old one over)")
    let remade = [Line(id: 1, words: ga!.segments[0].words + [Word(text: "trois", start: 1, end: 1.2)], english: nil)]
    check(Keep.words(gen, 1, [lineKey(remade[0])]) == nil, "a translation of other words isn't laid over a remade line")
    // the native language: a correction in it, else its file, else the English
    var vi = TrFile(lang: "vi")
    vi.lines["1"] = TrLine(src: "bonjour tout le monde", text: "xin chào mọi người"); vi.lines["3"] = TrLine(src: "something else", text: "cũ")
    e = Edits(); e.overrides = [ov("2", 3, 5, "tôi ở Paris", 1, field: "tr.vi")]
    let native = applyEdits(withEn, e, lang: "vi") { pre, post in Keep.words(vi, pre.id, [lineKey(pre), lineKey(post)]) }
    check(native.map { $0.english?.map(\.w).joined(separator: " ") ?? "" } == ["xin chào mọi người", "tôi ở Paris", "PARIS"], "native: its file, a correction winning, the English where it has none", native.map { $0.english?.map(\.w) ?? [] })
    check(applyEdits(withEn, e).map { $0.english?.map(\.w) ?? [] } == withEn.map { $0.english?.map(\.w) ?? [] }, "the English lines (exported, translated) never carry another language")
    let listing = Keep.parts(["keep/\(String(repeating: "a", count: 24))/asr.json", "keep/\(String(repeating: "a", count: 24))/tr/vi.json", "keep/\(String(repeating: "b", count: 24)).v2.json",
                              "keep/\(String(repeating: "b", count: 24)).edits.json", "keep/library.json", "keep/locks/\(String(repeating: "c", count: 24))"])
    check(listing == [String(repeating: "a", count: 24): ["asr", "tr/vi"], String(repeating: "b", count: 24): ["v2", "edits"]], "keep/ listed per item, old flat files included", listing)
    return ok
}

// ---------- inside Recense ----------
// Recense no longer runs as its own app: Recense starts its delegate once at launch. The command-line self-tests
// (--corrections-selftest, --match, …) stay in the recense repo's main.swift.
@MainActor enum Recense {
    static var delegate: AppDelegate?
    /// Posted when Recense starts or stops working (userInfo["working"]: Bool), for Recense's strip button (SPEC 20).
    static let workingChanged = Notification.Name("RecenseWorkingChanged")
    static var working: Bool { delegate?.wasWorking ?? false }
    /// The card, once Recense has started (nil before: Recense can be summoned before Recense finishes launching).
    static var overlay: Overlay? { delegate.flatMap { $0.overlay as Overlay? } }
    /// Two fingers held still on the trackpad (Recense's MultitouchSupport reader) and lifted: while the card is up, its
    /// time ruler shows where the media is and moves on with it, and folds away when they lift (item 21).
    static func hold(_ on: Bool) {
        guard let o = overlay, on ? o.panel.isVisible : true else { return }
        o.homeBar.call("hold", on)
    }
    static func start() {
        guard delegate == nil else { return }
        log("recense: starting Recense")
        let d = AppDelegate()
        delegate = d
        d.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        // The window is always the strip inside Recense, and starts hidden: shown at launch (empty, see-through, over the
        // menu bar) it went unnoticed, and the strip icon's first press hid it, so the icon seemed to do nothing.
        let mi = NSMenuItem(title: "Recense", action: nil, keyEquivalent: ""); mi.submenu = d.menu
        NSApp.mainMenu?.addItem(mi)
    }
}

/// Apple's sound classifier, half a second at a time: 1 where it hears a voice (speech, singing, a choir, rap…).
final class VoiceObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    var env: [UInt8] = []
    static let voices = ["speech", "speaking", "singing", "singer", "choir", "rapping", "chant", "whisper", "conversation", "narration", "yell", "shout", "babble"]
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        let v = r.classifications.contains { c in c.confidence >= 0.3 && VoiceObserver.voices.contains { c.identifier.contains($0) } }
        let i = Int(r.timeRange.start.seconds / Episode.voicesStep + 0.5)
        if env.count <= i { env += [UInt8](repeating: 0, count: i + 1 - env.count) }
        if v { env[i] = 1 }
    }
}

/// A line's words timed by ear (notes 20261029 rows 35, 40): pick a word and its stretch plays round; tap Start as the
/// voice reaches it and End as it lets go, as A and B are set on the loop (`now`: the time heard). A two-finger swipe
/// over a mark (or ← →) moves it a hundredth for the last touch. The light follows the voice inside that span
/// (Cadence.pin): it never lingers behind it or rushes ahead (row 40). Same in repeats: a chorus or an ad-lib sung
/// again is most likely the same recording, so it takes this line's timing (`repeats`). Auto gives the word back to
/// Cadence. Every change shows at once (`changed` without push), and is saved for Gallery as the mark is let go.
@MainActor final class TimingPanel: NSObject, NSWindowDelegate {
    private let line: Line
    private var pins: [Int: Pin]
    private let changed: ([Int: Pin], Bool) -> Void
    var hear: ((Double?, Double?) -> Void)?
    var now: (() -> Double)?
    var onClose: (() -> Void)?
    /// The lines sung again with these words, and what to do when this line's timing goes to them.
    var repeats: [Line] = [] { didSet { sameB.title = "Same in \(repeats.count) repeat" + (repeats.count == 1 ? "" : "s"); sameB.isHidden = repeats.isEmpty } }
    var toRepeats: (([Int: Pin]) -> Void)?
    private let win: NSPanel
    private var chips: [Chip] = []
    private let startB = Mark(), endB = Mark()
    private let hearB = NSButton(title: "Stop", target: nil, action: nil), autoB = NSButton(title: "Auto", target: nil, action: nil)
    private let sameB = NSButton(title: "", target: nil, action: nil)
    private let pad = LightPad()
    private let padCap = NSTextField(labelWithString: "")
    private var padTimer: Timer?
    private var cur = 0
    private var looping = false
    /// The stretch being heard round: the chosen word as it's now set; for the whole line, the stretch between its
    /// beats (the caller plays from 0.8 s before a span to 0.5 s past it, so the loop is exactly lo … hi).
    var span: (Double, Double)? {
        if lineMode { return (lo + 0.8, hi - 0.5) }
        let p = pinOf(cur); return (p.s, p.e)
    }
    // A stanza by ear (gallery notes 20261029 row 40, owner 2026-11-01; Gallery's `openLine`): Whole line plays the
    // line round; tap its first beat, then its last, and it loops between them until Use this cadence (or Retry). Its
    // words then follow the voice inside those beats; if that still isn't it, Trace it: slide along the pad as it is sung.
    private var lineMode = false
    private var beatA: Double?, beatB: Double?, lo = 0.0, hi = 0.0
    private let lineChip = Chip("Whole line")
    private let lineSay = NSTextField(wrappingLabelWithString: "")
    private let beat = Mark()
    private let useB = NSButton(title: "Use this cadence", target: nil, action: nil), retryB = NSButton(title: "Retry", target: nil, action: nil)
    private let traceB = NSButton(title: "Trace it", target: nil, action: nil), voiceB = NSButton(title: "Back to the voice", target: nil, action: nil)
    private let linePad = LightPad()
    private var wordViews: [NSView] = [], lineViews: [NSView] = []

    /// A word of the line as Gallery draws it (.txchip): a capsule, yellow once timed by ear, lit while it is picked.
    final class Chip: NSButton {
        var timed = false { didSet { paint() } }
        var picked = false { didSet { paint() } }
        convenience init(_ t: String) {
            self.init(frame: .zero)
            title = t; isBordered = false; wantsLayer = true
            font = .systemFont(ofSize: 12); paint()
        }
        override var intrinsicContentSize: NSSize { let s = super.intrinsicContentSize; return NSSize(width: s.width + 18, height: 22) }
        override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }
        private func paint() {
            let gold = NSColor(red: 1, green: 0.84, blue: 0.2, alpha: 1)
            layer?.borderWidth = 1
            layer?.borderColor = (timed ? gold.withAlphaComponent(0.7) : NSColor(white: 1, alpha: 0.25)).cgColor
            layer?.backgroundColor = picked ? NSColor(white: 1, alpha: 0.14).cgColor : nil
            attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: timed ? gold : NSColor(white: 1, alpha: 0.75), .font: font ?? .systemFont(ofSize: 12)])
        }
    }

    /// The light between Start and End (gallery notes 20261029 rows 40, 44), as Gallery's .txlight: drawn as it fills the
    /// word from A to B, the moment playing as a line across it. Drag up or down for its speed (faster or slower at
    /// first); slide along it as the word is sung and it copies the pointer (stopped: draw the path, across is time,
    /// up is lit); double-click (or ⌫) gives it back to the voice; ↑ ↓ change the speed.
    final class LightPad: NSView {
        var curve: (Double) -> Double = { $0 }
        var playhead: () -> Double? = { nil }
        var playing: () -> Bool = { false }
        var bend: ((Double, Bool) -> Void)?, traced: (([Double]) -> Void)?, toVoice: (() -> Void)?
        private var drag: (p: NSPoint, k0: Double, mode: Int, pts: [(u: Double, p: Double)])?
        var k0: () -> Double = { 0 }
        override var acceptsFirstResponder: Bool { true }
        override var isFlipped: Bool { false }
        private func X(_ u: Double) -> CGFloat { 10 + CGFloat(u) * (bounds.width - 20) }
        private func Y(_ p: Double) -> CGFloat { 8 + CGFloat(p) * (bounds.height - 16) }
        override func draw(_ r: NSRect) {
            NSColor(white: 1, alpha: 0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12).fill()
            let d = NSBezierPath(); d.move(to: NSPoint(x: X(0), y: Y(0))); d.line(to: NSPoint(x: X(1), y: Y(1)))
            NSColor(white: 1, alpha: 0.12).setStroke(); d.lineWidth = 1; d.stroke()
            let c = NSBezierPath()
            for j in 0...48 { let u = Double(j) / 48, q = NSPoint(x: X(u), y: Y(curve(u))); j == 0 ? c.move(to: q) : c.line(to: q) }
            NSColor(red: 1, green: 0.84, blue: 0.2, alpha: 1).setStroke(); c.lineWidth = 2.5; c.lineJoinStyle = .round; c.lineCapStyle = .round; c.stroke()
            if let g = drag, g.mode == 2, g.pts.count > 1 {
                let t = NSBezierPath()
                for (j, q) in g.pts.enumerated() { let n = NSPoint(x: X(q.u), y: Y(q.p)); j == 0 ? t.move(to: n) : t.line(to: n) }
                NSColor(red: 0.5, green: 0.74, blue: 1, alpha: 0.9).setStroke(); t.lineWidth = 2.5; t.stroke()
            }
            if let u = playhead(), u >= 0, u <= 1 {
                let h = NSBezierPath(); h.move(to: NSPoint(x: X(u), y: 4)); h.line(to: NSPoint(x: X(u), y: bounds.height - 4))
                NSColor(white: 1, alpha: 0.7).setStroke(); h.lineWidth = 1.5; h.stroke()
            }
            if window?.firstResponder === self {
                NSColor(red: 0.04, green: 0.52, blue: 1, alpha: 0.8).setStroke()
                let o = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 11, yRadius: 11); o.lineWidth = 2; o.stroke()
            }
        }
        private func at(_ e: NSEvent) -> (u: Double, p: Double) {
            let q = convert(e.locationInWindow, from: nil)
            let fx = Double(max(0, min(1, (q.x - 10) / max(1, bounds.width - 20))))
            let fy = Double(max(0, min(1, (q.y - 8) / max(1, bounds.height - 16))))
            if playing(), let u = playhead() { return (u, fx) }
            return (fx, fy)
        }
        override func mouseDown(with e: NSEvent) {
            window?.makeFirstResponder(self)
            if e.clickCount == 2 { drag = nil; toVoice?(); return }
            drag = (convert(e.locationInWindow, from: nil), k0(), 0, [])
        }
        override func mouseDragged(with e: NSEvent) {
            guard var g = drag else { return }
            let q = convert(e.locationInWindow, from: nil), dx = q.x - g.p.x, dy = q.y - g.p.y
            if g.mode == 0 {
                guard max(abs(dx), abs(dy)) >= 6 else { return }
                g.mode = abs(dy) > abs(dx) ? 1 : 2
            }
            if g.mode == 1 { drag = g; bend?(max(-1, min(1, ((g.k0 + Double(dy) / 60) * 20).rounded() / 20)), false); return }
            let a = at(e)
            if a.u >= -0.05, a.u <= 1.05 { g.pts.append((max(0, min(1, a.u)), a.p)) }
            drag = g; needsDisplay = true
        }
        override func mouseUp(with e: NSEvent) {
            guard let g = drag else { return }
            drag = nil
            if g.mode == 1 { bend?(k0(), true); return }
            guard g.mode == 2, g.pts.count >= 3 else { needsDisplay = true; return }
            // sixteen moments of the word, each lit as far as the pointer was then, never going back (as Gallery)
            let pts = [(u: 0.0, p: 0.0)] + g.pts.sorted { $0.u < $1.u } + [(u: 1.0, p: 1.0)]
            var c: [Double] = [], m = 0.0, k = 1
            for j in 0..<16 {
                let u = Double(j) / 15
                while k < pts.count - 1 && pts[k].u < u { k += 1 }
                let a = pts[k - 1], b = pts[k]
                let p = b.u > a.u ? a.p + (b.p - a.p) * (u - a.u) / (b.u - a.u) : b.p
                m = max(m, min(1, p)); c.append((m * 100).rounded() / 100)
            }
            c[15] = 1
            traced?(c)
        }
        override func keyDown(with e: NSEvent) {
            switch e.keyCode {
            case 126, 125: bend?(max(-1, min(1, ((k0() + (e.keyCode == 126 ? 0.1 : -0.1)) * 20).rounded() / 20)), true)
            case 51, 117: toVoice?()
            default: super.keyDown(with: e)
            }
        }
        override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
        override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    }

    /// A mark: a tap sets it to what is heard; two fingers along it (or ← →) move it a hundredth at a time. Drawn as
    /// Gallery's .txmark: a soft card, its name in blue above the time.
    final class Mark: NSButton {
        var nudge: ((Double) -> Void)?, done: (() -> Void)?
        var name = ""
        var value = "" { didSet { needsDisplay = true } }
        private var acc: CGFloat = 0
        override var acceptsFirstResponder: Bool { true }
        override func draw(_ r: NSRect) {
            let b = bounds.insetBy(dx: 1, dy: 1)
            NSColor(white: 1, alpha: isHighlighted ? 0.16 : 0.08).setFill()
            NSBezierPath(roundedRect: b, xRadius: 12, yRadius: 12).fill()
            if window?.firstResponder === self {
                NSColor(red: 0.04, green: 0.52, blue: 1, alpha: 0.8).setStroke()
                let o = NSBezierPath(roundedRect: b.insetBy(dx: 1, dy: 1), xRadius: 11, yRadius: 11); o.lineWidth = 2; o.stroke()
            }
            let n = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor(red: 0.5, green: 0.74, blue: 1, alpha: 1)])
            let v = NSAttributedString(string: value, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor(white: 1, alpha: 0.85)])
            let h = n.size().height + 1 + v.size().height, y0 = (bounds.height - h) / 2
            // a button's y runs downward: the name first, the time under it
            n.draw(at: NSPoint(x: (bounds.width - n.size().width) / 2, y: y0))
            v.draw(at: NSPoint(x: (bounds.width - v.size().width) / 2, y: y0 + n.size().height + 1))
        }
        override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
        override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
        override func scrollWheel(with e: NSEvent) {
            acc += e.scrollingDeltaX != 0 ? e.scrollingDeltaX : -e.scrollingDeltaY
            let step = e.hasPreciseScrollingDeltas ? 4 : 1
            while abs(acc) >= CGFloat(step) { nudge?(acc > 0 ? -0.01 : 0.01); acc -= acc > 0 ? CGFloat(step) : -CGFloat(step) }
            if e.phase == .ended || e.momentumPhase == .ended || !e.hasPreciseScrollingDeltas { done?() }
        }
        override func keyDown(with e: NSEvent) {
            switch e.keyCode {
            case 123: nudge?(-0.01); done?()
            case 124: nudge?(0.01); done?()
            default: super.keyDown(with: e)
            }
        }
    }

    init(_ line: Line, changed: @escaping ([Int: Pin], Bool) -> Void) {
        self.line = line; self.changed = changed
        var p: [Int: Pin] = [:]
        for (i, w) in line.words.enumerated() { if let t = w.tm { p[i] = t } }
        pins = p
        win = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150), styleMask: [.titled, .closable, .utilityWindow, .hudWindow],
                      backing: .buffered, defer: false)
        super.init()
        // Gallery's editor at the Mac's scale (row 40): the line, its words as chips, Start and End as cards, then the
        // blue words Stop · Auto · Same in N repeats; no title, the same dark glass
        win.title = "Timing by ear"; win.titleVisibility = .hidden; win.titlebarAppearsTransparent = true
        win.styleMask.insert(.fullSizeContentView)
        win.appearance = NSAppearance(named: .darkAqua); win.backgroundColor = NSColor(white: 0, alpha: 0.84); win.isOpaque = false
        win.isFloatingPanel = true; win.hidesOnDeactivate = false; win.delegate = self
        win.isReleasedWhenClosed = false
        let text = NSTextField(wrappingLabelWithString: line.words.map(\.text).joined(separator: " "))
        text.font = .systemFont(ofSize: 15, weight: .semibold); text.textColor = .white
        text.preferredMaxLayoutWidth = 328
        let field = NSView(); field.wantsLayer = true; field.layer?.cornerRadius = 10
        field.layer?.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
        text.translatesAutoresizingMaskIntoConstraints = false; field.addSubview(text)
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 10), text.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -10),
                                     text.topAnchor.constraint(equalTo: field.topAnchor, constant: 6), text.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -6),
                                     field.widthAnchor.constraint(equalToConstant: 348)])
        for (i, w) in line.words.enumerated() {
            let c = Chip(w.text); c.tag = i; c.target = self; c.action = #selector(pick(_:)); chips.append(c)
        }
        // the chips wrap like Gallery's, a row at a time
        var rows: [NSStackView] = [], width: CGFloat = 0
        lineChip.tag = -1; lineChip.target = self; lineChip.action = #selector(pickLine)
        for c in [lineChip] + chips {
            let cw = c.intrinsicContentSize.width
            if rows.isEmpty || width + cw > 348 { rows.append(NSStackView()); rows.last!.spacing = 4; width = 0 }
            rows.last!.addArrangedSubview(c); width += cw + 4
        }
        let words = NSStackView(views: rows); words.orientation = .vertical; words.alignment = .leading; words.spacing = 4
        for (m, key) in [(startB, true), (endB, false)] {
            m.isBordered = false; m.setButtonType(.momentaryPushIn); m.title = ""
            m.name = key ? "Start" : "End"
            m.target = self; m.action = key ? #selector(markStart) : #selector(markEnd)
            m.nudge = { [weak self] d in self?.move(start: key, by: d) }
            m.done = { [weak self] in guard let self else { return }; self.changed(self.pins, true) }
            m.heightAnchor.constraint(equalToConstant: 46).isActive = true
            m.widthAnchor.constraint(equalToConstant: 160).isActive = true
        }
        hearB.target = self; hearB.action = #selector(hearPressed); autoB.target = self; autoB.action = #selector(autoPressed)
        sameB.target = self; sameB.action = #selector(samePressed); sameB.isHidden = true
        for b in [hearB, autoB, sameB] { b.isBordered = false; b.contentTintColor = .linkColor }
        let marks = NSStackView(views: [startB, endB]); marks.spacing = 12
        let buttons = NSStackView(views: [hearB, autoB, sameB]); buttons.spacing = 14
        pad.heightAnchor.constraint(equalToConstant: 60).isActive = true
        pad.widthAnchor.constraint(equalToConstant: 332).isActive = true
        padCap.font = .systemFont(ofSize: 10.5, weight: .medium); padCap.textColor = NSColor(red: 0.5, green: 0.74, blue: 1, alpha: 1)
        padCap.alignment = .center
        let light = NSStackView(views: [pad, padCap]); light.orientation = .vertical; light.spacing = 2
        pad.k0 = { [weak self] in guard let self else { return 0 }; return self.pinOf(self.cur).k }
        pad.playing = { [weak self] in self?.looping ?? false }
        pad.playhead = { [weak self] in
            guard let self, let n = self.now?() else { return nil }
            let p = self.pinOf(self.cur); return (n - p.s) / max(0.05, p.e - p.s)
        }
        pad.curve = { [weak self] u in self?.lightAt(u) ?? u }
        pad.bend = { [weak self] k, push in self?.shape(k: k, c: nil, push: push) }
        pad.traced = { [weak self] c in self?.shape(k: 0, c: c, push: true) }
        pad.toVoice = { [weak self] in self?.shape(k: 0, c: nil, push: true) }
        lineSay.font = .systemFont(ofSize: 12); lineSay.textColor = NSColor(red: 0.5, green: 0.74, blue: 1, alpha: 1)
        lineSay.preferredMaxLayoutWidth = 332
        beat.isBordered = false; beat.setButtonType(.momentaryPushIn); beat.title = ""
        beat.target = self; beat.action = #selector(beatPressed)
        beat.heightAnchor.constraint(equalToConstant: 52).isActive = true
        beat.widthAnchor.constraint(equalToConstant: 332).isActive = true
        useB.target = self; useB.action = #selector(usePressed); retryB.target = self; retryB.action = #selector(retryPressed)
        traceB.target = self; traceB.action = #selector(tracePressed); voiceB.target = self; voiceB.action = #selector(voicePressed)
        for b in [useB, retryB, traceB, voiceB] { b.isBordered = false; b.contentTintColor = .linkColor }
        let lineBtns = NSStackView(views: [useB, retryB, traceB, voiceB]); lineBtns.spacing = 14
        linePad.heightAnchor.constraint(equalToConstant: 60).isActive = true
        linePad.widthAnchor.constraint(equalToConstant: 332).isActive = true
        linePad.playing = { true }
        linePad.playhead = { [weak self] in
            guard let self, let a = self.beatA, let b = self.beatB, let n = self.now?() else { return nil }
            return (n - a) / max(0.05, b - a)
        }
        linePad.traced = { [weak self] c in self?.fromTrace(c) }
        wordViews = [marks, light, buttons]; lineViews = [lineSay, beat, linePad, lineBtns]
        for v in lineViews { v.isHidden = true }
        let stack = NSStackView(views: [field, words, marks, light, buttons] + lineViews); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.setCustomSpacing(10, after: words)
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 16, bottom: 14, right: 16)
        win.contentView = stack
        win.setContentSize(stack.fittingSize)
        load(0)
    }

    func show(over w: NSWindow) {
        let f = w.frame
        win.setFrameOrigin(NSPoint(x: f.midX - win.frame.width / 2, y: max(40, f.minY - win.frame.height - 8)))
        win.orderFront(nil); win.makeKey()
        startLoop()
        padTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pad.needsDisplay = true }
        }
    }
    func close() { win.close() }
    func windowWillClose(_ n: Notification) { padTimer?.invalidate(); padTimer = nil; if looping { hear?(nil, nil) }; onClose?() }

    /// How much of the chosen word is lit u of the way from its start to its end, as the light will draw it.
    private func lightAt(_ u: Double) -> Double {
        var w = line.words[cur]; w.tm = pinOf(cur)
        let ln = Cadence.pin([Line(id: line.id, words: [w], english: nil)])
        guard let b = ln.first.map(sourceBeats)?.first else { return u }
        let p = pinOf(cur)
        return Cadence.progress(b, p.s + u * (p.e - p.s))
    }
    /// The chosen word's light reshaped: a speed (k), a trace (c), or neither (the voice).
    private func shape(k: Double, c: [Double]?, push: Bool) {
        let p = pinOf(cur)
        pins[cur] = Pin(s: p.s, e: p.e, k: c == nil ? k : 0, c: c)
        labels()
        changed(pins, push)
    }

    private func auto(_ i: Int) -> Pin { let w = line.words[i]; return Pin(s: w.start, e: max(w.end, w.start + 0.05), k: 0) }
    private func pinOf(_ i: Int) -> Pin { pins[i] ?? auto(i) }
    private func load(_ i: Int) {
        cur = i
        labels()
        win.makeFirstResponder(startB)
    }
    private func labels() {
        let p = pinOf(cur)
        func t(_ x: Double) -> String { String(format: "%d:%05.2f", Int(x) / 60, x.truncatingRemainder(dividingBy: 60)) }
        startB.value = t(p.s); endB.value = t(p.e)
        padCap.stringValue = p.c != nil ? "Traced" : abs(p.k) <= 0.05 ? "Follows the voice" : p.k > 0 ? "Faster at first" : "Slower at first"
        pad.needsDisplay = true
        for c in chips { c.picked = !lineMode && c.tag == cur; c.timed = pins[c.tag] != nil }
    }
    /// The word's span with one end moved (the other kept 50 ms clear of it); its light keeps its shape.
    private func set(start: Bool, _ x: Double, push: Bool) {
        let p = pinOf(cur)
        var a = p.s, b = p.e
        if start { a = max(0, x); b = max(b, a + 0.05) } else { b = max(x, a + 0.05) }
        pins[cur] = Pin(s: (a * 1000).rounded() / 1000, e: (b * 1000).rounded() / 1000, k: p.k, c: p.c)
        labels()
        changed(pins, push)
    }
    private func move(start: Bool, by d: Double) { let p = pinOf(cur); set(start: start, (start ? p.s : p.e) + d, push: false) }
    @objc private func markStart() { if let n = now?() { set(start: true, n, push: true) } }
    @objc private func markEnd() { if let n = now?() { set(start: false, n, push: true) } }
    @objc private func pick(_ c: NSButton) { setLineMode(false); load(c.tag); startLoop() }

    private func setLineMode(_ on: Bool) {
        lineMode = on
        for v in wordViews { v.isHidden = on }
        for v in lineViews { v.isHidden = !on }
        lineChip.picked = on
        if on { for c in chips { c.picked = false } }
        if let st = win.contentView { win.setContentSize(st.fittingSize) }
    }
    /// The line's sung stretch as it is now (a cadence already used has moved its words).
    private var sungSpan: (Double, Double)? {
        let ws = line.words.enumerated().filter { $0.element.un != true || pins[$0.offset] != nil }
        guard !ws.isEmpty else { return nil }
        return (ws.map { pins[$0.offset]?.s ?? $0.element.start }.min()!, ws.map { pins[$0.offset]?.e ?? $0.element.end }.max()!)
    }
    private func lineStep(_ step: String, _ say: String) {
        lineSay.stringValue = say
        beat.isHidden = step != "a" && step != "b"
        beat.name = step == "a" ? "First beat" : "Last beat"; beat.value = "tap as it is sung"
        useB.isHidden = step != "check"; retryB.isHidden = step == "a"
        traceB.isHidden = step != "auto"; voiceB.isHidden = pins.isEmpty
        linePad.isHidden = step != "trace"
        if let st = win.contentView { win.setContentSize(st.fittingSize) }
    }
    private func loopLine() { looping = true; hearB.title = "Stop"; hear?(lo + 0.8, hi - 0.5) }
    @objc private func pickLine() {
        guard let (w0, w1) = sungSpan else { return }
        setLineMode(true)
        beatA = nil; beatB = nil; lo = max(0, w0 - 0.8); hi = w1 + 0.5
        lineStep("a", "Tap on the first beat")
        loopLine()
        win.makeFirstResponder(beat)
    }
    @objc private func beatPressed() {
        guard let n = now?() else { return }
        let t = (n * 1000).rounded() / 1000
        if beatA == nil { beatA = t; lineStep("b", "Tap on the last beat"); return }
        guard let a = beatA, t > a + 0.1 else { lineSay.stringValue = "The last beat comes after the first"; return }
        beatB = t; lo = a; hi = t
        loopLine()
        func m(_ x: Double) -> String { String(format: "%d:%05.2f", Int(x) / 60, x.truncatingRemainder(dividingBy: 60)) }
        lineStep("check", "\(m(a)) – \(m(t)): playing between your two beats. Good?")
    }
    @objc private func retryPressed() { pickLine() }
    /// Auto: the words keep the voice's shape, set inside the listener's two beats.
    @objc private func usePressed() {
        guard let a = beatA, let b = beatB, let (w0, w1) = sungSpan else { return }
        let k = (b - a) / max(0.05, w1 - w0)
        let r3 = { (x: Double) in (x * 1000).rounded() / 1000 }
        for (i, w) in line.words.enumerated() where w.un != true || pins[i] != nil {
            let s0 = pins[i]?.s ?? w.start, e0 = pins[i]?.e ?? w.end
            pins[i] = Pin(s: r3(a + (s0 - w0) * k), e: r3(a + (e0 - w0) * k), k: 0)
        }
        changed(pins, true); labels()
        lineStep("auto", "The light follows the voice between your beats. Not quite? Trace it.")
    }
    @objc private func tracePressed() { lineStep("trace", "Slide along as it is sung, from its first word to its last") }
    @objc private func voicePressed() {
        pins = [:]; changed(pins, true); labels()
        pickLine()
    }
    /// The line traced (c: how much of the line was passed at 16 moments from the first beat to the last): each word
    /// takes its start, end and fill from where the finger was over its letters (Gallery's `fromTrace`).
    private func fromTrace(_ c: [Double]) {
        guard let a = beatA, let b = beatB else { return }
        let q = c.enumerated().map { (u: Double($0.offset) / Double(c.count - 1), p: $0.element) }
        func when(_ f: Double) -> Double {
            var j = 1
            while j < q.count - 1 && q[j].p < f { j += 1 }
            let x = q[j - 1], y = q[j]
            let u = y.p > x.p ? x.u + (y.u - x.u) * (f - x.p) / (y.p - x.p) : y.u
            return a + u * (b - a)
        }
        func at(_ t: Double) -> Double {
            let u = (t - a) / (b - a)
            var j = 1
            while j < q.count - 1 && q[j].u < u { j += 1 }
            let x = q[j - 1], y = q[j]
            return y.u > x.u ? x.p + (y.p - x.p) * (u - x.u) / (y.u - x.u) : y.p
        }
        let sung = line.words.enumerated().filter { $0.element.un != true || pins[$0.offset] != nil }
        let len = Double(sung.reduce(0) { $0 + max(1, $1.element.text.count) })
        var c0 = 0.0
        let r3 = { (x: Double) in (x * 1000).rounded() / 1000 }
        for (i, w) in sung {
            let n = Double(max(1, w.text.count)), f0 = c0 / len, f1 = (c0 + n) / len
            c0 += n
            let s = when(f0), e = max(when(f1), s + 0.05)
            var cw = (0..<16).map { j in ((max(0, min(1, (at(s + (e - s) * Double(j) / 15) - f0) / (f1 - f0)))) * 100).rounded() / 100 }
            for j in 1..<16 { cw[j] = max(cw[j], cw[j - 1]) }
            cw[15] = 1
            pins[i] = Pin(s: r3(s), e: r3(e), k: 0, c: cw)
        }
        changed(pins, true); labels()
        lineStep("auto", "Traced. Trace again or go back to the voice.")
    }
    private func startLoop() {
        looping = true; hearB.title = "Stop"
        let p = pinOf(cur); hear?(p.s, p.e)
    }
    @objc private func hearPressed() {
        if looping { looping = false; hearB.title = "Hear it"; hear?(nil, nil) } else { startLoop() }
    }
    @objc private func autoPressed() {
        pins[cur] = nil
        changed(pins, true)
        load(cur)
    }
    @objc private func samePressed() {
        toRepeats?(pins)
        sameB.title = "Repeats timed"
    }
}
