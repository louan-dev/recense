# CLAUDE.md · Recense mobile (`mobile/`): Recense for iPhone and iPad

Also read the root guide `../.claude/CLAUDE.md` (its rules apply here). Plan: `docs/PROGRESS.md` §2 Rules, then only the
section for the task. Architecture: `~/.claude/plans/starry-squishing-knuth.md` (copied to `docs/` in B0).

## Mirror rule (owner, 2026-11-06)
- Recense mobile mirrors Recense Mac (`../strip/`). A change to a shared surface ships to both in the same change:
  - **Draftpad:** `../editor/` (bundled `editor/dist/editor.html`), `HostApp/iOS/Draftpad.swift` here, `strip/editorhost.swift` on the Mac, sync in `../shared/notesync.swift`.
  - **The player:** one home, `../library/src/client/`; Mac, mobile and web all use it. Test all three.
  - **The skin** (Podcasts-style spaces, shows, episodes) and the **strip controls** that carry over: Swift goes in `../shared/`, never copied into one app.
- Mac-only (stay in `strip/`): menu-bar hider, brightness, CoreAudio volume, vault, the Mac's own terminal (the iPhone and iPad SSH to it from Library › Terminal, `../shared/SSHKit`, owner 11-10). iOS-only: the broadcast extension, Pencil.

## Build and check
- `zsh mobile/ios/build.sh [device]`: builds and installs on a connected iPhone or iPad (free team, 7-day profile; `sync/bin/resign-ios.zsh` renews daily).
- The unsigned compile (`CODE_SIGNING_ALLOWED=NO`) is a check, not a delivery. After any merge that touches the iOS app,
  run `zsh mobile/ios/build.sh <UDID>` for the iPad (`00008122-0009799A026B801C`) and the iPhone (`00008101-001A50643A98001E`).
  It needs CoreDevice and the Keychain: in a sandboxed session run it outside the sandbox, or the owner is left on an old build.
  Install fails with "device disconnected immediately": the Wi-Fi tunnel dropped; check `xcrun devicectl device info details --device <UDID>` shows connected, then reinstall the same `.app`.
- One iOS build at a time across sessions (`.handoff/MERGE-QUEUE`).
- **Test on the real iPhone through iPhone Mirroring, never the simulator (owner, 2026-11-10).** After the install:
  `zsh mobile/ios/mirror-shot.zsh "$TMPDIR/shots/<screen>.png" --launch` (launches Recense on the iPhone, opens iPhone
  Mirroring, screenshots only its window; outside the sandbox). Look at every screen you touched in it, drive it there, and
  name the shots in the Checked: line. A simulator screenshot is not evidence.
  "could not create image": the app running the session (Terminal; a session agent-resume started runs under launchd and
  has none) lacks System Settings › Privacy & Security › Screen & System Audio Recording; say so and ask the owner to check.
- Caption seek (`shared/CaptionSeek.swift`), after any change to it or to `shared/fingerprint.swift`:
  `swiftc -O shared/fingerprint.swift shared/CaptionSeek.swift mobile/ios/Tests/captionseek/main.swift -o "$TMPDIR/captionseek" && "$TMPDIR/captionseek"` (ALL OK).
- Listen's caption ring (`HostApp/iOS/CaptionRing.swift`), after any change to it or to `Captions.swift`:
  `swiftc -O mobile/HostApp/iOS/CaptionRing.swift mobile/ios/Tests/captionring/main.swift -o "$TMPDIR/captionring" && "$TMPDIR/captionring"` (ALL OK).
- The broadcast's clock (`HostApp/iOS/SoundClock.swift`: t0 from the sound's stamps, pauses kept), after any change to it or to `SampleHandler.processSampleBuffer`:
  `swiftc -O mobile/HostApp/iOS/SoundClock.swift mobile/ios/Tests/soundclock/main.swift -o "$TMPDIR/soundclock" && "$TMPDIR/soundclock"` (ALL OK).
- Listen's alignment (`HostApp/iOS/Align.swift`), after any change to it or to `Listener.rebuild()`:
  `swiftc -O mobile/HostApp/iOS/Align.swift mobile/ios/Tests/align/main.swift -o "$TMPDIR/align" && "$TMPDIR/align"` (ALL OK).
- Listen's ears (`HostApp/iOS/ListenEars.swift`, which ear hears, the once-per-stop prompt), after any change to it or to `Listener.redecide()`:
  `swiftc -O mobile/HostApp/iOS/ListenEars.swift mobile/ios/Tests/ears/main.swift -o "$TMPDIR/ears" && "$TMPDIR/ears"` (ALL OK).
