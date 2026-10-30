// Route tests: the built Worker in Miniflare, with in-memory R2 buckets and Access tokens signed
// by a throwaway key. Run with `npm test` (it builds first).

import { Miniflare } from "miniflare";
import { readdirSync } from "node:fs";
import { webcrypto as crypto } from "node:crypto";
import assert from "node:assert/strict";
import { GENESIS, link, massDelete } from "../src/fp.js";

const BUILD = new URL("../.test-build/", import.meta.url).pathname;
const TEAM = "team.cloudflareaccess.com";
const AUD = "test-aud";
const OWNER = "owner@example.com";
const CLIENT = "client-id.access";
const ORIGIN = "http://gallery.test";
// sha-256 of "note-pass", the test's Notability WebDAV password
const NOTE_HASH = "90503eefbbfeb080697647122bcee6ef66705509857d9455056cb09920e3862d";

// ---------- a signing key standing in for the Access team's ----------

const keys = await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
  true,
  ["sign", "verify"]
);
const jwk = { ...(await crypto.subtle.exportKey("jwk", keys.publicKey)), kid: "k1", alg: "RS256" };
const b64 = (x) => Buffer.from(x).toString("base64url");

async function jwt(claims) {
  const now = Math.floor(Date.now() / 1000);
  const body = { aud: [AUD], iss: "https://" + TEAM, exp: now + 600, iat: now, ...claims };
  const data = b64(JSON.stringify({ alg: "RS256", kid: "k1" })) + "." + b64(JSON.stringify(body));
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", keys.privateKey, new TextEncoder().encode(data));
  return data + "." + b64(new Uint8Array(sig));
}

const ownerJwt = await jwt({ email: OWNER });
const strangerJwt = await jwt({ email: "someone@example.com" });
const serviceJwt = await jwt({ common_name: CLIENT });

// ---------- the Worker ----------

const textModules = readdirSync(BUILD).filter((f) => /\.(css|js)$/.test(f) && f !== "worker.js");

const mf = new Miniflare({
  modules: [
    { type: "ESModule", path: BUILD + "worker.js" },
    ...textModules.map((f) => ({ type: "Text", path: BUILD + f })),
  ],
  compatibilityDate: "2026-08-01",
  r2Buckets: { PUBLIC: "gallery-public-test", MAIN: "gallery-main-test", KEEP: "recense-keep-test", TMP: "gallery-tmp-test", ARCHIVE: "gallery-archive-test" },
  bindings: { ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD, OWNER_EMAIL: OWNER, SERVICE_CLIENT_ID: CLIENT + ", phone-id.access", NOTABILITY_DAV_HASH: NOTE_HASH },
  outboundService: (req) =>
    new URL(req.url).pathname === "/cdn-cgi/access/certs"
      ? Response.json({ keys: [jwk] })
      : new Response("offline", { status: 503 }),
});

const PUBLIC = await mf.getR2Bucket("PUBLIC");
const MAIN = await mf.getR2Bucket("MAIN");

const call = (path, { as, write = true, headers = {}, ...init } = {}) => {
  const h = { ...headers };
  if (as === "owner") h["cf-access-jwt-assertion"] = ownerJwt;
  if (as === "cookie") h.cookie = "other=1; CF_Authorization=" + ownerJwt;
  if (as === "stranger") h["cf-access-jwt-assertion"] = strangerJwt;
  if (as === "mac") h["cf-access-jwt-assertion"] = serviceJwt;
  if (as && write && as !== "mac" && init.method && init.method !== "GET") h.origin = ORIGIN;
  if (as === "mac") h["x-gallery"] = "1";
  return mf.dispatchFetch(ORIGIN + path, { ...init, headers: h });
};

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

// ---------- tests ----------

await test("the landing page loads for anyone; the upload page is the owner's", async () => {
  const r = await call("/");
  assert.equal(r.status, 200);
  assert.match(await r.text(), /Sign In/);
  assert.equal((await call("/main/share")).status, 404);
  assert.match(await (await call("/main/share", { as: "owner" })).text(), /Create Share Link/);
});

await test("Main is 404 without a token, says who a signed-in stranger is, and 200 for the owner", async () => {
  const bare = await call("/main", { redirect: "manual" });
  assert.equal(bare.status, 302);
  assert.match(bare.headers.get("location"), /\/main\/$/);
  assert.equal((await call("/main/")).status, 404);
  // let through by Access with another email: told so, with a way to switch; the API stays 404
  const w = await call("/main", { as: "stranger" });
  assert.equal(w.status, 403);
  assert.match(await w.text(), /cdn-cgi\/access\/logout/);
  assert.equal((await call("/main/api/whoami", { as: "stranger" })).status, 404);
  const r = await call("/main", { as: "owner" });
  assert.equal(r.status, 200);
  assert.match(await r.text(), /Nothing in Main yet/);
});

await test("the sign-in cookie and the Mac's service token both count as the owner", async () => {
  assert.equal((await call("/main/api/whoami", { as: "cookie" })).status, 200);
  assert.equal((await call("/main/api/whoami", { as: "mac" })).status, 200);
});

await test("a token signed by another key is refused", async () => {
  const forged = ownerJwt.split(".").slice(0, 2).join(".") + "." + b64("x".repeat(256));
  const r = await mf.dispatchFetch(ORIGIN + "/main", { headers: { "cf-access-jwt-assertion": forged } });
  assert.equal(r.status, 404);
});

await test("writes need this site's Origin or the Mac's header", async () => {
  const r = await mf.dispatchFetch(ORIGIN + "/main/api/file?key=x.txt", {
    method: "PUT",
    body: "x",
    headers: { "cf-access-jwt-assertion": ownerJwt, origin: "https://evil.example" },
  });
  assert.equal(r.status, 403);
});

await test("Main: upload, list, read, delete to trash", async () => {
  let r = await call("/main/api/file?key=Raven/notes.txt&mtime=1700000000000", {
    as: "owner",
    method: "PUT",
    body: "hello",
    headers: { "content-type": "text/plain", "content-length": "5" },
  });
  assert.equal(r.status, 200);

  r = await call("/main", { as: "owner" });
  assert.match(await r.text(), /href="\/main\?p=Raven"/);

  r = await call("/main?p=Raven", { as: "owner" });
  const html = await r.text();
  assert.match(html, /"path":"Raven\/notes.txt"/);
  assert.match(html, /id="del"/);

  r = await call("/main/f/Raven/notes.txt", { as: "owner" });
  assert.equal(await r.text(), "hello");

  r = await call("/main/api/file?key=Raven/notes.txt", { as: "owner", method: "DELETE" });
  assert.equal(r.status, 200);
  assert.equal(await MAIN.head("files/Raven/notes.txt"), null);

  const day = new Date().toISOString().slice(0, 10);
  const trashed = await MAIN.get("trash/" + day + "/Raven/notes.txt");
  assert.equal(await trashed.text(), "hello");
  assert.equal(trashed.customMetadata.mtime, "1700000000");
});

await test("Main refuses a browser upload over 90 MiB with a short message", async () => {
  // the Worker answers before reading the body, so the client may see the connection close instead
  try {
    const r = await call("/main/api/file?key=big.bin", {
      as: "owner",
      method: "PUT",
      body: new Uint8Array(91 * 1024 * 1024),
    });
    assert.equal(r.status, 413);
    assert.equal(await r.text(), "Too big for the browser");
  } catch (e) {
    if (!/fetch failed/.test(e.message)) throw e;
  }
  assert.equal(await MAIN.head("files/big.bin"), null);
});

await test("Main refuses paths that climb out", async () => {
  const r = await call("/main/api/file?key=../x", { as: "owner", method: "PUT", body: "x" });
  assert.equal(r.status, 400);
});

let id;

await test("upload link: the server makes the id, files land, the gallery shows them", async () => {
  const items = ["5\t1700000000000\ttext%2Fplain\ta.txt", "3\t1700000000000\ttext%2Fplain\tb.txt"].join("\n");
  let r = await call("/main/api/link?action=start&days=7", { as: "owner", method: "POST", body: items });
  assert.equal(r.status, 200, await r.clone().text());
  const j = await r.json();
  id = j.id;
  assert.match(id, /^[A-Za-z0-9]{20}$/);
  assert.equal(j.url, "/s/" + id);

  r = await call("/api/gallery?id=" + id);
  let g = await r.json();
  assert.equal(g.ready, 0);
  assert.equal(g.items.length, 2);

  for (const [i, body] of [[0, "aaaaa"], [1, "bbb"]]) {
    r = await call(`/main/api/upload?id=${id}&i=${i}&name=${"ab"[i]}.txt&days=7&hasArt=0`, {
      as: "mac",
      method: "PUT",
      body,
      headers: { "content-type": "text/plain", "content-length": String(body.length) },
    });
    assert.equal(r.status, 200, await r.clone().text());
  }

  g = await (await call("/api/gallery?id=" + id)).json();
  assert.equal(g.ready, 2);
  assert.equal(g.complete, true);

  r = await call("/f/" + id + "/001");
  assert.equal(await r.text(), "bbb");
  assert.equal((await call("/s/" + id)).status, 200);
});

await test("upload link: uploads need the owner", async () => {
  const r = await call(`/main/api/upload?id=${id}&i=0&name=a.txt`, { method: "PUT", body: "x" });
  assert.equal(r.status, 404);
});

await test("upload link: delete one item, then the rest removes the link", async () => {
  let r = await call(`/main/api/link?id=${id}&item=000`, { as: "owner", method: "DELETE" });
  assert.equal(r.status, 200);

  const g = await (await call("/api/gallery?id=" + id)).json();
  assert.equal(g.items.length, 1);
  assert.equal(g.items[0].n, "001");
  assert.equal(g.complete, true);

  r = await call(`/main/api/link?id=${id}&item=001`, { as: "owner", method: "DELETE" });
  assert.equal(r.status, 200);
  assert.equal((await call("/s/" + id)).status, 404);
  assert.equal((await PUBLIC.list({ prefix: "links/" + id + "/" })).objects.length, 0);
});

await test("upload link: multipart for big files", async () => {
  const items = "12\t1700000000000\tapplication%2Foctet-stream\tbig.bin";
  const { id: big } = await (await call("/main/api/link?action=start", { as: "owner", method: "POST", body: items })).json();
  const q = `id=${big}&i=0&name=big.bin&total=2`;
  const started = await call(`/main/api/upload?action=start&${q}`, { as: "mac", method: "POST" });
  assert.equal(started.status, 200, await started.clone().text());
  const uploadId = await started.text();
  const e1 = await (await call(`/main/api/upload?action=part&part=1&uploadId=${encodeURIComponent(uploadId)}&${q}`, { as: "mac", method: "PUT", body: new Uint8Array(5 * 1024 * 1024).fill(1), headers: { "content-length": String(5 * 1024 * 1024) } })).text();
  const e2 = await (await call(`/main/api/upload?action=part&part=2&uploadId=${encodeURIComponent(uploadId)}&${q}`, { as: "mac", method: "PUT", body: new Uint8Array(7).fill(2), headers: { "content-length": "7" } })).text();
  const r = await call(`/main/api/upload?action=complete&uploadId=${encodeURIComponent(uploadId)}&${q}`, {
    as: "mac",
    method: "POST",
    body: JSON.stringify([{ partNumber: 1, etag: e1 }, { partNumber: 2, etag: e2 }]),
  });
  assert.equal(r.status, 200, e1 + " " + e2 + " " + (await r.clone().text()));
  assert.equal((await PUBLIC.head("links/" + big + "/000")).size, 5 * 1024 * 1024 + 7);
});

await test("folder link: a folder in Public gets one link, items delete, whole folder deletes", async () => {
  await PUBLIC.put("folders/Trip/day 1/a.jpg", "jpg-a", { httpMetadata: { contentType: "image/jpeg" } });
  await PUBLIC.put("folders/Trip/b.jpg", "jpg-b", { httpMetadata: { contentType: "image/jpeg" } });

  let r = await call("/main/api/link?action=folder&name=Trip", { as: "mac", method: "POST" });
  assert.equal(r.status, 200);
  const link = await r.json();

  const again = await (await call("/main/api/link?action=folder&name=Trip", { as: "mac", method: "POST" })).json();
  assert.equal(again.id, link.id);

  let g = await (await call("/api/gallery?id=" + link.id)).json();
  assert.equal(g.items.length, 2);
  const one = g.items.find((f) => f.path === "day 1/a.jpg");
  assert.equal(await (await call(one.src)).text(), "jpg-a");

  r = await call(`/main/api/link?id=${link.id}&item=${encodeURIComponent("day 1/a.jpg")}`, { as: "owner", method: "DELETE" });
  assert.equal(r.status, 200);
  g = await (await call("/api/gallery?id=" + link.id)).json();
  assert.equal(g.items.length, 1);

  r = await call(`/main/api/link?id=${link.id}`, { as: "owner", method: "DELETE" });
  assert.equal(r.status, 200);
  assert.equal((await PUBLIC.list({ prefix: "folders/Trip/" })).objects.length, 0);
  assert.equal((await call("/s/" + link.id)).status, 404);
});

