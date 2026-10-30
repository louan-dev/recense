// The assistant's calendar (src/calendar.js) and its tool loop (src/ai.js), against in-memory R2 and a scripted model.
//   node test/calendar.test.mjs
import assert from "node:assert/strict";
import { zoned, localMs, parseEvents, occurrences, buildEvent, editEvent, listEvents, createEvent, updateEvent, addInvitee, inviteIcs, showLocal } from "../src/calendar.js";
import { wantsCalendar } from "../src/ai-core.js";
import { aiRoute } from "../src/ai.js";

let passed = 0;
const test = async (name, fn) => { await fn(); passed++; console.log("ok", name); };
const TZ = "America/Los_Angeles";
const iso = (ms) => new Date(ms).toISOString();

function bucket() {
  const m = new Map(); let n = 0;
  return {
    m,
    async put(key, body, opts = {}) {
      const had = m.get(key);
      if (opts.onlyIf?.etagDoesNotMatch === "*" && had) return null;
      if (opts.onlyIf?.etagMatches && (!had || had.etag !== opts.onlyIf.etagMatches)) return null;
      const etag = "e" + ++n;
      m.set(key, { text: String(body), etag, custom: opts.customMetadata || {} });
      return { etag, httpEtag: `"${etag}"` };
    },
    async get(key) { const o = m.get(key); return o ? { text: async () => o.text, json: async () => JSON.parse(o.text), etag: o.etag } : null; },
    async delete(key) { m.delete(key); },
    async list({ prefix = "", delimiter, cursor } = {}) {
      const keys = [...m.keys()].filter((k) => k.startsWith(prefix)).sort();
      if (delimiter) {
        const pre = new Set(), objs = [];
        for (const k of keys) { const rest = k.slice(prefix.length), i = rest.indexOf(delimiter); if (i >= 0) pre.add(prefix + rest.slice(0, i + 1)); else objs.push(k); }
        return { objects: objs.map((k) => ({ key: k, etag: m.get(k).etag, customMetadata: m.get(k).custom })), delimitedPrefixes: [...pre], truncated: false };
      }
      return { objects: keys.map((k) => ({ key: k, etag: m.get(k).etag, customMetadata: m.get(k).custom })), truncated: false };
    },
  };
}

// ---------- time ----------
await test("local times convert across the end of daylight saving (Nov 1, 2026)", () => {
  assert.equal(iso(zoned(2026, 10, 31, 17, 0, 0, TZ)), "2026-11-01T00:00:00.000Z");   // PDT, -7
  assert.equal(iso(zoned(2026, 11, 2, 17, 0, 0, TZ)), "2026-11-03T01:00:00.000Z");    // PST, -8
  assert.equal(iso(localMs("2026-10-30", "17:00", TZ)), "2026-10-31T00:00:00.000Z");
  assert.throws(() => localMs("10/30/2026", null, TZ)); assert.throws(() => localMs("2026-10-30", "5pm", TZ));
});

// ---------- parsing ----------
const APPLE = [
  "BEGIN:VCALENDAR", "X-WR-CALNAME:Work", "BEGIN:VTIMEZONE", "TZID:America/Los_Angeles", "BEGIN:STANDARD", "DTSTART:19701101T020000", "END:STANDARD", "END:VTIMEZONE",
  "BEGIN:VEVENT", "UID:ABC-1", "SUMMARY:Team sync with a very long title that Apple folds across lines because it is longer than seventy",
  "  five octets", "DTSTART;TZID=America/Los_Angeles:20261028T170000", "DTEND;TZID=America/Los_Angeles:20261028T180000",
  "RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6", "EXDATE;TZID=America/Los_Angeles:20261102T170000",
  "ATTENDEE;CN=Alex:mailto:alex@example.com", "LOCATION:Room 4\\, 2nd floor",
  "BEGIN:VALARM", "TRIGGER:-PT15M", "ACTION:DISPLAY", "DESCRIPTION:alarm text", "END:VALARM", "END:VEVENT", "END:VCALENDAR", ""].join("\r\n");

