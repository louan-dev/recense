// The owner's calendar, for the assistant (ai.js) and the invite links (/c/<token>.ics).
//   own:    the Sync worker's CalDAV store (R2 bucket "sync", binding CALENDAR): caldav/users/<user>/<cal>/<res>.ics and
//           .calendar.json. Apple Calendar on the Mac and iPhone reads it as a CalDAV account; writing the objects here is
//           what the Sync worker would do on a client's PUT (same keys, same trash copy, uid in customMetadata), and its
//           ctag is computed from the listing, so clients see the change on their next sync.
//   icloud: the 30-minute EventKit backup in MAIN (ledger/calendar/views/tree.json + objects/<hh>/<hash>), read only.
//           Parsed events are cached by content hash in ai/cal-mirror.json, so a question reads only what changed.
// Times: events are written in UTC; the owner's local time zone (env.OWNER_TZ, default America/Los_Angeles) is used to
// read dates like "Friday at 5 pm" and to show times back.

export const TZ_DEFAULT = "America/Los_Angeles";
const tzOf = (env) => env.OWNER_TZ || TZ_DEFAULT;
const userOf = (env) => env.CALDAV_USER || "chau";
const OWN = (env) => `caldav/users/${userOf(env)}/`;
const MIRROR = "ledger/calendar/";
const MIRROR_CACHE = "ai/cal-mirror.json";
const INVITES = "ai/invites/";
const MIRROR_BUDGET = 400;                 // backup objects read per call; the rest next time (warmCalendar finishes it)
const DAY = 86400000;

// ---------- time zones ----------

function parts(ms, tz) {
  const f = new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", weekday: "short" });
  const o = {}; for (const p of f.formatToParts(new Date(ms))) o[p.type] = p.value;
  return { y: +o.year, m: +o.month, d: +o.day, h: +o.hour, mi: +o.minute, s: +o.second, wd: o.weekday };
}
const offset = (ms, tz) => { const p = parts(ms, tz); return Date.UTC(p.y, p.m - 1, p.d, p.h, p.mi, p.s) - Math.floor(ms / 1000) * 1000; };

/** Wall-clock time in `tz` → epoch ms (DST-safe: corrected once after the first guess). */
export function zoned(y, m, d, h = 0, mi = 0, s = 0, tz = TZ_DEFAULT) {
  const guess = Date.UTC(y, m - 1, d, h, mi, s);
  let t = guess - offset(guess, tz);
  t = guess - offset(t, tz);
  return t;
}

/** "2026-10-30" (+ "17:00") in the owner's zone → epoch ms. */
export function localMs(date, time, tz) {
  const dm = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(date || ""));
  if (!dm) throw new Error("date must be YYYY-MM-DD");
  const tm = time ? /^(\d{1,2}):(\d{2})$/.exec(String(time)) : null;
  if (time && !tm) throw new Error("time must be HH:MM (24-hour)");
  return zoned(+dm[1], +dm[2], +dm[3], tm ? +tm[1] : 0, tm ? +tm[2] : 0, 0, tz);
}

export function showLocal(ms, tz, allDay = false) {
  return new Intl.DateTimeFormat("en-US", { timeZone: tz, weekday: "short", month: "short", day: "numeric", year: "numeric", ...(allDay ? {} : { hour: "numeric", minute: "2-digit" }) }).format(new Date(ms));
}
export const today = (tz, now = Date.now()) => { const p = parts(now, tz); return `${p.y}-${String(p.m).padStart(2, "0")}-${String(p.d).padStart(2, "0")}`; };

/** The date facts a model gets wrong if left to work them out: today with its weekday, and this and next week (Mon–Sun). */
export function dateFacts(tz, now = Date.now()) {
  const p = parts(now, tz), back = { Mon: 0, Tue: 1, Wed: 2, Thu: 3, Fri: 4, Sat: 5, Sun: 6 }[p.wd];
  const day = (n) => { const d = new Date(Date.UTC(p.y, p.m - 1, p.d + n)); return `${["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getUTCDay()]} ${d.toISOString().slice(0, 10)}`; };
  return `today is ${day(0)} (local time ${String(p.h).padStart(2, "0")}:${String(p.mi).padStart(2, "0")}); tomorrow is ${day(1)}; ` +
    `this week is ${day(-back)} to ${day(6 - back)}; next week is ${day(7 - back)} to ${day(13 - back)}`;
}

