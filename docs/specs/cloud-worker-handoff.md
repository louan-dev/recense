# Cloud Worker: Technical Hand-off Report

*Share gallery, shared folders and private Studio on Cloudflare Workers and R2*

*Prepared 9 October 2026 from `worker.js` (VERSION `2026-10-09-shared-folders-v1`), `wrangler.toml` and `Copy Share Link.sh`. This is a static read of the three files; nothing was deployed or run.*

## 1. What the project is

`cloud` is a single Cloudflare Worker, live at cloud.improvdiplomat.workers.dev, backed by two R2 buckets. It serves one owner (Chau Phan) and does two jobs:

1. **Temporary sharing.** Select files or a folder and get an iCloud/Dropover-style gallery link. The link works before any upload finishes: items appear as placeholders with a progress ring and turn into real media by themselves. Everything expires (7 days by default) and is then deleted.
2. **Private Studio.** An owner-only library at `/studio` to browse, play and upload to a permanent set of files, kept at the same paths they had on the drives they were copied from. Protected by Cloudflare Access.

Around those sit a full viewer (photos, video, audio with an advanced player, PDFs), a web upload page at `/`, a macOS Finder Quick Action, and a daily cron job for cleanup.

Three facts frame everything below:

- **It is one Worker, not two.** The “shared” and “private” halves run the same code: the same gallery page, file-serving function, artwork extractor and junk-file filter. They differ only in route family, who may call them, and how long files live.
- **Public links are capability URLs.** Anyone holding `/s/<id>` can view it; nothing is listed or indexed (`x-robots-tag: noindex`). Writing needs a password. The Studio needs Cloudflare Access.
- **The project is converging on one Studio folder on the Mac with two sides:** *Studio* (kept) and *Shared* (temporary, where each folder is one link). The Worker comments state the rule directly: Shared means temporary, Studio means kept, and the two never mix.

**Headline conclusions** (detail in sections 14 to 16):

- Two buckets are not redundant in function, but the code does not require them either: it already separates the two zones by key prefix and by route. My recommendation is to keep both for now, because the bucket boundary is the only thing that keeps an auto-deleting zone physically apart from the permanent library. Merging into `global` is safe if done as described in section 15.
- Most urgent fix: the upload password sits in plain text in `wrangler.toml` and as a default value inside the script.

## 2. Constituents

| Component | Role | Defined in |
| --- | --- | --- |
| Worker `cloud` | All HTTP routes and the cron handler | `worker.js`, `wrangler.toml` |
| R2 bucket `share` (binding `BUCKET`) | Temporary data: upload shares, shared folders, link records | `wrangler.toml` |
| R2 bucket `global` (binding `GLOBAL_BUCKET`) | Permanent Studio library and its artwork cache | `wrangler.toml` |
| Cron `0 3 * * *` | Daily deletion of expired shares and folders | `wrangler.toml`, `scheduled()` |
| Cloudflare Access | Gate for `/studio`; the Worker re-verifies the signed token itself | Dashboard plus `ACCESS_*` vars |
| `Copy Share Link.sh` | Finder Quick Action: creates and uploads a share, or fetches a Shared-folder link | The script |
| Studio mount (`~/Studio`, with a `Shared` side) | Presents the buckets as folders on the Mac | Not in the files; inferred from the script and Worker comments |
| rclone | Copies files straight into R2, bypassing the Worker | Not in the files; named in Worker comments |
| R2 lifecycle rule | Backstop that deletes anything under `drop/` after 31 days | Dashboard only; described in a code comment |
| pdf.js 3.11.174 (cdnjs), client-zip@2 (jsDelivr) | Loaded by the browser for PDF viewing and zip downloads | `GALLERY_JS` |

## 3. `wrangler.toml`, line by line

- `name = "cloud"`, `main = "worker.js"`: the deployed Worker and its entry file.
- `compatibility_date = "2026-10-05"`: runtime behaviour is pinned to this date.
- `workers_dev = true`, `preview_urls = false`: served on the workers.dev subdomain; per-version preview URLs are off, so no stray copies of the Worker are reachable.
- Two `[[r2_buckets]]` blocks: `BUCKET` points to `share`, `GLOBAL_BUCKET` points to `global`. The code treats `BUCKET` as required (HTTP 500 without it) and `GLOBAL_BUCKET` as required only for `/studio`.
- `[triggers] crons = ["0 3 * * *"]`: daily at 03:00 UTC, calling `scheduled()`.
- `[vars]`: `ACCESS_AUD` and `ACCESS_TEAM_DOMAIN` (`chauphan.cloudflareaccess.com`) let the Worker verify Access tokens; `OWNER_EMAIL` names the one person allowed into `/studio`; `UPLOAD_PASSWORD` is the write password.
- The header comment says the file matches the dashboard as of 2026-10-09, and that `worker.live-studio-v1.js` is the code from before shared folders, kept for rollback. That file was not supplied.
- **Flag:** `worker.js` says the password should be a Worker *secret*; here it is a plain-text var (see section 14).

