# sync

The backend root for storage the owner runs instead of iCloud: Cloudflare R2 behind always-on mounts, an own CalDAV,
offsite disks for Photos, Messages and Mail, and a read-only iCloud ledger. Private repo.

## Long-term outcomes
- Files usable with no connection on Mac, iPhone and iPad, in each device's native place; edits flow both ways when a
  connection appears.
- The Mac's disk freed by moving bulk folders into R2 behind an always-on mount; nothing runs 24/7.
- Calendar, contacts, notes and messages on standards (CalDAV, CardDAV, IMAP, WebDAV), never private iCloud endpoints.
- A tamper-evident record of every change, so anything can be verified and restored.

The plan is `PROGRESS.md` (status, decisions, changelog), with detail in `BACKLOG.md` and `SPEC.md`. Start with
`docs/specs/gallery-nervous-system.md`.

## Features
- **Ledger** (`src/ledger.mjs`): read-only observer of the iCloud folder, an append-only SHA-256 hash-chained journal in
  the shared event-log format, mirrored to R2. Audit, backup status (Arq to R2), quota and freeing proposals (never
  deletes), verify, restore and health (`views/health.json`). Zero dependencies.
- **Canary** (`src/canary.mjs`): a note's round trip Mac → iPhone → iPad → Mac, with an upload-status probe.
- **CalDAV Worker** (`worker/`): the owner's own calendar server; calendar backup through EventKit (`tools/cal-export`).
- **Messenger ingest** (`src/messenger.mjs`).
- **Always-on archive mount**: `gallery-archive/chauphan` over Gallery's `/main/nc-archive/`, kept alive by launchd with
  a 2 GB cache.
- **Offsite disks**: Photos, Messages and Mail stores on APFS sparse bundles in `gallery-archive/.disks`, one rclone
  mount per disk plus a watchdog; Messages mounts at `~/Library/Messages` (the Disks Helper needs Full Disk Access).
- **Move Offsite**: a Finder Quick Action and an iPhone Shortcut that move files into R2, naming the macOS privacy
  permission when one blocks a read.
- **resign-ios**: a daily check that re-signs Gallery on the iPad and iPhone when 2 days or less are left.

## Layout

- `src/` ledger, canary, Messenger ingest
- `worker/` the CalDAV Worker (`src/caldav.js`, `src/index.js`, tests)
- `bin/` launchd jobs and mount scripts: `archive-mount.zsh`, `disks-mount.zsh`, `gallery-main-over-dav.zsh`,
  `add-gallery-archive-remote.zsh`, `add-gallery-tmp-remote.zsh`, `cal-job.sh`, `caldav-passwd.sh`, `ledger-job.sh`,
  `messenger-job.sh`, `move-ledger-sinks.zsh`, `offsite-image.zsh`, `resign-ios.zsh`
- `tools/` `cal-export.swift`, `upload-status.swift`, `disks-helper`, `quick-actions/`, `shortcuts/`, `hetzner-check.py`
- `launchd/` plist templates (`__HOME__` placeholders)
- `docs/specs` what is being built, `docs/research` reports, `docs/runbooks` step-by-step (Arq, overflow, offsite
  disks, recovery, SanDisk evacuation, Obsidian images and integration, Gallery drive), `docs/proposals` decisions
  waiting on the owner
- `decisions/` recorded owner decisions
- `requests/` inbox for files the owner uploads (contents are git-ignored)

## Commands

    npm test                          # both selftests
    node src/ledger.mjs <command>     # run|watch|fold|verify|restore|health|audit|backup-status|quota|selftest
    node src/canary.mjs start|check
    zsh bin/archive-mount.zsh         # the always-on archive mount (launchd: com.chauphan.archive-mount)
    zsh bin/disks-mount.zsh           # the offsite disks (launchd: com.chauphan.disks-mount)

## launchd

    sed "s#__HOME__#$HOME#g" launchd/com.chauphan.ledger.obsidian.plist.example \
      > ~/Library/LaunchAgents/com.chauphan.ledger.obsidian.plist