await test("the nightly cleanup removes expired upload-link files and leaves Main alone", async () => {
  await PUBLIC.put("links/Expired12345/000", "x", { customMetadata: { expires: String(Date.now() - 1000) } });
  await MAIN.put("files/keep.txt", "keep");
  const worker = await mf.getWorker();
  await worker.scheduled({ cron: "0 3 * * *" });
  assert.equal(await PUBLIC.head("links/Expired12345/000"), null);
  assert.ok(await MAIN.head("files/keep.txt"));
});

await test("the player's Key processor is served as a script", async () => {
  const r = await call("/player/key.js");
  assert.equal(r.status, 200);
  assert.match(await r.text(), /^\/\/ Runs inside the AudioWorklet[\s\S]*registerProcessor/);
});

await test("unknown paths and writes to public routes are refused", async () => {
  assert.equal((await call("/nope")).status, 404);
  assert.equal((await call("/api/gallery?id=x", { method: "POST" })).status, 405);
});


await test("comments: owner writes, visitors read, Main + upload link + folder link", async () => {
  // Main
  await MAIN.put("files/Music/song.mp3", "x", { httpMetadata: { contentType: "audio/mpeg" } });
  let r = await call("/main/api/caption", { as: "owner", method: "PUT", body: JSON.stringify({ kind: "main", path: "Music/song.mp3", text: "  first take  " }) });
  assert.equal(r.status, 200, await r.clone().text());
  const saved = await r.json();
  assert.equal(saved.text, "first take");
  assert.ok(saved.at > 0);
  let html = await (await call("/main?p=Music", { as: "owner" })).text();
  assert.match(html, /"caption":"first take"/);
  assert.equal((await call("/main/api/caption", { method: "PUT", body: "{}" })).status, 404);
  r = await call("/main/api/caption", { as: "owner", method: "PUT", body: JSON.stringify({ kind: "main", path: "Music/nope.mp3", text: "x" }) });
  assert.equal(r.status, 404);
  // clearing removes it, and the notes file with it
  r = await call("/main/api/caption", { as: "owner", method: "PUT", body: JSON.stringify({ kind: "main", path: "Music/song.mp3", text: "" }) });
  assert.equal(r.status, 200);
  assert.equal(await MAIN.head("notes/Music/.comments.json"), null);
  // delete to trash takes the comment along
  await call("/main/api/caption", { as: "owner", method: "PUT", body: JSON.stringify({ kind: "main", path: "Music/song.mp3", text: "keep?" }) });
  await call("/main/api/file?key=Music/song.mp3", { as: "owner", method: "DELETE" });
  assert.equal(await MAIN.head("notes/Music/.comments.json"), null);

  // upload link (comment lives in the manifest; visitors see it in the gallery data)
  const { id } = await (await call("/main/api/link?action=start&days=7", { as: "owner", method: "POST", body: "1\t1700000000000\ttext%2Fplain\ta.txt" })).json();
  await call(`/main/api/upload?id=${id}&i=0&name=a.txt&days=7&hasArt=0`, { as: "mac", method: "PUT", body: "a", headers: { "content-type": "text/plain", "content-length": "1" } });
  r = await call("/main/api/caption", { as: "owner", method: "PUT", body: JSON.stringify({ kind: "link", id, key: "000", text: "hello visitors" }) });
  assert.equal(r.status, 200, await r.clone().text());
  let g = await (await call("/api/gallery?id=" + id)).json();
  assert.equal(g.items[0].caption, "hello visitors");
  assert.ok(g.items[0].capAt > 0);

  // folder link
  await PUBLIC.put("folders/Notes/x.jpg", "j", { httpMetadata: { contentType: "image/jpeg" } });
  const fl = await (await call("/main/api/link?action=folder&name=Notes", { as: "mac", method: "POST" })).json();
  r = await call("/main/api/caption", { as: "owner", method: "PUT", body: JSON.stringify({ kind: "link", id: fl.id, key: "x.jpg", text: "folder note" }) });
  assert.equal(r.status, 200, await r.clone().text());
  g = await (await call("/api/gallery?id=" + fl.id)).json();
  assert.equal(g.items[0].caption, "folder note");
  await call(`/main/api/link?id=${fl.id}`, { as: "owner", method: "DELETE" });
  assert.equal(await PUBLIC.head("index/note/" + fl.id + ".json"), null);
});

await test("comments: a thread keeps every comment, deletes one, and reads old single comments", async () => {
  await MAIN.put("files/Thread/p.jpg", "x", { httpMetadata: { contentType: "image/jpeg" } });
  // an old single comment still shows as the first in the thread
  await MAIN.put("notes/Thread/.comments.json", JSON.stringify({ "p.jpg": { text: "old", at: 5 } }));
  const put = (b) => call("/main/api/caption", { as: "owner", method: "PUT", body: JSON.stringify({ kind: "main", path: "Thread/p.jpg", ...b }) });
  let j = await (await put({ op: "add", text: "one" })).json();
  assert.deepEqual(j.comments.map((c) => c.text), ["old", "one"]);
  j = await (await put({ op: "add", text: "two" })).json();
  assert.deepEqual(j.comments.map((c) => c.text), ["old", "one", "two"]);
  assert.equal((await put({ op: "add", text: "   " })).status, 400);
  j = await (await put({ op: "del", cid: j.comments[1].id })).json();
  assert.deepEqual(j.comments.map((c) => c.text), ["old", "two"]);
  assert.equal((await put({ op: "del", cid: "nope" })).status, 404);
  const html = await (await call("/main?p=Thread", { as: "owner" })).text();
  assert.match(html, /"comments":\[\{"id":"c0","text":"old"/);
  assert.equal((await call("/main/api/caption", { method: "PUT", body: JSON.stringify({ kind: "main", path: "Thread/p.jpg", op: "add", text: "hi" }) })).status, 404);
});

await test("invites: owner-only API, one folder, expiry, revoke, no deletes, own comments only", async () => {
  await MAIN.put("files/Party/a.jpg", "A", { httpMetadata: { contentType: "image/jpeg" } });
  await MAIN.put("files/Party/Inner/deep.jpg", "D", { httpMetadata: { contentType: "image/jpeg" } });
  await MAIN.put("files/Secret/s.jpg", "S", { httpMetadata: { contentType: "image/jpeg" } });
  const mk = (b) => call("/main/api/invites", { as: "owner", method: "POST", body: JSON.stringify(b) });

  // only the owner can make or list them
  assert.equal((await call("/main/api/invites", { method: "POST", body: JSON.stringify({ name: "x", ttl: 0, dir: "Party" }) })).status, 404);
  assert.equal((await call("/main/api/invites?dir=Party", { as: "stranger" })).status, 404);
  assert.equal((await mk({ name: "", ttl: 0, dir: "Party" })).status, 400);
  assert.equal((await mk({ name: "x", ttl: 0, dir: "../Secret" })).status, 400);

  const made = await mk({ name: "Sam", ttl: 0, dir: "Party" });
  assert.equal(made.status, 200, await made.clone().text());
  const inv = await made.json();
  assert.match(inv.url, /\/m\/[A-Za-z0-9_-]{43}$/);
  const token = inv.url.split("/m/")[1];
  const at = "/m/" + token;

  // the token itself is never stored, only its hash
  const keys = (await MAIN.list({ prefix: "invites/" })).objects.map((o) => o.key);
  assert.equal(keys.length, 1);
  assert.ok(!keys[0].includes(token) && keys[0].startsWith("invites/" + inv.id));
  const list = await (await call("/main/api/invites?dir=Party", { as: "owner", headers: { "x-gallery": "1" } })).json();
  assert.equal(list.length, 1);
  assert.equal(list[0].url, undefined);

  // the participant sees the folder, its files, nothing above, beside or below it
  let r = await call(at);
  assert.equal(r.status, 200);
  const html = await r.text();
  assert.match(html, /a\.JPG/);
  assert.ok(!html.includes("deep") && !html.includes("Secret") && !html.includes("/main/f/"));
  assert.equal(await (await call(at + "/f/a.jpg")).text(), "A");
  assert.equal((await call(at + "/f/..%2FSecret%2Fs.jpg")).status, 404);
  assert.equal((await call(at + "/f/Inner%2Fdeep.jpg")).status, 404);
  assert.equal((await call("/main/f/Party/a.jpg")).status, 404);
  assert.equal((await call("/m/" + "A".repeat(43))).status, 404);

  // writes: same-site only; upload new files, never replace; no deletes
  const w = (path, init) => call(at + path, { ...init, headers: { "x-gallery": "1", ...(init.headers || {}) } });
  assert.equal((await call(at + "/api/file?name=n.jpg", { method: "PUT", body: "N" })).status, 403);
  r = await w("/api/file?name=n.jpg", { method: "PUT", body: "N", headers: { "content-type": "image/jpeg", "content-length": "1" } });
  assert.equal(r.status, 200, await r.clone().text());
  assert.ok(await MAIN.head("files/Party/n.jpg"));
  assert.equal((await w("/api/file?name=a.jpg", { method: "PUT", body: "X", headers: { "content-length": "1" } })).status, 409);
  assert.equal((await w("/api/file?name=..%2Fx.jpg", { method: "PUT", body: "X", headers: { "content-length": "1" } })).status, 400);
  assert.equal((await w("/api/file?key=Party/a.jpg", { method: "DELETE" })).status, 404);
  assert.equal(await (await MAIN.get("files/Party/a.jpg")).text(), "A");

  // comments: add, delete own, not the owner's, not outside the folder, no wholesale replace
  const c = (b) => w("/api/caption", { method: "PUT", body: JSON.stringify({ kind: "main", ...b }) });
  r = await call("/main/api/caption", { as: "owner", method: "PUT", body: JSON.stringify({ kind: "main", path: "Party/a.jpg", op: "add", text: "owner says" }) });
  assert.equal(r.status, 200, "owner comment " + (await r.clone().text()));
  let j = await r.json();
  const ownerCid = j.comments[0].id;
  r = await c({ path: "Party/a.jpg", op: "add", text: "hi from Sam" });
  assert.equal(r.status, 200, await r.clone().text());
  j = await r.json();
  assert.equal(j.comments[1].by, "Sam");
  assert.equal((await c({ path: "Party/a.jpg", op: "del", cid: ownerCid })).status, 404);
  assert.equal((await c({ path: "Party/a.jpg", text: "" })).status, 403);
  assert.equal((await c({ path: "Secret/s.jpg", op: "add", text: "x" })).status, 403);
  assert.equal((await c({ path: "Party/Inner/deep.jpg", op: "add", text: "x" })).status, 403);
  j = await (await c({ path: "Party/a.jpg", op: "del", cid: j.comments[1].id })).json();
  assert.deepEqual(j.comments.map((x) => x.text), ["owner says"]);

  // revoke: gone at once, same 404 as never existing
  assert.equal((await call("/main/api/invites/" + inv.id, { as: "owner", method: "DELETE" })).status, 200);
  assert.equal((await call(at)).status, 404);
  assert.equal((await call(at + "/f/a.jpg")).status, 404);

  // expiry
  const short = await (await mk({ name: "Brief", ttl: 3600, dir: "Party" })).json();
  const k = (await MAIN.list({ prefix: "invites/" + short.id })).objects[0].key;
  const rec = await (await MAIN.get(k)).json();
  await MAIN.put(k, JSON.stringify({ ...rec, expires: Date.now() - 1 }));
  assert.equal((await call("/m/" + short.url.split("/m/")[1])).status, 404);
});

await test("share link from Main: owner only, copies just the picked files, visitors see them", async () => {
  await MAIN.put("files/Pick/a.jpg", "AAA", { httpMetadata: { contentType: "image/jpeg" } });
  await MAIN.put("files/Pick/b.jpg", "BBB", { httpMetadata: { contentType: "image/jpeg" } });
  const body = JSON.stringify({ paths: ["Pick/b.jpg"] });
  assert.equal((await call("/main/api/link?action=fromMain", { method: "POST", body })).status, 404);
  assert.equal((await call("/main/api/link?action=fromMain", { as: "owner", method: "POST", body: JSON.stringify({ paths: ["../x"] }) })).status, 400);
  let r = await call("/main/api/link?action=fromMain&days=7", { as: "owner", method: "POST", body });
  assert.equal(r.status, 200, await r.clone().text());
  const j = await r.json();
  assert.equal(j.count, 1);
  let g = await (await call("/api/gallery?id=" + j.id)).json();
  assert.ok(g.items[0].pending);
  assert.equal((await call(`/main/api/link?action=copy&id=${j.id}&i=0`, { method: "POST" })).status, 404);
  r = await call(`/main/api/link?action=copy&id=${j.id}&i=0`, { as: "owner", method: "POST" });
  assert.equal(r.status, 200, await r.clone().text());
  g = await (await call("/api/gallery?id=" + j.id)).json();
  assert.equal(g.items.length, 1);
  assert.ok(!g.items[0].pending);
  assert.equal(await (await call("/f/" + j.id + "/000")).text(), "BBB");
  assert.ok(await MAIN.head("files/Pick/b.jpg"));
});

await test("share link from the archive (from=archive): same link and page, copied from gallery-archive, the Mac app may make it", async () => {
  const AR = await mf.getR2Bucket("ARCHIVE");
  await AR.put("chauphan/Memos/m.m4a", "MEMO", { httpMetadata: { contentType: "audio/mp4" }, customMetadata: { mtime: "1700000000.5" } });
  await AR.put(".catalog/archive/x.json", "{}");
  const mk = (paths, as = "mac", from = "archive") => call(`/main/api/link?action=fromMain&days=1&from=${from}`, { as, method: "POST", body: JSON.stringify({ paths }) });
  assert.equal((await mk(["Memos/m.m4a"], "stranger")).status, 404);
  assert.equal((await mk(["Memos/m.m4a"], "mac", "elsewhere")).status, 400);
  assert.equal((await mk(["../.catalog/archive/x.json"])).status, 400);
  assert.equal((await mk(["Memos/none.m4a"])).status, 404);
  const r = await mk(["Memos/m.m4a"]);
  assert.equal(r.status, 200, await r.clone().text());
  const j = await r.json();
  let g = await (await call("/api/gallery?id=" + j.id)).json();
  assert.ok(g.items[0].pending);
  assert.equal(g.items[0].taken, 1700000000500);
  assert.equal((await call(`/main/api/link?action=copy&id=${j.id}&i=0`, { as: "mac", method: "POST" })).status, 200);
  g = await (await call("/api/gallery?id=" + j.id)).json();
  assert.ok(!g.items[0].pending);
  assert.equal(await (await call("/f/" + j.id + "/000")).text(), "MEMO");
  // the archive is untouched, and nothing of Main's was looked for
  assert.equal(await (await AR.get("chauphan/Memos/m.m4a")).text(), "MEMO");
  assert.equal(await MAIN.head("files/Memos/m.m4a"), null);
});

await test("transcripts: Main path, alias via library.json, invite name, link item; pending when none", async () => {
  const KEEP = await mf.getR2Bucket("KEEP");
  const k = async (p) => Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("gallery:files/" + p))).toString("hex").slice(0, 24);
  await MAIN.put("files/Tx/a.mp3", "x", { httpMetadata: { contentType: "audio/mpeg" } });
  await MAIN.put("files/Tx/b.mp3", "x", { httpMetadata: { contentType: "audio/mpeg" } });
  const g = (p, as = "owner") => call(p, { as, headers: { "x-gallery": "1" } });
  let j = await (await g("/main/api/transcript?path=Tx/a.mp3")).json();
  assert.ok(j.pending);
  await KEEP.put("keep/" + (await k("Tx/a.mp3")) + ".v2.json", JSON.stringify({ lines: [{ id: 0, words: [{ text: "un", start: 1, end: 2 }], english: [{ w: "one", s: [0] }] }] }));
  j = await (await g("/main/api/transcript?path=Tx/a.mp3")).json();
  assert.deepEqual(j.lines[0], { id: "0", s: 1, e: 2, text: "un", en: "one", enw: [{ w: "one", s: [0] }], words: [{ t: "un", s: 1, e: 2 }] });
  // b is the same recording, 2 s later: an alias
  await KEEP.put("keep/library.json", JSON.stringify({ pieces: {}, aliases: { [await k("Tx/b.mp3")]: { key: await k("Tx/a.mp3"), shift: 2, d: 9 } } }));
  j = await (await g("/main/api/transcript?path=Tx/b.mp3")).json();
  assert.equal(j.lines[0].s, 3);
  assert.equal((await call("/main/api/transcript?path=Tx/a.mp3")).status, 404);
  // invite
  const inv = await (await call("/main/api/invites", { as: "owner", method: "POST", body: JSON.stringify({ name: "T", ttl: 0, dir: "Tx" }) })).json();
  const tok = inv.url.split("/m/")[1];
  j = await (await call("/m/" + tok + "/api/transcript?name=a.mp3", { headers: { "x-gallery": "1" } })).json();
  assert.equal(j.lines[0].text, "un");
  // a share link made from Main
  const l = await (await call("/main/api/link?action=fromMain&days=1", { as: "owner", method: "POST", body: JSON.stringify({ paths: ["Tx/a.mp3"] }) })).json();
  j = await (await call("/api/transcript?id=" + l.id + "&n=000")).json();
  assert.equal(j.lines[0].en, "one");
});

