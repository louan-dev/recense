// Where a playing file's transcript comes from, in the order the offline gate asks for (player P1, 2026-11-11):
//   1. this device's copy (saved the last time the transcript was read), so it opens with no network;
//   2. the transcript the Mac stored (keep/<key>/, read through the Worker's GET /main/api/transcript?path=,
//      corrections and translations merged on read), saved here for next time;
//   3. none: the host hears the file on this device (PlaybackEars) and says so.
// One copy of the rule, Foundation and CryptoKit only; the host gives the fetch, so the tests need no network.
import Foundation
import CryptoKit

public enum TranscriptOrigin: String, Codable, Sendable {
    case device   // this device's saved copy
    case mac      // the Mac's stored transcript, just read
    case none     // neither: hear it on this device
}

public struct LoadedTranscript: Sendable, Equatable {
    public var lines: [TranscriptLine]
    public var origin: TranscriptOrigin
    /// Said under the transcript, so the listener knows where it came from.
    public var note: String? {
        switch origin {
        case .device: "Saved on this device."
        case .mac: "From the Mac's transcript."
        case .none: nil
        }
    }
}

public enum TranscriptSource {
    /// The Worker's answer (library/src/corrections.js `present`): { lines: [{ id, s, e, text, en, words: [{ t, s, e }] }] },
    /// or { pending: true } when there is none yet. nil when it isn't that shape or holds no lines.
    public static func decode(_ data: Data) -> [TranscriptLine]? {
        // FEAT-20: a word's syllables, "not sung" and the listener's timing come with it when the Worker sends them
        struct Y: Decodable { let c: Int; let s: Double; let e: Double }
        struct T: Decodable { let s: Double; let e: Double; let k: Double?; let c: [Double]? }
        struct W: Decodable { let t: String; let s: Double; let e: Double; let lang: String?; let syl: [Y]?; let un: Bool?; let tm: T? }
        struct L: Decodable {
            let id: Flexible; let s: Double; let e: Double; let text: String?; let en: String?; let words: [W]?
        }
        struct Body: Decodable { let lines: [L]?; let pending: Bool? }
        guard let b = try? JSONDecoder().decode(Body.self, from: data), let ls = b.lines, !ls.isEmpty else { return nil }
        return ls.map { l in
            let words = (l.words ?? []).map { w in
                Word(text: w.t, start: w.s, end: w.e, lang: w.lang,
                     syl: w.syl.flatMap { $0.isEmpty ? nil : $0.map { Syl(c: $0.c, s: $0.s, e: $0.e) } },
                     un: w.un == true ? true : nil,
                     tm: w.tm.map { Pin(s: $0.s, e: $0.e, k: $0.k ?? 0, c: Pin.trace($0.c)) })
            }
            let text = l.text?.isEmpty == false ? l.text! : words.map(\.text).joined(separator: " ")
            return TranscriptLine(id: l.id.text, start: l.s, end: l.e, text: text, words: words,
                                  translation: l.en?.isEmpty == false ? l.en : nil)
        }
    }

    /// The inverse of `decode`: `keep/<key>/lines.json` (FEAT-22 P1), the transcript as shown, in the shape the Worker sends and every
    /// screen already reads: { lines: [{ id, s, e, text, en, words: [{ t, s, e, lang, syl, un, tm }] }] }. Sorted keys, so the same
    /// lines always make the same bytes (carry hashes the file, so an unchanged transcript must not look changed). nil: no lines.
    public static func encode(_ lines: [TranscriptLine]) -> Data? {
        struct Y: Encodable { let c: Int; let s: Double; let e: Double }
        struct T: Encodable { let s: Double; let e: Double; let k: Double; let c: [Double]? }
        struct W: Encodable { let t: String; let s: Double; let e: Double; let lang: String?; let syl: [Y]?; let un: Bool?; let tm: T? }
        struct L: Encodable { let id: String; let s: Double; let e: Double; let text: String; let en: String?; let words: [W] }
        struct Body: Encodable { let lines: [L] }
        guard !lines.isEmpty else { return nil }
        let body = Body(lines: lines.map { l in
            L(id: l.id, s: l.start, e: l.end, text: l.text, en: l.translation?.isEmpty == false ? l.translation : nil,
              words: l.words.map { w in
                  W(t: w.text, s: w.start, e: w.end, lang: w.lang, syl: w.syl?.map { Y(c: $0.c, s: $0.s, e: $0.e) }, un: w.un,
                    tm: w.tm.map { T(s: $0.s, e: $0.e, k: $0.k, c: $0.c) })
              })
        })
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? e.encode(body)
    }

