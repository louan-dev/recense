# Structure

## Names (final)
- **Recense** — the whole project, and every app it ships (Mac, iPhone, iPad). Bundle id `local.recense`.
- **Gallery** — the library state. Its code is `library/`.
- **Sync** — the custody state. Its code is `sync/`.
- **Draftpad** — the writing surface inside Recense. Its code is `editor/`.
- **The menu-bar hider** — once a separate app called Nook; part of Recense since 2026-10-31 (`strip/hider.swift`).
  Say "the hider", never "Nook".
  "Nook" stays only in git history and in the one-time settings migration (`strip/hider.swift:23-31`),
  which must keep the old keys to carry old settings over.
- **Sill** — Recense's name until 2026-11-03. History only.

No part gets its own app name again. A new part gets a one-word folder.

## One repository
- **Fact:** `louan-dev/recense` (public) is the only repository.
  Gallery and Sync joined it with full history on 2026-11-05 (A15);
  `git log library/src/main.js` reaches Gallery's first commit.
- **Fact:** `louan-dev/gallery` and `louan-dev/sync` no longer exist on GitHub (checked 2026-11-14).
- The root `README.md` is the front page. It says what Recense is, the folder map, and how to build each part.
- Never in the repo: client matters, secrets, personal notes, screenshots, `triage*.md`.

## The folders
Each name is one word. Each part builds, tests and deploys on its own.
- `strip/` — Recense for the Mac.
- `mobile/` — Recense for iPhone and iPad.
- `shared/` — Swift that every Recense app compiles (incl. `ShowsKit`).
- `editor/` — Draftpad, one editor for every host.
- `library/` — Gallery: the Worker, the web app, share links; `library/src/client/` is the one player.
- `sync/` — the Mac's jobs, ledger, canary and launch agents.
- `calendar/` — the CalDAV server.
- `datasets/` — Recense's own training and test data.
- `reference/` — read-only sources we study.
- `docs/` — this law, specs, research, runbooks.
- `notes/` — the owner's live task tables.

Build commands and checks per folder: `.claude/CLAUDE.md` § Checks.

## How parts stay separate inside one repo
1. **Separate runtimes.** The Mac app, the iOS app, the Worker and the Mac jobs never share a process.
2. **One-way dependencies.** Strip → library modules (optional) → sync.
   Sync depends on nothing. Gallery never depends on the strip.
   Recense never needs the Worker to work.
3. **Contracts, not internals.** Parts meet through data formats (`keep/<key>/`, `Line`/`Word`, the event log),
   not through each other's private code.
4. **One feature, one source.** Shared logic lives where every embodiment compiles it;
   app folders hold glue only (`.claude/CLAUDE.md` § Parity).
5. **A feature knows nothing about its host.** It receives a host object and never names the app it runs in
   (`docs/architecture.md`, "The one rule that makes reuse work").

## Where a feature goes
Ask in order; the first yes wins.
1. Would it matter if nobody looked at it (truth, safety, moving bytes)? → `sync/`.
2. Is it a person experiencing, organizing or sharing media? → `library/`.
3. Is it this device, right now, across apps? → `strip/` and `mobile/`, logic in `shared/`.
4. Is it writing? → `editor/`.
5. Is it understanding audio (words, timing, voice, language)? → engine where the compute is, display where the viewer is.
6. None? A new one-word folder. Never stuffed into an existing part.

Source: `docs/specs/organism.md` §4. Its "don't fold" answer (§0, §3 H6) is superseded by A15.

## Working on one part
- **Ask by part, not by repo:** `/recense <file or word>` (e.g. `/recense player.js`)
  finds the part, its guide and its worktree (`.claude/skills/recense/SKILL.md`).
- **Several CLIs at once:** one worktree per area, `.claude/worktrees/<area>` on `work/<area>`.
  Only the main checkout is on `main`. Rules: `.claude/CLAUDE.md` § Sessions working together.

## Moving folders
- A folder moves only when the gain outweighs what it breaks:
  live worktrees, launch-agent paths, CI path filters (`.github/workflows/`), build scripts.
- A move is done only when the old path is gone everywhere (`.claude/CLAUDE.md` § Checks, "A move or rename").
- **Open:** grouping folders by shared feature instead of by device (e.g. one `player/`, one `ears/`).
  Not now: the current names are already one word, and 19 live worktrees depend on these paths (2026-11-14).

## Amendments
- 2026-11-14 · created; replaces `export/02_ARCHITECTURE.md` and the "Names" section of `docs/architecture.md`.
