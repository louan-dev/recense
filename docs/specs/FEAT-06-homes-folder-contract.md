# FEAT-06 · Homes: the folder contract on every device

From: owner 2026-11-08 (`.handoff/places/INBOX.md`, folder contract) + owner 2026-11-11 (carry) · Status: `[~]`

One layout on every device, owned by one piece of code, so a saved song,
a downloaded episode and a removed file mean the same thing on the Mac,
the iPhone and the iPad — with no network at any point.

## The contract (owner's words, 2026-11-08, unchanged)
- Mac: `~/Recense/`. iOS/iPadOS: the app's `Documents/Recense/` (visible in the Files app).
- Homes: `library/Music/`, `library/Study/`, `library/Legal/`, `library/Audiobooks/`,
  `library/Listen/`, `downloads/`, `trash/`.
- **Nothing is deleted unless the owner says so:** "Remove" moves to trash on every
  device; trash never empties by itself; "Delete forever" exists only inside Trash,
  with a confirmation naming the file.
- Plain files plus one small manifest per home (`.recense-index.json`: path, size,
  sha256, added, device, tags), so every device knows what exists even before the
  bytes arrive.

## Built `[x]`
- `shared/mediadownload.swift` — `Recense/downloads/` + `manifest.json` + `adopt()`
  + chunked sha256: the shape this spec generalizes, not a second mechanism.
- `shared/ShowsKit/Sources/ShowsKit/Model.swift` — `Zone` (inbox, library, keep, trash)
  and `Kind(path:)`, the one file-kind classifier. `Rules.downloads` names `downloads/`.
- `shared/ShowsKit/Sources/ShowsKit/PoolScan.swift` (player lane, merged after this
  spec was written) — reads the pool for the catalog. It stays the reader; this spec
  owns the folders and their manifests. No second scanner for the catalog.
- `shared/keephome.swift` — `~/Recense/keep/`: transcripts, outside the homes.

## Two discrepancies, decided here (PLAYBOOK §2; coordinator unreachable 2026-11-14)
1. **Trash is `trash/`, visible — not `.trash`.** The owner's contract says `trash/`,
   and `mobile/HostApp/iOS/Listen.swift:459` already writes to `Recense/trash/`, while
   ShowsKit's `Zone.folder` emits `.trash` (its README documents `.trash/`, kept 30 days).
   Facts: `Zone(folder:)` reads **both** spellings, and `PoolScan.tops` is
   `library/`, `downloads/`, `inbox/` — it never walks trash, so neither spelling
   changes what the catalog sees. Decision: the home is `trash/`, because the owner has
   to see and put back what was removed, and because that is the folder live iOS code
   already uses; nothing in the catalog breaks. **Open for the coordinator:** `Zone.folder`
   and `shared/ShowsKit/README.md` still say `.trash`; one of the two spellings should
   go when the catalog starts listing Trash. Nothing deletes either folder in the meantime.

2. **`library/Study` and `Rules.spaceFolders`.** `Rules` knows the spaces
   `study`, `folio`, `matters`, `raven`. The Study home is the same single folder
   `library/Study`; this spec creates it and renames nothing in `Rules`. Folio,
   Matters and Raven are spaces, not homes, and are left exactly as they are.

## Planned

### P1 · `shared/homes.swift` — the folders and their manifests `[x]`
- `Homes.root`: `RECENSE_HOME` if set (tests never touch the real folder), else
  `~/Recense` on the Mac and `Documents/Recense` on iOS/iPadOS.
- `Home`: `music`, `study`, `legal`, `audiobooks`, `listen`, `downloads`, `trash`,
  each with its folder path relative to the root and its label.
- `ensure()` creates every home; it is safe to call on every launch.
- `HomeEntry` (path, size, sha256, added, device, tags) in
  `<home>/.recense-index.json`, newest first, one entry per path.
- `add(_:to:)` takes a file in (move by default, copy on request), gives it a free
  name rather than overwriting, records sha256 at landing time.
- `home(for:)` picks the default home by `Kind(path:)`: audio → Music
  (`.m4b`/`.aa`/`.aax` → Audiobooks), pdf and text → Study, anything else → `downloads/`.
