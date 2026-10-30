# Sync event log: one format for every Sync log

**Status (2026-10-29 20:55 PDT):** DONE and live (Gallery 0b0ab499 = main 80a2ff2). `ledger.mjs` writes v2 (its launchd jobs run the repo file). The
catalog side (`gallery/src/fp.js`) is deployed: live batch 3 of the archive is chained and carries md5s, and
`changes?since=2` answers with events instead of the old false 410. §7.4 waits on one dashboard step. Written to resolve the
contradictions between `ledger.mjs`, the engine's catalog and `docs/specs/organism.md`.

## 1 · Two writers, one log
Sync keeps two logs. They do different jobs, so they stay two writers, but they share one format, one chain rule,
one delete guard and one verifier.

| | **Observer:** `src/ledger.mjs` | **Authority:** the catalog (`gallery/src/fp.js`) |
|---|---|---|
| Runs | on the Mac, launchd | in the Worker |
| Records | a folder Sync doesn't own and never writes to (Obsidian vault, iCloud Drive, the Calendar export) | an R2 root Sync owns (`gallery-archive` today; Main, Public, tmp later) |
| Lives in | `<sink>/journal/<time>-<rand>.jsonl` + `objects/<sha256>` | `<bucket>/.catalog/<root>/log/<seq:12>.json` + `snapshot.json` |
| One batch is | a segment: one run (a header line, then the events) | one reconcile pass (later: one write) |
| Bytes | content-addressed copies, sha-256 | the bucket's own objects, R2 etag |
| Kept | forever (append-only) | 30 days, then `410` and devices enumerate again (compaction not built yet) |
| Read by | `fold` → `views/tree.json`, `restore`, `verify` | devices through `changes?since=`; `verify` |

When a source moves from iCloud to R2 (the G1 cutover), its history moves from the first log to the second: the
ledger's last tree is what the catalog's baseline must match (`rclone check` today; a `ledger.mjs` comparison later).

## 2 · The event
| Field | Meaning | Ledger | Catalog |
|---|---|---|---|
| `op` | `create`, `modify`, `move`, `delete` change the tree; `conflict`, `skip` are information | yes | yes |
| `id` | stable item id (§4) | yes | yes |
| `path`, `dir` | where it is; folder or file | yes | yes |
| `size`, `mtime` | bytes; whole seconds | yes (+ `mtimeMs`, exact, for restore) | yes |
| `hash` | sha-256 of the content | yes | not yet (§7) |
| `etag` | R2's etag | — | yes |
| `from` | the old path, on `move` | — (a rename is delete + create) | yes |
| `prev` | the content's previous hash, on `modify`/`delete` | yes | — |
| `of`, `ofHash` | the original a conflict copy belongs to | yes | later (slice 3) |
| `v`, `seq`, `ts`, `origin` | format version, event number, time, which Mac job | yes | on the batch: `v`, `seq`, `at` |
| `chain` | the link (§3) | yes | yes |

**Consumers apply only `create`, `modify`, `move` and `delete`.** Anything else is information. The File Provider
extension follows this rule (`FileProviderExtension.swift`, `enumerateChanges`).

**v1 (ledger journals before 2026-10-29):** `put` = create or modify, `tombstone` = delete. Readers accept both,
forever; writers write v2 only. Verified on the live journals: Obsidian 27 segments / 261 files, iCloud Drive 2 / 65,
Calendar 6 / 1,078, all 0 problems with the new code, counts unchanged.

## 3 · The chain
- `chain = sha256(previous chain + "\n" + JSON of the event without its chain)`, hex. The first link is
  `GENESIS = sha256("genesis") = aeebad4a…182718e`.
- Ledger: each segment's header carries `prevChain`. Catalog: each batch carries `prev`, and `snapshot.json` keeps the
  head (`chain`).
- **Test vector, in both test suites:** `GENESIS` + `{"op":"create","id":"h000000000000000000000000","path":"a.m4a",
  "dir":false,"size":1,"etag":"\"e\"","mtime":1}` → `e704650f…bde83c894`.
- **One verifier:** `node src/ledger.mjs verify --sink <ledger sink>` or
  `--sink rclone:<remote>:<bucket>/.catalog/<root>`. For a ledger sink it also checks every object (and re-hashes them
  with `--deep`). For a catalog: no gaps, no forks, each batch continues the last; batches written before the chain
  existed are counted and skipped. The catalog's bytes aren't content-addressed, so only the chain is checked.
- **Proven across the two codebases:** the Worker's own `reconcile` run against an in-memory bucket wrote a log that
  `ledger.mjs verify` accepted (0 problems) and rejected after one path was edited ("chain broken").

## 4 · Ids
`h` + the first 24 hex of sha-256(path) when nothing stored an id; a file's `customMetadata.fid` when the Worker kept
one across a rename; `d` + the same for folders (`fp.js`). The ledger uses the same rule on the path inside its source.
Its renames are delete + create, the same as the catalog's for renames made around the Worker. No bytes move twice,
because the ledger stores content by hash.

