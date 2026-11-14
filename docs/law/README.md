# Recense law

The rules every decision about Recense's code, changes and upkeep must follow.
Read this folder before planning work in any part of the repo.

## The files
- `purpose.md` — what Recense is, and the principle behind every feature.
- `structure.md` — the names, the folders, where a feature goes, how parts stay separate.
- `offline.md` — what may need a network, and when.
- `interaction.md` — how every screen, gesture, sound and haptic must behave.

## Order of authority (highest first)
1. The owner's words, dated.
2. The owner's global rules (`~/.claude/CLAUDE.md`). Not repeated here; this folder only adds to them.
3. This folder.
4. Specs (`docs/specs/`), binding as `.claude/rules/spec-and-index-law.md` says.
5. Design notes (`docs/architecture.md`, `docs/specs/organism.md`, proposals): *how* a thing works, never *what* Recense is.
6. Code.

A lower layer never overrides a higher one.
On a conflict, fix the lower document first, then the code.

## Fact, rule, open question
Each statement here is one of three kinds:
- **Rule** — binding. Plain sentences.
- **Fact** — checked; it names its evidence (a commit, a test, a file).
- **Open** — marked `Open:`; not binding until the owner decides.

An idea is not a requirement because it appears in the vision.
A spec promotes it; until then it lives in `~/.claude/context/recense/notes/WISHES.md`.

## Amending
- Only the owner changes a rule.
- The change is dated in the file's `Amendments` list, with what it replaces.
- An agent that finds a rule wrong or stale proposes the change in its handoff; it never edits a rule on its own.

## Sources
- The owner's note of 2026-11-05 ("the 3-layer sync unification project is multimodal by nature").
  Original kept private: `~/.claude/context/recense/research/2026-11-05-three-states-note.md`. This repo is public.
- The earlier Claude Project pack (`export/`): its north star, architecture, design philosophy and decisions
  are replaced by this folder (git history: `3b462d0`); the rest is archived in `docs/archive/export/`.

## For a Claude Project
Upload this folder plus `docs/specs/INDEX.md`. It replaces the old `export/` pack.
When files here change, re-upload them so the Project's chats see the same law.

## Amendments
- 2026-11-14 · created from the 2026-11-05 note; replaces `export/00_NORTH_STAR.md`, `02_ARCHITECTURE.md`,
  `03_DESIGN_PHILOSOPHY.md`, `06_DECISIONS.md`, and the "Names" section of `docs/architecture.md`.
