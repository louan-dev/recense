// Viewer regressions (P0, then G3/G5): the built Worker in Miniflare, the owner's Main in Chromium, on the
// owner's three devices (iPad Air 13", MacBook Pro 13", iPhone 12 Pro Max), portrait and landscape, touch and pointer.
// Run with `npm test` (it builds first), or alone: `npm run build:test && node test/viewer.test.mjs`.

import { Miniflare } from "miniflare";
import { chromium } from "playwright";
import { readdirSync, mkdirSync } from "node:fs";
import { webcrypto as crypto } from "node:crypto";
import assert from "node:assert/strict";

const BUILD = new URL("../.test-build/", import.meta.url).pathname;
const SHOTS = new URL("./.shots/viewer/", import.meta.url).pathname;
mkdirSync(SHOTS, { recursive: true });
const TEAM = "team.cloudflareaccess.com";
const AUD = "test-aud";
const OWNER = "owner@example.com";

const keys = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
const jwk = { ...(await crypto.subtle.exportKey("jwk", keys.publicKey)), kid: "k1", alg: "RS256" };
const b64 = (x) => Buffer.from(x).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const data = b64(JSON.stringify({ alg: "RS256", kid: "k1" })) + "." + b64(JSON.stringify({ aud: [AUD], iss: "https://" + TEAM, exp: now + 3600, email: OWNER }));
const ownerJwt = data + "." + b64(new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", keys.privateKey, new TextEncoder().encode(data))));

const textModules = readdirSync(BUILD).filter((f) => /\.(css|js)$/.test(f) && f !== "worker.js");
const mf = new Miniflare({
  modules: [{ type: "ESModule", path: BUILD + "worker.js" }, ...textModules.map((f) => ({ type: "Text", path: BUILD + f }))],
  compatibilityDate: "2026-08-01",
  r2Buckets: { PUBLIC: "p", MAIN: "m", KEEP: "k" },
  bindings: { ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD, OWNER_EMAIL: OWNER },
  outboundService: () => Response.json({ keys: [jwk] }),
});
const base = (await mf.ready).toString().replace(/\/$/, "");
const MAIN = await mf.getR2Bucket("MAIN");

// a second of quiet 8 kHz mono WAV: every browser decodes it
const wav = (() => {
  const n = 8000;
  const b = Buffer.alloc(44 + n * 2);
  b.write("RIFF", 0);
  b.writeUInt32LE(36 + n * 2, 4);
  b.write("WAVEfmt ", 8);
  b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20);
  b.writeUInt16LE(1, 22);
  b.writeUInt32LE(8000, 24);
  b.writeUInt32LE(16000, 28);
  b.writeUInt16LE(2, 32);
  b.writeUInt16LE(16, 34);
  b.write("data", 36);
  b.writeUInt32LE(n * 2, 40);
  return b;
})();
const TRACKS = 30;
for (let i = 0; i < TRACKS; i++) await MAIN.put(`files/Tracks/t${String(i).padStart(2, "0")}.wav`, wav, { httpMetadata: { contentType: "audio/wav" } });
await MAIN.put("files/Words/p.jpg", "x", { httpMetadata: { contentType: "image/jpeg" } });
const TEXT = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda";
await mf.dispatchFetch(base + "/main/api/caption", {
  method: "PUT",
  headers: { "cf-access-jwt-assertion": ownerJwt, origin: base, "content-type": "application/json" },
  body: JSON.stringify({ kind: "main", path: "Words/p.jpg", op: "add", text: TEXT }),
});

// the owner's devices, each held both ways, each with a finger and with a pointer
export const DEVICES = [
  { name: "iPad Air 13in", w: 1032, h: 1376, mobile: false },
  { name: "MacBook Pro 13in", w: 1440, h: 900, mobile: false },
  { name: "iPhone 12 Pro Max", w: 428, h: 926, mobile: true },
];
const MATRIX = [];
for (const d of DEVICES)
  for (const turn of ["portrait", "landscape"])
    for (const input of ["touch", "pointer"]) {
      const [w, h] = (turn === "portrait") === d.w < d.h ? [d.w, d.h] : [d.h, d.w];
      MATRIX.push({ label: `${d.name} ${turn} ${input}`, w, h, touch: input === "touch", mobile: d.mobile && input === "touch" });
    }

const browser = await chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});
let passed = 0;
let failed = 0;
const only = process.env.ONLY ? new RegExp(process.env.ONLY) : null;

const test = async (name, fn) => {
  for (const m of MATRIX) {
    const full = name + " · " + m.label;
    if (only && !only.test(full)) continue;
    const ctx = await browser.newContext({ viewport: { width: m.w, height: m.h }, hasTouch: m.touch, isMobile: m.mobile, extraHTTPHeaders: { "cf-access-jwt-assertion": ownerJwt } });
    const pg = await ctx.newPage();
    const errors = [];
    pg.on("pageerror", (e) => errors.push(e.message));
    try {
      await fn(pg, m);
      assert.deepEqual(errors, [], "no page errors");
      passed++;
      console.log("ok   " + full);
    } catch (e) {
      failed++;
      console.log("FAIL " + full + "\n     " + (e && e.message));
      await pg.screenshot({ path: SHOTS + full.replace(/[^\w]+/g, "_") + ".png" }).catch(() => {});
      process.exitCode = 1;
    }
    await ctx.close();
  }
};

