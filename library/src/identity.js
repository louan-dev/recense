// Guest identity for invites (notes 47): the invitation, the guest and the calendar event are separate things.
//
// The invitation (invites/<hash>.json, invite.js) says who may claim a name in a folder until when.
// The guest (guests/<gid>.json) is that person, once claimed: one id, the invitation's name (never editable),
// an optional verified email and any passkeys. Claiming is a compare-and-swap on the invitation's ETag, so one
// invitation makes exactly one guest. A claimed link no longer opens on its own: the browser needs a session.
// Sessions (sessions/<gid>/<sha256>.json) are 90-day HttpOnly cookies, one per device; revoking the invitation
// or signing out everywhere deletes them all, and every request re-checks the invitation and the guest.
// New devices sign in by passkey (WebAuthn, iCloud Keychain or any provider), an emailed one-time link (needs
// the EMAIL send_email binding and EMAIL_FROM), or a one-time link made on a device already signed in.
// One-time codes (authcodes/<sha256>.json) last 15 minutes and are spent by a compare-and-swap, so a replay fails.
// The calendar event (/m/<token>/invite.ics) is generated from the invitation itself, so its end is the real expiry.
// Everything lives in the private MAIN bucket beside the invitations; no new database, WebDAV has no part.

import { hasDB, shareGet, shareClaim } from "./d1.js";
import { esc, jsonResponse, page } from "./common.js";

const GUESTS = "guests/";
const SESSIONS = "sessions/";
const CODES = "authcodes/";
const CHALLENGES = "challenges/";
const SESSION_TTL = 90 * 86400;
const CODE_TTL = 15 * 60 * 1000;
const CHALLENGE_TTL = 5 * 60 * 1000;
const SENDS_PER_HOUR = 5;
const COOKIE_RE = /(?:^|;\s*)gs=([0-9a-f]{32})\.([A-Za-z0-9_-]{43})(?:;|$)/;
const CODE_RE = /^[A-Za-z0-9_-]{43}$/;
const EMAIL_RE = /^[^\s@<>"]{1,64}@[^\s@<>"]{1,190}\.[A-Za-z]{2,}$/;
const JSON_MD = { httpMetadata: { contentType: "application/json" } };

const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
const sha = async (s) => hex(await crypto.subtle.digest("SHA-256", typeof s === "string" ? new TextEncoder().encode(s) : s));
const b64u = (bytes) => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb64u = (s) => Uint8Array.from(atob(String(s).replace(/-/g, "+").replace(/_/g, "/") + "===".slice((String(s).length + 3) % 4)), (c) => c.charCodeAt(0));
const secret = () => b64u(crypto.getRandomValues(new Uint8Array(32)));

async function readJson(env, key) {
  try {
    const o = await env.MAIN.get(key);
    return o ? { v: await o.json(), etag: o.etag } : null;
  } catch (e) {
    return null;
  }
}

export const emailOn = (env) => !!(env.EMAIL && env.EMAIL_FROM);

// ---------- guests and sessions ----------

export async function readGuest(env, gid) {
  if (!/^[0-9a-f]{32}$/.test(String(gid || ""))) return null;
  const r = await readJson(env, GUESTS + gid + ".json");
  return r && !r.v.revoked ? r.v : null;
}

const putGuest = (env, g) => env.MAIN.put(GUESTS + g.gid + ".json", JSON.stringify(g), JSON_MD);

// The guest this browser is signed in as for this invitation, or null.
export async function sessionGuest(req, env, inv) {
  const m = COOKIE_RE.exec(req.headers.get("cookie") || "");
  if (!m || !inv.guest || m[1] !== inv.guest) return null;
  const s = await readJson(env, SESSIONS + m[1] + "/" + (await sha(m[2])) + ".json");
  if (!s || s.v.expires <= Date.now()) return null;
  return readGuest(env, m[1]);
}

async function newSession(env, gid, base) {
  const s = secret();
  await env.MAIN.put(SESSIONS + gid + "/" + (await sha(s)) + ".json", JSON.stringify({ created: Date.now(), expires: Date.now() + SESSION_TTL * 1000 }), JSON_MD);
  return `gs=${gid}.${s}; Path=${base}; Max-Age=${SESSION_TTL}; HttpOnly; Secure; SameSite=Lax`;
}

