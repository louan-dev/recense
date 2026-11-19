// Derived from Spec: FEAT-23 P0 / P0c
// One note per media item: keep/<key>/note.md, with note.ink.json and note.matter.json beside it. These are the files
// only, one copy for the Mac (strip/editorhost.swift) and iPhone/iPad (mobile/HostApp/iOS/Draftpad.swift). Every rule
// of the note (when it is first written, when it empties, moment links, line notes) lives in editor/src/medianote.js;
// the page posts { action, key, … } on its `note` channel and this does what it says. Never draftpad.md, never media.
// Carry brings note.md from other devices (main 8935ad0, 762b638): a write never goes blind over a note.md that changed
// since the page saw it; the page's text goes beside it as carry's conflict sibling instead (review 2, items 1-2).
import Foundation
import CryptoKit

enum MediaNoteFiles {
    static let text = "note.md", ink = "note.ink.json", matter = "note.matter.json"
    static let names = [text, ink, matter]

    /// A key is exactly 24 lowercase hex characters (ContentKey, ShowsKit Model.swift).
    static func isKey(_ k: String) -> Bool { k.wholeMatch(of: #/[0-9a-f]{24}/#) != nil }

    static func url(_ key: String, _ name: String, keep: URL) -> URL {
        keep.appendingPathComponent(key, isDirectory: true).appendingPathComponent(name)
    }

    // FEAT-23 review-2 item 1: the text the page opened each note.md with, or last wrote to it, by path (this process).
    private static let lock = NSLock()
    private static var seen: [String: String] = [:]
    /// Item 2: the sibling an open note's text went to after a conflict, so later autosaves update it, not make more.
    private static var sideCopy: [String: URL] = [:]
    static func sibling(_ path: String) -> URL? { lock.lock(); defer { lock.unlock() }; return sideCopy[path] }
    static func setSibling(_ path: String, _ u: URL?) { lock.lock(); sideCopy[path] = u; lock.unlock() }
    static func seenText(_ path: String) -> String? { lock.lock(); defer { lock.unlock() }; return seen[path] }
    static func see(_ path: String, _ s: String?) { lock.lock(); seen[path] = s; sideCopy[path] = nil; lock.unlock() }

    /// A short digest of a text, for a parked file's name (the note it was written over).
    static func digest(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() }

    /// What a page's text is written over: the note it saw, that note's digest (a parked save), or nothing known.
    enum Base {
        case text(String), digest(String), unknown
        func matches(_ t: String) -> Bool {
            switch self { case .text(let b): return b == t; case .digest(let h): return MediaNoteFiles.digest(t) == h; case .unknown: return false }
        }
        var tag: String {
            switch self { case .text(let b): return MediaNoteFiles.digest(b); case .digest(let h): return h; case .unknown: return "x" }
        }
    }

    /// Writes `mine` to note.md only when note.md is missing, already holds it, or still holds what `base` names. Otherwise
    /// note.md changed under the page (carry, an append) and `mine` goes beside it as carry's conflict sibling
    /// (`note (<device> <date>).md`, conflictSiblingPath): neither text is overwritten. "wrote…"/"kept beside…" on success.
    /// `into`: this page's sibling from an earlier conflict, written again instead of a new one.
    static func place(_ mine: String, key: String, keep: URL, base: Base, device: String, into: URL? = nil) -> String {
        let note = url(key, text, keep: keep)
        try? FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch readNote(note.path) {
        case .unreadable: return "could not read \(text)"
        case .text(let t) where t != mine && !base.matches(t):
            let sib = into.map(\.path).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? freeSiblingPath(note.path, Date(), device: device)
            guard coordinatedWrite(mine, to: sib) else { return "could not write a sibling" }
            setSibling(note.path, URL(fileURLWithPath: sib))
            return "kept beside \(text) as \((sib as NSString).lastPathComponent)"
        default:
            guard coordinatedWrite(mine, to: note.path) else { return "could not write \(text)" }
            see(note.path, mine)
            return "wrote \(text)"
        }
    }

    /// What the page opens (`recenseEditor.openNote(key, <this>)`): { text, ink, matter, title, trigger, layout }.
    /// nil when a file is there but cannot be read now: a note is never shown blank over its words (T-0114's rule).
    static func payload(key: String, keep: URL, title: String = "", trigger: String = "note-button", layout: String = "note") -> String? {
        guard isKey(key) else { return nil }
        var d: [String: Any] = ["title": title, "trigger": trigger, "layout": layout]
        for (field, name) in [("text", text), ("ink", ink), ("matter", matter)] {
            switch readNote(url(key, name, keep: keep).path) {
            case .text(let s): d[field] = s
            case .missing: d[field] = ""
            case .unreadable: return nil
            }
        }
        see(url(key, text, keep: keep).path, d["text"] as? String)
        guard let data = try? JSONSerialization.data(withJSONObject: d), let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Moves one file to the Trash (Put Back works); where the system has no Trash (iOS), into `fallback` instead.
    /// Never deletes. False when it could not be moved (the file stays where it was).
    static func trash(_ file: URL, fallback: URL?) -> Bool {
        let fm = FileManager.default
        if (try? fm.trashItem(at: file, resultingItemURL: nil)) != nil { return true }
        guard let fallback else { return false }
        let key = file.deletingLastPathComponent().lastPathComponent
        let dir = fallback.appendingPathComponent("notes", isDirectory: true).appendingPathComponent(key, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent(file.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(file.lastPathComponent)")
        }
        return (try? fm.moveItem(at: file, to: dest)) != nil
    }

    // FEAT-23 review 2 · a note's words that could not reach keep/ wait in the Unsaved folder (shared/notesync.swift's
    // Unsaved.keep), one file per failure: "note-unsaved <ms> <action> <key> <base>.md". `retry` (the hosts' poll) writes them
    // once it can, then settles them into recovered/. Never deleted. Not "draftpad-unsaved", so never joined into draftpad.md.
    // A save's name ends with the digest of the note it was written over ("x": not known), so the retry never writes over
    // a note that changed since (review-2 item 1).
    /// Oldest first by the time in the name, whatever the action (review-2 item 3: a later line note never replays
    /// before an earlier save).
    static func pending(_ unsaved: URL) -> [URL] {
        let all: [URL] = (try? FileManager.default.contentsOfDirectory(at: unsaved, includingPropertiesForKeys: nil)) ?? []
        var dated: [(file: URL, ms: Int)] = []
        for f in all where f.lastPathComponent.hasPrefix("note-unsaved ") && f.pathExtension == "md" {
            if let p = parked(f) { dated.append((f, p.ms)) }
        }
        dated.sort { $0.ms != $1.ms ? $0.ms < $1.ms : $0.file.lastPathComponent < $1.file.lastPathComponent }
        return dated.map(\.file)
    }

    /// A parked file's name, read by what each part is, so an earlier layout ("<action> <key> <ms>") still reads.
    static func parked(_ f: URL) -> (ms: Int, action: String, key: String, base: String?)? {
        let parts = f.deletingPathExtension().lastPathComponent.split(separator: " ").map(String.init).dropFirst()
        guard let key = parts.first(where: isKey), let action = parts.first(where: { ["save", "append", "ink", "matter"].contains($0) }),
              let ms = parts.first(where: { !isKey($0) && !$0.isEmpty && $0.allSatisfy(\.isNumber) }).flatMap({ Int($0) }) else { return nil }
        let base = parts.first { $0.count == 16 && !isKey($0) && $0.allSatisfy(\.isHexDigit) }
        return (ms, action, key, base)
    }

    private static func park(_ text: String, action: String, key: String, base: String = "x", unsaved: URL?) -> String {
        guard let unsaved else { return "could not write; nowhere to keep it" }
        let f = unsaved.appendingPathComponent("note-unsaved \(Int(Date().timeIntervalSince1970 * 1000)) \(action) \(key) \(base).md")
        Unsaved.keep(text, as: f)
        return FileManager.default.fileExists(atPath: f.path) ? "could not write; kept in \(f.lastPathComponent)" : "could not write or keep"
    }

    /// The hosts' poll: each parked text, oldest first, written now if it can be. A save parked before a newer save
    /// that succeeded is stale (the newer text holds it) and is settled without writing. A parked save goes through
    /// `place`: never over a note.md that changed since it was parked (review-2 item 1).
    @discardableResult
    static func retry(keep: URL, unsaved: URL, device: String = "this device") -> Int {
        var done = 0
        let all = pending(unsaved)
        for (i, f) in all.enumerated() {
            guard let p = parked(f), let body = try? String(contentsOf: f, encoding: .utf8) else { continue }
            // item 4: a parked ink or matter state with a newer one parked after it is stale; the newer one is written
            if p.action == "ink" || p.action == "matter",
               all[(i + 1)...].contains(where: { parked($0).map { $0.action == p.action && $0.key == p.key } == true }) {
                Unsaved.settle(f, in: unsaved); done += 1; continue
            }
            let r: String
            switch p.action {
            case "append": r = handle(["action": "append", "key": p.key, "line": body], keep: keep, unsaved: nil)
            case "save": r = place(body, key: p.key, keep: keep, base: p.base.map { .digest($0) } ?? .unknown, device: device)
            case "ink", "matter": r = handle(["action": p.action, "key": p.key, "json": body], keep: keep, unsaved: nil)
            default: continue
            }
            if r.hasPrefix("wrote") || r.hasPrefix("kept beside") { Unsaved.settle(f, in: unsaved); done += 1 }
        }
        return done
    }

    /// One `note` message from the page. Returns what happened, for the log ("" when the message was not one).
    @discardableResult
    static func handle(_ d: [String: Any], keep: URL, trashFallback: URL? = nil, unsaved: URL? = nil, device: String = "this device",
                       trashFile: (URL, URL?) -> Bool = MediaNoteFiles.trash) -> String {
        guard let action = d["action"] as? String, let key = d["key"] as? String, isKey(key) else { return "" }
        let fm = FileManager.default
        let folder = keep.appendingPathComponent(key, isDirectory: true)
        func write(_ s: String, _ name: String) -> String {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            return coordinatedWrite(s, to: url(key, name, keep: keep).path) ? "wrote \(name)" : "could not write \(name)"
        }
        switch action {
        case "save":   // item 2: never blind; over note.md only while it still holds what the page saw
            guard let s = d["text"] as? String else { return "" }
            let notePath = url(key, text, keep: keep).path
            let base: Base = seenText(notePath).map { .text($0) } ?? .unknown
            let r = place(s, key: key, keep: keep, base: base, device: device, into: sibling(notePath))
            guard r.hasPrefix("wrote") || r.hasPrefix("kept beside") else {
                return park(s, action: "save", key: key, base: base.tag, unsaved: unsaved)
            }
            if let unsaved {   // this newer text holds any parked save of this note
                for f in pending(unsaved) where parked(f).map({ $0.action == "save" && $0.key == key }) == true { Unsaved.settle(f, in: unsaved) }
            }
            return r
        case "ink", "matter":   // item 4: strokes and note times are parked like words; the newest one wins
            guard let s = d["json"] as? String else { return "" }
            let r = write(s, action == "ink" ? ink : matter)
            guard r.hasPrefix("wrote") else { return park(s, action: action, key: key, unsaved: unsaved) }
            if let unsaved {   // this newer state holds any parked one
                for f in pending(unsaved) where parked(f).map({ $0.action == action && $0.key == key }) == true { Unsaved.settle(f, in: unsaved) }
            }
            return r
        case "append":   // A1 rule 9: a transcript line's note, the note not open in the page
            guard let line = d["line"] as? String, !line.isEmpty else { return "" }
            let r: String
            switch readNote(url(key, text, keep: keep).path) {
            case .unreadable: r = "could not read note.md"
            case .missing: r = write(line + "\n", text)
            case .text(let s): r = write(s + (s.isEmpty || s.hasSuffix("\n") ? "" : "\n") + line + "\n", text)
            }
            return r.hasPrefix("wrote") ? r : park(line, action: "append", key: key, unsaved: unsaved)
        case "trash":   // A1 rule 3: emptied, focus gone: the three files to the Trash; the media is never touched
            var moved = 0
            for name in names {
                let f = url(key, name, keep: keep)
                // item 2: a note.md with words the page never saw (carried in since it opened) is not the page's to empty
                if name == text, case .text(let t) = readNote(f.path), t.contains(where: { !$0.isWhitespace }), seenText(f.path) != t { continue }
                if fm.fileExists(atPath: f.path), trashFile(f, trashFallback) { moved += 1 }
                if name == text { see(f.path, nil) }
            }
            if let left = try? fm.contentsOfDirectory(atPath: folder.path), left.isEmpty { try? fm.removeItem(at: folder) }
            return "trashed \(moved)"
        default:
            return ""
        }
    }
}
