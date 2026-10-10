// Route tests: the built Worker in Miniflare, with in-memory R2 buckets and Access tokens signed
// by a throwaway key. Run with `npm test` (it builds first).

import { Miniflare } from "miniflare";
import { readdirSync } from "node:fs";
import { webcrypto as crypto } from "node:crypto";
import assert from "node:assert/strict";

const BUILD = new URL("../.test-build/", import.meta.url).pathname;
const TEAM = "team.cloudflareaccess.com";
const AUD = "test-aud";
const OWNER = "owner@example.com";
const CLIENT = "client-id.access";
const ORIGIN = "http://gallery.test";

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
  r2Buckets: { PUBLIC: "gallery-public-test", MAIN: "gallery-main-test" },
  bindings: { ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD, OWNER_EMAIL: OWNER, SERVICE_CLIENT_ID: CLIENT },
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
    console.log("FAIL " + name + "\n     " + (e && e.message));
    process.exitCode = 1;
  }
};

// ---------- tests ----------

await test("upload page loads for anyone", async () => {
  const r = await call("/");
  assert.equal(r.status, 200);
  assert.match(await r.text(), /New link/);
});

await test("Main is 404 without a token, with a stranger, and 200 for the owner", async () => {
  assert.equal((await call("/main")).status, 404);
  assert.equal((await call("/main", { as: "stranger" })).status, 404);
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

console.log(`\n${passed} passed`);
await mf.dispose();
