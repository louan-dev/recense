import Foundation

// Draftpad's file sync (spec A4, "Notes: 3-way merge against the base version, otherwise one sibling"; A11).
// draftpad.md lives in the iCloud vault, so an edit from the iPhone or iPad can land on disk while Recense holds its
// own unsaved text. Recense used to write its copy over the file and lose that edit. Now every save merges three
// versions: base (what Recense last read or wrote), mine (the panel) and theirs (the file now). Reads and writes go
// through NSFileCoordinator, as iCloud Drive expects, so iCloud never sees a half-written or uncoordinated replace.

/// Coordinated read: iCloud hands over the newest version it has (downloading it first if needed).
func coordinatedRead(_ path: String) -> String? {
    var out: String?
    var err: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: URL(fileURLWithPath: path), options: [], error: &err) { u in
        out = try? String(contentsOf: u, encoding: .utf8)
    }
    return out
}

/// Coordinated atomic write.
@discardableResult
func coordinatedWrite(_ text: String, to path: String) -> Bool {
    var ok = false
    var err: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: URL(fileURLWithPath: path), options: .forReplacing, error: &err) { u in
        ok = (try? text.write(to: u, atomically: true, encoding: .utf8)) != nil
    }
    return ok && err == nil
}

/// One changed region of base: lines base[s..<e] become `lines`.
private struct Hunk: Equatable { let s: Int, e: Int, lines: [Substring] }

/// The changed regions between base and new, in base's coordinates (Myers diff via CollectionDifference).
private func hunks(_ base: [Substring], _ new: [Substring]) -> [Hunk] {
    let d = new.difference(from: base)
    var removed = Set<Int>(), inserted = Set<Int>()
    for c in d {
        switch c {
        case .remove(let o, _, _): removed.insert(o)
        case .insert(let o, _, _): inserted.insert(o)
        }
    }
    var out: [Hunk] = []
    var i = 0, j = 0
    while i < base.count || j < new.count {
        if removed.contains(i) || inserted.contains(j) {
            let s = i, js = j
            while removed.contains(i) || inserted.contains(j) {
                while removed.contains(i) { i += 1 }
                while inserted.contains(j) { j += 1 }
            }
            out.append(Hunk(s: s, e: i, lines: Array(new[js..<j])))
        } else { i += 1; j += 1 }
    }
    return out
}

/// Three-way merge by lines. Returns nil when the two sides changed the same lines (or touching ones) differently.
func merge3(base: String, mine: String, theirs: String) -> String? {
    if mine == theirs || theirs == base { return mine }
    if mine == base { return theirs }
    let b = base.split(separator: "\n", omittingEmptySubsequences: false)
    let a = hunks(b, mine.split(separator: "\n", omittingEmptySubsequences: false))
    let t = hunks(b, theirs.split(separator: "\n", omittingEmptySubsequences: false))
    // merge the two sorted hunk lists; touching or overlapping hunks must be identical, else it's a real conflict
    var all: [Hunk] = []
    var x = 0, y = 0
    while x < a.count || y < t.count {
        if x < a.count, y < t.count {
            let p = a[x], q = t[y]
            if p.s <= q.e && q.s <= p.e {               // overlap or touch
                guard p == q else { return nil }
                all.append(p); x += 1; y += 1
            } else if p.s < q.s { all.append(p); x += 1 } else { all.append(q); y += 1 }
        } else if x < a.count { all.append(a[x]); x += 1 } else { all.append(t[y]); y += 1 }
    }
    var out: [Substring] = []
    var pos = 0
    for h in all {
        out.append(contentsOf: b[pos..<h.s])
        out.append(contentsOf: h.lines)
        pos = h.e
    }
    out.append(contentsOf: b[pos...])
    return out.joined(separator: "\n")
}

/// What a save should do, given the three versions.
enum NoteSave: Equatable {
    case write(String)                 // write this (mine, or a clean merge)
    case adopt(String)                 // the file is newer and Recense had nothing new: show it, write nothing
    case conflict(mine: String, theirs: String) // both changed the same lines: keep mine in the file, theirs beside it
}

func planNoteSave(base: String, mine: String, theirs: String?) -> NoteSave {
    guard let theirs = theirs, theirs != base else { return .write(mine) }
    if mine == base { return .adopt(theirs) }
    if let m = merge3(base: base, mine: mine, theirs: theirs) { return .write(m) }
    return .conflict(mine: mine, theirs: theirs)
}

/// The one sibling for a real conflict: "draftpad (other device 2026-11-05 2051).md", next to the note.
func conflictSiblingPath(_ path: String, _ d: Date = Date()) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HHmm"
    let dir = (path as NSString).deletingLastPathComponent
    let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    return (dir as NSString).appendingPathComponent("\(name) (other device \(f.string(from: d))).md")
}

func notesyncSelftest() -> Bool {
    let base = "a\nb\nc\nd\ne"
    let cases: [(String, NoteSave, String)] = [
        ("file unchanged: write mine", planNoteSave(base: base, mine: base + "\nf", theirs: base), ".write mine"),
        ("no file: write mine", planNoteSave(base: base, mine: "x", theirs: nil), ".write mine"),
        ("only the other device changed: adopt", planNoteSave(base: base, mine: base, theirs: "a\nB\nc\nd\ne"), ".adopt"),
        ("both changed apart: merge both", planNoteSave(base: base, mine: "a\nb\nc\nd\ne\nmac", theirs: "phone\na\nb\nc\nd\ne"), ".write merged"),
        ("both changed apart (middle): merge", planNoteSave(base: base, mine: "a\nB\nc\nd\ne", theirs: "a\nb\nc\nD\ne"), ".write merged"),
        ("same line changed both ways: conflict", planNoteSave(base: base, mine: "a\nb\nMAC\nd\ne", theirs: "a\nb\nPHONE\nd\ne"), ".conflict"),
        ("same edit on both: write once", planNoteSave(base: base, mine: "a\nb\nX\nd\ne", theirs: "a\nb\nX\nd\ne"), ".write same"),
    ]
    let want: [NoteSave] = [
        .write(base + "\nf"), .write("x"), .adopt("a\nB\nc\nd\ne"),
        .write("phone\na\nb\nc\nd\ne\nmac"), .write("a\nB\nc\nD\ne"),
        .conflict(mine: "a\nb\nMAC\nd\ne", theirs: "a\nb\nPHONE\nd\ne"), .write("a\nb\nX\nd\ne"),
    ]
    var ok = true
    for (i, (label, got, _)) in cases.enumerated() {
        let pass = got == want[i]
        print("\(pass ? "ok  " : "FAIL") draftpad sync, \(label)")
        ok = ok && pass
    }
    // a real write and read through the coordinator, in a temp folder
    let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("recense-notesync-\(getpid()).md")
    let rw = coordinatedWrite("one\ntwo", to: tmp) && coordinatedRead(tmp) == "one\ntwo"
    try? FileManager.default.removeItem(atPath: tmp)
    print("\(rw ? "ok  " : "FAIL") draftpad sync, coordinated write then read")
    let sib = conflictSiblingPath("/v/draftpad.md", Date(timeIntervalSince1970: 0)).hasPrefix("/v/draftpad (other device ")
    print("\(sib ? "ok  " : "FAIL") draftpad sync, the conflict copy sits beside the note")
    return ok && rw && sib
}
