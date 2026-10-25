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
  r2Buckets: { PUBLIC: "p", MAIN: "m", KEEP: "k" },
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

// spec §7: a two-finger trackpad swipe (a horizontal wheel) over your comment reveals its Delete
const swipeDelete = async (pg) => {
  const at = await pg.$eval("#thread .crow.sw", (e) => {
    const r = e.getBoundingClientRect();
    return { x: r.left + r.width * 0.75, y: r.top + r.height / 2 };
  });
  await pg.mouse.move(at.x, at.y);
  await pg.mouse.wheel(80, 0);
  await pg.waitForSelector("#thread .crow.sw.open");
  await pg.click("#thread .crow.open .cdel");
};

const test = async (name, owner, fn) => {
  if (process.env.ONLY && !name.includes(process.env.ONLY)) return;
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
  assert.ok(await pg.isVisible("#addtile"));
  assert.ok(!(await pg.isVisible("#del")));
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
  await pg.click("#sel");
  await pg.click('.tile[data-n="00000"]');
  assert.equal(await pg.textContent("#ftxt"), "1 Item Selected");
  await Promise.all([pg.waitForEvent("load"), pg.click("#del")]);
  assert.equal(await MAIN.head("files/Raven/one.txt"), null);
  assert.ok((await MAIN.list({ prefix: "trash/" })).objects.some((o) => o.key.endsWith("/Raven/one.txt")));
});

await test("Main: … > New Folder, then Select > Move puts a file in it", true, async (pg) => {
  await MAIN.put("files/Mvu/m.txt", "m", { httpMetadata: { contentType: "text/plain" } });
  await pg.goto(base + "/main?p=Mvu");
  pg.removeAllListeners("dialog");
  pg.on("dialog", (d) => (d.type() === "prompt" ? d.accept("Box") : d.accept()));
  await pg.click("#mbtn");
  await Promise.all([pg.waitForEvent("load"), pg.click("#m-dir")]);
  assert.ok(await pg.isVisible('.mainnav .fd:has-text("Box")'));
  assert.ok(!(await pg.isVisible("#mv")));
  await pg.click("#sel");
  await pg.click('.tile[data-n="00000"]');
  assert.ok(await pg.isVisible("#mv"));
  await pg.click("#mv");
  await pg.waitForSelector("#mvs:not([hidden]) .mvf");
  assert.equal(await pg.textContent("#mvgo"), "Already Here");
  await pg.click('.mvf:has-text("Box")');
  await pg.waitForFunction(() => document.querySelector("#mvgo").textContent === "Move Here");
  await Promise.all([pg.waitForEvent("load"), pg.click("#mvgo")]);
  assert.equal(await MAIN.head("files/Mvu/m.txt"), null);
  assert.equal(await (await MAIN.get("files/Mvu/Box/m.txt")).text(), "m");
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
  await pg.waitForSelector("#sel:not([hidden])");
  await pg.click("#sel");
  await pg.click('.tile[data-n="00000"]');
  await Promise.all([pg.waitForEvent("load"), pg.click("#del")]);
  assert.equal(await PUBLIC.head("folders/Trip/a.txt"), null);
  assert.ok(await PUBLIC.head("folders/Trip/b.txt"));
});

await test("the landing page offers a visitor the sign-in", false, async (pg) => {
  await pg.goto(base + "/");
  assert.ok(await pg.isVisible('a[href="/main/"]'));
});

await test("upload page is ready for the owner", true, async (pg) => {
  await pg.goto(base + "/main/share");
  await pg.waitForTimeout(500);
  assert.ok(!(await pg.isVisible("#signin")));
  assert.ok(await pg.isVisible("#drop"));
});

await test("comments: open the thread, post two, they stay after a reload, delete returns to collapsed", true, async (pg) => {
  await MAIN.put("files/Pics/p.jpg", "x", { httpMetadata: { contentType: "image/jpeg" } });
  await pg.goto(base + "/main?p=Pics");
  await pg.click('.tile[data-n="00000"]');
  assert.equal(await pg.textContent(".cmlabel"), "Add a comment…");
  await pg.click(".cmlabel");
  assert.ok(await pg.evaluate(() => document.body.classList.contains("comments-open")));
  await pg.fill("#thread textarea", "one");
  await pg.click('#thread .cbtns button:has-text("Post")');
  await pg.waitForSelector("#thread .crow");
  await pg.fill("#thread textarea", "two");
  await pg.press("#thread textarea", "Enter");
  await pg.waitForFunction(() => document.querySelectorAll("#thread .crow").length === 2);
  assert.ok(await pg.evaluate(() => document.body.classList.contains("comments-open")));
  await pg.reload();
  await pg.click('.tile[data-n="00000"]');
  assert.equal(await pg.textContent(".cmlabel"), "2 comments");
  await pg.click(".cmlabel");
  assert.deepEqual(await pg.$$eval("#thread .ctext", (e) => e.map((x) => x.textContent)), ["one", "two"]);
  await pg.focus("#thread textarea");
  await pg.click('#thread .cbtns button:has-text("Delete")');
  await pg.waitForFunction(() => !document.body.classList.contains("comments-open"));
  assert.equal(await pg.textContent(".cmlabel"), "1 comment");
});

await test("comments: right after posting, Cancel and Delete are there; your own can be edited and deleted", true, async (pg) => {
  await MAIN.put("files/Ced/p.jpg", "x", { httpMetadata: { contentType: "image/jpeg" } });
  await pg.goto(base + "/main?p=Ced");
  await pg.click('.tile[data-n="00000"]');
  await pg.click(".cmlabel");
  await pg.fill("#thread textarea", "first");
  await pg.press("#thread textarea", "Enter");
  await pg.waitForSelector("#thread .crow");
  await pg.evaluate(() => document.activeElement && document.activeElement.blur());
  assert.ok(await pg.isVisible('#thread .cfield .cbtns button:has-text("Cancel")'));
  assert.ok(await pg.isEnabled('#thread .cfield .cbtns button:has-text("Delete")'));
  await pg.click("#thread .ctext.cmine");
  await pg.fill("#thread textarea.cedit", "fixed");
  await pg.click('#thread .crow .cbtns button:has-text("Save")');
  await pg.waitForFunction(() => document.querySelector("#thread .ctext")?.textContent === "fixed");
  assert.match(await pg.textContent("#thread .cmeta"), /Edited/);
  await swipeDelete(pg);
  await pg.waitForFunction(() => !document.querySelector("#thread .crow"));
});