## 4. Storage map

| Bucket | Key pattern | Contents | Written by | Removed by |
| --- | --- | --- | --- | --- |
| `share` | `shares/<id>/.manifest` | JSON promise of the share: id, owner, created, exp, count, items (index, size, taken, type, name), optional `cancelled` | `/api/share` start and cancel | Cron, after expiry |
| `share` | `shares/<id>/<NNN>` | The file; NNN is its zero-padded index (000 to 999). Metadata: `name`, `expires`, `taken`, `hasArt` | `/api/upload` | Cron |
| `share` | `shares/<id>/<NNN>.art` | Cover image; a zero-byte object with `none=1` means no artwork | On demand | Cron |
| `share` | `shares/<id>/<NNN>.progress` | Zero-byte; metadata `done`, `total`, `expires` (2 days) | Multipart start and part | Complete, abort, or cron |
| `share` | `drop/<folder>/<path>` | Contents of a shared folder | The mount or rclone, not the Worker | `purgeFolder`, sweep, 31-day lifecycle |
| `share` | `links/<linkId>.json` | `{id, folder, created, exp}`; 20-character ID | `folderLink` | `purgeFolder` |
| `share` | `links/folder/<encoded folder>` | `{id}`: index from folder name to its current link | `folderLink` | `purgeFolder` |
| `global` | `lib/files/<path>` | The library at original paths; metadata `mtime` in seconds | rclone, or `/studio/api/file` | Nothing automatic |
| `global` | `lib/art/<path>` | Cached cover art; `none=1` marker when there is none | On demand | Deleted when the file is re-uploaded in the browser |

Note that `lib/art/` deliberately sits outside `lib/files/`, so an `rclone sync` of the library never sees it and never deletes it. The same pattern (derived data in a sibling prefix) is the natural home for any future Studio metadata.

## 5. Route map

| Route | Method | Who can call | What it does |
| --- | --- | --- | --- |
| `/` | GET | Public | Upload page (password needed to use it) |
| `/api/upload` | PUT, POST | `x-password` header | Single upload, or multipart via `action=start`, `part`, `complete`, `abort` |
| `/api/share` | POST | `x-password` header | `action=start`, `cancel` (upload shares) or `folder` (Shared-folder link) |
| `/api/gallery?id=` | GET | Public, needs the ID | JSON state of a gallery, used for polling |
| `/s/<id>` | GET | Public | Gallery page for an upload share or a shared folder |
| `/f/<id>/<NNN>` | GET | Public | File bytes for an upload share (`?art=1`, `?dl=1`) |
| `/d/<linkId>/<version>/<path>` | GET | Public | File bytes inside a shared folder (`?art=1`, `?dl=1`) |
| `/player/key.js` | GET | Public | The pitch-shift AudioWorklet source; static, cached one day |
| `/studio` (`?p=<folder>`) | GET | Access and owner email | Studio folder view |
| `/studio/f/<path>` | GET | Access and owner email | Library file bytes (`?art=1`, `?dl=1`) |
| `/studio/api/file?key=&mtime=` | PUT | Access and owner email, same origin | Browser upload, up to 90 MiB per file |
| anything else | any | n/a | 404 “Link not found” |

Failure behaviour worth knowing: a missing `BUCKET` binding returns 500; `/studio` without `GLOBAL_BUCKET` returns 500; a `/studio` request that fails the owner check returns the same 404 as an unknown link, so the Studio’s existence is not revealed.

## 6. Upload shares: the live gallery

### 6.1 Lifecycle, step by step

1. **Pick an ID.** The Quick Action uses `openssl rand -hex 6` (12 hex characters); the web page uses 12 random base62 characters. The Worker accepts any 8 to 32 alphanumerics (`ID_RE`).
2. **Register the gallery.** The client POSTs to `/api/share?action=start&id=…&days=…` with one line per file, tab-separated: size, taken time (ms), type, name (type and name URI-encoded). The Worker checks the password, allows 1 to 1,000 items, truncates names to 120 and types to 200 characters, clamps `days` to 1–365 (default 7) and writes `shares/<id>/.manifest`.
3. **The link is live now.** The client copies `/s/<id>` and opens it. Every item reads as pending.
4. **Upload smallest first**, each file to `shares/<id>/<NNN>` where NNN is its manifest index. Photos become viewable while a large video is still going up.
5. **Each view merges promise and reality** (6.3).
6. **On failure** the client calls `action=cancel`, which stamps `cancelled` on the manifest; unfinished tiles turn red and read “failed”.
7. **Expiry** is enforced at request time and by the nightly cron (6.5).

### 6.2 Single and multipart uploads

Cloudflare rejects request bodies over 100 MB on the Free and Pro plans before they reach the Worker, so uploads split by size:

- **Up to 90 MB:** one `PUT /api/upload?id&i&name&days&t&hasArt` with the file as the body. The Worker streams it into R2 with its content type and metadata. If the client sends no type, or `application/octet-stream`, the type is taken from the extension (`MIME_BY_EXT`: audio, video, PDF).
- **Over 90 MB:** R2 multipart. `action=start` returns an `uploadId`; `action=part&part=n` uploads one 32 MiB chunk and returns its ETag; `action=complete` takes a JSON array of `{partNumber, etag}` (1 to 10,000 parts, validated and sorted); `action=abort` cancels. Both clients retry each part up to four times and abort the upload on failure.
- **Progress** is a zero-byte side object, `<NNN>.progress`, whose metadata holds `done` and `total`. The list call that finds the files returns it at no extra cost, which is what draws the ring. It is deleted on complete or abort.

Every stored object carries metadata: `name` (URI-encoded), `expires` (upload time plus days, in ms), `taken` (the file’s modified time) and `hasArt`.

A dormant feature: `target()` can store an uploaded cover image as `<NNN>.art` (`art=1`), but neither client uses it (both send `hasArt=0`). Covers are instead extracted from audio files on demand (section 9).

### 6.3 How the gallery page knows the state

`getGalleryData(id)` runs on every page view and every poll:

1. Read the manifest and list `shares/<id>/` (paginated, with metadata).
2. Sort what it finds into ready files, progress objects and artwork. It tracks `lastActivity` as the newest upload time of anything, progress objects included, so every uploaded part counts as a sign of life.
3. If there is no manifest and no files, it checks whether the ID is a shared-folder link (section 7); otherwise the answer is “not found”.
4. It builds the item list: every ready, unexpired file, then one placeholder for each manifest entry not yet in R2, carrying `progress` (done over total), `stalled` (no sign of life for 15 minutes) and `failed` (manifest cancelled).
5. `complete` is true when ready items reach the expected count. The expiry shown is the later of the manifest’s and any file’s; once it has passed, the answer is “expired”.

The browser polls `/api/gallery?id=` every 2 seconds while the gallery is incomplete (paused while the tab is hidden), merges changes in place, animates arriving tiles, and swaps the “please check back soon” message for the real media if you were looking at it. Polling stops when the gallery is complete, when every pending item has failed, or on a 404 or 410.

### 6.4 Serving files and safety

- `/f/<id>/<NNN>` reads from R2 with range support (`Accept-Ranges`, 206 and `Content-Range`), so video and audio can seek.
- Expiry is checked on every request and answered with HTTP 410, so a file past its time is never served even before the cron deletes it.
- Only images (not SVG), video, audio and PDF display inline. Everything else, including SVG and HTML, is forced to download with `content-disposition: attachment`. Other headers: `x-content-type-options: nosniff`, `cache-control: private, max-age=3600`. `?dl=1` forces download for any file.
- Pages and JSON are `noindex` and `no-store`. Data embedded in pages and JSON escapes `<`, which blocks script injection through file names.

### 6.5 Expiry and cleanup

- **At request time:** per-object `expires` for `/f`, the link’s `exp` for shared folders.
- **Nightly (03:00 UTC):** `cleanup()` lists `shares/` and deletes, in batches, every object whose `expires` is in the past. `sweepFolders()` handles shared folders (section 7). Physical deletion can therefore lag expiry by up to about a day; access cannot.

## 7. Shared folders (the Shared side of the Studio mount)

### 7.1 The idea and its rules

- Everything under `drop/<folder>/` in the `share` bucket is shared. Each top-level folder is one gallery link.
- Expiry lives in `links/`, never on the files, because saving a file through the mount replaces the object and strips its R2 metadata.
- This code never reads or writes the `global` bucket. That is the stated guarantee that temporary and kept data do not mix.

### 7.2 Link records

- `links/<linkId>.json` holds `{id, folder, created, exp}`. `links/folder/<encoded name>` holds `{id}`, an index from folder name to its current link.
- Link IDs are 20 base62 characters (about 119 bits), made by rejection sampling on random bytes (bytes of 248 or more are discarded so every character is equally likely).
- `folderName()` accepts a name only if it is NFC-normalised, 1 to 200 characters, contains no `/`, is not `.` or `..`, has no control characters, and is not junk (starts with a dot, or is `Thumbs.db`, `desktop.ini` or `Icon` followed by a carriage return).

### 7.3 Asking for a link

`POST /api/share?action=folder&name=<folder>&days=N` (password required):

1. Validate the name (400 if bad).
2. The folder must hold at least one object under `drop/<name>/` (404 otherwise).
3. `days` is clamped to 1 to 30, default 7. It only matters when a new link is minted.
4. `folderLink()` returns the live link if the index points to one (same folder, same link). If the link exists but has expired, it purges the folder, the link and the index, and the answer is 410. If there is no link, it mints one and writes both records.
5. Response: `{ok, id, exp, url: "/s/<id>"}`.

### 7.4 The daily sweep

