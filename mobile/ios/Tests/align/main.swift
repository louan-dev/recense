// Tests for HostApp/iOS/Align.swift: one transcript, never twice (Layer A, text). The driver below places sentences
// the way Listener.rebuild() does: a match moves the place there (and completes a sentence left cut short), anything
// else is spliced in after the place. Run on the Mac:
//   swiftc -O mobile/HostApp/iOS/Align.swift mobile/ios/Tests/align/main.swift -o "$TMPDIR/align" && "$TMPDIR/align"
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failed += 1 } }

let stops: Set<Character> = [".", "?", "!", "…"]
struct Episode {
    var s: [String] = []
    var place = 0
    var last: Int?
    var run: [(copy: Int, old: Int)] = []   // held: new for now, each like stored sentence `old` (Align.fit)
    var anchor: Int?
    mutating func hear(_ text: String) {
        if let j = Align.match(text, in: s, place: place, after: run.last?.old ?? last) {
            switch Align.fit(j, after: last, end: place, run: run.map(\.old), anchor: anchor) {
            case .next: merge(j, text)
            case .merge(let c):
                if c { for k in run.map(\.copy).sorted(by: >) { s.remove(at: k) } }
                run = []; anchor = nil; merge(j, text)
            case .hold(let c):
                let was = place
                add(text)
                if c { run.append((place, j)) } else { run = [(place, j)]; anchor = was }
            }
        } else { run = []; anchor = nil; add(text) }
    }
    mutating func merge(_ j: Int, _ text: String) {
        if let end = s[j].last, !stops.contains(end), Align.completes(text, s[j]) { s[j] = text }
        place = j; last = j
    }
    mutating func add(_ text: String) {
        let at = s.isEmpty ? 0 : place + 1
        s.insert(text, at: at); place = at; last = at
    }
}

let clip = [
    "Bonjour à tous et bienvenue dans ce cours de droit des contrats.",
    "Aujourd'hui nous parlons de la formation du contrat.",
    "Un contrat suppose le consentement des parties.",
    "Oui.",
    "Le contrat est nul sous l'article 385 du code civil.",
    "La nullité peut être relative ou absolue selon l'intérêt protégé.",
    "D'accord.",
    "La nullité relative protège une partie au contrat.",
    "La nullité absolue protège l'intérêt général de la société.",
    "Le délai de prescription est de cinq ans en principe.",
    "Merci.",
    "Nous verrons la semaine prochaine les effets de la nullité.",
]

// start → exit at 40 % (mid-sentence) → resume a little before where it stopped → replay from the start
var e = Episode()
for t in clip[0..<4] { e.hear(t) }
e.hear("Le contrat est nul sous")                       // left mid-sentence
for t in clip[4...] { e.hear(t) }                       // resumed (players rewind a few seconds)
check(e.s == clip, "exit at 40 % then resume: one whole transcript, the cut sentence completed")
for t in clip { e.hear(t) }                             // replayed from 0
check(e.s == clip, "replay from the start adds nothing (short sentences included)")
check(e.s.count == Set(e.s).count, "no duplicates")

// a 10 s rewind is an overlap, not new
var r = Episode()
for t in clip[0..<7] { r.hear(t) }
for t in clip[4..<9] { r.hear(t) }
check(r.s == Array(clip[0..<9]), "rewind: no duplicate, continues after")

// a short sentence is only recognised right after the sentence it follows
var sh = Episode()
for t in clip[0..<4] { sh.hear(t) }
sh.hear("Une phrase toute nouvelle sur la responsabilité civile délictuelle.")
sh.hear("Oui.")
check(sh.s.filter { $0 == "Oui." }.count == 2, "a short sentence elsewhere is new, not a match")

// recognising content resumed in another episode: three sentences in a row, in order
check(Align.continues(Array(clip[4...7]), in: clip) == 7, "resume in a fresh episode is recognised (3 long sentences in a row, a short one between)")
check(Align.continues([clip[5], clip[9]], in: clip) == nil, "two sentences are not enough")
check(Align.continues([clip[2], clip[9], clip[10]], in: clip) == nil, "out of order or far apart is not a resume")

// two shows sharing an intro stay apart
let other = [
    "Bonjour à tous et bienvenue dans ce cours de droit des contrats.",
    "Aujourd'hui nous parlons de la formation du contrat.",
    "Le droit pénal sanctionne les infractions les plus graves.",
    "La légalité des délits et des peines est un principe fondamental.",
]
check(Align.continues(other, in: clip) == nil, "a shared intro (2 sentences) never merges two shows")

// English and Vietnamese work the same way (words, not French rules)
var vi = Episode()
let viClip = ["Xin chào các bạn đến với bài học hôm nay.", "Hợp đồng vô hiệu theo điều 385 bộ luật dân sự.", "Vâng.", "Thời hiệu khởi kiện là năm năm."]
for t in viClip { vi.hear(t) }
for t in viClip { vi.hear(t) }
check(vi.s == viClip, "Vietnamese replay adds nothing")