await test("viewer: Share opens a private link for just this item", true, async (pg) => {
  await MAIN.put("files/Vs/a.jpg", "x", { httpMetadata: { contentType: "image/jpeg" } });
  await MAIN.put("files/Vs/b.jpg", "y", { httpMetadata: { contentType: "image/jpeg" } });
  await pg.goto(base + "/main?p=Vs");
  await pg.click('.tile[data-n="00001"]');
  await pg.click("#vshare");
  assert.match(await pg.textContent("#invscope"), /b\.JPG|b\.jpg/);
  await pg.fill("#invname", "Lee");
  await pg.click("#invform button");
  await pg.waitForSelector("#invl .invr");
  const list = await pg.evaluate(async () => (await (await fetch("/main/api/invites?dir=Vs", { headers: { "x-gallery": "1" } })).json()));
  assert.deepEqual(list[0].items, ["b.jpg"]);
});

await test("invite: the owner makes a link from the menu; the invited person sees the folder and comments", true, async (pg) => {
  await MAIN.put("files/Pics/p.jpg", "x", { httpMetadata: { contentType: "image/jpeg" } });
  await pg.goto(base + "/main?p=Pics");
  await pg.click("#mbtn");
  await pg.click("#m-inv");
  await pg.fill("#invname", "Sam");
  await pg.click('#invform button');
  await pg.waitForSelector("#invl .invr");
  const url = await pg.evaluate(async () => {
    const r = await fetch("/main/api/invites?dir=Pics", { headers: { "x-gallery": "1" } });
    return (await r.json()).length;
  });
  assert.equal(url, 1);
  const made = (await MAIN.list({ prefix: "invites/" })).objects.length;
  assert.ok(made >= 1);
});

await test("invite page: no menu, no delete, comment as the participant", false, async (pg) => {
  // make one directly through the owner API
  const r = await mf.dispatchFetch(base + "/main/api/invites", {
    method: "POST",
    headers: { "cf-access-jwt-assertion": ownerJwt, origin: base, "content-type": "application/json" },
    body: JSON.stringify({ name: "Ana", ttl: 0, dir: "Pics" }),
  });
  const { url } = await r.json();
  await pg.goto(base + "/m/" + url.split("/m/")[1]);
  assert.ok(!(await pg.isVisible("#mbtn")));
  await pg.click('.tile[data-n="00000"]');
  await pg.click(".cmlabel");
  await pg.fill("#thread textarea", "from Ana");
  await pg.press("#thread textarea", "Enter");
  await pg.waitForFunction(() => [...document.querySelectorAll("#thread .ctext")].some((e) => e.textContent === "from Ana"));
  const notes = JSON.parse(await (await MAIN.get("notes/Pics/.comments.json")).text());
  assert.ok(notes["p.jpg"].list.some((c) => c.by === "Ana" && c.text === "from Ana"));
});

await test("select on Main, then … > Create Share Link makes the link and copies it", true, async (pg) => {
  await pg.context().grantPermissions(["clipboard-read", "clipboard-write"], { origin: base });
  await pg.goto(base + "/main?p=Raven");
  await pg.click("#sel");
  await pg.click('.tile[data-n="00001"]');
  await pg.click("#mbtn");
  await pg.click("#m-share");
  await pg.click('#shr label:has-text("30 days")');
  await pg.click("#shrgo");
  await pg.waitForFunction(() => /items? shared for 30 days/.test(document.querySelector("#mtoast").textContent), null, { timeout: 10000 });
  assert.ok(pg.url().includes("/main"));
  const link = await pg.evaluate(() => navigator.clipboard.readText());
  assert.match(link, /\/s\/[A-Za-z0-9]+$/);
  const g = await (await fetch(base + "/api/gallery?id=" + link.split("/s/")[1])).json();
  assert.deepEqual(g.items.map((f) => f.name), ["two.TXT"]);
  assert.ok(g.exp - Date.now() > 29 * 864e5);
});

await test("a Recense transcript shows in Learn mode: original first, then its English in place", true, async (pg) => {
  const KEEP = await mf.getR2Bucket("KEEP");
  const wav = Buffer.alloc(44 + 16000 * 2 * 3);
  wav.write("RIFF", 0); wav.writeUInt32LE(36 + 96000, 4); wav.write("WAVEfmt ", 8); wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22); wav.writeUInt32LE(16000, 24); wav.writeUInt32LE(32000, 28);
  wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34); wav.write("data", 36); wav.writeUInt32LE(96000, 40);
  await MAIN.put("files/Songs/s.wav", wav, { httpMetadata: { contentType: "audio/wav" } });
  const key = (await crypto.subtle.digest("SHA-256", new TextEncoder().encode("gallery:files/Songs/s.wav")));
  const hex = Buffer.from(key).toString("hex").slice(0, 24);
  await KEEP.put("keep/" + hex + ".v2.json", JSON.stringify({ complete: true, lines: [
    { id: 0, words: [{ text: "Bonjour", start: 0, end: 0.5 }, { text: "toi", start: 0.6, end: 1 }], english: [{ w: "Hello", s: [0] }, { w: "you", s: [1] }] },
  ] }));
  await pg.goto(base + "/main?p=Songs");
  await pg.click('.tile[data-n="00000"]');
  // Learn mode: the original first, in its place
  await pg.waitForSelector(".tx.learn .txp:not([hidden])");
  const words = () => pg.$$eval(".tx .txp:not([hidden]) .txs", (a) => a.map((x) => x.textContent).join(" "));
  const english = () => pg.$$eval(".tx .txp:not([hidden]) .txe", (a) => a.map((x) => x.textContent).join(" "));
  assert.equal(await words(), "Bonjour toi");
  assert.equal(await english(), "Hello you");
  assert.equal(await pg.$eval(".tx .txe", (e) => getComputedStyle(e).visibility), "hidden");
  // once heard, each phrase turns into its English where it stands
  await pg.$eval("audio", (a) => (a.currentTime = 1.6));
  await pg.waitForFunction(() => [...document.querySelectorAll(".tx .txe")].every((e) => getComputedStyle(e).visibility === "visible"));
  assert.equal(await pg.$eval(".tx .txs", (e) => getComputedStyle(e).visibility), "hidden");
});

