// D1 (C1): shares, folder locks, Main comments and reactions, annotations, metadata overrides.
//
// Used only when the DB binding exists; without it every caller keeps its R2 JSON (so a deploy
// before the database is created behaves exactly as before). Blobs never come here.
// Lazy migration: the first read of an R2 JSON object copies it in and records (key, ETag) in
// `migrated`; the R2 object is left as it was, as a backup. If its ETag later differs (an older
// Worker wrote it during the rollout), rows it has that D1 lacks are merged in by id.



const now = () => Date.now();
const b01 = (v) => (v ? 1 : 0);
const ov01 = (v) => (typeof v === "boolean" ? (v ? 1 : 0) : null);

export const hasDB = (env) => !!(env && env.DB);

async function r2Json(bucket, key) {
  try {
    const o = await bucket.get(key);
    return o ? { v: await o.json(), etag: o.etag } : null;
  } catch (e) {
    return null;
  }
}

// Whether `key` needs copying: "new" (never seen), "changed" (ETag moved), or null (up to date / absent).
async function migrationState(env, key) {
  const head = await env.MAIN.head(key);
  const row = await env.DB.prepare("SELECT etag FROM migrated WHERE r2_key = ?").bind(key).first();
  if (!head) {
    if (!row) await markMigrated(env, key, "");
    return null;
  }
  if (!row) return "new";
  return row.etag === head.etag ? null : "changed";
}

const markMigrated = (env, key, etag) =>
  env.DB.prepare("INSERT INTO migrated (r2_key, etag, migrated_at) VALUES (?, ?, ?) ON CONFLICT (r2_key) DO UPDATE SET etag = excluded.etag, migrated_at = excluded.migrated_at")
    .bind(key, etag, now())
    .run();

// ---------- shares (invitations) ----------

const P = ["view", "download", "upload", "comment", "react", "annotate"];

function shareStatements(env, hash, inv, from = null) {
  const id = hash.slice(0, 16);
  const p = { view: true, download: true, upload: !inv.items, comment: true, react: true, annotate: false, ...(inv.perms || {}) };
  const out = [
    env.DB.prepare(
      `INSERT INTO shares (id, token_hash, folder, name, created_at, expires_at, view_only, can_view, can_download, can_upload, can_comment, can_react, can_annotate, doc, migrated_from)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET folder = excluded.folder, name = excluded.name, expires_at = excluded.expires_at, view_only = excluded.view_only,
         can_view = excluded.can_view, can_download = excluded.can_download, can_upload = excluded.can_upload, can_comment = excluded.can_comment,
         can_react = excluded.can_react, can_annotate = excluded.can_annotate, doc = excluded.doc`
    ).bind(id, hash, inv.folder, inv.name, inv.created || now(), inv.expires || 0, b01(inv.viewOnly), ...P.map((k) => b01(p[k])), JSON.stringify(inv), from),
    env.DB.prepare("DELETE FROM share_items WHERE share_id = ?").bind(id),
    env.DB.prepare("DELETE FROM overrides WHERE share_id = ?").bind(id),
    env.DB.prepare("INSERT OR IGNORE INTO members (id, display, created_at) VALUES (?, ?, ?)").bind("s:" + id, inv.name, inv.created || now()),
    env.DB.prepare("INSERT OR IGNORE INTO share_members (share_id, member_id) VALUES (?, ?)").bind(id, "s:" + id),
  ];
  for (const n of inv.items || []) out.push(env.DB.prepare("INSERT OR IGNORE INTO share_items (share_id, name) VALUES (?, ?)").bind(id, n));
  for (const [n, o] of Object.entries(inv.overrides || {})) {
    out.push(env.DB.prepare("INSERT INTO overrides (share_id, name, can_view, can_download, can_upload, can_comment, can_react, can_annotate) VALUES (?, ?, ?, ?, ?, ?, ?, ?)").bind(id, n, ...P.map((k) => ov01(o[k]))));
  }
  return out;
}

export const sharePut = (env, hash, inv, from = null) => env.DB.batch(shareStatements(env, hash, inv, from));

const validInvite = (inv) => inv && typeof inv.name === "string" && typeof inv.folder === "string";

// The invitation stored under this hash, revoked ones as null; an R2-only one is copied in on the way.
export async function shareGet(env, hash) {
  const row = await env.DB.prepare("SELECT doc, revoked_at FROM shares WHERE token_hash = ?").bind(hash).first();
  if (row) return row.revoked_at ? null : JSON.parse(row.doc);
  const key = "invites/" + hash + ".json";
  const r = await r2Json(env.MAIN, key);
  if (!r || !validInvite(r.v)) return null;
  await sharePut(env, hash, r.v, "r2:" + key);
  return r.v;
}

