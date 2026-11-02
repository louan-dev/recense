// The public side: links anyone can open, backed by the PUBLIC bucket.
//
// Two kinds of link, both under /s/<id> and both temporary:
//   - upload links: files sent from the web page or the Mac, kept under links/<id>/
//   - folder links: a folder in Gallery/Public, kept under folders/<name>/
// Everything here expires and is deleted; nothing here reads or writes MAIN.

import { OWNER, ID_RE, FOLDER_MAX, JUNK, MIME_BY_EXT, IMG_BY_EXT, isAudioish, cleanPath, urlPath, notice, jsonResponse, serveObject, viewOf } from "./common.js";
import { extractArt } from "./art.js";
import { galleryPage } from "./page/gallery.js";
import { transcriptChanges, transcriptResponse, transcriptRun, transcriptSave } from "./transcript.js";
import { mainKeys, keyFields } from "./main.js";
import { logActivity, unlogLike } from "./shared.js";
import { liveInvites } from "./invite.js";

const LINKS = "links/";
const BLURS = ["off", "low", "medium", "high"];

// An upload that has shown no sign of life for this long is shown as "paused".
const STALL_MS = 15 * 60 * 1000;

// Daily: every upload-link object past its expiry goes.
const ARCHIVE_ROOT = "archive/"; // where the archive keeps what the app and /main/archive show

export async function cleanup(env) {
  const now = Date.now();
  let cursor;

  do {
    const r = await env.PUBLIC.list({
      prefix: LINKS,
      include: ["customMetadata"],
      cursor,
    });

    const dead = r.objects
      .filter(
        (o) =>
          o.customMetadata &&
          Number(o.customMetadata.expires) &&
          Number(o.customMetadata.expires) < now
      )
      .map((o) => o.key);

    if (dead.length) {
      await env.PUBLIC.delete(dead);
    }

    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);
}

// ---------- upload links ----------
//
// A link is a manifest written BEFORE any file is uploaded, so the gallery
// link works immediately. Items that are registered but not yet in R2 show up
// as "still uploading" placeholders and flip to real media the moment they land.

const manifestKey = (id) => LINKS + id + "/.manifest";

async function readManifest(env, id) {
  try {
    const mo = await env.PUBLIC.get(manifestKey(id));
    return mo ? await mo.json() : null;
  } catch (e) {
    return null;
  }
}

function writeManifest(env, manifest) {
  return env.PUBLIC.put(manifestKey(manifest.id), JSON.stringify(manifest), {
    httpMetadata: { contentType: "application/json" },
    customMetadata: { expires: String(Number(manifest.exp) || Date.now() + 7 * 864e5) },
  });
}

// What a link lets the people who open it do besides view, like and comment (notes 20261029 item 16):
//   upload    add files of their own (they expire with the link, like everything on the public side)
//   download  save files (?dl=1, Download, Save all)
// A link made from the archive is view-and-comment only until the owner turns these on (action=perms); any other
// upload link takes both. Folder links are never uploaded to.
export function linkPerms(manifest) {
  if (!manifest) return { upload: false, download: true };
  const fromArchive = (manifest.items || []).some((it) => it.lib === "archive");
  const p = manifest.perms || {};
  return { upload: p.upload ?? !fromArchive, download: p.download ?? !fromArchive, archive: fromArchive };
}

// POST /main/api/link?action=start&days=7        body: one item per line
//   "<size>\t<taken-ms>\t<type>\t<name>"  (type and name are encodeURIComponent'd)
//   -> { ok, id, exp, count, url }               the id is made here, never by the client
// POST /main/api/link?action=cancel&id=ID        marks unfinished items failed
// POST /main/api/link?action=folder&name=<folder in Public>&days=7
export async function linkApi(req, env, url) {
  const q = url.searchParams;
  const action = q.get("action") || "";

  if (action === "folder") return folderLinkApi(env, q);
  if (action === "fromMain") return fromMainLink(req, env, q);
  if (action === "copy") return copyFromMain(env, q);

  if (action === "start") {
    const id = newLinkId();
    const days = Math.min(365, Math.max(1, parseInt(q.get("days") || "", 10) || 7));
    const items = [];

    try {
      for (const line of (await req.text()).split("\n")) {
        if (!line.trim()) continue;

        const [size, taken, type, name] = line.replace(/\r$/, "").split("\t");

        items.push({
          i: items.length,
          size: Number(size) || 0,
          taken: Number(taken) || Date.now(),
          type: decodeURIComponent(type || "").slice(0, 200) || "application/octet-stream",
          name: decodeURIComponent(name || "").slice(0, 120) || "file",
        });
      }
    } catch (e) {
      return new Response("Bad item list", { status: 400 });
    }

    if (!items.length || items.length > 1000) {
      return new Response("Bad file count", { status: 400 });
    }

    const manifest = {
      id,
      owner: OWNER,
      created: Date.now(),
      exp: Date.now() + days * 864e5,
      count: items.length,
      items,
    };

    await writeManifest(env, manifest);

    return jsonResponse({ ok: true, id, exp: manifest.exp, count: items.length, url: "/s/" + id });
  }

  const id = q.get("id") || "";
  if (!ID_RE.test(id)) return new Response("Bad request", { status: 400 });

  // POST /main/api/link?action=arrange&id=ID   body: { order?: [n, …], cover?: n | null, v? }
  //   the owner's order for the link's items (the first picture is then the preview card's), and the
  //   pinned cover (null: back to the first picture); v is the stamp the copied link carries (?v=), so
  //   iMessage fetches the card again instead of showing the one it cached
  if (action === "arrange") {
    const manifest = await readManifest(env, id);
    if (!manifest) return new Response("Link not found", { status: 404 });

    let b;
    try {
      b = await req.json();
    } catch (e) {
      return new Response("Bad request", { status: 400 });
    }

    const known = new Set((manifest.items || []).map((it) => String(it.i).padStart(3, "0")));
    if (Array.isArray(b.order)) manifest.order = [...new Set(b.order.map(String))].filter((n) => known.has(n));
    if (b.cover === null) delete manifest.coverItem;
    else if (b.cover != null && known.has(String(b.cover))) manifest.coverItem = String(b.cover);
    if ("cover" in b) manifest.coverAt = Number(b.v) || Date.now();
    if (BLURS.includes(b.blur)) manifest.coverBlur = b.blur;

    await writeManifest(env, manifest);
    return jsonResponse({ ok: true, coverItem: manifest.coverItem || null, blur: manifest.coverBlur || "medium", v: manifest.coverAt || 0 });
  }

  // POST /main/api/link?action=perms&id=ID   body: { upload?, download? } -> { ok, perms }
  if (action === "perms") {
    const manifest = await readManifest(env, id);
    if (!manifest) return new Response("Link not found", { status: 404 });
    let b;
    try {
      b = await req.json();
    } catch (e) {
      return new Response("Bad request", { status: 400 });
    }
    const p = { ...(manifest.perms || {}) };
    for (const k of ["upload", "download"]) if (typeof b[k] === "boolean") p[k] = b[k];
    manifest.perms = p;
    await writeManifest(env, manifest);
    return jsonResponse({ ok: true, perms: linkPerms(manifest) });
  }

  if (action === "cancel") {
    const manifest = await readManifest(env, id);

    if (!manifest) return new Response("Link not found", { status: 404 });

    manifest.cancelled = Date.now();
    await writeManifest(env, manifest);

    return jsonResponse({ ok: true });
  }

  return new Response("Bad request", { status: 400 });
}

