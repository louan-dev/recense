# FEAT-23 · One note per media item, inside Draftpad

From: owner 2026-11-16 · Status: `[~]` P0 + P0c editor and files built 2026-11-18 (work/a2-underlay); the hosts' way in
(Note button, ··· › Open Note, the one editor under the player, play by key, the transcript feed) not built; device checks owed
Revised 2026-11-16 (lane notes-search-curve) after the owner's review of the design plan.
Supersedes the first draft on branch `work/feat23-media-notes` (4c47b9f); its mockup stays on that branch.
Amended 2026-11-18 (coordinator 89190d4b, PLAN-1118 §3b + §5k): arrivals make no note until you write (P0b rule 4);
moment links also show as scrubber ticks (rule 5); in-place opening on, copy-never-move for outside files (P0b rule 2).
Amended 2026-11-18 (owner 2026-11-18, PLAN-1118 §11c W1, §12c): **A1 the underlay on annotate**, **A2 backlinks per
media item**, **A3 several devices only after FEAT-22 P2**. Rule 7 is amended by A1. Sections: "One home and embodiments",
"A1", "A2", "A3", "Notability parity", "Debug channel", "Device checks", "Offline-first gate", "Registry block".
Linked specs: FEAT-21 (one search) · FEAT-22 (where it lives, how it catches up, Main and Guest) ·
FEAT-07 (the pill and the Sound button) · FEAT-08 (Draftpad as one matter) · FEAT-18 (the hub).

Labels: **proven** = a test or the code in this repo shows it (file:line) · **assumed** = believed, not shown ·
**untested** = nobody has run it.

## Verdict
**Build it as one more page of the editor we already have, not as a new view.**
The note is a plain Markdown file per item. Draftpad opens it. The editor's transcript pane sits beside it.

## One home and embodiments (added 2026-11-18)
- **One home: `editor/src/`.** The underlay, moment links, ticks, the quiet mark and the backlink rows are computed there.
  - The editor is the one renderer every host already loads (PLAN-1118 §5h decision).
  - Glue only (no rule of this spec lives there): `strip/editorhost.swift`, `strip/recense.swift` (the Mac's transcript
    window), `mobile/HostApp/iOS/Draftpad.swift`, ShowsKit `Views/NowPlaying.swift`, `library/src/client/viewer-sheet.js`.
  - Not this spec's logic: how a note file is read, saved and merged (`shared/notesync.swift`, FEAT-22).
- **Embodiments:**
  - Mac: Recense's transcript window (`Overlay`, `strip/recense.swift:1391`) and Draftpad (`EditorHost`).
  - iPhone (12 Pro Max) and iPad (Air M2 13-inch): Now Playing (ShowsKit) and Draftpad.
  - Web: the viewer's Transcript tab (`library/src/client/viewer-sheet.js:94`). **Gated**: see A3 and the Offline-first gate.
- **Code headers:** each file or function derived from this spec starts with `// Derived from Spec: FEAT-23`
  (`FEAT-23 A1` / `A2` for this amendment). Each test that guards a rule below names its rule in its title.

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
   - **Ticks on the scrubber** (amended 2026-11-18): each moment link is drawn as a tick on the item's scrubber.
     The ticks are derived from the note each time it is read, never saved in a second synced file.
   - Over an hour the label is `h:mm:ss`. The label is for the eye; only `t=` is read.
6. **The note breathes with the voice.** While the item plays, the pane lights the line being spoken, and
   the note lines whose moment link is the nearest at or before the playhead get a quiet left mark.
   - Reduce Motion: the mark appears with no fade. Nothing scrolls the note by itself.
7. **One visible way in.** Now Playing has a **Note** button in its top bar, beside ···. It shows a dot when
   the item has a note. The same action is ··· › "Open Note". No gesture is needed.
   - Amended 2026-11-18 (A1): in the player, Note opens **the underlay** (the note under the transcript).
     A row of the notes list (rule 11) still opens the note first, with the pane beside or under it (rule 4).
     One document, two layouts; never both on one screen.
   - Not decided here: UI-13 (PLAN-1118 §5h, Run 2) moves Note onto Home when the Now Playing sheet goes.
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

### Checked again 2026-11-18 (for A1–A3)
- **proven** No `keep/<key>/` folder exists yet on the owner's Mac (listing of `~/Recense/keep/`), and nothing in
  `editor/src/` reads `recense://` (search). P0 is unbuilt.
