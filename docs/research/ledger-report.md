# Ledger: use Apple's own client as the protocol

**Date:** 2026-10-10. Companion to `ledger.mjs`, `icloud-backend-technical-report.md`, `sync-matrix.md`.

## 1. The idea in one paragraph

Stop trying to speak Apple's protocol. The Mac's iCloud client already logs in, decrypts (Advanced Data Protection included) and syncs, and it leaves the result as ordinary files in `~/Library/Mobile Documents/`. Treat that folder as an **oracle**: observe it read-only, and publish what you see as an **append-only, content-addressed, hash-chained journal** in R2 (or any directory). Every other service then subscribes to the journal instead of to Apple. Apple can change its endpoints, rotate tokens or tighten web access; a folder does not change.

```
 iPhone/iPad ──▶ iCloud ──▶ Apple's client on the Mac ──▶ folder     (Apple's job, untouched)
                                                           │ read-only
                                                           ▼
                                                  ledger.mjs (the intermediary)
                                       objects/<sha256>   journal/*.jsonl   views/tree.json, health.json
                                                           │
        ┌───────────────┬──────────────────┬──────────────┴───────────┬────────────────────┐
     Gallery /main    Second vendor      Arq on the SanDisk     Worker WebDAV view      restore --at <time>
     (browse)       (rclone copy, safe)   (a plain directory)   (Obsidian, DEVONthink)   (time machine for iCloud)
```

## 2. How new is it? (honest version)

- **Not new:** backing up the local iCloud folder; handling placeholders (Arq, Carbon Copy Cloner and Duplicacy can report, ignore or "materialize" dataless files; Arq explains it materializes only changed files and evicts afterwards); content-addressed stores; event logs.
- **What I could not find** in a short search, and cannot promise nobody has built: a tool that treats the iCloud client as the oracle *and* publishes a subscribable, tamper-evident journal that other services consume, with point-in-time restore and conflict copies recorded as data. Backup tools produce snapshots for restoring; they do not offer a feed for syncing other systems.
- **Before you call it "first", do a proper prior-art search.** The defensible claim is the combination and the priorities below, not any single trick.

## 3. What a sync engine should prioritize

Ranked. `ledger.mjs` tags each of these in code and the self-test checks them.

| # | Priority | What it means here | Why it matters for iCloud |
|---|---|---|---|
| P1 | **Truth over completeness** | A placeholder is not a backup: evicted files are skipped *and reported*; a source that suddenly loses most files is refused | With a full iCloud and "Optimize Storage", many files are dataless. Backing up placeholders, or tombstoning everything when a mount comes back empty, is how people lose data |
| P2 | **Never write to the source** | Only `lstat`, `readdir`, read-only streams. The one local-write gate refuses anything inside the source or `Mobile Documents` | Your Notability notes and vault cannot be damaged by this tool |
| P3 | **Immutable data, append-only history** | Objects named by SHA-256; deletes are tombstone events | iCloud deletions propagate to every device. The mirror must not |
| P4 | **Hash what you copied** | Copy to staging while hashing, re-`stat` afterwards, discard if it changed | Files sync in the middle of your run; hashing a moving file lies |
| P5 | **Idempotent, resumable** | Order: objects, then journal segment, then local state. Re-running is always safe | Home networks and sleeping laptops interrupt jobs |
| P6 | **Tamper evidence** | Each event carries a chain hash; `verify` finds edits and gaps; `--deep` re-hashes objects | Silent corruption is the failure you only find at restore time |
| P7 | **Conflicts are data** | iCloud's `Name 2.ext` copies are recorded as `conflict` events (name heuristic) | You decide later; nothing is overwritten |
| P8 | **Ports and adapters** | Source = a folder, sink = directory or rclone remote, views derived | Same engine for the SanDisk, R2, a second vendor |
| P9 | **Observable** | `views/health.json`: last success, head hash, counts. Feed it to `/health` and Sill | A backup that stopped last month looks identical to one that works |
| P10 | **Bounded blast radius** | Hard denylist for the Notability container, `.photoslibrary`, Messages, Mail | A wrong path argument must not touch irreplaceable live stores |

## 4. Why the intermediary has to be the Mac

Only Apple's client can read iCloud data without reverse engineering and without holding your Apple credentials. So the Mac is the intermediary by necessity, and the cloud pieces are subscribers. Consequences:

- **No VPS needed for the oracle.** A VPS would add nothing and would be the wrong place for anything Apple-related. It could, at most, replicate `objects/` and `journal/` (immutable, so `rclone copy` is always safe).
- **The Worker is the hub** for browsing and WebDAV views, reading `views/tree.json`. It holds no Apple secrets.
- **The Mac must be awake** for the mirror to advance. Use `launchd` and a `/health` alert if `lastOk` is older than a day.
- Arq remains useful as an independent copy of the sink; it can also back up the source itself with its materialize option.

## 5. How it reaches every row of the matrix

