// /i/<key>: Obsidian note images (images.js), through the built Worker in Miniflare.

import { Miniflare } from "miniflare";
import { readdirSync } from "node:fs";
import assert from "node:assert/strict";
import { webcrypto as crypto, createHash } from "node:crypto";

const TEAM = "team.cloudflareaccess.com", AUD = "aud", CLIENT = "client-id.access";
const keys = await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
const jwk = { ...(await crypto.subtle.exportKey("jwk", keys.publicKey)), kid: "k1", alg: "RS256" };
const b64 = (x) => Buffer.from(x).toString("base64url");
async function jwt(claims) {
  const now = Math.floor(Date.now() / 1000);
  const data = b64(JSON.stringify({ alg: "RS256", kid: "k1" })) + "." +
    b64(JSON.stringify({ aud: [AUD], iss: "https://" + TEAM, exp: now + 600, iat: now, ...claims }));
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", keys.privateKey, new TextEncoder().encode(data));
  return data + "." + b64(new Uint8Array(sig));
}
const macJwt = await jwt({ common_name: CLIENT });
const strangerJwt = await jwt({ email: "someone@example.com" });

const BUILD = new URL("../.test-build/", import.meta.url).pathname;
const textModules = readdirSync(BUILD).filter((f) => /\.(css|js)$/.test(f) && f !== "worker.js");
const mf = new Miniflare({
  modules: [
    { type: "ESModule", path: BUILD + "worker.js" },
    ...textModules.map((f) => ({ type: "Text", path: BUILD + f })),
  ],
  compatibilityDate: "2026-08-01",
  r2Buckets: { PUBLIC: "p", MAIN: "m", KEEP: "k", TMP: "t", ARCHIVE: "a", NOTES_IMAGES: "notes-images-test" },
  bindings: { ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD, OWNER_EMAIL: "owner@example.com", SERVICE_CLIENT_ID: CLIENT },
  outboundService: (req) =>
    new URL(req.url).pathname === "/cdn-cgi/access/certs" ? Response.json({ keys: [jwk] }) : new Response("offline", { status: 503 }),
});
const IMAGES = await mf.getR2Bucket("NOTES_IMAGES");
const O = "http://gallery.test/i/";

const hash = "ab" + "0123456789abcdef".repeat(4).slice(2);
const key = `attachments/png/ab/${hash}.png`;
const svgKey = `attachments/svg/ab/${hash}.svg`;
await IMAGES.put(key, new Uint8Array([137, 80, 78, 71]));
await IMAGES.put(svgKey, "<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>");
await IMAGES.put("private/notes.md", "secret");

let n = 0;
const t = async (name, fn) => { await fn(); n++; console.log("ok", name); };

await t("serves a content-addressed image, cached for good", async () => {
  const r = await mf.dispatchFetch(O + key);
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("content-type"), "image/png");
  assert.match(r.headers.get("cache-control"), /immutable/);
  assert.deepEqual([...new Uint8Array(await r.arrayBuffer())], [137, 80, 78, 71]);
});

await t("If-None-Match gives 304", async () => {
  const etag = (await mf.dispatchFetch(O + key, { method: "HEAD" })).headers.get("etag");
  const r = await mf.dispatchFetch(O + key, { headers: { "If-None-Match": etag } });
  assert.equal(r.status, 304);
  await r.arrayBuffer();
});

await t("SVG is sandboxed and never sniffed", async () => {
  const r = await mf.dispatchFetch(O + svgKey);
  assert.equal(r.status, 200);
  assert.match(r.headers.get("content-security-policy"), /sandbox/);
  assert.equal(r.headers.get("x-content-type-options"), "nosniff");
  await r.arrayBuffer();
});

await t("anything that isn't a content-addressed image key is 404", async () => {
  for (const bad of [
    "private/notes.md",
    `attachments/png/cd/${hash}.png`, // hash2 must be the hash's first two characters
    `attachments/png/ab/${hash}.jpg`, // folder ext must match file ext
    `attachments/md/ab/${hash}.md`,
    `attachments/png/ab/${hash.slice(1)}.png`,
    `attachments/png/ab/../../private/notes.md`,
    `attachments/png/ab/${"ab" + "f".repeat(62)}.png`, // valid shape, not there
    "",
  ]) {
    const r = await mf.dispatchFetch(O + bad);
    assert.equal(r.status, 404, bad);
    await r.arrayBuffer();
  }
});

await t("read-only", async () => {
  const r = await mf.dispatchFetch(O + key, { method: "PUT", body: "x" });
  assert.equal(r.status, 405);
  await r.arrayBuffer();
});

const UP = "http://gallery.test/main/api/img";
const put = (q, body, h = {}, as = macJwt) =>
  mf.dispatchFetch(UP + q, { method: "PUT", body, headers: { "x-gallery": "1", ...(as ? { "cf-access-jwt-assertion": as } : {}), ...h } });
const jpeg = new Uint8Array([255, 216, 255, 224, 1, 2, 3]);
const sha = createHash("sha256").update(jpeg).digest("hex");

await t("upload: stores under the plugin's key, answers url + sha256 + md5", async () => {
  const r = await put("?name=Screenshot%202026.JPG", jpeg);
  assert.equal(r.status, 201);
  const j = await r.json();
  assert.equal(j.key, `attachments/jpg/${sha.slice(0, 2)}/${sha}.jpg`);
  assert.equal(j.sha256, sha);
  assert.equal(j.md5, createHash("md5").update(jpeg).digest("hex"));
  assert.equal(j.url, "http://gallery.test/i/" + j.key);
  assert.equal(j.existed, false);
  const g = await mf.dispatchFetch(j.url);
  assert.equal(g.status, 200);
  assert.equal(g.headers.get("content-type"), "image/jpeg");
  assert.deepEqual([...new Uint8Array(await g.arrayBuffer())], [...jpeg]);
});

await t("upload: same bytes again = same key, existed", async () => {
  const r = await put("", jpeg, { "content-type": "image/jpeg" });
  const j = await r.json();
  assert.equal(r.status, 200);
  assert.equal(j.existed, true);
  assert.equal(j.sha256, sha);
});

await t("upload: refuses non-images, empty bodies, strangers and no token", async () => {
  for (const [q, body, h, as, code] of [
    ["?ext=md", "x", {}, macJwt, 415],
    ["?name=a.exe", "x", {}, macJwt, 415],
    ["", "x", { "content-type": "text/html" }, macJwt, 415],
    ["?ext=png", "", {}, macJwt, 400],
    ["?ext=png", "x", {}, strangerJwt, 404],
    ["?ext=png", "x", {}, null, 404],
  ]) {
    const r = await put(q, body, h, as);
    assert.equal(r.status, code, q + " " + code);
    await r.arrayBuffer();
  }
});

await mf.dispose();
console.log(`images: ${n} ok`);
