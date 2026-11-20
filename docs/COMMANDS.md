# Commands

Every build, test, sync, deploy and account command, one line and one example each.
Each example was copied from the repo or a script's own header, and its path was checked to exist on 2026-11-20 (**ran**: `ls`; `cswap --help` run). Commands that build or install were not run.
Run from the repo root unless the example starts with `cd`.

## Build and run

- Mac app. Builds and installs Recense.app (`strip/build.sh:2-7`).
  `zsh strip/build.sh universal`
- Mac app in a worktree. Needs the main checkout's toolchain, or it builds without the on-device ears.
  `RECENSE_TOOLCHAIN=~/Developer/recense/.toolchain/CommandLineTools zsh strip/build.sh`
- iPhone and iPad app. Builds and installs on a connected device. Run outside the Claude sandbox.
  `zsh mobile/ios/build.sh <UDID>`
- iOS compile check (not a delivery).
  `xcodebuild -project mobile/ios/GalleryFiles.xcodeproj -scheme GalleryFiles -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
- iPhone Mirroring screenshot of the app on the real phone.
  `zsh mobile/ios/mirror-shot.zsh "$TMPDIR/shots/home.png" --launch`
- Mobile's Mac build.
  `zsh mobile/macos/build.sh`
- Draftpad editor bundle. Commit `editor/dist/editor.html` afterwards.
  `cd editor && npm run build`
- Hub (the Mac-side server). Build and selftest, from `hub/README.md:25`. Outside the sandbox.
  `cd hub && DEVELOPER_DIR=~/Developer/recense/.toolchain/CommandLineTools swift build --build-system native --scratch-path .build-sdk27 && .build-sdk27/debug/recense-hub selftest`
- Hub install on the Mac.
  `zsh hub/install.zsh mac`
- Audiobook (Python). Needs `KOKORO_DIR`.
  `python3 text/audiobook.py <speech.md> <out.m4b> <title> [voice]`

## Test

- Mac app selftest, after a build.
  `strip/recense selftest`
- Editor.
  `cd editor && npm test`
- Gallery (Worker and web).
  `cd library && npm run build:test && node test/<file>.test.mjs`
  `cd library && npm test`
- Calendar Worker.
  `cd calendar && npm test`
- Sync jobs (seven selftests chained).
  `cd sync && npm test`
- ShowsKit.
  `cd shared/ShowsKit && swift test`
- A feature's checks and its unchecked devices (reads `docs/specs/PARITY.md`). **It runs every `check:` line of the block, which can build and takes the build lock.** Run it only when a build is wanted.
  `zsh sync/bin/triage-merge.zsh checks draftpad`
- Second copies of a feature's symbols outside its home.
  `zsh sync/bin/triage-merge.zsh sweep draftpad`

## Sync and jobs on the Mac

- Wish order.
  `cd sync && node src/wishrank.mjs`
- Sync canary.
  `cd sync && node src/canary.mjs start`
- Docs to Gallery Main. Dry run first.
  `zsh sync/bin/docs-sync.zsh --dry-run`
- Images to R2, link on the clipboard, originals to the Trash after the checksum matches.
  `zsh sync/bin/offsite-image.zsh <file>`
- Renew the iOS app's 7-day profile (launchd runs it daily).
  `zsh sync/bin/resign-ios.zsh`
- Mac autoupdate (builds the installed app from main).
  `zsh strip/scripts/install-autoupdate.sh status`
- Resume an agent after a usage limit (launchd runs it every 15 minutes).
  `agent-resume --dry-run`

## Coordinator

- Who holds the lease.
  `zsh sync/bin/coord.zsh who`
- Post, list and close messages.
  `zsh sync/bin/coord.zsh post <file>`
  `zsh sync/bin/coord.zsh inbox`
  `zsh sync/bin/coord.zsh done <file>`
- Pick a review judge who did not write the branch.
  `zsh sync/bin/coord.zsh assign <branch>`
- Selftest.
  `zsh sync/bin/coord.zsh selftest`

## Deploy

- Gallery Worker: push to `main` touching `library/**`. The workflow runs `npm ci`, Playwright, `npm test`, then `wrangler deploy` (`.github/workflows/library.yml`).
- By hand.
  `cd library && npx wrangler deploy`
- Calendar Worker.
  `cd calendar && npx wrangler deploy`

## Accounts

Four Claude Pro accounts, one `cswap` (claude-swap).
- List accounts and show the current one.
  `cswap list`
  `cswap status`
- Open a new terminal as account N without changing the live login.
  `cswap run 2`
- Switch the live login.
  `cswap switch 2`
- Shell aliases `open-*` and `switch-*` wrap these (`~/.zshrc`).
- Settings, skills and project history are shared across accounts by symlink, so `claude --resume <session-id>` works from any of them.

## Law helpers (after the hooks are installed, `docs/law/instructions.md` section 5)

- Declare loci before an edit.
  `recense-locus declare "saveEvents" "Patch all loci together" strip/editorhost.swift:480-516 mobile/HostApp/iOS/Draftpad.swift:334-368`
- Check a document's citations: the command in `docs/law/instructions.md`, section 7.

## Known stale items (flagged, not fixed here)

- `sync/CLAUDE.md:35` says `npm test` "runs both selftests"; it now chains seven. (Local file.)
- `docs/reference.md:166` describes the old standalone `main.swift` build.
- `~/.local/bin/coordinator-memory-check` still cites `PLAYBOOK.md`, which moved to `coordinator/archive/PLAYBOOK-archive.md`.
- `~/Developer/auditor/README.md` Quick start uses `~/Developer/bar-auditor/...`, a path that does not exist.
- `night-run` (`~/.local/share/night-run/night-run`) is written but **not installed**: its runner and allowlist are absent, so `night-run request <name>` fails.
- Scripts with no header comment: `editor/scripts/build.mjs`, `reference/pomo/build.sh`, `sync/tools/hetzner-check.py`, `sync/tools/claude-exporter.js`.