/** Reads the iCloud backup until the parsed-event cache is complete (or `rounds` runs out). */
export async function warmCalendar(env, rounds = 6) {
  const tz = tzOf(env);
  for (let i = 0; i < rounds; i++) if (!(await mirrorEvents(env, tz)).partial) return true;
  return false;
}

// ---------- iCalendar ----------

const unfold = (ics) => String(ics).replace(/\r\n/g, "\n").replace(/\n[ \t]/g, "").split("\n");
const unesc = (v) => v.replace(/\\n/gi, "\n").replace(/\\([,;\\])/g, "$1");
const esc = (v) => String(v).replace(/\\/g, "\\\\").replace(/\n/g, "\\n").replace(/([,;])/g, "\\$1");

function prop(line) {
  const i = line.indexOf(":"); if (i < 0) return null;
  const head = line.slice(0, i).split(";"), params = {};
  for (const p of head.slice(1)) { const j = p.indexOf("="); if (j > 0) params[p.slice(0, j).toUpperCase()] = p.slice(j + 1).replace(/^"|"$/g, ""); }
  return { name: head[0].toUpperCase(), params, value: line.slice(i + 1) };
}

function timeOf(p, tz) {
  const v = p.value.trim();
  const m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/.exec(v);
  if (!m) return null;
  if (!m[4] || p.params.VALUE === "DATE") return { ms: zoned(+m[1], +m[2], +m[3], 0, 0, 0, tz), allDay: true };
  if (m[7]) return { ms: Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]), allDay: false };
  let zone = p.params.TZID || tz;
  try { new Intl.DateTimeFormat("en-US", { timeZone: zone }); } catch { zone = tz; }      // Windows/odd TZIDs: the owner's zone
  return { ms: zoned(+m[1], +m[2], +m[3], +m[4], +m[5], +m[6], zone), allDay: false };
}

/** The VEVENTs of an iCalendar text (alarms and other nested parts skipped). */
export function parseEvents(ics, tz = TZ_DEFAULT) {
  const out = []; let ev = null, depth = 0, calName = "";
  for (const line of unfold(ics)) {
    const p = prop(line); if (!p) continue;
    if (p.name === "X-WR-CALNAME") calName = unesc(p.value).trim();
    if (p.name === "BEGIN") { if (p.value === "VEVENT" && !ev) { ev = { attendees: [], exdates: [] }; depth = 0; } else if (ev) depth++; continue; }
    if (p.name === "END") { if (ev && depth > 0) { depth--; continue; } if (p.value === "VEVENT" && ev) { if (ev.start != null) out.push(ev); ev = null; } continue; }
    if (!ev || depth > 0) continue;
    if (p.name === "UID") ev.uid = p.value.trim();
    else if (p.name === "SUMMARY") ev.title = unesc(p.value);
    else if (p.name === "LOCATION") ev.location = unesc(p.value);
    else if (p.name === "DESCRIPTION") ev.notes = unesc(p.value).slice(0, 500);
    else if (p.name === "DTSTART") { const t = timeOf(p, tz); if (t) { ev.start = t.ms; ev.allDay = t.allDay; } }
    else if (p.name === "DTEND") { const t = timeOf(p, tz); if (t) ev.end = t.ms; }
    else if (p.name === "DURATION") ev.duration = p.value;
    else if (p.name === "RRULE") ev.rrule = p.value;
    else if (p.name === "RECURRENCE-ID") ev.recurrenceId = timeOf(p, tz)?.ms ?? null;
    else if (p.name === "EXDATE") for (const v of p.value.split(",")) { const t = timeOf({ ...p, value: v }, tz); if (t) ev.exdates.push(t.ms); }
    else if (p.name === "ATTENDEE") ev.attendees.push({ name: p.params.CN || "", email: p.value.replace(/^mailto:/i, "") });
    else if (p.name === "STATUS" && /CANCELLED/i.test(p.value)) ev.cancelled = true;
  }
  for (const e of out) {
    if (e.end == null) e.end = e.duration ? e.start + durMs(e.duration) : e.start + (e.allDay ? DAY : 0);
    e.calendar = calName;
    delete e.duration;
  }
  return out;
}

