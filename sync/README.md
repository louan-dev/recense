# sync

The backend root for storage I run instead of iCloud: Cloudflare R2 behind always-on mounts, an own CalDAV,
offsite disks for Photos, Messages and Mail, and a read-only iCloud ledger. Private repo.

## Why this exists
This started with a full iCloud and a laptop out of breath. My M1 has 8 GB of memory and a small disk, the files keep
growing, external SanDisk drives kept failing me, and when iCloud filled up it took Calendar, Notability and Obsidian
sync down with it. I could have paid for more space, but what I really wanted was to stop renting my own memories:
calendars, notes and messages on open standards (CalDAV, WebDAV, plain Markdown in an Obsidian vault), on storage I
choose, with a ledger that can prove nothing was lost or quietly changed.

Sync is the plumbing for that, and I want it to be plumbing anyone can borrow. Privacy, a working machine that doesn't
have to be thrown away, and tools free of a single corporation's say-so should not be luxuries. The same spirit runs
through Recense and Gallery: one unified, corporate-free home for the essentials, so the people I care about, including
those facing language, disability or cost barriers, can learn and keep their lives in the ways that suit them. I lacked
the resources to buy that, so I am making it, playfully and in the open, and learning a lot along the way.

## Long-term outcomes
- Files usable with no connection on Mac, iPhone and iPad, in each device's native place; edits flow both ways when a
  connection appears.
- The Mac's disk freed by moving bulk folders into R2 behind an always-on mount; nothing runs 24/7.
- Calendar, contacts, notes and messages on standards (CalDAV, CardDAV, IMAP, WebDAV), never private iCloud endpoints.
- A tamper-evident record of every change, so anything can be verified and restored.

Sync is the `sync/` folder of the one repo, `louan-dev/recense` (A15). The plan is `../docs/PROGRESS.md` (status,
decisions, changelog), with detail in `../docs/BACKLOG.md` and `../docs/SPEC.md`. Start with
`../docs/specs/gallery-nervous-system.md`. The unified offline-first plan for Sync, Gallery and Recense
(approved 2026-11-05; phase 0 done and pushed; A15 made the one repo) is
`../docs/specs/unified-offline-first-and-redesign.md`.

## Features
- **Ledger** (`src/ledger.mjs`): read-only observer of the iCloud folder, an append-only SHA-256 hash-chained journal in
  the shared event-log format, mirrored to R2. Audit, backup status (Arq to R2), quota and freeing proposals (never
  deletes), verify, restore and health (`views/health.json`). Zero dependencies.
  - **Held deletions** (D3, 2026-11-06). A file whose bytes reappear under another path was moved, not deleted. If what
    truly vanished trips the guard (over 100 files, or over 10 and over 10% of what was known), the run still records
    everything else and holds those deletions until you confirm them. The log and `health` say `held: N`. You get one
    notification when the count changes, never one per run. To record them (deletion is an event, so they stay
    restorable), run the job's command once with `--allow-mass-delete`. For the vault:
    `RCLONE_CONFIG=~/.config/rclone/jobs.conf node ~/Developer/recense/sync/src/ledger.mjs run --source "$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian" --sink rclone:gallery-main:gallery-main/ledger/obsidian --origin obsidian --materialize --apply --allow-mass-delete`
  - **Notifications** (`bin/ledger-job.sh`) fire only on a change: a run starts or stops failing, held deletions, fold
    fails, the mirror goes stale. The last state of each is in `~/.ledger/notified-<origin>-*`.
- **Canary** (`src/canary.mjs`): a note's round trip Mac → iPhone → iPad → Mac, with an upload-status probe.
- **CalDAV Worker** (`../calendar/`): your own calendar server; calendar backup through EventKit (`tools/cal-export`).
- **Messenger ingest** (`src/messenger.mjs`).
- **Always-on archive mount**: `gallery-archive/chauphan` over Gallery's `/main/nc-archive/`, kept alive by launchd with
  a 2 GB cache; folder listings are cached for an hour (Worker requests), and deletes still go to Gallery's trash.
- **Offsite disks**: Photos, Messages and Mail stores on APFS sparse bundles in `gallery-archive/.disks`, one rclone
  mount per disk plus a watchdog; Messages mounts at `~/Library/Messages` (the Disks Helper needs Full Disk Access).
- **Move Offsite**: a Finder Quick Action and an iPhone Shortcut that move files into R2, naming the macOS privacy
  permission when one blocks a read.
