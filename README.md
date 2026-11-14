# Recense

One system in three states: the strip on your Mac, the library in your cloud, and the sync that carries one into the
other. Offline first: the network is an optimization, not a dependency.

The longer essay, on improvisation, the measure of a gift, a score for speech and a shared tuning for the world's ideas,
is [the preface](docs/recense-preface.md).

**The rules every code decision follows are [the law](docs/law/README.md):** what Recense is (one matter, many
states), how the repo is arranged, what may need a network, and how every screen, gesture and haptic behaves.

| Folder     | What it is                                                     | Build or run                                       |
|------------|----------------------------------------------------------------|----------------------------------------------------|
| `strip`    | Recense.app for the Mac: the strip, listening surface, sound engine, menu-bar hider, Draftpad ([README](strip/README.md)) | `zsh strip/build.sh` |
| `mobile`   | Recense for iPhone and iPad (the Mac app's mirror) and the retiring Gallery Mac app ([README](mobile/README.md)) | `zsh mobile/ios/build.sh` |
| `shared`   | Swift both Recense apps compile: Draftpad's file sync (`notesync.swift`), embeds (`embedfiles.swift`), and `ShowsKit`, the Podcasts-style skin: model, rules, catalog store and its SwiftUI views (spaces, Library, shows, Now Playing, the Face ID gate) ([README](shared/ShowsKit/README.md)) | built by each app; `swift test` in `shared/ShowsKit` |
| `library`  | Gallery: the Worker, web app and share links ([README](library/README.md)) | deploys on push to `library/**` |
| `sync`     | the Mac's jobs, ledger, canary and launch-agent copies ([README](sync/README.md)) | launch agents in `sync/launchd/` |
| `calendar` | your calendar server (CalDAV Worker)                           | `cd calendar && npx wrangler deploy`               |
| `docs`     | the law, plans, specs, research, runbooks, design docs         | start at `docs/law/README.md`, then `docs/PROGRESS.md` |
| `docs/specs` | specs, app teardowns, triage and the parity map (PARITY.md: where each feature lives on every device); screenshots and triage are local only (not in git): back them up, never `git clean -X` there | start at `docs/specs/INDEX.md` |
| `notes`    | task tables: Recense's here, Gallery's in `notes/gallery/`, Sync's in `notes/sync/` | —                   |

Recense's own sources also live at the root: `datasets/` (hello-pronunciation) and `reference/` (read-only sources).
The old Claude Project pack is archived in `docs/archive/export/`; upload `docs/law/` instead.

The player Gallery and Recense share (home bar, key labels, rooms, prosody) has one home, `library/src/client/`;
`strip/build.sh` copies it into the app and stops if a file is missing.

## Status
One repo since A15 (2026-11-05): Gallery (`louan-dev/gallery`) and Sync (`louan-dev/sync`) joined with their full
history, so `git log library/src/main.js` reaches Gallery's first commit. Each app still builds, tests and deploys on its
own; Recense never depends on the Worker. The plan is `docs/specs/unified-offline-first-and-redesign.md`.
On this Mac the old `~/Developer/gallery` and `~/Developer/sync` folders are gone; the launch agents run
`~/Developer/recense/sync/bin/*`. Several Claude Code
sessions can work at once, one worktree per part: `/recense <file or word>` (`.claude/skills/recense/SKILL.md`).
Gemini / Antigravity sessions work as lane workers too: `GEMINI.md` loads the same repo guide and adds the worker
loop (the lane's `INBOX.md` is their only channel from the coordinator). When the coordinator is out of reach, sessions
decide by its playbook (`.handoff/coordinator/PLAYBOOK.md`, local to this Mac) and log each decision in it.

## What works offline
Recense entirely: transcription, the light, loops, speed, sound and Draftpad run on the Mac. Gallery's apps keep what
they've cached; share links, the web app and CalDAV need the internet.
Cloudflare is storage and caching only, kept replaceable: the plan is a one-command move to a Mac mini, and nothing
should stop working because a signature, subscription or vendor expires.

## Privacy
Client matters never enter this repo. Secrets stay out of git: `.dev.vars`, `rclone.conf`, `.env`, wrangler's
`.wrangler/` cache and the iOS device token are ignored.
