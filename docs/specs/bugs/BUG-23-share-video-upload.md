# BUG-23 · Adding a big video to a Gallery share link fails

From: owner, 2026-11-16 ("uploading a video to a Gallery share link fails with an error"; the file:
`ScreenRecording_11-16-2026 05-44-25_1.MP4`, an iPhone/iPad screen recording, 4-5 min, a few hundred MB) ·
Guards: notes 20261029 item 16 (Shared Albums: "people with a link post files"), BUG-20 ·
Status: `[~]` (investigating)

## What the owner sees
- On a share link (`/s/<id>`), Add → choose the screen recording → the upload fails with an error.
  The owner has not given the error text.

## Invariants
1. Any file a share link accepts (guest or owner, any name — spaces, upper-case `.MP4` — any type, any size up
   to the 5 GB guest cap) reaches the **link** (`links/<id>/NNN` in `PUBLIC`), never Main.
2. No single browser request body on that path exceeds ~90 MB (Cloudflare refuses bodies over 100 MB with a 413
   before the Worker runs): anything bigger goes up as R2 multipart parts.
3. The stored object keeps the original name (spaces, case) and a `video/*` content type.

## Log
- 2026-11-16 · filed by the share-video-upload lane; reading the upload path end to end.