await test("comments: the author edits their own, nobody else's", async () => {
  await MAIN.put("files/Ed/a.jpg", "x");
  const put = (body, as = "owner") => call("/main/api/caption", { as, method: "PUT", body: JSON.stringify({ kind: "main", path: "Ed/a.jpg", ...body }) });
  let j = await (await put({ op: "add", text: "first" })).json();
  const cid = j.comments[0].id;
  j = await (await put({ op: "edit", cid, text: "changed" })).json();
  assert.equal(j.comments[0].text, "changed");
  assert.ok(j.comments[0].edited);
  assert.equal((await put({ op: "edit", cid, text: "" })).status, 400);
  // an invited person can't edit the owner's
  const inv = await (await call("/main/api/invites", { as: "owner", method: "POST", body: JSON.stringify({ name: "Pat", ttl: 0, dir: "Ed" }) })).json();
  const tok = inv.url.split("/m/")[1];
  const r = await call("/m/" + tok + "/api/caption", { method: "PUT", headers: { "x-gallery": "1" }, body: JSON.stringify({ kind: "main", path: "Ed/a.jpg", op: "edit", cid, text: "hijack" }) });
  assert.equal(r.status, 404);
});

await test("rooms: an invite to some items sees only those, never uploads", async () => {
  for (const n of ["a.jpg", "b.jpg", "c.jpg"]) await MAIN.put("files/Rm/" + n, "x" + n);
  const mk = (body) => call("/main/api/invites", { as: "owner", method: "POST", body: JSON.stringify({ name: "Sam", ttl: 3600, dir: "Rm", ...body }) });
  assert.equal((await mk({ items: ["nope.jpg"] })).status, 404);
  assert.equal((await mk({ items: ["../x"] })).status, 400);
  const inv = await (await mk({ items: ["b.jpg"] })).json();
  assert.deepEqual(inv.items, ["b.jpg"]);
  assert.equal(inv.perms.upload, false);
  const tok = inv.url.split("/m/")[1];
  const page = await (await call("/m/" + tok)).text();
  assert.ok(page.includes("b.jpg") && !page.includes("a.jpg") && !page.includes("c.jpg"));
  assert.ok(page.includes('"start":0'));
  assert.equal(await (await call("/m/" + tok + "/f/b.jpg")).text(), "xb.jpg");
  assert.equal((await call("/m/" + tok + "/f/a.jpg")).status, 404);
  const up = await call("/m/" + tok + "/api/file?name=new.jpg", { method: "PUT", headers: { "x-gallery": "1", "content-length": "1" }, body: "z" });
  assert.equal(up.status, 403);
  const cm = await call("/m/" + tok + "/api/caption", { method: "PUT", headers: { "x-gallery": "1" }, body: JSON.stringify({ kind: "main", path: "Rm/a.jpg", op: "add", text: "hi" }) });
  assert.equal(cm.status, 403);
  // revoke
  assert.equal((await call("/main/api/invites/" + inv.id, { as: "owner", method: "DELETE" })).status, 200);
  assert.equal((await call("/m/" + tok)).status, 404);
});

await test("rename: moves the file, its comments and rooms; refuses clashes and strangers", async () => {
  await MAIN.put("files/Rn/old.mp3", "audio", { httpMetadata: { contentType: "audio/mpeg" } });
  await MAIN.put("files/Rn/taken.mp3", "y");
  await call("/main/api/caption", { as: "owner", method: "PUT", body: JSON.stringify({ kind: "main", path: "Rn/old.mp3", op: "add", text: "note" }) });
  const inv = await (await call("/main/api/invites", { as: "owner", method: "POST", body: JSON.stringify({ name: "Q", ttl: 0, dir: "Rn", items: ["old.mp3"] }) })).json();
  const rn = (name, as = "owner") => call("/main/api/rename", { as, method: "POST", body: JSON.stringify({ path: "Rn/old.mp3", name }) });
  assert.equal((await rn("new", "stranger")).status, 404);
  assert.equal((await rn("taken")).status, 409);
  assert.equal((await rn("a/b")).status, 400);
  const j = await (await rn("new")).json();
  assert.equal(j.path, "Rn/new.mp3"); // the extension is kept
  assert.equal(await MAIN.head("files/Rn/old.mp3"), null);
  const o = await MAIN.head("files/Rn/new.mp3");
  assert.equal(o.customMetadata.was, "Rn/old.mp3");
  const list = await (await call("/main?p=Rn", { as: "owner" })).text();
  assert.ok(list.includes("note"));
  const tok = inv.url.split("/m/")[1];
  assert.equal(await (await call("/m/" + tok + "/f/new.mp3")).text(), "audio");
});

await test("cover art: written into an MP3's tag, kept beside other files, JPEG/PNG only", async () => {
  const jpg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, ...new Array(60).fill(7)]);
  // an MP3 with an ID3v2.3 tag holding a title, then the audio
  const title = new Uint8Array([...Buffer.from("TIT2"), 0, 0, 0, 4, 0, 0, 0, ...Buffer.from("abc")]);
  const id3 = new Uint8Array([...Buffer.from("ID3"), 3, 0, 0, 0, 0, 0, title.length, ...title]);
  const audio = new Uint8Array([0xff, 0xfb, 1, 2, 3, 4, 5]);
  await MAIN.put("files/Cv/s.mp3", new Uint8Array([...id3, ...audio]), { httpMetadata: { contentType: "audio/mpeg" } });
  const cover = (path, body, as = "owner") => call("/main/api/cover?path=" + encodeURIComponent(path), { as, method: "PUT", headers: { "content-length": String(body.length) }, body });
  assert.equal((await cover("Cv/s.mp3", jpg, "stranger")).status, 404);
  assert.equal((await cover("Cv/s.mp3", new Uint8Array(40).fill(1))).status, 415);
  const j = await (await cover("Cv/s.mp3", jpg)).json();
  assert.equal(j.embedded, true);
  const b = new Uint8Array(await (await MAIN.get("files/Cv/s.mp3")).arrayBuffer());
  const txt = Buffer.from(b).toString("latin1");
  assert.ok(txt.includes("TIT2") && txt.includes("APIC") && txt.includes("image/jpeg"));
  assert.deepEqual([...b.slice(-audio.length)], [...audio]); // the audio is untouched
  const art = await call("/main/f/Cv/s.mp3?art=1", { as: "owner" });
  assert.deepEqual([...new Uint8Array(await art.arrayBuffer())], [...jpg]);
  // a WAV keeps it beside the file
  await MAIN.put("files/Cv/w.wav", "RIFFxxxxWAVE", { httpMetadata: { contentType: "audio/wav" } });
  assert.equal((await (await cover("Cv/w.wav", jpg)).json()).embedded, false);
  assert.equal(await (await MAIN.get("files/Cv/w.wav")).text(), "RIFFxxxxWAVE");
});

await test("original key: owner only, manual wins over auto, follows rename and trash, rides into links", async () => {
  await MAIN.put("files/Ky/a.mp3", "x", { httpMetadata: { contentType: "audio/mpeg" } });
  const put = (body, as = "owner") => call("/main/api/key", { as, method: "PUT", body: JSON.stringify(body) });
  const itemOf = async (name) => {
    const html = await (await call("/main?p=Ky", { as: "owner" })).text();
    const G = JSON.parse(html.match(/const G=(.*);\n/)[1]);
    return G.items.find((f) => f.path === "Ky/" + name);
  };
  assert.equal((await put({ path: "Ky/a.mp3", key: "E♭m", src: "auto" }, "stranger")).status, 404);
  assert.equal((await put({ path: "Ky/a.mp3", key: "Ebm", src: "auto" })).status, 400); // canonical only
  assert.equal((await put({ path: "Ky/a.mp3", key: "E♭m", src: "guess" })).status, 400);
  assert.equal((await put({ path: "Ky/none.mp3", key: "E♭m", src: "auto" })).status, 404);
  let j = await (await put({ path: "Ky/a.mp3", key: "E♭m", src: "auto" })).json();
  assert.deepEqual([j.key, j.keySrc], ["E♭m", "auto"]);
  j = await (await put({ path: "Ky/a.mp3", key: "D♯m", src: "manual" })).json();
  assert.deepEqual([j.key, j.keySrc], ["D♯m", "manual"]);
  j = await (await put({ path: "Ky/a.mp3", key: "C", src: "auto" })).json();
  assert.equal(j.key, "D♯m"); // a new detection never beats what the owner typed
  let f = await itemOf("a.mp3");
  assert.deepEqual([f.key, f.keySrc], ["D♯m", "manual"]);
  j = await (await put({ path: "Ky/a.mp3", key: "", src: "manual" })).json();
  assert.deepEqual([j.key, j.keySrc], ["C", "auto"]);
  // a share link made from it carries the key
  const l = await (await call("/main/api/link?action=fromMain&days=1", { as: "owner", method: "POST", body: JSON.stringify({ paths: ["Ky/a.mp3"] }) })).json();
  await call(`/main/api/link?action=copy&id=${l.id}&i=0`, { as: "owner", method: "POST" });
  const g = await (await call("/api/gallery?id=" + l.id)).json();
  assert.equal(g.items[0].key, "C");
  // rename carries it; trash drops it
  await call("/main/api/rename", { as: "owner", method: "POST", body: JSON.stringify({ path: "Ky/a.mp3", name: "b" }) });
  f = await itemOf("b.mp3");
  assert.equal(f.key, "C");
  await call("/main/api/file?key=" + encodeURIComponent("Ky/b.mp3"), { as: "owner", method: "DELETE" });
  assert.equal(await MAIN.head("keys/Ky/.keys.json"), null);
});

