// An item's metadata (G5): what the file says (EXIF), the owner's non-destructive overrides, every change
// to them, and where the folder's items were taken (the map card).
//
//   GET /main/api/meta?path=<rel>         -> { original, overrides, effective, revisions }
//   PUT /main/api/meta { path, field, action, value?, rev? }
//        field   "time" (ms) · "location" ({ lat, lon, name? }) · "line:<n>" (a transcript line's text)
//        action  adjust (set it) · revoke (drop it: the file's own value shows again) · clear (blank it,
//                writing a revision first so it can be restored) · restore (a revision's earlier value back)
//   GET /main/api/geo?dir=<folder>&s=&w=&n=&e=   -> { items: [{ path, name, lat, lon }], pending }
// The file is never rewritten. With D1 bound the overrides and revisions live in metadata_overrides and
// revisions; without it in meta/<path>.json in MAIN. Invitees read the same through their link (invite.js).

import { OWNER, cleanPath, jsonResponse } from "./common.js";
import { hasDB } from "./d1.js";

const EXIF_BYTES = 256 * 1024;
const PARSE_MAX = 40; // EXIF reads per /geo request; the rest come with the next one (pending)
const FIELD_RE = /^(time|location|line:\d{1,5})$/;
const ACTIONS = ["adjust", "revoke", "clear", "restore"];
const JPEG_RE = /\.(jpe?g)$/i;

// ---------- EXIF (JPEG): time taken, GPS, camera, pixel size ----------

export function exifOf(buf) {
  const d = new DataView(buf);
  const out = {};
  if (d.byteLength < 4 || d.getUint16(0) !== 0xffd8) return out;
  let p = 2;
  while (p + 4 <= d.byteLength) {
    if (d.getUint8(p) !== 0xff) break;
    const mk = d.getUint8(p + 1);
    const len = d.getUint16(p + 2);
    if (mk === 0xe1 && d.getUint32(p + 4) === 0x45786966) tiff(d, p + 10, out); // "Exif"
    else if ((mk >= 0xc0 && mk <= 0xc3) || (mk >= 0xc5 && mk <= 0xcb)) {
      out.height = out.height || d.getUint16(p + 5);
      out.width = out.width || d.getUint16(p + 7);
    }
    if (mk === 0xda) break;
    p += 2 + len;
  }
  return out;
}

function tiff(d, t, out) {
  if (t + 8 > d.byteLength) return;
  const le = d.getUint16(t) === 0x4949;
  const u16 = (o) => d.getUint16(t + o, le);
  const u32 = (o) => d.getUint32(t + o, le);
  const str = (o, n) => {
    let s = "";
    for (let i = 0; i < n && t + o + i < d.byteLength; i++) {
      const c = d.getUint8(t + o + i);
      if (!c) break;
      s += String.fromCharCode(c);
    }
    return s.trim();
  };
  const rat = (o) => (u32(o + 4) ? u32(o) / u32(o + 4) : 0);
  const ifd = (o, fn) => {
    if (!o || t + o + 2 > d.byteLength) return;
    const n = u16(o);
    for (let i = 0; i < n; i++) {
      const e = o + 2 + i * 12;
      if (t + e + 12 > d.byteLength) return;
      const count = u32(e + 4);
      const val = count * ({ 1: 1, 2: 1, 3: 2, 4: 4, 5: 8 }[u16(e + 2)] || 1) > 4 ? u32(e + 8) : e + 8;
      fn(u16(e), val, count, e);
    }
  };
  let exif = 0;
  let gps = 0;
  ifd(u32(4), (tag, v, n, e) => {
    if (tag === 0x010f) out.make = str(v, n);
    else if (tag === 0x0110) out.model = str(v, n);
    else if (tag === 0x8769) exif = u32(e + 8);
    else if (tag === 0x8825) gps = u32(e + 8);
  });
  ifd(exif, (tag, v, n, e) => {
    if (tag === 0x9003) {
      const m = /^(\d{4}):(\d\d):(\d\d) (\d\d):(\d\d):(\d\d)/.exec(str(v, n));
      if (m) out.taken = Date.UTC(+m[1], m[2] - 1, +m[3], +m[4], +m[5], +m[6]); // camera clock, no zone
    } else if (tag === 0xa002) out.width = u16(e + 2) === 3 ? u16(e + 8) : u32(e + 8);
    else if (tag === 0xa003) out.height = u16(e + 2) === 3 ? u16(e + 8) : u32(e + 8);
  });
  const g = {};
  ifd(gps, (tag, v, n) => {
    if (tag === 1 || tag === 3) g[tag] = str(v, n);
    else if (tag === 2 || tag === 4) g[tag] = rat(v) + rat(v + 8) / 60 + rat(v + 16) / 3600;
  });
  if (Number.isFinite(g[2]) && Number.isFinite(g[4]) && (g[2] || g[4])) {
    out.lat = +(g[1] === "S" ? -g[2] : g[2]).toFixed(6);
    out.lon = +(g[3] === "W" ? -g[4] : g[4]).toFixed(6);
  }
}

