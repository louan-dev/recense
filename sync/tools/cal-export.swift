// cal-export.swift: read-only EventKit export of every calendar to plain .ics files (PROGRESS B4, toward G1).
// One file per event series: OUT/<calendar title>/<uid>.ics (detached occurrences go into the same file as
// extra VEVENTs with RECURRENCE-ID). Window: --past-days (default 1095) .. --future-days (default 730).
// Never writes to Calendar. Files are rewritten only when their content changes, so the ledger sees real edits.
// Events that vanish from Calendar leave their file in place unless --prune (the ledger journal keeps history anyway).
//   swiftc -O tools/cal-export.swift -o bin/cal-export && bin/cal-export --out ~/.ledger/export/calendar
import EventKit
import Foundation

var out = NSString(string: "~/.ledger/export/calendar").expandingTildeInPath
var pastDays = 1095.0, futureDays = 730.0, prune = false
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
  switch a {
  case "--out": out = NSString(string: it.next() ?? out).expandingTildeInPath
  case "--past-days": pastDays = Double(it.next() ?? "") ?? pastDays
  case "--future-days": futureDays = Double(it.next() ?? "") ?? futureDays
  case "--prune": prune = true
  default: FileHandle.standardError.write("unknown flag \(a)\n".data(using: .utf8)!); exit(2)
  }
}

let store = EKEventStore()
let sem = DispatchSemaphore(value: 0)
var granted = false
store.requestFullAccessToEvents { ok, err in
  granted = ok
  if let err { FileHandle.standardError.write("access error: \(err.localizedDescription)\n".data(using: .utf8)!) }
  sem.signal()
}
sem.wait()
guard granted else {
  FileHandle.standardError.write("no Calendar access: System Settings → Privacy & Security → Calendars → allow this tool (Full Access)\n".data(using: .utf8)!)
  exit(1)
}

// iCalendar text helpers (RFC 5545): escape, fold at 75 octets, CRLF.
func esc(_ s: String) -> String {
  s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
    .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\r\n", with: "\\n")
    .replacingOccurrences(of: "\n", with: "\\n")
}
func fold(_ line: String) -> String {
  var bytes = Array(line.utf8), parts: [String] = [], first = true
  while !bytes.isEmpty {
    var n = min(bytes.count, first ? 75 : 74)
    while n < bytes.count && (bytes[n] & 0xC0) == 0x80 { n -= 1 } // don't split a UTF-8 sequence
    parts.append((first ? "" : " ") + String(decoding: bytes[..<n], as: UTF8.self))
    bytes.removeFirst(n); first = false
  }
  return parts.joined(separator: "\r\n")
}
let utc: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; return f }()
func day(_ d: Date, _ tz: TimeZone?) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz ?? .current; f.dateFormat = "yyyyMMdd"; return f.string(from: d) }

func rrule(_ r: EKRecurrenceRule) -> String {
  let freq = ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"][r.frequency.rawValue]
  var p = ["FREQ=\(freq)"]
  if r.interval > 1 { p.append("INTERVAL=\(r.interval)") }
  if let end = r.recurrenceEnd {
    if let d = end.endDate { p.append("UNTIL=\(utc.string(from: d))") } else if end.occurrenceCount > 0 { p.append("COUNT=\(end.occurrenceCount)") }
  }
  let wd = ["", "SU", "MO", "TU", "WE", "TH", "FR", "SA"]
  if let days = r.daysOfTheWeek, !days.isEmpty { p.append("BYDAY=" + days.map { ($0.weekNumber != 0 ? "\($0.weekNumber)" : "") + wd[$0.dayOfTheWeek.rawValue] }.joined(separator: ",")) }
  if let m = r.daysOfTheMonth, !m.isEmpty { p.append("BYMONTHDAY=" + m.map { "\($0)" }.joined(separator: ",")) }
  if let m = r.monthsOfTheYear, !m.isEmpty { p.append("BYMONTH=" + m.map { "\($0)" }.joined(separator: ",")) }
  if let m = r.setPositions, !m.isEmpty { p.append("BYSETPOS=" + m.map { "\($0)" }.joined(separator: ",")) }
  return "RRULE:" + p.joined(separator: ";")
}