// a horizontal finger swipe over the stage (touchstart → touchend, as a phone sends it)
const swipe = (pg, dx) =>
  pg.evaluate((dx) => {
    const st = document.getElementById("stage");
    const r = st.getBoundingClientRect();
    const x = r.left + r.width / 2;
    const y = r.top + r.height / 2;
    const t = (cx) => new Touch({ identifier: 1, target: st, clientX: cx, clientY: y });
    st.dispatchEvent(new TouchEvent("touchstart", { bubbles: true, touches: [t(x)], changedTouches: [t(x)] }));
    st.dispatchEvent(new TouchEvent("touchend", { bubbles: true, touches: [], changedTouches: [t(x + dx)] }));
  }, dx);
const next = (pg, m) => (m.touch ? swipe(pg, -120) : pg.keyboard.press("ArrowRight"));
const stats = (pg) => pg.evaluate(() => window.__galleryViewerStats());

await test("P0 bug 1: a long swipe across tracks never freezes; Back draws the folder at once", async (pg, m) => {
  const keyFetches = [];
  pg.on("request", (r) => /\/main\/f\/Tracks\//.test(r.url()) && !r.headers().range && keyFetches.push(r.url()));
  await pg.goto(base + "/main?p=Tracks");
  await pg.click('.tile[data-n="00000"]');
  await pg.waitForSelector("#lb:not([hidden])");
  keyFetches.length = 0;
  const STEPS = 25;
  for (let i = 0; i < STEPS; i++) await next(pg, m);
  let s = await stats(pg);
  assert.equal(s.cur, STEPS % TRACKS, "every swipe moved one item");
  assert.ok(s.live <= 1, "at most the item on stage holds a source, saw " + s.live);
  assert.ok(s.near <= 2);
  assert.equal(keyFetches.length, 0, "no key detection started while swiping: " + keyFetches.length);
  // still answers: one more step lands within a frame or two, and the player mounts once the swiping stops
  const t0 = Date.now();
  await next(pg, m);
  await pg.waitForFunction((c) => window.__galleryViewerStats().cur === c, (STEPS + 1) % TRACKS, { timeout: 1000 });
  assert.ok(Date.now() - t0 < 1000);
  await pg.waitForSelector("#stage .mbox", { state: "attached", timeout: 2000 });
  s = await stats(pg);
  assert.ok(s.live <= 1);
  // Back: the folder, drawn, on the first try
  if (m.touch) await pg.evaluate(() => history.back());
  else await pg.keyboard.press("Escape");
  await pg.waitForSelector("#lb", { state: "hidden" });
  await pg.waitForTimeout(80);
  const ok = await pg.evaluate(() => {
    const t = document.querySelector(".tile");
    if (!t) return "no tiles";
    const r = t.getBoundingClientRect();
    if (!r.width || !r.height) return "tile has no size";
    const hit = document.elementFromPoint(Math.min(r.left + r.width / 2, innerWidth - 1), Math.min(r.top + r.height / 2, innerHeight - 1));
    if (!hit || !hit.closest(".tile, #grid, main, body")) return "covered";
    if (document.body.classList.contains("lbopen") || document.body.style.overflow === "hidden") return "viewer state left over";
    return true;
  });
  assert.equal(ok, true);
  s = await stats(pg);
  assert.equal(s.live, 0, "nothing holds a source once the viewer closed");
  assert.equal(s.keyJob, false);
});

await test("P0 bug 2: tapping a word of your comment puts the caret on that word, though the layout moves", async (pg, m) => {
  await pg.goto(base + "/main?p=Words");
  await pg.click('.tile[data-n="00000"]');
  await pg.click(".cmlabel");
  await pg.waitForSelector("#thread .ctext.cmine");
  await pg.waitForTimeout(700); // the thread has finished opening (its scroll would cancel the tap)
  const word = "delta";
  const at = TEXT.indexOf(word);
  const pt = await pg.evaluate(
    ({ at, len }) => {
      const p = document.querySelector("#thread .ctext.cmine");
      const r = document.createRange();
      r.setStart(p.firstChild, at + 1);
      r.setEnd(p.firstChild, at + len - 1);
      const b = r.getBoundingClientRect();
      // the keyboard: as soon as the field appears, the page under it moves down
      const th = document.getElementById("thread");
      th.style.overflowAnchor = "none";
      new MutationObserver((_, o) => {
        if (!th.querySelector("textarea.cedit")) return;
        o.disconnect();
        const pad = document.createElement("div");
        pad.style.height = "180px";
        th.prepend(pad);
      }).observe(th, { childList: true, subtree: true });
      return { x: b.left + b.width / 2, y: b.top + b.height / 2 };
    },
    { at, len: word.length }
  );
  if (m.touch) await pg.touchscreen.tap(pt.x, pt.y);
  else await pg.mouse.click(pt.x, pt.y, { delay: 40 });
  await pg.waitForSelector("#thread textarea.cedit");
  await pg.waitForTimeout(1000); // past the settle
  const r = await pg.evaluate(() => {
    const box = document.querySelector("#thread textarea.cedit");
    return { focused: document.activeElement === box, a: box.selectionStart, b: box.selectionEnd, fs: getComputedStyle(box).fontSize, lh: getComputedStyle(box).lineHeight };
  });
  assert.ok(r.focused, "the field has focus");
  assert.equal(r.a, r.b);
  assert.ok(r.a >= at && r.a <= at + word.length, `caret ${r.a} not within "${word}" (${at}–${at + word.length})`);
  assert.equal(r.fs, "17px", "same type as the comment");
  await pg.keyboard.press("Escape");
});

console.log(`\n${passed} passed${failed ? ", " + failed + " failed" : ""}`);
await browser.close();
await mf.dispose();
