# OVERFLOW.md · A6 overflow lane (smallest version) · 2026-10-13

Status: rule PARTIAL (planner built and tested); Remotely Save PROPOSED (owner GUI); Notability WebDAV BLOCKED on A5 (by plan).

## 1. Rule (implemented, read-only)
`node ledger.mjs overflow --source <vault> --sink <sink> --max-mb 25 --total <plan> [--alert 80 --target 60]`
- Candidate = a file in the source larger than `--max-mb` (default 25 MB). `.obsidian/` is never a candidate.
- At or above `--alert`% iCloud usage, it selects candidates largest first until projected usage reaches `--target`%. Below the alert level every candidate is listed.
- `ready` = the sink already holds the file's exact bytes (sha256 object). `cloud` = dataless, so it cannot be hashed without a download. `nocopy` = not yet mirrored.
- The owner moves a ready file out by hand and leaves the pointer note (`pointerNote()` format: YAML front matter with sink, object key, sha256, size, original path, plus the restore command). The tool never writes to the vault.
- Today on the vault (10 MB limit): 1 candidate, `Imported/ScreenRecording_05-02-2026 07-51-41_1.mov` (73 MB, cloud-only). The plan size is unknown, so the quota level reads `inconsistent` (see A3).

## 2. Remotely Save → R2 (owner, in the Cloudflare dashboard and Obsidian)
**Precondition: only one sync layer per vault.** Either turn Remotely Save on for a vault that is *outside* iCloud, or move the vault out of iCloud first, after A2's restore drill. Never run both on the same folder.
1. Cloudflare → R2 → Create bucket `notes` (not `share`, which auto-deletes, and not `gallery-main`).
2. R2 → Manage API tokens → Object Read & Write, **scoped to `notes` only**. Store the keys in the password manager, not in this repo.
3. Obsidian (Mac first) → Community plugins → Remotely Save → S3: endpoint `https://<account-id>.r2.cloudflarestorage.com`, region `auto`, bucket `notes`, the token's keys. Cloudflare rejects `HeadBucket` for Object R/W keys, so ignore a failed connectivity check and test with a real sync.
4. Sync on open + every 5 min + on save. Leave `.obsidian` unsynced (default).
5. Proof: create `remotely-save-canary.md` on the Mac, sync, open on the iPhone (Remotely Save installed with the same token), sync, check it arrives, append a line, sync back.
6. R2 free tier is 10 GB storage plus Class A/B operation limits. A 5-minute interval on 3 devices stays well inside it (verify on the R2 dashboard after a week).

## 3. Notability → WebDAV on the Gallery Worker (design only; build after A5 is DONE)
- Route `/dav/notability/` in `cloud-gallery/gallery/src/worker.js`, R2 prefix `MAIN:notability-backup/`.
- Methods: `OPTIONS`, `PROPFIND` (Depth 0/1), `GET`, `HEAD`, `PUT`, `MKCOL`. `DELETE`, `MOVE`, `COPY`, `PROPPATCH` → 405. A `PUT` over an existing key writes a new version (`<key>@<iso>`) instead of overwriting, so the store is append-only.
- Auth: HTTP Basic with its own app password (wrangler secret `NOTABILITY_DAV_HASH`, compared as a hash in constant time), outside Cloudflare Access because Notability cannot do Access. Rate-limit failures.
- Tests (miniflare): Notability's request sequence (`PROPFIND` the root, `MKCOL`, `PUT`), 401 without or with a wrong password, 405 on `DELETE`/`MOVE`, a second `PUT` keeps both versions, no path traversal outside the prefix.
- Notability side (owner): Settings → Auto-Backup → WebDAV → `https://<gallery host>/dav/notability/`, format PDF + Note.