// POST /main/api/link?action=fromMain&days=7[&from=archive]   body: { paths: ["Folder/a.jpg", …], cover? } (files in Main, or
//   in the archive's archive/ with from=archive: the same link, the same page; archive files carry no keys or covers;
//   cover, one of paths or its index, is the picture the link's preview card shows, else its first image)
//   -> { ok, id, exp, count, url }   the link exists at once; its items show as pending until copied
// POST /main/api/link?action=copy&id=ID&i=N      copies item N from Main into the link (one file per call,
//   so a big video never has to fit in one request's time)
async function fromMainLink(req, env, q) {
  let b;

  try {
    b = await req.json();
  } catch (e) {
    return new Response("Bad request", { status: 400 });
  }

  let paths = Array.isArray(b && b.paths) ? b.paths : [];
  // "Folder/" is a whole folder in Main: every file under it (notes item 16, a picked Collections folder)
  if (q.get("from") !== "archive" && paths.some((p) => String(p).endsWith("/"))) {
    const out = [];
    for (const p of paths) {
      if (!String(p).endsWith("/")) { out.push(p); continue; }
      const dir = cleanPath(String(p).slice(0, -1));
      if (!dir) return new Response("Bad file path", { status: 400 });
      let cursor;
      do {
        const r = await env.MAIN.list({ prefix: "files/" + dir + "/", cursor });
        for (const o of r.objects) if (!o.key.split("/").some((x) => x.startsWith("."))) out.push(o.key.slice(6));
        cursor = r.truncated ? r.cursor : undefined;
      } while (cursor && out.length <= 1000);
    }
    paths = out;
  }
  if (!paths.length || paths.length > 1000) return new Response("Bad file count", { status: 400 });

  const days = Math.min(365, Math.max(1, parseInt(q.get("days") || "", 10) || 7));
  const archive = q.get("from") === "archive";
  if (q.get("from") && !archive) return new Response("Bad source", { status: 400 });
  const items = [];
  const keysByDir = new Map(); // each file's original key rides along into the link (Key slider labels)

  for (const p of paths) {
    const rel = cleanPath(String(p || ""));
    if (!rel || (archive && rel.split("/").some((x) => x.startsWith(".")))) return new Response("Bad file path", { status: 400 });

    const h = archive ? await env.ARCHIVE.head(ARCHIVE_ROOT + rel) : await env.MAIN.head("files/" + rel);
    if (!h) return new Response("Not found: " + rel, { status: 404 });

    const mtime = Number((h.customMetadata || {}).mtime);
    const dir = rel.split("/").slice(0, -1).join("/");
    if (!archive && !keysByDir.has(dir)) keysByDir.set(dir, await mainKeys(env, dir));
    const k = archive ? null : keyFields(keysByDir.get(dir)[rel.split("/").pop()]).key;

    items.push({
      i: items.length,
      size: h.size,
      taken: mtime > 0 ? Math.round(mtime * 1000) : h.uploaded.getTime(),
      type: (h.httpMetadata && h.httpMetadata.contentType) || "application/octet-stream",
      name: rel.split("/").pop().slice(0, 120),
      src: rel,
      ...(archive ? { lib: "archive" } : {}),
      ...(k ? { key: k } : {}),
    });
  }

  const id = newLinkId();
  const manifest = { id, owner: OWNER, created: Date.now(), exp: Date.now() + days * 864e5, count: items.length, items };
  const view = viewOf(b);
  if (view) manifest.view = view;
  const ci = b.cover == null ? -1 : typeof b.cover === "number" ? b.cover : items.findIndex((it) => it.src === cleanPath(String(b.cover)));
  if (ci >= 0 && ci < items.length) manifest.coverItem = String(ci).padStart(3, "0");

  await writeManifest(env, manifest);

  return jsonResponse({ ok: true, id, exp: manifest.exp, count: items.length, url: "/s/" + id });
}

async function copyFromMain(env, q) {
  const id = q.get("id") || "";
  const i = parseInt(q.get("i") || "", 10);
  if (!ID_RE.test(id) || !(i >= 0 && i < 1000)) return new Response("Bad request", { status: 400 });

  const manifest = await readManifest(env, id);
  const it = manifest && (manifest.items || []).find((x) => x.i === i);
  if (!it || !it.src) return new Response("Not found", { status: 404 });

  const key = LINKS + id + "/" + String(i).padStart(3, "0");
  if (await env.PUBLIC.head(key)) return jsonResponse({ ok: true });

  const archive = it.lib === "archive";
  const obj = archive ? await env.ARCHIVE.get(ARCHIVE_ROOT + it.src) : await env.MAIN.get("files/" + it.src);
  if (!obj) return new Response("Not found", { status: 404 });

  const { readable, writable } = new FixedLengthStream(obj.size);
  const copied = obj.body.pipeTo(writable);

  await env.PUBLIC.put(key, readable, {
    httpMetadata: { contentType: it.type },
    customMetadata: {
      name: encodeURIComponent(it.name),
      expires: String(manifest.exp),
      taken: String(it.taken),
      hasArt: "0",
    },
  });
  await copied;

  // a cover the owner chose or deleted in Main comes along (art/ is outside files/); the archive has none
  if (archive) return jsonResponse({ ok: true });
  const ah = await env.MAIN.head("art/" + it.src);
  const am = (ah && ah.customMetadata) || {};
  if (am.deleted === "1") {
    await putLinkCover(env, key, null);
  } else if (am.custom === "1") {
    const a = await env.MAIN.get("art/" + it.src);
    if (a) await putLinkCover(env, key, { data: new Uint8Array(await a.arrayBuffer()), mime: (a.httpMetadata && a.httpMetadata.contentType) || "image/jpeg" });
  }

  return jsonResponse({ ok: true });
}

// An upload-link item's cover, beside it (<n>.art), as Main has it: a picture, or none (pic null,
// the owner deleted it). It expires with the item. An item not copied yet gets it when it is.
async function putLinkCover(env, key, pic) {
  const head = await env.PUBLIC.head(key);
  if (!head) return;

  const meta = head.customMetadata || {};
  const stamp = { expires: meta.expires || "0", taken: meta.taken || String(Date.now()) };

  if (!pic) {
    await env.PUBLIC.put(key + ".art", new Uint8Array(0), { customMetadata: { ...stamp, name: "cover", none: "1", deleted: "1" } });
    return;
  }

  await env.PUBLIC.put(key + ".art", pic.data, {
    httpMetadata: { contentType: pic.mime },
    customMetadata: { ...stamp, name: encodeURIComponent("cover." + (pic.mime === "image/png" ? "png" : "jpg")) },
  });
}

// A Main file's cover changed (pic) or was deleted (null): every live upload link made from that
// file gets the same, so its grid matches Main's. Folder links show the Public bucket, not Main.
// a Main file renamed (or moved): links made from it show the new name everywhere, Activity included (notes item 16)
export async function renameInLinks(env, rel, to) {
  const now = Date.now();
  let cursor;
  do {
    const r = await env.PUBLIC.list({ prefix: LINKS, delimiter: "/", cursor });
    await Promise.all(
      (r.delimitedPrefixes || []).map(async (p) => {
        const id = p.slice(LINKS.length, -1);
        if (!ID_RE.test(id)) return;
        const manifest = await readManifest(env, id);
        if (!manifest || !(Number(manifest.exp) > now)) return;
        let hit = false;
        for (const it of manifest.items || []) if (it.src === rel) { it.src = to; it.name = to.split("/").pop().slice(0, 120); hit = true; }
        if (hit) await writeManifest(env, manifest);
      })
    );
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);
}

export async function syncLinkCovers(env, rel, pic) {
  const now = Date.now();
  let cursor;

  do {
    const r = await env.PUBLIC.list({ prefix: LINKS, delimiter: "/", cursor });

    await Promise.all(
      (r.delimitedPrefixes || []).map(async (p) => {
        const id = p.slice(LINKS.length, -1);
        if (!ID_RE.test(id)) return;

        const manifest = await readManifest(env, id);
        if (!manifest || !(Number(manifest.exp) > now)) return;

        for (const it of manifest.items || []) {
          if (it.src === rel) await putLinkCover(env, LINKS + id + "/" + String(it.i).padStart(3, "0"), pic);
        }
      })
    );

    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);
}

// GET /api/transcript?id=ID&n=NNN   an upload link's item made from a Main file: Recense's transcript of that file
// PUT /api/transcript?id=ID&n=NNN   a correction to it (anyone with the link; rate-limited per address)
// POST /api/transcript/run?id=ID&n=NNN   no transcript yet: ask Recense for one
async function linkSource(env, url) {
  const id = url.searchParams.get("id") || "";
  const n = url.searchParams.get("n") || "";
  if (!ID_RE.test(id) || !/^\d{3}$/.test(n)) return { error: new Response("Bad request", { status: 400 }) };

  const manifest = await readManifest(env, id);
  const it = manifest && manifest.exp > Date.now() && (manifest.items || []).find((x) => String(x.i).padStart(3, "0") === n);
  return { src: it && it.src ? it.src : null };
}

export async function linkTranscript(env, url) {
  const { src, error } = await linkSource(env, url);
  if (error) return error;
  if (!src) return jsonResponse({ none: true });
  return transcriptResponse(env, src, url.searchParams.get("f"));
}

export async function linkTranscriptChanges(env, url) {
  const { src, error } = await linkSource(env, url);
  if (error) return error;
  if (!src) return jsonResponse({ changes: [] });
  return transcriptChanges(env, src);
}

export async function linkTranscriptWrite(req, env, url, run) {
  // a header a page from another site can't send without asking first
  if (req.headers.get("x-gallery") !== "1") return new Response("Forbidden", { status: 403 });
  const { src, error } = await linkSource(env, url);
  if (error) return error;
  if (!src) return new Response("Not found", { status: 404 });
  return run ? transcriptRun(req, env, src, "share") : transcriptSave(req, env, src, "share");
}

