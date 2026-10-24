# Shared-links row and mobile read/write · PROPOSED · 2026-10-24

Two owner questions, answered from the code and the Mac as they are today. Nothing here is built
except where marked. Design rules applied: `sill/export/03_DESIGN_PHILOSOPHY.md` (§1 quiet by default,
§2 fewer steps not fewer features, §5 context over dashboards, §7 backend before polish, §8 don't
overbuild) and `gallery/src/page/ui/README.md`.

## 1. A "Shared" row for the links you've made

### What exists
| Kind | Made from | Stored | Ends | Delete now |
|---|---|---|---|---|
| Share link `/s/<id>` | Main › Select › … › Create Share Link | PUBLIC `links/<id>/.manifest` + copied files, each with `customMetadata.expires` | cron `0 3 * * *` → `cleanup()` deletes every object past `expires` | `DELETE /main/api/link?id=` (manifest + files, at once) |
| Room / invite `/m/<token>` | viewer Share, Main › Invite | MAIN `invites/<sha256>.json` (token never stored) | `expires` checked on every request; `0` = never | `DELETE /main/api/invites/<id>` |

Both deletes already exist and are owner-only (Access + `isOwner`). What's missing is one place that
lists every live link. Today the only list is the Invite sheet, and it covers only rooms, one folder
at a time. Accidental duplicates come from the viewer's Share and Create Share Link each making a new
link per tap.

### Proposal
- **Where:** the root of Main, under the folders, as the README's own `main/row.jpg` (§4.3): a `Shared`
  header and one horizontal row of 118 pt cards. It's there only when at least one link is live, and it
  never shows on `/s/` or `/m/` pages (recipients never get it, because it's rendered only for `/main`,
  behind Access). One row, not a dashboard (§5).
- **Card:** the first item's cover, its name (`+3` when there are more), and a quiet second line with the
  time left (`6 d`, `Never`). A link with the same items, language and notation as another shows `×2` on
  the card instead of a second card, so duplicates are visible at a glance.
- **Delete, discreetly:** a long-press (touch) or right-click / two-finger click (trackpad) opens the
  README §5.2 menu sheet for that card: `Copy Link`, `Delete Link` (blue, per the owner's rule), and
  `Delete Duplicates` when `×N`. There are no standing ✕ badges. A delete takes the card out at once
  with a 4 s `Undo` toast, and the request goes out when the toast ends, so an undo never has to restore
  R2 objects.
- **Backend:** one new owner route, `GET /main/api/shares`. It merges `links/*/.manifest` (PUBLIC, list
  with `include: customMetadata`, skip expired) and `invites/*.json` (MAIN) into
  `{ kind, id, url?, items, cover, created, expires, view, dupOf }`. `url` is known only for `/s/`
  (an `/m/` token is unrecoverable by design, so its card offers Revoke but not Copy). It's fetched
  lazily when the root grid renders, and the list is cached in the page for the visit. Deletes reuse
  the two existing routes.
- **Fit with 03:00:** nothing changes there. The cron stays the backstop for expiry; the row is just
  "expire now" by hand. A manual delete removes the same objects the cron would, so nothing is left
  half-gone.
- **Size:** about 120 lines of client code and one ~60-line route plus tests (list, dedupe key, owner-only,
  expired hidden, delete both kinds). No D1 needed (C1 can later replace the list scan).

**Owner to decide:** go / no-go; whether rooms (`/m/`) belong in the same row or only `/s/` links.

## 2. Mobile read/write for Main and Public without the Mac

### What exists (inspected 2026-10-24)
- `~/Gallery` is **not local storage**. It's `rclone nfsmount gallery: ~/Gallery` started by
  `/Applications/Gallery.app` (Touch ID, unmounts on sleep or lock). The `gallery` remote (combine) is
  `gallery-main:files` and `gallery-public:folders`. R2 is already the single source of truth.
- The mount already runs the "storage-saver" shape: `--vfs-cache-mode full --vfs-cache-max-size 20G`.
- No one-way `rclone sync`/`copy` job exists for Gallery. (The only launchd sync is the ledger:
  Obsidian → R2.) Remotes: `r2`, `gallery-main`, `gallery-public`, `gallery` (combine), `sync-backup`.
- Sizes: Main 37.3 GB / 29,645 files; the Public `folders/` prefix is empty (links live under `links/`).
  Internal disk 13 GiB free.
- The Worker is up 24/7: from the iPad and iPhone, Main already does view, upload, rename, delete
  (to trash), cover, transcript edits and key, with no Mac involved.

### Why not `rclone bisync` + launchd as specified
- **It can't fit:** a local copy of Main needs 37 GB; the Mac has 13 GiB.
- **It would loop:** pointed at `~/Gallery/{Main,Public}`, bisync would sync R2 with itself through the
  mount, which doubles the traffic and lets a conflict rename or delete land in the only copy.
- **Nothing to reconcile on wake:** an edit from the iPad is in R2, and the mount shows it within
  `--dir-cache-time 1m` the next time Gallery opens.
- So there's no `com.chauphan.gallery.bisync.plist`. If an offline subset is ever wanted (one folder
  on the Mac, say), the safe shape is bisync between a real local folder such as
  `~/GalleryOffline/<folder>` and `gallery-main:gallery-main/files/<folder>`. It would run with the flags
  given (`--conflict-resolve newer --conflict-loser num --resilient --fast-list`, excludes `.DS_Store`
  and `._*`), a `/tmp/gallery_bisync.lock` guard, `--resync` once by hand after a dry run, and
  WatchPaths + `StartInterval 300` + `RunAtLoad`. Owner's call, per folder.

### Done now (source only, not rebuilt)
`gallery/chau/Gallery/main.swift` mount args: `--vfs-cache-max-age 72h` (as asked) and
`--vfs-cache-min-free-space 5G`. The 20G cap alone could fill a disk with 13 GiB free. Takes effect
after `zsh chau/Gallery/build.sh`, which quits Gallery.app and so unmounts `~/Gallery`; run it when
nothing is open there.

### Mobile write path: recommendation
1. **The web UI first (recommended).** It already works without the Mac. What's missing for a full
   "Files-like" day: New Folder, Move to folder, and multi-select Delete on Main from touch (check
   G2/G4). All of these are `PUT`/`POST`/`DELETE` on `env.MAIN` behind Access, which is the same
   pattern as rename. It's small, already secured, and needs no new auth surface.
2. **Worker WebDAV, second, and scoped.** Caveat: as far as I know, iOS/iPadOS Files "Connect to
   Server" speaks **SMB only**, not WebDAV (verify on the iPad; it may have changed). WebDAV on iOS
   means a third-party File Provider app (Documents, FE File Explorer, Secure ShellFish, …), which
   then shows up inside Files. On the Mac, Finder mounts WebDAV natively. A `/dav/` endpoint needs
   its own credentials outside Cloudflare Access, which is a **production access-rule change** (rule 5).
   Build it the way A6 already designed `/dav/notability/`: Basic auth with a separate app password
   (hash as a wrangler secret), `PROPFIND/GET/PUT/MKCOL/MOVE`, `DELETE` going to `trash/<day>/` like
   the web UI, conditional `PUT` on ETag, and miniflare tests. Start read-only plus PUT of new files,
   then widen.

**Owner to decide:** (a) web-UI gaps first, yes or no; (b) WebDAV, yes or no, and which client app on
iOS; (c) any offline folder for bisync.
