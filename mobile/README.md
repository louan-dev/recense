# Recense mobile (`mobile/`)

Recense for iPhone and iPad: the mirror of Recense for the Mac (`../strip/`). The same Draftpad editor
(`../editor/dist/editor.html`), the same file sync (`../shared/notesync.swift`) and embeds (`../shared/embedfiles.swift`),
and our player from Gallery (`../library/src/client/`, served through `HostApp/iOS/Player.swift`). It talks to the
Gallery Worker (`../library/`) only through its API, so a push here never redeploys the website.

| Folder | What |
|---|---|
| `ios/` | the Xcode project (`GalleryFiles.xcodeproj`, bundle `com.chauphan.galleryfiles`), assets, entitlements, `build.sh` |
| `HostApp/iOS/` | the app: Browser (sidebar), Draftpad, Player, Listen, Captions |
| `ios/Broadcast/` | the screen-broadcast extension: hears other apps' audio, transcribes on the device (SpeechAnalyzer on iOS 26 through `../shared/speechcore.swift`, listed by hand in the project; SFSpeechRecognizer before) |
| `Extension/`, `FileProviderCore/` | the File Provider: Archive in the Files app (and Finder, for the Mac app) |
| `macos/`, `HostApp/macOS/` | Gallery for the Mac (retiring) |
| `Icon/` | the icon's source (`icon.swift`) |

## Recense for iPhone and iPad (`ios/`, `HostApp/iOS/`; formerly Gallery)
The home-screen name is **Recense** (11-06) with Gallery's icon; the bundle id stays `com.chauphan.galleryfiles`, so it
updates in place.
- **Places** (`HostApp/iOS/Places.swift`): the app's own screens (Draftpad, Archive, Main, Ask, Data, Exhibits,
  Shared) as ShowsKit `Place`s, rows in Library; Listen is on Home instead (below) (B2 redo, 11-07). Each wears the skin: native screens a large title and
  the accent (`.recenseScreen`), web places and the Draftpad editor an inline title (`.webPlace`), round toolbar buttons
  (`.glassCircle()`, glass on iOS 26) and a `···` menu holding every action (`MoreMenu`). Archive and Listen's episodes
  are rows like Podcasts' Recently Played (square picture, title, detail); inside a folder rows are the default, Icons
  is in `···` › View.
  Library opens a place with a view link, so a place opens its own rows with view links too (`NavigationLink { … }`),
  never `NavigationLink(value:)` + `navigationDestination(for:)`: on that stack a value push opened a second Listen
  instead of the episode, and Archive's top level instead of the tapped folder (both fixed 11-09).
- **The root (11-07): the Podcasts-style shell** (`HostApp/iOS/Shows.swift`, from `../shared/ShowsKit/`): Home (Up Next,
  Recently Played), New (what landed in `Recense/inbox/`), Library (Shows, Study, Folio, Matters with Face ID, Saved,
  Downloaded, Latest Episodes, then the places below; Recently Updated), Search; the mini-player above the tab bar.
  Home holds only what is on this device (player S3, 11-13): `PoolScan` reads `Documents/Recense/{library,downloads,inbox}/`
  at launch and after each saved file; `downloads/` is New, so a file played from the Archive shows in New and Up Next,
  and any episode tapped there plays in our player. With nothing there it says "Nothing here yet" with Open Archive; the
  invented sample shows load only under `SIMCTL_CHILD_RECENSE_TRANSCRIPT=sample` (player P1, 11-13). Our player fills Now Playing in B3. The old sidebar (`Browser.swift`) is kept,
  unused. Simulator checks: `SIMCTL_CHILD_RECENSE_TAB=new|library|search` opens a tab, `SIMCTL_CHILD_RECENSE_NO_LISTEN=1`
  skips the speech prompt, `SIMCTL_CHILD_RECENSE_PLACE=<id>` (draftpad, listen, archive…) opens one place,
  `SIMCTL_CHILD_RECENSE_TRANSCRIPT=sample` opens Now Playing on the sample transcript (English, Vietnamese, French), playing.
