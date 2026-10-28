// WebDAV (RFC 4918, class 1) over R2, on the same path checks as the file dashboard.
//
//   /main/dav/…        the Main library (files/), behind Access like the rest of /main: rclone's
//                      webdav backend with the Mac's service token. Read-write. An overwrite keeps
//                      the old file in trash/<day>/<path>@<time>; DELETE moves a file to the trash.
//   /main/dav-tmp/…    the gallery-tmp bucket, behind Access too. Throwaway by design (it expires), so
//                      DELETE and overwrites are for good: no trash, no versions.
//   /main/dav-archive/…  the gallery-archive bucket (chauphan/… and later computers), behind Access. Read-write
//                      like Main: an overwrite keeps the old file in .trash/<day>/<path>@<time> in the same
//                      bucket, and DELETE moves a file there. Finder's own files (._* and .DS_Store: NFS has no
//                      extended attributes) are stored as they come, never listed, never trashed.
//   /main/nc/…, /main/nc-tmp/…, /main/nc-archive/…  the same three, Nextcloud-shaped (…/dav/files/owner/, …/dav/uploads/owner/) for rclone's
//                      nextcloud vendor: a file bigger than one request (Cloudflare caps a body at 100 MB) arrives
//                      in chunks under .uploads/<dir>/ and is joined into place by MOVE …/.file.
//   /dav/notability/…  Notability's Auto-Backup (notability-backup/), outside Access: HTTP Basic
//                      with its own password, stored only as NOTABILITY_DAV_HASH (sha-256 hex).
//                      Append-only: an overwrite keeps the old copy under notability-versions/,
//                      and DELETE, MOVE and COPY are refused.
//
// Every path is the URL path after the mount, percent-decoded once and run through cleanPath (no
// empty, "." or ".." segments, no control characters), then prefixed: nothing reaches art/, trash/,
// order/, invites/ or another mount. New names (PUT, MKCOL, MOVE, COPY) also pass segmentName.
// Folder moves and deletes are refused for now; no LOCK, so Finder mounts it read-only.

import { JUNK, MIME_BY_EXT, IMG_BY_EXT, cleanPath, urlPath, esc, serveObject } from "./common.js";
import { segmentName, folderExists, makeFolder, moveFile, trashFile, keepInTrash } from "./main.js";

const MARK = ".folder-";
const LIST_MAX = 5000;
const FAILS_MAX = 10; // wrong passwords per address per 15 minutes
const FAIL_WINDOW = 15 * 60000;
const CHUNKED_MAX = 32 * 1024 * 1024;
const STAGE = ".uploads/"; // chunks wait here (hidden: dot names are never listed or writable through a mount)
const UPLOAD_DIR = /^[A-Za-z0-9_-]{1,100}$/;
const CHUNK = /^(\d{15})-(\d{15})$/; // rclone names a chunk by its first and last byte
const CHUNK_MAX = 100 * 1000 * 1000;
const JOINED_MAX = 5 * 1024 ** 3; // one R2 put

export const MAIN_DAV = { base: "/main/dav/", prefix: "files/", main: true, rw: true };
export const TMP_DAV = { base: "/main/dav-tmp/", prefix: "", bucket: "TMP", rw: true, ephemeral: true };
export const ARCHIVE_DAV = { base: "/main/dav-archive/", prefix: "", bucket: "ARCHIVE", rw: true, trash: ".trash/", finder: true };
export const MAIN_NC = { ...MAIN_DAV, base: "/main/nc/dav/files/owner/", uploads: "/main/nc/dav/uploads/owner/" };
export const TMP_NC = { ...TMP_DAV, base: "/main/nc-tmp/dav/files/owner/", uploads: "/main/nc-tmp/dav/uploads/owner/" };
export const ARCHIVE_NC = { ...ARCHIVE_DAV, base: "/main/nc-archive/dav/files/owner/", uploads: "/main/nc-archive/dav/uploads/owner/" };
export const NOTABILITY_DAV = { base: "/dav/notability/", prefix: "notability-backup/", versions: "notability-versions/" };

