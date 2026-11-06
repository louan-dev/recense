// GET /i/<key>   images from Obsidian notes, uploaded by the "S3 Image Sync" plugin to the NOTES_IMAGES bucket.
//
// Public on purpose: Obsidian on the iPhone and iPad can't sign in to Access, so a note's image must load
// without it. Only content-addressed keys are served (the plugin's default template,
// attachments/{ext}/{hash2}/{hash}.{ext}, hash = SHA-256), so nothing can be listed or guessed,
// and a key never changes content, so it caches forever.

const KEY = /^attachments\/([a-z0-9]{1,8})\/([0-9a-f]{2})\/(\2[0-9a-f]{62})\.\1$/;

const TYPES = {
  png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp",
  avif: "image/avif", heic: "image/heic", heif: "image/heif", bmp: "image/bmp", ico: "image/x-icon",
  svg: "image/svg+xml", tif: "image/tiff", tiff: "image/tiff",
};

// PUT /main/api/img?ext=<ext> (or ?name=<file name>, or the Content-Type)   owner only, behind Access.
// "Move Offsite" (Mac + iPhone/iPad Shortcut) sends an image's bytes; it lands under the same key the Obsidian
// plugin would use, so the same picture is stored once. Answers { url, key, sha256, md5, size, existed }:
// the caller checks sha256 against its own copy before it deletes the original.
const MAX = 95 * 1024 * 1024; // Workers take request bodies up to 100 MB

export async function noteImageUpload(req, env, url) {
  if (!env.NOTES_IMAGES) return jsonError("no NOTES_IMAGES bucket", 500);
  const ext = pickExt(url, req.headers.get("content-type"));
  if (!ext) return jsonError("not an image type: pass ?ext=png (or ?name=…)", 415);
  const len = Number(req.headers.get("content-length") || 0);
  if (len > MAX) return jsonError("too large (max 95 MB)", 413);

  const body = await req.arrayBuffer();
  if (!body.byteLength) return jsonError("empty body", 400);
  if (body.byteLength > MAX) return jsonError("too large (max 95 MB)", 413);
  const sha256 = hex(await crypto.subtle.digest("SHA-256", body));
  const key = `attachments/${ext}/${sha256.slice(0, 2)}/${sha256}.${ext}`;

  let obj = await env.NOTES_IMAGES.head(key);
  const existed = !!obj;
  if (!obj) obj = await env.NOTES_IMAGES.put(key, body, { httpMetadata: { contentType: TYPES[ext] } });
  return new Response(JSON.stringify({
    url: url.origin + "/i/" + key, key, sha256, md5: obj.checksums?.md5 ? hex(obj.checksums.md5) : obj.etag,
    size: obj.size, existed,
  }), { status: existed ? 200 : 201, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
}

function pickExt(url, contentType) {
  let e = (url.searchParams.get("ext") || "").toLowerCase().replace(/^\./, "");
  if (!e) e = ((url.searchParams.get("name") || "").match(/\.([A-Za-z0-9]{1,8})$/) || [])[1]?.toLowerCase() || "";
  if (!e && contentType) {
    const t = contentType.split(";")[0].trim().toLowerCase();
    e = t === "image/jpeg" ? "jpg" : Object.keys(TYPES).find((k) => TYPES[k] === t) || "";
  }
  return TYPES[e] ? e : null;
}

const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
const jsonError = (error, status) =>
  new Response(JSON.stringify({ error }), { status, headers: { "Content-Type": "application/json" } });

export async function noteImage(req, env, key) {
  const m = KEY.exec(key);
  const type = m && TYPES[m[1]];
  if (!type || !env.NOTES_IMAGES) return new Response("Not found", { status: 404 });

  const obj = await env.NOTES_IMAGES.get(key, { onlyIf: req.headers });
  if (!obj) return new Response("Not found", { status: 404 });

  const headers = new Headers({
    "Content-Type": type,
    "Cache-Control": "public, max-age=31536000, immutable",
    ETag: obj.httpEtag,
    "X-Content-Type-Options": "nosniff",
    // an SVG opened on its own can't run script on this origin (where /main lives)
    "Content-Security-Policy": "default-src 'none'; img-src data:; style-src 'unsafe-inline'; sandbox",
    "Access-Control-Allow-Origin": "*",
  });
  // onlyIf failed (If-None-Match matched): the object comes back without a body
  if (!("body" in obj)) return new Response(null, { status: 304, headers });
  headers.set("Content-Length", String(obj.size));
  return new Response(req.method === "HEAD" ? null : obj.body, { headers });
}
