# BUG-16 · A song dropped into downloads/ never reaches Music
From: T-0080 (owner 2026-11-15: "why is my music in ~/Recense/downloads not in the music library automatically")
Status: `[~]` first fix built; second fix (the next pass) built 2026-11-16, neither compiled nor device-checked

## What happened
- "Гарик Кричевский. Туманы.m4a" landed in `~/Recense/downloads/` at 11:04, saved by another app (Pulltube, Finder or AirDrop).
  It stayed there.
- FEAT-12 settles audio into Music only on Recense's own download paths. Files other apps drop in are adopted only by
  `recense download --adopt`, which nothing ran.

## Fix
- `Downloads.sweep()` (shared): adopt, then settle audio into Music. It also settles entries adopted earlier but never settled.
- Mac: `Downloads.watchFolder()` watches `downloads/` and `downloads/Pulltube/`. 3.5 s after a change it runs adoptAndCheck
  (probe), then the sweep. It runs once at launch too.
- iOS: the sweep runs at launch and on every return to the app.
- A file changed under 3 s ago, or with a partial name (.part, .crdownload, .download), waits for the next pass.

## Still broken, reported again (owner, 2026-11-16: "Pulltube downloads aren't showing up in recense")
The first fix was never device-checked, and a static read found why it cannot have worked for a real download.

**The code half — there was no next pass.** `watchFolder()` scheduled exactly one pass `retryFloor` after a folder
event, and `ready()` skips any file whose mtime is under `quiet` (3 s). The line below promised such a file "waits for
the next pass", but the only things that scheduled a pass were a folder event and app launch — and a download
*finishing* changes no directory entry, so it fires no folder event of its own. A file created and then written for
longer than one debounce was therefore skipped by its only pass and never looked at again until Recense was
relaunched. Every real Pulltube download is slower than 3.5 s, so this is all of them. The selftest missed it because
tests set `quiet = 0`, which makes every file ready the instant it is written.

**The second fix.** `waiting()` reports media the watcher can see but cannot take yet (still being written, or wearing
a partial name). A pass that finds anything waiting schedules the next one itself, doubling `retryFloor` (3.5 s) up to
`retryCeiling` (30 s) and resetting to the floor on any folder event. So the watcher keeps looking exactly while a
download is in flight, and goes quiet the moment nothing is. A non-media partial (`notes.txt.tmp`) is not counted, so
an abandoned temp file never keeps it awake.
Modelled, not run (no Swift toolchain in the cloud container): a 120 s download is adopted 22.5 s after its last byte,
after 7 passes. Worst case is one `retryCeiling` after a download finishes.

**The config half — not ruled out, and only the Mac can answer it.** Adoption only ever reads `downloads/` and
`downloads/Pulltube/`, neither recursively. If Pulltube's own download folder is still `~/Downloads`, `~/Movies`, or a
per-playlist subfolder, nothing is ever adopted and the symptom is identical. `recense download --where` now prints
Recense's watched folders, what is waiting, and any folder named in Pulltube's own preferences, with a verdict on
whether the two agree. **Run that first:** if it says Pulltube saves somewhere unwatched, the code fix changes nothing
and the setting is the whole bug.

## Invariant (selftest, "Regression guard: BUG-16")
- An audio file dropped into downloads/ is in Music after one sweep and gone from downloads/.
- A file still being written stays put.
- **A file still being written appears in `waiting()`**, which is what schedules the next pass.
- **Once it is left alone, the next pass takes it with no new folder event.**
- A partial name is waiting, never adopted; `partialBase("song.m4a.part") == "song.m4a"`.

## Device check owed (the thing that would actually close this)
On the Mac, with `strip/` rebuilt:
1. `recense download --where` — confirm Pulltube's folder is one Recense watches.
2. Download something in Pulltube that takes more than 10 s.
3. Without touching Recense, confirm it appears: audio in `library/Music/`, video left in `downloads/`.
4. `recense selftest` (or the downloads selftest) passes, including the two new guards.
