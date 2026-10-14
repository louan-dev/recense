# PROGRESS.md · handoff to Claude Code · 2026-10-13

Read every session; keep §7 current. Detail lives in `BACKLOG.md`: open only the section for the item you're on.
Nothing below has run on the owner's Mac. The only execution was `ledger.mjs selftest` in a Linux sandbox (all passed). Treat every claim as a lead to verify.

## 1. Objective and order
**Sync** (backend root) → **Gallery** (Cloudflare Worker + R2: web UI, API, glue) → **Sill** (macOS strip app: the UI that embeds Gallery and reads Sync). Spend effort in that order. Backend taste: boring, quiet, elegant; event-driven, no polling; on-demand over daemons; standards over cleverness.

- **A · Unclog & Mirror — today.** iCloud (5 GB, free tier, staying free) is full, so Notability, Obsidian and Calendar stopped syncing. Everything queues behind this.
- **B · Desk — tomorrow.** Notability, Obsidian and filesystem usable inside Sill; Calendar Desk scheduler; DEVONthink.
- **C · Rooms — next.** Gallery collaboration: main (shared, two-way) vs public (one-way).
- Everything else: BACKLOG, in dependency order.

## 2. Rules
1. Inspect once (tree, READMEs, configs, `git status`, tests). Keep a compact plan; don't re-read unchanged files or re-plan.
2. Evidence first. Never invent files, results or integrations. Trace defects to cause, fix narrowly, run the narrowest test, then regressions.
3. Batch related edits; minimal backward-compatible diffs. No new framework or dependency without demonstrated need (D1/Durable Objects for Gallery are allowed, §6).
4. Output: no routine narration, no whole-file dumps. Report decisions, blockers, validation, next action.
5. Data safety: never delete or move user data, overwrite backups, change prod access rules, or push/publish without explicit confirmation. Preserve unrelated changes. Never print, log or archive secrets (`.env`, tokens, `rclone.conf`, wrangler secrets).
6. Label status honestly: DONE (verified) / PARTIAL / BLOCKED / PROPOSED. No claim of real-time sync, security or compatibility without a test.
7. Apple: no private iCloud endpoints, no Apple credentials in code or Workers. Apple's own client is the oracle (ledger); otherwise standards (CalDAV, CardDAV, IMAP, WebDAV), EventKit, FSEvents, Shortcuts. The Apple ID is the one account everything depends on.
8. Running low on context: update §7, write a patch, build `progress.zip` (PROGRESS.md, patch, test output; no secrets, caches, `.build`, `.env`), verify it exists before saying so.

## 3. Ground truth (from the uploads; verify)
- **`sync/`** (no git: `git init` locally first, no remote). `ledger.mjs`: read-only observer of the iCloud folder, writes an append-only, SHA-256, hash-chained journal to a directory or rclone sink; zero deps; `run|watch|fold|verify|restore|selftest`. Docs: `ledger-report.md` (priorities P1–P10, run order), `sync-matrix.md`, `icloud-backend-technical-report.md` (safety gate, standards routes), `Obsidian integration.md` (Remotely Save → R2), `switchboard-spec.md` + `switchboard-scheduler-addendum.md` (Calendar Desk), `manager.md`, `notes/refs/sync.md` (CalDAV/WebDAV on Worker + R2 + D1). **`switchboard-iphone-addendum.md` is referenced everywhere but was not uploaded.**
- **`cloud-gallery/gallery/`** (git). Worker `src/worker.js` + `public.js`, `main.js`, `access.js`, `common.js`. Buckets `gallery-public` (PUBLIC), `gallery-main` (MAIN); cron 03:00. `/main` is owner-only via Cloudflare Access and everyone else gets a 404 by design. **No participant or invite model exists on main** (only public links `/s/<id>`). Comments, captions and folder order are JSON objects in R2. No D1/KV/DO yet. UI contract: `src/page/ui/README.md` (read §1.1, §3, §4.4, §7 before touching viewer or comments). Tests: `npm test` (miniflare + playwright; `node_modules` not shipped). `playerv12` (the player reference) was not uploaded. Scripts: `chau/setup.sh`, `chau/copy-share-link.sh` (README says `mac/` and `copy-public-link.sh`; reconcile). Clutter: `src/client/*.bak`, `src/page/ui.zip`, `.test-build/`.
- **`sill/sill/`** (git). One 7.2k-line `sill.swift`, `build.sh`, SwiftTerm. `backups/` holds 19 manual snapshots; `.build/`, `build/`, `*.bak` stay out of git and Arq. CPU/battery leads: one permanent 1 Hz timer (~line 6225) runs `pollExternal()` (stats `draftpad.md` every second to catch Obsidian edits), `updateClock()` and `restoreState()`; four repeating 60 Hz timers (settle/anim/band) and two 20 Hz meter timers (confirm each stops when idle); further 3 s, 60 s, 120 s and 30 min timers; 6 `Process()` calls (osascript near 4912–4920); 11 event-monitor sites; private MultitouchSupport gestures (experimental); no file-watch API. Draftpad file: `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian/draftpad.md`. Sill's own rule: consequential actions go draft → confirm → execute.
- **`nook/`** (no git). `main.swift` + `build.sh`: menu-bar hider (divider status items, per-app rules, hover-to-peek, auto-hide).
- "Proton Frankenstein" is in none of the uploads. Locate it on disk before touching anything.