function durMs(d) {
  const m = /^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/.exec(d || "");
  if (!m) return 0;
  return ((+m[2] || 0) * 7 * DAY + (+m[3] || 0) * DAY + (+m[4] || 0) * 3600e3 + (+m[5] || 0) * 60e3 + (+m[6] || 0) * 1e3) * (m[1] === "-" ? -1 : 1);
}

const WD = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 };

/** Occurrences of an event between from and to (ms). Recurrence: DAILY, WEEKLY (BYDAY), MONTHLY, YEARLY with INTERVAL,
 *  COUNT, UNTIL and EXDATE; stepped in the owner's local time so 5 pm stays 5 pm across daylight saving. */
export function occurrences(ev, from, to, tz = TZ_DEFAULT) {
  if (ev.cancelled) return [];
  const len = Math.max(0, ev.end - ev.start), hit = (s) => s < to && s + Math.max(len, 1) > from;
  if (!ev.rrule) return hit(ev.start) ? [{ start: ev.start, end: ev.start + len }] : [];
  const r = Object.fromEntries(ev.rrule.split(";").map((kv) => kv.split("=")));
  const freq = r.FREQ, step = Math.max(1, +r.INTERVAL || 1), count = r.COUNT ? +r.COUNT : Infinity;
  const until = r.UNTIL ? timeOf({ value: r.UNTIL, params: {} }, tz)?.ms ?? Infinity : Infinity;
  const p0 = parts(ev.start, tz), ex = new Set(ev.exdates), out = [];
  const at = (y, m, d) => zoned(y, m, d, p0.h, p0.mi, p0.s, tz);
  const byday = freq === "WEEKLY" && r.BYDAY ? r.BYDAY.split(",").map((x) => WD[x.slice(-2)]).filter((x) => x != null) : null;
  let n = 0;
  for (let i = 0; i < 3000 && n < count; i++) {
    let starts = [];
    if (freq === "DAILY") starts = [at(p0.y, p0.m, p0.d + i * step)];
    else if (freq === "WEEKLY") {
      const wk = at(p0.y, p0.m, p0.d + i * 7 * step), base = new Date(Date.UTC(p0.y, p0.m - 1, p0.d + i * 7 * step)).getUTCDay();
      starts = (byday || [base]).map((wd) => at(p0.y, p0.m, p0.d + i * 7 * step + ((wd - base + 7) % 7))).sort((a, b) => a - b);
      void wk;
    } else if (freq === "MONTHLY") starts = [at(p0.y, p0.m + i * step, p0.d)];
    else if (freq === "YEARLY") starts = [at(p0.y + i * step, p0.m, p0.d)];
    else return hit(ev.start) ? [{ start: ev.start, end: ev.start + len }] : [];
    for (const s of starts) {
      if (s < ev.start) continue;
      if (s > until || n >= count) return out;
      n++;
      if (s >= to) return out;
      if (!ex.has(s) && hit(s)) out.push({ start: s, end: s + len });
    }
  }
  return out;
}

const fold = (line) => { const out = []; let s = line; while (s.length > 74) { out.push(s.slice(0, 74)); s = " " + s.slice(74); } out.push(s); return out.join("\r\n"); };
const utc = (ms) => new Date(ms).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
const dateOnly = (ms, tz) => { const p = parts(ms, tz); return `${p.y}${String(p.m).padStart(2, "0")}${String(p.d).padStart(2, "0")}`; };