`sweepFolders()` runs after `cleanup()` in the same cron invocation:

1. Every expired link is purged: all objects under its folder, then the index (only if it still points at this link), then the link record.
2. Every folder under `drop/` with no index gets a 7-day link, so nothing in Shared can outlive its expiry just because nobody asked for a link.
3. Loose files at the root of `drop/` (not inside a folder, so nothing to hang an expiry on) are deleted once they are 7 days old.

The dashboard lifecycle rule (31 days on `drop/`) is the backstop, and the 30-day maximum for `days` keeps the code inside it.

### 7.5 Viewing a shared folder

- `/s/<linkId>` reaches `folderGalleryData()` through the fallback in `getGalleryData()`. It lists up to 5,000 objects, hides junk, shows files in nested subfolders flat with their relative path as the name, sorts naturally (so `2` comes before `10`), and numbers items with five digits.
- Type comes from stored metadata, or from the extension when the stored type is generic or `text/plain`. Time is the file’s `mtime` metadata, else its upload time.
- Each file’s address is `/d/<linkId>/<first 12 characters of its ETag>/<path>`. The ETag segment is only a cache-buster, so an edited file gets a new URL; the server does not check it.
- The gallery is marked complete, so it does not poll; edits appear on reload. Heading is the folder name and the zip is named after it.
- `/d/...` requires a known link (404) that has not expired (410), decodes and checks the path (no `.`, `..` or junk segments), reads `drop/<folder>/<path>` with range support, and serves it with the same safe-inline rules. It extracts cover art on every request and does not cache it.

### 7.6 Edge cases to know

- If a link has expired but the cron has not run yet, adding files to that folder and asking for a link purges the folder, new files included, and returns 410. This follows the stated rule that an expired folder gets no second life, but it will surprise someone.
- `folderLink()` has no locking. Two simultaneous requests could mint two links; the loser’s record is orphaned and, when it expires, purges the folder even though the other link is current. Both expire at nearly the same moment, so the impact is small.
- If an index exists but its link record is gone, the sweep does not re-mint; an explicit request does.

## 8. The private Studio

### 8.1 Who gets in

`studioOwner()` requires `OWNER_EMAIL` to be set, then gets the signed-in email in one of two ways: from `ctx.access.getIdentity()` if Access is on the whole Worker, or by verifying the `Cf-Access-Jwt-Assertion` token itself. Verification checks the team domain pattern, a three-part token, algorithm RS256, the audience, the issuer, expiry (with 60 seconds of skew on not-before) and the RSA signature against the team’s keys from `/cdn-cgi/access/certs` (fetched at most once a minute and cached per isolate). The email must equal `OWNER_EMAIL`, compared case-insensitively. Any failure returns the generic 404.

### 8.2 Browsing

`/studio?p=<path>` lists `lib/files/<path>/` with a delimiter, up to 5,000 files per folder. Subfolders appear as chips under a breadcrumb trail (Cloud / a / b). Junk names are hidden, sorting is natural, type comes from metadata or extension, and time comes from the `mtime` metadata that rclone preserves. Everything else is the same gallery page as for shares.

### 8.3 Uploading from the browser

- The page offers Upload or replace files: multi-select, a per-file 90 MiB check, a confirm dialog warning that matching names are replaced, then sequential PUTs to `/studio/api/file` with `mtime` set to the file’s last-modified time, then a reload.
- The server requires the `Origin` header to equal its own origin (403 otherwise), validates the key with `studioPath()` (up to 900 characters, no control characters, no empty, `.` or `..` segments), requires a `Content-Length` of at most 90 MiB (413 otherwise), writes `lib/files/<key>` with its content type and `mtime`, and deletes the cached `lib/art/<key>`.
- Anything larger goes in through the mount or rclone.

### 8.4 Bytes and artwork

`/studio/f/<path>` serves with range support and the same safe-inline rules. `?art=1` returns cached artwork from `lib/art/`, or extracts and caches it, or records a `none` marker.

### 8.5 Stated direction

The Worker comments say Studio keys never move and that organising will live in small JSON files beside them. That is not built yet.

## 9. Embedded artwork

`extractArt()` reads only tag bytes using range reads (the first 128 KB is cached, so a typical tag costs one R2 read). It supports:

- **MP3:** ID3v2.2, 2.3 and 2.4 picture frames, including unsynchronisation, extended headers and data-length indicators; compressed or encrypted frames are skipped.
- **FLAC:** the picture metadata block, including FLAC files that carry an ID3 tag in front.
- **M4A and MP4:** `moov > udta > meta > ilst > covr > data`.
- **WAV and AIFF:** the ` id3  ` chunk, which is often stored after the audio.

It prefers the front cover (type 3), accepts only bytes that really are JPEG, PNG, GIF or WEBP (magic-number check), and ignores tags over 24 MiB. Ogg, Opus and AAC are recognised as audio but have no cover extraction, so they show the file icon.

