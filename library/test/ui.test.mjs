// Page tests: the built Worker served by Miniflare, driven in Chromium with Playwright.
// Covers the owner's Upload and Delete controls on Main and on a public link.

import { Miniflare } from "miniflare";
import { chromium } from "playwright";
import { readdirSync } from "node:fs";
import { webcrypto as crypto } from "node:crypto";
import assert from "node:assert/strict";
import { mkdtempSync, truncateSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const BUILD = new URL("../.test-build/", import.meta.url).pathname;
const TEAM = "team.cloudflareaccess.com";
const AUD = "test-aud";
const OWNER = "owner@example.com";

const keys = await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
  true,
  ["sign", "verify"]
);
const jwk = { ...(await crypto.subtle.exportKey("jwk", keys.publicKey)), kid: "k1", alg: "RS256" };
const b64 = (x) => Buffer.from(x).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const data =
  b64(JSON.stringify({ alg: "RS256", kid: "k1" })) +
  "." +
  b64(JSON.stringify({ aud: [AUD], iss: "https://" + TEAM, exp: now + 600, email: OWNER }));
const ownerJwt =
  data + "." + b64(new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", keys.privateKey, new TextEncoder().encode(data))));

const textModules = readdirSync(BUILD).filter((f) => /\.(css|js)$/.test(f) && f !== "worker.js");

const mf = new Miniflare({
  modules: [
    { type: "ESModule", path: BUILD + "worker.js" },
    ...textModules.map((f) => ({ type: "Text", path: BUILD + f })),
  ],
  compatibilityDate: "2026-08-01",
  r2Buckets: { PUBLIC: "p", MAIN: "m" },
  bindings: { ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD, OWNER_EMAIL: OWNER },
  outboundService: () => Response.json({ keys: [jwk] }),
});

const base = (await mf.ready).toString().replace(/\/$/, "");
const MAIN = await mf.getR2Bucket("MAIN");
const PUBLIC = await mf.getR2Bucket("PUBLIC");

await MAIN.put("files/Raven/one.txt", "1", { httpMetadata: { contentType: "text/plain" } });
await MAIN.put("files/Raven/two.txt", "2", { httpMetadata: { contentType: "text/plain" } });
await PUBLIC.put("folders/Trip/a.txt", "a", { httpMetadata: { contentType: "text/plain" } });
await PUBLIC.put("folders/Trip/b.txt", "b", { httpMetadata: { contentType: "text/plain" } });

const browser = await chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});
let passed = 0;

const test = async (name, owner, fn) => {
  const ctx = await browser.newContext();
  if (owner) await ctx.addCookies([{ name: "CF_Authorization", value: ownerJwt, url: base }]);
  const pg = await ctx.newPage();
  pg.on("dialog", (d) => d.accept());
  try {
    await fn(pg);
    passed++;
    console.log("ok   " + name);
  } catch (e) {
    console.log("FAIL " + name + "\n     " + (e && e.message));
    await pg.screenshot({ path: "test-fail.png" });
    process.exitCode = 1;
  }
  await ctx.close();
};

await test("Main shows Upload and Delete, and no standing size note", true, async (pg) => {
  await pg.goto(base + "/main?p=Raven");
  assert.ok(await pg.isVisible("#up"));
  assert.ok(await pg.isVisible("#del"));
  assert.ok(!(await pg.isVisible("#note")));
  assert.ok(!(await pg.content()).includes("MiB"));
});

await test("Main: a file over the limit only shows a warning", true, async (pg) => {
  await pg.goto(base + "/main?p=Raven");
  const huge = join(mkdtempSync(join(tmpdir(), "gallery-")), "huge.mov");
  writeFileSync(huge, "");
  truncateSync(huge, 91 * 1024 * 1024);
  await pg.setInputFiles("#upin", huge);
  await pg.waitForSelector("#note:not([hidden])");
  assert.match(await pg.textContent("#note"), /huge\.mov is too big for the browser/);
  assert.equal(await MAIN.head("files/Raven/huge.MOV"), null);
});

await test("Main: Upload adds a file", true, async (pg) => {
  await pg.goto(base + "/main?p=Raven");
  await Promise.all([
    pg.waitForEvent("load"),
    pg.setInputFiles("#upin", { name: "three.txt", mimeType: "text/plain", buffer: Buffer.from("3") }),
  ]);
  assert.ok(await MAIN.head("files/Raven/three.txt"));
});

await test("Main: Delete picks files, then moves them to the trash", true, async (pg) => {
  await pg.goto(base + "/main?p=Raven");
  await pg.click("#del");
  await pg.click('.tile[data-n="00000"]');
  assert.equal(await pg.textContent("#del"), "Delete (1)");
  await Promise.all([pg.waitForEvent("load"), pg.click("#del")]);
  assert.equal(await MAIN.head("files/Raven/one.txt"), null);
  assert.ok((await MAIN.list({ prefix: "trash/" })).objects.some((o) => o.key.endsWith("/Raven/one.txt")));
});

let linkId;

await test("public link: visitors see Download only", false, async (pg) => {
  // the owner's Mac asks for the folder's link
  const r = await mf.dispatchFetch(base + "/main/api/link?action=folder&name=Trip", {
    method: "POST",
    headers: { "cf-access-jwt-assertion": ownerJwt, "x-gallery": "1" },
  });
  linkId = (await r.json()).id;

  await pg.goto(base + "/s/" + linkId);
  await pg.waitForTimeout(500);
  assert.ok(await pg.isVisible("#dl"));
  assert.ok(!(await pg.isVisible("#del")));
  assert.ok(!(await pg.isVisible("#up")));
});

await test("public link: the signed-in owner can delete an item", true, async (pg) => {
  await pg.goto(base + "/s/" + linkId);
  await pg.waitForSelector("#del:not([hidden])");
  await pg.click("#del");
  await pg.click('.tile[data-n="00000"]');
  await Promise.all([pg.waitForEvent("load"), pg.click("#del")]);
  assert.equal(await PUBLIC.head("folders/Trip/a.txt"), null);
  assert.ok(await PUBLIC.head("folders/Trip/b.txt"));
});

await test("upload page asks a visitor to sign in", false, async (pg) => {
  await pg.goto(base + "/");
  await pg.waitForSelector("#signin:not([hidden])");
  assert.ok(!(await pg.isVisible("#drop")));
});

await test("upload page is ready for the owner", true, async (pg) => {
  await pg.goto(base + "/");
  await pg.waitForTimeout(500);
  assert.ok(!(await pg.isVisible("#signin")));
  assert.ok(await pg.isVisible("#drop"));
});

console.log(`\n${passed} passed`);
await browser.close();
await mf.dispose();
