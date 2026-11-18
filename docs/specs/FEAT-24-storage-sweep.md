# FEAT-24 · Screenshots and screen recordings follow the tmp move rule

From: owner 2026-11-17 ("apply the tmp move rule to screenshots and screen recordings, to save storage; the Mac has 6.5 GB free") · Status: `[~]`

## Verdict
**Extend the one rule, not add a third sweeper.** `sync/bin/downloads-hold.zsh` already holds a finished file, then moves it to
`gallery-tmp:gallery-tmp`. Screenshots and recordings become two more *lanes* of that script.

## Facts (checked 2026-11-17)
- **proven** Screenshots land in `~/Documents/Screenshots` (`defaults read com.apple.screencapture location`).
  1252 files, 273 MB; 504 are named `Screenshot …`; the rest are the owner's own course pages. Name decides, never the folder.
- **proven** Screen recordings (Cmd-Shift-5) save to the same folder as `Screen Recording …mov`; none there today.
  QuickTime recordings land in `~/Movies`, which `movies-to-recordings.sh` already moves to `~/Recordings` (empty today).
- **proven** Two sweepers exist: `screenshots-sweep.sh` (the Claude context folder → Trash after 3 days; unrelated to the owner's
  screenshots) and `movies-to-recordings.sh` (routing, not deleting). Neither frees space on the owner's screenshots.
- **assumed** Screenshots will not fill 6.5 GB: today's whole folder is 273 MB. Recordings are the heavy kind. Say so to the owner.

## Rules
1. **Lanes.** A lane = folder · name pattern · hold · clock. Three lanes: Downloads/AirDrop (built), Screenshots, Screen recordings. **`~/Recordings` is not a lane** (it holds audio and video the owner keeps).
   **The lanes ship OFF (`LANES_ON=0`)** until the owner answers rule 6.
   - Screenshots: `~/Documents/Screenshots/Screenshot *.{png,jpg,heic}` · hold **2 min** (enough to paste or drag it).
   - Screen recordings: `~/Documents/Screenshots/Screen Recording *.mov` · hold **10 min after the
     file stops changing** (clock = last modified; a file still open or still growing never moves).
2. **Hands off:** a file opened, renamed or tagged during its hold is the owner's: it stays for good (same rule as AirDrop).
3. **Only new files.** Each lane starts the moment it first runs (a stamp file; `LANE_SINCE_ISO` overrides). **The 504 old screenshots are never moved.**
4. **Catch-up, never first.** The move is `rclone move` to R2 (verifies, then deletes the local copy). Offline: the file stays.
   Name clash: both kept (`.replaced-<time>`).
5. **Where in the bucket:** `screenshots/` and `recordings/` prefixes, so the owner can see and restore them.
6. **How long they live in R2:** the bucket-wide rule is 14 days (`expire-all-14d`). This spec does not change it.
   **Owner decides** (open question): keep 14 days, or a longer rule for these two prefixes.

## Checks
- Rule test (pure): per lane, due at hold, not before; opened / renamed / tagged = keep; older than `LANE_SINCE` = ignored.
- Real run: a `Screenshot …png` and a `Screen Recording …mov` in a temp folder move after their hold; a tagged one stays.
- `zsh sync/bin/downloads-hold.zsh selftest`, `npm test` in `sync/`, `plutil -lint` the plist, next real agent run OK in the log.
- Outside services: R2 only, as catch-up; nothing needs it at the moment of use.
