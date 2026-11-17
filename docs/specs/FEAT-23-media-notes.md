# FEAT-23 · One note per media item, inside Draftpad

From: owner 2026-11-16 · Status: `[ ]` written, not built
Revised 2026-11-16 (lane notes-search-curve) after the owner's review of the design plan.
Supersedes the first draft on branch `work/feat23-media-notes` (4c47b9f); its mockup stays on that branch.
Linked specs: FEAT-21 (one search) · FEAT-22 (where it lives, how it catches up, Main and Guest) ·
FEAT-07 (the pill and the Sound button) · FEAT-08 (Draftpad as one matter) · FEAT-18 (the hub).

Labels: **proven** = a test or the code in this repo shows it (file:line) · **assumed** = believed, not shown ·
**untested** = nobody has run it.

## Verdict
**Build it as one more page of the editor we already have, not as a new view.**
The note is a plain Markdown file per item. Draftpad opens it. The editor's transcript pane sits beside it.

## What the owner asked (2026-11-16)
- Every media item has its own note, so a note is never hunted for in another app.
- The note lives with the transcript: the scrubber, the transcript and the note move together.
- One searchable place holds all of them (search itself: FEAT-21).
- Deleting media never destroys a note. Clearing a note never deletes media.

## Terms
- **Key:** the 24-letter name Recense gives a recording from its content, so the same recording is one item
  on every device. **proven** `shared/ShowsKit/Sources/ShowsKit/Model.swift:19-32`.
- **Moment link:** a Markdown link to a second inside a recording: `[12:04](recense://<key>?t=724)`.
- **Transcript pane:** the panel the editor already has that shows transcript lines beside the page.

## Rules
1. **One file per item:** `keep/<key>/note.md`. Plain UTF-8 Markdown. Opens in any text editor in 10 years.
   - Why one file per item: a sync conflict stays inside one item, and no file grows large.
2. **The note is a Draftpad page.** Same editor, same ink, same Matter menu (FEAT-08), same fonts and column width.
   - It is a separate file from `draftpad.md`. Nothing is copied into `draftpad.md`.
3. **One editor web view, one document at a time.** Opening a note swaps the document in the editor that is
   already open. No second web view is created.
   - Why: the Mac has 8 GB and has hit memory pressure with several web views open (owner, brief 2026-11-16).
