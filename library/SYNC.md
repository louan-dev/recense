# Sharing the Gallery mount across devices (proposal, nothing built yet)

Goal: the same Main library on the Mac (Finder, `~/Gallery`), the iPad Air 13" and the iPhone 12 Pro Max, where an upload or an edit on one shows on the others within a second or two, and two devices editing the same thing never lose each other's work.

## 1. One source of truth: R2 plus a change feed
R2 stays where the bytes live. What is missing is a way for a device to hear that something changed. Add one Durable Object, **LibraryHub** (one instance for Main):
- Every write the Worker makes (upload, delete, rename, cover, key, comment, correction) ends by calling the hub with `{ seq, path, kind, etag, by }`. The hub gives it a sequence number and keeps the last ~10,000 in its storage.
- Pages open a WebSocket to `/main/api/live` (hibernatable, so idle sockets cost nothing). They receive changes as they happen and re-fetch only the item that changed. On reconnect they send their last `seq` and get what they missed, or "reload" if it is too old.
- This is the "Durable Objects only for presence and co-editing; no polling" rule in CLAUDE.md (C1).

## 2. Writes that never overwrite each other
- Every write is conditional on the ETag the device last saw (`onlyIf: { etagMatches }`). This is already done for transcript corrections. Extend it to rename, cover, key and comments.
- When the ETag check fails, the Worker answers 409 with the current version. Text (comments, corrections) merges per field, latest `updatedAt` wins, as `mergeOverrides` does now. A media file is never merged: the later upload becomes a new version and the older one goes to `trash/`.
- Uploads are multipart (resumable), so a phone that loses its connection carries on where it stopped. Each upload is announced to the hub when it starts (others show it as pending with progress) and when it is done.

## 3. The Mac's mount
The rclone mount only sees R2. Changes made through the Worker reach it on the next directory listing, and Finder edits never reach the hub. Two changes fix both:
- Run `rclone mount` with `--vfs-cache-mode writes --dir-cache-time 5s --poll-interval 0`, plus a small helper (inside Gallery.app) that subscribes to the hub and runs `rclone rc vfs/forget dir=<folder>` for each change. Finder then refreshes within a second.
- Finder writes go through the Worker, not straight to R2. Point rclone at a WebDAV endpoint that the Worker serves (`/main/dav`, behind the same Access service token as now). Every Finder save is then a Worker write: ETag-checked, versioned to `trash/`, announced to the hub. Using rclone's own WebDAV backend keeps the mount code unchanged.

## 4. iPad and iPhone
- The web app, opened as a Home Screen app, gets the same live socket. For the Files app (a mount like Finder's), the same `/main/dav` endpoint can be added in Files, Connect to Server. This needs Access to accept a per-device service token or a participant token, because Files cannot do the Access sign-in.
- Offline: the page queues corrections and comments in IndexedDB and sends them on reconnect. They go through the same 409 merge.

## 5. Transcripts
Content keys (done) mean an upload from any device that matches a file already transcribed gets its transcript at once. The hub also announces `keep/<key>/` changes: when Recense finishes, every open viewer switches to the lyrics without the current 5-second poll.

## Order of work
1. LibraryHub and the WebSocket, with the Worker announcing what it already writes. This is the largest gain.
2. ETag conditions on every write, with 409 merges.
3. The rclone refresh helper in Gallery.app.
4. `/main/dav` for Finder and the Files app.
5. Resumable uploads and the offline queue.
