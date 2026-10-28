// The archive shelf (docs/architecture.md §10): gallery-archive/chauphan/ shown with the same page and player as Main,
// read-only. Owner only, behind Access like the rest of /main.
//
//   GET /main/archive?p=<folder>[&open=<path>]   a folder, as Main shows one (open: straight onto that file)
//   GET /main/archive/f/<path>                   a file (Range works; ?dl=1 to download)
//   /main/archive/api/…                          the page's API base (G.mainApi): whoami answers, every other read is
//                                                404 and every write is 403. Nothing here writes, whatever a page sends.
//
// Paths are inside chauphan/; the bucket's dot folders (.catalog, .trash, .uploads) are never reachable.

import { OWNER, FOLDER_MAX, JUNK, MIME_BY_EXT, IMG_BY_EXT, cleanPath, urlPath, esc, notice, jsonResponse, serveObject } from "./common.js";
import { galleryPage } from "./page/gallery.js";

const ROOT = "chauphan/";
const MARK = ".folder-";

export async function archive(req, env, ctx, url, path) {
  const read = req.method === "GET" || req.method === "HEAD";
  if (path === "/main/archive/api/whoami" && read) return jsonResponse({ ok: true });
  if (path.startsWith("/main/archive/api/")) return read ? notice("Not here", 404) : new Response("The archive is read-only", { status: 403 });
  if (!read) return new Response("The archive is read-only", { status: 403 });
  if (path.startsWith("/main/archive/f/")) return archiveFile(req, env, url, path.slice("/main/archive/f/".length));
  if (path === "/main/archive" || path === "/main/archive/") return archiveFolder(env, url);
  return notice("Link not found", 404);
}

async function archiveFile(req, env, url, encoded) {
  const rel = cleanPath(encoded, true);
  if (!rel || rel.split("/").some((s) => s.startsWith("."))) return notice("Link not found", 404);
  let obj;
  try {
    obj = req.method === "HEAD" ? await env.ARCHIVE.head(ROOT + rel) : await env.ARCHIVE.get(ROOT + rel, { range: req.headers });
  } catch (e) {
    return new Response("Bad range", { status: 416 });
  }
  if (!obj) return notice("Link not found", 404);
  const name = rel.split("/").pop();
  const ext = (name.split(".").pop() || "").toLowerCase();
  return serveObject(req, url, obj, name, MIME_BY_EXT[ext] || IMG_BY_EXT[ext]);
}

async function archiveFolder(env, url) {
  const raw = url.searchParams.get("p") || "";
  const rel = raw ? cleanPath(raw) : "";
  if (rel === null || (rel && rel.split("/").some((s) => s.startsWith(".")))) return notice("Link not found", 404);
  const prefix = ROOT + (rel ? rel + "/" : "");

  const folders = [];
  const objs = [];
  let cursor;
  do {
    const r = await env.ARCHIVE.list({ prefix, delimiter: "/", include: ["httpMetadata", "customMetadata"], cursor });
    folders.push(...(r.delimitedPrefixes || []));
    objs.push(...r.objects);
    cursor = r.truncated && objs.length < FOLDER_MAX ? r.cursor : undefined;
  } while (cursor);
  if (rel && !folders.length && !objs.length) return notice("Link not found", 404);

  const byName = (a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" });
  const niceName = (s) => s.replace(/\.[^/.]+$/, (x) => x.toUpperCase());
  const items = [];
  for (const o of objs.slice(0, FOLDER_MAX)) {
    const name = o.key.slice(prefix.length);
    if (!name || JUNK.test(name) || name.startsWith(MARK)) continue;
    const ext = (name.split(".").pop() || "").toLowerCase();
    let type = (o.httpMetadata && o.httpMetadata.contentType) || "";
    if (/^(|application\/octet-stream|binary\/octet-stream)$/.test(type)) type = MIME_BY_EXT[ext] || IMG_BY_EXT[ext] || "application/octet-stream";
    const mtime = Number((o.customMetadata || {}).mtime);
    const path = o.key.slice(ROOT.length);
    items.push({ name: niceName(name), sortName: name, path, type, size: o.size, taken: mtime > 0 ? Math.round(mtime * 1000) : o.uploaded.getTime(), src: "/main/archive/f/" + urlPath(path), art: null });
  }
  items.sort((a, b) => byName(a.sortName, b.sortName));
  items.forEach((f, i) => {
    f.n = String(i).padStart(5, "0");
    delete f.sortName;
  });

  const subs = folders.map((p) => p.slice(prefix.length).replace(/\/$/, "")).filter((x) => x && !JUNK.test(x)).sort(byName);
  const here = rel ? rel.split("/") : [];
  const title = here.length ? here[here.length - 1] : "Chauphan";
  const go = (p) => (p ? "/main/archive?p=" + encodeURIComponent(p) : "/main/archive");
  const crumbs = [`<a href="/main/">Main Gallery</a>`, `<a href="/main/archive">Chauphan</a>`]
    .concat(here.map((x, i) => `<a href="${go(here.slice(0, i + 1).join("/"))}">${esc(x)}</a>`))
    .join("<i>/</i>");
  const links = subs.map((x) => `<a class="fd" href="${go((rel ? rel + "/" : "") + x)}">${esc(x)}</a>`).join("");
  const empty = !items.length && !subs.length ? `<p class="none">This folder is empty.</p>` : "";
  const nav = `<style>
.mainnav{padding:0 16px 14px;font:500 15px -apple-system,BlinkMacSystemFont,sans-serif}
.mainnav .fs{display:flex;flex-wrap:nowrap;gap:8px;overflow-x:auto;scrollbar-width:none;touch-action:pan-x}
.mainnav .fs::-webkit-scrollbar{display:none}
.mainnav .fd{color:#fff;text-decoration:none;padding:8px 12px;border-radius:10px;background:rgba(255,255,255,.08);flex:none;max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
</style>
<nav class="mainnav">${links ? `<div class="fs">${links}</div>` : ""}${empty}</nav>`;

  return galleryPage(
    {
      id: "archive",
      main: true,
      readOnly: true,
      mainApi: "/main/archive/api",
      api: "/main/archive/api",
      dir: rel,
      uploadMax: 0,
      owner: OWNER,
      title,
      heading: "Chauphan · read-only",
      zip: title + ".zip",
      exp: 0,
      expected: items.length,
      ready: items.length,
      complete: true,
      items,
    },
    nav,
    `<div class="crbar">${crumbs}</div>`
  );
}
