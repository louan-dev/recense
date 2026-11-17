# FEAT-16 · The transcript is complete before the audio plays

From: T-0095 · Owner 2026-11-16 · Status: `[ ]`

## Rule
Pressing play on a piece that has no finished transcript shows one load indicator.
Nothing plays, and nothing scrolls, until the whole transcript is made, stored and loaded.
Then the audio starts with the transcript time-synced to the word (FEAT-04 content clock) and autoscroll on.
Model: Apple Podcasts (spinner, then audio and transcript together).

## Evidence: the owner's media (gallery share QymBYs2S7iPGdAOn4xFS, 2026-11-15)
- `IMG_4208.PNG` = Apple Podcasts, Now Playing: "Loading…" spinner where the transcript goes; the scrubber shows a spinner and `--:--`;
  the transport (15/30, speed, sleep) is already drawn; the transcript button is lit. Nothing scrolls yet.
- Screen recording (8 s) = Recense's caption panel over a Podcasts episode: the pause button shows (audio running) while Recense's
  blue loading dash spins the whole time, so audio is ahead of the transcript. The date line shows empty boxes (missing glyphs): T-0096.

## Evidence: Apple's Podcasts.app bundle (static strings only, no decompiling; behavior below is inferred, not run)
- `PodcastsTranscripts.framework`: transcript text is fetched ahead, not made while playing ("Fetched transcript identifier from MAPI for local
  episode with AdamId…"; it is dropped if that episode "is no longer playing").
- Timed data: `TimedMetadata`, `timedContent`, `createParagraphs(splittingBehavior:)`, `_durationFromPlayerStartTimeToFirstWordTime`.
- Sync gate: `TranscriptSyncingStateObserver`, `_isSyncing`, a `loading` state, `_bridgedUpdateContentUnavailableConfiguration…` (the spinner view).
- Follow: `_activeParagraph`, "scroll to paragraph from reset live tracking": autoscroll follows the active paragraph; a manual scroll
  breaks tracking and a control resets it.
- Search: `TranscriptSearchButton` (floating, own backdrop layer), `_searchRanges`, `_activeSearchRange`, `OFFLINE_SEARCH_TITLE`
  (search is a separate offline-capable mode).
- Lesson to copy: gate = syncing state; paragraph = unit of follow; search = a floating pill. Lesson to beat: Apple's transcript is made on
  their server; ours is made on the device, so the wait is real and must show progress.

## Facts (code read 2026-11-16)
- Mac: `Episode.transcribeLoop()` (strip/recense.swift ~3867) transcribes "the chunk being played first, then onward":
  playback and transcription run together. This is the behavior to remove for the play path.
- iOS: live captions (`mobile/HostApp/iOS/Listen.swift`, `Captions.swift`) are for outside audio (S0); stored shows use `ShowsKit` Transcript view.
- A finished transcript is `Cache.read(key)?.complete == true` (recense.swift ~3293).

## Phases (each gate = its check)
- P1 gate: pure function `canPlay(transcriptComplete:)`; selftest: false while any chunk is undone, true once `complete`. Mac strip.
- P2 gate: Mac play path shows the spinner, runs the transcription in whole-file order (no play-first chunking), starts audio only when `complete`; selftest + screenshot of the spinner.
- P3 gate (coded 11-16; `Ears.gate` selftest in mobile/ios/Tests/ears passes; installed iPhone + iPad; on-device check pending): iPhone and iPad (stored shows): same rule and spinner; checked on the device via iPhone Mirroring.
- P4 (view already follows the playhead with a "Now" reset, Transcript.swift; the gate makes the first frame whole; 10-min drift check pending on device): autoscroll and word sync start at the first frame of audio; no drift after 10 min.

- P5 gate: the FEAT-07 pill (search + scrubber, one pill) on every surface that shows a transcript: Mac strip window,
  iPhone and iPad stored shows, Listen episodes, the web player. Surface list in the spec's table is the check: each gets a screenshot.
  Design stays FEAT-07's; this phase only places it. Follow-reset control (Apple's "reset live tracking") ships with it.

