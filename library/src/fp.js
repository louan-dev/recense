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

import { JUNK, cleanPath, jsonResponse, serveObject } from "./common.js";
import { sameSite, signedInAs } from "./access.js";

export const FP_ROOTS = { archive: { bucket: "ARCHIVE", catalog: ".catalog/archive/" } };
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

// nothing of the bucket's own (dot folders at its root: .catalog, .trash, .uploads) and no Finder or Windows files
function visible(key) {
  const parts = key.split("/");
  return !parts[0].startsWith(".") && !JUNK.test(parts[parts.length - 1]);
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
  if (m[2] === "items") return items(b, url);
  if (m[2] === "changes") return changes(b, root, url);
  return content(req, b, url);
}

async function items(b, url) {
  const raw = url.searchParams.get("path") || "";
  const rel = raw ? cleanPath(raw) : "";
  if (rel === null || (rel && !visible(rel + "/x"))) return bad(400, "Bad path");
  const prefix = rel ? rel + "/" : "";
  const parent = rel ? await folderId(rel) : "root";
  const r = await b.list({ prefix, delimiter: "/", include: ["customMetadata"], cursor: url.searchParams.get("cursor") || undefined, limit: PAGE });
  const out = [];
  for (const p of r.delimitedPrefixes) {
    const name = p.slice(prefix.length, -1);
    if (visible(p + "x")) out.push({ id: await folderId(p.slice(0, -1)), parent, name, dir: true });
  }
  for (const o of r.objects) {
    const name = o.key.slice(prefix.length);
    if (!visible(o.key) || name.startsWith(".folder-")) continue;
    out.push({ id: await fileId(o.key, o.customMetadata), parent, name, dir: false, size: o.size, etag: o.httpEtag, mtime: mtimeOf(o) });
  }
  if (rel && !out.length && !r.truncated && !(await b.list({ prefix, limit: 1 })).objects.length) return bad(404, "No such folder");
  return jsonResponse({ parent, items: out, cursor: r.truncated ? r.cursor : null });
}

async function content(req, b, url) {
  const rel = cleanPath(url.searchParams.get("path") || "");
  if (!rel || !visible(rel)) return bad(400, "Bad path");
  let obj;
  try {
    obj = req.method === "HEAD" ? await b.head(rel) : await b.get(rel, { range: req.headers });
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
    events.push(...(await (await b.get(o.key)).json()).events);
    seq = n;
  }
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
    const folders = new Set();
    let cursor;
    do {
      const r = await b.list({ include: ["customMetadata"], cursor, limit: PAGE });
      for (const o of r.objects) {
        if (!visible(o.key)) continue;
        for (let p = parentOf(o.key); p; p = parentOf(p)) folders.add(p);
        if (o.key.split("/").pop().startsWith(".folder-")) continue;
        items[await fileId(o.key, o.customMetadata)] = { path: o.key, size: o.size, etag: o.httpEtag, mtime: mtimeOf(o) };
      }
      cursor = r.truncated ? r.cursor : undefined;
    } while (cursor);
    for (const p of folders) items[await folderId(p)] = { path: p, dir: true };

    const events = [];
    for (const [id, it] of Object.entries(items)) {
      const was = old.items[id];
      const ev = { id, path: it.path, dir: !!it.dir, ...(it.dir ? {} : { size: it.size, etag: it.etag, mtime: it.mtime }) };
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
    return snap;
  } finally {
    await b.delete(lockKey);
  }
}
