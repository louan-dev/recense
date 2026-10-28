# Gallery · native sync architecture (File Provider)

Written 2026-10-28 from the owner's brief ("Change of priority", 2026-10-28 ~07:00). Changes only when a decision does.
Status labels: SETTLED (decided here), WALL (an Apple/Cloudflare limit, measured or read in the SDK), OPEN (owner's call).
The engine invariants in `sync/docs/specs/gallery-nervous-system.md` still hold; this file is how the File Provider
plugs into them. Prosogram work is parked until this is solid. Recense is not started.

## 1 · The end product
One folder, **Gallery**, in Finder (macOS) and in Files (iOS/iPadOS), that mirrors what is on R2:

| Inside the folder | Backed by | Today, through |
|---|---|---|
| `Chauphan/` (what moved out of `/Users/chauphan`) | `gallery-archive/chauphan/` | `/main/nc-archive/` (always-on NFS mount, `~/Cloud/Chauphan`) |
| `Main/`, `Public/` (what the NFS Gallery mount shows) | `gallery-main/files/`, `gallery-public/folders/` | `/main/nc/`, Gallery.app (Touch ID) |
| `tmp/` (every device's downloads, 14 days) | `gallery-tmp` | `/main/nc-tmp/`, `com.chauphan.downloads-to-r2` |

Files you open or mark **Keep** stay on the device. Everything else is a placeholder (name, size, date, icon) that
downloads on demand. It works offline: browsing always works, kept files open, and edits queue until a connection
comes back. The NFS mounts stay as they are until the File Provider has replaced them on the Mac (§9).

## 2 · Pieces (SETTLED)
```
 iPhone / iPad / Mac                         Cloudflare (all mine, nothing 24/7 on my side)
 ┌───────────────────────────────┐   HTTPS   ┌──────────────────────────────────────────┐
 │ Host app (tiny: sign-in,      │  Access   │ Worker = reverse proxy + the engine       │
 │  Keep list, status)           │  service  │  /main/api/fp/<root>/items    enumerate   │
 │ File Provider extension       │──token───▶│  /main/api/fp/<root>/changes  change feed │
 │  NSFileProviderReplicated-    │           │  /main/api/fp/<root>/content  bytes+Range │
 │  Extension (one Swift module, │           │  writes: PUT/MOVE/DELETE with base etag   │
 │  both OSes)                   │           │  reconciler: lists R2, diffs, logs events │
 └───────────────────────────────┘           │ R2: the objects + <root>/.catalog/ (log)  │
                                             └──────────────────────────────────────────┘
```
- **Backend = Worker + R2 + scripts.** No Nextcloud, no third-party service, no D1 for this (the other session owns
  D1). The catalog lives in R2 next to the files it describes.
- **One extension codebase.** `FileProviderCore` (Swift: API client, local item store, conflict naming) is shared.
  The extension target and a ~200-line host app wrap it per OS (§6).

## 3 · How the extension learns what changed (SETTLED)
R2 has no change feed, so the Worker keeps one.

**Ids that survive renames.** Every item has an id the File Provider uses as its `NSFileProviderItemIdentifier`:
- a file's id is `customMetadata.fid` when the object has one. Otherwise it's `h` + the first 24 hex of
  sha-256(path). That covers everything rclone wrote directly, which has no metadata.
- a folder's id is `d` + sha-256(path). When folder moves are built (§5), the Worker writes the old id into the
  moved folder's marker metadata (`fid`) and the id follows the folder, as it does for files.
- **A rename or move through the Worker copies the id across** (`fid` = the source's id, legacy or not). So a rename
  is one `move` event, nothing downloads again, and the File Provider keeps the same item. A rename made outside the
  Worker (rclone straight to the bucket) shows up as a delete plus a create. That's correct but costs a download.

**The change log.** It lives in `<bucket>/.catalog/<root>/`. Mount guards and listings hide it: dot folders at a
bucket root are never reachable through a mount.
- `log/<seq:12 digits>.json`: one batch of events `{seq, at, events:[{op: create|modify|delete|move, id, path,
  from?, dir, size, etag, mtime}]}`. Appends are R2 create-only puts (`onlyIf: etagDoesNotMatch "*"`) on the next
  seq. Two writers racing for the same seq: one wins, the other retries on seq+1. That gives a total order with no
  Durable Object.
- `snapshot.json`: the last full listing (id, path, etag, size, mtime) and the seq it matches. About 120 bytes per
  item, so roughly 350 KB for today's 2,859 archive objects and roughly 3.6 MB for Main.
- **Two sources feed the log.** (a) Every write the Worker serves appends its event at once (slice 3). (b) The
  **reconciler** lists the root, diffs it against `snapshot.json` and appends what changed. That catches everything
  written around the Worker: the owner's `rclone move`s, the Mac's Downloads agent, the R2 dashboard. It runs when a
  client asks for changes and the last pass is older than 60 s (one pass at a time, guarded by a create-only lock
  object), and nightly from the 03:00 cron. Above 1,000 list pages a pass becomes resumable and keeps its own cursor
  (Cloudflare caps one request at about 1,000 storage operations; WALL).
- **The anchor is the seq.** `changes?since=<seq>` returns the events after it plus the new seq. A seq older than the
  oldest log entry kept (compaction keeps 30 days) returns `410`. The extension maps that to
  `NSFileProviderError.syncAnchorExpired`, and the system re-enumerates. That's the native recovery path.

**Who asks, and when.** Without a paid account there is no push (WALL: File Provider push needs APNs). So:
- **macOS.** The host app runs as a login item and polls `changes` every 60 s while online. When something changed it
  calls `signalEnumerator(for: .workingSet)`.
- **iOS.** The system calls `enumerateChanges` on the working set while Files is open and when a folder is browsed,
  and the host app signals on launch and from `BGAppRefreshTask` (iOS decides how often). Changes made elsewhere
  show up when Files is opened. They won't arrive instantly in the background. Stated, not hidden.
- **Upgrade path.** With a paid account the Worker would send a File Provider push on each log append. Same anchors,
  no polling.

## 4 · When two devices edit the same file (SETTLED)
- Every write carries the version it was based on (`If-Match: <etag>` from the item the device last saw). The Worker
  already refuses a stale base with **412**, on Main and on the archive (live-tested).
- **On 412 the device keeps both.** Its version is uploaded as a new item named
  `name (conflict, <device>, <YYYY-MM-DD HHmm>).ext` next to the original. The extension reports the server's
  version for the original id, and the user sees both. Never a silent overwrite, never last-writer-wins.
- An overwrite that does win sends the previous bytes to the root's trash (`.trash/<day>/<path>@<time>`), so every
  version stays restorable.
- Two people at once (owner plus an invitee) go through the same rule. Invitees use `/m/<token>` on the web. Native
  access for other people's devices needs a paid account (§7).

## 5 · Deletes and renames, and the "nothing leaves my Mac without my yes" rule (SETTLED)
- **A delete on a device** becomes a server move to the root's trash, plus a `delete` event. Other devices see the
  item disappear and can restore it from `/main` (trash view) for 30 days. **tmp deletes for good**, by design.
- **Evicting is not deleting.** "Remove Download" frees the local copy only, and R2 is untouched.
- **Delete guard.** A batch from one device that would delete more than 10% of a root or more than 100 items in 10
  minutes is held: the Worker answers 409 `needs-confirmation`, and nothing goes until the owner confirms in `/main`.
  The extension shows the items as "waiting for confirmation" (spec invariant 5).
- **Renames and moves** are one `move` event with the same id (§3). Folder moves in the Worker are refused today (403).
  Building them is spec step 6: a resumable server-side job, one event per item.
- **Local originals in `/Users/chauphan` are never touched by the File Provider.** The domain only contains R2. Moving
  a folder into it stays the agreed manual flow: copy, hash-verify every file (`rclone check` / re-download MD5),
  restore test, then the **owner's yes**, then the owner runs the `rm` in Terminal.app. That's the Voice Memos and
  Record It procedure, unchanged.

## 6 · One codebase for iOS and macOS (SETTLED, with the WALLs found in the iOS 18.5 / macOS 15.5 SDK headers)
- Both OSes use `NSFileProviderReplicatedExtension` (macOS 11+, iOS 16+). The system owns the on-disk replica,
  placeholders, offline browsing and the upload queue. The extension only answers item, enumerate,
  fetchContents, create, modify and delete.
- **Shared:** `FileProviderCore` (API client over URLSession with the Access service token from the shared Keychain
  group, the id and conflict rules, the local item store in the App Group container). Built for both SDKs from the
  same sources.
- **Per OS (small `#if os(macOS)` blocks):**
  - **Keep (pin).** On macOS the item reports `contentPolicy = .downloadEagerlyAndKeepDownloaded`. **WALL: on iOS
    that policy and `requestDownloadForItem` are `API_UNAVAILABLE(ios)`**, and only `.inherited` /
    `.downloadLazilyAndEvictOnRemoteUpdate` exist. iOS's way: the host app downloads each kept file into a **keep
    store** in the App Group container, and the extension's `fetchContents` serves from that store first. So a kept
    file opens offline even after iOS has evicted the Files copy. The cost is up to 2× space for kept files while
    both copies exist (an APFS clone may avoid it: verify on device).
  - **Domains.** On macOS one domain per root. The app can `disconnect` the Main domain on screen lock (Gallery.app's
    wipe-on-lock posture) while Chauphan stays connected (Decided 3). On iOS one domain holding all roots, and Main's
    Face ID gate is an OPEN question (§8).
  - **Host app:** AppKit menu-bar item on macOS, SwiftUI single screen on iOS. Both only do sign-in, the Keep list
    and status.
- Folder layout: `gallery/apple/FileProviderCore/`, `gallery/apple/Extension/`, `gallery/apple/HostApp/`. The
  project is built with `xcodebuild` from a hand-kept project. **XcodeGen only on the owner's yes.**

## 7 · Apple account and signing (WALLs; one test pending)
What's on this Mac now: Xcode 16.4, iOS 18.5 / macOS 15.5 SDKs, **no iOS Simulator runtime** (about 8 GB). One
"Apple Development" certificate, team "Kelly Phan (Personal Team)" (free), and no provisioning profiles yet.

| Needs | Free Personal Team | Paid ($99/yr) |
|---|---|---|
| Build and run on your own iPhone/iPad | yes, **re-sign every 7 days**, at most 3 apps per device | yes, 1-year profiles |
| App + File Provider extension | expected yes. **Test (a) decides** (App Groups capability may be refused) | yes |
| macOS app + extension | yes. A team-prefixed App Group (`<TEAMID>.gallery`) needs no profile. **Test (b)** | yes |
| Push to wake the extension (§3) | **no** (APNs) | yes |
| Other people's devices (TestFlight / ad hoc) | **no** | yes |

Test (a): the throwaway iOS app plus extension with App Groups on the Personal Team. It needs the **iPhone plugged
in with Developer Mode on**, because a free team can only provision a device it can see. If it's refused, the
nearest build is the spec's fallback: a small iOS app that mirrors kept folders into its own Documents, visible in
Files under "On My iPhone".

## 8 · OPEN (owner)
1. Main on iOS: show it behind Face ID in the host app (disconnect the domain when the app locks it), or leave Main out
   of the iOS domain at first.
2. Paid account: only needed for push, for other people's devices, and to drop the 7-day re-sign. Not needed for
   slices 1–4 on your own devices.
3. The "A decision" to keep in `architecture.md`. `sill/docs/architecture.md` has no item called A. Name it and it
   goes into the right file.

## 9 · Order of work
| Slice | What | Proof |
|---|---|---|
| **1** | Backend, read-only, `gallery-archive`: ids, reconciler, `items`, `changes`, `content` with Range. Miniflare tests. | `test/fp.test.mjs`; live `changes` against the archive (after a deploy yes) |
| **1b** | iOS read-only: host app plus extension, root `Chauphan/Voice Memos/` first. Signing test (a) comes first. | Voice Memos visible in Files on the iPhone, one opens and plays, airplane mode still lists |
| 2 | Offline Keep: macOS content policy, iOS keep store | a kept memo plays in airplane mode after an eviction |
| 3 | Uploads and edits: create, modify (If-Match, 412 → conflict copy), delete to trash, delete guard, rename via `fid` | two-device conflict test; trash restore |
| 4 | Shared `tmp/`: the tmp root in the domain, plus iOS Safari's download location set to it | a Safari download on the iPhone shows on the Mac, gone after 14 days |
| 5 | Main and Public roots; replace the NFS mounts on the Mac | Finder parity with `~/Cloud` |

The `/main/archive` web shelf reads the same bucket and must keep working. It isn't built yet (Phase 2 was paused
at the mount, commit ec9ce9e), and nothing here changes how objects are stored, so building it later stays
compatible.