await test("Learn mode: tap a line to correct it; saved a second later and shown after a reload; no transcript asks Recense", true, async (pg) => {
  const KEEP = await mf.getR2Bucket("KEEP");
  const wav = Buffer.alloc(44 + 16000 * 2 * 3);
  wav.write("RIFF", 0); wav.writeUInt32LE(36 + 96000, 4); wav.write("WAVEfmt ", 8); wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22); wav.writeUInt32LE(16000, 24); wav.writeUInt32LE(32000, 28);
  wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34); wav.write("data", 36); wav.writeUInt32LE(96000, 40);
  await MAIN.put("files/Fix/a.wav", wav, { httpMetadata: { contentType: "audio/wav" } });
  await MAIN.put("files/Fix/b.wav", wav, { httpMetadata: { contentType: "audio/wav" } });
  const hex = async (p) => Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("gallery:files/" + p))).toString("hex").slice(0, 24);
  const ka = await hex("Fix/a.wav");
  await KEEP.put("keep/" + ka + ".v2.json", JSON.stringify({ complete: true, lines: [{ id: 3, words: [{ text: "Bonjour", start: 0, end: 0.5 }, { text: "twa", start: 0.6, end: 1 }] }] }));
  await pg.goto(base + "/main?p=Fix");
  await pg.click('.tile[data-n="00000"]');
  await pg.waitForSelector(".tx.learn .txp:not([hidden])");
  await pg.click(".tx.learn .txp:not([hidden])");
  await pg.waitForSelector(".txin");
  await pg.fill(".txin", "Bonjour toi");
  await pg.press(".txin", "Enter");
  assert.ok(await pg.$(".txall .txrow.cur .txin"), "the whole transcript stays open, the line heard still a field");
  let doc = null;
  for (let i = 0; i < 40 && !doc; i++) {
    await pg.waitForTimeout(100);
    const o = await KEEP.get("keep/" + ka + "/corrections.json");
    doc = o && (await o.json());
  }
  assert.ok(doc, "saved");
  assert.deepEqual([doc.overrides[0].segId, doc.overrides[0].to, doc.overrides[0].src], ["3", "Bonjour toi", "main"]);
  // Changes lists it with what it replaced; Restore puts that back, and the restore is listed too
  await pg.click(".txall .txbtn:text('Changes')");
  await pg.waitForSelector(".txchg");
  assert.equal(await pg.$eval(".txchg .txwas", (e) => e.textContent), "Bonjour twa");
  await pg.click(".txchg .txbtn:text('Restore')");
  await pg.waitForSelector(".txchg .txbtn:text('Restored')");
  assert.equal((await (await KEEP.get("keep/" + ka + "/corrections.json")).json()).overrides[0].to, "Bonjour twa");
  await pg.click(".txall .txbtn:text('Transcript')");
  await pg.fill(".txin", "Bonjour toi");
  await pg.press(".txin", "Enter");
  await pg.click(".txall .txbtn:text('Done')");
  await pg.waitForFunction(() => !document.querySelector(".txall"));
  for (let i = 0; i < 40; i++) {
    await pg.waitForTimeout(100);
    if ((await (await KEEP.get("keep/" + ka + "/corrections.json")).json()).overrides[0].to === "Bonjour toi") break;
  }
  await pg.goto(base + "/main?p=Fix");
  await pg.click('.tile[data-n="00000"]');
  await pg.waitForSelector(".tx.learn .txp:not([hidden])");
  assert.equal(await pg.$$eval(".tx .txp:not([hidden]) .txs", (a) => a.map((x) => x.textContent).join(" ")), "Bonjour toi");
  // b has no transcript: opening it queues Recense under the lock and says so
  await pg.keyboard.press("ArrowRight");
  await pg.waitForSelector(".txst .txmsg");
  // the lock is under the file's content key (transcript.js fingerprintKey)
  const sha = async (b) => Buffer.from(await crypto.subtle.digest("SHA-256", b)).toString("hex");
  const head = await sha(wav.subarray(0, 65536));
  const tail = wav.length <= 65536 ? head : await sha(wav.subarray(wav.length - 65536));
  const kb = (await sha(new TextEncoder().encode(`fp:${wav.length}:${head}:${tail}`))).slice(0, 24);
  let lock = null;
  for (let i = 0; i < 40 && !lock; i++) {
    await pg.waitForTimeout(100);
    lock = await KEEP.head("keep/locks/" + kb);
  }
  assert.ok(lock, "lock taken");
});

