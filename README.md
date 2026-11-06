# Recense

One system in three states: the strip on your Mac, the library in your cloud, and the sync that carries one into the
other. Offline first: the network is an optimization, not a dependency.

The longer essay, on improvisation, the measure of a gift, a score for speech and a shared tuning for the world's ideas,
is [the preface](docs/recense-preface.md).

| Folder     | What it is                                                     | Build or run                                       |
|------------|----------------------------------------------------------------|----------------------------------------------------|
| `strip`    | Recense.app for the Mac: the strip, listening surface, sound engine, menu-bar hider, Draftpad ([README](strip/README.md)) | `zsh strip/build.sh` |
| `library`  | Gallery: the Worker, web app, share links, and the iPhone, iPad and Mac apps ([README](library/README.md)) | deploys on push to `library/**` |
| `sync`     | the Mac's jobs, ledger, canary and launch-agent copies ([README](sync/README.md)) | launch agents in `sync/launchd/` |
| `calendar` | your calendar server (CalDAV Worker)                           | `cd calendar && npx wrangler deploy`               |
| `docs`     | plans, specs, runbooks, decisions, Recense's design docs       | start at `docs/PROGRESS.md`                        |
| `notes`    | task tables: Recense's here, Gallery's in `notes/gallery/`, Sync's in `notes/sync/` | —                   |

Recense's own sources also live at the root: `datasets/` (hello-pronunciation), `reference/` (read-only sources) and
`export/` (project description, north star, decisions).

The player Gallery and Recense share (home bar, key labels, rooms, prosody) has one home, `library/src/client/`;
`strip/build.sh` copies it into the app and stops if a file is missing.

## Status
One repo since A15 (2026-11-05): Gallery (`louan-dev/gallery`) and Sync (`louan-dev/sync`) joined with their full
history, so `git log library/src/main.js` reaches Gallery's first commit. Each app still builds, tests and deploys on its
own; Recense never depends on the Worker. The plan is `docs/specs/unified-offline-first-and-redesign.md`.
On this Mac the old `~/Developer/gallery` and `~/Developer/sync` folders are gone; the launch agents run
`~/Developer/recense/sync/bin/*`, and `~/Developer/sync` is a temporary link to `recense/sync`. Several Claude Code
sessions can work at once, one worktree per part: `/recense <file or word>` (`.claude/skills/recense/SKILL.md`).

## What works offline
Recense entirely: transcription, the light, loops, speed, sound and Draftpad run on the Mac. Gallery's apps keep what
they've cached; share links, the web app and CalDAV need the internet.
Cloudflare is storage and caching only, kept replaceable: the plan is a one-command move to a Mac mini, and nothing
should stop working because a signature, subscription or vendor expires.

## Privacy
Client matters never enter this repo. Secrets stay out of git: `.dev.vars`, `rclone.conf`, `.env`, wrangler's
`.wrangler/` cache and the iOS device token are ignored.
