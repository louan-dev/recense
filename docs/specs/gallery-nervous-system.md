# Gallery · the nervous system for my files

> **For a new session:** read this file first, then `PROGRESS.md` §2 (Rules) and the newest Gallery entries in §7, then `~/Developer/gallery/.handoff/HANDOFF.md`. This file wins where they disagree. Owner's words, 2026-10-27 21:20 PDT; status updated as work lands (see "Status").

## The outcome (long-term goal)
My files are usable **with no connection** on the Mac, iPhone and iPad, in each device's native place (Finder; the Home Screen web app and Shortcuts on iOS; later the Files app). Edits flow both ways when a connection appears. **Nothing of mine has to run 24/7.** The Mac's disk is freed by moving bulk folders into R2, behind an always-on mount.

## What the Gallery is
My own code, not a service: a serverless **Cloudflare Worker** behind **Cloudflare Access**, with one service token per device. **R2 is the storage. This project is not storage: it's the nervous system.** The Worker decides; thin adapters carry its decisions to each device's native hook. Build decisions and wiring, never storage features.

It's four things:
1. **Catalog.** Every file and where it lives: an append-only change log per root, a monotonic cursor, a stable id per file, and a sync plan per device. It lives **in R2, not D1** (the other session owns D1).
2. **Rules.** tmp expires after 14 days; per-device size budgets; conflicts keep both copies; old versions go to trash; delete guards.
3. **One web interface (`/main`).** Every root (Gallery, Chauphan, the MacBook, future computers) in one place, where I pin, upload, move and share.
4. **Thin adapters**, one per device, plugging the engine into that device's native hook.

1 + 2 = **the sync engine**, in the Worker. 3 + 4 = connective tissue. *The engine decides, adapters obey.*

### Native hooks
| Device | Hook | State |
|---|---|---|
| Mac | NFS mount (`rclone nfsmount`) + launchd → Finder | mostly built (Gallery.app) |
| Mac, offline | `~/Gallery` pinned-folder adapter on the engine | to build (step 4) |
| iPhone / iPad | `/main` installed to the Home Screen (no app) + Shortcuts (share sheet → tmp) | to build (step 5) |
| iPhone / iPad Files app | File Provider: needs a signed app shell | **deferred**. Shape the engine API (cursor, plan, stable ids) so it slots in later as a thin adapter with no rework |
| Windows | rclone mount + WinFsp (online only) | runbook written (`docs/runbooks/gallery-drive.md`) |

## Engine invariants (build and test these; they're what makes it solid)
1. **Event log per root.** Every change (create, modify, delete, move) is an event with a monotonic cursor. Devices resume from their own cursor. Deletes are recorded, so an offline device can tell "deleted" from "never had it".
   *(2026-10-29: the format, chain and delete guard are shared with the ledger: `event-log.md`.)*
2. **Stable ids.** Every file has an id that survives rename and move; paths are just labels. That means no re-upload on rename, and it's what a File Provider needs.
3. **Based-on version.** Every write carries the version it was based on. A stale base is refused (412) and becomes a kept-both copy. Never a silent overwrite.
4. **Idempotent and resumable.** A retried upload, plan or move after a crash or dropped connection never duplicates or loses anything.
5. **Safety rails.**
   - A plan that would delete more than **10% of a root or more than 100 files** needs my confirmation (adjustable defaults).
   - Every plan has a **dry run**.
   - Everything deleted goes to trash, and **restore is tested**.
