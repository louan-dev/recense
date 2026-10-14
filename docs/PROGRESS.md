# PROGRESS.md · handoff to Claude Code · 2026-10-13

Read every session; keep §7 current. Detail lives in `BACKLOG.md`: open only the section for the item you're on.
Nothing below has run on the owner's Mac. The only execution was `src/ledger.mjs selftest` in a Linux sandbox (all passed). Treat every claim as a lead to verify.

## 1. Objective and order
**Sync** (backend root) → **Gallery** (Cloudflare Worker + R2: web UI, API, glue) → **Sill** (macOS strip app: the UI that embeds Gallery and reads Sync). Spend effort in that order. Backend taste: boring, quiet, elegant; event-driven, no polling; on-demand over daemons; standards over cleverness.

- **A · Unclog & Mirror — today.** iCloud is nearly full (**correction 2026-10-13: owner's screenshot shows iCloud+ 200 GB, 184.7 GB used, 92%**; the earlier "5 GB free tier" was wrong), so Notability, Obsidian and Calendar stopped syncing. Everything queues behind this.
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
- **`sync/`** (no git: `git init` locally first, no remote). `src/ledger.mjs`: read-only observer of the iCloud folder, writes an append-only, SHA-256, hash-chained journal to a directory or rclone sink; zero deps; `run|watch|fold|verify|restore|selftest`. Docs: `docs/research/ledger-report.md` (priorities P1–P10, run order), `docs/research/sync-matrix.md`, `docs/research/icloud-backend-technical-report.md` (safety gate, standards routes), `docs/runbooks/obsidian-integration.md` (Remotely Save → R2), `docs/specs/switchboard-spec.md` + `docs/specs/switchboard-scheduler-addendum.md` (Calendar Desk), `docs/specs/manager.md`, `docs/specs/sync.md` (CalDAV/WebDAV on Worker + R2 + D1). **`switchboard-iphone-addendum.md` is referenced everywhere but was not uploaded.**
- **`cloud-gallery/gallery/`** (git). Worker `src/worker.js` + `public.js`, `main.js`, `access.js`, `common.js`. Buckets `gallery-public` (PUBLIC), `gallery-main` (MAIN); cron 03:00. `/main` is owner-only via Cloudflare Access and everyone else gets a 404 by design. **No participant or invite model exists on main** (only public links `/s/<id>`). Comments, captions and folder order are JSON objects in R2. No D1/KV/DO yet. UI contract: `src/page/ui/README.md` (read §1.1, §3, §4.4, §7 before touching viewer or comments). Tests: `npm test` (miniflare + playwright; `node_modules` not shipped). `playerv12` (the player reference) was not uploaded. Scripts: `chau/setup.sh`, `chau/copy-share-link.sh` (README says `mac/` and `copy-public-link.sh`; reconcile). Clutter: `src/client/*.bak`, `src/page/ui.zip`, `.test-build/`.
- **`sill/sill/`** (git). One 7.2k-line `sill.swift`, `build.sh`, SwiftTerm. `backups/` holds 19 manual snapshots; `.build/`, `build/`, `*.bak` stay out of git and Arq. CPU/battery leads: one permanent 1 Hz timer (~line 6225) runs `pollExternal()` (stats `draftpad.md` every second to catch Obsidian edits), `updateClock()` and `restoreState()`; four repeating 60 Hz timers (settle/anim/band) and two 20 Hz meter timers (confirm each stops when idle); further 3 s, 60 s, 120 s and 30 min timers; 6 `Process()` calls (osascript near 4912–4920); 11 event-monitor sites; private MultitouchSupport gestures (experimental); no file-watch API. Draftpad file: `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian/draftpad.md`. Sill's own rule: consequential actions go draft → confirm → execute.
- **`nook/`** (no git). `main.swift` + `build.sh`: menu-bar hider (divider status items, per-app rules, hover-to-peek, auto-hide).
- "Proton Frankenstein" is in none of the uploads. Locate it on disk before touching anything.

## 4. Track A · Unclog & Mirror (finish tonight)
**A1 Locate the 5 GB (read-only).** Ask the owner for the iCloud storage breakdown (System Settings → [name] → iCloud → Manage, or iPhone Settings → [name] → iCloud). Photos, device Backups, Messages, Mail and app data count toward quota but are not in iCloud Drive, which is why deleting local files hasn't helped. Then add a read-only `audit` reusing ledger scanning: per `~/Library/Mobile Documents/*` container → files, apparent vs on-disk bytes, dataless count, top 50 largest, duplicates (size, then hash), dev junk (`node_modules`, `.build`, DerivedData) inside iCloud-synced paths. Output `AUDIT.md` (≤1 page) plus saved counts as baseline. Never read inside the Notability container (ledger denylist).

**A2 Backup gate (blocks A3).** Arq destination: the 1 TB SanDisk (R2 as an extra S3-compatible destination only if it fits the free tier; skip B2). Sources: Obsidian vault, Notability in-app export folder (PDF + Note), Documents, `~/Developer`, dotfiles, iCloud containers after materializing. Exclude: destination, caches, Trash, `node_modules`, `.build`, `build`, DerivedData, `*.bak`, ledger sinks and mirrors. Arq plans are set up in its GUI (check what `arqc` can script): output an exact checklist (sources, excludes, schedule, thinning retention) rather than faking automation. Add `backup-status`: last success, snapshot count, restore one sample to a scratch dir and compare sha256. Materialize dataless files in batches (`ledger run --materialize --stage-dir <SanDisk>`); a placeholder is not a backup.

**A3 Free the quota (owner approves a list; you delete nothing).** Candidates = items with a verified copy (checksum on SanDisk and/or R2). Facts to respect: evicting a local copy does not free iCloud quota; deleting from iCloud Drive deletes on every device; Recently Deleted (Drive, Photos, Notes, Mail) may still count until emptied; if device Backups dominate, offer: encrypted local Finder backup (covered by Arq) → turn off iCloud Backup → delete the old iCloud backup (owner's call). Target ≤60% used, alert at 80% (configurable). `brctl quota` may expose usage (verify).

**A4 Prove sync is back.** Canary note in the vault: Mac → iPhone → iPad → Mac; record latency. Confirm Notability on the iPad has finished uploading before touching anything it may hold.

**A5 Mirror with `src/ledger.mjs`.** On the Mac: `selftest` → dry run on a *copy* → `run --apply` on the Obsidian vault with sink `<SanDisk>/ledger/obsidian` → `verify --deep` → launchd job + `views/health.json` (alert when `lastOk` > 1 day) → iCloud Drive (review eviction counts first) → sink `rclone:gallery-main:ledger/<source>` (encrypt private material). One prefix per source. Untested on macOS: rclone sink, `SF_DATALESS` flag, `watch`.

**A6 Overflow lane (smallest version).** Config rule: file > N MB or iCloud usage ≥ 80% → goes to R2, a pointer note stays. Vault overflow: Remotely Save → R2 bucket `notes` with its own token (`docs/runbooks/obsidian-integration.md`); never run it and iCloud sync on the same vault at once. Notability: Auto-Backup → Worker WebDAV `/dav/notability/` (append-only, no DELETE, own app password); build after A5.

**A7 Surfaces.** Gallery: read-only `/main/ledger/` browsing `views/tree.json` (objects via Worker binding). Sill: status chip from `views/health.json`.

**Tonight is done when:** audit explains the 5 GB · Arq snapshot on SanDisk with a verified restore · iCloud usage under target and canary round-trips · vault mirrored by launchd with fresh `health.json` · §7 updated.

## 5. Track B · Desk (tomorrow)
**B1 Notes in Sill.** Obsidian panel (plain-markdown read/write; the vault stays the source of truth). Notability panel (read-only: Auto-Backup PDFs/Notes; never the container). Filesystem panel (ledger tree + search). Draftpad links via `obsidian://`, file paths, Notability PDF links. Re-measure draftpad.md latency after A4 before changing code; add a file watcher (none exists).
**B2 DEVONthink.** Replace Sill's standalone hub with a widget in the shared R2/Gallery bottom-bar panel. Detect the installed version first (DEVONthink 3 vs 4 Server). Connect through local AppleScript/JXA (query/open), `x-devonthink-item://` links, and Index-in-place of ledger folders (no duplicate storage). A WebDAV view of `views/tree.json` for DT sync is a candidate (verify what its sync accepts). Embed the Server web UI only on loopback or behind auth.
**B3 Calendar Desk.** Prerequisite: Switchboard Phases 0–1 (`docs/specs/switchboard-spec.md` §14: Worker, D1, secrets, notify channel); the addendum is built on them. Then implement `docs/specs/switchboard-scheduler-addendum.md` §§1–9, phases S1→S3 first, shadow mode first, §7 guardrails kept (per-provider opt-in once, veto window, undo, kill switch, rate limits, truthful messages; rescheduling is proposal-only). Owner deltas: ① offer the best **two** slots; ② calendar = Apple Calendar via the CalDAV Worker (`docs/specs/sync.md` §§5–7) or EventKit, not Google; ③ signals = wake/bed + steps via Shortcuts → `POST /signal` (steps from Health samples; verify) plus wake-strip interaction rhythm from Sill; ④ confirm/cancel texts leave through an always-on jailbroken iPhone SE with a second non-VoIP SIM (design is in the missing addendum; S1 and the signal/alarm parts of S2 need no SMS bridge, so start there; S2 late notices and S3 cancels do); ⑤ Sill shows cards and status only (Telegram, per the spec, stays the fallback card channel); execution lives in the Worker's Autonomy Governor. "Self-learning" = rules mode until ≥30 outcomes, then a calibrated model.
**B4 Apple data via standards.** Calendar/Contacts over CalDAV/CardDAV with app-specific passwords; Mail via IMAP (`mbsync`); iMessage: copy `chat.db` first, export from the copy. Private prefix, never public.

## 6. Track C · Rooms (next; security before cosmetics)
**C0 Server-side authz.** `/main` stays owner-only. Add a participant surface outside Access (e.g. `/m/<token>`): per-person invite tokens (≥128-bit, store the hash), scoped to one folder; perms {view, download, upload, comment, react, annotate}; expiry or none; revoke; per-media overrides (comments off for member X on media Y); document-level view-only lock; participants cannot delete the owner's content. Tests: unauthenticated, expired, revoked, direct URL, cross-folder, public/main separation. Hidden UI is not access control.
**C1 Data.** Add D1 (shares, members, comments, reactions, annotations); blobs stay in R2; migrate the JSON comment maps lazily. Durable Objects only for live presence and co-editing (WebSocket hibernation). No polling.
**C2 Product model and UI.** `BACKLOG.md` §G6 (Rooms, annotations, ephemeral posts) and §G1–G5; UI per `src/page/ui/README.md`.
**C3 Two-way R2 editing.** `BACKLOG.md` §G7: versioned save-back first, then live co-editing.

## 7. Status ledger (update as you go)
| ID | Item | State | Evidence / next |
|---|---|---|---|
| A1 | Audit + quota breakdown | PARTIAL | Plan = iCloud+ 200 GB, 184.7 GB used (`quota --total 200GB` → 91.8%, alert). Screenshots cover only "Others" (~2.5 GB; Backups 0 KB); the ~180 GB above it (Photos/Messages/Mail/Drive) still uncaptured |
| A2 | Arq plan + verified restore | PARTIAL | Owner: stay on Arq 5.7.8. Checklist updated (Arq 5 labels, Clips source, exFAT caution); `backup-status` accepts Arq 5 layout. No backup set or drill yet |
| A3 | Quota freed | PARTIAL | Owner decisions in `decisions/20261012 A3-PROPOSAL.md`: rows 1–4b proceed. Owner-side: empty Recently Deleted (13 GB), WhatsApp backup setting. Done here: Clips → Arq sources; 4b sidecar copied out + verified, awaits override + test. Row 5 needs the top of the Manage sheet |
| A4 | Canary round-trip | PARTIAL | Canary round-tripped Mac 18:16 → iPhone 19:16 → iPad 19:25 → Mac (arrival time unmeasured). Notability upload-finished not shown in the iPad screenshot |
| A5 | Ledger mirror | DONE (vault) | SanDisk sink: 146 files, `verify --deep` 0 problems; launchd agent installed, run from launchd exit 0, health OK. Next: WatchPaths trigger test, iCloud Drive source, R2 sink |
| A6 | Overflow lane, Notability WebDAV | PARTIAL | Planner done; Remotely Save owner-side; Notability WebDAV now unblocked by A5 (vault), not built |
| A7 | Gallery + Sill ledger surfaces | PROPOSED | |
| B1–B4 | Notes in Sill, DEVONthink, Calendar Desk, Apple pulls | PROPOSED | specs exist, no code; iPhone addendum missing |
| C0–C3 | Authz, D1, Rooms, co-editing | PROPOSED | no participant model exists |
| — | Chrome `/main` 404, setup scripts, Sill CPU, audio/EQ, layout, Draftpad, Phi, Nook, cleanup | PROPOSED | BACKLOG |

## 8. Decisions made (defaults; change only if the owner objects)
1. "rw" = R2. "5 GB" = the iCloud quota (superseded: the plan is iCloud+ 200 GB, see §1).
2. iCloud stays the live lane once unclogged; ledger mirrors it; R2 takes overflow (A6).
3. Add D1 to Gallery (concurrent two-way writes, revocation checks, queries; Sync/Switchboard specs already use D1).
4. Phi: reuse whatever is installed on the SanDisk. Owner says "3.2", the Oct 9 directive says 3.5; inspect the files.
5. Battery colors: green ≥40, yellow 30–39, red ≤29 (red at 29 is mandatory; the old spec's yellow overlapped red). One constant each.
6. Scheduler starts in shadow mode for 2 weeks (addendum §7); owner can switch to live.
7. Recommended private repo: `sync/` (src/ledger.mjs + specs): unique, tiny, unversioned, and the root of both other projects. Do not push anywhere until the owner names the repo.

## CHANGELOG

### 2026-10-13 18:14 PDT · A1 · PARTIAL
- Changed: `src/ledger.mjs audit` (read-only; per-container/Drive-folder files, apparent vs on-disk bytes, dataless count confirmed by batched `SF_DATALESS` checks, top 50, duplicates by size→sha256 on local copies only, dev-junk dirs; denied containers never opened, not even `readdir`). Writes `AUDIT.md` + baseline `~/.ledger/audit/latest.json` (full JSON with paths stays outside the repo; delta vs previous run). 4 new selftests. Also: `.gitignore` was an empty directory; replaced with a file. `git` already existed (commit `baseline`).
- Validated: `selftest` on macOS 15.5 / Node 24 (all passed, incl. first macOS run of the original 17 checks). Real audit of `~/Library/Mobile Documents`: 1,814 files, 15.1 GB apparent, 1.8 GB local, 443 dataless (13.3 GB). Both Notability containers denied, 0 unreadable.
- Findings: iCloud Drive Recently Deleted (`.Trash`) = 13.0 GB (12.7 GB cloud-only; an 11.3 GB `.wav`, a 305 MB `.m4b`, a 108 MB PDF); it counts against quota until emptied or auto-purged. Clips 1.3 GB, WhatsApp backup 423 MB, Obsidian 220 MB. No duplicates ≥1 MB, no dev junk. `brctl quota` reports 16.4 GB remaining, which is impossible on a 5 GB plan: plan size, or what brctl measures, must be confirmed.
- Next: owner sends System Settings → Apple Account → iCloud → Manage breakdown (Photos, Backups, Messages, Mail are invisible here) and the plan size.

### 2026-10-13 18:14 PDT · A2 · PARTIAL
- Changed: `src/ledger.mjs backup-status` (read-only: destination last write, Arq 7 `*.backuprecord` snapshot count, sha256 comparison of an Arq-restored sample vs source without forcing downloads; state in `~/.ledger/backup-status.json`; exit 1 if stale >26 h, no drill, or mismatch). 3 new selftests. `docs/runbooks/ARQ-CHECKLIST.md`: destination, sources, excludes, schedule, thinning, materialize-in-batches, restore drill.
- Validated: selftest passes. Inspected the Mac: Arq 5.7.8 installed, no backup sets, agent not running, no `arqc`; SanDisk mounted, exFAT, 796 GiB free; internal disk ~12 GiB free.
- Not done: no backup has run, no restore verified (GUI-only; owner's step). `backup-status` against a real Arq 5 destination is unverified (snapshot count only for Arq 7 layout).
- Note: `/Volumes/SanDisk/Backups/` holds a plaintext password-export CSV and a Proton Pass zip (names only seen, not opened); consider moving them into an encrypted container.
- Next: owner chooses Arq 5 vs 7, follows the checklist, runs the drill command in §4. A3 stays gated on a passing drill.

### 2026-10-13 18:15 PDT · A3 · BLOCKED
- Changed: `docs/proposals/A3-PROPOSAL.md` (ranked candidates with size, copy status, owner action; nothing deleted). `src/ledger.mjs quota [--total 5GB --target 60 --alert 80 --write]`: usage from `brctl quota` with configurable plan size, levels ok/over-target/alert/inconsistent, optional `~/.ledger/quota.json`. 2 new selftests.
- Validated: selftest passes. `quota --total 5GB` → `inconsistent` (16.4 GB remaining > 5 GB plan); `--total 50GB` → 67.2% used, `over-target`.
- Blocked on: plan size + Apple-side breakdown (A1); owner review of Recently Deleted (13.0 GB, 12.7 GB cloud-only, 11.3 GB single wav); A2 restore drill (no candidate has a verified copy).
- Next: owner decides per row in `docs/proposals/A3-PROPOSAL.md`; then re-run `audit` and `quota --write`.

### 2026-10-13 18:17 PDT · A4 · BLOCKED
- Changed: `src/canary.mjs` (separate from the read-only ledger; writes one note `_sync-canary.md` with a nonce, `check --wait N` blocks on `fs.watch` until the iPad line returns, results in `~/.ledger/canary.json`; never deletes). `tools/upload-status.swift` (read-only, public `NSURLUbiquitousItemIsUploaded*` keys; skips Notability and `.DS_Store`). Started the real canary `10051f3f` in the vault at 18:16.
- Validated: canary selftest + scratch-vault run (start → iphone → iPad line via `fs.watch` → exit 0). On the real vault: 237 files, 235 uploaded, 2 not: `draftpad.md` and the canary, both "uploading" with no upload error. `brctl status iCloud~md~obsidian`: client idle, last-sync 2026-10-13 07:50. Both pending files were written minutes earlier (`draftpad.md` 18:14), so this alone does not prove a stall; the 07:50 last-sync is the stronger hint. Re-check with `upload-status` after an hour.
- Blocked on: A3 (quota), then owner devices: on iPhone then iPad append `iphone HH:MM` / `ipad HH:MM` to `_sync-canary.md`; confirm on the iPad that Notability shows its iCloud upload finished.
- Next: after the owner frees space: `swift tools/upload-status.swift "<vault>"` until 0 pending, then `node src/canary.mjs check --wait 60`. Canary note stays in the vault until the owner removes it.

### 2026-10-13 18:27 PDT · A5 · PARTIAL
- Changed (`src/ledger.mjs`): **fix** state was keyed by source only, so a second sink (R2 after SanDisk) would inherit "unchanged" and never receive the files; now keyed by source×sink. New guard: a sink under `/Volumes/<X>` fails with "not mounted" instead of being created on the internal disk. New `health --sink S --max-age-hours 24` (exit 1 if `views/health.json` is missing or stale). 3 new selftests. Added `bin/ledger-job.sh` (run → fold --write → health; macOS notification on failure; exits 0 when the sink volume is absent) and `launchd/com.chauphan.ledger.obsidian.plist` (WatchPaths on the vault, StartOnMount, daily 03:30 heartbeat, Background/LowPriorityIO, log `~/Library/Logs/ledger-obsidian.log`; `plutil -lint` OK).
- Validated on this Mac (macOS 15.5, Node 24, rclone 1.75.1): selftest all passed. Dry run + apply on a local copy of the vault (151 local files): copy unchanged, deep verify OK, re-run idempotent. rclone sink path via on-the-fly `:local:` backend: upload, idempotent re-run, deep verify, restore = identical content (names come back NFC; source has NFD `RÉVÉLATO` names, equivalent on APFS). Real vault → scratch sink: 235 files, 145 captured, **89 dataless detected via `SF_DATALESS`**, 1 deferred (being edited), deep verify OK, vault names/mtimes/sizes/blocks/flags hash identical before and after. Job script on scratch sink: health OK; with SanDisk absent: clean skip.
- Blocked: the **SanDisk disappeared** during the first real `--apply` (EIO on copy, then gone from `diskutil list`); nothing was written to it. A drive that drops mid-write is itself a backup risk (cable/port/power). Watch (`fs.watch`) still untested.
- Next (owner): reconnect the SanDisk (try another port/cable), then
  `node ~/Developer/sync/src/ledger.mjs run --source "$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian" --sink /Volumes/SanDisk/ledger/obsidian --origin obsidian --apply && node ~/Developer/sync/src/ledger.mjs verify --sink /Volumes/SanDisk/ledger/obsidian --deep`
  then install the job (persistent; owner's call): `cp launchd/com.chauphan.ledger.obsidian.plist ~/Library/LaunchAgents/ && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.chauphan.ledger.obsidian.plist`. iCloud Drive and the `rclone:gallery-main:ledger/<source>` sink (with `crypt` for private material) come after.

### 2026-10-13 18:28 PDT · A6 · PARTIAL
- Changed: `src/ledger.mjs overflow` (read-only): candidates = files > `--max-mb` (default 25) outside `.obsidian/`; at ≥ alert% usage picks largest-first until projected usage ≤ target%; `ready` only when the sink holds the exact sha256; `pointerNote()` defines the note left behind. 3 new selftests. `docs/runbooks/OVERFLOW.md`: rule, Remotely Save → R2 `notes` checklist (bucket-scoped token, one sync layer per vault, canary), Notability WebDAV design (append-only, no DELETE/MOVE, own Basic-auth secret, miniflare tests). `docs/proposals/A3-PROPOSAL.md` row 4b added.
- Validated: selftest all passed (32 checks). Real vault at 10 MB: 1 candidate (73 MB `.mov`, cloud-only, so not ready); before the `.obsidian` exclusion it also flagged a 59 MB Mac-only plugin binary (`local-dictation-sidecar`) syncing through iCloud, now an A3 row.
- Not done: no bucket or token created, no Remotely Save configured (owner's Cloudflare/Obsidian GUI). No file moved, no pointer written. Notability WebDAV not built: the plan gates it on A5, which waits on the SanDisk.
- Next: owner sets the plan size so `quota` stops reading `inconsistent`; after A5 is DONE, build `/dav/notability/` in `cloud-gallery` per `docs/runbooks/OVERFLOW.md` §3.

### 2026-10-13 18:29 PDT · A4 · BLOCKED (update)
- Changed: nothing in code; re-measured.
- Validated: `swift tools/upload-status.swift <vault>` at 18:28 → 237 files, 237 uploaded, 0 pending (canary and `draftpad.md` included). Mac→iCloud upload for the Obsidian container works now (≤12 min for the canary), which agrees with `brctl quota`'s 16.4 GB free and weakens the "iCloud is full" premise. If iPad/iPhone still don't sync, look at those devices (their own iCloud state, Low Power/Low Data mode, Obsidian on iOS opened in the foreground) rather than the Mac.
- Next: owner appends the iPhone line, then the iPad line; run `node src/canary.mjs check --wait 60` on the Mac.

### 2026-10-13 19:06 PDT · A5 · PARTIAL (fix)
- Observed: owner ran the real vault → `/Volumes/SanDisk/ledger/obsidian` mirror at ~19:00. Process went to `U` (uninterruptible I/O) on a 0-byte `.part` at 19:05; every object had an AppleDouble `._` sibling. Cause: `LocalDirSink` used `fs.copyFile` → macOS `copyfile(3)`, which also copies xattrs (`com.apple.provenance`); exFAT stores them as `._` files and the FSKit exFAT driver hangs (earlier: EIO, then the drive dropped). So the earlier "drive dropped" was most likely this, not the cable.
- Changed: `putFile`/`getFile` now stream bytes only (`pipeline`, `wx`); `list()` ignores `._*` AppleDouble files so the partial sink needs no cleanup (finished objects are valid; `.part` and `._` are skipped). 1 new selftest (33 total, all passed).
- Not verified: a run onto the SanDisk itself (this session's sandbox cannot write `/Volumes`).
- Next: owner stops the stuck run (Ctrl-C; if it stays in `U`, eject or replug the SanDisk), re-runs the same command, then `verify --deep`.

### 2026-10-13 21:15 PDT · A1 · PARTIAL
- Changed: nothing in code. Read `requests/20261012 icloud 1–3.png`: **iCloud+ 200 GB, 184.7 GB used**. The "Others" list: Clips 1.2 GB, WhatsApp 403.7 MB, Notability Pro 298 MB, Obsidian 227.9 MB, iCloud Drive 105.4 MB, Books 70.8 MB, FaceTime 67.8 MB, Notes 27.7 MB, rest KB-sized; **Backups 0 KB**.
- Validated: `quota --total 200GB --write` → 91.8% used, level `alert` (`~/.ledger/quota.json`). `brctl quota` (16.48 GB left) agrees with Settings within rounding (200 − 184.7 = 15.3 GB; Settings rounds and may lag).
- Open: the Others list explains ~2.5 GB. The other ~180 GB sits in the categories above "Others" (Photos, Messages, Mail, possibly Drive incl. Recently Deleted), which the screenshots cut off.
- Next: owner screenshots the top of the same Manage sheet (above "Others").

### 2026-10-13 21:15 PDT · A2 · PARTIAL
- Changed: owner decision recorded: stay on Arq 5.7.8. `docs/runbooks/ARQ-CHECKLIST.md`: Arq 5 menu path (labels flagged to verify on screen), Clips container added to sources (A3 row 2), exFAT caution (first backup small, watch it finish). `src/ledger.mjs backup-status`: an Arq 5 destination (no `*.backuprecord`) is now a note, not a failure; otherwise Arq 5 could never pass. 1 new selftest; `npm test` passes.
- Validated: `~/Library/Arq/config` still has only `app_config.plist`: no destination or backup set yet.
- Next: owner sets up the destination + plan per the checklist, runs the drill; then `node src/ledger.mjs backup-status --dest /Volumes/SanDisk/Arq --source <vault> --restored ~/Desktop/arq-restore-test`.

### 2026-10-13 21:15 PDT · A3 · PARTIAL
- Changed: read `decisions/20261012 A3-PROPOSAL.md` (owner's Decision column; not edited). Row 2 (Clips): added to Arq sources. Row 4b (plugin binary): Speech Kit has a `sidecarPathOverride` setting that points to the executable and bypasses the plugin's installer, so the move is possible. Copied `bin/cpu/` (sidecar 59 MB + translation helper + 2 small files) to `~/Library/Application Support/obsidian-local-dictation/cpu/`; vault copy untouched.
- Validated: all 4 copied files match by sha256. Not tested: dictation running from the new path.
- Owner-side (Apple/app UI; I don't delete): rows 1/1a/1b "Drop" → Finder or iCloud.com → iCloud Drive → Recently Deleted → Delete All (13.0 GB). Row 3 → iPhone WhatsApp → Settings → Chats → Chat Backup. Row 4 (73 MB `.mov` to R2) waits on the R2 `notes` bucket + overflow lane. Row 4b: Obsidian → Settings → Speech Kit → sidecar path override = `~/Library/Application Support/obsidian-local-dictation/cpu/local-dictation-sidecar` (full path), test one dictation, then delete `.obsidian/plugins/local-dictation/bin/` from the vault. Row 5: see A1.
- Arithmetic: target 60% = 120 GB means ~65 GB must go; emptying Recently Deleted reaches about 171.7 GB (86%), still above the 80% alert. The big lever is in the uncaptured categories.

### 2026-10-13 21:15 PDT · A4 · PARTIAL
- Changed: nothing in code.
- Validated: `_sync-canary.md` has `iphone 19:16` and `iPad 19:25`, read back on the Mac. Hops as logged: Mac→iPhone ≤60 min (includes the owner's own delay), iPhone→iPad ≤9 min. Arrival back on the Mac: before my check at ~21:13, exact time unmeasured (no watcher was running; `canary.json`'s `backMs` is the check time, not arrival). Owner: DEVONthink To Go works on both devices. `.md` is unsupported in Notability (expected; the canary is an Obsidian note).
- Open: `requests/20261012 notability ipad.png` shows Notability's iCloud Drive search for the canary (no results) and 109 notes, not an upload status. Settings shows Notability Pro holding 298 MB in iCloud, so data reached iCloud, but "finished uploading" is unconfirmed.
- Next: owner checks Notability's sync/backup status screen on the iPad (or confirms a recent iPad note opens on another device).

### 2026-10-13 21:15 PDT · A5 · DONE (vault)
- Changed: launchd agent installed from `launchd/com.chauphan.ledger.obsidian.plist.example` (`__HOME__` substituted) → `~/Library/LaunchAgents/com.chauphan.ledger.obsidian.plist`, `launchctl bootstrap` + `kickstart`.
- Validated: owner's run (post-fix) wrote `/Volumes/SanDisk/ledger/obsidian`; `verify --deep` → 1 segment, 146 live files, 0 problems; `health` OK. launchd run: exit 0, 145 unchanged, 1 changed (draftpad), journal segment written, health OK (`~/Library/Logs/ledger-obsidian.log`). So iCloud and removable-volume access work from the agent.
- Not yet tested: WatchPaths actually firing on a vault edit (it watches only the top-level folder; the 03:30 daily run is the backstop). 221 leftover `._*` AppleDouble files from the hung run remain in the sink (ignored by `list()`); harmless.
- Next: check the log after the next Obsidian edit; then iCloud Drive source and the R2 sink (`crypt` for private material).

### 2026-10-13 21:15 PDT · A6 · PARTIAL
- Unchanged code. The Notability WebDAV build was gated on A5; the vault part of A5 is now done, so it can start in `cloud-gallery` when the owner says go (it's another repo and a deploy).
