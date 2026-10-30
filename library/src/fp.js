// The File Provider's backend (docs/architecture.md §3), behind Access like the rest of /main. Slice 1: read-only.
//
//   GET /main/api/fp/<root>/items?path=<folder>[&cursor=…]   one folder's children, a page at a time
//   GET /main/api/fp/<root>/changes[?since=<seq>]            the events after <seq> and the new seq; no since: the seq
//                                                           to start from. 410: since is older than the log kept.
//   GET /main/api/fp/<root>/content?path=<file>              the bytes (Range works)
//
// R2 has no change feed, so the Worker keeps one in <bucket>/.catalog/<root>/: snapshot.json (the last full listing:
// id, path, size, etag, mtime per item) and log/<seq>.json (one batch of events per change). The reconciler lists the
// root, diffs it against the snapshot and appends what changed, so writes that went around the Worker (rclone straight
// to the bucket) are seen too. It runs when changes are asked for and the snapshot is older than RECONCILE_MS, one
// pass at a time.
//
// An item's id survives a rename through the Worker: a file's is customMetadata.fid when it has one, else "h" + 24 hex
// of sha-256(path); a folder's is "d" + the same. Paths are labels.
//
// The log is Sync's event-log format (sync/docs/specs/event-log.md), the same as sync's ledger.mjs journal: every
// event carries chain = sha-256(the previous chain + "\n" + the event's JSON), starting at GENESIS, and every batch its
// prev, so `node ledger.mjs verify --sink rclone:<remote>:<bucket>/.catalog/<root>` checks this log with the ledger's
// own code. Batches written before the chain have no prev; the verifier counts them and starts after them.
//
// The delete guard (event-log.md §5, the same numbers as ledger.mjs): a pass that would delete more than 100 files,
// or more than 10 that are also more than 10% of the root, logs nothing. It's held in held.json (changes says so)
// until the owner, signed in, POSTs …/confirm; until then no device removes anything.
//
//   POST /main/api/fp/<root>/confirm                     the owner lets the held pass through (409: nothing held)

import { cleanPath, jsonResponse, serveObject } from "./common.js";
import { sameSite, signedInAs } from "./access.js";

// a root: its bucket, the prefix its files live under ("" = the whole bucket), and where its catalog is kept.
// Paths and ids in the feed are relative to the prefix, so Main's "files/Music/x.mp3" is "Music/x.mp3".
export const FP_ROOTS = {
  archive: { bucket: "ARCHIVE", prefix: "", catalog: ".catalog/archive/" },
  main: { bucket: "MAIN", prefix: "files/", catalog: ".catalog/main/" },
};
// What is never content (sync/docs/specs/event-log.md §6; the same two lists as sync's ledger.mjs). JUNK_PATHS: the
// OS's own litter. CHURN_PATHS: one device's app state. Neither is listed, logged or synced; every other file is,
// dotfiles included (a vault's .obsidian/, a project's .gitignore).
export const JUNK_PATHS = [
  /(^|\/)\.DS_Store$/, /(^|\/)\._/, /(^|\/)\.Trash/, /(^|\/)\.localized$/, /(^|\/)Thumbs\.db$/i, /(^|\/)desktop\.ini$/i,
  /(^|\/)~\$/, /(^|\/)\.~lock\.[^/]*#$/, /(^|\/)Icon\r$/, /(^|\/)\.(Spotlight-V100|fseventsd|TemporaryItems|DocumentRevisions-V100)(\/|$)/,
];
export const CHURN_PATHS = [/(^|\/)\.obsidian\/workspace(-mobile)?\.json$/, /(^|\/)\.obsidian\/cache$/];
const MARK = ".folder-"; // Gallery's empty-folder marker (main.js): the folder is the item, not its marker
// Batches older than this leave log/ for history/: kept for good (the chain stays verifiable), but a device whose
// anchor is older than log/ gets 410 and enumerates again instead of replaying months.
const KEEP_MS = 30 * 24 * 3600 * 1000;
const COMPACT_MAX = 20; // batches moved per pass
export const GENESIS = "aeebad4a796fcc2e15dc4c6061b45ed9b373f26adfc798ca7d2d8cc58182718e"; // sha-256("genesis")
const GUARD = { files: 100, floor: 10, pct: 10 };
export const massDelete = (n, known) => n > GUARD.files || (n > GUARD.floor && n * 100 > known * GUARD.pct);
const CONFIRM_MS = 10 * 60 * 1000; // a confirmation covers the next pass within this time, and at most the deletes it was shown
const RECONCILE_MS = 60 * 1000;
const LOCK_MS = 5 * 60 * 1000;
const EVENTS_MAX = 50; // log entries per changes answer
const PAGE = 1000;