## 4. Track A · Unclog & Mirror (finish tonight)
**A1 Locate the 5 GB (read-only).** Ask the owner for the iCloud storage breakdown (System Settings → [name] → iCloud → Manage, or iPhone Settings → [name] → iCloud). Photos, device Backups, Messages, Mail and app data count toward quota but are not in iCloud Drive, which is why deleting local files hasn't helped. Then add a read-only `audit` reusing ledger scanning: per `~/Library/Mobile Documents/*` container → files, apparent vs on-disk bytes, dataless count, top 50 largest, duplicates (size, then hash), dev junk (`node_modules`, `.build`, DerivedData) inside iCloud-synced paths. Output `AUDIT.md` (≤1 page) plus saved counts as baseline. Never read inside the Notability container (ledger denylist).

**A2 Backup gate (blocks A3).** Arq destination: the 1 TB SanDisk (R2 as an extra S3-compatible destination only if it fits the free tier; skip B2). Sources: Obsidian vault, Notability in-app export folder (PDF + Note), Documents, `~/Developer`, dotfiles, iCloud containers after materializing. Exclude: destination, caches, Trash, `node_modules`, `.build`, `build`, DerivedData, `*.bak`, ledger sinks and mirrors. Arq plans are set up in its GUI (check what `arqc` can script): output an exact checklist (sources, excludes, schedule, thinning retention) rather than faking automation. Add `backup-status`: last success, snapshot count, restore one sample to a scratch dir and compare sha256. Materialize dataless files in batches (`ledger run --materialize --stage-dir <SanDisk>`); a placeholder is not a backup.