- **Docs sync** (`bin/docs-sync.zsh`, launchd `com.chauphan.docs-sync`): every readable or editable document on the
  Mac in one place, Gallery Main › **Docs**, seen in the Gallery app on iPhone/iPad, Gallery in Finder and Files, and
  the website. Two-way (rclone bisync) for iCloud Drive, Documents, Desktop and Temporary, without Markdown (that goes
  to the Obsidian vault, which only iCloud writes); one-way for the vault, Developer, Voice Memos (`Docs/Recordings`;
  macOS lets the job read it only once Disks Helper has Full Disk Access) and Notability's PDF backups
  (`Docs/Notability`). Downloads isn't a lane: downloads-to-r2 moves it into Gallery's tmp. `Docs/INDEX.md` lists
  everything by source, rebuilt nightly. Documents only (`config/docs-sync.filters`: writing, PDFs, Office/iWork,
  ebooks, recordings; no code, app data or hidden files; the vault also takes its pictures). Straight to R2 over its
  S3 API (`jobs.conf` remote `gallery-main:`), so a pass costs no Worker requests; until 2026-11-05 it went through
  the Worker's WebDAV and used most of the account's daily budget. What a pass replaces in Docs goes to Main's
  `trash/<day>/Docs/`; what it would delete on the Mac is kept in `~/.docs-sync/kept/`. The same file edited on both
  sides: the newer keeps its name, the other becomes `name.conflict1.ext`. Hourly, and at login.
- **Markdown mirror** (`bin/md-mirror.zsh`, launchd `com.chauphan.md-mirror`): every Markdown file made on the Mac is
  in the Obsidian vault too, under `Mac/Developer`, `Mac/Desktop` and `Mac/Documents`, so it opens in Obsidian on the
  iPhone and iPad, and an edit made there reaches the original on the next pass. Two-way, disk to disk (rclone bisync,
  no network, no Worker requests), every 5 minutes, through Disks Helper. Markdown only (`config/md-mirror.filters`:
  no `.git`, `node_modules`, `.build*`, `backups`, `.claude`, `.handoff`, `.wrangler`, `venv`, `auto_avsr`). The same
  file edited on both sides: the newer wins, the other stays as `name.md.conflictN`. Whatever a pass overwrites or
  deletes on either side is kept first in `~/Library/Application Support/md-mirror/backup/<time>/<name>/{mac,vault}`,
  and a pass that would delete more than 10 % of a side stops. If the vault's `Mac/<name>` folder disappears, that pair
  waits for `--resync` instead of reading it as every note deleted. Log: `~/Library/Logs/md-mirror.log`.
- **Where the vault's pictures and shares go** (read 11-05; nothing changed): the images-uploader plugin sends each
  pasted picture straight to R2 (bucket `notes-images`, over S3) and deletes the local copy at once, so a picture lives
  only in R2, and notes show it through the Gallery Worker's `/i`. The share-note plugin publishes encrypted copies to
  note.sx (5 notes). Both plugins keep their keys in the synced vault's `.obsidian/plugins/*/data.json`.
- **resign-ios**: a daily check, per device, that reinstalls Recense (the iOS app) on the iPad or iPhone when its app is
  missing or 5 or more days old, renewing the 7-day profile first when 2 days or less are left. Devices are listed by UDID
  (the Xcode 27 device framework, 11-06); it builds through `mobile/ios/build.sh`.

## Layout

- `src/` ledger, canary, Messenger ingest
- `../calendar/` the CalDAV Worker (`src/caldav.js`, `src/index.js`, tests)
- `bin/` launchd jobs and mount scripts: `archive-mount.zsh`, `disks-mount.zsh`, `gallery-main-over-dav.zsh`,
  `add-gallery-archive-remote.zsh`, `add-gallery-tmp-remote.zsh`, `cal-job.sh`, `docs-sync.zsh`, `caldav-passwd.sh`, `ledger-job.sh`,
  `md-mirror.zsh`, `messenger-job.sh`, `move-ledger-sinks.zsh`, `offsite-image.zsh`, `resign-ios.zsh`
