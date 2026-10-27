// Transcript corrections, glossary, share rate limit, the transcription lock and the zero-error replay
// (spec §9): corrections.js on its own, then the built Worker in Miniflare. Run with `npm test`.

import { Miniflare } from "miniflare";
import { readdirSync } from "node:fs";
import { webcrypto as crypto } from "node:crypto";
import assert from "node:assert/strict";
import * as C from "../src/corrections.js";
import * as L from "../src/layout.js";

const BUILD = new URL("../.test-build/", import.meta.url).pathname;
const TEAM = "team.cloudflareaccess.com";
const AUD = "test-aud";
const OWNER = "owner@example.com";
const ORIGIN = "http://gallery.test";

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

// a v2.json line: words spread one per 0.5 s from t
const line = (id, t, text, english) => ({
  id,
  words: text.split(" ").map((w, i) => ({ text: w, start: t + i * 0.5, end: t + i * 0.5 + 0.4 })),
  ...(english ? { english } : {}),
});
const texts = (lines) => lines.map((l) => (l.fixed ? l.text : l.words.map((w) => w.t).join(" ")));

// ---------- corrections.js ----------

await test("apply: by segId, else ≥50 % time overlap; Recense's own edits first; glossary only where nobody corrected", () => {
  const asr = { lines: [line(1, 0, "bonjour tout le monde"), line(2, 3, "je suis a pari"), line(3, 6, "PARI pari Parisien")] };
  let doc = { overrides: [{ segId: "1", start: 0, end: 1.9, field: "text", to: "Bonjour à tous", src: "main", updatedAt: 1 }], glossary: { pari: "Paris" } };
  assert.deepEqual(texts(C.correctedLines(asr, doc)), ["Bonjour à tous", "je suis a Paris", "PARIS Paris Parisien"]);
  // the override's line was remade with another id: found by its time; a line under half its span is not
  const moved = { lines: [line(10, 0.2, "bonjour tout le monde"), line(11, 3, "je suis a pari")] };
  assert.equal(texts(C.correctedLines(moved, doc))[0], "Bonjour à tous");
  doc.overrides[0].end = 0.3; // only 0.1 s of it overlaps line 10
  doc.overrides[0].segId = "gone";
  assert.equal(texts(C.correctedLines(moved, doc))[0], "bonjour tout le monde");
  // an override of nothing hides the line; tr.en replaces the English
  doc = { overrides: [{ segId: "2", start: 3, end: 5, field: "text", to: "  ", updatedAt: 1 }, { segId: "1", field: "tr.en", to: "Hi all", updatedAt: 1 }] };
  const out = C.present(C.correctedLines(asr, doc));
  assert.deepEqual(out.map((l) => l.id), ["1", "3"]);
  assert.equal(out[0].en, "Hi all");
  // Recense's own edit (a time stretch) is laid over first and is never taken over by an older override's overlap
  doc = {
    edits: [{ id: 1, a: 3, b: 5, from: "je suis a pari", words: [{ text: "je", start: 3, end: 3.4 }, { text: "suis", start: 3.5, end: 3.9 }, { text: "à", start: 4, end: 4.4 }, { text: "Paris", start: 4.5, end: 4.9 }], at: 50 }],
    english: {},
    overrides: [{ segId: "2", start: 3, end: 4.9, field: "text", to: "older", updatedAt: 10 }],
  };
  const r = C.present(C.correctedLines(asr, doc));
  assert.equal(r[1].id, String(C.EDITED + 1));
  assert.equal(r[1].text, "je suis à Paris");
  // ... but a later one, made on that line, wins
  doc.overrides = [{ segId: String(C.EDITED + 1), start: 3, end: 4.9, field: "text", to: "je suis à Paris !", updatedAt: 60 }];
  assert.equal(C.present(C.correctedLines(asr, doc))[1].text, "je suis à Paris !");
});

await test("merge: per segment and field, the latest updatedAt wins", () => {
  const a = [{ segId: "1", field: "text", to: "a", updatedAt: 5 }, { segId: "2", field: "text", to: "b", updatedAt: 9 }];
  const b = [{ segId: "1", field: "text", to: "A", updatedAt: 7 }, { segId: "2", field: "text", to: "B", updatedAt: 3 }, { segId: "2", field: "tr.en", to: "x", updatedAt: 1 }];
  const m = C.mergeOverrides(a, b);
  assert.deepEqual(m.map((o) => o.segId + o.field + o.to).sort(), ["1textA", "2textb", "2tr.enx"]);
});