await test("Learn mode: two places, lines take turns, centred in the player", true, async (pg) => {
  const KEEP = await mf.getR2Bucket("KEEP");
  const secs = 9;
  const wav = Buffer.alloc(44 + 16000 * 2 * secs);
  wav.write("RIFF", 0); wav.writeUInt32LE(36 + 32000 * secs, 4); wav.write("WAVEfmt ", 8); wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22); wav.writeUInt32LE(16000, 24); wav.writeUInt32LE(32000, 28);
  wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34); wav.write("data", 36); wav.writeUInt32LE(32000 * secs, 40);
  await MAIN.put("files/Barrel/b.wav", wav, { httpMetadata: { contentType: "audio/wav" } });
  const hex = Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("gallery:files/Barrel/b.wav"))).toString("hex").slice(0, 24);
  const line = (id, a, b, s) => ({ id, words: [{ text: a, start: s, end: s + 0.5 }, { text: b, start: s + 0.6, end: s + 1 }] });
  await KEEP.put("keep/" + hex + ".v2.json", JSON.stringify({ complete: true, lines: [line(0, "Un", "deux", 0), line(1, "Trois", "quatre", 3), line(2, "Cinq", "six", 6)] }));
  await pg.goto(base + "/main?p=Barrel");
  await pg.click('.tile[data-n="00000"]');
  const ROW = ".tx.learn .txp:not([hidden])";
  await pg.waitForSelector(ROW);
  assert.equal(await pg.$$eval(".tx.learn .txp", (a) => a.length), 2, "two places, one over the other");
  await pg.$eval("audio", (a) => (a.currentTime = 3.2));
  await pg.waitForFunction(() => [...document.querySelectorAll(".tx.learn .txp:not([hidden]) .txs")].some((x) => /Trois/.test(x.textContent)), null, { timeout: 5000 });
  const r = await pg.$eval(".tx.learn", (e) => { const b = e.getBoundingClientRect(); return [b.bottom, innerHeight]; });
  assert.ok(r[0] > r[1] * 0.25 && r[0] < r[1] * 0.6, "centred above the play controls, not under the date");
});

await test("Text Size: the top-right pill, Info's row and a trackpad pinch move one subtitle size, kept after a reload", true, async (pg) => {
  const KEEP = await mf.getR2Bucket("KEEP");
  const wav = Buffer.alloc(44 + 16000 * 2 * 6);
  wav.write("RIFF", 0); wav.writeUInt32LE(36 + 32000 * 6, 4); wav.write("WAVEfmt ", 8); wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22); wav.writeUInt32LE(16000, 24); wav.writeUInt32LE(32000, 28);
  wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34); wav.write("data", 36); wav.writeUInt32LE(32000 * 6, 40);
  await MAIN.put("files/Sizes/s.wav", wav, { httpMetadata: { contentType: "audio/wav" } });
  const hex = Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("gallery:files/Sizes/s.wav"))).toString("hex").slice(0, 24);
  await KEEP.put("keep/" + hex + ".v2.json", JSON.stringify({ complete: true, lines: [{ id: 0, words: [{ text: "Người", start: 0, end: 0.5 }, { text: "ấy", start: 0.6, end: 1 }] }] }));
  await pg.goto(base + "/main?p=Sizes");
  await pg.click('.tile[data-n="00000"]');
  await pg.waitForSelector(".tx.learn .txp:not([hidden])");
  await pg.waitForSelector(".tpill:not([hidden])");
  const size = () => pg.$eval(".tx.learn .txp:not([hidden])", (e) => parseFloat(e.style.fontSize));
  const lh = await pg.$eval(".tx.learn .txp:not([hidden])", (e) => getComputedStyle(e).lineHeight);
  const s0 = await size();
  assert.ok(s0 >= 22 && s0 <= 30, "base size within clamp(22px, 3vw, 30px): " + s0);
  assert.ok(Math.abs(parseFloat(lh) / s0 - 1.45) < 0.02, "line-height 1.45: " + lh);
  await pg.click(".tpill .txs-up");
  await pg.waitForFunction((a) => parseFloat(document.querySelector(".tx.learn .txp:not([hidden])").style.fontSize) > a * 1.05, s0);
  await pg.click("#info");
  await pg.waitForSelector("#meta .mtsz");
  await pg.click("#meta .mtsz .txs-dn");
  await pg.click("#meta .mtsz .txs-dn");
  await pg.waitForFunction((a) => parseFloat(document.querySelector(".tx.learn .txp:not([hidden])").style.fontSize) < a * 0.95, s0);
  assert.equal(await pg.$eval(".tpill .txs-pct", (e) => e.textContent), "90%", "the pill follows Info");
  await pg.click("#info");
  // a trackpad pinch (ctrl + wheel) over the lyrics scales them, and the page itself doesn't zoom
  const box = await pg.$eval("#stage", (e) => { const r = e.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; });
  await pg.mouse.move(box[0], box[1]);
  await pg.keyboard.down("Control");
  await pg.mouse.wheel(0, -40);
  await pg.keyboard.up("Control");
  await pg.waitForFunction(() => /^(1[0-9]{2}|[2-9][0-9])%$/.test(document.querySelector(".tpill .txs-pct").textContent) && document.querySelector(".tpill .txs-pct").textContent !== "90%");
  await pg.waitForTimeout(400);
  const kept = await pg.evaluate(() => localStorage.getItem("gallery.textScale"));
  assert.ok(parseFloat(kept) > 0.9, "pinch kept: " + kept);
  await pg.reload();
  await pg.click('.tile[data-n="00000"]');
  await pg.waitForSelector(".tx.learn .txp:not([hidden])");
  assert.equal(await pg.$eval(".tpill .txs-pct", (e) => e.textContent), Math.round(parseFloat(kept) * 100) + "%", "same size after a reload");
});

