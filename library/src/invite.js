// Invites: a private link for one person to one Main folder, outside Cloudflare Access.
//
// The owner makes them from Main (… > Invite). Each link is /m/<token>; the token is 32 random
// bytes and only its SHA-256 is stored, under invites/<hash>.json in MAIN:
//   { name, folder, items?, created, expires (ms, 0 = never), perms: { download, upload, comment } }
// items (file names in the folder) makes it a room: the person sees only those, and a room of one
// opens straight onto that item in the viewer. A room never takes uploads.
// The public id shown to the owner (for Revoke) is the first 16 hex of the hash.
// A participant can see and download the folder's files, upload new ones and comment, and
// delete only their own comments. They can never delete or replace the owner's files, see
// other folders, or reach /main. An unknown, expired or revoked link is the same 404.

import { OWNER, cleanPath, urlPath, notice, jsonResponse, viewOf } from "./common.js";
import { listFolder, mainFile, mainUpload } from "./main.js";
import { commentApi } from "./public.js";
import { galleryPage } from "./page/gallery.js";
import { sameSite } from "./access.js";
import { transcriptResponse } from "./transcript.js";

const INVITES = "invites/";
const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;
const ID_RE = /^[0-9a-f]{16}$/;
const NAME_MAX = 80;
const TTL_MAX = 365 * 86400;
const ITEMS_MAX = 500;

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
  perms: inv.perms,
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
    let cursor;

    do {
      const r = await env.MAIN.list({ prefix: INVITES, cursor });

      for (const o of r.objects) {
        const inv = await readInvite(env, o.key);
        if (inv && (dir === null || inv.folder === dir)) out.push(pub(o.key.slice(INVITES.length, -5), inv));
      }

      cursor = r.truncated ? r.cursor : undefined;
    } while (cursor);

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
      perms: { download: true, upload: !items, comment: true },
    };
    if (items) inv.items = items;
    const view = viewOf(b);
    if (view) inv.view = view;

    await env.MAIN.put(INVITES + hash + ".json", JSON.stringify(inv), {
      httpMetadata: { contentType: "application/json" },
    });

    return jsonResponse({ ...pub(hash, inv), url: url.origin + "/m/" + token });
  }

  const m = path.match(/^\/main\/api\/invites\/([0-9a-f]+)$/);

  if (m && method === "DELETE") {
    if (!ID_RE.test(m[1])) return new Response("Bad id", { status: 400 });

    const r = await env.MAIN.list({ prefix: INVITES + m[1] });
    if (!r.objects.length) return new Response("Not found", { status: 404 });

    await env.MAIN.delete(r.objects.map((o) => o.key));
    return jsonResponse({ ok: true });
  }

  return new Response("Not found", { status: 404 });
}

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

  const inv = await readInvite(env, INVITES + (await hashOf(token)) + ".json");
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
  const inFolder = (name) => (inv.folder ? inv.folder + "/" : "") + name;
  const allowed = (name) => !inv.items || inv.items.includes(name);

  if ((rest === "" || rest === "/") && read) {
    const items = (await listFolder(env, inv.folder)).items.filter((f) => allowed(f.path.split("/").pop()));
    items.forEach((f, i) => (f.n = String(i).padStart(5, "0")));

    // files are served through this link only, never through /main
    for (const f of items) {
      const name = f.path.split("/").pop();
      f.src = base + "/f/" + encodeURIComponent(name);
      f.art = f.art ? f.src + f.art.slice(f.art.indexOf("?")) : null; // keeps the cover's version
    }

    const title = inv.items && items.length === 1 ? items[0].name : inv.folder ? inv.folder.split("/").pop() : "Gallery";

    return galleryPage({
      id: "invite",
      invite: { name: inv.name, perms: inv.perms, expires: inv.expires || 0, room: !!inv.items },
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
    if (!inv.perms.download) return gone();

    const name = cleanPath(fm[1], true);
    if (!name || name.includes("/") || !allowed(name)) return gone();

    return mainFile(req, env, ctx, url, urlPath(inFolder(name)));
  }

  if (rest.startsWith("/api/")) {
    if (!sameSite(req, url)) return new Response("Forbidden", { status: 403 });

    // GET /m/<token>/api/transcript?name=<file>   Recense's transcript of a file in the folder
    if (rest === "/api/transcript" && read) {
      if (!inv.perms.download) return new Response("Not allowed", { status: 403 });
      const name = cleanPath(url.searchParams.get("name") || "");
      if (!name || name.includes("/")) return new Response("Bad file name", { status: 400 });
      if (!allowed(name)) return new Response("Not allowed", { status: 403 });
      return transcriptResponse(env, inFolder(name));
    }

    // PUT /m/<token>/api/caption   same body as the owner's, path inside the folder
    if (rest === "/api/caption" && method === "PUT") {
      if (!inv.perms.comment) return new Response("Not allowed", { status: 403 });

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
      if (b.op !== "add" && b.op !== "del" && b.op !== "edit") return new Response("Not allowed", { status: 403 });

      return commentApi(req, env, inv.name, true);
    }

    // PUT /m/<token>/api/file?name=<file>&mtime=<ms>   a new file only; nothing is ever replaced
    if (rest === "/api/file" && method === "PUT") {
      if (!inv.perms.upload || inv.items) return new Response("Not allowed", { status: 403 });

      const name = cleanPath(url.searchParams.get("name") || "");
      if (!name || name.includes("/") || name.startsWith(".")) return new Response("Bad file name", { status: 400 });

      const key = inFolder(name);
      if (await env.MAIN.head("files/" + key)) return new Response("A file with that name is already here", { status: 409 });

      const u = new URL(url);
      u.search = new URLSearchParams({ key, mtime: url.searchParams.get("mtime") || "" }).toString();
      return mainUpload(req, env, u);
    }

    return new Response("Not found", { status: 404 });
  }

  return read ? gone() : new Response("Method not allowed", { status: 405 });
}

// A file in a folder was renamed: rooms that hold it keep holding it.
export async function renameInInvites(env, folder, from, to) {
  let cursor;
  do {
    const r = await env.MAIN.list({ prefix: INVITES, cursor });
    for (const o of r.objects) {
      const inv = await readInvite(env, o.key);
      if (inv && inv.folder === folder && Array.isArray(inv.items) && inv.items.includes(from)) {
        inv.items = to == null ? inv.items.filter((x) => x !== from) : inv.items.map((x) => (x === from ? to : x));
        await env.MAIN.put(o.key, JSON.stringify(inv), { httpMetadata: { contentType: "application/json" } });
      }
    }
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);
}