/** A new event as iCalendar text. */
export function buildEvent({ uid, title, start, end, allDay, location, notes }, tz = TZ_DEFAULT, now = Date.now()) {
  const lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//gallery//assistant//EN", "CALSCALE:GREGORIAN", "BEGIN:VEVENT",
    `UID:${uid}`, `DTSTAMP:${utc(now)}`, `CREATED:${utc(now)}`, `LAST-MODIFIED:${utc(now)}`,
    allDay ? `DTSTART;VALUE=DATE:${dateOnly(start, tz)}` : `DTSTART:${utc(start)}`,
    allDay ? `DTEND;VALUE=DATE:${dateOnly(end, tz)}` : `DTEND:${utc(end)}`,
    `SUMMARY:${esc(title)}`];
  if (location) lines.push(`LOCATION:${esc(location)}`);
  if (notes) lines.push(`DESCRIPTION:${esc(notes)}`);
  lines.push("END:VEVENT", "END:VCALENDAR");
  return lines.map(fold).join("\r\n") + "\r\n";
}

/** Edits the first VEVENT's own properties (not its alarms): `set` replaces or adds lines by property name, `add` appends
 *  lines; everything else the client wrote (alarms, attendees, X- properties) is kept byte for byte. */
export function editEvent(ics, set = {}, add = [], now = Date.now()) {
  const src = String(ics).replace(/\r\n/g, "\n").split("\n"), out = [];
  let inEv = false, depth = 0, done = new Set();
  const names = Object.keys(set);
  const nameOf = (l) => l.split(/[;:]/)[0].toUpperCase();
  for (let i = 0; i < src.length; i++) {
    const l = src[i];
    if (/^BEGIN:VEVENT$/i.test(l) && !inEv && !done.has("__ev")) { inEv = true; depth = 0; out.push(l); continue; }
    if (inEv && /^BEGIN:/i.test(l)) { depth++; out.push(l); continue; }
    if (inEv && /^END:/i.test(l) && depth > 0) { depth--; out.push(l); continue; }
    if (inEv && /^END:VEVENT$/i.test(l)) {
      for (const n of names) if (!done.has(n) && set[n] != null) out.push(fold(set[n]));
      if (!done.has("LAST-MODIFIED")) out.push(`LAST-MODIFIED:${utc(now)}`);
      for (const a of add) out.push(fold(a));
      out.push(l); inEv = false; done.add("__ev"); continue;
    }
    if (inEv && depth === 0 && /^[ \t]/.test(l)) { if (out.__skip) continue; out.push(l); continue; }   // continuation line
    out.__skip = false;
    if (inEv && depth === 0) {
      const n = nameOf(l);
      if (n === "LAST-MODIFIED" || n === "DTSTAMP") { out.push(`${n}:${utc(now)}`); done.add(n); continue; }
      if (n in set) { out.__skip = true; if (!done.has(n) && set[n] != null) out.push(fold(set[n])); done.add(n); continue; }
    }
    out.push(l);
  }
  return out.join("\r\n").replace(/(\r\n)*$/, "\r\n");
}

// ---------- the stores ----------

async function listAll(bucket, prefix, delimiter) {
  const objects = [], prefixes = []; let cursor;
  do {
    const r = await bucket.list({ prefix, delimiter, cursor, include: ["customMetadata"] });
    objects.push(...r.objects); prefixes.push(...(r.delimitedPrefixes || []));
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);
  return { objects, prefixes };
}

/** The owner's own calendars (Sync's CalDAV), as { cal, name }; "main" when none exist yet (as the Sync worker does). */
export async function ownCalendars(env) {
  const { prefixes } = await listAll(env.CALENDAR, OWN(env), "/"), out = [];
  for (const p of prefixes) {
    const cal = p.slice(OWN(env).length, -1);
    const o = await env.CALENDAR.get(OWN(env) + cal + "/.calendar.json");
    const m = o ? await o.json().catch(() => null) : null;
    if (m && !m.deleted) out.push({ cal, name: m.displayname || cal });
  }
  if (!out.length) {
    await env.CALENDAR.put(OWN(env) + "main/.calendar.json", JSON.stringify({ displayname: env.CALDAV_DEFAULT_NAME || "Calendar", created: new Date().toISOString() }), { httpMetadata: { contentType: "application/json" } });
    out.push({ cal: "main", name: env.CALDAV_DEFAULT_NAME || "Calendar" });
  }
  return out;
}