await test("glossary: single-word replacements, whole word, case-preserving; taught back removes it", () => {
  assert.deepEqual(C.learned("on a mange des crepes", "on a mangé des crêpes."), [["mange", "mangé"], ["crepes", "crêpes"]]);
  assert.deepEqual(C.learned("la tour effel", "la tour Eiffel de Paris"), []); // one word became three: not a single-word replacement
  assert.deepEqual(C.learned("Bonjour", "bonjour"), []);
  const g = C.teach({}, "je vais a pari", "je vais à Paris");
  assert.deepEqual(g, { a: "à", pari: "Paris" });
  C.teach(g, "à", "a");
  assert.deepEqual(g, { a: "", pari: "Paris" }); // forgotten
  assert.equal(C.glossWord("a", g), "a");
  assert.equal(C.glossWord("pari,", g), "Paris,");
  assert.equal(C.glossWord("«PARI»", g), "«PARIS»");
  assert.equal(C.glossWord("parisien", g), "parisien");
  assert.equal(C.cleanText("<b>hi</b> <script>x</script>there"), "hi xthere");
  assert.equal(C.cleanText("x".repeat(2001)), null);
});

await test("layout: an old v2.json splits into asr.json and tr/en.json and joins back; a translation of other words is not shown", () => {
  const v2 = {
    complete: true,
    duration: 9,
    done: [true],
    lyrics: ["x"],
    lines: [
      { id: 1, words: [{ text: "un", start: 0, end: 0.4, lang: "fr" }, { text: "deux", start: 0.5, end: 0.9, lang: "fr" }], english: [{ w: "one", s: [0] }, { w: "two", s: [1] }] },
      { id: 2, words: [{ text: "hello", start: 2, end: 2.4 }], english: [] },
      { id: 3, words: [{ text: "trois", start: 3, end: 3.4 }], english: [{ w: "three", s: [] }], draft: true },
      { id: 4, words: [{ text: "quatre", start: 4, end: 4.4 }] },
    ],
  };
  const { asr, en } = L.split(v2, 5);
  assert.deepEqual(asr.segments.map((s) => [s.id, s.start, s.end, s.text, s.lang]), [[1, 0, 0.9, "un deux", "fr"], [2, 2, 2.4, "hello", undefined], [3, 3, 3.4, "trois", undefined], [4, 4, 4.4, "quatre", undefined]]);
  assert.equal(asr.segments[0].english, undefined); // the original only
  assert.deepEqual([asr.complete, asr.duration, asr.recense], [true, 9, { done: [true], lyrics: ["x"] }]);
  assert.deepEqual(en, {
    lang: "en",
    complete: false,
    updatedAt: 5,
    lines: { 1: { src: "un deux", text: "one two", words: [{ w: "one", s: [0] }, { w: "two", s: [1] }] }, 2: { src: "hello", same: true }, 3: { src: "trois", text: "three", words: [{ w: "three", s: [] }], draft: true } },
  });
  const back = L.join(asr, en);
  assert.deepEqual(back.lines.map((l) => l.english), [v2.lines[0].english, [], [{ w: "three", s: [] }], undefined]);
  assert.deepEqual(C.present(C.correctedLines(back, {})).map((l) => l.en), C.present(C.correctedLines(v2, {})).map((l) => l.en));
  // segment 1 remade with other words: its old English is not laid over them
  asr.segments[0].words = [{ text: "un", start: 0, end: 0.4 }, { text: "deux", start: 0.5, end: 0.9 }, { text: "trois", start: 1, end: 1.2 }];
  assert.equal(L.join(asr, en).lines[0].english, undefined);
  assert.deepEqual(["asr", "tr", "corr", "hist"].map((x) => ({ asr: L.asrName("k"), tr: L.trName("k", "vi"), corr: L.corrName("k"), hist: L.histName("k", 3) })[x]), ["keep/k/asr.json", "keep/k/tr/vi.json", "keep/k/corrections.json", "keep/k/history/3.json"]);
});

// ---------- the Worker ----------

