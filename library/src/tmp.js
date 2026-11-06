// SPEC 42: downloads go through a temporary, self-deleting R2 bucket (binding TMP).
//
//   PUT /main/api/tmp?name=<file name>   the owner sends bytes (a baked download, a zip, an export)
//   PUT /main/api/tmp?path=<main path>   or copies one Main file across, server side
//       → { url: "/t/<id>/<name>", expires }   a link anyone holding it can download until it expires
//   GET /t/<id>/<name>                   the file, always as an attachment
//
// The id is 128 random bits, so the link is the key. Objects die three ways, whichever comes first:
//   1. the bucket's lifecycle rule (the real self-delete; set up once, see below),
//   2. a GET after the expiry deletes it and answers 404,
//   3. the nightly cron (tmpSweep) deletes anything past its expiry.
// Without a TMP binding every route here answers 503, and nothing else in the Worker changes.
//
// One-time setup (owner, NOT run by the code; it changes Cloudflare config):
//   npx wrangler r2 bucket create gallery-tmp
//   npx wrangler r2 bucket lifecycle add gallery-tmp expire-tmp-1d tmp/ --expire-days 1 --force
//   npx wrangler r2 bucket lifecycle add gallery-tmp abort-mpu-1d --abort-multipart-days 1 --force
//   npx wrangler r2 bucket lifecycle list gallery-tmp        # check it took
// Keys are tmp/<id>/<name>: the expire rule is scoped to tmp/ only (owner 2026-10-27). The lifecycle rule works in whole days, so TTL_MS below should stay at or under it.

import { MIME_BY_EXT, IMG_BY_EXT, cleanPath, jsonResponse, notice, serveObject } from "./common.js";

export const TTL_MS = 24 * 3600 * 1000;
const MAX_BYTES = 5e9; // R2's limit for one PUT
const FILES = "files/"; // Main's file prefix (main.js)
const PREFIX = "tmp/"; // every key lives under tmp/, the only prefix the lifecycle rule expires

const off = () => new Response("Temporary downloads aren't set up", { status: 503 });

// A file name safe for a URL segment and a content-disposition: no slashes, controls or leading dots.
export function tmpName(s) {
  const n = String(s || "")
    .replace(/[\u0000-\u001f\u007f/\\]+/g, " ")
    .replace(/^[.\s]+/, "")
    .trim()
    .slice(0, 200);
  return n || "download";
}

const newId = () => [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, "0")).join("");

const typeOf = (name) => {
  const ext = (name.split(".").pop() || "").toLowerCase();
  return MIME_BY_EXT[ext] || IMG_BY_EXT[ext] || "application/octet-stream";
};

// PUT /main/api/tmp (owner only: worker.js routes it inside /main/api/, after the same-site check)
export async function tmpPut(req, env, url) {
  if (!env.TMP) return off();

  const rel = url.searchParams.get("path");
  let body, name, type, size;

  if (rel != null) {
    const clean = cleanPath(rel);
    if (!clean) return new Response("Bad file path", { status: 400 });
    const obj = await env.MAIN.get(FILES + clean);
    if (!obj) return new Response("Not found", { status: 404 });
    name = tmpName(url.searchParams.get("name") || clean.split("/").pop());
    type = (obj.httpMetadata && obj.httpMetadata.contentType) || typeOf(name);
    body = obj.body;
    size = obj.size;
  } else {
    size = Number(req.headers.get("content-length"));
    if (size > MAX_BYTES) return new Response("Too large", { status: 413 });
    body = req.body;
    if (!(size > 0) && body) {
      // no length (chunked): R2 needs one, so read it in; browsers send a length for a Blob
      body = await req.arrayBuffer();
      size = body.byteLength;
    }
    if (!body || !(size > 0)) return new Response("Empty body", { status: 400 });
    if (size > MAX_BYTES) return new Response("Too large", { status: 413 });
    name = tmpName(url.searchParams.get("name"));
    type = (req.headers.get("content-type") || "").split(";")[0].trim() || typeOf(name);
  }

  const id = newId();
  const expires = Date.now() + TTL_MS;

  await env.TMP.put(PREFIX + id + "/" + name, body, {
    httpMetadata: { contentType: type },
    customMetadata: { expires: String(expires) },
  });

  return jsonResponse({ ok: true, url: "/t/" + id + "/" + encodeURIComponent(name), expires, size });
}

const expiredAt = (obj) => Number((obj.customMetadata || {}).expires) || obj.uploaded.getTime() + TTL_MS;

// GET /t/<id>/<name>
export async function tmpGet(req, env, ctx, url, id, encodedName) {
  if (!env.TMP) return off();

  let name;
  try {
    name = decodeURIComponent(encodedName);
  } catch (e) {
    return notice("Link not found", 404);
  }
  if (name !== tmpName(name)) return notice("Link not found", 404);

  const key = PREFIX + id + "/" + name;
  let obj;
  try {
    obj = await env.TMP.get(key, { range: req.headers });
  } catch (e) {
    return new Response("Bad range", { status: 416 });
  }
  if (!obj) return notice("This download has expired", 404);

  if (expiredAt(obj) <= Date.now()) {
    const gone = env.TMP.delete(key).catch(() => {});
    if (ctx && ctx.waitUntil) ctx.waitUntil(gone);
    return notice("This download has expired", 404);
  }

  const dl = new URL(url);
  dl.searchParams.set("dl", "1"); // always an attachment
  const r = serveObject(req, dl, obj, name, typeOf(name));
  r.headers.set("cache-control", "private, no-store");
  r.headers.set("x-robots-tag", "noindex");
  return r;
}

// Nightly: delete whatever outlived its expiry (a backstop for the lifecycle rule).
export async function tmpSweep(env) {
  if (!env.TMP) return;
  const now = Date.now();
  let cursor;
  do {
    const page = await env.TMP.list({ prefix: PREFIX, cursor, include: ["customMetadata"] });
    const dead = page.objects.filter((o) => expiredAt(o) <= now).map((o) => o.key);
    if (dead.length) await env.TMP.delete(dead);
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
}