// ---------- comments ----------
//
// One owner comment per item, shown under the picture strip: { text, at } (at = when it was written).
//   Main            notes/<folder>/.comments.json   { "<file name>": { text, at } }  (outside files/ and art/)
//   upload links    inside the link's manifest, on the item:  item.comment
//   folder links    index/note/<link id>.json       { "<path in folder>": { text, at } }
// Visitors only ever read them (they ride along in the item lists); only the owner can write.

const NOTES = "notes/";
const COMMENT_MAX = 4000;
const THREAD_MAX = 500;

// A stored value is either the old single comment { text, at } or { list: [{ id, text, at, by }] }.
export function thread(v) {
  if (!v || typeof v !== "object") return [];
  if (Array.isArray(v.list)) return v.list.filter((c) => c && c.text);
  return v.text ? [{ id: "c0", text: v.text, at: v.at || 0, by: OWNER }] : [];
}

// What every item list carries: the whole thread, plus caption/capAt (the first comment) for old pages.
export function commentFields(v) {
  const list = thread(v);
  return { caption: list.length ? list[0].text : "", capAt: list.length ? list[0].at : 0, comments: list, likes: likesOf(v) };
}

// Likes ride along with the thread: { list, likes: [{ by, at }] }, one per person.
const likesOf = (v) => (v && Array.isArray(v.likes) ? v.likes.filter((l) => l && l.by) : []);

// op "add" appends, op "edit" rewrites one of your own by id, op "del" removes one comment by id, op "like" turns your like
// on or off, no op replaces the thread with one comment (or none).
// Returns the new stored value (null = nothing left) or a string error.
// vid: a share link's guest (guestCommentApi); their comments and likes are theirs by vid, never by the name they typed
// cc: the connection's apparent country, from Cloudflare's edge (req.cf.country), never from the client. A VPN or proxy
// moves it, so it says where the comment came from, not who someone is.
export const countryOf = (req) => {
  const c = String((req && req.cf && req.cf.country) || "").toUpperCase();
  return /^[A-Z]{2}$/.test(c) && c !== "XX" && c !== "T1" ? c : "";
};

function applyComment(v, b, by, participant, vid = null, cc = "") {
  const text = String((b && b.text) || "").trim().slice(0, COMMENT_MAX);
  const list = thread(v);
  const likes = likesOf(v);
  // the owner may say whose words they are posting (notes 47): stored as "as", "by" stays the owner's so edit/delete still work
  // an invitee says who they are before posting (one invite link may be passed around); never the owner's name
  // invitees and guests post as who their link or cookie says, never a typed label
  const as = !participant && !vid && by === OWNER ? String((b && b.as) || "").trim().slice(0, 80) : "";
  const labelled = (c) => ({ ...c, ...(as ? { as } : {}), ...(cc ? { cc } : {}) });

  if (b.op === "like") {
    const i = likes.findIndex((l) => (vid ? l.vid === vid : l.by === by && !l.vid));
    if (i < 0) likes.push(vid ? { by, at: Date.now(), vid } : { by, at: Date.now() });
    else likes.splice(i, 1);
  } else if (b.op === "add") {
    if (!text) return "Empty comment";
    if (list.length >= THREAD_MAX) return "Too many comments";
    const id = "c" + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
    list.push(labelled(vid ? { id, text, at: Date.now(), by, vid } : { id, text, at: Date.now(), by }));
  } else if (b.op === "label") {
    // owner only, on the owner's own comments; an empty "as" gives the comment back to the owner's name
    if (participant || vid || by !== OWNER) return "Not allowed";
    const c = list.find((c) => c.id === String(b.cid || "") && (c.by || OWNER) === OWNER && !c.vid);
    if (!c) return "Comment not found";
    const name = String(b.as || "").trim().slice(0, 80);
    if (name) c.as = name;
    else delete c.as;
  } else if (b.op === "edit") {
    // only the comment's own author changes it (the owner too: never someone else's words)
    if (!text) return "Empty comment";
    const c = list.find((c) => c.id === String(b.cid || "") && (vid ? c.vid === vid : (c.by || OWNER) === by && !c.vid));
    if (!c) return "Comment not found";
    c.text = text;
    c.edited = Date.now();
  } else if (b.op === "del") {
    // a participant may only remove their own
    const i = list.findIndex((c) => c.id === String(b.cid || "") && (!participant || (vid ? c.vid === vid : c.by === by && !c.vid)));
    if (i < 0) return "Comment not found";
    list.splice(i, 1);
  } else {
    list.length = 0;
    if (text) list.push(labelled({ id: "c" + Date.now().toString(36), text, at: Date.now(), by }));
  }

  if (!list.length && !likes.length) return null;
  return likes.length ? { list, likes } : { list };
}

const noteKey = (id) => INDEX + "note/" + id + ".json";
const mainNotesKey = (dir) => NOTES + (dir ? dir + "/" : "") + ".comments.json";

async function readJson(bucket, key) {
  try {
    const o = await bucket.get(key);
    const j = o ? await o.json() : null;
    return j && typeof j === "object" ? j : {};
  } catch (e) {
    return {};
  }
}

// Writes (or, when the map is empty, removes) a { name: { text, at } } map.
async function saveMap(bucket, key, map) {
  if (!Object.keys(map).length) return bucket.delete(key);

  return bucket.put(key, JSON.stringify(map), { httpMetadata: { contentType: "application/json" } });
}

// The comments of one Main folder, by file name.
export const mainComments = (env, dir) => readJson(env.MAIN, mainNotesKey(dir));

// Main: a file went to the trash, so its comment goes too.
export async function dropMainComment(env, rel) {
  const dir = rel.split("/").slice(0, -1).join("/");
  const name = rel.split("/").pop();
  const map = await mainComments(env, dir);

  if (map[name]) {
    delete map[name];
    await saveMap(env.MAIN, mainNotesKey(dir), map);
  }
}

// Main: a file was renamed or moved to another folder, so its comments follow it.
export async function renameComment(env, rel, to) {
  const dir = rel.split("/").slice(0, -1).join("/");
  const toDir = to.split("/").slice(0, -1).join("/");
  const map = await mainComments(env, dir);
  const a = rel.split("/").pop();

  if (map[a]) {
    const there = toDir === dir ? map : await mainComments(env, toDir);
    there[to.split("/").pop()] = map[a];
    delete map[a];
    if (there !== map) await saveMap(env.MAIN, mainNotesKey(toDir), there);
    await saveMap(env.MAIN, mainNotesKey(dir), map);
  }
}

// PUT /main/api/caption   body: { kind: "main", path, ... }  or  { kind: "link", id, key, ... }
//   plus { op: "add", text, as? } to append (as: the owner names who said it),
//   { op: "label", cid, as } (owner only; empty as clears it), { op: "edit", cid, text } to rewrite your own, { op: "del", cid } to remove one, or { text } to replace
//   the whole thread (empty text clears it).  -> { ok, text, at, comments }
// by: who is writing (the owner, or an invited participant's name).
export async function commentApi(req, env, by = OWNER, participant = false, vid = null, cc = countryOf(req)) {
  let b;

  try {
    b = await req.json();
  } catch (e) {
    return new Response("Bad request", { status: 400 });
  }

  if (!b || typeof b !== "object") return new Response("Bad request", { status: 400 });

  // the stored value goes in, the new one comes out; null means remove
  const change = (v) => applyComment(v, b, by, participant, vid, cc);
  const done = async (v, where) => {
    const f = commentFields(v);
    // the Shared section's Activity: new comments, and likes turned on
    const liked = b.op === "like" && f.likes.some((l) => (vid ? l.vid === vid : l.by === by));
    if (b.op === "add" || liked) {
      const c = f.comments[f.comments.length - 1];
      await logActivity(env, { type: liked ? "like" : "comment", by: (!liked && c && c.as) || by, vid, ...where, text: liked || !c ? "" : c.text }).catch(() => {});
    } else if (b.op === "like") {
      await unlogLike(env, { by, vid, ...where }).catch(() => {}); // a like taken back leaves the feed too
    }
    return jsonResponse({ ok: true, ...f, text: f.caption, at: f.capAt });
  };
  const bad = (e) => new Response(e, { status: e === "Comment not found" ? 404 : e === "Not allowed" ? 403 : 400 });

  if (b.kind === "main") {
    const rel = cleanPath(b.path);
    if (!rel) return new Response("Bad file path", { status: 400 });
    if (!(await env.MAIN.head("files/" + rel))) return new Response("Not found", { status: 404 });

    const dir = rel.split("/").slice(0, -1).join("/");
    const name = rel.split("/").pop();
    const map = await mainComments(env, dir);
    const v = change(map[name]);
    if (typeof v === "string") return bad(v);

    if (v) map[name] = v;
    else delete map[name];

    await saveMap(env.MAIN, mainNotesKey(dir), map);
    return done(v, { kind: "main", ref: rel });
  }

  if (b.kind === "link") {
    const id = String(b.id || "");
    if (!ID_RE.test(id)) return new Response("Bad request", { status: 400 });

    const manifest = await readManifest(env, id);

    if (manifest) {
      const n = String(b.key || "");
      if (!/^\d{3}$/.test(n)) return new Response("Bad item", { status: 400 });

      const it = (manifest.items || []).find((x) => String(x.i).padStart(3, "0") === n);
      if (!it) return new Response("Not found", { status: 404 });

      const v = change(it.comment);
      if (typeof v === "string") return bad(v);

      if (v) it.comment = v;
      else delete it.comment;

      await writeManifest(env, manifest);
      return done(v, { kind: "link", ref: id, key: n, name: it.name || "" });
    }

    const link = await readLink(env, id);
    const rel = cleanPath(b.key);
    if (!link || !rel) return new Response("Not found", { status: 404 });
    if (!(await env.PUBLIC.head(FOLDERS + link.folder + "/" + rel))) return new Response("Not found", { status: 404 });

    const map = await readJson(env.PUBLIC, noteKey(id));
    const v = change(map[rel]);
    if (typeof v === "string") return bad(v);

    if (v) map[rel] = v;
    else delete map[rel];

    await saveMap(env.PUBLIC, noteKey(id), map);
    return done(v, { kind: "link", ref: id, key: rel });
  }

  return new Response("Bad request", { status: 400 });
}