const keys = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
const jwk = { ...(await crypto.subtle.exportKey("jwk", keys.publicKey)), kid: "k1", alg: "RS256" };
const b64 = (x) => Buffer.from(x).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const data = b64(JSON.stringify({ alg: "RS256", kid: "k1" })) + "." + b64(JSON.stringify({ aud: [AUD], iss: "https://" + TEAM, exp: now + 600, iat: now, email: OWNER }));
const ownerJwt = data + "." + b64(new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", keys.privateKey, new TextEncoder().encode(data))));

const textModules = readdirSync(BUILD).filter((f) => /\.(css|js)$/.test(f) && f !== "worker.js");
const mf = new Miniflare({
  modules: [{ type: "ESModule", path: BUILD + "worker.js" }, ...textModules.map((f) => ({ type: "Text", path: BUILD + f }))],
  compatibilityDate: "2026-08-01",
  r2Buckets: { PUBLIC: "p", MAIN: "m", KEEP: "k" },
  bindings: { ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD, OWNER_EMAIL: OWNER },
  outboundService: (req) => (new URL(req.url).pathname === "/cdn-cgi/access/certs" ? Response.json({ keys: [jwk] }) : new Response("offline", { status: 503 })),
});
const MAIN = await mf.getR2Bucket("MAIN");
const KEEP = await mf.getR2Bucket("KEEP");

const owner = (path, init = {}) =>
  mf.dispatchFetch(ORIGIN + path, { ...init, headers: { "cf-access-jwt-assertion": ownerJwt, "x-gallery": "1", ...(init.method && init.method !== "GET" ? { origin: ORIGIN } : {}), ...(init.headers || {}) } });
const anyone = (path, init = {}) => mf.dispatchFetch(ORIGIN + path, { ...init, headers: { "x-gallery": "1", ...(init.headers || {}) } });
const keyOf = async (p) => Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("gallery:files/" + p))).toString("hex").slice(0, 24);
const hexOf = async (b) => Buffer.from(await crypto.subtle.digest("SHA-256", b)).toString("hex");
// the content key Recense computes too (ContentKey in main.swift)
const fpOf = async (bytes) => {
  const b = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  const head = await hexOf(b.slice(0, 65536));
  const tail = b.length <= 65536 ? head : await hexOf(b.slice(b.length - 65536));
  return (await hexOf(new TextEncoder().encode(`fp:${b.length}:${head}:${tail}`))).slice(0, 24);
};
const keepJson = async (k) => {
  const o = await KEEP.get(k);
  return o ? o.json() : null;
};
const mainTx = (p) => owner("/main/api/transcript?path=" + encodeURIComponent(p)).then((r) => r.json());
const mainPut = (p, body) => owner("/main/api/transcript?path=" + encodeURIComponent(p), { method: "PUT", body: JSON.stringify(body) });
// Recense writing a transcript as it does now: keep/<key>/asr.json and its English in keep/<key>/tr/en.json
const putAsr = async (k, v2) => {
  const { asr, en } = L.split(v2);
  await KEEP.put(L.asrName(k), JSON.stringify(asr));
  if (en) await KEEP.put(L.trName(k, "en"), JSON.stringify(en));
};
const putTr = (k, lang, lines, extra = {}) => KEEP.put(L.trName(k, lang), JSON.stringify({ lang, complete: true, updatedAt: 1, lines, ...extra }));
const shareLink = async (p) => (await (await owner("/main/api/link?action=fromMain&days=1", { method: "POST", body: JSON.stringify({ paths: [p] }) })).json()).id;

