import Foundation
import NaturalLanguage

// ---------- Recense's open ears: every language Apple's can't hear ----------
// Apple's SpeechAnalyzer hears about 46 languages on this Mac (speech.swift). Every other one — Amharic, Zulu, Yoruba,
// Shona, Swahili, Bambara, Persian, Tibetan, Burmese, Khmer, Mongolian, Javanese, Scottish Gaelic, Irish, Kabyle,
// Uyghur, Tigrinya, … 1,600+ in all — is heard by Meta's Omnilingual ASR (CTC, 300M parameters, Apache 2.0) running
// on this Mac: offline, no quota, no key. One model for all of them (1.2 GB in ~/.cache/fairseq2, 0.6 GB in memory),
// in a Python helper (ears/omni.py) Sill starts when it's needed and that leaves after five quiet minutes.
// The model is told no language: it writes what it hears in the script it's written in, and `Tongue` names the
// language from that text. That makes it the ears that tell which language a recording is in, too: Apple's need to
// be told, so a recording Apple can hear is identified here first and then heard by Apple (better timing, the
// listener's lexicon), and one it can't is heard here.
// Setup (once): python3.10 -m venv ~/.local/share/recense/omni; …/omni/bin/pip install omnilingual-asr torchaudio==2.8.0;
// brew install libsndfile. The model downloads on first use.

@MainActor enum OpenEars {
    struct Word { var text: String; var start: Double; var end: Double; var c: Double; var t: [Double] }

    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/recense/omni")
    static var python: String { root.appendingPathComponent("bin/python").path }
    static var script: String? {
        if let p = Bundle.main.path(forResource: "omni", ofType: "py", inDirectory: "ears") { return p }
        let dev = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/sill/sill/ears/omni.py").path
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }
    /// The helper and its Python are on this Mac (the model itself may still need its one download).
    static var installed: Bool { FileManager.default.isExecutableFile(atPath: python) && script != nil && !broken }
    static var broken = false                       // it failed to start three times running: not again this launch
    static var card: String?, device: String?

    private static var proc: Process?
    private static var input: FileHandle?
    private static var buffer = Data()
    private static var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private static var ready: CheckedContinuation<Void, Error>?
    private static var next = 0, fails = 0
    private static var queue: Task<Void, Never> = Task {}
    static var pace: Double?                        // seconds a second of audio took them last (a request of 20 s or more)
    /// They hear at least as fast as it plays: worth asking about a stretch another ears already heard.
    static var keepsUp: Bool { (pace ?? 0) <= 1 }

    /// Hears 16 kHz mono samples; `script`: the one the recording's language is written in, when it's known (the model
    /// then writes only its letters, plus Latin where it earns its place). One request at a time.
    static func hear(_ samples: [Float], script: String? = nil) async throws -> [Word] {
        let prev = queue
        let mine = Task { @MainActor () async throws -> [Word] in
            await prev.value
            return try await request(samples, script: script)
        }
        queue = Task { _ = try? await mine.value }
        return try await mine.value
    }

