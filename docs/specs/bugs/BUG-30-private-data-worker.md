# BUG-30 · Private data reaches Workers AI; Worker security gaps

From: PLAN-1118 §3 Ask + Sync/security findings, owner 2026-11-18 ·
Guards: A6/X7 (client matters never indexed) ·
Status: `[~]`

## Invariants (each has a test marked `// Regression guard: BUG-30`)
1. A file is private when any path segment is Raven, Matters or Sealed (any case, any depth, either root).
   Never indexed, never returned by search or ask. `POST /main/api/ai/purge-sealed` (owner only) deletes the vectors
   and stored text of such files. Test: `library/test/ai.test.mjs`.
2. `OWNER_EMAIL` unset or empty: no Access email is the owner. Service-token owners are unaffected.
3. Main trash: two files of one name trashed on one day both survive (key carries `@<ms>`).
4. Postbox: the token is accepted from a header only; a query-string token is refused.
5. CalDAV: passwords are PBKDF2-SHA256 (>=100k iterations, random per-user salt); the old unsalted hash is accepted once
   and rewritten; failed logins are limited per IP.
6. Cron: a failing scheduled job is logged (`console.error`) and the other jobs still run.
7. Listen episode merge writes only if the ETag is unchanged (re-read and re-merge, max 3 tries).

## Live steps after deploy (coordinator)
- `POST /main/api/ai/purge-sealed` once as the owner (removes already-indexed private vectors).
- Set `OWNER_EMAIL` on the Worker if it is not set (names only; value is the owner's).
