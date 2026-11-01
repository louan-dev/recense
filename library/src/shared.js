// The owner's Shared section (/main/shared): every live share link as an album tile, a tile's files with
// Delete (the link expires on the spot), and Activity (participant uploads, likes and comments, newest first).
// Owner-only: it lives under /main, behind Access and isOwner(); nothing here is reachable from the public side.
//
// A share is one of:
//   kind "link"   an upload link or a folder link, /s/<id> (PUBLIC; public.js)
//   kind "invite" a private invite to one Main folder, /m/<token> (MAIN; invite.js); its token is never shown again
//
// GET    /main/api/shares                  -> { shares: [{ kind, id, type, title, who, url, created, exp, count, cover, coverVideo }] }
// GET    /main/api/shares/<kind>/<id>      -> { share: { …, items: [{ ref, name, type, size, taken, src, thumb, video, pending }] } }
// DELETE /main/api/shares/<kind>/<id>      expires it now -> { ok: true }
// PATCH  /main/api/shares/<kind>/<id>      body: { upload?, download? } the owner's overrides -> { ok, perms }
// GET    /main/api/activity                -> { events: [{ type, by, who, at, text, count, share: { kind, id, title }, items }] }
//
// Activity events are empty objects under activity/<inverted time>-<rand> in MAIN, their fields in customMetadata, so
// one listing reads the newest first. Logged where things happen: comments and likes (public.js commentApi), a
// participant's upload (invite.js). An event whose share is gone is not shown; the daily sweep drops old ones.

import { OWNER, IMG_BY_EXT, MIME_BY_EXT, jsonResponse, page, esc } from "./common.js";
import { getGalleryData, liveLinks, expireLink, linkApi } from "./public.js";
import { liveInvites, revokeInvite, inviteApi } from "./invite.js";
import { listFolder } from "./main.js";
import js from "./client/sharedview.js";
import css from "./client/sharedview.css";

const ACTIVITY = "activity/";
const KEEP_MS = 90 * 864e5;
const SHOWN = 300;
const GROUP_MS = 30 * 60 * 1000; // one person's uploads to one share this close together are one row

export async function logActivity(env, ev) {
  const now = Date.now();
  const key = ACTIVITY + String(1e15 - now).padStart(15, "0") + "-" + Math.random().toString(36).slice(2, 8);
  const meta = { type: ev.type, by: String(ev.by || OWNER).slice(0, 80), at: String(now), kind: ev.kind, ref: String(ev.ref || "").slice(0, 900) };
  if (ev.key) meta.key = String(ev.key).slice(0, 400);
  if (ev.name) meta.name = String(ev.name).slice(0, 200);
  if (ev.text) meta.text = String(ev.text).slice(0, 240);
  if (ev.vid) meta.vid = String(ev.vid).slice(0, 24); // a share link's guest (public.js guestCommentApi)
  await env.MAIN.put(key, new Uint8Array(0), { customMetadata: meta });
}

// A like taken back: its event goes (the newest SHOWN events are where it can be).
export async function unlogLike(env, ev) {
  const r = await env.MAIN.list({ prefix: ACTIVITY, include: ["customMetadata"], limit: SHOWN });
  const same = (m) => m.type === "like" && (ev.vid ? m.vid === ev.vid : m.by === String(ev.by || OWNER).slice(0, 80) && !m.vid) && m.kind === ev.kind && m.ref === String(ev.ref || "").slice(0, 900) && (m.key || "") === String(ev.key || "").slice(0, 400);
  const keys = r.objects.filter((o) => same(o.customMetadata || {})).map((o) => o.key);
  if (keys.length) await env.MAIN.delete(keys);
}

// Daily: events older than KEEP_MS go.
export async function activitySweep(env) {
  const cut = Date.now() - KEEP_MS;
  let cursor;

  do {
    const r = await env.MAIN.list({ prefix: ACTIVITY, include: ["customMetadata"], cursor });
    const old = r.objects.filter((o) => Number((o.customMetadata || {}).at) < cut).map((o) => o.key);
    if (old.length) await env.MAIN.delete(old);
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);
}

