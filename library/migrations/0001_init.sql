-- 0001_init.sql · Gallery D1 (C1). Bound as DB in wrangler.toml; apply with
--   npx wrangler d1 migrations apply gallery --remote
-- Blobs stay in R2 (files/, art/, keep/). D1 holds who may do what, and the conversation around items.
-- An item is (bucket, dir, name): dir is its folder under files/ ('' = root), name its file name,
-- the same strings invite.js and public.js use. Times are ms since epoch (Date.now()).
-- The R2 JSON these rows were copied from (invites/, notes/, annotations/) is never deleted by the copy.

-- A share = an invitation (was invites/<hash>.json). One person, one Main folder (or a room: chosen items).
-- doc is the whole invitation as invite.js reads it; the columns beside it are for queries and audits.
CREATE TABLE shares (
  id            TEXT PRIMARY KEY,
  token_hash    TEXT NOT NULL UNIQUE,
  bucket        TEXT NOT NULL DEFAULT 'main' CHECK (bucket IN ('main')),
  folder        TEXT NOT NULL,
  name          TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  expires_at    INTEGER NOT NULL DEFAULT 0,
  revoked_at    INTEGER,
  view_only     INTEGER NOT NULL DEFAULT 0,
  can_view      INTEGER NOT NULL DEFAULT 1,
  can_download  INTEGER NOT NULL DEFAULT 1,
  can_upload    INTEGER NOT NULL DEFAULT 1,
  can_comment   INTEGER NOT NULL DEFAULT 1,
  can_react     INTEGER NOT NULL DEFAULT 1,
  can_annotate  INTEGER NOT NULL DEFAULT 0,
  doc           TEXT NOT NULL,
  migrated_from TEXT
);
CREATE INDEX shares_folder ON shares (bucket, folder);

-- A room's chosen items. No rows = the whole folder.
CREATE TABLE share_items (
  share_id TEXT NOT NULL REFERENCES shares (id) ON DELETE CASCADE,
  name     TEXT NOT NULL,
  PRIMARY KEY (share_id, name)
);

-- People. Today a share is one person (shares.name); the owner is 'owner'.
CREATE TABLE members (
  id         TEXT PRIMARY KEY,
  display    TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
INSERT INTO members (id, display, created_at) VALUES ('owner', 'owner', 0);

CREATE TABLE share_members (
  share_id  TEXT NOT NULL REFERENCES shares (id) ON DELETE CASCADE,
  member_id TEXT NOT NULL REFERENCES members (id),
  PRIMARY KEY (share_id, member_id)
);

-- Per-file overrides of a share's permissions. NULL = inherit from the share.
CREATE TABLE overrides (
  share_id     TEXT NOT NULL REFERENCES shares (id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  can_view     INTEGER,
  can_download INTEGER,
  can_upload   INTEGER,
  can_comment  INTEGER,
  can_react    INTEGER,
  can_annotate INTEGER,
  PRIMARY KEY (share_id, name)
);

-- The owner's view-only lock on a whole folder: every share into it loses its writes.
CREATE TABLE folder_locks (
  bucket    TEXT NOT NULL DEFAULT 'main',
  folder    TEXT NOT NULL,
  locked_at INTEGER NOT NULL,
  PRIMARY KEY (bucket, folder)
);

-- Comments (was notes/<folder>/.comments.json { name: { list: [...] } }). doc is the comment as the
-- thread reads it (id, text, at, by, as?, cc?, vid?, edited?); seq keeps the thread's order.
CREATE TABLE comments (
  bucket     TEXT NOT NULL CHECK (bucket IN ('main', 'public')),
  dir        TEXT NOT NULL,
  name       TEXT NOT NULL,
  cid        TEXT NOT NULL,
  seq        INTEGER NOT NULL,
  by_name    TEXT NOT NULL,
  vid        TEXT NOT NULL DEFAULT '',
  body       TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  edited_at  INTEGER,
  doc        TEXT NOT NULL,
  PRIMARY KEY (bucket, dir, name, cid)
);
CREATE INDEX comments_dir ON comments (bucket, dir);

-- Reactions (was the thread's likes). One per person and kind.
CREATE TABLE reactions (
  bucket     TEXT NOT NULL,
  dir        TEXT NOT NULL,
  name       TEXT NOT NULL,
  by_name    TEXT NOT NULL,
  vid        TEXT NOT NULL DEFAULT '',
  kind       TEXT NOT NULL DEFAULT 'like',
  seq        INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  doc        TEXT NOT NULL,
  PRIMARY KEY (bucket, dir, name, by_name, vid, kind)
);
CREATE INDEX reactions_dir ON reactions (bucket, dir);

-- Annotations (was annotations/<path>.json): a note at a time (t, ms) or a spot (x, y in 0..1).
-- via_share is the invitation that wrote it (NULL = the owner): ownership is by share, never by name.
CREATE TABLE annotations (
  id         TEXT PRIMARY KEY,
  bucket     TEXT NOT NULL DEFAULT 'main',
  dir        TEXT NOT NULL,
  name       TEXT NOT NULL,
  by_name    TEXT NOT NULL,
  via_share  TEXT,
  body       TEXT NOT NULL,
  t          REAL,
  x          REAL,
  y          REAL,
  created_at INTEGER NOT NULL
);
CREATE INDEX annotations_item ON annotations (bucket, dir, name, created_at);

-- Non-destructive edits to an item's metadata (time, location, a transcript line): the file is never
-- rewritten. Dropping the row (Revoke) falls back to the original.
CREATE TABLE metadata_overrides (
  bucket     TEXT NOT NULL DEFAULT 'main',
  path       TEXT NOT NULL,
  field      TEXT NOT NULL,
  value      TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (bucket, path, field)
);

-- Every change to a metadata override, with the value it replaced, so any of them can be restored.
CREATE TABLE revisions (
  id     INTEGER PRIMARY KEY AUTOINCREMENT,
  bucket TEXT NOT NULL DEFAULT 'main',
  path   TEXT NOT NULL,
  field  TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('adjust', 'revoke', 'clear', 'restore')),
  before TEXT,
  after  TEXT,
  at     INTEGER NOT NULL,
  by     TEXT NOT NULL
);
CREATE INDEX revisions_item ON revisions (bucket, path, at);

-- Which R2 JSON objects have been copied in (lazy migration bookkeeping), and at which ETag.
CREATE TABLE migrated (
  r2_key      TEXT PRIMARY KEY,
  etag        TEXT NOT NULL,
  migrated_at INTEGER NOT NULL
);