await test("cover change and delete reach the root grid, rooms and share links, past any cached copy", async () => {
  const jpg = (n) => new Uint8Array([0xff, 0xd8, 0xff, 0xe0, ...new Array(60).fill(n)]);
  const ss = (n) => [(n >> 21) & 127, (n >> 14) & 127, (n >> 7) & 127, n & 127];
  // an MP3 at the top of Main whose ID3v2.3 tag carries a picture, then the audio
  const pic = jpg(1);
  const body = [0, ...Buffer.from("image/jpeg"), 0, 3, 0, ...pic];
  const apic = [...Buffer.from("APIC"), 0, 0, 0, body.length, 0, 0, ...body];
  const id3 = [...Buffer.from("ID3"), 3, 0, 0, ...ss(apic.length), ...apic];
  const audio = [0xff, 0xfb, 9, 9, 9];
  await MAIN.put("files/root.mp3", new Uint8Array([...id3, ...audio]), { httpMetadata: { contentType: "audio/mpeg" } });
  await MAIN.put("files/root.wav", "RIFFxxxxWAVE", { httpMetadata: { contentType: "audio/wav" } });

  const G = async (path) => JSON.parse((await (await call(path, { as: "owner" })).text()).match(/const G=(.*);\n/)[1]);
  const rootItem = async (name) => (await G("/main")).items.find((f) => f.path === name);
  const bytes = async (path, as) => [...new Uint8Array(await (await call(path, { as })).arrayBuffer())];
  const cover = (path, b, as = "owner") => call("/main/api/cover?path=" + encodeURIComponent(path), { as, method: "PUT", headers: { "content-length": String(b.length) }, body: b });
  const uncover = (path, as = "owner") => call("/main/api/cover?path=" + encodeURIComponent(path), { as, method: "DELETE" });

  // before: the embedded picture, at a versioned address
  const a0 = (await rootItem("root.mp3")).art;
  assert.match(a0, /^\/main\/f\/root\.mp3\?art=1&v=\w+$/);
  assert.deepEqual(await bytes(a0, "owner"), [...pic]);

  // a share link made before the change, already looked at
  const l = await (await call("/main/api/link?action=fromMain&days=1", { as: "owner", method: "POST", body: JSON.stringify({ paths: ["root.mp3"] }) })).json();
  await call(`/main/api/link?action=copy&id=${l.id}&i=0`, { as: "owner", method: "POST" });
  const s0 = (await (await call("/api/gallery?id=" + l.id)).json()).items[0].art;
  assert.match(s0, /\?art=1&v=\w+$/);
  assert.deepEqual(await bytes(s0), [...pic]);
  const inv = await (await call("/main/api/invites", { as: "owner", method: "POST", body: JSON.stringify({ name: "R", ttl: 0, dir: "", items: ["root.mp3"] }) })).json();
  const room = "/m/" + inv.url.split("/m/")[1];

  // Change cover: the root grid's address changes (so no cached copy is shown) and serves the new picture
  const c1 = jpg(2);
  const j = await (await cover("root.mp3", c1)).json();
  const a1 = (await rootItem("root.mp3")).art;
  assert.equal(a1, j.art);
  assert.notEqual(a1, a0);
  assert.deepEqual(await bytes(a1, "owner"), [...c1]);
  // the share link made earlier follows, at a new address too
  const s1 = (await (await call("/api/gallery?id=" + l.id)).json()).items[0].art;
  assert.notEqual(s1, s0);
  assert.deepEqual(await bytes(s1), [...c1]);
  assert.match((await G(room)).items[0].art, new RegExp("^" + room + "/f/root\\.mp3\\?art=1&v=" + a1.split("&v=")[1] + "$"));

  // Delete cover: owner only; the grid gets the file tile, the tag loses its pictures, the audio is untouched
  assert.equal((await uncover("root.mp3", "stranger")).status, 404);
  assert.equal((await uncover("nope.mp3")).status, 404);
  const d = await (await uncover("root.mp3")).json();
  assert.equal(d.stripped, true);
  const file = new Uint8Array(await (await MAIN.get("files/root.mp3")).arrayBuffer());
  assert.ok(!Buffer.from(file).toString("latin1").includes("APIC"));
  assert.deepEqual([...file.slice(-audio.length)], audio);
  let f = await rootItem("root.mp3");
  assert.equal(f.art, null);
  assert.equal(f.nocover, true);
  assert.equal((await call(a1.split("&")[0], { as: "owner" })).status, 404);
  // the share link and the room lose it too
  const g = (await (await call("/api/gallery?id=" + l.id)).json()).items[0];
  assert.equal(g.art, null);
  assert.equal(g.nocover, true);
  assert.equal((await call(`/f/${l.id}/000?art=1`)).status, 404);
  const ri = (await G(room)).items[0];
  assert.equal(ri.art, null);
  assert.equal(ri.nocover, true);
  // a share link made after the delete starts without it
  const l2 = await (await call("/main/api/link?action=fromMain&days=1", { as: "owner", method: "POST", body: JSON.stringify({ paths: ["root.mp3"] }) })).json();
  await call(`/main/api/link?action=copy&id=${l2.id}&i=0`, { as: "owner", method: "POST" });
  assert.equal((await (await call("/api/gallery?id=" + l2.id)).json()).items[0].nocover, true);

  // a new cover after a delete shows again; a WAV's delete leaves the file as it was
  const c2 = jpg(3);
  await cover("root.mp3", c2);
  f = await rootItem("root.mp3");
  assert.ok(!f.nocover);
  assert.deepEqual(await bytes(f.art, "owner"), [...c2]);
  const s2 = (await (await call("/api/gallery?id=" + l2.id)).json()).items[0];
  assert.deepEqual(await bytes(s2.art), [...c2]);
  await cover("root.wav", c1);
  assert.equal((await (await uncover("root.wav")).json()).stripped, false);
  assert.equal(await (await MAIN.get("files/root.wav")).text(), "RIFFxxxxWAVE");
  assert.equal((await rootItem("root.wav")).nocover, true);
});

await test("nightly sweep: covers of files gone (deleted or renamed on the mount) go to the trash", async () => {
  const jpg = (n) => new Uint8Array([0xff, 0xd8, 0xff, 0xe0, ...new Array(60).fill(n)]);
  await MAIN.put("files/Sw/kept.mp3", "a", { httpMetadata: { contentType: "audio/mpeg" } });
  await MAIN.put("art/Sw/kept.mp3", jpg(4), { httpMetadata: { contentType: "image/jpeg" } });
  await MAIN.put("art/Sw/old name.mp3", jpg(5), { httpMetadata: { contentType: "image/jpeg" }, customMetadata: { custom: "1" } });
  await MAIN.put("art/Sw/gone.mp3", new Uint8Array(0), { customMetadata: { none: "1", deleted: "1" } });
  await (await mf.getWorker()).scheduled({ cron: "0 3 * * *" });
  assert.ok(await MAIN.head("art/Sw/kept.mp3"));
  assert.equal(await MAIN.head("art/Sw/old name.mp3"), null);
  assert.equal(await MAIN.head("art/Sw/gone.mp3"), null);
  const day = new Date().toISOString().slice(0, 10);
  const t = await MAIN.head("trash/" + day + "/art/Sw/old name.mp3");
  assert.equal(t && t.customMetadata.custom, "1");
});

await test("share links carry the sharer's language and Key notation (G.view), never the visitor's browser", async () => {
  await MAIN.put("files/View/a.mp3", "A", { httpMetadata: { contentType: "audio/mpeg" } });
  const gOf = (html) => JSON.parse(html.match(/const G=(\{.*?\});\n<\/script>/s)[1]);
  // Create Share Link (public /s/)
  const l = await (await call("/main/api/link?action=fromMain&days=1", { as: "owner", method: "POST", body: JSON.stringify({ paths: ["View/a.mp3"], lang: "vi", notation: 2 }) })).json();
  await call(`/main/api/link?action=copy&id=${l.id}&i=0`, { as: "owner", method: "POST" });
  assert.deepEqual((await (await call("/api/gallery?id=" + l.id)).json()).view, { lang: "vi", notation: 2 });
  assert.deepEqual(gOf(await (await call(l.url)).text()).view, { lang: "vi", notation: 2 });
  // junk is dropped, not stored
  const bad = await (await call("/main/api/link?action=fromMain&days=1", { as: "owner", method: "POST", body: JSON.stringify({ paths: ["View/a.mp3"], lang: "xx", notation: 42 }) })).json();
  assert.equal((await (await call("/api/gallery?id=" + bad.id)).json()).view, undefined);
  // a room (viewer Share / Invite, /m/)
  const inv = await (await call("/main/api/invites", { as: "owner", method: "POST", body: JSON.stringify({ name: "Phone", ttl: 0, dir: "View", items: ["a.mp3"], lang: "fr", notation: 1 }) })).json();
  const g = gOf(await (await call(new URL(inv.url).pathname)).text());
  assert.deepEqual(g.view, { lang: "fr", notation: 1 });
});

// ---------- file dashboard: New Folder and Move stay inside files/ ----------

// every key in the bucket, to prove nothing was written outside files/<expected>
const allKeys = async () => (await MAIN.list({ limit: 1000 })).objects.map((o) => o.key);
const post = (path, body, as = "owner") => call(path, { as, method: "POST", body: JSON.stringify(body) });

await test("new folder: makes files/<dir>/<name>/.folder-<id>; owner only, same-site only", async () => {
  await MAIN.put("files/Nf/a.jpg", "a");
  assert.equal((await post("/main/api/folder", { dir: "Nf", name: "Trips" }, "stranger")).status, 404);
  assert.equal((await call("/main/api/folder", { as: "owner", write: false, method: "POST", body: JSON.stringify({ dir: "Nf", name: "X" }) })).status, 403);
  const r = await post("/main/api/folder", { dir: "Nf", name: "  Trips " });
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.equal(j.path, "Nf/Trips");
  const marks = (await MAIN.list({ prefix: "files/Nf/Trips/" })).objects.map((o) => o.key);
  assert.equal(marks.length, 1);
  assert.match(marks[0], /^files\/Nf\/Trips\/\.folder-[0-9a-f]{16}$/);
  // it shows as a chip, and the picker lists it
  assert.ok((await (await call("/main?p=Nf", { as: "owner" })).text()).includes(">Trips</a>"));
  assert.deepEqual((await (await call("/main/api/folders?p=Nf", { as: "owner", headers: { "x-gallery": "1" } })).json()).folders, ["Trips"]);
  // same name again (folder or file) is a clash
  assert.equal((await post("/main/api/folder", { dir: "Nf", name: "Trips" })).status, 409);
  assert.equal((await post("/main/api/folder", { dir: "Nf", name: "a.jpg" })).status, 409);
  // the parent must exist
  assert.equal((await post("/main/api/folder", { dir: "Nope", name: "X" })).status, 404);
});