// Every live (not revoked) invitation as [{ hash, inv }], R2-only ones copied in first.
export async function shareList(env) {
  const { results } = await env.DB.prepare("SELECT token_hash, doc, revoked_at FROM shares").all();
  const known = new Set(results.map((r) => r.token_hash));
  let cursor;
  do {
    const r = await env.MAIN.list({ prefix: "invites/", cursor });
    for (const o of r.objects) {
      const hash = o.key.slice(8, -5);
      if (!/^[0-9a-f]{64}$/.test(hash) || known.has(hash)) continue;
      const inv = await shareGet(env, hash);
      if (inv) results.push({ token_hash: hash, doc: JSON.stringify(inv), revoked_at: null });
    }
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);
  return results.filter((r) => !r.revoked_at).map((r) => ({ hash: r.token_hash, inv: JSON.parse(r.doc) }));
}

// The live invitation with this public id (first 16 hex of the hash), or null.
export async function shareById(env, id) {
  const row = await env.DB.prepare("SELECT token_hash, doc, revoked_at FROM shares WHERE id = ?").bind(id).first();
  if (row) return row.revoked_at ? null : { hash: row.token_hash, inv: JSON.parse(row.doc) };
  const r = await env.MAIN.list({ prefix: "invites/" + id });
  if (r.objects.length !== 1) return null;
  const hash = r.objects[0].key.slice(8, -5);
  const inv = await shareGet(env, hash);
  return inv ? { hash, inv } : null;
}

// Revokes: the row stays (history keeps its authors), the link 404s; the R2 copy goes so no older
// Worker can still open it. -> the invitation, or null if there was none.
export async function shareRevoke(env, id) {
  const s = await shareById(env, id);
  if (!s) return null;
  await env.DB.prepare("UPDATE shares SET revoked_at = ? WHERE id = ?").bind(now(), id).run();
  await env.MAIN.delete("invites/" + s.hash + ".json");
  return s.inv;
}

// The first write accepts the invitation: only one claim can ever win.
export async function shareClaim(env, hash, gid, at) {
  const r = await env.DB.prepare(
    "UPDATE shares SET doc = json_set(doc, '$.guest', ?, '$.claimed', ?) WHERE token_hash = ? AND revoked_at IS NULL AND json_extract(doc, '$.guest') IS NULL"
  )
    .bind(gid, at, hash)
    .run();
  return r.meta.changes === 1;
}

// ---------- folder locks ----------

export async function locksGet(env) {
  const key = "invites/_locks.json";
  if (await migrationState(env, key)) {
    const r = await r2Json(env.MAIN, key);
    const st = Object.keys((r && r.v) || {}).map((f) => env.DB.prepare("INSERT OR IGNORE INTO folder_locks (bucket, folder, locked_at) VALUES ('main', ?, ?)").bind(f, now()));
    if (st.length) await env.DB.batch(st);
    await markMigrated(env, key, r ? r.etag : "");
  }
  const { results } = await env.DB.prepare("SELECT folder FROM folder_locks WHERE bucket = 'main'").all();
  return Object.fromEntries(results.map((r) => [r.folder, true]));
}

export const lockSet = (env, folder, on) =>
  on
    ? env.DB.prepare("INSERT OR IGNORE INTO folder_locks (bucket, folder, locked_at) VALUES ('main', ?, ?)").bind(folder, now()).run()
    : env.DB.prepare("DELETE FROM folder_locks WHERE bucket = 'main' AND folder = ?").bind(folder).run();

// ---------- Main comments and reactions ----------

const notesKey = (dir) => "notes/" + (dir ? dir + "/" : "") + ".comments.json";

// The old shapes, as the thread reads them: { text, at } is one owner comment "c0".
const listOf = (v, owner) =>
  !v || typeof v !== "object" ? [] : Array.isArray(v.list) ? v.list.filter((c) => c && c.text) : v.text ? [{ id: "c0", text: v.text, at: v.at || 0, by: owner }] : [];
const likesOf = (v) => (v && Array.isArray(v.likes) ? v.likes.filter((l) => l && l.by) : []);

