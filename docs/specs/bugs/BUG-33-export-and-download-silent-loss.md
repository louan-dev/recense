# BUG-33 · M4B export and offline downloads lose or hide work (same-minute names, discarded ffmpeg errors, queue that never drains)

From: owner 2026-11-18 (PLAN-1118 §5k "Anything → M4B audiobook, and the offline download infrastructure") ·
Guards: FEAT-01 (M4B), FEAT-11 (downloads), FEAT-12 (Music), FEAT-31 P1 ·
Status: `[~]` tests pass (`strip/recense selftest exportjobs downloads`; `mobile/ios/Tests/partsresume/run.zsh`); device check owed

## What the owner would see
- Two Export as M4B in one minute: one file, or none; the first one's work folder deleted under ffmpeg.
- Download of the same title in the same minute: the first copy silently replaced.
- "ffmpeg couldn't make the audiobook" for every cause; a hung ffmpeg never ends.
- iPhone temp folders pile up in the app's tmp.
- A download asked while online (or from another device) waits for a network change; a failed one sits in `.queue/failed/` unseen.
- youtu.be and watch?v= of one video download twice; a `.vtt` stays behind when Music renames its file; no free-space check; `.part` files skipped forever.

## Items (PLAN-1118 §5k)
| Item | Gap (proven by reading code, 2026-11-18, main e9c1315) | Fix |
|---|---|---|
| M-B1 data loss | `exportStamp()` looked only at finished files; the work folder `export/<stamp>` and the output were deleted by the second job | `ExportJobs.stamp` reserves the stamp at once; `ExportGate` runs exports one at a time; the final move never replaces a file |
| M-B2 data loss | `downloadPlayed` did `removeItem` on `<stamp> <title>.<ext>` before copying | `ExportJobs.freeURL`, no removal |
| M-B4 | ffmpeg stderr to /dev/null, no timeout | run through `Downloads.run` (timeout 7200 s), the last stderr line and "took too long" reach the owner and the log |
| M-B5 | iOS `Exporter.dir()` folders never deleted | folder removed on failure; older than a day swept before each export |
| D1 | `.queue/` drained only on a network change or launch; failure moved to `failed/` with no word | also drained every 60 s and when `.queue/` changes; a failure posts a notification callback |
| D2 | dedupe by exact URL string; youtu.be vs watch?v= twice | `Downloads.canonical(link)` (video id) keys `existing`; `existing` still verifies the bytes by sha256 |
| D3 | `settle()` moved sidecars under their old names when Music renamed the file | sidecars take the renamed base |
| D4 | no free-space check; `.part` older than a day kept | under 500 MiB free the request waits in the queue (never failed/), saying how much is left; `sweepStale` removes `.part`/`.ytdl` older than a day |
Not in this change (open): M-B3 language tags, M-B6 artist/cover/AAC copy, D1-D4's yt-dlp pin/update and the `-P temp:` `.incoming/` move, merge of the second yt-dlp path (`recense.swift:3587`), iOS download engine.

## Invariants (tests: `strip/recense selftest`, groups `exportjobs` and `downloads`)
- Three stamps asked in one minute are distinct; a stamp whose file exists is skipped.
- `freeURL` never returns an existing path.
- `ExportGate` never runs two exports at once.
- `failure(status:stderr:)` returns ffmpeg's last line, and a timeout reads as one.
- A temp folder older than a day is swept; a fresh one stays.
- `canonical` of youtu.be/ID, youtube.com/watch?v=ID&t=5, youtube.com/shorts/ID is one key.
- `sweepStale` removes a day-old `.part` and leaves a fresh one.
- A settled subtitle sidecar follows its media's new name.

## Device check (owed)
- Two exports of different recordings started together: two `.m4b` files, both play, chapters intact.
- A media link pasted in two forms: one file.