Caching differs by zone: upload shares write `<NNN>.art` next to the file (with the share’s expiry); the Studio writes `lib/art/`; shared folders cache nothing. On the page, if an audio file has no cover, the viewer looks for an image with the same base name in the same gallery.

## 10. The viewer

One dark, iOS-style page (`GALLERY_CSS` and `GALLERY_JS`, embedded as strings in `worker.js`) serves all three gallery types.

**Gallery.** Header card (heading, item count, expiry), hero tile (first photo, video or audio), a grid of 3 columns (5 on wide screens), Select mode with checkmarks, and a Download button. One file downloads directly (`?dl=1`); several are zipped in the browser with client-zip. The Studio refuses zips over 2 GB. The footer counts items by type.

**Lightbox.** Opening pushes a history entry, so the browser Back button closes it. It has previous and next, touch swipe, a filmstrip, an info card (type and size), and keyboard control (arrows, Esc, Space, `<` and `>`, `A`, `B`, `L`).

**PDFs.** pdf.js loads only when a gallery contains a PDF. First-page thumbnails are rendered once and reused in the filmstrip. The viewer renders pages lazily, releases far-off pages (it matters on iPhone), caps canvas size, supports double-tap zoom, shows a “3 of 12” pill and re-renders on rotation.

**Pending items.** Shimmer placeholder, a ring with percentage, “paused” after 15 quiet minutes, a red “failed” ring, and an iCloud-style message when opened.

**Audio and video player.**

- *Centre controls:* back 10 s, play and pause, forward 10 s; picture-in-picture where the browser supports it. Controls fade while playing.
- *Home bar:* a thin stroke at the bottom. Hover (mouse) or tap (touch) unfolds Loop and A–B; a second tap or click shows Speed (0.5, 0.75, 1, 1.25, 1.5, 2×). Press and hold (0.22 s mouse, 0.4 s touch) opens a temporary Time Seeking ruler whose ticks scale to the media length, with zoom levels of 1×, 4×, 16× and 64× reached by sliding up, and snapping to A and B. Two-finger swipes (touch or trackpad) seek without holding.
- *Loop rules:* Track Loop repeats the whole track; A–B repeats between two captured points. A–B needs Track Loop: turning A–B on turns Track Loop on, turning Track Loop off turns A–B off, and clearing the points leaves Track Loop alone. Pressing B first means loop from 0:00 to now. None of this ever pauses, reloads or recreates the media.
- *Sound island (vertical stroke at the right):* a three-band EQ (low shelf 160 Hz, mid peak 1 kHz, high shelf 5 kHz, ±15 dB) drawn as a live curve from the same filter maths the audio uses; Key, ±12 semitones; and Space, a reverb with Room or Hall and an amount with bypass.
- *Key:* a phase vocoder (2048-point FFT, 8× overlap, phase-locked after Laroche and Dolson) in an AudioWorklet served from `/player/key.js`. It shifts pitch without changing tempo, with about 41 ms of latency.
- *Space:* a convolution reverb whose impulse responses are synthesised in the browser from seeded noise, so nothing is downloaded and a render is repeatable.
- *Safari and iOS deck:* Safari hands media elements to Web Audio at 1× whatever the speed, which breaks playback above 1×. On Safari and every iOS browser the element plays muted as the clock and picture, and a second AudioWorklet plays the file’s own decoded audio in 65,536-frame chunks, kept in step with the element. WAV and AIFF are read in byte ranges; other formats are decoded whole if they are at most 150 MB and 20 minutes, otherwise playback falls back to 1× with a notice.
- *Downloads with the sound baked in:* if Key, EQ or Space is active, the download button for audio renders a WAV (16 or 24 bit, original sample rate and length) in stretches, using the same filters, the same Key processor run in the page, and Space through an offline audio context that carries the room tail between stretches. It falls back to the original on any problem. Video downloads unchanged, and Speed is never baked in.
- Settings last for the page session only; nothing is stored. Sliders have ARIA roles and keyboard control, and reduced-motion and reduced-transparency preferences are respected.

## 11. The web upload page (`/`)

A public page with a password field (remembered in `localStorage`), a duration choice of 1, 7 or 30 days, drag-and-drop or file picker, a removable file list and a Create link button. On click it opens a blank window straight from the click (so popup blockers allow it), registers the session, copies the link, points the window at the gallery, then uploads smallest first (single request, or 32 MiB parts with four retries). On error it cancels the session. Its only protection is the password at the API.

## 12. The Finder Quick Action (`Copy Share Link.sh`)

**Setup.** In Automator create a Quick Action that receives files or folders in Finder, add Run Shell Script with shell `/bin/bash` and input passed as arguments. Standard input also works: the script reads one path per line.

### 12.1 Configuration

