// Pairing tests: a signed-in Mac mints a code, a phone claims it and gets a device cookie that
// opens /main until it is revoked. Run with `npm test` (it builds first).

import { Miniflare } from "miniflare";
import { readdirSync } from "node:fs";
import { webcrypto as crypto } from "node:crypto";
import assert from "node:assert/strict";

const BUILD = new URL("../.test-build/", import.meta.url).pathname;
const TEAM = "team.cloudflareaccess.com";
const AUD = "test-aud";
const OWNER = "owner@example.com";
const ORIGIN = "http://gallery.test";
const SECRET = "x".repeat(40);

const keys = await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
  true, ["sign", "verify"]
);
const jwk = { ...(await crypto.subtle.exportKey("jwk", keys.publicKey)), kid: "k1", alg: "RS256" };
const b64 = (x) => Buffer.from(x).toString("base64url");
async function jwt(claims) {
  const now = Math.floor(Date.now() / 1000);
  const data = b64(JSON.stringify({ alg: "RS256", kid: "k1" })) + "." + b64(JSON.stringify({ aud: [AUD], iss: "https://" + TEAM, exp: now + 600, ...claims }));
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", keys.privateKey, new TextEncoder().encode(data));
  return data + "." + b64(new Uint8Array(sig));
}
const ownerJwt = await jwt({ email: OWNER });

const textModules = readdirSync(BUILD).filter((f) => f !== "worker.js" && !f.endsWith(".map"));
function make(bindings) {
  return new Miniflare({
    modules: [{ type: "ESModule", path: BUILD + "worker.js" }, ...textModules.map((f) => ({ type: "Text", path: BUILD + f }))],
    compatibilityDate: "2026-08-01",
    r2Buckets: { PUBLIC: "p", MAIN: "m", KEEP: "k", TMP: "t", ARCHIVE: "a" },
    bindings: { ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD, OWNER_EMAIL: OWNER, SERVICE_CLIENT_ID: "mac-id.access", ...bindings },
    outboundService: (r) => new URL(r.url).pathname === "/cdn-cgi/access/certs" ? Response.json({ keys: [jwk] }) : new Response("offline", { status: 503 }),
  });
}

const mf = make({ PAIR_SECRET: SECRET });
const MAIN = await mf.getR2Bucket("MAIN");
const go = (path, init = {}) => mf.dispatchFetch(ORIGIN + path, { redirect: "manual", ...init });
const asOwner = (path, init = {}) => go(path, { ...init, headers: { "cf-access-jwt-assertion": ownerJwt, origin: ORIGIN, ...(init.headers || {}) } });
const tokenJwt = await jwt({ common_name: "mac-id.access" });
const mint = async () => (await (await asOwner("/main/api/pair", { method: "POST" })).json()).code;
const claim = (code, name = "iPhone") => go("/pair", { method: "POST", headers: { origin: ORIGIN }, body: new URLSearchParams({ code, name }) });
const cookieOf = (r) => (r.headers.get("set-cookie") || "").split(";")[0];
const asDevice = (c, path = "/main/api/whoami") => go(path, { headers: { cookie: c } });
let n = 0;
const ok = (name) => console.log("ok " + ++n + " " + name);