async function readExif(env, rel) {
  if (!JPEG_RE.test(rel)) return {};
  try {
    const o = await env.MAIN.get("files/" + rel, { range: { offset: 0, length: EXIF_BYTES } });
    return o ? exifOf(await o.arrayBuffer()) : {};
  } catch (e) {
    return {};
  }
}

// ---------- overrides and revisions: D1, else meta/<path>.json ----------

const metaKey = (rel) => "meta/" + rel + ".json";

async function load(env, rel) {
  if (hasDB(env)) {
    const [o, r] = await env.DB.batch([
      env.DB.prepare("SELECT field, value FROM metadata_overrides WHERE bucket = 'main' AND path = ?").bind(rel),
      env.DB.prepare("SELECT id, field, action, before, after, at, by FROM revisions WHERE bucket = 'main' AND path = ? ORDER BY id DESC LIMIT 200").bind(rel),
    ]);
    return { overrides: Object.fromEntries(o.results.map((x) => [x.field, JSON.parse(x.value)])), revisions: r.results.map((x) => ({ ...x, before: x.before == null ? null : JSON.parse(x.before), after: x.after == null ? null : JSON.parse(x.after) })) };
  }
  try {
    const o = await env.MAIN.get(metaKey(rel));
    const j = o ? await o.json() : null;
    return { overrides: (j && j.overrides) || {}, revisions: (j && j.revisions) || [] };
  } catch (e) {
    return { overrides: {}, revisions: [] };
  }
}

// one change: the revision is written with (D1: in the same batch as) the override it describes
async function change(env, rel, field, action, before, after, by) {
  const at = Date.now();
  if (hasDB(env)) {
    const rev = env.DB.prepare("INSERT INTO revisions (bucket, path, field, action, before, after, at, by) VALUES ('main', ?, ?, ?, ?, ?, ?, ?)").bind(
      rel, field, action, before == null ? null : JSON.stringify(before), after == null ? null : JSON.stringify(after), at, by
    );
    const set =
      after == null
        ? env.DB.prepare("DELETE FROM metadata_overrides WHERE bucket = 'main' AND path = ? AND field = ?").bind(rel, field)
        : env.DB.prepare("INSERT INTO metadata_overrides (bucket, path, field, value, updated_at) VALUES ('main', ?, ?, ?, ?) ON CONFLICT (bucket, path, field) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at").bind(rel, field, JSON.stringify(after), at);
    await env.DB.batch([rev, set]);
    return;
  }
  const m = await load(env, rel);
  const id = (m.revisions.reduce((x, r) => Math.max(x, r.id), 0) || 0) + 1;
  m.revisions.unshift({ id, field, action, before, after, at, by });
  if (after == null) delete m.overrides[field];
  else m.overrides[field] = after;
  await env.MAIN.put(metaKey(rel), JSON.stringify(m), { httpMetadata: { contentType: "application/json" } });
}