- Label (owner 2026-11-15): the app shows `downloads/` as **Inbox** (home label, Search filter, Lock Screen
  album). The folder keeps its name. Library › Downloaded keeps its own meaning: files stored on this device.
- `adopt(_:)` records files already in a home that the manifest does not know
  (dropped by Finder, the Files app, AirDrop, Pulltube), once each.
- `remove(_:from:)` moves the file into `trash/` and records where it came from
  (`from:<home folder>/<path>` in its tags). It never deletes.
- `restore(_:)` puts a trashed file back where that tag says.
- `deleteForever(_:from:)` throws unless the home is `trash/`.
- `homesSelftest()` in `recense selftest`.

### P2 · One definition of `downloads/` `[x]`
`Downloads.root` reads `Homes.url(.downloads)`, keeping `RECENSE_DOWNLOADS` for
tests. Two folder truths for one folder is a bug waiting to happen; after this
there is one.

### P3 · carry C0 — the exit exists before anything relies on it `[x]`
Owner's 2026-11-11 decision, in `.handoff/places/INBOX.md`:
- `recense carry verify` writes `~/Recense/.carry/manifest.jsonl`: one line per
  file across every home — path, size, mtime, sha256, device, and the home it is in.
  It is the device's statement of what it holds, readable by any tool.
- `recense carry move --to <folder>` copies every home into that folder, verifies
  every sha256 after the copy, writes a receipt (`carry-receipt-<date>.json`), and
  **leaves the source in place** until the owner says otherwise.
- Both are local filesystem work only. No network, no company, ever.

### P4 · Not in this slice (named so nothing is silently dropped)
- **C1 folder carrier / C2 direct carrier** — the actual byte transport between
  devices. C2 builds on the listen lane's pairing (pinned CryptoKit keys, Bonjour,
  `includePeerToPeer`); never a second pairing layer. Until C1/C2 ship, a file saved
  on one device reaches the others only by carry's folder route or the existing
  rclone jobs — P1–P3 make that honest, they do not make it automatic.
- **The Music and Search surfaces** (Music home in the skin, scope chips
  All · Music · Study · Legal · Downloads · Trash, tiles vs list) — player and
  places lanes, not this one.
- **FEAT-03 Share** — `Recense/share/`, its own folder and lane (`work/share`).

## Invariants
- Every home exists after `ensure()`, on the Mac and on iOS, with no network.
- A file taken in by `add()` produces exactly one manifest entry, with a sha256 of
  the bytes as they landed; a second file of the same name never overwrites the first.
- `adopt()` run twice adds nothing the second time.
- `remove()` leaves the file on the device, inside `trash/`, with the home it came
  from recorded; no code path in `homes.swift` deletes a file outside `trash/`.
- `deleteForever()` outside `trash/` throws, every time.
- `Downloads.root` and `Homes.url(.downloads)` are the same folder.
- `carry verify` lists every file in every home; `carry move` reports a mismatch
  instead of removing a source.

## Done checks
- `recense selftest` (includes `homesSelftest`) — Mac.
- `zsh strip/build.sh` (with `RECENSE_TOOLCHAIN` in a worktree).
- iOS compile: `xcodebuild -project mobile/ios/GalleryFiles.xcodeproj -scheme GalleryFiles
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.
- Real-device check (owner, iPhone + iPad via iPhone Mirroring, Wi-Fi off): the homes
  exist in the Files app under Recense, a file added lands in the right one, Remove
  puts it in Trash and Trash still holds it after a relaunch.

## Offline-first gate
- Outside services touched by P1–P3: **none**. Filesystem and CryptoKit only.
- `carry move`'s destination may be a folder a company syncs (iCloud Drive, a USB
  stick, the WebDAV mount) — the owner picks it, and `~/Recense/private/**` never
  rides a company folder (owner, 2026-11-11).

## Amendments
- 2026-11-14 · created; the contract itself is the owner's 2026-11-08 decision,
  moved out of `.handoff/places/INBOX.md` into spec form so later lanes derive from it.