- The floating window's picture (`HostApp/iOS/FloatingCaption.swift`: whole lines only), after any change to it or to
  ShowsKit's `TranscriptLineText`: `swift run --package-path mobile/ios/Tests/floatingcaption --scratch-path "$TMPDIR/floatingcaption"`
  (ALL OK; outside the sandbox, as SwiftPM sandboxes itself). It renders the app's own file on the Mac (a link in the package).
- The floating window's show/hide rule (`HostApp/iOS/Floating.swift`), after any change to it or to `Listener.floatTick()`:
  `swiftc -O mobile/HostApp/iOS/Floating.swift mobile/ios/Tests/floating/main.swift -o "$TMPDIR/floating" && "$TMPDIR/floating"` (ALL OK).
- Places opened from Library navigate with view links only. After any change to `HostApp/iOS/Listen.swift` or `Browser.swift`:
  `grep -nE '^[^/]*(NavigationLink\(value:|navigationDestination\(for:)' mobile/HostApp/iOS/Listen.swift mobile/HostApp/iOS/Browser.swift`
  prints nothing (a value push opened a second Listen, and Archive's top level instead of the folder, 11-09).
- Listen's start and floating-window layer (fixed 11-10 on the iPhone), after any change to `CaptionLayer`, `StartBroadcast`
  or `Listener.name`: each line prints what it says.
  `grep -c 'guard Host.owner === self' mobile/HostApp/iOS/Listen.swift` prints 1 (Home and Listen took the one layer from
  each other on every layout; iOS's watchdog ended Recense, 0x8BADF00D, when Now Playing opened).
  `grep -nE 'Button *\{ *l\.start\(\)' mobile/HostApp/iOS/*.swift` prints nothing: the Start a person taps is the system
  picker (`StartBroadcast`); iOS ignores the picker tapped from code (probe 11-10).
  `grep -n '"Automatic (' mobile/HostApp/iOS/*.swift` prints nothing (the row wrapped after "English,").
  iPhone Mirroring can't show the broadcast sheet or use the phone's mic: the last step (Start Broadcast, words appear) is checked on the phone in hand.
- Every Swift package under `../shared/` stays out of the app's synchronized folder. After adding one, and before any iOS build:
  `for d in shared/*/Package.swift; do n=$(basename $(dirname $d)); grep -qE "membershipExceptions = \([^)]*\b$n\b" mobile/ios/GalleryFiles.xcodeproj/project.pbxproj || echo "NOT EXCLUDED: $n"; done`
  prints nothing (`shared/pieces` was missed on 11-09; its Package.swift and XCTest tests would have compiled into the app).
- Recense Guest compiles every file in `HostApp/iOS/` with the `GUEST` flag, but links only ShowsKit. A file that imports
  another package (SSHKit, SSHTerminal) puts an empty stub under `#if GUEST` (as `Terminal.swift` does). After any change to
  the packages, `Places.swift` or the pbxproj: `xcodebuild -project mobile/ios/GalleryFiles.xcodeproj -scheme RecenseGuest
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` ends BUILD SUCCEEDED (it failed on CNIOAtomics, 11-10).
- A worktree has no `ios/Secrets/`: link the main checkout's (`ln -s ~/Developer/recense/mobile/ios/Secrets mobile/ios/Secrets`); never stage the link.
- After a Draftpad or shared change, also run `zsh strip/build.sh` and `recense selftest`, and `npm test` in `editor/`.
- New source files: anything in `HostApp/iOS/` or `../shared/` joins the app by itself (Xcode synchronized folders, objectVersion 77; don't put non-app files there). Except the Swift packages, excluded from the synchronized group (exception sets `…E2`, and `…601F` for Recense Guest): `../shared/ShowsKit/` (linked as a local package, `…E3`–`E5`; its files compile only as the package), `../shared/SSHKit/` (local package `…E6`–`EA`: products SSHKit and SSHTerminal) and `../shared/pieces/` (not linked yet; its Package.swift and XCTest tests must never join the app). A new package under `../shared/` goes on that list in the same commit. Files outside them (the extensions, `FileProviderCore/Core.swift`, `editor.html`, assets) are still listed by hand in `ios/GalleryFiles.xcodeproj/project.pbxproj`.

## Never
- Commit `ios/Secrets/` (the device token) or `build/` (`mobile/.gitignore`).
- Put Matters or Raven into a share link, a feed or a guest build.