// ---------- the owner's Shared section (shared.js) ----------

// Every link still alive: upload links (their manifest) and folder links (index/<id>.json).
export async function liveLinks(env) {
  const now = Date.now();
  const out = [];
  let cursor;

  do {
    const r = await env.PUBLIC.list({ prefix: LINKS, delimiter: "/", cursor });
    for (const p of r.delimitedPrefixes || []) {
      const id = p.slice(LINKS.length, -1);
      const m = ID_RE.test(id) ? await readManifest(env, id) : null;
      if (m && Number(m.exp) > now) out.push({ id, kind: "upload", created: Number(m.created) || 0, exp: Number(m.exp) });
    }
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);

  do {
    const r = await env.PUBLIC.list({ prefix: INDEX, delimiter: "/", cursor });
    for (const o of r.objects) {
      const link = await readLink(env, o.key.slice(INDEX.length).replace(/\.json$/, ""));
      if (link && link.exp > now) out.push({ id: link.id, kind: "folder", folder: link.folder, created: Number(link.created) || 0, exp: link.exp });
    }
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);

  return out;
}

// Expires a link now. An upload link's files are copies and go with it, as at its expiry; a folder
// link only stops working, and its Public folder then goes the way an expired one does (sweepFolders).
export async function expireLink(env, id) {
  if (!ID_RE.test(id)) return false;

  const manifest = await readManifest(env, id);
  if (manifest) {
    await deletePrefix(env, LINKS + id + "/");
    return true;
  }

  const link = await readLink(env, id);
  if (!link) return false;

  link.exp = Date.now() - 1;
  await env.PUBLIC.put(linkKey(id), JSON.stringify(link), { httpMetadata: { contentType: "application/json" } });
  return true;
}

// ---------- folder links (Gallery/Public on the Mac) ----------
//
// Everything under folders/<folder>/ is public. A folder gets its link the first time
// one is asked for (the Quick Action, or action=folder), or at the next cleanup if
// nobody asks, so nothing in Public outlives its expiry. When the link expires, the
// cleanup deletes the whole folder. Saving a file through the mount replaces the
// object and strips its R2 metadata, so the expiry lives in index/, never on the files.

const FOLDERS = "folders/";
const INDEX = "index/";
const FOLDER_DAYS = 7;
const FOLDER_DAYS_MAX = 30; // the bucket's lifecycle rule deletes anything in folders/ after 31 days
const LINK_ID_LEN = 20;

const linkKey = (id) => INDEX + id + ".json";
const folderKey = (folder) => INDEX + "folder/" + encodeURIComponent(folder);

function newLinkId() {
  const abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  const bytes = crypto.getRandomValues(new Uint8Array(LINK_ID_LEN * 2));
  let id = "";

  // 248 is the largest multiple of 62 under 256: rejecting the rest keeps every letter equally likely
  for (const b of bytes) {
    if (b < 248) id += abc[b % 62];
    if (id.length === LINK_ID_LEN) break;
  }

  return id.length === LINK_ID_LEN ? id : newLinkId();
}

async function readLink(env, id) {
  if (!ID_RE.test(id)) return null;

  try {
    const o = await env.PUBLIC.get(linkKey(id));
    const link = o ? await o.json() : null;
    return link && typeof link.folder === "string" && Number(link.exp) > 0 ? link : null;
  } catch (e) {
    return null;
  }
}

// One folder name at the top of Public, or null.
function folderName(s) {
  const name = String(s || "").normalize("NFC");

  if (!name || name.length > 200 || name.includes("/") || name === "." || name === "..") return null;
  if ([...name].some((ch) => ch.charCodeAt(0) < 32) || JUNK.test(name)) return null;

  return name;
}

async function folderHasFiles(env, folder) {
  const r = await env.PUBLIC.list({ prefix: FOLDERS + folder + "/", limit: 1 });
  return r.objects.length > 0;
}

// Deletes a public folder and its link.
async function purgeFolder(env, link) {
  await deletePrefix(env, FOLDERS + link.folder + "/");
  await env.PUBLIC.delete(noteKey(link.id)).catch(() => {});

  const idx = await env.PUBLIC.get(folderKey(link.folder));
  const owner = idx ? await idx.json().catch(() => null) : null;

  if (!owner || owner.id === link.id) await env.PUBLIC.delete(folderKey(link.folder));
  await env.PUBLIC.delete(linkKey(link.id));
}

// The folder's live link; a new one if it has none. An expired folder is deleted
// on the spot instead of being given a second life.
async function folderLink(env, folder, days) {
  const now = Date.now();
  const idx = await env.PUBLIC.get(folderKey(folder));

  if (idx) {
    const owner = await idx.json().catch(() => null);
    const link = owner && (await readLink(env, owner.id));

    if (link && link.exp > now) return link;

    if (link) {
      await purgeFolder(env, link);
      return { expired: true };
    }
  }

  const link = { id: newLinkId(), folder, created: now, exp: now + days * 864e5 };

  await env.PUBLIC.put(linkKey(link.id), JSON.stringify(link), {
    httpMetadata: { contentType: "application/json" },
  });
  await env.PUBLIC.put(folderKey(folder), JSON.stringify({ id: link.id }), {
    httpMetadata: { contentType: "application/json" },
  });

  return link;
}

// action=folder&name=<folder in Public>&days=7
//   -> { ok, id, exp, url }   the same link every time until it expires
async function folderLinkApi(env, q) {
  const folder = folderName(q.get("name"));
  if (!folder) return new Response("Bad folder name", { status: 400 });

  if (!(await folderHasFiles(env, folder))) {
    return new Response("That folder isn't in Public yet (or is empty)", { status: 404 });
  }

  const days = Math.min(FOLDER_DAYS_MAX, Math.max(1, parseInt(q.get("days") || "", 10) || FOLDER_DAYS));
  const link = await folderLink(env, folder, days);

  if (link.expired) {
    return new Response("This folder's link had expired, so the folder was deleted", { status: 410 });
  }

  return jsonResponse({ ok: true, id: link.id, exp: link.exp, url: "/s/" + link.id });
}

// Daily: expired links take their folders with them, and a folder nobody asked a
// link for gets one, so its clock starts. Loose files at the top of Public (not in
// any folder) have no link to hang an expiry on: they go once they are FOLDER_DAYS old.
export async function sweepFolders(env) {
  const now = Date.now();
  let cursor;

  do {
    const r = await env.PUBLIC.list({ prefix: INDEX, delimiter: "/", cursor });

    for (const o of r.objects) {
      const link = await readLink(env, o.key.slice(INDEX.length).replace(/\.json$/, ""));
      if (link && link.exp <= now) await purgeFolder(env, link);
    }

    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);

  cursor = undefined;

  do {
    const r = await env.PUBLIC.list({ prefix: FOLDERS, delimiter: "/", cursor });

    for (const p of r.delimitedPrefixes || []) {
      const folder = p.slice(FOLDERS.length, -1);
      if (folder && !(await env.PUBLIC.head(folderKey(folder)))) {
        await folderLink(env, folder, FOLDER_DAYS);
      }
    }

    const loose = r.objects
      .filter((o) => now - o.uploaded.getTime() > FOLDER_DAYS * 864e5)
      .map((o) => o.key);

    if (loose.length) await env.PUBLIC.delete(loose);

    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);
}

