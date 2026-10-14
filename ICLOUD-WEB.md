# ICLOUD-WEB.md · optional unofficial iCloud web mirror · 2026-10-13

**Status: OFF.** Start only when the owner says "enable the iCloud web route". Until then PROGRESS.md rule 7 stands and the ledger (Apple's own client as the oracle) is the primary route. Follow PROGRESS.md §2 for everything not stated here.

## 1. When to turn it on, and what it cannot do
- The internal disk is nearly full, so materializing dataless iCloud files locally may not fit. This route streams straight into a stage directory on the SanDisk.
- Photos that are not downloaded on the Mac, or reading without waiting for the Mac client.
- It cannot fix a full iCloud: anything that never reached iCloud (e.g. iPad changes) is invisible here too.
- It is unofficial, undocumented and can break without notice. Evidence checked 2026-10-13: icloudpd/pyicloud reports through Sept 2026 of accounts locked (`-20209`) after repeated automated logins, API logins rejected (`-20101`) even after an unlock, `421` "finish setup on icloud.com" errors, and one user locked again within a day. The account at risk is the owner's only Apple Account. Operating model: **one session, one login per ~30 days, zero automatic retries.**

## 2. Conditions (enforce in code and tests)
1. Owner's own account and data. The owner types password and 2FA interactively. The password is never stored; the session/trust token lives only in the login Keychain. Never in the repo, R2, a Worker, a VPS, logs or reports.
2. Runs only on the owner's Mac from its usual network. Never from a VPS, Worker or CI.
3. **Read-only by construction.** The client has no write, delete, move or rename code path. A test fails the build if a non-allowlisted verb or endpoint appears.
4. Polite and honest client: one session, ≤2 concurrent transfers, ≤2 requests/s, an off-hours window, a daily byte cap, jittered backoff. No rotating IPs, user agents or sessions; no reuse of browser cookies; no device or attestation emulation; no workaround for 2FA, ADP or rate limits. Aim for a well-behaved client, not an invisible one.
5. **Circuit breaker.** Any auth-class failure (401, 403, 421, 429, `-20209`, `-20101`, captcha, "Missing PCS cookies") sets state `open`: all jobs halt, an alert is written, no automatic re-login. Only an owner command half-opens it. Account unlocks are done by the owner on icloud.com, never scripted.
6. ADP: never turn it off to make this work. Current rclone docs say ADP works if "Access iCloud Data on the Web" is on and the owner approves on a trusted device (older docs said the opposite; check `rclone version`). If that is not enabled, skip.
7. The stage directory is plaintext. Encrypt private classes (rclone `crypt`) before any R2 sink, use a private prefix, never create public links.
8. Everything it produces goes through the ledger (P1–P10): truth over completeness, append-only history, hash what you copied, mass-vanish refusal.

## 3. Build levels (stop at the first that works)
**L0 · Don't write a client.** rclone's `iclouddrive` backend (v1.69+, support tier 4) already does SRP login, 2FA, trust token, Drive and Photos (`--iclouddrive-service photos`, paths like `PrimarySync/All Photos/`). Owner does:
```
rclone version                  # need >= 1.69
rclone config                   # new remote "icloud", type iclouddrive; password + 2FA; then set a config password
export RCLONE_PASSWORD_COMMAND='security find-generic-password -a rclone -s rclone-config -w'   # config password in Keychain
rclone lsd icloud:              # list only
rclone copy icloud: <SanDisk>/icloud-stage/drive --dry-run -vv --transfers 2 --tpslimit 2
rclone copy "icloud:<one small folder>" "<SanDisk>/icloud-stage/drive/<one small folder>" --transfers 2 --tpslimit 2 --max-transfer 1G --cutoff-mode soft -vv
```
`copy` only: never `sync`, `move` or `mount` with write access. icloudpd / icloudpd-rs are the fallback for Photos.

**L1 · Thin wrapper** (shell or Node, no dependencies): applies §2 (flags, caps, window, breaker), runs the canary, writes `views/icloud-web.json`, then calls `node ledger.mjs run --source <stage> --sink <sink> --origin icloud-web --apply`. `ledger.mjs` needs no change: the stage directory is just another source folder.

**L2 · Own client**: only if L0/L1 hit a demonstrated gap (no change tokens, no hashes) and the owner approves. Port one endpoint family from rclone's Go backend (MIT); do not re-derive Apple's protocol. Fixtures are sanitized recorded responses; no tokens in fixtures.

## 4. Session lifecycle
- Trust token ~30 days per rclone docs (other clients report longer; plan for 30). Re-auth is manual (`rclone reconnect icloud:`); never automate 2FA.
- `views/icloud-web.json`: `session_days_left`, `breaker` (closed/open), `last_ok`, items, bytes, skipped. Alert at 5 days left.
- Weekly canary: list one known folder, fetch one small known file, compare its sha256 with the first recorded value. Failure opens the breaker.

## 5. Data flow
- Stage layout `<stage>/<service>/<path>`, plus `remote-index.sqlite` (id, path, size, modified, etag if exposed, last_seen).
- Incremental: compare each listing with the index; fetch only new or changed items. A remote delete becomes a tombstone note, never a stage delete. A listing that is empty or loses >20% of known items aborts the run.
- Download to a temp name while hashing, check size, rename atomically. Signed URLs expire: re-request on 4xx. Resume if Range works. The API may expose no content hash: keep your own sha256 manifest.
- Stop if the stage volume has <10 GB free. Prune the stage only after `ledger verify --deep` passes and the owner's retention policy allows.

## 6. Data classes: use the supported route first
| Class | Route |
|---|---|
| iCloud Drive | local folder via ledger; this route when disk-limited |
| Photos | local export (Photos / `osxphotos`) first; this route for items not downloaded |
| Calendar, Contacts | CalDAV / CardDAV, app-specific password (no private API) |
| Mail | IMAP (`mbsync`) |
| Messages | copy local `chat.db` (end-to-end encrypted; no web route) |
| Notes, Reminders | not via this route |
| Notability | never; Auto-Backup → WebDAV (PROGRESS A6) |

## 7. Acceptance
1. Allowlist test passes; grep finds no write verbs.
2. Fake-server tests for 401/403/421/429/`-20209`/`-20101`: breaker opens, zero retries, alert written.
3. Dry-run counts for one small folder match the Mac's container (differences explained, e.g. placeholders).
4. One file's sha256 equals the Mac's copy; the stage then ledgers cleanly and `verify --deep` passes.
5. `views/icloud-web.json` shows days-left and breaker state; canary tested by forcing a failure.
6. Sentinel test: no password, token or Apple Account email in logs or reports.
7. Kill switch (`touch ~/.icloud-web.off` or `ICLOUD_WEB=0`) stops the next run.

## 8. Off switch and rollback
`launchctl unload` the job; delete the Keychain items; `rclone config delete icloud`; on iCloud.com use Account Settings → sign out of all browsers to end web sessions (verify the label). Staged data stays; delete nothing without the owner.

## 9. Out of scope (do not build or suggest)
Writing to iCloud; impersonating Apple devices or emulating attestation; bypassing 2FA, ADP or rate limits; extracting browser cookies or sessions; storing credentials; reading other people's data; operating "unnoticed".

## 10. Native feel, on the owner's side (public APIs only)
Present the mirror like a first-class location: a File Provider extension for Finder (and later the Files app on iPhone/iPad), Quick Look previews, Spotlight via `CSSearchableIndex`. The existing Touch ID "Gallery" mount is the starting point. This delivers "feels native" without touching Apple's internals.

Sources checked 2026-10-13: rclone.org/iclouddrive; icloudpd discussion #1332; docker-icloudpd issues #961, #964, #967; pyicloud PR #368.
