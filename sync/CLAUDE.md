# CLAUDE.md · Sync (backend root, plan owner) · repo root `~/Developer/sync`

This repo holds the shared plan. Every session: read `PROGRESS.md` §2 (Rules) and only the section for the task named. Open only the matching section of `BACKLOG.md`. Don't re-read unchanged files or re-plan. You edit only this repo unless the task names another folder.

## Where things are
- `ledger.mjs`: read-only observer of the iCloud folder, append-only SHA-256 hash-chained journal to a directory or rclone sink. Zero deps. Commands: `run|watch|fold|verify|restore|selftest`. Only `selftest` has run (Linux); macOS paths, rclone sink, `SF_DATALESS` and `watch` are untested.
- Docs: `ledger-report.md`, `sync-matrix.md`, `icloud-backend-technical-report.md`, `Obsidian integration.md`, `switchboard-spec.md`, `switchboard-scheduler-addendum.md`, `manager.md`, `notes/refs/sync.md`. `switchboard-iphone-addendum.md` is referenced everywhere but is missing: ask the owner for it.
- No git yet: run `git init` (local only, no remote, no push until the owner names a repo). `.gitignore`: `.env`, `rclone.conf`, ledger sinks and mirrors, `.DS_Store`, `node_modules/`. Commit before each task.

## Your items (PROGRESS §4-§5, BACKLOG §S)
Tonight's priority is **Track A, Unclog & Mirror**. Do in order, one per session:
- **A1** locate the 5 GB of iCloud usage: ask for the storage breakdown screenshot, then add a read-only `audit` that writes `AUDIT.md` (never read inside the Notability container).
- **A2** Arq backup gate to the 1 TB SanDisk: give an exact GUI checklist (sources, excludes, schedule, retention) and add `backup-status` with a verified sample restore.
- **A3** free the quota: propose a list only, delete nothing. Evicting a local copy does not free iCloud quota.
- **A4** canary note round trip Mac, iPhone, iPad, Mac.
- **A5** ledger mirror: `selftest`, dry run on a copy, `run --apply` on the Obsidian vault, `verify --deep`, launchd job and `views/health.json`.
- **A6** overflow lane to R2 (Remotely Save for the vault; Notability WebDAV after A5). **A7** surfaces: the Gallery and Sill parts belong to the other repos; leave a one-line handoff in §7.
- Then Track B (Desk): Notes in Sill, DEVONthink, Calendar Desk (Switchboard Phases 0-1 first, shadow mode), Apple data via standards. BACKLOG §S1-S6: network exposure, iPhone SE bridge assessment, notes latency, storage ledger, rclone GUI, Arq drills.

## Rules that matter most here
Never delete or move user data, overwrite backups, change production access rules or push without explicit confirmation. Never print, log or archive secrets (`.env`, tokens, `rclone.conf`, wrangler secrets). No private iCloud endpoints and no Apple credentials in code; use standards (CalDAV, CardDAV, IMAP, WebDAV), EventKit, FSEvents, Shortcuts. Label status honestly and claim no real-time sync or security without a test.

## Keep the plan current
Update `PROGRESS.md` §7 as you go. Add these owner decisions to §8 and fix §3 and BACKLOG SL6, which are now out of date:
- **Nook is being folded into Sill** (hover-to-peek and an always-hidden tier behind a Sill setting that can be turned off; running Sill hides menu-bar icons automatically). The old `~/Developer/nook` folder is deleted afterwards, only after verification, a recoverable snapshot and the owner's confirmation of the exact path. Work happens in the Sill repo.
- A new **widget panel** (name undecided; right-edge slide-out on a non-conflicting three-finger gesture, first widget Find My) is built inside Sill as item SL7, not as a standalone app.
- Repos: `sync`, `sill`, `cloud-gallery` are separate local git repos, all private.

## Output
No routine narration, no whole-file dumps. Report decisions, blockers, validation, next action. Running low on context: update §7, write a patch, build `progress.zip` (PROGRESS.md, patch, test output; no secrets, caches or `.env`) and verify it exists.