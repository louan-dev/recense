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

**A8 Messenger backup, scheduled (PROPOSED; grouped with the WhatsApp chat backup, A3 row 3).** Does not gate "Tonight is done when". *Goal:* Messenger chats are backed up on a schedule with one manual step (the download), private, verified, and mirrored like the rest of Track A. *Objectives:*
1. **Schedule in Meta's own tool** (Accounts Center → Your information and permissions → Download your information → recurring export: Messages, JSON, all time, media included). Verify which intervals and delivery options (download link or cloud destination) this account offers and how long a link stays valid. No scraping, no unofficial APIs, no Facebook credentials in code, scripts or Workers (rule 7).
2. **Drop folder, event-driven ingest.** Owner saves each finished zip to `<SanDisk>/inbox/messenger/`. A launchd job (WatchPaths + StartOnMount, same shape as the A5 agent) ingests it: record sha256, extract a copy, never edit or delete the zip. No polling.
3. **Verify per export.** Thread and message counts must not shrink vs the previous export; once, compare 2–3 sample chats with the app. Check whether end-to-end encrypted chats are in the export (do not assume); if absent, record the gap, don't fake it.
4. **Normalize on the copy only.** Check the known JSON text-encoding flaw (UTF-8 stored as Latin-1 escapes; verify on real data); write a derived per-thread `.jsonl` plus index. Raw export untouched.
5. **Mirror.** `src/ledger.mjs run --origin messenger`: SanDisk sink first, then R2 through `crypt`. Private prefix, never public. `verify --deep`.
6. **Health.** `views/health.json` for the messenger source; alert when the newest export is older than schedule interval + grace (configurable), so a missed download shows.
*Done when:* first scheduled export archived and hashed · counts verified · encrypted-chat coverage stated (covered or gap) · SanDisk sink `verify --deep` clean · R2 sink encrypted · health fresh · §7 updated.

