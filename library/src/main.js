// Main: the owner's permanent library, backed by the MAIN bucket.
//
// Files live under files/<path>, exactly as they are in Gallery/Main on the Mac. rclone puts
// most of them there straight into R2; the page can add and delete files too. Artwork found in
// a file is cached under art/<path>, outside files/, so an rclone sync never sees it or deletes
// it. Deleting moves a file to trash/<date>/<path>, which the bucket empties after 30 days.
//
// The router lets a request in here only when it comes from the owner (see access.js).

import { OWNER, FOLDER_MAX, JUNK, MIME_BY_EXT, IMG_BY_EXT, isAudioish, cleanPath, urlPath, esc, notice, jsonResponse, serveObject } from "./common.js";
import { extractArt } from "./art.js";
import { galleryPage } from "./page/gallery.js";

const FILES = "files/";
const ART = "art/";
const TRASH = "trash/";

// a single request body is capped at 100 MB by Cloudflare; bigger files go through the mount
const PAGE_UPLOAD_MAX = 90 * 1024 * 1024;

// GET /main?p=<folder>
export async function mainFolder(env, url) {
  const rel = cleanPath(url.searchParams.get("p"));
  if (rel === null) return notice("Link not found", 404);

  const prefix = FILES + (rel ? rel + "/" : "");
  const folders = [];
  const objs = [];
  let cursor;

  do {
    const r = await env.MAIN.list({
      prefix,
      delimiter: "/",
      include: ["httpMetadata", "customMetadata"],
      cursor,
    });

    folders.push(...(r.delimitedPrefixes || []));
    objs.push(...r.objects);
    cursor = r.truncated && objs.length < FOLDER_MAX ? r.cursor : undefined;
  } while (cursor);

  const byName = (a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" });
  const niceName = (s) => s.replace(/\.[^/.]+$/, (x) => x.toUpperCase());
  /** @type {any[]} */
  const items = [];

  for (const o of objs.slice(0, FOLDER_MAX)) {
    const name = o.key.slice(prefix.length);
    if (!name || JUNK.test(name)) continue;

    const ext = (name.split(".").pop() || "").toLowerCase();
    let type = (o.httpMetadata && o.httpMetadata.contentType) || "";

    if (/^(|application\/octet-stream|binary\/octet-stream)$/.test(type)) {
      type = MIME_BY_EXT[ext] || IMG_BY_EXT[ext] || "application/octet-stream";
    }

    // rclone keeps the file's own modification time here (seconds)
    const mtime = Number((o.customMetadata || {}).mtime);
    const path = o.key.slice(FILES.length);
    const at = "/main/f/" + urlPath(path);

    items.push({
      name: niceName(name),
      sortName: name,
      path,
      type,
      size: o.size,
      taken: mtime > 0 ? Math.round(mtime * 1000) : o.uploaded.getTime(),
      src: at,
      art: isAudioish(type, name) ? at + "?art=1" : null,
    });
  }

  items.sort((a, b) => byName(a.sortName, b.sortName));
  items.forEach((f, i) => {
    f.n = String(i).padStart(5, "0");
    delete f.sortName;
  });

  const subs = folders
    .map((p) => p.slice(prefix.length).replace(/\/$/, ""))
    .filter((x) => x && !JUNK.test(x))
    .sort(byName);

  const here = rel ? rel.split("/") : [];
  const title = here.length ? here[here.length - 1] : "Main";
  const go = (p) => (p ? "/main?p=" + encodeURIComponent(p) : "/main");

  const crumbs = [`<a href="/main">Main</a>`]
    .concat(here.map((x, i) => `<a href="${go(here.slice(0, i + 1).join("/"))}">${esc(x)}</a>`))
    .join("<i>/</i>");

  const links = subs
    .map((x) => `<a class="fd" href="${go((rel ? rel + "/" : "") + x)}">${esc(x)}</a>`)
    .join("");

  const empty =
    !items.length && !subs.length
      ? `<p class="none">${rel ? "This folder is empty." : "Nothing in Main yet."}</p>`
      : "";

  const nav = `<style>
.mainnav{padding:0 16px 14px;font:500 15px -apple-system,BlinkMacSystemFont,sans-serif}
.mainnav .cr{color:rgba(255,255,255,.55);margin-bottom:10px;overflow-wrap:anywhere}
.mainnav .cr a{color:inherit;text-decoration:none}
.mainnav .cr a:last-child{color:#fff}
.mainnav .cr i{font-style:normal;margin:0 6px;opacity:.5}
.mainnav .fs{display:flex;flex-wrap:wrap;gap:8px}
.mainnav .fd{color:#fff;text-decoration:none;padding:8px 12px;border-radius:10px;background:rgba(255,255,255,.08);max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.mainnav .fd:hover{background:rgba(255,255,255,.14)}
.mainnav .none{color:rgba(255,255,255,.55);margin:8px 0 0}
</style>
<nav class="mainnav"><div class="cr">${crumbs}</div>${links ? `<div class="fs">${links}</div>` : ""}${empty}</nav>`;

  return galleryPage(
    {
      id: "main",
      main: true,
      dir: rel,
      uploadMax: PAGE_UPLOAD_MAX,
      owner: OWNER,
      title,
      heading: title,
      zip: title + ".zip",
      exp: 0,
      expected: items.length,
      ready: items.length,
      complete: true,
      items,
    },
    nav
  );
}

// GET /main/f/<path>   (?art=1 for embedded artwork, ?dl=1 to download)
export async function mainFile(req, env, ctx, url, encoded) {
  const rel = cleanPath(encoded, true);
  if (!rel) return notice("Link not found", 404);

  if (url.searchParams.get("art") === "1") return mainArt(env, ctx, rel);

  let obj;

  try {
    obj = await env.MAIN.get(FILES + rel, { range: req.headers });
  } catch (e) {
    return new Response("Bad range", { status: 416 });
  }

  if (!obj) return notice("Link not found", 404);

  const name = rel.split("/").pop();
  const ext = (name.split(".").pop() || "").toLowerCase();

  return serveObject(req, url, obj, name, MIME_BY_EXT[ext] || IMG_BY_EXT[ext]);
}

// Artwork inside a file, read once and kept under art/.
async function mainArt(env, ctx, rel) {
  const none = () =>
    new Response("No artwork", {
      status: 404,
      headers: { "cache-control": "private, max-age=3600" },
    });

  const pic = (body, type) =>
    new Response(body, {
      headers: {
        "content-type": type,
        "cache-control": "private, max-age=3600",
        "x-content-type-options": "nosniff",
      },
    });

  const keep = (p) => {
    if (ctx && ctx.waitUntil) ctx.waitUntil(Promise.resolve(p).catch(() => {}));
  };

  const cached = await env.MAIN.get(ART + rel);

  if (cached) {
    if ((cached.customMetadata || {}).none === "1") return none();
    return pic(cached.body, (cached.httpMetadata && cached.httpMetadata.contentType) || "image/jpeg");
  }

  const head = await env.MAIN.head(FILES + rel);
  const name = rel.split("/").pop();

  if (!head || !isAudioish(head.httpMetadata && head.httpMetadata.contentType, name)) {
    return none();
  }

  let art = null;

  try {
    art = await extractArt(env.MAIN, FILES + rel, head.size);
  } catch (e) {}

  if (!art) {
    keep(env.MAIN.put(ART + rel, new Uint8Array(0), { customMetadata: { none: "1" } }));
    return none();
  }

  const bytes = art.data.slice();

  keep(env.MAIN.put(ART + rel, bytes, { httpMetadata: { contentType: art.mime } }));

  return pic(bytes, art.mime);
}

// PUT /main/api/file?key=<path>&mtime=<ms>   body: the file; a file with the same path is replaced
export async function mainUpload(req, env, url) {
  const rel = cleanPath(url.searchParams.get("key"));
  if (!rel) return new Response("Bad file path", { status: 400 });

  const length = req.headers.get("content-length");
  const size = length === null ? NaN : Number(length);
  if (!Number.isSafeInteger(size) || size > PAGE_UPLOAD_MAX) {
    return new Response("Too big for the browser", { status: 413 });
  }
  if (!req.body) return new Response("Missing file", { status: 400 });

  const contentType = (req.headers.get("content-type") || "application/octet-stream").slice(0, 200);
  const modified = Number(url.searchParams.get("mtime"));
  const mtime = Number.isFinite(modified) && modified > 0 ? Math.floor(modified / 1000) : Math.floor(Date.now() / 1000);

  await env.MAIN.put(FILES + rel, req.body, {
    httpMetadata: { contentType },
    customMetadata: { mtime: String(mtime) },
  });
  await env.MAIN.delete(ART + rel);

  return jsonResponse({ ok: true, key: rel });
}

// DELETE /main/api/file?key=<path>   moves the file to trash/<date>/<path>
export async function mainDelete(env, url) {
  const rel = cleanPath(url.searchParams.get("key"));
  if (!rel) return new Response("Bad file path", { status: 400 });

  const obj = await env.MAIN.get(FILES + rel);
  if (!obj) return new Response("Not found", { status: 404 });

  const day = new Date().toISOString().slice(0, 10);
  const { readable, writable } = new FixedLengthStream(obj.size);
  const copied = obj.body.pipeTo(writable);

  await env.MAIN.put(TRASH + day + "/" + rel, readable, {
    httpMetadata: obj.httpMetadata,
    customMetadata: obj.customMetadata,
  });
  await copied;
  await env.MAIN.delete([FILES + rel, ART + rel]);

  return jsonResponse({ ok: true, key: rel });
}