const RW = "OPTIONS, PROPFIND, GET, HEAD, PUT, MKCOL, DELETE, MOVE, COPY";
const APPEND = "OPTIONS, PROPFIND, GET, HEAD, PUT, MKCOL";

const r2 = (env, mount) => env[mount.bucket || "MAIN"];
const text = (status, body = "", headers = {}) => new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8", ...headers } });

const under = (path, base) => path + "/" === base || path.startsWith(base);

// the owner's mount (behind Access) serving this path, or null
export function ownerMount(path) {
  return [MAIN_DAV, TMP_DAV, ARCHIVE_DAV, MAIN_NC, TMP_NC, ARCHIVE_NC].find((m) => under(path, m.base) || (m.uploads && under(path, m.uploads))) || null;
}

// the path inside the mount, or null; "" is the mount's root
export function davPath(mount, pathname) {
  if (pathname + "/" === mount.base) return "";
  if (!pathname.startsWith(mount.base)) return null;
  const rel = cleanPath(pathname.slice(mount.base.length), true);
  // a mount on a bucket's root shares it with its staging and trash: never reachable through the mount
  const top = rel === null ? "" : rel.split("/")[0] + "/";
  if (!mount.prefix && (top === STAGE || top === mount.trash)) return null;
  return rel;
}

export async function dav(req, env, url, mount) {
  if (mount.uploads && under(url.pathname, mount.uploads)) return chunked(req, env, url, mount);
  const rel = davPath(mount, url.pathname);
  if (rel === null) return text(400, "Bad path");
  const allow = mount.rw ? RW : APPEND;

  switch (req.method) {
    case "OPTIONS":
      return new Response(null, { status: 200, headers: { dav: "1", allow, "ms-author-via": "DAV" } });
    case "PROPFIND":
      return propfind(req, env, mount, rel);
    case "GET":
    case "HEAD":
      return get(req, env, url, mount, rel);
    case "PUT":
      return put(req, env, mount, rel);
    case "MKCOL":
      return mkcol(req, env, mount, rel);
    case "DELETE":
      return mount.main ? del(env, rel) : mount.trash ? bin(env, mount, rel) : mount.rw ? drop(env, mount, rel) : text(405, "", { allow });
    case "MOVE":
    case "COPY":
      return mount.rw ? moveOrCopy(req, env, url, mount, rel, req.method === "MOVE") : text(405, "", { allow });
    case "PATCH":
      // rclone's nextcloud vendor asks the server to recompute a hash after an upload; there is none to recompute
      return mount.rw && req.headers.has("x-recalculate-hash") ? new Response(null, { status: 204 }) : text(405, "", { allow });
    default:
      return text(405, "", { allow });
  }
}

// ---------- reading ----------

const exists = (env, mount, rel) => (mount.bucket ? folderIn(r2(env, mount), mount.prefix, rel) : folderExists(env, rel, mount.prefix));

async function folderIn(bucket, prefix, rel) {
  if (!rel) return true;
  const r = await bucket.list({ prefix: prefix + rel + "/", limit: 1 });
  return r.objects.length > 0;
}

// what is at rel: { file: head } | { dir: true } | null
async function stat(env, mount, rel) {
  if (!rel) return { dir: true };
  const head = await r2(env, mount).head(mount.prefix + rel);
  if (head) return { file: head };
  return (await exists(env, mount, rel)) ? { dir: true } : null;
}

const hidden = (name) => !name || name.startsWith(".") || JUNK.test(name);
const typeOf = (name, o) => {
  const t = (o.httpMetadata && o.httpMetadata.contentType) || "";
  const ext = (name.split(".").pop() || "").toLowerCase();
  return /^(|application\/octet-stream|binary\/octet-stream)$/.test(t) ? MIME_BY_EXT[ext] || IMG_BY_EXT[ext] || "application/octet-stream" : t;
};
// rclone keeps the file's own modification time (seconds) in customMetadata.mtime
const modified = (o) => {
  const m = Number((o.customMetadata || {}).mtime);
  return m > 0 ? new Date(m * 1000) : o.uploaded;
};