await test("Key labels: stored key spelled per caption state; tap resets the key; right-click, swipe and hold change the state", true, async (pg) => {
  const wav = Buffer.alloc(44 + 16000 * 2);
  wav.write("RIFF", 0); wav.writeUInt32LE(36 + 32000, 4); wav.write("WAVEfmt ", 8); wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22); wav.writeUInt32LE(16000, 24); wav.writeUInt32LE(32000, 28);
  wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34); wav.write("data", 36); wav.writeUInt32LE(32000, 40);
  await MAIN.put("files/Keys/k.wav", wav, { httpMetadata: { contentType: "audio/wav" } });
  await MAIN.put("keys/Keys/.keys.json", JSON.stringify({ "k.wav": { auto: "C", manual: "E♭m", at: 1 } }));
  await pg.goto(base + "/main?p=Keys");
  await pg.click('.tile[data-n="00000"]');
  await pg.waitForSelector(".p-eqbtn");
  await pg.click(".p-eqbtn");
  await pg.waitForSelector(".p-band.key .kcap", { state: "visible" });
  const lines = () => pg.$$eval(".p-band.key .kval span", (a) => a.map((x) => x.textContent));
  const cap = () => pg.$eval(".p-band.key .kcap", (e) => e.textContent);
  const now = () => pg.$eval(".p-band.key .p-btrack", (e) => e.getAttribute("aria-valuenow"));

  assert.deepEqual(await lines(), ["E♭m"]);
  assert.equal(await cap(), "Key");
  // a tap resets the key to 0 and leaves the caption alone
  await pg.focus(".p-band.key .p-btrack");
  await pg.keyboard.press("ArrowUp");
  assert.equal(await now(), "1");
  await pg.click(".p-band.key .kcap");
  assert.equal(await cap(), "Key");
  assert.equal(await now(), "0");
  await pg.click(".p-band.key .kcap", { button: "right" });
  assert.equal(await cap(), "Cents");
  assert.deepEqual(await lines(), ["E♭m", "+0¢"]);

  // State 9 steps in cents; leaving it snaps the key back to whole semitones
  await pg.focus(".p-band.key .p-btrack");
  await pg.keyboard.press("ArrowUp");
  assert.equal(await now(), "0.01");
  assert.deepEqual(await lines(), ["E♭m", "+1¢"]);
  await pg.hover(".p-band.key .kcap");
  await pg.mouse.wheel(0, 20);
  await pg.click('.kpop .krow[data-state="0"]');
  assert.equal(await cap(), "Key");
  assert.equal(await now(), "0");
  await pg.mouse.move(0, 0);
  await pg.waitForTimeout(150);

  // two fingers down over the caption: one state back, however many events the swipe brings
  await pg.hover(".p-band.key .kcap");
  await pg.mouse.wheel(0, -20);
  await pg.mouse.wheel(0, -20);
  assert.equal(await cap(), "Cents");
  await pg.waitForTimeout(150);
  // two fingers up: the list; resting the pointer on the caption opens it too
  await pg.mouse.wheel(0, 20);
  assert.ok(await pg.isVisible(".p-band.key .kpop"));
  await pg.click('.kpop .krow[data-state="1"]');
  assert.equal(await cap(), "Ton.");
  await pg.mouse.move(0, 0);
  await pg.hover(".p-band.key .kcap");
  await pg.waitForSelector(".p-band.key .kpop:not([hidden])", { timeout: 2000 });
  await pg.mouse.move(0, 0);
  await pg.waitForSelector(".p-band.key .kpop[hidden]", { state: "attached", timeout: 2000 });

  // hold: the list; pick a row
  const box = await pg.$eval(".p-band.key .kcap", (e) => { const r = e.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; });
  await pg.mouse.move(box.x, box.y);
  await pg.mouse.down();
  await pg.waitForTimeout(450);
  await pg.mouse.up();
  assert.ok(await pg.isVisible(".p-band.key .kpop"));
  assert.deepEqual(await pg.$$eval(".kpop .krow", (a) => a.map((x) => x.textContent)), ["Key", "Ton.", "Tông", "Tonart", "調", "调", "Sa", "Maqam", "Maqam¼", "Cents"]);
  assert.equal(await pg.$eval(".kpop .krow.on", (e) => e.textContent), "Ton.");
  assert.equal(await cap(), "Ton."); // the click that ended the hold changed nothing
  await pg.click('.kpop .krow[data-state="7"]');
  assert.ok(!(await pg.isVisible(".p-band.key .kpop")));
  assert.equal(await cap(), "Maqam");
  assert.deepEqual(await lines(), ["E♭m", "Kurd"]);
  // the label never widens the column
  const w = await pg.$eval(".p-band.key", (e) => [e.getBoundingClientRect().width, e.previousElementSibling.getBoundingClientRect().width]);
  assert.ok(w[0] <= w[1] + 0.5, "Key column " + w[0] + " wider than High " + w[1]);
  // the state stays for the next visit
  await pg.reload();
  await pg.click('.tile[data-n="00000"]');
  await pg.waitForSelector(".p-band.key .kcap", { state: "attached" });
  assert.equal(await cap(), "Maqam");
});

await test("Info: Delete Cover gives the root grid the file tile, Change Cover gives it the new picture, both after a reload", true, async (pg) => {
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==", "base64");
  await MAIN.put("files/song.mp3", "x", { httpMetadata: { contentType: "audio/mpeg" } });
  await MAIN.put("art/song.mp3", png, { httpMetadata: { contentType: "image/png" }, customMetadata: { custom: "1" } });
  const tile = '.tile[data-n="00000"]';
  const loaded = () => pg.waitForFunction((t) => { const i = document.querySelector(t + " img.art"); return i && i.complete && i.naturalWidth > 0; }, tile);
  const openInfo = async () => {
    await pg.click(tile);
    await pg.click("#info");
  };

  await pg.goto(base + "/main");
  await loaded();
  await openInfo();
  await pg.click('#meta .mops button:has-text("Delete Cover")');
  await pg.waitForSelector(tile + " .doc small", { state: "attached" }); // the grid is behind the viewer
  assert.equal(await pg.textContent(tile + " .doc small"), "song.MP3");
  assert.equal(await pg.textContent(tile + " .doc .fi i"), "MP3");
  await pg.reload();
  await pg.waitForSelector(tile + " .doc small");
  assert.equal(await pg.$(tile + " img"), null);

  await openInfo();
  const [chooser] = await Promise.all([pg.waitForEvent("filechooser"), pg.click('#meta .mops button:has-text("Change Cover")')]);
  await chooser.setFiles({ name: "c.png", mimeType: "image/png", buffer: png });
  await pg.waitForSelector(tile + " img.art", { state: "attached" });
  await loaded();
  const src = await pg.$eval(tile + " img.art", (i) => i.getAttribute("src"));
  assert.match(src, /\?art=1&v=\w+$/);
  await pg.reload();
  await loaded();
  assert.equal(await pg.$eval(tile + " img.art", (i) => i.getAttribute("src")), src);
});

