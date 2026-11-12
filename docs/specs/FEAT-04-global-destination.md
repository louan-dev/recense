# FEAT-04 · One Recense destination for screenshots, downloads and trash

From: T-0034 (owner 2026-11-12, "recense iphone, mac, ipad. add global destination for screenshots,
downloads, trash") · Status: `[~]`
Code: `shared/destinations.swift` (new, this spec), `shared/mediadownload.swift` (reused pattern, the
`downloads` destination already exists), `mobile/HostApp/iOS/Places.swift`, `mobile/HostApp/macOS/Window.swift`

## Goal
One consistent place per device for three kinds of file the OS would otherwise scatter: a screenshot,
a download, and something you deleted. Same folder names on Mac, iPhone and iPad:
`Recense/screenshots/`, `Recense/downloads/`, `Recense/trash/` — the same shape the "places" folder
contract already set out (playbook §3), and the same manifest + sha256 pattern `shared/mediadownload.swift`
already uses for `downloads/` (reused here, not reinvented, per Reuse before new).

## What each OS actually lets an app do (checked in Apple's own docs, not assumed)
Read every claim below as a fact about the platform, not a wish. Where the platform has no public API,
the fix is "sweep up after," not "redirect at the source" — naming that presumption up front rather
than discovering it after building the wrong thing (Spike before building on an untested assumption).

| Kind | Mac | iPhone / iPad |
|---|---|---|
| Screenshots | **Redirectable.** `defaults write com.apple.screencapture location <path>` is a real, long-standing, scriptable system default (`man screencapture`); every ⌘⇧3/4/5 capture lands there from then on. No app-store-review-visible API needed. | **Not redirectable.** No public API lets any app change where `Side button + Volume Up` saves a screenshot — it always goes to Photos. The only on-device move is to **sweep**: observe the Photos library (`PHPhotoLibraryChangeObserver`) for new assets whose `mediaSubtypes` includes `.photoScreenshot`, copy the bytes into `Recense/screenshots/`, and offer to remove the Photos copy afterward (default off; deleting from Photos needs its own confirmation, since it is the owner's photo library, not Recense's). |
| Downloads | **Redirectable, but it's Safari's own setting, not Recense's:** Safari → Settings → General → "File Download Location" → "Other…" → any folder, including `~/Recense/downloads`. Recense cannot flip this System/Safari preference for the owner from inside its own sandbox; it can only hand them the exact menu path (below). | **Partly redirectable, with a real cost.** Settings → Safari → Downloads → "Other…" lists any Files-visible location, **including a third-party File Provider domain** — if that domain accepts writes. Recense's existing File Provider (`mobile/Extension/FileProviderExtension.swift`) is explicitly **read-only** today ("Creates and edits are refused"). Making it a legal Safari download target means implementing `createItem`/`modifyItem` on a NSFileProviderReplicatedExtension — a real, separate, higher-risk piece of work (file-provider writes that go wrong can corrupt what Files shows, or desync the Gallery mirror this same extension already serves read-only). **Not built in this slice; P3 below, needs the owner's go before touching a working extension.** Until then: sweep the Files app's own `Downloads` folder (`.documentDirectory`-adjacent, every app can read it with Files access) the same way as screenshots. |
| Trash | **Not a thing to redirect.** macOS's Trash is Finder's own mechanism; no third-party app can make "everything deleted anywhere on this Mac" land in its own folder instead — that would mean replacing Finder, not an achievable scope. | Same: iOS has no system-wide trash to intercept. |
| Trash, Recense's own | **Fully in Recense's control**, no OS limitation: anything removed *from inside Recense* (Draftpad delete, Library remove, a Gallery "Remove") already goes through Recense's own code, so it already can land in `Recense/trash/` instead of being destroyed outright. This is the one "trash" that is honestly "global" — global to Recense's own actions, not to the OS. | Same. |

## Scope for this slice (P1–P2 below; P3 is a separate go/no-go)
- **P1 · The folder contract + manifest, shared.** `shared/destinations.swift`: `Recense/screenshots/`
  and `Recense/trash/`, each with `manifest.json` (name, source, bytes, sha256, saved, via) and an
  `adopt()` that walks the folder and files anything not yet in the manifest — the exact shape
  `shared/mediadownload.swift` already has for `downloads/`. `downloads/` itself is **not duplicated**:
  `Downloads` (mediadownload.swift) already is this destination; FEAT-04 only adds the other two kinds
  alongside it using the same pattern.
- **P2 · The sweeps.**
  - iOS/iPad: a `PHPhotoLibraryChangeObserver` that adopts new `.photoScreenshot` assets into
    `Recense/screenshots/` (copy, not move, until the owner decides on Photos deletion — see Never
    self-answer in the owner's playbook: deleting the owner's data needs their call, not Recense's).
  - All platforms: `Recense.remove(_:)` (wherever Draftpad/Library today call something destructive)
    routes through `Destinations.trash(_:)` instead of deleting outright.
- **P3 · Not built here, needs the owner's go first:** a writable File Provider domain so iOS's Safari
  "Downloads" setting can point at Recense directly, instead of sweeping Files' own Downloads folder
  after the fact. Flagged, not started — extending a working read-only sync extension to accept writes
  is exactly the kind of change that deserves its own spike and its own spec, not a line item here.

## Invariants
- **D1 · Same three folder names everywhere:** `Recense/screenshots/`, `Recense/downloads/`,
  `Recense/trash/` — Mac via `~`, iOS/iPad via the app's Documents directory (same convention
  `Downloads.root` already uses; `RECENSE_<KIND>_DIR` env override per kind, for tests, mirroring
  `RECENSE_DOWNLOADS`).
- **D2 · Nothing is silently destroyed.** A sweep copies; it never deletes the original without a
  separate, explicit confirmation the owner has already agreed to (Photos deletion default OFF).
- **D3 · One manifest shape.** Every destination's `manifest.json` uses the same `DestinationEntry`
  record (name, source, bytes, sha256, saved, via) so one `adopt()` implementation serves all three
  kinds, and any device can verify it holds the same bytes as any other (the same cross-device
  guarantee `downloads/manifest.json` already gives).
- **D4 · No OS setting changes itself.** Recense never runs `defaults write` or opens Safari's
  settings pane on the owner's behalf. It gives the exact command or the exact menu path and waits.

## Red test first (`/derive`)
- File: `shared/test/destinations/main.swift` (the `mobile/ios/Tests/floating/main.swift` style:
  `swiftc -O shared/destinations.swift shared/test/destinations/main.swift -o out && ./out`, `FAIL`
  lines, no XCTest needed).
- Cases: `adopt()` on an empty folder finds nothing; a file dropped into `screenshots/` with no
  manifest entry is adopted with the right sha256; a file already in the manifest is not re-added or
  re-hashed; `trash(_:)` moves a file's bytes into `Recense/trash/` and leaves a manifest entry with
  `via: "trash"`; two destinations never share one root (`screenshots/` and `trash/` resolve to
  different paths for the same kind).

## Ready for the owner, not run here
- Mac screenshot location, to be redirected right now if wanted:
  ```zsh
  defaults write com.apple.screencapture location ~/Recense/screenshots
  killall SystemUIServer
  ```
  This changes where every ⌘⇧3/4/5 capture on this Mac lands, system-wide, until undone with
  `defaults delete com.apple.screencapture location`.
- Mac Safari downloads, menu path (no command exists for this one — it's a GUI-only preference):
  **Safari → Settings (⌘,) → General → "File download location" → Other… → choose `~/Recense/downloads`.**
- iPad/iPhone Safari downloads, until P3 ships a writable File Provider: **Settings → Safari →
  Downloads → Other… → choose any Files location you already use** (Recense's own folder isn't a
  legal choice yet — see P3). The P2 sweep still picks up what lands in Files' own Downloads folder.

## Device check
- Mac: run the `defaults write` command above, take a screenshot, confirm it lands in
  `~/Recense/screenshots` with a manifest entry.
- iPhone and iPad: take a screenshot, confirm the Photos-observer sweep adopts it into
  `Recense/screenshots/` within the app without removing it from Photos (default behaviour).
- All three: delete something from inside Draftpad or the Library, confirm it lands in
  `Recense/trash/`, not gone.
