# FEAT-39 · Live edits: the iPad sees what changed on the Mac before it is committed, and a review snapshot reaches the coordinator inbox

From: owner 2026-11-19 ("iPad sees what's updated in real time on my Mac, not committed, with last-edited times, and zip files sent to you for code review") · Status: `[~]` P1, P3, the hub endpoints and the iPad list built and compiled (2026-11-19); not installed, no device check yet; the diff view and the LAN/R2 rungs are open
Linked specs: FEAT-22 (catch-up ladder: device → paired device → hub → R2 optional) · FEAT-18 (hub) · FEAT-38 (intake, same transfer path) · `.claude/CLAUDE.md` § Sessions working together (review dialogue)

Labels: **checked** = seen this session · **assumption** = not yet verified.

## Why
Work sits uncommitted for hours in several worktrees. The owner cannot see from the iPad what moved, and a reviewer
cannot read work that has no commit. Git can snapshot uncommitted work without touching the branch, so neither needs a commit.

## Checked (what exists)
- The coordinator inbox is `.handoff/coordinator/inbox/`; `coord.zsh post <file>` files a plan or review request (`sync/bin/coord.zsh:785`). **checked**
- Review messages begin `READY FOR REVIEW: <branch> @ <commit>` (global CLAUDE.md, review dialogue). **checked**
- `sync/bin/` already holds launch-agent jobs; `sync/` tests with `npm test`. **checked**
- A hub exists in `hub/` (FEAT-18). **checked** that the folder exists; **assumption:** it can serve a small read-only JSON file to a paired iPad.
- No watcher of uncommitted state exists (search of `sync/bin`, `strip/`: none). **checked**

## Built `[x]` (Mac, `work/live-edits`; checks: `node --test "test/*.test.mjs"` in `sync/`, 22 tests, 5 runs green, outside the Claude sandbox)
- P1 manifest and skip list: `sync/src/livestate.mjs:30` (`isSkipped`), `:85` (`worktreeFiles`), `:112` (`buildManifest`), `:122` (`writeManifest`), age label `:38`.
- P1 watcher and debounce: `:135` (`createDebouncer`), `:142` (`startWatcher`); glue `sync/bin/live.zsh`, `sync/launchd/com.chauphan.live.plist` (plist lints; not yet installed).
- P3 snapshot: `:186` (`snapshot`); BUILT stamp `:80` (`markBuilt`).
- Invariants 1-4 and 6 are tests in `sync/test/livestate.test.mjs`. Real path: manifest of the live repo wrote in 913 ms (two worktrees, 14 files); a snapshot of this worktree applied cleanly to a clone at its base; the real watcher re-wrote the manifest about 8 s after an edit (5 s debounce).
- The watcher test needs FSEvents, which the Claude Bash sandbox blocks (**checked**); there it skips with a message.

## Built `[x]` slice 2 (hub and iPad; compiled, not installed)
- Hub: `GET /api/live` and `POST /api/live/snapshot`, both with the token: `hub/Sources/recense-hub/HubLive.swift` (`hubLiveManifest`, `hubLiveWorktreeName`, `hubLiveSnapshot`, `hubLiveProcessRunner`), routes in `HubServer.swift` (`route`), options `--live`, `--live-script`, `--conf` in `main.swift`.
  A snapshot may name only a worktree the manifest lists (never a path); the name goes to the script as its own argument; one snapshot runs at a time.
  Checks: `recense-hub selftest` (hub; a mutation of the name guard failed 5 cases). Real path: a hub of its own on port 8443 with a throwaway certificate and token (`--conf`): no token 401, wrong token 401, wrong method 405, unknown worktree 404, `GET /api/live` the manifest, snapshot 200 `made`, patch and note in the inbox.