**A9 Time Machine on the 1 TB SanDisk (PROPOSED; a second, full-system layer beside Arq, A2).** Does not gate "Tonight is done when". *Goal:* macOS Time Machine backs up the whole Mac to the SanDisk automatically whenever it is attached, encrypted, proven by a real restore, and reported next to Arq and the ledger, without costing anything already on the drive (Arq destination, `ledger/` sink, `Backups/`, the Phi model files). *Drive specs* (from retailer listings; sandisk.com's page is script-rendered and returned no spec table, so verify on the device):
- SanDisk Ultra Dual Drive Go USB Type-C, 1 TB, SKU SDDDC3-1T00-G46. A USB flash drive, not an SSD.
- Interface USB 3.1 Gen 1 (also labelled USB 3.2 Gen 1, 5 Gbps nominal). Two connectors: USB Type-C and USB Type-A on a swivel that covers whichever is unused.
- Speed: listings say up to 150 MB/s read (some say up to 400 MB/s). No write speed appears in any listing seen.
- 44.5 × 12.2 × 8.6 mm, 3.7 g, key ring loop. 5-year warranty (one retailer).
- Compatibility per one retailer: Windows 10+, OS X 10.9+, iOS, Android 11+.
- This unit: exFAT, 796 GiB free at 18:14 (A2 changelog).

*Objectives:*
1. **Inventory first (read-only).** `diskutil list`, `diskutil info /Volumes/SanDisk`, `system_profiler SPUSBDataType`: partition map, format, free space, the real USB link speed on the Mac's port, and everything on the drive (`Arq/`, `ledger/`, `Backups/`, the Phi files, anything else). Record the internal disk's used bytes against the 1 TB.
2. **Size check.** Time Machine keeps hourly, daily and weekly history, so the destination must sit well above the data backed up (Apple's guidance is roughly twice; verify). Measure used bytes minus the exclusions in objective 5 and decide how much of the drive Time Machine gets.
3. **Format decision (owner's call).** Time Machine does not use exFAT: it wants a Mac-format volume (APFS; HFS+ also works), and on an exFAT drive it offers to erase it. Never accept "Erase" with anything uncopied on the drive (rule 5). Options: **(a)** one APFS container with two volumes, `SanDisk` (keeps every `/Volumes/SanDisk/...` path in this file valid and drops the exFAT/`._` AppleDouble hang seen in A5) and an encrypted `TimeMachine` volume with the Backup role and an optional quota; space is shared, no fixed split. **(b)** two partitions, exFAT `SanDisk` plus APFS `TimeMachine`; fixed split, and Windows can still read the exFAT part. Disk Utility likely cannot shrink exFAT in place (verify), so assume (b) also erases. APFS is not readable on Windows, which matters only if the owner reads this drive there.
4. **Migration gate.** Either option erases the drive. Copy everything off first to a second location, compare sha256, owner confirms the list, then repartition. Claude runs no `eraseDisk`, `partitionDisk` or `apfs` command without an explicit go. Ideally this happens before the first Arq backup so the Arq repository is never moved. The ledger sink is a hash-chained journal: copy it as-is, then `verify --deep` after copy-back. `Backups/` (plaintext password CSV, Proton Pass zip, see A2 note) goes wherever the owner says; nothing is deleted. If (a) or (b) is chosen, the exFAT caution in `ARQ-CHECKLIST.md` changes: update the runbook then, not now.
5. **Configure Time Machine.** System Settings → General → Time Machine → add the `TimeMachine` volume, encryption on. The passphrase stays in the owner's password manager, never in code, logs or this file. Exclusions mirror A2: caches, Trash, `node_modules`, `.build`, `build`, DerivedData, `*.bak`, ledger sinks and mirrors, the Arq destination, the Time Machine volume itself. Cloud-only iCloud placeholders are probably not backed up (verify), so A2's materialize rule still applies.
6. **Drive behavior.** The drive has dropped before (A5: EIO, then gone from `diskutil list`), and a flash drive can throttle and run warm under sustained writes. First backup: direct port (no hub), unattended, no eject mid-run, watch `log stream --predicate 'subsystem == "com.apple.TimeMachine"'`, measure throughput over the first hour to estimate completion, try another port if it drops again. The internal disk has about 12 GiB free (A2): Time Machine adds purgeable local snapshots there (`tmutil listlocalsnapshots /`), so check free space before and after.
7. **Prove it with a restore.** `tmutil destinationinfo`, `tmutil latestbackup`, `tmutil listbackups` (verify flags on this macOS). Restore one known file to a scratch directory (never over the original) and compare sha256, once through the Time Machine UI. Same drill shape as A2.
8. **Status.** Extend read-only `backup-status` (or add a sibling `tm-status`): last Time Machine backup time, destination mounted or not, snapshot count, stale threshold configurable (it only runs while the drive is attached, so "stale" means days since last; owner picks the default). Show it in `views/health.json`.
9. **State the residual risk.** Arq, Time Machine and the ledger sink now share one 3.7 g keyring flash drive: one loss or failure takes all three. Encryption covers the loss case, not the failure case. The off-site copy is R2 (A5 R2 sink; Arq R2 destination if it fits the free tier). Claim no 3-2-1 until a verified off-site copy exists.

*Done when:* format decision recorded · everything previously on the drive copied, hash-matched and owner-confirmed before any erase · `TimeMachine` volume encrypted and first full backup finished · one sample restored from Time Machine with matching sha256 · Arq and ledger paths on the drive still work (`verify --deep`, `backup-status`) · status in health · residual single-drive risk written down · §7 updated.

**A10 Phi 3.5 on the 1 TB SanDisk (PROPOSED; the local-model lane on the same drive as A2, A5 and A9).** Does not gate "Tonight is done when". *Goal:* the Phi 3.5 model already installed on the SanDisk loads and answers prompts on the owner's Mac straight from the drive, on demand and offline, with the drive's limits measured and the model files left untouched. Drive specs, the exFAT caveat and the drop history are in A5 and A9. *Objectives:*
1. **Inventory first (read-only).** Locate the model on the drive and list its files with sizes and sha256 (record only; nothing moved, renamed or deleted, rule 5). Identify the exact variant (mini, MoE or vision; instruct or base), the weight format (GGUF, MLX/safetensors, ONNX), the quantization, and whatever tool installed it and where that tool's config points. Decision 4 says to inspect the files: confirm from them that this is 3.5, and write down what "3.2" referred to, if anything. Record the Mac's RAM (verify) and the internal free space (about 12 GiB, A2), since both bound what can run.
2. **Pick the runtime (smallest that works).** Reuse the tool that installed the model if it still runs; otherwise one standard runtime that reads the format found in objective 1 on this Mac (M1, macOS 15.5). No new framework or dependency without demonstrated need (rule 3). Record the version and the exact command that works.
3. **Load from the drive.** Run one fixed short prompt with the model path on `/Volumes/SanDisk/...`. Record cold load time (first read over USB from a flash drive whose listings give only "up to 150 MB/s" read; measure it), warm load time, tokens per second, peak memory, and whether the drive dropped or ran warm. Do not copy the model to the internal disk unless the owner decides; if that would help, state the size and the trade-off as a proposal.
4. **Drive-specific failure modes.** exFAT writes `._*` AppleDouble files (A5): check whether any sit beside the model files and whether the runtime's directory scan trips on them; point it at exact files or make it ignore them. Use the model directory read-only (no convert, quantize or cache output onto the drive without an explicit go). If the drive is absent or drops mid-load, the run must fail with a plain message and exit, never hang in `U` state (same shape as the A5 "not mounted" guard).
5. **Config and path.** One config value for the model path and one for the runtime; no hardcoded paths. The path must survive A9: under format option (a) `/Volumes/SanDisk/...` stays valid, under (b) it may not. The model files are on A9's copy-off list; hash them before and after any migration and re-run objective 7 afterwards.
6. **On demand, no daemon.** Start the model when asked and let it exit when idle. If something later needs a local endpoint (Sill, Sync tools), it is loopback only, never listening on the network, started on demand. Wiring Phi into Sill or Gallery is not part of this item: only record which interface the runtime exposes (CLI or local HTTP) so later work can attach.
7. **Prove it.** Run three fixed prompts (a short answer, a summary of a short text, a small structured JSON reply), then eject and remount the SanDisk and run them again. Keep the prompts and outputs in the repo as the baseline; judge "sane", claim nothing about quality beyond what was run (rule 6).
8. **Status.** A read-only `phi-status` check (or a line in `views/health.json`): drive mounted or not, model files present with expected sizes (full sha256 on demand, not every run), runtime version. Stale or missing shows as a warning, never a crash.
9. **State the residual risk.** The model now shares the one keyring flash drive with Arq, Time Machine and the ledger sink (A9 objective 9). Record where the model files came from, so they can be fetched again if the drive fails; claim no copy exists until one is verified.

*Done when:* variant, format and runtime recorded and 3.5 confirmed from the files · one prompt answered from the drive with load time and tokens per second measured · the three-prompt baseline passes again after eject and remount · drive-absent behavior is a clean failure · model path in config and valid after A9 · model files hash-identical before and after · status check in place · source of the files written down · §7 updated.

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
| A1 | Audit + quota breakdown | DONE | icloud.com: Photos 149.6 GB, Messages 22.6, Documents 15.3 (→ ~2.6 after trash), Mail 3.5, Backups 0. Audit re-run 2026-10-14 |
| A2 | Arq plan + verified restore | PARTIAL | Arq 5.7.8 → R2 bucket `c267690e…-arq` (owner-configured, works on macOS 15.5). **Restore drill not done** (no `~/.ledger/backup-status.json`, no restore folder). `sync-backup` key is account-wide and was pasted in plain text: rotate |
| A3 | Quota freed | PARTIAL | Target approved: ≤75%, alert 85% (code defaults now 200GB/75/85). Still 91.9% on 2026-10-22: the emptied 12.5 GB never came off Apple's total. Next: icloud.com Data Recovery / Recently Deleted check, then Messages attachments |
| A4 | Canary round-trip | DONE | Canary Mac→iPhone→iPad→Mac. Notability: persists to Notability Server (sockets connected, breakers closed); legacy iCloud 104/104 uploaded; Auto-Backup disabled |
| A5 | Ledger mirror | DONE | Sink moved to R2 `gallery-main/ledger/obsidian` (unencrypted, private bucket), SanDisk removed from launchd. Seed: 250 files incl. 89 materialized, `verify --deep` 0 problems; launchd run exit 0, health OK |
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

### 2026-10-14 00:34 PDT · A1 · DONE
- Changed: read `requests/20261012 icloud 4.png` (icloud.com storage): 200 GB plan, used 184.6 GB: Photos 149.6 GB (18,271 photos, 1,282 videos), Messages 22.6 GB, Documents 15.3 GB, Mail 3.5 GB. Device backups 0 KB (earlier screenshot). Re-ran `audit`: Mobile Documents 2.6 GB apparent (was 15.1), `.Trash` 0.5 GB / 158 files (was 13.0 GB / 687), delta −12.5 GB, −530 files.
- Validated: Documents 15.3 GB on icloud.com ≈ audit's 15.1 GB before emptying, so the audit's view of Drive matches Apple's. `brctl quota` 16.55 GB free (+0.1 GB): Apple's total has not reflected the emptied trash yet.
- Next: re-run `quota --total 200GB` tomorrow; expect ~29 GB free.

### 2026-10-14 00:34 PDT · A3 · PARTIAL
- Owner did: emptied Recently Deleted (rows 1/1a/1b), WhatsApp backup (row 3), Speech Kit override set and vault `bin/` removed (row 4b; `data.json` override non-empty, `bin/` gone; plugin now runs from `~/Library/Application Support/obsidian-local-dictation/cpu/`).
- Changed: `docs/proposals/A3-USAGE-TARGET.md` (owner asked for a recommendation): keep the 200 GB plan (moving 150 GB of photos to R2 costs about the same and loses iCloud Photos); target ≤75% (≤150 GB, ≥50 GB free for ephemeral sync and photo growth), alert 85%; Messages large attachments first, then archive the largest old videos to R2 (`crypt`, sha256-verified) only if needed. Notability's legacy iCloud copy stays (only second copy until A6 backup exists).
- Not changed: `ledger quota` defaults stay 60/80 until the owner approves 75/85.
- Next: owner approves the target; reviews Messages → Review Large Attachments on the iPhone.

### 2026-10-14 00:34 PDT · A4 · DONE
- Validated: `requests/20261012 notability ipad logs.zip` (extracted to scratch, not committed): Notability 16.12.4 on iPad15,6, **Persistence Mode: Notability Server** (migrated 2026-06-16), 109 notes; server sync socket reachable, metadata socket connected, both circuit breakers closed; mutation acks 0 remaining. Legacy iCloud store: 104 uploaded, 0 uploading, quota not reached. App logs: 0 sync-failure or quota lines across 10 files. Canary round-trip as logged earlier.
- Finding: **Notability Auto-Backup is disabled**, so Notability's server is the only live copy. That raises A6's Notability WebDAV backup priority.

### 2026-10-14 00:34 PDT · A2 · PARTIAL
- Owner decision: the SanDisk is not a reliable destination; use Cloudflare. `docs/runbooks/ARQ-CHECKLIST.md` §1–2 rewritten: R2 bucket `arq` with a bucket-scoped Object R/W token, Arq 5 "S3-Compatible Server", Arq encryption, 8 GB budget to stay inside R2's 10 GB free tier, iCloud Drive left to the ledger, drill via `backup-status --source … --restored …` (no `--dest`, since R2 isn't a local folder).
- Unverified: whether Arq 5.7.8 works against R2 (signature/region, and whether it insists on creating its own bucket). Fallback documented: ledger → `rclone crypt` on R2.
- Existing rclone remotes (names/types only): `r2`, `gallery-main`, `gallery-public` (S3/Cloudflare), `studio`, `gallery` (combine). None is scoped to an `arq` bucket.
- Next: owner creates bucket + token and adds the Arq destination; first backup = vault only.

- 2026-10-14 07:34 PDT · A5 · DONE: removed the Notability entry from DENY in src/ledger.mjs (Messages replaces it in the selftest). Test: run/verify --deep/restore on one real .nbn (5 files, 574,536 bytes, 0 problems, source stat unchanged). Caveat: a .nbn is several files, so a mid-edit run can capture a mixed state until the next run. Next: dry run Obsidian and Notability as separate sources once the sink path is known.

### 2026-10-22 18:02 PDT · A3 · PARTIAL
- Owner approved the usage recommendation. `src/ledger.mjs quota` defaults: `--total 200GB --target 75 --alert 85` (were 5GB/60/80); test updated; `npm test` all passed. `quota --write` → 91.9% used, 16.26 GB free, level `alert`.
- Finding: 8 days after Recently Deleted was emptied (local `.Trash` 13.0 → 0.5 GB), Apple's free space hasn't changed (16.5 → 16.3 GB). Either the server copy wasn't purged or new usage replaced it.
- Next: owner checks icloud.com → iCloud Drive → Recently Deleted (and Photos → Recently Deleted) and re-screenshots storage; then Messages → Review Large Attachments.

### 2026-10-22 18:02 PDT · A5 · DONE
- Owner decision: launchd mirror to R2 only; SanDisk dropped from launchd. Changed: `launchd/…plist.example` sink → `rclone:gallery-main:gallery-main/ledger/obsidian`, `StartOnMount` removed; `bin/ledger-job.sh` exports a PATH with Homebrew (launchd lacks it; rclone is in `/opt/homebrew/bin`) and runs `--materialize` (a placeholder is not a backup). Agent re-bootstrapped.
- Why this bucket: the plan's A5/A7 path; uses the existing bucket-scoped `gallery-main` key (`sync-backup` would also work but reaches every bucket); Gallery only lists `files/`, `order/` and its other own prefixes (`src/main.js`), so `ledger/` stays invisible in the UI until A7 adds `/main/ledger/`. Unencrypted per owner (readable from anywhere; protected by the private bucket and Cloudflare account).
- Validated: seed run: 250 files, 235 objects, 162.9 MB uploaded, 0 evicted (89 cloud-only files materialized), 6 `conflict` events (duplicate-style names: `Untitled 1.md`, `IMG_3855 1.jpeg`, 4 PDFs/PNG under `Imported/`; heuristic, owner can review). `verify --deep` 1 segment, 250 live, 0 problems. launchd kickstart: exit 0, 250 unchanged, health OK.
- Finding: the old SanDisk job had logged 539 silent `skip: not mounted` lines from 2026-10-14 09:23Z to 2026-10-22: the vault went 8 days unmirrored with no alert. The R2 sink fails loudly (notification) instead.
- Not tested: WatchPaths firing on an edit; rclone over a network outage (expected: run fails → notification; next trigger retries).

### 2026-10-22 18:02 PDT · A2 · PARTIAL
- Owner: Arq 5.7.8 works on macOS 15.5, destination R2 (Arq made bucket `c267690e36349d5d02de51e4a48ea1eb-arq`); SanDisk is not to be used.
- Checked: restore drill **not done** (no `~/.ledger/backup-status.json`, no `~/Desktop/arq-restore-test`).
- Security: the owner pasted the `sync-backup` R2 secret and the Arq password into `decisions/20261022 ARQ-CHECKLIST.md` and the tracked `docs/runbooks/ARQ-CHECKLIST.md`. Redacted in the runbook (decisions copy untouched per its README) and `.gitignore` now excludes that decisions file; nothing was committed. `sync-backup` can list all buckets and read `gallery-main`, so it is account-wide, not two-bucket. Owner: rotate it in Cloudflare, rescope to the two buckets, update rclone/Arq.
- Next: owner runs the drill (ARQ-CHECKLIST §4).

### 2026-10-22 18:02 PDT · SanDisk evacuation · PROPOSED
- `docs/runbooks/sandisk-evac.md`: refined owner script: volume found by name (was `disk4s2`; actual volume was on `disk4s1`), read-only mount, MD5-verifiable copy (dropped `--s3-disable-checksum`), hash `check` before erase, excludes for AppleDouble/old ledger/cache and the two plain-text password exports, day/night `--bwlimit`, erase + `f3` capacity test, Windows 11 option.
- Measured: uplink 52.7 Mbps (~6.6 MB/s → 140 GB ≈ 7–9 h); uplink responsiveness Low (bufferbloat). Mac: M1 (MacBookPro17,1), **8 GB RAM**, ~5 GiB free internal.
- Models: re-pull instead of copying: `phi3.5` and **`phi4-mini`** (not 14B `phi4`, which doesn't fit 8 GB RAM), `OLLAMA_MODELS` on the APFS SanDisk; Obsidian via a local-LLM plugin at `localhost:11434`.

### 2026-10-22 18:02 PDT · Notability source · PROPOSED
- Owner found `~/Library/Mobile Documents/ZP9ZJ4EF3S~com~gingerlabs~Notability/Documents` and removed the ledger denylist entry (uncommitted change kept and committed here; selftest passes).
- Fact from the 2026-10-14 iPad logs: Notability persists to **Notability Server** since 2026-06-16 (109 notes); this iCloud folder is the **legacy** store (104 notes), no longer updated. Its `.note` files are proprietary: editing copies outside Notability can't flow back, so two-way via the ledger is not possible (the ledger is one-way by design; `watch` exists but is untested).
- Fits the goals as: (1) a one-time read-only ledger snapshot of the legacy folder to `gallery-main/ledger/notability-legacy` (archive); (2) Notability Auto-Backup (PDF + Note) → A6 WebDAV for current notes, readable as PDFs in Obsidian/DEVONthink. Owner to approve (1).