    private static func request(_ samples: [Float], script: String?) async throws -> [Word] {
        if proc == nil { try await start() }
        guard let input else { throw err("the open ears aren't running") }
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("recense-open-\(UUID().uuidString).f32")
        try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        next += 1
        let id = next
        var q: [String: Any] = ["id": id, "f32": f.path]
        if let script { q["script"] = script }
        let line = try JSONSerialization.data(withJSONObject: q) + Data("\n".utf8)
        let t0 = Date()
        let reply = try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: Any], Error>) in
            waiting[id] = c
            do { try input.write(contentsOf: line) } catch { waiting[id] = nil; c.resume(throwing: error) }
        }
        if let e = reply["error"] as? String { throw err("open ears: \(e)") }
        let ws = (reply["words"] as? [[String: Any]] ?? []).compactMap { w -> Word? in
            guard let t = w["w"] as? String, let s = w["s"] as? Double, let e = w["e"] as? Double else { return nil }
            return Word(text: t, start: s, end: e, c: w["c"] as? Double ?? 0.5, t: w["t"] as? [Double] ?? [])
        }
        let secs = Double(samples.count) / 16000, took = Date().timeIntervalSince(t0)
        if secs >= 20 { pace = took / secs }
        log(String(format: "speech: open ears heard %.0f s in %.1f s (%d words)", secs, took, ws.count))
        return ws
    }

    private static func start() async throws {
        guard installed, let script else { throw err("the open ears aren't installed (~/.local/share/recense/omni)") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-u", script]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["DYLD_FALLBACK_LIBRARY_PATH"] = "/opt/homebrew/lib:/usr/local/lib:/usr/lib"     // libsndfile (Homebrew)
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let i = Pipe(), o = Pipe()
        p.standardInput = i; p.standardOutput = o
        let errLog = cacheDir.appendingPathComponent("openears.log")
        FileManager.default.createFile(atPath: errLog.path, contents: nil)
        p.standardError = (try? FileHandle(forWritingTo: errLog)) ?? FileHandle.nullDevice
        o.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            Task { @MainActor in received(d) }
        }
        p.terminationHandler = { q in
            let code = q.terminationStatus
            Task { @MainActor in ended(code) }
        }
        try p.run()
        proc = p; input = i.fileHandleForWriting; buffer = Data()
        log("speech: starting the open ears (Omnilingual ASR)")
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in ready = c }
            fails = 0
        } catch {
            fails += 1
            if fails >= 3 { broken = true; log("speech: the open ears failed to start three times; not again until Sill restarts (see \(errLog.path))") }
            throw error
        }
    }

    private static func received(_ d: Data) {
        if d.isEmpty { return }
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if o["ready"] as? Bool == true {
                card = o["card"] as? String; device = o["device"] as? String
                log("speech: open ears ready (\(card ?? "?") on \(device ?? "?"), loaded in \(o["load"] ?? "?") s)")
                ready?.resume(); ready = nil
            } else if let id = o["id"] as? Int, let c = waiting.removeValue(forKey: id) {
                c.resume(returning: o)
            }
        }
    }

    private static func ended(_ code: Int32) {
        proc = nil; input = nil
        if code != 0 { log("speech: the open ears stopped (exit \(code)); see openears.log") }
        let e = err("the open ears stopped (exit \(code))")
        ready?.resume(throwing: e); ready = nil
        for (_, c) in waiting { c.resume(throwing: e) }
        waiting = [:]
    }

    /// The language codes Omnilingual names (`amh_Ethi` …), from the installed package: what these ears can hear.
    static var languages: [String] = {
        let f = root.appendingPathComponent("lib/python3.10/site-packages/omnilingual_asr/models/wav2vec2_llama/lang_ids.py")
        guard let s = try? String(contentsOf: f, encoding: .utf8) else { return [] }
        let re = try! NSRegularExpression(pattern: "\"([a-z]{3}_[A-Z][a-z]{3})\"")
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } }
    }()

    static func report() -> [String: Any] {
        var r: [String: Any] = ["installed": installed, "model": card ?? "omniASR_CTC_300M", "running": proc != nil, "languages": languages.count]
        if let device { r["device"] = device }
        if broken { r["broken"] = true }
        return r
    }
}