function entry(mount, rel, o) {
  const href = mount.base + (rel ? urlPath(rel) + (o ? "" : "/") : "");
  const name = rel.split("/").pop() || "";
  const props = o
    ? `<d:resourcetype/><d:getcontentlength>${o.size}</d:getcontentlength><d:getcontenttype>${esc(typeOf(name, o))}</d:getcontenttype>` +
      `<d:getetag>${esc(o.httpEtag)}</d:getetag><d:getlastmodified>${modified(o).toUTCString()}</d:getlastmodified>`
    : `<d:resourcetype><d:collection/></d:resourcetype>`;
  return `<d:response><d:href>${esc(href)}</d:href><d:propstat><d:prop><d:displayname>${esc(name)}</d:displayname>${props}</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>`;
}

// Depth 0 or 1 (none counts as 1); every property is returned whatever the body asks for
async function propfind(req, env, mount, rel) {
  const depth = (req.headers.get("depth") || "1").trim().toLowerCase();
  if (depth !== "0" && depth !== "1") {
    return new Response('<?xml version="1.0" encoding="utf-8"?><d:error xmlns:d="DAV:"><d:propfind-finite-depth/></d:error>', {
      status: 403,
      headers: { "content-type": "application/xml; charset=utf-8" },
    });
  }

  const at = await stat(env, mount, rel);
  if (!at) return text(404, "Not found");

  const out = [entry(mount, rel, at.file)];
  if (at.dir && depth === "1") {
    const prefix = mount.prefix + (rel ? rel + "/" : "");
    let cursor;
    let n = 0;
    do {
      const r = await r2(env, mount).list({ prefix, delimiter: "/", include: ["httpMetadata", "customMetadata"], cursor });
      for (const p of r.delimitedPrefixes || []) {
        const name = p.slice(prefix.length).replace(/\/$/, "");
        if (!hidden(name)) out.push(entry(mount, (rel ? rel + "/" : "") + name, null));
      }
      for (const o of r.objects) {
        const name = o.key.slice(prefix.length);
        if (!hidden(name)) out.push(entry(mount, (rel ? rel + "/" : "") + name, o));
      }
      n += r.objects.length;
      cursor = r.truncated && n < LIST_MAX ? r.cursor : undefined;
    } while (cursor);
  }

  return new Response('<?xml version="1.0" encoding="utf-8"?>\n<d:multistatus xmlns:d="DAV:">' + out.join("") + "</d:multistatus>", {
    status: 207,
    headers: { "content-type": "application/xml; charset=utf-8" },
  });
}

async function get(req, env, url, mount, rel) {
  const name = rel.split("/").pop();
  if (!rel || (hidden(name) && !finderFile(mount, rel))) return text(rel ? 404 : 405, rel ? "Not found" : "A folder");
  let obj;
  try {
    const b = r2(env, mount);
    obj = req.method === "HEAD" ? await b.head(mount.prefix + rel) : await b.get(mount.prefix + rel, { range: req.headers });
  } catch (e) {
    return text(416, "Bad range");
  }
  if (!obj) return (await exists(env, mount, rel)) ? text(405, "A folder") : text(404, "Not found");
  if (req.method === "HEAD") {
    const h = new Headers();
    obj.writeHttpMetadata(h);
    h.set("etag", obj.httpEtag);
    h.set("content-length", String(obj.size));
    h.set("last-modified", modified(obj).toUTCString());
    return new Response(null, { status: 200, headers: h });
  }
  const ext = (name.split(".").pop() || "").toLowerCase();
  const res = serveObject(req, url, obj, name, MIME_BY_EXT[ext] || IMG_BY_EXT[ext]);
  res.headers.set("last-modified", modified(obj).toUTCString());
  return res;
}

