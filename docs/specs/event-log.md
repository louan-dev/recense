# Sync event log: one format for every Sync log

**Status (2026-10-29 19:30 PDT):** DONE in code and tests. `ledger.mjs` writes v2 now (its launchd jobs run the repo
file, so the next run writes v2). The catalog side (`gallery/src/fp.js`) is NOT deployed. Written to resolve the
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

## 7 · Not unified yet (each with its reason)
1. **Junk and dotfiles.** The ledger keeps dotfiles (`.obsidian/` is part of a vault) and ignores a named list; the
   catalog hides every dot name (`common.js` `JUNK`). Unify when a root needs its dotfiles (the vault's cutover), not
   before: `JUNK` also guards the mounts.
2. **Content hash in the catalog.** Only the etag today. The Worker can store `customMetadata.sha256` on every write it
   serves (slice 3); rclone's direct writes stay etag-only.
3. **Catalog compaction** (30 days) isn't built, and `snapshot.json` grows with the root.
4. **Ledger sinks live in the product bucket** (`gallery-main/ledger/<source>/`). Their owner is Sync. Moving them is
   a data migration (copy, `verify --deep`, switch the jobs), only on the owner's yes.
5. **More roots.** `FP_ROOTS` has no prefix, and the reconciler lists the whole bucket. Adding Main as it stands would
   put `ledger/`, `invites/`, `notability-backup/`, `order/` and the rest of `gallery-main`'s top level into Files (listed 2026-10-29). Main needs `prefix: "files/"` first.

## 8 · Bug found while unifying (fixed, not deployed)
`changes?since=N` answered `410` whenever batch N still existed: the listing started at `…/N`, and `…/N.json` sorts
after it, so batch N itself came first and failed the gap check. So **every incremental check made the Files
extension enumerate everything again**. It was never caught because the only test asked from `since=0`. Fixed
(`startAfter` ends in `.json`), and the new test asks from an existing batch.