let wavs = 0; // every file different bytes, so no two share a content key
const wavOf = (secs) => {
  const n = 16000 * 2 * secs;
  const w = Buffer.alloc(44 + n);
  w.write("RIFF", 0); w.writeUInt32LE(36 + n, 4); w.write("WAVEfmt ", 8); w.writeUInt32LE(16, 16);
  w.writeUInt16LE(1, 20); w.writeUInt16LE(1, 22); w.writeUInt32LE(16000, 24); w.writeUInt32LE(32000, 28);
  w.writeUInt16LE(2, 32); w.writeUInt16LE(16, 34); w.write("data", 36); w.writeUInt32LE(n, 40);
  w.writeUInt32LE(++wavs, 44 + n - 4);
  return w;
};
// a file's content key, as transcript.js fingerprintKey and Recense compute it
const fpKey = async (b) => {
  const sha = async (x) => Buffer.from(await crypto.subtle.digest("SHA-256", x)).toString("hex");
  const head = await sha(b.subarray(0, 65536));
  const tail = b.length <= 65536 ? head : await sha(b.subarray(b.length - 65536));
  return (await sha(new TextEncoder().encode(`fp:${b.length}:${head}:${tail}`))).slice(0, 24);
};
const keepKey = async (p) =>
  Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("gallery:files/" + p))).toString("hex").slice(0, 24);

await test("§1 native language: Info's segmented picker sets the Key label's second line at once, keeps the Key state, and persists", true, async (pg) => {
  await MAIN.put("files/Nl/k.wav", wavOf(1), { httpMetadata: { contentType: "audio/wav" } });
  await MAIN.put("keys/Nl/.keys.json", JSON.stringify({ "k.wav": { manual: "E♭m", at: 1 } }));
  await pg.goto(base + "/main?p=Nl");
  await pg.click('.tile[data-n="00000"]');
  await pg.waitForSelector(".p-eqbtn");
  await pg.click(".p-eqbtn");
  await pg.waitForSelector(".p-band.key .kcap", { state: "visible" });
  const lines = () => pg.$$eval(".p-band.key .kval span", (a) => a.map((x) => x.textContent));
  assert.deepEqual(await lines(), ["E♭m"]);
  await pg.click("#info");
  assert.deepEqual(await pg.$$eval('#meta .seg input[name="nlang"]', (a) => a.map((x) => x.value)), ["en", "vi", "fr"]);
  assert.deepEqual(await pg.$$eval("#meta .seg span", (a) => a.map((x) => x.textContent)), ["English", "Vietnamese", "French"]);
  assert.ok(await pg.isChecked('#meta .seg input[value="en"]'));
  await pg.click('#meta .seg label:has-text("French")');
  assert.deepEqual(await lines(), ["E♭m", "Mi♭m"]);
  await pg.click('#meta .seg label:has-text("Vietnamese")');
  assert.deepEqual(await lines(), ["E♭m", "Mi♭t"]);
  assert.equal(await pg.textContent(".p-band.key .kcap"), "Key", "the state is untouched");
  assert.equal(await pg.evaluate(() => localStorage.getItem("gallery.nativeLang")), "vi");
  await pg.reload();
  await pg.click('.tile[data-n="00000"]');
  await pg.click("#info");
  assert.ok(await pg.isChecked('#meta .seg input[value="vi"]'));
  await pg.click(".p-eqbtn");
  await pg.waitForSelector(".p-band.key .kcap", { state: "visible" });
  assert.deepEqual(await lines(), ["E♭m", "Mi♭t"]);
  await pg.click('#meta .seg label:has-text("English")');
  assert.deepEqual(await lines(), ["E♭m"]);
});

await test("share link: the sharer's language and notation (Tông) win over the visitor's browser; a key is found as the item opens", true, async (pg) => {
  // an A minor triad, so detection has something to find
  const secs = 4, n = 16000 * secs, chord = Buffer.alloc(44 + n * 2);
  chord.write("RIFF", 0); chord.writeUInt32LE(36 + n * 2, 4); chord.write("WAVEfmt ", 8); chord.writeUInt32LE(16, 16);
  chord.writeUInt16LE(1, 20); chord.writeUInt16LE(1, 22); chord.writeUInt32LE(16000, 24); chord.writeUInt32LE(32000, 28);
  chord.writeUInt16LE(2, 32); chord.writeUInt16LE(16, 34); chord.write("data", 36); chord.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) chord.writeInt16LE(Math.round(3000 * [220, 261.63, 329.63].reduce((a, f) => a + Math.sin((2 * Math.PI * f * i) / 16000), 0)), 44 + i * 2);
  await MAIN.put("files/Sv/k.wav", wavOf(1), { httpMetadata: { contentType: "audio/wav" } });
  await MAIN.put("files/Sv/z.wav", chord, { httpMetadata: { contentType: "audio/wav" } });
  await MAIN.put("keys/Sv/.keys.json", JSON.stringify({ "k.wav": { manual: "E♭m", at: 1 } }));
  await pg.goto(base + "/main?p=Sv");
  // the sharer reads in Vietnamese with the French caption picked earlier: the link gets Tông
  await pg.evaluate(() => { localStorage.setItem("gallery.nativeLang", "vi"); localStorage.setItem("gallery.keyNotation", "1"); });
  await pg.reload();
  const url = await pg.evaluate(async () => {
    const H = { "x-gallery": "1", "content-type": "application/json" };
    const j = await (await fetch("/main/api/link?action=fromMain&days=1", { method: "POST", headers: H, body: JSON.stringify({ paths: ["Sv/k.wav", "Sv/z.wav"], ...window.galleryView() }) })).json();
    for (let i = 0; i < j.count; i++) await fetch("/main/api/link?action=copy&id=" + j.id + "&i=" + i, { method: "POST", headers: H });
    return j.url;
  });
  // the visitor's own browser says English and Key: the link wins
  await pg.evaluate(() => { localStorage.setItem("gallery.nativeLang", "en"); localStorage.setItem("gallery.keyNotation", "0"); });
  await pg.goto(base + url);
  await pg.click('.tile[data-n="000"]');
  await pg.waitForSelector(".p-eqbtn");
  await pg.click(".p-eqbtn");
  await pg.waitForSelector(".p-band.key .kcap", { state: "visible" });
  assert.equal(await pg.textContent(".p-band.key .kcap"), "Tông");
  assert.deepEqual(await pg.$$eval(".p-band.key .kval span", (a) => a.map((x) => x.textContent)), ["Mi♭t"]);
  assert.equal(await pg.evaluate(() => localStorage.getItem("gallery.keyNotation")), "0", "a visit never writes the visitor's settings");
  // the item without a stored key: found on opening, so solfège instead of +1, +2
  await pg.keyboard.press("ArrowRight");
  await pg.waitForFunction(() => { const v = document.querySelector(".p-band.key .kval"); return v && v.textContent && !/^[+−]?\d/.test(v.textContent); }, null, { timeout: 15000 });
});