function originalOf(head, ex, rel) {
  return {
    name: rel.split("/").pop(),
    type: (head && head.httpMetadata && head.httpMetadata.contentType) || "",
    size: head ? head.size : 0,
    taken: ex.taken || ms(Number((head && head.customMetadata && head.customMetadata.mtime) || 0)) || (head ? head.uploaded.getTime() : 0),
    lat: ex.lat ?? null,
    lon: ex.lon ?? null,
    make: ex.make || "",
    model: ex.model || "",
    width: ex.width || 0,
    height: ex.height || 0,
  };
}

// a modified time is milliseconds, but some clients store seconds (read as milliseconds that is January 1970)
const ms = (t) => (t > 0 && t < 1e11 ? t * 1000 : t);

const effectiveOf = (orig, ov) => {
  const e = { taken: orig.taken, lat: orig.lat, lon: orig.lon, place: "" };
  if ("time" in ov) e.taken = ov.time === "" ? null : Number(ov.time);
  if ("location" in ov) {
    const l = ov.location;
    if (l === "") Object.assign(e, { lat: null, lon: null, place: "" });
    else Object.assign(e, { lat: l.lat, lon: l.lon, place: l.name || "" });
  }
  return e;
};

export async function metaOf(env, rel) {
  const head = await env.MAIN.head("files/" + rel);
  if (!head) return null;
  const original = originalOf(head, await readExif(env, rel), rel);
  const m = await load(env, rel);
  return { path: rel, original, overrides: m.overrides, effective: effectiveOf(original, m.overrides), revisions: m.revisions };
}

const validValue = (field, v) => {
  if (field === "time") return Number.isFinite(Number(v)) && Number(v) > 0 && Number(v) < 4102444800000 ? Number(v) : undefined;
  if (field === "location") {
    if (!v || typeof v !== "object") return undefined;
    const lat = Number(v.lat);
    const lon = Number(v.lon);
    if (!(lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180)) return undefined;
    return { lat: +lat.toFixed(6), lon: +lon.toFixed(6), name: String(v.name || "").slice(0, 120) };
  }
  const s = String(v ?? "").slice(0, 2000);
  return s.trim() ? s : undefined;
};

// GET/PUT /main/api/meta (owner)
export async function metaApi(req, env, url, by = OWNER) {
  if (req.method === "GET") {
    const rel = cleanPath(url.searchParams.get("path") || "");
    const m = rel && (await metaOf(env, rel));
    return m ? jsonResponse(m) : new Response("Not found", { status: 404 });
  }
  if (req.method !== "PUT") return new Response("Method not allowed", { status: 405 });
  let b;
  try {
    b = await req.json();
  } catch (e) {
    return new Response("Bad request", { status: 400 });
  }
  const rel = cleanPath(String((b && b.path) || ""));
  const field = String((b && b.field) || "");
  const action = String((b && b.action) || "");
  if (!rel || !FIELD_RE.test(field) || !ACTIONS.includes(action)) return new Response("Bad request", { status: 400 });
  const cur = await metaOf(env, rel);
  if (!cur) return new Response("Not found", { status: 404 });
  const was = field in cur.overrides ? cur.overrides[field] : null;

  if (action === "adjust") {
    const v = validValue(field, b.value);
    if (v === undefined) return new Response("Bad value", { status: 400 });
    await change(env, rel, field, "adjust", was, v, by);
  } else if (action === "revoke") {
    if (was === null) return new Response("Nothing to revoke", { status: 409 });
    await change(env, rel, field, "revoke", was, null, by);
  } else if (action === "clear") {
    // what showed before the blank is the revision's "before", so Restore brings it back
    const shown = was !== null ? was : field === "time" ? cur.original.taken : field === "location" ? (cur.original.lat == null ? null : { lat: cur.original.lat, lon: cur.original.lon, name: "" }) : null;
    await change(env, rel, field, "clear", shown, "", by);
  } else {
    const r = cur.revisions.find((x) => x.id === Number(b.rev) && x.field === field);
    if (!r) return new Response("No such revision", { status: 404 });
    await change(env, rel, field, "restore", was, r.before, by);
  }
  return jsonResponse(await metaOf(env, rel));
}