const hex = async (s) => [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))].map((b) => b.toString(16).padStart(2, "0")).join("");
export const fileId = async (path, meta) => (meta && /^[A-Za-z0-9_-]{8,64}$/.test(meta.fid || "") ? meta.fid : "h" + (await hex(path)).slice(0, 24));
export const folderId = async (path) => "d" + (await hex(path + "/")).slice(0, 24);
const seqKey = (n) => String(n).padStart(12, "0");
// one link of the chain: the same bytes as ledger.mjs hashes (`${chain}\n${JSON.stringify(event)}`)
export const link = (chain, event) => hex(`${chain}\n${JSON.stringify(event)}`);
const readJson = async (b, key) => {
  const o = await b.get(key);
  return o ? o.json() : null;
};
const bad = (status, msg) => new Response(msg, { status, headers: { "content-type": "text/plain; charset=utf-8" } });

// rel: a path inside the root. Never the bucket's own dot folders (.catalog, .trash, .uploads) on a whole-bucket root,
// never a folder marker, junk or churn.
export function visible(rel, root) {
  if (!root.prefix && rel.split("/")[0].startsWith(".")) return false;
  if (rel.split("/").pop().startsWith(MARK)) return false;
  return !JUNK_PATHS.some((x) => x.test(rel)) && !CHURN_PATHS.some((x) => x.test(rel));
}
// the content's md5 when R2 knows it without reading the bytes: a single-part upload's etag, or the md5 rclone stores
// for a multipart one (customMetadata.md5chksum, base64). The ledger records the same md5, so the two logs compare.
function md5Of(o) {
  if (/^[0-9a-f]{32}$/.test(o.etag || "")) return o.etag;
  const b64 = o.customMetadata && o.customMetadata.md5chksum;
  if (!b64) return undefined;
  try {
    const s = atob(b64);
    return s.length === 16 ? [...s].map((c) => c.charCodeAt(0).toString(16).padStart(2, "0")).join("") : undefined;
  } catch {
    return undefined;
  }
}
// whole seconds: rclone writes a fractional mtime ("1788075805.8020115")
const mtimeOf = (o) => Math.floor(Number(o.customMetadata && o.customMetadata.mtime) || o.uploaded.getTime() / 1000);
const parentOf = (p) => (p.includes("/") ? p.slice(0, p.lastIndexOf("/")) : "");

export async function fp(req, env, url, path) {
  const m = path.match(/^\/main\/api\/fp\/([a-z]+)\/(items|changes|content|confirm)$/);
  const root = m && FP_ROOTS[m[1]];
  if (!root) return bad(404, "Not found");
  const b = env[root.bucket];
  if (m[2] === "confirm") return confirm(req, env, url, b, root);
  if (req.method !== "GET" && req.method !== "HEAD") return bad(405, "Read-only for now");
  if (m[2] === "items") return items(b, root, url);
  if (m[2] === "changes") return changes(b, root, url);
  return content(req, b, root, url);
}

async function items(b, root, url) {
  const raw = url.searchParams.get("path") || "";
  const rel = raw ? cleanPath(raw) : "";
  if (rel === null || (rel && !visible(rel, root))) return bad(400, "Bad path");
  const prefix = root.prefix + (rel ? rel + "/" : "");
  const parent = rel ? await folderId(rel) : "root";
  const r = await b.list({ prefix, delimiter: "/", include: ["customMetadata"], cursor: url.searchParams.get("cursor") || undefined, limit: PAGE });
  const out = [];
  for (const p of r.delimitedPrefixes) {
    const path = p.slice(root.prefix.length, -1);
    if (visible(path, root)) out.push({ id: await folderId(path), parent, name: p.slice(prefix.length, -1), dir: true });
  }
  for (const o of r.objects) {
    const path = o.key.slice(root.prefix.length);
    if (!visible(path, root)) continue;
    out.push({ id: await fileId(path, o.customMetadata), parent, name: o.key.slice(prefix.length), dir: false, size: o.size, etag: o.httpEtag, md5: md5Of(o), mtime: mtimeOf(o) });
  }
  if (rel && !out.length && !r.truncated && !(await b.list({ prefix, limit: 1 })).objects.length) return bad(404, "No such folder");
  return jsonResponse({ parent, items: out, cursor: r.truncated ? r.cursor : null });
}

