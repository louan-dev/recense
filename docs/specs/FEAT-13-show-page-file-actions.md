# FEAT-13 · Show page file actions: "+" adds, ··· moves and removes, rows show a thumbnail

From: owner 2026-11-10 loop (folders are shows; ··· menus; + uploads into the folder) · UI-02 · Status: `[~]` built, device check owed

A show is a folder, so its page can change the folder:
add a file to it, move an episode out of it, or remove one.
Every action runs on the device, offline, through the one folder contract (FEAT-06).

## Decided (PLAYBOOK §5, 2026-11-14 19:13; coordinator unreachable)
- ShowsKit cannot call `shared/homes.swift`: Homes is compiled into each app, not into the package.
  The app passes a `FileActions` value into `ShowsRoot`, as it already passes `places` and `player`.
- Remove goes to the visible `trash/` (FEAT-06; PLAYBOOK §3 line 166), never a hidden `.trash`.
  The `Change.delete` note in `Model.swift` is corrected to say so.
- Share is FEAT-03 (one Share for every device). This spec adds no Share entry.

## Behaviour
- **"+" on a show page:** the system file picker opens.
  Each chosen file moves into that show's folder (`Homes.add`, `subfolder:` = the show's path).
  It never overwrites: a clash becomes "name 2.ext", as in Finder.
  The new episode appears at the top of the list without a reload.
- **··· → Move to…:** a list of the other shows (folders) in the same space.
  Picking one moves the file there; the episode leaves this list and appears in the other.
- **··· → Remove:** moves the file to `trash/`, recording where it came from.
  The row leaves the list. Undo appears for 5 seconds; Put Back in Trash works any time later.
- **Row thumbnail:** the first frame of a video, the first page of a PDF, the image itself.
  Audio keeps the show's art. Made on the device (QuickLookThumbnailing) and cached by content key.
- Each action is one visible control (button or menu entry) and also reachable by VoiceOver.
- A failed action names the file and the reason in the existing "Couldn't do that" alert.

## Interfaces
- `public protocol FileActions: Sendable` in ShowsKit:
  `add(_ files: [URL], to show: Show) async throws -> [PoolItem]`,
  `move(_ e: Episode, to show: Show) async throws`,
  `remove(_ e: Episode) async throws`,
  `thumbnail(for e: Episode, side: CGFloat) async -> CGImage?`.
- `ShowsRoot(model:places:files:player:)`; `files` defaults to a no-op value,
  so the controls hide where no app provides one (previews, the sample catalog).
- Mac and iOS each provide one adapter over `Homes`; no second file mover.

## Outside services
None. Every action is local. Sync carries the result later (carry, FEAT-06), and never blocks it.

## Done checks
1. ShowsKit tests: one per action through a fake `FileActions`
   (add shows the new episode first; move removes it here and adds it there;
   remove drops the row and Undo restores it; no controls without `FileActions`).
2. `homes` selftest: add into a subfolder never overwrites; remove records its origin.
3. Compiles: ShowsKit `swift test`; Mac release build plus `recense selftest`;
   iOS `xcodebuild … generic/platform=iOS`.
4. Device: on the iPhone via iPhone Mirroring, add a file with "+", move it, remove it, put it back.
   Screenshot audit per the UI rule.

## As built (2026-11-16, rebased onto FEAT-07), where it differs from the plan above
- FEAT-07 (main, 2026-11-15) had already added Rename… and Delete to the ··· menu through `EpisodeFiles`, implemented once
  in `shared/homefiles.swift` for the Mac and iOS. FEAT-13 joins that design instead of adding a second one:
  - `ShowFolderFiles` (`FileActions.swift`): `canAdd`, `add`, `move`, `thumbnail`; `HomeFiles` implements it.
    The model reads it from the same `files` property, so a host without it hides "+" and Move to….
  - **Remove is dropped:** FEAT-07's Delete already moves the file to `trash/` with its origin (one function, one control).
    Its 5-second Undo is not carried over; Put Back from Trash still works.
  - Only the homes take files: a show folder outside them (`library/<name>/`) gets no "+" and no Move to…, as FEAT-07's
    Rename and Delete already do.
- Moves keep the file's SHA-256 and change its path, so Carry (FEAT-09) replays them on paired devices.
- A file the picker hands over from another app's provider (iCloud Drive, a server) that can't be moved arrives as a copy.
- Thumbnails come from QuickLookThumbnailing, which keeps its own cache.
- The swipe action that unsaves says "Unsave", so no two controls share the word "Remove".
