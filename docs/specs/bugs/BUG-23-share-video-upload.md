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
  2 parts; the owner can add with guest posting off; no-Access and stranger get 404; a guest can't send the owner's
  reserved file (403).
- `ui.test.mjs` "BUG-23: the owner adds a big .MP4 …": the owner, signed in, on their own `/s/<id>` adds a 110 MB
  file (a sparse file with the HEVC clip at its head, under the real name). It lands in `links/<id>/001`, no request
  is over 90 MiB, and nothing lands in Main. Red before the fix, green after.
- `ui.test.mjs` "BUG-23: a guest adds a 40 MB .MP4 …": the guest path in the browser, 3 parts.

## Log
- 2026-11-16 · filed by the share-video-upload lane; read the upload path end to end.
- 2026-11-16 · reproduced red in the browser (owner path: 413 on one PUT to Main); fixed; tests green.
