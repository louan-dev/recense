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
