// Postbox: the owner's Claude sessions (any account, web/desktop/CLI) talk through /postbox (src/postbox.js).
// 1. unset secret: 404 · no token / wrong token: 401
// 2. POST and GET-send both store a message; the sender name comes from the token, never from the sender
// 3. GET ?since= returns only newer messages, plain text, with the cursor in a header
// 4. rules page is token-gated and 404s until stored; an empty post is refused
// Run: `npm run build:test && node test/postbox.test.mjs`
import { Miniflare } from "miniflare";
import { readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import assert from "node:assert/strict";

const BUILD = new URL("../.test-build/", import.meta.url).pathname;
const hash = (s) => createHash("sha256").update(s).digest("hex");
const TOKENS = JSON.stringify({ "web-a": hash("tok-web-a"), "cli-b": hash("tok-cli-b") });
const textModules = readdirSync(BUILD).filter((f) => /\.(css|js|html|svg|webmanifest)$/.test(f) && f !== "worker.js");
const make = (bindings) => new Miniflare({
  modules: [{ type: "ESModule", path: BUILD + "worker.js" }, ...textModules.map((f) => ({ type: "Text", path: BUILD + f }))],
  compatibilityDate: "2026-08-01",
  r2Buckets: { PUBLIC: "p", MAIN: "m", KEEP: "k" },
  bindings,
});

const off = make({});
const offBase = (await off.ready).toString().replace(/\/$/, "");
const mf = make({ POSTBOX_TOKENS: TOKENS });
const base = (await mf.ready).toString().replace(/\/$/, "");
const bearer = (t) => ({ authorization: "Bearer " + t });
try {
  assert.equal((await off.dispatchFetch(offBase + "/postbox")).status, 404);
  console.log("ok unset secret: 404");

  assert.equal((await mf.dispatchFetch(base + "/postbox")).status, 401);
  assert.equal((await mf.dispatchFetch(base + "/postbox", { headers: bearer("nope") })).status, 401);
  assert.equal((await mf.dispatchFetch(base + "/postbox?t=nope")).status, 401);
  // Regression guard: BUG-30 (a token in the URL reaches logs and history: refused even when right)
  assert.equal((await mf.dispatchFetch(base + "/postbox?t=tok-web-a")).status, 401);
  console.log("ok no token and wrong token: 401");

  const p1 = await mf.dispatchFetch(base + "/postbox", { method: "POST", headers: bearer("tok-web-a"), body: "hello from web\n— Agent: claude · Session: s1" });
  assert.equal(p1.status, 200);
  await new Promise((r) => setTimeout(r, 5));
  const p2 = await mf.dispatchFetch(base + "/postbox/send?text=" + encodeURIComponent("hello from cli (GET)"), { headers: bearer("tok-cli-b") });
  assert.equal(p2.status, 200);
  assert.equal((await mf.dispatchFetch(base + "/postbox/send?text=%20", { headers: bearer("tok-cli-b") })).status, 400);
  console.log("ok POST and GET-send both store; empty refused");

  const all = await mf.dispatchFetch(base + "/postbox", { headers: bearer("tok-cli-b") });
  const body = await all.text();
  assert.match(all.headers.get("content-type"), /^text\/plain/);
  assert.ok(body.includes("· web-a\nhello from web") && body.includes("· cli-b\nhello from cli (GET)"), body);
  assert.ok(body.indexOf("web-a") < body.indexOf("cli-b"), "oldest first");
  const first = body.match(/^#(\S+) /)[1];
  const since = await (await mf.dispatchFetch(base + "/postbox?since=" + first, { headers: bearer("tok-web-a") })).text();
  assert.ok(!since.includes("hello from web") && since.includes("hello from cli"), since);
  const last = all.headers.get("x-postbox-last");
  assert.equal(await (await mf.dispatchFetch(base + "/postbox?since=" + last, { headers: bearer("tok-web-a") })).text(), "(nothing new)\n");
  console.log("ok since= returns only newer; sender comes from the token");

  assert.equal((await mf.dispatchFetch(base + "/postbox/rules", { headers: bearer("tok-web-a") })).status, 404);
  assert.equal((await mf.dispatchFetch(base + "/postbox/rules")).status, 401);
  const m = await mf.getR2Bucket("MAIN");
  await m.put("postbox/rules.md", "RULES BODY");
  assert.equal(await (await mf.dispatchFetch(base + "/postbox/rules", { headers: bearer("tok-web-a") })).text(), "RULES BODY");
  console.log("ok rules page token-gated");
} catch (e) {
  console.error(e);
  process.exitCode = 1;
} finally {
  await off.dispose();
  await mf.dispose();
}