async function content(req, b, root, url) {
  const rel = cleanPath(url.searchParams.get("path") || "");
  if (!rel || !visible(rel, root)) return bad(400, "Bad path");
  const key = root.prefix + rel;
  let obj;
  try {
    obj = req.method === "HEAD" ? await b.head(key) : await b.get(key, { range: req.headers });
  } catch (e) {
    return bad(416, "Bad range");
  }
  if (!obj) return bad(404, "Not found");
  return serveObject(req, url, obj, rel.split("/").pop());
}

async function changes(b, root, url) {
  const raw = url.searchParams.get("since");
  const since = raw === null ? null : Number(raw);
  if (since !== null && !(Number.isSafeInteger(since) && since >= 0)) return bad(400, "Bad since");

  let snap = await readSnapshot(b, root);
  let held = await readJson(b, root.catalog + "held.json");
  const recent = (t) => Date.now() - t <= RECONCILE_MS;
  // a held pass is re-checked once a minute, like any other, not on every ask
  if (!snap || (!recent(snap.at) && !(held && recent(held.at)))) {
    snap = (await reconcile(b, root)) || snap || (await readSnapshot(b, root));
    held = snap && snap.held ? snap.held : await readJson(b, root.catalog + "held.json");
  }
  if (!snap) return bad(503, "Catalog is being built, try again");
  const hold = held ? { held: { deletes: held.deletes, known: held.known, at: held.at } } : {};
  if (since === null || since >= snap.seq) return jsonResponse({ seq: snap.seq, events: [], more: false, ...hold });

  const log = root.catalog + "log/";
  // after the anchor's own batch (its key ends in .json, so the bare number would list that batch first: a false 410)
  const r = await b.list({ prefix: log, startAfter: log + seqKey(since) + ".json", limit: EVENTS_MAX });
  const first = r.objects[0] && Number(r.objects[0].key.slice(log.length, -5));
  if (first !== since + 1) return bad(410, "Anchor expired: enumerate again");
  const events = [];
  let seq = since;
  for (const o of r.objects) {
    const n = Number(o.key.slice(log.length, -5));
    if (n !== seq + 1 || n > snap.seq) break;
    const batch = await readJson(b, o.key);
    if (!batch) break; // moved to history/ since the listing: answer what we have, the device asks again
    events.push(...batch.events);
    seq = n;
  }
  if (seq === since) return bad(410, "Anchor expired: enumerate again");
  return jsonResponse({ seq, events, more: seq < snap.seq, ...hold });
}

// the owner lets a held pass through: a person signed in to Access (a device's token has no email), from this site
async function confirm(req, env, url, b, root) {
  if (req.method !== "POST") return bad(405, "POST only");
  const who = await signedInAs(req, env);
  if (!who || !sameSite(req, url)) return bad(403, "Only the owner, signed in, confirms deletes");
  const held = await readJson(b, root.catalog + "held.json");
  if (!held) return bad(409, "Nothing is waiting for confirmation");
  await b.put(root.catalog + "confirm.json", JSON.stringify({ v: 1, at: Date.now(), by: who, deletes: held.deletes }));
  await b.delete(root.catalog + "held.json");
  return jsonResponse({ ok: true, deletes: held.deletes, sample: held.sample });
}

async function readSnapshot(b, root) {
  const o = await b.get(root.catalog + "snapshot.json");
  return o ? o.json() : null;
}

