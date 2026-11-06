// node --test worker/test: CalDAV Phase 0 against an in-memory R2 (same calls the Worker makes).
import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import worker from "../src/index.js";

class Mem {
  m = new Map(); n = 0;
  obj(key, v) { return { key, size: v.body.length, etag: v.etag, httpEtag: `"${v.etag}"`, customMetadata: v.cm, body: v.body, text: async () => v.body, json: async () => JSON.parse(v.body) }; }
  async head(k) { const v = this.m.get(k); return v ? this.obj(k, v) : null; }
  async get(k) { return this.head(k); }
  async put(k, body, o = {}) {
    const cur = this.m.get(k);
    if (o.onlyIf?.etagDoesNotMatch === "*" && cur) return null;
    if (o.onlyIf?.etagMatches && (!cur || cur.etag !== o.onlyIf.etagMatches)) return null;
    const v = { body: String(body), etag: "e" + ++this.n, cm: o.customMetadata || {} }; this.m.set(k, v); return this.obj(k, v);
  }
  async delete(k) { this.m.delete(k); }
  async list({ prefix = "", delimiter }) {
    const objects = [], pre = new Set();
    for (const [k, v] of [...this.m].sort()) { if (!k.startsWith(prefix)) continue; const rest = k.slice(prefix.length); if (delimiter && rest.includes(delimiter)) pre.add(prefix + rest.slice(0, rest.indexOf(delimiter) + 1)); else objects.push(this.obj(k, v)); }
    return { objects, delimitedPrefixes: [...pre], truncated: false };
  }
}
const PASS = "test-app-password";
const env = () => ({ STORE: new Mem(), CALDAV_USER: "chau", CALDAV_PASS_HASH: createHash("sha256").update(PASS).digest("hex") });
const AUTH = "Basic " + Buffer.from("chau:" + PASS).toString("base64");
const call = (e, method, path, body, headers = {}) => worker.fetch(new Request("https://x" + path, { method, body, headers: { Authorization: AUTH, ...headers } }), e);
const PF = props => `<?xml version="1.0"?><A:propfind xmlns:A="DAV:" xmlns:B="urn:ietf:params:xml:ns:caldav" xmlns:C="http://calendarserver.org/ns/"><A:prop>${props}</A:prop></A:propfind>`;
const ICS = (uid, s = "Lunch") => `BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:${uid}\r\nDTSTART:20261028T120000Z\r\nDTEND:20261028T130000Z\r\nSUMMARY:${s}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n`;

test("well-known redirects and auth is required", async () => {
  const e = env();
  const r = await worker.fetch(new Request("https://x/.well-known/caldav"), e);
  assert.equal(r.status, 301); assert.equal(r.headers.get("Location"), "/dav/");
  assert.equal((await worker.fetch(new Request("https://x/dav/", { method: "PROPFIND" }), e)).status, 401);
  const bad = "Basic " + Buffer.from("chau:nope").toString("base64");
  assert.equal((await worker.fetch(new Request("https://x/dav/", { method: "PROPFIND", headers: { Authorization: bad } }), e)).status, 401);
  assert.equal((await worker.fetch(new Request("https://x/dav/", { method: "PROPFIND" }), { STORE: e.STORE })).status, 503);
});

test("discovery: principal, home set, default calendar", async () => {
  const e = env();
  let t = await (await call(e, "PROPFIND", "/", PF("<A:current-user-principal/>"), { Depth: "0" })).text();
  assert.match(t, /<d:current-user-principal><d:href>\/dav\/principals\/chau\/<\/d:href>/);
  t = await (await call(e, "PROPFIND", "/dav/principals/chau/", PF("<B:calendar-home-set/><A:displayname/><B:schedule-inbox-URL/>"), { Depth: "0" })).text();
  assert.match(t, /<c:calendar-home-set><d:href>\/dav\/calendars\/chau\/<\/d:href>/);
  assert.match(t, /404 Not Found/); // schedule-inbox-URL not offered in Phase 0
  t = await (await call(e, "PROPFIND", "/dav/calendars/chau/", PF("<A:resourcetype/><A:displayname/><C:getctag/><A:current-user-privilege-set/>"), { Depth: "1" })).text();
  assert.match(t, /\/dav\/calendars\/chau\/main\/<\/d:href>.*<c:calendar\/>.*Calendar.*<d:privilege><d:all\/>/s);
  assert.ok(e.STORE.m.has("caldav/users/chau/main/.calendar.json"));
  assert.equal((await call(e, "PROPFIND", "/dav/calendars/someone/", PF("<A:displayname/>"))).status, 403);
});

