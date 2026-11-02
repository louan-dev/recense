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

let cdp = null;
const test = async (name, fn) => {
  for (const m of MATRIX) {
    const full = name + " · " + m.label;
    if (only && !only.test(full)) continue;
    const ctx = await browser.newContext({ viewport: { width: m.w, height: m.h }, hasTouch: m.touch, isMobile: m.mobile, extraHTTPHeaders: { "cf-access-jwt-assertion": ownerJwt } });
    const pg = await ctx.newPage();
    cdp = m.touch ? await ctx.newCDPSession(pg) : null;
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
// a real drag (the browser's own pointer, so capture works): the mouse, or a finger through CDP.
// mid(at) runs before the last move is released, to look at what follows the finger.
const drag = async (pg, m, a, b, { steps = 8, mid, via } = {}) => {
  const line = (p, q) => Array.from({ length: steps }, (_, i) => ({ x: p.x + ((q.x - p.x) * (i + 1)) / steps, y: p.y + ((q.y - p.y) * (i + 1)) / steps }));
  const pts = [a, ...(via ? [...line(a, via), ...line(via, b)] : line(a, b))];
  if (m.touch) {
    await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [pts[0]] });
    for (const p of pts.slice(1)) await cdp.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [p] });
    if (mid) await mid();
    await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
  } else {
    await pg.mouse.move(pts[0].x, pts[0].y);
    await pg.mouse.down();
    for (const p of pts.slice(1)) await pg.mouse.move(p.x, p.y);
    if (mid) await mid();
    await pg.mouse.up();
  }
};
const tapAt = (pg, m, x, y) => (m.touch ? pg.touchscreen.tap(x, y) : pg.mouse.click(x, y));
const center = (pg, q) => pg.$eval(q, (e) => { const r = e.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height }; });
const settle = (pg) => pg.waitForTimeout(450);
// proof shots of each state on one device (gallery/test/.shots/viewer/)
const shot = (pg, m, name) => (m.label === "iPhone 12 Pro Max portrait touch" || m.label === "iPad Air 13in landscape pointer" ? pg.screenshot({ path: SHOTS + m.label.replace(/\W+/g, "_") + "-" + name + ".png" }) : null);
const vars = (pg) => pg.evaluate(() => { const s = getComputedStyle(document.getElementById("lb")); return { vs: parseFloat(s.getPropertyValue("--vs")), vr: parseFloat(s.getPropertyValue("--vr")), vc: parseFloat(s.getPropertyValue("--vc")), vy: parseFloat(s.getPropertyValue("--vy")), st: document.getElementById("lb").dataset.vstate }; });

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

// ---------- G3: the viewer shell ----------

await test("G3: B framed by default; tap A ⇄ B; drag up follows the finger to C; back to B; spring 320/32/1", async (pg, m) => {
  await pg.goto(base + "/main?p=Words");
  await pg.click('.tile[data-n="00000"]');
  await pg.waitForSelector("#lb:not([hidden])");
  await settle(pg);
  assert.deepEqual(await pg.evaluate(() => window.__galleryShell.spring), { k: 320, c: 32, m: 1 });
  let v = await vars(pg);
  assert.equal(v.st, "B");
  assert.ok(Math.abs(v.vs - 0.82) < 0.01 && Math.abs(v.vr - 24) < 0.5 && v.vc > 0.99, JSON.stringify(v));
  const scaleOf = () => pg.$eval("#stage > img", (e) => new DOMMatrix(getComputedStyle(e).transform).a);
  assert.ok(Math.abs((await scaleOf()) - 0.82) < 0.01, "the media is what scales");
  assert.equal(await pg.$eval("#lb .top", (e) => getComputedStyle(e).opacity), "1");
  await shot(pg, m, "B-framed");
  // A: a tap on the media; chrome fades and stops taking taps
  const c = await center(pg, "#stage > img");
  await tapAt(pg, m, c.x, c.y);
  await settle(pg);
  v = await vars(pg);
  assert.equal(v.st, "A");
  assert.ok(v.vs > 0.99 && v.vr < 0.5 && v.vc < 0.01, JSON.stringify(v));
  assert.equal(await pg.$eval("#lb .top", (e) => getComputedStyle(e).pointerEvents), "none");
  await shot(pg, m, "A-fullbleed");
  await tapAt(pg, m, c.x, c.y);
  await settle(pg);
  assert.equal((await vars(pg)).st, "B");
  // C: drag up; mid-drag the media is where the finger took it (1:1), then it docks with the sheet beneath
  let during = null;
  await drag(pg, m, { x: c.x, y: c.y + 60 }, { x: c.x, y: c.y - 100 }, { mid: async () => (during = await vars(pg)) });
  assert.ok(Math.abs(during.vy - -160) < 2, "follows the finger 1:1: " + during.vy);
  await pg.waitForFunction(() => document.body.classList.contains("comments-open"));
  await settle(pg);
  v = await vars(pg);
  assert.equal(v.st, "C");
  assert.ok(Math.abs(v.vy) < 1, "settled: " + v.vy);
  const dock = await pg.evaluate(() => {
    const r = document.querySelector(".stage-container").getBoundingClientRect();
    return { h: r.height / innerHeight, w: r.width / innerWidth, short: matchMedia("(max-height: 500px)").matches };
  });
  // a phone on its side keeps the media beside the sheet (gallery.css), everything else docks it to the top 38%
  if (dock.short) assert.ok(dock.w < 0.7, "beside the sheet: " + dock.w);
  else assert.ok(Math.abs(dock.h - 0.38) < 0.02, "docked to the top 38%: " + dock.h);
  assert.ok(await pg.isVisible("#thread"));
  await shot(pg, m, "C-docked");
  // B again: Hide Comments
  await pg.click('#thread button:has-text("Hide Comments")');
  await settle(pg);
  assert.equal((await vars(pg)).st, "B");
});