await test("corrections: an old <key>.edits.json moves to keep/<key>/corrections.json with Recense's own edits; versioned, with history", async () => {
  await MAIN.put("files/Fx/a.mp3", "Fx/a.mp3");
  const k = await keyOf("Fx/a.mp3");
  await KEEP.put("keep/" + k + ".v2.json", JSON.stringify({ complete: true, lines: [line(1, 0, "un deux trois", [{ w: "one", s: [0] }, { w: "two", s: [1] }, { w: "three", s: [2] }]), line(2, 3, "quatre cinq")] }));
  await KEEP.put("keep/" + k + ".edits.json", JSON.stringify({ edits: [], english: { x: [] }, last: 4 }));
  let t = await mainTx("Fx/a.mp3");
  assert.equal(t.version, 0);
  assert.deepEqual(t.lines.map((l) => l.id), ["1", "2"]);
  let r = await mainPut("Fx/a.mp3", { version: 0, edits: [{ segId: "2", field: "text", to: "quatre <i>six</i>" }] });
  assert.equal(r.status, 200);
  let j = await r.json();
  assert.equal(j.version, 1);
  assert.equal(j.lines[1].text, "quatre six");
  assert.ok(j.lines[1].fixed);
  const doc = await keepJson(L.corrName(k));
  assert.equal(doc.last, 4); // Recense's fields are left as they were
  assert.deepEqual(await keepJson("keep/" + k + ".edits.json"), { edits: [], english: { x: [] }, last: 4 }); // the old file is left alone
  assert.deepEqual(doc.english, { x: [] });
  assert.deepEqual([doc.overrides[0].segId, doc.overrides[0].field, doc.overrides[0].src, doc.overrides[0].start, doc.overrides[0].end], ["2", "text", "main", 3, 3.9]);
  assert.deepEqual(doc.glossary, { cinq: "six" });
  assert.ok(await KEEP.head(L.histName(k, 1)));
  assert.equal(await KEEP.head("keep/history/" + k + "/1.json"), null);
  // every correction is logged with what it replaced; removing a line can be put back from the log
  r = await mainPut("Fx/a.mp3", { version: 1, edits: [{ segId: "2", field: "text", to: "" }] });
  assert.equal((await r.json()).lines.length, 1);
  let ch = await (await owner("/main/api/transcript/changes?path=Fx/a.mp3")).json();
  assert.deepEqual(ch.changes.map((c) => [c.v, c.segId, c.from, c.to]), [[2, "2", "quatre six", ""], [1, "2", "quatre cinq", "quatre six"]]);
  r = await mainPut("Fx/a.mp3", { version: 2, edits: [{ segId: "2", field: "text", to: ch.changes[0].from }] });
  j = await r.json();
  assert.equal(j.lines[1].text, "quatre six");
  ch = await (await owner("/main/api/transcript/changes?path=Fx/a.mp3")).json();
  assert.equal(ch.changes.length, 3);
  // the English of a line whose words stay the same in number keeps its alignment
  r = await mainPut("Fx/a.mp3", { version: 3, edits: [{ segId: "1", field: "text", to: "un deux trois!" }] });
  j = await r.json();
  assert.deepEqual(j.lines[0].enw.map((w) => w.s), [[0], [1], [2]]);
  // a correction is never undone by a newer transcript of the same speech
  await putAsr(k, { complete: true, lines: [line(7, 0, "un deux trois"), line(8, 3.1, "quatre cinq")] });
  t = await mainTx("Fx/a.mp3");
  assert.deepEqual(t.lines.map((l) => l.text), ["un deux trois!", "quatre six"]);
  // validation
  assert.equal((await mainPut("Fx/a.mp3", { version: t.version, edits: [{ segId: "99", field: "text", to: "x" }] })).status, 400);
  assert.equal((await mainPut("Fx/a.mp3", { version: t.version, edits: [{ segId: "7", field: "text", to: "x".repeat(2001) }] })).status, 400);
  assert.equal((await mainPut("Fx/a.mp3", { version: t.version, edits: [{ segId: "7", field: "bad", to: "x" }] })).status, 400);
  assert.equal((await mainPut("Fx/a.mp3", { version: t.version, edits: [{ segId: "7", field: "text", to: "x".repeat(70000) }] })).status, 413);
  assert.equal((await mainPut("Fx/none.mp3", { version: 0, edits: [{ segId: "1", field: "text", to: "x" }] })).status, 404);
});

await test("version conflict: 409 with what is saved; merged per segment (latest wins) and retried once", async () => {
  await MAIN.put("files/Fx/c.mp3", "Fx/c.mp3");
  const k = await keyOf("Fx/c.mp3");
  await KEEP.put("keep/" + k + ".v2.json", JSON.stringify({ lines: [line(1, 0, "a b"), line(2, 2, "c d")] }));
  // two viewers both open version 0
  assert.equal((await mainPut("Fx/c.mp3", { version: 0, edits: [{ segId: "1", field: "text", to: "first viewer", updatedAt: Date.now() - 5000 }] })).status, 200);
  const mine = [{ segId: "1", field: "text", to: "second viewer older", updatedAt: Date.now() - 9000 }, { segId: "2", field: "text", to: "second viewer", updatedAt: Date.now() - 1000 }];
  const r = await mainPut("Fx/c.mp3", { version: 0, edits: mine });
  assert.equal(r.status, 409);
  const c = await r.json();
  assert.equal(c.version, 1);
  // the page's merge: keep an edit unless what is saved for that segment is newer
  const keep = mine.filter((e) => !c.overrides.some((o) => o.segId === e.segId && o.field === e.field && o.updatedAt > e.updatedAt));
  assert.deepEqual(keep.map((e) => e.segId), ["2"]);
  const j = await (await mainPut("Fx/c.mp3", { version: c.version, edits: keep })).json();
  assert.deepEqual(j.lines.map((l) => l.text), ["first viewer", "second viewer"]);
  // an older edit sent anyway loses on the server too
  const j2 = await (await mainPut("Fx/c.mp3", { version: 2, edits: [mine[0]] })).json();
  assert.equal(j2.lines[0].text, "first viewer");
});

