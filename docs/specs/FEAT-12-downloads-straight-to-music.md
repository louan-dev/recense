# FEAT-12 · Audio downloads land straight in Music

From: T-0076 (owner, 2026-11-15, "how can i just get a download in recense/download to just automatically go
into the recense music location") · owner 2026-11-15 (scope: every audio-mode download moves immediately;
downloads/ stays the holding area only for av/video) · Status: `[x]` (P1+P2 built and checked 2026-11-15; P3 needed no change; owner's real-device check owed)

## Why
`downloads/` and the Music home (`library/Music`) are two different Homes (FEAT-06): downloads is a staging area
Recense tracks for carry and offline dedup, not the library. Today nothing moves a finished audio download into
Music — it just sits in `downloads/` until the owner does it by hand (`mv` + `recense homes adopt`).

## Built `[x]` (what this stands on)
- `shared/mediadownload.swift`: `Downloads.fetch` (direct link or yt-dlp), `Downloads.adopt()` (records files
  dropped into `downloads/` or `downloads/Pulltube/` by Pulltube, Finder or AirDrop), `Downloads.existing(link:mode:)`
  (offline dedup: the same link in the same mode, already on disk with its sha256 intact, is reused with no network).
- `shared/homes.swift`: `Home.music` (`library/Music`), `Homes.add(_:to:move:subfolder:)` (moves a file into a
  home, records it in that home's index).

## Planned `[x]`

### P1 `[x]` · Move on record, not just on fetch
- Every point a `DownloadEntry` with `mode == .audio` is recorded — `Downloads.fetch` (direct or yt-dlp path,
  after `makePlayable`) and `Downloads.adoptAndCheck()` (Pulltube/Finder/AirDrop drops) — moves the file into
  `Home.music` via `Homes.add(file, to: .music, move: true)` instead of leaving it under `downloads/`.
- `av` and `video` mode downloads are unchanged: they stay in `downloads/` for the owner to review/trim, exactly
  as today. Only `.audio` moves.
- The downloads manifest (`downloads/manifest.json`) still gets the entry (it is the download *history* and the
  offline queue's dedup key), but its `DownloadEntry` now carries the file's final location so `file(e)` resolves
  to `library/Music/...`, not `downloads/...`, once moved.

### P2 `[x]` · Dedup keeps working after the move
- `Downloads.existing(link:mode:)` must still find a previously-downloaded audio file to skip re-downloading the
  same link. Since the bytes are no longer at `root.appendingPathComponent(e.name)`, `file(e)` becomes
  mode-aware: `.audio` entries resolve under `Homes.url(.music)`, everything else under `downloads/` as today.
- Invariant: fetching the same link in `.audio` mode twice in a row performs the move once, then on the second
  call `existing()` finds the file in Music and returns without touching the network or yt-dlp.

### P3 `[x]` · Carry sees it in the right home
- No change needed here: `Carry.verify()` already walks every `Home`, so once the file is under `library/Music`,
  FEAT-09's "Carry Now" treats it as a Music file on every paired device, not a downloads file.

## Invariants
- A `.audio` download, once recorded, is never found under `downloads/` — only `av`/`video` ones are.
- Re-running `recense download <link> audio` for an already-downloaded link does not re-download (checked by sha256
  and mtime, no network call).
- `recense homes adopt` + a manual `.m4a`/`.mp3` dropped into `downloads/Pulltube/` ends up recorded in `Home.music`,
  not `Home.downloads`.

## Planned code layout
- `shared/mediadownload.swift`: `fetch`, `fromSource`, `adoptAndCheck`, `existing`, `file(_:)` — mode-aware home.
- No new file; this is a change to the one existing home-crossing point in Downloads.

## Done checks
- `strip/recense selftest` — add a downloads↔homes case: fetch (or adopt) an `.audio` entry lands in `library/Music`,
  a second fetch of the same link is a no-op on the network.
- `zsh strip/build.sh`; iOS compile (GalleryFiles + RecenseGuest) — shared file, parity rule.
- Real-device check (owner): `recense download <link>` for a song ends up playable from Recense's Music, not
  Downloads, in the Mac UI; the equivalent iOS adopt/download path does the same.

## Offline-first gate
- Outside services: **none new.** This only changes where a file already downloaded to this device is filed —
  no network call added, `existing()`'s offline-dedup behavior is preserved by P2.
