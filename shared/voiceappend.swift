import Foundation

// Derived from Spec: FEAT-08 (P2, voice continuation from any device and while moving)
// A spoken passage lands at the end of draftpad.md as its own passage, from anywhere: the Lock Screen, the Action button,
// a Mac menu, with no editor open. The write goes through planBlindSave (shared/notesync.swift), the rule that never
// writes over a note this device could not read; an open editor then folds it in with its 3-way merge (planNoteSave).
// Its passage (seed: device, input "voice", time) goes into draftpad.matter.json beside the note, so it keeps where it began.

enum VoiceAppend {
    /// What to add after the note so the spoken text becomes its own passage (one blank line before it).
    static func mine(_ text: String, after note: NoteRead) -> String {
        guard case .text(let t) = note, !t.isEmpty else { return text }
        if t.hasSuffix("\n\n") { return text }
        return "\n" + text   // after "note\n" gives one blank line; after "note", planBlindSave adds the other "\n"
    }

    /// The plan for adding `text` to the note as it is now. `.wait`: the note could not be read; keep the text elsewhere.
    static func plan(_ text: String, now: NoteRead) -> BlindSave {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if spoken.isEmpty { if case .text(let t) = now { return .recovered(seen: t, joined: t) }; return .recovered(seen: "", joined: "") }
        return planBlindSave(mine: mine(spoken, after: now), now: now)
    }

    /// draftpad.matter.json (editor/src/matter.js) with one more passage for the spoken words: born as voice, seeded
    /// (device, input "voice", time), its voice form already typed into the body, so "Make text" never types it twice.
    /// Every passage and log entry already there stays (JSON round trip). A broken sidecar starts fresh.
    static func addPassage(to json: String?, text: String, body: String, device: String, at t: Date,
                           id: String = UUID().uuidString) -> String {
        var root: [String: Any] = ["version": 1, "passages": [String: Any](), "log": [Any]()]
        if let json = json, let d = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any], obj["passages"] is [String: Any] { root = obj }
        var passages = root["passages"] as? [String: Any] ?? [:]
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = Int(t.timeIntervalSince1970 * 1000)
        let seed: [String: Any] = ["device": device, "input": "voice", "time": time]
        var from = seed; from["cross"] = 0
        let words = spoken.split(whereSeparator: { $0.isWhitespace }).map { ["w": String($0)] }
        var voice: [String: Any] = ["spoken": [Any](), "from": from]
        var entry: [String: Any] = ["words": words, "at": time, "from": from]
        var type: [String: Any] = ["from": from]
        if let q = quote(spoken, endingAt: body) {   // the words sit at the end of the body (planBlindSave put them there)
            entry["typed"] = q
            type.merge(q) { a, _ in a }
        }
        voice["spoken"] = [entry]
        var forms: [String: Any] = ["voice": voice]
        if type["quote"] != nil { forms["type"] = type }
        let pid = "vo-" + id.lowercased()
        passages[pid] = ["id": pid, "born": "voice", "seed": seed, "phase": "voice", "forms": forms]
        root["passages"] = passages
        if root["log"] == nil { root["log"] = [Any]() }
        if root["version"] == nil { root["version"] = 1 }
        let out = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
        return String(data: out, encoding: .utf8) ?? json ?? ""
    }

    /// matter.js makeQuote for words at the very end of `body`: the quote and 32 UTF-16 units of context before it.
    static func quote(_ words: String, endingAt body: String) -> [String: String]? {
        let b = Array(body.utf16), w = Array(words.utf16)
        guard !w.isEmpty, b.count >= w.count, Array(b[(b.count - w.count)...]) == w else { return nil }
        let off = b.count - w.count
        let pre = String(utf16CodeUnits: Array(b[max(0, off - 32)..<off]), count: min(32, off))
        return ["quote": words, "prefix": pre, "suffix": ""]
    }

    /// True when `json` is a matter sidecar this code can add a passage to (an object with a `passages` object).
    static func sidecarParses(_ json: String?) -> Bool {
        guard let json = json, let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return obj["passages"] is [String: Any]
    }

    enum Outcome: Equatable { case added(String), kept(URL), nothing }

    /// Adds the spoken `text` to the note in `vault`. If the note cannot be read now (iCloud mid-sync, evicted offline),
    /// the text is kept in `unsavedDir` (Unsaved, T-0114) and joins the note at the next launch: nothing is lost.
    @discardableResult
    static func append(_ text: String, vault: URL, device: String, unsavedDir: URL, now: Date = Date()) -> Outcome {
        let note = vault.appendingPathComponent("draftpad.md").path
        let read = readNote(note)
        switch plan(text, now: read) {
        case .wait:
            let f = Unsaved.file(in: unsavedDir, launch: now)
            let prior = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            Unsaved.keep(prior + "\n" + text, as: f)   // the leading "\n" keeps it its own passage when Unsaved.join adds it
            return .kept(f)
        case .recovered(let seen, let joined):
            if joined == seen { return .nothing }
            guard coordinatedWrite(joined, to: note) else {
                let f = Unsaved.file(in: unsavedDir, launch: now)
                let prior = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
                Unsaved.keep(prior + "\n" + text, as: f)
                return .kept(f)
            }
            let side = vault.appendingPathComponent("draftpad.matter.json").path   // beside draftpad.md (FEAT-08)
            let prior = coordinatedRead(side)
            // A sidecar that exists but cannot be read or parsed right now (iCloud evicted, truncated) is never replaced by a
            // one-passage file: it holds every passage's seed and the crossings log. The words are already in the note.
            if FileManager.default.fileExists(atPath: side) && !sidecarParses(prior) { return .added(joined) }
            _ = coordinatedWrite(addPassage(to: prior, text: text, body: joined, device: device, at: now), to: side)
            return .added(joined)
        }
    }
}

/// FEAT-08 · the page's draftpad.matter.json against the file on disk. Another writer (AddToDraftpadIntent, another
/// device) changed the file since this host last saw it: hand that file to the page first (mergeMatter unions every
/// passage), then write the union. Otherwise write. Never writes over a passage the page has not seen.
enum MatterWrite: Equatable {
    case write, mergeFirst(String)
    static func plan(json: String, disk: String?, seen: String?) -> MatterWrite {
        guard let disk = disk, !disk.isEmpty, disk != json, disk != seen else { return .write }
        return .mergeFirst(disk)
    }
}