- **A show page changes its own folder** (FEAT-13, `../shared/homefiles.swift`, shared with the Mac): "+" picks files in
  the Files app and moves them into the show's folder (a file another app holds on to, such as iCloud Drive, arrives
  as a copy); ··· › Move to… moves an episode into another show (its saved transcript moves with it, so it still opens
  offline), beside Rename… and Delete (FEAT-07). Rows show thumbnails.
- **Lock Screen and Control Center** (BUG-09, 11-14, `NowPlayingInfo.swift`): our player shows its title, folder and a
  time bar you can drag; play, pause, ⏯, back 15 s and forward 30 s work from the Lock Screen and headphones.
  A video's sound plays on when the phone locks or you leave the app (FEAT-19 P2, `BackgroundVideo.swift`): the
  picture lets go of the player in the background and picks it up again when you return.
- **The floating window shows behind Safari** (BUG-14, 11-14): YouTube playing in Safari with the broadcast on now
  shows full captions. Before, the window rested as a thin strip. Two causes: the broadcast's fallback engine
  (SFSpeechRecognizer) never reported sound, and a sound date left by an earlier broadcast read as quiet for good.
  Every engine now reports sound, and a sound older than the running broadcast lets iOS's own flag decide. The float
  log's focus line names the engine (`engine=`).
- **The floating window follows our player** (BUG-10, 11-14): leave Recense while a file plays and the window shows
  that file's transcript, each word lit at its time in the file, its translation under it (FEAT-10); before, Recense's
  own sound didn't count as playing and the window rested as a black strip. While the player holds a file and no
  broadcast hears, the audio session is the player's (Lock Screen controls stay); otherwise it mixes under other apps
  (`NativePlayer.session`).
- **A played file is heard in its own language** (BUG-11, 11-14): on Automatic, each two-minute stretch is first heard
  for 10 s by the English, French and Vietnamese models and the surest wins (`SpeechAhead.choose`, the live check's
  rule); before, every file was heard in the last broadcast's language, English by default. Now Playing says which
  ("Heard on this device in French (automatic)"). Models not on the device are skipped, never downloaded then.
- **Words light as they are heard, headphones too** (BUG-12, 11-14): our player's transcript and the floating window
  read the position less the audio route's latency (`RouteLatency.current`, the web player's rule; Bluetooth ~0.2 s),
  read once per route and logged in the floating window's log. The Lock Screen and skip keep the raw position.
- **Lines are whole sentences** (BUG-13, 11-14): a heard file's lines follow sentence ends, as the Mac's (ShowsKit
  `Phrasing`, ≤ 18 words a line); before, one line per breath ("This is the" / "resent player"). Transcripts this
  device saved the old way are regrouped on open.