6. **Device registry.** Last seen, last cursor, free space, budget and pins per device, shown in `/main`.
7. **Convergence test (Miniflare).** Three simulated devices (Mac, iPhone, iPad) do random creates, edits, deletes and renames and go offline for random stretches: 1,000 operations per run, **50 seeds**, and the seed is printed on failure so it can be replayed. After each device's final sync:
   - all trees are identical;
   - no file ever written is lost (it's in the tree or in trash; tmp is excluded);
   - every conflict left both copies;
   - no plan went past the delete guard without confirmation.

## Decided (don't reopen)
1. **Two buckets, one Finder parent** (amended 2026-10-28; the "one R2 tree" half of this is superseded, the mount half stands). `chauphan/` lives in its **own bucket `gallery-archive`** — created 2026-10-28, chosen over a prefix inside `gallery-main` so it gets its own lifecycle rules and its own scoped token. Shelf `/main/archive`, mount `/main/dav-archive/`. Both buckets are private behind Access and shared between my devices, never public. `chauphan/` keeps **its own mount** (pattern: `dav-tmp`), outside Main's gallery folders.
2. **What moves out of `/Users/chauphan`.** Bulk only: Sync, Google Drive My Drive, media, old projects as archives. The old path becomes a **link into the mount**. **Stays local:** `~/Library`, `.ssh`, app databases, Photos, Mail, active repos and builds (one-way copy to R2, never edited through the mount).
3. **Mac: one parent folder in Finder** holding:
   - **Gallery:** Touch ID, wipes on lock, unchanged.
   - **Chauphan:** always on. launchd keeps it up and reconnects after sleep or Wi-Fi loss; no wipe on lock.

   Confirmed 2026-10-28 against the alternatives: a single always-on mount was rejected because it would discard
   Gallery.app's owner-tested Touch ID, Secure Enclave unseal and wipe-on-lock (`edfead3`) over 34.6 GiB of curated
   files that rooms and invites also reach; keeping today's single locked mount was rejected because every moved folder
   leaves a link into the mount, so a wipe on lock breaks `~/Movies`, `~/Downloads`, Google Drive and `~/Sync` every
   time the Mac locks. Two mounts match two sensitivities.

   The cache is on the internal disk: **2 GB to start, plus a minimum-free-space guard.** With two mounts that is two
   budgets: give the always-on archive the 2 GB and keep Gallery's smaller, since Gallery's is wiped on lock anyway.
   It must work **with the SanDisk unplugged**.
4. **Never delete a local original** without my yes after a restore test. Pause apps that watch a folder (Google Drive, Obsidian, DEVONthink) before moving it.
5. **Conflicts keep both; old versions to trash.** **tmp is shown, not synced:** devices push downloads into it, and I pull a file only when I pick it.

## Order (each step ends with a test I can run)
0. **Disk.** Free space and the sizes of `/Users/chauphan`'s top folders. Show me the list; **I pick what moves.**
1. **The always-on Chauphan mount.** Test: SanDisk unplugged; Wi-Fi off mid-copy; Finder must not freeze.
2. **First folder.**
   1. Copy, then `rclone check`.
   2. I open files through the mount and give my yes.
   3. Delete the local copy and put the link in its place.

   Then the rest, biggest first. **Report GB freed after each.**
3. **The engine** per the invariants: catalog in R2, change cursor, sync plan. Don't touch `invite.js` or `migrations/`. Write `gallery/docs/engine.md` next to the code. Test: invariant 7 passes on 50 seeds.
4. **Mac pinned-folder adapter** (`~/Gallery`, works offline) on the engine.
5. **iPhone/iPad:** `/main` as an installed web app.
   - It shows all roots, keeps pins for offline, and queues uploads until online.
   - A Shortcut on the share sheet sends to tmp.
   - On the device, check that Access login works inside the installed app and how long it lasts, and **report exactly what iOS refuses.**
3. **Last,** two things. First, folder rename through the mount (403 today). Second, the File Provider decision, starting with a signing test and no features: (a) a throwaway iOS app plus File Provider extension with the App Groups capability on my free Personal Team: does Xcode accept it? If not, report the exact error. (b) a throwaway macOS app plus extension with app group $(TeamIdentifierPrefix)group.gallery and no keychain group: does the domain show up in Finder? Then give me an estimate and your recommendation. If (a) works, the build is a Files-native provider with real create, modify and delete against the engine, using github.com/alexmodrono/Findle (Apache-2.0) as a reference for structure only. If (a) fails, the build is a small iOS app that mirrors my pinned folders into its own Documents folder so they show in Files. XcodeGen only if I say yes.

If something is impossible, name the wall (Apple rule, Cloudflare limit, disk) and build the nearest thing that works; don't stop at "not possible". If a step needs an app or an account, **stop and ask**. End each report with a table: every part of the vision, DONE or NOT, with proof.

## Build, don't install
- **Nothing new:** no Nextcloud, no third-party app, no new service or account, no marketing emails.
- **If it exists elsewhere:** when it's open source, lift only what we need from its source (check the license). Otherwise write down the exact feature and rebuild it ourselves, in the Worker or on the device. Never something that works only while the Mac is on.
- **Reuse first:** look in `gallery/` and `sync/` before writing anything, and list what was reused in the final table. Candidates: `dav.js` (mounts, `ownerMount`, chunked uploads, ETag/412, trash), `access.js` (per-device tokens), Gallery.app (mount, Touch ID, cache wipe, Secure Enclave unlock), `jobs.conf`, `ledger-job.sh`/`ledger.mjs` (hash-chained journal: a model for the event log), the `/main` UI, `chau/test-md-roundtrip.sh`, `test/dav-rclone.test.mjs`.
- **Plain code over dependencies;** name any you add.
- **Not a host:** RDP, VM, container or sandbox (none are always on).

## Cancelled (2026-10-27 21:20)
- `docs/proposals/gallery-files-everywhere.md`: routes **A** (Nextcloud apps / `nextcloud.js` / `nextcloudcmd`) and **B** (own app, $99) are cancelled. Option C is superseded and widened by this file.
- The Owlfiles step (read-only token on iPhone/iPad).
- HANDOFF.md's "Next session" line (Nextcloud build).

## Where things live
- **`~/Developer/gallery`:**
  - Worker: `gallery/src`, `gallery/test`, `wrangler.toml`.
  - Gallery.app: `gallery/chau/Gallery`.
  - Web interface: `gallery/src/client`, `/main`.
  - Engine doc: `gallery/docs/engine.md`, linked from PROGRESS.
- **`~/Developer/sync`:**
  - Mac jobs and launchd scripts: `bin/`.
  - Runbooks: `docs/runbooks/` (`gallery-drive.md`, `recovery.md`).
  - Proposals, this spec, PROGRESS.md (log every step), SPEC.md.
- **The Mac itself** (changes need my yes; a denied command → hand me the command): LaunchAgents, mounts, `~/.config/rclone` (encrypted `rclone.conf`, unencrypted `jobs.conf` with scoped keys only), `/Users/chauphan`.

## Standing rules
- **No push.** Deploy only with my yes, from a **`git archive` export of the commit**, never the working tree: another session's uncommitted files live in the gallery repo.
- **Other sessions' files:** don't touch `invite.js`, `migrations/`, D1, `client/gallery.js` and `test/ui.test.mjs` work-in-progress (the C0/D1 session). Commit only your own files.
- **Never print, log or commit secrets** (keys, tokens, passwords). Access tokens come from the Keychain (`gallery-access`) or `jobs.conf`.
- **Status labels:** DONE (verified) / PARTIAL / BLOCKED / PROPOSED. Each step gets a §7 entry in PROGRESS.md and a handoff bundle (owner's global CLAUDE.md).

## Facts (measured 2026-10-27)
- **Library:** Main is 34.6 GiB / 29,646 files.
- **Mac:**
  - 6.8 GB free on the internal disk.
  - Signing team: free Personal Team; iOS apps expire after 7 days.
  - Xcode 16.4, iOS 18.5 SDK, no iOS Simulator runtime (it needs about 8 GB).
- **Worker:**
  - Live version 2897ffd6 (gallery 1cd3406). `/main/dav/`, `/main/dav-tmp/`, `/main/nc/…` and `/main/nc-tmp/…` (chunked, rclone `vendor=nextcloud`).
  - `SERVICE_CLIENT_ID` is a comma list of device tokens.
  - Trash/versions on Main; tmp deletes for good.
  - Public has no trash yet.
- **Live tests:**
  - 120 MB through Finder, hash-identical.
  - Stale save → 412.
  - `chau/test-md-roundtrip.sh` 8/8: Mac → server ~6 s, server → Mac ~40 s.
  - Folder MOVE → 403.
  - TextEdit won't open files on the NFS mount (cause unknown; VS Code works).
- **Cloudflare walls:** 100 MB per request (solved by chunks); about 1,000 storage operations per request, so big folder moves must be resumable jobs; Workers CPU limits.
- **Apple walls:** the Files app's "Connect to Server" is SMB only, with no custom headers and no offline. The File Provider needs a signed app. A free team means 7-day expiry, and App Groups may be refused.

## Status
| Part | State | Proof |
|---|---|---|
| Worker + Access + per-device tokens | DONE | e5aa551 deployed; `SERVICE_CLIENT_ID` list tests |
| Chunked uploads > 100 MB | DONE | 1cd3406 live; 120 MB hash match |
| Trash / versions / 412 on Main | DONE | routes tests; live stale-save 412 |
| tmp mount + 14-day expiry | DONE | `/main/dav-tmp/`; lifecycle `expire-all-14d` |
| Gallery.app (Touch ID, wipe on lock, encrypted keys) | DONE | edfead3; owner-tested |
| Step 0 disk list | DONE, waiting for the owner's pick | PROGRESS §7 2026-10-27 21:35 (5.3 GB free; candidates ~18–23 GB) |
| Chauphan mount (always on, launchd, 2 GB cache) | DONE | gallery ec9ce9e deployed (version 87728872); sync 443b184; live: hash-identical read, trash on overwrite, recovers from `kill -9`. Finder `._*` fix 08b03de committed, NOT deployed |
| **File Provider (now the top priority, 2026-10-28)** | design SETTLED, slice 1 PARTIAL | `gallery/docs/architecture.md`; gallery 036f213 read-only feed (routes 44 pass), NOT deployed; iOS slice needs the iPhone plugged in |
| Folder moves (skipped by owner 2026-10-28), engine, Mac adapter, iOS web app, folder rename | NOT STARTED | the File Provider plan now sets the order |
