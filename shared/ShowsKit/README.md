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
    `Views/ShowPage.swift`, `Views/NowPlaying.swift` (mini-player, Now Playing, `VerdictBar`; the quote button shows the
    transcript in place of the player, with back 15 / play / forward 30 under it), `Views/Cards.swift`.
  - `Views/Transcript.swift`: `TranscriptView`, the transcript as iOS Podcasts shows it (owner's screenshots in
    `~/.claude/context/recense/research/podcasts-ios/`): serif lines on the show's dark colour, the line being heard bold
    with its spoken words bright and the rest dim, the view following the playhead (a "Now" button after scrolling
    away), tap a line to play from it, hold it for Play / Share from <time> / Copy / Select Text (the system's text
    view: Look Up, Translate), the translation under each line, chapter headings inline; every action also in its menu.
    Reduce Motion: it jumps instead of scrolling. `TranscriptLine` / `TranscriptWord` are its data; `TranscriptLight`
    its rules (which line, how much of it is said: by word times, else by time at a whole word, in any language).
    Used by iOS Listen and Now Playing.
    The light redraws every screen frame, at most 60 a second (`TranscriptLight.frame`), as the Mac's display link
    does; at the old 12 a second a word could light up to 83 ms late (the owner's bar is 50 ms against the Mac).
    Each frame reads the playhead for the moment it reaches the screen, one refresh after it's drawn (`FrameClock`,
    the display link's target time; 11-10: lit for "now", every word was a frame late). The Mac's window and the web
    player add the same lead.
    The view turns to the next line ahead of it (`TranscriptLight.following`): the new line is bold, wrapped and still
    before its first word lights, so the eye lands on a resting line. It waits for the outgoing line's last word first
    (`TranscriptLight.turn`), then scrolls in the time left before the next line.
  - `Views/Scrubber.swift`: our scrubber (the home bar's Time Seeking, `library/src/client/homebar.js`) under the
    transcript: slide to move from where it was, slide up for ×4/×16/×64, seeks every 90 ms and lands on release, the
    landed time shown a moment; a tap jumps. It and the lines share one playhead. `ScrubMath` holds its rules.
  - `Feeds.swift`: Up Next, Recently Played, Saved, Downloaded, Latest, Recently Updated, built from the reads every
    store has (no store code needed).
  - `Transport` (in `ShowsModel.swift`): play/pause/skip, and `time` / `duration` / `seek(to:)` for the transcript and
    scrubber (defaults: 0, nil, nothing), given by B3's player; until then play opens Now Playing. `ShowsModel.transcript`
    is the playing episode's transcript, filled by the app's ears.
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
- Test: `swift test` in this folder (36 tests; with Xcode's toolchain: the Command Line Tools have no XCTest).
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