All settings are environment variables with defaults: `SHARE_BASE` (the workers.dev URL), `SHARE_PASSWORD` (a default is hard-coded), `SHARE_DAYS` (7), `SHARE_OPEN` (1: open the gallery in the browser), `SHARE_PART_MB` (32, minimum 5), `SHARE_BIG_BYTES` (90,000,000), `SHARE_RETRY_SLEEP` (3), `SHARE_LOG_DIR` (`~/Library/Logs`, log file `share-link.log`) and `SHARE_SHARED_DIR` (`~/Studio/Shared`).

### 12.2 Helpers

Logging; macOS alert, notification and a self-closing 7-second toast; `enc`, a percent-encoder for every byte; `call`, curl with the password header (20 s connect timeout, 120 s total, 900 s for uploads); `call_retry` (four tries with 3, 6 and 9 s back-off, never retrying 401 or 404); `why`, which turns HTTP codes into plain reasons; abort and cancel on failure or interruption; a dependency check (curl, openssl, file, dd, od, tr, sed, sort, cut, mktemp); and a temporary directory removed on exit.

### 12.3 The two paths

**A. Shared-folder path.** If the first selected item is under `~/Studio/Shared/`:

1. A loose file directly in Shared is refused (put it in a folder first).
2. Otherwise the top-level folder name is POSTed to `action=folder`.
3. On 200 the script reads `url` with sed, builds the link, copies it to the clipboard, notifies that it expires with the folder, prints it and exits. On 410 it says the folder had expired and was deleted; on 404 it says the folder is not in the cloud yet and to wait for the copy to finish.
4. Nothing is uploaded.

**B. Upload path** (anything else). Every input must be a regular file; folders are refused here.

1. Generate the ID and the link `BASE/s/ID`.
2. Build the item list (size, modified time in ms, MIME type from `file`, name) and POST `action=start`. A 200 makes the session live; a 404 means an old Worker, so the script falls back to link-at-the-end.
3. Copy the link at once, notify, show the toast, open the gallery.
4. Sort by size, smallest first. At or below `SHARE_BIG_BYTES`, one PUT with `-T`. Above it: multipart. `start`, then `dd` cuts 32 MiB chunks into a temp file, each PUT with retries, ETags collected with quotes stripped, then `complete` with the JSON list.
5. Verify: poll `/api/gallery` for up to 10 seconds for `"complete":true`, then GET the public link and expect 200.
6. Finish: print the link, notify, show an alert. In live mode the clipboard is not overwritten at the end.
7. On any failure: abort the multipart upload, cancel the session (tiles turn red), alert, exit 1.

### 12.4 Quirks

- The Shared path inspects only the first selected item.
- A few comments and one message still use older names (`worker.mjs`, “live-v2”).
- The 404 fallback for old Workers is dead code now.
- Files selected from the mounted Studio are treated as ordinary files: they are read back through the mount and re-uploaded, so each such share transfers the data twice.

## 13. Rules and limits at a glance

| Rule | Value | Enforced in |
| --- | --- | --- |
| Upload-share lifetime | UI offers 1, 7 or 30 days; API accepts 1 to 365; script default 7 | `shareSession`, `target`, `SHARE_DAYS` |
| Shared-folder lifetime | Default 7, maximum 30; unrequested folders get 7 at the next sweep | `shareFolder`, `sweepFolders` |
| Files per upload share | 1,000 (three-digit index) | `shareSession`, `target` |
| Single-request upload | About 90 MB; clients switch at 90,000,000 bytes (Cloudflare caps bodies at 100 MB on Free and Pro) | Clients |
| Multipart upload | 32 MiB parts, up to 10,000 parts, four retries per part | Clients, `multipart` |
| Browser upload to Studio | 90 MiB per file, same origin only | `studioUpload` |
| Write authentication | `x-password` header, constant-time compare | `authed` |
| Studio authentication | Access token plus owner email, re-verified in the Worker | `studioOwner`, `accessEmail` |
| Share ID format | 8 to 32 alphanumerics | `ID_RE` |
| Folder name | Up to 200 characters, no `/`, no junk | `folderName` |
| Studio path | Up to 900 characters, no `.` or `..` segments | `studioPath` |
| Item name and type | 120 and 200 characters | `shareSession` |
| Listing cap | 5,000 files per folder view | `STUDIO_MAX` |
| Stall detection | 15 minutes with no sign of life | `STALL_MS` |
| Inline display | Images (not SVG), video, audio, PDF; all else downloads | `serveObject` |
| Cover tag ceiling | 24 MiB | `MAX_TAG` |
| Zip download | Studio capped at 2 GB; shares and shared folders have no cap | `GALLERY_JS` |
| Hidden names | Dot-files, `Thumbs.db`, `desktop.ini`, `Icon` plus carriage return | `STUDIO_JUNK` |
| Cron | 03:00 UTC daily | `wrangler.toml` |
| Lifecycle backstop | 31 days on `drop/` | Dashboard |
| Loose files in Shared root | Deleted after 7 days | `sweepFolders` |
| Expiry enforcement | At request time (410) and by the cron | `file`, `folderFile`, `cleanup` |

## 14. Security model and findings