// A public folder as a gallery: whatever is in it right now, edits included.
async function folderGalleryData(env, link) {
  if (!(link.exp > Date.now())) return { expired: true };

  const prefix = FOLDERS + link.folder + "/";
  const objs = [];
  let cursor;

  do {
    const r = await env.PUBLIC.list({
      prefix,
      include: ["httpMetadata", "customMetadata"],
      cursor,
    });

    objs.push(...r.objects);
    cursor = r.truncated && objs.length < FOLDER_MAX ? r.cursor : undefined;
  } while (cursor);

  const notes = await readJson(env.PUBLIC, noteKey(link.id));

  const byName = (a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" });
  const niceName = (s) => s.replace(/\.[^/.]+$/, (x) => x.toUpperCase());
  /** @type {any[]} */
  const items = [];

  for (const o of objs.slice(0, FOLDER_MAX)) {
    const rel = o.key.slice(prefix.length);
    if (!rel || rel.split("/").some((x) => !x || JUNK.test(x))) continue;

    const name = rel.split("/").pop();
    const ext = (name.split(".").pop() || "").toLowerCase();
    let type = (o.httpMetadata && o.httpMetadata.contentType) || "";

    if (/^(|application\/octet-stream|binary\/octet-stream|text\/plain.*)$/.test(type)) {
      type = MIME_BY_EXT[ext] || IMG_BY_EXT[ext] || type || "application/octet-stream";
    }

    const mtime = Number((o.customMetadata || {}).mtime);
    // the file's version is part of its address, so an edit is never hidden by a cached copy
    const at = "/d/" + link.id + "/" + o.etag.replace(/[^A-Za-z0-9]/g, "").slice(0, 12) + "/" + urlPath(rel);

    items.push({
      name: niceName(rel),
      sortName: rel,
      path: rel,
      type,
      size: o.size,
      taken: mtime > 0 ? Math.round(mtime * 1000) : o.uploaded.getTime(),
      src: at,
      art: isAudioish(type, name) ? at + "?art=1" : null,
      ...commentFields(notes[rel]),
    });
  }

  if (!items.length) return { missing: true };

  items.sort((a, b) => byName(a.sortName, b.sortName));
  items.forEach((f, i) => {
    f.n = String(i).padStart(5, "0");
    delete f.sortName;
  });

  return {
    id: link.id,
    owner: OWNER,
    title: link.folder,
    zip: link.folder + ".zip",
    exp: link.exp,
    expected: items.length,
    ready: items.length,
    complete: true,
    items,
    ...(link.coverItem ? { coverItem: String(link.coverItem) } : {}),
  };
}

// GET /d/<id>/<version>/<path inside the folder>   (?art=1 for embedded artwork)
export async function folderFile(req, env, url, id, relEncoded) {
  const link = await readLink(env, id);
  if (!link) return notice("Link not found", 404);
  if (!(link.exp > Date.now())) return notice("Link expired", 410);

  const rel = cleanPath(relEncoded, true);
  if (!rel || rel.split("/").some((x) => JUNK.test(x))) return notice("Link not found", 404);

  const key = FOLDERS + link.folder + "/" + rel;
  const name = rel.split("/").pop();
  const ext = (name.split(".").pop() || "").toLowerCase();

  if (url.searchParams.get("art") === "1") {
    const head = await env.PUBLIC.head(key);
    let art = null;

    if (head && isAudioish(head.httpMetadata && head.httpMetadata.contentType, name)) {
      try {
        art = await extractArt(env.PUBLIC, key, head.size);
      } catch (e) {}
    }

    return art
      ? new Response(art.data.slice(), {
          headers: {
            "content-type": art.mime,
            "cache-control": "private, max-age=3600",
            "x-content-type-options": "nosniff",
          },
        })
      : new Response("No artwork", { status: 404, headers: { "cache-control": "private, max-age=3600" } });
  }

  let obj;

  try {
    obj = await env.PUBLIC.get(key, { range: req.headers });
  } catch (e) {
    return new Response("Bad range", { status: 416 });
  }

  if (!obj) return notice("Link not found", 404);

  return serveObject(req, url, obj, name, MIME_BY_EXT[ext] || IMG_BY_EXT[ext]);
}

// ---------- upload ----------
//
// Cloudflare rejects any single request body over 100 MB on the Free and Pro
// plans (413, before it reaches this Worker). Small files go up in one PUT.
// Big files use R2 multipart upload: start -> part, part, ... -> complete,
// with every part a separate, small request.

function target(q, sentType) {
  const id = q.get("id") || "";
  const i = parseInt(q.get("i") || "", 10);

  if (!ID_RE.test(id) || !(i >= 0 && i < 1000)) return null;

  const days = Math.min(365, Math.max(1, parseInt(q.get("days") || "", 10) || 7));
  const isArt = q.get("art") === "1";
  const n = String(i).padStart(3, "0");
  const key = LINKS + id + "/" + n + (isArt ? ".art" : "");

  const metadata = {
    name: encodeURIComponent(
      Array.from(q.get("name") || (isArt ? "cover.jpg" : "file")).slice(0, 120).join("")
    ),
    expires: String(Date.now() + days * 864e5),
    taken: String(Number(q.get("t")) || Date.now()),
  };

  if (!isArt) {
    metadata.hasArt = q.get("hasArt") === "1" ? "1" : "0";
  }

  // don't trust a generic type for files we can recognise by extension
  const sent = sentType || "";
  const ext = ((q.get("name") || "").split(".").pop() || "").toLowerCase();

  const contentType =
    !isArt && (!sent || sent === "application/octet-stream")
      ? MIME_BY_EXT[ext] || "application/octet-stream"
      : sent || "application/octet-stream";

  return { key, metadata, contentType };
}

export async function upload(req, env, url) {
  const q = url.searchParams;
  const action = q.get("action");

  if (action) return multipart(req, env, q, action);

  const t = target(q, req.headers.get("content-type"));

  if (!t) return new Response("Bad request", { status: 400 });

  await env.PUBLIC.put(t.key, req.body, {
    httpMetadata: { contentType: t.contentType },
    customMetadata: t.metadata,
  });

  return new Response("ok");
}

// Progress lives in a tiny side object so the gallery can show a ring without
// any extra reads: the list call that finds the files already returns it.
function setProgress(env, t, done, total) {
  if (t.key.endsWith(".art") || !(total >= 1 && total <= 10000)) {
    return Promise.resolve();
  }

  return env.PUBLIC.put(t.key + ".progress", new Uint8Array(0), {
    customMetadata: {
      done: String(done),
      total: String(total),
      expires: String(Date.now() + 2 * 864e5),
    },
  }).catch(() => {});
}

// best-effort: tidying up must never turn a finished upload into an error
async function dropProgress(env, t) {
  try {
    await env.PUBLIC.delete(t.key + ".progress");
  } catch (e) {}
}

// action=start    POST  -> uploadId (plain text)       ?total=N is optional
// action=part     PUT   -> etag     (plain text)       body = one chunk, ?total=N
// action=complete POST  -> "ok"                        body = [{partNumber, etag}, ...]
// action=abort    POST  -> "ok"
async function multipart(req, env, q, action, t = target(q, q.get("type"))) {

  if (!t) return new Response("Bad request", { status: 400 });

  const total = parseInt(q.get("total") || "", 10);

  if (action === "start") {
    const mp = await env.PUBLIC.createMultipartUpload(t.key, {
      httpMetadata: { contentType: t.contentType },
      customMetadata: t.metadata,
    });

    await setProgress(env, t, 0, total);

    return new Response(mp.uploadId);
  }

  const uploadId = q.get("uploadId") || "";

  if (!uploadId || uploadId.length > 1024) {
    return new Response("Bad request", { status: 400 });
  }

  const mp = env.PUBLIC.resumeMultipartUpload(t.key, uploadId);

  if (action === "part") {
    const n = parseInt(q.get("part") || "", 10);

    if (!(n >= 1 && n <= 10000) || !req.body) {
      return new Response("Bad request", { status: 400 });
    }

    try {
      const part = await mp.uploadPart(n, req.body);
      await setProgress(env, t, n, total);
      return new Response(part.etag);
    } catch (e) {
      return new Response("Part failed: " + (e && e.message), { status: 500 });
    }
  }

  if (action === "complete") {
    let parts;

    try {
      parts = await req.json();
    } catch (e) {
      return new Response("Bad request", { status: 400 });
    }

    const valid =
      Array.isArray(parts) &&
      parts.length >= 1 &&
      parts.length <= 10000 &&
      parts.every(
        (p) =>
          p &&
          Number.isInteger(p.partNumber) &&
          p.partNumber >= 1 &&
          p.partNumber <= 10000 &&
          typeof p.etag === "string" &&
          p.etag.length > 0 &&
          p.etag.length <= 200
      );

    if (!valid) return new Response("Bad request", { status: 400 });

    parts.sort((a, b) => a.partNumber - b.partNumber);

    try {
      await mp.complete(parts);
    } catch (e) {
      return new Response("Complete failed: " + (e && e.message), { status: 400 });
    }

    await dropProgress(env, t);

    return new Response("ok");
  }

  if (action === "abort") {
    try {
      await mp.abort();
    } catch (e) {}

    await dropProgress(env, t);

    return new Response("ok");
  }

  return new Response("Bad request", { status: 400 });
}

// ---------- file bytes ----------

export async function file(req, env, ctx, url, id, n) {
  if (!ID_RE.test(id)) {
    return notice("Link not found", 404);
  }

  const isArt =
    url.searchParams.get("art") === "1";

  const key =
    LINKS +
    id +
    "/" +
    n +
    (isArt ? ".art" : "");

  let obj;

  try {
    obj = await env.PUBLIC.get(key, {
      range: req.headers,
    });
  } catch (e) {
    return new Response("Bad range", {
      status: 416,
    });
  }

  if (!obj && isArt) {
    return artFromSource(env, ctx, id, n);
  }

  if (!obj) {
    return notice("Link not found", 404);
  }

  const meta =
    obj.customMetadata || {};

  if (
    Number(meta.expires) &&
    Date.now() > Number(meta.expires)
  ) {
    return notice("Link expired", 410);
  }

  if (!isArt && url.searchParams.get("dl") === "1" && !linkPerms(await readManifest(env, id)).download) {
    return new Response("Downloads are off for this link", { status: 403 });
  }

  if (isArt && meta.none === "1") {
    return new Response("No artwork", {
      status: 404,
      headers: { "cache-control": "private, max-age=3600" },
    });
  }

  return serveObject(req, url, obj, decodeURIComponent(meta.name || "file"));
}

// Serves /f/<id>/<n>?art=1 when no cover was uploaded: pull it out of the
// audio file once, then keep it next to the file so it expires with the link.
async function artFromSource(env, ctx, id, n) {
  const gone = () =>
    new Response("No artwork", {
      status: 404,
      headers: { "cache-control": "private, max-age=3600" },
    });

  const keep = (p) => {
    const safe = Promise.resolve(p).catch(() => {});
    if (ctx && ctx.waitUntil) ctx.waitUntil(safe);
  };

  const srcKey = LINKS + id + "/" + n;
  const head = await env.PUBLIC.head(srcKey);

  if (!head) return notice("Link not found", 404);

  const meta = head.customMetadata || {};

  if (Number(meta.expires) && Date.now() > Number(meta.expires)) {
    return notice("Link expired", 410);
  }

  const type = (head.httpMetadata && head.httpMetadata.contentType) || "";
  const name = decodeURIComponent(meta.name || "");

  if (!isAudioish(type, name)) return gone();

  let art = null;

  try {
    art = await extractArt(env.PUBLIC, srcKey, head.size);
  } catch (e) {}

  const artKey = srcKey + ".art";

  const stamp = {
    expires: meta.expires || "0",
    taken: meta.taken || String(Date.now()),
  };

  if (!art) {
    // remember "no artwork" so the next view skips the lookup
    keep(
      env.PUBLIC.put(artKey, new Uint8Array(0), {
        customMetadata: { ...stamp, name: "cover", none: "1" },
      })
    );

    return gone();
  }

  const ext =
    art.mime === "image/png"
      ? "png"
      : art.mime === "image/webp"
      ? "webp"
      : art.mime === "image/gif"
      ? "gif"
      : "jpg";

  const bytes = art.data.slice();

  keep(
    env.PUBLIC.put(artKey, bytes, {
      httpMetadata: { contentType: art.mime },
      customMetadata: {
        ...stamp,
        name: encodeURIComponent("cover." + ext),
      },
    })
  );

  return new Response(bytes, {
    headers: {
      "content-type": art.mime,
      "cache-control": "private, max-age=3600",
      "x-content-type-options": "nosniff",
    },
  });
}

// ---------- live gallery state ----------

// Merges what the uploader promised (the manifest) with what is actually in R2.
// Registered-but-missing items come back as { pending: true, progress, ... }.
export async function getGalleryData(env, id) {
  if (!ID_RE.test(id)) return { missing: true };

  const manifest = await readManifest(env, id);
  const objs = [];
  let cursor;

  do {
    const r = await env.PUBLIC.list({
      prefix: LINKS + id + "/",
      include: ["httpMetadata", "customMetadata"],
      cursor,
    });

    objs.push(...r.objects);
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);

  const ready = {};
  const progress = {};
  const arts = {};
  let lastActivity = manifest ? Number(manifest.created) || 0 : 0;

  for (const o of objs) {
    const m = o.key.match(/\/(\d{3})(\.art|\.progress)?$/);

    if (o.uploaded) lastActivity = Math.max(lastActivity, o.uploaded.getTime());

    if (!m) continue; // the manifest

    if (m[2] === ".progress") progress[m[1]] = o;
    else if (m[2] === ".art") arts[m[1]] = o;
    else if (!m[2]) ready[m[1]] = o;
  }

  const manifestItems = manifest && Array.isArray(manifest.items) ? manifest.items : [];
  const said = {};
  const keyOf = {};
  const byOf = {}; // a guest's own uploads: their name and vid

  manifestItems.forEach((it) => {
    if (it.comment) said[String(it.i).padStart(3, "0")] = it.comment;
    if (it.key) keyOf[String(it.i).padStart(3, "0")] = it.key;
    if (it.by) byOf[String(it.i).padStart(3, "0")] = { by: it.by, vid: it.vid };
  });

  if (!manifest && !Object.keys(ready).length) {
    // not an upload link: maybe a folder link
    const link = await readLink(env, id);
    return link ? folderGalleryData(env, link) : { missing: true };
  }

  const now = Date.now();
  const niceName = (s) => s.replace(/\.[^/.]+$/, (x) => x.toUpperCase());
  const items = [];

  for (const n of Object.keys(ready).sort()) {
    const o = ready[n];
    const meta = o.customMetadata || {};
    const exp = Number(meta.expires) || 0;

    if (exp && exp <= now) continue;

    let rawName = "file";
    try {
      rawName = decodeURIComponent(meta.name || "file");
    } catch (e) {}
    // a Main file renamed after it was shared: the manifest carries the new name (renameInLinks, notes item 16)
    const mi = manifestItems.find((it) => String(it.i).padStart(3, "0") === n);
    if (mi && mi.name) rawName = mi.name;

    const ctype =
      (o.httpMetadata && o.httpMetadata.contentType) || "application/octet-stream";

    // the cover's version is part of its address (the .art's etag, else the file's), so a cover
    // changed in Main is never hidden by a cached copy; a deleted one shows the file tile
    const ao = arts[n];
    const cover =
      ao && (ao.customMetadata || {}).deleted === "1"
        ? { art: null, nocover: true }
        : {
            art:
              meta.hasArt === "1" || isAudioish(ctype, rawName)
                ? "/f/" + id + "/" + n + "?art=1&v=" + String((ao || o).etag || "").replace(/[^A-Za-z0-9]/g, "").slice(0, 12)
                : null,
          };

    items.push({
      n,
      name: niceName(rawName),
      type: ctype,
      size: o.size,
      exp,
      taken: Number(meta.taken) || o.uploaded.getTime(),
      ...cover,
      ...commentFields(said[n]),
      ...(keyOf[n] ? { key: keyOf[n] } : {}),
      ...(byOf[n] ? { by: byOf[n].by, vid: byOf[n].vid } : {}),
    });
  }

  const readyNumbers = new Set(items.map((f) => f.n));
  const stalled = now - lastActivity > STALL_MS;
  const failed = !!(manifest && manifest.cancelled);

  for (const it of manifestItems) {
    const n = String(it.i).padStart(3, "0");

    if (readyNumbers.has(n) || ready[n]) continue; // ready (or expired) already

    const po = progress[n];
    const pm = po && po.customMetadata ? po.customMetadata : null;
    const total = pm ? Number(pm.total) : 0;

    items.push({
      n,
      name: niceName(it.name || "file"),
      type: it.type || "application/octet-stream",
      size: Number(it.size) || 0,
      taken: Number(it.taken) || now,
      ...commentFields(said[n]),
      ...(it.by ? { by: it.by, vid: it.vid } : {}),
      pending: true,
      progress: total > 0 ? Math.min(1, Number(pm.done) / total) : null,
      stalled: stalled && !failed,
      failed,
    });
  }

  // the owner's order (arrange), then the rest by number
  const rank = new Map(((manifest && manifest.order) || []).map((n, i) => [n, i]));
  const at = (f) => (rank.has(f.n) ? rank.get(f.n) : 1e6 + Number(f.n));
  items.sort((a, b) => at(a) - at(b));

  const readyItems = items.filter((f) => !f.pending);
  const expected = manifest ? Math.max(Number(manifest.count) || 0, items.length) : items.length;
  const manifestExp = manifest ? Number(manifest.exp) || 0 : 0;
  const exp = Math.max(manifestExp, ...readyItems.map((f) => f.exp), 0);

  if (exp && now > exp) return { expired: true };

  return {
    id,
    owner: OWNER,
    exp,
    expected,
    ready: readyItems.length,
    complete: readyItems.length >= expected,
    items: items.map(({ exp, ...f }) => f),
    ...(manifest && manifest.view ? { view: manifest.view } : {}),
    ...(manifest && manifest.coverItem ? { coverItem: String(manifest.coverItem) } : {}),
    ...(manifest && manifest.coverBlur ? { coverBlur: manifest.coverBlur } : {}),
    ...(manifest && manifest.order ? { order: manifest.order } : {}),
    ...(manifest && manifest.coverAt ? { coverAt: manifest.coverAt } : {}),
    perms: linkPerms(manifest),
  };
}

export async function galleryApi(env, url) {
  const data = await getGalleryData(env, url.searchParams.get("id") || "");

  if (!data || data.missing) return jsonResponse({ error: "Link not found" }, 404);
  if (data.expired) return jsonResponse({ error: "Link expired" }, 410);

  return jsonResponse(data);
}
export async function gallery(env, id, req) {
  const live = await getGalleryData(env, id);

  if (!live || live.missing) return notice("Link not found", 404);
  if (live.expired) return notice("Link expired", 410);

  const you = req ? await guestId(req) : null;
  return galleryPage(you ? { ...live, you } : live, "", "", req ? linkPreview(live, new URL(req.url)) : null);
}

// ---------- link previews (notes 20261029 item 3) ----------
// iMessage, Messenger and Telegram draw a big card from the Open Graph tags in /s/<id>'s <head> instead of a bare
// link with Safari's compass. The picture is GET /api/og-image/<id>[?cover=]: public, an hour's cache, any origin.
// Which picture: ?cover= (an item's number, path or name), else the link's coverItem, else its first image a
// card can show (jpeg/png/webp/gif, under Messenger's 8 MB), else any image, else a song's cover. None: a small card.
const OG_IMG = /^image\/(jpeg|png|webp|gif)$/;
const OG_MAX = 8 * 1024 * 1024;

function previewCover(live, want) {
  const items = (live.items || []).filter((f) => !f.pending);
  const is = (k) => (f) => k && (f.n === k || f.path === k || f.name === k || (/^\d+$/.test(k) && Number(f.n) === Number(k)));
  const asked = want && items.find(is(want));
  if (asked && (/^image\//.test(asked.type) || asked.art)) return asked;
  return (
    (live.coverItem && items.find(is(live.coverItem))) ||
    items.find((f) => OG_IMG.test(f.type) && !(f.size > OG_MAX)) ||
    items.find((f) => /^image\//.test(f.type)) ||
    items.find((f) => f.art) ||
    null
  );
}

function linkPreview(live, url) {
  const count = live.expected || (live.items || []).length;
  const want = url.searchParams.get("cover");
  const cover = previewCover(live, want);
  return {
    title: (live.title || count + (count === 1 ? " file" : " files") + " for you") + " · Shared by " + OWNER,
    description: "View and download shared files",
    url: url.href,
    // v: the cover's stamp, so a card cached under the old picture is fetched again
    image: cover
      ? url.origin + "/api/og-image/" + live.id + (want || live.coverAt ? "?" + new URLSearchParams({ ...(want ? { cover: want } : {}), ...(live.coverAt ? { v: String(live.coverAt) } : {}) }) : "")
      : null,
  };
}

// GET /api/og-image/<id>[?cover=]   the preview card's picture, streamed from the link's own copy in PUBLIC
export async function ogImage(env, ctx, url, id) {
  const none = (status) => new Response("No preview image", { status, headers: { "cache-control": "public, max-age=300", "access-control-allow-origin": "*" } });
  const live = await getGalleryData(env, id);
  if (!live || live.missing) return none(404);
  if (live.expired) return none(410);

  const f = previewCover(live, url.searchParams.get("cover"));
  if (!f) return none(404);

  const art = !/^image\//.test(f.type);
  const folder = !!f.path;
  const at = new URL((folder ? "/d/" + id + "/v/" + urlPath(f.path) : "/f/" + id + "/" + f.n) + (art ? "?art=1" : ""), url);
  const r = folder ? await folderFile(new Request(at), env, at, id, urlPath(f.path)) : await file(new Request(at), env, ctx, at, id, f.n);
  const type = (r.headers.get("content-type") || "").split(";")[0].trim();
  if (r.status !== 200 || !/^image\//.test(type)) return none(404);

  const h = { "content-type": type, "cache-control": "public, max-age=3600", "access-control-allow-origin": "*", "x-content-type-options": "nosniff" };
  const len = r.headers.get("content-length");
  if (len) h["content-length"] = len;
  return new Response(r.body, { headers: h });
}

// ---------- guests: whoever opens a share link may comment and like (notes 20261029 item 16) ----------
// A guest is a random 128-bit cookie (gv, HttpOnly, a year). Comments and likes keep only its hash (vid, 24 hex), so
// what a page reads can't be used to pass as someone. The name is what they typed the first time they commented: a
// label, never the owner's name or "You". A guest edits and deletes only their own comments; the owner deletes any.
// Each comment and like goes to the Shared section's Activity as "<name> · Guest".
//   PUT /api/caption   body: { kind: "link", id, key, op: add | edit | del | like, text?, cid?, name }
//                      -> what /main/api/caption answers, plus you: this guest's vid
const GUEST_RE = /(?:^|;\s*)gv=([0-9a-f]{32})(?:;|$)/;
const sha24 = async (s) => [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("guest:" + s)))].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 24);
export const guestId = async (req) => {
  const m = GUEST_RE.exec(req.headers.get("cookie") || "");
  return m ? sha24(m[1]) : null;
};
export function guestName(v) {
  const n = String(v || "").replace(/[\u0000-\u001f\u007f]/g, "").replace(/\s+/g, " ").trim().slice(0, 40);
  const l = n.toLowerCase();
  const taken = ["you", "owner", OWNER.toLowerCase(), OWNER.split(" ")[0].toLowerCase()];
  return n && !taken.includes(l) ? n : null;
}

export async function guestCommentApi(req, env, url) {
  const origin = req.headers.get("origin");
  if (origin ? origin !== url.origin : req.headers.get("x-gallery") !== "1") return new Response("Forbidden", { status: 403 });
  let b;
  try {
    b = await req.json();
  } catch (e) {
    return new Response("Bad request", { status: 400 });
  }
  if (!b || b.kind !== "link" || !["add", "edit", "del", "like"].includes(b.op)) return new Response("Bad request", { status: 400 });
  // only a live link takes comments
  const id = String(b.id || "");
  const manifest = ID_RE.test(id) ? await readManifest(env, id) : null;
  const link = manifest ? null : await readLink(env, id);
  if (!(manifest ? manifest.exp > Date.now() : link && link.exp > Date.now())) return new Response("Link expired", { status: 410 });

  let secret = (GUEST_RE.exec(req.headers.get("cookie") || "") || [])[1];
  const fresh = !secret;
  if (fresh) secret = [...crypto.getRandomValues(new Uint8Array(16))].map((x) => x.toString(16).padStart(2, "0")).join("");
  const vid = await sha24(secret);

  // the first name a guest gives is theirs for good: later ones are ignored, and nobody takes an invitee's name
  const nameKey = "guests/" + vid + ".json";
  const kept = fresh ? null : await env.MAIN.get(nameKey).then((o) => (o ? o.json() : null)).catch(() => null);
  let name = kept && kept.name;
  if (!name) {
    name = guestName(b.name);
    if (!name) return new Response("Choose a name to comment with", { status: 400 });
    const l = name.toLowerCase();
    if ((await liveInvites(env)).some((i) => String(i.name).toLowerCase() === l)) return new Response("That name is taken, choose another", { status: 409 });
    await env.MAIN.put(nameKey, JSON.stringify({ name, at: Date.now() }), { httpMetadata: { contentType: "application/json" } });
  }

  const inner = new Request(url, { method: "PUT", body: JSON.stringify(b), headers: { "content-type": "application/json" } });
  const r = await commentApi(inner, env, name, true, vid, countryOf(req));
  const out = r.ok ? jsonResponse({ ...(await r.json()), you: vid, youName: name }) : r;
  if (fresh && r.ok) out.headers.append("set-cookie", `gv=${secret}; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax`);
  return out;
}


// ---------- guests add to a link (notes 20261029 item 16) ----------
// Whoever opens an upload link whose perms allow it can add files: a life update, the papers for an errand. A file is
// reserved in the manifest first (so it shows as uploading to everyone), then sent in parts like the owner's.
// It expires with the link. Its uploader is the guest's name and vid; the upload shows in the owner's Activity.
//   POST /api/upload?action=reserve&id=ID   body: { name, size, type, taken?, who }  -> { ok, i, n, you }
//   /api/upload?action=start|part|complete|abort&id=ID&i=N&uploadId=…&part=…&total=…  as the owner's multipart
// A reservation is only this guest's (vid), and only until its file lands.
const GUEST_MAX = 5 * 1024 ** 3;

async function guestVid(req) {
  let secret = (GUEST_RE.exec(req.headers.get("cookie") || "") || [])[1];
  const fresh = !secret;
  if (fresh) secret = [...crypto.getRandomValues(new Uint8Array(16))].map((x) => x.toString(16).padStart(2, "0")).join("");
  return { secret, fresh, vid: await sha24(secret) };
}

export async function guestUploadApi(req, env, url) {
  const origin = req.headers.get("origin");
  if (origin ? origin !== url.origin : req.headers.get("x-gallery") !== "1") return new Response("Forbidden", { status: 403 });
  const q = url.searchParams;
  const action = q.get("action") || "";
  const id = q.get("id") || "";
  if (!ID_RE.test(id)) return new Response("Bad request", { status: 400 });

  const g = await guestVid(req);
  const manifest = await readManifest(env, id);
  if (!manifest || !(manifest.exp > Date.now())) return new Response("Link expired", { status: 410 });
  if (!linkPerms(manifest).upload) return new Response("Adding files is off for this link", { status: 403 });

  if (action === "reserve") {
    let b;
    try {
      b = await req.json();
    } catch (e) {
      return new Response("Bad request", { status: 400 });
    }
    const who = guestName(b.who);
    if (!who) return new Response("Choose a name first", { status: 400 });
    const size = Number(b.size) || 0;
    if (!(size > 0 && size <= GUEST_MAX)) return new Response("Files up to 5 GB", { status: 413 });

    // the manifest is read-modify-write: a write only lands on the version it was read from, else read again
    for (let tries = 0; tries < 6; tries++) {
      const mo = await env.PUBLIC.get(manifestKey(id));
      if (!mo) return new Response("Link not found", { status: 404 });
      const m = await mo.json();
      const items = Array.isArray(m.items) ? m.items : [];
      if (items.length >= 1000) return new Response("This link is full", { status: 409 });
      const i = items.reduce((x, it) => Math.max(x, Number(it.i) + 1), 0);
      if (i >= 1000) return new Response("This link is full", { status: 409 });
      items.push({
        i,
        size,
        taken: Number(b.taken) || Date.now(),
        type: String(b.type || "").slice(0, 200) || "application/octet-stream",
        name: Array.from(String(b.name || "file")).slice(0, 120).join(""),
        by: who,
        vid: g.vid,
      });
      m.items = items;
      m.count = Math.max(Number(m.count) || 0, items.length);
      const put = await env.PUBLIC.put(manifestKey(id), JSON.stringify(m), {
        onlyIf: { etagMatches: mo.etag },
        httpMetadata: { contentType: "application/json" },
        customMetadata: { expires: String(Number(m.exp) || Date.now() + 7 * 864e5) },
      });
      if (!put) continue;
      const out = jsonResponse({ ok: true, i, n: String(i).padStart(3, "0"), you: g.vid });
      if (g.fresh) out.headers.append("set-cookie", `gv=${g.secret}; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax`);
      return out;
    }
    return new Response("Busy, try again", { status: 503 });
  }

  if (!["start", "part", "complete", "abort"].includes(action)) return new Response("Bad request", { status: 400 });
  const i = parseInt(q.get("i") || "", 10);
  const it = (manifest.items || []).find((x) => Number(x.i) === i);
  if (!it || it.vid !== g.vid || g.fresh) return new Response("Not your file", { status: 403 });
  const n = String(i).padStart(3, "0");
  if (await env.PUBLIC.head(LINKS + id + "/" + n)) return new Response("Already sent", { status: 409 });

  const ext = (it.name.split(".").pop() || "").toLowerCase();
  const t = {
    key: LINKS + id + "/" + n,
    contentType: !it.type || it.type === "application/octet-stream" ? MIME_BY_EXT[ext] || IMG_BY_EXT[ext] || "application/octet-stream" : it.type,
    metadata: { name: encodeURIComponent(it.name), expires: String(manifest.exp), taken: String(it.taken || Date.now()), hasArt: "0" },
  };
  const r = await multipart(req, env, q, action, t);
  if (action === "complete" && r.ok) {
    await logActivity(env, { type: "upload", by: it.by, vid: it.vid, kind: "link", ref: id, key: n, name: it.name }).catch(() => {});
  }
  if (action === "abort") {
    // a file that will never come stops showing as uploading
    const m = await readManifest(env, id);
    if (m) {
      m.items = (m.items || []).filter((x) => Number(x.i) !== i);
      await writeManifest(env, m);
    }
  }
  return r;
}

// ---------- deleting (owner only) ----------

async function deletePrefix(env, prefix) {
  let cursor;

  do {
    const r = await env.PUBLIC.list({ prefix, cursor });
    const keys = r.objects.map((o) => o.key);
    if (keys.length) await env.PUBLIC.delete(keys);
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);
}

// DELETE /main/api/link?id=ID                     the whole link and its files, now
// DELETE /main/api/link?id=ID&item=…&item=…       chosen items only: an upload link's
//                                                 three-digit number, or a folder link's path
export async function deleteFromLink(env, url) {
  const q = url.searchParams;
  const id = q.get("id") || "";
  const picked = q.getAll("item");

  if (!ID_RE.test(id) || picked.length > 1000) return new Response("Bad request", { status: 400 });

  const manifest = await readManifest(env, id);
  const link = manifest ? null : await readLink(env, id);

  if (link) {
    if (!picked.length) {
      await purgeFolder(env, link);
      return jsonResponse({ ok: true, deleted: "link" });
    }

    const keys = [];

    for (const p of picked) {
      const rel = cleanPath(p);
      if (!rel) return new Response("Bad item", { status: 400 });
      keys.push(FOLDERS + link.folder + "/" + rel);
    }

    await env.PUBLIC.delete(keys);

    const notes = await readJson(env.PUBLIC, noteKey(link.id));
    let touched = false;

    for (const p of picked) {
      const rel = cleanPath(p);
      if (notes[rel]) {
        delete notes[rel];
        touched = true;
      }
    }

    if (touched) await saveMap(env.PUBLIC, noteKey(link.id), notes);

    return jsonResponse({ ok: true, deleted: keys.length });
  }

  const remaining = manifest && Array.isArray(manifest.items) ? manifest.items : [];

  if (!picked.length || (manifest && remaining.every((it) => picked.includes(String(it.i).padStart(3, "0"))))) {
    await deletePrefix(env, LINKS + id + "/");
    return jsonResponse({ ok: true, deleted: "link" });
  }

  if (!picked.every((n) => /^\d{3}$/.test(n))) return new Response("Bad item", { status: 400 });

  await env.PUBLIC.delete(picked.flatMap((n) => [n, n + ".art", n + ".progress"].map((x) => LINKS + id + "/" + x)));

  if (manifest) {
    manifest.items = remaining.filter((it) => !picked.includes(String(it.i).padStart(3, "0")));
    manifest.count = manifest.items.length;
    await writeManifest(env, manifest);
  }

  return jsonResponse({ ok: true, deleted: picked.length });
}