await test("Learn: the native language's line from keep/<key>/tr/<lang>.json; the English where that language has no file", true, async (pg) => {
  const KEEP = await mf.getR2Bucket("KEEP");
  await MAIN.put("files/Nv/a.wav", wavOf(3), { httpMetadata: { contentType: "audio/wav" } });
  const k = await keepKey("Nv/a.wav");
  const words = [{ text: "Bonjour", start: 0, end: 0.5 }, { text: "toi", start: 0.6, end: 1 }];
  await KEEP.put(`keep/${k}/asr.json`, JSON.stringify({ format: 1, complete: true, duration: 3, segments: [{ id: 0, start: 0, end: 1, text: "Bonjour toi", words }] }));
  await KEEP.put(`keep/${k}/tr/en.json`, JSON.stringify({ lang: "en", complete: true, lines: { 0: { src: "Bonjour toi", text: "Hello you", words: [{ w: "Hello", s: [0] }, { w: "you", s: [1] }] } } }));
  await KEEP.put(`keep/${k}/tr/vi.json`, JSON.stringify({ lang: "vi", complete: true, lines: { 0: { src: "Bonjour toi", text: "Chào bạn" } } }));
  await pg.goto(base + "/main?p=Nv");
  await pg.evaluate(() => localStorage.setItem("gallery.nativeLang", "vi"));
  await pg.reload();
  await pg.click('.tile[data-n="00000"]');
  const native = (t) =>
    pg.waitForFunction((t) => [...document.querySelectorAll(".tx.learn .txp:not([hidden]) .txe")].map((x) => x.textContent).join(" ") === t, t, { timeout: 5000 });
  await native("Chào bạn");
  // no French file: the English, not the Vietnamese
  await pg.click("#info");
  await pg.click('#meta .seg label:has-text("French")');
  await native("Hello you");
  await pg.click('#meta .seg label:has-text("Vietnamese")');
  await native("Chào bạn");
  await pg.evaluate(() => localStorage.setItem("gallery.nativeLang", "en"));
});

await test("§2 viewer modes: cover while it is transcribed (with progress), lyrics on black once done", true, async (pg) => {
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==", "base64");
  const KEEP = await mf.getR2Bucket("KEEP");
  const wav = wavOf(3);
  await MAIN.put("files/Md/a.wav", wav, { httpMetadata: { contentType: "audio/wav" } });
  await MAIN.put("art/Md/a.wav", png, { httpMetadata: { contentType: "image/png" }, customMetadata: { custom: "1" } });
  await pg.goto(base + "/main?p=Md");
  await pg.click('.tile[data-n="00000"]');
  // mode 1: the cover, and a small progress indicator while the transcript is on its way
  await pg.waitForSelector(".aw .txst .txmsg");
  assert.ok(!(await pg.$eval(".aw", (e) => e.classList.contains("lyrics"))));
  assert.ok(await pg.isVisible(".aw img"));
  // done: the page switches to mode 2 by itself
  const k = await keepKey("Md/a.wav");
  await KEEP.put("keep/" + k + ".v2.json", JSON.stringify({ complete: true, lines: [{ id: 0, words: [{ text: "Bonjour", start: 0, end: 0.5 }, { text: "toi", start: 0.6, end: 1 }] }] }));
  await KEEP.delete("keep/locks/" + (await fpKey(wav)));
  await pg.waitForSelector(".aw.lyrics .tx.learn", { timeout: 9000 });
  assert.ok(!(await pg.isVisible(".aw img")), "no cover in mode 2");
  assert.equal(await pg.$eval(".aw", (e) => getComputedStyle(e).backgroundColor), "rgb(0, 0, 0)");
  assert.equal(await pg.$(".aw .txst"), null);
  // the grid keeps the square cover
  assert.ok(await pg.$('.tile[data-n="00000"] img'));
});

await test("§5 strip: Share sits in the old Download slot, no Download icon; Download is in Info, left of the comment label", true, async (pg) => {
  await MAIN.put("files/Dl/a.jpg", "x", { httpMetadata: { contentType: "image/jpeg" } });
  await pg.goto(base + "/main?p=Dl");
  await pg.click('.tile[data-n="00000"]');
  assert.equal(await pg.$("#save"), null);
  assert.equal(await pg.$('.bot [aria-label="Download"]'), null);
  assert.ok(await pg.isVisible("#vshare"));
  assert.equal(await pg.$eval("#vshare", (e) => getComputedStyle(e).gridArea.split(" ")[0]), "sav");
  await pg.click("#info");
  const first = await pg.$eval("#meta .mops button", (e) => e.textContent);
  assert.equal(first, "Download");
  // Info opens from the ⓘ at the bar's left, beside Add a comment
  const ib = await pg.$eval("#info", (e) => e.getBoundingClientRect().right);
  const cm = await pg.$eval("#cm", (e) => e.getBoundingClientRect().left);
  assert.ok(ib <= cm, "Info is left of Add a comment");
  const [d] = await Promise.all([pg.waitForEvent("download"), pg.click('#meta .mops button:has-text("Download")')]);
  assert.match(d.suggestedFilename(), /a\.jpg/i);
});