// Live captions arrive growing ("And the judge" … "And the judge said nothing more."), the way Listener.rebuild()
// sees them. Regression (owner 11-09, "insanely inaccurate"): a new sentence whose first words all occur in some
// longer sentence heard earlier was taken for that one, and the new sentence was lost. Driver as rebuild(): a growing
// sentence is matched only once it is complete (Align.complete); before that it is new and grows in place.
struct Live {
    var s: [String] = []
    var place = 0
    var last: Int?
    var run: [(copy: Int, old: Int)] = []
    var anchor: Int?
    mutating func hear(_ full: String) {
        let w = full.split(separator: " ").map(String.init)
        var mine: Int?            // the sentence this one is growing in (added as new)
        var placed: Int?          // matched to one heard before
        for k in 1...w.count {
            let text = w[0..<k].joined(separator: " ")
            let done = k == w.count
            if let p = placed { if let end = s[p].last, !stops.contains(end), Align.completes(text, s[p]) { s[p] = text }; continue }
            if let m = mine {
                s[m] = text
                guard done else { continue }
                // as rebuild(): the copy grew whole; it merges only when Align.fit says so, else it stays new (held)
                if let j = Align.match(text, in: s, place: place, after: run.last?.old ?? last, besides: m) {
                    // after: the copy itself (the stored sentence after it is the one that follows); end: before it
                    let f = Align.fit(j, after: m, end: m - 1, run: run.map(\.old), anchor: anchor)
                    switch f {
                    case .next, .merge:
                        let gone = ([m] + (f == .merge(continues: true) ? run.map(\.copy) : [])).sorted(by: >)
                        for k in gone { s.remove(at: k) }
                        let jj = j - gone.filter { $0 < j }.count
                        if let end = s[jj].last, !stops.contains(end), Align.completes(text, s[jj]) { s[jj] = text }
                        place = jj; last = jj; placed = jj; run = []; anchor = nil
                    case .hold(let c):
                        if c { run.append((m, j)) } else { run = [(m, j)]; anchor = m - 1 }
                    }
                } else { run = []; anchor = nil }
                mine = nil
                continue
            }
            if done || Align.complete(text), let j = Align.match(text, in: s, place: place, after: run.last?.old ?? last) {
                let f = Align.fit(j, after: last, end: place, run: run.map(\.old), anchor: anchor)
                if case .hold(let c) = f {   // new for now, at the end
                    let was = place, at = s.isEmpty ? 0 : place + 1
                    s.insert(text, at: at); place = at; last = at; placed = at
                    if c { run.append((at, j)) } else { run = [(at, j)]; anchor = was }
                    continue
                }
                let gone = (f == .merge(continues: true) ? run.map(\.copy) : []).sorted(by: >)
                for k in gone { s.remove(at: k) }
                let jj = j - gone.filter { $0 < j }.count
                if let end = s[jj].last, !stops.contains(end), Align.completes(text, s[jj]) { s[jj] = text }
                place = jj; last = jj; placed = jj; run = []; anchor = nil
            } else {
                let at = s.isEmpty ? 0 : place + 1
                s.insert(text, at: at); place = at; last = at; mine = at
            }
        }
    }
}
let talk = [
    "So the thing you have to know about the court is that it is slow and it is expensive.",
    "The judge said the contract was void and the parties had to give everything back.",
    "You have to know that.",
    "And the judge said nothing more about the appeal that day.",
    "It is slow.",
    "But the court is not the only place where this happens, you know.",
    "Is that the thing?",
    "The parties had to wait two more years for the appeal.",
]
var lv = Live()
for t in talk { lv.hear(t) }
check(lv.s == talk, "growing live captions: every new sentence kept, in order (none taken for an older one)")
for t in talk { lv.hear(t) }
check(lv.s == talk, "growing live captions replayed: nothing added twice")
var lc = Live()
for t in clip[0..<4] { lc.hear(t) }
lc.hear("Le contrat est nul sous")
for t in clip[4...] { lc.hear(t) }
check(lc.s == clip, "growing: exit mid-sentence then resume completes the cut sentence")

// Regression (owner's iPad videos 11-10, Dua Lipa "Dance the Night"): a song's chorus comes back. Each repeated line
// read like its first time, so the light jumped back there and every new line was spliced in mid-transcript. A
// repeat stays where it is heard, at the end; only a run of 3 in a row, or one that reaches where the listening was,
// is a rewind.
let song = [
    "Baby I can feel your halo tonight and it is shining bright.",
    "Coming now, following my lead.",
    "I'm not afraid to tell you when you're wrong.",
    "Ooh yeah I think it's tough as we got it all the love the passion.",
    "Diamond under my eyes turn the rhythm don't you wanna just come with me.",
    "Coming now, following my lead.",
    "You can see my heartbeat tonight I can take the heat baby best believe.",
]
var sg = Episode()
for t in song { sg.hear(t) }
check(sg.s == song, "song: a chorus line heard again stays in order at the end (Episode)")
check(sg.place == song.count - 1, "song: the light is on the newest line, not the earlier chorus")
var sl = Live()
for t in song { sl.hear(t) }
check(sl.s == song, "song: a chorus line heard again stays in order at the end (growing live captions)")
check(sl.place == song.count - 1, "song (live): the light is on the newest line")
// a two-line chorus repeated, then a new verse: both chorus lines stay, in order, before the verse
let two = ["Watch me dance dance the night away tonight.", "My heart could be burning but you won't see it on my face.",
           "Something completely new about the summer and the city lights.",
           "Watch me dance dance the night away tonight.", "My heart could be burning but you won't see it on my face.",
           "And a verse nobody has heard before in this song at all."]
var tw = Live()
for t in two { tw.hear(t) }
check(tw.s == two, "song: a two-line chorus repeated keeps both lines, in order")
// a 2-sentence rewind that catches up with where the listening was still merges (no duplicate)
var r2 = Live()
for t in clip[0..<7] { r2.hear(t) }
for t in clip[5..<9] { r2.hear(t) }
check(r2.s == Array(clip[0..<9]), "growing: a 2-sentence rewind that reaches the place merges, then continues")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
