import Foundation
import AVFoundation
import NaturalLanguage
#if compiler(>=6.2)
import Speech
#endif

// ---------- Recense's ears: on this Mac ----------
// Apple's SpeechAnalyzer (the macOS 26 generation) hears what Recense plays in place of Groq's Whisper: offline, with
// no quota to run out of, every word timed. Every language it has on this Mac (asked of the system, ~46), and for the
// rest the open ears (openears.swift: Meta's Omnilingual ASR, 1,600+ languages, also on this Mac) and the canon
// (canon.swift: recited texts in languages no model hears, written as the text has them). No Groq. Two modules:
//   SpeechTranscriber      English and French: the long-form model (on a 2-minute English recording it wrote 98 % of
//                          Whisper's words, word times within 0.09 s of Whisper's at the median, ~30× real time)
//   DictationTranscriber   Vietnamese (SpeechTranscriber has none), and the only module that takes a custom language
//                          model: the words this listener taught it (CustomLM)
// A request is answered the way Whisper answers one, so the pipeline after it (chunks, the second pass, songs,
// keep/, Gallery) is unchanged. Whisper picked the language itself; here the open ears name it (Apple's must be
// told), and where two win by turns (a French lesson explained in English) both are kept, phrase by phrase.
// Platform reach: macOS only; the engine needs macOS 26+ at run time and a 26+ SDK to compile (compiler(>=6.2));
// built without one, nothing is transcribed (transcripts already made still play) and the Lexicon still learns.

@MainActor enum OnDeviceASR {
    /// This Mac transcribes for itself: built with the SDK, running macOS 26+.
    static var enabled: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }

    /// One request, answered as Whisper answers one (`language`, `segments`, `words` timed from the samples' start,
    /// with `probability` and `lang` per word, `engine`), or nil when this Mac can't hear `language` (or, with none
    /// forced, any of `languages`). `prefer`: the language this recording was heard in last.
    static func transcribe(_ samples: [Float], language: String?, languages: [String], prefer: String?) async throws -> [String: Any]? {
        #if compiler(>=6.2)
        if #available(macOS 26, *), enabled {
            return try await Ears.transcribe(samples, language: language, languages: languages, prefer: prefer)
        }
        #endif
        return nil
    }

    /// What the ears are, for a look from the terminal (`curl -s localhost:47123/speech`): which model hears each
    /// language, the lexicon's size, the custom language models, the permission they need. Read-only: the server
    /// answers any page.
    static func report() async -> [String: Any] {
        var r: [String: Any] = ["onDevice": enabled, "translator": cfg.translateBase.isEmpty ? "apple" : "apple, then \(cfg.translateModel)",
                                "lexicon": ["version": Lexicon.version, "lessons": Lexicon.book.langs.mapValues(\.count)] as [String: Any]]
        #if compiler(>=6.2)
        if #available(macOS 26, *), enabled {
            // every language this Mac's ears have, asked of the system: Apple's two modules, then the open ears
            let speech = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted()
            let dictation = await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted()
            let apple = Set((speech + dictation).map { String($0.split(separator: "-")[0]) }).sorted()
            r["apple"] = ["languages": apple.count, "codes": apple, "speechTranscriber": speech, "dictationTranscriber": dictation] as [String: Any]
            r["open"] = OpenEars.report()
            r["canon"] = Canon.report()
            var hears: [String: String] = [:]
            for l in apple { if let (m, loc) = await Ears.module(l) { hears[l] = m.rawValue + " " + loc.identifier } }
            r["hears"] = hears
            r["customLM"] = CustomLM.built
            r["permission"] = ["not asked", "denied", "restricted", "allowed"][min(3, SFSpeechRecognizer.authorizationStatus().rawValue)]
        }
        #endif
        return r
    }

    /// `defaults write local.recense speechCheck -bool YES`, then Recense started: once, a throwaway custom language model is
    /// built (asking for Speech Recognition permission if it hasn't been), and the outcome logged.
    static func startup() {
        guard UserDefaults.standard.bool(forKey: "speechCheck") else { return }
        UserDefaults.standard.removeObject(forKey: "speechCheck")
        #if compiler(>=6.2)
        if #available(macOS 26, *), enabled { Task { try? await Task.sleep(for: .seconds(5)); log("speech check: \(await CustomLM.check())") } }
        #endif
    }

    /// Whether this Mac hears a language itself.
    static func hears(_ lang: String) async -> Bool {
        #if compiler(>=6.2)
        if #available(macOS 26, *), enabled {
            if OpenEars.installed || Canon.languages.contains(lang) { return true }
            return await Ears.module(lang) != nil
        }
        #endif
        return false
    }
}

#if compiler(>=6.2)
@available(macOS 26, *)
@MainActor enum Ears {
    enum Module: String { case speech = "apple.speechtranscriber", dictation = "apple.dictationtranscriber", open = "meta.omnilingual" }
    struct W { var text: String; var start: Double; var end: Double; var c: Double; var lang: String; var heard: String? = nil }
    struct Phrase { var start: Double; var end: Double; var text: String; var alts: [String]; var words: [W] }
    struct Hearing { var lang: String; var module: Module; var phrases: [Phrase]; var lm = false; var canon: String? = nil
        var words: [W] { phrases.flatMap(\.words) }
    }

    /// The module that hears a language here, and its locale; nil: neither does.
    static var modules: [String: (Module, Locale)?] = [:]
    static func module(_ lang: String) async -> (Module, Locale)? {
        if let m = modules[lang] { return m }
        let want = Locale(identifier: ["en": "en-US", "fr": "fr-FR", "vi": "vi-VN"][lang] ?? lang)
        var m: (Module, Locale)?
        if SpeechTranscriber.isAvailable, let l = await SpeechTranscriber.supportedLocale(equivalentTo: want) { m = (.speech, l) }
        else if let l = await DictationTranscriber.supportedLocale(equivalentTo: want) { m = (.dictation, l) }
        modules[lang] = m
        if m == nil { log("speech: no on-device model for \(lang)") }
        return m
    }

