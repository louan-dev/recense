# D1 migrations (C1)

`0001_init.sql`: shares, share_items, members, share_members, overrides, folder_locks, comments, reactions,
annotations, metadata_overrides, revisions, migrated. Bound as `DB` in `wrangler.toml` (placeholder id until
the owner creates the database). Tested in Miniflare: `GALLERY_D1=1 node test/routes.test.mjs` (part of `npm test`).

Owner actions, once:

    npx wrangler d1 create gallery            # done: database_id is in wrangler.toml
    npx wrangler d1 migrations apply gallery --remote

## How the move from R2 works (`src/d1.js`)
- No `DB` binding: everything stays in R2 JSON exactly as before.
- With `DB`: D1 is the source of truth. The first read of an R2 JSON object (`invites/<hash>.json`,
  `invites/_locks.json`, `notes/<folder>/.comments.json`, `annotations/<path>.json`) copies it in and records
  `(r2_key, etag)` in `migrated`. The R2 object is never deleted or rewritten by this: it stays as a backup.
- If the R2 ETag later differs (an older Worker wrote it during the rollout), rows it has that D1 lacks are
  merged in by id (`INSERT OR IGNORE`); nothing doubles.
- Revoke sets `shares.revoked_at` (the row and its history stay) and deletes the R2 invitation, as before, so an
  older Worker cannot open it; a revoked row wins over any R2 copy.
- Claiming an invitation is one conditional `UPDATE … WHERE json_extract(doc,'$.guest') IS NULL`.
- Public share links (manifests, `index/note/`) stay in R2: they are one-way and expire with the link.
- No Durable Objects yet.
