import Foundation
import AVFoundation
import NaturalLanguage

/// Draftpad's page library on the device side (editor/src/libraryui.js is the page side), one copy for the Mac and iOS.
/// · draftpad.playlists.json beside the note: written when the page changes a playlist, sent back to the page on load.
/// · Expired pages (14 days, like a new episode) are appended to "Draftpad expired/<yyyy-MM>.md" in the vault before
///   the page removes them, so nothing is lost: it's plain Markdown, readable in Obsidian, and searchable.
/// · Read-aloud with the spoken word reported back (ReadAloud), for playlists and the Recensed view.
enum DraftpadLibrary {
    static let sidecars: Set<String> = ["playlists", "pages"]

    static func sidecarURL(_ vault: URL, _ name: String) -> URL { vault.appendingPathComponent("draftpad.\(name).json") }

    /// JavaScript calls to run once the page has loaded (each sidecar that exists).
    static func loadCalls(vault: URL?, quote: (String) -> String) -> [String] {
        guard let vault = vault else { return [] }
        return sidecars.sorted().compactMap { name in
            guard let json = coordinatedRead(sidecarURL(vault, name).path), !json.isEmpty else { return nil }
            return "setSidecar(\(quote(name)), \(quote(json)))"
        }
    }

    /// Appends pages to this month's archive, skipping any already there. True when every page is in the archive.
    static func archive(_ pages: [String], vault: URL, now: Date = Date()) -> Bool {
        let dir = vault.appendingPathComponent("Draftpad expired", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return false }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        let url = dir.appendingPathComponent("\(f.string(from: now)).md")
        var text = coordinatedRead(url.path) ?? ""
        let fresh = pages.filter { !$0.isEmpty && !text.contains($0) }
        if fresh.isEmpty { return true }
        f.dateFormat = "yyyy-MM-dd"
        let stamp = f.string(from: now)
        for p in fresh {
            if !text.isEmpty { text += "\n\n<!-- page -->\n\n" }
            text += "<!-- expired \(stamp) -->\n" + p
        }
        return coordinatedWrite(text, to: url.path)
    }

    /// Handles the library's messages from the page's `ui` channel. Returns true when the message was one of them.
    static func handle(_ d: [String: Any], vault: URL?, voice: ReadAloud, js: @escaping (String) -> Void,
                       quote: @escaping (String) -> String) -> Bool {
        if let s = d["sidecar"] as? [String: Any], let name = s["name"] as? String, let json = s["json"] as? String {
            if sidecars.contains(name), let vault = vault { _ = coordinatedWrite(json, to: sidecarURL(vault, name).path) }
            return true
        }
        if let a = d["archivePages"] as? [String: Any], let token = a["token"] as? String {
            let pages = a["pages"] as? [String] ?? []
            let ok = vault.map { archive(pages, vault: $0) } ?? false
            js("pagesArchived(\(quote(token)), \(ok))")
            return true
        }
        if let s = d["speakParts"] as? [String: Any], let id = s["id"] as? String {
            voice.onWord = { id, part, from, len in js("speechProgress(\(quote(id)), \(part), \(from), \(len))") }
            voice.onDone = { id in js("speechDone(\(quote(id)))") }
            voice.speak(id: id, parts: s["parts"] as? [String] ?? [], lang: s["lang"] as? String)
            return true
        }
        if d["speakStop"] as? Bool == true { voice.stop(); return true }
        return false
    }
}

/// Speaks parts in order, each in its own language with the best installed voice, and reports each word as it starts
/// (AVSpeechSynthesizer's willSpeakRange: UTF-16 offsets, the same as JavaScript's string indices).
final class ReadAloud: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var id: String?
    private var index: [ObjectIdentifier: Int] = [:]
    private var remaining = 0
    var onWord: ((String, Int, Int, Int) -> Void)?
    var onDone: ((String) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(id: String, parts: [String], lang: String?) {
        stop()
        self.id = id
        remaining = 0
        for (k, p) in parts.enumerated() where !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let u = AVSpeechUtterance(string: p)
            u.rate = AVSpeechUtteranceDefaultSpeechRate
            u.voice = ReadAloud.bestVoice(for: p, lang: lang)
            index[ObjectIdentifier(u)] = k
            remaining += 1
            synth.speak(u)
        }
        if remaining == 0 { finish() }
    }

    func stop() {
        guard id != nil else { return }
        synth.stopSpeaking(at: .immediate)
        finish()
    }

    private func finish() {
        guard let id = id else { return }
        self.id = nil
        index.removeAll()
        onDone?(id)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance u: AVSpeechUtterance) {
        guard let id = id, let k = index[ObjectIdentifier(u)] else { return }
        onWord?(id, k, r.location, r.length)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        guard id != nil, index.removeValue(forKey: ObjectIdentifier(u)) != nil else { return }
        remaining -= 1
        if remaining <= 0 { finish() }
    }

    static func bestVoice(for text: String, lang: String?) -> AVSpeechSynthesisVoice? {
        var code = lang
        if code == nil {
            let r = NLLanguageRecognizer()
            r.processString(text)
            code = r.dominantLanguage?.rawValue
        }
        guard let code = code else { return nil }
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(code) }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: code)
    }
}
