// Derived from Spec: FEAT-23 P0 / P0c
// One note per media item: keep/<key>/note.md, with note.ink.json and note.matter.json beside it. These are the files
// only, one copy for the Mac (strip/editorhost.swift) and iPhone/iPad (mobile/HostApp/iOS/Draftpad.swift). Every rule
// of the note (when it is first written, when it empties, moment links, line notes) lives in editor/src/medianote.js;
// the page posts { action, key, … } on its `note` channel and this does what it says. Never draftpad.md, never media.
// Single device (A3): keep/ is not carried; nothing here merges with another device.
import Foundation

enum MediaNoteFiles {
    static let text = "note.md", ink = "note.ink.json", matter = "note.matter.json"
    static let names = [text, ink, matter]

    /// A key is exactly 24 lowercase hex characters (ContentKey, ShowsKit Model.swift).
    static func isKey(_ k: String) -> Bool { k.wholeMatch(of: #/[0-9a-f]{24}/#) != nil }

    static func url(_ key: String, _ name: String, keep: URL) -> URL {
        keep.appendingPathComponent(key, isDirectory: true).appendingPathComponent(name)
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
    // Unsaved.keep), one file per failure: "note-unsaved <action> <key> <ms>.md". `retry` (the hosts' poll) writes them
    // once it can, then settles them into recovered/. Never deleted. Not "draftpad-unsaved", so never joined into draftpad.md.
    static func pending(_ unsaved: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: unsaved, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("note-unsaved ") && $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func park(_ text: String, action: String, key: String, unsaved: URL?) -> String {
        guard let unsaved else { return "could not write; nowhere to keep it" }
        let f = unsaved.appendingPathComponent("note-unsaved \(action) \(key) \(Int(Date().timeIntervalSince1970 * 1000)).md")
        Unsaved.keep(text, as: f)
        return FileManager.default.fileExists(atPath: f.path) ? "could not write; kept in \(f.lastPathComponent)" : "could not write or keep"
    }

    /// The hosts' poll: each parked text, oldest first, written now if it can be. A save parked before a newer save
    /// that succeeded is stale (the newer text holds it) and is settled without writing.
    @discardableResult
    static func retry(keep: URL, unsaved: URL) -> Int {
        var done = 0
        for f in pending(unsaved) {
            let parts = f.deletingPathExtension().lastPathComponent.split(separator: " ").map(String.init)
            guard parts.count == 4, isKey(parts[2]), let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let d: [String: Any] = parts[1] == "append" ? ["action": "append", "key": parts[2], "line": text]
                : ["action": "save", "key": parts[2], "text": text]
            if handle(d, keep: keep, unsaved: nil).hasPrefix("wrote") { Unsaved.settle(f, in: unsaved); done += 1 }
        }
        return done
    }

    /// One `note` message from the page. Returns what happened, for the log ("" when the message was not one).
    @discardableResult
    static func handle(_ d: [String: Any], keep: URL, trashFallback: URL? = nil, unsaved: URL? = nil,
                       trashFile: (URL, URL?) -> Bool = MediaNoteFiles.trash) -> String {
        guard let action = d["action"] as? String, let key = d["key"] as? String, isKey(key) else { return "" }
        let fm = FileManager.default
        let folder = keep.appendingPathComponent(key, isDirectory: true)
        func write(_ s: String, _ name: String) -> String {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            return coordinatedWrite(s, to: url(key, name, keep: keep).path) ? "wrote \(name)" : "could not write \(name)"
        }
        switch action {
        case "save":
            guard let s = d["text"] as? String else { return "" }
            let r = write(s, text)
            guard r.hasPrefix("wrote") else { return park(s, action: "save", key: key, unsaved: unsaved) }
            if let unsaved {   // this newer text holds any parked save of this note
                for f in pending(unsaved) where f.lastPathComponent.hasPrefix("note-unsaved save \(key) ") { Unsaved.settle(f, in: unsaved) }
            }
            return r
        case "ink":
            guard let s = d["json"] as? String else { return "" }
            return write(s, ink)
        case "matter":
            guard let s = d["json"] as? String else { return "" }
            return write(s, matter)
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
                if fm.fileExists(atPath: f.path), trashFile(f, trashFallback) { moved += 1 }
            }
            if let left = try? fm.contentsOfDirectory(atPath: folder.path), left.isEmpty { try? fm.removeItem(at: folder) }
            return "trashed \(moved)"
        default:
            return ""
        }
    }
}
