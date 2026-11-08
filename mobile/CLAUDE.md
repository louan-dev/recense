# CLAUDE.md · Recense mobile (`mobile/`): Recense for iPhone and iPad

Also read the root guide `../.claude/CLAUDE.md` (its rules apply here). Plan: `docs/PROGRESS.md` §2 Rules, then only the
section for the task. Architecture: `~/.claude/plans/starry-squishing-knuth.md` (copied to `docs/` in B0).

## Mirror rule (owner, 2026-11-06)
- Recense mobile mirrors Recense Mac (`../strip/`). A change to a shared surface ships to both in the same change:
  - **Draftpad:** `../editor/` (bundled `editor/dist/editor.html`), `HostApp/iOS/Draftpad.swift` here, `strip/editorhost.swift` on the Mac, sync in `../shared/notesync.swift`.
  - **The player:** one home, `../library/src/client/`; Mac, mobile and web all use it. Test all three.
  - **The skin** (Podcasts-style spaces, shows, episodes) and the **strip controls** that carry over: Swift goes in `../shared/`, never copied into one app.
- Mac-only (stay in `strip/`): menu-bar hider, brightness, CoreAudio volume, vault, terminal. iOS-only: the broadcast extension, Pencil.

## Build and check
- `zsh mobile/ios/build.sh [device]`: builds and installs on a connected iPhone or iPad (free team, 7-day profile; `sync/bin/resign-ios.zsh` renews daily).
- The unsigned compile (`CODE_SIGNING_ALLOWED=NO`) is a check, not a delivery. After any merge that touches the iOS app,
  run `zsh mobile/ios/build.sh <UDID>` for the iPad (`00008122-0009799A026B801C`) and the iPhone (`00008101-001A50643A98001E`).
  It needs CoreDevice and the Keychain: in a sandboxed session run it outside the sandbox, or the owner is left on an old build.
  Install fails with "device disconnected immediately": the Wi-Fi tunnel dropped; check `xcrun devicectl device info details --device <UDID>` shows connected, then reinstall the same `.app`.
- One iOS build at a time across sessions (`.handoff/MERGE-QUEUE`).
- After a Draftpad or shared change, also run `zsh strip/build.sh` and `recense selftest`, and `npm test` in `editor/`.
- New source files: anything in `HostApp/iOS/` or `../shared/` joins the app by itself (Xcode synchronized folders, objectVersion 77; don't put non-app files there). Except `../shared/ShowsKit/`: a Swift package, excluded from the synchronized group (exception set `…E2`) and linked as a local package (`…E3`–`E5`); its files compile only as the package. Files outside them (the extensions, `FileProviderCore/Core.swift`, `editor.html`, assets) are still listed by hand in `ios/GalleryFiles.xcodeproj/project.pbxproj`.

## Never
- Commit `ios/Secrets/` (the device token) or `build/` (`mobile/.gitignore`).
- Put Matters or Raven into a share link, a feed or a guest build.
