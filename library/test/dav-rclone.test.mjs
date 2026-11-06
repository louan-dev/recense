// The real rclone (webdav backend, nextcloud vendor) against the built Worker in Miniflare, as Gallery.app and
// Windows use it: list, upload (one request, and in chunks past the size of one), overwrite, rename, delete.
// Skipped when rclone isn't installed. Run with `npm test` (it builds first).

import { Miniflare } from "miniflare";
import { readdirSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { webcrypto as crypto, randomBytes, createHash } from "node:crypto";
import { execFile, spawnSync } from "node:child_process";
import { promisify } from "node:util";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";

const RCLONE = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"].find((p) => spawnSync(p, ["version"]).status === 0);
if (!RCLONE) {
  console.log("skip dav-rclone: rclone not installed");
  process.exit(0);
}

const BUILD = new URL("../.test-build/", import.meta.url).pathname;
const TEAM = "team.cloudflareaccess.com";
const AUD = "test-aud";
const CLIENT = "client-id.access";

const keys = await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
  true,
  ["sign", "verify"]
);
const jwk = { ...(await crypto.subtle.exportKey("jwk", keys.publicKey)), kid: "k1", alg: "RS256" };
const b64 = (x) => Buffer.from(x).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const data = b64(JSON.stringify({ alg: "RS256", kid: "k1" })) + "." + b64(JSON.stringify({ aud: [AUD], iss: "https://" + TEAM, exp: now + 3600, iat: now, common_name: CLIENT }));
const serviceJwt = data + "." + b64(new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", keys.privateKey, new TextEncoder().encode(data))));

const mf = new Miniflare({
  modules: [
    { type: "ESModule", path: BUILD + "worker.js" },
    ...readdirSync(BUILD).filter((f) => /\.(css|js)$/.test(f) && f !== "worker.js").map((f) => ({ type: "Text", path: BUILD + f })),
  ],
  compatibilityDate: "2026-08-01",
  port: 0,
  r2Buckets: { PUBLIC: "gallery-public-test", MAIN: "gallery-main-test", KEEP: "recense-keep-test", TMP: "gallery-tmp-test" },
  bindings: { ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD, OWNER_EMAIL: "owner@example.com", SERVICE_CLIENT_ID: CLIENT },
  outboundService: (req) => (new URL(req.url).pathname === "/cdn-cgi/access/certs" ? Response.json({ keys: [jwk] }) : new Response("offline", { status: 503 })),
});
const origin = (await mf.ready).toString().replace(/\/$/, "");
const MAIN = await mf.getR2Bucket("MAIN");
await MAIN.put("files/R/.folder-0000000000000000", "");

// a remote made of environment variables only, like the temporary ones used against the live Worker
const env = {
  ...process.env,
  RCLONE_CONFIG: "/dev/null",
  RCLONE_CONFIG_G_TYPE: "webdav",
  RCLONE_CONFIG_G_URL: origin + "/main/nc/dav/files/owner/",
  RCLONE_CONFIG_G_VENDOR: "nextcloud",
  RCLONE_CONFIG_G_NEXTCLOUD_CHUNK_SIZE: "10M",
  RCLONE_CONFIG_G_HEADERS: "cf-access-jwt-assertion," + serviceJwt,
};
// async: Miniflare answers the Access certs fetch from this process, so a blocking call would starve it
const rc = async (...args) => (await promisify(execFile)(RCLONE, [...args, "--retries", "1", "--timeout", "30s", "-q"], { env, encoding: "utf8" })).stdout;
const sha = (b) => createHash("sha256").update(b).digest("hex");

let passed = 0;
const test = async (name, fn) => {
  try {
    await fn();
    passed++;
    console.log("ok   " + name);
  } catch (e) {
    console.log("FAIL " + name + "\n     " + ((e && (e.stderr || e.message)) || e));
    process.exitCode = 1;
  }
};

const dir = mkdtempSync(join(tmpdir(), "dav-rclone-"));

await test("rclone nextcloud: small file in one PUT, listed, read back, overwritten (old one to the trash)", async () => {
  writeFileSync(join(dir, "a.txt"), "one");
  await rc("copyto", join(dir, "a.txt"), "G:R/a.txt");
  assert.match(await rc("lsf", "G:R"), /^a\.txt$/m);
  assert.equal(await rc("cat", "G:R/a.txt"), "one");
  writeFileSync(join(dir, "a.txt"), "two!");
  await rc("copyto", join(dir, "a.txt"), "G:R/a.txt");
  assert.equal(await (await MAIN.get("files/R/a.txt")).text(), "two!");
  assert.ok((await MAIN.list({ prefix: "trash/" })).objects.some((o) => o.key.includes("/R/a.txt@")));
});

await test("rclone nextcloud: 25 MB in 10 MB chunks arrives whole, no chunks left behind", async () => {
  const big = randomBytes(25 * 1024 * 1024);
  writeFileSync(join(dir, "big.bin"), big);
  await rc("copyto", join(dir, "big.bin"), "G:R/big.bin");
  const got = await MAIN.get("files/R/big.bin");
  assert.equal(got.size, big.length);
  assert.equal(sha(Buffer.from(await got.arrayBuffer())), sha(big));
  assert.equal((await MAIN.list({ prefix: ".uploads/" })).objects.length, 0);
  assert.match(await rc("lsl", "G:R"), /26214400 .* big\.bin/);
});

await test("rclone nextcloud: rename and delete (to the trash)", async () => {
  await rc("moveto", "G:R/a.txt", "G:R/b.txt");
  assert.equal(await MAIN.head("files/R/a.txt"), null);
  assert.equal(await (await MAIN.get("files/R/b.txt")).text(), "two!");
  await rc("deletefile", "G:R/b.txt");
  assert.equal(await MAIN.head("files/R/b.txt"), null);
  assert.ok((await MAIN.list({ prefix: "trash/" })).objects.some((o) => o.key.endsWith("/R/b.txt")));
});

rmSync(dir, { recursive: true, force: true });
console.log(passed + " passed");
await mf.dispose();