// Every session of a guest ends, on every device.
export async function endSessions(env, gid) {
  let cursor;
  do {
    const r = await env.MAIN.list({ prefix: SESSIONS + gid + "/", cursor });
    if (r.objects.length) await env.MAIN.delete(r.objects.map((o) => o.key));
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);
}

async function countSessions(env, gid) {
  let n = 0, cursor;
  do {
    const r = await env.MAIN.list({ prefix: SESSIONS + gid + "/", cursor });
    n += r.objects.length;
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);
  return n;
}

// The invitation is revoked: its guest can never sign in again, whatever email or passkey they hold.
export async function revokeGuest(env, gid) {
  const r = gid && (await readJson(env, GUESTS + gid + ".json"));
  if (r) await env.MAIN.put(GUESTS + gid + ".json", JSON.stringify({ ...r.v, revoked: Date.now() }), JSON_MD);
  if (gid) await endSessions(env, gid);
}

// For the owner's list: what became of an invitation's guest.
export async function guestStatus(env, inv) {
  if (!inv.guest) return { claimed: false };
  const g = await readGuest(env, inv.guest);
  if (!g) return { claimed: true, revoked: true };
  return { claimed: true, at: g.created, email: g.email || "", passkeys: (g.passkeys || []).length, devices: await countSessions(env, g.gid) };
}

// Claims the invitation for a new guest (first write wins: the invitation's ETag must not have moved).
// -> { guest, cookie } or null when someone else claimed it first.
export async function claim(env, key, base) {
  const gid = hex(crypto.getRandomValues(new Uint8Array(16)));
  let name;
  if (hasDB(env)) {
    // D1 (C1): one conditional UPDATE, so only one claim can win
    const hash = key.slice(8, -5);
    const inv = await shareGet(env, hash);
    if (!inv || inv.guest || !(await shareClaim(env, hash, gid, Date.now()))) return null;
    name = inv.name;
  } else {
    const r = await readJson(env, key);
    if (!r || r.v.guest) return null;
    const ok = await env.MAIN.put(key, JSON.stringify({ ...r.v, guest: gid, claimed: Date.now() }), { ...JSON_MD, onlyIf: { etagMatches: r.etag } });
    if (!ok) return null;
    name = r.v.name;
  }
  const guest = { gid, name, invite: key.slice(8, 24), created: Date.now(), passkeys: [] };
  await putGuest(env, guest);
  return { guest, cookie: await newSession(env, gid, base) };
}

// ---------- one-time codes (email links, "sign in another device") ----------

async function newCode(env, rec) {
  const c = secret();
  await env.MAIN.put(CODES + (await sha(c)) + ".json", JSON.stringify({ ...rec, expires: Date.now() + CODE_TTL }), JSON_MD);
  return c;
}

// Spends a code once: the compare-and-swap means two clicks (or a replay) can't both succeed.
async function spendCode(env, code) {
  if (!CODE_RE.test(code)) return null;
  const key = CODES + (await sha(code)) + ".json";
  const r = await readJson(env, key);
  if (!r || r.v.used || r.v.expires <= Date.now()) return null;
  const ok = await env.MAIN.put(key, JSON.stringify({ ...r.v, used: Date.now() }), { ...JSON_MD, onlyIf: { etagMatches: r.etag } });
  return ok ? r.v : null;
}

async function sendMail(env, to, subject, text) {
  const { EmailMessage } = await import("cloudflare:email");
  const from = env.EMAIL_FROM;
  const raw = [
    `From: Gallery <${from}>`,
    `To: <${to}>`,
    `Subject: ${subject}`,
    `Message-ID: <${hex(crypto.getRandomValues(new Uint8Array(12)))}@${from.split("@")[1]}>`,
    `Date: ${new Date().toUTCString()}`,
    "MIME-Version: 1.0",
    "Content-Type: text/plain; charset=utf-8",
    "",
    text,
  ].join("\r\n");
  await env.EMAIL.send(new EmailMessage(from, to, raw));
}

// ---------- WebAuthn (passkeys): ES256 and RS256, attestation "none" ----------

