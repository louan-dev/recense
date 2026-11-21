// Pair a phone or tablet with the owner's Main, from the Mac that is already signed in.
//
// The signed-in Mac asks for a one-time six-digit code (/main/pair). The other device types it at
// /pair; the Worker checks it and sets a signed device cookie. isOwner() then accepts that cookie
// as long as the device's record exists and is not revoked (/main/devices lists and revokes them).
//
// Rules:
//   - a paired device stays paired until it is revoked: the pass never expires by date, the cookie is renewed
//     for the browser's maximum (400 days) each time the device is used, so only a device unused for over a
//     year (or one that was revoked) has to pair again
//   - one live code at a time; it lasts 5 minutes, works once, and dies after 5 wrong guesses
//     (5 in a million: no brute force), checked with a conditional R2 write so two claims can't both win
//   - the code is stored only as a hash; the cookie is HMAC-SHA256 over id.expiry with PAIR_SECRET
//   - no PAIR_SECRET set: pairing is off, every device cookie is refused
// Storage: the gallery-main bucket under .pair/ (names starting with "." never show in Main).

import { page, notice, esc } from "./common.js";

const PENDING = ".pair/pending.json";
const DEVICE = (id) => ".pair/devices/" + id + ".json";
const CODE_TTL = 5 * 60e3;
const MAX_TRIES = 5;
const COOKIE = "gdev";
const COOKIE_DAYS = 400; // the longest a browser keeps a cookie (Chrome's cap; Safari honours it for server-set cookies)
const FOREVER = 9999999999999; // the pass's signed expiry: revoking the device record is what ends a pass
const enc = new TextEncoder();

const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
const sha = async (s) => hex(await crypto.subtle.digest("SHA-256", enc.encode(s)));

async function hmac(env, s) {
  const key = await crypto.subtle.importKey("raw", enc.encode(env.PAIR_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, enc.encode(s)));
}

// constant-time compare of two hex strings
function same(a, b) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

const on = (env) => typeof env.PAIR_SECRET === "string" && env.PAIR_SECRET.length >= 32;

// ---------- the device cookie, read by isOwner() ----------

const renewals = new WeakMap();

// A fresh cookie for a device that just proved its pass (a request flagged by deviceOwner), or the response as it was.
export async function withRenewal(req, env, res) {
  const id = renewals.get(req);
  if (!id || res.status === 101) return res;
  const out = new Response(res.body, res);
  out.headers.append("set-cookie", await passCookie(env, id));
  return out;
}

export async function deviceOwner(req, env) {
  if (!on(env)) return false;
  const m = (req.headers.get("cookie") || "").match(/(?:^|;\s*)gdev=([0-9a-f]{32})\.(\d{10,13})\.([0-9a-f]{64})(?:;|$)/);
  if (!m) return false;
  const [, id, exp, sig] = m;
  if (!(Number(exp) > Date.now())) return false;
  if (!same(sig, await hmac(env, id + "." + exp))) return false;

  const obj = await env.MAIN.get(DEVICE(id));
  if (!obj) return false;
  const dev = await obj.json();
  if (dev.revoked) return false;

  // the first time the device comes back with its pass, it counts as paired (never before: no false positives)
  // an old 90-day pass is swapped for a never-expiring one on its next use; every pass is renewed hourly while in use
  if (Number(exp) !== FOREVER) renewals.set(req, id);
  if (!dev.confirmed || Date.now() - (dev.seen || 0) > 3600e3) {
    renewals.set(req, id);
    dev.confirmed = dev.confirmed || Date.now();
    dev.seen = Date.now();
    await env.MAIN.put(DEVICE(id), JSON.stringify(dev), { onlyIf: { etagMatches: obj.etag } }).catch(() => {});
  }
  return true;
}

// What the device check sees, step by step, for a phone that pairs but can't get in.
// Names only what failed; never a value.
export async function pairCheck(req, env) {
  const raw = req.headers.get("cookie") || "";
  const names = raw.split(";").map((c) => c.split("=")[0].trim()).filter(Boolean);
  const say = (step) => page(shell("Pairing check", `<p>${esc(step)}</p><p>Cookies this browser sent: ${esc(names.join(", ") || "none")}</p><p><a href="/pair">Pair again</a></p>`));
  if (!on(env)) return say("Pairing is off on this address (no PAIR_SECRET).");
  const m = raw.match(/(?:^|;\s*)gdev=([^;]*)/);
  if (!m) return say("No pairing pass: this browser did not keep or send it. Check Block All Cookies and Private tabs.");
  const p = m[1].match(/^([0-9a-f]{32})\.(\d{10,13})\.([0-9a-f]{64})$/);
  if (!p) return say("The pass is malformed.");
  if (!(Number(p[2]) > Date.now())) return say("The pass has expired.");
  if (!same(p[3], await hmac(env, p[1] + "." + p[2]))) return say("The pass's signature is wrong (made with another secret?).");
  const obj = await env.MAIN.get(DEVICE(p[1]));
  if (!obj) return say("The pass is fine but its device record is missing.");
  const d = await obj.json();
  if (d.revoked) return say("This device was revoked.");
  return say("All checks pass: this device should open /main/ (" + d.name + ").");
}