// ---------- the map: where a folder's items are ----------

const geoKey = (dir) => "geo/" + (dir ? dir + "/" : "") + ".geo.json";

// Items of one folder with a place, as [{ path, name, lat, lon }]; `allowed(name)` filters (invitees).
// The EXIF of each picture is read once (per ETag) into geo/<dir>/.geo.json; location overrides win.
export async function folderGeo(env, dir, allowed = () => true) {
  const prefix = "files/" + (dir ? dir + "/" : "");
  const objs = [];
  let cursor;
  do {
    const r = await env.MAIN.list({ prefix, delimiter: "/", cursor });
    objs.push(...r.objects);
    cursor = r.truncated && objs.length < 5000 ? r.cursor : undefined;
  } while (cursor);

  let cache = {};
  try {
    const o = await env.MAIN.get(geoKey(dir));
    cache = (o && (await o.json())) || {};
  } catch (e) {}
  let parsed = 0;
  let pending = 0;
  for (const o of objs) {
    const name = o.key.slice(prefix.length);
    if (!JPEG_RE.test(name) || (cache[name] && cache[name].e === o.etag)) continue;
    if (parsed >= PARSE_MAX) {
      pending++;
      continue;
    }
    parsed++;
    const ex = await readExif(env, prefix.slice(6) + name);
    cache[name] = { e: o.etag, lat: ex.lat ?? null, lon: ex.lon ?? null };
  }
  if (parsed) await env.MAIN.put(geoKey(dir), JSON.stringify(cache), { httpMetadata: { contentType: "application/json" } });

  // the owner's moved pins
  const moved = {};
  if (hasDB(env)) {
    const { results } = await env.DB.prepare("SELECT path, value FROM metadata_overrides WHERE bucket = 'main' AND field = 'location' AND substr(path, 1, ?) = ?").bind(prefix.length - 6, prefix.slice(6)).all();
    for (const r of results) moved[r.path] = JSON.parse(r.value);
  } else {
    for (const o of objs) {
      const rel = o.key.slice(6);
      const m = await env.MAIN.head(metaKey(rel));
      if (m) moved[rel] = (await load(env, rel)).overrides.location;
    }
  }

  const items = [];
  for (const o of objs) {
    const name = o.key.slice(prefix.length);
    const rel = o.key.slice(6);
    if (!name || name.includes("/") || !allowed(name)) continue;
    let p = cache[name] && cache[name].lat != null ? { lat: cache[name].lat, lon: cache[name].lon } : null;
    if (rel in moved && moved[rel] !== undefined) p = moved[rel] === "" ? null : { lat: moved[rel].lat, lon: moved[rel].lon };
    if (p) items.push({ path: rel, name, lat: p.lat, lon: p.lon });
  }
  return { items, pending };
}

// ?s=&w=&n=&e= : only what is inside the view (a view across the antimeridian has w > e)
export function inBounds(items, q) {
  if (!["s", "w", "n", "e"].every((k) => q.has(k) && q.get(k) !== "")) return items;
  const s = Number(q.get("s"));
  const w = Number(q.get("w"));
  const n = Number(q.get("n"));
  const e = Number(q.get("e"));
  if (![s, w, n, e].every(Number.isFinite)) return items;
  return items.filter((i) => i.lat >= s && i.lat <= n && (w <= e ? i.lon >= w && i.lon <= e : i.lon >= w || i.lon <= e));
}

// GET /main/api/geo?dir=&s=&w=&n=&e= (owner)
export async function geoApi(env, url) {
  const dir = cleanPath(url.searchParams.get("dir") || "");
  if (dir === null) return new Response("Bad folder", { status: 400 });
  const g = await folderGeo(env, dir);
  return jsonResponse({ items: inBounds(g.items, url.searchParams), pending: g.pending });
}
