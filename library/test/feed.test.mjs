// Show feeds: chau/show.mjs (outline → episodes, invitations) and GET /m/<token>/feed.xml (feed.js),
// on the built Worker in Miniflare. Run with `npm test` (it builds first); GALLERY_D1=1 runs it over D1.

import { Miniflare } from "miniflare";
import { readdirSync, readFileSync } from "node:fs";
import { webcrypto as crypto } from "node:crypto";
import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";
import { parseOutline, speakable, episodeFile, refusePath, showName, pickVoice, makeInvites, MANIFEST } from "../chau/show.mjs";

const BUILD = new URL("../.test-build/", import.meta.url).pathname;
const TEAM = "team.cloudflareaccess.com";
const AUD = "test-aud";
const OWNER = "owner@example.com";
const CLIENT = "client-id.access";
const ORIGIN = "http://gallery.test";

const keys = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
const jwk = { ...(await crypto.subtle.exportKey("jwk", keys.publicKey)), kid: "k1", alg: "RS256" };
const b64 = (x) => Buffer.from(x).toString("base64url");
async function jwt(claims) {
  const now = Math.floor(Date.now() / 1000);
  const body = { aud: [AUD], iss: "https://" + TEAM, exp: now + 600, iat: now, ...claims };
  const data = b64(JSON.stringify({ alg: "RS256", kid: "k1" })) + "." + b64(JSON.stringify(body));
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", keys.privateKey, new TextEncoder().encode(data));
  return data + "." + b64(new Uint8Array(sig));
}
const serviceJwt = await jwt({ common_name: CLIENT });

const WITH_D1 = !!process.env.GALLERY_D1;
const textModules = readdirSync(BUILD).filter((f) => /\.(css|js)$/.test(f) && f !== "worker.js");
const mf = new Miniflare({
  modules: [{ type: "ESModule", path: BUILD + "worker.js" }, ...textModules.map((f) => ({ type: "Text", path: BUILD + f }))],
  compatibilityDate: "2026-08-01",
  ...(WITH_D1 ? { d1Databases: { DB: "gallery-d1-feed-test" } } : {}),
  r2Buckets: { PUBLIC: "p", MAIN: "m", KEEP: "k", TMP: "t", ARCHIVE: "a" },
  bindings: { ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD, OWNER_EMAIL: OWNER, SERVICE_CLIENT_ID: CLIENT },
  outboundService: (req) => (new URL(req.url).pathname === "/cdn-cgi/access/certs" ? Response.json({ keys: [jwk] }) : new Response("offline", { status: 503 })),
});
const MAIN = await mf.getR2Bucket("MAIN");
const DB = WITH_D1 ? await mf.getD1Database("DB") : null;
if (DB) {
  const dir = new URL("../migrations/", import.meta.url).pathname;
  for (const f of readdirSync(dir).filter((f) => /^\d{4}_.*\.sql$/.test(f)).sort()) {
    const sql = readFileSync(dir + f, "utf8").replace(/--.*$/gm, "");
    for (const st of sql.split(/;\s*$/m).map((x) => x.trim()).filter(Boolean)) await DB.prepare(st).run();
  }
}

// the Mac's call into the owner's API (what chau/show.mjs sends, with the service token's JWT)
const mac = (path, init = {}) => mf.dispatchFetch(ORIGIN + path, { ...init, headers: { "cf-access-jwt-assertion": serviceJwt, "x-gallery": "1", "content-type": "application/json", ...(init.headers || {}) } });
const get = (path, headers = {}) => mf.dispatchFetch(ORIGIN + path, { headers });
const pathOf = (u) => new URL(u).pathname;

async function patchInvite(id, fn) {
  if (DB) {
    const row = await DB.prepare("SELECT doc FROM shares WHERE id = ?").bind(id).first();
    const v = fn(JSON.parse(row.doc));
    await DB.prepare("UPDATE shares SET doc = ?, expires_at = ? WHERE id = ?").bind(JSON.stringify(v), v.expires || 0, id).run();
    return;
  }
  const k = (await MAIN.list({ prefix: "invites/" + id })).objects[0].key;
  await MAIN.put(k, JSON.stringify(fn(await (await MAIN.get(k)).json())));
}

let passed = 0;
const test = async (name, fn) => {
  try {
    await fn();
    passed++;
    console.log("ok   " + name);
  } catch (e) {
    console.log("FAIL " + name + "\n     " + (e && e.message) + (process.env.STACK ? "\n" + e.stack : ""));
    process.exitCode = 1;
  }
};

// ---------- the outline ----------