**Revised 2026-11-16 (owner's design review):** what the pill holds is settled in FEAT-07 § "Revision 2026-11-16", part A:
magnifier · the stroke · Sound, and nothing else. Find's last row hands over to Search everything (FEAT-21 rule 6).
The Note button is in Now Playing's top bar, not on the pill (FEAT-23 rule 7). This phase still only places the pill.

### P5 surfaces (code read 2026-11-16, before coding)
The pill = FEAT-07's: Find (magnifier → find face: field, "2 of 5", ⌃ ⌄, waveform or a 0.35 s hold back) and the scrubber, one pill.
Follow reset = Apple's "reset live tracking": a hand scroll lets go of the voice; one visible control brings it back.

| Surface | Where (file:line) | Pill before P5 | Follow reset before P5 | P5 status |
|---|---|---|---|---|
| iPhone, stored shows (Now Playing) | `shared/ShowsKit/Sources/ShowsKit/Views/NowPlaying.swift:113` → `Views/Transcript.swift:269-280` → `Views/SearchPill.swift` | present (FEAT-07 P2) | "Now" `Transcript.swift:257-265`; ··· Follow the Playhead `:337`; hand scroll detaches `:366-372` | **coded, not compiled, device check owed:** hits kept as track marks after Back to Scrubbing; no magnifier without a transcript (`Transcript.swift:212-214`, `SearchPill.swift:28-36`) |
| iPad, stored shows | same ShowsKit code as iPhone | present | present | same ShowsKit change as iPhone: **coded, not compiled, device check owed** |
| Listen episodes (iOS) | `mobile/HostApp/iOS/Listen.swift:1497` (`seek: nil`, no `duration`) | Find face only; no scrubber (another app's audio cannot be moved) | present (same view) | Find only, by decision (see Decisions); gets the ShowsKit change (no magnifier without lines): **coded, not compiled** |
| Mac strip window | `strip/recense.swift:997-1209` `RecenseHomeBar` (WKWebView over `strip/homebar/index.html`, which runs Gallery's `library/src/client/homebar.js`) | scrubber only (homebar Time Seeking); no Find | not needed: one line on screen; a scroll turns the drum and plays from the line picked (`recense.swift:1962-1987`), so view and voice never part | **coded, not compiled, device check owed.** Find comes with `homebar.js`; `strip/homebar/index.html` (Find host, `Recense.lines`, pointer rects, `find` message); `strip/recense.swift` `pushFindLines()` + the `find` message (web view takes the keys). Host page checked in Chromium with a stub handler. |
| Web player (Gallery) | `library/src/client/gallery.js:1751` `Homebar.horizontal`; transcript `showTranscript` `:5017`, whole transcript `openAll` `:5293` | scrubber only (homebar Time Seeking); no Find | none: the whole-transcript sheet re-follows every line turn (`:6107-6117`) | **built and tested** (`library/test/ui.test.mjs` "FEAT-16 P5", `test/find.test.mjs`); screenshot local only (`docs/specs/FEAT-16-p5-web-pill.png`, git-ignored; regenerate: `cd library && FEAT16_SHOT=$PWD/../docs/specs/FEAT-16-p5-web-pill.png ONLY="FEAT-16 P5" node test/ui.test.mjs`) |

Not a transcript surface: the Mac's ShowsKit Library window (`LibraryShelf`, `Root.swift:162`) has no transcript view of its own.

## Hard limit: outside audio
Recense cannot hold back another app's audio. In the recording the audio is Apple Podcasts', so "do not play until complete" cannot apply there.
Nearest version that works now: when the piece is in Recense's own library, Recense plays it and the rule holds.
For outside audio: Recense shows the spinner and `--:--` and stays silent about sync until its transcript is whole (no half-synced scrolling).
Route to the full version: a one-tap "Play in Recense" that fetches the episode into the library, transcribes it, then plays it.
Untested: whether iOS lets Recense pause another app (assumed no).

## Risk and open choice for the owner
An hour of audio with no stored transcript may take minutes before it plays. The rule as written has no skip.
Recommended: show progress (percent), keep the rule strict, and let a transcript already stored play at once.

## Handoff (FEAT-16 P5, lane feat16-p5, 2026-11-16)

### Built, per surface
- **Web player (Gallery):** the pill's Find lives in `library/src/client/homebar.js` (`find()`, plus pure `findHits`,
  `findStep`, `findCount`, `fold`, rule for rule with ShowsKit's `TranscriptFind` / `SearchPill`). The magnifier sits at the
  stroke's start (only when the item has a transcript). Find takes the stroke's place: waveform (Back to Scrubbing),
  the field, "2 of 5", ⌃ ⌄. Enter = next, ⇧Enter = previous, Escape or a 0.35 s hold on the face = back. A hit seeks
  and plays (FEAT-07 rule 1). The hits of what's typed are marks on the time ruler (`.p-skhit`; no haptic on the web, rule 8).
  `gallery.js` passes the item's lines and the go. Escape folds Find before it closes the viewer.
  Follow reset: in the whole-transcript sheet (`openAll`), a hand scroll (wheel, finger, scroll keys) lets go of the voice
  and shows **Now**. Now (or playing a line) follows again. Before P5 the sheet snapped back at every line turn.
- **Mac strip window:** no new UI code. The strip's bar is the same `homebar.js`, so Find comes with it.
  `strip/homebar/index.html` gives Find the lines, seeks and plays a hit, posts the pointer rects of the magnifier and face,
  and tells main.swift when Find opens. `strip/recense.swift`: `pushFindLines()` (once a second, on change; times mapped
  as `onPick` maps a line) and the `find` message (makes the panel key and the web view first responder, as the line
  editor does). Follow reset: not needed (one line on screen; a scroll picks a line and plays it).
- **iPhone, iPad (stored shows) and Listen episodes:** the pill and "Now" were already there (FEAT-07 P2, ShowsKit). After the
  owner's delegation (Decisions below), two small ShowsKit edits, **coded, not compiled**: the hits of the typed text stay as marks
  and strong detents after Back to Scrubbing (`Transcript.swift:212-214`), and there's no magnifier without a transcript (`SearchPill.swift:28-36`).

### Tests run
- `node --test test/find.test.mjs`: 4 pass, 0 fail (same fixture and answers as `TranscriptFindTests.swift`).
- `ui.test.mjs` "FEAT-16 P5…": passes (Find, count, Enter/⌃/⌄, seek+play, translation search, "No matches", đ→d, Escape keeps
  the viewer and the text, one ruler mark, waveform back, Now after a wheel scroll).
- Full `npm test` (Chromium via `CHROMIUM=/opt/pw-browsers/chromium`): keylabel, ai, calendar, routes (both), feed (both),
  dav-rclone, transcript, learn, pieces, cadence and find pass. `ui.test`: 39 pass, 2 fail. Both also fail on `main` in a full
  run (main: 38 pass, the same 2 fail): "Home bar: Delete Cover…" (passes alone, fails only in a full run) and
  "SPEC P3 12: Download bakes in EQ…". `viewer.test`: 114 pass, 6 fail, the same on `main` (G3 touch drag, all six devices).
  `editorpwa` skips its browser steps (it doesn't read `CHROMIUM`).
- The strip host page (`strip/homebar/index.html` with the bundled client files) driven in Chromium with a stub
  `webkit.messageHandlers.recense`: magnifier only with lines; Find posts `find` on/off, `seek` (player time) then `playPause`;
  the face's rect is posted. This was a one-off check in the session's scratchpad; nothing was committed for it.

### Unverified
- Swift: `strip/recense.swift`, `Views/Transcript.swift` and `Views/SearchPill.swift` are **coded, not compiled**; `TranscriptFindTests` not run. No Swift toolchain in this container.
- Whether the strip's panel really gives the keys to the web view's field (`makeKey` + `makeFirstResponder(homeBar)`), and
  that Space, ←, → typed into the field don't reach the player.
- Swift is unchanged on iOS. The iPad and Listen screenshots the P5 gate asks for are still owed.

### What the owner must check, and on which device
1. **Mac:** build Recense (`strip/build.sh`). Follow a Gallery or browser player with a transcript. The magnifier shows left of the
   stroke. Click it, type a word: the count, ⌄ jumps and plays, Escape returns, the ruler (hold the stroke) shows a mark per hit.
   Screenshot the open pill.
2. **Web (Safari on iPhone and iPad, a Mac browser):** open a song with a transcript in Gallery. Same steps, then open the
   whole transcript, scroll by hand: Now shows and brings it back. Check that the iPhone keyboard doesn't hide the field.
3. **iPhone and iPad (iPhone Mirroring):** Now Playing on a stored show: the pill and Now as before. Screenshot each for the gate.
   Listen › a past episode: the magnifier only (see question 1).

### Decisions (the owner delegated them on 2026-11-16: "you decide what's best based on what I'd do")
1. **Listen episodes stay Find only, with no scrubber.** Their audio is another app's (§ Hard limit). A scrubber that moved only the
   text would break one control per function and the expectation that scrubbing moves the sound. Scrolling plus Now already
   moves the reading place.
2. **Hits stay places on the ruler** (FEAT-07 rule 1; a spec outranks the code). Swift now keeps the typed text's hits as track
   marks and strong detents after Back to Scrubbing, as the web does. Clearing the field clears them.
3. **No transcript, no magnifier**, on every surface (law, interaction.md: "shown only when relevant"). The scrubber stays.
4. **Screenshots stay out of the repo** (law, structure.md; the owner's `.gitignore` for `docs/specs/**/*.png`; the repo is public).
   The web screenshot is kept local beside the spec, with the command that regenerates it (table above). It was committed
   once in `bfd734e` and deleted later on this branch. **Merge this branch squashed**, so the image never enters `main`'s history.