await test("glossary: a one-word fix is applied to every line nobody corrected, in its case", async () => {
  await MAIN.put("files/Fx/g.mp3", "Fx/g.mp3");
  const k = await keyOf("Fx/g.mp3");
  await KEEP.put("keep/" + k + ".v2.json", JSON.stringify({ lines: [line(1, 0, "la tour effel"), line(2, 3, "Effel est haute"), line(3, 6, "EFFEL effelois")] }));
  const j = await (await mainPut("Fx/g.mp3", { version: 0, edits: [{ segId: "1", field: "text", to: "la tour Eiffel" }] })).json();
  assert.deepEqual(j.lines.map((l) => l.text), ["la tour Eiffel", "Eiffel est haute", "EIFFEL effelois"]);
  assert.deepEqual(j.glossary, { effel: "Eiffel" });
});

await test("share: anyone with the link corrects; 20 edits a minute per address per media, then 429; Main has no limit", async () => {
  await MAIN.put("files/Fx/s.mp3", "Fx/s.mp3");
  const k = await keyOf("Fx/s.mp3");
  await KEEP.put("keep/" + k + ".v2.json", JSON.stringify({ lines: [line(1, 0, "a b c")] }));
  const id = await shareLink("Fx/s.mp3");
  const put = (v, ip, n = 1, headers = {}) =>
    anyone(`/api/transcript?id=${id}&n=000`, { method: "PUT", headers: { "cf-connecting-ip": ip, ...headers }, body: JSON.stringify({ version: v, edits: Array.from({ length: n }, (_, i) => ({ segId: "1", field: "text", to: "edit " + v + "." + i })) }) });
  assert.equal((await put(0, "1.1.1.1", 1, { "x-gallery": "" })).status, 403);
  let v = 0;
  for (let i = 0; i < 4; i++) {
    const r = await put(v, "1.1.1.1", 5);
    assert.equal(r.status, 200, "batch " + i);
    v = (await r.json()).version;
  }
  const r = await put(v, "1.1.1.1");
  assert.equal(r.status, 429);
  assert.equal(r.headers.get("retry-after"), "60");
  assert.equal((await put(v, "2.2.2.2")).status, 200); // another address
  const doc = await keepJson(L.corrName(k));
  assert.equal(doc.overrides[0].src, "share");
  // Main: no limit
  let mv = doc.version;
  for (let i = 0; i < 25; i++) mv = (await (await mainPut("Fx/s.mp3", { version: mv, edits: [{ segId: "1", field: "text", to: "m" + i }] })).json()).version;
  assert.equal(mv, doc.version + 25);
  // history keeps the last 20 versions
  assert.equal(await KEEP.head(L.histName(k, mv - 20)), null);
  assert.ok(await KEEP.head(L.histName(k, mv - 19)));
});