    /// The locale's model on this Mac, downloaded once (the one moment this needs a connection) and reserved.
    static var ready: Set<String> = []
    static var used: [String: Date] = [:]          // when each locale was last asked for (the one used longest ago goes first)
    static func prepare(_ m: Module, _ l: Locale) async -> Bool {
        let id = m.rawValue + "|" + l.identifier
        used[l.identifier(.bcp47)] = Date()
        if ready.contains(id) { return true }
        let probe: any SpeechModule = m == .speech ? SpeechTranscriber(locale: l, preset: .transcription) : DictationTranscriber(locale: l, preset: .longDictation)
        let have = m == .speech ? await SpeechTranscriber.installedLocales : await DictationTranscriber.installedLocales
        // the system lets an app hold at most a few locales (5 here): every language unlocked means letting go of the
        // one used longest ago (its model stays on the Mac; reserving it again later is instant)
        let held = await AssetInventory.reservedLocales
        if held.count >= AssetInventory.maximumReservedLocales, !held.contains(where: { $0.identifier(.bcp47) == l.identifier(.bcp47) }) {
            let own = Set(NativeLang.all.map(\.code))        // the listener's own languages go last
            let old = held.min { a, b in
                let oa = own.contains(a.language.languageCode?.identifier ?? ""), ob = own.contains(b.language.languageCode?.identifier ?? "")
                return oa != ob ? !oa : (used[a.identifier(.bcp47)] ?? .distantPast) < (used[b.identifier(.bcp47)] ?? .distantPast)
            }
            if let old, await AssetInventory.release(reservedLocale: old) {
                ready = ready.filter { !$0.hasSuffix("|" + old.identifier) }
                log("speech: let go of the \(old.identifier) model to make room for \(l.identifier)")
            }
        }
        if !have.contains(where: { $0.identifier(.bcp47) == l.identifier(.bcp47) }) {
            do {
                if let r = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                    log("speech: downloading the \(l.identifier) model (\(m))")
                    try await r.downloadAndInstall()
                }
            } catch { log("speech: the \(l.identifier) model isn't on this Mac and couldn't be fetched: \(error.localizedDescription)"); return false }
        }
        _ = try? await AssetInventory.reserve(locale: l)
        ready.insert(id)
        return true
    }

    /// Hears 16 kHz mono samples in one language with one module (a custom language model too, when there is one).
    static func hear(_ samples: [Float], _ lang: String, module m: Module, _ l: Locale, lm: Bool = true) async throws -> Hearing {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recense-\(UUID().uuidString).wav")
        try wav(samples, sr: 16000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        let module: any SpeechModule
        let collect: Task<[Phrase], Error>
        var custom = false
        switch m {
        case .speech:
            let t = SpeechTranscriber(locale: l, transcriptionOptions: [], reportingOptions: [.alternativeTranscriptions],
                                      attributeOptions: [.audioTimeRange, .transcriptionConfidence])
            module = t
            collect = Task { var out: [Phrase] = []; for try await r in t.results { out.append(phrase(r.range, r.text, r.alternatives, lang)) }; return out }
        case .open:
            return try await heardOpen(samples, lang)
        case .dictation:
            var hints = Set<DictationTranscriber.ContentHint>()
            if lm, let c = CustomLM.configuration(lang) { hints.insert(.customizedLanguage(modelConfiguration: c)); custom = true }
            let t = DictationTranscriber(locale: l, contentHints: hints, transcriptionOptions: [.punctuation], reportingOptions: [.alternativeTranscriptions],
                                         attributeOptions: [.audioTimeRange, .transcriptionConfidence])
            module = t
            collect = Task { var out: [Phrase] = []; for try await r in t.results { out.append(phrase(r.range, r.text, r.alternatives, lang)) }; return out }
        }
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .utility, modelRetention: .lingering))
        // DictationTranscriber fails with "RecogFailed" on speech in a language not its own (silence comes back
        // empty): it heard nothing it can write, which is an empty hearing, not an error to retry forever.
        func nothing(_ e: Error) -> Bool { let n = e as NSError; return n.domain == "SFSpeechErrorDomain" && n.localizedDescription == "RecogFailed" }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: last) }
            else { await analyzer.cancelAndFinishNow() }
        } catch {
            collect.cancel(); rest()
            if nothing(error) { return Hearing(lang: lang, module: m, phrases: [], lm: custom) }
            throw error
        }
        let phrases: [Phrase]
        do { phrases = try await collect.value } catch { rest(); if nothing(error) { phrases = [] } else { throw error } }
        rest()
        return Hearing(lang: lang, module: m, phrases: tidy(phrases), lm: custom)
    }

    /// A model hearing speech in a language it doesn't know may write one word of its own over all of it ("Bonjour",
    /// timed over a whole English sentence): a word longer than 1.5 s keeps only its last 0.6 s (the rule Recense
    /// already had for Whisper's sung words), and phrases are cut where the voice really stops (a long pause, or a pause after a thought), so what was really heard can
    /// be told from what was skipped, stretch by stretch.
    nonisolated static func tidy(_ phrases: [Phrase]) -> [Phrase] {
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
                // a cut where the voice really stops: 2.5 s of nothing, or a pause after the thought ends. A slow song
                // pauses 0.8 s between its words; cutting there made every word its own line (notes 20261029 item 21)
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

    nonisolated static func phrase(_ range: CMTimeRange, _ text: AttributedString, _ alts: [AttributedString], _ lang: String) -> Phrase {
        var ws: [W] = []
        for run in text.runs {
            let t = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, let r = run.audioTimeRange else { continue }
            ws.append(W(text: t, start: r.start.seconds, end: r.end.seconds, c: run.transcriptionConfidence ?? 1, lang: lang))
        }
        return Phrase(start: range.start.seconds, end: range.end.seconds, text: String(text.characters).trimmingCharacters(in: .whitespaces),
                      alts: alts.map { String($0.characters).trimmingCharacters(in: .whitespaces) }, words: ws)
    }

    /// The models stay warm between requests and are let go after three quiet minutes (the lifecycle the
    /// Translation sessions taught: nothing long-lived that isn't working).
    static var resting: Task<Void, Never>?
    static func rest() {
        resting?.cancel()
        resting = Task { try? await Task.sleep(for: .seconds(180)); guard !Task.isCancelled else { return }; await SpeechModels.endRetention() }
    }

    /// How surely a hearing heard its language: its words' length × confidence, × how much they read as that
    /// language among the candidates (a model hearing another language writes its own words, unsurely).
    static func score(_ h: Hearing, among: [String]) -> Double {
        let ws = h.words
        guard !ws.isEmpty else { return 0 }
        let sure = ws.reduce(0) { $0 + max(0.05, $1.end - $1.start) * $1.c }
        let text = ws.map(\.text).joined(separator: " ")
        var agree = 0.5
        if ws.count >= 3 {
            let r = NLLanguageRecognizer()
            r.languageConstraints = among.map { NLLanguage($0) }
            r.processString(text)
            agree = r.languageHypotheses(withMaximum: among.count)[NLLanguage(h.lang)] ?? 0
        }
        return sure * (0.25 + 0.75 * agree) * (inOwnScript(h) ? 1 : 0.3)
    }
    static func quality(_ h: Hearing) -> Double {
        let ws = h.words, d = ws.reduce(0) { $0 + max(0.05, $1.end - $1.start) }
        return d > 0 ? ws.reduce(0) { $0 + max(0.05, $1.end - $1.start) * $1.c } / d : 0
    }

    /// Two hearings of the same audio in two languages, kept stretch by stretch: where their phrases overlap, the
    /// one that heard it more surely; where only the second heard anything (a model writes nothing for speech in a
    /// language it doesn't know: the English between two French sentences), the second's, when it heard it surely.
    static func merge(_ a: Hearing, _ b: Hearing, among: [String]) -> Hearing {
        var all = a.phrases.map { ($0, 0) } + b.phrases.map { ($0, 1) }
        all.sort { $0.0.start < $1.0.start }
        var out: [Phrase] = [], i = 0
        while i < all.count {
            var end = all[i].0.end, j = i + 1
            while j < all.count && all[j].0.start < end { end = max(end, all[j].0.end); j += 1 }
            let island = all[i..<j]
            let ha = Hearing(lang: a.lang, module: a.module, phrases: island.filter { $0.1 == 0 }.map(\.0))
            let hb = Hearing(lang: b.lang, module: b.module, phrases: island.filter { $0.1 == 1 }.map(\.0))
            if ha.phrases.isEmpty { if quality(hb) >= 0.6 { out += hb.phrases } }
            else if !hb.phrases.isEmpty { out += (score(ha, among: among) >= score(hb, among: among) ? ha : hb).phrases }
            else { out += ha.phrases }
            i = j
        }
        var h = a; h.phrases = out
        return h
    }

    /// Seconds of voice (by loudness, in runs of a second or more) that a hearing wrote no words over.
    static func unheard(_ h: Hearing, _ samples: [Float]) -> Double {
        let db = frameDB(samples), sorted = db.sorted()
        guard sorted.count > 200 else { return 0 }
        let thr = max(sorted[sorted.count / 10] + 12, sorted[sorted.count * 95 / 100] - 30)
        var covered = [Bool](repeating: false, count: db.count)
        for w in h.words {
            let a = max(0, Int((w.start - 0.3) * 100)), b = min(db.count, Int((w.end + 0.3) * 100))
            if a < b { for i in a..<b { covered[i] = true } }
        }
        // voiced: half of the 300 ms around it is loud (as voiceStretches), so the pauses between words don't count
        var loud = 0, total = 0, run = 0
        for i in 0..<min(15, db.count) where db[i] >= thr { loud += 1 }
        for i in db.indices {
            if i + 15 < db.count, db[i + 15] >= thr { loud += 1 }
            if i - 15 >= 0, db[i - 15] >= thr { loud -= 1 }
            if loud >= 15 && !covered[i] { run += 1 } else { if run >= 100 { total += run }; run = 0 }
        }
        if run >= 100 { total += run }
        return Double(total) / 100
    }

    /// One request. Apple's ears hear every language they have (all ~46 on this Mac, asked of the system, none picked
    /// by hand); the open ears (openears.swift) hear the rest and tell which language a recording is in; a recitation
    /// of a text in the canon is written as that text (canon.swift).
    ///   language pinned        Apple's ears if they have it, else the open ears
    ///   language heard last    Apple's again, kept when heard surely; else, as for a new recording:
    ///   new recording          the open ears hear it and name the language; Apple's hear it when they have it (the
    ///                          language heard last beside it, phrase by phrase, for a lesson in two languages), else
    ///                          the open ears' hearing stands. Without the open ears: each language the listener uses,
    ///                          tried, the surest kept (as before).
    static func transcribe(_ samples: [Float], language: String?, languages: [String], prefer: String?) async throws -> [String: Any]? {
        var h: Hearing
        if let language {
            if let (m, loc) = await module(language), await prepare(m, loc) { h = try await hear(samples, language, module: m, loc) }
            else if OpenEars.installed { h = try await heardOpen(samples, language) }
            else { return nil }
        } else if let p = prefer, let (m, loc) = await module(p), await prepare(m, loc),
                  let first = try? await hear(samples, p, module: m, loc),
                  score(first, among: [p]) > 0, !reads(first, otherThan: p),
                  quality(first) >= 0.75 && unheard(first, samples) < 1.5 || !OpenEars.keepsUp {
            // Unsure, or with voice left unheard (a radio show's music bed), the stretch goes to the open ears too, to
            // name its language again: only while they keep up with real time. On an 8 GB M1 they took 1,147 s for
            // 127 s of French Apple had already heard, and the podcast took hours.
            h = first
        } else if OpenEars.installed, let open = try? await heardOpen(samples, nil, like: prefer) {
            h = open
            if let c = anchored(open) {
                h = c
            } else {
                // the language they named, and the listener's own beside it: the open ears name a language by its
                // letters, and a lesson mostly in English, heard by them as Arabic (0.54) or as none, came out empty
                // (notes 20261029 item 33: 100 % of four minutes of English lost, which Apple's English ears hear)
                var cands: [(String, Module, Locale)] = []
                // one spoken language, two written ones: Hindustani heard as Urdu may be Hindi, and the other way round
                let sibling = ["ur": "hi", "hi": "ur"][open.lang]
                for l in [open.lang == "und" ? nil : open.lang, sibling, prefer].compactMap({ $0 }) + languages
                    where !cands.contains(where: { $0.0 == l }) {
                    if let (pm, pl) = await module(l), await prepare(pm, pl) { cands.append((l, pm, pl)) }
                }
                let named = cands.contains { $0.0 == open.lang }
                if !cands.isEmpty, let a = try? await best(samples, cands, prefer: prefer),
                   named || quality(a) >= 0.75 && a.words.count > open.words.count {
                    // a language Apple's ears lack (Amharic) keeps the open ears' hearing, unless one of the listener's
                    // own heard the stretch surely and more of it
                    h = a
                    // Apple's answer in another script than its language's (Urdu written in Latin letters) isn't the
                    // original: the open ears' hearing, in the language's own letters, stands instead
                    if !inOwnScript(h), inOwnScript(open) { h = open }
                    // what Apple's ears left unheard the open ears may have heard (a verse in a language they lack)
                    else if unheard(h, samples) >= 1.5 { h = merge(h, open, among: [h.lang, open.lang]) }
                }
            }
            log("speech: heard as \(h.lang) by \(h.module.rawValue) (open ears named \(open.lang))")
        } else {
            var cands: [(String, Module, Locale)] = []
            for l in [prefer].compactMap({ $0 }) + languages where !cands.contains(where: { $0.0 == l }) {
                if let (m, loc) = await module(l), await prepare(m, loc) { cands.append((l, m, loc)) }
            }
            guard !cands.isEmpty else { return nil }
            h = try await best(samples, cands, prefer: prefer)
        }
        if h.module == .speech { h = await secondOpinion(h, samples) }
        if h.module != .open, Canon.hearAs.contains(h.lang), let c = anchored(h) { h = c }
        return reply(h)
    }

    /// Whether a hearing is written in its language's own script (Urdu in Arabic letters, not Latin).
    static func inOwnScript(_ h: Hearing) -> Bool {
        let text = h.words.map(\.text).joined(separator: " ")
        guard let want = scriptOf(language: h.lang), let got = scriptOf(text: text) else { return true }
        return want == got
    }

    /// Whether a hearing reads as another language than the one it was heard in (Amharic heard by the English model
    /// writes English words, surely enough, but they don't read as English).
    static func reads(_ h: Hearing, otherThan lang: String) -> Bool {
        let text = h.words.map(\.text).joined(separator: " ")
        guard h.words.count >= 6, let (l, p) = dominantLanguage(text), p >= 0.8 else { return false }
        return l != lang && scriptOf(language: l) == scriptOf(language: lang) && spellingTells(lang)
    }

    /// Each candidate on the stretch, the surest kept, and the runner-up beside it phrase by phrase where it heard
    /// nearly as much, or heard what the surest left unheard. A model that hears nothing in its language says so by
    /// failing ("RecogFailed"): that's a score of 0.
    static func best(_ samples: [Float], _ cands: [(String, Module, Locale)], prefer: String?) async throws -> Hearing {
        if cands.count == 1 { return try await hear(samples, cands[0].0, module: cands[0].1, cands[0].2) }
        let among = cands.map(\.0)
        var failure: Error?
        func attempt(_ c: (String, Module, Locale)) async -> Hearing {
            do { return try await hear(samples, c.0, module: c.1, c.2) }
            catch { failure = failure ?? error; return Hearing(lang: c.0, module: c.1, phrases: []) }
        }
        var tried: [(Hearing, Double)] = []
        for c in cands { let x = await attempt(c); tried.append((x, score(x, among: among))) }
        tried.sort { $0.1 > $1.1 }
        log("speech: heard as " + tried.map { String(format: "%@ %.1f (sure %.2f)", $0.0.lang, $0.1, quality($0.0)) }.joined(separator: ", ")
            + String(format: "; %.1f s of voice left unheard by the first", unheard(tried[0].0, samples)))
        if tried[0].1 == 0, let failure { throw failure }
        var h = tried[0].0
        if tried.count > 1, tried[1].1 > 0, tried[1].1 >= 0.7 * tried[0].1 || unheard(tried[0].0, samples) >= 1.5 {
            h = merge(tried[0].0, tried[1].0, among: among)
        }
        return h
    }

    /// The open ears' hearing, in `lang` when it's known, else in the language its words read as ("und": unknown);
    /// `like`: the language the recording was heard in last, whose script it's heard in.
    /// Words of a script written without spaces (Chinese, Japanese, Thai, Lao, Khmer, Burmese, Tibetan) come as one
    /// run per breath; they're cut into words here, each timed by its first letter.
    static func heardOpen(_ samples: [Float], _ lang: String?, like: String? = nil) async throws -> Hearing {
        // A language pinned keeps the model to its script; one heard in the last stretch is only a guess, which the
        // scripts the model writes compete with (a song misheard once must not be kept to the wrong letters). Not the Indic ones: the
        // model writes Sanskrit in Gujarati letters as readily as in Devanagari, and they're the same sounds letter for
        // letter, so they're written over into Devanagari below instead.
        let hint = (lang ?? like).flatMap { scriptOf(language: $0) }.flatMap { indic.keys.contains($0) || $0 == "Deva" || $0 == "CJK" ? nil : $0 }
        var ws = try await OpenEars.hear(samples, script: hint, soft: lang == nil)
        let text = ws.map(\.text).joined(separator: " ")
        let id = lang.map { ($0, 1.0) } ?? Tongue.identify(text)
        let code = id?.0 ?? "und"
        if ["sa", "hi", "mr", "ne", "pi"].contains(code) {
            for i in ws.indices {
                if let sc = scriptOf(text: ws[i].text), let name = indic[sc],
                   let d = ws[i].text.applyingTransform(StringTransform("\(name)-Devanagari"), reverse: false) { ws[i].text = d; ws[i].t = [] }
            }
        }
        var out: [W] = []
        for w in ws {
            guard ["CJK", "Thai", "Laoo", "Khmr", "Mymr", "Tibt"].contains(scriptOf(text: w.text) ?? ""), w.text.count > 1, !w.t.isEmpty else {
                out.append(W(text: w.text, start: w.start, end: w.end, c: w.c, lang: code)); continue
            }
            let tok = NLTokenizer(unit: .word)
            tok.string = w.text
            if code != "und" { tok.setLanguage(NLLanguage(code)) }
            // each word keeps what follows it up to the next (a tsheg, a shad, a Chinese comma): nothing heard is dropped
            var cuts: [(String.Index, Double)] = []
            tok.enumerateTokens(in: w.text.startIndex..<w.text.endIndex) { r, _ in
                let k = w.text.unicodeScalars.distance(from: w.text.unicodeScalars.startIndex, to: r.lowerBound)
                cuts.append((r.lowerBound, w.t[min(k, w.t.count - 1)]))
                return true
            }
            if !cuts.isEmpty { cuts[0].0 = w.text.startIndex }
            var parts: [(String, Double)] = cuts.indices.compactMap { i in
                let t = w.text[cuts[i].0..<(i + 1 < cuts.count ? cuts[i + 1].0 : w.text.endIndex)].trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : (t, cuts[i].1)
            }
            if parts.isEmpty { parts = [(w.text, w.start)] }
            for (i, p) in parts.enumerated() {
                let end = i + 1 < parts.count ? parts[i + 1].1 : w.end
                out.append(W(text: p.0, start: p.1, end: max(end, p.1 + 0.05), c: w.c, lang: code))
            }
        }
        guard let a = out.first, let b = out.last else { return Hearing(lang: code, module: .open, phrases: []) }
        if let id { log(String(format: "speech: open ears read %@ (%.2f)", id.0, id.1)) }
        return Hearing(lang: code, module: .open, phrases: tidy([Phrase(start: a.start, end: b.end, text: text, alts: [], words: out)]))
    }

    static let indic = ["Gujr": "Gujarati", "Beng": "Bengali", "Guru": "Gurmukhi", "Orya": "Oriya", "Telu": "Telugu", "Knda": "Kannada",
                        "Mlym": "Malayalam", "Taml": "Tamil"]

    /// A hearing with the passage it recites (if it recites one from the canon) written as the text has it, its words
    /// timed by the voice, a phrase per line of the text; the rest as heard.
    static func anchored(_ h: Hearing) -> Hearing? {
        let ws = h.words
        guard let m = Canon.match(ws.map { ($0.text, $0.start, $0.end) }) else { return nil }
        var canon: [Phrase] = [], cur: [W] = []
        for (k, i) in (m.from..<m.to).enumerated() {
            if let l = cur.last, m.text.line[i] != m.text.line[i - 1] {
                canon.append(Phrase(start: cur[0].start, end: l.end, text: cur.map(\.text).joined(separator: " "), alts: [], words: cur)); cur = []
            }
            cur.append(W(text: m.text.words[i], start: m.times[k].0, end: m.times[k].1, c: max(0.8, m.identity), lang: m.text.lang))
        }
        if let l = cur.last { canon.append(Phrase(start: cur[0].start, end: l.end, text: cur.map(\.text).joined(separator: " "), alts: [], words: cur)) }
        let a = ws[m.heardFrom].start, b = ws[m.heardTo - 1].end
        var out = h
        out.phrases = h.phrases.compactMap { p -> Phrase? in
            let keep = p.words.filter { $0.end <= a || $0.start >= b }
            guard let f = keep.first, let l = keep.last else { return nil }
            return keep.count == p.words.count ? p : Phrase(start: f.start, end: l.end, text: keep.map(\.text).joined(separator: " "), alts: [], words: keep)
        } + canon
        out.phrases.sort { $0.start < $1.start }
        let canonTime = canon.reduce(0) { $0 + $1.end - $1.start }, all = out.phrases.reduce(0) { $0 + $1.end - $1.start }
        if canonTime >= all / 2 { out.lang = m.text.lang }
        out.canon = m.text.title
        return out
    }

    /// Where SpeechTranscriber was unsure, or wrote a mistake a correction taught (whatever its confidence: a misheard
    /// name can be heard surely), DictationTranscriber with this listener's custom language model listens again; a
    /// taught word it hears there replaces the doubtful ones it overlaps, keeping what they were (`heard`).
    static func secondOpinion(_ h: Hearing, _ samples: [Float]) async -> Hearing {
        guard CustomLM.configuration(h.lang) != nil, let taught = Lexicon.rights(h.lang), !taught.isEmpty else { return h }
        let forms = Lexicon.forms(h.lang)
        func doubtful(_ w: W) -> Bool { w.c < 0.6 || forms[Corrections.fold(w.text)] != nil }
        let unsure = h.words.filter(doubtful)
        guard !unsure.isEmpty else { return h }
        var spans: [(a: Double, b: Double)] = []
        for w in unsure {
            let a = max(0, w.start - 0.6), b = w.end + 0.6
            if let l = spans.last, a <= l.b { spans[spans.count - 1].b = max(l.b, b) } else { spans.append((a, b)) }
        }
        let want = Locale(identifier: ["en": "en-US", "fr": "fr-FR", "vi": "vi-VN"][h.lang] ?? h.lang)
        guard let loc = await DictationTranscriber.supportedLocale(equivalentTo: want), await prepare(.dictation, loc) else { return h }
        var out = h
        for s in spans.prefix(6) {
            let lo = Int(s.a * 16000), hi = min(samples.count, Int(s.b * 16000))
            guard hi - lo > 4000, let d = try? await hear(Array(samples[lo..<hi]), h.lang, module: .dictation, loc) else { continue }
            let heard = d.words.map { W(text: $0.text, start: $0.start + s.a, end: $0.end + s.a, c: $0.c, lang: $0.lang) }
            var found = heard.filter { taught.contains(Corrections.fold($0.text)) }
            guard let first = found.first, let last = found.last else { continue }
            for p in out.phrases.indices {
                let ws = out.phrases[p].words
                let gone = ws.indices.filter { doubtful(ws[$0]) && ws[$0].end > first.start - 0.05 && ws[$0].start < last.end + 0.05 }
                guard let g0 = gone.first, let g1 = gone.last,
                      ws[g0...g1].map({ Corrections.fold($0.text) }) != found.map({ Corrections.fold($0.text) }) else { continue }
                for k in found.indices { found[k].heard = ws[g0...g1].map(\.text).joined(separator: " ") }
                var nw = Array(ws[..<g0]) + found + Array(ws[(g1 + 1)...])
                nw.sort { $0.start < $1.start }
                out.phrases[p].words = nw
                log("speech: second opinion \(ws[g0...g1].map(\.text).joined(separator: " ")) → \(found.map(\.text).joined(separator: " "))")
                out.lm = true
                break
            }
        }
        return out
    }

    /// A hearing as Whisper's verbose_json, times from the samples' start.
    static func reply(_ h: Hearing) -> [String: Any] {
        let ws = h.words
        var by: [String: Double] = [:]
        for w in ws { by[w.lang, default: 0] += w.end - w.start }
        let lang = by.max { $0.value < $1.value }?.key ?? h.lang
        return [
            "text": ws.map(\.text).joined(separator: " "),
            "language": lang,
            "sure": h.canon != nil ? 0.95 : quality(h),     // how surely it heard: low when the language isn't one it knows
            "engine": h.module.rawValue + (h.lm ? "+lm" : "") + (h.canon != nil ? "+canon" : ""),
            "canon": h.canon.map { $0 as Any } ?? NSNull(),
            "segments": h.phrases.map { p -> [String: Any] in
                let d = p.words.reduce(0) { $0 + max(0.05, $1.end - $1.start) }
                let c = d > 0 ? p.words.reduce(0) { $0 + max(0.05, $1.end - $1.start) * $1.c } / d : 1
                return ["start": min(p.start, p.words.first?.start ?? p.start), "end": p.end, "text": p.text,
                        "no_speech_prob": 0.0, "avg_logprob": log(max(0.01, c)), "alternatives": p.alts]
            },
            "words": ws.map { w -> [String: Any] in
                var x: [String: Any] = ["word": w.text, "start": w.start, "end": w.end, "probability": w.c, "lang": w.lang]
                if let h = w.heard { x["heard"] = h }
                return x
            },
        ]
    }
}

