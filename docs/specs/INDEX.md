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
- UI-05 · VoiceOS (voice dictation + edit + agent patterns) · `[ ]` · owner 2026-11-12 · `strip/app.swift:6249` VoiceEntry, `strip/speech.swift`, `strip/openears.swift`
- UI-06 · Draftpad page navigation, gesture-only (Antinote study): dots tap/drag/hold, slots, reopen, no ⌘ keys · `[~]` · owner 2026-11-15, T-0020/21/22/24 · D1–D4 date label added; G4 drag a dot to any place (T-0089); device check (Mac/iPhone/iPad) owed · `ui-teardowns/UI-06-antinote-navigation/UI-06.md`, `editor/src/pagemode.js`, `editor/src/index.js`

### Features
- FEAT-01 · Clean text → chaptered audiobook (TOML rule profiles, Kokoro M4B) · `[~]` · owner 2026-11-12 · `text/`
- FEAT-02 · P2P transport (Bluetooth + Wi-Fi, MultipeerConnectivity) · `[~]` P1–P3 built, device check owed · T-0035 · `shared/p2ptransport.swift`
- FEAT-03 · Share: consolidated cross-device destination · `[ ]` · T-0035 · `shared/mediadownload.swift` (reused pattern), `mobile/HostApp/macOS/Window.swift`
- FEAT-04 · Exact time sync for stored transcripts (fingerprint → content clock) · `[~]` P1+P2 built, P3 parked (aligner), P4 after FEAT-02 · owner 2026-11-12 · `shared/ShowsKit/Sources/ShowsKit/{Word,ContentClock}.swift`, `mobile/HostApp/iOS/Listen.swift`, `strip/handoff.swift`
- FEAT-06 · Homes: the folder contract on every device (+ carry C0 exit) · `[~]` P1–P3 built, device check owed · owner 2026-11-08 + 11-11 · `shared/homes.swift`, `strip/app.swift` (`recense carry`)
- FEAT-07 · Transcript search pill + haptic zoning; P0 the Music list (play, pause, loop, rename across devices, slide to delete) · `[~]` P0–P2 built (Music list, search pill on iPhone/iPad, translation on the voice), Mac pill and device check owed · T-0045, owner 2026-11-15 · `FEAT-07-search-pill-haptic-ruler.md`; `shared/homefiles.swift`, `shared/ShowsKit/Sources/ShowsKit/Views/{ShowPage,Cards,Root}.swift`, `strip/musicshelf.swift`
- FEAT-08 · Draftpad as one matter (the 12-move test) · `[ ]` · owner 2026-11-14 (T-0046, T-0050) · `FEAT-08-draftpad-one-matter.md`; `editor/`, `shared/notesync.swift`
- FEAT-09 · Carry between devices: pair once, then the same homes everywhere · `[~]` pairing + full ops-log settling (move/trash/restore replay, keep-both) built and wired end to end; pairing checked on Mac/iPhone/iPad 11-15 (BUG-17); P4 automatic carry built and tested, device check owed (T-0084); P1b pair by typing the code built and tested, device check owed (T-0086); text merge against a tracked base still open · owner 2026-11-11 + 11-14, T-0035, T-0047, T-0084, T-0086 · `shared/carrysync.swift`, `shared/carrypair.swift`, `shared/carrymanager.swift`, `shared/carryapply.swift`, `mobile/HostApp/iOS/PairIntent.swift`
- FEAT-10 · Translate the transcript as it plays (English, Tiếng Việt, Français), on the device · `[~]` iOS built, device check owed · T-0068 · `shared/translateplan.swift`, `mobile/HostApp/iOS/Translate.swift`
- FEAT-11 · iOS download engine (yt-dlp in embedded CPython + AVFoundation join, no ffmpeg) · `[ ]` spike PASS on iPhone 2026-11-14 · T-0049 · `spike/ios-ytdlp/`
- FEAT-15 · Bose Bridge: one pair of QC SC, many sources (route, seats, two symphonies at once) · `[~]` P1–P5 built, device check owed · T-0059 · `shared/bosebridge.swift`, `strip/bosebridge.swift`, `mobile/HostApp/iOS/Headphones.swift`
- FEAT-16 · Transcript complete before audio plays (spinner, synced autoscroll) + the search-scrubber pill on every transcript surface · `[ ]` · T-0095 · `FEAT-16-transcript-before-play.md`; builds on FEAT-07
- FEAT-19 · Playback survives the Lock Screen and leaving the app, with a Lock Screen scrubber, on every surface · `[~]` P2 (iOS video on lock) built, device check owed; web already SPEC 69; editor browser player proposed · T-0132 · `FEAT-19-play-on-lock.md`; builds on SPEC 69, BUG-09
- FEAT-12 · Audio downloads land straight in Music · `[x]` · T-0076 · `shared/mediadownload.swift`, `shared/homes.swift`