const bare = (n) => String(n || "").replace(/\.[^/.]+$/, "");
const ext = (n) => (String(n).split(".").pop() || "").toLowerCase();
const typeOf = (f) => f.type || MIME_BY_EXT[ext(f.name)] || IMG_BY_EXT[ext(f.name)] || "";

function item(f, src, ref) {
  const type = typeOf(f);
  const ok = !f.pending;
  return {
    ref,
    name: f.name,
    type,
    size: f.size || 0,
    taken: f.taken || 0,
    src: ok ? src : null,
    thumb: ok ? f.art || (type.startsWith("image/") ? src : null) : null,
    video: ok && type.startsWith("video/") && !f.art,
    pending: !ok,
    comments: Array.isArray(f.comments) ? f.comments.length : 0,
    likes: Array.isArray(f.likes) ? f.likes.length : 0,
    ...(f.by ? { by: f.by } : {}),
  };
}

function shareOf(base, items) {
  const first = items.find((f) => f.thumb || f.video);
  return { ...base, count: items.length, cover: first ? first.thumb || first.src : null, coverVideo: !!(first && !first.thumb), items };
}

async function linkShare(env, l) {
  const d = await getGalleryData(env, l.id);
  if (!d || d.missing || d.expired) return null;

  const items = (d.items || []).map((f) => item(f, f.src || "/f/" + l.id + "/" + f.n, l.kind === "folder" ? f.path : f.n));
  const title =
    l.kind === "folder" ? l.folder : !items.length ? "Share Link" : items.length === 1 ? bare(items[0].name) : bare(items[0].name) + " & " + (items.length - 1) + " more";

  return shareOf({ kind: "link", id: l.id, type: l.kind, title, who: "", url: "/s/" + l.id, created: l.created, exp: l.exp, perms: d.perms || { upload: false, download: true } }, items);
}

async function inviteShare(env, inv) {
  const listed = await listFolder(env, inv.folder).catch(() => ({ items: [] }));
  const items = listed.items
    .filter((f) => !inv.items || inv.items.includes(f.path.split("/").pop()))
    .map((f) => item(f, f.src, f.path));
  const title = inv.items && items.length === 1 ? bare(items[0].name) : inv.folder ? inv.folder.split("/").pop() : "Main";

  const s = shareOf({ kind: "invite", id: inv.id, type: inv.items ? "room" : "invite", title, who: inv.name, url: null, created: inv.created, exp: inv.expires || 0, perms: { upload: !!(inv.perms || {}).upload && !inv.items, download: (inv.perms || {}).download !== false, room: !!inv.items } }, items);
  Object.defineProperty(s, "scope", { value: { folder: inv.folder, items: inv.items }, enumerable: false });
  return s;
}

// Every live share, newest first, with its items.
async function gather(env) {
  const [links, invites] = await Promise.all([liveLinks(env), liveInvites(env)]);
  const all = await Promise.all([...links.map((l) => linkShare(env, l)), ...invites.map((i) => inviteShare(env, i))]);
  return all.filter(Boolean).sort((a, b) => b.created - a.created);
}

const strip = ({ items, ...s }) => s;
const brief = (s) => ({ kind: s.kind, id: s.id, title: s.title });
const pic = (f) => ({ ref: f.ref, name: f.name, thumb: f.thumb, src: f.src, video: f.video, type: f.type });

