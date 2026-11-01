// The archive shelf (docs/architecture.md §10): gallery-archive/archive/ shown with the same page and player as Main,
// read-only. Owner only, behind Access like the rest of /main.
//
//   GET /main/archive?p=<folder>[&open=<path>]   a folder, as Main shows one (open: straight onto that file)
//   GET /main/archive/f/<path>                   a file (Range works; ?dl=1 to download)
//   /main/archive/api/…                          the page's API base (G.mainApi): whoami answers, every other read is
//                                                404 and every write is 403. Nothing here writes, whatever a page sends.
//
// Paths are inside archive/; the bucket's dot folders (.catalog, .trash, .uploads) are never reachable.

import { OWNER, FOLDER_MAX, JUNK, MIME_BY_EXT, IMG_BY_EXT, cleanPath, urlPath, esc, notice, jsonResponse, serveObject } from "./common.js";
import { galleryPage } from "./page/gallery.js";

const ROOT = "archive/";
// Data (notes 20261029 item 16): the Mac's offsite disks (Photos, Messages, Mail: APFS sparse bundles in .disks/,
// mounted on the Mac by Disks Helper) shown as one place in the archive. Their bytes are disk bands, not files, so the
// page shows each disk and its size; what is exported out of them lands in archive/Data/<disk>/ and shows as files.
const DATA = "Data";
const DISKS = ".disks/";
const DISK_CACHE = "cache/disks.json"; // in MAIN: [{ name, size, bands, at }], the daily sweep's count

export async function diskSweep(env) {
  const top = await env.ARCHIVE.list({ prefix: DISKS, delimiter: "/" });
  const out = [];
  for (const p of top.delimitedPrefixes || []) {
    let size = 0;
    let bands = 0;
    let cursor;
    do {
      const r = await env.ARCHIVE.list({ prefix: p, cursor });
      for (const o of r.objects) {
        size += o.size;
        bands++;
      }
      cursor = r.truncated ? r.cursor : undefined;
    } while (cursor);
    out.push({ name: p.slice(DISKS.length).replace(/\/$/, "").replace(/\.sparsebundle$/, ""), size, bands, at: Date.now() });
  }
  await env.MAIN.put(DISK_CACHE, JSON.stringify(out), { httpMetadata: { contentType: "application/json" } });
  return out;
}

async function disks(env) {
  try {
    const o = await env.MAIN.get(DISK_CACHE);
    if (o) return await o.json();
  } catch (e) {}
  return diskSweep(env).catch(() => []);
}

const bytes = (n) => {
  const u = ["bytes", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1000 && i < u.length - 1) {
    n /= 1000;
    i++;
  }
  return (i ? n.toFixed(n < 10 ? 1 : 0) : n) + " " + u[i];
};
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

function diskCards(list) {
  if (!list.length) return `<p class="dn">No disks yet.</p>`;
  const icon = `<svg viewBox="0 0 24 24"><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M5 13l2.5-8h9L19 13M7 16.5h.01"/></svg>`;
  const cards = list
    .map((d) => `<div>${icon}<b>${esc(d.name)}</b><small>${d.size ? bytes(d.size) + " offsite" : "Offsite"}</small></div>`)
    .join("");
  return `<div class="dk">${cards}</div><p class="dn">These live offsite in your archive and open on Chau’s MacBook Pro. What’s exported from them shows here as files.</p>`;
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
  if (rel && rel !== DATA && !folders.length && !objs.length) return notice("Link not found", 404);

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

  const subs = folders.map((p) => p.slice(prefix.length).replace(/\/$/, "")).filter((x) => x && !JUNK.test(x) && !(!rel && x === DATA)).sort(byName);
  // Data comes first at the root, whether or not anything is exported into it yet
  if (!rel) subs.unshift(DATA);
  const here = rel ? rel.split("/") : [];
  const title = here.length ? here[here.length - 1] : "Chau Phan's Archive";
  const go = (p) => (p ? "/main/archive?p=" + encodeURIComponent(p) : "/main/archive");
  const crumbs = [`<a href="/main/">Main Gallery</a>`, `<a href="/main/archive">Archive</a>`]
    .concat(here.map((x, i) => `<a href="${go(here.slice(0, i + 1).join("/"))}">${esc(x)}</a>`))
    .join("<i>/</i>");
  const links = subs.map((x) => `<a class="fd" href="${go((rel ? rel + "/" : "") + x)}">${esc(x)}</a>`).join("");
  const shelf = rel === DATA ? diskCards(await disks(env)) : "";
  const empty = !items.length && !subs.length && !shelf ? `<p class="none">This folder is empty.</p>` : "";
  const nav = `<style>
.mainnav{padding:0 16px 14px;font:500 15px -apple-system,BlinkMacSystemFont,sans-serif}
.mainnav .fs{display:flex;flex-wrap:nowrap;gap:8px;overflow-x:auto;scrollbar-width:none;touch-action:pan-x}
.mainnav .fs::-webkit-scrollbar{display:none}
.mainnav .dk{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:10px;margin:0 0 14px}
.mainnav .dk div{background:rgba(255,255,255,.08);border-radius:14px;padding:14px;display:flex;flex-direction:column;gap:4px}
.mainnav .dk svg{width:26px;height:26px;stroke:#0a84ff;fill:none;stroke-width:1.7;margin-bottom:4px}
.mainnav .dk b{font-weight:600}
.mainnav .dk small,.mainnav .dn{color:#8e8e93;font-size:13px}
.mainnav .dn{margin:0 0 14px;line-height:1.35}
.mainnav .fd{color:#fff;text-decoration:none;padding:8px 12px;border-radius:10px;background:rgba(255,255,255,.08);flex:none;max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
</style>
<nav class="mainnav">${shelf}${links ? `<div class="fs">${links}</div>` : ""}${empty}</nav>`;

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
      heading: (here.length ? title : "Chau Phan's Archive") + " · read-only",
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
