// /i/<key>: Obsidian note images (images.js), through the built Worker in Miniflare.

import { Miniflare } from "miniflare";
import { readdirSync } from "node:fs";
import assert from "node:assert/strict";

const BUILD = new URL("../.test-build/", import.meta.url).pathname;
const textModules = readdirSync(BUILD).filter((f) => /\.(css|js)$/.test(f) && f !== "worker.js");
const mf = new Miniflare({
  modules: [
    { type: "ESModule", path: BUILD + "worker.js" },
    ...textModules.map((f) => ({ type: "Text", path: BUILD + f })),
  ],
  compatibilityDate: "2026-08-01",
  r2Buckets: { PUBLIC: "p", MAIN: "m", KEEP: "k", TMP: "t", ARCHIVE: "a", NOTES_IMAGES: "notes-images-test" },
  bindings: { ACCESS_TEAM_DOMAIN: "team.cloudflareaccess.com", ACCESS_AUD: "aud", OWNER_EMAIL: "owner@example.com" },
  outboundService: () => new Response("offline", { status: 503 }),
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

await mf.dispose();
console.log(`images: ${n} ok`);