async function ownEvents(env, tz) {
  const cals = await ownCalendars(env), out = [];
  for (const c of cals) {
    const { objects } = await listAll(env.CALENDAR, OWN(env) + c.cal + "/");
    await Promise.all(objects.filter((o) => o.key.endsWith(".ics")).map(async (o) => {
      const b = await env.CALENDAR.get(o.key); if (!b) return;
      for (const e of parseEvents(await b.text(), tz)) out.push({ ...e, calendar: c.name, source: "own", key: o.key });
    }));
  }
  return out;
}

async function mirrorEvents(env, tz) {
  const t = await env.MAIN.get(MIRROR + "views/tree.json");
  if (!t) return { events: [], partial: false, missing: 0 };
  const tree = await t.json();
  const c = await env.MAIN.get(MIRROR_CACHE);
  const cache = (c && (await c.json().catch(() => null))) || { tz, byHash: {} };
  if (cache.tz !== tz) { cache.tz = tz; cache.byHash = {}; }
  const files = Object.entries(tree.files || {}).filter(([p]) => p.endsWith(".ics"));
  const want = new Set(files.map(([, f]) => f.hash));
  const missing = files.filter(([, f]) => !cache.byHash[f.hash]);
  const now = missing.slice(0, MIRROR_BUDGET);
  for (let i = 0; i < now.length; i += 25) {
    await Promise.all(now.slice(i, i + 25).map(async ([path, f]) => {
      const o = await env.MAIN.get(MIRROR + "objects/" + f.hash.slice(0, 2) + "/" + f.hash);
      const evs = o ? parseEvents(await o.text(), tz) : [];
      const cal = path.split("/")[0];
      cache.byHash[f.hash] = evs.map((e) => ({ ...e, calendar: e.calendar || cal }));
    }));
  }
  let changed = now.length > 0;
  for (const h of Object.keys(cache.byHash)) if (!want.has(h)) { delete cache.byHash[h]; changed = true; }
  if (changed) await env.MAIN.put(MIRROR_CACHE, JSON.stringify(cache), { httpMetadata: { contentType: "application/json" } });
  const events = files.flatMap(([, f]) => (cache.byHash[f.hash] || []).map((e) => ({ ...e, source: "icloud" })));
  return { events, partial: missing.length > now.length, missing: missing.length - now.length };
}

/** Everything on the owner's calendars between two local dates (inclusive), as occurrences sorted by start. */
export async function listEvents(env, fromDate, toDate) {
  const tz = tzOf(env), from = localMs(fromDate, null, tz), to = localMs(toDate, null, tz) + DAY;
  if (!(to > from) || to - from > 400 * DAY) throw new Error("the range must be 1 to 400 days");
  const [own, mirror] = await Promise.all([env.CALENDAR ? ownEvents(env, tz) : [], mirrorEvents(env, tz)]);
  // a moved occurrence (RECURRENCE-ID) replaces the series' instance at that time
  const all = [...own, ...mirror.events], moved = new Set(all.filter((e) => e.recurrenceId != null).map((e) => e.uid + "@" + e.recurrenceId));
  const out = [];
  for (const e of all) for (const o of occurrences(e, from, to, tz)) {
    if (e.recurrenceId == null && moved.has(e.uid + "@" + o.start)) continue;
    out.push({ uid: e.uid, title: e.title || "(no title)", start: o.start, end: o.end, allDay: !!e.allDay, when: showLocal(o.start, tz, e.allDay) + (e.allDay ? "" : " – " + showLocal(o.end, tz).split(", ").pop()),
      location: e.location || "", calendar: e.calendar || "", source: e.source, editable: e.source === "own", invitees: e.attendees.map((a) => a.name || a.email) });
  }
  out.sort((a, b) => a.start - b.start);
  return { tz, events: out, partial: mirror.partial };
}

