// UI-12 S1 regression: the offline Draftpad editor served at /main/editor/ (src/editorpwa.js).
// 1. the copies bundled in src/client/editorpwa/ are byte-identical to editor/dist/pwa/ (a stale copy shipped once)
// 2. owner-only: a visitor gets no editor
// 3. in Chromium, after one visit: a service worker controls the page, the network goes away, a reload still opens it,
//    and a typed note survives the reload (IndexedDB); a bare file:// open degrades without throwing
// Run: `npm run build:test && node test/editorpwa.test.mjs` (step 3 skips when no browser is installed)
import { Miniflare } from "miniflare";
import { chromium } from "playwright";
import { readdirSync, readFileSync } from "node:fs";
import { webcrypto as crypto } from "node:crypto";
import assert from "node:assert/strict";

const BUILD = new URL("../.test-build/", import.meta.url).pathname;
const DIST = new URL("../../editor/dist/pwa/", import.meta.url).pathname;
const COPY = new URL("../src/client/editorpwa/", import.meta.url).pathname;
for (const f of ["index.html", "sw.js", "manifest.webmanifest", "icon.svg"]) {
  assert.ok(readFileSync(DIST + f).equals(readFileSync(COPY + f)), `library/src/client/editorpwa/${f} differs from editor/dist/pwa/${f}: cd editor && npm run build, then copy dist/pwa/* over it`);
}
console.log("ok bundled copies match editor/dist/pwa");

const TEAM = "team.cloudflareaccess.com", AUD = "test-aud", OWNER = "owner@example.com";
const keys = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
const jwk = { ...(await crypto.subtle.exportKey("jwk", keys.publicKey)), kid: "k1", alg: "RS256" };
const b64 = (x) => Buffer.from(x).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const data = b64(JSON.stringify({ alg: "RS256", kid: "k1" })) + "." + b64(JSON.stringify({ aud: [AUD], iss: "https://" + TEAM, exp: now + 3600, email: OWNER }));
const ownerJwt = data + "." + b64(new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", keys.privateKey, new TextEncoder().encode(data))));
const textModules = readdirSync(BUILD).filter((f) => /\.(css|js|html|svg|webmanifest)$/.test(f) && f !== "worker.js");
const mf = new Miniflare({
  modules: [{ type: "ESModule", path: BUILD + "worker.js" }, ...textModules.map((f) => ({ type: "Text", path: BUILD + f }))],
  compatibilityDate: "2026-08-01",
  r2Buckets: { PUBLIC: "p", MAIN: "m", KEEP: "k" },
  bindings: { ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD, OWNER_EMAIL: OWNER },
  outboundService: () => Response.json({ keys: [jwk] }),
});
const base = (await mf.ready).toString().replace(/\/$/, "");
let failed = false;
try {
  const anon = await mf.dispatchFetch(base + "/main/editor/");
  assert.ok(!(await anon.text()).includes("recenseEditor"), "anonymous visitor got the editor");
  assert.notEqual(anon.status, 200);
  const own = await mf.dispatchFetch(base + "/main/editor/", { headers: { "cf-access-jwt-assertion": ownerJwt } });
  assert.equal(own.status, 200);
  assert.ok((await own.text()).includes("recenseEditor"));
  const sw = await mf.dispatchFetch(base + "/main/editor/sw.js", { headers: { "cf-access-jwt-assertion": ownerJwt } });
  assert.equal(sw.headers.get("service-worker-allowed"), "/main/editor/");
  console.log("ok owner-only (anonymous " + anon.status + ", owner 200)");

  let browser = null;
  try { browser = await chromium.launch(); } catch (e) { console.log("skip browser steps: " + String(e.message).split("\n")[0]); }
  if (browser) {
    const ctx = await browser.newContext({ serviceWorkers: "allow" });
    await ctx.addCookies([{ name: "CF_Authorization", value: ownerJwt, url: base }]);
    const page = await ctx.newPage();
    await page.goto(base + "/main/editor/");
    await page.waitForFunction(() => window.recenseEditor);
    await page.evaluate(() => navigator.serviceWorker.ready);
    await page.evaluate(() => navigator.serviceWorker.controller || new Promise((r) => navigator.serviceWorker.addEventListener("controllerchange", r)));
    console.log("ok service worker registered and controlling");
    await page.evaluate(() => window.recenseEditor.setText("offline hello"));
    await page.evaluate(() => window.webkit.messageHandlers.editor.postMessage("offline hello"));
    await page.waitForTimeout(300);
    await ctx.setOffline(true);
    await page.reload();
    await page.waitForFunction(() => window.recenseEditor, null, { timeout: 8000 });
    await page.waitForFunction(() => window.recenseEditor.getText() === "offline hello", null, { timeout: 8000 });
    console.log("ok offline reload opens and the note survives");
    const keyed = "typed offline " + Date.now();
    await page.evaluate((t) => window.recenseEditor.setText(t), keyed);
    await page.evaluate((t) => window.webkit.messageHandlers.editor.postMessage(t), keyed);
    await page.waitForTimeout(300);
    await page.reload();
    await page.waitForFunction((t) => window.recenseEditor && window.recenseEditor.getText() === t, keyed, { timeout: 8000 });
    console.log("ok second offline reload keeps the new note");
    const fpage = await (await browser.newContext()).newPage();
    const errs = [];
    fpage.on("pageerror", (e) => errs.push(String(e)));
    await fpage.goto("file://" + DIST + "index.html");
    await fpage.waitForFunction(() => window.recenseEditor, null, { timeout: 8000 });
    await fpage.waitForTimeout(500);
    assert.deepEqual(errs, [], "file:// open threw: " + errs.join(" | "));
    console.log("ok file:// open degrades without throwing");
    await browser.close();
  }
} catch (e) { failed = true; console.error(e); }
await mf.dispose();
process.exit(failed ? 1 : 0);
