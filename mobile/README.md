# Recense mobile (`mobile/`)

Recense for iPhone and iPad: the mirror of Recense for the Mac (`../strip/`). The same Draftpad editor
(`../editor/dist/editor.html`), the same file sync (`../shared/notesync.swift`) and embeds (`../shared/embedfiles.swift`),
and our player from Gallery (`../library/src/client/`, served through `HostApp/iOS/Player.swift`). It talks to the
Gallery Worker (`../library/`) only through its API, so a push here never redeploys the website.

| Folder | What |
|---|---|
| `ios/` | the Xcode project (`GalleryFiles.xcodeproj`, bundle `com.chauphan.galleryfiles`), assets, entitlements, `build.sh` |
| `HostApp/iOS/` | the app: Browser (sidebar), Draftpad, Player, Listen, Captions |
| `ios/Broadcast/` | the screen-broadcast extension: hears other apps' audio, transcribes on the device |
| `Extension/`, `FileProviderCore/` | the File Provider: Archive in the Files app (and Finder, for the Mac app) |
| `macos/`, `HostApp/macOS/` | Gallery for the Mac (retiring) |
| `Icon/` | the icon's source (`icon.swift`) |

## Recense for iPhone and iPad (`ios/`, `HostApp/iOS/`; formerly Gallery)
The home-screen name is **Recense** (11-06) with Gallery's icon; the bundle id stays `com.chauphan.galleryfiles`, so it
updates in place.
- **Places** (`HostApp/iOS/Places.swift`): the app's own screens (Draftpad, Listen, Ask, Main, Archive, Data, Exhibits,
  Shared) as ShowsKit `Place`s, the rows the skin's Library shows (B2 redo, 11-07).
- **Shows (preview)** (sidebar, under Draftpad): the Podcasts-style skin from `../shared/ShowsKit/` (B2). Spaces as tabs on
  the iPhone and a sidebar on the iPad; the Library grid; each show's seasons and episodes (swipe or long-press a row to
  Star or mark Played); the mini-player and Now Playing with **Clicked / Not yet**; Matters opens only with Face ID. It
  runs on a made-up sample pool until B1's pool store lands; our player fills Now Playing in B3
  (`HostApp/iOS/Shows.swift`). Simulator check: launch with `SIMCTL_CHILD_RECENSE_OPEN=shows` to open it directly.
- **Draftpad** (top of the sidebar): the Mac's editor (`editor/dist/editor.html`, bundled) on the same `draftpad.md`.
  The first time, choose the Obsidian vault folder (Files › iCloud Drive › Obsidian › Obsidian); it's remembered.
  Saves go through the Mac's 3-way merge (`shared/notesync.swift`), and an edit from the Mac or Obsidian is merged in
  within 3 s while it's open. Pages as on the Mac: ‹ › in the toolbar, ⌘[ / ⌘] or two fingers on a trackpad.
  Links open in Safari; `![](file.pdf)` and images show inline (vault files directly, web files cached for offline,
  through `shared/embedfiles.swift`).
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
- **Listen**: Recense on the iPhone and iPad. Start it from Control Center › Screen Recording › Gallery; the broadcast
  extension hears whatever is playing in any app, recognised on the device in its own language, cut into sentences
  and translated with Apple's on-device Translation. Lines float in a Picture in Picture window over every app,
  in Follow (sentence and translation, newest word lit) or Learn (two sentences taking turns); in the app, Read along
  with Copy, Clear and full screen. What's heard is kept per episode in the same transcript store as the Mac.
  The floating window draws as Recense's overlay does (same yellow, semibold words, the translation a step quieter);
  its middle button holds the words where they are and play shows the newest. Read along shows a word only once
  speech recognition has stopped rewriting it (Settle), so sentences grow calmly.
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
Signed with a free Personal Team, so the iOS profile lasts 7 days. `sync/bin/resign-ios.zsh` runs daily and checks
each device on its own: one whose app is missing or was installed 5 or more days ago is reinstalled (the cached
profile is renewed first when 2 days or less are left). Per-device stamps: `~/Library/Application Support/recense/resign-ios/`. The device's Access token comes from the Keychain (`gallery-access-<device>`, else
`gallery-access`) into `Secrets/token.json`, which git ignores.
