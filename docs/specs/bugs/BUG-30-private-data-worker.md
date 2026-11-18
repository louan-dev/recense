# BUG-30 · Private data reaches Workers AI; Worker security gaps

From: PLAN-1118 §3 Ask + Sync/security findings, owner 2026-11-18 ·
Guards: A6/X7 (client matters never indexed) ·
Status: `[~]`

## Invariants (each has a test marked `// Regression guard: BUG-30`)
1. **REVERSED by the owner 2026-11-18 ("NO sealed, do not withhold the sealed data from cloud ai access"; "Drop it everywhere").**
   Raven, Matters and Sealed are indexed, searched and answered from like any file; the purge route is removed;
   share links and feeds include them. Face ID / Touch ID still opens Matters on the device (`Rules.locked`).
   Test: `library/test/ai.test.mjs` "Raven, Matters and Sealed paths are indexed like any file".
2. HELD (owner): `OWNER_EMAIL` unset or empty: no Access email is the owner. Service-token owners are unaffected.
3. Main trash: two files of one name trashed on one day both survive (key carries `@<ms>`).
4. HELD (owner; fetch-only Claude web sessions need ?t=): Postbox: the token is accepted from a header only; a query-string token is refused.
5. CalDAV: passwords are PBKDF2-SHA256 (>=100k iterations, random per-user salt); the old unsalted hash is accepted once
   and rewritten; failed logins are limited per IP.
6. Cron: a failing scheduled job is logged (`console.error`) and the other jobs still run.
7. Listen episode merge writes only if the ETag is unchanged (re-read and re-merge, max 3 tries).

## Live steps after deploy (coordinator)
- Set `OWNER_EMAIL` on the Worker if it is not set (names only; value is the owner's).

## Later
- Key the failed-login limit by IPv6 /64, not the full address.
- Listen: retries exhausted returns 503 (never 409, which iOS treats as "take theirs").