// nobody can mint
assert.equal((await go("/main/api/pair", { method: "POST", headers: { origin: ORIGIN } })).status, 404); ok("mint needs the owner");
// the claim page is public
assert.equal((await go("/pair")).status, 200); ok("claim page is public");
{ const html = await (await go("/pair?code=123456")).text();
  assert.match(html, /name="code"[^>]*value="123456"/); ok("?code= fills the box");
  assert.doesNotMatch(await (await go("/pair?code=12<script>")).text(), /value="12/); ok("a bad ?code= is ignored"); }

// the Mac mints with its service token alone (chau/pair-this-mac.zsh): no email, no browser sign-in
{ const r = await go("/main/api/pair", { method: "POST", headers: { "cf-access-jwt-assertion": tokenJwt, "x-gallery": "1" } });
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.match(j.code, /^\d{6}$/);
  assert.equal((await claim(j.code, "Mac")).status, 200); ok("service token mints a code that a device claims (no email)"); }
const strangerToken = await jwt({ common_name: "not-mine.access" });
assert.equal((await go("/main/api/pair", { method: "POST", headers: { "cf-access-jwt-assertion": strangerToken, "x-gallery": "1" } })).status, 404); ok("another service token cannot mint");

// happy path
let code = await mint();
assert.match(code, /^\d{6}$/);
let r = await claim(code);
assert.equal(r.status, 200);
const dev = cookieOf(r);
assert.match(r.headers.get("set-cookie"), /HttpOnly; SameSite=Lax/);
assert.equal((await asDevice(dev)).status, 200); ok("claimed device opens /main");
assert.equal((await go("/main/api/whoami")).status, 404); ok("no cookie stays 404");

// the check page names the failing step
assert.match(await (await go("/pair/check")).text(), /No pairing pass/);
assert.match(await (await go("/pair/check", { headers: { cookie: dev } })).text(), /All checks pass/);
assert.match(await (await go("/pair/check", { headers: { cookie: dev.slice(0, -4) + "0000" } })).text(), /signature is wrong/); ok("check page names the step");

// Regression guard: iPhone sends the form twice and keeps only the second answer
r = await claim(code);
assert.equal(r.status, 200);
assert.equal(cookieOf(r).slice(5).split(".")[0], dev.slice(5).split(".")[0]); ok("same right code again: same device's pass");
assert.equal((await asDevice(cookieOf(r))).status, 200); ok("repeat pass opens /main");
assert.equal((await claim(String((Number(code) + 1) % 1e6).padStart(6, "0"))).status, 403); ok("used code: a wrong guess still refused");

// wrong guesses kill the code
code = await mint();
const wrong = String((Number(code) + 1) % 1e6).padStart(6, "0");
for (let i = 0; i < 5; i++) assert.equal((await claim(wrong)).status, 403);
assert.equal((await claim(code)).status, 403); ok("5 wrong guesses kill the code");

// expiry
code = await mint();
const p = await (await MAIN.get(".pair/pending.json")).json();
await MAIN.put(".pair/pending.json", JSON.stringify({ ...p, exp: Date.now() - 1 }));
assert.equal((await claim(code)).status, 403); ok("expired code refused");

// cross-site claim
assert.equal((await go("/pair", { method: "POST", headers: { origin: "https://evil.test" }, body: new URLSearchParams({ code: "000000" }) })).status, 403); ok("cross-site claim refused");

// forged and tampered cookies
const [id, exp, sig] = dev.slice(5).split(".");
assert.equal((await asDevice(`gdev=${id}.${exp}.${"0".repeat(64)}`)).status, 404); ok("forged signature refused");
assert.equal((await asDevice(`gdev=${id}.${Number(exp) + 1000}.${sig}`)).status, 404); ok("extended expiry refused");
assert.equal((await asDevice(`gdev=${"a".repeat(32)}.${exp}.${sig}`)).status, 404); ok("other id refused");

// a paired device stays paired: the pass never expires by date, and the cookie is renewed for 400 days
assert.equal(exp, "9999999999999");
assert.match(r.headers.get("set-cookie"), /Max-Age=34560000/); ok("pass never expires by date; cookie lasts 400 days");
const otherJwt = await jwt({ email: "other@example.com" });
const wrongAcct = await go("/main/api/whoami", { headers: { "cf-access-jwt-assertion": otherJwt, cookie: dev } });
assert.equal(wrongAcct.status, 200); ok("a wrong-account Access session does not hide a valid pass (regression: 'This account can't open Main')");
assert.equal((await go("/main/api/whoami", { headers: { "cf-access-jwt-assertion": otherJwt } })).status, 404); ok("wrong account without a pass: still refused");
const hk = await crypto.subtle.importKey("raw", new TextEncoder().encode(SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
const old = Date.now() + 90 * 864e5;
const oldSig = Buffer.from(await crypto.subtle.sign("HMAC", hk, new TextEncoder().encode(id + "." + old))).toString("hex");
const renewed = await asDevice(`gdev=${id}.${old}.${oldSig}`);
assert.equal(renewed.status, 200);
assert.match(renewed.headers.get("set-cookie") || "", new RegExp(`gdev=${id}\\.9999999999999\\.[0-9a-f]{64}; .*Max-Age=34560000`)); ok("an old 90-day pass is swapped for a never-expiring one on use");

// devices list and revoke
// a claimed device that never came back is not listed
code = await mint(); const ghost = await claim(code, "Ghost");
assert.doesNotMatch(await (await asOwner("/main/devices")).text(), /Ghost/); ok("unconfirmed device not listed");
const list = await (await asOwner("/main/devices")).text();
assert.match(list, /iPhone/); ok("devices page lists it");
assert.equal((await go(`/main/api/devices/${id}/revoke`, { method: "POST", headers: { cookie: dev } })).status, 403); ok("revoke needs same-site");
assert.equal((await asOwner(`/main/api/devices/${id}/revoke`, { method: "POST" })).status, 200);
assert.equal((await asDevice(dev)).status, 404); ok("revoked device refused");

// the code never stored in the clear
assert.ok(!JSON.stringify(await (await MAIN.get(".pair/pending.json")).json()).includes(code)); ok("code stored only as hash");

await mf.dispose();

// no secret: pairing off, cookies refused
const off = make({});
const offOwner = (path, init = {}) => off.dispatchFetch(ORIGIN + path, { ...init, headers: { "cf-access-jwt-assertion": ownerJwt, origin: ORIGIN } });
assert.equal((await offOwner("/main/api/pair", { method: "POST" })).status, 503);
assert.equal((await off.dispatchFetch(ORIGIN + "/main/api/whoami", { headers: { cookie: dev } })).status, 404); ok("no PAIR_SECRET: off");
await off.dispose();

// the main address sends phones to the device address and names it on the Mac's page
const two = make({ PAIR_SECRET: SECRET, DEVICE_ORIGIN: "https://dev.test" });
let t = await two.dispatchFetch(ORIGIN + "/pair", { redirect: "manual" });
assert.equal(t.status, 302); assert.equal(t.headers.get("location"), "https://dev.test/pair");
t = await two.dispatchFetch(ORIGIN + "/main/pair", { headers: { "cf-access-jwt-assertion": ownerJwt } });
assert.match(await t.text(), /https:\/\/dev\.test\/pair/); ok("main address points phones at the device address");
t = await two.dispatchFetch(ORIGIN + "/pair", { method: "POST", redirect: "manual", headers: { origin: ORIGIN }, body: new URLSearchParams({ code: "123456" }) });
assert.equal(t.status, 303); ok("main address never claims a code");
await two.dispose();
// the device address serves the claim page itself
const dv = make({ PAIR_SECRET: SECRET, DEVICE_ORIGIN: "https://dev.test", DEVICE_HOST: "1" });
assert.equal((await dv.dispatchFetch("https://dev.test/pair")).status, 200); ok("device address serves /pair");
await dv.dispose();

console.log("pair: ALL OK");
