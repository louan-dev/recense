# Spec index · read this before planning or coding

**Specs are law; code is derived from them.**
If behaviour and spec disagree, fix the spec first, then the code.
Rules: `.claude/rules/spec-and-index-law.md`.
Skills: `/spec` (idea → spec), `/derive` (spec → tests → code), `/bug` (red → green → guard).

## Status
- `[ ]` written, not built
- `[~]` building
- `[x]` built and checked

## Where things live
- `triage.md` — raw notes and `T-####` entries (local only, not in git).
- `ui-teardowns/UI-xx-*/` — studies of other apps: `NOTES.md` in git, screenshots local only.
- `bugs/BUG-xx-*.md` — bug specs and their guard invariants.
- `_raw/`, `_traces/` — dumps and logs; Claude may not read them.
- **Local-only risk:** screenshots and `triage*.md` have no git copy.
  `git clean -X` or trashing `docs/specs/` loses them; keep them in the backup.

## Specs
Row: ID · title · status · From · code pointer

### UI teardowns
- UI-01 · Photos video viewer (iOS) · `[~]` · owner 2026-11-08 · `library/src/client/viewer-shell.js`, `viewer-sheet.js`
- UI-02 · Podcasts (iOS) · `[~]` · owner 2026-11-08 · `shared/ShowsKit/`
- UI-03 · Shared playlist (Spotify, iOS) · `[ ]` · owner 2026-11-08 · —
- UI-04 · Apple Pencil Pro mechanics (Notability study) · `[~]` · owner 2026-11-11 · `editor/src/ink.js`, `mobile/HostApp/iOS/Draftpad.swift`

### Bugs
- BUG-01 · Squeeze-hold menu stuck after hover loss or palm cancel · `[ ]` (anticipated) · owner 2026-11-11 · —

### Earlier specs (same folder, older format)
- `cloud-lab-integrations.md` · Cloud Lab integrations
- `cloud-worker-handoff.md` · Cloud Worker hand-off
- `event-log.md` · Sync event log format
- `gallery-nervous-system.md` · Gallery nervous system
- `manager.md` · Calendar commitment manager
- `organism.md` · Sync · Gallery · Recense as one organism
- `switchboard-spec.md`, `switchboard-scheduler-addendum.md` · Switchboard
- `sync.md` · Sync foundation
- `translation-pipeline.md` · Translation pipeline
- `unified-offline-first-and-redesign.md` · Offline-first + redesign