await test("lock: the first viewer queues Recense, the second waits; lapses after 15 min; failure offers Retry; never reruns a done one", async () => {
  await MAIN.put("files/Fx/l.mp3", "Fx/l.mp3");
  const k = await fpOf("Fx/l.mp3");
  const run = (body = {}) => owner("/main/api/transcript/run?path=Fx/l.mp3", { method: "POST", body: JSON.stringify(body) });
  let t = await mainTx("Fx/l.mp3");
  assert.ok(t.pending);
  assert.equal(t.run, null);
  let r = await run();
  assert.equal(r.status, 202);
  const first = await r.json();
  const lock = await keepJson("keep/locks/" + k);
  assert.deepEqual([lock.state, lock.path, lock.src], ["queued", "Fx/l.mp3", "main"]);
  // a second viewer (here on a share link) joins the same run
  const id = await shareLink("Fx/l.mp3");
  r = await anyone(`/api/transcript/run?id=${id}&n=000`, { method: "POST", body: "{}" });
  assert.equal(r.status, 200);
  assert.equal((await r.json()).at, first.at);
  t = await (await anyone(`/api/transcript?id=${id}&n=000`)).json();
  assert.equal(t.run.state, "queued");
  // Recense reports progress, then fails: Retry, not a rerun on its own
  await KEEP.put("keep/locks/" + k, JSON.stringify({ ...lock, state: "running", beat: Date.now(), progress: 0.5 }));
  assert.equal((await mainTx("Fx/l.mp3")).run.progress, 0.5);
  await KEEP.put("keep/locks/" + k, JSON.stringify({ state: "failed", error: "no sound", at: Date.now() }));
  r = await run();
  assert.equal((await r.json()).state, "failed");
  r = await run({ retry: true });
  assert.equal(r.status, 202);
  // a lock nobody beat for 15 minutes has lapsed: the next viewer takes it
  await KEEP.put("keep/locks/" + k, JSON.stringify({ state: "running", at: 1, beat: Date.now() - 16 * 60000, path: "Fx/l.mp3" }));
  assert.equal((await mainTx("Fx/l.mp3")).run, null);
  assert.equal((await run()).status, 202);
  // Recense writes the transcript, then lets go: no run asked for again
  await putAsr(k, { complete: true, lines: [line(1, 0, "fini")] });
  await KEEP.delete("keep/locks/" + k);
  r = await run();
  assert.equal((await r.json()).state, "done");
  assert.equal(await KEEP.head("keep/locks/" + k), null);
  // only an explicit Retranscribe (Main) queues it again; overrides stay
  await mainPut("Fx/l.mp3", { version: 0, edits: [{ segId: "1", field: "text", to: "fini !" }] });
  r = await anyone(`/api/transcript/run?id=${id}&n=000`, { method: "POST", body: JSON.stringify({ retranscribe: true }) });
  assert.equal((await r.json()).state, "done");
  r = await run({ retranscribe: true });
  assert.equal(r.status, 202);
  assert.equal((await keepJson("keep/locks/" + k)).redo, true);
  t = await mainTx("Fx/l.mp3");
  assert.equal(t.lines[0].text, "fini !");
  assert.equal(t.run.state, "queued");
});

await test("zero-error replay: correct every wrong segment; every reload, a retranscription and an alias show it with 0 differences", async () => {
  await MAIN.put("files/Fx/z.mp3", "Fx/z.mp3");
  const k = await keyOf("Fx/z.mp3");
  const heard = ["je suis allé à pari hier", "la tour est belle", "nous avons vu la tour effel", "il fait beau", "pari est grande", "on a mange des crepes", "merci beaucoup", "thank you"];
  const truth = ["je suis allé à Paris hier", "la tour est belle", "nous avons vu la tour Eiffel", "il fait beau", "Paris est grande", "on a mangé des crêpes", "merci beaucoup"];
  const asr = (id0, dt) => ({ complete: true, lines: heard.map((h, i) => line(id0 + i, i * 4 + dt, h)) });
  await KEEP.put("keep/" + k + ".v2.json", JSON.stringify(asr(0, 0)));
  const id = await shareLink("Fx/z.mp3");
  const shareGet = async () => (await (await anyone(`/api/transcript?id=${id}&n=000`)).json()).lines.map((l) => l.text);

  // the listener goes through it, correcting each line still wrong (some on Main, some on the share link)
  let t = await mainTx("Fx/z.mp3");
  let v = t.version;
  let turn = 0;
  for (;;) {
    const wrong = t.lines.findIndex((l, i) => (truth[i] === undefined ? true : l.text !== truth[i]));
    if (wrong < 0 && t.lines.length === truth.length) break;
    const l = t.lines[wrong];
    const pos = heard.findIndex((h, i) => Math.abs(i * 4 - l.s) < 0.01);
    const body = JSON.stringify({ version: v, edits: [{ segId: l.id, field: "text", to: truth[pos] ?? "" }] });
    const r = turn++ % 2 ? await mainPut("Fx/z.mp3", JSON.parse(body)) : await anyone(`/api/transcript?id=${id}&n=000`, { method: "PUT", headers: { "cf-connecting-ip": "9.9.9.9" }, body });
    assert.equal(r.status, 200);
    const j = await r.json();
    v = j.version;
    t = j;
    assert.ok(turn < 10, "too many edits");
  }
  assert.equal(turn, 4); // "pari est grande" was put right by the glossary, not by hand

  for (let replay = 0; replay < 3; replay++) {
    assert.deepEqual((await mainTx("Fx/z.mp3")).lines.map((l) => l.text), truth, "main replay " + replay);
    assert.deepEqual(await shareGet(), truth, "share replay " + replay);
  }
  // Retranscribe: a new raw transcript (new ids, timings a little off, the same mistakes) keeps every correction
  await putAsr(k, asr(100, 0.15));
  assert.deepEqual((await mainTx("Fx/z.mp3")).lines.map((l) => l.text), truth);
  // the same recording elsewhere, 2 s later (an alias) shows it too
  await MAIN.put("files/Fx/z2.mp3", "Fx/z2.mp3");
  await KEEP.put("keep/library.json", JSON.stringify({ pieces: {}, aliases: { [await keyOf("Fx/z2.mp3")]: { key: k, shift: 2 } } }));
  const a = await mainTx("Fx/z2.mp3");
  assert.deepEqual(a.lines.map((l) => l.text), truth);
  assert.equal(a.lines[0].s, 2.15);
});