### Bugs
- BUG-01 · Squeeze-hold menu stuck after hover loss or palm cancel · `[ ]` (anticipated) · owner 2026-11-11 · —
- BUG-02 · Vertical scroll turns into a page swipe; pages jump · `[~]` · T-0025 T-0026 T-0027 · `bugs/BUG-02-scroll-locks-sideways.md`
- BUG-03 · A Pencil tap meant to place the cursor draws a stroke instead · `[~]` (tests pass; iPad+Pencil check pending) · T-0030 · `bugs/BUG-03-pencil-tap-draws.md`
- BUG-04 · setText put the caret back at a stale offset after a native round-trip (Enter looked reversed) · `[~]` (tests pass; owner's real-device check pending) · T-0001 · `bugs/BUG-04-settext-caret-drift.md`
- BUG-06 · Draftpad ink ignores touch (iPhone has no Pencil, so annotation never worked there) · `[~]` (fixed, device check owed) · T-0023 · `bugs/BUG-06-mobile-ink-touch-blocked.md`
- BUG-07 · Ink anchors to the wrong line (hard-coded 28px vs. the real line height) · `[~]` (fixed, device check owed) · T-0014 · `bugs/BUG-07-ink-anchor-line-height.md`
- BUG-08 · The document moved while the owner was dragging a selection (highlight not what was dragged; caret wrong after Delete) · `[~]` (fixed, device check owed) · T-0028 · `bugs/BUG-08-drag-selection-moved.md`
- BUG-09 · No Lock Screen scrubber for Recense's own player on iOS (no Now Playing info, no remote commands) · `[~]` (fixed, device check owed) · T-0067 · `bugs/BUG-09-no-lock-screen-scrubber.md`
- BUG-10 · The floating window is black while Recense's own player plays (own sound read as quiet; window drew only the broadcast) · `[x]` (owner confirmed on iPhone 11-14) · T-0069 · `bugs/BUG-10-floating-black-own-player.md`
- BUG-11 · A file played in Recense is heard in the last broadcast's language (English by default), not its own · `[x]` (owner confirmed on iPhone 11-14) · T-0070 · `bugs/BUG-11-file-heard-wrong-language.md`
- BUG-12 · Words light ahead of the voice through Bluetooth headphones (the player's position, not what is heard) · `[x]` (shipped deee2de; iPhone Bluetooth latency 0.186 s measured 11-15) · T-0072 · `bugs/BUG-12-words-ahead-in-headphones.md`
- BUG-13 · Transcript lines cut off mid-sentence (one line per breath-phrase on iOS; the Mac's sentence rule moved to ShowsKit) · `[x]` (shipped deee2de; iPhone Bluetooth latency 0.186 s measured 11-15) · T-0073 · `bugs/BUG-13-lines-cut-mid-sentence.md`
- BUG-16 · A song dropped into downloads/ by another app never reaches Music (no watcher ran adopt) · `[~]` fixed, device check owed · T-0080 · `bugs/BUG-16-downloads-not-settled.md`
- BUG-17 · Pairing finished on the Mac only: the side waiting for the group secret threw it away, and a listed peer could not re-pair · `[~]` pairing checked on all three devices 11-15; rename-carry check owed · T-0081 · `bugs/BUG-17-pairing-one-sided.md`
- BUG-18 · Pages full of ⌧ boxes (control characters) count as text, so swipe never deletes them · `[~]` (fixed in editor; source of 0x04 open) · T-0085 · `bugs/BUG-18-control-chars-block-delete.md`
- BUG-19 · Carried files counted settled before they arrived (bytes lost in transit, never asked for again) · `[x]` device-checked 11-15 on iPad and iPhone · T-0087 · `bugs/BUG-19-carry-applied-before-bytes.md`
- BUG-21 · A finger drag scrolls the page instead of inking (touch-action never set) · `[~]` fixed in editor, device check owed · T-0131 · `bugs/BUG-21-finger-ink-pans-page.md`
- BUG-20 · Guests can't add media to a share link: Main's "hide the old Upload pill" CSS (`#up{display:none!important}`) also swallowed the guest's reused "Add" button · `[x]` (tests pass; checks in `library/`) · T-0130 · `bugs/BUG-20-guest-add-button-css-hidden.md`

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