**How protection works today.** Reading a share needs an unguessable ID. Writing needs the password, compared in constant time. The Studio needs a valid Access token whose email is the owner’s, re-verified inside the Worker rather than trusted from the edge, and it answers failures with the same 404 as an unknown link. Browser uploads to the Studio also check the `Origin` header. Files display inline only if their type is safe, pages are `noindex`, and embedded JSON escapes `<`.

**Findings, in priority order:**

1. **The password is exposed.** `UPLOAD_PASSWORD` is a plain-text var in `wrangler.toml` (so it is visible in the dashboard and wherever the file is stored), the same value is the default inside the script, and the web page remembers it in `localStorage`. The Worker’s own header says it should be a secret. Because these files were shared for this review, treat it as exposed and rotate it. It is deliberately not reproduced in this report.
2. **Share IDs from the script are short.** `openssl rand -hex 6` gives 48 bits, against about 119 bits for shared-folder links. A capability URL is only as strong as its ID.
3. **No throttling on password guesses.** `/api/upload` and `/api/share` are public endpoints; a constant-time compare does not limit how many guesses can be made.
4. **Verify how Access is scoped.** The Studio’s protection depends on the Access policy covering `/studio*` while `/s`, `/f`, `/d`, `/api` and `/player` stay public. The code works with either Access arrangement, but the dashboard decides. On a workers.dev hostname, path-level scoping may not be available; a custom domain on your own zone normally allows it.
5. **Unpinned third-party code in the page.** client-zip is imported as `@2` (a version range, not an exact version) from jsDelivr, and pdf.js is pinned but loaded without an integrity check. A compromised release would run inside the gallery page, the Studio included.
6. **Zip size guard is Studio-only.** A shared folder can list 5,000 files and has no size warning before the browser starts zipping in memory.
7. **Browser caching outlives expiry.** Files are served with `private, max-age=3600`, so a browser can keep a copy for up to an hour after a link expires. Low impact.
8. **Expired-folder purge on request** (7.6) can delete files someone has just added.

## 15. Two buckets: redundant, fine, or merge?

### 15.1 A correction first

There is one Worker with two bindings. The question is about storage layout, not about merging two Workers, and no Worker code needs to be merged.

### 15.2 What actually differs between the zones

|  | Share zone (`share`) | Studio zone (`global`) |
| --- | --- | --- |
| Read access | Anyone with the link | Owner, through Access |
| Write access | Password (API); mount or rclone for `drop/` | Owner (browser); rclone |
| Retention | Expires: 1 to 365 days; folders 1 to 30 | None |
| Automatic deletion | Yes: cleanup, purge, sweep, lifecycle rule | None |
| Object metadata | `expires`, `name`, `taken`, `hasArt`; plus link records | `mtime` only |
| Key prefixes | `shares/`, `drop/`, `links/` | `lib/files/`, `lib/art/` |
| Routes that touch it | `/f`, `/d`, `/s`, `/api/*`, cron | `/studio*` only |

What is the same: range serving, the safe-inline policy, artwork extraction, the gallery page, the junk filter and name validation.

### 15.3 What the code shows

The two zones’ prefixes never overlap, and every delete path is bound to a prefix: `cleanup()` to `shares/`, `purgeFolder()` to `drop/<folder>/` and `links/`, and the Studio writes only under `lib/`. So the bucket boundary is not doing any rule-enforcement that the prefixes and routes are not already doing. On that point your observation is right: the rules that differ (who may read, how long data lives) are implemented by route and prefix, and the serving logic is shared.

### 15.4 What the bucket boundary still gives you that code cannot

1. **Deletion blast radius.** The share zone has three automatic deleters: the nightly cleanup, the folder purge and sweep, and a dashboard lifecycle rule that lives outside the repository. With separate buckets, the worst misconfiguration (a lifecycle rule with an empty prefix, a typo in a prefix constant) costs temporary data. In one bucket it could cost the library. Lifecycle rules are per bucket with an optional prefix filter, so safety would rest on one dashboard field.
2. **Credentials.** As far as I know, R2 API tokens are scoped per bucket, not per prefix. Separate buckets let the Shared side of the mount use a token that physically cannot touch the library. Whether that benefit is used today depends on how the mount is configured, which is not in the files.
3. **Bucket-wide settings.** Public access (r2.dev or a custom domain), CORS and storage class are set per bucket. If you ever serve shared files straight from a custom domain for speed, enabling public access on a mixed bucket would expose everything in it.

### 15.5 What a merge would give you

- One binding, one rclone remote and token, one place to look, one fewer concept to document.
- Server-side copy inside one bucket through the S3 API, for example promoting a Studio folder to Shared without crossing the Mac (the Worker binding itself has no copy call, so the Worker would still stream).
- No cost saving: R2 bills storage and operations, not buckets.

The gain is mostly tidiness.

### 15.6 Verdict