function cbor(buf) {
  let p = 0;
  const u8 = buf;
  const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
  const len = (ai) => (ai < 24 ? ai : ai === 24 ? u8[p++] : ai === 25 ? ((p += 2), dv.getUint16(p - 2)) : ai === 26 ? ((p += 4), dv.getUint32(p - 4)) : NaN);
  const item = () => {
    const b = u8[p++], mt = b >> 5, n = len(b & 31);
    if (Number.isNaN(n)) throw new Error("cbor");
    if (mt === 0) return n;
    if (mt === 1) return -1 - n;
    if (mt === 2) return u8.slice(p, (p += n));
    if (mt === 3) return new TextDecoder().decode(u8.slice(p, (p += n)));
    if (mt === 4) return Array.from({ length: n }, item);
    if (mt === 5) {
      const m = new Map();
      for (let i = 0; i < n; i++) m.set(item(), item());
      return m;
    }
    if (mt === 7) return n === 20 ? false : n === 21 ? true : null;
    throw new Error("cbor");
  };
  const v = item();
  return { v, end: p };
}

function coseToJwk(m) {
  if (m.get(1) === 2 && m.get(3) === -7 && m.get(-1) === 1) return { alg: -7, jwk: { kty: "EC", crv: "P-256", x: b64u(m.get(-2)), y: b64u(m.get(-3)), ext: true } };
  if (m.get(1) === 3 && m.get(3) === -257) return { alg: -257, jwk: { kty: "RSA", n: b64u(m.get(-1)), e: b64u(m.get(-2)), alg: "RS256", ext: true } };
  throw new Error("Unsupported key");
}

function derToRaw(der) {
  // SEQUENCE { INTEGER r, INTEGER s } -> r||s, 32 bytes each
  let p = 2;
  if (der[1] & 0x80) p += der[1] & 0x7f;
  const int = () => {
    const l = der[p + 1];
    let v = der.slice(p + 2, p + 2 + l);
    p += 2 + l;
    while (v.length > 32 && v[0] === 0) v = v.slice(1);
    const out = new Uint8Array(32);
    out.set(v, 32 - v.length);
    return out;
  };
  const r = int(), s = int(), out = new Uint8Array(64);
  out.set(r);
  out.set(s, 32);
  return out;
}

async function checkClient(cdBytes, type, challenge, origin) {
  const cd = JSON.parse(new TextDecoder().decode(cdBytes));
  if (cd.type !== type || cd.challenge !== challenge || cd.origin !== origin) throw new Error("Bad client data");
}

async function checkAuthData(ad, rpId) {
  if (hex(ad.slice(0, 32)) !== (await sha(rpId))) throw new Error("Wrong site");
  if (!(ad[32] & 1)) throw new Error("No user presence");
  return { flags: ad[32], counter: new DataView(ad.buffer, ad.byteOffset + 33, 4).getUint32(0) };
}

async function newChallenge(env, rec) {
  const c = secret();
  await env.MAIN.put(CHALLENGES + (await sha(c)) + ".json", JSON.stringify({ ...rec, expires: Date.now() + CHALLENGE_TTL }), JSON_MD);
  return c;
}

async function spendChallenge(env, clientDataB64) {
  let c;
  try {
    c = JSON.parse(new TextDecoder().decode(unb64u(clientDataB64))).challenge;
  } catch (e) {
    return null;
  }
  if (!CODE_RE.test(String(c || ""))) return null;
  const key = CHALLENGES + (await sha(c)) + ".json";
  const r = await readJson(env, key);
  if (!r) return null;
  await env.MAIN.delete(key);
  return r.v.expires > Date.now() ? { ...r.v, challenge: c } : null;
}

// ---------- routes: /m/<token>/api/id/… and /m/<token>/auth/<code> ----------

const ok = (body, cookie) => {
  const r = jsonResponse(body);
  if (cookie) r.headers.append("set-cookie", cookie);
  return r;
};
const no = (t, s = 400) => new Response(t, { status: s });