- `tools/` `cal-export.swift`, `upload-status.swift`, `disks-helper`, `quick-actions/`, `shortcuts/`, `hetzner-check.py`
- `config/` docs-sync and md-mirror filter lists
- `launchd/` plist templates (`__HOME__` placeholders)
- `../docs/specs` what is being built, `../docs/research` reports, `docs/runbooks` step-by-step (Arq, overflow, offsite
  disks, recovery, SanDisk evacuation, Obsidian images and integration, Gallery drive), `../docs/proposals` decisions
  waiting on you
- `../docs/decisions/` your recorded decisions
- `../docs/requests/` inbox for files you upload (contents are git-ignored)

## Commands

Run from `sync/` (`cd ~/Developer/recense/sync`).

    npm test                          # both selftests
    node src/ledger.mjs <command>     # run|watch|fold|verify|restore|health|audit|backup-status|quota|selftest
    node src/canary.mjs start|check
    zsh bin/archive-mount.zsh         # the always-on archive mount (launchd: com.chauphan.archive-mount)
    zsh bin/disks-mount.zsh           # the offsite disks (launchd: com.chauphan.disks-mount)
    zsh bin/docs-sync.zsh             # one Docs pass now; --dry-run, --resync, --only "Obsidian", --verbose
    zsh bin/md-mirror.zsh             # one Markdown pass now; --dry-run, --resync, --only Developer, --verbose

## launchd

    cp launchd/com.chauphan.docs-sync.plist ~/Library/LaunchAgents/ &&
      launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.chauphan.docs-sync.plist

    cp launchd/com.chauphan.md-mirror.plist ~/Library/LaunchAgents/ &&
      launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.chauphan.md-mirror.plist

    sed "s#__HOME__#$HOME#g" launchd/com.chauphan.ledger.obsidian.plist.example \
      > ~/Library/LaunchAgents/com.chauphan.ledger.obsidian.plist

## Triage watch (save triage.md → bug gets worked on)
- **You write** one plain line under `# Inbox` in `docs/specs/triage.md`, any language, typed or dictated. Save.
  - `!` first (or the old `P1 -`) = urgent: an agent starts. Any other line is only filed.
- **Filing:** `bin/triage-watch.zsh`, run by `launchd/com.chauphan.triage-watch.plist` on save (5 s debounce) and hourly.
  Local, instant, no network: each line becomes `T-####` (urgent → `TRIAGED P1`, else `NEW`).
- **Scout** (urgent only): `claude -p --model haiku --effort low --max-budget-usd 0.10`, read/grep tools only.
  Writes `Where:` (files) and `Repro:` (marked guess) under the entry, then stops.
  No files found → the entry gets "tell me where you saw it" and a notification; nothing more is spent.
- **Fixer:** `claude -p --model sonnet --effort medium --max-budget-usd 1.50` running `/bug` in `.claude/worktrees/t-####`.
  - Narrow brief: the entry and its `Where:` files only.
  - One at a time; skips an entry whose files are already FIXING or held by a LANES lane.
  - Urgent entries in the same Area filed within 10 min share one run.
  - Stops at a commit on its branch + a MERGE-QUEUE line; never merges, pushes or installs. Normal permissions, never bypass.
  - Needs Opus or blocked → writes why to `~/.local/state/triage-watch/queue.blocked`; the owner or coordinator restarts it.
- **Caps:** `$3.00` a day (scout + fixer, `TRIAGE_DAILY_BUDGET_USD`), backstop 3 fixer runs a day (`TRIAGE_DAILY_CAP`).
  Over the cap, entries wait in the queue with a notification.
- **Offline:** filing never needs the network. Scout and fixer (Anthropic) run as catch-up on the next save or hourly run.
- **Phone edits:** md-mirror (two-way bisync, every 5 min) carries an Obsidian edit to the source, which fires the watcher. Risk: an edit on the phone in the same 5 min as the watcher rewrites the file → the newer wins, the other is kept as `triage.md.conflictN`.
- **Usage:** every run's cost and turns go to `~/.local/state/triage-watch/usage.log`; weekly line: `zsh bin/triage-watch.zsh weekly`.
- Log: `~/.local/state/triage-watch/log`, launchd log `~/Library/Logs/triage-watch.log`.
- Test: `zsh bin/triage-watch.zsh selftest` (part of `npm test`).
- Turn on:

      cp launchd/com.chauphan.triage-watch.plist ~/Library/LaunchAgents/ &&
        launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.chauphan.triage-watch.plist

- Turn off (exit path):

      launchctl bootout gui/$(id -u)/com.chauphan.triage-watch