await test("new layout: asr.json + tr/en.json read; vi and fr from their own files; a correction of one wins; written by nobody but Recense", async () => {
  await MAIN.put("files/Fx/n.mp3", "Fx/n.mp3");
  const k = await keyOf("Fx/n.mp3");
  await putAsr(k, { complete: true, lines: [line(1, 0, "un deux", [{ w: "one", s: [0] }, { w: "two", s: [1] }]), line(2, 3, "trois quatre", [{ w: "three", s: [0] }, { w: "four", s: [1] }])] });
  await putTr(k, "vi", { 1: { src: "un deux", text: "một hai", words: [{ w: "một", s: [0] }, { w: "hai", s: [1] }] }, 2: { src: "trois quatre", text: "ba bốn" } });
  await putTr(k, "fr", { 1: { src: "un deux", same: true }, 2: { src: "trois quatre", same: true } });
  let t = await mainTx("Fx/n.mp3");
  assert.deepEqual(t.langs, ["en", "vi", "fr"]);
  assert.deepEqual(t.lines.map((l) => [l.en, l.tr]), [["one two", { vi: "một hai" }], ["three four", { vi: "ba bốn" }]]); // fr: already French, nothing to show
  assert.deepEqual(t.lines[0].enw.map((w) => w.s), [[0], [1]]);
  assert.equal(await KEEP.head("keep/" + k + ".v2.json"), null); // nothing in the old layout
  // a correction of the Vietnamese wins over the file; the file stays as Recense wrote it
  let r = await mainPut("Fx/n.mp3", { version: 0, edits: [{ segId: "2", field: "tr.vi", to: "ba và bốn" }] });
  assert.equal(r.status, 200);
  assert.deepEqual((await r.json()).lines[1].tr, { vi: "ba và bốn" });
  assert.equal((await keepJson(L.trName(k, "vi"))).lines[2].text, "ba bốn");
  // a correction of the original keeps the translation made from the words Recense had
  r = await mainPut("Fx/n.mp3", { version: 1, edits: [{ segId: "1", field: "text", to: "un, deux" }] });
  assert.deepEqual((await r.json()).lines[0].tr, { vi: "một hai" });
  // Recense remakes segment 1 with other words: its old Vietnamese is not shown on them
  await putAsr(k, { complete: true, lines: [line(1, 0, "un deux cinq"), line(2, 3, "trois quatre")] });
  t = await mainTx("Fx/n.mp3");
  assert.equal(t.lines[0].tr, undefined);
  assert.equal(t.lines[0].text, "un, deux"); // (the correction, laid over the new words)
  // Re-running one language never touches the others or the original
  const before = await Promise.all([L.asrName(k), L.trName(k, "en"), L.trName(k, "fr")].map((n) => KEEP.head(n).then((o) => o.etag)));
  await putTr(k, "vi", { 2: { src: "trois quatre", text: "ba, bốn" } });
  const after = await Promise.all([L.asrName(k), L.trName(k, "en"), L.trName(k, "fr")].map((n) => KEEP.head(n).then((o) => o.etag)));
  assert.deepEqual(after, before);
  assert.deepEqual((await mainTx("Fx/n.mp3")).lines[1].tr, { vi: "ba và bốn" });
});

await test("per-language fallback: no file for a language, no translation in it (the page shows the English); never another language", async () => {
  await MAIN.put("files/Fx/f.mp3", "Fx/f.mp3");
  const k = await keyOf("Fx/f.mp3");
  await putAsr(k, { complete: true, lines: [line(1, 0, "bonjour", [{ w: "hello", s: [0] }])] });
  let t = await mainTx("Fx/f.mp3");
  assert.deepEqual(t.langs, ["en"]);
  assert.equal(t.lines[0].tr, undefined);
  assert.equal(t.lines[0].en, "hello");
  await putTr(k, "fr", { 1: { src: "bonjour", text: "salut" } });
  t = await mainTx("Fx/f.mp3");
  assert.deepEqual(t.langs, ["en", "fr"]);
  assert.deepEqual(t.lines[0].tr, { fr: "salut" }); // no vi: the page's Vietnamese falls back to "hello", not "salut"
  // a file that lost its English still reads (the original is shown untranslated)
  await KEEP.delete(L.trName(k, "en"));
  t = await mainTx("Fx/f.mp3");
  assert.deepEqual([t.langs, t.lines[0].en, t.lines[0].enw], [["fr"], "", null]);
});