- **proven** `keep/` is not a carried home today: `shared/carrysync.swift:277-278`. A note written today stays on its device.
- **proven** The transcript pane posts per-line `annotate` and `bookmark` messages keyed by `cueId`
  (`editor/src/audio.js:108-117`, `:186-195`). Both hosts hand them to `onAudioAction`
  (`strip/editorhost.swift:358-365`, `mobile/HostApp/iOS/Draftpad.swift:243-249`). No host assigns `onAudioAction`
  (search). **So a line note typed in the pane today is stored nowhere.** A1 rule 9 replaces that path.
- **proven** The Mac's transcript is native: `WordsView` (`strip/recense.swift:2094`) in `Overlay` (`:1391`).
  iOS: ShowsKit `TranscriptView` (`Views/Transcript.swift:222`), shown by `Views/NowPlaying.swift:113`.
- **proven** iOS makes its editor box per Draftpad screen (`@StateObject DraftpadWebBox`, `Draftpad.swift:626-631`),
  not once at the app's root. Rule 3 needs it held once (PLAN-1118 §5h).
- **proven** The page lock exists: `setPagesLocked` (`editor/src/pagemode.js:620`), `toolLocksPages`
  (`editor/src/ink.js:33`), applied on every tool change (`editor/src/index.js:870`). BUG-31.
- **proven** Timings reused below: text save debounce 300 ms (`editor/src/bridge.js:4`); ink save debounce 300 ms
  (`editor/src/ink.js:143`); stroke and palm rules (`editor/src/palm.js:4-12`); tap slop 6 px (`editor/src/pagemode.js:558`).
- **assumed** One CSS px is one pt in the editor's web view at its default zoom (WebKit's documented mapping; not measured here).
- **proven** A key is exactly 24 lowercase hex characters (`ContentKey`, `shared/ShowsKit/Sources/ShowsKit/Model.swift:26-29`).

## Offline-first gate (rewritten 2026-11-18; covers the whole spec, A1–A3 included)
Every outside service this spec touches, and when:
- **At the moment of use: none.** Writing, inking, dictating, the underlay, moment links, ticks, the quiet mark and the
  backlink list all run on the device, from files on the device.
  - Dictation is Apple's on-device speech (`shared/speechcore.swift`), never Groq (root guide, since 2026-10-30).
- **Setup only:** the speech language assets iOS and macOS download once per language (Apple's; stored on the device by
  the system). Recense downloads nothing for this spec.
- **Reaching another device:** FEAT-22's ladder, as catch-up that never blocks writing: paired device (FEAT-02,
  on-device Bluetooth and peer Wi-Fi), then the hub on the owner's Mac (FEAT-18), then Cloudflare R2, optional and last,
  with FEAT-22's exit. Gated by A3.
- **The web is the exception to watch.** The web app is served by the Gallery Worker (Cloudflare) unless the page is
  already cached (`library/src/client/editorpwa/sw.js`) or served by the hub. A web underlay that needs the Worker to
  open is "needed at the moment of use", so the web embodiment ships only from the cache or the hub (A3 rule 4).
- No CDN, SDK or third-party library is added.

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
- **P0c · The underlay, one device** (A1; added 2026-11-18). Type and dictate open the note under the transcript;
  emptied, it removes itself. Mac, iPhone, iPad. Web waits (A3 rule 4). Ink joins at P4.
  - Check 1 (test, editor): the A1 trigger table, row by row: whitespace alone writes nothing; the first other character
    writes `note.md` within one 300 ms flush; the first final dictated word does the same; a partial result writes nothing.
  - Check 2 (test, editor): emptied, then focus leaves → the host is asked to trash `note.md`; the media file is untouched.
  - Check 3 (test, editor): re-weave. Load lines A, place three note times, load corrected lines B: `note.md`,
    `note.ink.json` and `note.matter.json` are byte-identical; the lit line for each time is the one B gives.
  - Check 4 (test, editor): BUG-31 inside the underlay: pen chosen → note region locked, transcript region still scrolls,
    the drag handle and the player's buttons still work; `{ pagesLocked:false }` is posted when the region hides.
  - Check 5 (device): A1's device checks below.
- **P0d · Backlinks per media item** (A2; added 2026-11-18). Check list in A2.
- **P0e · Several devices** (A3; added 2026-11-18). Waits for FEAT-22 P2 `REVIEW: OK` and merged. Check list in A3.
- **Build order (2026-11-18):** P0 → P0c → P4 → P0d → P1. P0b runs when its spikes pass. P0e waits on FEAT-22 P2.
  Batch 1 (FEAT-08 "Phases") = P0 + P0c here, with FEAT-08 P5 + P6: one read of `editor/src/` and the two hosts.
