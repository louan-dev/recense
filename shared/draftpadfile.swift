// Derived from Spec: BUG-29
import Foundation

// Draftpad's load and save, the one copy the Mac (strip/app.swift, strip/editorhost.swift) and the iPhone and iPad
// (mobile/HostApp/iOS/Draftpad.swift) both use. The rules are notesync.swift's: readNote, planBlindSave, planNoteSave,
// Unsaved, freeSiblingPath. A note or ink sidecar that could not be read is never written over, a failed write never
// moves the base, and ink this host has not seen is merged first.

/// draftpad.md: what this device last read or wrote (the merge's base), and whether a save is owed.
final class DraftpadNote {
    let path: String
    let unsavedDir: URL
    private let launch: Date
    private let read: (String) -> NoteRead
    private let write: (String, String) -> Bool
    private(set) var base = ""          // what this device last read or wrote: the merge's base
    private(set) var readable = true    // false: the note existed but could not be read at load (T-0114); nothing is saved over it
    private(set) var pending = false    // a save could not reach the file; the host's poll tries again
    /// Where each line of the log goes (the host's own log).
    var say: (String) -> Void = { _ in }

    /// Typed text that could not reach the note waits here, one file per launch (Unsaved).
    static var unsavedFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Recense", isDirectory: true)
    }

    init(path: String, unsavedDir: URL = DraftpadNote.unsavedFolder, launch: Date = Date(),
         read: @escaping (String) -> NoteRead = { readNote($0) },
         write: @escaping (String, String) -> Bool = { coordinatedWrite($0, to: $1) }) {
        self.path = path; self.unsavedDir = unsavedDir; self.launch = launch; self.read = read; self.write = write
    }

    private var launchFile: URL { Unsaved.file(in: unsavedDir, launch: launch) }
    private func keepSafe(_ text: String) { if !text.isEmpty { Unsaved.keep(text, as: launchFile) } }
    private func settleLaunch() { Unsaved.settle(launchFile, in: unsavedDir) }   // its text reached the note

    /// The file as it is now; it becomes the base. A note that exists but cannot be read now (iCloud offline, a sync
    /// mid-replace) is not a blank note (T-0114): the editor starts empty, nothing is saved over the note, and the first
    /// save after it can be read joins what was typed to it.
    func load() -> String {
        switch read(path) {
        case .text(let s): base = s; readable = true; return joinKept(note: s)
        case .missing: base = ""; readable = true; return joinKept(note: "")
        case .unreadable:
            base = ""; readable = false
            say("the note can't be read now (iCloud offline?); nothing is saved over it until it can be")
            return ""
        }
    }

    /// The note with the text kept by earlier failed saves added after it, written to the note; else the note as it is.
    private func joinKept(note s: String) -> String {
        guard let joined = Unsaved.recover(note: s, in: unsavedDir, write: { self.write($0, self.path) }) else { return s }
        base = joined
        say("text typed while the note could not be saved was added after it")
        return joined
    }

    /// Saves `mine`, merging any edit that reached the file meanwhile (the file is read on every save). Returns the text
    /// the editor should show when that differs from `mine` (a merge, or a newer file adopted), else nil.
    func save(_ mine: String) -> String? {
        if !readable {
            switch planBlindSave(mine: mine, now: read(path)) {
            case .wait:
                keepSafe(mine); pending = true
                return nil
            case .recovered(let seen, let joined):
                if joined != seen, !write(joined, path) { keepSafe(mine); pending = true; return nil }
                settleLaunch()   // this launch's typed text is in the note now
                base = joined; readable = true; pending = false
                say("the note can be read again; what was typed meanwhile was added after it")
                let shown = joinKept(note: joined)   // and any earlier launch's
                return shown == mine ? nil : shown
            }
        }
        let theirs: String?
        switch read(path) {
        case .text(let t): theirs = t == base ? nil : t
        case .missing: theirs = nil
        case .unreadable: keepSafe(mine); pending = true; return nil
        }
        switch planNoteSave(base: base, mine: mine, theirs: theirs) {
        case .write(let t):
            // the base moves only once the file really holds the text; a failed write leaves the base as it was, so the
            // next poll does not read the old file as "theirs" and put it over the edit (T-0114)
            if t != (theirs ?? base), !write(t, path) { keepSafe(mine); pending = true; return nil }
            base = t; pending = false; settleLaunch()
            if t != mine { say("merged an edit from another device") }
            return t == mine ? nil : t
        case .adopt(let t):
            base = t; pending = false
            return t
        case .conflict(let m, let other):
            // theirs goes beside the note first, under a name no file has (T-0127): only once it is safe is the note replaced
            let sib = freeSiblingPath(path)
            guard write(other, sib), write(m, path) else { keepSafe(mine); pending = true; return nil }
            base = m; pending = false; settleLaunch()
            say("the same lines changed here and on another device; theirs kept in \((sib as NSString).lastPathComponent)")
            return nil
        }
    }
}