// ---------- which language a heard text is in ----------
// From the script first (Ge'ez letters are Amharic or Tigrinya, Tibetan is Tibetan), then, among the languages that
// share a script, from the spelling: Apple's NaturalLanguage where it knows the language, and the little words a
// language can't speak without (ukuthi, agus, ẹ, ɛ) where it doesn't: Zulu, Yoruba, Swahili, Shona, Bambara, Gaelic,
// Irish, Javanese, Kabyle, Sanskrit, Uyghur. ISO 639-1 codes where there is one.
enum Tongue {
    /// The language of `text`, and how surely; nil when there's too little to tell.
    static func identify(_ text: String) -> (code: String, p: Double)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 4, let script = scriptOf(text: t) else { return nil }
        switch script {
        case "Ethi": return marked(t, ["ti": ["እየ", "ኣብ", "ምስ", "ከኣ", "ኢዩ", "እዩ", "ኣይ", "ዝኾነ", "እዚ"]], or: ("am", 0.8))
        case "Tibt": return ("bo", 0.95)
        case "Mymr": return ("my", 0.95)
        case "Khmr": return ("km", 0.95)
        case "Laoo": return ("lo", 0.95)
        case "Sinh": return ("si", 0.95)
        case "Thai": return ("th", 0.95)
        case "Mong": return ("mn", 0.95)
        case "Geor": return ("ka", 0.95)
        case "Armn": return ("hy", 0.95)
        case "Thaa": return ("dv", 0.95)
        case "Grek": return ("el", 0.9)
        case "Hebr": return dominantLanguage(t, among: ["he", "yi"]) ?? ("he", 0.6)
        case "Taml": return ("ta", 0.9)
        case "Telu": return ("te", 0.95)
        case "Knda": return ("kn", 0.95)
        case "Mlym": return ("ml", 0.95)
        case "Orya": return ("or", 0.95)
        case "Guru": return ("pa", 0.95)
        case "Beng": return dominantLanguage(t, among: ["bn", "as"]) ?? ("bn", 0.6)
        case "Deva", "Gujr": return indic(t, script)
        case "Arab": return arabic(t)
        case "Cyrl": return dominantLanguage(t, among: ["ru", "uk", "bg", "sr", "mk", "be", "kk", "mn", "ky", "tg"]) ?? ("ru", 0.5)
        case "CJK": return cjk(t)
        case "Latn": return latin(t)
        default: return nil
        }
    }

    static func words(_ t: String) -> [String] {
        t.lowercased().components(separatedBy: CharacterSet.letters.union(.nonBaseCharacters).union(CharacterSet(charactersIn: "'’ʼ‘")).inverted).filter { !$0.isEmpty }
    }

    /// The language whose little words make up the largest share of the text, when they make up enough of it.
    static func marked(_ t: String, _ marks: [String: Set<String>], or fallback: (String, Double)?, floor: Double = 0.12,
                       bonus: [String: Double] = [:]) -> (code: String, p: Double)? {
        let ws = words(t)
        guard !ws.isEmpty else { return fallback }
        let best = marks.map { (k, v) in (k, Double(ws.filter { v.contains($0) }.count) / Double(ws.count) + (bonus[k] ?? 0)) }.max { $0.1 < $1.1 }
        if let best, best.1 >= floor { return (best.0, min(0.95, 0.5 + best.1)) }
        return fallback
    }

    /// Latin script: NaturalLanguage for the languages it has a model of; the little words for those it hasn't.
    static let latinMarks: [String: Set<String>] = [
        "zu": ["ukuthi", "ngoba", "kodwa", "futhi", "uma", "kakhulu", "yini", "ngiyabonga", "abantu", "nkosi", "lapho", "manje", "kanye", "noma",
               "wena", "mina", "thina", "yebo", "ngithi", "kahle", "ukuba", "ngaphandle", "kufanele", "nje", "khona", "sizwe", "baba", "ngempela"],
        "xh": ["ukuba", "kwaye", "ndiya", "umntu", "yintoni", "enkosi", "ngoko", "kwakhona", "kakhulu", "ukuze", "ndingu", "nathi", "ewe"],
        "sn": ["uye", "kuti", "ndiri", "asi", "kana", "zvino", "vanhu", "mwari", "ndinoda", "here", "sei", "pamwe", "chete", "zvakanaka", "iwe",
               "ini", "isu", "ndi", "nekuti", "saka", "ndakanga", "zvose", "kwete", "ehe", "baba", "amai"],
        "sw": ["na", "kwa", "ya", "wa", "ni", "katika", "kwamba", "lakini", "sana", "hii", "huu", "watu", "mungu", "nini", "yake", "wako", "hapa",
               "sasa", "hapana", "ndiyo", "kama", "pia", "hivyo", "yetu", "wetu", "mimi", "wewe", "sisi"],
        "yo": ["ati", "ni", "ti", "won", "mo", "si", "fun", "naa", "sugbon", "oluwa", "emi", "awa", "ko", "wa", "lo", "ọlọrun", "olorun",
               "ṣe", "se", "pẹlu", "pelu", "kan", "yii", "rẹ", "re", "mi", "ẹ", "e"],
        "bm": ["ye", "ka", "ni", "bɛ", "be", "tɛ", "te", "ko", "ani", "min", "an", "kɔ", "dɔ", "ma", "la", "kɛ", "ke", "bɛɛ", "fɛ", "nin", "i", "n"],
        "gd": ["agus", "tha", "air", "gu", "ann", "bha", "sin", "seo", "mi", "thu", "chan", "ach", "nach", "ri", "dhan", "dhe", "bho", "nam",
               "gun", "aig", "e", "i", "iad", "sinn", "sibh", "cha", "mar", "leis", "ruith", "fhèin", "fhein"],
        "ga": ["agus", "tá", "ta", "bhí", "bhi", "ar", "go", "sé", "sí", "níl", "nil", "mé", "me", "tú", "tu", "leis", "ach", "nach", "seo",
               "sin", "i", "ag", "is", "an", "na", "do", "ní", "ni", "iad", "muid", "sibh", "féin", "fein", "mar"],
        "jv": ["lan", "ing", "sing", "ora", "iku", "karo", "kanggo", "wis", "aku", "kowe", "dadi", "uga", "saka", "nang", "menyang", "ana",
               "dheweke", "iki", "kuwi", "wae", "mung", "banget", "neng", "kabeh", "kudu", "arep", "durung"],
        "kab": ["akken", "d", "n", "ad", "ur", "yella", "di", "s", "seg", "deg", "netta", "nekk", "ɣer", "ger", "acu", "ayen", "kan", "mačči",
                "macci", "ihi", "nnig", "deffir", "tura", "ass", "yiwen"],
        "uz": ["va", "bu", "uchun", "bilan", "ham", "edi", "emas", "bor", "yoʻq", "yo'q", "men", "sen", "biz", "siz", "ular", "lekin", "juda",
               "nima", "qanday", "shu", "u", "deb"],
        "la": ["et", "est", "in", "non", "ad", "cum", "quod", "sed", "qui", "quae", "ut", "deus", "dei", "domine", "nobis", "sunt", "esse",
               "per", "ex", "nos", "tibi", "mea", "tua", "gloria", "amen"],
    ]
    static func latin(_ t: String) -> (code: String, p: Double)? {
        // letters only some of them write
        let s = Set(t.lowercased())
        var bonus: [String: Double] = [:]
        if !s.isDisjoint(with: ["ɔ", "ɲ", "ŋ"]) { bonus["bm"] = 0.3 }                           // Bambara's open o, ny, ng
        if !s.isDisjoint(with: ["ẹ", "ọ", "ṣ"]) { bonus["yo"] = 0.3 }                           // Yoruba's under-dots
        if !s.isDisjoint(with: ["ɣ", "č", "ǧ", "ṭ", "ẓ", "ḍ"]) { bonus["kab"] = 0.3 }              // Kabyle's
        if !s.isDisjoint(with: ["à", "è", "ì", "ò", "ù"]) { bonus["gd"] = 0.1 }                   // Gaelic's grave accents
        let nl = dominantLanguage(t)
        let m = marked(t, latinMarks, or: nil, floor: 0.15, bonus: bonus)
        if let m, m.code != nl?.code, (nl?.p ?? 0) < 0.9 || m.p > 0.8 { return m }
        if let nl, nl.p >= 0.5 { return nl }
        return m ?? nl
    }

    /// Devanagari (and the Gujarati script Omnilingual sometimes writes Sanskrit in): Sanskrit, Hindi, Marathi, Nepali,
    /// Gujarati — by their little words, Sanskrit's visarga and endings; NaturalLanguage between the living ones.
    static func indic(_ t: String, _ script: String) -> (code: String, p: Double)? {
        let d = script == "Gujr" ? (t.applyingTransform(StringTransform("Gujarati-Devanagari"), reverse: false) ?? t) : t
        let ws = d.split(whereSeparator: { $0.isWhitespace || "।॥,.".contains($0) }).map(String.init)
        guard !ws.isEmpty else { return nil }
        let marks: [String: Set<String>] = [
            "sa": ["च", "न", "तत्", "इति", "अथ", "एव", "हि", "सः", "अहम्", "त्वम्", "यत्", "तस्य", "नमः", "ॐ", "शान्तिः", "वा", "अपि", "तु", "यः",
                   "ते", "मे", "मम", "तव", "सर्वम्", "इदम्", "अस्ति", "भवति", "उवाच", "किम्", "यथा", "तथा", "सह", "प्रति", "स्वाहा", "तदा", "यदा"],
            "hi": ["है", "हैं", "का", "की", "के", "में", "से", "और", "को", "नहीं", "यह", "था", "थी", "थे", "भी", "पर", "हम", "आप", "मैं", "तो", "कि", "जो", "हो", "गया"],
            "mr": ["आहे", "आणि", "हे", "या", "ला", "च्या", "नाही", "होते", "आहेत", "मी", "तुम्ही", "आम्ही", "पण", "म्हणून", "काय", "केले"],
            "ne": ["छ", "र", "हो", "पनि", "मा", "को", "लाई", "गर्न", "थियो", "छन्", "म", "हामी", "तपाईं", "भयो", "यो", "त्यो"],
            "gu": ["છે", "અને", "માં", "નો", "ની", "નું", "પણ", "હતો", "હતી", "હું", "તમે", "અમે"].map { $0.applyingTransform(StringTransform("Gujarati-Devanagari"), reverse: false) ?? $0 }.reduce(into: Set<String>()) { $0.insert($1) },
        ]
        var score = marks.mapValues { m in Double(ws.filter { m.contains($0) }.count) / Double(ws.count) }
        // Sanskrit's own shape: words ending in visarga, in -म्/-स्य/-ाय/-ेन, long compounds
        let shaped = ws.filter { $0.hasSuffix("ः") || $0.hasSuffix("म्") || $0.hasSuffix("स्य") || $0.hasSuffix("ाय") || $0.hasSuffix("ेन") || $0.hasSuffix("ानि") }.count
        score["sa", default: 0] += 0.5 * Double(shaped) / Double(ws.count) + (ws.filter { $0.count >= 12 }.count > ws.count / 6 ? 0.1 : 0)
        if script == "Gujr", (score["gu"] ?? 0) < 0.08 { score["gu"] = 0 }
        let best = score.max { $0.value < $1.value }!
        if best.value >= 0.1 { return (best.key, min(0.95, 0.5 + best.value)) }
        if script == "Gujr" { return ("gu", 0.5) }
        return dominantLanguage(d, among: ["hi", "mr", "ne"]) ?? ("hi", 0.4)
    }

    /// Arabic script: Persian, Urdu, Pashto, Uyghur, Kurdish and Arabic by the letters only each of them writes.
    static func arabic(_ t: String) -> (code: String, p: Double)? {
        func n(_ s: String) -> Int { t.unicodeScalars.filter { s.unicodeScalars.contains($0) }.count }
        let letters = max(1, t.unicodeScalars.filter { $0.properties.isAlphabetic }.count)
        let tally: [(String, Int)] = [
            ("ug", n("ېۆۇۈڭ") * 2 + (t.contains("ئ") ? 2 : 0)),
            ("ps", n("ټډړږښګڼۍ") * 2),
            ("ur", n("ےٹڈڑں") * 2),
            ("ckb", n("ڕڵێ") * 2),
            ("fa", n("پچژگ") + n("یک") / 3),
            ("ar", n("ةيىأإ") + (t.components(separatedBy: " ال").count - 1)),
        ]
        let best = tally.max { $0.1 < $1.1 }!
        if best.1 == 0 { return ("ar", 0.4) }
        return (best.0, min(0.95, 0.5 + Double(best.1) / Double(letters)))
    }

    /// Chinese characters: Korean by its own letters, Japanese by kana, Cantonese by the characters only it writes.
    static func cjk(_ t: String) -> (code: String, p: Double)? {
        let u = t.unicodeScalars
        if u.contains(where: { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }) { return ("ko", 0.95) }
        if u.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return ("ja", 0.95) }
        if t.contains(where: { "嘅咗唔係冇嘢喺哋佢啲".contains($0) }) { return ("yue", 0.85) }
        return ("zh", 0.9)
    }
}