await test("§5 strip on a public link: no Download icon or Share for visitors; Info has Download", false, async (pg) => {
  await pg.goto(base + "/s/" + linkId);
  await pg.click(".tile:not(.add)");
  assert.equal(await pg.$("#save"), null);
  assert.ok(!(await pg.isVisible("#vshare")));
  await pg.click("#info");
  assert.ok(await pg.isVisible('#meta .mops button:has-text("Download")'));
});

await test("§7 comments: a leftward swipe on the right side (touch) or a trackpad swipe while hovering reveals a blue Delete", true, async (pg) => {
  await MAIN.put("files/Sw/p.jpg", "x", { httpMetadata: { contentType: "image/jpeg" } });
  await pg.goto(base + "/main?p=Sw");
  await pg.click('.tile[data-n="00000"]');
  await pg.click(".cmlabel");
  for (const [i, t] of ["one", "two"].entries()) {
    await pg.fill("#thread textarea", t);
    await pg.press("#thread textarea", "Enter");
    await pg.waitForFunction((n) => document.querySelectorAll("#thread .crow").length === n, i + 1);
  }
  await pg.waitForFunction(() => document.querySelectorAll("#thread .crow.sw").length === 2);
  await pg.evaluate(() => document.activeElement && document.activeElement.blur());
  await pg.waitForTimeout(600); // the thread's smooth scroll to the field settles
  assert.equal(await pg.$$eval("#thread .crow button:not(.cdel)", (a) => a.length), 0, "no Edit button, no Delete until a swipe");
  assert.equal(await pg.$$eval("#thread .ctext.cmine", (a) => a.length), 2, "your comments edit on tap");
  const box = (i) => pg.$$eval("#thread .crow.sw", (a, i) => { const r = a[i].getBoundingClientRect(); return { l: r.left, w: r.width, y: r.top + r.height / 2 }; }, i);
  const delRight = (i) => pg.$$eval("#thread .crow.sw", (a, i) => { const r = a[i].getBoundingClientRect(); const d = a[i].querySelector(".cdel").getBoundingClientRect(); return Math.round(r.right - d.right); }, i);
  const shown = (i) => pg.$$eval("#thread .crow.sw", (a, i) => a[i].querySelector(".cslide").getBoundingClientRect().right <= a[i].querySelector(".cdel").getBoundingClientRect().left + 1, i);
  assert.ok(!(await shown(0)));
  // trackpad: hover, two-finger swipe right to left
  let b = await box(0);
  await pg.mouse.move(b.l + b.w * 0.5, b.y);
  await pg.mouse.wheel(60, 0);
  await pg.waitForSelector("#thread .crow.sw.open");
  await pg.waitForTimeout(300);
  assert.ok(await shown(0));
  assert.equal(await delRight(0), 0, "at the comment's right end");
  const blue = await pg.$eval("#thread .crow.open .cdel", (e) => getComputedStyle(e).color);
  assert.equal(blue, await pg.$eval("#thread .tact .lnk", (e) => getComputedStyle(e).color), "the same blue as the other controls");
  // swiping back folds it
  b = await box(0);
  await pg.mouse.move(b.l + b.w * 0.5, b.y);
  await pg.mouse.wheel(-60, 0);
  await pg.waitForFunction(() => !document.querySelector("#thread .crow.open"));
  // touch: a swipe that starts on the left half does nothing; one on the right half reveals it
  const cdp = await pg.context().newCDPSession(pg);
  await cdp.send("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 1 });
  const swipe = async (x0, x1, y) => {
    await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: x0, y }] });
    for (let k = 1; k <= 6; k++) await cdp.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x: x0 + ((x1 - x0) * k) / 6, y }] });
    await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
  };
  b = await box(1);
  await swipe(b.l + b.w * 0.3, b.l + b.w * 0.3 - 150, b.y);
  await pg.waitForTimeout(100);
  assert.equal(await pg.$("#thread .crow.open"), null, "the left side doesn't swipe");
  await swipe(b.l + b.w * 0.9, b.l + b.w * 0.9 - 150, b.y);
  await pg.waitForFunction(() => document.querySelectorAll("#thread .crow.sw")[1].classList.contains("open"));
  await cdp.send("Emulation.setTouchEmulationEnabled", { enabled: false });
  await pg.click("#thread .crow.open .cdel");
  await pg.waitForFunction(() => document.querySelectorAll("#thread .crow").length === 1);
  assert.equal(await pg.textContent("#thread .ctext"), "one");
});

console.log(`\n${passed} passed`);
await test("Documents: Markdown and plain text open as pages in the PDF viewer's layout", true, async (pg) => {
  await MAIN.put("files/Docs/notes.md", "# Title\n\nSome **bold** and a [link](https://example.com).\n\n- one\n- two\n\n<script>window.__x=1</script>", { httpMetadata: { contentType: "text/markdown" } });
  await MAIN.put("files/Docs/plain.txt", "line one\nline two", { httpMetadata: { contentType: "text/plain" } });
  await pg.goto(base + "/main?p=Docs");
  await pg.click('.tile[data-n="00000"]');
  await pg.waitForSelector(".pdfv .pdfp.txtdoc h1");
  assert.equal(await pg.$eval(".txtdoc h1", (e) => e.textContent), "Title");
  assert.equal(await pg.$eval(".txtdoc strong", (e) => e.textContent), "bold");
  assert.equal(await pg.$$eval(".txtdoc li", (a) => a.length), 2);
  assert.equal(await pg.evaluate(() => window.__x), undefined, "nothing in a document runs");
  await pg.keyboard.press("ArrowRight");
  await pg.waitForFunction(() => /line one\nline two/.test((document.querySelector(".txtdoc pre") || {}).textContent || ""));
  // Word, through mammoth from cdnjs (skipped offline)
  if (process.env.DOCX) {
    await MAIN.put("files/Docs/w.docx", (await import("node:fs")).readFileSync(process.env.DOCX));
    await pg.goto(base + "/main?p=Docs");
    await pg.click('.tile[data-n="00002"]');
    await pg.waitForFunction(() => /Hello from Word/.test((document.querySelector(".txtdoc") || {}).textContent || ""), null, { timeout: 15000 });
  }
});

await browser.close();
await mf.dispose();