// ---------- the listener's own language model ----------
// The lexicon's words and the lines they were corrected in, compiled per language into a custom language model
// that DictationTranscriber hears with (Vietnamese always; English and French in the second opinion). Rebuilt when
// the lexicon changes, a minute after the last lesson. Needs Speech Recognition permission (asked once, the first
// time there's something to build); refused or failing, the lexicon still works on its own.
@available(macOS 26, *)
@MainActor enum CustomLM {
    static var built: [String: Int] = (UserDefaults.standard.dictionary(forKey: "customLM") as? [String: Int]) ?? [:]
    static var pending: Task<Void, Never>?
    static var refused = false

    static func dir(_ lang: String) -> URL { cacheDir.appendingPathComponent("lm/\(lang)", isDirectory: true) }
    static func configuration(_ lang: String) -> SFSpeechLanguageModel.Configuration? {
        let d = dir(lang), lm = d.appendingPathComponent("lm")
        guard built[lang] != nil, FileManager.default.fileExists(atPath: lm.path) else { return nil }
        return SFSpeechLanguageModel.Configuration(languageModel: lm, vocabulary: d.appendingPathComponent("vocab"), weight: 0.6)
    }

    /// Proof that a custom language model can be built here: three phrases, en-US, into lm/_check.
    static func check() async -> String {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return "no Speech Recognition permission" }
        let d = dir("_check"), t0 = Date()
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let data = SFCustomLanguageModelData(locale: Locale(identifier: "en-US"), identifier: "local.recense.recense", version: "check")
        for p in ["I met Kefaya", "Kefaya told me", "Kefaya"] { data.insert(phraseCount: .init(phrase: p, count: 20)) }
        do {
            try await data.export(to: d.appendingPathComponent("data.bin"))
            try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: d.appendingPathComponent("data.bin"), configuration:
                SFSpeechLanguageModel.Configuration(languageModel: d.appendingPathComponent("lm"), vocabulary: d.appendingPathComponent("vocab"), weight: 0.6),
                ignoresCache: true)
            return String(format: "custom language model built in %.1f s", Date().timeIntervalSince(t0))
        } catch { return "custom language model failed: \(error.localizedDescription)" }
    }

    static func soon() {
        pending?.cancel()
        pending = Task { try? await Task.sleep(for: .seconds(60)); guard !Task.isCancelled else { return }; await rebuild() }
    }

    static func rebuild() async {
        guard !refused else { return }
        for lang in Lexicon.languages where built[lang] != Lexicon.version {
            let want = Locale(identifier: ["en": "en-US", "fr": "fr-FR", "vi": "vi-VN"][lang] ?? lang)
            guard let loc = await DictationTranscriber.supportedLocale(equivalentTo: want) else { continue }
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                _ = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                    SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
                }
            }
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
                refused = true; log("speech: no Speech Recognition permission, so no custom language model (the lexicon still applies)"); return
            }
            let data = SFCustomLanguageModelData(locale: loc, identifier: "local.recense.recense", version: "\(Lexicon.version)")
            for (phrase, n) in Lexicon.phrases(lang) { data.insert(phraseCount: .init(phrase: phrase, count: n)) }
            let d = dir(lang)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let asset = d.appendingPathComponent("data.bin")
            do {
                try await data.export(to: asset)
                let c = SFSpeechLanguageModel.Configuration(languageModel: d.appendingPathComponent("lm"), vocabulary: d.appendingPathComponent("vocab"), weight: 0.6)
                try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: asset, configuration: c, ignoresCache: true)
                built[lang] = Lexicon.version
                log("speech: \(lang) custom language model built from \(Lexicon.phrases(lang).count) phrase(s)")
            } catch {
                built[lang] = nil
                log("speech: \(lang) custom language model not built (\(error.localizedDescription)); the lexicon still applies")
            }
            UserDefaults.standard.set(built, forKey: "customLM")
        }
    }
}
#endif