/// draftpad.ink.json (T-0125). The page posts its whole ink document; the union of strokes by id is the page's own
/// (editor/src/ink.js mergeInkDocuments, called as `mergeInk`), so a host hands it the file and saves what it returns.
final class DraftpadInk {
    enum Plan: Equatable {
        case write                 // nothing on disk this host hasn't seen: write the post
        case mergeFirst(String)    // the file holds strokes not seen here: merge it into the page, then save the union
        case wait                  // the file can't be read now: write nothing over it, try again later
    }

    /// What one post should do. `seen` is the file as this host last read or wrote it; nil = never read.
    static func plan(json: String, disk: NoteRead, seen: String?) -> Plan {
        switch disk {
        case .unreadable: return .wait
        case .missing: return .write
        case .text(let d): return d.isEmpty || d == json || d == seen ? .write : .mergeFirst(d)
        }
    }

    /// The page's merged ink (a JS object, or already a string) as JSON text.
    static func json(from v: Any?) -> String? {
        if let s = v as? String { return s }
        guard let v = v, JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    let path: String
    private let read: (String) -> NoteRead
    private let write: (String, String) -> Bool
    private(set) var seen: String?      // the file as this host last read or wrote it; nil: never read (unreadable at load)
    private(set) var waiting: String?   // a post not yet written (the file was unreadable, or the write failed)

    init(path: String, read: @escaping (String) -> NoteRead = { readNote($0) },
         write: @escaping (String, String) -> Bool = { coordinatedWrite($0, to: $1) }) {
        self.path = path; self.read = read; self.write = write
    }

    /// The sidecar for the page's setInk: its text ("" when there is none yet), or nil when it can't be read now; then
    /// nothing is treated as seen and the first post merges whatever the file holds by then.
    func load() -> String? {
        switch read(path) {
        case .text(let s): seen = s; return s
        case .missing: seen = ""; return ""
        case .unreadable: seen = nil; return nil
        }
    }

    /// The file was merged into the page (the poll found another device's strokes): a post of the union may be written.
    func saw(_ disk: String) { seen = disk }

    /// A merge handed to the page did not come back (page not loaded, no ink layer, the call failed): the file was not
    /// merged after all, so nothing counts as seen and the next post merges it again instead of writing over it.
    func unsee() { seen = nil }

    /// One post from the page. `.mergeFirst(disk)`: the host calls the page's mergeInk(disk) and saves the result.
    @discardableResult
    func save(_ json: String) -> Plan {
        let plan = Self.plan(json: json, disk: read(path), seen: seen)
        switch plan {
        case .wait:
            waiting = json
        case .mergeFirst(let d):
            seen = d; waiting = nil   // the page's union replaces this post
        case .write:
            if json == seen { waiting = nil; break }
            if write(json, path) { seen = json; waiting = nil } else { waiting = json; return .wait }
        }
        return plan
    }

    /// The post that is still waiting, tried again (the host's poll). nil: nothing waiting.
    @discardableResult
    func retry() -> Plan? { waiting.map { save($0) } }
}
