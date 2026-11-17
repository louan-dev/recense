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
- **P1 · It breathes.** The quiet mark on note lines near the playhead; Add moment button; Reduce Motion path.
  - Check: test with a fixture note of three moment links and a clock: the marked line at t = 0, 10, 724, 9999.
- **P2 · The notes list and Unlinked.** Check: delete a media file in a test home; its note is listed under Unlinked.
- **P3 · "Move Media and Note to Trash…".** Check: both land in `trash/` with their origins; Restore brings both back.
- **P4 · Ink on a note** (`keep/<key>/note.ink.json`, the format `draftpad.ink.json` already uses).
  Check: the BUG-07 anchor test passes on a note page.

## Risks and edge cases
- **Two files, one recording.** A re-encoded copy has a different key, so it gets a different note. No fix proposed;
  the notes list shows both. Recorded so it is not a surprise.
- **A note open on two devices.** Handled by FEAT-22 (three-way merge; both kept when no clean merge). Never
  last-writer-wins.
- **Sealed and private items.** A note inherits its item's privacy: a note on a Matters or Raven item never
  reaches a guest or a link (`shared/ShowsKit/Sources/ShowsKit/Rules.swift:14-18`).
- **Screen audit owed** at P0: the Note button must be the only way-in control (no second pencil icon elsewhere).