await test("lazy migration: an old v2.json is written out as asr.json + tr/en.json on first read, never over newer files, never deleted", async () => {
  await MAIN.put("files/Fx/m.mp3", "Fx/m.mp3");
  const k = await keyOf("Fx/m.mp3");
  const old = { complete: true, duration: 4, done: [true, true], lines: [line(1, 0, "un deux", [{ w: "one", s: [0] }, { w: "two", s: [1] }]), line(2, 3, "trois")] };
  await KEEP.put("keep/" + k + ".v2.json", JSON.stringify(old));
  let t = await mainTx("Fx/m.mp3");
  assert.deepEqual(t.lines.map((l) => [l.text, l.en]), [["un deux", "one two"], ["trois", ""]]);
  assert.deepEqual(t.langs, ["en"]);
  const asr = await keepJson(L.asrName(k));
  assert.deepEqual([asr.complete, asr.duration, asr.recense, asr.segments.map((s) => s.text)], [true, 4, { done: [true, true] }, ["un deux", "trois"]]);
  const en = await keepJson(L.trName(k, "en"));
  assert.deepEqual([en.complete, Object.keys(en.lines)], [false, ["1"]]);
  assert.deepEqual(await keepJson("keep/" + k + ".v2.json"), old); // left where it was
  // read again: the same, from the new files
  assert.deepEqual((await mainTx("Fx/m.mp3")).lines, t.lines);
  // Recense writes newer files meanwhile: the old one is not moved over them
  await MAIN.put("files/Fx/m2.mp3", "Fx/m2.mp3");
  const k2 = await keyOf("Fx/m2.mp3");
  await KEEP.put("keep/" + k2 + ".v2.json", JSON.stringify(old));
  await putTr(k2, "en", { 1: { src: "un deux", text: "one, two" } });
  t = await mainTx("Fx/m2.mp3");
  assert.equal(t.lines[0].en, "one two"); // the old file's English, as it has it
  assert.equal((await keepJson(L.trName(k2, "en"))).lines[1].text, "one, two"); // Recense's, untouched
  assert.ok(await keepJson(L.asrName(k2)));
  // an alias to an old transcript moves the transcript's own folder, not the alias's
  await MAIN.put("files/Fx/m3.mp3", "Fx/m3.mp3");
  const k3 = await keyOf("Fx/m3.mp3");
  const k4 = "a".repeat(24);
  await KEEP.put("keep/" + k4 + ".v2.json", JSON.stringify(old));
  const lib = (await keepJson("keep/library.json")) || { pieces: {}, aliases: {} };
  lib.aliases[k3] = { key: k4, shift: 1 };
  await KEEP.put("keep/library.json", JSON.stringify(lib));
  assert.equal((await mainTx("Fx/m3.mp3")).lines[0].s, 1);
  assert.ok(await KEEP.head(L.asrName(k4)));
  assert.equal(await KEEP.head(L.asrName(k3)), null);
});

await test("content key: a transcript made from the same bytes elsewhere is this file's, under any name; an old path key still found", async () => {
  const bytes = new Uint8Array(200000).map((_, i) => (i * 7) % 251);
  await MAIN.put("files/Fx/fp-a.m4a", bytes);
  await MAIN.put("files/Other/renamed.m4a", bytes);
  const k = await fpOf(bytes);
  const old = { complete: true, duration: 4, done: [true, true], lines: [line(1, 0, "un deux", [{ w: "one", s: [0] }, { w: "two", s: [1] }]), line(2, 3, "trois")] };
  await putAsr(k, old);
  assert.equal((await mainTx("Fx/fp-a.m4a")).lines.length, old.lines.length);
  assert.equal((await mainTx("Other/renamed.m4a")).lines.length, old.lines.length);
  await MAIN.put("files/Fx/legacy.m4a", "legacy bytes");
  await putAsr(await keyOf("Fx/legacy.m4a"), old);
  assert.equal((await mainTx("Fx/legacy.m4a")).lines.length, old.lines.length);
});

await mf.dispose();
console.log(`\n${passed} passed`);
