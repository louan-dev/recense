// Handoff (Gallery notes item 31): one transcript per episode, shared by Recense on the Mac and Gallery's Listen on
// the iPhone and iPad, so whichever plays it next picks up where the last one left off.
//   keep/listen/index.json   { episodes: { <key>: { title, heard, into, count, updated } } }
//   keep/listen/<key>.json   { key, title, heard, into, place, updated, by, sentences: [{ id, heard, said, at, t? }] }
// (written here straight to R2 (Keep), by the phone through Gallery's /main/api/listen, src/listen.js.)
// key = 24 hex of sha-256("listen:" + the title lower-cased, spaces collapsed): the phone's user types or picks the
// title; here a playing item's title is matched to the index's by its words, so "Déserts médicaux" on the phone finds
// "Déserts médicaux : faut-il… | La Question du jour" here, and the phone's title is kept for both.
// The phone can't see another app's clock, so its sentences have no episode time and place is just the sentence last
// heard: here that sentence is found in this Mac's own transcript by its words (or its `t`, when the Mac wrote it) and
// playback is moved there. What this Mac writes has `t` on every sentence (real episode times), which the phone keeps:
// it then shows the whole episode ahead of where it is, and finds its place in it the same way.
import Foundation
import CryptoKit

struct HandSentence: Codable { var id: String; var heard: String; var said: String; var at: Double; var t: Double? }
struct HandEpisode: Codable {
    var key: String?; var title: String; var heard: String; var into: String
    var place: Int; var updated: Double; var by: String?; var sentences: [HandSentence]
}
struct HandIndex: Codable {
    struct Entry: Codable { var title: String; var heard: String?; var into: String?; var count: Int?; var updated: Double? }
    var episodes: [String: Entry]
}