async function findOwn(env, uid) {
  for (const c of await ownCalendars(env)) {
    const { objects } = await listAll(env.CALENDAR, OWN(env) + c.cal + "/");
    for (const o of objects) if (o.key.endsWith(".ics") && (o.customMetadata?.uid === uid || o.key.endsWith("/" + uid + ".ics"))) return { key: o.key, cal: c.cal, etag: o.etag };
  }
  return null;
}

async function putOwn(env, key, ics, prevEtag) {
  if (prevEtag) {                                                    // the Sync worker's trash copy before an overwrite
    const old = await env.CALENDAR.get(key);
    if (old) {
      const rel = key.slice("caldav/users/".length).replace(/\.ics$/, "");
      await env.CALENDAR.put(`caldav/trash/${rel}.${Math.floor(Date.now() / 1000)}.ics`, await old.text(), { httpMetadata: { contentType: "text/calendar; charset=utf-8" } });
    }
  }
  const uid = (/^UID[;:](?:[^:\r\n]*:)?(.*)$/m.exec(ics)?.[1] || "").trim();
  const put = await env.CALENDAR.put(key, ics, { httpMetadata: { contentType: "text/calendar; charset=utf-8" }, customMetadata: { uid }, onlyIf: prevEtag ? { etagMatches: prevEtag } : { etagDoesNotMatch: "*" } });
  if (!put) throw new Error("the event changed meanwhile; try again");
}

/** Times from the assistant's arguments: a date, optional start/end times or a duration; all-day when no time. */
function span(a, tz) {
  const allDay = !!a.all_day || !a.start_time;
  const start = localMs(a.date, allDay ? null : a.start_time, tz);
  let end;
  if (allDay) end = localMs(a.end_date || a.date, null, tz) + DAY;
  else if (a.end_time) { end = localMs(a.end_date || a.date, a.end_time, tz); if (end <= start) end += DAY; }
  else end = start + Math.max(5, Math.min(24 * 60, +a.duration_minutes || 60)) * 60000;
  return { start, end, allDay };
}

export async function createEvent(env, a) {
  if (!env.CALENDAR) throw new Error("the calendar isn't connected");
  const tz = tzOf(env), title = String(a.title || "").trim().slice(0, 300);
  if (!title) throw new Error("an event needs a title");
  const { start, end, allDay } = span(a, tz);
  const cals = await ownCalendars(env);
  const cal = (a.calendar && cals.find((c) => c.name.toLowerCase() === String(a.calendar).toLowerCase())) || cals[0];
  const uid = crypto.randomUUID().toUpperCase();
  await putOwn(env, `${OWN(env)}${cal.cal}/${uid}.ics`, buildEvent({ uid, title, start, end, allDay, location: a.location, notes: a.notes }, tz));
  return { ok: true, uid, title, calendar: cal.name, when: showLocal(start, tz, allDay) + (allDay ? " (all day)" : " – " + showLocal(end, tz).split(", ").pop()) };
}

export async function updateEvent(env, a) {
  const tz = tzOf(env), f = await findOwn(env, String(a.uid || ""));
  if (!f) throw new Error("no event with that uid on the owner's own calendar (iCloud events can't be edited from here)");
  const o = await env.CALENDAR.get(f.key), ics = await o.text(), set = {};
  if (a.title) set.SUMMARY = `SUMMARY:${esc(String(a.title).slice(0, 300))}`;
  if (a.location != null) set.LOCATION = a.location ? `LOCATION:${esc(a.location)}` : null;
  if (a.notes != null) set.DESCRIPTION = a.notes ? `DESCRIPTION:${esc(a.notes)}` : null;
  if (a.date) {
    const { start, end, allDay } = span(a, tz);
    set.DTSTART = allDay ? `DTSTART;VALUE=DATE:${dateOnly(start, tz)}` : `DTSTART:${utc(start)}`;
    set.DTEND = allDay ? `DTEND;VALUE=DATE:${dateOnly(end, tz)}` : `DTEND:${utc(end)}`;
    set.DURATION = null;
  }
  await putOwn(env, f.key, editEvent(ics, set), o.etag);
  const ev = parseEvents(editEvent(ics, set), tz)[0];
  return { ok: true, uid: a.uid, title: ev.title, when: showLocal(ev.start, tz, ev.allDay) };
}