await test("outline: one episode per ## section, in order, Markdown read as plain speech", async () => {
  const o = parseOutline(readFileSync(new URL("./fixtures/sample-outline.md", import.meta.url), "utf8"), "x");
  assert.equal(o.title, "Study Feed Sample");
  assert.match(o.description, /three-part sample/);
  assert.deepEqual(o.episodes.map((e) => [e.n, e.title]), [[1, "Offer and acceptance"], [2, "Consideration"], [3, "Remedies"]]);
  assert.match(o.episodes[0].text, /^Offer and acceptance\.\n\nA contract needs an offer, an acceptance/);
  assert.match(o.episodes[0].text, /See the Restatement for the rule\./);
  assert.doesNotMatch(o.episodes[0].text, /https?:|\*|\[/);
  assert.match(o.episodes[1].text, /A bargained-for exchange\.\nPast consideration/);
  assert.equal(speakable("```\nkeep **this**\n```"), "keep this.", "code reads as its text");
  assert.equal(parseOutline("```\n## code\n```\n## Real\nText", "f").episodes.length, 1, "a ## inside a code block is not a section");
  assert.equal(parseOutline("## Một\nXin chào", "Thử").title, "Thử", "no # title: the file name");
});

await test("outline: file names keep outline order; Matters and Raven are refused; voices by language", async () => {
  assert.equal(episodeFile(3, "Offer / acceptance: rule", 3), "03 Offer - acceptance- rule.m4a");
  assert.equal(episodeFile(7, "x", 120), "007 x.m4a");
  assert.equal(episodeFile(1, "..hidden", 1), "01 hidden.m4a");
  assert.equal(showName("../Bar"), "-Bar");
  assert.equal(showName("  "), null);
  for (const p of ["/Users/a/Matters/x.md", "/Users/a/raven/b/x.md", "C:\\Matters\\x.md"]) assert.ok(refusePath(p), p);
  for (const p of ["/Users/a/Matters.md", "/Users/a/Bar/Ravenna/x.md"]) assert.ok(!refusePath(p), p);
  const installed = ["Ava (Premium)", "Linh", "Thomas", "Amélie"];
  assert.equal(pickVoice("en", null, installed), "Ava (Premium)");
  assert.equal(pickVoice("vi", null, installed), "Linh");
  assert.equal(pickVoice("fr", null, ["Amélie"]), "Amélie");
  assert.throws(() => pickVoice("vi", null, ["Ava (Premium)"]), /no vi voice installed/);
  assert.throws(() => pickVoice("en", "Nobody", installed), /not installed/);
});

// ---------- the feed ----------

const SHOW = "Shows/Bar & Co";
const audio = (n) => new Uint8Array(1000 + n).fill(n);
const manifest = {
  title: "Bar & Co <Review>",
  description: "Contracts, then torts.",
  lang: "en",
  updated: "2026-11-06T12:00:00Z",
  episodes: [
    { n: 2, id: "id-two", title: "Consideration", file: "02 Consideration.m4a", duration: 75, summary: "Bargained-for exchange." },
    { n: 1, id: "id-one", title: "Offer & acceptance", file: "01 Offer & acceptance.m4a", duration: 3725, summary: "Mirror image." },
    { n: 3, id: "id-three", title: "Remedies", file: "03 Remedies.m4a", duration: 9, summary: "" },
    { n: 4, id: "id-gone", title: "Not uploaded", file: "04 Not uploaded.m4a", duration: 9 },
  ],
};
await MAIN.put("files/" + SHOW + "/" + MANIFEST, JSON.stringify(manifest));
for (const e of manifest.episodes.slice(0, 3)) await MAIN.put("files/" + SHOW + "/" + e.file, audio(e.n), { httpMetadata: { contentType: "audio/mp4" } });
await MAIN.put("files/Plain/photo.jpg", new Uint8Array([1, 2, 3]));

const showOf = (s) => s.replace(/^Shows\//, "");
let feedInv, webInv;

await test("invite command: a view-only feed link and, for a guest, a web link that can react and comment", async () => {
  const links = await makeInvites(mac, { show: showOf(SHOW), name: "Mom", days: 30, guest: true });
  assert.deepEqual(links.map((l) => l.kind), ["feed", "web"]);
  [feedInv, webInv] = links;
  assert.match(pathOf(feedInv.url), /^\/m\/[A-Za-z0-9_-]{43}\/feed\.xml$/);
  const list = await (await mac("/main/api/invites?dir=" + encodeURIComponent(SHOW))).json();
  const f = list.find((i) => i.id === feedInv.id);
  const w = list.find((i) => i.id === webInv.id);
  assert.equal(f.viewOnly, true);
  assert.equal(f.name, "Mom · podcast");
  assert.ok(f.expires > Date.now() + 29 * 86400e3 && f.expires < Date.now() + 31 * 86400e3, "expires in 30 days");
  assert.deepEqual({ ...w.perms }, { view: true, download: true, upload: false, comment: true, react: true, annotate: false });
  assert.equal(w.viewOnly, false);
  // the feed link writes nothing, so it can never be claimed and locked to one signed-in browser
  const cap = await mf.dispatchFetch(ORIGIN + pathOf(feedInv.url).replace("/feed.xml", "/api/caption"), {
    method: "PUT",
    headers: { origin: ORIGIN },
    body: JSON.stringify({ kind: "main", path: SHOW + "/01 Offer & acceptance.m4a", op: "add", text: "hi" }),
  });
  assert.equal(cap.status, 403);
});

await test("feed: RSS 2.0 + iTunes, serial, outline order, enclosures on the link's own file route", async () => {
  const r = await get(pathOf(feedInv.url));
  assert.equal(r.status, 200);
  assert.match(r.headers.get("content-type"), /^application\/rss\+xml/);
  assert.equal(r.headers.get("x-robots-tag"), "noindex");
  const body = await r.text();
  const lint = spawnSync("xmllint", ["--noout", "-"], { input: body, encoding: "utf8" });
  assert.equal(lint.status, 0, "xmllint: " + lint.stderr);
  assert.match(body, /<rss version="2\.0" xmlns:itunes="http:\/\/www\.itunes\.com\/dtds\/podcast-1\.0\.dtd"/);
  assert.match(body, /<itunes:type>serial<\/itunes:type>/);
  assert.match(body, /<title>Bar &amp; Co &lt;Review&gt;<\/title>/);
  const items = [...body.matchAll(/<item>([\s\S]*?)<\/item>/g)].map((m) => m[1]);
  assert.equal(items.length, 3, "an episode whose file is missing is left out");
  assert.deepEqual(items.map((i) => i.match(/<itunes:episode>(\d+)</)[1]), ["1", "2", "3"]);
  assert.deepEqual(items.map((i) => i.match(/<guid isPermaLink="false">([^<]+)</)[1]), ["id-one", "id-two", "id-three"]);
  assert.match(items[0], /<itunes:duration>01:02:05<\/itunes:duration>/);
  const base = pathOf(feedInv.url).replace(/\/feed\.xml$/, "");
  for (const [i, it] of items.entries()) {
    const [, u, len, type] = it.match(/<enclosure url="([^"]+)" length="(\d+)" type="([^"]+)"\/>/);
    assert.equal(type, "audio/mp4");
    const href = u.replace(/&amp;/g, "&");
    assert.ok(href.startsWith(ORIGIN + base + "/f/"), href);
    assert.equal(Number(len), 1001 + i);
    const a = await get(pathOf(href));
    assert.equal(a.status, 200, href);
    assert.equal((await a.arrayBuffer()).byteLength, Number(len));
  }
  assert.equal((await mf.dispatchFetch(ORIGIN + pathOf(feedInv.url), { method: "HEAD" })).status, 200);
});

await test("feed: wrong, revoked or expired token, or a folder with no show, is the same 404", async () => {
  const bad = await get("/m/" + "A".repeat(43) + "/feed.xml");
  assert.equal(bad.status, 404);
  const badBody = await bad.text();
  assert.doesNotMatch(badBody, /Bar|show|feed/i);
  assert.equal((await get("/m/short/feed.xml")).status, 404);

  // a folder without .show.json: nothing says a show could be there
  const plain = await (await mac("/main/api/invites", { method: "POST", body: JSON.stringify({ name: "Plain guest", ttl: 0, dir: "Plain" }) })).json();
  const pr = await get(pathOf(plain.url) + "/feed.xml");
  assert.equal(pr.status, 404);
  assert.equal(await pr.text(), badBody);

  // expired
  const exp = (await makeInvites(mac, { show: showOf(SHOW), name: "Friend", days: 1 }))[0];
  assert.equal((await get(pathOf(exp.url))).status, 200);
  await patchInvite(exp.id, (v) => ({ ...v, expires: Date.now() - 1000 }));
  const er = await get(pathOf(exp.url));
  assert.equal(er.status, 404);
  assert.equal(await er.text(), badBody);

  // revoked: the feed and every enclosure go at once
  const rev = (await makeInvites(mac, { show: showOf(SHOW), name: "Ami", days: 7 }))[0];
  const enc = (await (await get(pathOf(rev.url))).text()).match(/<enclosure url="([^"]+)"/)[1].replace(/&amp;/g, "&");
  assert.equal((await mac("/main/api/invites/" + rev.id, { method: "DELETE" })).status, 200);
  const rr = await get(pathOf(rev.url));
  assert.equal(rr.status, 404);
  assert.equal(await rr.text(), badBody);
  assert.equal((await get(pathOf(enc))).status, 404);
});

await test("feed: only the episodes this link may see (rooms, per-file view off)", async () => {
  const room = await (await mac("/main/api/invites", { method: "POST", body: JSON.stringify({ name: "Room guest", ttl: 0, dir: SHOW, items: ["03 Remedies.m4a"] }) })).json();
  const body = await (await get(pathOf(room.url) + "/feed.xml")).text();
  assert.deepEqual([...body.matchAll(/<itunes:title>([^<]+)</g)].map((m) => m[1]), ["Remedies"]);
  assert.match(body, /<itunes:episode>1<\/itunes:episode>/);
  await mac("/main/api/invites/" + feedInv.id, { method: "PATCH", body: JSON.stringify({ overrides: { "02 Consideration.m4a": { view: false } } }) });
  const b2 = await (await get(pathOf(feedInv.url))).text();
  assert.doesNotMatch(b2, /Consideration/);
  await mac("/main/api/invites/" + room.id, { method: "PATCH", body: JSON.stringify({ overrides: { "03 Remedies.m4a": { view: false } } }) });
  assert.equal((await get(pathOf(room.url) + "/feed.xml")).status, 404, "nothing to hear is a 404");
});

console.log(`\n${passed} passed`);
await mf.dispose();
