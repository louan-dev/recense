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
  Sample shows until B1's pool store; our player fills Now Playing in B3. The old sidebar (`Browser.swift`) is kept,
  unused. Simulator checks: `SIMCTL_CHILD_RECENSE_TAB=new|library|search` opens a tab, `SIMCTL_CHILD_RECENSE_NO_LISTEN=1`
  skips the speech prompt, `SIMCTL_CHILD_RECENSE_PLACE=<id>` (draftpad, listen, archive…) opens one place,
  `SIMCTL_CHILD_RECENSE_TRANSCRIPT=sample` opens Now Playing on the sample transcript (English, Vietnamese, French), playing.
- **Now Playing's transcript** (11-08): the quote button in Now Playing's toolbar shows the episode's transcript in
  place of the player (which keeps playing under it): ShowsKit's `TranscriptView`, our scrubber under it and back 15 /
  play / forward 30 under that. `Ears.swift` hears the playing episode's file on this device with the shared engine
  (`../shared/speechcore.swift`, two-minute stretches, the playhead's first) in Listen's "Hear in" language. It needs
  the file on the device (B1's pool) and a player that tells its time (B3's `Transport.time`); until then it says so.
- **Draftpad** (top of the sidebar): the Mac's editor (`editor/dist/editor.html`, bundled) on the same `draftpad.md`.
  The first time, choose the Obsidian vault folder (Files › iCloud Drive › Obsidian › Obsidian); it's remembered.
  Saves go through the Mac's 3-way merge (`shared/notesync.swift`), and an edit from the Mac or Obsidian is merged in
  within 3 s while it's open. Pages as on the Mac: ‹ › in the toolbar, ⌘[ / ⌘] or two fingers on a trackpad.
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
- **Listen**: Recense on the iPhone and iPad, first on **Home** as the "Now Playing" card (`HostApp/iOS/ListeningCard.swift`,
  11-10): which ear hears and in which language, the live transcript of what plays (ShowsKit's `TranscriptView`),
  and one button that says what it does now (`Listener.control`, the same on Listen): **Start listening** when nothing hears,
  **Pause listening** while hearing, **Resume listening** when paused; "Now Playing ›" opens Listen. A newer listening takes the card and bumps the one before down to
  Home's Recently Played, merged with the catalog's by when each played (ShowsKit `HomeExtras`, `ListenEpisodeRow`). It hears by itself (`HostApp/iOS/ListenEars.swift`, `MicEar.swift`):
  with the sound on the device's own speaker, the microphone hears what plays, fed to the speech engine only while
  another app plays, text only, never audio (iOS asks once for the microphone; denied: no mic, nothing nags).
  "Start listening" (or, while the mic hears, "Hear other apps directly") starts the broadcast: the button is the system's
  own broadcast picker under our label (`StartBroadcast`), because iOS no longer opens the sheet for a picker tapped from
  code (11-10); then one tap on the sheet's Start Broadcast (or Control Center › Screen Recording, long press › Recense).
  It hears through headphones too. With neither (headphones and no broadcast, or iOS ended it) the page says why under
  Start, and a notification asks once per stop. An episode that heard nothing is not kept.
  iPhone Mirroring can't show that sheet or lend the phone's mic: check hearing on the phone in hand.
  iOS won't start the microphone while Recense is in the background, so there it asks instead.
  One **Pause** (page and ··· menu) stops both and is kept across launches. Every input's outcome is a written-down
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
  under each line, hold a line for Share / Copy / Select Text; Clear and full screen in the ··· menu. What's heard is
  kept per episode in the same transcript store as the Mac (each sentence's timed words too), on the device in
  `Documents/Recense/library/Listen/` (the places contract; episodes from the old `Documents/Listen/episodes/` move there on
  first launch, the older of two copies going to `Recense/trash/`).
  **Automatic** language (S6, 11-10, the default): the ears follow whichever of English, French and Vietnamese is
  spoken (`SpeechAuto` in `../shared/speechcore.swift`): the last 8 s stay in memory only; on doubt (few or unsure words,
  or a minute of sound) the last 4 s are heard in each language and the surest by a clear margin (1.5x) wins; the new
  engine re-hears those 8 s before the old one stops, so nothing is lost. The heard language in the wrong model scored
  91-100 % word errors on FLEURS; in its own, en 9.2 %, fr 8.0 %, vi 21.2 %. Each check is logged in the app's
  `listen.checks` (Library/Preferences). Choosing a language in "Hear in" pins it.
  Ears (iOS 26): choosing "Hear in" downloads that language's SpeechAnalyzer model once (Automatic: all three) (the only time Listen needs a
  connection); the line under the picker says which ears hear it here. Without it (iOS 18-25, or no model), and for a
  day after iOS ends a broadcast that used it, SFSpeechRecognizer on the device hears instead (no word times).
  The floating window has no Dock: it shows by itself when Recense is left while another app plays, hides in
  Recense (Home shows the transcript) and after 3 s of that app paused (`HostApp/iOS/Floating.swift`, tested in
  `ios/Tests/floating`). Whether iOS lets it reopen from behind when the sound plays again is measured on the
  device and kept (`listen.reshowFromBehind`: works or refused); Recense stays awake up to 10 minutes after hiding it, to reopen it on play; if refused, it stays open on pause so no line is missed (11-10 iPhone: refused). Behind other apps iOS ignores a plain
  stop, so hiding detaches the window's content; the next tick gives it back once it's closed (`Floating.reattach`),
  or iOS had nothing to open as Recense was left (11-10 iPhone log). A start iOS refuses is logged with its error. Each decision is logged in `listen.floatLog` (Library/Preferences).
  Its layer sits behind Home's transcript and is Listen's preview, so leaving from either opens it. One host holds it at a
  time, the last on screen (11-10: both took it on every layout and iOS's watchdog ended Recense as Now Playing opened).
  The floating window's middle button holds the words where they are and play shows the newest.
  Its words light on the refresh they start on: each coming word's picture is drawn up to 1.5 s ahead and stamped for
  that moment (`Floating.onsets`); the layer runs on the host clock and shows it then. Before (11-10), a word waited
  for the next redraw, at most 10 a second and up to a second behind other apps.
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

## Gallery for the Mac (`macos/`, `HostApp/macOS/`; retiring: Recense Mac takes over)
- The whole site in a native window through the Mac's token, with an Assistant button (⌘K), the same … menu and
  Select, Download to Downloads and native AirDrop.
- Gallery as a location in Finder (File Provider extension). Deletes go both ways: what Gallery deletes leaves
  Finder, and a file deleted in Finder or Files goes to Gallery's trash for 30 days (`DELETE /main/api/fp/<root>/item`);
  folders are deleted in Gallery.

## Build and install

```
zsh mobile/ios/build.sh [device name or id]   # builds and installs on a connected iPhone or iPad
zsh mobile/macos/build.sh                     # builds and installs the Mac app in /Applications
```

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
`zsh mobile/ios/mirror-shot.zsh <out.png> --launch` opens Recense on the iPhone through iPhone Mirroring and screenshots that window; builds are checked there, not in the simulator.