- **P1 · It breathes.** The quiet mark on note lines near the playhead; Add moment button; Reduce Motion path.
  - Check: test with a fixture note of three moment links and a clock: the marked line at t = 0, 10, 724, 9999.
  - Amended 2026-11-18 (Notability's reverse sync, UI-04 gap N2): the quiet mark also goes on the stroke group and the
    passage whose time (A1 rule 6) is the nearest at or before the playhead. Same fixture, plus two timed strokes.
- **P2 · The notes list and Unlinked.** Check: delete a media file in a test home; its note is listed under Unlinked.
- **P3 · "Move Media and Note to Trash…".** Check: both land in `trash/` with their origins; Restore brings both back.
- **P4 · Ink on a note** (`keep/<key>/note.ink.json`, the format `draftpad.ink.json` already uses).
  Check: the BUG-07 anchor test passes on a note page.
  - Amended 2026-11-18 (A1): moved up to run right after P0c. Each stroke also stores `t` (A1 rule 6), and the first
    kept stroke is an A1 trigger. Added check: a stroke drawn at playhead 724.36 s reloads with `t: 724.3`;
    a stroke written before this amendment (no `t`) loads unchanged and is never given one.

## Arrivals: AirDrop and "Open with Recense" (phase P0b)

### Verdict
**A file sent to the device becomes an item and its note in one step, with no internet.**
**The note links to the media by its key, never by its folder path.**

### Rules
1. **One landing place.** Arrivals go where downloads already go and are sorted into their home by kind
   (audio → Music, PDF and text → Study, the rest → Inbox). No second folder. FEAT-03 is revised to match.
   - **proven** the sorting rule: `shared/homes.swift:161-163`; the watcher that sorts what lands: `strip/app.swift:6808` (BUG-16).
2. **iPhone and iPad:** Recense declares the file types it opens (audio, video, pictures, PDF, plain text, Markdown).
   After an AirDrop, iOS then offers "Open with Recense". The note page opens at once, because the person chose Recense.
   - Amended 2026-11-18 (§5k): `LSSupportsOpeningDocumentsInPlace` is **on** (with `UIFileSharingEnabled`, so the
     homes show in Files). A file iOS hands us inside our own container (the Inbox copy) is moved into its home.
     A file opened in place from outside our container (Files, another app's folder) is **copied** into its home;
     the original is never moved or deleted.
   - Owner decision first: Matters and Raven must not appear in Files (a hidden subfolder or an exclusion).
3. **Mac:** Recense also looks in `~/Downloads`, and takes **only** files the system marked as arriving through
   its sharing service (`sharingd`, the service behind AirDrop). Everything else in `~/Downloads` is left alone.
   The note is made but not opened: the notes list shows it at the top, marked **New**. No window jumps up.
4. **No note until you write** (amended 2026-11-18; rule 8 holds for arrivals too).
   - The arrival is recorded in the item's index `tags` (`arrived:airdrop` or `arrived:open-with`, and the time),
     not in a note. The item shows at the top of **New** until opened.
   - The note page opens empty with the item above it. At the first keystroke the file is written with its first line,
     `[▶ <title>](recense://<key>)` (for a PDF or a picture `![<title>](recense://<key>)`), then what was typed.
   - Was: a two-line note (link + "Arrived by AirDrop · <time>") written on arrival. Replaced: a file nobody wrote in
     is clutter, and the arrival fact belongs with the item, where every device's index already carries it.
5. **Where the media is now** is drawn by the editor under the first line and **never saved in the file**:
   "Music › Song.m4a · on this iPhone", "on the Mac", or "not on this device" (then FEAT-22's ladder).
   - Why: a path saved into the note goes stale the moment the file is renamed, moved or carried.
     The key is the same on every device (**proven** `shared/ShowsKit/Sources/ShowsKit/Model.swift:19-32`).
6. **The other direction** (media → note) is the Note dot and button (rule 7).
7. **Audio and video are transcribed on the device** as soon as they land (FEAT-16's gate). The transcript pane
   fills when the transcript is complete. Typing in the note is never blocked by it.
8. **The same file again** (same key): no second note and no second file. The arrival time is added to the item's
   `tags`; an existing note opens unchanged (amended 2026-11-18: no "Arrived again" line is written into it).
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
- **Test (shared):** a fixture file arrives → it is moved into its home, its index `tags` carry `arrived:airdrop`,
  **no `note.md` exists**, `draftpad.md` is untouched; one typed character → `note.md` starts with the ▶ line;
  a file opened in place from outside the container → copied, the original's bytes and path unchanged.
- **Test (editor):** the "where it is now" line is drawn from the host's answer and the file's text is unchanged.
- **Device (iPhone via iPhone Mirroring, iPad, Mac):** router off, AirDrop a voice memo: the note opens (iPhone, iPad)
  or appears as New (Mac); the transcript fills in; the ▶ link plays it. Screenshot audit: one Note control per screen.

## A1 · The underlay on annotate (owner 2026-11-18)
Source: PLAN-1118 §11c W1, quoting the 11-16 FEAT-20 plan:
"a media section appears only on the first note and removes itself when emptied".
Read here as: the media section = the item's note region in the player (**assumed**; Q-A1).

### Verdict
**When you annotate a recording, its note appears under its transcript, in the player, on every device.**
**The note file holds only what you made. The transcript is never copied in.**

### Terms
- **Annotate:** type, ink or dictate into an item's note.
- **The underlay:** the note region under the transcript region in the player, one drag handle between them.
- **The invitation:** the empty region shown after you press Note, before you write. It writes nothing.
- **Note time:** the playhead second a passage or a stroke was born at (rule 6). Kept beside the text, never in it.

### Rules
1. **Way in: visible controls only.** Any one of:
   - the **Note** button in the player's top bar (rule 7);
   - ··· › "Open Note";
   - voice: the spoken label "Open Note" (FEAT-08 decision 4: the voice phrase is the menu label);
   - Mac: the same item in the Recense window's menu.
   - With no note yet, each opens **the invitation**: an empty region, the caret in it, the editor's tool row.
2. **The note appears only on the first note.** `keep/<key>/note.md` is first written by the first save after one of:
   - **type:** the first character that is not whitespace (space, tab, newline) is inserted;
   - **ink** (from P4): the ink layer keeps its first stroke. `palm.js` decides what is kept: a touch or mouse stroke
     under 3 px is dropped; a mouse stroke under 60 ms and under 8 px is a brush; Pencil strokes are kept;
   - **dictate:** the first *final* recognized word arrives. A partial (volatile) result shows greyed and writes nothing.
     **assumed:** both speech engines mark finals (`shared/speechcore.swift`, not re-read for this amendment).
   - The save is the editor's debounced flush, 300 ms (`bridge.js:4`, `ink.js:143`). The file exists at most
     300 ms after the trigger, plus the host's write.
   - Whitespace alone, a dropped stroke or partial speech writes nothing. No empty file is made (rule 8).
   - Refines rule 8: "the first character" now reads "the first character that is not whitespace".
3. **It removes itself when emptied.**
   - *Empty* means all three: `note.md` has no character that is not whitespace; the note has no stroke;
     no dictation is running.
   - Empty while the caret or the pen is still in the region: the region stays. No timer runs.
   - Empty when focus leaves the region (another control, the player closing, the item changing, the app going to
     the background): in that same flush the host moves `note.md`, `note.ink.json` and `note.matter.json` to the
     Trash (rule 8; Put Back works), and the region closes.
   - The media file and its transcript are never touched (owner 2026-11-16).
   - Edit › Undo in the same session brings the note back at the next flush. After that: Put Back.
4. **Layout** (spec choices, **untested** on the devices; Q-A7).
   - Transcript region on top, note region under it, one drag handle between. The same order on every embodiment.
   - The note region opens at 40 % of the player's content height, never under 120 pt.
   - The transcript region keeps at least 96 pt (three 28 pt lines plus padding; `DEFAULT_LINE_HEIGHT`, `ink.js:78`).
   - The handle: hit area 44 pt high, full width; drawn grabber 36 × 5 pt.
     Also a VoiceOver adjustable control and the arrow keys (10 % per step).
   - The height is remembered per device and orientation, locally. It is never synced.
   - Why two regions and not one scroll: rule 6 says nothing scrolls the note by itself, and the transcript
     follows the playhead. In one scroll the follow would move the note.
   - Opening and closing: a 200 ms height change. With Reduce Motion: none.
5. **What is stored where.**
   - `keep/<key>/note.md`: your words, your explicit moment links (rule 5), the arrival line (P0b rule 4).
     Never transcript text, never a path, never a note time.
   - `keep/<key>/note.ink.json`: the strokes, each with its note time `t` (P4).
   - `keep/<key>/note.matter.json`: FEAT-08's sidecar for this note. A passage's seed carries its note time as
     `media: { key, t }` (FEAT-08 P6).
   - The transcript stays where it lives: the Mac's `~/Recense/keep/<key>.v2.json` (`strip/keephome.swift:21`);
     iOS per FEAT-22 P4. The underlay only reads it.
   - The region height: device preferences.
   - `draftpad.md`: never written by the underlay (rule 2).
6. **Every annotation keeps its second** (Notability's core; UI-04 gap N1).
   - A passage typed or dictated gets `media.t` = the playhead at its first keystroke, or when dictation started.
   - A stroke gets `t` = the playhead at pen-down.
   - `t` is in seconds, rounded down to 0.1 s. A paused player counts: its position is the playhead.
   - An item with no sound (a PDF, a picture) gives no `t`.
   - The note-first layout (rule 4) does the same while the item plays.
   - An explicit moment link (rule 5) is written only when you ask for it.
     Note times never enter the text (FEAT-08: a seed lives beside the page, never inside the owner's text).
7. **Play from an annotation: visible controls.**
   - A moment link: tap or click it (rule 5). Plays from exactly `t`.
   - A passage or stroke with a note time: the Matter menu (FEAT-08 decision 4) shows **"Play from mm:ss"**.
     Voice: "Play from here" (the caret's passage).
     Plays from `t` − 2.0 s, never below 0, because you write after you hear (spec choice; Q-A7).
   - Shortcut, never the only way: with the text tool (`select`), a tap on a stroke plays from it.
     A tap = down to up in under 300 ms, moved under 6 pt (`AXIS_SLOP_PX`, `pagemode.js:558`). With a pen, a tap draws.
8. **A corrected transcript re-weaves. The note never changes.**
   - Two kinds of correction: a listener's edit (kept as a layer over the lines), and a better transcription that
     replaces the lines (FEAT-22 P2's upgrade rule).
   - **The rule:** every tie between note and transcript is a time in seconds. Never a line number, a line id or
     quoted transcript words.
   - So a correction changes no byte of `note.md`, `note.ink.json` or `note.matter.json` (P0c check 3).
   - **Re-weave** = when the host hands the editor new lines (`setAudioTranscript`: **proven**
     `strip/editorhost.swift:220`, `Draftpad.swift:496`), the editor recomputes from the note times the lit line,
     the ticks (rule 5) and the quiet marks (rule 6).
   - Target: under 50 ms for 1,000 lines and 200 note times on the iPhone 12 Pro Max (**untested**).
   - A correction cannot push a note time past the end. The key is the content (`Model.swift:19-32`):
     same key, same sound, same length.
   - Where the new lines split differently, a note keeps its second; only the line it sits beside changes. Intended.
9. **The pane's line notes join the note.**
   - The pane's `annotate` message (stored nowhere today; see "Checked again") writes into `note.md` instead:
     a new line `[mm:ss](recense://<key>?t=<s>) <text>`, `t` = the line's start.
   - Its `bookmark` message writes the same line with no text.
   - Nothing is keyed by `cueId`.
   - The dropped messages are reported to the coordinator for triage (this run writes specs only).
10. **The page lock (BUG-31) inside the underlay.**
   - BUG-31 invariants 1–5 hold in the note region unchanged: pen, highlighter, lasso or eraser locks its pages;
     the text tool (`select`) unlocks.
   - The lock covers the note region only. It never stops the transcript region scrolling or following, the scrubber,
     play and pause, the drag handle or any player button (BUG-31 inv 3: the lock removes no visible control).
   - iOS: while locked, the host also turns off the player's own swipes that start inside the note region
     (the sheet's swipe down to close; the edge swipe back), as BUG-31 inv 4 does for Draftpad. The close button stays.
   - A stroke that starts in the note region and leaves it is clipped at the region's top edge.
     Ink never lands on the transcript; the transcript is read-only.
   - When the region hides (emptied, the player closed, the item changed), the page posts `{ pagesLocked: false }`
     first, so no recognizer stays off anywhere else. The chosen tool is kept.
11. **One web view (rule 3) on each host.**
   - iOS: the one editor box is held once by the app (PLAN-1118 §5h) and lent to Draftpad or the player.
     The screen without it shows one line and a button, "Show Note Here". Today the box is per screen: P0c moves it.
   - Mac: the one `EditorWebView` moves into the Recense window under `WordsView` (**untested** that a web view keeps
     its page when moved between windows; Q-A2).
   - Before any swap the pending flush (≤ 300 ms) completes. A swap never drops a keystroke.
   - Web: the viewer loads the editor bundle under its Transcript tab, one per page.

## A2 · Backlinks per media item (owner 2026-11-18)

### Verdict
**From the note: moment links. From the media item: the list of notes and pages that link to it.**
**The list is derived from the note files; it is never a second source of truth.**

### Rules
1. **Link grammar.** One function, `momentLinks(text)` in `editor/src/links.js`.
   - `recense://<key>` or `recense://<key>?t=<s>`. `<key>` = 24 lowercase hex characters.
     `<s>` = one or more digits (whole seconds), and the link ends there.
   - Counted inside a Markdown link `[label](…)`, an image `![label](…)` (P0b rule 4), or bare.
   - Anything else (uppercase, another length, a fraction, another parameter) is not a moment link. It stays text.
   - The label is for the eye; only `<key>` and `t` are read (rule 5).
2. **Sources scanned:** every `keep/*/note.md` on this device, and every page of `draftpad.md`. Nothing else (Q-A4).
3. **What a media item lists: "Linked From".**
   - Every source except the item's own note that holds at least one link to the item's key.
   - The item's own note is left out: its links are already its ticks (rule 5), and it is the underlay.
   - One row per link: the source (a note: its key and title; Draftpad: its page date), `t` or none, the label,
     the line number, an excerpt (the line without link markup, first 80 characters), the source's last edit time.
   - Order: newest source edit first; inside one source, by line. 20 rows per load (as rule 11).
4. **The derived index.**
   - One cache file per device, outside every carried home:
     - Mac: `~/Library/Caches/local.recense/backlinks.json`;
     - iPhone and iPad: the app's `Library/Caches/backlinks.json`;
     - web: an IndexedDB store `backlinks`.
   - Per source it holds: the path inside its home, size, modification time, `version`, and its rows.
     Never a note's full text.
   - Never carried, never uploaded, never in `keep/`. Deleting it loses nothing: the next open rebuilds it.
   - Freshness:
     - the editor saves a note or a page → that source's rows are replaced in the same flush (it holds the text);
     - carry lands a note file → the host marks that source stale;
     - the list opens → each source whose size or time differs is re-read; a source gone or in the Trash loses its rows;
     - the cache does not parse, or its `version` differs → full rebuild.
   - Parsing happens in the editor only (one home). The host hands it texts, at most 50 files per batch.
   - Target, full rebuild: under 500 ms for 1,000 notes of 4 KB on the Mac (**untested**; Q-A3).
5. **Visible controls (never a gesture only).**
   - The player's ··· menu: **"Linked From (n)…"**, shown only when n ≥ 1 (law: shown only when relevant).
   - The underlay's header: a small button **"Linked from n"**, shown only when n ≥ 1.
   - Voice: the spoken label "Linked From".
   - Mac: the same item in the Recense window's menu.
   - Rows are at least 44 pt high. A row opens its source at that line (rule 3 swap).
   - A row with `t` also has a ▶ button, "Play from mm:ss": this item plays at `t`; the list stays open.
   - Keyboard: arrows move, Return opens, Space plays. VoiceOver reads source, time, excerpt.
6. **Offline.**
   - Everything is read from this device. The list's header says "On this device".
   - A note that is only on another device is not listed until carry brings it (FEAT-22). Opening the list never fetches.
   - This item's media missing here: the list still opens (it is keyed by key); ▶ follows rule 9.
   - A source note whose own media was deleted still lists (rule 9: notes outlive media).
7. **Privacy.** Rows from a Matters or Raven note never reach a guest build or a share link (Risks below).
   The cache never leaves the device.
8. **Not a second truth.** No row is ever written into a note. Changing a link in a note is the only way to change a backlink.

### Checks (phase P0d)
- Test (editor), `momentLinks` fixture: a key with `t`, without `t`, an image link, a bare link → counted;
  uppercase key, 23 characters, `t=-1`, `t=1.5` → not counted; the label is ignored.
- Test (editor): three sources link to key K, and K's own note links to K → "Linked From" lists exactly the three
  sources' rows, newest edit first.
- Test (editor + host fixture): change one note → only its rows change; delete the cache → the rebuild gives the same
  rows; a source moved to the Trash → its rows go; Put Back → they return.
- Test (host): the cache path is outside every carried home (`CarryWatch.counts`, `shared/carrysync.swift:279`, is false).
- Device: "Device checks" below.

## A3 · Several devices only after FEAT-22 P2 (the data-loss gate)
Rule (owner, "Ship to my devices first"): only two things block shipping: it does not build, or it can lose data.
1. **Single device first.** P0, P0c, P4, P0d and P1 ship to the Mac, the iPhone and the iPad when their checks pass.
   Each device's notes stay on that device: `keep/` is not carried today (**proven** `shared/carrysync.swift:277-278`).
2. **Several devices wait.** Carrying `keep/<key>/note.md` between devices (FEAT-22 P1) goes live only with or after
   FEAT-22 P2 (three-way merge with a tracked base), merged with `REVIEW: OK`.
   - Why: with no tracked base, two devices that edited one note can only pick a winner or append blindly.
     Either can lose a line. FEAT-22 P2's check (the same line edited on both → both kept) is the guard.
   - The coordinator checks at merge: if FEAT-22 P1 is queued before P2, note files stay out of carry until P2 merges.
3. **The first carry after the gate.** A note made on two devices while apart has no shared base.
   That first merge keeps both texts, never one over the other (Q-A5, for FEAT-22 P2 to state).
4. **The sidecars ride too.** `note.ink.json` and `note.matter.json` are carried and merged with `note.md`
   (`mergeMatter`, FEAT-08 P1; ink by FEAT-22). FEAT-22 P1–P2 name only `note.md` and `lines.json` today.
   Until they name the sidecars, strokes and note times stay on the device that made them:
   not lost, only not handed off (Q-A5).
5. **The web** writes notes only once the hub serves them (FEAT-22 P3) and P2 has merged.
   Before that the web underlay is read-only, opened from the hub or the cached page.
   Browser storage is never the only copy of a note.
6. **Never blind over a carried note (review 2, 2026-11-18).** main carries `keep/<key>/note.md` already (8935ad0),
   so the hosts never write over a note.md that changed since the page saw it. The page's text goes beside it as
   carry's conflict sibling `note (<device> <yyyy-MM-dd HHmm>).md` (`conflictSiblingPath`); merge3 comes with FEAT-22 P2.
   - A parked save names the digest of the note it was written over; the retry writes it only over that note
     (guard: `mobile/ios/Tests/medianotes`, item 1).
- **Check (P0e):** FEAT-22 P2's tests pass. Then the canary: with the Mac and the iPhone apart, type one note line
  on each → reconnect → one note holding both lines, their strokes and note times, on both. The owner confirms the phone.

## Notability parity (T-0050)
- **Notability:** audio recorded with ink; each stroke tagged with the recording time; tap ink → replays at that
  second; scrub → the strokes written then light up (UI-04 Area 1, gaps N1–N2).
- **Built on here:** a time on every stroke and passage (A1 rule 6); "Play from mm:ss" and the stroke tap (rule 7);
  the reverse mark (P1, amended).
- **Not here:** recording new sound while writing. A recording has no key until it ends (the key is its content),
  so its note needs a provisional name, renamed at stop (Q-A6). Batch 2, measured against the bar.
- **The bar:** `.claude/worktrees/agy/.handoff/agy/T-0050-notability-bar.md` (agy; not yet written; referenced, not read).
  PLAN-1118 §11c names `docs/specs/T-0050-notability-bar.md` instead: the coordinator settles which.

## Debug channel: `~/Recense/logs/media-notes.jsonl`
- Writer: ShowsKit `DebugChannel` and its JS twin `library/src/client/debuglog.js` (PLAN-1118 §11b).
  **Proven** only on Stream B's `skills` worktree; not on `main` (2026-11-18). These events wait for it.
- The editor posts each event to its host; the host writes the line. iOS: `Documents/Recense/logs/`.
- Fields: ids, counts, states, times, error text. Never what the person wrote or said (DebugChannel's rule).
- Events (name · fields):
  - `media-notes.underlay.open` · `key`, `trigger` (note-button / menu / voice / arrival), `hasNote` (0/1)
  - `media-notes.underlay.first` · `key`, `input` (type / ink / dictate), `ms` (invitation → file written)
  - `media-notes.underlay.empty` · `key`, `outcome` (trashed / kept-focus)
  - `media-notes.save` · `key`, `bytes`, `strokes`, `links`, `ms`
  - `media-notes.reweave` · `key`, `lines`, `times`, `ms`, `reason` (load / edit / retranscribe)
  - `media-notes.play` · `key`, `t`, `from` (link / passage / stroke / backlink), `found` (here / ladder / missing)
  - `media-notes.lock` · `key`, `locked` (0/1), `tool`
  - `media-notes.backlinks.build` · `sources`, `rows`, `stale`, `full` (0/1), `ms`
  - `media-notes.backlinks.open` · `key`, `rows`, `trigger` (menu / button / voice)
  - `media-notes.error` · `where`, `error`

## Device checks (per embodiment; the simulator is not evidence)
- **iPhone 12 Pro Max, through iPhone Mirroring**
  (`zsh mobile/ios/mirror-shot.zsh "$TMPDIR/shots/<screen>.png" --launch`, outside the sandbox):
  1. Wi-Fi off. Play a song → Note → type one word: the note region appears under the transcript;
     the transcript keeps following the playhead.
  2. Delete the word, tap the scrubber: the region closes; `note.md` is in the Trash.
  3. Tap a transcript line → a moment link is written; tap the link → plays from there.
  4. ··· → "Linked From (n)…" lists a Draftpad page that links to the song; ▶ plays at its second.
  - Dictation needs the phone's own microphone, which iPhone Mirroring cannot use: checked with the phone in hand.
  - Screenshot audit: one Note control, one handle, one close button, nothing carried over from the web.
- **iPad Air M2 13-inch** (on the device; the owner confirms, or a recording from Control Center › Screen Recording):
  1. A pen chosen: draw on the note → no page turns; a finger still scrolls the transcript;
     a downward stroke does not close the sheet.
  2. The text tool: tap the stroke → plays from about 2 s before it was drawn.
  3. Close the player, open Draftpad: edge swipes work again.
- **Mac:** open Recense's transcript window, play, Note → type: the editor sits under the transcript.
  Activity Monitor: no extra WebContent process after five notes in a row (P0 check 4). Clear → the Trash.
- **Web:** only after A3 rule 5: the hub's page, with the internet off, shows the note under the transcript, read-only.

## Risks and edge cases
- **Two files, one recording.** A re-encoded copy has a different key, so it gets a different note. No fix proposed;
  the notes list shows both. Recorded so it is not a surprise.
- **A note open on two devices.** Handled by FEAT-22 (three-way merge; both kept when no clean merge). Never
  last-writer-wins. Amended 2026-11-18: and never before FEAT-22 P2 merges (A3).
- **A line note typed in the transcript pane today is lost** (proven, "Checked again"). A1 rule 9 is the fix;
  until it ships, the pane's note field should not be offered (for the coordinator to triage).
- **The underlay hides while a pen is chosen** (the item changes under it): A1 rule 10 posts the unlock first.
  Missing that would leave iOS's edge swipes off in Draftpad.
- **Two renderers on one screen** until UI-13: the transcript is drawn natively (Mac, iOS), the note by the editor.
  Their light and scroll are separate on purpose (A1 rule 4). UI-13 decides whether they become one woven page.
- **Sealed and private items.** A note inherits its item's privacy: a note on a Matters or Raven item never
  reaches a guest or a link (`shared/ShowsKit/Sources/ShowsKit/Rules.swift:14-18`).
- **Screen audit owed** at P0: the Note button must be the only way-in control (no second pencil icon elsewhere).

## Open questions (2026-11-18, A1–A3)
- **Q-A1** "a media section appears only on the first note": read as the note region in the player.
  If it meant a section inside `draftpad.md`, A1 would contradict rule 2.
- **Q-A2** Mac: can the one `EditorWebView` move into the Recense window without reloading? If not: dock
  Draftpad's window under the transcript window.
- **Q-A3** Backlinks parse only in the editor (one home). On the Mac the editor may not be loaded when "Linked From"
  opens. Either load it (assumed about 1 s, untested), or allow a Swift twin held to the same fixture
  (a second copy, which the parity law calls a bug).
- **Q-A4** Backlink sources: notes and `draftpad.md` only, or every Markdown file in the vault?
- **Q-A5** For FEAT-22 P1–P2: state the no-base first merge, and carry `note.ink.json` and `note.matter.json`.
- **Q-A6** Recording while writing: a provisional note name until the recording's key exists (T-0050 bar, batch 2).
- **Q-A7** Spec choices to confirm on the devices: the 40 % / 120 pt / 96 pt region sizes; the 2.0 s replay lead.

## Registry block (for PARITY.md)
Proposal only: Stream B owns `docs/specs/PARITY.md`. Same keys as B's draft registry
(`.claude/worktrees/skills/docs/specs/PARITY.md`, not on `main` 2026-11-18).
```
<!-- parity:begin media-notes -->
feature: media-notes
home: editor/src/
note: underlay, moment links, ticks, quiet marks, backlink rows (FEAT-23 A1-A2); file rules stay in `notes` (shared/notesync.swift)
symbols: momentLinks backlinkRows
embodiments: mac=[ ] iphone=[ ] ipad=[ ] web=[ ]
events: media-notes.underlay.open media-notes.underlay.first media-notes.underlay.empty media-notes.save media-notes.reweave media-notes.play media-notes.lock media-notes.backlinks.build media-notes.backlinks.open media-notes.error
spec: FEAT-23 FEAT-22 FEAT-08 BUG-31
check: editor :: npm test
device: Wi-Fi off, annotate a song on iPhone through iPhone Mirroring: the note appears under the transcript; emptied, it goes to the Trash
device: iPad, a pen on the note: no page turns, a finger scrolls the transcript, the sheet stays open
<!-- parity:end -->
```
- **Feature:** the note under the transcript, and the links between notes and media.
- **One home:** `editor/src/`.
- **Embodiments:** Mac `[ ]` · iPhone `[ ]` · iPad `[ ]` · web `[ ]`.
- **Gaps:**
  - web waits for FEAT-22 P3 and P2 (A3 rule 5);
  - several devices wait for FEAT-22 P2 (A3);
  - two renderers on one screen until UI-13 (Risks);
  - `symbols:` are proposed names, not yet in the code.
