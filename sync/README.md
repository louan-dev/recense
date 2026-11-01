# sync

The backend root for storage the owner runs instead of iCloud: Cloudflare R2 behind always-on mounts, an own CalDAV,
offsite disks for Photos, Messages and Mail, and a read-only iCloud ledger. Private repo.

## Why this exists
This started with a full iCloud and a laptop out of breath. My M1 has 8 GB of memory and a small disk, the files keep
growing, external SanDisk drives kept failing me, and when iCloud filled up it took Calendar, Notability and Obsidian
sync down with it. I could have paid for more space, but what I really wanted was to stop renting my own memories:
calendars, notes and messages on open standards (CalDAV, WebDAV, plain Markdown in an Obsidian vault), on storage I
choose, with a ledger that can prove nothing was lost or quietly changed.

Sync is the plumbing for that, and I want it to be plumbing anyone can borrow. Privacy, a working machine that doesn't
have to be thrown away, and tools free of a single corporation's say-so should not be luxuries. The same spirit runs
through Sill and Gallery: one unified, corporate-free home for the essentials, so the people I care about, including
those facing language, disability or cost barriers, can learn and keep their lives in the ways that suit them. I lacked
the resources to buy that, so I am making it, playfully and in the open, and learning a lot along the way.

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
- **Docs sync** (`bin/docs-sync.zsh`, launchd `com.chauphan.docs-sync`): every readable or editable document on the
  Mac in one place, Gallery Main › **Docs**, seen in the Gallery app on iPhone/iPad, Gallery in Finder and Files, and
  the website. Two-way (rclone bisync) for the Obsidian vault, iCloud Drive, Documents, Desktop, Downloads, Temporary,
  Developer and Google Drive; one-way for Voice Memos (`Docs/Recordings`; macOS lets the job read it only once Disks Helper has Full Disk Access) and Notability's PDF backups
  (`Docs/Notability`); `Docs/INDEX.md` lists everything by source. Documents only (`config/docs-sync.filters`: writing,
  PDFs, Office/iWork, ebooks, recordings; no code, app data or hidden files; the vault also takes its pictures). Writes
  go through the Worker with this Mac's Access token, so Gallery keeps what it replaces in its trash; files a pass
  removes on the Mac are kept in `~/.docs-sync/kept/`. The same file edited on both sides → both kept
  (`name.conflict1.md`, `name.conflict2.md`). Every 10 minutes, at login and when the vault changes.
- **resign-ios**: a daily check that re-signs Gallery on the iPad and iPhone when 2 days or less are left.

## Layout

- `src/` ledger, canary, Messenger ingest
- `worker/` the CalDAV Worker (`src/caldav.js`, `src/index.js`, tests)
- `bin/` launchd jobs and mount scripts: `archive-mount.zsh`, `disks-mount.zsh`, `gallery-main-over-dav.zsh`,
  `add-gallery-archive-remote.zsh`, `add-gallery-tmp-remote.zsh`, `cal-job.sh`, `docs-sync.zsh`, `caldav-passwd.sh`, `ledger-job.sh`,
  `messenger-job.sh`, `move-ledger-sinks.zsh`, `offsite-image.zsh`, `resign-ios.zsh`
- `tools/` `cal-export.swift`, `upload-status.swift`, `disks-helper`, `quick-actions/`, `shortcuts/`, `hetzner-check.py`
- `config/` docs-sync filter lists
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
    zsh bin/docs-sync.zsh             # one Docs pass now; --dry-run, --resync, --only "Obsidian"

## launchd

    cp launchd/com.chauphan.docs-sync.plist ~/Library/LaunchAgents/ &&
      launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.chauphan.docs-sync.plist

    sed "s#__HOME__#$HOME#g" launchd/com.chauphan.ledger.obsidian.plist.example \
      > ~/Library/LaunchAgents/com.chauphan.ledger.obsidian.plist