// ---------- the Mac: mint a code (owner only, under /main) ----------

export async function mintCode(env) {
  if (!on(env)) return Response.json({ ok: false, error: "Pairing is off: PAIR_SECRET is not set." }, { status: 503 });
  const n = crypto.getRandomValues(new Uint32Array(1))[0] % 1e6;
  const code = String(n).padStart(6, "0");
  const exp = Date.now() + CODE_TTL;
  await env.MAIN.put(PENDING, JSON.stringify({ hash: await sha(code), exp, tries: 0, used: false }));
  return Response.json({ ok: true, code, exp });
}

export function pairPage(env) {
  const where = String(env.DEVICE_ORIGIN || "") + "/pair";
  return page(shell("Pair a device", `
<p>On your iPhone or iPad, open <b id="where">${esc(where)}</b></p>
<p>and type this code within 5 minutes:</p>
<p id="code" class="code">······</p>
<p><button id="new">New Code</button></p>
<p><a href="/main/devices">Paired Devices</a></p>
<script>
if (!document.getElementById("where").textContent.startsWith("http")) document.getElementById("where").textContent = location.origin + "/pair";
let timer;
async function mint() {
  const r = await fetch("/main/api/pair", { method: "POST" });
  const j = await r.json();
  document.getElementById("code").textContent = j.ok ? j.code : j.error;
  clearTimeout(timer);
  if (j.ok) timer = setTimeout(mint, Math.max(5000, j.exp - Date.now() - 20000)); // a fresh code just before this one dies
}
document.getElementById("new").onclick = mint;
mint();
</script>`));
}

// ---------- the phone: claim (public, outside Access) ----------

export function claimPage(msg = "", status = 200, env = {}, url = null) {
  // the phone pairs on the device address (no Access in front); send it there
  if (url && env.DEVICE_ORIGIN && !env.DEVICE_HOST && url.origin !== env.DEVICE_ORIGIN) return Response.redirect(env.DEVICE_ORIGIN + "/pair" + url.search, 302);
  // /pair?code=123456 (the Mac's own script opens it) fills the box; it still takes one tap on Pair, and no GET ever claims
  const c = url ? url.searchParams.get("code") : "";
  const prefill = /^\d{6}$/.test(c || "") ? c : "";
  return page(shell("Pair this device", `
${msg ? `<p class="msg">${esc(msg)}</p>` : ""}
<form method="post" action="/pair" onsubmit="if(this.dataset.sent)return false;this.dataset.sent=1;this.querySelector('button').disabled=true">
<p><label>Code from your Mac<br><input name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" value="${esc(prefill)}" required autofocus></label></p>
<p><label>Name for this device<br><input name="name" maxlength="40" placeholder="iPhone"></label></p>
<p><button>Pair</button></p>
</form>`), status);
}

export async function claim(req, env, url) {
  // a form post from this page only
  const origin = req.headers.get("origin");
  if (origin && origin !== url.origin) return new Response("Forbidden", { status: 403 });
  if (!on(env)) return claimPage("Pairing is off.", 503);
  // codes are only ever claimed on the device address, where the pass is set
  if (env.DEVICE_ORIGIN && !env.DEVICE_HOST) return Response.redirect(env.DEVICE_ORIGIN + "/pair", 303);

  const form = await req.formData().catch(() => null);
  const code = String(form?.get("code") || "").trim();
  const name = String(form?.get("name") || "").trim().replace(/[\u0000-\u001f\u007f]/g, "").slice(0, 40) || "Device";
  const bad = () => claimPage("That code didn't work. Ask your Mac for a new one.", 403);
  if (!/^\d{6}$/.test(code)) return bad();

  const obj = await env.MAIN.get(PENDING);
  if (!obj) return bad();
  const p = await obj.json();
  if (p.tries >= MAX_TRIES || !(p.exp > Date.now())) return bad();
  const right = same(await sha(code), p.hash);

  // the same right code sent again (iPhone autofill or a double tap sends the form twice and keeps only the
  // last answer): hand back the pass of the device the first send paired, while the code is still live
  if (p.used) return right && p.device ? passTo(env, p.device) : bad();

  const id = hex(crypto.getRandomValues(new Uint8Array(16)));
  const next = right ? { ...p, used: true, device: id } : { ...p, tries: p.tries + 1 };
  // conditional write: of two claims racing on the same code, one wins
  const won = await env.MAIN.put(PENDING, JSON.stringify(next), { onlyIf: { etagMatches: obj.etag } });
  if (!won) return right ? claim(req2(req, code, name), env, url) : bad();
  if (!right) return bad();

  const now = Date.now();
  await env.MAIN.put(DEVICE(id), JSON.stringify({ id, name, created: now, seen: 0, confirmed: 0, revoked: false }));
  return passTo(env, id);
}

