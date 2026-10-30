-- 0001_init.sql · Gallery D1 (C1). DRAFT: not bound in wrangler.toml, not applied anywhere.
-- Blobs stay in R2 (files/, art/, keep/). D1 holds who may do what, and the conversation around items.
-- Item identity is (bucket, path) with path = the R2 key under files/ ("<folder>/<name>"), the same
-- string invite.js and public.js already use; a rename/move updates rows in one transaction
-- (replaces renameInInvites / renameComment walking R2).
-- Times are ms since epoch (Date.now()), matching the R2 JSON.

PRAGMA foreign_keys = ON;

-- A share = today's invites/<hash>.json. One person, one Main folder (or a room: chosen items).
CREATE TABLE shares (
  id          TEXT PRIMARY KEY,                 -- first 16 hex of token_hash (the id the owner revokes by)
  token_hash  TEXT NOT NULL UNIQUE,             -- SHA-256 hex of the 256-bit token; the token is never stored
  bucket      TEXT NOT NULL DEFAULT 'main' CHECK (bucket IN ('main')),  -- public stays one-way, never shared here
  folder      TEXT NOT NULL,                    -- '' = Main root
  name        TEXT NOT NULL,                    -- who it is for, as the owner typed it
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER NOT NULL DEFAULT 0,       -- 0 = never
  revoked_at  INTEGER,                          -- soft revoke: link 404s, history (comments' authors) survives
  view_only   INTEGER NOT NULL DEFAULT 0,       -- document-level lock: overrides every write perm below
  can_view     INTEGER NOT NULL DEFAULT 1,
  can_download INTEGER NOT NULL DEFAULT 1,
  can_upload   INTEGER NOT NULL DEFAULT 1,      -- rooms (share_items present) never take uploads, enforced in code
  can_comment  INTEGER NOT NULL DEFAULT 1,
  can_react    INTEGER NOT NULL DEFAULT 0,
  can_annotate INTEGER NOT NULL DEFAULT 0,
  view_json   TEXT,                             -- { lang, notation } (viewOf), as today
  migrated_from TEXT                            -- 'r2:invites/<hash>.json' when lazily copied
);
CREATE INDEX shares_folder ON shares (bucket, folder);

-- A room's chosen items (today invites/<hash>.json "items"). No rows = the whole folder.
CREATE TABLE share_items (
  share_id TEXT NOT NULL REFERENCES shares (id) ON DELETE CASCADE,
  name     TEXT NOT NULL,                       -- file name inside shares.folder
  PRIMARY KEY (share_id, name)
);

-- Members = people. Today a share is one person; this lets one person hold several shares
-- (and own their comments across them) and gives comments a stable author instead of a name string.
CREATE TABLE members (
  id         TEXT PRIMARY KEY,                  -- random 16 hex; 'owner' is the owner
  display    TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
INSERT INTO members (id, display, created_at) VALUES ('owner', 'owner', 0);

CREATE TABLE share_members (
  share_id  TEXT NOT NULL REFERENCES shares (id) ON DELETE CASCADE,
  member_id TEXT NOT NULL REFERENCES members (id),
  PRIMARY KEY (share_id, member_id)
);

-- Per-media overrides: "comments off for member X on item Y". NULL = inherit from the share.
CREATE TABLE overrides (
  share_id     TEXT NOT NULL REFERENCES shares (id) ON DELETE CASCADE,
  path         TEXT NOT NULL,                   -- item path under files/
  can_view     INTEGER,
  can_download INTEGER,
  can_comment  INTEGER,
  can_react    INTEGER,
  can_annotate INTEGER,
  view_only    INTEGER,                         -- per-item lock
  PRIMARY KEY (share_id, path)
);

-- Comments (today notes/<folder>/.comments.json, index/note/<id>.json, manifest item.comment).
CREATE TABLE comments (
  id         TEXT PRIMARY KEY,                  -- keeps the R2 ids ('c0', 'c<base36>') when migrated, prefixed by scope
  bucket     TEXT NOT NULL CHECK (bucket IN ('main', 'public')),
  path       TEXT NOT NULL,
  author_id  TEXT NOT NULL REFERENCES members (id),
  via_share  TEXT REFERENCES shares (id),       -- NULL = owner on /main
  body       TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 4000),
  created_at INTEGER NOT NULL,
  edited_at  INTEGER,
  deleted_at INTEGER                            -- soft delete; own comments only (owner may delete any)
);
CREATE INDEX comments_item ON comments (bucket, path, created_at);

CREATE TABLE reactions (
  bucket     TEXT NOT NULL,
  path       TEXT NOT NULL,
  author_id  TEXT NOT NULL REFERENCES members (id),
  emoji      TEXT NOT NULL CHECK (length(emoji) <= 16),
  created_at INTEGER NOT NULL,
  PRIMARY KEY (bucket, path, author_id, emoji)
);

-- Annotations: a mark on an item at a place (image region, media time, page). Shape lives in JSON;
-- large ink stays in R2 (blob_key) like other blobs.
CREATE TABLE annotations (
  id         TEXT PRIMARY KEY,
  bucket     TEXT NOT NULL,
  path       TEXT NOT NULL,
  author_id  TEXT NOT NULL REFERENCES members (id),
  via_share  TEXT REFERENCES shares (id),
  kind       TEXT NOT NULL CHECK (kind IN ('point', 'rect', 'ink', 'time', 'text')),
  anchor     TEXT NOT NULL,                     -- JSON: {x,y,w,h} 0..1, or {t0,t1} seconds, or {page}
  body       TEXT,
  blob_key   TEXT,
  created_at INTEGER NOT NULL,
  edited_at  INTEGER,
  deleted_at INTEGER
);
CREATE INDEX annotations_item ON annotations (bucket, path, created_at);

-- Which R2 comment maps have been copied in (lazy migration bookkeeping).
CREATE TABLE migrated (
  r2_key      TEXT PRIMARY KEY,                 -- e.g. 'notes/Trips/.comments.json'
  etag        TEXT NOT NULL,                    -- the R2 ETag that was copied
  migrated_at INTEGER NOT NULL
);
