// Derived from Spec: PLAN-1118 §11b · the debug channel. One JSON line per event, appended to ~/Recense/logs/<feature>.jsonl
// (iOS: Documents/Recense/logs/). Twin of library/src/client/debuglog.js; both must give the same bytes for the same input
// (Tests/ShowsKitTests/Fixtures/debugchannel.json). Diagnostics never block, never throw and never leave the device:
// a failed write is dropped. Log ids, counts, states and error text, never what the person wrote or said.
import Foundation

public enum DebugChannel {
    private static let queue = DispatchQueue(label: "recense.debugchannel", qos: .utility)
    private static let maxBytes = 5_000_000

    /// `<feature>.<name>` with feature `[a-z][a-z0-9-]*`; field keys `[a-z][A-Za-z0-9_]*`. Anything else is refused (nil).
    public static func line(feature: String, event: String, fields: [String: String] = [:], at: Date = Date()) -> String? {
        guard matches(feature, #"^[a-z][a-z0-9-]*$"#), event.hasPrefix(feature + "."), matches(event, #"^[a-z][a-z0-9._-]*$"#),
              fields.keys.allSatisfy({ matches($0, #"^[a-z][A-Za-z0-9_]*$"#) }) else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = fields.keys.sorted().map { "\(quote($0)):\(quote(fields[$0]!))" }.joined(separator: ",")
        return "{\"t\":\(quote(f.string(from: at))),\"feature\":\(quote(feature)),\"event\":\(quote(event)),\"fields\":{\(body)}}"
    }

    /// Appends one line to `<directory>/<feature>.jsonl` off the caller's thread. Over 5 MB the file becomes `<feature>.1.jsonl`.
    public static func event(_ feature: String, _ event: String, _ fields: [String: String] = [:], in directory: URL? = nil) {
        guard let text = line(feature: feature, event: event, fields: fields) else { return }
        let dir = directory ?? defaultDirectory()
        queue.async { append(text + "\n", feature: feature, dir: dir) }
    }

    /// Waits for queued writes (tests; a quitting app).
    public static func flush() { queue.sync {} }

    public static func defaultDirectory() -> URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Recense/logs", isDirectory: true)
        #else
        return (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Recense/logs", isDirectory: true)
        #endif
    }

    private static func append(_ text: String, feature: String, dir: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(feature).jsonl")
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size >= maxBytes {
                let old = dir.appendingPathComponent("\(feature).1.jsonl")
                try? fm.removeItem(at: old); try fm.moveItem(at: file, to: old)
            }
            if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
            let h = try FileHandle(forWritingTo: file); defer { try? h.close() }
            try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8))
        } catch { /* a diagnostic is never worth a failure */ }
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }

    /// The JSON string rule JS's JSON.stringify uses: \" \\ \b \f \n \r \t, other control characters as \u00xx; the rest as is.
    private static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}
