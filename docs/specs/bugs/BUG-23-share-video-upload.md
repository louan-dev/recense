# BUG-23 · Adding a big video to a Gallery share link fails

From: owner, 2026-11-16 ("uploading a video to a Gallery share link fails with an error"; the file:
`ScreenRecording_11-16-2026 05-44-25_1.MP4`, an iPhone/iPad screen recording, 4-5 min, a few hundred MB) ·
Guards: notes 20261029 item 16 (Shared Albums: "people with a link post files"), BUG-20 ·
Status: `[~]` (fixed, tests pass; owner's check on the real file after deploy owed)

## What the owner sees
- On a share link (`/s/<id>`), Add → choose the screen recording → the upload fails with an error.
  The owner has not given the error text.

## Invariants
1. Any file a share link accepts (guest or owner, any name — spaces, upper-case `.MP4` — any type, any size up
   to the 5 GB guest cap) reaches the **link** (`links/<id>/NNN` in `PUBLIC`), never Main.
2. No single browser request body on that path exceeds ~90 MB (Cloudflare refuses bodies over 100 MB with a 413
   before the Worker runs): anything bigger goes up as R2 multipart parts.
3. The stored object keeps the original name (spaces, case) and a `video/*` content type.

## Red (what the code shows)
The share page has two add paths, and the owner was on the wrong one.
- `library/src/client/gallery.js` `guestPost()` (`guest() && G.perms.upload`) runs **once at page load**
  and turns `#up` into the visible "Add" pill. At that moment `owner` is still `false`: `showOwner()`
  sets it only after `/main/api/whoami` answers. So a signed-in owner sees the guest's Add pill on their own link.
- When the owner taps Add, `addFiles()` checks `guestPost()` again. `guest()` is now false (`owner` is true),
  so the code skips `guestAdd()` (reserve → 16 MB parts → complete) and falls through to the **Main** path:
  - `files.filter((f) => f.size > G.uploadMax)`: share pages never set `G.uploadMax` (only `main.js:653`,
    `invite.js:396` and `archive.js:185` do), and `size > undefined` is false, so nothing is "too big".
  - `putFile(MAIN_API + "/file?key=<name>")` sends the **whole file in one PUT**, aimed at Main's root,
    not at the link.
- Main's `/main/api/file` (`main.js` `mainUpload`) refuses any body over 90 MiB with
  `413 "Too big for the browser"`. In production, Cloudflare refuses bodies over 100 MB with its own 413 before
  the Worker runs. A 4–5 min screen recording (a few hundred MB) cannot pass either one. The tile shows a red "!"
  ring, and the card says "upload failed".
- Reproduced (`ui.test.mjs` "BUG-23: the owner adds a big .MP4 …", before the fix):
  `PUT /main/api/file?key=ScreenRecording_11-16-2026+05-44-25_1.MP4&mtime=… -> 413`, the tile's red ring,
  and "1 of 2 items · upload failed". Even a small file was wrong on this path: it went to Main's root, not the link.

### Ruled out (each is tested now, all already fine)
- **Upper-case `.MP4` / MIME:** `target()` and `guestUploadApi` lower-case the extension; the stored type is `video/mp4`.
- **Spaces in the name:** kept intact through `encodeURIComponent` in `customMetadata.name`.
- **Part size and count:** 16 MiB parts (5 MiB minimum, 10000 maximum); the 5 GB guest cap is about 320 parts.
- **H.264 vs HEVC:** the server never parses the video; both clips round-trip byte for byte and serve 206 on a range request.
- **Progress record:** removed on complete.
- **Poster/artwork:** not on the upload path.
- **Finder script and `/main/share`:** both send anything over 90 MB in 32 MiB parts already.

## Green (the fix)
- `gallery.js`: `linkPost()` = `G.perms.upload && (guest() || ownsLink())`. `addFiles()` sends both the owner
  and guests through `guestAdd()`; for the owner it posts to `MAIN_API + "/linkadd"` and asks for no name.
- `public.js` `guestUploadApi(req, env, url, owner)`: with `owner=true`, it needs no guest cookie and no name,
  stores the item with `vid: "owner"` and no `by`, skips the guest-perms gate (the owner can add even after
  turning guest posting off), and logs no Activity. `worker.js` routes `/main/api/linkadd` (POST/PUT) to it
  inside the Access-guarded `/main` block.
- Hardening (not shown to be the cause):
  - `multipart()` buffers a part sent without `Content-Length` instead of failing with "Provided readable stream
    must have a known length".
  - `guestAdd()` retries each part up to 4 times with a growing pause, as `upload.js` does. Before, one dropped
    16 MB request on a phone failed the whole video with "Couldn't add …: Load failed".

## Tests
- `routes.test.mjs` "BUG-23: a guest adds an iPhone screen recording …": the real H.264 and HEVC clips
  (`test/fixtures/bug23/`, made with ffmpeg) under the owner's exact file name, padded to 3 parts. Bytes, name, type,
  expiry, progress cleanup, gallery entry and a range request are all checked.
- `routes.test.mjs` "BUG-23: the owner adds to their own upload link through /main/api/linkadd …": the owner sends
  2 parts; the owner can add with guest posting off; an abort mid-way leaves no file, no ring and no pending tile; no-Access and stranger get 404; a guest can't send the owner's
  reserved file (403).
- `ui.test.mjs` "BUG-23: the owner adds the real 160 MB .MP4 to their own mixed share …": a share already holding
  a photo, an mp3 and a small mp4. The owner, signed in, adds a 159,964,662-byte file (the real recording's size: a
  sparse file with the HEVC clip at its head, under the real name). A pending tile with its ring shows; the first
  part is dropped once and sent again. Checked: sha256 equal, 10 part requests, none over 90 MiB, nothing in Main,
  and the gallery lists all four items with the right names and types.
  Red before the fix (413 on one PUT to Main). Red again without the retry ("Couldn't add …: Failed to fetch").
- `ui.test.mjs` "BUG-23: a guest adds a 40 MB .MP4 …": the guest path in the browser, 3 parts.

## Log
- 2026-11-16 · filed by the share-video-upload lane; read the upload path end to end.
- 2026-11-16 · reproduced red in the browser (owner path: 413 on one PUT to Main); fixed; tests green.
- 2026-11-16 · coordinator relayed the owner: "i need the multipart upload to work when im uploading media on
  cloudflare too, right now it only works if i do it as a quick action, i need to be able to have mixed share media
  then add a large video to it via browser". The real share holds the recording at 159,964,662 bytes (HEVC 2732x2048).
  Tests widened to that size, a mixed share, sha256, retry and abort.

## Handoff
**Status: PARTIAL.** Fixed and tested on `work/share-video-upload`. Not merged, not deployed (`wrangler deploy`
needs the owner's confirmation). The owner's check on the real file is owed.

**Cause (evidence).** On a share link (`/s/<id>`), the owner's own browser add never used multipart.
- The "Add" pill appears at page load, while the page still takes the viewer for a guest (`guestPost()` in
  `library/src/client/gallery.js`).
- Once `/main/api/whoami` says "owner", `addFiles()` no longer matches `guestPost()`. It falls through to Main's
  path: one `PUT /main/api/file?key=<name>` with the whole file. Share pages have no `G.uploadMax`, so nothing
  stops the file first.
- That route refuses bodies over 90 MiB (`main.js` `mainUpload`: 413 "Too big for the browser"), and Cloudflare
  refuses bodies over 100 MB with its own 413. A 160 MB recording can pass neither. The tile shows a red "!" ring
  and the card says "upload failed".
- Reproduced in Playwright + miniflare: `PUT /main/api/file?key=ScreenRecording_11-16-2026+05-44-25_1.MP4 -> 413`.
- Why only the Quick Action worked: it goes through `/main/api/link` + `/main/api/upload` start/part/complete in
  32 MiB parts.
- Even a small file went wrong on this path: it landed in Main's root, not in the link.

**Ruled out (tested):** upper-case `.MP4`, spaces in the name, H.264 vs HEVC, part size and count, progress record,
poster/artwork. `/main/share` and the Finder script already send anything over 90 MB in parts.

**Fix.**
- `gallery.js`: the owner on their own upload link (`ownsLink()` and `G.perms.upload`) adds through `guestAdd()`,
  the same protocol guests use: reserve, start, 16 MB parts, complete, with abort on failure. For the owner it
  posts to `/main/api/linkadd` and asks for no name.
- `worker.js` routes `/main/api/linkadd` (Access-guarded, like all of `/main`) to `guestUploadApi(…, owner=true)`
  in `public.js`. Owner mode needs no cookie or name, ignores the guest-posting switch, and writes no Activity entry.
  It reuses the existing `multipart()` start/part/complete/abort; there is no second protocol.
- Hardening:
  - Each part is retried up to 4 times (one dropped request no longer fails the whole video).
  - `multipart()` buffers a part sent without `Content-Length`.

**Tests.**
- `routes.test.mjs`: 62 passed. `GALLERY_D1=1 routes.test.mjs`: 63 passed. Both include the 2 new BUG-23 tests.
- `ui.test.mjs`: 55 ok, 2 FAIL. The 2 new BUG-23 tests pass. The 2 failures are the ones already failing on main:
  "Home bar: Delete Cover…" and "SPEC P3 12: Download bakes in EQ…".
- `viewer.test.mjs`: 114 passed, 6 failed (the G3 "B framed by default…" set). The same 6 fail on main, checked in a
  clean worktree. `npm test` never reaches this file because the chain stops at ui's failure.
- All other test files pass: keylabel 13, ai 25, calendar 15, feed 11 + 11 (D1), transcript 15, pieces 7, cadence 10,
  images 8, editorpwa 2. dav-rclone and learn exit 0.

**Unverified.**
- Real Cloudflare: the 100 MB edge cap, R2 multipart in production, Safari/iPadOS file pickers. Miniflare and
  Chromium only.
- The owner never gave the error text. The cause above explains "fails with an error" for the owner adding on their
  own link. If they were signed out (a guest), the guest path was already multipart; the only weak point there was
  the missing retry, now fixed.
- Not done: resuming after a page reload or a locked phone mid-upload. A reload loses the upload. The reserved
  item stays as a pending tile, which `galleryApi` shows as stalled (not checked further).

**Owner's check after deploy** (share a link, then on each device).
1. **Mac (Safari or Chrome)**, signed in to `/main`:
   - Open a share link that already has photos, audio or a small video.
   - Click **Add** and pick `ScreenRecording_11-16-2026 05-44-25_1.MP4`.
   - Expect: a new tile with a filling ring, then the video plays in the link. No red "!".
2. **iPhone 12 Pro Max (Safari)**, signed in to `/main` on the phone: the same steps, picking from Files or Photos.
   - Keep Safari in front while it uploads; it takes roughly 10 parts of 16 MB.
   - Expect the note to read "Adding … N%", then "Added…".
3. **iPad Air M2 13-inch (Safari)**: the same steps, then once more in a private window, which is the guest path.
   Enter a name when asked.
4. Open the link on another device and play it: the name keeps its spaces, and seeking works.

**If it still fails, copy:**
- The red note's exact words under the card (they start "Couldn't add …:").
- From the browser console's Network tab, the last `/main/api/linkadd?…` or `/api/upload?…` request: its `action=…`
  and its status code.
- On a Mac: Safari › Develop › Show Web Inspector › Console and Network. On iPhone/iPad: Settings › Safari ›
  Advanced › Web Inspector, then connect to the Mac's Safari Develop menu.