Every source is "a folder", so the engine does not change.

| Matrix row | Folder that Ledger watches | Status |
|---|---|---|
| iCloud Drive, Draftpad | `~/Library/Mobile Documents/com~apple~CloudDocs/...` | Works today |
| Obsidian vault | `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/<vault>` | Works today (the churny `.obsidian/workspace*.json` files are ignored) |
| Photos | A folder of **exported originals** (Photos export or `osxphotos`; verify), never the `.photoslibrary` bundle | Needs the export step |
| Calendar, Contacts | Folder filled by a CalDAV/CardDAV pull (`vdirsyncer`; verify) | Needs the pull job |
| Mail and attachments | Folder filled by `mbsync` over IMAP (verify) | Needs the pull job |
| iMessage | A **copy** of `chat.db` and `Attachments/` plus the exporter's output, in a private sink prefix | Needs the copy step; keep it private |
| Notability | Not watched. Notability's Auto-Backup writes to a Worker WebDAV endpoint into `inbox/notability/`; a Mac job pulls that to a local folder and Ledger journals it | WebDAV endpoint not built yet |
| DEVONthink | WebDAV view of `views/tree.json` (verify what its sync accepts) | Later |

## 6. What the code does and does not do

**Done and tested** (`node ledger.mjs selftest`, 17 checks, passes on Node 22 on Linux): dry run writes nothing; one object per distinct content; ignored noise; idempotent re-runs; put/tombstone/conflict events with previous hash; append-only objects; `fold` and `fold --at`; `verify` (chain, presence, size, deep re-hash) including tamper detection; `restore --at` with hash check and refusal to write into `Mobile Documents`; quiet-period deferral; mass-vanish refusal; denylist refusal; source unchanged byte for byte and mtime.

**Written but not exercised here:** the `rclone` sink (no rclone in my sandbox), the macOS `stat` flag check for dataless files (`SF_DATALESS`; confirm on your OS version), and `watch` mode (`fs.watch` recursive uses FSEvents on macOS). Test each on a small folder first.

**Deliberately not built yet:**
1. **Subscribers.** A Worker route that serves `views/tree.json` and objects (browse and read-only WebDAV).
2. **Write-back.** Two-way sync for plain-file vaults: a writer proposes `put` with `prev` = the hash it started from; the Mac agent applies it to the local folder only if the local file still has that hash (optimistic concurrency), otherwise records a `conflict`. Apple's own client then uploads the change, so we still never speak Apple's protocol. **Never for Notability.**
3. **Drift check.** Compare `tree.json` to the live folder and report differences.
4. **Replication** to the second vendor and the SanDisk.

## 7. Limits and risks

- **It cannot fix a full iCloud.** If the iPad's changes never reached iCloud, the Mac never sees them. Free space first.
- **Placeholders stay placeholders** unless you pass `--materialize`, which makes Apple download them (disk and bandwidth). Do that deliberately, in batches, and with a stage directory on the SanDisk (`--stage-dir`).
- Conflict detection is a **name heuristic**; legitimate files like `Chapter 2.txt` beside `Chapter.txt` are flagged and need a human glance.
- The journal records file *paths*: protect the sink as you would the files.
- Not end-to-end encrypted at the sink. If R2 holds private material (messages, coursework), encrypt before upload (for example an rclone `crypt` remote) or keep it on the SanDisk only.
- `fs.watch` only says something changed; the incremental scan, not the event, is the source of truth.

## 8. First run (about ten minutes, nothing destructive)

```
# 1. Prove the tests pass on your Mac
node ledger.mjs selftest

# 2. Dry run on a COPY of a small folder (not your whole iCloud, not Notability)
cp -R ~/Developer/some-small-folder /tmp/ledger-try
node ledger.mjs run --source /tmp/ledger-try --sink /tmp/ledger-sink

# 3. Apply, then check
node ledger.mjs run --source /tmp/ledger-try --sink /tmp/ledger-sink --apply
node ledger.mjs verify --sink /tmp/ledger-sink --deep
node ledger.mjs fold   --sink /tmp/ledger-sink --write

# 4. Only then point it at the Obsidian vault, with a sink on the SanDisk
node ledger.mjs run --source "$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/<vault>" \
                    --sink /Volumes/SanDisk/ledger/obsidian
# 5. Later, R2:  --sink rclone:gallery-main:ledger/obsidian
```

Use `--sink` prefixes per source (`ledger/obsidian`, `ledger/drive`, ...) so each has its own journal.

## 9. Recommended order

1. Run the self-test and the copy trial above.
2. Obsidian vault to the SanDisk (plain files, lowest risk, immediate value).
3. Add `launchd` plus the health alert.
4. iCloud Drive proper, with eviction counts reviewed before any `--materialize`.
5. R2 sink; then the Worker subscriber routes.
6. The pull jobs for Calendar, Contacts, Mail; Notability WebDAV; iMessage copy.
7. Write-back for the vault only, last.
