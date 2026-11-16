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
- Carry's rules (`shared/carrysync.swift`: scan diff → ops, settling, the seen vector), after any change to it or to
  `shared/notesync.swift`: `swiftc -O shared/notesync.swift shared/carrysync.swift mobile/ios/Tests/carrysync/main.swift -o "$TMPDIR/carrysync" && "$TMPDIR/carrysync"` (ALL OK).
- Automatic carry starts at launch (T-0084, iPad 11-15: a cold launch is already `.active`, so a plain `onChange` never fired):
  `grep -c 'onChange(of: phase, initial: true)' mobile/HostApp/iOS/App.swift` prints 1.
- Carry's received files (BUG-19), after any change to `shared/p2ptransport.swift` or `CarryManager.landed`:
  `grep -n 'moveItem(at: localURL' shared/p2ptransport.swift` prints one line (moved before the callback returns) and
  `grep -n 'lastPathComponent' shared/carrymanager.swift` prints nothing (the key rides the resource name).
- Carry's pairing (`shared/carrypair.swift`: the six-digit code, group sealing, invitation proof), after any change to it:
  `swiftc -O shared/carrypair.swift mobile/ios/Tests/carrypair/main.swift -o "$TMPDIR/carrypair" && "$TMPDIR/carrypair"` (ALL OK).
- Carry's settling against real homes (`shared/carryapply.swift`: fetch, replace, keep-both, move — the only place
  that writes to disk for a settled change), after any change to it or to `shared/homes.swift`: it needs ShowsKit
  linked, so it runs inside `strip/recense selftest` (`carrymanagerSelftest`, ALL OK there), not a standalone swiftc test.
  A fetched file never deletes what is already at its key (T-0109): the "fetch over a file that appeared meanwhile" case in
  that selftest prints three ok lines, and `grep -n 'removeItem(at: dest)' shared/carryapply.swift` prints nothing.
  (`ink ocr` fails in that selftest on the installed app too: T-0071/T-0079, not this.)
  Carry never hashes the homes on the main thread (T-0107): `grep -n 'Carry.verify()' shared/carrymanager.swift` prints nothing
  (every scan is `Carry.verify(reuse: true)` inside `Task.detached`); no test reaches `receiveOps`, so check the iPhone's
  responsiveness (no freeze, no 0x8BADF00D) while a large library settles.
- The Lock Screen player (`HostApp/iOS/NowPlayingInfo.swift`, BUG-09), after any change to it or to `NativePlayer`'s publish/remote:
  `swiftc -O mobile/HostApp/iOS/NowPlayingInfo.swift mobile/ios/Tests/nowplaying/main.swift -o "$TMPDIR/nowplaying" && "$TMPDIR/nowplaying"` (ALL OK).
- A video's sound on the Lock Screen (`HostApp/iOS/BackgroundVideo.swift`, FEAT-19 P2), after any change to it or to `VideoLayer`:
  `swiftc -O mobile/HostApp/iOS/BackgroundVideo.swift mobile/ios/Tests/backgroundvideo/main.swift -o "$TMPDIR/bgvideo" && "$TMPDIR/bgvideo"` (ALL OK).
- The editor's embedded recordings are served in byte ranges (`shared/embedfiles.swift` ByteRange, FEAT-19 P4), after any change to it:
  `{ echo 'import Foundation'; sed -n '/^enum ByteRange/,$p' shared/embedfiles.swift; } > "$TMPDIR/byterange.swift" && swiftc -O "$TMPDIR/byterange.swift" mobile/ios/Tests/byterange/main.swift -o "$TMPDIR/byterange" && "$TMPDIR/byterange"` (ALL OK).
- Translate Into's plan (`shared/translateplan.swift`, FEAT-10), after any change to it:
  `swiftc -O shared/translateplan.swift mobile/ios/Tests/translateplan/main.swift -o "$TMPDIR/translateplan" && "$TMPDIR/translateplan"` (ALL OK).
- A played file's language (`shared/speechcore.swift` SpeechAhead, BUG-11), after any change to SpeechAhead or to
  `SpeechCore.sureness`/`pick`: `zsh mobile/ios/Tests/aheadlang/run.zsh` (outside the sandbox; French, Vietnamese and
  English recordings each print ALL OK, heard in their own language).
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
- Heard text is never lost or crossed (T-0102, T-0097, T-0100), after any change to `Listener.save()`, `PlaybackEars.hear`,
  `SpeechAhead.loop` or `PlaybackTranslator.run`: each line prints what it says.
  `grep -n 'dirty = false' mobile/HostApp/iOS/Listen.swift` shows it after the `.write(` guard in `save()` (a failed write stays dirty).
  `grep -c 'T-0097' shared/speechcore.swift` prints 1 (the guard after `SpeechEngine.hear(url:`) and
  `grep -c 'guard self?.key == e.id' mobile/HostApp/iOS/Ears.swift` prints 1 (a stopped hearing writes nothing into the next episode).
  `grep -n 'let gen = inFlight + 1' mobile/HostApp/iOS/Translate.swift` shows it above `apply(p.fills` (every run is a new generation).
  A hearing that fails is said and retried, and never downloads at the moment of use (T-0098, T-0099):
  `grep -n 'prepare(m, l, download: false)' shared/speechcore.swift` prints the line in `SpeechAhead.loop`,
  `grep -c 'fail(' shared/speechcore.swift` prints 5 or more and `grep -c 'a.failed = ' mobile/HostApp/iOS/Ears.swift` prints 1.
- Draftpad's note is never overwritten by what it could not read or write (T-0114), after any change to `DraftpadFile.load/save`
  or to `readNote`/`planBlindSave` in `shared/notesync.swift`: run it outside the sandbox (NSFileCoordinator needs it):
  `swiftc -O shared/notesync.swift mobile/ios/Tests/notesave/main.swift -o "$TMPDIR/notesave" && "$TMPDIR/notesave"` (ALL OK), and
  `grep -c 'guard coordinatedWrite\|!coordinatedWrite' mobile/HostApp/iOS/Draftpad.swift` prints 3 (a failed write never moves the base),
  `grep -c 'draftpad-unsaved.md' mobile/HostApp/iOS/Draftpad.swift shared/notesync.swift` prints 0 for both (typed text is kept one file
  per launch, `Unsaved.file`, never one fixed file) and `grep -c 'conflictSiblingPath' mobile/HostApp/iOS/Draftpad.swift` prints 0
  (a conflict copy uses `freeSiblingPath`, so it never replaces one made in the same minute),
  `grep -n 'coordinatedRead(p) ?? ""' mobile/HostApp/iOS/Draftpad.swift` prints only `loadInk` (the note's own load never reads blank;
  the ink sidecar still does: filed as its own triage entry).
  The Mac's own copy of this rule (`strip/app.swift` saveNow/load) is a gap until wired: `docs/specs/PARITY.md`.
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