await test("new folder: path traversal and bad names are refused, nothing is written", async () => {
  await MAIN.put("files/Pt/a.jpg", "a");
  const before = await allKeys();
  const badNames = ["", "   ", ".", "..", "../x", "a/b", "a\\b", "..\\..\\x", ".hidden", ".folder-0123456789abcdef", "a\u0000b", "a\nb", "x".repeat(301), "Thumbs.db", null, 42, ["a"]];
  for (const name of badNames) {
    assert.equal((await post("/main/api/folder", { dir: "Pt", name })).status, 400, "name " + JSON.stringify(name));
  }
  const badDirs = ["..", "../Pt", "Pt/..", "Pt/../..", "Pt//x", "./Pt", "Pt/./x", "Pt\u0000", "Pt/\u0007"];
  for (const dir of badDirs) {
    assert.equal((await post("/main/api/folder", { dir, name: "X" })).status, 400, "dir " + JSON.stringify(dir));
  }
  // percent-encoding is not decoded in the body: a literal name that can only land under files/
  assert.equal((await post("/main/api/folder", { dir: "Pt", name: "%2e%2e" })).status, 200);
  const after = await allKeys();
  const added = after.filter((k) => !before.includes(k));
  assert.equal(added.length, 1);
  assert.match(added[0], /^files\/Pt\/%2e%2e\/\.folder-[0-9a-f]{16}$/);
  // a junk body
  assert.equal((await call("/main/api/folder", { as: "owner", method: "POST", body: "{nope" })).status, 400);
});

await test("move: carries the file, its art, comments and key into an existing folder", async () => {
  await MAIN.put("files/Mv/s.mp3", "song", { httpMetadata: { contentType: "audio/mpeg" } });
  await MAIN.put("files/Mv/keep.jpg", "k");
  await MAIN.put("art/Mv/s.mp3", "pic", { customMetadata: { custom: "1" } });
  await post("/main/api/folder", { dir: "Mv", name: "In" });
  await call("/main/api/caption", { as: "owner", method: "PUT", body: JSON.stringify({ kind: "main", path: "Mv/s.mp3", op: "add", text: "moved note" }) });
  await call("/main/api/key", { as: "owner", method: "PUT", body: JSON.stringify({ path: "Mv/s.mp3", key: "Am", src: "manual" }) });
  const room = await (await post("/main/api/invites", { name: "R", ttl: 0, dir: "Mv", items: ["s.mp3"] })).json();
  assert.equal((await post("/main/api/move", { paths: ["Mv/s.mp3"], to: "Mv/In" }, "stranger")).status, 404);
  const j = await (await post("/main/api/move", { paths: ["Mv/s.mp3"], to: "Mv/In" })).json();
  assert.deepEqual(j, { ok: true, moved: [{ from: "Mv/s.mp3", to: "Mv/In/s.mp3" }], failed: [] });
  assert.equal(await MAIN.head("files/Mv/s.mp3"), null);
  assert.equal(await (await MAIN.get("files/Mv/In/s.mp3")).text(), "song");
  assert.equal((await MAIN.head("files/Mv/In/s.mp3")).customMetadata.was, "Mv/s.mp3");
  assert.equal(await MAIN.head("art/Mv/s.mp3"), null);
  assert.equal(await (await MAIN.get("art/Mv/In/s.mp3")).text(), "pic");
  const page = await (await call("/main?p=Mv/In", { as: "owner" })).text();
  assert.ok(page.includes("moved note"));
  assert.ok(page.includes('"key":"Am"'));
  // the room in the old folder no longer reaches it
  assert.equal((await call("/m/" + room.url.split("/m/")[1] + "/f/s.mp3")).status, 404);
  // up to the root, and a no-op when it is already there
  assert.equal((await (await post("/main/api/move", { paths: ["Mv/In/s.mp3"], to: "" })).json()).moved[0].to, "s.mp3");
  assert.deepEqual((await (await post("/main/api/move", { paths: ["s.mp3"], to: "" })).json()).moved, [{ from: "s.mp3", to: "s.mp3" }]);
  assert.equal(await (await MAIN.get("files/Mv/keep.jpg")).text(), "k");
});

await test("move: never replaces a file, never into a missing folder, partial results reported", async () => {
  await MAIN.put("files/Mc/a.jpg", "new a");
  await MAIN.put("files/Mc/b.jpg", "b");
  await MAIN.put("files/Mc/Dst/a.jpg", "old a");
  const r = await post("/main/api/move", { paths: ["Mc/a.jpg", "Mc/b.jpg", "Mc/gone.jpg"], to: "Mc/Dst" });
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.equal(j.ok, false);
  assert.deepEqual(j.moved, [{ from: "Mc/b.jpg", to: "Mc/Dst/b.jpg" }]);
  assert.deepEqual(j.failed.map((f) => f.path), ["Mc/a.jpg", "Mc/gone.jpg"]);
  assert.equal(await (await MAIN.get("files/Mc/Dst/a.jpg")).text(), "old a");
  assert.equal(await (await MAIN.get("files/Mc/a.jpg")).text(), "new a");
  // all failed -> 409
  assert.equal((await post("/main/api/move", { paths: ["Mc/a.jpg"], to: "Mc/Dst" })).status, 409);
  // a folder that does not exist is not made by a move
  assert.equal((await post("/main/api/move", { paths: ["Mc/a.jpg"], to: "Mc/New" })).status, 404);
  assert.equal((await MAIN.list({ prefix: "files/Mc/New" })).objects.length, 0);
});

await test("move: path traversal, markers and bad lists are refused before anything moves", async () => {
  await MAIN.put("files/Mt/a.jpg", "a");
  await post("/main/api/folder", { dir: "Mt", name: "In" });
  await MAIN.put("trash/2026-01-01/secret.jpg", "s");
  await MAIN.put("invites/x.json", "{}");
  const before = await allKeys();
  const marker = (await MAIN.list({ prefix: "files/Mt/In/.folder-" })).objects[0].key.slice("files/".length);
  const badPaths = ["../trash/2026-01-01/secret.jpg", "Mt/../../invites/x.json", "Mt/./a.jpg", "Mt//a.jpg", "..", "", "/", "Mt/a.jpg\u0000", "Mt/\u0001a.jpg", marker, 7, null];
  for (const p of badPaths) {
    assert.equal((await post("/main/api/move", { paths: [p], to: "Mt/In" })).status, 400, "path " + JSON.stringify(p));
    // a bad entry anywhere in the list stops the whole request
    assert.equal((await post("/main/api/move", { paths: ["Mt/a.jpg", p], to: "Mt/In" })).status, 400, "mixed " + JSON.stringify(p));
  }
  const badTo = ["..", "../art", "Mt/..", "Mt/In/../..", "Mt//In", "./Mt", "Mt\u0000", undefined, null, 3, ["Mt"]];
  for (const to of badTo) {
    assert.equal((await post("/main/api/move", { paths: ["Mt/a.jpg"], to })).status, 400, "to " + JSON.stringify(to));
  }
  assert.equal((await post("/main/api/move", { paths: [], to: "Mt/In" })).status, 400);
  assert.equal((await post("/main/api/move", { paths: "Mt/a.jpg", to: "Mt/In" })).status, 400);
  assert.equal((await post("/main/api/move", { paths: Array.from({ length: 201 }, (_, i) => "Mt/" + i), to: "Mt/In" })).status, 400);
  // a leading slash is only trimmed: the path still resolves under files/
  assert.deepEqual(after(await allKeys(), before), []);
  // the folder picker refuses traversal too
  for (const p of ["..", "Mt/..", "../trash"]) assert.equal((await call("/main/api/folders?p=" + encodeURIComponent(p), { as: "owner", headers: { "x-gallery": "1" } })).status, 400);
  assert.equal((await call("/main/api/folders?p=Nowhere", { as: "owner", headers: { "x-gallery": "1" } })).status, 404);
  assert.equal((await call("/main/api/folders?p=Mt", { as: "stranger", headers: { "x-gallery": "1" } })).status, 404);
  assert.equal(await (await MAIN.get("trash/2026-01-01/secret.jpg")).text(), "s");
  assert.equal(await (await MAIN.get("files/Mt/a.jpg")).text(), "a");
});
function after(now, before) {
  return now.filter((k) => !before.includes(k)).concat(before.filter((k) => !now.includes(k)));
}

// ---------- WebDAV: /dav/notability (Basic, append-only) and /main/dav (Access, read-write) ----------

const basic = (pass, user = "notability") => "Basic " + Buffer.from(user + ":" + pass).toString("base64");
let ipN = 0;
const nb = (path, { pass = "note-pass", ip, headers = {}, ...init } = {}) =>
  mf.dispatchFetch(ORIGIN + "/dav/notability/" + path, {
    ...init,
    headers: { ...(pass === null ? {} : { authorization: basic(pass) }), "cf-connecting-ip": ip || "10.0.0.1", ...headers },
  });
const md = (path, init = {}) => call("/main/dav/" + path, { as: "mac", ...init });
const hrefs = (xml) => [...xml.matchAll(/<d:href>([^<]*)<\/d:href>/g)].map((m) => m[1]);

await test("dav/notability: Basic auth with its own password; wrong ones are counted and locked out", async () => {
  const none = await nb("", { method: "PROPFIND", pass: null });
  assert.equal(none.status, 401);
  assert.match(none.headers.get("www-authenticate"), /^Basic realm="Notability backup"/);
  assert.equal((await nb("", { method: "PROPFIND", pass: "wrong" })).status, 401);
  assert.equal((await nb("", { method: "PROPFIND", headers: { authorization: "Basic !!!" } })).status, 401);
  // an Access token is not a way in
  assert.equal((await mf.dispatchFetch(ORIGIN + "/dav/notability/", { method: "PROPFIND", headers: { "cf-access-jwt-assertion": ownerJwt } })).status, 401);
  for (let i = 0; i < 10; i++) assert.equal((await nb("", { method: "PROPFIND", pass: "guess" + i, ip: "10.9.9.9" })).status, 401);
  assert.equal((await nb("", { method: "PROPFIND", pass: "note-pass", ip: "10.9.9.9" })).status, 429);
  assert.equal((await nb("", { method: "PROPFIND", ip: "10.0.0.2" })).status, 207);
});

await test("dav/notability: PROPFIND, MKCOL, PUT as Auto-Backup does; a second PUT keeps both versions", async () => {
  const opt = await nb("", { method: "OPTIONS" });
  assert.equal(opt.headers.get("dav"), "1");
  assert.ok(!opt.headers.get("allow").includes("DELETE"));
  const root = await nb("", { method: "PROPFIND", headers: { depth: "1" } });
  assert.equal(root.status, 207);
  assert.deepEqual(hrefs(await root.text()), ["/dav/notability/"]);
  assert.equal((await nb("Notes", { method: "MKCOL" })).status, 201);
  assert.equal((await nb("Notes/", { method: "MKCOL" })).status, 405);
  assert.equal((await nb("Missing/Sub", { method: "MKCOL" })).status, 409);
  const name = "Notes/Lecture 3: Waves.pdf";
  const enc = "Notes/" + encodeURIComponent("Lecture 3: Waves.pdf");
  assert.equal((await nb(enc, { method: "PUT", body: "v1", headers: { "content-type": "application/pdf" } })).status, 201);
  assert.equal((await nb(enc, { method: "PUT", body: "v2" })).status, 204);
  assert.equal(await (await MAIN.get("notability-backup/" + name)).text(), "v2");
  const vers = (await MAIN.list({ prefix: "notability-versions/Notes/" })).objects;
  assert.equal(vers.length, 1);
  assert.equal(await (await MAIN.get(vers[0].key)).text(), "v1");
  const list = await (await nb("Notes/", { method: "PROPFIND", headers: { depth: "1" } })).text();
  assert.deepEqual(hrefs(list), ["/dav/notability/Notes/", "/dav/notability/" + enc]); // the .folder- marker is hidden
  assert.match(list, /<d:getcontentlength>2<\/d:getcontentlength>/);
  assert.equal(await (await nb(enc)).text(), "v2");
  assert.equal((await nb("Nope/x.pdf", { method: "PUT", body: "x" })).status, 409);
  assert.equal((await nb("", { method: "PROPFIND", headers: { depth: "infinity" } })).status, 403);
  // append-only: nothing is deleted, moved, copied or re-propertied
  for (const method of ["DELETE", "MOVE", "COPY", "PROPPATCH", "LOCK", "POST"]) {
    assert.equal((await nb(enc, { method, headers: { destination: ORIGIN + "/dav/notability/Notes/x.pdf" } })).status, 405, method);
  }
  assert.equal(await (await MAIN.get("notability-backup/" + name)).text(), "v2");
});

