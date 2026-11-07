# ShowsKit

The Podcasts-style skin's shared core, used by Recense Mac (`strip/`) and Recense mobile (`mobile/`).
Plan: `~/.claude/plans/starry-squishing-knuth.md` (B0.5 is this contract).

## What is in it
- `Sources/ShowsKit/Model.swift`: the types and their JSON.
  - `ContentKey`: a file's key by its content (the same as the Mac's and the Worker's).
  - `HLC`, `HLCClock`, `Stamped`: hybrid logical clock stamps; the newest stamp wins, the same on every device.
  - `PoolItem`, `ItemState`, `ListenPosition`: the device pool, the listener's marks, where each device stopped.
  - `Space`, `Show`, `Season`, `Episode`, `ShowManifest` (`.show.json`).
  - `CatalogEvent`, `ChangesPage`: the Worker's changes feed (`library/src/fp.js`).
  - `OutboxOp`: a change waiting to be sent, with an `opId` that applies once.
- `Sources/ShowsKit/Rules.swift`: folder → space/show/season, locks, New's expiry, filter bars, episode order.
- `Sources/ShowsKit/Store.swift`: the `CatalogStore` protocols, and `MemoryCatalog`, the in-memory reference store.
- The skin (B2), SwiftUI for the Mac and iOS alike:
  - `ShowsModel.swift`: what the views read and do over any `CatalogStore`; every mark (Star, Played, Clicked / Not yet)
    is a stamped `.state` change through the outbox, so it works offline.
  - `Lock.swift`: `Gate`, Face ID / Touch ID for Matters and Raven. Biometrics only (no passcode fallback, owner 11-06);
    it shuts whenever the app leaves the screen.
  - The layout follows Podcasts on iOS 26 (owner's screenshots, 11-07). `Views/Root.swift`: `ShowsRoot`, tabs Home · New ·
    Library · Search (a sidebar on iPad and Mac, macOS 15+), the mini-player in the tab bar's accessory slot on iOS 26
    (floating above the tab bar before), the profile circle, the gate's `LockedView`.
  - `Views/Home.swift` (Up Next cards, Recently Played rows, `EntryList`), `Views/New.swift` (what landed in New as
    featured cards, a rail of shows per space), `Views/Library.swift` (rows: Shows, Study, Folio, Matters, Saved,
    Downloaded, Latest Episodes, then the app's places; Recently Updated), `Views/Search.swift` (field + filter bars),
    `Views/ShowPage.swift`, `Views/NowPlaying.swift` (mini-player, Now Playing, `VerdictBar`), `Views/Cards.swift`.
  - `Feeds.swift`: Up Next, Recently Played, Saved, Downloaded, Latest, Recently Updated, built from the reads every
    store has (no store code needed).
  - `Transport` (in `ShowsModel.swift`): play/pause/skip, given by B3's player; until then play opens Now Playing.
  - `Views/Theme.swift`: the look every screen shares, in ShowsKit and in each app's own places: `Theme` (accent,
    gutter, corners, readable width, `hues`), `Artwork`, `SectionHeader`, `LibraryRow`, `Place` (a screen the app adds
    to Library) and `.recenseScreen(title)`.
  - `Sample.swift`: `MemoryCatalog.sample(device:)`, a made-up pool for previews and tests.
- `ItemState.verdict` (B2): Clicked / Not yet, one stamped record per episode (the retelling loop's measurement).

## The pool layout
```
Recense/inbox/…                          → the show "New", top of Library
Recense/library/<show>/[<season>/]<file> → Library
Recense/library/Study|Folio/<show>/…     → Study, Folio
Recense/library/Matters|Raven/<client>/… → Matters (locked: Face ID / Touch ID; never shared)
Recense/keep/…                           → transcripts, notes, keep/listen/<device>/<key>.json
Recense/.trash/…                         → deletes, kept 30 days
```

## Build and test
- Test: `swift test` in this folder (27 tests).
- Mac: `strip/Package.swift` depends on it by path; `zsh strip/build.sh` builds it in.
- iOS: a local package of `mobile/ios/GalleryFiles.xcodeproj`. This folder is excluded from the project's
  synchronized `shared/` group, so its files compile only as the package.
- Using it: `import ShowsKit`. Both apps already have their own `Episode`; write `ShowsKit.Episode` where both are seen.

## Rules for changing it
- `Model.swift`, `Rules.swift` and `Store.swift` are the contract: changes go through the coordinator.
- A new store (B1) goes in its own file here and must pass `CatalogContract.run` in the tests.
- No SwiftUI macros (`@State`, `@Entry`, `#Preview`): the Mac builds this package with the Command Line Tools
  (`strip/build.sh`), which lack SwiftUI's macro plugin. Use `@StateObject`, `@Observable`, `@Bindable`.
  `testNoSwiftUIMacros` guards it.