// a racing second send re-reads the code (the form body is already consumed)
function req2(req, code, name) {
  return new Request(req.url, { method: "POST", headers: req.headers, body: new URLSearchParams({ code, name }) });
}

async function passCookie(env, id) {
  const value = id + "." + FOREVER + "." + (await hmac(env, id + "." + FOREVER));
  return `${COOKIE}=${value}; Path=/; Max-Age=${COOKIE_DAYS * 86400}; Secure; HttpOnly; SameSite=Lax`;
}

async function passTo(env, id) {
  // a plain 200 page carries the pass (some browsers drop a cookie set on a redirect), then goes to Main
  const res = page(shell("Paired", `<p>This device is paired.</p><p><a id="go" href="/main/">Open Main</a></p>
<script>setTimeout(function(){location.replace("/main/")},400)</script>`));
  res.headers.append("set-cookie", await passCookie(env, id));
  return res;
}

// ---------- the list, with Revoke (owner only) ----------

async function listDevices(env) {
  const out = [];
  let cursor;
  do {
    const l = await env.MAIN.list({ prefix: ".pair/devices/", cursor });
    for (const o of l.objects) {
      const d = await (await env.MAIN.get(o.key))?.json();
      if (d && d.confirmed) out.push(d);
    }
    cursor = l.truncated ? l.cursor : undefined;
  } while (cursor);
  return out.sort((a, b) => b.created - a.created);
}

export async function devicesPage(env) {
  const rows = (await listDevices(env))
    .map((d) => `<li><b>${esc(d.name)}</b><br>paired ${new Date(d.created).toISOString().slice(0, 10)}, last seen ${new Date(d.seen).toISOString().slice(0, 16).replace("T", " ")} UTC<br>${
      d.revoked ? "<i>Revoked</i>" : `<button data-id="${d.id}">Revoke</button>`
    }</li>`)
    .join("");
  return page(shell("Paired devices", `
<ul>${rows || "<li>None yet.</li>"}</ul>
<p><a href="/main/pair">Pair a Device</a></p>
<script>
for (const b of document.querySelectorAll("button[data-id]")) b.onclick = async () => {
  await fetch("/main/api/devices/" + b.dataset.id + "/revoke", { method: "POST" });
  location.reload();
};
</script>`));
}

export async function revoke(env, id) {
  if (!/^[0-9a-f]{32}$/.test(id)) return new Response("Not found", { status: 404 });
  const obj = await env.MAIN.get(DEVICE(id));
  if (!obj) return new Response("Not found", { status: 404 });
  const d = await obj.json();
  d.revoked = true;
  d.revokedAt = Date.now();
  await env.MAIN.put(DEVICE(id), JSON.stringify(d));
  return Response.json({ ok: true });
}

function shell(title, body) {
  return `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark"><title>${esc(title)}</title>
<style>body{margin:0 auto;max-width:28rem;padding:2rem 1rem;background:#1c1c1e;color:#fff;font:20px/1.5 -apple-system,BlinkMacSystemFont,sans-serif}
h1{font-size:1.4rem}.code{font:600 3rem ui-monospace,monospace;letter-spacing:.3em}a,button{color:#0a84ff;font:inherit}
button{background:none;border:1px solid #0a84ff;border-radius:10px;padding:.4rem 1rem}input{font:inherit;width:100%;padding:.4rem;border-radius:8px;border:1px solid #555;background:#2c2c2e;color:#fff}
ul{list-style:none;padding:0}li{margin:0 0 1rem}.msg{color:#ffd60a}</style>
<h1>${esc(title)}</h1>${body}`;
}