// ---------- the lexicon: what corrections teach the ears ----------
// Every correction teaches, per language: the word (or run of up to three) as the listener wrote it, what the
// recognizer had written there, and how it sounded — a voiceprint of each place it was corrected (the six newest).
// A first transcription, or a replay, writes the corrected word where the recognizer makes that same mistake again
// and the evidence agrees: the same recording; or the recognizer unsure of it (under 0.8) or the sound close to a
// taught one — and never closer to a place it was corrected back. Where the recognizer itself had the taught word
// among its alternatives, that's evidence enough. A word written this way keeps what was heard (`Word.heard`), so
// the window and Gallery can show it, and correcting it back unteaches it. Calibrated on this Mac (2026-10-29):
// the recognizer's confidence on a misheard name was 0.56–0.75 against ~0.99 for ordinary words, while voiceprints of
// one speaker's repeated word only modestly beat other words, so sound vetoes and confirms but never decides alone.
// cacheDir/lexicon.json, mirrored to keep/lexicon.json with the library.
@MainActor enum Lexicon {
    struct Sample: Codable, Equatable { var k: String; var a: Double; var b: Double; var v: String }
    struct Entry: Codable {
        var right: String                  // as the listener wrote it
        var heard: [String: Int] = [:]     // what the recognizer wrote instead (folded words) → how often
        var n = 0                          // corrections
        var last = 0.0                     // the latest (ms)
        var like: [Sample] = []            // how it sounded where it was corrected
        var unlike: [Sample] = []          // where the recognizer had it right after all (corrected back)
        var lines: [String] = []           // the lines it was corrected in: the custom language model's phrases
    }
    struct Book: Codable { var version = 0; var langs: [String: [String: Entry]] = [:] }

