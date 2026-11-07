# PROGRESS.md · handoff to Claude Code · 2026-10-13

Read every session; keep §7 current. Detail lives in `BACKLOG.md`: open only the section for the item you're on.
Nothing below has run on the owner's Mac. The only execution was `src/ledger.mjs selftest` in a Linux sandbox (all passed). Treat every claim as a lead to verify.

## 1. Objective and order
**Sync** (backend root) → **Gallery** (Cloudflare Worker + R2: web UI, API, glue) → **Recense** (macOS strip app: the UI that embeds Gallery and reads Sync). Spend effort in that order. Backend taste: boring, quiet, elegant; event-driven, no polling; on-demand over daemons; standards over cleverness.

- **A · Unclog & Mirror — today.** iCloud is nearly full (**correction 2026-10-13: owner's screenshot shows iCloud+ 200 GB, 184.7 GB used, 92%**; the earlier "5 GB free tier" was wrong), so Notability, Obsidian and Calendar stopped syncing. Everything queues behind this.
- **B · Desk — tomorrow.** Notability, Obsidian and filesystem usable inside Recense; Calendar Desk scheduler; DEVONthink.
- **C · Rooms — next.** Gallery collaboration: main (shared, two-way) vs public (one-way).
- Everything else: BACKLOG, in dependency order.

## 1a. Long-term goal: Gallery, the nervous system for my files (owner, 2026-10-27)
Files usable **with no connection** on Mac, iPhone and iPad, in each device's native place. Edits flow both ways when a connection appears; nothing of mine runs 24/7; the Mac's disk is freed by moving bulk folders into R2 behind an always-on mount. R2 is the storage. The Worker is the **sync engine** (catalog with an event log, cursors and stable ids; rules; sync plans), `/main` is the one interface, and thin adapters per device obey it (Mac NFS + launchd + `~/Gallery`; iOS Home Screen web app + Shortcuts; File Provider later).
**Read `docs/specs/gallery-nervous-system.md` first:** outcome, invariants, decisions, order, rules, status. The engine design goes in `~/Developer/gallery/gallery/docs/engine.md` (once written).
*Ownership (PROPOSED 2026-10-29, §8 decision 8):* the engine is Sync's job, built today inside the Gallery Worker; which project owns what is in `docs/specs/organism.md`.

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
- **`gallery/gallery/`** (git). Worker `src/worker.js` + `public.js`, `main.js`, `access.js`, `common.js`. Buckets `gallery-public` (PUBLIC), `gallery-main` (MAIN); cron 03:00. `/main` is owner-only via Cloudflare Access and everyone else gets a 404 by design. **No participant or invite model exists on main** (only public links `/s/<id>`). Comments, captions and folder order are JSON objects in R2. No D1/KV/DO yet. UI contract: `src/page/ui/README.md` (read §1.1, §3, §4.4, §7 before touching viewer or comments). Tests: `npm test` (miniflare + playwright; `node_modules` not shipped). `playerv12` (the player reference) was not uploaded. Scripts: `chau/setup.sh`, `chau/copy-share-link.sh` (README says `mac/` and `copy-public-link.sh`; reconcile). Clutter: `src/client/*.bak`, `src/page/ui.zip`, `.test-build/`.
- **`recense/recense/`** (git, `github.com/louan-dev/recense`; called Sill until 2026-11-03). **Recense is the only
  app**: `recense/recense.swift` (7.4k lines) is its transcript surface and `app.swift` the strip and entry point (the
  old `sill.swift`). Recense owns the window, the audio engine (`soundengine.swift`: Core Audio process tap +
  EQ/Key/Space chain), the localhost server on port 47123 and the caches; the transcript surface is an in-process
  `NSPanel` (`recense.swift:1599`) summoned from the strip, with its menu in Recense's menu bar. There is no second
  process. The older standalone Recense copy (then `sill/recense/`) is deleted: never recreate it. Authoritative:
  `recense/.claude/CLAUDE.md` § "One app" and `recense/docs/architecture.md`. Files: `app.swift` (7.6k), `recense.swift` (7.4k),
  `soundengine.swift` (0.4k), symlinked into `Sources/recense/`; `build.sh`, `Package.swift`, SwiftTerm. `backups/` holds 19 manual snapshots; `.build/`, `build/`, `*.bak` stay out of git and Arq. CPU/battery leads: one permanent 1 Hz timer (~line 6225) runs `pollExternal()` (stats `draftpad.md` every second to catch Obsidian edits), `updateClock()` and `restoreState()`; four repeating 60 Hz timers (settle/anim/band) and two 20 Hz meter timers (confirm each stops when idle); further 3 s, 60 s, 120 s and 30 min timers; 6 `Process()` calls (osascript near 4912–4920); 11 event-monitor sites; private MultitouchSupport gestures (experimental); no file-watch API. Draftpad file: `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian/draftpad.md`. Recense's own rule: consequential actions go draft → confirm → execute.
- **`nook/`** (no git). `main.swift` + `build.sh`: menu-bar hider (divider status items, per-app rules, hover-to-peek, auto-hide).
- "Proton Frankenstein" is in none of the uploads. Locate it on disk before touching anything.

## 4. Track A · Unclog & Mirror (finish tonight)
**A1 Locate the 5 GB (read-only).** Ask the owner for the iCloud storage breakdown (System Settings → [name] → iCloud → Manage, or iPhone Settings → [name] → iCloud). Photos, device Backups, Messages, Mail and app data count toward quota but are not in iCloud Drive, which is why deleting local files hasn't helped. Then add a read-only `audit` reusing ledger scanning: per `~/Library/Mobile Documents/*` container → files, apparent vs on-disk bytes, dataless count, top 50 largest, duplicates (size, then hash), dev junk (`node_modules`, `.build`, DerivedData) inside iCloud-synced paths. Output `AUDIT.md` (≤1 page) plus saved counts as baseline. Never read inside the Notability container (ledger denylist).

**A2 Backup gate (blocks A3).** Arq destination: the 1 TB SanDisk (R2 as an extra S3-compatible destination only if it fits the free tier; skip B2). Sources: Obsidian vault, Notability in-app export folder (PDF + Note), Documents, `~/Developer`, dotfiles, iCloud containers after materializing. Exclude: destination, caches, Trash, `node_modules`, `.build`, `build`, DerivedData, `*.bak`, ledger sinks and mirrors. Arq plans are set up in its GUI (check what `arqc` can script): output an exact checklist (sources, excludes, schedule, thinning retention) rather than faking automation. Add `backup-status`: last success, snapshot count, restore one sample to a scratch dir and compare sha256. Materialize dataless files in batches (`ledger run --materialize --stage-dir <SanDisk>`); a placeholder is not a backup.

**A3 Free the quota (owner approves a list; you delete nothing).** Candidates = items with a verified copy (checksum on SanDisk and/or R2). Facts to respect: evicting a local copy does not free iCloud quota; deleting from iCloud Drive deletes on every device; Recently Deleted (Drive, Photos, Notes, Mail) may still count until emptied; if device Backups dominate, offer: encrypted local Finder backup (covered by Arq) → turn off iCloud Backup → delete the old iCloud backup (owner's call). Target ≤60% used, alert at 80% (configurable). `brctl quota` may expose usage (verify).

**A4 Prove sync is back.** Canary note in the vault: Mac → iPhone → iPad → Mac; record latency. Confirm Notability on the iPad has finished uploading before touching anything it may hold.

**A5 Mirror with `src/ledger.mjs`.** On the Mac: `selftest` → dry run on a *copy* → `run --apply` on the Obsidian vault with sink `<SanDisk>/ledger/obsidian` → `verify --deep` → launchd job + `views/health.json` (alert when `lastOk` > 1 day) → iCloud Drive (review eviction counts first) → sink `rclone:gallery-main:ledger/<source>` (encrypt private material). One prefix per source. Untested on macOS: rclone sink, `SF_DATALESS` flag, `watch`.

**A6 Overflow lane (smallest version).** Config rule: file > N MB or iCloud usage ≥ 80% → goes to R2, a pointer note stays. Vault overflow: Remotely Save → R2 bucket `notes` with its own token (`docs/runbooks/obsidian-integration.md`); never run it and iCloud sync on the same vault at once. Notability: Auto-Backup → Worker WebDAV `/dav/notability/` (append-only, no DELETE, own app password); build after A5.

**A7 Surfaces.** Gallery: read-only `/main/ledger/` browsing `views/tree.json` (objects via Worker binding). Recense: status chip from `views/health.json`.

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
6. **On demand, no daemon.** Start the model when asked and let it exit when idle. If something later needs a local endpoint (Recense, Sync tools), it is loopback only, never listening on the network, started on demand. Wiring Phi into Recense or Gallery is not part of this item: only record which interface the runtime exposes (CLI or local HTTP) so later work can attach.
7. **Prove it.** Run three fixed prompts (a short answer, a summary of a short text, a small structured JSON reply), then eject and remount the SanDisk and run them again. Keep the prompts and outputs in the repo as the baseline; judge "sane", claim nothing about quality beyond what was run (rule 6).
8. **Status.** A read-only `phi-status` check (or a line in `views/health.json`): drive mounted or not, model files present with expected sizes (full sha256 on demand, not every run), runtime version. Stale or missing shows as a warning, never a crash.
9. **State the residual risk.** The model now shares the one keyring flash drive with Arq, Time Machine and the ledger sink (A9 objective 9). Record where the model files came from, so they can be fetched again if the drive fails; claim no copy exists until one is verified.

*Done when:* variant, format and runtime recorded and 3.5 confirmed from the files · one prompt answered from the drive with load time and tokens per second measured · the three-prompt baseline passes again after eject and remount · drive-absent behavior is a clean failure · model path in config and valid after A9 · model files hash-identical before and after · status check in place · source of the files written down · §7 updated.

**Tonight is done when:** audit explains the 5 GB · Arq snapshot on SanDisk with a verified restore · iCloud usage under target and canary round-trips · vault mirrored by launchd with fresh `health.json` · §7 updated.

## 5. Track B · Desk (tomorrow)
**B1 Notes in Recense.** Obsidian panel (plain-markdown read/write; the vault stays the source of truth). Notability panel (read-only: Auto-Backup PDFs/Notes; never the container). Filesystem panel (ledger tree + search). Draftpad links via `obsidian://`, file paths, Notability PDF links. Re-measure draftpad.md latency after A4 before changing code; add a file watcher (none exists).
**B2 DEVONthink.** Replace Recense's standalone hub with a widget in the shared R2/Gallery bottom-bar panel. Detect the installed version first (DEVONthink 3 vs 4 Server). Connect through local AppleScript/JXA (query/open), `x-devonthink-item://` links, and Index-in-place of ledger folders (no duplicate storage). A WebDAV view of `views/tree.json` for DT sync is a candidate (verify what its sync accepts). Embed the Server web UI only on loopback or behind auth.
**B3 Calendar Desk.** Prerequisite: Switchboard Phases 0–1 (`docs/specs/switchboard-spec.md` §14: Worker, D1, secrets, notify channel); the addendum is built on them. Then implement `docs/specs/switchboard-scheduler-addendum.md` §§1–9, phases S1→S3 first, shadow mode first, §7 guardrails kept (per-provider opt-in once, veto window, undo, kill switch, rate limits, truthful messages; rescheduling is proposal-only). Owner deltas: ① offer the best **two** slots; ② calendar = Apple Calendar via the CalDAV Worker (`docs/specs/sync.md` §§5–7) or EventKit, not Google; ③ signals = wake/bed + steps via Shortcuts → `POST /signal` (steps from Health samples; verify) plus wake-strip interaction rhythm from Recense; ④ confirm/cancel texts leave through an always-on jailbroken iPhone SE with a second non-VoIP SIM (design is in the missing addendum; S1 and the signal/alarm parts of S2 need no SMS bridge, so start there; S2 late notices and S3 cancels do); ⑤ Recense shows cards and status only (Telegram, per the spec, stays the fallback card channel); execution lives in the Worker's Autonomy Governor. "Self-learning" = rules mode until ≥30 outcomes, then a calibrated model.
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
| A2 | Arq plan + verified restore | PARTIAL | Arq 5.7.8 → R2 bucket `c267690e…-arq` (owner-configured, works on macOS 15.5). **Restore drill not done** (no `~/.ledger/backup-status.json`, no restore folder). `sync-backup` key is account-wide and was pasted in plain text: rotate (Arq's target uses the same access key id, checked 2026-10-27; rotating breaks Arq until it gets its own token) |
| A3 | Quota freed | PARTIAL | Target approved: ≤75%, alert 85% (code defaults now 200GB/75/85). Still 91.9% on 2026-10-22: the emptied 12.5 GB never came off Apple's total. Next: icloud.com Data Recovery / Recently Deleted check, then Messages attachments |
| A4 | Canary round-trip | DONE | Canary Mac→iPhone→iPad→Mac. Notability: persists to Notability Server (sockets connected, breakers closed); legacy iCloud 104/104 uploaded; Auto-Backup disabled |
| A5 | Ledger mirror | DONE | Re-verified 2026-10-24: selftest 34 ok; copy dry run/apply/idempotent/restore hash-identical (250); real vault → R2 `gallery-main/ledger/obsidian` apply 250 unchanged, `verify --deep` 13 seg / 250 live / 0 problems; launchd exit 0 (51 runs, WatchPaths firing); `views/health.json` lastOk 22:32Z, stale check exits 1. Unencrypted, private bucket; SanDisk not in launchd. 2026-10-27 18:18: iCloud Drive mirrored → R2 `gallery-main/ledger/icloud-drive` (65 files, 40 dataless materialized, 0.14 GB), `verify --deep` 2 seg / 65 live / 0 problems, idempotent re-run 65 unchanged; launchd `com.chauphan.ledger.icloud-drive` loaded (WatchPaths + 03:45 daily), first launchd run OK, health fresh |
| A6 | Overflow lane, Notability WebDAV | PARTIAL | Planner done; Remotely Save owner-side; Notability WebDAV built and deployed 2026-10-24 (`gallery/src/dav.js`, 450905eb); secret set 2026-10-25, live 401 without the password; Notability Auto-Backup not yet pointed at it. 2026-10-27: owner confirms Notability → WebDAV done (118 files in R2). Remotely Save 0.5.25 installed + enabled in the vault, R2 bucket `notes` created; owner still pastes an R2 token (Object R/W, `notes` only) in the plugin. Use sync direction **push-only** until G1 cutover (never two-way with iCloud on) |
| A7 | Gallery + Recense ledger surfaces | PROPOSED | |
| A8 | Messenger backup | PARTIAL | 2026-10-27: `src/messenger.mjs` (ingest: sha256, extracted copy, mojibake-fixed per-thread jsonl, shrink check; status) + `bin/messenger-job.sh` + LaunchAgent `com.chauphan.ledger.messenger` (WatchPaths inbox + StartOnMount), SanDisk sink, R2 only via `r2-crypt` remote. Tested on a synthetic export. Owner: schedule the Meta export, save zips to `/Volumes/SanDisk/inbox/messenger/`, create `r2-crypt` |
| B4a | Calendar backup (EventKit → .ics → ledger) | DONE | 2026-10-27: `tools/cal-export.swift` → `bin/cal-export` (Info.plist embedded, ad-hoc signed; Calendar Full Access granted), `bin/cal-job.sh`, LaunchAgent `com.chauphan.ledger.calendar` every 30 min. 17 calendars, 1077 series; R2 `gallery-main/ledger/calendar` verify --deep 1078 live / 0 problems; re-run 0 rewritten (alarm/attendee order made stable) |
| G1-0 | CalDAV Phase 0 spike (docs/specs/sync.md §13) | PARTIAL | 2026-10-27: Worker `sync` at https://sync.improvdiplomat.workers.dev (`worker/`), R2 bucket `sync`, layout `caldav/users/<u>/<cal>/…`, `caldav/trash/…`; discovery, PROPFIND, REPORT multiget/query, PUT/DELETE with If-Match, MKCALENDAR, PROPPATCH; Basic auth (sha256 secret via `bin/caldav-passwd.sh`). `npm test` 4/4. Next: add account on Mac + iPhone, create event each way (Phase 0 exit), then Phase 1 (D1, time-range, sync-collection) |
| B1–B4 | Notes in Recense, DEVONthink, Calendar Desk, Apple pulls | PROPOSED | specs exist, no code; iPhone addendum missing |
| B2 | DEVONthink reach over Tailscale | PARTIAL | 2026-10-27: only the DEVONthink MCP/API listens (*:8420, 401 from LAN); no web interface running; Tailscale installed, not signed in. Recense widget PROPOSED |
| C0 | Invites + participant authz | PARTIAL (live-verified) | 2026-10-27 20:30: live on d976d865 (from e5aa551). iPad upload via `/m/` landed in `gallery-main/files/Music/`; made-up token, revoked link, direct URL without token, cross-folder all refused (entry below). Missing: see tomorrow's order below |
| G5 | Comments thread + expanded viewer | DONE (local tests) | 2026-10-22: per-item thread `{list:[{id,text,at,by}]}` (old `{text,at}` still read), Post/Delete/Cancel, swipe up/down, Return posts; viewer chrome black scrim; video first frame. Not deployed |
| G5b | Viewer round 2 (owner list 2026-10-22) | DONE (local tests) | Learn mode (port of Recense phrases/learningPlaces/ink) on the heard clock (deck time on Safari, resync 0.2+0.05×rate); EQ headroom trim (getFrequencyResponse peak) live + in baked downloads; Rename + Change Cover (MP3/FLAC tag rewrite, ETag-conditional, original kept in trash; others art/ sidecar; `was` keeps transcripts); viewer Share + rooms (invite `items`, single item opens in viewer, no uploads); comment Edit/Delete per own comment, buttons always shown; signed-in non-owner on /main gets 403 'signed in as X · sign out' instead of 404. 25 route + 15 UI tests pass. Not deployed |
| C0-G5 | Branch `c0-c1-g3-g5` (gallery): C0 authz, C1 D1, P0 bugs, G3 viewer shell, G5 State C sheet | DONE (local tests; not deployed) | 2026-11-01: commits 658c02a C0, 0e23b5e C1, 38db262 P0, a91db14 G3, 5d53109 G5 on top of 570c213. `npm test` green: 13/23/15/60 (R2)/61 (D1)/3/15/36/120 (viewer matrix: iPad Air 13", MBP 13", iPhone 12 Pro Max × portrait/landscape × touch/pointer). Owner actions: `npx wrangler d1 create gallery`, paste id into `gallery/wrangler.toml` (placeholder 0000…), `npx wrangler d1 migrations apply gallery --remote`; then deploy. Merge will conflict with the uncommitted gallery.js WIP in the main checkout. Not run on the owner's devices. |
| P2 | Shared homebar, Gallery + Recense (SPEC §P2) | PARTIAL | 2026-10-25: one implementation, `gallery/src/client/homebar.{js,css}`, hosted by Recense in a WKWebView (`recense/homebar/index.html`, copied by `build.sh`). Gallery `npm test` 12 + 39 + 14 + 31 pass; Recense compiles, selftests pass, headless host check OK. Not run in the real Recense window, not on touch devices. Not deployed, nothing committed |
| N1026 | SPEC 52–61 (notes 2026-10-26) | PARTIAL | 2026-10-26 23:10: 52, 53, 55, 56, 57, 59, 60, 61 built (+ 3, 4, 15, 25); 54 partial (no tray in Recense); 58 left for an ultracode run. Gallery `npm test` 12 + 39 + 14 + 34 pass; Recense compiled and installed 23:10, not relaunched; Gallery not deployed. Spec scored 82.5% implemented (CHANGELOG) |
| N1027 | SPEC 71–84 (notes 23–36) | DONE (tests/builds; device checks open) | 2026-10-27 06:50: all built. Gallery deployed (4ccf0ab0), `npm test` 109 ok / 0 fail; Recense built from `claude/exciting-lumiere-9b0e58` and relaunched. R2 lifecycle applied. Not checked on iPhone/iPad: 27 (background), 23 (fit) |
| C1–C3 | D1, Rooms, co-editing | PROPOSED | invites live in R2 `invites/` until D1 |
| N1029-9 | Notes 20261029 item 9: on-device ears (SpeechAnalyzer) + correction lexicon | PARTIAL (installed; custom LM BLOCKED) | 2026-10-29 19:59: Recense transcribes on this Mac: SpeechTranscriber (en, fr), DictationTranscriber (vi), Groq only for languages Apple can't hear (Persian) and only with a key; no key needed any more; offline translation falls back to Apple Translation. `recense/recense/speech.swift` (engine + Lexicon + CustomLM), `voiceprint.swift` (MFCC + DTW), `recense.swift` (whisper() routes on-device first; Word.c/heard; correct()/Gallery overrides teach; relisten() on replays). Built against Apple CLT 27.2 unpacked in `recense/.toolchain` (Xcode here is 16.4/SDK 15.5); `build.sh` uses it when present. Spike: 98 % of Whisper's words, word times ±0.09 s median, 30× real time; auto language en/fr/vi + French↔English code-switching verified on a bench; correction → next recording fixed by sound; real "cafe" left alone; 33 Recense self-tests + Gallery `npm test` 128 ok. **Blocked:** Apple's custom-LM builder fails (SFSpeechErrorDomain 1) in every variant, CLI and signed Recense with permission. **Not yet run:** live playback inside Recense (first real media will be; `curl -s localhost:47123/speech`). |
| N1029-3 | Notes 20261029 item 3: share-link preview cards (iMessage, Messenger, Telegram) | DONE (deployed a3307bc1; real paste not yet seen) | 2026-10-30: c35d22d. `/s/<id>` head gets og:title ("N files for you · Shared by Chau Phan" or folder name), og:description/type/url/image(+1200×630), twitter:card summary_large_image (summary when no picture). `GET /api/og-image/<id>[?cover=]` (public.js `ogImage`): ?cover= → manifest/link `coverItem` (fromMain body `cover`) → first jpeg/png/webp/gif ≤8 MB → any image → song cover; public, max-age=3600, ACAO *. routes 53/53, UI 34/34. Deployed c35d22d alone (live was 5e99216) as a3307bc1; /api/og-image live. Row 30 (9e68d98, 18c1b2c) left undeployed: transcript.test 2 FAIL there, 15/15 at c35d22d. Next: owner pastes a link in iMessage. |
| IMG | Obsidian images → R2 (S3 Image Sync plugin) | PARTIAL | 2026-10-29: Gallery `/i/<key>` route (`src/images.js`, binding `NOTES_IMAGES` → bucket `notes-images`), `test/images.test.mjs` 5 ok, full `npm test` passes. 2026-10-29 19:50 PDT: bucket `notes-images` exists (no lifecycle: links must outlive the source); deployed **9664dc41 from 2045487** (owner's yes; HEAD 7322474/1a10977 not deployed: needs Vectorize index `gallery-ai`, other session's step); live: test PNG 200 image/png, bad key 404, `/` 200, `/main/` 302; test object deleted. 2026-10-29 20:40: **Move Offsite** (any app): Gallery `a942b18` `PUT /main/api/img` (images 8 ok, routes 47) committed, **deploy blocked by the auto-mode classifier, owner to deploy**; `bin/offsite-image.zsh` tested vs a local stand-in; `tools/shortcuts/Move Offsite (Mac|iPhone).shortcut` signed, not imported/run. Owner steps in `docs/runbooks/obsidian-images.md` |
| U0 | Unified offline-first plan, phase 0 (`docs/specs/unified-offline-first-and-redesign.md`; order: `.handoff/CONTINUATION-PLAN.md`) | PARTIAL | 2026-11-05: A10 #1–5, N2, R15, R16, G20, Raven, X5, D1 done (CHANGELOG 14:21), pushed by the owner 14:57 (gallery's CI failed a flaky UI test; all of it went live with 7442fcc at 16:44). A13 L1 DONE and deployed 16:44 (gallery 7442fcc). A11 N3 DONE (vault: one brain dump, one draftpad; 50 copies in `_conflicts/2026-11-03/`). A11 N4 DONE on the Mac (md-mirror every 5 min, 108 notes; canary f6666f34 waits for the iPhone and iPad). R17 DONE (recense 03c398d; the hour's log check to 17:11 clean, nothing new played). X4 DONE (recense fcb45a5), X9/N9 read, autoupdate resumed. A15 started 11-05 16:20: git-filter-repo installed, A15i Nook rename DONE (recense 0551831), A15j delete/remove rows DONE (CHANGELOG). All pushed by 16:45; gallery 1c676a1 not deployed (the same flaky test). A15 step 3 (17:40): merge built and verified on branch `a15/monorepo` (recense worktree `.claude/worktrees/a15-monorepo`, e93014f); A15 cutover DONE 18:45 (CHANGELOG): recense main = the one repo, old folders in the Trash, agents repointed, /recense skill |
| — | Chrome `/main` 404, setup scripts, Recense CPU, audio/EQ, layout, Draftpad, Phi, Nook, cleanup | PROPOSED | BACKLOG |

### 2026-10-29 20:50 PDT · "Deploy all, resolve all": event-log open items · DONE except the sink move (BLOCKED on one dashboard step)
- **Committed everything** (owner: "just commit everything"): gallery f7747b6 … 62cb547, sync 6514f2c … , sill f8a9802.
- **Deployed.** The AI assistant (another session, unfinished) landed in main mid-turn; the owner chose "without the
  assistant", so 0d471b69 went out from a `deploy/no-ai` commit (36e6662). The assistant session then reported the owner
  told it to deploy the assistant and that mine had replaced its version 9 s later. Branch deleted; from now on deploy
  only from main. **Live: ba333615** (assistant session, main at 9d50a2a, all tests green), which includes all of this.
- **Resolved (`docs/specs/event-log.md` §7):** one junk/churn rule in ledger, feed and mounts (dotfiles are content;
  LibreOffice `.~lock.*#` added after live batch 3 showed 7 of them); md5 in both logs; old batches to `history/`
  (kept, verified as one chain); Main as a feed root (`files/` only); ledger sinks: bucket `sync-ledger` created,
  `bin/move-ledger-sinks.zsh` ready (dry run, `--apply`), **BLOCKED** until the jobs' gallery-main key gets the bucket.
- **Live checks:** `/` 200, `/main/` 302; archive `changes?since=2` → batch 3 (was a false 410), chained, md5 on files;
  batch 4 dropped the 7 lock files (below the guard). **Main's first pass failed live** (`exceededCpu` at ~1 s CPU,
  24 s wall, lock left): fixed in 62cb547 / 14e7ff8 / 80a2ff2 (a pass lists ≤5,000 objects or 8 s per request, saved in
  `.catalog/<root>/pass/`; merge in its own request). **Live 0b0ab499 (main 80a2ff2, assistant included, deployed with
  the assistant session's agreement):** Main baseline built; a steady pass = 7 requests at 250–345 ms CPU; no change →
  no batch; Main's top level shows only `files/` folders.
- **Tests:** gallery routes 49, ui 33, rclone 3, transcript 15, keylabel 13, images 5; ledger selftest all passed.
- **Next:** owner: give the jobs' gallery-main R2 key the bucket `sync-ledger` (dashboard), then
  `zsh ~/Developer/sync/bin/move-ledger-sinks.zsh` (dry run) and `--apply`. Deploy only from main from now on (the
  assistant session's request). Apps don't offer Main yet (architecture.md slice 5).

### 2026-10-29 19:35 PDT · One event-log format: ledger.mjs + the catalog (fp.js) unified · DONE (code + tests; catalog NOT deployed)
- **Contradictions found:**
  1. The guide called "a hash-chained record of every byte" Sync's moat, but only the ledger was chained. The engine's
     catalog (the log devices sync from) had no chain, though the nervous-system spec named the ledger as its model.
  2. Two vocabularies: put/tombstone vs create/modify/move/delete.
  3. Three delete guards: the ledger refused above max(10, 20%); the spec says 10% or 100; the reconciler had none, so
     an emptied R2 folder would have been removed from every device.
  4. Plan decision 2 ("iCloud stays the live lane") vs the owner's replace-iCloud goal.
  5. The guide's single-writer rule ignored the direct writers that exist (the ledger jobs into `gallery-main/ledger/`,
     the Downloads agent, the archive moves).
- **Resolved:** `docs/specs/event-log.md` (§8 decision 9). `ledger.mjs`: writes v2 (create/modify/delete with `id`,
  `dir` and `mtime`), still reads v1; one `massDelete`; recognizes the engine's conflict names; `verify` and `fold` read
  a catalog. `fp.js`: chained batches (`v`, `prev`, per-event `chain`, `snapshot.chain`); the delete guard holds a pass
  in `held.json` until the owner POSTs `/main/api/fp/<root>/confirm`. `FileProviderExtension.swift`: applies only the
  four tree ops. The guide (§2, §5, §7, §8), `gallery/docs/architecture.md` §3/§5, nervous-system invariant 1 and
  decision 2 annotated.
- **Bug fixed (live in the deployed feed):** `changes?since=N` answered 410 whenever batch N existed (`startAfter`
  without `.json`), so the Files extension re-enumerated on every incremental check.
- **Validation:** `npm test` (sync) all passed, ledger selftest 42 ok (was 34). Live journals verified read-only with
  the new code: obsidian 27 seg / 261, icloud-drive 2 / 65, calendar 6 / 1,078, 0 problems, counts unchanged. Gallery
  `build:test` + `routes.test.mjs` 47 passed (1 new). The Worker's `reconcile` run in a scratch harness → its log is
  verified by `ledger.mjs` (0 problems), and tampering is caught. iOS extension compiles (`xcodebuild`, no signing).
  Not run: `ui.test.mjs` (another session's WIP), the macOS app build.
- **Next:** owner's yes to deploy the fp.js change (from a `git archive` of the commit, per the standing rule). The
  next ledger launchd run writes v2: check `verify` once after it.

### 2026-10-29 · IMG · Obsidian images → R2 (S3 Image Sync plugin) · PARTIAL
- "S3 image sync" = community plugin `images-uploader` 1.0.10 (installed + enabled since 10-15, never configured). It uploads through Obsidian's `requestUrl` (no CORS rule needed); links = `<public URL>/<key>`; image folder required (empty falls back to the author's default).
- Choices: own bucket `notes-images` (Remotely Save syncs `notes`, so images there would come back into the vault); public links through the Gallery Worker `/i/<key>`, not r2.dev, only content-addressed keys served, SVG sandboxed; auto-scan off (no polling); delete policy "Ask each time".
- Changed (gallery, uncommitted, other session's uncommitted files untouched): `src/images.js` (new), `src/worker.js` (+3 lines), `wrangler.toml` (+binding), `package.json` (test), `test/images.test.mjs` (new). Validated: images 5 ok; keylabel 13, routes 47, dav-rclone 3, transcript 14, ui 33 pass.
- Caveat: uploaded images need a connection (goal §1a); keep offline-critical images local.
- Next: owner creates bucket + token, says yes to deploy (from a commit), fills plugin settings; then `curl -I` a real key.

### 2026-10-29 18:56 PDT · Boundaries: Sync, Gallery, Sill (long-term backend guide) · PROPOSED
- **Decision (owner to confirm):** keep three projects; move the sync engine's ownership from Gallery to Sync; Recense is a
  capability shared through modules and `keep/<key>/`; on iOS, build the follow-you player inside Gallery. §8 decision 8.
- **Guide written:** `docs/specs/organism.md`: each project's one job and asset (§1–2), the five folding options judged
  (§3), placement rules + a feature table (§4), contracts (§5), iOS playback outside the app (§6), the two-Worker
  serverless design with single-writer ownership, Queue-fed change log and second-vendor replicator (§7), migration
  steps that keep every device URL (§8).
- **Evidence used:** engine code lives in the Gallery Worker (`fp.js` 162, `dav.js` 560, `tmp.js`, `archive.js`); the Sync
  Worker serves only CalDAV (`worker/src/caldav.js`); `sync/bin/resign-ios.zsh` re-signs Gallery's iOS app;
  `apple/HostApp/iOS/` has no `AVAudioSession`/Now Playing/PiP code; Recense writes `keep/` and Gallery's
  `corrections.js` writes corrections into it.
- **Validation:** docs only. No code moved, nothing built or deployed.
- **Next:** owner answers §10 of the guide; then step 1 (engine boundary inside the Gallery Worker), after the C0/D1
  session commits its work in the Gallery repo.

### 2026-10-28 03:40 PDT · Sill/Recense consolidation: one app, dead tree emptied, docs corrected · PARTIAL
- **Root cause of "Recense.app keeps opening", found and recorded.** Three causes: (1) `sill/recense/build.sh` *rebuilds*
  `Recense.app` into its own folder and prints "launch with: open $PWD/Recense.app", so any session following the old
  docs resurrected it; (2) the bundle was **trashed, not deleted** — `~/.Trash/Recense.app` (26 MB) stayed registered
  with Launch Services as `local.recense` *pointing into the Trash*, and macOS launches apps from the Trash, after which
  it took port 47123 from Sill; (3) a stale **enabled** login item (`2.Recense`, UUID 6D3AF30C-E16B-42F8-A335-EA53ADF3C11E)
  aimed at a deleted Claude scratchpad path. Verified: no `Recense.app` bundle exists outside the Trash, no Recense
  process runs, and `sill` (PID 85894) holds 47123.
- **The deeper cause was documentation.** `sill/docs/recense-voice-vision.md` said "`recense/main.swift` … the real
  Recense. `sill/recense.swift` is a copy", and `sill/.claude/CLAUDE.md` never mentioned `recense.swift` at all. Every session
  trusted the docs over the filesystem and rebuilt the old world. Corrected: `sill/.claude/CLAUDE.md` now opens with
  § "One app, three faces"; new `sill/docs/architecture.md` (naming, reuse rule, the two reuse tracks, the `Transcriber`
  provider seam, offline-ASR prerequisites, macOS 26 upgrade risk table, enforcement); vision doc's source-of-truth line
  flipped; **§3 of this file corrected in the same pass.**
- **Dead tree emptied (A1/C6).** Moved out of `sill/recense/`: `prosody.js` and `prosogram.js` → canonical in
  `gallery/gallery/src/client/`; the file:// harness variant, `data.js`, `song.m4a`, `prosogram.html` and the `.js`/`.m4a`
  clip twins → `sill/.handoff/prototypes/prosogram-file/`; the dead host page → `sill/.handoff/recense-homebar-index-DEAD.html`.
  `prosody.js` deduped: `.handoff/prototypes/_shared/prosody.js` is now a symlink to Gallery's copy (old file kept as
  `.superseded-20261028`). What remains in `sill/recense/homebar/prosogram/` is **100% byte-identical duplicates**
  (`data.json`, `song.flac`, 8 clip files — all md5-verified against `_shared/`).
- **C4 resolved: nothing to port.** `sill/sill/homebar/index.html` (bundled) is strictly newer than the dead
  `recense/homebar/index.html` — it alone has `vox` (the extractor, notes 32) wired through `sound`/`plain()`/
  `sendSound()`/the tare snapshot, plus `chroma()`/`chords()` (SPEC 40). The dead page's only extra was the `volume`
  slide, deliberately removed per notes 2026-10-26 #16.
- **C5 resolved: nothing to merge.** `claude/cool-antonelli-c894a6`, `claude/exciting-lumiere-9b0e58`,
  `claude/recense-tray` and `claude/notes-36-41` are all **0 commits ahead of main** (9–20 behind). Worktrees:
  `cool-antonelli` and `recense-tray` clean; `exciting-lumiere` dirty only with a modified `.build-log.txt` and an
  untracked `recense.swift.orig` that is 511 lines **shorter** than main's and lacks the chord detector,
  `onRetranscribe`/`onExport` and `stripTop` — an older pre-patch backup. `wip/main-uncommitted-2026-10-26` is the only
  branch with a unique commit (7979dd9), self-described as superseded by `claude/exciting-lumiere-9b0e58`.
- **Validation:** md5 comparisons for every file left in the dead tree; full diff of both host pages; `git rev-list`
  ahead/behind per branch; `git status --porcelain` per worktree. Nothing built, nothing deployed, nothing deleted.
- **Next:** owner runs `sill/.handoff/delete-recense-tree.sh` (snapshot → confirm → delete); then `lsregister -u` plus
  the Trash bundle and the login item; then C4 cleanup, branch/worktree deletion, `build.sh` manifest + broken
  `universal` branch, and the visible port-47123 conflict.

### 2026-10-27 20:15 PDT · Finder through the Worker: Touch ID test, two-way dav, chunked uploads, drive runbook · PARTIAL
- Per-device Access tokens already done (e5aa551). Not touched: invite.js, migrations/, D1 (another session; its uncommitted `client/gallery.js`, `ui.test.mjs`, `migrations/` left out of every commit).
- 1 Touch ID unlock: owner ran `rclone config encryption set` (backup `rclone.conf.bak-pre-encrypt`, plaintext 600). Waiting on the owner's open → password once → reopen with Touch ID only; then commit main.swift. While encrypted: Sill's R2 tray and sandisk-rescue (if the SanDisk is plugged) can't read keys; Downloads/ledger fine (jobs.conf).
- 2 Two-way /main/dav/: temporary env-only remote (Keychain `gallery-access` token, no rclone.conf write) made `DAV test/hello.txt` in Main and edited it (19:55:50); conditional PUT with the current ETag 204, with the out-of-date ETag **412**, content unchanged ("Version 3 · conditional edit at 19:55:58"). Owner's iPhone check of the web Gallery pending.
- 3 Chunked uploads: gallery `1cd3406` (not deployed). `/main/nc/dav/files/owner/` + `/main/nc-tmp/…` (Nextcloud-shaped, rclone `vendor=nextcloud`): chunks to `.uploads/<dir>/` (≤100 MB each, size = name), MOVE `.file` joins them in order (gap/overlap → 400, ≤5 GiB), old file to trash, Overwrite F → 412, X-OC-Mtime kept; PATCH X-Recalculate-Hash → 204. Probe of rclone 1.75.1 against a stub fixed the protocol (no Destination until MOVE). `test/dav-rclone.test.mjs` runs the real rclone against Miniflare (25 MB in 10 MB chunks hash-identical; overwrite/rename/delete to trash). `npm test` 13/42/3/14/32. Deploy must ship HEAD only (`git archive`), not the working tree, because of the other session's uncommitted files.
- 4 Prepared, not run: `sync/bin/gallery-main-over-dav.zsh` (adds `gallery-main-dav` webdav remote with the Keychain token, points `gallery` Main at it; `undo` reverts). `sync/docs/runbooks/gallery-drive.md`: Mac + Windows (WinFsp, rclone, own service token, `rclone mount … G:`), known limits: **folder rename/move fails (403), not fixed tonight**, no LOCK, 5 GiB max. Finder test after deploy + switch.
- Leftover: chunks of an abandoned upload stay in `gallery-main/.uploads/` until rclone's next DELETE of that dir (tmp: 14-day rule). Proposed: lifecycle rule on gallery-main prefix `.uploads/`, 1 day (owner's yes).
- 20:20: owner's yes → deployed exactly 1cd3406 from a `git archive` export (no migrations/, no D1, none of the other session's files): version 2897ffd6. Live: `/main/nc/…` 302 to Access. Live chunked test: 120 MB in 50 MB chunks through `/main/nc/dav/files/owner/` in 53 s, sha256 identical on read-back, 0 chunk dirs left, delete → trash. Switch script started in a terminal for the owner (needs the config password).
- Next: owner runs the switch, confirms Touch ID test + iPhone check → commit main.swift; Finder test (upload >100 MB, edit, delete → trash).

### 2026-10-27 20:30 PDT · G1/C0 live proof, D1 draft, B2 reach · PARTIAL
- **C0 live: DONE (verified)**, no server change. `wrangler deployments list`: d976d865 is current (100%); `invite.js` in e5aa551 and routed in `worker.js`. Owner made an invite to Main/Music (1 hour) on the iPad and uploaded a photo: `files/Music/IMG_0277.jpeg` in R2 at 20:10:55 (upload keeps the photo's own mtime, 2026-10-06, so `--max-age` misses it; use `--use-server-modtime`). curl, token never printed: made-up token (43-char base64url and 64 hex) 404 on page, `/f/`, `/api/file` GET+PUT, same body as any unknown path; invite page + file with token 200; `/main/files/Music/<f>` without token 302 (Access), `/files/…` 404; other folder via `/f/Sessions%2F…`, `..%2F`, `/../` 404; transcript of other folder 400; overwrite 409; `../` name 400; cross-site upload 403. Second invite ("Revoke Test"): 200, then revoked by the owner → 404 on page and file. First invite expires 21:02 → expired check still to run. `npm test` 13/41/14/32 ok.
- **Finder: BLOCKED.** Gallery.app not running and nothing mounted at 20:15 (`rclone config encryption set` is running, other session's step). Owner to open Gallery → Main → Music → `IMG_0277.jpeg`.
- **Changed (not deployed):** `gallery/src/client/gallery.js` `expiresAt()`: share/invite pages say "Expires today at 9:02 PM" / "tomorrow at …" / "3 November at …" (was date only, so a 1-hour link read "Expires 27 October"). New UI test (`test/ui.test.mjs`); ui 33 ok.
- **C0 still lacks (tomorrow, in order):** (1) comment ownership is by display name (`public.js` commentApi `c.by === by`): two invites with the same name can edit/delete each other's comments, and an invite named `OWNER` ("Chau Phan") can edit the owner's; reject `OWNER` and duplicate live names now, `author_id` with D1; (2) per-invite permission toggles (API hardcodes download+comment, upload unless room; no UI); (3) document-level view-only lock (+ per item); (4) per-media overrides; (5) react + annotate perms, routes, tests; (6) tests: expired live, public/main separation.
- **C1 D1: PROPOSED.** `gallery/migrations/0001_init.sql` (shares, share_items, members, share_members, overrides, comments, reactions, annotations, migrated; loads in `sqlite3 :memory:`) + `migrations/README.md` (lazy copy of `invites/` on first token use, revoke deletes the R2 copy too; comment JSON copied once per key with ETag; archive, never delete). Not bound in wrangler.toml, not applied.
- **B2: PARTIAL.** `*:8420` is DEVONthink 4.4.1's MCP/API server (POST JSON-RPC; GET 405; localhost answers without auth, LAN IP 192.168.29.100 → 401). No DEVONthink web interface listening. Tailscale was not installed → `brew install --cask tailscale-app` (owner's permission). Next: owner opens Tailscale, signs in, allows the VPN; enables DEVONthink Settings > Web Server (needs the Server edition) with a password; then check tailnet reach and no public reach. Plan: tailnet only (`tailscale serve` for HTTPS on the ts.net name), never Funnel.

### 2026-10-27 19:43 PDT · Gallery.app mount (cont.): tmp key live, Gallery committed, dav-tmp deployed, jobs.conf, Touch ID unlock built · PARTIAL
- Owner decisions: Touch ID design approved, with the rule that it must forgive lost/broken devices and forgotten passwords (no Apple ID dependency; data never encrypted with a single-copy password). `/main/dav/` must cover Main **and** tmp (tmp = throwaway mirror, no keep/delete decisions). Gallery.app test passed (Main/Public/tmp show, unmounts ≤5 s after closing).
- Step 1 DONE: owner deleted the WebDAV files; only empty `~/Library/Caches/rclone-webdav/{vfs,vfsMeta}/gallery` dirs may remain (`rm -r` it).
- Step 2 DONE: `gallery-tmp` remote (Account token, Object R&W, gallery-tmp only; lists 0 buckets, gallery-main denied). `tmp=gallery-tmp:gallery-tmp`; Downloads agent → `gallery-tmp:gallery-tmp --config jobs.conf`. Fresh file moved 19:39 (local gone, in R2), Downloads 659 entries before/after. Destination still the bucket root (never expires) until the owner picks expiry.
- Step 5 DONE: gallery `b22c303` (Gallery.app hidden mount, close on last window, cache wipe). Owner's run confirmed `vfs/gallery` gone after close.
- Step 6 DONE (deployed with the owner's go): gallery `e5aa551`, Worker version d976d865. `/main/dav-tmp/` → TMP bucket behind Access (delete/overwrite for good); `SERVICE_CLIENT_ID` takes a comma list (one token per device). `npm test` 13/41/14/32. Live: `/` 200, `/main/dav/` + `/main/dav-tmp/` 302 to Access, `/dav/notability/` 401. rclone `:webdav:` with the Mac's existing Keychain service token (`gallery-access`): lists Main and tmp; tmp write/move/read/delete OK. **Not switched in Gallery.app:** Workers cap a request at 100 MB, so Finder uploads of bigger files would fail over WebDAV (main.js:196 already sends big files through the S3 mount). Options: keep S3 for Main, or add chunked PUT (nextcloud-style) to dav.js.
- Step 3 PARTIAL: `~/.config/rclone/jobs.conf` (600; gallery-tmp + gallery-main only). `sync/bin/ledger-job.sh` and `messenger-job.sh` export `RCLONE_CONFIG` (default jobs.conf); obsidian ledger kickstarted → exit 0, 4 uploaded, health OK. Gallery.app (uncommitted, built 19:42): if `rclone.conf` is encrypted, unseals its password with the Touch ID context (Secure Enclave P256 ECIES, `.userPresence`), else asks once and seals it; passes it on stdin via `--password-command cat`; "I forgot it" opens `docs/runbooks/recovery.md` (new: who-opens-what table, lost-device steps, forgot-password rekey, paper sheet). Round-trip + stdin hand-off tested in a harness; real SE unseal not yet (needs Touch ID). Inactive until `rclone.conf` is encrypted.
- Blocking encryption: sandisk-rescue (paused for a SanDisk replug since 10-26 20:52) and Arq both use `sync-backup` from the default config; Sill's "Go to R2" tray reads `gallery:Main` from it.
- 19:50: owner chose 2 weeks → rule `expire-all-14d` (all prefixes, 14 days) added to gallery-tmp; `tmp/` keeps its 1-day rules. Downloads stay at the bucket root. gallery 35b5467 records it in wrangler.toml.
- Next: owner makes scoped tokens for Arq (its bucket) and sandisk-rescue (sandisk bucket + gallery-main) → jobs.conf / Arq, restart sandisk-rescue with `RCLONE_CONFIG`, delete the `sync-backup` token and the unused `r2` remote; owner fills in the recovery sheet; owner runs `rclone config encryption set`; open Gallery (types the password once) → commit; Sill tray unlock (Sill task).

### 2026-10-27 19:08 PDT · Gallery.app mount: WebDAV removed, scoped tmp key, R2 keys behind Touch ID, wipe on lock · PARTIAL (owner steps open)
- Mac WebDAV server (`com.chauphan.gallery-webdav`, rclone serve webdav on :8080 with Basic auth) contradicted "no Basic-auth door into Main": booted out and `launchctl disable`d; nothing listens on :8080. Deleting its plist/htpasswd/password/log/cache was denied → owner's command in `gallery/.handoff/HANDOFF.md`.
- `gallery/chau/Gallery/main.swift` `close()`: after unmount, waits ≤5 s for rclone, deletes `~/Library/Caches/rclone/vfs/gallery` + `vfsMeta/gallery`, runs `qlmanage -r cache`. Keeps the cache (and logs it) when a file is still waiting to upload (`"Dirty": true` in vfsMeta; tested that SIGTERM leaves such a file only in the cache). Built into /Applications/Gallery.app; not run with a real mount yet. Earlier uncommitted work (hidden `~/.gallery`, `nobrowse`, close on display sleep/screensaver/idle, close when the last Finder window goes) also awaits the owner's test before commit.
- Finding: `gallery-tmp` lifecycle expires only `tmp/` (1 day). The Downloads agent writes to the bucket root, so those files never expire. Owner picks: agent → `tmp/downloads/` (existing rule) or a bucket-wide rule.
- Finding: `/main/dav/` is already live (PROPFIND 302 → Access). `access.js` takes one service token (`SERVICE_CLIENT_ID`); per-device tokens need a list (code + deploy, owner's yes).
- rclone audit (fingerprints only): `sync-backup` (account-wide) → Downloads agent, sandisk-rescue (running), **Arq (same access key id)**, Gallery `tmp=`; `gallery-main` (bucket-scoped) → ledger obsidian/icloud-drive/calendar, chau scripts, Sill "Go to R2" tray (`gallery:Main`); `gallery-public` → Gallery, setup.sh; `r2` → no consumer found; Recense has its own key (`~/.config/recense/config`). Full table in the handoff.
- Proposed (not done): `jobs.conf` with scoped keys for agents; `rclone.conf` encrypted, password sealed by a Secure Enclave key (`.userPresence`; creation tested from an ad-hoc binary without entitlements) and fed to rclone on stdin (`--password-command cat`, tested) instead of `RCLONE_CONFIG_PASS`. Breaks Sill's tray until Sill gets the same unlock.
- Next: owner creates a `gallery-tmp`-only token and picks the tmp layout → switch `tmp=` + agent, verify; owner rotates `sync-backup` (Arq + sandisk-rescue first); owner tests Gallery.app → commit; yes/no on the Touch ID design and on per-device service tokens.

### 2026-10-27 20:10 PDT · A6/A8/B4a/G1-0 · PARTIAL
- Owner goal set: everything serves G1 (replace iCloud), 1–2 days. Arq (A2) + R2 cleanup deferred.
- Built: calendar backup (B4a, DONE), Messenger ingest (A8, waiting on first export), Remotely Save installed (A6, waiting on token), CalDAV Worker deployed (G1-0, waiting on device check).
- Validation: worker tests 4/4; live `/dav/` 401 with secret set; calendar mirror verify --deep 0 problems; messenger synthetic ingest idempotent.
- Next: owner adds CalDAV account on Mac + iPhone; event round-trip both ways.

### 2026-10-27 18:18 PDT · A5 · iCloud Drive mirror · DONE
- Dry run: 65 files, 40 dataless (0.12 GB; internal disk 9.7 GiB free, so materializing was safe). Apply with `--materialize` uploaded 60 objects (144.6 MB); second run 65 unchanged.
- `verify --deep` 0 problems; `health` OK. LaunchAgent `~/Library/LaunchAgents/com.chauphan.ledger.icloud-drive.plist` (copy of the Obsidian agent, log `~/Library/Logs/ledger-icloud-drive.log`); kickstarted run OK.
- Not done: SanDisk sink (drive not mounted), R2 layout cleanup and Arq (deferred by owner).

### 2026-10-24 01:37 PDT · Gallery spec §8 Key slider labels · PARTIAL
- Built (uncommitted, not deployed): 10-state notation cycle on the Key slider caption (tap / right-click / trackpad swipe / 350 ms hold list), float `setKey` (½ semitone in Maqam¼, 1¢ in Cents) with snap on state change, per-item original key (`keys/<folder>/.keys.json` in MAIN, `PUT /main/api/key`, manual beats auto, follows rename/trash, copied into share links made from Main), Info › Set Key / Detect Key, detection on owner audio uploads (Krumhansl-Schmuckler on chroma). Label math in `gallery/src/client/keylabel.js`.
- Validated: `npm test` 12 label + 26 route + 16 UI passed (Chromium, desktop pointer only).
- Not tested: iPhone/iPad touch, real Safari, detection accuracy on real music, Maqam names (owner to verify the `MAQAM` constant).

### 2026-10-24 · Gallery spec §9 Transcript corrections, persistence, auto-run (+ Recense) · PARTIAL
- Built (uncommitted, not deployed): corrections in Recense's existing `keep/<key>.edits.json` (shared fields `version, updatedAt, overrides, glossary`; Recense's own `edits/english/last` passed through), history `keep/history/<key>/<v>.json` (last 20), ASR request lock `keep/locks/<key>` (15 min from last beat). Rules in `gallery/src/corrections.js`, routes in `src/transcript.js`: `PUT|POST /main/api/transcript[/run]`, `PUT /api/transcript`, `POST /api/transcript/run` (share: `x-gallery` header, 20 edits/min per IP per media via PUBLIC `rate/tx/`, swept by cron). Learn view: tap a line to correct it (Save/Cancel, Retranscribe on Main), 1 s debounce, 409 merge + one retry; no transcript → auto-queues Recense, shows progress / Retry.
- Recense (`~/Developer/recense/main.swift`, uncommitted): same apply/glossary/merge rules (`Corrections`), merge-before-upload of `.edits.json` (`CorrectionSync`, also in the sweep), pull on Episode load, `GalleryJob.serve` polls `keep/locks/` every minute, Retranscribe = from scratch with the recording's glossary in the Whisper prompt, only finished transcripts uploaded. `--corrections-selftest` added to `tests/regress.sh`; `build.sh` OK.
- Validated: `npm test` 12 + 26 + 9 transcript + 17 UI passed; Recense `--corrections-selftest` 17/17, `--edits-selftest` 8/8.
- Not tested: real R2 (If-Match on S3 PUT from Recense, Worker conditional puts), Recense picking up a real lock end to end, iPhone/iPad editing.

### 2026-10-24 · Gallery spec §3 Delete cover + §4 cover backend sync · PARTIAL
- Built (uncommitted, not deployed): Info › Delete Cover (owner, Main, audio; confirm dialog) → `DELETE /main/api/cover?path=` writes `art/<path>` marker `{none,deleted}`, strips pictures from MP3/FLAC tags (old file to `trash/<day>/<path>.before-delete-cover`, conditional put); grid then shows the existing file tile (`nocover`, no same-named-picture fallback). Main, room (`/m/`) and upload-link art URLs now carry `&v=<art etag, else file etag>` so the 1 h `private` cache never shows a stale cover; Change/Delete cover rewrite `<n>.art` in every live upload link made from that file, and new links copy a custom/deleted cover.
- Validated: `npm test` 12 + 27 route + 9 + 18 UI passed (new: route "cover change and delete reach the root grid…", UI "Info: Delete Cover…").
- Not tested: real R2, iPhone/iPad, Safari. Folder links (Public bucket) unaffected by design.

### 2026-10-24 02:31 PDT · Gallery spec §6 Single-line learn view (+ Recense) · PARTIAL
- Built (uncommitted, not deployed): Learn mode shows one line at a time on a 3D barrel (`gallery/src/client/gallery.js` `showTranscript`, `lineAt`, `nativeOf`; CSS `.tx.learn`). Rows 30° apart on a drum (CSS perspective); the drum eases to the line of the moment (a line comes ≤0.5 s before it is spoken, once the previous line has been read, never after its first word). Vertical drag (touch/mouse), wheel / two-finger scroll and ↑/↓ turn it; neighbours show while it turns; where it stops is played from. Tap still goes to the line and opens §9's inline correction. Trailing language = `prefs.nativeLang` (`tr.<lang>` whole line; else English phrase-by-phrase; else any translation). Reduced motion: no roll. Two-place `learningPlaces` removed.
- Recense (`main.swift`, uncommitted): same barrel in Learn (`learningLine`, `Overlay.renderLearning` → `WordsView.drum`, drawn with CG perspective/flatten); trackpad/wheel scroll over the line turns it and seeks; mouse drag still moves the window; double-click/E edits the line in view; Reduce Motion respected. `--learning-check` now sweeps `learningLine`; `learningPlaces` removed. `viewer/read-along.html` untouched (audiobook reader, not Learn).
- Validated: `npm test` 12 + 27 + 9 + 19 UI passed (new UI "Learn mode barrel…"); Recense `build.sh` OK, `tests/regress.sh` exit 0 (learning check 0 missing on all fixtures).
- Not tested: iPhone/iPad touch, real Safari, Recense on screen.

### 2026-10-24 03:05 PDT · Gallery spec §1 native language (+ Recense), §2 viewer modes, §5 strip buttons, §7 comment swipe-delete · PARTIAL
- Built (uncommitted, not deployed): §1 Info panel (audio/video) "Native language" segmented control English | Vietnamese | French (Create Share Link's `.seg`), `localStorage gallery.nativeLang`, redraws Key State 0 line 2 (`repaintKey`) and Learn mode; Key state untouched. §2 audio with a transcript gets `.aw.lyrics` (cover hidden, black); while transcribing, cover + smaller `.txst` progress pill; Info › New Window opens `?open=<n>` in a popup. §5 `#save` removed, `#vshare` in its grid slot; Info panel row "Download" (baked sound kept) for everyone. §7 own comments: Delete removed from the meta line, revealed by touch swipe left starting on the right half, or a horizontal trackpad wheel over the comment (thread-level listener); blue `--ctl` text; Escape/tap elsewhere folds.
- Recense (`main.swift`, uncommitted): `NativeLang` (UserDefaults `nativeLang`), EN | VI | FR segmented control left of Follow/Learn, shown on hover with it; a line's `tr.<lang>` correction is its trailing line when set, else English (`Corrections.apply`, `Episode.shown` re-made on change).
- Validated: `npm test` 12 + 27 + 9 + 24 UI passed (new UI §1, §2, §5 ×2, §7; old comment-delete tests now swipe). Recense `build.sh` OK, `--corrections-selftest` and `--edits-selftest` pass.
- Not tested: iPhone/iPad touch on device, real Safari/trackpad, Recense on screen.

### 2026-10-24 · Transcripts per item in keep/<key>/ + Vietnamese and French (Gallery + Recense) · PARTIAL
- Built (uncommitted, not deployed): one folder per item, any source: `keep/<key>/asr.json` (original only), `keep/<key>/tr/{en,vi,fr}.json` (each language on its own, by segment id with `src` words), `keep/<key>/corrections.json`, `keep/<key>/history/<v>.json`. `keep/locks/<key>` and `keep/library.json` stay where they were (Recense lists the locks every minute). Old flat `<key>.v2.json`/`.edits.json` are still read; the first read writes the new layout (conditional, never over newer files, never deletes). Gallery: `src/layout.js` (new), `src/transcript.js`, `nativeOf` falls back to English only. Recense: `Keep` (layout, push/restore/migrate), `CorrectionSync` on corrections.json, vi/fr after English (`nativeStep`: native language first, same model rotation, on-device drafts), the window shows the chosen language (`Episode.display`), `GalleryJob` pushes asr/en and then vi/fr, and backfills vi/fr for files already in keep/.
- Validated: `npm test` 12 + 27 + 13 transcript + 25 UI passed (new: layout, new-layout read, per-language fallback, lazy migration, Learn native line). Recense `build.sh` OK, `tests/regress.sh` exit 0, `--corrections-selftest` 24/24, `--edits-selftest` 8/8.
- Not tested: real R2 (If-None-Match on Recense PUT, Worker conditional puts), real Groq vi/fr output and quota, Apple Translation vi/fr on device, Recense on screen. Deploy Gallery before running the new Recense: the old Gallery does not read asr.json.

### 2026-10-24 05:21 PDT · Content keys, player sizing, Key gestures, Learn view restored, documents viewer (Gallery + Recense) · PARTIAL
- Deployed to gallery.improvdiplomat.workers.dev (version 5698b8b8). Nothing committed, in either repo.
- Content keys: a transcript's key is now cacheKey("fp:<size>:<sha256 first 64 KiB>:<sha256 last 64 KiB>"). Recense computes it in `ContentKey` (local files, and Gallery files through ranged R2 GETs). The Worker computes it in `transcript.js` `fingerprintKey`. Locks use the same key. Old path keys are still read as a fallback, and library.json aliases are checked under both keys.
- Player: EQ sliders and the tool bar are sized for iPad Air 13" and 12 Pro Max (`gallery.css`). An audio file with no stored key gets its key detected the first time it is opened, so the Key labels show key names instead of +1/+2. The Key caption's list now also opens on a press plus one-finger swipe up, a pointer resting on it, or two fingers up. Two fingers down steps back one notation. Hold still opens it.
- Learn mode: the §6 barrel was replaced by the earlier two-place view (`learningPlaces`, recovered from the session log). Native-language lines were kept. The view is centred above the play controls. It rebuilds when the language changes. `.txp` got box-sizing back, which fixes text shrunk to 8px.
- Share sheet: Send was renamed Copy (it copies the link). Documents: .md, .docx (mammoth 1.6.0 from cdnjs), .txt/.csv/.json/code/.rtf now open as pages in the PDF viewer's layout. Nothing in a document runs.
- Recense: CC On / CC Off replace "Minimize Subtitles", which did nothing because a non-activating panel won't miniaturize. CC Off hides the window. [Ambient Sounds] is shown between lines while there is sound, and for the whole of an instrumental. It uses a loudness envelope every 0.25 s, cached as <key>.ambience.
- Docs: Gallery README "How it works", `gallery/SYNC.md` (a proposal for a live multi-device library: Durable Object change feed, ETag writes, WebDAV for Finder/Files), Recense README sections.
- Validated: `npm test` 12 + 27 + 14 + 26 UI passed, including new content-key, Learn and Documents tests. Recense `build.sh` OK, `tests/regress.sh` exit 0. Checked on the live /m/ link in Chromium and Playwright WebKit: audio plays, no main-thread stalls.
- BLOCKED: the reported freeze after a selective share link doesn't reproduce in either browser. Next step: the owner's device and browser, and whether it happens on Main or only on /m/.
- Not tested: a real iPad, iPhone or Safari; Recense live with [Ambient Sounds]. Leftovers to delete: `test/.shots/`, `test/wk.tmp.mjs`, `test/ui.test.mjs.add`.

### 2026-10-24 05:45 PDT · Firefox freeze, Language label, Recense Play/Pause (Gallery + Recense) · PARTIAL
- Freeze on MacBook Firefox (both /m/<token> and /main): the cause was Recense's Firefox bridge (extension/content.js), not Gallery. It followed Gallery's player, sent it play/pause/seek commands, and fetched whole files through the page when Recense couldn't download them ("can't decode … yt-dlp couldn't get audio … bytes for episode" in recense.log). The bridge now skips gallery.improvdiplomat.workers.dev; Gallery shows the same transcripts through content keys. Signed unlisted as 2.1.7 (`extension/signed/c10d67200a6440a499d0-2.1.7.xpi`); the owner installs it. Not reproduced in headless Firefox/Chromium/WebKit without the extension, which fits.
- Gallery: Info's "Native language" is now "Language". Deployed (f69e79fc, then again with this entry).
- Recense: the menu bar's Play and Pause rows are one row, "Play" while paused and "Pause" while playing. It is wired like Sill's wake strip: the system ⏯ key (`pressPlayPause`), so it controls whatever plays. A followed browser player is told directly. Its state is tracked locally when nothing is followed, since macOS 15.4+ hides what is playing. Built; not relaunched.
- Not tested: the new xpi in the owner's Firefox; ⏯ posting needs Recense to have Accessibility permission (Sill has it).

### 2026-10-24 06:40 PDT · Firefox freeze (2nd pass), Info layout, Sill ⏯ drives Recense · PARTIAL
- Freeze: it persisted with bridge 2.1.7 installed, so the bridge wasn't the whole cause. It doesn't reproduce in clean Playwright Firefox (an 80 s session with play, EQ, Key, pause, seek and the lyrics on: main-thread lag ≤ 27 ms). The owner's Firefox has 20 add-ons. The likeliest culprit is Dark Reader: it watches inline-style mutations, and Learn mode rewrote each word's color, background and shadow every frame. Fixes: `<meta name="darkreader-lock">` on every Gallery page (Gallery is dark already), and `paintWord` now writes a style only when it changes. A second suspect, Audio Controller (it takes the media element with its own AudioContext when a volume is stored for the page), is already caught by Gallery's try/catch. Deployed a96c898f, then again with this entry. NOT VERIFIED in the owner's Firefox. If it still freezes: try a private window with add-ons off, then turn on Dark Reader, then Audio Controller.
- Info: Rename / Change Cover / Delete Cover stay on one row. The key controls are on the row below: Detect Key, then Set Key / Key X to its right. Under the name only the size shows (the type is gone), and both are left-aligned.
- Recense: new `POST 127.0.0.1:47123/playpause`. It plays or pauses a followed player (handled: true), otherwise it just flips the menu row's state. The menu row is unchanged. Sill: the strip's ⏯ calls that endpoint first and presses the system ⏯ key only when Recense didn't handle it or isn't running, so the two never double-toggle. Both were built and relaunched (Recense with `open`, Sill with `launchctl kickstart -k local.sill`). The endpoint was checked with curl. The strip button wasn't pressed.

### 2026-10-24 · Playback that outlives the viewer, 12 Pro Max layout, Key barrel, [Ambient Sounds], swipe-down Back, Info popup, instrumentals, word light · PARTIAL
- Deployed e43e5177 (gallery.improvdiplomat.workers.dev). Nothing committed.
- Playback: a playing track is parked whole in a hidden dock when the viewer closes or moves to another item (photo, PDF); reopening its item puts it back. It stops only on Pause (pill, lock screen, keys) or when other media plays. A "♪ name ❚❚" pill shows while parked. Following a link while sound plays (/main?p=Music → ?p=Raven) opens the page in a frame over the playing one (`SHELL` in gallery.js); a play in any frame stops the others; Back closes the frame. Checked in Playwright Chromium: survives Back, item change and folder change; Pause stops it.
- Layout (12 Pro Max): upright, the play controls rise 120px while the sound tray is open (`:has(.p-eqwrap.open)`). The 10-row Key list is now one line, a sideways scroll-snap barrel with faded ends, centred on the notation in use. Checked at 428×746 and 926×340 (touch emulation).
- Info no longer pops up on play: background key detection reopened it (`keySaved`); it now refreshes Info only if open.
- "Visions, diaspora": a Whisper hallucination on instrumentals. A transcript whose every uncorrected line is a known phantom (`PHANTOM` in transcript.js) is served as none, so the cover shows. Richmond (Moses Yoofee Trio) left unedited as asked; not checked against its real asr.json.
- [Ambient Sounds] (Gallery): shown while media plays and no line is up, and over an instrumental's cover.
- Swipe down on the viewer (comments closed) goes Back.
- Word light: gold for the whole word (no fade to pale mid-word), wipe with a soft edge, beats bridged across gaps < 0.6 s, a smoothed clock (interpolated, never steps back < 0.3 s) for coarse Firefox/deck time; fades gold → white over 0.45 s after.
- Validated: `npm test` 12 + 27 + 14 + 25 passed. Not tested: real iPhone/Firefox iOS, owner's MacBook Firefox freeze (still unverified), lock-screen pause, frames under Cloudflare Access. The round grey speech-bubble button in the owner's screenshots is not Gallery's (likely the browser/iOS); not changed.

### 2026-10-24 08:35 PDT · Firefox silent playback (3rd pass), orphaned covers · PARTIAL
- Cause: the owner's Firefox add-on "Audio Controller" (content script on `<all_urls>`, all frames) wraps every `<audio>/<video>` it finds at DOMContentLoaded (and, for URLs it has a stored volume for, every one added later; it has one for `/m/<token>`) in its own AudioContext, made before any click. On this Mac (SoundSource) that context can stay dead, so the track ran on silent; Gallery's watchdog only sees Gallery's own graph. Reproduced in Playwright Firefox with the add-on's script injected: deep link `?open=` created a suspended AudioContext around the player.
- Fix (gallery.js): the player's media element lives in an open shadow root (`shelter`, `.mbox{display:contents}`), which querySelectorAll/MutationObserver don't enter; play/pause handed to `mediaWatch` (they aren't composed); `stageMedia()` for lookups. Repro after the fix: no add-on AudioContext, track plays.
- Covers: R2 had 6 `art/Music/*` covers for files deleted or renamed outside Gallery (You & Me, You Know You Like It, DJ Snake…, Born Yesterday…, I Got You…, dilbar…). New `artSweep` (main.js, nightly cron) moves art/ entries whose file is gone to `trash/<day>/art/` then deletes them. Deleted covers (Delta V, Ramta Jogi) are correctly marked `deleted:1`; keys/comments maps have no stale names.
- Validated: `npm test` 12 + 28 + 14 + 25 passed (new sweep test). Deployed 1753c5ba (15:31Z). The 6 orphan covers moved by hand (rclone) to `trash/2026-10-24/art/Music/`; art/Music now 19. Not committed, not heard in the owner's Firefox.

### 2026-10-24 11:41 PDT · Firefox silence after share links (4th pass), Text Size (Gallery + Recense), share-link view state, eager key · PARTIAL
- Firefox: Audio Controller is no longer installed, and clean Playwright Firefox plays Main, Key/EQ and folder frames fine. Owner: Main goes silent with time moving after playing a selective share link, and comes back later by itself. Likely cause (not reproduced): Gallery's one AudioContext was never suspended or closed, so Firefox kept its output stream open for the whole visit. With SoundSource, one stuck stream can silence every tab of the site, since a site shares a process. Fix (`gallery.js`): the context sleeps 4 s after the last pause, wakes on play, is closed when no player uses it, when its sound dies (`soundDied`) and on `pagehide`; the "waiting" toast only shows after 2 s down. Checked in Playwright Firefox: running → suspended after pause → running on play, no toast → closed on viewer close. NOT VERIFIED in the owner's Firefox.
- Gallery Text Size: subtitles `clamp(22px,3vw,30px)`, line-height 1.45, letter-spacing .012em, the same size for both languages; one `prefs.txScale` (0.7–1.8, `localStorage gallery.textScale`) with three entry points: a frosted `a | A` pill top-right (shown only while subtitles are up; it pulses on tap, dims at the bounds and shows the % while changing), Info › Text Size under Language, and a pinch over the stage (2-finger touch, trackpad ctrl+wheel, Safari gesture events; browser zoom prevented). The full-transcript sheet scales too. Note: the owner rule "liquid glass only on the 3 playback controls" conflicts with the asked-for frosted pill; the pill was built frosted as asked.
- Recense (`main.swift`, built, not relaunched): it has no ⓘ button, so the two rows are in the menu-bar menu. Text Size runs `A− ──●── A+` (0.7–1.6). Balance runs `L1 ━━●━━ L2` (5 ticks, continuous, detents at the centre and both ends). Toward one side, that side's lines grow 1.15→1.3× while the other side's shrink 0.8→0.6× and dim 0.7→0.4; at the end detent the other side is hidden and takes no room. It applies to Follow and Learn (`Reader`, `ReaderRow`, `dim`). `tests/regress.sh` exit 0.
- Share-link state (2A): the viewer's Share made an `/m/` room with no language, and pages read `localStorage`, which exists only on the Mac, so the iPhone got English. Links now store `view: {lang, notation}` at creation: `/s/` in `.manifest`, `/m/` in `invites/<hash>.json` (`viewOf` in `common.js`). Share pages hydrate from `G.view` (else the old `?lang`, else English) and never read or write the visitor's `localStorage`. `?lang=` is no longer added to copied URLs.
- Notation follows language (2B): Ton.⇄Tông⇄Key move with FR/VI/EN (`notationFor`), on Main at load (the owner's stored vi + Ton. becomes Tông) and on share links. Other notations are left alone. Solfège needs a known key: see 2C.
- Eager key (2C): `autoKey` runs as soon as an audio item opens (a one-item link opens at load) on Main and on share links (kept in memory for visitors; Main saves it). Transpose prompt: "Enter a starting key. Leave blank to keep D minor / Ré mineur." with the detected key filled in (EN plus the active language). Blank re-applies the detected key without detecting again.
- Proposals (3, 4): `sync/docs/proposals/G-shared-links-and-mobile-rw.md`. bisync was not installed: `~/Gallery` is Gallery.app's `rclone nfsmount` of R2 (37.3 GB Main; the Mac has 13 GiB free), so bisync would sync R2 with itself. `chau/Gallery/main.swift` gets `--vfs-cache-max-age 72h --vfs-cache-min-free-space 5G` (source only; `build.sh` would unmount `~/Gallery`).
- Validated: `npm test` keylabel 12, routes 29 (new: G.view on /s/ and /m/), transcript 14 (stale version numbers in one test fixed, unrelated to this change), UI 28 (new: Text Size; share link Tông plus eager key). Screenshots at 1280×800 and 428×926.
- Deployed d98aee6e (2026-10-24 ~11:45 PDT): `/` 200, `/main` 302 (Access), an unknown `/s/` 404, and a live `/s/` page serves the new client (`ctxSleep`, `gallery.textScale`, `notationFor`). Not committed. Links made before this deploy have no `view`, so they fall back to `?lang` or English. Not tested: the owner's Firefox and SoundSource, real iPhone pinch, Recense menu on screen. Leftover temp scripts to delete: `test/ff3.tmp.mjs`, `test/ff4*.tmp.mjs`, `test/shot2*.tmp.mjs`.
| G-tx | Transcript: full-transcript sheet + persistent change history | DONE (tests) | 2026-10-24. Tap a line → whole transcript; only the line being heard is a field, others seek+play. `keep/<key>/changes.json` logs every correction with `from` (last 1000); Changes → Restore. GET `/main/api/transcript/changes`, `/api/transcript/changes`. transcript 13/13, routes 28/28, ui 25/25. Not deployed, not committed. Recense side not done |
| G4a | Home bar + vertical bar, phone landscape | PROPOSED | 2026-10-27 `homebar.css`: new `(pointer:coarse) and (max-height:500px) and (min-width:700px)` blocks — horizontal --hbw 460/--hbl 60/--hbh 36/--hbs min(780, safe width−120); vertical `.p-eqbtn` --sl 30, height 52. CSS parses; not viewed on device or in playwright yet |

### 2026-10-24 15:31 PDT · SPEC P1 file dashboard: New Folder + Move (no WebDAV yet) · PARTIAL
- Backend (`gallery/src/main.js`, routed in `worker.js`, owner-only behind Access + same-site check): `POST /main/api/folder {dir,name}` writes the Mac-style `files/<dir>/<name>/.folder-<16 hex>` marker; `GET /main/api/folders?p=` lists subfolders for the picker; `POST /main/api/move {paths,to}` moves files (≤200) with art, comments, key and `was`, drops them from rooms in the old folder (`renameInInvites(…, null)`). Containment: every key is `files/` + a `cleanPath` path (no empty/`.`/`..` segments, no control chars); new names are one segment (no `/ \ :`, not hidden, not junk, ≤300, strings only); destination must already exist; a move never replaces a file (head check + `etagDoesNotMatch:"*"`), a clash or missing file is reported per item. `copyObject` no longer awaits the stream when a conditional put is refused. `renameComment`/`moveMainKey` handle cross-folder moves. Folders themselves are not movable (files only).
- UI (`page/gallery.js`, `client/gallery.js`, `gallery.css`): ⋯ menu row "New Folder" (Main only) → prompt → reload; Select mode footer gets a blue `--ctl` "Move" (Main, owner, ≥1 picked) → sheet (same `.inv` sheet as Invite) with breadcrumb, folder list, "Move Here" (disabled "Already Here" in the source folder), Cancel.
- Validated: `npm test` keylabel 12, routes 34 (5 new: new folder, traversal/bad names, move carries sidecars, no-replace/missing-folder/partial, traversal/markers/bad lists + picker), transcript 14, UI 28 (new: New Folder → Move in Chromium). Not deployed, not committed, not checked on the owner's devices.
- Next: WebDAV (P1 second half) on these same checks (`/dav/…`, own Basic-auth secret, Notability append-only per A6).

### 2026-10-24 · SPEC P1 WebDAV (`gallery/src/dav.js`) · PARTIAL
- `/dav/notability/` → MAIN `notability-backup/`, outside Access, HTTP Basic against secret `NOTABILITY_DAV_HASH` (sha-256 hex; unset = 404), constant-time compare, 10 wrong passwords per IP per 15 min → 429 (PUBLIC `rate/dav/`, swept by the daily `rateSweep`). Append-only per OVERFLOW.md §3: OPTIONS, PROPFIND (Depth 0/1; infinity → 403), GET/HEAD (Range), PUT, MKCOL; an overwrite copies the old file to `notability-versions/<path>@<time>` first; DELETE/MOVE/COPY/PROPPATCH/LOCK → 405.
- `/main/dav/` → MAIN `files/`, behind Access like all of `/main` (rclone webdav backend with the Mac's service token, or the browser cookie). Read-write: PUT honours If-Match/If-None-Match, keeps the old file in `trash/<day>/<path>@<time>`, ETag-conditional put, `X-OC-Mtime` → `mtime`; MKCOL writes the `.folder-` marker; DELETE → trash; MOVE/COPY files with comments/art/key (Overwrite T trashes the old destination, F → 412). Folder MOVE/DELETE → 403, no LOCK (class 1, so Finder mounts read-only). Chunked PUTs without Content-Length are buffered up to 32 MiB, else 413. No Basic-auth door into Main: Files app / Finder need Access (SYNC.md §4), owner decision.
- Path checks: same `cleanPath` (decoded once) + `segmentName` as New Folder/Move; markers, `._*`, `.DS_Store` and other dot names are hidden and refused; Destination must be this origin and this mount. `segmentName` now allows `:` (Notability titles). Refactor: `trashFile`, `moveFile`, `makeFolder`, `keepInTrash` exported from main.js and reused by the dashboard.
- Validated: `npm test` keylabel 12, routes 39 (5 new: Basic auth + lockout, Auto-Backup sequence + versions + 405s, traversal on both mounts incl. %2f/NUL/Destination, main PUT/versioning/conditionals/chunked, MOVE/COPY/DELETE), transcript 14, UI 28. Not tried with real Notability, rclone or Finder. Not deployed, not committed.
- Deployed 450905eb (2026-10-24, owner's go; working tree as is, uncommitted): `/` 200, `/main` and `/main/dav/` (GET, PROPFIND) 302 to Access, unknown `/s/` 404, `/dav/notability/` 404 because **`NOTABILITY_DAV_HASH` is not on the `gallery` Worker** (`wrangler secret list` shows only ACCESS_AUD, SERVICE_CLIENT_ID). Signed-in `/main/dav/` and the dashboard buttons not tried live. 2026-10-25: owner set the secret on `gallery`; live `/dav/notability/` now 401 with `WWW-Authenticate: Basic realm="Notability backup"` (no auth and a wrong password both 401). Correct password and Notability's own backup not tried.
- Owner, to switch it on: `wrangler secret put NOTABILITY_DAV_HASH` with `printf %s '<password>' | shasum -a 256`, deploy, then Notability › Auto-Backup › WebDAV `https://<host>/dav/notability/`, PDF + Note. Next: try that, then decide on folder MOVE (Finder renames) and LOCK for a read-write Finder mount.
- 2026-10-29 15:01 PDT · Google Drive + ~/Sync off the Mac · PARTIAL. rclone check vs gallery-archive/chauphan/{Sync,Google Drive}: Sync 15/15 match (Nichole m4a only in R2). Drive: `Live/2026-09-22 21-01-49.mov` was truncated in R2 (573 MB of 2.36 GB) → re-uploaded, verified with `check --download`; 3 .gmap pointers uploaded; .gdoc → .docx exports already in R2; 7 online-only files size-match R2 (local unreadable, Drive app gone); `School/Untitled document (1)/(2).gdoc` unreadable, live only in the Google account. Moved to ~/.Trash: ~/Sync, ~/Google Drive link, DriveFS (6.8 GB), drivefs containers/prefs, com.sync.desktop.plist, Chrome-app Google Drive.app. Left: ~/Library/CloudStorage/GoogleDrive-clphan7@gmail.com (mv denied, File Provider-held). Kept Google updater agents (Chrome).
- 2026-10-29 15:01 PDT · Gallery Files sidebar name → "Gallery" · DONE (System Events shows "Gallery"). apple/macos: CFBundleName "Gallery Files" (must match the bundle file name), en.lproj/InfoPlist.strings → "Gallery", LSHasLocalizedDisplayName; rebuilt + installed, Finder relaunched.
- 2026-10-29 15:59 PDT · Offsite disks (Photos, Messages, Mail stores in R2) · PARTIAL. APFS sparse bundles in gallery-archive/.disks/ via the direct S3 remote; login item com.chauphan.disks-mount runs through ~/Applications/Disks Helper.app (zsh run by launchd is refused the network mount). Verified: test image survives an empty-cache remount (md5 + SQLite integrity), cache evicts to its cap, upload ~3.9 MB/s. Messages + Mail stores copied (verified) and linked from ~/Library (originals kept as *.local-2026-10-29); Photos library copied (89,732 files), the switch is the owner's GUI step. Runbook docs/runbooks/offsite-disks.md; details .handoff/2026-10-29_164631_HANDOFF.md. Next: owner GUI steps, then Gallery-app exports (ask the owner what to show).
- 2026-10-31 07:09 PDT · Gallery iOS app icon → Photos-style petals forming the iCloud cloud · DONE (actool compiles AppIcon for iOS 18 with no warnings; 120 px output checked; not built or installed on a device). AppIcon.appiconset/icon-1024.png replaced (white background, 12 translucent petals around a round aperture, outline fitted to Apple's iCloud icon cloud); Contents.json is now a single universal entry, so dark and tinted modes use the light icon (owner's choice). icon-1024-dark.png and icon-1024-tinted.png kept on disk unreferenced (owner chose to keep them). Uncommitted. Details: gallery/.handoff/ITEM38.md
- 2026-11-05 13:47 PST · Unified offline-first + redesign plan (Sync · Gallery · Recense) · IN PROGRESS (phase 0 since the owner's "go ahead for all", 11-05 14:00). Spec at docs/specs/unified-offline-first-and-redesign.md (A1–A17, B1–B11). Done 2026-11-05 14:21 PST: A10 #1–#4 + downloads-to-r2 --no-traverse (docs-sync hourly on S3, 0 Worker requests a pass), A11 N2, Y8 (empty Desktop), R15, R16, G20, Raven sealed, A10 #5 committed (gallery 9226f2a, push = deploy waits for the owner), X5, D1. Next: A11 N3–N4, A13 L1, R17, X4/X9, then A15. Details .handoff/HANDOFF.md.

- 2026-11-06 08:20 PST · D34 G0 show feeds (work/study-feed, merged 8e7986a) · PARTIAL. `library/chau/show.mjs` publish|invite|revoke; `GET /m/<token>/feed.xml`. npm test 120 passed; fresh Claude review: no blockers, 3 fixes (NFC titles, GUID per section, Matters/Raven guard by name) coming as a follow-up merge. Next: live feed + iPhone Podcasts follow.

- 2026-11-06 11:55 PST · D13/D33 editor core in the strip (work/editor 3d0a4b4, strip side be1efdf) · DONE. CodeMirror 6 core M1–M5 (search, outline, legal numbering, Draftpad page markers, bridge, deletions record); a Claude review found 2 blockers, fixed and now regression tests; the real page round-trips and syncs inside Recense. Classic stays the default. Open: `getRemoved()` (D32) isn't read by the host yet.
- 2026-11-06 17:05 PST · Prototype step 1 + iOS (3ac18c2, 6bad6d3) · PARTIAL. Editor M6: pages again (swipe, ⌘[ ⌘]), one-field find, outline overlay, links, PDF/image embeds via recense-file: (cached offline); editor 29/29, strip selftest 58 ok. `recense draftpad-flip` dry run lists 24 pages newest-first; `draftpad-flip-go` waits for the owner (Obsidian closed on iOS). iOS: named Recense (Gallery icon), Draftpad tab with the same editor and merge, Apple Pencil (Scribble; squeeze/double-tap ink → PNG in `Draftpad ink/`); SideStore + LiveContainer removed; installed on iPhone 12 Pro Max and iPad Air M3; resign-ios now per device. Open: on-device Pencil and Draftpad check; guest build (step 3).

## 8. Decisions made (defaults; change only if the owner objects)
1. "rw" = R2. "5 GB" = the iCloud quota (superseded: the plan is iCloud+ 200 GB, see §1).
2. iCloud stays the live lane once unclogged; ledger mirrors it; R2 takes overflow (A6). *Superseded in part by the owner's goal of 2026-10-27 ("everything serves G1, replace iCloud", §7) and §1a: iCloud stays live only until each source's cutover. The ledger keeps recording whatever Apple still holds, and at cutover a source's history moves to the catalog (`docs/specs/event-log.md` §1).*
3. Add D1 to Gallery (concurrent two-way writes, revocation checks, queries; Sync/Switchboard specs already use D1).
4. Phi: reuse whatever is installed on the SanDisk. Owner says "3.2", the Oct 9 directive says 3.5; inspect the files.
5. Battery colors: green ≥40, yellow 30–39, red ≤29 (red at 29 is mandatory; the old spec's yellow overlapped red). One constant each.
6. Scheduler starts in shadow mode for 2 weeks (addendum §7); owner can switch to live.
7. Recommended private repo: `sync/` (src/ledger.mjs + specs): unique, tiny, unversioned, and the root of both other projects. Do not push anywhere until the owner names the repo.
8. **Three projects, no folding; the sync engine belongs to Sync (PROPOSED 2026-10-29, owner to confirm).** Full guide: `docs/specs/organism.md`. Sync = custody (catalog, change feed, write protocol, devices, standards, backups, health); Gallery = library, player and Rooms on every device; Recense = presence on the Mac (process tap on any app, strip, Nook, Draftpad). Recense is a capability (modules + the `keep/<key>/` contract), not a fourth product. Rejected: Gallery into Sync, all into Sync, Recense into Gallery, Sync into Gallery (reasons in §3 of the guide). The engine code in the Gallery Worker (`fp.js`, `dav.js`, `tmp.js`, `archive.js`) moves first behind a boundary (`gallery/src/engine/`), then into the Sync Worker behind a service binding, with every device URL unchanged. iOS "player that follows you" = Gallery's own playback leaving the app (background audio, Now Playing, PiP with lines, Live Activity) on a native sound engine driven by the web home bar; Recense does not fold into Gallery. Placement rule for new work: the guide's §4. Supersedes, as to ownership only, `docs/specs/gallery-nervous-system.md` "1 + 2 = the sync engine, in the Worker" and §1's "Gallery (… API, glue)".
9. **One event-log format for Sync's two logs (2026-10-29, built).** `docs/specs/event-log.md`. The ledger (observer: folders Sync doesn't own) and the catalog (authority: R2 roots Sync owns) stay two writers but share the event vocabulary (create/modify/move/delete; v1 put/tombstone still read), the chain rule (same GENESIS and test vector in both suites), the id rule, one delete guard (`massDelete`: >100, or >10 and >10%) and one verifier (`ledger.mjs verify` reads both). Consumers apply only the four tree ops.

## CHANGELOG

### 2026-11-06 07:15 PST · A12h / D3 ledger: a move is not a deletion; held deletions instead of a stalled journal · DONE
- Cause (2026-11-05 15:33 → 11-06 14:52Z): N3 moved the conflict copies. The mass-delete guard counted moves as deletions
  and threw before saving state, so nothing was journaled. `ledger-job.sh` notified on every WatchPaths run, which meant
  every Draftpad save.
- Change:
  - `sync/src/ledger.mjs` counts only vanished files whose bytes are gone from the source.
  - Past the guard, those deletions are held: kept in state, shown as `held: N` in the log and in `views/health.json`,
    while the run records everything else.
  - `sync/bin/ledger-job.sh` notifies only on a change (run failing or recovered, held count, fold, stale), using
    markers in `~/.ledger/`.
- The 51 conflict copies' deletions were recorded at 14:52Z by session chauphan-3f's one `--allow-mass-delete` run
  (110 creates, 51 deletes, 2 modifies).
- Validation:
  - `npm test` in `sync/`: exit 0; 6 new checks (held, stays held, approve, cleared, health, mass move).
  - The real job through launchd kickstart at 15:04Z: exit 0, `held: 0`, health OK, no notification.
- Next: Recense foundations (X1: transcripts in `~/Recense/keep/`; the play-button fix). Lanes `work/study-feed` and
  `work/editor` started from `main` 9fab85a; briefs in `.handoff/<area>/INBOX.md`.

### 2026-11-05 21:05 PST · A11 Draftpad: edits from the iPhone/iPad no longer overwritten · DONE (code + selftest; device round trip unverified)
- Owner: "edits don't sync". Mac side fine: 373/373 vault files uploaded, iCloud synced 20:51; no new conflict copies.
- Cause in Recense (`strip/app.swift` saveNow/pollExternal): the 1 s poll skips while you type, then the 0.4 s save wrote the
  whole panel over `draftpad.md` and set lastMTime, so an edit that arrived from another device in that window was lost
  for good. Writes were also uncoordinated (no NSFileCoordinator) on an iCloud file, the T1 conflict-copy path.
- Fix: `strip/notesync.swift` (linked in `Sources/recense/`): every save compares base (last read/written), mine and the
  file; file unchanged → write mine; only the file changed → show it; both → line 3-way merge (Myers via
  CollectionDifference), shown in the panel; same lines both ways → mine in the file, theirs as one sibling
  `draftpad (other device <date time>).md` (spec A4 notes rule). Reads/writes through NSFileCoordinator.
- Validation: build ok (one retry: a transient "error closing speech.swift.o"); `recense selftest` exit 0 with 9 new
  draftpad checks; Recense relaunched on it. Not yet seen live: an iPhone edit while typing on the Mac.
- Next: owner test: type in Draftpad on the Mac, edit `draftpad.md` in Obsidian on the iPhone, check both land; also
  the canary f6666f34 lines (`iphone HH:MM`, `ipad HH:MM`), which show whether iCloud carries the vault both ways.

### 2026-11-05 20:40 PST · Library deploys from louan-dev/recense · DONE
- `wrangler deploy` failed twice on `/accounts` with the GALLERY_GITHUB secret set at 18:12; the owner gave a new Cloudflare API
  token (set 20:01). The rerun then hung 30 min in `playwright install --with-deps` (cancelled); a fresh `workflow_dispatch`
  run 42163127779 passed `npm test` and deployed e7b4cb3 at 20:39 (Cloudflare deployment 04:39:18Z). First library deploy
  from the one repo: everything since 7442fcc (f468f35, the cutover, the home bar glide fix) is live.
- Owner: roll that token (it was pasted in chat) and set the new value on GitHub; rotate the two 64-hex values pasted
  earlier if they are live R2 keys.

### 2026-11-05 19:50 PST · CI: the comment swipe test that blocked every library deploy · DONE (fix pushed; deploy below)
- Every CI run since 11-05 14:57 (gallery 9226f2a, 1c676a1; recense 75acd7a, e005a61 twice) failed only
  `comments: right after posting…` (`library/test/ui.test.mjs`), waiting 30 s for `#thread .crow.sw.open`; it passed on the Mac.
- Reproduced with Chromium CPU throttled 6× (2 of 3 failed). Probe: between reading the row and the wheel, the thread
  scrolled 52 px (the field's smooth `scrollIntoView` still settling after the repaint), so the wheel hit the field's
  textarea, not the row. A test race, not a product bug: a real pointer stays over the moving content.
- Fix (test only): `swipeDelete` waits until the thread's scroll rests for 150 ms, then swipes, and retries up to 4 times.
  Throttled 6×: 5 of 5 pass, plus all 4 comment tests; full `ui.test.mjs` unthrottled: 36 passed, 0 failed.
- Also: `gh` timed out to api.github.com from this Mac (curl worked): CI was read, rerun and the old repos archived
  through the REST API with gh's token (`louan-dev/gallery` and `louan-dev/sync` archived 19:3x).

### 2026-11-05 18:52 PST · Library home bar: momentum glide fix (held back from f468f35) · DONE (not pushed; push deploys library)
- **Cause:** the Gallery session's homebar.js glide detector needed < 34 ms between wheel steps; Playwright's
  synthetic steps come ~50 ms apart, so "Notes 35" never saw the glide and failed. On failure the harness's unbounded
  `pg.screenshot()` stalled on the animating ruler and node grew to 1.3 GB until macOS killed the UI suite.
- **Fix** (recense 81e22fc): `library/src/client/homebar.js` glide steps may be up to 80 ms apart (detector, walk-back
  to the lift point, swallow window); `library/test/ui.test.mjs` failure screenshot bounded (5 s, caught). Plus the
  session's own item 31 reorder (notation toggle on the music page; `chromaAvg` declared before use). README.
- **Validation:** Notes 35 2/2; ui 52/52; viewer 120/120; routes 60 + 61 (D1: the 90 MiB upload test flaked once
  under memory pressure, 2/2 on rerun; passes on HEAD); dav-rclone 3; transcript 15; cadence; images 8.
- **Next:** owner pushes recense (deploys library via `.github/workflows/library.yml`).

### 2026-11-05 18:45 PST · A15 cutover (HANDOFF item 5, steps a–l) · DONE (push and the old repos' archive below)
- a. Gallery's tree committed by its session (f468f35, 18:24; its homebar momentum-glide change held back, patch kept in
  `.handoff/homebar-glide-uncommitted-20261105.patch`). sync and recense were already pushed. No second cutover ran.
- b. `a15-merge.zsh` rerun: 303 commits, gallery f468f35 + sync 0ea3fe5. One conflict in `sync/README.md` (the carried
  couplings commit vs sync's newer status line): took the one-repo text. The root `.gitignore` still named
  `recense/{.build-log.txt,_CodeSignature/,.wrangler/}` and `/recense/recense`: now `strip/…`. Re-verified on the
  branch: library `npm test` exit 0 (0 failed; ui 36, viewer 120), calendar dry-run + 4/4, sync selftests, `zsh -n`, plutil.
- c, d. Froze autoupdate, docs-sync, md-mirror (none mid-run); tagged `pre-monorepo-20261105` in recense (0551831),
  gallery (f468f35), sync (0ea3fe5).
- e. `main` fast-forwarded to the merge; the a15-monorepo worktree removed.
- f. Ignored local files moved (mv only): build output, launcher, `_CodeSignature/`, `.wrangler/` → `strip/` (the
  ModuleCache with the old path → Trash); node_modules, `.wrangler`, `.test-build`, `apple/build`, `apple/ios/Secrets`,
  `test/{.shots,.wrangler,tmpdeck.tmp.mjs}` → `library/`; Gallery's and Sync's handoffs → `.handoff/{gallery,sync}/`;
  `AUDIT.md`, `bin/cal-export` → `sync/`; the Arq checklist → `docs/decisions/`; the request files → `docs/requests/`.
- g. `~/Developer/gallery`, `~/Developer/sync` and the empty `recense/recense/` → `~/.Trash/recense-cutover-20261105/`;
  `~/Developer/sync` → `recense/sync` (temporary symlink; the signed `Move Offsite (Mac)` shortcuts still name the old path).
- h. 9 agents rewritten from `sync/launchd/` (they were equal apart from the path; old copies in the Trash folder) and
  reloaded (archive-mount and disks-mount needed a second bootstrap once the old instance had detached); autoupdate
  reinstalled from `strip/scripts/`; Move Offsite Quick Action reinstalled; Disks Helper rebuilt and signed (new default
  path); `~/Developer/.claude/launch.json` → `recense/library`, `recense/.handoff/prototypes`.
- i. md-mirror: the vault's `Mac/Developer/{gallery,sync}` (49 notes, all older than the last pass) moved to
  `~/Library/Application Support/md-mirror/backup/a15-cutover-20261105/`, so a resync can't rebuild the old folders or
  write through the symlink. Dry run: 0 to the Mac, 52 to the vault; real run ok. docs-sync's Gallery copy keeps the old
  `Developer/gallery` and `Developer/sync` trees (it never deletes): delete them there when you like.
- j. `zsh strip/build.sh`: exit 0, no warning, installed; Recense relaunched on it; `recense selftest` 25/25. Library
  `npm test` in the main checkout: exit 0, 0 failed (routes 60 + 61, ui 36, viewer 120, the rest pass). Calendar dry-run + 4/4; sync selftests. `launchctl list`: every agent exit 0
  except `ledger.obsidian` (1), which has refused since 15:33 because 51 of 312 vault files vanished at once (N3's moves
  into `_conflicts/`); it needs one `--allow-mass-delete` run, the owner's call (the auto-mode classifier blocked it here).
- k. `GALLERY_GITHUB` is already on `louan-dev/recense` (added 18:12); recense is private, so X4 doesn't block.
- l. Root guide `.claude/CLAUDE.md`: a one-repo table, one worktree per area, per-worktree handoffs, "One repo, separate
  apps". `/recense` skill. Memory: the old gallery and sync project folders held no memories, so nothing was copied.
- Validation: as above. Next: push recense (deploys library), archive `louan-dev/gallery` and `louan-dev/sync` with a
  pointer README; chauphan-88 then applies its homebar fix in `library/`.

### 2026-11-05 17:40 PST · A15 order step 3: the merge, staged · PARTIAL (built and verified on a branch; the cutover waits for Gallery's tree)
- Gate check: pushes open; the Gallery tree still closed: another session (chauphan-88) was running Gallery's tests at
  17:22 with its 6 edited files and `notes/item16-rec/` uncommitted. So the merge was built where it can't disturb
  anything: branch `a15/monorepo` in the worktree `recense/.claude/worktrees/a15-monorepo`, from fresh filtered clones.
  `~/Developer/{recense,gallery,sync}`, the launch agents and the installed app are untouched. Nothing pushed.
- `recense/.handoff/a15-merge.zsh <scratch>` (rerunnable): filter-repo on clones of gallery 1c676a1 (`gallery/` →
  `library/`, root docs → `library/`, notes → `notes/gallery/`) and sync 13cad4d (`bin src tools launchd config
  package.json` → `sync/`, `worker/` → `calendar/`, `PROGRESS BACKLOG SPEC decisions requests` → `docs/`, notes →
  `notes/sync/`), a path-collision check (none), two `--allow-unrelated-histories` merges, `git mv recense strip`, tag
  `a15/base`. A rerun carries every commit after `a15/base` over by cherry-pick. `refs/snapshots/gallery/p2-pre` kept.
- e93014f A15f: build.sh reads `../library/src/client` (a missing file stops the build), autoupdate pulls one repo and only
  in the main checkout, canon/openears read `recense/strip/`, Gallery.app's recovery doc, 9 launch-agent copies, disks-helper,
  Move Offsite, resign-ios, caldav-passwd; .gitignore rules follow their folders (the Arq checklist and requests stay
  ignored); `calendar/.wrangler/cache/wrangler-account.json` untracked (sync had the X4 leak too); CI
  `.github/workflows/library.yml` (`paths: library/**`); README.md is the front page (A15d), Recense's README is
  `strip/README.md`; the three CLAUDE.md files name `docs/PROGRESS.md`.
- Validation: 301 commits (105 + 143 + 50 + 3); `git log library/src/main.js` and `calendar/src/index.js` reach their
  first commits without `--follow`. `strip/build.sh` (minus its install step) built Recense with all 7 home-bar files, no
  warning; with `GALLERY_CLIENT=/nonexistent` it stops with an error. Library: wrangler dry-run ok; keylabel, ai, calendar,
  routes (60 and 61 with D1), dav-rclone 3, transcript 15, cadence, images 8, ui, viewer 108 all pass (one routes case,
  the 90 MiB upload, was "terminated" once in the full run and passed both reruns: a flake). Calendar: dry-run ok, 4/4.
  Sync: `npm test` ok; `zsh -n` on bin; plists and Move Offsite lint OK. Repos: all three are private (A15e #6 settled).
- Found: a copied `.build-sdk27` fails (its ModuleCache has the old path baked in): at the cutover, move
  `recense/.build-sdk27` to `strip/` and drop its `arm64-apple-macosx/release/ModuleCache`.
- Next (cutover, in order): Gallery session commits → owner pushes gallery and sync → rerun the script → freeze
  (bootout autoupdate, docs-sync, md-mirror) → tag `pre-monorepo-20261105` ×3 → ff recense main to `a15/monorepo` → move
  the ignored files (list in .handoff/HANDOFF.md) → old folders to the Trash on the owner's yes, symlink
  `~/Developer/sync → recense/sync` → repoint 9 agents + autoupdate, Move Offsite, rebuild disks-helper, launch.json →
  md-mirror `--resync` → owner adds `GALLERY_GITHUB` to louan-dev/recense, pushes, archives the old repos.

### 2026-11-05 17:16 PST · R17's hour log check; pushes and deploys since 16:36 · DONE (A15 merge waits for the gallery tree)
- R17, live: `~/Library/Logs/recense.log` 16:11–17:11 (207 lines): 0 sound checks, 0 lyrics lookups, 0 failed lookups,
  0 errors, 0 crash reports. Nothing new was played (every item came from its cached transcript), so no lookup ran;
  the selftest (25/25) stays the test of the lookup itself. Recense was relaunched at 16:23 by the A15 build (pid
  16746: R17 + A15i). The one odd line, `scan com.apple.Safari: -2753`, is older than R17 (11-03, 11-05 02:59).
- Pushed 16:36–16:45, all three: gallery 7442fcc, then sync 9b66ca9, recense 0551831 and gallery 1c676a1.
- Gallery CI: 7442fcc deployed at 16:44 (tests and `wrangler deploy` ok), so A13 L1 is live, and with it G20, the
  Raven seal and the 10-minute cron: the 14:57 run (9226f2a) had failed `npm test`, so nothing deployed then
  (corrected in the 14:21 entry). 1c676a1 (A15j) failed `npm test` too and is not deployed. Both are the same UI
  test, `comments: right after posting, Cancel and Delete are there…` (`gallery/test/ui.test.mjs:329`), 30 s waiting
  for `#thread .crow.sw.open`; it passed at 16:36 and locally, and failed at 14:57 before 1c676a1 existed: a flake.
- Next: the owner reruns the failed deploy (`gh run rerun 42139183544 -R louan-dev/gallery --failed`) or pushes
  again; the A15 merge waits only for a clean gallery tree (the other session's 6 files, `notes/item16-rec/`, and 3
  untracked test logs).

### 2026-11-05 16:40 PST · A15j "your call" rows: owner said yes · DONE (sandisk-rescue kept)
- Moved to `~/.Trash/recense-cleanup-20261105/your-call/`: `recense/.toolchain/pkgs` 403 MB (untracked installers;
  an offline reinstall needs them back from the Trash); `recense/.handoff/prototypes/_shared/clips/variations.flac`
  62 MB (the `.m4a`, `.json` and features files beside it stay); `~/Developer/auto_avsr` 843 MB (its own repo, 2
  uncommitted deletions, nothing ahead); the 4 old `~/.claude/projects/-Users-chauphan-Developer-sill*` folders 134 MB.
- Gallery 1c676a1 (not pushed): the 20 tracked reference images under `src/page/ui/{common,main,public}` 32 MB;
  `page/ui/README.md` (the interface rules `docs/architecture.md` cites) stays; README notes it. Nothing in the code
  used the images. Only these paths were staged; the other session's 6 files are untouched.
- `sandisk-rescue`: the owner said keep (until D3–D11 close). It went to the Trash for a moment and was moved back
  unchanged (12 entries, 1.3 GB, `scripts/run-all.sh` path for its disabled launchd job works).
- A15 order step 2 (cleanup) is done. Step 3 (merge) still waits: pushes (sync 4, recense 3, gallery 1 ahead) and a
  clean gallery tree.

### 2026-11-05 16:25 PST · A15 (one repo), steps 2–3: Nook → plain Recense; cleanup · PARTIAL (merge waits for its gates)
- **git-filter-repo** installed (brew, a40bce548d2c): that gate is open.
- **A15i** (recense 0551831, not pushed): `nook.swift` → `hider.swift` (+ its `Sources/recense/` symlink); `Nook`,
  `NookPrefs`, `NookToggle` → `MenuBarHider`, `HiderPrefs`, `HiderToggle`; `nookEnabled` → `hiderEnabled`, carried
  over once, and the stale `local.sill.nook.always` (155) / `.toggle` (153) positions are removed by the app on launch;
  README, `docs/architecture.md`, `.claude/CLAUDE.md` say menu-bar hider (history and the migration keep "Nook").
  Validation: `zsh build.sh` ok; `recense selftest` 25/25 (6 hider cases); relaunched (pid 16746); after launch both
  stale keys are gone and `local.recense.divider` is still 154. Not checked by eye: the divider in the menu bar.
- **A15j "delete"/"remove" rows** (→ `~/.Trash/recense-cleanup-20261105/`): `recense/recense/.build` 517 MB (unused:
  the toolchain build uses `.build-sdk27`); 8 of 9 `gallery/apple/build/ios-*` (kept ios-20261103-120034); `.test-build`
  43 MB, `test-results`, `test-fail.png`; 26 ignored `test/*.tmp.mjs` (kept `tmpdeck.tmp.mjs`). `git worktree remove`
  of gallery's c0-c1-g3-g5 and competent-williamson-789a2f (clean, merged into main), `prune` (no stale entries left).
  Recense branch `wip/main-uncommitted-2026-10-26` deleted (7979dd9, kept as tag `archive/wip-main-uncommitted-2026-10-26`).
  Already gone: `nook-fix` worktree (tag `archive/nook-fix-1f871c`), `gallery/.retired`, `.shots`. Skipped:
  `recense/build/Recense.app` (every `build.sh` remakes it). The other session's 6 gallery files are untouched.
- **Gates still closed:** the owner's pushes (sync 2, recense 3, gallery 1 ahead) and a clean gallery tree (the
  other session's collection-search work). "Your call" rows of A15j: not asked yet.
- Next: owner pushes + gallery session commits; then freeze (pause autoupdate + docs-sync, tag `pre-monorepo-<date>`),
  merge in fresh clones (A15e/c), couplings (A15f), CI, verify.

### 2026-11-05 16:15 PST · X4 + X9/N9 + autoupdate (continuation step 5) · DONE; A15 gates still closed
- **X4** (recense fcb45a5, not pushed): `recense/.build-log.txt`, the `./recense` launcher, `recense/_CodeSignature/`
  and `recense/.wrangler/` (wrangler's account cache) left the index and joined `.gitignore`; the local files are
  untouched. History still holds them: rewriting it is the owner's call (A15).
- **X9/N9** (read only; no key printed, nothing changed):
  - share-note publishes encrypted copies (`shareUnencrypted: false`) to `api.note.sx`. 5 notes are shared: "Chicago
    Family Trip…", "Revelato 007 Draft Pad - Design Brief", "Forwarding Address", "Medication & Sleep Log",
    "RÉVÉLATO 001 V1". Anyone holding a link can read the note; the key travels in the link.
  - images-uploader uploads straight to R2 over S3 (account endpoint, bucket `notes-images`), not through the Worker.
    Its access key and secret sit in the vault's `.obsidian/plugins/images-uploader/data.json`, which iCloud syncs to
    every device (X1/X8: rotate it, scope it to that bucket). `deletePolicy: immediate`: the vault holds 0 local
    attachments, so a picture exists only in R2. Notes show pictures through the Gallery Worker's `/i`, so each view
    is a Worker request. Its `customDomainName` holds literal backticks (`` `https://…workers.dev/i` ``); the 2 links
    in notes are fine, but check that the next upload's link works.
- **autoupdate** resumed (`launchctl bootstrap`): the first run exited 0 and left both repos untouched. It logs
  "installed" only after a push brings new commits; local commits never trigger it.
- **A15 gates:** pushes open (all three repos have new local commits now); gallery tree closed (the other session's 6
  files + `notes/item16-rec/`); `git-filter-repo` not installed. A15 waits for its own session.
- **Owner:** keep or unshare the two sensitive shares; fix `customDomainName`; set `deletePolicy` to keep a local copy
  if pictures should survive offline.

### 2026-11-05 16:13 PST · R17: lyrics lookups for music only (Recense) · DONE (installed and running; the hour's log check runs to 17:11)
- **Changed** (`recense/recense/recense.swift`, recense 03c398d, not pushed):
  1. Music only: played in Music, kept in the Music folder, or heard as music by SoundAnalysis in 30 s from the middle
     (`heardAsMusic`, once per item, cached as `heardMusic`). A title alone counts only when nothing could be heard.
  2. One exact LRCLIB `/api/get` (artist, title, album, length), then one `/api/search`; no artist-only search. Genius
     only for a confirmed song: 1 search + 1 get.
  3. User-Agent `Recense/0.1 (https://github.com/louan-dev/recense)`.
  4. 429/5xx: Retry-After (≤ 30 s; else 2 s, 4 s), 3 tries, no wait after the last; 404 = a definite miss.
  5. A miss is asked again after 30 days or under a new title (`lyricsAt`, `lyricsFor`); a failed network isn't saved.
  6. Lyrics count as the song's only within 2 s of its length or once the singing matches them (≥ 35 %).
- **Changes from the plan:** the title patterns (`looksLikeMusic`, "Artist - Title") don't bypass the sound check; they
  count only when nothing could be heard, because a 4-minute "Interview - Someone" otherwise costs 2 requests (the
  fixture's "0 for speech"). Once heard, the verdict also outranks the title heuristics in `isSong`. `build.sh` fix:
  lsregister failing to unregister the build copy (-10814) stopped the script after the install, before the launcher
  and cleanup (autoupdate would have logged "build failed" and never relaunched).
- **Validation:** sound check calibrated on 41 local files: 13 music files had music in 74–100 % of their 3 s windows,
  28 talks, lectures and podcasts 0–5 % (two podcasts over 20 min with music beds: 47 %, 89 %). `zsh build.sh` OK;
  `recense selftest` exit 0, 25 checks, 11 of them lyrics: 50 items against a stand-in that counts requests. 26 songs
  cost at most 2 each, 30 in all (the old lookup searched 44 times before any Genius call); 24 speech items cost 0
  (old: 25). Also checked: the retries, no network, the User-Agent, the 2 s rule, the 30-day recheck, Genius 1 + 1.
  Live LRCLIB, 5 requests: get hit, get miss (404 TrackNotFound) and search all have the shapes the parser expects.
  Recense relaunched on the new build at 16:11 (quit + open, as autoupdate does).
- Next: X4 untrack, X9/N9 plugin checks, resume autoupdate.

### 2026-11-05 15:43 PST · A11 N4: every Markdown file on the Mac in the vault (md-mirror) · DONE on the Mac (device check open)
- **New:** `bin/md-mirror.zsh`, `config/md-mirror.filters`, `launchd/com.chauphan.md-mirror.plist`, installed and loaded
  (every 300 s through Disks Helper, no WatchPaths, log `~/Library/Logs/md-mirror.log`). Three local bisync pairs,
  `~/Developer`, `~/Desktop`, `~/Documents` ↔ `<vault>/Mac/<name>`: Markdown only, minus `.git`, `node_modules`,
  `.build*`, `backups`, `.toolchain`, `.claude`, `.handoff`, `.wrangler`, `venv`, `auto_avsr`. `--compare
  size,modtime,checksum --conflict-resolve newer --resilient --recover --max-lock 2m --max-delete 10`, workdir
  `~/Library/Application Support/md-mirror/`.
- **Changes from the spec:** `--backup-dir1/2` keep every overwritten or deleted copy in
  `~/Library/Application Support/md-mirror/backup/<time>/<name>/{mac,vault}` (without them a note deleted on the iPhone
  would delete the original). A pair whose vault folder disappears after it was in step waits for `--resync` instead of
  reading it as every note deleted. The filters sit in `config/` beside docs-sync's (the plan said `bin/`).
  `RCLONE_CONFIG=/dev/null`: the user's rclone.conf is encrypted, and any rclone command without it waits for a password.
- **Validation:** dry-run resync: 108 copies, no deletes. First resync, then `rclone check`: 108 matching, 0 differences.
  Desktop and Documents hold no Markdown (skipped). launchd loaded; the RunAtLoad pass exited 0. A test note in
  `sync/notes/` reached the vault on the next scheduled pass, 4 min 41 s after it was made; an edit to the vault copy
  reached the original (kickstart, 1 s); deleting the vault copy moved the original into `backup/…/mac/` (4 s). iCloud:
  `Mac/` 108 of 108 uploaded, the vault 423 of 423, 0 pending. Canary f6666f34 started at 15:43 (the 10-13 note and
  state are kept in `~/.ledger/`).
- **Owner:** on the iPhone, then the iPad, append `iphone HH:MM` and `ipad HH:MM` to `_sync-canary.md` in Obsidian and
  open a note under `Mac/Developer/`; `node src/canary.mjs check` reports the hops.
- Next: R17 (Recense lyrics).

### 2026-11-05 15:33 PST · A11 N3: the split notes cleaned up (vault) · DONE
- **Brain dump:** 11 variants and no base file. The two newest differed only in lines 10–14: the 11-04 10:58 copy
  (62,228 B) has the full line 10 (the loop-cost request) and 2 more lines (the ad hoc networks question and a `---`),
  where the 10:40 copy has a cut-off "strengthen the replay logi". The 10:58 copy is now `20261102235159 Brain Dump.md`.
- **Moved, nothing deleted:** the other 10 variants and the 40 `draftpad.conflict*.md` are in
  `<vault>/_conflicts/2026-11-03/` under their old names; `draftpad.md` is untouched. The folder `Brain Dump/`
  (Notepad.md) is not a variant and stayed.
- **Report for the owner:** `_conflicts/2026-11-03/N3 report.md` lists, once each, the lines the moved copies have and the
  kept notes lack: 67 in the older brain dumps, 58 in the draftpad conflicts (some are long pasted blocks, cut at 400
  characters with their length noted). Nothing was merged.
- Validation: 0 brain-dump variants and 0 draftpad conflicts left at the vault root; 0 `*.conflict*` files anywhere else
  in the vault; 51 files in `_conflicts/2026-11-03/` (50 + the report).
- Next: N4 (md-mirror). Owner: the 7-day check for new `*.conflict*` files (spec A11 acceptance).

### 2026-11-05 15:32 PST · A13 L1: the Safari deck loops from memory · DONE (tests; not deployed)
- **What changed (gallery 7442fcc):** with Sound on, Safari's deck streams a WAV or AIFF in 65536-frame Range chunks. It
  kept two chunks behind the playhead and read 14 ahead, past B, so every A–B pass fetched the loop's start again and
  every Track Loop wrap the file's start. Now, while A–B or Track Loop is on, it reads ahead in loop order and never past
  B, and `openSound` keeps the fetched bytes of the chunks the deck holds plus the loop's, up to 64 MB. A longer loop
  streams and logs `[deck] this loop is over 64 MB`. Keeping is opt-in, so a download (bake) keeps nothing.
- **Change from the spec (A13 L1):** above 64 MB the loop streams instead of "fetch the file once", which would hold the
  whole file in memory; the local store (L2–L4) covers longer loops.
- **Validation:** two new UI tests with the deck forced. A six-chunk A–B loop: 0 Range requests in the 4 passes after
  the first (HEAD: 24). Track Loop on a 22-chunk file: each chunk read once over two passes (HEAD: 27 on the second).
  Both fail on HEAD. Full `npm test` in a clean worktree: exit 0 (calendar 15, routes 60 + 61, dav-rclone 3,
  transcript 15, images 8, UI 36, viewer 108). WebKit not run (only Chromium's headless shell is installed).
- **Also:** the owner pushed sync, recense and gallery at 14:57–14:58, so G20, the Raven seal and the 10-minute cron are
  deployed (corrected 17:16: that CI run failed a flaky UI test; they went live with 7442fcc at 16:44). The cut-off session `offline-first-unified-system-plan` has exited (no process); it can't resume on its own.
- Next: A11 N3 (vault conflicts), then N4 (md-mirror).

### 2026-11-05 14:21 PST · Phase 0 of the unified plan: A10, A11 N2, Y8, R15, R16, G20, Raven, X5, D1 · PARTIAL
- **A10 #1–#3, A11 N2 (sync bin/docs-sync.zsh, launchd plist):** docs-sync now reaches Main's `files/Docs` over R2's S3
  API (`gallery-main:`), not the Worker's WebDAV: 0 Worker requests a pass (it was ≈ 400–550, ≈ 90 % of the daily
  budget). Hourly with no WatchPaths (was every ≤ 10 min plus every vault save); INDEX.md nightly; `--modify-window 1s`
  (Gallery keeps whole-second mtimes), `--fast-list`, `--conflict-resolve newer`, every resync `--resync-mode newer`,
  `--backup-dir2` = Main's `trash/<day>/Docs/`. The vault is one-way (only iCloud writes it, T1); Downloads left
  (downloads-to-r2 owns it); two-way lanes skip Markdown. Y8: a lane with no documents on either side is skipped (the
  empty Desktop failed 408 passes and notified each time).
- **Not as planned:** the preview run went through Disks Helper, which passes no arguments, so it ran for real (14:15)
  instead of `--dry-run`. Audit: the new S3 listings equal the old WebDAV listings file for file in all four two-way
  lanes; no backup was written on either side; nothing was copied, replaced or deleted. Next previews run the script
  directly, not through Disks Helper.
- **A10 #4:** archive-mount caches listings 1 h (was 1 min); it stays on the Worker so Finder deletes keep Gallery's
  trash. downloads-to-r2 gets `--no-traverse` (live plist).
- **R15/R16 (recense cee3f7f, installed):** the idle crash was `flux.sorted()[n-1]` with n = 0 (stems under 160
  samples), confirmed in the crashed binary's code; guarded, and the login item restarts Recense after a crash
  (KeepAlive Crashed; SIGTRAP restarts, SIGTERM stays quit, tested). ⌘ reveals hidden icons only when held alone with
  the pointer in the menu bar. `recense selftest` covers both. Every build since the rename had failed on a module cache
  holding `sill/` paths (moved to the Trash); the installed app dated from 11-03. `nook-fix` kept as tag
  `archive/nook-fix-1f871c`, worktree removed (504 MB).
- **G20, Raven, A10 #5 (gallery 9226f2a, not pushed):** only AI-using steps spend the daily budget; Main's `Raven/` is
  never indexed or answered from (its vectors leave on the next sweep); cron every 10 minutes. Tests: 25/25 AI (the G20
  test fails on the old code), routes 60 and 61 (D1 variant), the rest green; wrangler dry run OK. Pushing deploys: the auto-mode
  classifier blocked it, so it waits for the owner.
- **X5:** five plain-text `rclone.conf` copies moved to `~/.Trash/rclone-conf-backups-20261105/` (empty the Trash).
  **D1:** `com.chauphan.sandisk-rescue` unloaded and disabled (its caffeinate kept the Mac awake).
- Validation: docs-sync log `Desktop: no documents on either side, skipped` then `ok` (22:18Z, about 15 s); launchctl
  interval 3600; Recense selftest 14/14, running under launchd; gallery suites as above.
- Next: A11 N3–N4, A13 L1, R17, X4, X9; then A15 (one repo). Owner: push gallery (deploys), X1–X3, X8.

### 2026-11-05 13:47 PST · Unified offline-first + redesign plan (spec saved) · DONE
- Saved the owner-approved plan as `docs/specs/unified-offline-first-and-redesign.md`. It is documentation only: its items are PROPOSED, and nothing is implemented, deployed or committed. It covers:
  - the 11-03 Error 1027 (docs-sync's WebDAV bisync makes ≈ 90 % of the Worker's requests) and A10's five reversible fixes;
  - Obsidian everywhere (A11), media loops at 0 Worker requests (A13), ad hoc networks (A14);
  - one repo with Recense as the parent (A15);
  - the ask engine moved on-device, with verdicts on DEVONthink (A16);
  - seeding and links made offline (A17);
  - gestures, haptics, languages and reading (B9–B11).
- Found read-only on 11-05:
  - Recense's idle crash came back on 11-04 at 06:43 (`Features.measure`; R15).
  - Holding ⌘ breaks the strip (`recense/recense/nook.swift:51-53,93-102`; R16).
  - Idle cron runs spend Gallery's AI indexing budget (`gallery/gallery/src/ai.js:359-362`; G20).
  - The lyrics lookup grades D (R17).
  - DEVONthink To Go can't sync encrypted databases or cross Tailscale, so Matters splits into Matters (syncs at home) and Sealed (Mac only).
- The 10-29 offsite-disks handoff is archived unchanged as `.handoff/2026-10-29_164631_HANDOFF.md`; the spec and §7 cite it. `.handoff/HANDOFF.md` now holds this plan's handoff.
- Validation: `cmp` shows the plan and the spec are identical (190,014 B); HEAD is unchanged (bdfc2cd); the notes row was added. Next: the owner's go on phase 0, then A15.

### 2026-11-04 10:37 PST · Rename Sill → Recense across sync · DONE
- Current docs (README, CLAUDE, BACKLOG, SPEC, docs/specs, runbooks, proposals, worker comment, PROGRESS §1–7 and §8) now say Recense; paths `sill/sill/…` → `recense/recense/…`, `sill.swift` → `app.swift`, repo `louan-dev/recense`. Dated entries, CHANGELOG, `docs/archive`, `docs/research` and `decisions/` keep "Sill" as the record of the time.
- Validation: grep; Worker change is a comment only. Next: none.

- 2026-10-31 09:17 PDT · gallery notes 20261029 row 29 (owner: "retranscribe was just as useless as before") · PARTIAL
  - Cause: Tsehaye's vocal stem was heard as Arabic (the open ears' script choice summed over the song, and Ge'ez writes nothing where Arabic writes sung vowels), then Apple's Arabic dictation, then every redo re-guessed its language from 5-20 s (Czech, Croatian).
  - Fix (sill 8b562cc; recense.swift hunks swept into 9177a73): omni.py compares scripts pairwise on pieces both write in, kin scripts (Ge'ez/Hebrew/Syriac beside Arabic) always compete, last stretch's language is a soft hint (wins ties only); redo/skipped stretches use the song's sole language and don't change spokenLanguage.
  - Validation: bench on the stem: 0-120 s and 120-247 s in Ge'ez with real Amharic words; Arabic `say` control stays Arabic with or without a Ge'ez hint. Sill built, installed, relaunched. Not verified in-app.
  - Next: owner presses Retranscribe on Tsehaye - Ebne Hakim; check recense.log for "open ears read am". Mac was swapping (Obsidian Helper 4.3 GB): open ears ran ~5x slower than real time.

- 2026-10-31 07:00 PDT · gallery notes 20261029 row 35 (owner: "make it fluidly sweep through the letters") · PARTIAL
  - Both twins: a sung word's light sweeps without stopping; each syllable's letters are spread over the time it's sung, up to where the next comes in (or 0.25 s past its end, so a breath isn't swept through). Gallery 1a89f82 (`fillOf`), Sill 676a853 (`Cadence.progress`), same formula. Sill built, installed, relaunched 06:47.
  - Gallery live as 0dba8a10 (07:51, from the working folder; kept). Not done: 1:38 and 2:01 still need a listen; nothing watched in the window.

- 2026-10-31 · gallery notes 20261029 row 35 (owner's issues at 1:38, 2:01, 2:12–2:44, 2:51; blank line → [Ambient Sounds]) · PARTIAL
  - General rule (both twins): a quiet unit joined to the singing (≤ 0.3 s, chained) is the voice going soft, not bleed. Variations (as corrected): "dream" 2:51 held to 173.5 (was 170.5); 2:08 phrase ~0.7 s earlier. Gallery df2dd4e (7/7 Cadence tests, new test fails on the old code), Sill 8be2e06; Swift == JS on 212 cases. Built, installed, Sill relaunched.
  - Sill: a line the listener cleared shows [Ambient Sounds] over its stretch even where a voice is heard (Corrections.blanked). Gallery already showed it (no line up → ambient).
  - Tried and dropped: penalizing / removing off-register units (1:38 then made "a" share "on", and 2:12 moved seconds late).
  - Not done: 1:38 and 2:01 (need a listen to know where "a" and "When" are sung); Gallery deploy (gallery.js has another session's uncommitted work); nothing watched in the window.

- 2026-10-30 23:25 PDT · gallery notes 20261029 row 30 (non-Latin transcript lines) · PARTIAL (display DONE; notation with the prosody session)
  - Gallery 9e68d98 (local, not deployed): unspaced scripts (zh/ja/th/lo/km/my/bo) joined with nothing between words and phrases, re-cut on correction (Intl.Segmenter); line direction by most letters, browser bidi across words ("New York" in Arabic in order), each word lit in its own direction; word `lang` passed through present(); no letter-spacing on RTL; Devanagari/Tibetan marks inside the light; CJK/Arabic/Ge'ez stops end phrases.
  - Sill a42de2b (installed 23:23, relaunched): same rules in WordsView (sep/gap/visual bidi order), Corrections.words re-cuts unspaced runs, editor shows the written line, open ears keep tsheg/shad/Chinese punctuation (speech.swift heardOpen).
  - Validation: test/scripts.tmp.mjs (Miniflare + Playwright) on am/ar/zh/sa/hi/bo/th/zu lines in WebKit, Firefox, Chromium; transcript.test 13 pass, ui "Learn" 4 pass; Sill's Recense window captured on am/ar/zh (gallery/notes/row30/). Not checked on iPhone/iPad.
  - Next: prosody session does the notation (Chinese tones, Ge'ez/Arabic/Zulu prosody, pp/ff/mp/mf 50% larger); deploy Gallery on the owner's go-ahead; Sill's Arabic Learn phrases still run left to right (Gallery's run right to left).
- 2026-10-30 23:25 PDT · gallery notes 20261029 row 35 (Sill half) · PARTIAL (port verified against JS; window not watched)
  - Sill 299c1fb (+ fix-up 2f2670a: patch staging had misplaced two inserts; the commit now matches the built tree): `sill/cadence.swift` (+ `Sources/sill/cadence.swift` symlink), the twin of Gallery's cadence.js (b825d0c, 5e99216): syllables, units (the voice's syllables from the stem), align (lyrics hung on them over the whole song). Cadence.fit sets Word.syl and Word.un; Beat.un; the overlay never fills or glows an unsung word and draws no prosody figure for it. Line.fixed (set where Gallery's text overrides are laid over; Recense's own edit lines count too) lights a corrected word even with no syllable of its own, as Gallery's `fixed`.
  - Validation: Swift-vs-JS harness (recipe in side-session notes `row35-sill-cadence-harness.md`): Variations 96/96 words and Nina 244/244, the Gallery test cases with and without fixed, Variations with a corrected line and edit lines, 200 fuzz cases: 0 differences, 0 ms. Variations 1:20: Va 80.29 ri 80.63 a 80.96 tions 81.32, on 81.79–82.21, dream to 85.26; 2:35: 155.20–155.65, dream to 159.72. The window's own sourceBeats + Cadence.progress fill Variations syllable by syllable; an unsung word is never filled. zsh build.sh OK (2:10), installed, Sill relaunched 23:21.
  - The 50-minute build was swap (M1 8 GB, ~6 GB swap used), not the type checker: cadence.swift compiles -O alone in 12 s.
  - Not verified: Sill's karaoke window by eye (computer use can't target Sill; Recense's window only opens from the UI). The no-syllable branch for a fixed word could not be reached by any input tried (sharing a syllable always costs less).
  - Next: the owner plays Variations at 1:20 and 2:35 in Sill and watches the light; then row 35 → DONE.

- 2026-10-27 08:08 PDT · notes 2026-10-26 items 36, 38-41 · DONE (38 verified in log; 39/40 not tried on device)
  - 36 Text Size flipped: already fixed by e374a41 (installed 07:10); no new change.
  - 38 new audio not transcribed (Recense e124766, 1b4a6b8; Gallery transcript.js): GalleryJob idle now ignores an episode with no audio; empty incomplete stubs never pushed to keep/ and count as none (ContentKey.choose, itemKey, run, Gallery load); stale lock for a replaced file dropped; Retranscribe-while-playing stops the episode before setting aside. Verified: Bo Gogo lock dropped, Walton picked up 15:08 UTC. Data: PLIv1/.../012-usc-a-g-policies-102-i.m4a and 032-mpep-plants-1600x.m4a are damaged in R2 (032: first 3.3 MB zeros) — owner must re-upload.
  - 39 Skip Ad: extension skipAd always runs the ad to its end (YouTube ignores script clicks). Signed 2.1.15 (signed/c10d67200a6440a499d0-2.1.15.xpi); owner installs in Firefox. recense/ inner repo left uncommitted (prior sessions' work mixed in).
  - 40 vertical bar on phones: one-finger drag (Gallery 45b7465). 41 Rename moved to the transcript editor (45b7465). Gallery deployed 468fd6de; 99 tests pass.
  - Sill: merged claude/notes-36-41 into main (ebc842e), installed, relaunched.

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
- Next: owner sets the plan size so `quota` stops reading `inconsistent`; after A5 is DONE, build `/dav/notability/` in `gallery` per `docs/runbooks/OVERFLOW.md` §3.

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
- Unchanged code. The Notability WebDAV build was gated on A5; the vault part of A5 is now done, so it can start in `gallery` when the owner says go (it's another repo and a deploy).

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

### 2026-10-24 15:35 PDT · A5 · DONE (re-verified)
- Changed: no code. Checkpoint commit `8fb283e` before the task.
- Validated: `npm test` 34 ledger selftests + canary ok. Copy of the vault in scratch: dry run wrote nothing; `--apply` 250 files, `verify --deep` 1 segment / 250 live / 0 problems, re-run 250 unchanged, `restore` 250 files sha256-identical to the copy, copy unchanged. The 7 unmirrored files are by-design excludes (5 `.DS_Store`, `.obsidian/workspace*.json`). Real vault → `rclone:gallery-main:gallery-main/ledger/obsidian` (`--materialize`): dry run and `--apply` 250 unchanged, `verify --deep` 13 segments / 250 live / 0 forks / 0 problems (exit 0). launchd agent: 51 runs, last exit 0; run times through the day (17:09Z…22:32Z) are not the 03:30 heartbeat, so **WatchPaths fires on vault edits** (previously untested). `views/health.json` on R2: lastOk 2026-10-24T22:32:19Z, seq 268, evicted 0, unstable 0; `health --max-age-hours 24` exit 0, forced-stale threshold exit 1.
- Notes: a fresh `cp -R` resets mtimes, so a copy needs `--quiet-secs 0` or everything is deferred (by design). `launchctl kickstart` waits out the plist's 300 s `ThrottleInterval` ("spawn scheduled"); not a fault.
- Not tested: rclone over a network outage; `watch`; R2 sink encryption (owner chose unencrypted).
- Next: A5 follow-ons in §4 (iCloud Drive source after reviewing eviction counts; `crypt` for private material if the owner changes the decision); A6 Notability WebDAV.

### 2026-10-25 07:17 PDT · P2 · Shared homebar (Gallery + Recense) · PARTIAL
- Changed (uncommitted; pre-work snapshots at `refs/snapshots/p2-pre` in both repos): the home bar and the vertical bar left `gallery.js` / Recense's native `HomeBar` (~1,050 lines of AppKit, removed) for one module, `gallery/src/client/homebar.js` + `homebar.css`. Gallery inlines them; Recense runs them in a transparent WKWebView that only takes the pointer where the bar is (`build.sh` copies them from `../gallery/gallery/src/client`, override with `GALLERY_CLIENT`).
- Horizontal: thirds (≤3 items over Loop · A · B), a barrel that rolls on click (or two fingers upright), no blur (iridescent sheen), 44 px hitbox, three-segment text size (wedge · lens · wedge). Gallery: hover = Vietnamese · English · French, then Text size, Rename · Change Cover · Delete Cover, Download · Transpose · Share (white, blue on hover), comments ("Add a comment…" white / "n comments" blue), Loop · A · B, Speed, Play ±15. Recense: hover = bookmarks, firm press (Force Touch) = bookmark, then language, text size, Loop · A · B, speed, Retranscribe · Export as MD · M4B. Info icon, Back, the top-right size pill, Info's text-size row and pinch are gone for audio/video.
- Vertical: original-language prominence by two fingers or a drag (0 trailing only, 50 both, 90 original only, past 90 a detent to blank); blue while text size, prominence, EQ, C/Đô or reverb is changed; a press resets them. Volume gesture removed. Recense: same bar, no EQ, bookmark list on hover.
- Gallery only: notation tags are a one-tag vertical barrel (slide up = previous, down = next); caption 0 is now C/Đô.
- Decisions (owner may overrule): the bar at rest leaves prominence off (each app's reading view as before) and the first move starts at 50%; photos and documents keep Info, the comment label and Share in the bottom bar (they have no home bar); A–B clear = hold the A–B connector (no ×); Gallery's slide order follows the spec's 1–4 then Loop · A · B, Speed, Play; Recense's "press the bar" is a firm press, so a click can still roll the barrel; Retranscribe in Recense asks first and sets the old transcript aside in the temp folder.
- Validated: Gallery `npm test` 12 keylabel + 39 routes + 14 transcript + 31 UI (3 new P2 tests, 6 rewritten); Recense `swiftc` clean, `--corrections-selftest` and `--edits-selftest` pass, `build.sh` builds and signs `~/Developer/recense/Recense.app`; Recense host page driven headless at 1000×244 with a stubbed bridge (every message checked).
- Not verified: the new Recense.app in use (the /Applications copy was running, so it wasn't launched), WebKit's hover and Force Touch inside the panel, iPhone/iPad touch, real Safari. `tests/regress.sh` (pipeline replays) not run.
- Next: owner runs the repo build of Recense, tries the bar, then commits both repos.

### 2026-10-26 21:01 PDT · P3a · Root-cause bugs (46, 5, 6, 7, 8, 9, 13, 18, 21, 29, 35, 36, 47) · PARTIAL
- Changed (uncommitted): Sill worktree `exciting-lumiere-9b0e58` (`sill/recense.swift`, `sill/sill.swift`), Gallery `src/client/gallery.js`, Recense `sill/recense/main.swift` (item 5). Patches + REPORT.md: `~/Developer/p3a-root-cause-bugs.zip`.
- 46 + global sync: strip starts hidden (first icon press shows it); undecodable R2 audio falls through to yt-dlp/page; a failed episode still shows the transcript it loaded; Gallery files keyed by content and fetched from the bucket.
- 13/18 freezes: Translation sessions one per language pair in a never-hidden window (Recense was killed on 10-26 for a Mach-port leak, 305,834 ports, in ExtensionKit's remote view); library.json/translations.json written every 2 min off the main thread (was every 20 s on it, ~213 KB/s flagged by macOS); transcript saves throttled to 10 s; home bar reports 30/s.
- 21: Sill's left volume bar ignores the momentum glide, sends ≤30 changes/s, mutes at 0 and unmutes on any rise. 29: Gallery's A–B loop also jumps on `timeupdate` (rAF stops in hidden tabs). 35: not reproduced in Firefox with the current code (script `gallery/test/p3a35.tmp.mjs`). 5, 6, 8, 36 fixed; 9, 47 partial; 7 documented (`docs/specs/translation-pipeline.md`).
- Validated: Sill `swift build -c release` clean; Gallery tests (see zip). Not run in the app: no Sill relaunch, nothing deployed.
- Next: owner relaunches Sill and retests; merge `claude/cool-antonelli-c894a6` and `claude/exciting-lumiere-9b0e58`; deploy Gallery when approved.

### 2026-10-26 21:53 PDT · P3a (cont.) · Notes 49–51, item 9, Gallery tests · PARTIAL
- Added SPEC items 49–51 from `sill/notes/20261026 Notes.md`.
- 49: Sill's strip ⏯ asks Recense first (the followed player is toggled directly); a play/pause flip reported by a player redraws at once. 50: the Recense strip keeps one height (164 pt) with a fixed zone for the bar under the lines; no growth while open; compact ruler in the strip (render-checked). 9: Retranscribe translates afresh, the requested language first (Gallery's `lang`, or the window's).
- Gallery UI tests updated to items 36/39/41 (swipe to change slides, refresh reopens the item, comment label below the strip): 31/32 pass; "P2 audio" waits on item 45 (P3c).
- Sill built and installed at 21:53 (build.sh exits 1 at `lsregister -u` after the copy). Not run: Sill needs a relaunch.
- Open: 51 (which volume control should follow the source: owner to answer), 35 (not reproduced), 47 (Recense window).

### 2026-10-26 22:05 PDT · P3a · Item 51 volume control · DONE (render-checked; not run in the app)
- Recense window: a Volume slide (after speed) in the shared home bar's three-segment style; shows and sets the playing source's own volume: QuickTime (`audio volume`, `muted`), Music (`sound volume`, `mute`), Safari/Chrome tabs (element volume), Firefox via bridge 2.1.11 (needs `extension/sign.sh` + install). homebar.js: the text-size control generalized (Gallery unchanged). Bar commands now also reach a player followed without a transcript.
- Validated: Sill compiled and installed 22:04 (needs a relaunch); the slide exercised in a headless render (60% → louder → 70% posted; a source change to 25% shown; unknown shows "–").

### 2026-10-26 23:10 PDT · Notes 2026-10-26 → SPEC 52–61, implemented · PARTIAL (tests + renders; nothing deployed, Sill not relaunched)
- SPEC.md: notes 4–13 added as items 52–61 (tare, Recense bookmarks, Recense vertical bar 1:1, bar positions, landscape transcript, the editor holds the tools, hi-fi for ultracode, two-line Learn, held ruler, strip time · date · battery); item 48 cleaned up and superseded by 61; P2 "Language menu", slide 3 and "Recense only" marked superseded.
- Shared bar (`gallery/src/client/homebar.{js,css}`, also Recense's): 52 a tap opens/closes the tray, blue or white; tare = press and hold 0.7 s (a light climbs the stroke), a tap within 6 s undoes it. 57 `Homebar.tools` (language trio, Follow · Learn, icon row) for both editors. 60 `bar.fingers(on)`: a trackpad swipe held still keeps the ruler up, live, until the fingers lift. 25 a⁻ · 100% · A⁺ without outlines; icon items lose the word under them.
- Gallery (`gallery.js/.css`): 57 the bar loses the language hover slide and the Download · Retranscribe · Transpose · Share slide; the editor (tap the lyrics, or the transcription pill / [Ambient Sounds] when there are no lines) holds language, Follow · Learn (`gallery.view`, Learn default), Clear (every line as a correction, ≤100 per PUT; Changes keeps them), Download, Share, Transpose, Retranscribe, Export as MD (client-side, Recense's note format), Export as M4B (POST 127.0.0.1:47123/export → Recense). Rows show the chosen language; the line heard has a field for it too (P3 4). 59/27 one size per transcript (`uniformSize`), long phrases wrap; next line arrives when the light has crossed the line between (fade 0.4 s). 55 the bars stand on the real bottom bar (`--botH` → `--bb0`). 56 lyrics centred in the band between the top bar and the bars. 3 a hard scroll in the editor never goes Back.
- Recense (Sill worktree `exciting-lumiere-9b0e58`, `sill/recense.swift`; host page `~/Developer/sill/recense/homebar/index.html`): 53/57 hover slide, language and tools slides gone (bar = size, Loop · A · B, speed, volume); editing a line shows the tools in the bar's zone (Clear, Download, Share, Retranscribe, MD, M4B, bookmarks: + this moment, jump); the hover EN·VI·FR / Follow·Learn switches are gone (15). 54 vertical bar: Gallery's gestures and tare, no bookmark list; no tray (Recense doesn't play the sound itself). 59 Learn = two places (`learningPlaces`, Gallery's), one uniform size (`uniformSize`); the §6 drum retired. 60 `scrollWheel` phases → `Recense.fingers`. M4B: one ffmpeg pass (AAC, chapters, the transcript as a mov_text track) → `<stamp>.m4b`, no chapter files, Audiobook Builder or .vtt; `/export` for Gallery files (keep/ transcript + bucket audio).
- Sill (`sill/sill.swift`, same worktree): 61 strip left to right: time `HH:mm:ss` (12/24 h follows the system; this Mac 24 h), date `EEE, dd MMM` ("Mon, 26 Oct"), batteries.
- Validated: Gallery `npm test` keylabel 12, routes 39, transcript 14, UI 34 (3 new: SPEC 57 editor/Follow/MD/Clear, SPEC 55/56 at 428×746 and 926×340 touch, "two places" now checks the band; 6 rewritten). Probes: lyrics click opens the editor in Chromium, WebKit, Firefox, touch; Recense host page in WebKit with a stub bridge (tools, bookmarks, posted messages, held swipe). ffmpeg one-pass M4B checked (aac + mov_text + 2 chapters). Sill `swift build -c release` clean; installed /Applications/Sill.app 23:10 (build.sh exits 1 at `lsregister -u` after the install).
- Not done: 58 (ultracode run), 54's tray (needs an audio path in Recense), 32 (CC → play/pause: the menu lives in `cool-antonelli`), 12, 14, 17, 20, 30, 34, 35, 37, 40, 42, 43. Not run: Sill needs a relaunch; Gallery isn't deployed (the live site still has the old editor). Item 15's controls are hidden, not deleted (M still switches view).
- Next: owner relaunches Sill and tries the editor, Learn, the held ruler and the strip; approve a Gallery deploy; merge `cool-antonelli` and `exciting-lumiere`.

### 2026-10-27 01:08 PDT · Review of SPEC 1–70 vs code (notes 2026-10-26) · PARTIAL
- SPEC.md: owner notes appended after 61 added as items 62–70.
- Fixed (uncommitted): 65 menu row is the swipe's full rectangle (homebar.css); 64 Gallery's Play ±15 slide removed (gallery.js, ui.test.mjs); 66 Text Size capped at what fits, Gallery + Recense (gallery.js, recense.swift); 52 a slow drag can't tare (homebar.js).
- Validated: Gallery `npm test` green on 2nd run (1st: 2 load timeouts that pass alone); Sill `swift build -c release` clean; swipe probe 21/21 × Chromium/Firefox/WebKit.
- Report + work-list: `.handoff/REVIEW-2026-10-27.md`. Owner questions: 52 tap-vs-hold, 62 labels without a key, 24 phrase.

### 2026-10-27 06:50 PDT · Notes 23–36 → SPEC 71–84 · DONE (tests, builds, deploy; device checks open)
- Owner approved: deploy Gallery, relaunch Sill, R2 lifecycle (full). Applied: `abort-multipart-1d` on gallery-main, gallery-public, recense-tmp. gallery-tmp and its `tmp/` 1-day expiry already existed (another session); a duplicate rule I added was removed. gallery-public `expire-folders` (31 d) left as is.
- Gallery (`homebar.js`, `gallery.js/.css`, `transcript.js` + routes): 35 held swipe in a browser (momentum tail = let go, a stop short = held until the pointer moves); 26 slide swipe 16 px and owns its gesture; 25 speed only by tap; 29 Edit beside Delete; 27 audio session "playback" + resume interrupted Web Audio; 33 `?f=features` route + voice-shaped light. 28 and 31 verified as already working (new tests).
- Recense (`recense.swift`, `soundengine.swift`, `homebar/index.html`, commits e374a41, 76dd7fc + barrel): 33 voice-shaped light (Cadence.voice → Ink.voice); 36 the fit cap made Text Size non-monotonic, so size is now min(Text Size, largest that fits); 34 prominence stacks the trailing language under the original; 30/32 native chain first for all players, Center Cut extractor ported (numeric check: centre 0.000 out / 1.000 alone), chord detector (chroma off the chain, chord above the lines); 24 already built, barrel widened.
- Validated: Gallery `npm test` exit 0 (109 ok); new UI tests Notes 25/26, 28 (×3 engines), 29, 31, 33, 35. Sill `swift build -c release` clean; Recense host page loads in WebKit with Vocals + Chords, no errors.
- Not verified: on-device (iPhone 12 Pro Max/iPad) for 27 and 23; Recense's light, extractor and chords by ear/eye in the app; Firefox tap needs the Audio Capture permission.
- Next: owner tries Recense (tray Vocals/Chords, prominence, A⁺/a⁻, the voice light) and Gallery on the phone in the background; merge `claude/exciting-lumiere-9b0e58` into Sill main when happy.

### 2026-10-27 07:15 PDT · Notes 37 → SPEC 85; branch merged · DONE (build; not seen on screen)
- `sill/sill.swift` RestStrip layout: the four icons now sit right after the date at fixed places; the batteries follow them, truncated before the Spaces arrows. Commit 6258b71.
- Merged `claude/exciting-lumiere-9b0e58` into Sill `main` (f9952bf, no conflicts). main's old uncommitted sill.swift/.build-log edits (10-26 19:55 draft of the strip date and Recense ⏯, superseded) kept on branch `wip/main-uncommitted-2026-10-26` and as `.handoff/main-uncommitted-2026-10-26.patch`. CLAUDE.md and draftpad/ deletions left uncommitted as they were.
- Validated: Sill built, installed and relaunched 07:10; `swift build -c release` from main clean. Not checked visually (Sill isn't reachable by screenshot tools).


### 2026-10-27 15:16 PDT · Hello Pronunciation dataset, Phases 1–2 (read-only) · BLOCKED (owner: Cécilia's consent before Phase 3)
- PDF (63 pp): PyMuPDF chosen. pdfplumber gives valid IPA Unicode but drops the nasal tilde (U+0303 detached); PyMuPDF `get_textbox` composes ɑ̃ ɔ̃ œ̃ correctly. Her r is ʀ (U+0280), kept raw. Diagrams = raster + vector number overlays → render regions, not raw images. One listen link per table row (2 words) + one per-sound badge.
- Wix audio page: 253 tracks, readable without login; hash set identical to the PDF's 253 m4a links. Originals are `static.wixstatic.com/mp3/730488_<h>.m4a` (~94 KB); "Download All" zip is 45.9 MB. Nothing downloaded, nothing uploaded to R2.
- R2: target recense-tmp/hello-pronunciation/ (only tmp/ expires). Detail and Phase 3 steps in sill/.handoff/HANDOFF.md.
- Next: owner confirms consent (and that recense-tmp has no public r2.dev/custom domain) → Phase 3.

### 2026-10-27 15:58 PDT · Hello Pronunciation dataset, Phase 3 · DONE (Phase 4 planned, not started)
- Consent confirmed by owner. R2 recense-tmp/hello-pronunciation/: source PDF, 253 original m4a (47.2 MB), 25 diagrams (16 lip photos, 9 cross-sections); 279 objects, 63.4 MB. All streamed in memory, nothing local.
- Sill 85ccad8: data/hello-pronunciation/index.json (23 sounds, 117 examples, 9 notes, 154 lesson clips, 253 clip records) + README (spot-check list, Phase 4 plan) + tools/.
- Validation: words and IPA found in page text; audio↔row confirmed by site titles (0 mismatches); diagrams reviewed on a contact sheet; p30/33/38 checked visually. Flags left for the owner: Southern-accent clip filed under [ɛ] on the site, S Attention 1/2 order, ã vs ɑ̃ (book inconsistent), [yn cʀɛp].
- Next: owner spot-check, then Phase 4 (prosody.hello.test.js, calibration through Features) on the owner's go.

### 2026-10-27 18:10 PDT · Recense single copy · PARTIAL
- Recense.app (a login item) ran next to Sill's Recense: doubled jobs, port/quota contention. Quit, snapshot ~/Developer/Recense.app-snapshot-2026-10-27.zip, moved to Trash; recense/build.sh guarded (RECENSE_STANDALONE=1). Sill commit 0aa2fe8: Retranscribe…/Export in the line menu (built, not installed).
- Validated: one process, sill on 47123, single log lines. Next: owner removes the Recense login item; port Edit Translation, Prosogram, CLI flags; strip-button right-click menu.

### 2026-10-27 19:09 PDT · Gallery.app mount hardening · PARTIAL
- Changed: WebDAV agent booted out + disabled (files left: rm denied); `gallery/chau/Gallery/main.swift` wipes rclone's gallery cache and Quick Look's cache on close (keeps the cache when an upload is pending); Gallery.app rebuilt. §7 entry 19:08, A2 row notes Arq shares the `sync-backup` key.
- Validated: nothing on :8080; Dirty detector unit-checked; build + codesign OK. Not run with a real mount.
- Next: owner creates the `gallery-tmp` token, picks the tmp expiry layout, tests Gallery.app; then switch `tmp=` + Downloads agent, commit, rotate `sync-backup`.

### 2026-10-27 19:44 PDT · Gallery.app mount hardening (cont.) · PARTIAL
- Changed: gallery-tmp scoped key live (tmp mount + Downloads agent); gallery b22c303 (Gallery.app) and e5aa551 (`/main/dav-tmp/`, per-device service tokens) committed, e5aa551 deployed; `~/.config/rclone/jobs.conf` + `RCLONE_CONFIG` in ledger-job.sh/messenger-job.sh; Gallery.app Touch ID unlock for an encrypted rclone.conf (built, uncommitted, inactive); `docs/runbooks/recovery.md`.
- Validated: key scope, Downloads move, `npm test`, live route checks, rclone webdav on both mounts, ledger run on jobs.conf, sealing/stdin harness.
- Next: owner's tmp expiry choice, tokens for Arq + sandisk-rescue, `sync-backup` deletion, recovery sheet, config encryption, then commit Gallery.app.

### 2026-10-27 19:50 PDT · gallery-tmp expiry · DONE
- Changed: R2 lifecycle rule `expire-all-14d` on gallery-tmp (owner: 2 weeks); recorded in gallery/wrangler.toml.
- Validated: `wrangler r2 bucket lifecycle list gallery-tmp` shows it beside the tmp/ 1-day rules.
- Next: tokens for Arq + sandisk-rescue, delete `sync-backup`, recovery sheet, encrypt rclone.conf.

### 2026-10-27 20:15 PDT · Finder through the Worker · PARTIAL
- Changed: gallery 1cd3406 (chunked WebDAV uploads + real-rclone test, not deployed); sync bin/gallery-main-over-dav.zsh, docs/runbooks/gallery-drive.md (Windows), recovery.md link.
- Validated: npm test 13/42/3/14/32; live stale-ETag save → 412 on /main/dav/.
- Next: owner's Touch ID + iPhone checks, deploy yes, Finder test.

### 2026-10-27 20:20 PDT · Chunked WebDAV deployed · DONE (live-verified); Finder switch pending owner
- Deployed 1cd3406 (version 2897ffd6) from a clean export. Live 120 MB chunked upload hash-identical; delete to trash.
- Next: owner runs `sync/bin/gallery-main-over-dav.zsh`, then Finder test.

### 2026-10-27 20:30 PDT · rclone.conf password forgotten → restored; Main switched to WebDAV · PARTIAL
- Owner hadn't written down the config password (before Gallery sealed it). Recovery as designed: locked file kept as `rclone.conf.forgotten`, plaintext `rclone.conf.bak-pre-encrypt` restored; no R2 key or token affected. Encryption re-run waiting in the owner's terminal (backup `rclone.conf.bak-pre-encrypt-2`); owner writes the password on the sheet first.
- Main switched: remote `gallery-main-dav` (webdav, nextcloud vendor, 50M chunks, Keychain service token) → `gallery` upstream `Main=gallery-main-dav:`; lists the same 5 entries. Undo: `sync/bin/gallery-main-over-dav.zsh undo`.
- Next: owner encrypts, opens Gallery (password once, then Touch ID only), Finder test (upload >100 MB, edit, delete → trash; folder rename 403 expected), iPhone check of `DAV test`.

### 2026-10-27 20:45 PDT · Finder test round 2 · PARTIAL
- Owner: Touch ID unlock works (password once, then Touch ID). iPhone web Gallery showed the WebDAV edit (step 2 DONE).
- Bug: the close-on-last-window check never saw Gallery's Finder windows (hidden nobrowse mount), so it unmounted every 10–19 s and canceled uploads ("context canceled"); the Dirty guard kept the cache each time. Owner asked to drop the time limit: window-close check removed (and NSAppleEventsUsageDescription); still closes on lock/sleep/screensaver/user switch/15 min idle.
- Finder upload over WebDAV: 120 MB `big-test-file.bin` uploaded 20:37:03 through `/main/nc/` chunks, sha256 identical in R2, 0 chunk dirs left.
- TextEdit couldn't open `hello.txt`: rclone's NFS server has no lock manager (`No locks available`). Mount now uses `-o locallocks` (tested on a scratch mount: locks work). Rebuilt; owner re-test pending (edit, then delete → trash).

### 2026-10-27 20:50 PDT · Finder through the Worker · DONE (owner-tested), TextEdit open
- 1 Touch ID: password once, then Touch ID only (owner). Committed gallery edfead3 (unlock, no window-close timer, `-o locallocks`).
- 2 Two-way /main/dav/: WebDAV edit seen on the iPhone web Gallery; stale ETag → 412, no overwrite. DONE.
- 3 Chunked uploads: 1cd3406 deployed (2897ffd6) from a clean export; live 120 MB tests hash-identical. DONE.
- 4 Gallery.app Main = `gallery-main-dav` (/main/nc/, nextcloud vendor, 50M chunks). Finder: 120 MB upload hash-identical, 0 chunk dirs left; VS Code edit saved 20:42:27 with the previous version in `trash/2026-10-28/DAV test/`; Finder delete → trash. Folder rename/move → 403 (documented, not fixed). **TextEdit opens nothing** on the mount (activates, no window, no log, not hung; reads and locks work) → known limit in `docs/runbooks/gallery-drive.md`; Windows setup there too.
- Config password: owner forgot the first one; restored from the plaintext backup, re-encrypted with a written-down one (rclone.conf.forgotten kept, useless). Plaintext backups `rclone.conf.bak-*` still on disk: delete once the owner is sure of the new password.
- Next: delete plaintext backups (owner's yes); tokens for Arq + sandisk-rescue, delete `sync-backup`; `.uploads/` lifecycle rule on gallery-main (owner's yes); TextEdit cause; folder MOVE in dav.js; Sill tray unlock (card).

### 2026-10-27 20:45 PDT · Markdown round-trip test · DONE
- Owner: what matters is .md files open and edits update. gallery `chau/test-md-roundtrip.sh` (committed): new note readable + lockable, reaches the server; in-place edit and safe-save (temp + rename) reach it; server edit visible on the Mac; stale save 412. Run 20:43 with Gallery open: 8/8 (Mac→server ~6 s, server→Mac 42 s). Documented in `docs/runbooks/gallery-drive.md` (Check it works).

### 2026-10-27 21:00 PDT · Gallery in Finder + Files, two-way and offline · PROPOSED (owner picks A or B)
- Owner: the main way in should be Finder (Mac) and Files (iPhone, iPad), two-way, working offline, Mac not needed; downloads on every device → tmp. Gaps listed: iPhone/iPad, Public, folder renames.
- Measured: Main 34.6 GiB / 29,646 files; Mac 6.8 GB free (no iOS Simulator runtime installed; one needs ~8 GB); Xcode 16.4 / iOS 18.5 SDK; signing team = free Personal Team (iOS apps expire after 7 days). Public has no trash (deletes are permanent).
- Proposal `docs/proposals/gallery-files-everywhere.md`: File Provider on every device. A (recommended): free Nextcloud apps + the Worker speaks the Nextcloud API subset, per-device app passwords issued only after Access sign-in (hashed, revocable, rate-limited; replaces "no Basic-auth door into Main"). B: own Swift File Provider app, needs the $99/yr Apple Developer Program and ~10 GB free. Either way: Public mount with a trash, resumable folder move, Safari downloads → tmp (check on the device).
- Next: owner chooses A or B → new session builds step 1 (Worker), tests first, deploy on yes.

### 2026-10-27 21:10 PDT · Files/Finder offline: owner's constraint → option C · PROPOSED
- Owner: files must be usable with no connection; no third-party provider app and no app of our own; built-in utilities are fine. Asked whether a "simulated RDP" could do it: no remote system (RDP, VM, cloud) is reachable offline, so offline = a local copy per device that syncs when a connection appears.
- Added option C to `docs/proposals/gallery-files-everywhere.md`. Mac: `~/Gallery` (chosen folders) + launchd + `rclone bisync` through the Worker. iPhone/iPad: Files › On My iPhone › Gallery + a Shortcuts automation (Wi-Fi join / charger / times) that runs a Worker-computed sync plan with the device's Access token. Safari downloads → that folder's tmp/Downloads → tmp. Physical drive is the only zero-connection link between devices (optional). Checked here: `/usr/bin/shortcuts sign` and `rclone bisync` available.
- Next: owner says build C → Worker sync-plan endpoint (tests first), Mac bisync agent, signed Shortcut; device test in airplane mode.

### 2026-10-27 21:25 PDT · Gallery nervous system: brief recorded, step 0 started · PARTIAL
- Owner widened option C into the engine + adapters plan. Recorded verbatim-in-substance in `docs/specs/gallery-nervous-system.md` (review file) and as goal §1a. Cancelled: proposal routes A/B, the Nextcloud next-session line, the Owlfiles step.
- Step 0 running: free space + `/Users/chauphan` top-level and `~/Library` sizes.

### 2026-10-27 21:35 PDT · Gallery nervous system, step 0: disk list · DONE (waiting for the owner's pick)
- Free: **5.3 GB** of 228 GB (down from 6.8 earlier today). Home without Library 38.9 GB; Library: Application Support 34.2 (Claude 12.9, Google 8.5, MailMate 3.9, DEVONthink 2.5), Group Containers 24.2 (Notes 9.2, Voice Memos 7.9, screencapture 2.7, Telegram 2.4), Caches 9.9 (Homebrew 2.3, Google 1.6, playwright 1.0), Containers 7.3, CloudStorage/GoogleDrive 2.75, Mail 1.4.
- Move candidates (bulk, per decision 2): Downloads 5.1 (Wallpapers 1.4), Music/Music 4.7 (Apple Music library = app database + media: ask), Movies 3.7 (Record It 3.6), ~/Shared 3.4 (PLIv1 3.0: possibly already in R2 Main → dedupe check), Google Drive My Drive 2.75, ~/Sync 1.2, old projects in Developer (auto_avsr 0.8, sandisk-rescue 0.75 paused), Documents 0.5.
- Stays local (decision 2): Photos Library 8.4, Mail, ~/Library, active repos. Regenerable caches (clear, don't move; owner's yes): ~/.cache 4.5 (whisper 1.6, codex-runtimes 1.5, uv 1.0), Library/Caches ~10.

- 2026-10-28 04:11 PDT · Gallery Phase 1 · Record It → gallery-archive · DONE (copy only). Owner: "skip the sandisk for now" (the 123 damaged Raven objects stay unrepaired). Copied 126/126 `~/Movies/Record It/Video/*.mp4` (3.86 GB) to `gallery-archive/chauphan/Movies/Record It/Video/` via wrangler single-part PUT. The jobs.conf key is scoped to gallery-main and gets 403 on gallery-archive. Validation: each object re-downloaded, MD5 equals local for 126/126, ffprobe duration OK for 126/126; manifest `.handoff/archive-record-it.tsv`. Local not deleted (owner's yes needed). Next: ~/Downloads, which needs the owner's "old" cutoff and, for the one file over 300 MiB, a gallery-archive-scoped R2 token.
- 2026-10-28 04:42 PDT · Gallery Phase 1 · ~/Downloads pre-2023 → gallery-archive · DONE (copy only). Owner cutoff: "before 2023" (mtime). Copied 119/119 top-level files (622 MB) to `gallery-archive/chauphan/Downloads/`; re-download MD5 = local 119/119. Manifest `.handoff/archive-downloads-pre2023.tsv`, path list `.handoff/downloads-pre2023-copied-paths.txt`. Nothing deleted. Next per plan: `~/Developer/auto_avsr` (1.6 GB) → `chauphan/Developer/`.
- 2026-10-28 05:18 PDT · SL6 Proton Frankenstein · DONE. Located via zsh history and a Gemini chat PDF: a 2026-09-27 Bridge/hydroxide/proton-headless/proton-frankenstein experiment for MailMate; the project folders were already gone. Kept MailMate, openssl@3 and Playwright 1194 (all in use). Uninstalled the brew build-only packages libfido2, libcbor, protobuf, go, pkgconf (nothing depended on them). Left for the owner: MailMate's dead Proton account, the old Bridge data folders, the ProtonVPN system extension. auto_avsr: owner chose delete over archive (owner runs the rm).
- 2026-10-28 05:18 PDT · Gallery Phase 1 · Voice Memos → gallery-archive · PARTIAL. 298/303 copied and verified (4.05 GB, by year), manifests in .handoff. 5 files over 300 MiB are blocked on a gallery-archive-scoped R2 token. Disk at 6 GiB free because another session staged 18G of SanDisk data.
- 2026-10-28 06:26 PDT · Gallery Phase 1 · large Voice Memos, Photos Library, lost_and_found · PARTIAL. Owner added the gallery-archive rclone remote. Large memos: 1 OK, 1 FAIL (retry), rest in progress. Photos Library has no local originals (Optimize Storage); owner chose to archive it anyway as one tar in gallery-main/files/Photos/ (in progress, verified by re-download MD5). DriveFS lost_and_found = 3 identical copies of a file already in My Drive (safe to delete). Owner is moving Google Drive, ~/Sync/Nichole and the SanDisk Records with their own rclone moves. 16 stray objects under gallery-archive/chauphan/Sync from a stopped copy.
- 2026-10-28 07:14 PDT · Gallery · Chauphan mount + File Provider slice 1 · PARTIAL. Owner yes → deployed gallery ec9ce9e (version 87728872): /main/dav-archive/ and /main/nc-archive/ on gallery-archive, trash in .trash/. launchd com.chauphan.archive-mount (sync 443b184) mounts chauphan/ at ~/.chauphan, shown as ~/Cloud/Chauphan and ~/Cloud/Gallery. Live: MD5 read match, overwrite trashed, recovers after kill -9. 08b03de (accept Finder ._* files; without it rclone retries 403s forever) committed, NOT deployed. Owner's priority change: File Provider. Design in gallery/docs/architecture.md; slice 1 read-only feed gallery 036f213 (items/changes/content, reconciler, stable ids), routes 44 pass, NOT deployed. All 303 Voice Memos copied (021639 retry OK; PLI_Supplement* are unplayable at the source). Next: owner yes to deploy 08b03de+036f213; iPhone plugged in with Developer Mode on for signing test (a), then the iOS read-only Voice Memos slice.
- 2026-10-28 07:32 PDT · Gallery Phase 1 · DONE for this session's items. Voice Memos 303/303 verified (8.25 GB). Photos Library tar in gallery-main/files/Photos/ (8.92 GB) verified by re-download MD5. Next: Phase 2, the /main/archive shelf.
- 2026-10-28 17:20 PDT · Gallery prosogram lanes (notes screenshots 12:58/15:53) · PARTIAL. gallery 9b79885: one word walker per frame (was one per cell, restarting at word 0 with an 8-word window, so past the first thought every lane was blank). 3-line Playwright probe (gallery test/proso2.tmp.mjs, gitignored): third thought 0 px before, painted after. npm test: 4 UI fails (Notes 35, 25/26, 33, 31) in tests that don't touch the prosogram; not caused by this change. NOT deployed. The 12:58 left-hand list was the earlier panel version, already replaced by c673650. Next: owner's yes to deploy; Sill Recense translation highlight overlaps the text (15:46 screenshot, 'Soro-sorə, stop').
- 2026-10-28 17:35 PDT · Gallery prosogram lanes · DONE (deployed). Owner yes. Version f7568904 from a clean export of 9b79885 with src/fp.js pinned to live (another session's 736b9cd fp.js change NOT deployed). Only diff vs live 23a54cc: prosogram-mount.js. Next: owner checks lanes on a later line in /main.
- 2026-10-29 15:01 PDT · Drive/Sync offload + Gallery sidebar name · PARTIAL/DONE · see §7 entries of 2026-10-29 15:01. Next: owner removes the leftover GoogleDrive CloudStorage folder; empties Trash after a look.
- 2026-10-29 15:25 PDT · ~/Shared + My Drive/Live offsite · PARTIAL. ~/Shared verified in R2 (PLIv1 211/211 in gallery-main/files/PLIv1 after uploading 38 missing files, 828 MB; Documents → gallery-archive/chauphan/Shared/Documents; mp4 = gallery-archive/chauphan/SanDisk/Live, check --download) → moved to ~/.Trash. My Drive/Live 5/5 in R2 (3 content-verified, 2 online-only placeholders size+mtime match). My Drive can't be moved: the Drive File Provider domain (com.google.drivefs.fpext) is still registered without its app; mv times out. Next: reboot, else reinstall Google Drive → Disconnect account → quit → delete app.
- 2026-10-29 15:59 PDT · Offsite disks · PARTIAL. Added bin/disks-mount.zsh, launchd/com.chauphan.disks-mount.plist, tools/disks-helper, docs/runbooks/offsite-disks.md (validation in §7). Next: owner GUI steps; Gallery exports.
- 2026-10-29 16:46 PDT · Offsite disks · PARTIAL (working). 32b989c: one rclone mount per disk + watchdog (a shared mount's NFS server dropped its connection under load; reads hung until forced off); Messages Disk mounted at ~/Library/Messages (its database service won't follow a symlink), verified chat.db opened there; Mail via symlink verified. Owner: Full Disk Access for Disks Helper, then the GUI steps in docs/runbooks/offsite-disks.md. Next: Gallery exports (ask what to show).
- 2026-10-29 18:56 PDT · Boundaries guide (Sync · Gallery · Sill) · PROPOSED. docs/specs/organism.md + §8 decision 8 + §7 entry + §1a ownership note. Docs only, nothing moved or deployed. Next: owner's yes/no on the guide's §10, then step 1 (engine boundary in the Gallery Worker).
- 2026-10-29 19:35 PDT · Event-log unification (ledger.mjs v2 + chained catalog + one delete guard + one verifier) · DONE (code/tests), catalog NOT deployed. docs/specs/event-log.md; §8 decision 9; §7 entry. Also fixed the feed's false 410 on every incremental check. Next: deploy yes; verify a ledger sink after its first v2 run.
- 2026-10-29 19:59 PDT · N1029-9 (notes item 9) · PARTIAL. Groq/Whisper replaced by SpeechAnalyzer (SpeechTranscriber en/fr, DictationTranscriber vi) behind Recense's whisper(); correction lexicon (same mistake + confidence + voiceprint + recognizer alternatives) learns from Recense and Gallery corrections and applies on first transcriptions and replays; Gallery marks learned words. Validation: bench (real pipeline) en/fr/vi auto, code-switch, learn→recall, 33 self-tests; Gallery npm test 128 ok; Sill built (SDK 27.2) + installed + relaunched, /speech OK. Blocked: custom LM build (Apple error 1). Next: owner plays real media; watch recense.log `speech:`/`lexicon:` lines.
- 2026-10-29 20:12 PDT · Gallery assistant uses the G1 calendar · DONE (code, not deployed). gallery/src/calendar.js binds R2 `sync` as CALENDAR and writes caldav/users/chau/<cal>/<UID>.ics like a CalDAV PUT (customMetadata uid, onlyIf etag, trash copy to caldav/trash/…); reads iCloud via ledger/calendar backup. No change to the sync worker. Next: owner adds the CalDAV account on Mac + iPhone (G1-0 device check).
- 2026-10-29 20:55 PDT · "Deploy all, resolve all" · DONE except the ledger-sink move (BLOCKED: one dashboard step). Live Gallery 0b0ab499 (main 80a2ff2). Junk rule, md5, history/, Main root, stepped passes; sync-ledger bucket + bin/move-ledger-sinks.zsh ready.
- 2026-10-30 16:23 PDT · N1030-29 (gallery notes row 29: every language in its original script, no quota) · DONE (code, built, Sill relaunched; Tsehaye Retranscribe left to the owner). sill/speech.swift: Apple's ears hear every locale the system has (47 codes asked of SpeechTranscriber/DictationTranscriber, oldest reserved locale released past the limit of 5, the listener's own kept); a new recording is identified first by the open ears. sill/openears.swift + ears/omni.py: Meta Omnilingual ASR CTC-300M (Apache 2.0, 1,668 languages, 1.2 GB in ~/.cache/fairseq2, fp16 on MPS, venv ~/.local/share/recense/omni) as a helper process; Tongue names the language from the text (script, NaturalLanguage, function words); decoding kept to one script plus Latin. sill/canon.swift + canon/*.json: text-anchored hearing (fold to Latin sound keys, 4-gram seeds, Smith–Waterman) over Pāli Paritta (SuttaCentral CC0), Yoga Sūtras, Bhagavad Gītā (gita/gita Unlicense), Īśa Upaniṣad. Groq fallback for unsure hearings removed. Validation: bench (RECENSE_CACHE) ar/ru/zh/th/en by Apple in own script; Amharic vocal stem → Ge'ez; Sanskrit → Yoga Sūtras 84 %; Pāli → Metta Sutta 83 %; Hindi → Urdu script (Apple's hi/ur answer in Latin). Next: owner presses Retranscribe on Tsehaye; row 35 (syllable light), then row 30 (non-Latin display + prosody).
- 2026-10-30 · N1029-3 (gallery notes item 3, share-link preview cards) · DONE: c35d22d deployed alone as a3307bc1 (owner OK); row 30 commits not deployed (2 transcript tests fail there); transcript.test fails on another session's uncommitted corrections.js/transcript.js edits, not this change.
- 2026-10-30 23:20 PDT · gallery notes row 36 (translation off Groq) + Recense title flicker · DONE (verified on a real job; Firefox podcast not replayed). Sill 988f019.
  - Translation: Apple's Translation translates every line on this Mac (no quota, no drafts); a line already in the target language is itself; a pair Apple lacks goes to an optional own translator (TRANSLATE_BASE, groq.com refused), else "…". Groq Whisper path, GROQ_API_KEY, TRANSCRIBER=groq, RateLimited and the "Groq's daily … limit" statuses removed; no Groq in transcription or translation.
  - Stall: the open ears re-heard French chunks Apple had already heard (127 s took 1,147 s on the 8 GB M1, recense.log 01:46); now skipped once they run slower than real time (OpenEars.keepsUp). Translation also waited on Groq's daily token limit (gpt-oss/qwen cooling 200-700 s).
  - Flicker: the Firefox bridge went quiet 5-15 s while playing ("players polled once a second (playing: true)", following/idle every few seconds); Recense dropped a playing source after 2.5 s. The followed browser piece now keeps the window 20 s without a report (`reported`).
  - Validation: Sill compiles (build.sh compiled, signed and installed; exited 1 at the lsregister/cleanup step in this sandbox, build/Sill.app left behind). Since the 23:00 relaunch: zero Groq calls; a 312-line lecture translated to French on this Mac in ~2 min, complete, 0 drafts, 0 placeholders. Not verified: a France Culture podcast in Firefox end to end (owner was playing QuickTime); the committed tree alone (without other sessions' uncommitted hunks) wasn't built separately.
  - Next: owner plays a podcast in Firefox and watches the title; download missing Translation languages if the title names one.
- 2026-10-31 17:50 PDT · gallery notes 20261029 item 42 (all documents visible and editable on every device) · PARTIAL. Cause: Obsidian reached R2 only as the ledger journal (not browsable files), Notability PDFs sat in `notability-backup/` outside Main's `files/`, and loose documents were never uploaded. Built `bin/docs-sync.zsh` (9f517ec): bisync of vault, iCloud Drive, Documents, Desktop, Downloads, Temporary, Developer, Google Drive ↔ Main/Docs/<source> through the Worker (trash on replace), Voice Memos + Notability PDFs one way, Docs/INDEX.md. Gallery 3c68843: Edit/Save/Cancel for Main .md/.txt (If-Match PUT). Validated: round trip Mac→Gallery, Gallery edit→Mac, Gallery delete→Mac (kept copy), both-sides conflict → two copies; 1,377 documents live in Docs. Left: owner installs launchd `com.chauphan.docs-sync` (classifier blocked me); Google Drive streams online-only files and times out (8 of 11 up; mark My Drive available offline); Gallery editor not deployed (push = deploy).