// ---------- writing ----------

const parentOf = (rel) => rel.split("/").slice(0, -1).join("/");
const nameOk = (rel) => segmentName(rel.split("/").pop()) === rel.split("/").pop();
const FINDER = /^(\._.+|\.DS_Store)$/;
// a mount that takes Finder's own files: they're written and read by name only, and go for good
const finderFile = (mount, rel) => !!(mount.finder && rel && FINDER.test(rel.split("/").pop()));

// If-Match / If-None-Match against what is there now (RFC 7232); null when the write may go ahead
function preconditions(req, head) {
  const match = req.headers.get("if-match");
  const none = req.headers.get("if-none-match");
  const tags = (s) => s.split(",").map((x) => x.trim().replace(/^W\//, ""));
  if (match && (!head || (match.trim() !== "*" && !tags(match).includes(head.httpEtag)))) return text(412, "Changed");
  if (none && head && (none.trim() === "*" || tags(none).includes(head.httpEtag))) return text(412, "Already there");
  return null;
}

async function put(req, env, mount, rel) {
  const finder = finderFile(mount, rel);
  if (!rel || !(nameOk(rel) || finder)) return text(rel ? 403 : 405, "That name can’t be used");
  if (!(await exists(env, mount, parentOf(rel)))) return text(409, "No such folder");
  if (await exists(env, mount, rel)) return text(405, "A folder is there");

  // R2 needs the size up front: a chunked upload (Finder sends them) is read into memory, up to CHUNKED_MAX
  const cl = req.headers.get("content-length");
  let body = req.body;
  let length = cl === null ? NaN : Number(cl);
  if (cl === null) {
    body = await readAll(req.body, CHUNKED_MAX);
    if (!body) return text(413, "Too big without a Content-Length");
    length = body.length;
  }
  if (!Number.isSafeInteger(length) || length < 0) return text(400, "Bad Content-Length");

  const b = r2(env, mount);
  const key = mount.prefix + rel;
  const head = await b.head(key);
  const refused = preconditions(req, head);
  if (refused) return refused;

  // nothing is lost: the file as it was goes to the trash (Main, archive) or to the versions (append-only); tmp just replaces it
  if (head && !mount.ephemeral && !finder) {
    const kept = mount.main
      ? await keepInTrash(env, rel)
      : mount.trash
        ? await toTrash(b, mount, rel)
        : await copyKey(b, key, mount.versions + rel + "@" + new Date().toISOString().replace(/[:.]/g, "-"));
    if (!kept) return text(412, "Changed");
  }

  const mt = Number(req.headers.get("x-oc-mtime")); // rclone sends the file's mtime here
  const name = rel.split("/").pop();
  const contentType = (req.headers.get("content-type") || typeOf(name, {})).slice(0, 200);
  const meta = { mtime: String(mt > 0 && Number.isFinite(mt) ? Math.floor(mt) : Math.floor(Date.now() / 1000)) };
  if (head && head.customMetadata && head.customMetadata.was) meta.was = head.customMetadata.was;

  const done = await b.put(key, length ? body : "", {
    httpMetadata: { contentType },
    customMetadata: meta,
    onlyIf: head ? { etagMatches: head.etag } : { etagDoesNotMatch: "*" },
  });
  if (!done) return text(412, "Changed");
  if (mount.main) await env.MAIN.delete("art/" + rel).catch(() => {});

  const h = { etag: done.httpEtag };
  if (mt > 0) h["x-oc-mtime"] = "accepted";
  return new Response(null, { status: head ? 204 : 201, headers: h });
}

async function readAll(stream, max) {
  if (!stream) return new Uint8Array(0);
  const parts = [];
  let n = 0;
  const r = stream.getReader();
  for (;;) {
    const { done, value } = await r.read();
    if (done) break;
    n += value.length;
    if (n > max) {
      await r.cancel().catch(() => {});
      return null;
    }
    parts.push(value);
  }
  const out = new Uint8Array(n);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

async function copyKey(bucket, from, to) {
  const obj = await bucket.get(from);
  if (!obj) return null;
  const { readable, writable } = new FixedLengthStream(obj.size);
  const copied = obj.body.pipeTo(writable);
  const put = await bucket.put(to, readable, { httpMetadata: obj.httpMetadata, customMetadata: obj.customMetadata, onlyIf: { etagDoesNotMatch: "*" } });
  if (put) await copied;
  else copied.catch(() => {});
  return put;
}

async function mkcol(req, env, mount, rel) {
  if (req.body && Number(req.headers.get("content-length") || 0) > 0) return text(415, "No body");
  if (!rel) return text(405, "Already there");
  if (!nameOk(rel)) return text(403, "That name can’t be used");
  if (!(await exists(env, mount, parentOf(rel)))) return text(409, "No such folder");
  if (await stat(env, mount, rel)) return text(405, "Already there");
  await makeFolder(env, mount.prefix, rel, r2(env, mount));
  return new Response(null, { status: 201 });
}

async function del(env, rel) {
  if (!rel) return text(403, "Not the root");
  if (await env.MAIN.head("files/" + rel)) return (await trashFile(env, rel)) ? new Response(null, { status: 204 }) : text(404, "Not found");
  return (await folderExists(env, rel)) ? text(403, "Folders are deleted on the Mac") : text(404, "Not found");
}

// a copy of the file as it is, in the mount's own trash: <trash><day>/<path>@<time>
function toTrash(b, mount, rel) {
  const now = new Date().toISOString();
  return copyKey(b, mount.prefix + rel, mount.trash + now.slice(0, 10) + "/" + rel + "@" + now.replace(/[:.]/g, "-"));
}

// archive: a file goes to the trash; folders are refused, as on Main
async function bin(env, mount, rel) {
  if (!rel) return text(403, "Not the root");
  const b = r2(env, mount);
  if (await b.head(mount.prefix + rel)) {
    if (!finderFile(mount, rel) && !(await toTrash(b, mount, rel))) return text(412, "Changed");
    await b.delete(mount.prefix + rel);
    return new Response(null, { status: 204 });
  }
  return (await exists(env, mount, rel)) ? text(403, "Folders are deleted on the Mac") : text(404, "Not found");
}

// tmp: a file goes for good; a folder only once nothing but folder markers is left in it
async function drop(env, mount, rel) {
  if (!rel) return text(403, "Not the root");
  const b = r2(env, mount);
  if (await b.head(mount.prefix + rel)) {
    await b.delete(mount.prefix + rel);
    return new Response(null, { status: 204 });
  }
  const inside = (await b.list({ prefix: mount.prefix + rel + "/", limit: 100 })).objects.map((o) => o.key);
  if (!inside.length) return text(404, "Not found");
  if (!inside.every((k) => k.split("/").pop().startsWith(MARK))) return text(409, "Not empty");
  await b.delete(inside);
  return new Response(null, { status: 204 });
}

// Destination: an absolute URL (or a path) on this host, inside the same mount
function destination(req, url, mount) {
  const d = req.headers.get("destination");
  if (!d) return null;
  let u;
  try {
    u = new URL(d, url);
  } catch (e) {
    return null;
  }
  if (u.origin !== url.origin) return null;
  const rel = davPath(mount, u.pathname);
  return rel && (nameOk(rel) || finderFile(mount, rel)) ? rel : null;
}

async function moveOrCopy(req, env, url, mount, rel, move) {
  const to = destination(req, url, mount);
  if (!to) return text(400, "Bad destination");
  if (!rel) return text(403, "Not the root");

  const at = await stat(env, mount, rel);
  if (!at) return text(404, "Not found");
  if (at.dir) return text(403, "Folders are moved on the Mac");
  if (to === rel) return text(403, "Same place");
  if (!(await exists(env, mount, parentOf(to)))) return text(409, "No such folder");
  if (await exists(env, mount, to)) return text(412, "A folder is there");

  // Overwrite: T (the default) sends what is there to the trash first (tmp: deletes it); F refuses
  const b = r2(env, mount);
  const there = await b.head(mount.prefix + to);
  if (there) {
    if ((req.headers.get("overwrite") || "T").trim().toUpperCase() === "F") return text(412, "Already there");
    if (mount.trash && !finderFile(mount, to) && !(await toTrash(b, mount, to))) return text(412, "Changed");
    if (!mount.main) await b.delete(mount.prefix + to);
    else if (!(await trashFile(env, to))) return text(412, "Changed");
  }

  if (move && mount.main) {
    const why = await moveFile(env, rel, to);
    if (why) return text(why === "not found" ? 404 : 412, why);
  } else if (!(await copyKey(b, mount.prefix + rel, mount.prefix + to))) {
    return text(412, "Already there");
  } else if (move) {
    await b.delete(mount.prefix + rel);
  }
  return new Response(null, { status: there ? 204 : 201 });
}

// ---------- chunked uploads (rclone's nextcloud vendor) ----------

// DELETE <dir> (leftovers), MKCOL <dir>, PUT <dir>/<first>-<last> for each chunk, MOVE <dir>/.file with the Destination
async function chunked(req, env, url, mount) {
  const rest = url.pathname.slice(mount.uploads.length).split("/").filter(Boolean);
  const [dir, part] = rest;
  if (!dir || rest.length > 2 || !UPLOAD_DIR.test(dir)) return text(400, "Bad path");
  const b = r2(env, mount);
  const stage = STAGE + dir + "/";

  switch (req.method) {
    case "MKCOL":
      return part ? text(405, "", { allow: "MKCOL, DELETE" }) : new Response(null, { status: 201 });
    case "DELETE":
      if (part) return text(405, "", { allow: "MKCOL, DELETE" });
      await dropStage(b, stage);
      return new Response(null, { status: 204 });
    case "PUT": {
      const m = CHUNK.exec(part || "");
      const size = m ? Number(m[2]) - Number(m[1]) + 1 : 0;
      if (!m || size < 1 || size > CHUNK_MAX) return text(400, "Bad chunk");
      const cl = req.headers.get("content-length");
      const body = cl === null ? await readAll(req.body, CHUNK_MAX) : req.body;
      if ((cl === null ? body && body.length : Number(cl)) !== size) return text(400, "Chunk size doesn't match its name");
      await b.put(stage + part, body);
      return new Response(null, { status: 201 });
    }
    case "MOVE":
      return part === ".file" ? join(req, env, url, mount, b, stage) : text(400, "Bad path");
    default:
      return text(405, "", { allow: "MKCOL, PUT, MOVE, DELETE" });
  }
}

async function dropStage(b, stage) {
  let cursor;
  do {
    const r = await b.list({ prefix: stage, cursor });
    if (r.objects.length) await b.delete(r.objects.map((o) => o.key));
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);
}

// the chunks, in order from byte 0 with no gap or overlap, streamed into one object; the old file is kept like a PUT keeps it
async function join(req, env, url, mount, b, stage) {
  const rel = destination(req, url, mount);
  if (!rel) return text(400, "Bad destination");
  if (!(await exists(env, mount, parentOf(rel)))) return text(409, "No such folder");
  if (await exists(env, mount, rel)) return text(405, "A folder is there");

  const parts = [];
  let cursor;
  do {
    const r = await b.list({ prefix: stage, cursor });
    parts.push(...r.objects);
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);
  parts.sort((x, y) => (x.key < y.key ? -1 : 1)); // zero-padded offsets sort as numbers
  let total = 0;
  for (const p of parts) {
    const m = CHUNK.exec(p.key.slice(stage.length));
    if (!m || Number(m[1]) !== total || p.size !== Number(m[2]) - total + 1) return text(400, "Chunks missing or overlapping");
    total += p.size;
  }
  if (!total) return text(400, "No chunks");
  if (total > JOINED_MAX) return text(413, "Over 5 GiB");

  const key = mount.prefix + rel;
  const there = await b.head(key);
  if (there) {
    if ((req.headers.get("overwrite") || "T").trim().toUpperCase() === "F") return text(412, "Already there");
    if (mount.main && !(await keepInTrash(env, rel))) return text(412, "Changed");
    if (mount.trash && !(await toTrash(b, mount, rel))) return text(412, "Changed");
  }

  const mt = Number(req.headers.get("x-oc-mtime"));
  const meta = { mtime: String(mt > 0 && Number.isFinite(mt) ? Math.floor(mt) : Math.floor(Date.now() / 1000)) };
  if (there && there.customMetadata && there.customMetadata.was) meta.was = there.customMetadata.was;

  const { readable, writable } = new FixedLengthStream(total);
  const pump = (async () => {
    try {
      for (const p of parts) await (await b.get(p.key)).body.pipeTo(writable, { preventClose: true });
      await writable.close();
    } catch (e) {
      await writable.abort(e).catch(() => {});
      throw e;
    }
  })();
  const done = await b
    .put(key, readable, {
      httpMetadata: { contentType: typeOf(rel.split("/").pop(), {}) },
      customMetadata: meta,
      onlyIf: there ? { etagMatches: there.etag } : { etagDoesNotMatch: "*" },
    })
    .catch(() => null);
  const pumped = await pump.then(() => true, () => false);
  if (!done || !pumped) return text(412, "Changed");
  if (mount.main) await env.MAIN.delete("art/" + rel).catch(() => {});
  await dropStage(b, stage);
  const h = { etag: done.httpEtag };
  if (mt > 0) h["x-oc-mtime"] = "accepted";
  return new Response(null, { status: there ? 204 : 201, headers: h });
}

// ---------- Notability's password ----------

const hex = async (s) =>
  [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))].map((b) => b.toString(16).padStart(2, "0")).join("");

// both sides are 64 hex characters, compared in full whatever they hold
function same(a, b) {
  if (a.length !== b.length) return false;
  let x = 0;
  for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return x === 0;
}

const failKey = async (ip) => "rate/dav/" + (await hex("ip:" + ip)).slice(0, 20);

async function failures(env, key) {
  try {
    const o = await env.PUBLIC.get(key);
    return o ? ((await o.json()).t || []).filter((x) => Date.now() - x < FAIL_WINDOW) : [];
  } catch (e) {
    return [];
  }
}

// null: let it in; else the answer. No NOTABILITY_DAV_HASH set: the mount does not exist.
export async function notabilityAuth(req, env) {
  const want = String(env.NOTABILITY_DAV_HASH || "").trim().toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(want)) return text(404, "Not found");

  const key = await failKey(req.headers.get("cf-connecting-ip") || "unknown");
  const t = await failures(env, key);
  if (t.length >= FAILS_MAX) return text(429, "Too many tries", { "retry-after": "900" });

  const m = (req.headers.get("authorization") || "").match(/^Basic\s+([A-Za-z0-9+/=]+)$/i);
  let pass = null;
  if (m) {
    try {
      const pair = new TextDecoder().decode(Uint8Array.from(atob(m[1]), (c) => c.charCodeAt(0)));
      if (pair.includes(":")) pass = pair.slice(pair.indexOf(":") + 1);
    } catch (e) {}
  }
  if (pass !== null && same(await hex(pass), want)) return null;

  if (m) {
    t.push(Date.now());
    await env.PUBLIC.put(key, JSON.stringify({ t })).catch(() => {});
  }
  return text(401, "Sign in", { "www-authenticate": 'Basic realm="Notability backup", charset="UTF-8"' });
}