await test("dav: path traversal on either mount is refused and writes nothing outside its prefix", async () => {
  await MAIN.put("files/Dt/a.jpg", "a");
  await MAIN.put("invites/dav.json", "{}");
  const before = await allKeys();
  // the URL parser already resolves plain %2e%2e segments, so those never reach a mount: refused elsewhere
  const resolved = ["%2e%2e/files/Dt/a.jpg", "Notes/%2e%2e/%2e%2e/x", "%2e/%2e%2e/x"];
  // the rest reach the mount, and cleanPath refuses them after decoding: %2f, NUL, newline, empty segment, bad escape
  const bad = ["%2e%2e%2f%2e%2e%2finvites%2fdav.json", "Dt%2f%2e%2e%2f%2e%2e%2finvites%2fdav.json", "a%2f%2e%2e%2fb", "a%00b", "a%0ab", "Notes//x", "%E0%A4%A"];
  for (const p of [...resolved, ...bad]) {
    for (const method of ["PUT", "MKCOL", "GET", "PROPFIND"]) {
      const init = { method, ...(method === "PUT" ? { body: "x" } : {}) };
      const a = (await nb(p, init)).status;
      const b = (await md(p, init)).status;
      if (bad.includes(p)) {
        assert.equal(a, 400, "notability " + method + " " + p);
        assert.equal(b, 400, "main " + method + " " + p);
      } else {
        assert.ok(a >= 400 && b >= 400, method + " " + p + " " + a + "/" + b);
      }
    }
  }
  // hidden names and folder markers are not served or written
  const hid = ["._a.jpg", ".DS_Store", "Dt/.folder-0123456789abcdef", "Dt/.secret"];
  for (const p of hid) {
    assert.equal((await md(p, { method: "PUT", body: "x" })).status, 403, "put " + p);
    assert.equal((await nb(p, { method: "PUT", body: "x" })).status, 403, "nb put " + p);
    assert.equal((await md(p, { method: "MKCOL" })).status, 403, "mkcol " + p);
  }
  // a Destination off this mount, off this host, or with traversal
  for (const d of [ORIGIN + "/main/api/folder", "http://evil.test/main/dav/Dt/b.jpg", ORIGIN + "/main/dav/%2e%2e/art/b.jpg", ORIGIN + "/dav/notability/b.jpg", ORIGIN + "/main/dav/Dt/.b.jpg", "", ORIGIN + "/main/dav/"]) {
    assert.equal((await md("Dt/a.jpg", { method: "MOVE", headers: { destination: d } })).status, 400, "dest " + d);
    assert.equal((await md("Dt/a.jpg", { method: "COPY", headers: { destination: d } })).status, 400, "copy dest " + d);
  }
  assert.deepEqual(after(await allKeys(), before), []);
  assert.equal(await (await MAIN.get("files/Dt/a.jpg")).text(), "a");
});

await test("main/dav: Access only; PROPFIND hides markers; PUT keeps the old file in the trash", async () => {
  await MAIN.put("files/Dv/a.txt", "one", { httpMetadata: { contentType: "text/plain" }, customMetadata: { mtime: "1700000000" } });
  await call("/main/api/folder", { as: "owner", method: "POST", body: JSON.stringify({ dir: "Dv", name: "Sub" }) });
  assert.equal((await mf.dispatchFetch(ORIGIN + "/main/dav/Dv/", { method: "PROPFIND" })).status, 404);
  assert.equal((await call("/main/dav/Dv/", { as: "stranger", method: "PROPFIND" })).status, 404);
  assert.equal((await mf.dispatchFetch(ORIGIN + "/main/dav/Dv/a.txt", { headers: { authorization: basic("note-pass") } })).status, 404);
  const pf = await md("Dv/", { method: "PROPFIND", headers: { depth: "1" } });
  assert.equal(pf.status, 207);
  const xml = await pf.text();
  assert.deepEqual(hrefs(xml).sort(), ["/main/dav/Dv/", "/main/dav/Dv/Sub/", "/main/dav/Dv/a.txt"]);
  assert.match(xml, /Tue, 14 Nov 2023 22:13:20 GMT/); // rclone's mtime
  // the browser session cookie works too (Access in front)
  assert.equal((await call("/main/dav/Dv/a.txt", { as: "cookie" })).status, 200);
  const r = await md("Dv/a.txt", { headers: { range: "bytes=1-2" } });
  assert.equal(r.status, 206);
  assert.equal(await r.text(), "ne");
  // overwrite: conditional, versioned
  const etag = (await md("Dv/a.txt", { method: "HEAD" })).headers.get("etag");
  assert.equal((await md("Dv/a.txt", { method: "PUT", body: "x", headers: { "if-none-match": "*" } })).status, 412);
  assert.equal((await md("Dv/a.txt", { method: "PUT", body: "x", headers: { "if-match": '"nope"' } })).status, 412);
  const w = await md("Dv/a.txt", { method: "PUT", body: "two", headers: { "if-match": etag, "x-oc-mtime": "1710000000" } });
  assert.equal(w.status, 204);
  const now = await MAIN.head("files/Dv/a.txt");
  assert.equal(now.customMetadata.mtime, "1710000000");
  const old = (await MAIN.list({ prefix: "trash/" })).objects.filter((o) => o.key.includes("/Dv/a.txt@"));
  assert.equal(old.length, 1);
  assert.equal(await (await MAIN.get(old[0].key)).text(), "one");
  // new files and folders; a chunked upload with no length is refused
  assert.equal((await md("Dv/Sub/b.txt", { method: "PUT", body: "b" })).status, 201);
  assert.equal((await md("Dv/Sub", { method: "PUT", body: "b" })).status, 405);
  assert.equal((await md("Dv/New", { method: "MKCOL" })).status, 201);
  assert.match((await MAIN.list({ prefix: "files/Dv/New/" })).objects[0].key, /\/\.folder-[0-9a-f]{16}$/);
  // chunked uploads (no Content-Length, as Finder sends) are read into memory up to 32 MiB
  const chunks = (n, size) => new ReadableStream({ start(c) { for (let i = 0; i < n; i++) c.enqueue(new Uint8Array(size).fill(115)); c.close(); } });
  assert.equal((await md("Dv/s.txt", { method: "PUT", body: chunks(2, 1), duplex: "half" })).status, 201);
  assert.equal(await (await MAIN.get("files/Dv/s.txt")).text(), "ss");
  assert.equal((await md("Dv/big.bin", { method: "PUT", body: chunks(33, 1024 * 1024), duplex: "half" })).status, 413);
  assert.equal(await MAIN.head("files/Dv/big.bin"), null);
});

await test("main/dav: MOVE and COPY files with their comments; DELETE to the trash; folders stay put", async () => {
  await MAIN.put("files/Dm/a.mp3", "A", { httpMetadata: { contentType: "audio/mpeg" } });
  await MAIN.put("files/Dm/In/x.txt", "X");
  await call("/main/api/caption", { as: "owner", method: "PUT", body: JSON.stringify({ kind: "main", path: "Dm/a.mp3", op: "add", text: "dav note" }) });
  const dest = (p) => ({ destination: ORIGIN + "/main/dav/" + p });
  assert.equal((await md("Dm/a.mp3", { method: "MOVE", headers: dest("Dm/In/b.mp3") })).status, 201);
  assert.equal(await MAIN.head("files/Dm/a.mp3"), null);
  assert.equal(await (await MAIN.get("files/Dm/In/b.mp3")).text(), "A");
  assert.ok((await (await call("/main?p=Dm/In", { as: "owner" })).text()).includes("dav note"));
  assert.equal((await md("Dm/In/b.mp3", { method: "MOVE", headers: dest("Dm/Nope/b.mp3") })).status, 409);
  // Overwrite: F refuses, T sends what was there to the trash first
  assert.equal((await md("Dm/In/b.mp3", { method: "COPY", headers: { ...dest("Dm/In/x.txt"), overwrite: "F" } })).status, 412);
  assert.equal(await (await MAIN.get("files/Dm/In/x.txt")).text(), "X");
  assert.equal((await md("Dm/In/b.mp3", { method: "COPY", headers: dest("Dm/In/x.txt") })).status, 204);
  assert.equal(await (await MAIN.get("files/Dm/In/x.txt")).text(), "A");
  assert.ok((await MAIN.list({ prefix: "trash/" })).objects.some((o) => o.key.endsWith("/Dm/In/x.txt")));
  // DELETE: files to the trash, never a folder or the root
  assert.equal((await md("Dm/In/x.txt", { method: "DELETE" })).status, 204);
  assert.equal(await MAIN.head("files/Dm/In/x.txt"), null);
  assert.equal((await md("Dm/In/", { method: "DELETE" })).status, 403);
  assert.equal((await md("", { method: "DELETE" })).status, 403);
  assert.equal((await md("Dm/In", { method: "MOVE", headers: dest("Dm/Out") })).status, 403);
  assert.equal((await md("Dm/In/b.mp3", { method: "PROPPATCH" })).status, 405);
  assert.equal((await md("Dm/In/b.mp3", { method: "POST" })).status, 405);
  assert.equal(await (await MAIN.get("files/Dm/In/b.mp3")).text(), "A");
});

await test("main/dav-tmp: Access only, every device token listed; tmp is read-write and deletes for good", async () => {
  const TMP = await mf.getR2Bucket("TMP");
  const mt = (path, init = {}) => call("/main/dav-tmp/" + path, { as: "mac", ...init });
  await TMP.put("Dl/a.pdf", "A", { customMetadata: { mtime: "1700000000" } });
  // nobody else: no token, a stranger, the Notability password, a device token that isn't listed
  assert.equal((await mf.dispatchFetch(ORIGIN + "/main/dav-tmp/", { method: "PROPFIND" })).status, 404);
  assert.equal((await call("/main/dav-tmp/", { as: "stranger", method: "PROPFIND" })).status, 404);
  assert.equal((await mf.dispatchFetch(ORIGIN + "/main/dav-tmp/Dl/a.pdf", { headers: { authorization: basic("note-pass") } })).status, 404);
  const asDevice = async (name) => mf.dispatchFetch(ORIGIN + "/main/dav-tmp/Dl/a.pdf", { headers: { "cf-access-jwt-assertion": await jwt({ common_name: name }) } });
  assert.equal((await asDevice("phone-id.access")).status, 200);
  assert.equal((await asDevice("lost-laptop.access")).status, 404);
  // reads and lists the TMP bucket, not Main
  const xml = await (await mt("Dl/", { method: "PROPFIND", headers: { depth: "1" } })).text();
  assert.deepEqual(hrefs(xml).sort(), ["/main/dav-tmp/Dl/", "/main/dav-tmp/Dl/a.pdf"]);
  assert.notEqual((await mt("%2e%2e/files/Dv/a.txt")).status, 200);
  // writes: new file, overwrite with no trash, folders, move and delete for good
  assert.equal((await mt("Dl/b.txt", { method: "PUT", body: "b", headers: { "x-oc-mtime": "1710000000" } })).status, 201);
  assert.equal((await TMP.head("Dl/b.txt")).customMetadata.mtime, "1710000000");
  assert.equal((await mt("Dl/b.txt", { method: "PUT", body: "bb" })).status, 204);
  assert.equal(await (await TMP.get("Dl/b.txt")).text(), "bb");
  assert.equal((await MAIN.list({ prefix: "trash/" })).objects.filter((o) => o.key.includes("/Dl/b.txt@")).length, 0);
  assert.equal((await mt("Dl/Sub", { method: "MKCOL" })).status, 201);
  assert.equal((await mt("Dl/b.txt", { method: "MOVE", headers: { destination: ORIGIN + "/main/dav-tmp/Dl/Sub/c.txt" } })).status, 201);
  assert.equal(await TMP.head("Dl/b.txt"), null);
  assert.equal(await (await TMP.get("Dl/Sub/c.txt")).text(), "bb");
  assert.equal((await mt("Dl/Sub/c.txt", { method: "MOVE", headers: { destination: ORIGIN + "/main/dav/Dl/c.txt" } })).status, 400);
  assert.equal((await mt("Dl/Sub/", { method: "DELETE" })).status, 409);
  assert.equal((await mt("Dl/Sub/c.txt", { method: "DELETE" })).status, 204);
  assert.equal(await TMP.head("Dl/Sub/c.txt"), null);
  assert.equal((await mt("Dl/Sub/", { method: "DELETE" })).status, 204);
  assert.equal((await TMP.list({ prefix: "Dl/Sub/" })).objects.length, 0);
  assert.equal((await mt("", { method: "DELETE" })).status, 403);
  assert.equal(await (await TMP.get("Dl/a.pdf")).text(), "A");
});

