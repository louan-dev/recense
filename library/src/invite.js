// Invites: a private link for one person to one Main folder, outside Cloudflare Access.
//
// The owner makes them from Main (… > Invite). Each link is /m/<token>; the token is 32 random
// bytes and only its SHA-256 is stored, under invites/<hash>.json in MAIN:
//   { name, folder, items?, created, expires (ms, 0 = never), perms: { download, upload, comment } }
// items (file names in the folder) makes it a room: the person sees only those, and a room of one
// opens straight onto that item in the viewer. A room never takes uploads.
// The public id shown to the owner (for Revoke) is the first 16 hex of the hash.
// Permissions (every one checked here, whatever the page shows): view, download, upload, comment,
// react, annotate. perms holds the invite's defaults; overrides[name] changes them for one file
// (null = inherit); viewOnly, or the owner's lock on the folder (invites/_locks.json), turns every
// write off. download off still lets media play inline; it refuses ?dl=1 and anything not playable.
// A participant can see and download the folder's files, upload new ones and comment, and
// delete only their own comments. They can never delete or replace the owner's files, see
// other folders, or reach /main. An unknown, expired or revoked link is the same 404.

import { OWNER, cleanPath, urlPath, notice, jsonResponse, viewOf } from "./common.js";
import { listFolder, mainFile, mainUpload } from "./main.js";
import { commentApi, countryOf, guestName } from "./public.js";
import { galleryPage } from "./page/gallery.js";
import { sameSite } from "./access.js";
import { transcriptResponse } from "./transcript.js";
import { logActivity } from "./shared.js";
import { hasDB, shareGet, sharePut, shareList, shareById, shareRevoke, locksGet, lockSet } from "./d1.js";
import { metaOf, folderGeo, inBounds } from "./meta.js";
import { annotationChange, readAnnotations, pubOf as annotationOf } from "./annotations.js";
import { identityApi, authRoute, signInPage, sessionGuest, claim, revokeGuest, guestStatus, endSessions, inviteIcs, emailOn } from "./identity.js";

const INVITES = "invites/";
const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;
const ID_RE = /^[0-9a-f]{16}$/;
const NAME_MAX = 80;
const TTL_MAX = 365 * 86400;
const ITEMS_MAX = 500;
const LOCKS = INVITES + "_locks.json";
export const PERMS = ["view", "download", "upload", "comment", "react", "annotate"];
const WRITES = ["upload", "comment", "react", "annotate"];
// what the browser can show inline; anything else is a download
const PLAYABLE = /\.(jpe?g|png|gif|webp|heic|heif|avif|mp3|m4a|aac|wav|aiff?|flac|ogg|opus|mp4|m4v|mov|webm|pdf)$/i;

// The invite's own defaults, the same for invites made before react/annotate/view existed.
export const basePerms = (inv) => ({ view: true, download: true, upload: !inv.items, comment: true, react: true, annotate: false, ...(inv.perms || {}) });

// What this invite may do with one file (name null = the folder itself), the lock applied last.
export function permsFor(inv, name, locked = false) {
  const p = basePerms(inv);
  const o = name != null && inv.overrides && inv.overrides[name];
  if (o) for (const k of PERMS) if (typeof o[k] === "boolean") p[k] = o[k];
  if (inv.items) p.upload = false;
  if (inv.viewOnly || locked) for (const k of WRITES) p[k] = false;
  if (!p.view) for (const k of PERMS) p[k] = false;
  return p;
}

async function readLocks(env) {
  if (hasDB(env)) return locksGet(env);
  try {
    const o = await env.MAIN.get(LOCKS);
    const j = o ? await o.json() : null;
    return j && typeof j === "object" ? j : {};
  } catch (e) {
    return {};
  }
}
export const folderLocked = async (env, folder) => !!(await readLocks(env))[folder];

const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
const hashOf = async (token) => hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)));