async function activity(env) {
  const shares = await gather(env);
  const links = new Map(shares.filter((s) => s.kind === "link").map((s) => [s.id, s]));
  const invites = shares.filter((s) => s.kind === "invite");
  const files = new Map();
  for (const s of shares) for (const f of s.items) files.set(s.kind + ":" + s.id + ":" + f.ref, f);

  const r = await env.MAIN.list({ prefix: ACTIVITY, include: ["customMetadata"], limit: SHOWN });
  const events = [];

  for (const o of r.objects) {
    const m = o.customMetadata || {};
    let s = null;
    let f = null;

    if (m.kind === "link") {
      s = links.get(m.ref);
      f = s && files.get("link:" + s.id + ":" + (m.key || ""));
    } else if (m.kind === "main") {
      const dir = m.ref.split("/").slice(0, -1).join("/");
      const name = m.ref.split("/").pop();
      s = invites.find((i) => i.scope.folder === dir && (!i.scope.items || i.scope.items.includes(name)));
      f = s && files.get("invite:" + s.id + ":" + m.ref);
    }
    if (!s) continue;

    const at = Number(m.at) || 0;
    const by = m.by || OWNER;
    const one = f ? pic(f) : { ref: m.key || m.ref, name: m.name || m.ref.split("/").pop(), thumb: null, src: null, video: false, type: "" };
    const last = events[events.length - 1];

    // the listing runs newest first: an older upload by the same person to the same share joins the row above
    if (m.type === "upload" && last && last.type === "upload" && last.by === by && last.share.id === s.id && last.end - at < GROUP_MS) {
      last.count++;
      last.end = at;
      if (last.items.length < 4) last.items.push(one);
      continue;
    }

    events.push({ type: m.type, by, at, end: at, text: m.text || "", count: 1, share: brief(s), items: [one], ...(m.vid ? { guest: m.vid.slice(0, 4) } : {}) });
  }

  // each share's own start: "You shared 5 items"
  for (const s of shares) {
    events.push({ type: "share", by: OWNER, at: s.created, end: s.created, text: "", count: s.count, share: brief(s), items: s.items.filter((f) => f.thumb || f.video).slice(0, 4).map(pic), who: s.who });
  }

  events.sort((a, b) => b.at - a.at);
  return events.slice(0, SHOWN).map(({ end, ...e }) => ({ who: "", ...e, mine: e.by === OWNER }));
}

export async function sharesApi(req, env, url, path) {
  const method = req.method;
  const read = method === "GET" || method === "HEAD";

  if (path === "/main/api/activity" && read) return jsonResponse({ events: await activity(env) });
  if (path === "/main/api/shares" && read) return jsonResponse({ shares: (await gather(env)).map(strip) });

  const m = path.match(/^\/main\/api\/shares\/(link|invite)\/([A-Za-z0-9]{8,32})$/);
  if (!m) return new Response("Not found", { status: 404 });

  if (read) {
    const s = (await gather(env)).find((x) => x.kind === m[1] && x.id === m[2]);
    return s ? jsonResponse({ share: s }) : new Response("Not found", { status: 404 });
  }

  if (method === "PATCH") {
    const body = await req.text();
    const fwd = (u, meth) => new Request(new URL(u, url), { method: meth, body, headers: { "content-type": "application/json" } });
    return m[1] === "link" ? linkApi(fwd("/main/api/link?action=perms&id=" + m[2], "POST"), env, new URL("/main/api/link?action=perms&id=" + m[2], url)) : inviteApi(fwd("/main/api/invites/" + m[2], "PATCH"), env, url, "/main/api/invites/" + m[2]);
  }

  if (method === "DELETE") {
    const ok = m[1] === "link" ? await expireLink(env, m[2]) : await revokeInvite(env, m[2]);
    return ok ? jsonResponse({ ok: true }) : new Response("Not found", { status: 404 });
  }

  return new Response("Method not allowed", { status: 405 });
}

export function sharedPage(url) {
  const data = JSON.stringify({ owner: OWNER, origin: url.origin }).replace(/</g, "\\u003c");
  return page(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="darkreader-lock">
<meta name="theme-color" content="#000000">
<meta name="color-scheme" content="dark">
<meta name="robots" content="noindex">
<title>${esc("Shared")}</title>
<style>${css}</style>
</head>
<body>
<main id="app" aria-live="polite"></main>
<script>window.SHARED=${data};</script>
<script>${js}</script>
</body>
</html>`);
}