- **Follow in · Heard in** (FEAT-10, 11-14, amended 11-18; `translateplan.swift` + `Translate.swift`): a file playing
  in our player shows each line's translation under it. The transcript's ··· menu › Languages has two sections:
  Follow in (English · Français · Tiếng Việt · Off; default Français) and Heard in (Auto-detect, or one language for
  every line; the same setting as Listen's Hear in). The playhead's line is translated first, then the lines after it
  8 at a time, then those before it. Apple's on-device Translation does the work, once a language pair is installed.
- **Our player** (player P1 S2, 11-13, `NativePlayer.swift`): an audio or video file tapped in the Archive plays
  here, in Now Playing, opened on its transcript; other files keep the page viewer. Bytes come from this device first
  (`Recense/<path>`, else `Recense/downloads/<path>`); else the Worker streams them (`/main/api/fp/archive/content`,
  this device's Access token) while a copy is saved to `Recense/downloads/<path>` (files up to 2 GB), so the next play
  needs no network. The transcript (`Ears.swift`): the copy saved on this device, else the Mac's
  (`/main/api/transcript?path=`, saved here at once), else heard on this device once the file is saved here (saved too
  when finished); Now Playing names the source under the title.
  A played file takes its content key from this device's copy (at once, or when the copy lands), so Save, Played and
  Clicked / Not yet work on it.
- **Now Playing's transcript** (11-08): the quote button in Now Playing's toolbar shows the episode's transcript in
  place of the player (which keeps playing under it): ShowsKit's `TranscriptView`, our scrubber under it and back 15 /
  play / forward 30 under that. `Ears.swift` hears the playing episode's file on this device with the shared engine
  (`../shared/speechcore.swift`, two-minute stretches, the playhead's first) in Listen's "Hear in" language. It needs
  the file on the device (B1's pool) and a player that tells its time (B3's `Transport.time`); until then it says so.
- **Draftpad** (top of the sidebar): the Mac's editor (`editor/dist/editor.html`, bundled) on the same `draftpad.md`.
  The first time, choose the Obsidian vault folder (Files › iCloud Drive › Obsidian › Obsidian); it's remembered.
  Saves go through the Mac's 3-way merge (`shared/notesync.swift`), and an edit from the Mac or Obsidian is merged in
  within 3 s while it's open. Load and save are one copy with the Mac (`shared/draftpadfile.swift`, BUG-29): a note or
  ink file that can't be read now is never written over, ink from another device is unioned in, a save runs to the end
  when you leave the app, and the 3 s check reads the files off the main thread. Pages as on the Mac: ‹ › in the toolbar, ⌘[ / ⌘] or two fingers on a trackpad.
  Links open in Safari; `![](file.pdf)` and images show inline (vault files directly, web files cached for offline,
  through `shared/embedfiles.swift`).
  The wings' layout (cards moved between the two sides, pins) saves to `draftpad.wings.json`, as on the Mac. In a wing:
  swipe a card left to Remove (Undo, 5 s) or right to Pin, with a haptic at the threshold; each card's ··· menu does the
  same, plus Size (S–XL, also by dragging the bar on a card's bottom edge); **Show in wing…** at the top adds a card back (open by itself, keyboard up, when nothing plays). Swipe in from
  the screen's left or right edge to bring out that wing (no long hold). The ink palette, colour wheel (the system colour
  picker samples any shade) and handwriting search (⌘F finds ink, read on the device by `shared/inkocr.swift`) are the
  Mac's, from the same page. So are saved pages (bookmark), the Saved and Playlists tabs, the 14-day expiry (archived to
  `Draftpad expired/` in the vault) and the calendar sheet (`shared/draftpadlibrary.swift`).
  The Recense layer (✦: Gist, Reformat, Source under your text, each line citing its sentences) and the Chapters tab
  run here too, on the device (`shared/recensetext.swift`; the model needs Apple Intelligence, iOS 26).
- **Apple Pencil in Draftpad:** write into the text with Scribble (iPadOS turns handwriting into typed text).
  Squeeze (Apple Pencil Pro), double-tap, or the pencil button opens the ink layer: the Pencil draws, fingers still
  scroll, and the system palette follows the Pencil Pro (barrel roll, squeeze for the compact palette). **Done** saves
  the drawing in `Draftpad ink/` next to the note, as a PNG (dark ink on white, shown by the editor and Obsidian) plus
  its PencilKit `.drawing`, and puts `![](<Draftpad ink/….png>)` under the cursor's line. **Cancel** throws it away.
- A Files-like browser over Main and the archive, with Gallery's own player and Learn mode inside the app
  (`gallery://` scheme handler), and an Assistant button on each folder (⌘K on an iPad keyboard).
- Gallery as a location in the Files app (File Provider extension), with the app's icon and a shared Keychain token.
- Folders have the site's header, a … menu and Select: Download (Save to Files), AirDrop, Create Share Link, Invite,
  Add Media (Photos or Files), New Folder. Writes never overwrite.
  A file over 90 MiB goes up in parts (16–90 MiB, at most 10,000: ~879 GiB), each sent from a temp file, 4 tries each.
- **Listen**: Recense on the iPhone and iPad, first on **Home** as the "Now Playing" card (`HostApp/iOS/ListeningCard.swift`,
  11-10): which ear hears and in which language, the live transcript of what plays (ShowsKit's `TranscriptView`),
  and one button that says what it does now (`Listener.control`, the same on Listen): **Start listening** when nothing hears,
  **Pause listening** while hearing, **Resume listening** when paused; "Now Playing ›" opens Listen. A newer listening takes the card and bumps the one before down to
  Home's Recently Played, merged with the catalog's by when each played (ShowsKit `HomeExtras`, `ListenEpisodeRow`). It hears the media only, never the room
  (owner, 2026-11-10, "Yes, no mic"): captions come from the broadcast (another app's sound itself,
  `ios/Broadcast/SampleHandler.swift`) or Recense's own player. The mic code and the microphone permission went on 11-11
  (`MicEar.swift`, Listen's mic calls, `NSMicrophoneUsageDescription`), so iOS never asks for it. The stop notification
  comes only after hearing really ended, never on a launch or a Resume with no broadcast (`ListenEars.swift`, `Prompts.ended`).
  "Start listening" starts the broadcast: the button is the system's
  own broadcast picker under our label (`StartBroadcast`), because iOS no longer opens the sheet for a picker tapped from
  code (11-10); then one tap on the sheet's Start Broadcast (or Control Center › Screen Recording, long press › Recense).
  It hears through headphones too. With no broadcast (any route, or iOS ended it) the page says why under
  Start, and a notification asks once per stop. An episode that heard nothing is not kept.
  iPhone Mirroring can't show that sheet: check hearing on the phone in hand.
  One **Pause** (page and ··· menu) stops hearing and is kept across launches. Every input's outcome is a written-down
  truth table, `ios/Tests/ears/main.swift`. Each listening is its own episode,
  named by when it began and its language, a silence of 3 minutes starts the next, and one that continues an older
  episode joins it (below). The broadcast
  extension hears whatever is playing in any app, recognised on the device in its own language, cut into sentences
  and translated with Apple's on-device Translation. Lines float in a Picture in Picture window over every app,
  in Follow (the sentence before, quiet, then the one being heard lit as it's said, its translation under it) or Learn
  (two sentences taking turns), drawn with ShowsKit's `TranscriptLineText` (the transcript's own line) at 3x on a
  400x188 pt canvas, left-aligned, older text fading at the top, a new picture only when it changes (at most 10 a
  second); in the app, the shared
  transcript view (ShowsKit's `TranscriptView`, the one Now Playing has): the sentence being heard bold, its words lit
  at the voice's own pace from SpeechAnalyzer's word times (a moment behind, as live captions must be), the translation
  under each line, hold a line for Share / Copy / Select Text; Clear and full screen in the ··· menu. When the Mac is
  transcribing live and Gallery has uploaded timestamped sentences within the last 2 minutes, the iOS transcript also
  animates — the Mac's own player clock (`clock`, `rate` in what it sends, FEAT-04) drives the active line and word
  highlight instead of the iOS broadcast index — so both devices show the same lit sentence and translation trail without
  a local broadcast running (`ListenView.transcript()`, `Listener.contentNow`). What's heard is
  kept per episode in the same transcript store as the Mac (each sentence's timed words too, in seconds into the episode:
  one clock everywhere, ShowsKit `ContentClock`; files from before 11-12 timed on the wall clock read onto it), on the device in
  `Documents/Recense/library/Listen/` (the places contract; episodes from the old `Documents/Listen/episodes/` move there on
  first launch, the older of two copies going to `Recense/trash/`). Episodes Gallery hasn't taken yet are remembered across
  launches (`listen.unsent`), so what was heard offline uploads once the network is back.
- **The homes** (`../shared/homes.swift`, spec `../docs/specs/FEAT-06-homes-folder-contract.md`): `Documents/Recense/`
  holds the same layout as the Mac's `~/Recense/` — `library/Music/`, `library/Study/`, `library/Legal/`,
  `library/Audiobooks/`, `library/Listen/`, `downloads/`, `trash/` — created at launch and visible in the Files app.
  Each keeps `.recense-index.json` (path, size, SHA-256, added, device, tags). A file taken in is moved, never
  overwritten, and hashed as it lands; Remove puts it in `trash/` with where it came from, and only Trash can delete
  forever. No network at any point. Moving bytes between devices by themselves (FEAT-09): pairing and a one-way
  "Carry Now" push are wired (Library › Devices, `HostApp/iOS/Devices.swift`); the full move/trash/restore replay
  across devices is not built yet. Pairing finishes on both devices whichever taps "They Match" first (BUG-17).
  A device paired on one side only is fixed by pairing again: Library › Devices › Pair a Device… on both, in
  either order (the device you pick is invited again until it answers).
  A carried file counts as settled only once its bytes are placed; a file still owed shows "Waiting for N files" and
  is asked for again on the next Carry Now (BUG-19).
  Carry's staging (BUG-25): received bytes wait in `.carry/incoming/` under a 64-character SHA-256 name, so long or
  accented file names stage too; a file deleted after it was carried is answered "gone", so the other device stops
  waiting; staged bytes nothing waits for are removed at launch and, after 10 minutes, before each carry.
  Pairing holds steady (BUG-26): a duplicate message is ignored instead of ending both sides; the code may be typed
  or spoken in any script's digits or as words in English, Vietnamese, French or Spanish ("one two three…"); anything
  else asks again. One pairing prompt at a time: a second nearby device waits until the first is done.
  A device that leaves mid-prompt takes its prompt with it (T-0121); after a wrong code, whichever device you
  pick next shows the new code (T-0123).
  A paired device proves its key, not its name (SEC-02, `../shared/carryauth.swift`): every connection runs a
  handshake, and what changed (seen, ops, gone) travels sealed and counted, so a renamed or reset device gets nothing
  and changes nothing. A carried file lands only if its SHA-256 is the one its change promised, and never outside
  `Recense/`. Devices paired before this need pairing again once: Library › Devices lists them under
  "Needs pairing again"; carry with them pauses and nothing is deleted. Each paired row has Forget (also "Forget Device"
  by voice): carry with that device stops on both sides until you pair it again; files stay.
  An edit replaces the other device's copy when that copy is the version it was edited from (BUG-27); the old version
  goes to `trash/`. Only when both devices changed the file are both kept, the copy named for the device that made it.
  After a reinstall (pairing survives in the Keychain), the new log is renumbered above what each peer already saw,
  so its changes reach them at the next carry (BUG-28).
  Pairing (T-0086): pick the other device's name in Library › Devices; this screen shows six digits; type them on the
  other device (number field, "Enter Pairing Code" by voice, the Mac's Pair a Device window, or `recense carry pair`).
  Carry runs by itself (T-0084): when a paired device connects, 2 s after a home stops changing, and when Recense
  comes to the front; Carry Now stays as the visible retry. The scan runs off the main thread and re-hashes only
  files whose size or date changed.
  **Automatic** language (S6, 11-10, the default): the ears follow whichever of English, French and Vietnamese is
  spoken (`SpeechAuto` in `../shared/speechcore.swift`): the last 8 s stay in memory only; on doubt (few or unsure words,
  or a minute of sound) the last 4 s are heard in each language and the surest by a clear margin (1.5x) wins; the new
  engine re-hears those 8 s before the old one stops, so nothing is lost. The heard language in the wrong model scored
  91-100 % word errors on FLEURS; in its own, en 9.2 %, fr 8.0 %, vi 21.2 %. Each check is logged in the app's
  `listen.checks` (Library/Preferences). Choosing a language in "Hear in" pins it.
  Ears (iOS 26): choosing "Hear in" downloads that language's SpeechAnalyzer model once (Automatic: all three) (the only time Listen needs a
  connection); the line under the picker says which ears hear it here. Without it (iOS 18-25, or no model), and for a
  day after iOS ends a broadcast that used it, SFSpeechRecognizer on the device hears instead (no word times).
  Word times run on the sound's own clock (`HostApp/iOS/SoundClock.swift`): t0 is the first buffer's presentation
  stamp, not when it reached the extension, and a pause in the other app stays a pause (up to 2 s fed as silence, the
  rest added to later words). Before (11-10) every pause pulled the words after it early by its length.
  The floating window has no Dock: it shows by itself when Recense is left while another app plays, hides in
  Recense (Home shows the transcript) and 0.3 s after that app pauses, decided 10 times a second; "pauses" means the broadcast heard no real sound for 0.4 s (`Floating.playing`), since iOS keeps its own "other audio playing" flag on for ~40 s after a pause (T-0041) (`HostApp/iOS/Floating.swift`, tested in
  `ios/Tests/floating`). Whether iOS lets it reopen from behind when the sound plays again is measured on the
  device and kept (`listen.reshowFromBehind2`: works, or refused only on iOS's own error; 11-10's "refused" came from a
  silent wait and is set aside); behind other apps Recense stays awake while the window is open and for 10 minutes of
  quiet (`Floating.awake`), so a play there shows it, 1 s after leaving at the earliest (`Floating.settle`);
  iOS opens it only as Recense is left, never from behind (11-10 19:19:42, AVKitErrorDomain -1001), so it opens on every
  leave unless Listen is paused, even before any sound plays (`Floating.autoOpen`; T-0002: YouTube starts after you leave):
  quiet or paused, any open window rests as a thin dark strip, front or behind, held or not, so no old caption stays on
  screen (T-0077, T-0139); the next sound brings back full captions (`Floating.rest`). iOS's real window size is logged (`iOS: window W×H`). It closes behind only
  where iOS was seen to reopen it, or after 10 minutes of quiet (battery). Behind other apps iOS ignores a plain
  stop, so hiding detaches the window's content; the next tick gives it back once it's closed (`Floating.reattach`),
  or iOS had nothing to open as Recense was left (11-10 iPhone log). A start iOS refuses is logged with its error. Each decision is logged in `listen.floatLog` (Library/Preferences).
  Its layer sits behind Home's transcript and is Listen's preview, so leaving from either opens it. One host holds it at a
  time, the last on screen (11-10: both took it on every layout and iOS's watchdog ended Recense as Now Playing opened).
  The floating window's middle button pauses it: the window rests as the thin strip at once (our player pauses too;
  T-0036, T-0038, 11-18; before, it held the old words on a full window), and play brings back the newest words.
  Its words light on the refresh they start on, and sweep inside a word (BUG-24 P1b, 11-18): every moment the picture
  changes (a word's start, each quarter of a word of 0.25 s or more, a line's turn, a Learn fade) is drawn up to 1.5 s
  ahead and stamped for that moment at the player's speed (ShowsKit `FloatingFrames`); the layer runs on the host clock
  and shows it then. At most 12 pictures wait. Before (11-10), a word waited for the next redraw, at most 10 a second
  and up to a second behind other apps; until 11-18 a word lit whole at its start, and at 1.5× each lit late.
  Nothing lost: the extension also keeps its recent lines in a ring in the shared Keychain (`HostApp/iOS/CaptionRing.swift`,
  200 lines or 128 KB, text only), and the app takes the ones it missed when it wakes or is opened again, so a stretch
  heard while iOS had the app asleep or closed still reaches the episode.
  Offline translation: the line under the language pickers says whether the pair translates on this device;
  **Download** fetches English, Vietnamese and French once (iOS asks before each), counting each direction as it goes, then
  says which arrived and, for any that didn't, iOS's reason (a declined sheet used to look like nothing happened). A sentence that couldn't
  be translated says "not translated (pack missing)" instead of staying blank, and is translated once the pack is there.
  One transcript, never twice (`HostApp/iOS/Align.swift`): content left partway and resumed, rewound, or replayed from
  the start lands on the sentences the episode already has (a sentence left cut short is completed; a short one like
  "Oui." is recognised only right after the sentence it follows); new stretches are spliced in after the last place
  recognised. A listening whose first sentences continue another episode of the last 30 days (three in a row, in order)
  joins that episode, so two shows that share an intro stay apart. Text only for now: the speech engines still hear a
  replay (acoustic fingerprints come next).
- **Export on iPhone/iPad**: the transcript editor's Export as MD and Export as M4B work in the app: the page hands
  the file to the app, which offers Save to Files; the M4B is made on the device (AAC, title, transcript as lyrics;
  no chapters yet).

### Library › Music (FEAT-07 P0, 2026-11-15)
Tap **Music** under Library › Recently Updated. You get every track in `Recense/library/Music`.
- **Play / Pause:** the capsule on each row. It shows a pause sign while that track plays.
- **Loop:** in the row's ··· menu once the track plays. The capsule shows ⟲1 while it's on.
- **Rename…:** in the ··· menu. The file is renamed and its extension kept, and the next Carry sync renames it on every paired device.
- **Delete:** slide the row **left → right**, or ··· › Delete. The track goes to `Recense/trash/` and can be restored.

### The search pill and the translation that follows the voice (FEAT-07 P1–P2, FEAT-10; 2026-11-15)
- **Find:** in Now Playing's transcript, tap the 🔍 at the left of the pill (or the transcript menu › Find in Transcript…).
  Type two letters or more. Accents and case don't matter ("viet" finds "Việt"). ⌃ ⌄ go to the previous or next match and
  play from there, and the view keeps following the voice. To scrub again, tap the waveform or hold the pill for 0.35 s.
- **Marks and detents:** matches show as marks on the scrubber, and sliding across one gives a firm tap (lines a light one).
- **Two sizes:** drag Now Playing down to half height (minimized); the transcript and the pill keep working.
- **Translation:** the translated line lights word by word at the pace of the original voice, pauses included.

## Gallery for the Mac (`macos/`, `HostApp/macOS/`; retiring: Recense Mac takes over)
- The whole site in a native window through the Mac's token, with an Assistant button (⌘K), the same … menu and
  Select, Download to Downloads and native AirDrop.
- Gallery as a location in Finder (File Provider extension). Deletes go both ways: what Gallery deletes leaves
  Finder, and a file deleted in Finder or Files goes to Gallery's trash for 30 days (`DELETE /main/api/fp/<root>/item`);
  folders are deleted in Gallery.

**FEAT-16 P3 (11-16):** a stored show with no finished transcript is paused at once and plays only when the on-device hearing is whole ("Loading transcript… N%"); a failed hearing releases it. `Ears.gate` (ListenEars.swift) holds the rule; test: `swiftc -O mobile/HostApp/iOS/ListenEars.swift mobile/ios/Tests/ears/main.swift`.

## Build and install

```
zsh mobile/ios/build.sh [device name or id]   # builds and installs on a connected iPhone or iPad
zsh mobile/macos/build.sh                     # builds and installs the Mac app in /Applications
zsh mobile/ios/build.sh --guest [device]      # Recense Guest: installs it and writes an unsigned .ipa
```

**Recense Guest** (iPhone only; targets `RecenseGuest` + `RecenseGuestBroadcast`, entry `HostApp/iOS/GuestApp.swift`,
compiled with the `GUEST` flag): Now Playing only (start listening, the live transcript, languages, the floating window,
earlier episodes). Same Listen code as Recense; no Library, Draftpad, Archive in Files or Gallery token, so nothing in
it reaches Gallery, and no SSH (`Terminal.swift` is an empty stub under `GUEST`, so the app links no SwiftNIO). `build.sh --guest` installs it here and writes `build/guest-<date>/RecenseGuest.ipa`, unsigned, for
the guest to sign in Sideloadly with their own Apple ID. The app and its broadcast extension find each other through the
Keychain group they were signed with (`Captions.group`, read at runtime), so a re-signed build still works.

Now Playing rules fixed 11-10 (owner's iPad videos): on iPad, Recense counts as in front only while its window has the
focus (another app's window can cover it while it stays active), so the floating window opens under a full-screen app
(`Floating.front`); a line heard again (a song's chorus) stays in order at the end and keeps the light, and only three
in a row, or a replay that reaches where the listening was, counts as a rewind (`Align.fit`). Pause rests the broadcast
instead of ending it (`Captions.State.hold`; the extension drops the sound and its clock keeps the gap), so iOS shows
no "stopped" alert and Resume needs no broadcast sheet. The floating window is drawn by the one caption painter
(ShowsKit `CaptionPainter`, FEAT-05), as the in-app modes: Follow, the line the transcript turns to, gold up to the
voice, its translation under it; Learn, the two places, each sentence turning into its translation once heard. Only
whole lines show: a long line shrinks (to 60 %) before it is cut (`HostApp/iOS/FloatingCaption.swift`, drawn straight
into the frame's pixels, rendered on the Mac by `ios/Tests/floatingcaption`).

New Swift files in `HostApp/iOS/` or `../shared/` are built in automatically (synchronized folders); others go into the project by hand.
`../shared/ShowsKit/` is the exception: a Swift package the app links (`import ShowsKit`), excluded from the synchronized group.
Built with Xcode 27.2 (`/Applications/Xcode-27.2.0.app`, iOS 27.2 SDK; `build.sh` picks it unless `DEVELOPER_DIR` is set). Devices are named by UDID.
With no device named, `build.sh` picks the first physical iPhone or iPad (booted simulators are listed as connected too since Xcode 27).
The unsigned compile (`CODE_SIGNING_ALLOWED=NO`) only proves the code builds; nothing reaches a device until `build.sh` runs.
It needs the device service and the Keychain, so a sandboxed agent session must run it outside the sandbox.
Signed with a free Personal Team, so the iOS profile lasts 7 days. `sync/bin/resign-ios.zsh` runs daily and checks
each device on its own: one whose app is missing or was installed 5 or more days ago is reinstalled (the cached
profile is renewed first when 2 days or less are left). Per-device stamps: `~/Library/Application Support/recense/resign-ios/`. The device's Access token comes from the Keychain (`gallery-access-<device>`, else
`gallery-access`) into `Secrets/token.json`, which git ignores.

## Testing on the iPhone
`zsh mobile/ios/mirror-shot.zsh <out.png> --launch` opens Recense on the iPhone through iPhone Mirroring and screenshots that window; builds are checked there, not in the simulator. It
launches Recense paused for that run (its mic otherwise blocks Mirroring); Mirroring ignores scrolling sent from the Mac, so screens below
the fold are checked on the phone in hand.

## Headphones (Places › Headphones)
The iPhone and iPad half of Bose Bridge (`docs/specs/FEAT-15-bose-bridge.md`), sharing every rule with the Mac
through `shared/bosebridge.swift`:
- the live route, read from AVAudioSession, and what to plug in when it drops, for your exact pair;
- what that pair really allows (how many devices it holds, whether the cable plays with it switched off,
  whether USB-C carries sound) — the battery level is Mac-only, because iOS has no public API for it;
- **Two at once:** two pieces from Music, Listen or Audiobooks play together, each with its own volume and ear;
- **Where I left off:** the seats any device wrote (`library/Listen/seats.jsonl`), carried offline by FEAT-09.
Code: `mobile/HostApp/iOS/Headphones.swift`, one row in `Places.swift`. No network at any point.