await test("Apple's events parse: folded lines, TZID, escapes, attendees, alarms ignored", () => {
  const [e] = parseEvents(APPLE, TZ);
  assert.equal(e.uid, "ABC-1"); assert.match(e.title, /seventy five octets$/);
  assert.equal(iso(e.start), "2026-10-29T00:00:00.000Z"); assert.equal(e.end - e.start, 3600e3);
  assert.equal(e.location, "Room 4, 2nd floor"); assert.deepEqual(e.attendees, [{ name: "Alex", email: "alex@example.com" }]);
  assert.equal(e.notes, undefined, "the alarm's DESCRIPTION is not the event's"); assert.equal(e.calendar, "Work");
});
await test("weekly repeats keep 5 pm local across daylight saving, skip EXDATE, stop at COUNT", () => {
  const [e] = parseEvents(APPLE, TZ);
  const occ = occurrences(e, zoned(2026, 10, 1, 0, 0, 0, TZ), zoned(2026, 12, 31, 0, 0, 0, TZ), TZ);
  const local = occ.map((o) => showLocal(o.start, TZ));
  assert.deepEqual(local, ["Wed, Oct 28, 2026, 5:00 PM", "Wed, Nov 4, 2026, 5:00 PM", "Mon, Nov 9, 2026, 5:00 PM", "Wed, Nov 11, 2026, 5:00 PM", "Mon, Nov 16, 2026, 5:00 PM"]);
});
await test("all-day and yearly events (an anniversary) land on the right local day", () => {
  const ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:a\r\nSUMMARY:Anniversary\r\nDTSTART;VALUE=DATE:20260204\r\nDTEND;VALUE=DATE:20260205\r\nRRULE:FREQ=YEARLY\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
  const [e] = parseEvents(ics, TZ);
  assert.ok(e.allDay);
  const occ = occurrences(e, localMs("2027-02-01", null, TZ), localMs("2027-02-10", null, TZ), TZ);
  assert.equal(occ.length, 1); assert.match(showLocal(occ[0].start, TZ, true), /Feb 4, 2027/);
});
await test("editing keeps what Apple wrote (alarms, attendees) and replaces only what changed", () => {
  const out = editEvent(APPLE, { SUMMARY: "SUMMARY:Short" }, ["ATTENDEE;CN=Mom:mailto:mom@example.com"], Date.UTC(2026, 9, 29));
  const [e] = parseEvents(out, TZ);
  assert.equal(e.title, "Short"); assert.equal(e.attendees.length, 2);
  assert.match(out, /BEGIN:VALARM\r\nTRIGGER:-PT15M/); assert.ok(!/five octets/.test(out), "the folded continuation of the old title is gone");
  assert.match(out, /LAST-MODIFIED:20261029T000000Z/);
});
await test("a built event round-trips", () => {
  const ics = buildEvent({ uid: "U1", title: "Dinner; with, Mom", start: localMs("2026-10-30", "17:00", TZ), end: localMs("2026-10-30", "18:30", TZ), location: "Home" }, TZ);
  const [e] = parseEvents(ics, TZ);
  assert.equal(e.title, "Dinner; with, Mom"); assert.equal(showLocal(e.start, TZ), "Fri, Oct 30, 2026, 5:00 PM"); assert.equal(e.end - e.start, 90 * 60e3);
});

// ---------- the stores ----------
const env = { MAIN: bucket(), CALENDAR: bucket(), OWNER_TZ: TZ, CALDAV_USER: "chau" };
const ORIGIN = "https://g.test";
await env.MAIN.put("ledger/calendar/views/tree.json", JSON.stringify({ files: {
  "Work/ABC-1.ics": { hash: "aa11" }, "Home/notes.txt": { hash: "bb22" } } }));
await env.MAIN.put("ledger/calendar/objects/aa/aa11", APPLE);

