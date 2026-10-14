# ARQ-CHECKLIST.md · A2 backup gate · 2026-10-13

Status: PROPOSED. The owner does this in Arq's GUI; nothing here has been automated or run.

## 0. What is on this Mac (checked 2026-10-13)
- `/Applications/Arq.app` is **Arq 5.7.8** (2019-era, legacy). No backup sets are configured (`~/Library/Arq/config` has only `app_config.plist`), the agent is not running, and Arq 5 has no CLI (`arqc` does not exist; its AppleScript suite only handles license URLs).
- SanDisk: `/Volumes/SanDisk`, 932 GiB exFAT, 796 GiB free. No Arq data on it yet.
- Internal disk: about 12 GiB free, so dataless iCloud files must be materialized in batches (§3), not all at once.
- **Owner decision (2026-10-13): stay on Arq 5.7.8.** No CLI, so everything below is GUI; `backup-status` reports snapshot count as unknown for the Arq 5 layout and relies on the restore drill. Menu labels below are from Arq 5 memory: verify them on screen.
- **exFAT caution:** the ledger hung on this SanDisk when macOS's `copyfile` also copied extended attributes (fixed in `src/ledger.mjs` by copying plain bytes). Arq 5 has not been seen writing to this drive yet: make the first backup a small folder and watch that it finishes before adding the rest.

## 1. Destination
Arq → Preferences → Destinations → + → Local Folder → `/Volumes/SanDisk/Arq` (new folder). Set an encryption password and save it in the password manager (not in this repo). R2 as a second destination only if total stays inside R2's free 10 GB; skip B2.

## 2. Backup plan (one plan, destination SanDisk)
**Sources**
- `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian` (the vault)
- Notability in-app export folder: _owner names the path_ (Notability → Settings → Auto-Backup, PDF + Note). Never the `…~gingerlabs~Notability` container.
- `~/Documents`, `~/Desktop`
- `~/Developer`
- Dotfiles: `~/.zshrc`, `~/.zprofile`, `~/.config`, `~/.ssh`, `~/.gnupg`, `~/.npmrc`, `~/.ledger` (Arq encrypts; these hold keys, so the Arq password matters)
- `~/Library/Mobile Documents/iCloud~com~apple~clips` (Clips projects, 1.3 GB, fully local; A3 row 2: back up, pass the drill, then the owner deletes old projects in Clips)
- `~/Library/Mobile Documents/com~apple~CloudDocs` (iCloud Drive), only after its dataless files are materialized (§3)

**Excludes** (Arq: plan → Edit → Exclude, wildcard rules)
`/Volumes/SanDisk/**` (the destination) · `~/Library/Caches` · `**/.Trash` · `**/node_modules` · `**/.build` · `**/build` · `**/DerivedData` · `**/*.bak` · ledger sinks and stages (`/Volumes/SanDisk/ledger/**`, `/Volumes/SanDisk/stage/**`) · `~/.ollama`, `~/.nvm`, `~/.docker`, `~/.android` (re-downloadable) · `.env` stays included (encrypted) but never in git

**Schedule:** hourly, plus "when the destination is connected". Thinning: hourly for 24 h, daily for 30 days, weekly after that. No budget cap on the SanDisk at first.

## 3. Materialize before backing up (a placeholder is not a backup)
`AUDIT.md` shows 443 dataless files (13.3 GB), 12.7 GB of them in iCloud Drive's `.Trash`. Outside the trash about 0.6 GB is cloud-only (WhatsApp backup tars, Obsidian attachments, Drive/Downloads). Batch them through the ledger so only one batch sits on the internal disk at a time:
```
node src/ledger.mjs run --source "<folder>" --sink /Volumes/SanDisk/ledger/<name> --materialize --stage-dir /Volumes/SanDisk/stage --apply
```
Recently Deleted (`.Trash`) items are not backup sources; the owner decides about them in A3.

## 4. Gate: verified restore
1. Run the first backup; wait for it to finish.
2. Arq → Restore → pick 3–5 files from the vault (include one attachment) → restore to `~/Desktop/arq-restore-test` (not over the originals).
3. Check:
```
node ~/Developer/sync/src/ledger.mjs backup-status --dest /Volumes/SanDisk/Arq --source "$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian" --restored ~/Desktop/arq-restore-test
```
Pass = exit 0, every restored file's sha256 equals the source. Result is kept in `~/.ledger/backup-status.json`. A3 stays blocked until this passes.