func vevent(_ e: EKEvent, uid: String, master: Bool) -> [String] {
  var l = ["BEGIN:VEVENT", "UID:\(esc(uid))", "DTSTAMP:\(utc.string(from: e.lastModifiedDate ?? e.creationDate ?? e.startDate))"]
  if let c = e.creationDate { l.append("CREATED:\(utc.string(from: c))") }
  if let m = e.lastModifiedDate { l.append("LAST-MODIFIED:\(utc.string(from: m))") }
  if e.isAllDay {
    l.append("DTSTART;VALUE=DATE:\(day(e.startDate, e.timeZone))")
    l.append("DTEND;VALUE=DATE:\(day(Calendar.current.date(byAdding: .day, value: 1, to: e.endDate) ?? e.endDate, e.timeZone))")
  } else {
    l.append("DTSTART:\(utc.string(from: e.startDate))"); l.append("DTEND:\(utc.string(from: e.endDate))")
  }
  if let tz = e.timeZone { l.append("X-APPLE-TZ:\(tz.identifier)") } // keeps the zone for a later TZID-correct import
  if !master, let od = e.occurrenceDate { l.append(e.isAllDay ? "RECURRENCE-ID;VALUE=DATE:\(day(od, e.timeZone))" : "RECURRENCE-ID:\(utc.string(from: od))") }
  if master, let rules = e.recurrenceRules { l += rules.map(rrule) }
  l.append("SUMMARY:\(esc(e.title ?? ""))")
  if let s = e.location, !s.isEmpty { l.append("LOCATION:\(esc(s))") }
  if let s = e.notes, !s.isEmpty { l.append("DESCRIPTION:\(esc(s))") }
  if let u = e.url { l.append("URL:\(u.absoluteString)") }
  l.append("STATUS:" + (e.status == .canceled ? "CANCELLED" : e.status == .tentative ? "TENTATIVE" : "CONFIRMED"))
  l.append("TRANSP:" + (e.availability == .free ? "TRANSPARENT" : "OPAQUE"))
  if let o = e.organizer { l.append("ORGANIZER;CN=\(esc(o.name ?? "")):\(o.url.absoluteString)") }
  for a in (e.attendees ?? []).sorted(by: { $0.url.absoluteString < $1.url.absoluteString }) { l.append("ATTENDEE;CN=\(esc(a.name ?? ""));PARTSTAT=\(["NEEDS-ACTION","NEEDS-ACTION","ACCEPTED","DECLINED","TENTATIVE","DELEGATED","COMPLETED","IN-PROCESS"][min(a.participantStatus.rawValue, 7)]):\(a.url.absoluteString)") }
  for al in (e.alarms ?? []).sorted(by: { ($0.absoluteDate?.timeIntervalSince1970 ?? $0.relativeOffset) < ($1.absoluteDate?.timeIntervalSince1970 ?? $1.relativeOffset) }) {
    l += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder"]
    if let d = al.absoluteDate { l.append("TRIGGER;VALUE=DATE-TIME:\(utc.string(from: d))") } else { let s = Int(al.relativeOffset); l.append("TRIGGER:\(s < 0 ? "-" : "")PT\(abs(s))S") }
    l.append("END:VALARM")
  }
  l.append("END:VEVENT")
  return l
}

func safe(_ s: String) -> String {
  let bad = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
  let t = s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
  return t.isEmpty || t == "." || t == ".." ? "_" : String(t.prefix(120))
}

let fm = FileManager.default
let now = Date()
let start = now.addingTimeInterval(-pastDays * 86400), end = now.addingTimeInterval(futureDays * 86400)
var written = 0, same = 0, pruned = 0, total = 0
var calsOut: [[String: Any]] = []

for cal in store.calendars(for: .event) {
  let dir = (out as NSString).appendingPathComponent(safe(cal.title))
  try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
  // events(matching:) caps a predicate at 4 years, so walk the window in 1-year slices.
  var series: [String: (master: EKEvent, detached: [EKEvent])] = [:]
  var from = start
  while from < end {
    let to = min(from.addingTimeInterval(365 * 86400), end)
    for e in store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: [cal])) {
      let uid = e.calendarItemExternalIdentifier ?? e.calendarItemIdentifier
      if e.isDetached { series[uid, default: (e, [])].detached.append(e); continue }
      if let cur = series[uid] { if cur.master.isDetached || e.startDate < cur.master.startDate { series[uid] = (e, cur.detached) } }
      else { series[uid] = (e, []) }
    }
    from = to
  }
  var keep = Set<String>()
  for (uid, s) in series {
    var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//sync//cal-export//EN", "X-WR-CALNAME:\(esc(cal.title))"]
    lines += vevent(s.master, uid: uid, master: !s.master.isDetached)
    var seen = Set<Date>()
    for d in s.detached.sorted(by: { $0.startDate < $1.startDate }) where d !== s.master {
      if let od = d.occurrenceDate, seen.insert(od).inserted { lines += vevent(d, uid: uid, master: false) }
    }
    lines.append("END:VCALENDAR")
    let body = lines.map(fold).joined(separator: "\r\n") + "\r\n"
    let name = safe(uid) + ".ics"; keep.insert(name)
    let path = (dir as NSString).appendingPathComponent(name)
    if let old = fm.contents(atPath: path), old == body.data(using: .utf8) { same += 1; continue }
    try! body.write(toFile: path, atomically: true, encoding: .utf8); written += 1
  }
  if prune, let names = try? fm.contentsOfDirectory(atPath: dir) {
    for n in names where n.hasSuffix(".ics") && !keep.contains(n) { try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(n)); pruned += 1 }
  }
  total += series.count
  calsOut.append(["title": cal.title, "source": cal.source.title, "type": cal.type.rawValue, "series": series.count])
}

let manifest: [String: Any] = ["v": 1, "at": ISO8601DateFormatter().string(from: now), "pastDays": pastDays, "futureDays": futureDays, "calendars": calsOut]
let mdata = try! JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
let mpath = (out as NSString).appendingPathComponent("calendars.json")
let mOld = fm.contents(atPath: mpath).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
if (mOld?["calendars"] as? NSArray) != (calsOut as NSArray) { try! mdata.write(to: URL(fileURLWithPath: mpath)) }
print("cal-export: \(calsOut.count) calendar(s), \(total) series, \(written) written, \(same) unchanged, \(pruned) pruned → \(out)")
