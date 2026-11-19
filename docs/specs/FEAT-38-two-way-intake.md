# FEAT-38 · Two-way intake: PullTube, Telegram and links land in Music from the Mac or the phone, and pull to refresh

From: owner 2026-11-19 ("music to phone and phone to mac; PullTube downloads and Telegram Tidal-bot downloads, same destination") · Status: `[ ]` written, not built
Linked specs: FEAT-12 (audio lands in Music) · FEAT-06 (homes) · FEAT-09 (Carry) · FEAT-18 (hub) · FEAT-22 (catch-up ladder) · FEAT-24 (only new files) · BUG-16 (iOS sweep)

Labels: **checked** = seen this session (file:line or command) · **assumption** = not yet verified.

## Why
The owner downloads music three ways: PullTube on the Mac, links, and a Telegram bot (Tidal) on the Mac and the phone.
Today only the Mac's PullTube drop folder reaches Music. The phone has no way to add a link, and nothing carries a
Telegram download into Music. A track saved on one device should be in Music on both.

## Checked (what exists)
- PullTube has no iOS app (web search 2026-11-19: every source describes it as macOS only). **checked**
- Mac: files in `downloads/Pulltube/` are recorded and audio moves to `library/Music` (FEAT-12, `shared/mediadownload.swift:118-142`). **checked**
- iOS: `Downloads.sweep()` runs at `mobile/HostApp/iOS/Shows.swift:20` and settles audio found in `downloads/`. **checked**
- iOS: no Share extension (`mobile/ios/*-Info.plist` hold only a File Provider and a Broadcast extension) and no paste-a-link control. **checked**
- The request queue `downloads/.queue/` and its drain exist (`shared/mediadownload.swift:289-545`). The yt-dlp engine is the Mac's. **checked**
- Mac Telegram saves to `~/Downloads/Telegram Desktop` (owner's `ls`, 2026-11-19). **checked**
- Carry shows iPhone and iPad as "Pair again" (`recense carry devices`); after re-pairing, nothing reached the phone's Music. Cause unknown. **checked**
- A second Telegram install (Mac App Store, `ru.keepcoder.Telegram`) exists; its container is unreadable from the sandbox. **assumption:** it also uses the folder above.

## Planned `[ ]`

### P1 · Pull to refresh (Home, Library, every show page)
- One shared refresh in `ShowsKit`; each of the three screens attaches it.
- Gesture: iOS standard pull down from the top (owner confirmed 2026-11-19).
- Visible control beside it: a **Refresh** button in each screen's toolbar (no action depends on a gesture alone).
- One refresh does, in order: `Downloads.sweep()` (adopt files, audio to Music) → drain `.queue` if a path allows → ask the transfer path for catch-up now → rescan the pool.
- It never blocks the screen: the list stays usable and updates when each step ends. Reduce Motion: no bounce animation, a plain spinner.
- Targets: starts within 100 ms of release; the sweep step ends within 2 s for 200 files (**assumption**, measure).

### P2 · Mac intake from Telegram (and any chosen folder)
- A watcher on `~/Downloads/Telegram Desktop` moves **new** audio files (`m4a mp3 flac wav aac ogg opus`) into `library/Music` with `Homes.add(_:to:move:)`.
- New means: appeared after the setting was turned on. Existing files stay (FEAT-24 rule).
- Never overwrites (`song 2.m4a`), records SHA-256, skips files still growing (size unchanged for 3 s).
- A visible setting in Recense › Settings: **Take in Telegram downloads** (off until the owner turns it on, because it moves files out of a folder Recense does not own). The folder is shown and can be changed.
- Moving a file out of Telegram's folder may show it as "missing" in Telegram. **assumption**, test it.

### P3 · Phone intake: Share to Recense and Add a link
- **Share extension** "Recense": accepts URLs and audio files from any app (Telegram, Safari, Files, YouTube).
  - A file lands in `downloads/` (shared app-group folder) and the app sweeps it to Music.
  - A direct media link (MP3, M4A…) is fetched on the phone.
  - Any other link becomes a request in `.queue/` for the Mac's yt-dlp (the PullTube-equivalent), done when the Mac is reachable.
- **Add a link** button in Library › Music: paste, choose Audio / Audio + Video, add. Same queue.
- Telegram on the phone: Share on a track → Recense, or Save to Files → `Recense/downloads`. Both arrive in Music.
- The phone never shows a spinner for a Mac job: the row says "Waiting for the Mac" and resolves when the file arrives.

### P4 · Both directions: the hub replaces Carry (owner decision 2026-11-19: "abandon carry")
- A new track in Music on either device reaches the other through the Mac's hub (FEAT-18 H2, `https://recense.local`), not Carry. The owner decided; it is not reopened.
- The phone asks the hub on every refresh (P1) and when the app opens: it pulls tracks it lacks and pushes tracks the hub lacks, by SHA-256. Plain files, resumable, never blocks.
- Away from home the hub is out of reach; the phone keeps working and catches up at the next refresh at home. R2 as second copy stays optional (FEAT-18 H2).
- Order, so nothing is lost: (1) build the hub's library route and the phone's pull/push; (2) check a track each way on the real devices; (3) only then retire Carry (code `shared/carry*.swift`, `shared/p2ptransport.swift`, pairing UI, SEC-02) in its own spec ADR-xx with a snapshot of any unsent Carry log first.
- Carry's silence after pairing is no longer diagnosed; it is replaced.
- Hub H2 is a sketch only (FEAT-18 §H2): it needs its own spec section (routes, auth, limits) before code. Auth: the hub's own root and a device key, no company.

## Invariants (a test can check)
1. A file is never overwritten or deleted by intake; a name clash gets a numbered copy.
2. Only audio extensions are moved; other files stay where they are.
3. Each landed file is recorded once (path, size, SHA-256); the same bytes arriving twice make one entry.
4. Files present before the setting was turned on are never moved.
5. A request in `.queue/` survives restart and offline; a failure goes to `.queue/failed/` and never blocks the next.
6. Refresh with no network and no paired device still completes the local steps and ends in under 2 s.

## Home and code layout
- **home:** `shared/intake.swift` (which files qualify, new-only rule, settle, dedupe) plus `shared/mediadownload.swift` (links, queue). Everything else is glue.
- Mac glue: `strip/` watcher + Settings row. iOS glue: `mobile/ios/Share/` (extension), `mobile/HostApp/iOS/Shows.swift` (refresh hook, Add a link). Refresh view: `shared/ShowsKit/`.
- Tests: `recense selftest intake`; `shared/ShowsKit/Tests/ShowsKitTests/RefreshTests.swift`; extension of the `downloads` selftest for queue cases.

## Embodiments
- Mac: P2, P1 (Library window), P3 n/a (the Mac already has PullTube and `recense download`).
- iPhone: P1, P3.
- iPad: P1, P3 (same build).
- Web: n/a, the web library has no local downloads folder.

## Debug-channel events (`~/Recense/logs/intake.jsonl`)
`intake.telegram.moved` · `intake.telegram.skipped` (reason) · `intake.share.received` (kind) · `intake.link.queued` · `intake.link.fetched` · `intake.refresh.run` (steps, ms)

## Offline-first gate (outside services)
- Telegram and PullTube: the owner's own apps; Recense only reads their output folders. Not required.
- A link's source site (YouTube etc.): needed at the moment of fetching a link, by nature; offline it queues and never blocks.
- Transfer path: Carry or the hub, both ours. No Cloudflare or other company on the required path.
- Setup once: none.

## Done checks
- `recense selftest intake downloads` passes; `swift test` in `shared/ShowsKit/`.
- Mac build `zsh strip/build.sh` and the iOS compile from the project CLAUDE.md.
- On the owner's devices (iPhone Mirroring, not the simulator): the device checks below.

## Device checks (owner or an agent through iPhone Mirroring)
1. Mac: turn on **Take in Telegram downloads**, save a track in Telegram Desktop, then: `ls ~/Recense/library/Music | tail -3` shows it.
2. Mac: `tail -3 ~/Recense/logs/intake.jsonl` shows `intake.telegram.moved`.
3. iPhone: share a track from Telegram to Recense; Library › Music shows it after pulling to refresh.
4. iPhone: Add a link with a YouTube URL, Wi-Fi on; the row reads "Waiting for the Mac", then the track appears.
5. Offline proof: iPhone in airplane mode, add a link and a file; the file is in Music at once, the link waits; turn airplane mode off and the link resolves.
6. Both ways: a track made on the Mac appears on the phone, and a track shared on the phone appears on the Mac (needs P4).

## Owner answers (2026-11-19)
- Refresh gesture: the standard pull down, plus the Refresh button. Closed.
- Carry: abandoned; the hub library replaces it (P4). Closed.
- Number: first filed as FEAT-36, renamed FEAT-38 the same day because FEAT-36 (bug-tape) and FEAT-37 (capture-clips) were taken in their branches.