// one pass: list the root, diff against the snapshot, append the events, write the new snapshot. null: another pass holds the lock.
export async function reconcile(b, root, now = Date.now()) {
  const lockKey = root.catalog + "lock";
  const lock = await b.head(lockKey);
  if (lock && now - lock.uploaded.getTime() < LOCK_MS) return null;
  if (lock) await b.delete(lockKey);
  if (!(await b.put(lockKey, "", { onlyIf: { etagDoesNotMatch: "*" } }))) return null;
  try {
    const old = (await readSnapshot(b, root)) || { seq: 0, items: {}, at: 0, fresh: true };
    const items = {};
    const md5s = {}; // only for this pass's events: the snapshot stays small (etag is enough to see a change)
    const folders = new Set();
    let cursor;
    do {
      const r = await b.list({ prefix: root.prefix, include: ["customMetadata"], cursor, limit: PAGE });
      for (const o of r.objects) {
        const path = o.key.slice(root.prefix.length);
        if (!path || (!root.prefix && path.split("/")[0].startsWith("."))) continue;
        if (JUNK_PATHS.some((x) => x.test(path)) || CHURN_PATHS.some((x) => x.test(path))) continue;
        for (let p = parentOf(path); p; p = parentOf(p)) if (visible(p, root)) folders.add(p);
        if (!visible(path, root)) continue; // a folder marker: its folder counts (above), it doesn't
        const id = await fileId(path, o.customMetadata);
        items[id] = { path, size: o.size, etag: o.httpEtag, mtime: mtimeOf(o) };
        md5s[id] = md5Of(o);
      }
      cursor = r.truncated ? r.cursor : undefined;
    } while (cursor);
    for (const p of folders) items[await folderId(p)] = { path: p, dir: true };

    const events = [];
    for (const [id, it] of Object.entries(items)) {
      const was = old.items[id];
      const ev = { id, path: it.path, dir: !!it.dir, ...(it.dir ? {} : { size: it.size, etag: it.etag, md5: md5s[id], mtime: it.mtime }) };
      if (!was) events.push({ op: "create", ...ev });
      else if (was.path !== it.path) events.push({ op: "move", from: was.path, ...ev });
      else if (!it.dir && was.etag !== it.etag) events.push({ op: "modify", ...ev });
    }
    for (const [id, was] of Object.entries(old.items)) if (!items[id]) events.push({ op: "delete", id, path: was.path, dir: !!was.dir });

    // the delete guard: too many deletes at once (an emptied folder, a broken copy) log nothing until the owner confirms
    const gone = events.filter((e) => e.op === "delete" && !e.dir);
    const known = Object.values(old.items).filter((i) => !i.dir).length;
    if (!old.fresh && massDelete(gone.length, known)) {
      const ok = await readJson(b, root.catalog + "confirm.json");
      if (!ok || now - ok.at > CONFIRM_MS || ok.deletes < gone.length) {
        const held = { v: 1, at: now, deletes: gone.length, known, sample: gone.slice(0, 20).map((e) => e.path) };
        await b.put(root.catalog + "held.json", JSON.stringify(held));
        return { ...old, held };
      }
    }

    // the first pass is the baseline: clients start from it by enumerating, so it logs nothing
    let seq = old.seq;
    let chain = old.chain || GENESIS;
    if (events.length && !old.fresh) {
      const prev = chain;
      for (const e of events) e.chain = chain = await link(chain, e);
      seq += 1;
      const ok = await b.put(root.catalog + "log/" + seqKey(seq) + ".json", JSON.stringify({ v: 2, seq, at: now, prev, events }), { onlyIf: { etagDoesNotMatch: "*" } });
      if (!ok) return null;
      await b.delete(root.catalog + "confirm.json"); // a confirmation is spent by the pass it let through
    }
    const snap = { seq, at: now, chain, items };
    await b.put(root.catalog + "snapshot.json", JSON.stringify(snap));
    await compact(b, root, now);
    return snap;
  } finally {
    await b.delete(lockKey);
  }
}

// batches older than KEEP_MS move from log/ to history/, oldest first, a few per pass (one list and one read when
// there's nothing to move). Never deleted: `ledger.mjs verify` reads history/ and log/ as one chain.
async function compact(b, root, now) {
  const log = root.catalog + "log/";
  const r = await b.list({ prefix: log, limit: COMPACT_MAX });
  for (const o of r.objects) {
    const text = await (await b.get(o.key)).text();
    if (now - JSON.parse(text).at <= KEEP_MS) break;
    await b.put(root.catalog + "history/" + o.key.slice(log.length), text);
    await b.delete(o.key);
  }
}