await test("main/nc: rclone's chunked uploads (nextcloud vendor) are joined into one file at MOVE", async () => {
  const FILES = "/main/nc/dav/files/owner/";
  const UP = "/main/nc/dav/uploads/owner/rclone-chunked-upload-0123abcd/";
  const up = (path, init = {}) => call(UP + path, { as: "mac", ...init });
  const range = (a, b) => String(a).padStart(15, "0") + "-" + String(b).padStart(15, "0");
  await MAIN.put("files/Nc/old.bin", "OLD");
  // the Nextcloud-shaped Main mount is the same library as /main/dav/
  assert.equal((await call(FILES + "Nc/old.bin", { as: "mac" })).status, 200);
  assert.equal((await mf.dispatchFetch(ORIGIN + UP, { method: "MKCOL" })).status, 404);
  assert.equal((await call(UP, { as: "stranger", method: "MKCOL" })).status, 404);
  // rclone: DELETE (leftovers), MKCOL, PUT chunks named by byte range, MOVE .file to the destination
  assert.equal((await up("", { method: "DELETE" })).status, 204);
  assert.equal((await up("", { method: "MKCOL" })).status, 201);
  assert.equal((await up(range(0, 3), { method: "PUT", body: "abcd" })).status, 201);
  assert.equal((await up(range(4, 7), { method: "PUT", body: "efg" })).status, 400); // length doesn't match the name
  assert.equal((await up(range(4, 7), { method: "PUT", body: "efgh" })).status, 201);
  assert.equal((await up(range(8, 9), { method: "PUT", body: "ij" })).status, 201);
  assert.equal((await up("../x", { method: "PUT", body: "x" })).status, 400);
  const dest = (p) => ({ destination: ORIGIN + FILES + p });
  assert.equal((await up(".file", { method: "MOVE", headers: dest("Nope/new.bin") })).status, 409);
  assert.equal((await up(".file", { method: "MOVE", headers: { destination: ORIGIN + "/main/dav-tmp/new.bin" } })).status, 400);
  const m = await up(".file", { method: "MOVE", headers: { ...dest("Nc/new.bin"), "x-oc-mtime": "1710000000" } });
  assert.equal(m.status, 201);
  const made = await MAIN.get("files/Nc/new.bin");
  assert.equal(await made.text(), "abcdefghij");
  assert.equal(made.customMetadata.mtime, "1710000000");
  assert.equal((await MAIN.list({ prefix: ".uploads/" })).objects.length, 0);
  // a gap between chunks: nothing is written
  await up("", { method: "MKCOL" });
  await up(range(0, 1), { method: "PUT", body: "ab" });
  await up(range(4, 5), { method: "PUT", body: "ef" });
  assert.equal((await up(".file", { method: "MOVE", headers: dest("Nc/gap.bin") })).status, 400);
  assert.equal(await MAIN.head("files/Nc/gap.bin"), null);
  assert.equal((await up("", { method: "DELETE" })).status, 204);
  assert.equal((await MAIN.list({ prefix: ".uploads/" })).objects.length, 0);
  // over an existing file: the old one goes to the trash (Overwrite F refuses)
  await up("", { method: "MKCOL" });
  await up(range(0, 2), { method: "PUT", body: "NEW" });
  assert.equal((await up(".file", { method: "MOVE", headers: { ...dest("Nc/old.bin"), overwrite: "F" } })).status, 412);
  assert.equal((await up(".file", { method: "MOVE", headers: dest("Nc/old.bin") })).status, 204);
  assert.equal(await (await MAIN.get("files/Nc/old.bin")).text(), "NEW");
  const old = (await MAIN.list({ prefix: "trash/" })).objects.filter((o) => o.key.includes("/Nc/old.bin@"));
  assert.equal(old.length, 1);
  assert.equal(await (await MAIN.get(old[0].key)).text(), "OLD");
  // rclone's Nextcloud hash refresh is a no-op
  assert.equal((await call(FILES + "Nc/new.bin", { as: "mac", method: "PATCH", headers: { "x-recalculate-hash": "sha1" } })).status, 204);
  // tmp has the same, into the TMP bucket
  const TMP = await mf.getR2Bucket("TMP");
  const tup = (path, init = {}) => call("/main/nc-tmp/dav/uploads/owner/rclone-chunked-upload-ff/" + path, { as: "mac", ...init });
  await tup("", { method: "MKCOL" });
  await tup(range(0, 1), { method: "PUT", body: "hi" });
  assert.equal((await tup(".file", { method: "MOVE", headers: { destination: ORIGIN + "/main/nc-tmp/dav/files/owner/t.txt" } })).status, 201);
  assert.equal(await (await TMP.get("t.txt")).text(), "hi");
  assert.equal((await TMP.list({ prefix: ".uploads/" })).objects.length, 0);
});

await test("main/dav-archive: Access only; read-write with its own trash, nothing reaches Main or tmp", async () => {
  const AR = await mf.getR2Bucket("ARCHIVE");
  const TMP = await mf.getR2Bucket("TMP");
  const ma = (path, init = {}) => call("/main/dav-archive/" + path, { as: "mac", ...init });
  const dest = (p) => ({ destination: ORIGIN + "/main/dav-archive/" + p });
  const trashed = async (p) => (await AR.list({ prefix: ".trash/" })).objects.filter((o) => o.key.includes("/" + p + "@"));
  await AR.put("chauphan/Movies/a.mp4", "A", { customMetadata: { mtime: "1700000000" } });
  // nobody else
  assert.equal((await mf.dispatchFetch(ORIGIN + "/main/dav-archive/", { method: "PROPFIND" })).status, 404);
  assert.equal((await call("/main/dav-archive/", { as: "stranger", method: "PROPFIND" })).status, 404);
  assert.equal((await mf.dispatchFetch(ORIGIN + "/main/dav-archive/chauphan/Movies/a.mp4", { headers: { authorization: basic("note-pass") } })).status, 404);
  // lists the ARCHIVE bucket; the trash is never listed or reachable
  const xml = await (await ma("chauphan/Movies/", { method: "PROPFIND", headers: { depth: "1" } })).text();
  assert.deepEqual(hrefs(xml).sort(), ["/main/dav-archive/chauphan/Movies/", "/main/dav-archive/chauphan/Movies/a.mp4"]);
  assert.equal(await (await ma("chauphan/Movies/a.mp4")).text(), "A");
  // overwrite: the old copy goes to .trash/, a stale base is refused
  assert.equal((await ma("chauphan/Movies/a.mp4", { method: "PUT", body: "A2" })).status, 204);
  assert.equal(await (await AR.get("chauphan/Movies/a.mp4")).text(), "A2");
  const old = await trashed("chauphan/Movies/a.mp4");
  assert.equal(old.length, 1);
  assert.equal(await (await AR.get(old[0].key)).text(), "A");
  assert.equal((await ma("chauphan/Movies/a.mp4", { method: "PUT", body: "A3", headers: { "if-match": '"stale"' } })).status, 412);
  const root = await (await ma("", { method: "PROPFIND", headers: { depth: "1" } })).text();
  assert.ok(!hrefs(root).some((h) => h.includes(".trash")));
  assert.notEqual((await ma(".trash/")).status, 200);
  assert.notEqual((await ma(encodeURI(old[0].key))).status, 200);
  assert.notEqual((await ma(".trash/x", { method: "PUT", body: "x" })).status, 201);
  // move, copy over a file (old one to the trash), delete to the trash; folders and the root are refused
  assert.equal((await ma("chauphan/Old", { method: "MKCOL" })).status, 201);
  assert.equal((await ma("chauphan/Movies/a.mp4", { method: "COPY", headers: dest("chauphan/Old/b.mp4") })).status, 201);
  assert.equal((await ma("chauphan/Old/b.mp4", { method: "PUT", body: "B" })).status, 204);
  assert.equal((await ma("chauphan/Movies/a.mp4", { method: "COPY", headers: dest("chauphan/Old/b.mp4") })).status, 204);
  assert.equal((await trashed("chauphan/Old/b.mp4")).length, 2);
  assert.equal((await ma("chauphan/Old/b.mp4", { method: "MOVE", headers: dest("chauphan/Old/c.mp4") })).status, 201);
  assert.equal(await AR.head("chauphan/Old/b.mp4"), null);
  assert.equal((await ma("chauphan/Old/c.mp4", { method: "MOVE", headers: { destination: ORIGIN + "/main/dav/Old/c.mp4" } })).status, 400);
  assert.equal((await ma("chauphan/Old/c.mp4", { method: "DELETE" })).status, 204);
  assert.equal(await AR.head("chauphan/Old/c.mp4"), null);
  assert.equal(await (await AR.get((await trashed("chauphan/Old/c.mp4"))[0].key)).text(), "A2");
  assert.equal((await ma("chauphan/Old/", { method: "DELETE" })).status, 403);
  assert.equal((await ma("", { method: "DELETE" })).status, 403);
  assert.equal((await ma("chauphan/Old", { method: "MOVE", headers: dest("chauphan/New") })).status, 403);
  // Finder's own files: stored by name, never listed, never trashed; other dot names still refused
  assert.equal((await ma("chauphan/Movies/._a.mp4", { method: "PUT", body: "xattr" })).status, 201);
  assert.equal((await ma("chauphan/Movies/.DS_Store", { method: "PUT", body: "ds" })).status, 201);
  assert.equal((await ma("chauphan/Movies/._a.mp4", { method: "PUT", body: "xattr2" })).status, 204);
  assert.equal((await trashed("chauphan/Movies/._a.mp4")).length, 0);
  assert.equal(await (await ma("chauphan/Movies/._a.mp4")).text(), "xattr2");
  assert.equal((await ma("chauphan/Movies/._a.mp4", { method: "PROPFIND", headers: { depth: "0" } })).status, 207);
  const listed = hrefs(await (await ma("chauphan/Movies/", { method: "PROPFIND", headers: { depth: "1" } })).text());
  assert.ok(!listed.some((h) => h.includes("/.")));
  assert.equal((await ma("chauphan/Movies/._a.mp4", { method: "MOVE", headers: dest("chauphan/Movies/._b.mp4") })).status, 201);
  assert.equal((await ma("chauphan/Movies/._b.mp4", { method: "DELETE" })).status, 204);
  assert.equal(await AR.head("chauphan/Movies/._b.mp4"), null);
  assert.equal((await trashed("chauphan/Movies/._b.mp4")).length, 0);
  assert.equal((await ma("chauphan/Movies/.hidden", { method: "PUT", body: "h" })).status, 403);
  assert.equal((await call("/main/dav/Dm/._x", { as: "mac", method: "PUT", body: "x" })).status, 403);
  // chunked uploads land in the archive and keep the old file
  const up = (path, init = {}) => call("/main/nc-archive/dav/uploads/owner/rclone-chunked-upload-aa/" + path, { as: "mac", ...init });
  await up("", { method: "MKCOL" });
  await up("000000000000000-000000000000002", { method: "PUT", body: "BIG" });
  assert.equal((await up(".file", { method: "MOVE", headers: { destination: ORIGIN + "/main/nc-archive/dav/files/owner/chauphan/Movies/a.mp4" } })).status, 204);
  assert.equal(await (await AR.get("chauphan/Movies/a.mp4")).text(), "BIG");
  assert.equal((await trashed("chauphan/Movies/a.mp4")).length, 2);
  assert.equal((await AR.list({ prefix: ".uploads/" })).objects.length, 0);
  // nothing written to Main or tmp
  assert.equal((await MAIN.list({ prefix: "files/chauphan/" })).objects.length, 0);
  assert.equal((await TMP.list({ prefix: "chauphan/" })).objects.length, 0);
});