function itemStatements(env, dir, name, v, owner, ignore = false) {
  const verb = ignore ? "INSERT OR IGNORE" : "INSERT";
  const out = [];
  listOf(v, owner).forEach((c, i) =>
    out.push(
      env.DB.prepare(`${verb} INTO comments (bucket, dir, name, cid, seq, by_name, vid, body, created_at, edited_at, doc) VALUES ('main', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).bind(
        dir, name, String(c.id), i, String(c.by || owner), c.vid || "", c.text, c.at || 0, c.edited || null, JSON.stringify(c)
      )
    )
  );
  likesOf(v).forEach((l, i) =>
    out.push(
      env.DB.prepare(`${verb} INTO reactions (bucket, dir, name, by_name, vid, kind, seq, created_at, doc) VALUES ('main', ?, ?, ?, ?, 'like', ?, ?, ?)`).bind(
        dir, name, String(l.by), l.vid || "", i, l.at || 0, JSON.stringify(l)
      )
    )
  );
  return out;
}

async function readCommentRows(env, dir) {
  const [c, r] = await env.DB.batch([
    env.DB.prepare("SELECT name, doc FROM comments WHERE bucket = 'main' AND dir = ? ORDER BY name, seq").bind(dir),
    env.DB.prepare("SELECT name, doc FROM reactions WHERE bucket = 'main' AND dir = ? ORDER BY name, seq").bind(dir),
  ]);
  const map = {};
  for (const x of c.results) (map[x.name] ||= { list: [] }).list.push(JSON.parse(x.doc));
  for (const x of r.results) ((map[x.name] ||= { list: [] }).likes ||= []).push(JSON.parse(x.doc));
  return map;
}

// { "<file name>": { list, likes? } } for one Main folder, the R2 map copied in the first time.
export async function commentMap(env, dir, owner) {
  const key = notesKey(dir);
  const st = await migrationState(env, key);
  if (st) {
    const r = await r2Json(env.MAIN, key);
    const stmts = [];
    for (const [name, v] of Object.entries((r && r.v) || {})) stmts.push(...itemStatements(env, dir, name, v, owner, true));
    // the seq of merged rows may tie with existing ones; order then falls back to the stored time
    if (stmts.length) await env.DB.batch(stmts);
    await markMigrated(env, key, r ? r.etag : "");
  }
  return readCommentRows(env, dir);
}

// Writes the items of `map` that differ from what is stored (an item missing from map is removed).
export async function commentSave(env, dir, map, owner) {
  const cur = await readCommentRows(env, dir);
  const stmts = [];
  for (const name of new Set([...Object.keys(cur), ...Object.keys(map)])) {
    const a = cur[name];
    const b = map[name] ? { list: listOf(map[name], owner), ...(likesOf(map[name]).length ? { likes: likesOf(map[name]) } : {}) } : null;
    if (JSON.stringify(a || null) === JSON.stringify(b)) continue;
    stmts.push(env.DB.prepare("DELETE FROM comments WHERE bucket = 'main' AND dir = ? AND name = ?").bind(dir, name));
    stmts.push(env.DB.prepare("DELETE FROM reactions WHERE bucket = 'main' AND dir = ? AND name = ?").bind(dir, name));
    if (b) stmts.push(...itemStatements(env, dir, name, b, owner));
  }
  if (stmts.length) await env.DB.batch(stmts);
}

// ---------- annotations ----------

const split = (rel) => {
  const i = rel.lastIndexOf("/");
  return i < 0 ? ["", rel] : [rel.slice(0, i), rel.slice(i + 1)];
};

export async function annotationsGet(env, rel) {
  const [dir, name] = split(rel);
  const key = "annotations/" + rel + ".json";
  if (await migrationState(env, key)) {
    const r = await r2Json(env.MAIN, key);
    const items = (r && r.v && Array.isArray(r.v.items) && r.v.items) || [];
    const st = items.map((a) =>
      env.DB.prepare("INSERT OR IGNORE INTO annotations (id, dir, name, by_name, via_share, body, t, x, y, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)").bind(
        a.id, dir, name, a.by, a.inv || null, a.text, a.t ?? null, a.x ?? null, a.y ?? null, a.at || 0
      )
    );
    if (st.length) await env.DB.batch(st);
    await markMigrated(env, key, r ? r.etag : "");
  }
  const { results } = await env.DB.prepare("SELECT * FROM annotations WHERE bucket = 'main' AND dir = ? AND name = ? ORDER BY created_at, id").bind(dir, name).all();
  return results.map((a) => {
    const o = { id: a.id, by: a.by_name, inv: a.via_share, at: a.created_at, text: a.body };
    for (const k of ["t", "x", "y"]) if (a[k] != null) o[k] = a[k];
    return o;
  });
}

export async function annotationsSave(env, rel, items) {
  const [dir, name] = split(rel);
  await env.DB.batch([
    env.DB.prepare("DELETE FROM annotations WHERE bucket = 'main' AND dir = ? AND name = ?").bind(dir, name),
    ...items.map((a) =>
      env.DB.prepare("INSERT INTO annotations (id, dir, name, by_name, via_share, body, t, x, y, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)").bind(
        a.id, dir, name, a.by, a.inv || null, a.text, a.t ?? null, a.x ?? null, a.y ?? null, a.at
      )
    ),
  ]);
}

export async function annotationsMove(env, from, to) {
  await annotationsGet(env, from); // copies any R2 ones in first
  const [d, n] = split(from);
  if (!to) return env.DB.prepare("DELETE FROM annotations WHERE bucket = 'main' AND dir = ? AND name = ?").bind(d, n).run();
  const [d2, n2] = split(to);
  return env.DB.prepare("UPDATE annotations SET dir = ?, name = ? WHERE bucket = 'main' AND dir = ? AND name = ?").bind(d2, n2, d, n).run();
}

