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
- Test: `swift test` in this folder (16 tests).
- Mac: `strip/Package.swift` depends on it by path; `zsh strip/build.sh` builds it in.
- iOS: a local package of `mobile/ios/GalleryFiles.xcodeproj`. This folder is excluded from the project's
  synchronized `shared/` group, so its files compile only as the package.
- Using it: `import ShowsKit`. Both apps already have their own `Episode`; write `ShowsKit.Episode` where both are seen.

## Rules for changing it
- `Model.swift`, `Rules.swift` and `Store.swift` are the contract: changes go through the coordinator.
- A new store (B1) goes in its own file here and must pass `CatalogContract.run` in the tests.