await test("fp: the File Provider's read-only feed over gallery-archive (ids, items, content, changes)", async () => {
  const AR = await mf.getR2Bucket("ARCHIVE");
  const api = (p, init = {}) => call("/main/api/fp/archive/" + p, { as: "mac", ...init });
  const j = async (p) => (await api(p)).json();
  const VM = "chauphan/Voice Memos/2024";
  await AR.put(VM + "/a.m4a", "ABCDEF", { customMetadata: { mtime: "1700000000.8020115" } }); // rclone's fractional mtime
  await AR.put(VM + "/b.m4a", "B1");
  await AR.put(VM + "/c.m4a", "C1");
  // owner and the Mac only; read-only
  assert.equal((await mf.dispatchFetch(ORIGIN + "/main/api/fp/archive/items")).status, 404);
  assert.equal((await call("/main/api/fp/archive/items", { as: "stranger" })).status, 404);
  assert.equal((await api("items", { method: "PUT", body: "x" })).status, 405);
  assert.equal((await api("nope")).status, 404);
  assert.equal((await call("/main/api/fp/main/items", { as: "mac" })).status, 404);
  // the root: folders only from what's stored, never the bucket's own dot folders
  const top = await j("items");
  assert.equal(top.parent, "root");
  assert.ok(top.items.some((i) => i.name === "chauphan" && i.dir && /^d[0-9a-f]{24}$/.test(i.id)));
  assert.ok(!top.items.some((i) => i.name.startsWith(".")));
  assert.equal((await api("items?path=.trash")).status, 400);
  assert.equal((await api("items?path=chauphan/nowhere")).status, 404);
  // a folder: files with stable ids, size, etag, mtime; Finder files left out
  await AR.put(VM + "/._a.m4a", "x");
  const vm = await j("items?path=" + encodeURIComponent(VM));
  const a = vm.items.find((i) => i.name === "a.m4a");
  assert.deepEqual(vm.items.map((i) => i.name).sort(), ["a.m4a", "b.m4a", "c.m4a"]);
  assert.match(a.id, /^h[0-9a-f]{24}$/);
  assert.equal(a.size, 6);
  assert.equal(a.mtime, 1700000000);
  assert.equal(vm.parent, top.items.length && (await j("items?path=chauphan%2FVoice%20Memos")).items.find((i) => i.name === "2024").id);
  assert.equal((await j("items?path=" + encodeURIComponent(VM))).items.find((i) => i.name === "a.m4a").id, a.id);
  // content, with Range
  const part = await api("content?path=" + encodeURIComponent(VM + "/a.m4a"), { headers: { range: "bytes=1-2" } });
  assert.equal(part.status, 206);
  assert.equal(await part.text(), "BC");
  assert.equal((await api("content?path=.catalog%2Farchive%2Fsnapshot.json")).status, 400);
  assert.equal((await api("content?path=" + encodeURIComponent(VM + "/zz.m4a"))).status, 404);
  // changes: the first pass is the baseline (no events)
  const base = await j("changes");
  assert.equal(base.events.length, 0);
  assert.deepEqual(await j("changes?since=" + base.seq), { seq: base.seq, events: [], more: false });
  // writes around the Worker: a new file, an edit, a delete, a rename that kept its id
  await AR.put(VM + "/d.m4a", "D1");
  await AR.put(VM + "/b.m4a", "B2");
  await AR.delete(VM + "/c.m4a");
  await AR.put("chauphan/Voice Memos/2025/a renamed.m4a", "ABCDEF", { customMetadata: { fid: a.id } });
  await AR.delete(VM + "/a.m4a");
  // within a minute nothing is re-listed; an older snapshot is
  assert.equal((await j("changes?since=" + base.seq)).events.length, 0);
  const snap = await (await AR.get(".catalog/archive/snapshot.json")).json();
  await AR.put(".catalog/archive/snapshot.json", JSON.stringify({ ...snap, at: 0 }));
  const c = await j("changes?since=" + base.seq);
  assert.equal(c.seq, base.seq + 1);
  const by = (op, path) => c.events.find((e) => e.op === op && e.path === path);
  assert.ok(by("create", VM + "/d.m4a"));
  assert.ok(by("modify", VM + "/b.m4a"));
  assert.ok(by("delete", VM + "/c.m4a"));
  const mv = by("move", "chauphan/Voice Memos/2025/a renamed.m4a");
  assert.equal(mv.id, a.id);
  assert.equal(mv.from, VM + "/a.m4a");
  assert.ok(by("create", "chauphan/Voice Memos/2025") && by("create", "chauphan/Voice Memos/2025").dir);
  assert.equal(c.events.filter((e) => e.path.includes("/.")).length, 0);
  // the log is chained like sync's ledger (event-log.md): the batch starts at the snapshot's head, each event links on
  const batch1 = await (await AR.get(".catalog/archive/log/" + String(c.seq).padStart(12, "0") + ".json")).json();
  assert.equal(batch1.prev, GENESIS);
  let head = batch1.prev;
  for (const e of batch1.events) {
    const { chain, ...rest } = e;
    assert.equal(chain, await link(head, rest));
    head = chain;
  }
  assert.equal((await (await AR.get(".catalog/archive/snapshot.json")).json()).chain, head);
  // the new folder's item shows the moved file under the same id
  assert.equal((await j("items?path=chauphan%2FVoice%20Memos%2F2025")).items[0].id, a.id);
  // an anchor older than the log kept: 410, enumerate again
  await AR.delete(".catalog/archive/log/" + String(c.seq).padStart(12, "0") + ".json");
  assert.equal((await api("changes?since=" + base.seq)).status, 410);
  assert.equal((await api("changes?since=x")).status, 400);
  // the catalog is never reachable through the mount
  assert.notEqual((await call("/main/dav-archive/.catalog/archive/snapshot.json", { as: "mac" })).status, 200);
  const rootList = await (await call("/main/dav-archive/", { as: "mac", method: "PROPFIND", headers: { depth: "1" } })).text();
  assert.ok(!hrefs(rootList).some((h) => h.includes(".catalog")));
});

await test("fp: the catalog's chain and delete guard are sync's (event-log.md): same vector, held until the owner confirms", async () => {
  // the same bytes in, the same link out, as ledger.mjs's selftest
  const vec = { op: "create", id: "h000000000000000000000000", path: "a.m4a", dir: false, size: 1, etag: '"e"', mtime: 1 };
  assert.equal(await link(GENESIS, vec), "e704650f481588363d585a229270dc0033dc38cd814054bfb4d0e71bde83c894");
  assert.ok(!massDelete(10, 12) && massDelete(11, 12) && !massDelete(15, 200) && massDelete(21, 200) && massDelete(101, 1e7));

  const AR = await mf.getR2Bucket("ARCHIVE");
  const api = (p, init = {}) => call("/main/api/fp/archive/" + p, { as: "mac", ...init });
  const j = async (p) => (await api(p)).json();
  const stale = async () => {
    const s = await (await AR.get(".catalog/archive/snapshot.json")).json();
    await AR.put(".catalog/archive/snapshot.json", JSON.stringify({ ...s, at: 0 }));
  };
  const BULK = "chauphan/Bulk";
  for (let i = 0; i < 30; i++) await AR.put(`${BULK}/f${i}.m4a`, "x" + i);
  const logKey = (n) => ".catalog/archive/log/" + String(n).padStart(12, "0") + ".json";
  await stale();
  const s0 = (await j("changes")).seq; // this pass logs the 30 new files as the head batch
  const added = await (await AR.get(logKey(s0))).json();
  assert.equal(added.events.filter((e) => e.op === "create" && e.path.startsWith(BULK + "/f")).length, 30);

  // 25 of ~35 files gone at once: nothing is logged, the feed says it's held, the head doesn't move
  for (let i = 0; i < 25; i++) await AR.delete(`${BULK}/f${i}.m4a`);
  await stale();
  const held = await j("changes?since=" + s0);
  assert.deepEqual(held.events, []);
  assert.equal(held.seq, s0);
  assert.equal(held.held.deletes, 25);
  assert.ok((await AR.get(".catalog/archive/held.json")) !== null);
  assert.equal((await j("changes?since=" + s0)).held.deletes, 25); // asked again within a minute: still held, no relist

  // only the owner, signed in, confirms: never a device token, never a GET
  assert.equal((await api("confirm", { method: "POST" })).status, 403);
  assert.equal((await call("/main/api/fp/archive/confirm", { as: "owner" })).status, 405);
  const ok = await call("/main/api/fp/archive/confirm", { as: "owner", method: "POST" });
  assert.equal(ok.status, 200);
  assert.equal((await ok.json()).deletes, 25);
  assert.equal(await AR.get(".catalog/archive/held.json"), null);

  // the next pass goes through, chained onto the last batch, and spends the confirmation
  const after = await j("changes?since=" + s0);
  assert.equal(after.seq, s0 + 1);
  assert.equal(after.events.filter((e) => e.op === "delete").length, 25);
  assert.equal(after.held, undefined);
  const prevBatch = await (await AR.get(logKey(s0))).json();
  const nextBatch = await (await AR.get(logKey(s0 + 1))).json();
  assert.equal(nextBatch.prev, prevBatch.events[prevBatch.events.length - 1].chain);
  assert.equal(await AR.get(".catalog/archive/confirm.json"), null);
  assert.equal((await call("/main/api/fp/archive/confirm", { as: "owner", method: "POST" })).status, 409);
});

await test("main/archive: Main's page and player over gallery-archive/chauphan, read-only", async () => {
  const AR = await mf.getR2Bucket("ARCHIVE");
  await AR.put("chauphan/Shelf/Sub/x.txt", "x");
  await AR.put("chauphan/Shelf/b.m4a", "0123456789", { customMetadata: { mtime: "1700000000" } });
  await AR.put("chauphan/Shelf/a.m4a", "AAAA");
  await AR.put("chauphan/Shelf/.DS_Store", "ds");
  await AR.put(".catalog/archive/secret.json", "{}");
  // owner only
  assert.equal((await mf.dispatchFetch(ORIGIN + "/main/archive")).status, 404);
  assert.equal((await call("/main/archive", { as: "stranger" })).status, 403); // the wrong-account page, as on /main
  // a folder: the same page, with its items in order, its subfolders, and the read-only switches
  const page = await (await call("/main/archive?p=Shelf", { as: "owner" })).text();
  const G = JSON.parse(page.match(/const G=(\{.*?\});\n/s)[1]);
  assert.equal(G.readOnly, true);
  assert.equal(G.mainApi, "/main/archive/api");
  assert.equal(G.api, "/main/archive/api");
  assert.deepEqual(G.items.map((f) => [f.n, f.path, f.src]), [
    ["00000", "Shelf/a.m4a", "/main/archive/f/Shelf/a.m4a"],
    ["00001", "Shelf/b.m4a", "/main/archive/f/Shelf/b.m4a"],
  ]);
  assert.equal(G.items[1].taken, 1700000000000);
  assert.ok(page.includes('href="/main/archive?p=Shelf%2FSub"'));
  assert.ok(!page.includes(".DS_Store"));
  assert.equal((await call("/main/archive?p=Nope", { as: "owner" })).status, 404);
  assert.equal((await call("/main/archive?p=..%2F.catalog", { as: "owner" })).status, 404);
  // files, with Range; nothing outside chauphan/ or in a dot folder
  const part = await call("/main/archive/f/Shelf/b.m4a", { as: "owner", headers: { range: "bytes=2-4" } });
  assert.equal(part.status, 206);
  assert.equal(await part.text(), "234");
  assert.equal((await call("/main/archive/f/..%2F.catalog%2Farchive%2Fsecret.json", { as: "owner" })).status, 404);
  assert.equal((await call("/main/archive/f/Shelf/.DS_Store", { as: "owner" })).status, 404);
  // the page's API: whoami answers, reads are 404, every write is 403, and nothing is written anywhere
  const before = (await AR.list()).objects.length;
  assert.equal((await call("/main/archive/api/whoami", { as: "owner" })).status, 200);
  assert.equal((await call("/main/archive/api/transcript?path=Shelf%2Fa.m4a", { as: "owner" })).status, 404);
  for (const [p, m] of [["file?key=Shelf%2Fa.m4a", "DELETE"], ["file?order=1&dir=Shelf", "PUT"], ["rename", "POST"], ["cover?path=Shelf%2Fa.m4a", "PUT"], ["key", "PUT"]]) {
    assert.equal((await call("/main/archive/api/" + p, { as: "owner", method: m, body: m === "DELETE" ? undefined : "[]", headers: { origin: ORIGIN } })).status, 403, p);
  }
  assert.equal((await call("/main/archive/f/Shelf/a.m4a", { as: "owner", method: "PUT", body: "z" })).status, 403);
  assert.equal((await AR.list()).objects.length, before);
  assert.equal(await (await AR.get("chauphan/Shelf/a.m4a")).text(), "AAAA");
});

await test("SPEC 42: temporary downloads go to TMP, are owner-made, and die at expiry", async () => {
  const TMP = await mf.getR2Bucket("TMP");
  await MAIN.put("files/Tmp/song.mp3", "SONG", { httpMetadata: { contentType: "audio/mpeg" } });
  // only the owner, same-site, can make one
  assert.equal((await call("/main/api/tmp?name=a.wav", { method: "PUT", body: "x" })).status, 404);
  assert.equal((await call("/main/api/tmp?name=a.wav", { as: "owner", write: false, method: "PUT", body: "x" })).status, 403);
  // bytes from the page (a baked download)
  const up = await (await call("/main/api/tmp?name=" + encodeURIComponent("../My mix.wav"), { as: "owner", method: "PUT", body: "WAVDATA", headers: { "content-type": "audio/wav" } })).json();
  assert.match(up.url, /^\/t\/[0-9a-f]{32}\/My%20mix\.wav$/);
  assert.ok(up.expires > Date.now());
  const g = await call(up.url);
  assert.equal(g.status, 200);
  assert.equal(await g.text(), "WAVDATA");
  assert.match(g.headers.get("content-disposition"), /^attachment/);
  assert.equal(g.headers.get("content-type"), "audio/wav");
  // a Main file copied across server side
  const cp = await (await call("/main/api/tmp?path=Tmp/song.mp3", { as: "owner", method: "PUT" })).json();
  assert.equal(await (await call(cp.url)).text(), "SONG");
  assert.equal((await call("/main/api/tmp?path=Tmp/none.mp3", { as: "owner", method: "PUT" })).status, 404);
  // a wrong id, a non-hex id, an unsafe name: 404
  assert.equal((await call("/t/" + "0".repeat(32) + "/My%20mix.wav")).status, 404);
  assert.equal((await call("/t/xyz/My%20mix.wav")).status, 404);
  // expired: 404 on GET and gone; the sweep clears the rest
  const key = "tmp/" + decodeURIComponent(up.url.slice(3)); // keys live under tmp/ (lifecycle prefix)
  await TMP.put(key, "WAVDATA", { customMetadata: { expires: String(Date.now() - 1) } });
  assert.equal((await call(up.url)).status, 404);
  for (let i = 0; i < 20 && (await TMP.head(key)); i++) await new Promise((r) => setTimeout(r, 25));
  assert.equal(await TMP.head(key), null);
});

console.log(`\n${passed} passed`);
await mf.dispose();