# BUG-16 · A song dropped into downloads/ never reaches Music
From: T-0080 (owner 2026-11-15: "why is my music in ~/Recense/downloads not in the music library automatically")
Status: `[~]` fixed, device check owed

## What happened
- "Гарик Кричевский. Туманы.m4a" landed in `~/Recense/downloads/` at 11:04, saved by another app (Pulltube, Finder or AirDrop).
  It stayed there.
- FEAT-12 settles audio into Music only on Recense's own download paths. Files other apps drop in are adopted only by
  `recense downloads --adopt`, which nothing ran.

## Fix
- `Downloads.sweep()` (shared): adopt, then settle audio into Music. It also settles entries adopted earlier but never settled.
- Mac: `Downloads.watchFolder()` watches `downloads/` and `downloads/Pulltube/`. 3.5 s after a change it runs adoptAndCheck
  (probe), then the sweep. It runs once at launch too.
- iOS: the sweep runs at launch and on every return to the app.
- A file changed under 3 s ago, or with a partial name (.part, .crdownload, .download), waits for the next pass.

## Invariant (selftest, "Regression guard: BUG-16")
- An audio file dropped into downloads/ is in Music after one sweep and gone from downloads/.
- A file still being written stays put.
