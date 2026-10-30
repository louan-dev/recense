# D1 migrations (C1) · PROPOSED, nothing bound or applied

`0001_init.sql`: shares, share_items, members, share_members, overrides, comments, reactions, annotations, migrated. Checked with `sqlite3 :memory:` only.

## Lazy move from R2 (proposal)
Goal: no big-bang copy, no downtime, R2 JSON stays as a read-only fallback until a cleanup step the owner approves.

1. **Bind, don't read yet.** Add `[[d1_databases]] binding = "DB"` and apply `0001_init.sql` (owner's yes; separate deploy). Code paths unchanged.
2. **Invites (`invites/<hash>.json`).** `participantRoute`: look up `shares` by `token_hash`; on miss, read the R2 object; if found, insert into `shares` (+ `share_items`, a `members` row for `inv.name`) with `migrated_from`, then serve from the row. The owner's list/revoke reads D1 then R2 (union by id) until a one-off sweep has copied the rest. Revoke sets `revoked_at` and deletes the R2 object, so a revoked link can never be resurrected by the fallback. New invites go to D1 only.
3. **Comments (`notes/<folder>/.comments.json`, `index/note/<id>.json`, manifest `item.comment`).** On the first read of a folder's comments: if `migrated` has no row for that R2 key, copy every thread into `comments` (old `{text,at}` → one owner comment `c0`; `by` name → member: `OWNER` → `owner`, else the member of the share whose `name` matches, else a new member) in one `batch()`, and record `(r2_key, etag)`. Writes go to D1 only after that. If the R2 ETag later differs from `migrated.etag` (an old Worker wrote it during rollout), re-merge by comment id.
4. **Renames/moves.** `renameInInvites` / `renameComment` become `UPDATE … SET path/name` in one transaction; keep the R2 rewrite only for not-yet-migrated keys.
5. **Cleanup (later, owner's yes).** When the sweep reports every `invites/` and comment key in `migrated`, stop reading R2 for them; archive the JSON to `archive/pre-d1/` rather than delete.

Ownership fix that comes with it: comments carry `author_id`, not a display name, so "delete your own comment" can no longer match a different invite that has the same name.

Tests to add with step 2–3: unmigrated invite works and is copied once; revoked invite stays 404 with the R2 copy present or absent; comment thread copies once (ETag), old single-comment shape, rename after migration.