// inv: the live invitation; key: its R2 key; base: "/m/<token>"; me: the signed-in guest or null
export async function identityApi(req, env, url, rest, inv, key, base, me) {
  const method = req.method;
  let b = {};
  if (method === "POST") {
    try {
      b = (await req.json()) || {};
    } catch (e) {
      b = {};
    }
  }

  // GET id/me -> who this browser is, for the page
  if (rest === "/api/id/me" && method === "GET") {
    return ok({ state: me ? "you" : inv.guest ? "signin" : "unclaimed", name: inv.name, email: (me && me.email) || "", passkeys: me ? (me.passkeys || []).length : 0, emailOn: emailOn(env) });
  }

  // POST id/claim -> becomes this invitation's guest (only while nobody has)
  if (rest === "/api/id/claim" && method === "POST") {
    if (me) return ok({ ok: true });
    const c = await claim(env, key, base);
    if (!c) return no("This invitation has already been accepted. Sign in instead.", 409);
    return ok({ ok: true }, c.cookie);
  }

  // POST id/signout { everywhere? }
  if (rest === "/api/id/signout" && method === "POST") {
    if (me && b.everywhere) await endSessions(env, me.gid);
    const m = COOKIE_RE.exec(req.headers.get("cookie") || "");
    if (m && me) await env.MAIN.delete(SESSIONS + me.gid + "/" + (await sha(m[2])) + ".json");
    return ok({ ok: true }, `gs=; Path=${base}; Max-Age=0; HttpOnly; Secure; SameSite=Lax`);
  }

  // POST id/device -> a one-time link that signs another device in as this guest (15 minutes)
  if (rest === "/api/id/device" && method === "POST") {
    if (!me) return no("Sign in first", 401);
    return ok({ url: url.origin + base + "/auth/" + (await newCode(env, { gid: me.gid, kind: "device" })) });
  }

  // POST id/email { email } -> signed in: verify it for this guest; not signed in: a sign-in link if it is theirs.
  // The answer never says whether an address matched.
  if (rest === "/api/id/email" && method === "POST") {
    if (!emailOn(env)) return no("Email sign-in isn’t set up", 503);
    const email = String(b.email || "").trim().toLowerCase();
    if (!EMAIL_RE.test(email)) return no("That doesn’t look like an email address");
    const g = me || (inv.guest && (await readGuest(env, inv.guest)));
    if (!g) return ok({ ok: true });
    const now = Date.now();
    g.sends = (g.sends || []).filter((t) => t > now - 3600e3);
    if (g.sends.length >= SENDS_PER_HOUR) return no("Too many emails. Try again in an hour.", 429);
    const verify = !!me;
    if (verify || g.email === email) {
      g.sends.push(now);
      await putGuest(env, g);
      const link = url.origin + base + "/auth/" + (await newCode(env, { gid: g.gid, kind: verify ? "verify" : "email", email }));
      await sendMail(
        env,
        email,
        verify ? "Confirm your email for the gallery" : "Your sign-in link",
        `Hello ${g.name},\r\n\r\n${verify ? "Confirm this address to sign in to the gallery from your other devices" : "Sign in to the gallery"}:\r\n${link}\r\n\r\nThe link works once, for 15 minutes. If you didn’t ask for it, ignore this email.\r\n`
      );
    }
    return ok({ ok: true });
  }

  const rpId = url.hostname;

  // POST id/passkey/options { mode: "register" | "login" } -> WebAuthn options
  if (rest === "/api/id/passkey/options" && method === "POST") {
    if (b.mode === "register") {
      if (!me) return no("Sign in first", 401);
      const challenge = await newChallenge(env, { gid: me.gid, mode: "register" });
      return ok({
        challenge,
        rp: { id: rpId, name: "Gallery" },
        user: { id: b64u(new TextEncoder().encode(me.gid)), name: me.name, displayName: me.name },
        pubKeyCredParams: [{ type: "public-key", alg: -7 }, { type: "public-key", alg: -257 }],
        authenticatorSelection: { residentKey: "preferred", userVerification: "preferred" },
        excludeCredentials: (me.passkeys || []).map((p) => ({ type: "public-key", id: p.id })),
        attestation: "none",
        timeout: CHALLENGE_TTL,
      });
    }
    const g = inv.guest && (await readGuest(env, inv.guest));
    const challenge = await newChallenge(env, { gid: g ? g.gid : "", mode: "login" });
    return ok({ challenge, rpId, allowCredentials: g ? (g.passkeys || []).map((p) => ({ type: "public-key", id: p.id })) : [], userVerification: "preferred", timeout: CHALLENGE_TTL });
  }

  // POST id/passkey/register { id, clientDataJSON, attestationObject }
  if (rest === "/api/id/passkey/register" && method === "POST") {
    if (!me) return no("Sign in first", 401);
    const ch = await spendChallenge(env, b.clientDataJSON);
    if (!ch || ch.mode !== "register" || ch.gid !== me.gid) return no("Expired. Try again.");
    try {
      await checkClient(unb64u(b.clientDataJSON), "webauthn.create", ch.challenge, url.origin);
      const att = cbor(unb64u(b.attestationObject)).v;
      const ad = att.get("authData");
      const { flags, counter } = await checkAuthData(ad, rpId);
      if (!(flags & 0x40)) throw new Error("No credential");
      const idLen = (ad[53] << 8) | ad[54];
      const credId = b64u(ad.slice(55, 55 + idLen));
      if (credId !== b.id) throw new Error("Credential mismatch");
      const key = coseToJwk(cbor(ad.slice(55 + idLen)).v);
      me.passkeys = (me.passkeys || []).filter((p) => p.id !== credId);
      me.passkeys.push({ id: credId, ...key, counter, created: Date.now() });
      await putGuest(env, me);
      return ok({ ok: true, passkeys: me.passkeys.length });
    } catch (e) {
      return no("Couldn’t add the passkey: " + e.message);
    }
  }

  // POST id/passkey/login { id, clientDataJSON, authenticatorData, signature }
  if (rest === "/api/id/passkey/login" && method === "POST") {
    const ch = await spendChallenge(env, b.clientDataJSON);
    const g = inv.guest && (await readGuest(env, inv.guest));
    if (!ch || ch.mode !== "login" || !g || (ch.gid && ch.gid !== g.gid)) return no("Expired. Try again.");
    const pk = (g.passkeys || []).find((p) => p.id === b.id);
    if (!pk) return no("That passkey isn’t for this invitation", 403);
    try {
      const cd = unb64u(b.clientDataJSON);
      await checkClient(cd, "webauthn.get", ch.challenge, url.origin);
      const ad = unb64u(b.authenticatorData);
      const { counter } = await checkAuthData(ad, rpId);
      if (counter && pk.counter && counter <= pk.counter) throw new Error("Replayed");
      const data = new Uint8Array([...ad, ...new Uint8Array(await crypto.subtle.digest("SHA-256", cd))]);
      const ec = pk.alg === -7;
      const k = await crypto.subtle.importKey("jwk", pk.jwk, ec ? { name: "ECDSA", namedCurve: "P-256" } : { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
      const sig = unb64u(b.signature);
      const good = await crypto.subtle.verify(ec ? { name: "ECDSA", hash: "SHA-256" } : { name: "RSASSA-PKCS1-v1_5" }, k, ec ? derToRaw(sig) : sig, data);
      if (!good) throw new Error("Bad signature");
      if (counter) {
        pk.counter = counter;
        await putGuest(env, g);
      }
      return ok({ ok: true }, await newSession(env, g.gid, base));
    } catch (e) {
      return no("Couldn’t sign in: " + e.message, 403);
    }
  }

  return no("Not found", 404);
}

// GET shows a button (so mail scanners that open links don't spend them); POST spends the code and signs in.
export async function authRoute(req, env, url, code, inv, base) {
  if (req.method === "GET" || req.method === "HEAD") {
    return page(
      shell(
        "Sign in",
        `<h1>${esc(inv.name)}</h1><p>Continue to the gallery on this device.</p><form method="post"><button>Continue</button></form>`
      )
    );
  }
  if (req.method !== "POST") return no("Method not allowed", 405);
  const origin = req.headers.get("origin");
  if (origin && origin !== url.origin) return no("Forbidden", 403);
  const c = await spendCode(env, code);
  const g = c && inv.guest === c.gid && (await readGuest(env, c.gid));
  if (!g) return page(shell("Link expired", `<h1>This link has expired</h1><p>Ask for a new one from the gallery.</p>`), 410);
  if (c.kind === "verify") {
    g.email = c.email;
    await putGuest(env, g);
  }
  const r = new Response(null, { status: 303, headers: { location: base } });
  r.headers.append("set-cookie", await newSession(env, g.gid, base));
  return r;
}

// The page a claimed invitation shows a browser that isn't signed in.
export function signInPage(inv, env) {
  return page(
    shell(
      "Sign in",
      `<h1>${esc(inv.name)}</h1>
<p>This invitation is already in use. Sign in to continue.</p>
<button id="pk">Sign in with a passkey</button>
${emailOn(env) ? `<form id="em"><input type="email" name="email" placeholder="Email" autocomplete="email" required><button>Email me a link</button></form>` : ""}
<p class="s">On a device that’s already signed in, you can also make a one-time link for this one (Devices in the comments).</p>
<p class="s" id="msg" role="status"></p>
<script>
const api = location.pathname.replace(/\\/$/, "") + "/api/id/";
const H = { "content-type": "application/json" };
const say = t => { document.getElementById("msg").textContent = t; };
const u8 = s => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0));
const b64 = b => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
document.getElementById("pk").onclick = async () => {
  try {
    const o = await (await fetch(api + "passkey/options", { method: "POST", headers: H, body: JSON.stringify({ mode: "login" }) })).json();
    const c = await navigator.credentials.get({ publicKey: { ...o, challenge: u8(o.challenge), allowCredentials: o.allowCredentials.map(x => ({ ...x, id: u8(x.id) })) } });
    const r = await fetch(api + "passkey/login", { method: "POST", headers: H, body: JSON.stringify({ id: c.id, clientDataJSON: b64(c.response.clientDataJSON), authenticatorData: b64(c.response.authenticatorData), signature: b64(c.response.signature) }) });
    if (r.ok) location.reload(); else say(await r.text());
  } catch (e) { say("No passkey was used."); }
};
const em = document.getElementById("em");
if (em) em.onsubmit = async e => {
  e.preventDefault();
  const r = await fetch(api + "email", { method: "POST", headers: H, body: JSON.stringify({ email: em.email.value }) });
  say(r.ok ? "If that address belongs to this invitation, a link is on its way." : await r.text());
};
</script>`
    ),
    401
  );
}

function shell(title, body) {
  return `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark"><meta name="darkreader-lock"><title>${esc(title)}</title>
<style>body{margin:0;display:grid;place-items:center;min-height:100vh;background:#1c1c1e;color:#fff;font:15px/1.4 -apple-system,BlinkMacSystemFont,sans-serif}
main{width:min(320px,calc(100vw - 32px));display:grid;gap:12px;text-align:center}h1{font-size:22px;margin:0}p{margin:0;color:#ebebf5cc}.s{font-size:13px;color:#ebebf599}
button,input{font:inherit;border:0;border-radius:12px;padding:12px 14px;width:100%;box-sizing:border-box}button{background:#0a84ff;color:#fff;font-weight:600}
input{background:#2c2c2e;color:#fff;margin-bottom:8px}form{margin:0}</style><main>${body}</main>`;
}

// ---------- the calendar event ----------

const icsText = (s) => String(s).replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
const icsTime = (ms) => new Date(ms).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
// lines over 75 octets go on continuation lines that start with a space (RFC 5545 3.1)
function fold(line) {
  const bytes = new TextEncoder().encode(line);
  if (bytes.length <= 75) return line;
  const out = [];
  let cur = "", n = 0;
  for (const ch of line) {
    const l = new TextEncoder().encode(ch).length;
    if (n + l > (out.length ? 74 : 75)) {
      out.push(cur);
      cur = "";
      n = 0;
    }
    cur += ch;
    n += l;
  }
  out.push(cur);
  return out.join("\r\n ");
}

// A reminder before access ends, sized to how long it lasts; none when the event is too short or already over.
export function alarmBefore(durationMs) {
  const h = 3600e3;
  if (durationMs >= 2 * 24 * h) return "-P1D";
  if (durationMs >= 3 * h) return "-PT1H";
  if (durationMs >= 30 * 60e3) return "-PT10M";
  return null;
}

// inv: the invitation; link: the invitation's own URL. Never the guest's session or an email code.
export function inviteIcs(inv, hashId, link, now = Date.now()) {
  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Gallery//Invitation//EN",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    "BEGIN:VEVENT",
    "UID:invite-" + hashId + "@gallery",
    "DTSTAMP:" + icsTime(now),
    "DTSTART:" + icsTime(inv.created),
    "DTEND:" + icsTime(inv.expires),
    "SUMMARY:Gallery access",
    "DESCRIPTION:" + icsText("Your invitation to the gallery. Open it from the link; access ends when this event does."),
    "LOCATION:" + icsText(link),
    "URL:" + link,
    "STATUS:CONFIRMED",
    "TRANSP:TRANSPARENT",
  ];
  const before = alarmBefore(inv.expires - inv.created);
  if (before && inv.expires > now) {
    lines.push("BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:" + icsText("Gallery access ends soon"), "TRIGGER;RELATED=END:" + before, "END:VALARM");
  }
  lines.push("END:VEVENT", "END:VCALENDAR");
  return lines.map(fold).join("\r\n") + "\r\n";
}
