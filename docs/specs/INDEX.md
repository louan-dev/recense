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
- UI-04 · Apple Pencil Pro mechanics (Notability study) · `[~]` · owner 2026-11-11 · `editor/src/ink.js`, `editor/src/pressure.js`, `editor/src/palm.js`, `editor/src/pencilstate.js`, `mobile/HostApp/iOS/Draftpad.swift` · P7–P12 planned from the owner's 05:44 recording (T-0133..T-0138)
- UI-05 · VoiceOS (voice dictation + edit + agent patterns) · `[ ]` · owner 2026-11-12 · `strip/app.swift:6249` VoiceEntry, `strip/speech.swift`, `strip/openears.swift`
- UI-06 · Draftpad page navigation, gesture-only (Antinote study): dots tap/drag/hold, slots, reopen, no ⌘ keys · `[~]` · owner 2026-11-15, T-0020/21/22/24 · D1–D4 date label added; G4 drag a dot to any place (T-0089); device check (Mac/iPhone/iPad) owed · `ui-teardowns/UI-06-antinote-navigation/UI-06.md`, `editor/src/pagemode.js`, `editor/src/index.js`
- UI-07 · Draftpad's editor box per device and orientation (iPhone 12 Pro Max, iPad Air M2 13-inch; 11-inch fallback band), not the Mac's box scaled · `[~]` · owner 2026-11-16 · built in editor; device check (iPhone/iPad) owed · `ui-teardowns/UI-07-draftpad-device-sizes/UI-07.md`, `editor/src/devicelayout.js`
- UI-12 · The editor at a local path: offline by default, sync on a drip (not a teardown: Recense's own surface) · `[~]` S1 built but demoted (Cloudflare route behind Access, the shape the owner rejected); S2–S5 `[ ]` · owner 2026-11-16 · `UI-12-offline-editor-local.md`; `editor/dist/`, `editor/src/webstore.js`, `editor/src/pwa/sw.js`, `library/src/editorpwa.js`, `shared/carry*.swift`

### Features
- FEAT-01 · Clean text → chaptered audiobook (TOML rule profiles, Kokoro M4B) · `[~]` · owner 2026-11-12 · `text/`
- FEAT-02 · P2P transport (Bluetooth + Wi-Fi, MultipeerConnectivity) · `[~]` P1–P3 built, device check owed · T-0035 · `shared/p2ptransport.swift`
- FEAT-03 · Share: consolidated cross-device destination; revised 2026-11-16: one landing place (`downloads/`, no `share/`), iOS "Open with Recense" first · `[ ]` · T-0035, owner 2026-11-16 · `FEAT-03-share-destination.md`; `shared/mediadownload.swift`, `shared/homes.swift`, `strip/app.swift` (watcher), `mobile/ios/App-Info.plist`
- FEAT-05 · Transcript modes (Transcript · Learn · Follow) + floating window as a mirror, one CaptionPainter · `[ ]` · owner 2026-11-12, T-0030/31/32 · `FEAT-05-transcript-modes-floating-mirror.md`; `shared/ShowsKit/`, `strip/recense.swift`, `mobile/HostApp/iOS/Listen.swift`
- FEAT-04 · Exact time sync for stored transcripts (fingerprint → content clock) · `[~]` P1+P2 built, P3 parked (aligner), P4 after FEAT-02 · owner 2026-11-12 · `shared/ShowsKit/Sources/ShowsKit/{Word,ContentClock}.swift`, `mobile/HostApp/iOS/Listen.swift`, `strip/handoff.swift`
- FEAT-06 · Homes: the folder contract on every device (+ carry C0 exit) · `[~]` P1–P3 built, device check owed · owner 2026-11-08 + 11-11 · `shared/homes.swift`, `strip/app.swift` (`recense carry`)
- FEAT-07 · Transcript search pill + the sound curve (seven beads behind one Sound button; two fingers the fast path); P0 the Music list · `[~]` P0–P2 built (Music list, search pill on iPhone/iPad, translation on the voice), Mac pill and device check owed; P4–P9 the sound curve written 2026-11-16, not built · T-0045, owner 2026-11-15 + 2026-11-16 · `FEAT-07-search-pill-haptic-ruler.md` (read § Revision 2026-11-16 first); `shared/homefiles.swift`, `shared/ShowsKit/Sources/ShowsKit/Views/{ShowPage,Cards,Root,Scrubber,SearchPill}.swift`, `strip/musicshelf.swift`, `library/src/client/homebar.js` (the tray), `strip/soundengine.swift`
- FEAT-08 · Draftpad as one matter (the 12-move test) · `[ ]` · owner 2026-11-14 (T-0046, T-0050) · `FEAT-08-draftpad-one-matter.md`; `editor/`, `shared/notesync.swift`
- FEAT-09 · Carry between devices: pair once, then the same homes everywhere · `[~]` pairing + full ops-log settling (move/trash/restore replay, keep-both) built and wired end to end; pairing checked on Mac/iPhone/iPad 11-15 (BUG-17); P4 automatic carry built and tested, device check owed (T-0084); P1b pair by typing the code built and tested, device check owed (T-0086); text merge against a tracked base still open · owner 2026-11-11 + 11-14, T-0035, T-0047, T-0084, T-0086 · `shared/carrysync.swift`, `shared/carrypair.swift`, `shared/carrymanager.swift`, `shared/carryapply.swift`, `mobile/HostApp/iOS/PairIntent.swift`
- SEC-02 · Carry peer auth: a paired device proves its key, not its name (handshake, sealed seen/ops/gone, forget, re-pair once; T-0121/0122/0123 UI) · `[~]` · T-0121, T-0122, T-0123, owner 2026-11-18 (PLAN-1118 §3) · `SEC-02-carry-peer-auth.md`; `shared/carryauth.swift` (planned), `shared/carrymanager.swift`, `shared/p2ptransport.swift`
- FEAT-10 · Translate the transcript as it plays (English, Tiếng Việt, Français), on the device; Follow in + Heard in, one language list, playhead first (amended 11-18) · `[~]` iOS built, device check owed · T-0068, T-0029 · `shared/translateplan.swift`, `mobile/HostApp/iOS/Translate.swift`, `shared/ShowsKit/Sources/ShowsKit/Langs.swift`
- FEAT-11 · iOS download engine (yt-dlp in embedded CPython + AVFoundation join, no ffmpeg) · `[ ]` spike PASS on iPhone 2026-11-14 · T-0049 · `spike/ios-ytdlp/`
- FEAT-15 · Bose Bridge: one pair of QC SC, many sources (route, seats, two symphonies at once) · `[~]` P1–P5 built, device check owed · T-0059 · `shared/bosebridge.swift`, `strip/bosebridge.swift`, `mobile/HostApp/iOS/Headphones.swift`
- FEAT-16 · Transcript complete before audio plays (spinner, synced autoscroll) + the search-scrubber pill on every transcript surface · `[ ]` · T-0095 · `FEAT-16-transcript-before-play.md`; builds on FEAT-07
- FEAT-19 · Playback survives the Lock Screen and leaving the app, with a Lock Screen scrubber, on every surface · `[~]` P2 (iOS video on lock) built, device check owed; web already SPEC 69; editor browser player P4 built (shared `mediasession.js`, Play a file…) · T-0132 · `FEAT-19-play-on-lock.md`; builds on SPEC 69, BUG-09
- FEAT-20 · The Mac's song pipeline and syllable light on iPhone and iPad, 1:1 (route A: the Mac separates and measures, iOS fits with the shared Swift Cadence, T-0132) · `[~]` P1 compiled, device check owed · owner 2026-11-16 · `FEAT-20-prosody-on-ios.md`; `shared/ShowsKit/Sources/ShowsKit/SongLight.swift`, `mobile/HostApp/iOS/SongVoice.swift`
- FEAT-21 · One search: transcript words, translations, notes and titles; one fold rule, a derived `find.tsv` per item; the pill hands over to Library › Search · `[ ]` · owner 2026-11-16 (T-0045, T-0046 behind it) · `FEAT-21-one-search.md`; `shared/ShowsKit/Sources/ShowsKit/TranscriptFind.swift`, `Views/Search.swift`, `library/src/client/homebar.js`
- FEAT-22 · Where notes, transcripts and the index live; catch-up ladder (device → paired device → hub → R2 optional); Main and Guest as one app with a role value · `[ ]` · owner 2026-11-16 · `FEAT-22-where-it-lives.md`; `shared/homes.swift`, `shared/carrysync.swift`, `shared/ShowsKit/Sources/ShowsKit/TranscriptSource.swift`, `mobile/HostApp/iOS/GuestApp.swift`, `hub/`
- FEAT-23 · One note per media item inside Draftpad (`keep/<key>/note.md`, moment links `[mm:ss](recense://<key>?t=<s>)`, the editor's transcript pane) · `[ ]` revised 2026-11-16 (+ P0b: AirDrop and "Open with Recense" arrive as an item with its note); supersedes the draft on `work/feat23-media-notes` · owner 2026-11-16 · `FEAT-23-media-notes.md`; `editor/src/audio.js`, `editor/src/links.js`, `strip/editorhost.swift`, `mobile/HostApp/iOS/Draftpad.swift`
- FEAT-24 · Screenshots and screen recordings follow the tmp move rule (lanes of `downloads-hold.zsh`; only new files; opened/renamed/tagged stay) · `[~]` · owner 2026-11-17 · `FEAT-24-storage-sweep.md`; `sync/bin/downloads-hold.zsh`
- FEAT-07 · 21 · 22 · 23 open questions (seven choices for the owner) and the build order · owner to answer · 2026-11-16 · `FEAT-21-23-open-questions.md`
- FEAT-12 · Audio downloads land straight in Music · `[x]` · T-0076 · `shared/mediadownload.swift`, `shared/homes.swift`
- FEAT-18 · Offline Recense hub: `https://recense.local` served by our own Mac (own root, Bonjour, Draftpad + note sync; H2 library, H3 standby) · `[~]` H1 building · owner 2026-11-16 · `FEAT-18-offline-hub.md`; `hub/`, `editor/src/hubsync.js`
- FEAT-25 · Global destination: screenshots and trash in one Recense place (renamed from FEAT-04, which is exact time sync) · `[~]` P1 built, P2/P3 open · T-0034 · `shared/destinations.swift`, `FEAT-25-global-destination.md`
- FEAT-13 · Show page file actions ("+" adds, ··· Move to… beside FEAT-07 Rename…/Delete, row thumbnails; via ShowFolderFiles on HomeFiles) · `[~]` built, device check owed · owner 2026-11-10 loop, UI-02 · `shared/ShowsKit/Sources/ShowsKit/Views/ShowPage.swift`, `Cards.swift`

### Bugs
- BUG-01 · Squeeze-hold menu stuck after hover loss or palm cancel · `[ ]` (anticipated) · owner 2026-11-11 · —
- BUG-02 · Vertical scroll turns into a page swipe; pages jump · `[~]` · T-0025 T-0026 T-0027 · `bugs/BUG-02-scroll-locks-sideways.md`
- BUG-03 · A Pencil tap meant to place the cursor draws a stroke instead · `[~]` (tests pass; iPad+Pencil check pending) · T-0030 · `bugs/BUG-03-pencil-tap-draws.md`
- BUG-04 · setText put the caret back at a stale offset after a native round-trip (Enter looked reversed) · `[~]` (tests pass; owner's real-device check pending) · T-0001 · `bugs/BUG-04-settext-caret-drift.md`
- BUG-05 · The old transcript stays when new media starts (episodes keyed by date + language; no item change read) · `[ ]` · T-0044 · `bugs/BUG-05-new-media-keeps-old-text.md`
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
- BUG-22 · A blue band follows the caret's line in Draftpad (highlightActiveLine) · `[~]` fixed in editor, device check owed · owner 2026-11-16 · `bugs/BUG-22-blue-line-guide.md`
- BUG-23 · Adding a big video to a Gallery share link fails (the owner's add went as one 413'd PUT to Main, not in parts into the link) · `[~]` fixed, tests pass; not deployed, owner's check on the real file owed · owner 2026-11-16 · `bugs/BUG-23-share-video-upload.md`
- BUG-24 · On iPhone and iPad the light steps word by word: no sweep inside a word, no prosody, no number for lag or drift (renderer steps unless a line has song data; no voice measure ever reached the iPhone; P1 = clock sweep in ShowsKit) · `[~]` P1 + P1b built 11-18 (B1), device checks owed · T-0141 (and T-0132), T-0031, T-0036, T-0038 · `bugs/BUG-24-mobile-light-word-only.md`; `shared/ShowsKit/Sources/ShowsKit/Views/Transcript.swift`, `SongLight.swift`
- BUG-25 · Carry's staging stalls (long names never stage, gone files waited on forever, stray bytes never leave) · `[~]` tests pass; device check owed · T-0111, T-0108, T-0092 · `bugs/BUG-25-carry-staging-stalls.md`
- BUG-26 · Pairing breaks on a duplicate message, a spoken code, or a second device nearby · `[~]` tests pass; device check owed · T-0118, T-0119, T-0120 · `bugs/BUG-26-pairing-prompt-fragile.md`
- BUG-27 · Carry turns every edit into a copy beside the original (no parent known; rescued base not ported: it loses concurrent edits) · `[~]` tests pass; device check owed · T-0106 · `bugs/BUG-27-carry-every-edit-a-copy.md`
- BUG-28 · After a reinstall a device's new changes are invisible to its peers (log restarts at 1) · `[~]` tests pass; device check owed · T-0110 · `bugs/BUG-28-carry-reinstall-invisible.md`
- BUG-29 · Draftpad's Mac save is an unfixed second copy of the iPhone's (unreadable note or ink written over, failed write moves the base, Mac ink over iPad strokes, same-minute conflict copy replaced) · `[~]` tests pass; device check owed · T-0124, T-0125, T-0127 · `bugs/BUG-29-draftpad-save-second-copy.md`; `shared/draftpadfile.swift`
- BUG-30 · Private data reaches Workers AI (Raven/Matters/Sealed at any depth) and Worker security gaps (owner email, trash overwrite, postbox token, CalDAV hash, cron errors, Listen merge) · `[~]` · PLAN-1118 / owner 2026-11-18 · `bugs/BUG-30-private-data-worker.md` · item 1 REVERSED by owner 2026-11-18 (no sealing: AI, links, feeds read Raven/Matters/Sealed)
- BUG-31 · Pages turn under the hand while annotating (page lock while an ink tool is chosen; page bar buttons stay live) · `[~]` · PLAN-1118 §3 / owner 2026-11-18 · `bugs/BUG-31-pages-turn-while-inking.md`
- BUG-32 · guessLang reads French â ê ô as Vietnamese and NFD text as English (NFC first; Vietnamese only on letters French never writes) · `[x]` · T-0029, PLAN-1118 §3 · `bugs/BUG-32-guesslang-fr-vi.md`, `editor/src/matter.js`
- BUG-33 · M4B export and offline downloads lose or hide work (same-minute stamps and names overwrite, ffmpeg errors discarded, download queue drains only on a network change, duplicates by link form) · `[~]` tests pass; device check owed · PLAN-1118 §5k / owner 2026-11-18 · `bugs/BUG-33-export-and-download-silent-loss.md`; `shared/exportjobs.swift`, `shared/mediadownload.swift`, `strip/recense.swift`
- BUG-12 · Words light ahead of the voice through Bluetooth headphones (the player's position, not what is heard) · `[~]` · T-0072 · `bugs/BUG-12-words-ahead-in-headphones.md`
- BUG-13 · Transcript lines cut off mid-sentence (one line per breath-phrase on iOS; the Mac's sentence rule moved to ShowsKit) · `[~]` · T-0073 · `bugs/BUG-13-lines-cut-mid-sentence.md`
- BUG-15 · Floating window goes dead and won't close (frozen on an old caption, or a black box that never closes) · `[~]` (fixed leads; device check owed) · T-0077 · `bugs/BUG-15-floating-window-goes-dead.md`
- BUG-14 · Floating window rests while Safari plays (old broadcast sound read as quiet; fallback engine never notes sound) · `[~]` · T-0074 · `bugs/BUG-14-floating-quiet-behind-safari.md`

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
- FEAT-26 · Paste as Text: copied file → editable text (Vision OCR, PDFKit, CGEvent paste) · `[~]` P1 built (Mac) · owner 2026-11-18 · `shared/pastetext.swift`, `FEAT-26-paste-as-text.md`
- FEAT-29 · One lifecycle per item; Keep (P0: share links outlive their timer) · `[~]` P0 built · owner 2026-11-18 · `FEAT-29-one-lifecycle.md`, `library/src/public.js` (keptLink, action=keep)
- FEAT-34 · Switch access: every action from one or two switches (Apple Switch Control reaches all gestures; one action catalogue → menu, voice, Shortcuts; our spoken switch deck; Mac display/audio/headphones, iOS via the owner's shortcuts, hub wake) · `[ ]` written · owner 2026-11-18 · `FEAT-34-switch-access.md`
- FEAT-33 · The web library works with no network: Pin offline in Safari (service worker, ranges from the cache), one explorer view on web, hub, Mac wing and iOS · `[ ]` written, S0 spike first · owner 2026-11-18 · `FEAT-33-offline-web-library.md`, builds on UI-12, FEAT-18 H2, §5j step 8
- FEAT-32 · Recense a source + Ask engine: a Safari finder (Web Extension, FEAT-30 transport) over an offline notebook (FTS5 passages, Apple model, cited answers); S1 capture → S6 index → S7 Ask → S8 Safari → S2/S3 narration (review 2026-11-18, owner: "Safari LLM finder on a NotebookLM/Ask engine") · `[ ]` written · owner 2026-11-18 · `FEAT-32-recense-a-source.md`
- FEAT-31 · Big uploads resume where they stopped (Swift putParts keeps its part list; background session spike; survey premises checked) · `[ ]` written · owner 2026-11-18 · `FEAT-31-resumable-parts.md`
- FEAT-30 · Safari bridge on iPhone and iPad (the Firefox bridge's script, native-message transport; words on Safari's clock) · `[ ]` plan, S0 spike next · owner 2026-11-14 (first filed as FEAT-12 on work/bug-14; renumbered 2026-11-18, FEAT-12 is downloads → Music) · `FEAT-30-safari-bridge.md`
