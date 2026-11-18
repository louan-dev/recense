# FEAT-31 · Big uploads resume where they stopped, on every device

From: owner 2026-11-18 (research request: "anything the project does better that would improve offline sync and uploads?"; sources: canopas/cloud-gallery and a pasted survey of Immich, Ente, tus/TUSKit, TanStack DB, automerge-swift) · Status: `[ ]` spec only · Effort: medium

## Verdict first
- **canopas/cloud-gallery: nothing to adopt.** An archived (read-only since 2025-09-18) Flutter app that copies photos to Google Drive and Dropbox. Its README says nothing about resumable upload, dedup or offline behaviour (checked 2026-11-18).
- **One real gap found, from the Ente/tus idea: resume after a kill.** The web uploader resumes; the Swift one does not.
- Most of the pasted survey's "fixes your codebase issue" claims describe problems this codebase does not have, or has already fixed (table below).

## Premises checked against the code (2026-11-18, main 03d2e2e)
| Claim in the survey | Verdict | Evidence |
|---|---|---|
| Uploads should go direct to R2 with presigned URLs; the Worker must not stream bytes | **Not adopted.** True that bytes pass through the Worker; false that this is a problem | `library/src/main.js` / `fp.js` / `invite.js` stream each part through the R2 binding. A part is one request (≤ 90 MiB), so a 10 GB file is ~115 Worker requests. Uploads are not what spends the Worker's daily request allowance. Presigning would need R2 S3 credentials stored in the Worker, a SigV4 signer and bucket CORS rules: more secrets and code for no measured gain |
| Worker "Error 1027" lockouts from media | **Happened once, cause was elsewhere, fixed** | `docs/PROGRESS.md` 2026-11-05: the 11-03 Error 1027 was docs-sync's WebDAV bisync (≈ 90 % of Worker requests), not uploads. `com.chauphan.docs-sync` now runs hourly (StartInterval 3600). Current daily request count is **unmeasured**: check the Cloudflare dashboard before anyone claims a number |
| Replace `PROPFIND`/`LIST` walks with a cursor (`sinceTime`) | **Already built for the Files app** | `fp.js`: `GET …/changes?since=<seq>` returns events after `seq` and the new seq; `items` pages by `cursor` |
| A static `shared-index.json` per share link makes leaks impossible by construction | **File does not exist; the property is already how invite.js works** | invite.js lists only `inv.items`; every other write path answers `gone()` (404); BUG-30 (merged ad9b0f9) seals private paths "anywhere" and tests it. A second index file would be a second thing to keep in step |
| `Listen.swift` loses its upload/edit queue on termination | **False as stated** | `pending` (line 155) is the list of sentences still to translate, re-derivable from the transcript. The episode itself is written atomically to `Documents/Recense/library/Listen/<key>.json` after each change (line 499), and the ring's `seen` map is in UserDefaults |
| Immutable, content-addressed assets with long cache headers | **Partly there** | `library/src/images.js:68` sends `max-age=31536000, immutable`. Whether every key is content-addressed was not audited |
| Base-tracked 3-way text merge (automerge-style) | **Already own** | `notesync.swift`, `.carry/base/<sha256>`; no dependency to adopt |
| Optimistic local write + durable outbox | **Already the model** for Carry and Draftpad (BUG-29 shared save core); no sqlite outbox needed |
| `TextRenderer` / CoreText for the syllable wipe | **Not sync or uploads; deferred.** No `TextRenderer` use in the repo today; relevant to FEAT-19 `TranscriptLineText.lit`, so noted there, not here |

## The gap (proven by reading both clients)
- Web `putParts` (`library/src/client/gallery.js`, ~6560-6650) keeps `{uploadId, size, parts:[{partNumber, etag}]}` in localStorage after every part. A reload, a suspended Safari tab or a dropped network carries on from the next part. A failure forgets the id only when R2 says it no longer exists.
- Swift `Feed.putParts` (`mobile/FileProviderCore/Core.swift`, merged 03d2e2e) keeps the ids in memory only, and **aborts the upload on any failure** (`action=abort`). A failure or a kill at part 200 of 230 starts again from part 1.
- It runs on `URLSessionConfiguration.default` (Core.swift line 81): iOS may suspend the extension and stop a transfer that a background session would finish. (Not yet proven for a File Provider extension; see P2.)
- tus/TUSKit and Ente solve exactly this: persisted upload state plus an offset to carry on from. R2 multipart already gives the offset (the part list), so **no tus server or new protocol is needed**.

## P1 · Swift resumes like the web (small, no new dependency)
- Before `start`, look for a saved record for this file: key `sha256(path|size|mtime)` → `{uploadId, partSize, parts:[{partNumber, etag}]}`, in the extension's App Group container, written atomically after each part.
- Found: skip the `start`, continue from `parts.count`. R2 answers `NoSuchUpload` (10024) or the record is older than 6 days (R2 drops unfinished uploads after 7): delete the record and start fresh.
- On failure: **keep the record and throw**; abort only when the user cancels or the record expires. The next attempt (the system retries `createItem`) resumes.
- On `complete` success: delete the record. On a 409 (name taken meanwhile): abort and delete.
- Same two states as the web client, so Gallery and the Files app agree.
- Done when: a unit test with a fake session proves (a) resume from part N+1, (b) `NoSuchUpload` restarts, (c) complete deletes the record, (d) failure leaves it. A real check: kill the Files-app upload at about 50 %, relaunch, watch the part numbers continue (log), compare the SHA-256 on R2 with the source.

## P2 · Background transfer (needs a spike first, untested)
- Replace the foreground session with `URLSessionConfiguration.background(withIdentifier:)` + `sharedContainerIdentifier` so a part finishes while the extension is suspended.
- Unknown: whether a File Provider extension is allowed to use a background session on a free Personal Team build, and how the part temp files must be kept until the delegate fires. **Spike one afternoon on the iPhone before committing to it.** If it fails, P1 alone still removes the "start over" cost.

## P3 · Integrity (later, cheap)
- R2's part etag is the MD5 of that part. Compute the MD5 of each part while it is copied to the temp file (already read in 4 MiB blocks) and refuse a mismatch before `complete`. The Ente idea, at the cost of one hash per part. TLS already protects the wire, so this catches only a bad read from disk: low priority.

## Not adopting (and why)
- **Presigned S3 URLs:** see the table. Reopen if the measured Worker request count shows uploads in the top three.
- **tus protocol / TUSKit:** a second upload protocol and a server for it, to get what R2 multipart plus a saved part list already give.
- **Immich / Ente as dependencies or encrypted-album model:** Recense's privacy model is path-sealing on our own hub, not client-side encryption; a change of that kind is its own decision, not an upload fix.
- **pglite / TanStack DB:** a second local database beside files-on-disk; the project's rule is plain open formats.

## Owed / open
- Measure the Worker's real requests per day by route (Cloudflare dashboard); it decides whether presigning ever matters.
- Audit that every immutable-cached image key is content-addressed.