- Mac command line for it: `live.zsh snapshot --json <name>` (`snapshotReply`, `resolveWorktree` in `sync/src/livestate.mjs`; a name from git wins over a same-named folder). Watch failures are logged (`live.manifest.skipped`, reason `watch failed …`), never silent.
- Reader rules (one copy for iPhone and iPad): `shared/ShowsKit/Sources/ShowsKit/LiveEdits.swift` (`LiveManifest` decode and `sorted`, `LiveAge.of`, `LiveHub.pairToken` / `baseURL` / `request` / `reach`, `LiveSnapshotReply.decode`, `LiveCache`). 13 tests in `Tests/ShowsKitTests/LiveEditsTests.swift`; mutations of the age step, the row order and the https rule each failed tests.
- Screen: `mobile/HostApp/iOS/LiveEdits.swift` (`LiveEditsPlace`), a row in the Library (`Places.swift`: **Library › Live edits**; the app has no Settings screen, so this replaces "Settings ›" above). Pairing: on the Mac `recense-hub pair | pbcopy`, on the iPad the **Paste** button in that screen (token kept in the Keychain, this device only). Controls: per worktree **Make Review Snapshot**; `···` menu **Refresh** and **Forget the Mac**; pull down also refreshes; refresh runs every 10 s while the screen is open (30 s when the Mac is out of reach). Offline: the last copy opens at once, marked "Mac not reachable" with its "as of" time (`LiveCache`, Application Support).
  The iPad button files the snapshot and never sends `READY FOR REVIEW` (Decision 2).
- Compile: `xcodebuild … -scheme GalleryFiles` and `-scheme RecenseGuest` (the Guest build gets an empty stub) both BUILD SUCCEEDED, `CODE_SIGNING_ALLOWED=NO`. `NSLocalNetworkUsageDescription` now names the Mac hub.

## Not built `[ ]`
- **The file's diff on a row tap** (P2): needs `GET /api/live/diff?worktree=&path=` on the hub (`git diff HEAD -- path`; the file itself for untracked text) and a detail screen. Filed T-0185.
- **LAN-first and R2 rungs** of the catch-up ladder: only the hub over the LAN (`https://recense.local`, or the address typed in the screen) is built; `live.view.refreshed` reports `hub` or `cache`. The device must trust the hub's root (the FEAT-18 profile) or the screen says so.
- **Siri/Shortcuts name "Live edits"** (an App Intent like `DraftpadVoiceIntent.swift`): not built; the Library row is the one control.
- **Device checks 2, 3, 5** below on the owner's iPad and the screenshot audit (no install from a worktree: the coordinator installs after review).
- Singular/plural ("1 files") in the header: no String Catalog in the app yet; English literals only.

## Planned `[ ]` (original text, P1 and P3 now built above)