await test("G3: top bar is round back, two lines, •••; Go to File only on purpose; nothing downloads on open", async (pg, m) => {
  const downloads = [];
  pg.on("download", (d) => downloads.push(d.suggestedFilename()));
  await pg.goto(base + "/main?p=Words");
  await pg.click('.tile[data-n="00000"]');
  await pg.waitForSelector("#lb:not([hidden])");
  const t = await pg.evaluate(() => {
    const r = (q) => document.querySelector(q).getBoundingClientRect();
    const top = document.querySelector("#lb .top");
    const texts = [...top.querySelectorAll("button, a")].filter((b) => b.offsetParent).map((b) => (b.getAttribute("aria-label") || b.textContent).trim());
    return { back: getComputedStyle(document.querySelector(".vback")).borderRadius, backLeft: r(".vback").left, moreRight: innerWidth - r(".vmore").right, fold: r(".vfold"), t1: r("#t1"), folder: document.querySelector(".vfold").textContent, texts };
  });
  assert.equal(t.back, "50%");
  assert.ok(t.backLeft < 40 && t.moreRight < 40, "back left, ••• right");
  assert.ok(t.fold.bottom <= t.t1.top + 1, "two lines: the folder over the date");
  assert.equal(t.folder, "Words");
  assert.ok(!t.texts.some((x) => /^(Done|Gallery|‹ Gallery|< Gallery)$/.test(x)), "no second back or Done: " + t.texts);
  await pg.click(".vmore");
  assert.ok(await pg.isVisible('.vmenu button:has-text("Go to File")'));
  await pg.click(".vmore");
  assert.deepEqual(downloads, []);
});

await test("G3: one active item: stage, filmstrip and title never disagree; the active thumb is centred and larger", async (pg, m) => {
  await pg.goto(base + "/main?p=Tracks");
  await pg.click('.tile[data-n="00000"]');
  await pg.waitForSelector("#lb:not([hidden])");
  for (let i = 0; i < 6; i++) await next(pg, m);
  await settle(pg);
  const s = await pg.evaluate(() => {
    const ths = [...document.querySelectorAll("#strip .th")];
    const on = document.querySelector("#strip .th.on");
    const st = document.getElementById("strip").getBoundingClientRect();
    const r = on.getBoundingClientRect();
    return { idx: ths.indexOf(on), cur: window.__galleryViewerStats().cur, active: document.getElementById("lb").dataset.active, off: Math.abs(r.left + r.width / 2 - (st.left + st.width / 2)), w: r.width, scale: new DOMMatrix(getComputedStyle(on).transform).a, ons: ths.filter((t) => t.classList.contains("on")).length };
  });
  assert.equal(s.idx, 6);
  assert.equal(s.cur, 6);
  assert.equal(s.ons, 1);
  assert.equal(s.active, "Tracks/t06.wav");
  assert.ok(s.off <= s.w, "centred: " + s.off);
  assert.ok(s.scale > 1.1, "enlarged: " + s.scale);
  // a tap on a thumbnail moves the stage to it, and the strip with it
  await pg.click("#strip .th:nth-child(3)");
  await settle(pg);
  assert.equal(await pg.evaluate(() => window.__galleryViewerStats().cur), 2);
  assert.equal(await pg.evaluate(() => document.getElementById("lb").dataset.active), "Tracks/t02.wav");
});