    static let url = cacheDir.appendingPathComponent("lexicon.json")
    static var book: Book = (try? JSONDecoder().decode(Book.self, from: Data(contentsOf: url))) ?? Book()
    static var version: Int { book.version }
    static var languages: [String] { book.langs.filter { !$0.value.isEmpty }.map(\.key) }

    static let near: Float = 6.1        // as close as a different word ever came, one speaker (p5)
    static let far: Float = 9.5         // further than three in four different words: not this word

    static func save() {
        book.version += 1
        if let d = try? JSONEncoder().encode(book) { try? d.write(to: url, options: .atomic) }
        index = [:]
        #if compiler(>=6.2)
        if #available(macOS 26, *), OnDeviceASR.enabled { CustomLM.soon() }
        #endif
    }

    /// The taught words of a language, folded.
    static func rights(_ lang: String) -> Set<String>? { book.langs[lang].map { Set($0.values.map { Corrections.fold($0.right) }) } }

    /// The custom language model's training: each taught word, and each line it was corrected in.
    static func phrases(_ lang: String) -> [(String, Int)] {
        var out: [String: Int] = [:]
        for e in (book.langs[lang] ?? [:]).values where e.n > 0 {
            out[e.right, default: 0] += 10 + 5 * e.n
            for l in e.lines { out[l, default: 0] += 2 + e.n }
        }
        return out.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Runs where `from` (the recognizer's words, timed) and `to` (the listener's) differ: up to three words each way.
    nonisolated static func hunks(_ from: [Word], _ to: [String]) -> [(del: [Word], ins: [String])] {
        let fa = from.map { Corrections.fold($0.text) }, fb = to.map(Corrections.fold), m = fa.count, n = fb.count
        var L = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) { L[i][j] = fa[i] == fb[j] ? L[i + 1][j + 1] + 1 : max(L[i + 1][j], L[i][j + 1]) }
        }
        var out: [(del: [Word], ins: [String])] = [], i = 0, j = 0, del: [Word] = [], ins: [String] = []
        func hunk() {
            if !del.isEmpty && !ins.isEmpty && del.count <= 3 && ins.count <= 3 { out.append((del, ins)) }
            del = []; ins = []
        }
        while i < m || j < n {
            if i < m && j < n && fa[i] == fb[j] { hunk(); i += 1; j += 1 }
            else if j < n && (i == m || L[i][j + 1] >= L[i + 1][j]) { ins.append(to[j]); j += 1 }
            else { del.append(from[i]); i += 1 }
        }
        hunk()
        return out
    }

    /// A correction of a line: `from` the words as shown (timed), `to` the listener's. `audio`: the recording's
    /// samples (16 kHz) from `origin`, for the voiceprints. A word the lexicon wrote that's corrected again is
    /// unlearned where it was wrong (its voiceprint kept against it). Returns how many lessons it taught.
    @discardableResult
    static func learn(_ from: [Word], to: [String], lang: String?, key: String, audio: (samples: [Float], origin: Double)?) -> Int {
        guard let lang else { return 0 }
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        let line = to.joined(separator: " ")
        var taught = 0
        var entries = book.langs[lang] ?? [:]
        for (del, ins) in hunks(from, to) {
            let a = del.first!.start, b = del.last!.end
            let v = audio.map { Voiceprint.pack(Voiceprint.of($0.samples, origin: $0.origin, from: a, to: b)) } ?? ""
            let sample = Sample(k: key, a: a, b: b, v: v)
            // corrected back: the lexicon's own word was wrong here
            for w in del where w.heard != nil {
                let f = Corrections.fold(w.text)
                guard var e = entries[f] else { continue }
                if let h = w.heard.map(Corrections.fold), let c = e.heard[h] { e.heard[h] = c > 1 ? c - 1 : nil }
                if !v.isEmpty { e.unlike = Array((e.unlike + [sample]).suffix(6)) }
                entries[f] = e
            }
            let right = ins.map { Corrections.parts($0).1 }.joined(separator: " ")
            let heard = del.map { Corrections.fold($0.heard ?? $0.text) }.joined(separator: " ")
            let f = Corrections.fold(right)
            guard !f.isEmpty, !heard.isEmpty, heard != f, del.allSatisfy({ $0.heard == nil || Corrections.fold($0.heard!) != f }) else { continue }
            var e = entries[f] ?? Entry(right: right)
            e.right = right; e.heard[heard, default: 0] += 1; e.n += 1; e.last = now
            e.like = Array((e.like.filter { !($0.k == key && abs($0.a - a) < 0.3) } + [sample]).suffix(6))
            e.unlike.removeAll { $0.k == key && abs($0.a - a) < 0.3 }
            if !e.lines.contains(line) { e.lines = Array((e.lines + [line]).suffix(6)) }
            entries[f] = e
            taught += 1
            log("lexicon \(lang): \(heard) → \(right)\(v.isEmpty ? "" : " (with its sound)")")
        }
        guard taught > 0 || entries.count != (book.langs[lang]?.count ?? 0) || from.contains(where: { $0.heard != nil }) else { return 0 }
        book.langs[lang] = entries
        save()
        return taught
    }

    /// A correction undone (Reset to Auto): what it taught at that place is forgotten.
    static func forget(key: String, a: Double, b: Double, lang: String?) {
        guard let lang, var entries = book.langs[lang] else { return }
        var changed = false
        for (f, var e) in entries {
            let before = e.like.count
            e.like.removeAll { $0.k == key && $0.a >= a - 0.05 && $0.b <= b + 0.05 }
            guard e.like.count != before else { continue }
            e.n -= before - e.like.count; changed = true
            entries[f] = e.n > 0 ? e : nil
        }
        if changed { book.langs[lang] = entries; save() }
    }

    /// Heard form (folded, first word) → the entries it may stand for, per language.
    static var index: [String: [String: [(f: String, form: [String])]]] = [:]
    static func forms(_ lang: String) -> [String: [(f: String, form: [String])]] {
        if let x = index[lang] { return x }
        var x: [String: [(f: String, form: [String])]] = [:]
        for (f, e) in book.langs[lang] ?? [:] {
            for h in e.heard.keys {
                let ws = h.split(separator: " ").map(String.init)
                if let w = ws.first { x[w, default: []].append((f, ws)) }
            }
        }
        for k in x.keys { x[k]!.sort { $0.form.count > $1.form.count } }
        index[lang] = x
        return x
    }

    /// Whether a lesson's mistake occurs in these words at all (before any audio is decoded for them).
    static func mayApply(_ words: [Word]) -> Bool {
        words.contains { w in w.lang.map { forms($0)[Corrections.fold(w.text)] != nil } ?? false }
    }

    /// One hearing's words (absolute times) with the lessons applied. `samples` (16 kHz) start at `origin`;
    /// `alts`: the recognizer's other readings of each phrase.
    static func recall(_ words: [Word], samples: [Float], origin: Double, key: String, alts: [(a: Double, b: Double, texts: [String])] = []) -> [Word] {
        guard !book.langs.isEmpty, !words.isEmpty else { return words }
        var out: [Word] = [], i = 0
        while i < words.count {
            let w = words[i]
            guard let lang = w.lang, let book = book.langs[lang], let cands = forms(lang)[Corrections.fold(w.text)] else { out.append(w); i += 1; continue }
            var best: (e: Entry, n: Int, d: Float, same: Bool, sure: Double)?
            for (f, form) in cands where i + form.count <= words.count && form.count >= (best?.n ?? 0) {
                let run = Array(words[i..<(i + form.count)])
                guard run.map({ Corrections.fold($0.text) }) == form, let e = book[f] else { continue }
                let a = run.first!.start, b = run.last!.end
                let sure = run.map { $0.c ?? 1 }.reduce(0, +) / Double(run.count)
                let same = e.like.contains { $0.k == key }
                var dLike = Float.infinity, dUnlike = Float.infinity
                if e.like.contains(where: { !$0.v.isEmpty }) || !e.unlike.isEmpty {
                    let r = Voiceprint.of(samples, origin: origin, from: a, to: b, slack: 0.2)
                    if !r.isEmpty {
                        for s in e.like where !s.v.isEmpty { dLike = min(dLike, Voiceprint.search(Voiceprint.unpack(s.v), in: r)) }
                        for s in e.unlike where !s.v.isEmpty { dUnlike = min(dUnlike, Voiceprint.search(Voiceprint.unpack(s.v), in: r)) }
                    }
                }
                let sounded = e.like.allSatisfy { $0.v.isEmpty } || dLike <= far
                guard dUnlike.isInfinite || dLike < dUnlike, same || ((sure < 0.8 || dLike <= near) && sounded) else {
                    log(String(format: "lexicon: %@ left as heard at %@ (not %@: sure %.2f, sound %.1f, unlike %.1f)", run.map(\.text).joined(separator: " "),
                               clock(a), e.right, sure, dLike, dUnlike))
                    continue
                }
                if best == nil || form.count > best!.n || dLike < best!.d { best = (e, form.count, dLike, same, sure) }
            }
            if let b = best {
                let run = Array(words[i..<(i + b.n)])
                out += spread(b.e.right, run.first!.start, run.last!.end, like: run)
                log(String(format: "lexicon: %@ → %@ at %@ (%@, sure %.2f, sound %.1f)", run.map(\.text).joined(separator: " "), b.e.right,
                           clock(run.first!.start), b.same ? "this recording" : "taught elsewhere", b.sure, b.d))
                i += b.n; continue
            }
            out.append(w); i += 1
        }
        return alts.isEmpty ? out : fromAlternatives(out, alts)
    }

    /// Where the recognizer's own alternative reading of a phrase has a taught word the chosen one lacks, that reading
    /// is taken there: the recognizer heard it as possible, the listener said it is.
    static func fromAlternatives(_ words: [Word], _ alts: [(a: Double, b: Double, texts: [String])]) -> [Word] {
        var out = words
        for p in alts where p.texts.count > 1 {
            let idx = out.indices.filter { out[$0].start >= p.a - 0.05 && out[$0].start < p.b && out[$0].heard == nil }
            guard let lang = idx.first.flatMap({ out[$0].lang }), let taught = rights(lang), !taught.isEmpty else { continue }
            let top = idx.map { out[$0] }
            for t in p.texts.dropFirst() {
                let alt = Corrections.words(t)
                for (del, ins) in hunks(top, alt) where taught.contains(Corrections.fold(ins.map { Corrections.parts($0).1 }.joined(separator: " "))) {
                    let a = del.first!.start, b = del.last!.end
                    guard let k = out.firstIndex(where: { $0.start == a }), let l = out.lastIndex(where: { $0.end == b }), k <= l else { continue }
                    let right = ins.map { Corrections.parts($0).1 }.joined(separator: " ")
                    out.replaceSubrange(k...l, with: spread(right, a, b, like: Array(out[k...l])))
                    log("lexicon: \(del.map(\.text).joined(separator: " ")) → \(right) at \(clock(a)) (the recognizer's own alternative)")
                }
                break
            }
        }
        return out
    }

    /// The taught words over the stretch the misheard ones took, each by its length; what was heard kept on them.
    static func spread(_ right: String, _ a: Double, _ b: Double, like run: [Word]) -> [Word] {
        let ws = Corrections.words(right), total = Double(ws.reduce(0) { $0 + max(1, $1.count) })
        let heard = run.map { $0.heard ?? $0.text }.joined(separator: " ")
        let sure = run.compactMap(\.c).min()
        var t = a, out: [Word] = []
        for (k, x) in ws.enumerated() {
            let e = k == ws.count - 1 ? b : t + (b - a) * Double(max(1, x.count)) / total
            var w = Word(text: Corrections.caseLike(run.first!.text, x), start: t, end: e, lang: run.first!.lang)
            w.c = sure; w.heard = heard
            out.append(w); t = e
        }
        return out
    }

    /// keep/'s copy merged in: every entry, its samples by place, the higher counts.
    static func merge(_ d: Data) -> Bool {
        guard let r = try? JSONDecoder().decode(Book.self, from: d) else { return false }
        var changed = false
        for (lang, es) in r.langs {
            var mine = book.langs[lang] ?? [:]
            for (f, x) in es {
                guard var e = mine[f] else { mine[f] = x; changed = true; continue }
                let before = (e.n, e.like.count, e.unlike.count, e.heard)
                e.n = max(e.n, x.n); e.last = max(e.last, x.last)
                for (h, c) in x.heard { e.heard[h] = max(e.heard[h] ?? 0, c) }
                for s in x.like where !e.like.contains(s) { e.like.append(s) }
                for s in x.unlike where !e.unlike.contains(s) { e.unlike.append(s) }
                e.like = Array(e.like.suffix(6)); e.unlike = Array(e.unlike.suffix(6))
                for l in x.lines where !e.lines.contains(l) { e.lines = Array((e.lines + [l]).suffix(6)) }
                if before != (e.n, e.like.count, e.unlike.count, e.heard) { changed = true }
                mine[f] = e
            }
            book.langs[lang] = mine
        }
        if changed { save() }
        return changed
    }
}