@MainActor enum Handoff {
    static func key(_ title: String) -> String {
        let norm = "listen:" + title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(SHA256.hash(data: Data(norm.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24))
    }

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
    }
    /// How much of the shorter one the other has (0–1).
    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }

    /// What's playing here, matched once per item.
    final class Match { weak var ep: Episode?; var key: String; var title: String; var theirs: HandEpisode?
        var resumed = false; var since = Date(); var lastPush = Date.distantPast
        init(ep: Episode, key: String, title: String) { self.ep = ep; self.key = key; self.title = title } }
    static var match: Match?
    static var busy = false

    /// Every 5 s (AppDelegate): match, resume once, then send this Mac's transcript and place every minute.
    static func tick(_ app: AppDelegate) async {
        guard !busy, let ep = app.episode, let title = (ep.publishedTitle ?? ep.title)?.trimmingCharacters(in: .whitespacesAndNewlines),
              title.count >= 3 else { return }
        busy = true; defer { busy = false }
        if match?.ep !== ep {
            let (k, t) = await resolve(title)
            let m = Match(ep: ep, key: k, title: t)
            m.theirs = await fetch(k)
            match = m
            log("handoff: \(title.prefix(60)) → \(k)\(t != title ? " (as “\(t.prefix(40))”)" : "")\(m.theirs.map { ", \($0.sentences.count) sentences by \($0.by ?? "phone")" } ?? "")")
        }
        guard let m = match else { return }
        if !m.resumed { resume(app, m) }
        if !app.pos.paused, Date().timeIntervalSince(m.lastPush) > 60, !ep.display.isEmpty {
            m.lastPush = Date()
            await push(app, m, ep)
        }
    }

    /// The key and title to use: this title's own if the index has it, else the index's closest title by its words.
    static func resolve(_ title: String) async -> (String, String) {
        let own = key(title)
        guard let (d, _) = await Keep.get("listen/index.json"), let idx = try? JSONDecoder().decode(HandIndex.self, from: d) else { return (own, title) }
        if idx.episodes[own] != nil { return (own, title) }
        let w = words(title)
        let best = idx.episodes.map { ($0.key, $0.value.title, overlap(w, words($0.value.title))) }.max { $0.2 < $1.2 }
        if let best, best.2 >= 0.6, words(best.1).count >= 2 { return (best.0, best.1) }
        return (own, title)
    }

    static func fetch(_ key: String) async -> HandEpisode? {
        guard let (d, _) = await Keep.get("listen/\(key).json") else { return nil }
        return try? JSONDecoder().decode(HandEpisode.self, from: d)
    }

    /// Where the phone or iPad left off, in this Mac's time: the sentence's own `t`, else the line of this Mac's
    /// transcript with the same words. Only near the start of playback (the user hasn't chosen a place yet), only
    /// when another device played it last; tried for two minutes while the transcript comes in.
    static func resume(_ app: AppDelegate, _ m: Match) {
        guard let theirs = m.theirs, theirs.by != "mac", theirs.sentences.indices.contains(theirs.place) else { m.resumed = true; return }
        if Date().timeIntervalSince(m.since) > 120 || app.mediaTime > 30 { m.resumed = true; return }
        let s = theirs.sentences[theirs.place]
        var target = s.t
        if target == nil {
            let w = words(s.heard)
            guard w.count >= 3 else { m.resumed = true; return }
            let lines = m.ep?.display ?? []
            let best = lines.map { l in (l.start, overlap(w, words(l.words.map(\.text).joined(separator: " ")))) }.max { $0.1 < $1.1 }
            if let best, best.1 >= 0.6 { target = best.0 }
        }
        guard let t = target else { return }  // not transcribed that far yet: again next tick
        m.resumed = true
        guard t > app.mediaTime + 15 else { return }
        log("handoff: resuming at \(Int(t)) s, where the \(theirs.by ?? "phone") left off")
        app.command(.seek(t))
    }

    /// This Mac's transcript (timed) and where it is, for the phone and iPad. Theirs is replaced only if it is
    /// older; a newer one is taken as `theirs` (another device moved on).
    static func push(_ app: AppDelegate, _ m: Match, _ ep: Episode) async {
        let name = "listen/\(m.key).json"
        let current = await Keep.get(name)
        if let (d, _) = current, let now = try? JSONDecoder().decode(HandEpisode.self, from: d), now.updated > (m.theirs?.updated ?? 0), now.by != "mac" {
            m.theirs = now; m.resumed = false; m.since = Date()  // a device played it since: go where it is
            return
        }
        let lines = ep.display
        let t = app.mediaTime
        let ss = lines.map { l in
            HandSentence(id: "m\(l.id)", heard: l.words.map(\.text).joined(separator: " "),
                         said: (l.english ?? []).map(\.w).joined(separator: " "), at: l.start, t: l.start)
        }
        let place = max(0, (lines.lastIndex { $0.start <= t } ?? 0))
        let heard = lines.first?.words.first?.lang ?? m.theirs?.heard ?? ""
        let e = HandEpisode(key: m.key, title: m.title, heard: heard, into: NativeLang.current, place: place,
                            updated: Date().timeIntervalSince1970 * 1000, by: "mac", sentences: ss)
        guard let body = try? JSONEncoder().encode(e) else { return }
        let sent = current == nil ? await Keep.put(name, body, ifAbsent: true) : await Keep.put(name, body, ifMatch: current?.1)
        guard sent != nil else { log("handoff: \(name) changed meanwhile; next minute"); return }
        m.theirs = e
        // the index: one entry changed, on its etag, three tries
        for _ in 0..<3 {
            let got = await Keep.get("listen/index.json")
            var idx = got.flatMap { try? JSONDecoder().decode(HandIndex.self, from: $0.0) } ?? HandIndex(episodes: [:])
            idx.episodes[m.key] = .init(title: m.title, heard: heard, into: e.into, count: ss.count, updated: e.updated)
            guard let d = try? JSONEncoder().encode(idx) else { return }
            if await Keep.put("listen/index.json", d, ifAbsent: got == nil, ifMatch: got?.1) != nil { break }
        }
    }
}