function newToken() {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const pub = (hash, inv) => ({
  id: hash.slice(0, 16),
  name: inv.name,
  folder: inv.folder,
  items: inv.items || null,
  created: inv.created,
  expires: inv.expires || 0,
  perms: basePerms(inv),
  viewOnly: !!inv.viewOnly,
  overrides: inv.overrides || {},
});

// ---------- owner: /main/api/invites ----------

// GET    /main/api/invites?dir=<folder>        -> [{ id, name, folder, created, expires, perms }]
// POST   /main/api/invites  { name, ttl, dir, items? }  -> the same plus url (the only time the token is shown)
// DELETE /main/api/invites/<id>                 revokes it at once
export async function inviteApi(req, env, url, path) {
  const method = req.method;

  if (path === "/main/api/invites" && method === "GET") {
    const dir = cleanPath(url.searchParams.get("dir") || "");
    const out = [];
    for (const { hash, inv } of await allInvites(env)) {
      if (dir === null || inv.folder === dir) out.push({ ...pub(hash, inv), guest: await guestStatus(env, inv) });
    }

    out.sort((a, b) => a.created - b.created);
    return jsonResponse(out);
  }

  if (path === "/main/api/invites" && method === "POST") {
    let b;

    try {
      b = await req.json();
    } catch (e) {
      return new Response("Bad request", { status: 400 });
    }

    const name = String((b && b.name) || "").trim().slice(0, NAME_MAX);
    const folder = cleanPath(String((b && b.dir) || ""));
    const ttl = Number(b && b.ttl);

    if (!name) return new Response("Name needed", { status: 400 });
    // each invitee's name is theirs alone (notes 47), and never the owner's
    if (!guestName(name)) return new Response("That name is reserved", { status: 400 });
    if ((await liveInvites(env)).some((i) => String(i.name).toLowerCase() === name.toLowerCase())) {
      return new Response("Someone already has an invitation under that name", { status: 409 });
    }
    if (folder === null) return new Response("Bad folder", { status: 400 });
    if (!Number.isFinite(ttl) || ttl < 0 || ttl > TTL_MAX) return new Response("Bad expiry", { status: 400 });

    let items = null;
    if (b.items != null) {
      if (!Array.isArray(b.items) || !b.items.length || b.items.length > ITEMS_MAX) return new Response("Bad items", { status: 400 });
      items = [];
      for (const x of b.items) {
        const n = cleanPath(String(x || ""));
        if (!n || n.includes("/")) return new Response("Bad items", { status: 400 });
        if (!(await env.MAIN.head("files/" + (folder ? folder + "/" : "") + n))) return new Response("Not found: " + n, { status: 404 });
        if (!items.includes(n)) items.push(n);
      }
    }

    const token = newToken();
    const hash = await hashOf(token);
    const inv = {
      name,
      folder,
      created: Date.now(),
      expires: ttl ? Date.now() + ttl * 1000 : 0,
      perms: { view: true, download: true, upload: !items, comment: true, react: true, annotate: false },
    };
    // the owner may narrow (or widen annotate) when making it; upload never goes to a room
    if (b.perms && typeof b.perms === "object") for (const k of PERMS) if (typeof b.perms[k] === "boolean") inv.perms[k] = b.perms[k];
    if (items) inv.perms.upload = false;
    if (b.viewOnly === true) inv.viewOnly = true;
    if (items) inv.items = items;
    const view = viewOf(b);
    if (view) inv.view = view;

    await saveInvite(env, hash, inv);

    return jsonResponse({ ...pub(hash, inv), url: url.origin + "/m/" + token });
  }

  // GET /main/api/invites/locks -> { "<folder>": true }   PUT { dir, locked }  a folder's view-only lock
  if (path === "/main/api/invites/locks") {
    if (method === "GET") return jsonResponse(await readLocks(env));
    if (method !== "PUT") return new Response("Method not allowed", { status: 405 });
    let b;
    try {
      b = await req.json();
    } catch (e) {
      return new Response("Bad request", { status: 400 });
    }
    const dir = cleanPath(String((b && b.dir) || ""));
    if (dir === null || typeof b.locked !== "boolean") return new Response("Bad request", { status: 400 });
    if (hasDB(env)) {
      await locksGet(env); // copies the R2 locks in first, so the change lands on top of them
      await lockSet(env, dir, b.locked);
    } else {
      const locks = await readLocks(env);
      if (b.locked) locks[dir] = true;
      else delete locks[dir];
      await env.MAIN.put(LOCKS, JSON.stringify(locks), { httpMetadata: { contentType: "application/json" } });
    }
    return jsonResponse({ ok: true, locked: b.locked });
  }

  const m = path.match(/^\/main\/api\/invites\/([0-9a-f]+)$/);

  // PATCH /main/api/invites/<id>   body: { <perm>?: bool, viewOnly?: bool, overrides?: { <file>: { <perm>: bool|null } | null } }
  //   -> { ok, perms, viewOnly, overrides }
  if (m && method === "PATCH") {
    if (!ID_RE.test(m[1])) return new Response("Bad id", { status: 400 });
    let b;
    try {
      b = await req.json();
    } catch (e) {
      return new Response("Bad request", { status: 400 });
    }
    const found = await inviteById(env, m[1]);
    if (!found) return new Response("Not found", { status: 404 });
    const { hash, inv } = found;
    inv.perms = basePerms(inv);
    for (const k of PERMS) if (typeof b[k] === "boolean") inv.perms[k] = b[k];
    if (inv.items) inv.perms.upload = false;
    if (typeof b.viewOnly === "boolean") inv.viewOnly = b.viewOnly;
    if (b.overrides && typeof b.overrides === "object") {
      const ov = { ...(inv.overrides || {}) };
      for (const [n, o] of Object.entries(b.overrides)) {
        const name = cleanPath(String(n));
        if (!name || name.includes("/")) return new Response("Bad override", { status: 400 });
        if (o === null) {
          delete ov[name];
          continue;
        }
        if (typeof o !== "object") return new Response("Bad override", { status: 400 });
        const cur = { ...(ov[name] || {}) };
        for (const k of PERMS) {
          if (o[k] === null) delete cur[k];
          else if (typeof o[k] === "boolean") cur[k] = o[k];
        }
        if (Object.keys(cur).length) ov[name] = cur;
        else delete ov[name];
      }
      if (Object.keys(ov).length > ITEMS_MAX) return new Response("Too many overrides", { status: 400 });
      inv.overrides = ov;
    }
    await saveInvite(env, hash, inv);
    return jsonResponse({ ok: true, perms: inv.perms, viewOnly: !!inv.viewOnly, overrides: inv.overrides || {} });
  }

  // DELETE /main/api/invites/<id>/sessions   signs the guest out on every device (the invitation stays)
  const ms = path.match(/^\/main\/api\/invites\/([0-9a-f]{16})\/sessions$/);
  if (ms && method === "DELETE") {
    const found = await inviteById(env, ms[1]);
    const inv = found && found.inv;
    if (!inv) return new Response("Not found", { status: 404 });
    if (inv.guest) await endSessions(env, inv.guest);
    return jsonResponse({ ok: true });
  }

  if (m && method === "DELETE") {
    if (!ID_RE.test(m[1])) return new Response("Bad id", { status: 400 });

    if (!(await revokeInvite(env, m[1]))) return new Response("Not found", { status: 404 });
    return jsonResponse({ ok: true });
  }

  return new Response("Not found", { status: 404 });
}

// Revokes an invite by its public id: the link is the same 404 as any unknown one from now on.
export async function revokeInvite(env, id) {
  if (!ID_RE.test(id)) return false;
  if (hasDB(env)) {
    const inv = await shareRevoke(env, id);
    if (inv && inv.guest) await revokeGuest(env, inv.guest);
    return !!inv;
  }
  const r = await env.MAIN.list({ prefix: INVITES + id });
  if (!r.objects.length) return false;
  // the guest goes with it: every session ends and no email or passkey signs them back in
  for (const o of r.objects) {
    const inv = await readInvite(env, o.key);
    if (inv && inv.guest) await revokeGuest(env, inv.guest);
  }
  await env.MAIN.delete(r.objects.map((o) => o.key));
  return true;
}

// Every invite still alive, for the Shared section (shared.js): [{ id, name, folder, items, created, expires, perms }]
export async function liveInvites(env) {
  const now = Date.now();
  return (await allInvites(env)).filter(({ inv }) => !(inv.expires && inv.expires <= now)).map(({ hash, inv }) => pub(hash, inv));
}

// ---------- storage: D1 when bound (C1), else invites/<hash>.json in MAIN ----------

// Every invitation (expired ones too) as [{ hash, inv }].
async function allInvites(env) {
  if (hasDB(env)) return shareList(env);
  const out = [];
  let cursor;
  do {
    const r = await env.MAIN.list({ prefix: INVITES, cursor });
    for (const o of r.objects) {
      const inv = await readInvite(env, o.key);
      if (inv) out.push({ hash: o.key.slice(INVITES.length, -5), inv });
    }
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);
  return out;
}

async function inviteById(env, id) {
  if (hasDB(env)) return shareById(env, id);
  const r = await env.MAIN.list({ prefix: INVITES + id });
  const inv = r.objects.length === 1 && (await readInvite(env, r.objects[0].key));
  return inv ? { hash: r.objects[0].key.slice(INVITES.length, -5), inv } : null;
}

const saveInvite = (env, hash, inv) =>
  hasDB(env) ? sharePut(env, hash, inv) : env.MAIN.put(INVITES + hash + ".json", JSON.stringify(inv), { httpMetadata: { contentType: "application/json" } });

async function readInvite(env, key) {
  try {
    const o = await env.MAIN.get(key);
    const inv = o ? await o.json() : null;
    return inv && typeof inv.name === "string" && typeof inv.folder === "string" ? inv : null;
  } catch (e) {
    return null;
  }
}

// The live invite behind a token, or null (unknown, revoked or expired all look the same).
async function lookup(env, token) {
  if (!TOKEN_RE.test(token)) return null;

  const hash = await hashOf(token);
  const inv = hasDB(env) ? await shareGet(env, hash) : await readInvite(env, INVITES + hash + ".json");
  if (!inv || (inv.expires && inv.expires <= Date.now())) return null;

  return inv;
}

// ---------- participant: /m/<token>/… ----------

export async function participantRoute(req, env, ctx, url, path) {
  const m = path.match(/^\/m\/([A-Za-z0-9_-]+)(\/.*)?$/);
  const gone = () => notice("Link not found", 404);
  if (!m) return gone();

  const token = m[1];
  const rest = m[2] || "";
  const inv = await lookup(env, token);
  if (!inv) return gone();

  const method = req.method;
  const read = method === "GET" || method === "HEAD";
  const base = "/m/" + token;
  const invKey = INVITES + (await hashOf(token)) + ".json";
  const me = await sessionGuest(req, env, inv);

  // the calendar event: made from the invitation itself, so it ends exactly when access does
  if (rest === "/invite.ics" && read) {
    if (!inv.expires) return new Response("This invitation doesn’t expire", { status: 404 });
    return new Response(inviteIcs(inv, invKey.slice(INVITES.length, INVITES.length + 16), url.origin + base), {
      headers: { "content-type": "text/calendar; charset=utf-8", "content-disposition": 'attachment; filename="Gallery access.ics"', "cache-control": "no-store", "x-robots-tag": "noindex" },
    });
  }

  const am = rest.match(/^\/auth\/([A-Za-z0-9_-]+)$/);
  if (am) return authRoute(req, env, url, am[1], inv, base);
  if (rest.startsWith("/api/id/")) {
    if (!sameSite(req, url)) return new Response("Forbidden", { status: 403 });
    return identityApi(req, env, url, rest, inv, invKey, base, me);
  }

  // once someone has accepted the invitation, it opens only for them (signed in on any of their devices)
  if (inv.guest && !me) return read && !rest.startsWith("/api/") ? signInPage(inv, env) : new Response("Sign in first", { status: 401 });
  const inFolder = (name) => (inv.folder ? inv.folder + "/" : "") + name;
  const locked = await folderLocked(env, inv.folder);
  const P = (name) => permsFor(inv, name, locked);
  const allowed = (name) => (!inv.items || inv.items.includes(name)) && P(name).view;
  const hashId = invKey.slice(INVITES.length, INVITES.length + 16);

  if ((rest === "" || rest === "/") && read) {
    const items = (await listFolder(env, inv.folder)).items.filter((f) => allowed(f.path.split("/").pop()));
    items.forEach((f, i) => (f.n = String(i).padStart(5, "0")));

    // files are served through this link only, never through /main
    for (const f of items) {
      const name = f.path.split("/").pop();
      f.perms = P(name); // for the page's controls only; every request is checked again here
      f.src = base + "/f/" + encodeURIComponent(name);
      f.art = f.art ? f.src + f.art.slice(f.art.indexOf("?")) : null; // keeps the cover's version
    }

    const title = inv.items && items.length === 1 ? items[0].name : inv.folder ? inv.folder.split("/").pop() : "Gallery";

    return galleryPage({
      id: "invite",
      invite: { name: inv.name, perms: P(null), locked: locked || !!inv.viewOnly, expires: inv.expires || 0, room: !!inv.items, you: !!me, emailOn: emailOn(env), email: (me && me.email) || "", passkeys: me ? (me.passkeys || []).length : 0 },
      start: inv.items && items.length === 1 ? 0 : null,
      view: inv.view || null,
      api: base + "/api",
      dir: inv.folder,
      uploadMax: 90 * 1024 * 1024,
      owner: OWNER,
      title,
      heading: "Shared by " + OWNER,
      zip: title + ".zip",
      exp: inv.expires || 0,
      expected: items.length,
      ready: items.length,
      complete: true,
      items,
    });
  }

  const fm = rest.match(/^\/f\/([^/]+)$/);

  if (fm && read) {
    const name = cleanPath(fm[1], true);
    if (!name || name.includes("/") || !allowed(name)) return gone();
    // without download, media still plays in the page; saving it (?dl, or a file that only downloads) is refused
    if (!P(name).download && (url.searchParams.has("dl") || !PLAYABLE.test(name))) return new Response("Not allowed", { status: 403 });

    return mainFile(req, env, ctx, url, urlPath(inFolder(name)));
  }

  if (rest.startsWith("/api/")) {
    if (!sameSite(req, url)) return new Response("Forbidden", { status: 403 });

    // GET /m/<token>/api/transcript?name=<file>   Recense's transcript of a file in the folder
    if (rest === "/api/transcript" && read) {
      const name = cleanPath(url.searchParams.get("name") || "");
      if (!name || name.includes("/")) return new Response("Bad file name", { status: 400 });
      if (!allowed(name)) return new Response("Not allowed", { status: 403 });
      return transcriptResponse(env, inFolder(name), url.searchParams.get("f"));
    }

    // PUT /m/<token>/api/caption   same body as the owner's, path inside the folder
    if (rest === "/api/caption" && method === "PUT") {

      let b;
      try {
        b = await req.clone().json();
      } catch (e) {
        return new Response("Bad request", { status: 400 });
      }

      const rel = cleanPath(String((b && b.path) || ""));
      if (!b || b.kind !== "main" || !rel || rel !== inFolder(rel.split("/").pop()) || !allowed(rel.split("/").pop())) {
        return new Response("Not allowed", { status: 403 });
      }
      if (b.op !== "add" && b.op !== "del" && b.op !== "edit" && b.op !== "like") return new Response("Not allowed", { status: 403 });
      if (!P(rel.split("/").pop())[b.op === "like" ? "react" : "comment"]) return new Response("Not allowed", { status: 403 });

      // the first to write accepts the invitation and becomes its guest; after that only they (signed in) can
      let setCookie = "";
      if (!me) {
        const c = await claim(env, invKey, base);
        if (!c) return new Response("This invitation has already been accepted. Sign in instead.", { status: 401 });
        setCookie = c.cookie;
      }
      const r = await commentApi(req, env, inv.name, true, null, countryOf(req));
      if (setCookie) r.headers.append("set-cookie", setCookie);
      return r;
    }

    // GET /m/<token>/api/annotations?name=<file>     PUT { name, op: add|del, text?, t?, x?, y?, aid? }
    if (rest === "/api/annotations" && (read || method === "PUT")) {
      let b = null;
      if (!read) {
        try {
          b = await req.json();
        } catch (e) {
          return new Response("Bad request", { status: 400 });
        }
      }
      const name = cleanPath(String((read ? url.searchParams.get("name") : b && b.name) || ""));
      if (!name || name.includes("/")) return new Response("Bad file name", { status: 400 });
      if (!allowed(name) || !(await env.MAIN.head("files/" + inFolder(name)))) return new Response("Not found", { status: 404 });
      if (read) return jsonResponse({ items: (await readAnnotations(env, inFolder(name))).map((a) => annotationOf(a, hashId)) });
      if (!P(name).annotate) return new Response("Not allowed", { status: 403 });
      return annotationChange(env, inFolder(name), b, { by: inv.name, inv: hashId });
    }

    // GET /m/<token>/api/meta?name=<file>   the item's metadata, as the owner set it (read-only here)
    if (rest === "/api/meta" && read) {
      const name = cleanPath(url.searchParams.get("name") || "");
      if (!name || name.includes("/") || !allowed(name)) return new Response("Not found", { status: 404 });
      const m = await metaOf(env, inFolder(name));
      if (!m) return new Response("Not found", { status: 404 });
      // the history of changes is the owner's
      return jsonResponse({ ...m, path: name, revisions: [] });
    }

    // GET /m/<token>/api/geo?s=&w=&n=&e=   the folder's items with a place, only those this link may see
    if (rest === "/api/geo" && read) {
      const g = await folderGeo(env, inv.folder, allowed);
      return jsonResponse({ items: inBounds(g.items, url.searchParams).map((i) => ({ ...i, path: i.name })), pending: g.pending });
    }

    // PUT /m/<token>/api/file?name=<file>&mtime=<ms>   a new file only; nothing is ever replaced
    if (rest === "/api/file" && method === "PUT") {
      if (!P(null).upload) return new Response("Not allowed", { status: 403 });
      // a bad request must not accept the invitation (its cookie would be lost with the error)
      const name = cleanPath(url.searchParams.get("name") || "");
      if (!name || name.includes("/") || name.startsWith(".")) return new Response("Bad file name", { status: 400 });

      const key = inFolder(name);
      if (await env.MAIN.head("files/" + key)) return new Response("A file with that name is already here", { status: 409 });

      let setCookie = "";
      if (!me) {
        const c = await claim(env, invKey, base);
        if (!c) return new Response("This invitation has already been accepted. Sign in instead.", { status: 401 });
        setCookie = c.cookie;
      }

      const u = new URL(url);
      u.search = new URLSearchParams({ key, mtime: url.searchParams.get("mtime") || "" }).toString();
      const res = await mainUpload(req, env, u);
      if (res.ok) await logActivity(env, { type: "upload", by: inv.name, kind: "main", ref: key }).catch(() => {});
      if (setCookie) res.headers.append("set-cookie", setCookie);
      return res;
    }

    return new Response("Not found", { status: 404 });
  }

  // no write reaches the owner's files through a link (DELETE, PUT, MOVE … on /f/ or anywhere): the same 404
  return gone();
}

// A file in a folder was renamed: rooms that hold it keep holding it.
export async function renameInInvites(env, folder, from, to) {
  for (const { hash, inv } of await allInvites(env)) {
    if (inv.folder === folder && Array.isArray(inv.items) && inv.items.includes(from)) {
      inv.items = to == null ? inv.items.filter((x) => x !== from) : inv.items.map((x) => (x === from ? to : x));
      await saveInvite(env, hash, inv);
    }
  }
}
