# ARQ-CHECKLIST.md · A2 backup gate · 2026-10-13

Status: PROPOSED. The owner does this in Arq's GUI; nothing here has been automated or run.

## 0. What is on this Mac (checked 2026-10-13)
- `/Applications/Arq.app` is **Arq 5.7.8** (2019-era, legacy). No backup sets are configured (`~/Library/Arq/config` has only `app_config.plist`), the agent is not running, and Arq 5 has no CLI (`arqc` does not exist; its AppleScript suite only handles license URLs).
- SanDisk: `/Volumes/SanDisk`, 932 GiB exFAT, 796 GiB free. No Arq data on it yet.
- Internal disk: about 12 GiB free, so dataless iCloud files must be materialized in batches (§3), not all at once.
- **Owner decision (2026-10-13): stay on Arq 5.7.8.** No CLI, so everything below is GUI; `backup-status` reports snapshot count as unknown for the Arq 5 layout and relies on the restore drill. Menu labels below are from Arq 5 memory: verify them on screen.
- **exFAT caution:** the ledger hung on this SanDisk when macOS's `copyfile` also copied extended attributes (fixed in `src/ledger.mjs` by copying plain bytes). Arq 5 has not been seen writing to this drive yet: superseded: the destination is now R2 (§1).

## 1. Destination: Cloudflare R2 (owner decision 2026-10-14: the SanDisk is not a reliable destination)
1. Cloudflare → R2 → Create bucket **`arq`** (not `gallery-main`/`gallery-public`, not `notes`).
2. R2 → Manage API tokens → **Object Read & Write, scoped to `arq` only**. Keys go in the password manager, not this repo.
3. Arq 5 → Preferences → Destinations → + → **S3-Compatible Server** (label from memory; verify): server `https://<account-id>.r2.cloudflarestorage.com`, the token's keys, bucket `arq`. If Arq 5 insists on creating its own bucket, stop and tell Claude: a bucket-scoped token cannot create buckets.
4. Set an Arq encryption password (password manager). Arq encrypts before upload, so R2 only ever holds ciphertext.
5. **Size against R2's free tier (10 GB storage/month):** vault ~0.2 GB, Clips 1.3 GB, `~/Developer` 2.0 GB before excludes, Documents/Desktop and dotfiles small. Expect ~3–4 GB. Leave iCloud Drive out of Arq; the ledger covers it. Arq 5's budget setting: 8 GB, so thinning stays under the free tier.
6. **Unverified:** Arq 5.7.8 against R2's S3 API. First backup: only the vault. If it fails (signature/region errors: R2 wants region `auto`, aliased `us-east-1`), the fallback is the ledger to an encrypted R2 remote (`rclone crypt`), which already has `restore` and `verify --deep`.

## 2. Backup plan (one plan, destination R2 `arq`)
**Sources**
- `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian` (the vault)
- Notability in-app export folder: _owner names the path_ (Notability → Settings → Auto-Backup, PDF + Note). Never the `…~gingerlabs~Notability` container.
- `~/Documents`, `~/Desktop`
- `~/Developer`
- Dotfiles: `~/.zshrc`, `~/.zprofile`, `~/.config`, `~/.ssh`, `~/.gnupg`, `~/.npmrc`, `~/.ledger` (Arq encrypts; these hold keys, so the Arq password matters)
- `~/Library/Mobile Documents/iCloud~com~apple~clips` (Clips projects, 1.3 GB, fully local; A3 row 2: back up, pass the drill, then the owner deletes old projects in Clips)
- ~~iCloud Drive~~: not in Arq (R2 free-tier size); the ledger mirrors it

**Excludes** (Arq: plan → Edit → Exclude, wildcard rules)
`/Volumes/**` · `~/Library/Caches` · `**/.Trash` · `**/node_modules` · `**/.build` · `**/build` · `**/DerivedData` · `**/*.bak` · ledger sinks and stages (`/Volumes/SanDisk/ledger/**`, `/Volumes/SanDisk/stage/**`) · `~/.ollama`, `~/.nvm`, `~/.docker`, `~/.android` (re-downloadable) · `.env` stays included (encrypted) but never in git

**Schedule:** hourly. Thinning: hourly for 24 h, daily for 30 days, weekly after that, inside the 8 GB budget (§1.5). Formerly: no budget cap on the SanDisk at first.

## 3. Materialize before backing up (a placeholder is not a backup)
`AUDIT.md` shows 443 dataless files (13.3 GB), 12.7 GB of them in iCloud Drive's `.Trash`. Outside the trash about 0.6 GB is cloud-only (WhatsApp backup tars, Obsidian attachments, Drive/Downloads). Batch them through the ledger so only one batch sits on the internal disk at a time:
```
node src/ledger.mjs run --source "<folder>" --sink /Volumes/SanDisk/ledger/<name> --materialize --stage-dir /Volumes/SanDisk/stage --apply   # ledger sink; moving to R2 is pending owner OK (see PROGRESS A5)
```
Recently Deleted (`.Trash`) items are not backup sources; the owner decides about them in A3.

## 4. Gate: verified restore
1. Run the first backup; wait for it to finish.
2. Arq → Restore → pick 3–5 files from the vault (include one attachment) → restore to `~/Desktop/arq-restore-test` (not over the originals).
3. Check:
```
node ~/Developer/sync/src/ledger.mjs backup-status --source "$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian" --restored ~/Desktop/arq-restore-test
```
Pass = exit 0, every restored file's sha256 equals the source. Result is kept in `~/.ledger/backup-status.json`. A3 stays blocked until this passes.