/** Adds someone to an event's invitees and returns a private link that adds the event to their calendar. */
export async function addInvitee(env, a, origin) {
  const f = await findOwn(env, String(a.uid || ""));
  if (!f) throw new Error("no event with that uid on the owner's own calendar");
  const name = String(a.name || "").trim().slice(0, 100), email = String(a.email || "").trim();
  if (!name) throw new Error("who should be invited?");
  if (!email) return { ok: false, need: "email", message: `Ask the owner for ${name}'s email address (unless you already remember it), then call add_invitee again with it.` };
  if (!/^[^\s@<>"]+@[^\s@<>"]+\.[a-z]{2,}$/i.test(email)) return { ok: false, need: "email", message: `"${email}" doesn't look like an email address; ask the owner again.` };
  const o = await env.CALENDAR.get(f.key), ics = await o.text();
  const have = parseEvents(ics)[0]?.attendees || [];
  if (!have.some((x) => x.email.toLowerCase() === email.toLowerCase())) {
    await putOwn(env, f.key, editEvent(ics, {}, [`ATTENDEE;CN="${name.replace(/"/g, "")}";ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:${email}`]), o.etag);
  }
  const link = await inviteLink(env, f.key, origin);
  return { ok: true, invited: { name, email }, link, message: `Added ${name} as an invitee. Give the owner this link to text ${name}; opening it adds the event to their calendar: ${link}` };
}

// ---------- invite links: /c/<token>.ics (public, the token is the key; only its hash is stored) ----------

const sha = async (s) => [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))].map((b) => b.toString(16).padStart(2, "0")).join("");

async function inviteLink(env, key, origin) {
  const token = [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, "0")).join("");
  await env.MAIN.put(INVITES + (await sha(token)) + ".json", JSON.stringify({ key, exp: Date.now() + 60 * DAY }), { httpMetadata: { contentType: "application/json" } });
  return `${origin}/c/${token}.ics`;
}

/** GET /c/<token>.ics: the event, published for the person invited (other invitees' addresses are left out). */
export async function inviteIcs(env, token) {
  const notFound = () => new Response("This invite link has expired or doesn't exist.", { status: 404, headers: { "content-type": "text/plain; charset=utf-8" } });
  if (!/^[0-9a-f]{32}$/.test(token) || !env.CALENDAR) return notFound();
  const o = await env.MAIN.get(INVITES + (await sha(token)) + ".json");
  const inv = o ? await o.json().catch(() => null) : null;
  if (!inv || inv.exp < Date.now()) return notFound();
  const ev = await env.CALENDAR.get(inv.key);
  if (!ev) return notFound();
  const lines = [];
  let alarm = false;
  for (const l of (await ev.text()).replace(/\r\n/g, "\n").replace(/\n[ \t]/g, "").split("\n")) {
    if (/^BEGIN:VALARM$/i.test(l)) { alarm = true; continue; }               // the owner's alarms are theirs, not the guest's
    if (/^END:VALARM$/i.test(l)) { alarm = false; continue; }
    if (alarm || !l || /^(ATTENDEE|ORGANIZER|X-APPLE-)/i.test(l)) continue;   // other invitees' addresses stay private
    lines.push(/^BEGIN:VCALENDAR$/i.test(l) ? "BEGIN:VCALENDAR\r\nMETHOD:PUBLISH" : fold(l));
  }
  const body = lines.join("\r\n") + "\r\n";
  return new Response(body, { headers: { "content-type": "text/calendar; charset=utf-8", "content-disposition": 'inline; filename="invite.ics"', "cache-control": "private, no-store", "x-robots-tag": "noindex" } });
}