await test("G3: the 2D scrubber: dx scrubs, up is fine, down coarse again; it keeps the pointer and never moves the sheet", async (pg, m) => {
  await pg.goto(base + "/main?p=Tracks");
  await pg.click('.tile[data-n="00000"]');
  await pg.waitForSelector("#lb:not([hidden])");
  await pg.waitForFunction(() => { const a = window.__galleryViewer.media(); return a && a.duration > 0; });
  if (await pg.evaluate(() => matchMedia("(max-height: 500px)").matches)) {
    assert.equal(await pg.$eval(".vscrub", (e) => getComputedStyle(e).display), "none", "short landscape: the home bar scrubs");
    return;
  }
  assert.equal(await pg.$eval(".vrail", (e) => getComputedStyle(e).touchAction), "none");
  const r = await pg.$eval(".vrail", (e) => { const b = e.getBoundingClientRect(); return { l: b.left, w: b.width, y: b.top + b.height / 2 }; });
  let mid = {};
  await drag(pg, m, { x: r.l + r.w * 0.1, y: r.y }, { x: r.l + r.w * 0.6, y: r.y }, {
    mid: async () => (mid = await pg.evaluate(() => ({ cap: document.querySelector(".vscrub.held") !== null, t: window.__galleryViewer.media().currentTime / window.__galleryViewer.media().duration }))),
  });
  assert.ok(mid.cap, "held while dragging");
  assert.ok(Math.abs(mid.t - 0.6) < 0.08, "coarse: the rail is the track: " + mid.t);
  // up past the step: fine (a tenth as fast), then far up and down: the sheet and the viewer stay as they were
  // straight up first (fine), then 40% of the rail to the right: a tenth of what coarse would move
  let fine = {};
  await drag(pg, m, { x: r.l + r.w * 0.5, y: r.y }, { x: r.l + r.w * 0.9, y: r.y - 60 }, {
    steps: 6,
    via: { x: r.l + r.w * 0.5, y: r.y - 60 },
    mid: async () => (fine = await pg.evaluate(() => ({ fine: !!document.querySelector(".vscrub.fine"), t: window.__galleryViewer.media().currentTime / window.__galleryViewer.media().duration }))),
  });
  assert.ok(fine.fine, "drag up: fine");
  assert.ok(fine.t > 0.5 && fine.t < 0.56, "fine moves a tenth as far: " + fine.t);
  await drag(pg, m, { x: r.l + r.w * 0.5, y: r.y }, { x: r.l + r.w * 0.5, y: r.y + 200 }, { steps: 6 });
  assert.equal(await pg.evaluate(() => document.body.classList.contains("comments-open")), false, "vertical drift never pulls the sheet");
  assert.ok(await pg.isVisible("#lb"), "nor closes the viewer");
});

await test("G3: the capsule: Share, Favorite, Info, Audio/EQ and Delete apart; only the three playback controls are glass", async (pg, m) => {
  await pg.goto(base + "/main?p=Tracks");
  await pg.click('.tile[data-n="00000"]');
  await pg.waitForSelector("#lb:not([hidden])");
  await settle(pg);
  await shot(pg, m, "B-audio-capsule");
  const c = await pg.evaluate(() => {
    const vis = (q) => [...document.querySelectorAll(q)].filter((e) => e.offsetParent && getComputedStyle(e).display !== "none");
    // glass = a backdrop blur on something you can see and press
    const glass = vis("#lb .bot *").filter((e) => getComputedStyle(e).backdropFilter !== "none" && getComputedStyle(e).opacity === "1" && e.getBoundingClientRect().width >= 40);
    return {
      acts: vis(".vcap .vic").map((e) => e.getAttribute("aria-label")),
      glass: glass.map((e) => e.getAttribute("aria-label")),
      blue: vis(".vcap .vic").every((e) => getComputedStyle(e).color === "rgb(10, 132, 255)"),
      delApart: !document.querySelector(".vdel").closest(".vpill"),
    };
  });
  assert.deepEqual(c.acts, ["Share", "Favorite", "Info and transcript", "Audio and EQ", "Delete"]);
  assert.deepEqual(c.glass, ["Back 10 seconds", "Play", "Forward 10 seconds"]);
  assert.ok(c.blue, "everything else is blue");
  assert.ok(c.delApart, "Delete stands apart");
  // Info opens the sheet (C), the same way as a swipe up
  await pg.click(".vinfo");
  await pg.waitForFunction(() => document.body.classList.contains("comments-open"));
  assert.equal(await pg.evaluate(() => document.getElementById("lb").dataset.vstate), "C");
});

console.log(`\n${passed} passed${failed ? ", " + failed + " failed" : ""}`);
await browser.close();
await mf.dispose();