    /// The query the Worker reads: the file's path under files/ in Main.
    public static func remotePath(_ path: String) -> String {
        var c = URLComponents()
        c.path = "/main/api/transcript"
        c.queryItems = [URLQueryItem(name: "path", value: path)]
        return c.string ?? "/main/api/transcript"
    }

    /// Device copy first, then the Mac's (saved here when it comes), else none.
    /// `keep` (FEAT-22 P1): the `keep/<key>/lines.json` that carry brought, with its modified time. It is read before the Worker, so a
    /// transcript made on the Mac opens with no network. A device copy older than it is replaced (the Mac's pass is newer: the upgrade
    /// rule); one newer than it, or the same, stays. A `keep` file that is not a transcript is ignored.
    /// `fetch` answers a site path with its body, or nil (offline, refused, not found).
    public static func load(path: String, cache: TranscriptCache, keep: (data: Data, modified: Date)? = nil,
                            fetch: @Sendable (String) async -> Data?) async -> LoadedTranscript {
        let saved = cache.read(path)
        if let keep, let lines = decode(keep.data), saved == nil || (cache.modified(path).map { keep.modified > $0 } ?? true) {
            cache.write(path, lines)
            return LoadedTranscript(lines: lines, origin: .mac)
        }
        if let saved { return LoadedTranscript(lines: saved, origin: .device) }
        if let d = await fetch(remotePath(path)), let lines = decode(d) {
            cache.write(path, lines)
            return LoadedTranscript(lines: lines, origin: .mac)
        }
        return LoadedTranscript(lines: [], origin: .none)
    }
}

/// This device's copies, one plain JSON file per media path (the lines as TranscriptLine), in a folder the host names.
public struct TranscriptCache: Sendable {
    public let dir: URL
    public init(dir: URL) { self.dir = dir }

    public func file(_ path: String) -> URL {
        let h = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return dir.appendingPathComponent("\(h).json")
    }
    /// When this device's copy was last saved; nil when there is none.
    public func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file(path).path))?[.modificationDate] as? Date
    }
    public func read(_ path: String) -> [TranscriptLine]? {
        guard let d = try? Data(contentsOf: file(path)), let ls = try? JSONDecoder().decode([TranscriptLine].self, from: d),
              !ls.isEmpty else { return nil }
        return ls
    }
    public func write(_ path: String, _ lines: [TranscriptLine]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(lines) { try? d.write(to: file(path), options: .atomic) }
    }
    /// The media file moved (FEAT-13 Move to…): its saved copy follows, so it still opens offline. Never overwrites a
    /// copy already saved for the new path; nothing saved for the old path is no change.
    public func move(from old: String, to new: String) {
        let a = file(old), b = file(new), fm = FileManager.default
        guard a != b, fm.fileExists(atPath: a.path), !fm.fileExists(atPath: b.path) else { return }
        try? fm.moveItem(at: a, to: b)
    }
}

/// A segment id the Worker writes as a number (Recense's) or a string (Listen's).
private struct Flexible: Decodable {
    let text: String
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let i = try? c.decode(Int.self) { text = String(i) }
        else if let x = try? c.decode(Double.self) { text = String(x) }
        else { text = try c.decode(String.self) }
    }
}