let created;
await test("create_event writes the owner's own calendar the way a CalDAV client would", async () => {
  created = await createEvent(env, { title: "Coffee with Sam", date: "2026-10-30", start_time: "17:00" });
  assert.ok(created.ok); assert.match(created.when, /Fri, Oct 30, 2026, 5:00 PM – 6:00 PM/);
  const key = [...env.CALENDAR.m.keys()].find((k) => k.endsWith(".ics"));
  assert.match(key, /^caldav\/users\/chau\/main\/[0-9A-F-]+\.ics$/);
  assert.equal(env.CALENDAR.m.get(key).custom.uid, created.uid);
  assert.ok(env.CALENDAR.m.has("caldav/users/chau/main/.calendar.json"));
  await assert.rejects(createEvent(env, { title: " ", date: "2026-10-30" }));
});
await test("list_events merges the own calendar and the iCloud backup, marks what's editable", async () => {
  const r = await listEvents(env, "2026-10-26", "2026-11-01");
  const titles = r.events.map((e) => `${e.title}|${e.source}|${e.editable}`);
  assert.ok(titles.includes("Coffee with Sam|own|true"));
  assert.ok(titles.some((t) => /^Team sync.*\|icloud\|false$/.test(t)));
  assert.ok(env.MAIN.m.has("ai/cal-mirror.json"), "parsed backup events are cached");
  await assert.rejects(listEvents(env, "2026-01-01", "2027-12-31"));
});
await test("update_event moves it and keeps the old version in Sync's trash", async () => {
  const u = await updateEvent(env, { uid: created.uid, date: "2026-10-31", start_time: "10:00" });
  assert.match(u.when, /Sat, Oct 31, 2026, 10:00 AM/);
  assert.ok([...env.CALENDAR.m.keys()].some((k) => k.startsWith("caldav/trash/chau/main/")));
  await assert.rejects(updateEvent(env, { uid: "ABC-1", title: "x" }), /iCloud events can't be edited/);
});
let link;
await test("add_invitee asks for the email first, then adds the invitee and returns a private link", async () => {
  const ask = await addInvitee(env, { uid: created.uid, name: "Mom" }, ORIGIN);
  assert.equal(ask.ok, false); assert.equal(ask.need, "email");
  assert.equal((await addInvitee(env, { uid: created.uid, name: "Mom", email: "not an email" }, ORIGIN)).need, "email");
  const r = await addInvitee(env, { uid: created.uid, name: "Mom", email: "mom@example.com" }, ORIGIN);
  assert.ok(r.ok); link = r.link; assert.match(link, /^https:\/\/g\.test\/c\/[0-9a-f]{32}\.ics$/);
  const key = [...env.CALENDAR.m.keys()].find((k) => k.startsWith("caldav/users/") && k.endsWith(".ics"));
  assert.match(env.CALENDAR.m.get(key).text.replace(/\r\n[ \t]/g, ""), /ATTENDEE;CN="Mom";ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:mom@example\.com/);
  await addInvitee(env, { uid: created.uid, name: "Mom", email: "MOM@example.com" }, ORIGIN);
  assert.equal((env.CALENDAR.m.get(key).text.match(/ATTENDEE/g) || []).length, 1, "the same person isn't added twice");
});
await test("the invite link serves the event without other people's addresses; bad or expired tokens are 404", async () => {
  const token = link.match(/\/c\/([0-9a-f]{32})\.ics$/)[1];
  const r = await inviteIcs(env, token);
  assert.equal(r.status, 200); assert.match(r.headers.get("content-type"), /text\/calendar/);
  const body = await r.text();
  assert.match(body, /METHOD:PUBLISH/); assert.match(body, /SUMMARY:Coffee with Sam/); assert.ok(!/mom@example|ATTENDEE/.test(body));
  assert.equal((await inviteIcs(env, "0".repeat(32))).status, 404);
  assert.equal((await inviteIcs(env, "../../x")).status, 404);
  const rec = [...env.MAIN.m.keys()].find((k) => k.startsWith("ai/invites/"));
  await env.MAIN.put(rec, JSON.stringify({ ...JSON.parse(env.MAIN.m.get(rec).text), exp: Date.now() - 1 }));
  assert.equal((await inviteIcs(env, token)).status, 404);
  assert.ok(![...env.MAIN.m.keys()].some((k) => k.includes(token)), "only the token's hash is stored");
});

// ---------- the assistant drives it ----------
await test("calendar questions are recognised (planner flag first, words as fallback)", () => {
  assert.equal(wantsCalendar('{"queries":[],"calendar":true}', "x"), true);
  assert.equal(wantsCalendar('{"queries":[],"calendar":false}', "do I have anything this week?"), false);
  assert.equal(wantsCalendar("junk", "do I have anything scheduled this week?"), true);
  assert.equal(wantsCalendar(null, "what is photosynthesis?"), false);
  assert.equal(wantsCalendar(null, "mom@example.com", [{ role: "assistant", content: "What's Mom's email so I can invite her to the event?" }]), true);
});
await test("the assistant lists, creates and shares through tools, and asks for the email", async () => {
  const script = [
    { choices: [{ message: { content: "", tool_calls: [{ id: "c1", function: { name: "create_event", arguments: JSON.stringify({ title: "Dinner", date: "2026-11-02", start_time: "17:00" }) } }] } }] },
    (msgs) => { const res = JSON.parse(msgs.at(-1).content); return { tool_calls: [{ name: "add_invitee", arguments: { uid: res.uid, name: "Mom" } }] }; },
    (msgs) => { assert.equal(JSON.parse(msgs.at(-1).content).need, "email"); return { response: "What's Mom's email address?" }; },
  ];
  const calls = [];
  const ai = {
    async run(model, input) {
      if (input.text) return { data: input.text.map(() => new Array(1024).fill(0.01)) };
      if (!input.tools && !input.stream) return { response: '{"queries":["dinner"],"calendar":true}' };
      calls.push(JSON.parse(JSON.stringify(input)));       // a snapshot: the loop keeps adding to the same array
      const next = script.shift();
      return typeof next === "function" ? next(input.messages) : next;
    },
  };
  const vectors = { async query() { return { matches: [] }; } };
  const e2 = { ...env, AI: ai, VECTORS: vectors };
  const r = await aiRoute(new Request(ORIGIN + "/main/api/ai/ask", { method: "POST", body: JSON.stringify({ q: "Add dinner Monday at 5 pm and share it with mom" }) }), e2, { waitUntil: () => {} }, new URL(ORIGIN + "/main/api/ai/ask"), "/main/api/ai/ask", "POST");
  const rows = (await r.text()).trim().split("\n").map((l) => JSON.parse(l));
  assert.deepEqual(rows.filter((x) => x.tool).map((x) => `${x.tool}:${x.ok}`), ["create_event:true", "add_invitee:false"]);
  assert.equal(rows.filter((x) => x.t).map((x) => x.t).join(""), "What's Mom's email address?");
  assert.ok(rows.at(-1).done);
  assert.match(calls[0].messages[0].content, /Calendar: it is now/); assert.equal(calls[0].tools.length, 4);
  assert.equal(calls[1].messages.at(-2).tool_calls[0].function.name, "create_event", "the tool call is kept in the conversation");
  const all = await listEvents(env, "2026-11-02", "2026-11-02");
  assert.ok(all.events.some((x) => x.title === "Dinner" && /5:00 PM/.test(x.when)));
});

console.log(`\n${passed} passed`);
