# FEAT-21 · One search: transcript words, notes and titles together

From: owner 2026-11-16 (design review; T-0045 and T-0046 behind it) · Status: `[ ]` written, not built
Linked specs: FEAT-07 (the pill's Find, one item) · FEAT-23 (notes) · FEAT-22 (where the index lives) ·
FEAT-08 P4 (searchable audio and ink inside a page).

Labels: **proven** = a test or the code shows it (file:line) · **assumed** · **untested**.

## Verdict
**One matching rule, one index format, two entrances that never overlap.**
- Inside one item: the pill's Find (built, FEAT-07).
- Across everything: Library › Search (the screen exists; today it finds names only).
No third search box anywhere.

## Terms
- **Fold:** turning text into its plain form before comparing: lower case, accents off, đ → d, full-width
  letters as narrow. "Đường" and "duong" then match.
- **Index:** a small derived file that makes search fast. Derived means it can be deleted and rebuilt
  from the transcripts and notes at any time. It is never the only copy of anything.
- **Hit:** one place where the typed words were found.

## Rules
1. **One fold rule everywhere.** The rule the pill already uses. Never a second, slightly different matcher.
2. **What is searched:** the title and show name; every transcript line, in the language spoken;
   every stored translation of it (English, Tiếng Việt, Français); every line of every note.
3. **Accents are ignored unless you type them.** A query typed without accents matches with or without.
   A query typed with accents lists exact-accent hits first, then the rest under "Also, without accents".
   - Why: Vietnamese words that differ only by tone mark (ma, má, mà) would otherwise drown the result.
4. **Results are grouped by item, one column, large text.** Each row: the title, then up to three hits.
   A hit shows its time (`12:04`) or "Note", the line, the match in bold. "12 more in this item" opens the item's Find.
5. **A hit is a place.** Transcript hit: plays from that line and opens Now Playing with the pill's Find holding
   the same words (so the ruler shows the marks, FEAT-07 rule 1). Note hit: opens the note at that line.
6. **The pill hands over, it does not duplicate.** Under the pill's own results, one last row:
   "Search everything for "…"". It opens Library › Search with the words already typed.
7. **Search never waits for the network and never blocks typing.** It covers what is on this device.
   Items known only by name (not downloaded here) show under "Not on this device" by title match only.
8. **Privacy by role.** A locked item (Matters, Raven) is searched only while unlocked. Guest never searches
   the owner's vault (FEAT-22).
9. **Budget (binding numbers).** On the owner's Mac archive and on the iPhone 12 Pro Max:
   first results within 200 ms of the last key; loading the index when Search opens within 1 s.
10. **Find inside a note** stays the editor's own Find (`editor/src/search.js`), which also reads handwriting.
    It gets the same last row as rule 6.

## The index
- **One file per item, next to its note:** `keep/<key>/find.tsv`. UTF-8 text, one line per row, tab-separated:
  `kind · seconds or note line · language · the text as written`.
  - `kind`: `T` transcript line, `R` translation, `N` note line, `H` title.
- **Plain on purpose:** it is the item's whole text as a readable file. `grep` works on it in 10 years.
- **Rebuilt, never synced.** Each device writes it when a transcript completes, a translation lands, or a note is saved.
  A missing or older file is rebuilt on the next search. Deleting `find.tsv` loses nothing.
- **How it is searched (step 1):** when Search opens, all `find.tsv` files are read into memory once, folded, and scanned.
- **How it is searched (step 2, only if step 1 misses the budget):** one SQLite full-text table per device
  (FTS5, part of the SQLite that ships with macOS and iOS), filled from the same files, still derived.

## What exists (checked 2026-11-16)
- **proven** The fold and the matcher exist twice, rule for rule, with shared fixtures:
  Swift `shared/ShowsKit/Sources/ShowsKit/TranscriptFind.swift:9` (`fold`), `:15` (`hits`), tests `TranscriptFindTests`;
  JavaScript `library/src/client/homebar.js:231`, test `library/test/find.test.mjs` (4 pass, per FEAT-16's handoff).
- **proven** Library › Search finds names and titles only: `shared/ShowsKit/Sources/ShowsKit/Views/Search.swift:1-2`
  ("transcripts and extracted text join through B1's local index": that index was never built).
- **proven** Size today: 537 transcripts, 110 MB of JSON on the owner's Mac (`~/Recense/keep/*.v2.json`,
  counted 2026-11-16). Most of that is per-word timing, not text.
- **assumed** The text alone is about a twentieth of that (5 to 10 MB). P1's first check measures it.
- **proven** FTS5 is present in this Mac's SQLite (a table was created with it in a throwaway memory database, 2026-11-16).
- **proven** FTS5's own accent removal does not fold đ: "đường" was not found by "duong" in that same test.
  So our fold runs first in both steps; FTS5 never replaces rule 1.
- **untested** FTS5 on the iPhone and iPad (documented by Apple's SQLite build; not run here).
- **untested** The 200 ms budget. No measurement exists yet.
- **proven** The editor's Find already reads handwriting: `editor/src/index.js:975-985` (`setInkSearch`).

## Outside services
- **At the moment of use: none.** The index and the search are on the device.
- **Setup: none.** SQLite is part of the system; no download.
- **Catch-up:** none of its own. Transcripts and notes arrive by FEAT-22; each device then indexes them itself.

## Phases (each ends with its check)
- **P1 · The index file and the matcher (ShowsKit, no screen).**
  - Check 1: test: a fixture item (two transcript lines, one translation, one note) gives the expected `find.tsv`.
  - Check 2: test: rule 3 on "ma", "má", "duong", "Đường".
  - Check 3 (measure, written into this spec): text size and scan time for the owner's Mac archive, and for a
    made-up archive of 5,000 items × 300 lines. If either misses rule 9, P1b builds step 2 before P2.
- **P2 · Library › Search shows hits** on Mac, iPhone, iPad (one ShowsKit view).
  - Check: device run: a word that occurs only inside one transcript returns that item; tapping plays from the line.
  - Baseline to beat: Apple Podcasts cannot search inside transcripts across episodes. Done = the 3rd mention of a
    word across two episodes reached in under 10 s, 3 tries, numbers recorded here.
- **P3 · Notes join** (after FEAT-23 P0). Check: a word typed only in a note returns "Note" hits; tap opens the line.
- **P4 · Hand-over rows** (rules 6 and 10) on the pill, the web pill and the editor's Find.
  Check: UI test: the row opens Search with the same words; no second search field exists on any screen (audit).
- **P5 · The web** (Gallery): the same `find.tsv` read by the page for the items it has. Check: `find.test.mjs` extended.

## Risks and edge cases
- **Chinese, Japanese, Thai** have no spaces. Step 1 (substring scan) finds them; step 2 (FTS5 words) would not
  without extra work. Recorded; step 2 must keep the substring path for such text.
- **A transcript still being made** is indexed when complete (FEAT-16's rule: complete before play).
- **Memory.** If the folded text passes 50 MB in memory on any device, step 2 becomes mandatory there.
- **Two entrances drifting apart.** Guard: one fixture file, read by the Swift test and the JS test (as today).