## 5 · The delete guard (one function, both logs)
`massDelete(n, known) = n > 100 || (n > 10 && n > 10% of known)`. The same constant is in `ledger.mjs` and `fp.js`.
- **Ledger:** the run refuses and writes nothing; the launchd job notifies; `--allow-mass-delete` is the confirmation.
  (Was: refuse above max(10, 20%).)
- **Catalog:** the pass logs nothing and writes `held.json`; `changes` answers `held: {deletes, known, at}` and no
  device removes anything. The owner, signed in to Access (never a device token) and from the site, `POST`s
  `/main/api/fp/<root>/confirm`. That covers at most the deletes shown, for 10 minutes, and the pass that goes through
  spends it. A held pass is re-checked once a minute, not on every ask. (Was: no guard; an emptied folder in R2 would
  have removed it from every device.)
- **Writes through the Worker** (slice 3) answer `409 needs-confirmation` with the same function.
- The owner's spec says "more than 10% of a root or more than 100 files". The floor of 10 is ours, so that a small
  root doesn't stop on a single deletion. The owner can drop it: change `GUARD.floor` in both files.

## 6 · Conflict copies
Both names are recognized as `conflict` events: iCloud's `Report 2.docx` and the engine's
`Report (conflict, iPhone, 2026-10-29 1830).docx`.

## 7 · The five that were left open (resolved 2026-10-29, owner: "resolve all")
1. **Junk and dotfiles: one rule.** `JUNK_PATHS` (the OS's litter: `.DS_Store`, `._*`, `.Trash*`, `.localized`,
   `Thumbs.db`, `desktop.ini`, Office `~$*` and LibreOffice `.~lock.*#` lock files, `Icon\r`, volume folders) and
   `CHURN_PATHS` (one device's app state: `.obsidian/workspace*.json`, `.obsidian/cache`) are the same in
   `ledger.mjs` and `fp.js`, with one test vector in both suites. Junk is never listed, logged or synced; churn is stored
   but never logged or synced. **Every other file is content, dotfiles included**: in the ledger, in the feed and in
   the Finder mounts (`dav.js`, which used to refuse every dot name). Gallery's own pages still hide dotfiles: that's
   how Gallery shows a library, not what Sync keeps. Live on the first pass: 7 LibreOffice lock files appeared and
   4 Office `~$` lock files left the feed (the objects stay in R2), which is what added `.~lock.*#` to the list.
2. **Content hash in the catalog: md5.** The feed and the log carry `md5` whenever R2 knows it without the bytes (a
   single-part upload's etag, or rclone's `md5chksum` for a multipart one). The ledger now records `md5` beside
   `sha256` for every file it captures, so the two logs compare directly. Not covered: multipart uploads that stored no
   md5 (some Worker chunked joins).
3. **Compaction.** Each pass moves batches older than 30 days from `log/` to `history/` (oldest first, at most 20).
   They're never deleted, `ledger.mjs verify` reads both as one chain, and an anchor older than `log/` gets `410`.
   `snapshot.json` stays a full listing, without md5 (the etag is enough to see a change).
4. **Ledger sinks out of Gallery's bucket: ready, waiting on one dashboard step.** Bucket `sync-ledger` exists.
   `bin/move-ledger-sinks.zsh` (dry run by default, `--apply`) pauses each job, copies server-side, runs
   `verify --deep`, compares the trees, carries the state file over (`ledger.mjs state-path`), points the job at the
   new bucket (old plist kept) and restarts it. It deletes nothing and prints the purge command. Blocked until the
   jobs' `gallery-main` key is given the new bucket in the Cloudflare dashboard (the script says how).
5. **Main as a root.** `FP_ROOTS.main = { bucket: MAIN, prefix: "files/" }`: paths and ids are relative to the prefix,
   and nothing outside `files/` (ledger, invites, order, trash, the catalog itself) is ever listed. The iOS/Mac apps
   don't offer Main yet (architecture.md slice 5, and the open Face ID question).
   **Big roots go in steps.** Main's first live pass was stopped by Cloudflare at ~1 s of CPU (`exceededCpu`, 24 s
   wall) while listing ~30,000 files in one request. A pass now lists at most 5,000 objects or 8 s per request, saves
   that part in `.catalog/<root>/pass/` with the cursor, and the next request goes on. The diff, the log and the
   snapshot happen once, in a request of their own, after the last page. A pass older than 30 minutes starts over.
   **Measured live (0b0ab499, Main = 29,519 objects):** a pass is 7 requests, 250–345 ms of CPU and 4–8 s each; the
   snapshot is 6 MB; a pass with no change logs nothing. A root as small as the archive still finishes in one request.
   Consequence: on Main a change reaches the feed after one pass (~7 polls, ~7 minutes at one a minute), until R2
   event notifications feed the log directly (organism.md §7).

## 8 · Bug found while unifying (fixed, live 2026-10-29)
`changes?since=N` answered `410` whenever batch N still existed: the listing started at `…/N`, and `…/N.json` sorts
after it, so batch N itself came first and failed the gap check. So **every incremental check made the Files
extension enumerate everything again**. It was never caught because the only test asked from `since=0`. Fixed
(`startAfter` ends in `.json`), and the new test asks from an existing batch.
