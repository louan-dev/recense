// Skip Ad skips only ads (SPEC 37). Runs the bridge's content.js in headless Chromium on a page that mimics YouTube's
// player: one <video> inside .html5-video-player, the ad and then the video played in it in turn, "ad-showing" while
// an ad plays and "ad-created" left on for the whole video once the ad module has loaded (as youtube.com does, seen
// 2026-11-10), a gap with no source between them, and a Skip button that ignores a script's click (not isTrusted).
// The window's side is a stub: it records what the bridge reports (/pos) and hands it the Skip Ad command.
//   node strip/bridge/test/ads.test.mjs
// Playwright comes from library/ (npm install there); in a worktree, from the main checkout's library/.
import { readFileSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import { execSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "../../..");
const common = dirname(execSync("git rev-parse --path-format=absolute --git-common-dir", { cwd: here }).toString().trim());
const lib = [join(repo, "library"), join(common, "library")].find((d) => existsSync(join(d, "node_modules/playwright")));
if (!lib) { console.error("needs playwright: npm install in library/"); process.exit(2); }
const { chromium } = createRequire(join(lib, "package.json"))("playwright");
const content = readFileSync(join(here, "../content.js"), "utf8");

// The window, stubbed: /pos reports are kept, a queued command rides back on the next report or /wait.
const stub = `
  window.__pos = null; window.__queue = []; let seq = 0;
  window.__skip = () => window.__queue.push({ op: "skipAd", seq: ++seq });
  const take = () => { const c = window.__queue.splice(0); return c.length ? { cmds: c } : {}; };
  window.browser = { runtime: {
    sendMessage: async (msg) => {
      if (msg.cmd !== "app") return null;
      if (msg.path === "/pos") { window.__pos = msg.body; return take(); }
      if (msg.path === "/wait") { await new Promise((r) => setTimeout(r, 100)); return take(); }
      if (msg.path === "/media") return { state: "ok" };
      return {};
    },
    connect: () => ({ onMessage: { addListener() {} }, onDisconnect: { addListener() {} } }),
    onMessage: { addListener() {} },
  } };`;

// The player. wav(s): a silent clip s seconds long. play(): the ad (if any), a gap with no source, then the video;
// a mid-roll saves the video's time and puts it back when the ad ends, as YouTube does.
const page = `<!doctype html><title>fixture</title>
<div id="movie_player" class="html5-video-player playing-mode">
  <div class="html5-video-container"><video playsinline></video></div>
  <button class="ytp-skip-ad-button" style="display:none">Skip</button>
</div>
<script>
  function wav(s) {
    const rate = 8000, n = rate * s, b = new ArrayBuffer(44 + n * 2), d = new DataView(b);
    const str = (o, t) => [...t].forEach((c, i) => d.setUint8(o + i, c.charCodeAt(0)));
    str(0, "RIFF"); d.setUint32(4, 36 + n * 2, true); str(8, "WAVE"); str(12, "fmt "); d.setUint32(16, 16, true);
    d.setUint16(20, 1, true); d.setUint16(22, 1, true); d.setUint32(24, rate, true); d.setUint32(28, rate * 2, true);
    d.setUint16(32, 2, true); d.setUint16(34, 16, true); str(36, "data"); d.setUint32(40, n * 2, true);
    return URL.createObjectURL(new Blob([b], { type: "audio/wav" }));
  }
  const AD = wav(4), MAIN = wav(40);
  const p = document.getElementById("movie_player"), v = p.querySelector("video"), btn = p.querySelector("button");
  btn.addEventListener("click", (e) => { if (e.isTrusted) endAd(); });   // a script's click does nothing
  let resumeAt = 0, inAd = false;
  window.gapMs = 300;
  function load(src, t) { v.src = src; v.addEventListener("loadedmetadata", () => { v.currentTime = t; v.play(); }, { once: true }); }
  window.startAd = () => {
    if (inAd) return;
    resumeAt = v.src === MAIN ? v.currentTime : 0;
    inAd = true; p.classList.add("ad-created", "ad-showing", "ad-interrupting"); btn.style.display = "";
    load(AD, 0);
  };
  function endAd() {
    if (!inAd) return;
    v.removeAttribute("src"); v.load();   // the gap between the ad and the video: no source, duration NaN
    setTimeout(() => {
      inAd = false; p.classList.remove("ad-showing", "ad-interrupting"); btn.style.display = "none";
      load(MAIN, resumeAt);
    }, window.gapMs);
  }
  v.addEventListener("ended", () => { if (inAd) endAd(); else window.mainEnded = true; });
  window.MAIN = MAIN; window.AD = AD;
  window.state = () => ({ src: v.src === MAIN ? "main" : v.src === AD ? "ad" : "none", t: v.currentTime, ended: v.ended,
    muted: v.muted, rate: v.playbackRate, paused: v.paused, mainEnded: !!window.mainEnded, ad: window.__pos && window.__pos.ad });
</script>`;

const browser = await chromium.launch({ args: ["--autoplay-policy=no-user-gesture-required"] });
let failed = 0;
async function test(name, fn) {
  const ctx = await browser.newContext();
  const pg = await ctx.newPage();
  await pg.route("https://www.youtube.test/**", (r) => r.fulfill({ contentType: "text/html", body: page }));
  await pg.addInitScript(stub);
  await pg.addInitScript(content);
  await pg.goto("https://www.youtube.test/watch?v=fixture");
  const st = () => pg.evaluate(() => window.state());
  const until = async (what, ok, ms = 8000) => {
    const end = Date.now() + ms;
    for (;;) { const s = await st(); if (ok(s)) return s; if (Date.now() > end) throw new Error(`timed out: ${what} (${JSON.stringify(s)})`); await pg.waitForTimeout(50); }
  };
  try { await fn(pg, st, until); console.log("ok  ", name); }
  catch (e) { failed++; console.log("FAIL", name, "-", e.message); }
  await ctx.close();
}
const near = (a, b, tol) => Math.abs(a - b) <= tol;
function expect(c, msg, s) { if (!c) throw new Error(`${msg} (${JSON.stringify(s)})`); }

await test("pre-roll: Skip Ad ends the ad, the video then plays from 0:00", async (pg, st, until) => {
  await pg.evaluate(() => window.startAd());
  await until("the ad is reported as one", (s) => s.src === "ad" && !s.paused && s.ad === true);
  await pg.evaluate(() => window.__skip());
  const s = await until("the video plays after the ad", (s) => s.src === "main" && !s.paused && s.t > 0.3, 4000);
  expect(s.t < 2, "the video starts at 0:00", s);
  await pg.waitForTimeout(400);
  const s2 = await st();
  expect(s2.ad === false && !s2.ended && !s2.mainEnded && !s2.muted && s2.rate === 1, "the video plays on, heard, at speed 1, not as an ad", s2);
});

await test("after an ad: the video is not reported as one, and Skip Ad leaves it where it was", async (pg, st, until) => {
  await pg.evaluate(() => window.startAd());
  await until("the ad plays to its end, then the video", (s) => s.src === "main" && s.t > 1, 10000);
  await pg.waitForTimeout(400);
  const s = await st();
  expect(s.ad === false, "the video (its player still carries ad-created) is reported as the video, not an ad", s);
  await pg.evaluate(() => window.__skip());
  await pg.waitForTimeout(800);
  const s2 = await st();
  expect(s2.src === "main" && !s2.ended && !s2.mainEnded && near(s2.t, s.t + 1.2, 1), "Skip Ad with no ad playing moves nothing", s2);
});

await test("mid-roll: Skip Ad ends the ad, the video resumes where it was", async (pg, st, until) => {
  await pg.evaluate(() => { const v = document.querySelector("video"); v.src = window.MAIN; v.addEventListener("loadedmetadata", () => { v.currentTime = 12; v.play(); }, { once: true }); });
  await until("the video plays at 0:12", (s) => s.src === "main" && s.t > 12.3);
  await pg.evaluate(() => window.startAd());
  await until("the mid-roll is reported as an ad", (s) => s.src === "ad" && !s.paused && s.ad === true);
  await pg.evaluate(() => window.__skip());
  const s = await until("the video comes back", (s) => s.src === "main" && !s.paused, 4000);
  await pg.waitForTimeout(400);
  const s2 = await st();
  expect(near(s.t, 12.4, 1) && !s2.ended && !s2.mainEnded && !s2.muted && s2.rate === 1 && s2.ad === false, "resumed at 0:12, heard, at speed 1", { s, s2 });
});

await test("between the ad and the video (no source yet): Skip Ad leaves the video heard, at speed 1", async (pg, st, until) => {
  await pg.evaluate(() => { window.gapMs = 1500; window.startAd(); });
  await until("the ad plays", (s) => s.src === "ad" && !s.paused && s.ad === true);
  await until("the gap after it", (s) => s.src === "none", 8000);
  // The command is applied at once, during the gap (the stub hands it over on the next report).
  await pg.evaluate(() => window.__skip());
  await pg.waitForTimeout(300);
  const s = await until("the video plays after the gap", (s) => s.src === "main" && !s.paused && s.t > 0.3, 4000);
  await pg.waitForTimeout(300);
  const s2 = await st();
  expect(s.t < 2 && !s2.muted && s2.rate === 1 && !s2.mainEnded && s2.ad === false, "the video starts at 0:00, heard, at speed 1", s2);
});

await browser.close();
console.log(failed ? `${failed} failed` : "all passed");
process.exit(failed ? 1 : 0);