4. **The transcript stays out of the note file.** It shows in the transcript pane, read from the stored transcript.
   - iPad landscape and Mac: pane beside the note. iPhone and iPad portrait: pane under the note, half height,
     one drag handle (UI-07 sets the editor's box per device).
5. **Moment links.**
   - Tap a line in the pane, or press **Add moment** (clock-plus button at the left of the note's scrubber):
     `[mm:ss](recense://<key>?t=<whole seconds>)` is written at the caret, then a space.
   - Tap a moment link: that item plays from that second. If another item is playing, it is paused first.
   - Over an hour the label is `h:mm:ss`. The label is for the eye; only `t=` is read.
6. **The note breathes with the voice.** While the item plays, the pane lights the line being spoken, and
   the note lines whose moment link is the nearest at or before the playhead get a quiet left mark.
   - Reduce Motion: the mark appears with no fade. Nothing scrolls the note by itself.
7. **One visible way in.** Now Playing has a **Note** button in its top bar, beside ···. It shows a dot when
   the item has a note. The same action is ··· › "Open Note". No gesture is needed.
8. **New and empty notes.** No file exists until the first character is typed. A note cleared to nothing
   removes `note.md` (through the Trash, so Put Back works) and never touches the media.
9. **Deleting media.** The note stays in `keep/<key>/`. It is listed under **Unlinked** in the notes list.
   Its moment links show "not on this device" when tapped and offer FEAT-22's ladder.
10. **Deleting both** is one menu action, "Move Media and Note to Trash…", with a confirm that names both.
11. **The notes list** ("all notes on one page", the owner's wish): one list, newest note edit first, showing
    only items that have a note. Each row: title, date, the note's first two lines. A row opens that note.
    - It loads 20 rows at a time. It is not one giant document. **Open question 1** asks whether this is enough.

## What exists (checked in the code, 2026-11-16)
- **proven** The editor has a transcript pane and an audio sidecar: `editor/src/audio.js:373`
  (`createTranscriptPane`), `:848` (`createAudioSidecar`: `sourceKey`, cues, bookmarks, `onInsertToPage`, `onSeek`).
  Tests: `editor/test/p4-audio.test.mjs`.
- **proven** Both hosts already pass a transcript to it: `strip/editorhost.swift:216`,
  `mobile/HostApp/iOS/Draftpad.swift:496` (`setAudioTranscript`), and both listen on an `audio` channel
  (`editorhost.swift:168,332`; `Draftpad.swift:192,303`).
- **proven** The hosts load exactly one note today, `draftpad.md` in the vault: `Draftpad.swift:31`,
  `editorhost.swift:111-116`. Opening a second file is new host work (small: the editor takes text by `setText`,
  `Draftpad.swift:228`).
- **proven** The editor opens only `http(s)` links today: `editor/src/links.js:6-8`. `recense://` needs one rule there.
- **proven** The Mac registers the `recense` URL scheme: `strip/Info.plist:14`.
- **untested** iPhone and iPad: no URL scheme was found in `mobile/` (search of plists, project files and Swift,
  2026-11-16). Inside the app no scheme is needed (the editor hands the link to its host). From another app it is.
- **proven** The Mac keeps transcripts flat today (`~/Recense/keep/<key>.v2.json`, `strip/keephome.swift:21`);
  537 transcripts, 110 MB, counted on the owner's Mac 2026-11-16. `keep/<key>/note.md` is a new folder beside them.
- **assumed** A note file and a flat transcript file with the same key do not collide (a folder and a file with
  different names). Phase P0's first check proves it.

## Outside services
- **At the moment of use: none.** Notes, transcripts and links work with no network.
- **Catch-up between devices:** FEAT-22 (paired device first, hub second, Cloudflare R2 optional and last).
- **Setup: none.**

## Phases (each ends with its check)
- **P0 · The note on one device.** Note button → the editor swaps to `keep/<key>/note.md` → transcript pane shows →
  tap a line writes a moment link → tap the link plays from there. Mac, iPhone, iPad (one editor, three hosts).
  - Check 1 (test, editor): `[12:04](recense://<key>?t=724)` round-trips: written by a pane tap, parsed back to
    key + 724, label ignored.
  - Check 2 (test, hosts): typing in the note never changes `draftpad.md`; clearing the note leaves the media file.
  - Check 3 (device, iPhone Mirroring + Mac): write a note on a song, quit, reopen: the note is there; the link plays.
  - Check 4 (Mac): Activity Monitor shows no extra WebContent process after opening five notes in a row.
- **P0b · Arrivals open as a note** (owner 2026-11-16: "AirDrop straight into an offline editor, with the backlinks to
  the media's location"). Section "Arrivals" below. Check list there.
- **P1 · It breathes.** The quiet mark on note lines near the playhead; Add moment button; Reduce Motion path.
  - Check: test with a fixture note of three moment links and a clock: the marked line at t = 0, 10, 724, 9999.
- **P2 · The notes list and Unlinked.** Check: delete a media file in a test home; its note is listed under Unlinked.
- **P3 · "Move Media and Note to Trash…".** Check: both land in `trash/` with their origins; Restore brings both back.
- **P4 · Ink on a note** (`keep/<key>/note.ink.json`, the format `draftpad.ink.json` already uses).
  Check: the BUG-07 anchor test passes on a note page.

## Arrivals: AirDrop and "Open with Recense" (phase P0b)

### Verdict
**A file sent to the device becomes an item and its note in one step, with no internet.**
**The note links to the media by its key, never by its folder path.**

### Rules
1. **One landing place.** Arrivals go where downloads already go and are sorted into their home by kind
   (audio → Music, PDF and text → Study, the rest → Inbox). No second folder. FEAT-03 is revised to match.
   - **proven** the sorting rule: `shared/homes.swift:161-163`; the watcher that sorts what lands: `strip/app.swift:6808` (BUG-16).
2. **iPhone and iPad:** Recense declares the file types it opens (audio, video, pictures, PDF, plain text, Markdown).
   After an AirDrop, iOS then offers "Open with Recense". The file is moved (never copied) into its home,
   and the note opens at once, because the person chose Recense.
3. **Mac:** Recense also looks in `~/Downloads`, and takes **only** files the system marked as arriving through
   its sharing service (`sharingd`, the service behind AirDrop). Everything else in `~/Downloads` is left alone.
   The note is made but not opened: the notes list shows it at the top, marked **New**. No window jumps up.
4. **The note made on arrival** (an exception to rule 8: this note exists before anything is typed).
   Exactly two lines:
   - `[▶ <title>](recense://<key>)` · for a PDF or a picture: `![<title>](recense://<key>)`, so the page shows it;
   - `Arrived by AirDrop · 2026-11-16 14:02` (or `Opened in Recense · …` for other "Open with" arrivals).
5. **Where the media is now** is drawn by the editor under the first line and **never saved in the file**:
   "Music › Song.m4a · on this iPhone", "on the Mac", or "not on this device" (then FEAT-22's ladder).
   - Why: a path saved into the note goes stale the moment the file is renamed, moved or carried.
     The key is the same on every device (**proven** `shared/ShowsKit/Sources/ShowsKit/Model.swift:19-32`).
6. **The other direction** (media → note) is the Note dot and button (rule 7).
7. **Audio and video are transcribed on the device** as soon as they land (FEAT-16's gate). The transcript pane
   fills when the transcript is complete. Typing in the note is never blocked by it.
8. **The same file again** (same key): no second note. The existing note opens and gets one more line,
   `Arrived again by AirDrop · <date>`. Nothing in it is replaced.
9. **The sender's name is not recorded.** **assumed:** iOS does not tell the receiving app who sent it.
   **untested** on the Mac.

### What exists (checked 2026-11-16)
- **proven** No file types are declared: `mobile/ios/App-Info.plist` has no `CFBundleDocumentTypes`; the app's only
  extensions are Files and screen broadcast (`mobile/ios/Ext-Info.plist`, `Broadcast-Info.plist`).
  So "Open with Recense" does not appear today.
- **proven** The Mac's watcher covers `~/Recense/downloads/` only (`strip/app.swift:6808`), not `~/Downloads`.
- **proven** On the owner's Mac, 95 of 618 files in `~/Downloads` and `~/Recense/downloads/` carry the system's
  arrival mark naming `sharingd` (counted 2026-11-16, file names not read).
- **assumed** `sharingd` marks only AirDrop arrivals. Spike S2 checks it against files saved by Safari and Mail.
- **assumed** (Apple's documented behavior, not run here) Declared file types are enough for AirDrop's
  "Open with"; iOS hands the file over in `Documents/Inbox/`, which Recense must empty by moving the file out.
- **proven** The editor shows embeds through its host's `recense-file:` scheme today (`editor/src/embeds.js:1-3`).
  Resolving `recense://<key>` there is new work.

### Outside services
- **None, at any time.** AirDrop goes device to device over Bluetooth and peer Wi-Fi, with no router or internet
  (Apple's documented behavior). Transcription and the note are on the device.

### Checks (in order; each gates the next)
- **Spike S1 (iPhone, 30 min, may fail):** declare the types; with the router off, AirDrop a song from the Mac:
  Recense opens holding it. If it fails, the route is a Share Extension (FEAT-03 P1) and this phase waits for it.
- **Spike S2 (Mac, 30 min):** AirDrop a file from the iPhone: it carries the `sharingd` mark; a file saved by Safari
  and one saved from Mail do not.
- **Test (shared):** a fixture file arrives → it is moved into its home, the note has exactly the two lines,
  `draftpad.md` is untouched; the same bytes again → still one note, one more line.
- **Test (editor):** the "where it is now" line is drawn from the host's answer and the file's text is unchanged.
- **Device (iPhone via iPhone Mirroring, iPad, Mac):** router off, AirDrop a voice memo: the note opens (iPhone, iPad)
  or appears as New (Mac); the transcript fills in; the ▶ link plays it. Screenshot audit: one Note control per screen.

## Risks and edge cases
- **Two files, one recording.** A re-encoded copy has a different key, so it gets a different note. No fix proposed;
  the notes list shows both. Recorded so it is not a surprise.
- **A note open on two devices.** Handled by FEAT-22 (three-way merge; both kept when no clean merge). Never
  last-writer-wins.
- **Sealed and private items.** A note inherits its item's privacy: a note on a Matters or Raven item never
  reaches a guest or a link (`shared/ShowsKit/Sources/ShowsKit/Rules.swift:14-18`).
- **Screen audit owed** at P0: the Note button must be the only way-in control (no second pencil icon elsewhere).