**A3 Free the quota (owner approves a list; you delete nothing).** Candidates = items with a verified copy (checksum on SanDisk and/or R2). Facts to respect: evicting a local copy does not free iCloud quota; deleting from iCloud Drive deletes on every device; Recently Deleted (Drive, Photos, Notes, Mail) may still count until emptied; if device Backups dominate, offer: encrypted local Finder backup (covered by Arq) → turn off iCloud Backup → delete the old iCloud backup (owner's call). Target ≤60% used, alert at 80% (configurable). `brctl quota` may expose usage (verify).

**A4 Prove sync is back.** Canary note in the vault: Mac → iPhone → iPad → Mac; record latency. Confirm Notability on the iPad has finished uploading before touching anything it may hold.

**A5 Mirror with `ledger.mjs`.** On the Mac: `selftest` → dry run on a *copy* → `run --apply` on the Obsidian vault with sink `<SanDisk>/ledger/obsidian` → `verify --deep` → launchd job + `views/health.json` (alert when `lastOk` > 1 day) → iCloud Drive (review eviction counts first) → sink `rclone:gallery-main:ledger/<source>` (encrypt private material). One prefix per source. Untested on macOS: rclone sink, `SF_DATALESS` flag, `watch`.

**A6 Overflow lane (smallest version).** Config rule: file > N MB or iCloud usage ≥ 80% → goes to R2, a pointer note stays. Vault overflow: Remotely Save → R2 bucket `notes` with its own token (`Obsidian integration.md`); never run it and iCloud sync on the same vault at once. Notability: Auto-Backup → Worker WebDAV `/dav/notability/` (append-only, no DELETE, own app password); build after A5.

**A7 Surfaces.** Gallery: read-only `/main/ledger/` browsing `views/tree.json` (objects via Worker binding). Sill: status chip from `views/health.json`.

**Tonight is done when:** audit explains the 5 GB · Arq snapshot on SanDisk with a verified restore · iCloud usage under target and canary round-trips · vault mirrored by launchd with fresh `health.json` · §7 updated.

## 5. Track B · Desk (tomorrow)
**B1 Notes in Sill.** Obsidian panel (plain-markdown read/write; the vault stays the source of truth). Notability panel (read-only: Auto-Backup PDFs/Notes; never the container). Filesystem panel (ledger tree + search). Draftpad links via `obsidian://`, file paths, Notability PDF links. Re-measure draftpad.md latency after A4 before changing code; add a file watcher (none exists).
**B2 DEVONthink.** Replace Sill's standalone hub with a widget in the shared R2/Gallery bottom-bar panel. Detect the installed version first (DEVONthink 3 vs 4 Server). Connect through local AppleScript/JXA (query/open), `x-devonthink-item://` links, and Index-in-place of ledger folders (no duplicate storage). A WebDAV view of `views/tree.json` for DT sync is a candidate (verify what its sync accepts). Embed the Server web UI only on loopback or behind auth.
**B3 Calendar Desk.** Prerequisite: Switchboard Phases 0–1 (`switchboard-spec.md` §14: Worker, D1, secrets, notify channel); the addendum is built on them. Then implement `switchboard-scheduler-addendum.md` §§1–9, phases S1→S3 first, shadow mode first, §7 guardrails kept (per-provider opt-in once, veto window, undo, kill switch, rate limits, truthful messages; rescheduling is proposal-only). Owner deltas: ① offer the best **two** slots; ② calendar = Apple Calendar via the CalDAV Worker (`notes/refs/sync.md` §§5–7) or EventKit, not Google; ③ signals = wake/bed + steps via Shortcuts → `POST /signal` (steps from Health samples; verify) plus wake-strip interaction rhythm from Sill; ④ confirm/cancel texts leave through an always-on jailbroken iPhone SE with a second non-VoIP SIM (design is in the missing addendum; S1 and the signal/alarm parts of S2 need no SMS bridge, so start there; S2 late notices and S3 cancels do); ⑤ Sill shows cards and status only (Telegram, per the spec, stays the fallback card channel); execution lives in the Worker's Autonomy Governor. "Self-learning" = rules mode until ≥30 outcomes, then a calibrated model.
**B4 Apple data via standards.** Calendar/Contacts over CalDAV/CardDAV with app-specific passwords; Mail via IMAP (`mbsync`); iMessage: copy `chat.db` first, export from the copy. Private prefix, never public.

## 6. Track C · Rooms (next; security before cosmetics)
**C0 Server-side authz.** `/main` stays owner-only. Add a participant surface outside Access (e.g. `/m/<token>`): per-person invite tokens (≥128-bit, store the hash), scoped to one folder; perms {view, download, upload, comment, react, annotate}; expiry or none; revoke; per-media overrides (comments off for member X on media Y); document-level view-only lock; participants cannot delete the owner's content. Tests: unauthenticated, expired, revoked, direct URL, cross-folder, public/main separation. Hidden UI is not access control.
**C1 Data.** Add D1 (shares, members, comments, reactions, annotations); blobs stay in R2; migrate the JSON comment maps lazily. Durable Objects only for live presence and co-editing (WebSocket hibernation). No polling.
**C2 Product model and UI.** `BACKLOG.md` §G6 (Rooms, annotations, ephemeral posts) and §G1–G5; UI per `src/page/ui/README.md`.
**C3 Two-way R2 editing.** `BACKLOG.md` §G7: versioned save-back first, then live co-editing.

## 7. Status ledger (update as you go)
| ID | Item | State | Evidence / next |
|---|---|---|---|
| A1 | Audit + quota breakdown | PARTIAL | `ledger audit` → `AUDIT.md`: Drive `.Trash` holds 12.7 GB of 15.1 GB (one 11.3 GB wav); `brctl quota` says 16.4 GB left, contradicting "5 GB full". Needs owner's Apple-side breakdown |
| A2 | Arq plan + verified restore | PARTIAL | `ARQ-CHECKLIST.md` + `backup-status` (selftested). Installed Arq is 5.7.8, no plans, no CLI; owner picks Arq 5 vs 7, runs plan, restore drill |
| A3 | Quota freed | BLOCKED | `A3-PROPOSAL.md` + `ledger quota` ready; needs plan size, owner decisions on Recently Deleted (13 GB), and A2 drill |
| A4 | Canary round-trip | PROPOSED | |
| A5 | Ledger mirror | PARTIAL | selftest passes (Linux); macOS paths untested |
| A6 | Overflow lane, Notability WebDAV | PROPOSED | |
| A7 | Gallery + Sill ledger surfaces | PROPOSED | |
| B1–B4 | Notes in Sill, DEVONthink, Calendar Desk, Apple pulls | PROPOSED | specs exist, no code; iPhone addendum missing |
| C0–C3 | Authz, D1, Rooms, co-editing | PROPOSED | no participant model exists |
| — | Chrome `/main` 404, setup scripts, Sill CPU, audio/EQ, layout, Draftpad, Phi, Nook, cleanup | PROPOSED | BACKLOG |

## 8. Decisions made (defaults; change only if the owner objects)
1. "rw" = R2. "5 GB" = the iCloud quota.
2. iCloud stays the live lane once unclogged; ledger mirrors it; R2 takes overflow (A6).
3. Add D1 to Gallery (concurrent two-way writes, revocation checks, queries; Sync/Switchboard specs already use D1).
4. Phi: reuse whatever is installed on the SanDisk. Owner says "3.2", the Oct 9 directive says 3.5; inspect the files.
5. Battery colors: green ≥40, yellow 30–39, red ≤29 (red at 29 is mandatory; the old spec's yellow overlapped red). One constant each.
6. Scheduler starts in shadow mode for 2 weeks (addendum §7); owner can switch to live.
7. Recommended private repo: `sync/` (ledger.mjs + specs): unique, tiny, unversioned, and the root of both other projects. Do not push anywhere until the owner names the repo.

## CHANGELOG

### 2026-10-13 18:14 PDT · A1 · PARTIAL
- Changed: `ledger.mjs audit` (read-only; per-container/Drive-folder files, apparent vs on-disk bytes, dataless count confirmed by batched `SF_DATALESS` checks, top 50, duplicates by size→sha256 on local copies only, dev-junk dirs; denied containers never opened, not even `readdir`). Writes `AUDIT.md` + baseline `~/.ledger/audit/latest.json` (full JSON with paths stays outside the repo; delta vs previous run). 4 new selftests. Also: `.gitignore` was an empty directory; replaced with a file. `git` already existed (commit `baseline`).
- Validated: `selftest` on macOS 15.5 / Node 24 (all passed, incl. first macOS run of the original 17 checks). Real audit of `~/Library/Mobile Documents`: 1,814 files, 15.1 GB apparent, 1.8 GB local, 443 dataless (13.3 GB). Both Notability containers denied, 0 unreadable.
- Findings: iCloud Drive Recently Deleted (`.Trash`) = 13.0 GB (12.7 GB cloud-only; an 11.3 GB `.wav`, a 305 MB `.m4b`, a 108 MB PDF); it counts against quota until emptied or auto-purged. Clips 1.3 GB, WhatsApp backup 423 MB, Obsidian 220 MB. No duplicates ≥1 MB, no dev junk. `brctl quota` reports 16.4 GB remaining, which is impossible on a 5 GB plan: plan size, or what brctl measures, must be confirmed.
- Next: owner sends System Settings → Apple Account → iCloud → Manage breakdown (Photos, Backups, Messages, Mail are invisible here) and the plan size.

### 2026-10-13 18:14 PDT · A2 · PARTIAL
- Changed: `ledger.mjs backup-status` (read-only: destination last write, Arq 7 `*.backuprecord` snapshot count, sha256 comparison of an Arq-restored sample vs source without forcing downloads; state in `~/.ledger/backup-status.json`; exit 1 if stale >26 h, no drill, or mismatch). 3 new selftests. `ARQ-CHECKLIST.md`: destination, sources, excludes, schedule, thinning, materialize-in-batches, restore drill.
- Validated: selftest passes. Inspected the Mac: Arq 5.7.8 installed, no backup sets, agent not running, no `arqc`; SanDisk mounted, exFAT, 796 GiB free; internal disk ~12 GiB free.
- Not done: no backup has run, no restore verified (GUI-only; owner's step). `backup-status` against a real Arq 5 destination is unverified (snapshot count only for Arq 7 layout).
- Note: `/Volumes/SanDisk/Backups/` holds a plaintext password-export CSV and a Proton Pass zip (names only seen, not opened); consider moving them into an encrypted container.
- Next: owner chooses Arq 5 vs 7, follows the checklist, runs the drill command in §4. A3 stays gated on a passing drill.

### 2026-10-13 18:15 PDT · A3 · BLOCKED
- Changed: `A3-PROPOSAL.md` (ranked candidates with size, copy status, owner action; nothing deleted). `ledger.mjs quota [--total 5GB --target 60 --alert 80 --write]`: usage from `brctl quota` with configurable plan size, levels ok/over-target/alert/inconsistent, optional `~/.ledger/quota.json`. 2 new selftests.
- Validated: selftest passes. `quota --total 5GB` → `inconsistent` (16.4 GB remaining > 5 GB plan); `--total 50GB` → 67.2% used, `over-target`.
- Blocked on: plan size + Apple-side breakdown (A1); owner review of Recently Deleted (13.0 GB, 12.7 GB cloud-only, 11.3 GB single wav); A2 restore drill (no candidate has a verified copy).
- Next: owner decides per row in `A3-PROPOSAL.md`; then re-run `audit` and `quota --write`.