- **Not redundant in function, and not required by the code.** The split is a safety boundary, not an architectural need.
- **My recommendation: keep two buckets for now.** The cost is zero, and it is the only part of the design that keeps an automatically deleting zone physically separate from permanent data. That matters most if the R2 copy of the library is ever the only copy.
- **Revisit the merge** if you add a feature that wants both zones in one bucket (such as server-side copy), or if the mount turns out to use one credential for both sides, in which case the separation buys nothing in practice.
- **If the library has a backup elsewhere and you prefer simplicity,** merging into `global` is a sound direction and a low-risk change, because the prefixes are already disjoint.

### 15.7 If you merge into `global`

1. In `wrangler.toml`, point `BUCKET` at `global` as well. Both bindings then address one bucket with no code change; collapse them to one binding name later.
2. Recreate the 31-day lifecycle rule on `global`, scoped to `drop/` only, and confirm no rule has an empty prefix.
3. Repoint the mount and rclone: the Shared side to `global:drop/`, the Studio side stays `global:lib/files/`. Never run rclone against the bucket root.
4. Existing links live in `share`. Either let current shares lapse before cutting over, or copy `shares/`, `drop/` and `links/` across with object metadata preserved (the `expires` metadata is what the cleanup and gallery rely on), and verify before switching.
5. Keep `share` until its longest-lived share has expired, then delete it.
6. Afterwards, hold every prefix in one constants block, make the purge and cleanup functions refuse any key outside their prefix, and keep a separate copy of the library.

One thing to check regardless: if any earlier rclone copy of the library went to `lib/files/` inside the `share` bucket, `/studio` cannot see it, because it reads `global`.

### 15.8 Something else: what is really duplicated

The duplication is not the buckets but the two sharing models. Upload shares use a client-chosen ID, a manifest in `shares/` and per-object expiry metadata. Shared folders use a server-minted ID, a record in `links/` and expiry held in the link. That is two ID schemes, two expiry mechanisms and two cleanup paths (`cleanup` and `sweepFolders`). Folding both under one `links/` record (type upload or folder, expiry, prefix) gives one expiry authority and one cleanup, and it follows the lesson the code already records: object metadata gets stripped, so expiry belongs in the link. That removes more complexity than merging the buckets would.

## 16. Recommended next steps

Ordered by priority and consistent with the project’s direction (one Cloud folder, Studio kept, Shared temporary).

**Do first: security hygiene**

1. Rotate the upload password and store it as a Worker secret (`wrangler secret put UPLOAD_PASSWORD`); delete it from `[vars]`; remove the default from the script and read it from the environment or the macOS Keychain; clear browser-remembered copies.
2. Mint share IDs on the server, or at least lengthen script IDs to 20 or more base62 characters. `ID_RE` already allows it.
3. Add a Cloudflare rate-limiting rule on `/api/upload` and `/api/share` for repeated 401 responses.
4. Confirm the Access application’s scope. If workers.dev prevents path-level scoping, move the Worker to a custom domain.
5. Pin client-zip to an exact version, or self-host it and pdf.js.

**Next: correctness and robustness**

6. Fix the expired-folder edge case: before purging on request, compare the link’s expiry with the newest object in the folder, and treat newer files as a new folder with a fresh link.
7. Apply the 2 GB zip guard to shared folders, and consider a streaming or server-side zip for large ones.
8. Script: handle several selected items in Shared (or refuse mixed selections), refresh the stale comments and messages, and drop the old-Worker fallback.
9. Record the dashboard-only configuration in the repository: lifecycle rule, Access application, secrets, rclone remotes and token scopes. Add the rollback file `worker.live-studio-v1.js`.
10. Decide the bucket question (section 15) and write the decision into the repository.

**Then: in line with the direction**

11. Unify link records (15.8).
12. Share from Studio: an Access-gated endpoint that stream-copies a Studio folder into `drop/<name>/` and mints its link, avoiding the download-and-reupload through the Mac.
13. Put Studio organisation data (the small JSON files the code comments anticipate) in a sibling prefix such as `lib/meta/`, following the `lib/art/` pattern so an rclone sync never touches it.
14. Maintainability: `worker.js` is one very large file with the viewer embedded as strings. Split it into modules and static assets with a build step, and add tests for the pure parts: ID3, FLAC and MP4 parsing, `folderName`, `studioPath`, `accessEmail` and the `getGalleryData` merge.

## 17. What these files cannot confirm

- How Cloudflare Access is configured and scoped.
- The mount and rclone setup: remotes, token scopes, and how Studio and Shared map to buckets and prefixes.
- The exact lifecycle rule (it is described only by a code comment).
- Whether `UPLOAD_PASSWORD` also exists as a dashboard secret, and which value the deployed Worker uses.
- Whether the deployed Worker matches `worker.js`; the `x-version` response header can confirm it.
- Whether public access (r2.dev) is disabled on both buckets.
- Where earlier library copies live (see the note in 15.7).
- `worker.live-studio-v1.js` was not supplied.