### P1 · The watcher and the manifest (Mac)
- A launch agent runs `sync/bin/live.zsh`, woken by FSEvents (the system's file-change notice) on every worktree
  found by `git worktree list` (Decision 1).
- **Debounce:** run only after no write for $T_d = 5\,\text{s}$ (assumption: enough to skip a burst of saves; measure).
- Per worktree it writes one `live.json`: branch, HEAD, and for every modified or untracked path:
  `path · status (M/A/D/?) · mtime (ISO UTC) · sha256 · +added −deleted · state (BUILT / UNBUILT / UNKNOWN)`.
- Age shown to the reader: $\text{age} = t_{\text{now}} - t_{\text{mtime}}$, shown as "3 min ago" (under 60 s: "just now").
- **Skip list** (never listed, never snapshotted): anything in `.gitignore`, `.env*`, `Secrets/`, `*.key`, `*.pem`, `node_modules/`, `.build/`.
- Targets: manifest written within 2 s of the debounce firing, for a worktree of up to 200 changed files (assumption, measure).
- Idle cost: no polling loop; zero CPU between events.

### P2 · The iPad view (read-only list)
- Screen: **Live edits** (Recense mobile › Library › Live edits; a Siri/Shortcuts name "Live edits" is owed, see Not built).
- One row per file: name, folder, "edited 3 min ago", `+12 −4`. Rows sorted by newest edit. Group header per worktree/branch.
- Visible controls: **Refresh** button (pull down also works, never alone), **Make review snapshot** button (P3).
- Tapping a row shows the file's diff, large text, narrow column.
- Reads the manifest by the catch-up ladder: **LAN first** (Bonjour, same Wi-Fi), then the hub, then R2 only if the owner enabled it.
  It never blocks: the list shows the last copy with "as of 14:02" and updates when a newer one arrives.
- Offline (no Mac in reach): shows the last copy, marked "Mac not reachable".

### P3 · The review snapshot (Mac, triggered from either side)
- `git stash create` builds a commit object of the work **without touching the branch or the working files**
  (assumption: it includes tracked changes only; untracked files are added with `git ls-files --others --exclude-standard`).
- Output into `.handoff/coordinator/inbox/live/` (attachments) and `inbox/` (the note, via `coord.zsh post - live`):
  - `live/<YYYYMMDD-HHMMSS>-<worktree>.patch` (the diff, the main artifact: small and readable).
  - `live/<YYYYMMDD-HHMMSS>-<worktree>.zip` only for untracked or binary files a patch cannot carry; built from the manifest's list, never the whole folder.
  - the note (posted, so named by `coord.zsh`): first line `REVIEW SNAPSHOT: <worktree> @ <stash-sha> (UNBUILT|BUILT)`, then branch, base commit, file list, state, checks run, unchecked, attachment paths, signed with the id line.
- **Size cap:** zip at most 25 MB; above that the note lists the files and names them, no zip.
- The same step runs `coord.zsh post - live` on the note. On the Mac it also prints `READY FOR REVIEW: <worktree> @ <stash-sha> (UNBUILT|BUILT)` for an author who chooses to send it; the iPad button never sends it (Decision 2).
- A snapshot is labelled `BUILT` only if the project's cheapest check passed just before; otherwise `UNBUILT`. It never claims more.
- Snapshot refs live under `refs/wip/<worktree>/<stamp>` (local only; never pushed to `main`).

## Invariants (a test can check)
1. The branch's HEAD and the index are byte-identical before and after a snapshot.
2. No path in the skip list appears in the manifest, the patch or the zip.
3. Two saves 3 s apart produce one manifest write, not two.
4. The patch applies cleanly to the base commit (`git apply --check`).
5. With the Mac unreachable the iPad still opens the last manifest copy.
6. A snapshot never changes any file outside `.handoff/coordinator/inbox/` (including `live/`) and `refs/wip/`.

## Home and code layout
- **home:** `sync/src/livestate.mjs` (build the manifest, apply the skip list, make the snapshot, name the files). Everything else is glue.
- Mac glue: `sync/bin/live.zsh` (FSEvents wake, debounce) and `sync/launchd/com.chauphan.live.plist`.
- iOS glue: `mobile/HostApp/iOS/LiveEdits.swift` (the list), reading the manifest through the existing transfer path.
- Tests: `sync/test/livestate.test.mjs` (invariants 1–4, 6); a Swift decoding test for the manifest in `shared/ShowsKit/` (only if the model lands there).

## Embodiments
- Mac: P1, P3 (the watcher and the snapshot).
- iPhone: P2 (view), P3 trigger button.
- iPad: P2, P3 trigger button (same build; the owner's request).
- Web: n/a, the manifest is private to the owner's devices; no web viewer.

## Debug-channel events (`~/Recense/logs/live.jsonl`)
`live.manifest.written` (worktree, files, ms) · `live.manifest.skipped` (reason) · `live.snapshot.made` (worktree, files, bytes, state) · `live.snapshot.refused` (reason: size, secret) · `live.view.refreshed` (source: lan|hub|r2|cache)

## Offline-first gate (outside services)
- FSEvents, git, zip: on the Mac, local. Not network.
- LAN (Bonjour) and the hub: ours. Needed to reach the iPad only; catch-up, never blocking.
- R2/Cloudflare: optional last rung (FEAT-22); not required; migration is the existing hub path.
- Setup once: none. No outside SDK.

## Done checks
- `npm test` in `sync/` passes (invariants 1–4, 6, run 5 times).
- The launch agent: `plutil -lint`, every path exists, the next run ends OK in `~/Library/Logs/`.
- iOS compile from the project CLAUDE.md; **no simulator evidence**.
- Device checks below on the owner's iPad through iPhone Mirroring (iPad build tested on the real iPad).

## Device checks
1. Mac: edit any file in a worktree, wait 6 s, then: `tail -2 ~/Recense/logs/live.jsonl` shows `live.manifest.written`.
2. iPad (once, pairing: on the Mac `recense-hub pair | pbcopy`; on the iPad Library › Live edits › **Paste**; the hub's root profile must be trusted, FEAT-18): open Library › Live edits; the file appears with "just now" within 10 s (assumption, measure).
3. iPad: tap **Make Review Snapshot** under the worktree; then on the Mac: `ls -t ~/Developer/recense/.handoff/coordinator/inbox ~/Developer/recense/.handoff/coordinator/inbox/live | head -6` shows the `-live.md` note and the `.patch`.
4. Mac: `git -C ~/Developer/recense status --short | head` is unchanged by step 3 (invariant 1).
5. Offline proof: iPad Wi-Fi off; Library › Live edits still opens and reads "Mac not reachable", showing the last copy.
6. Secret proof: create `.env` in a worktree with a fake line; it never appears in the list, the patch or the zip.

## Decisions (answered 2026-11-19; supersede the two open questions)
1. **Worktrees: all, discovered, not listed.** The watcher takes every path from `git -C ~/Developer/recense worktree list --porcelain`
   (main checkout, `.claude/worktrees/*`, and lanes elsewhere, e.g. `~/.gemini/antigravity/worktrees/`; **checked**: one exists today),
   re-read on every wake so a new lane appears without setup. Skipped: prunable or missing paths, and paths named in
   `~/.config/recense/live-ignore` (one path per line; optional, absent by default). A worktree with no changes writes no entry.
   Why: a list to maintain is the chore the owner declined to track; the skip list (P1) already protects secrets.
   **Assumption:** FSEvents on many worktrees stays cheap; measure idle CPU after build (target: 0 between events).
2. **The iPad button files the snapshot; it does not send `READY FOR REVIEW`.** It runs P3 and posts the note to the inbox
   (`coord.zsh post - live`). The note's first line is `REVIEW SNAPSHOT: <worktree> @ <stash-sha> (UNBUILT|BUILT)`, never `READY`.
   Why (rule): `READY FOR REVIEW` asserts the author's checks passed (global CLAUDE.md, review dialogue step 1); a button cannot know that.
   Why (fact, **checked**): the coordinator reads `inbox/` itself (`coord.zsh inbox`; `state-check` flags files open over 24 h),
   so filing is enough; `SendMessage` exists only inside a Claude session on the Mac, never on the iPad.
   The Mac side still prints the `READY FOR REVIEW` line for an author who ran the snapshot and wants to claim it.

## Corrections from reading `coord.zsh` (2026-11-19, **checked**)
- `coord.zsh post` moves the file and names it `<yyyymmdd-hhmm>-<sid8>[-kind].md`; the note cannot keep the name `live-<worktree>-<stamp>.md`.
  Spec now: the note is posted with kind `live`; the `.patch` and `.zip` sit in `.handoff/coordinator/inbox/live/<stamp>-<worktree>.{patch,zip}`
  and the note names them. (`coord.zsh inbox` globs `inbox/*.md` only, so the attachments never show as messages.)
- **Manifest is one file, not one per worktree** (2026-11-19, derive): `~/Recense/live/live.json` = `{generated, worktrees:[{name,path,branch,head,files:[…]}]}`.
  One file is one transfer and one "as of" time for the iPad. Written atomically (tmp + rename); skipped when nothing but `generated` would change.
- **BUILT / UNBUILT / UNKNOWN** (the spec left it open): `zsh sync/bin/live.zsh built` run in a worktree after its cheapest check passes touches
  `<gitdir>/recense-built`. A file is BUILT if its mtime ≤ that stamp, UNBUILT if newer, UNKNOWN when no stamp exists. A snapshot is BUILT only if every file is BUILT.
- **Snapshot via a temporary index** (replaces the `git stash create` assumption, which can refresh the real index and so break invariant 1):
  `GIT_INDEX_FILE=<tmp> git read-tree HEAD`, `git add -A -- <allowed paths>`, `write-tree`, `commit-tree -p HEAD`, `update-ref refs/wip/…`. The real index is never opened for writing.
  Untracked text files are in that commit, so the patch carries them; the zip carries only **binary** files (the patch excludes them so `git apply --check` stays clean).
- **Noise list** (listed nowhere; unlike the skip list it is not about secrets): `.handoff/coordinator/`, so snapshots and posts never re-trigger the watcher.
- **Watcher** is a long-running `node livestate.mjs watch` under launchd `KeepAlive`, using `fs.watch(dir,{recursive:true})` (FSEvents on macOS; **assumption**, tested by a real write).
  launchd `WatchPaths` is not recursive, so it cannot do this job.
- **Transfer is not built yet:** FEAT-22's ladder does not exist; the hub (`hub/`, **checked**) serves `/api/health` and `/api/note` only. Slice 2 adds `GET /api/live` (token) and `POST /api/live/snapshot` (token) to the hub.
- Invariant 6 reads: a snapshot changes nothing outside `.handoff/coordinator/inbox/` (including `live/`) and `refs/wip/`.