test("PUT, list, multiget, query, ctag, conditional writes, delete to trash", async () => {
  const e = env(), cal = "/dav/calendars/chau/main/";
  await call(e, "PROPFIND", "/dav/calendars/chau/", PF("<A:displayname/>"), { Depth: "1" });
  const ctagOf = async () => /<cs:getctag>([^<]+)</.exec(await (await call(e, "PROPFIND", cal, PF("<C:getctag/>"), { Depth: "0" })).text())[1];
  const c0 = await ctagOf();
  let r = await call(e, "PUT", cal + "A-1.ics", ICS("A-1"), { "If-None-Match": "*", "Content-Type": "text/calendar" });
  assert.equal(r.status, 201); const etag = r.headers.get("ETag"); assert.ok(etag);
  assert.equal((await call(e, "PUT", cal + "A-1.ics", ICS("A-1"), { "If-None-Match": "*" })).status, 412);
  const c1 = await ctagOf(); assert.notEqual(c0, c1);
  let t = await (await call(e, "PROPFIND", cal, PF("<A:getetag/>"), { Depth: "1" })).text();
  assert.ok(t.includes(cal + "A-1.ics") && t.includes(etag.replace(/"/g, "&quot;")));
  t = await (await call(e, "REPORT", cal, `<B:calendar-multiget xmlns:A="DAV:" xmlns:B="urn:ietf:params:xml:ns:caldav"><A:prop><A:getetag/><B:calendar-data/></A:prop><A:href>${cal}A-1.ics</A:href><A:href>${cal}missing.ics</A:href></B:calendar-multiget>`)).text();
  assert.match(t, /SUMMARY:Lunch/); assert.match(t, /missing\.ics<\/d:href><d:status>HTTP\/1.1 404/);
  t = await (await call(e, "REPORT", cal, `<B:calendar-query xmlns:A="DAV:" xmlns:B="urn:ietf:params:xml:ns:caldav"><A:prop><A:getetag/></A:prop><B:filter><B:comp-filter name="VCALENDAR"/></B:filter></B:calendar-query>`)).text();
  assert.match(t, /A-1\.ics/); assert.doesNotMatch(t, /calendar-data/);
  assert.equal((await call(e, "PUT", cal + "A-1.ics", ICS("A-1", "Dinner"), { "If-Match": '"stale"' })).status, 412);
  r = await call(e, "PUT", cal + "A-1.ics", ICS("A-1", "Dinner"), { "If-Match": etag });
  assert.equal(r.status, 204);
  assert.match(await (await call(e, "GET", cal + "A-1.ics")).text(), /SUMMARY:Dinner/);
  assert.equal([...e.STORE.m.keys()].filter(k => k.startsWith("caldav/trash/chau/main/A-1.")).length, 1); // old version kept
  assert.equal((await call(e, "DELETE", cal + "A-1.ics")).status, 204);
  assert.equal((await call(e, "GET", cal + "A-1.ics")).status, 404);
  assert.equal([...e.STORE.m.keys()].filter(k => k.startsWith("caldav/trash/")).length >= 1, true);
  assert.equal((await call(e, "PUT", cal + "x.ics", "not ics")).status, 415);
  assert.equal((await call(e, "PUT", cal + "..%2F..%2Fetc.ics", ICS("z"))).status, 404);
});

test("MKCALENDAR, PROPPATCH, soft DELETE", async () => {
  const e = env();
  const mk = `<B:mkcalendar xmlns:A="DAV:" xmlns:B="urn:ietf:params:xml:ns:caldav" xmlns:D="http://apple.com/ns/ical/"><A:set><A:prop><A:displayname>Work</A:displayname><D:calendar-color>#FF0000FF</D:calendar-color></A:prop></A:set></B:mkcalendar>`;
  assert.equal((await call(e, "MKCALENDAR", "/dav/calendars/chau/work/", mk)).status, 201);
  assert.equal((await call(e, "MKCALENDAR", "/dav/calendars/chau/work/", mk)).status, 405);
  const pp = `<A:propertyupdate xmlns:A="DAV:"><A:set><A:prop><A:displayname>Work 2</A:displayname></A:prop></A:set></A:propertyupdate>`;
  assert.equal((await call(e, "PROPPATCH", "/dav/calendars/chau/work/", pp)).status, 207);
  let t = await (await call(e, "PROPFIND", "/dav/calendars/chau/", PF("<A:displayname/>"), { Depth: "1" })).text();
  assert.match(t, /Work 2/);
  await call(e, "PUT", "/dav/calendars/chau/work/w.ics", ICS("w"));
  assert.equal((await call(e, "DELETE", "/dav/calendars/chau/work/")).status, 204);
  t = await (await call(e, "PROPFIND", "/dav/calendars/chau/", PF("<A:displayname/>"), { Depth: "1" })).text();
  assert.doesNotMatch(t, /Work 2/);
  assert.ok(e.STORE.m.has("caldav/users/chau/work/w.ics")); // events kept after a calendar delete
});
