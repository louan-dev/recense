# iCloud backend plan: technical report

**Date:** 2026-10-10. **Owner:** Chau. **Companion:** `sync-matrix.md`, `sync.md`, `cloud-lab-integrations.md`.
**Basis:** web research on 2026-10-10 (rclone docs, icloudpd and icloudpd-rs repos, imessage-exporter, Notability support pages) plus the project files. **Nothing here has been run on your Mac.** Commands are a plan; flags marked *(verify)* should be checked against your installed versions.

## 1. Summary

1. The "mimic a browser logging into iCloud" idea is real and already built: `rclone` (`iclouddrive` backend, since v1.69) does SRP login, 2FA and trust-token reuse for **Drive and Photos**; `icloudpd` and `icloudpd-rs` do the same for Photos. Writing a fourth client from scratch adds risk and little value.
2. The part nobody has done well is not the login, it is **what happens after**: a verified, versioned, read-only mirror in your own storage that other apps can browse. That is where this project can be distinctive (section 9).
3. Three of your services do not need reverse engineering: Calendar, Contacts and Mail have open protocols. iMessage has no remote route at all; it is a local database. Notability has a supported one-way export.
4. **Notability is handled differently on purpose.** Its container is a live mirror of your iCloud state in a proprietary format. We never read from it while the app syncs, never write, and rely on the app's own Auto-Backup instead.
5. Everything is one-way and `copy`-only. No `sync`, no `move`, no `mount` with write access.

## 2. Principles and the failure each one prevents

| Principle | Prevents |
|---|---|
| Apple's side is never written to | A buggy client deleting or corrupting notes on every device |
| Prefer a supported export over a private API | Breakage when Apple changes an endpoint |
| Work on copies of local databases, never the live file | A locked or half-written `chat.db` or a corrupted container |
| `rclone copy` only, with `--max-delete` where any delete is possible | A drive or session that comes back empty wiping the mirror |
| Credentials stay on the Mac (login keychain), not on a VPS | A server holding your Apple password and trust token |
| Every job names its prefix | The cleanup-cron mistake in `cloud-lab-integrations.md` rule 12 |
| Verify, then trust | A copy that silently skipped files |

## 3. Safety gate for Notability (do this first)

Your notes are academic records. Before any other step:

1. **Arq snapshot** of `~/Library/Mobile Documents/` (or at least the Notability container) to a destination that is not iCloud. This is a plain read, done by Arq, not by us. Confirm the snapshot restores a sample file.
2. **In-app export**: Notability > Library > select all > Share > export as PDF (and Note) to a folder on the SanDisk. Slow, but it is the supported, human-readable copy.
3. **Check eviction and sync state.** With iCloud full, some files may be placeholders that were never fully downloaded. A backup of placeholders is not a backup. Open Notability on each device and confirm every subject loads, and check the iCloud storage warning is not blocking uploads from the iPad. If the iPad holds notes that never reached the Mac, those exist *only* on the iPad until they sync. Free iCloud space (or enable Notability Auto-Backup from the iPad) before migrating anything.
4. **Do not** open, move, rename or `rsync --delete` anything inside the container. Do not run any tool whose write path could reach it.

## 4. Phase 1: read-only inventory (no network, no Apple login)

Goal: know what exists before choosing tools. All commands only list or read.

```
ls -la "$HOME/Library/Mobile Documents/"                         # all iCloud containers
du -sh "$HOME/Library/Mobile Documents/"*/ 2>/dev/null | sort -h
ls -ld "$HOME/Pictures/"*.photoslibrary                          # default Photos library location
ls -la "$HOME/Library/Messages/" | head                          # chat.db, Attachments (needs Full Disk Access)
```

For eviction state, files shown with a `.icloud` suffix or as "dataless" are not downloaded *(verify the marker on your macOS version)*. Record counts per container in a text file; it becomes the baseline for verification.

Note on the paths in your message: the Obsidian container is `iCloud~md~obsidian` (with tildes) and the Notability one is `ZP9ZJ4EF3S~com~gingerlabs~Notability`. Confirm both by listing, since the message had them garbled.

## 5. Phase 2: iCloud Drive and Photos through rclone

**What it is.** rclone's `iclouddrive` backend authenticates the way the iCloud web interface does: an SRP key exchange, a 2FA prompt on a trusted device (or SMS), then a trust token. rclone's documentation says the trust token lasts about 30 days, after which `rclone reconnect` is needed. Regular Apple password plus 2FA only; app-specific passwords are not accepted. The same backend reaches Photos with `--iclouddrive-service photos` (paths like `PrimarySync/All Photos/`).

**Advanced Data Protection.** Documentation conflicts. An older page says ADP must be off; the current page says ADP is supported if *Access iCloud Data on the Web* is on, requesting extra cookies that you approve on a trusted device. Check which version you have (`rclone version`), and check whether ADP is enabled on your account. If a login fails with a "Missing PCS cookies" style error, that is this approval flow. Do not turn ADP off just to make a backup work without deciding that on its own merits: it lowers your account's protection.

**Plan.**

```
rclone config                       # new remote "icloud" (type iclouddrive); do 2FA once
rclone lsd icloud:                  # list only
rclone copy icloud:  gallery-main:icloud/drive   --dry-run --max-delete 0 -vv
```

Then the same with `--iclouddrive-service photos` into `gallery-main:icloud/photos`. Run without `--dry-run` only after reading the dry run. Use `copy` (never `sync`). Throttle (`--transfers 2 --tpslimit 2`) to look less like abuse; repeated failed logins can lock the Apple Account.

**Photos alternative that avoids the web API.** If *Download Originals* is on and the library is fully local, export from the library on the Mac instead (Photos' *Export Unmodified Originals*, or the open-source `osxphotos` tool *(verify)*). It is independent of Apple's web endpoints, so it survives API changes. Use rclone/icloudpd only for what is not local. Never copy into or out of the `.photoslibrary` bundle by hand.

**Known weaknesses of this route (be honest about them).**
- Unofficial: Apple can change endpoints without notice; rclone lists the backend as lowest-support tier.
- Session expiry every ~30 days means a calendar reminder to re-authenticate.
- No evidence in the docs that the backend exposes content hashes, so verification is by size and count *(verify)*; keep your own SHA-256 manifest of what you copy.
- Live Photos, edited versions and Shared Library items can be split or missing; icloudpd has flags for these, and you should check a sample.
- iCloud Drive "Optimize Mac Storage" does not matter for the web route, but it does for any local-folder copy.

## 6. Phase 3: Notability (supported, one-way)

**Your setup (confirmed): iCloud Sync, kept on purpose.** You are a Classic (pre-subscription) user and stay on iCloud Sync; Notability Cloud is a separate system and iCloud Sync is not available inside it, so switching would be a migration you do not want. Nothing in this project changes how Notability syncs. We only add a one-way copy beside it. Notability's help describes Classic as including iCloud syncing and third-party backup for life; the wording in its FAQ versions is inconsistent, so confirm both toggles exist in your app (Library > Gear > Connected Services).

What that means in practice:
- **Pick one device for Auto-Backup.** With several devices on iCloud Sync, Auto-Backup can run on only one. Choose the device whose Library is most complete and current (check the Mac and iPad show the same subjects and note counts first; if only the iPad has everything, use the iPad).
- **iCloud Sync is two-way and deletions are unrecoverable.** A note deleted on any device is deleted everywhere, and Notability says it cannot be recovered from iCloud. The Auto-Backup copy is not deleted when the original is, so it is your safety net.
- **Full iCloud is the live risk.** Notability's help has a troubleshooting entry for full-storage errors. Until space is freed, edits on one device may not reach the others. Free space (Settings > Apple Account > iCloud > Manage Storage shows what is using it) or upgrade the plan before relying on any of the steps below.
- **Version history on our side.** Classic keeps 7 days of version history. If Ledger journals the folder Auto-Backup writes to, each re-exported note becomes a retained version, giving you history far beyond 7 days.

Facts from Notability's help: Auto-Backup/Third-Party Backup supports WebDAV, Dropbox, Google Drive, OneDrive and Box; it is one-way; deleting a note does not delete the backup; password-protected notes are skipped by default; formats are PDF, RTF or Note (with or without recordings); all notes are backed up when you enable it or change its settings; with several devices on iCloud sync, Auto-Backup can run on only one. iCloud Sync and Notability Cloud are mutually exclusive.

**Plan.**
1. Add a small **WebDAV endpoint** to the Gallery Worker (for example `/dav/notability/`), writing to `gallery-main` under `notability/`. This keeps the destination under your control and gives Notability exactly the interface it supports, with no private API. Basic auth with its own revocable app password; never reuse the upload password.
2. Choose **Note** *and* **PDF** as formats so you have the restorable file and a readable one. Include recordings if the academic material needs them.
3. Because the backup never deletes, the R2 copy is append-only from Notability's side; keep the Worker's handler from honoring `DELETE` and overwrites for that prefix *(design decision: recommended)*.
4. Test with one subject first, restore it into a scratch Notability install or a second device if possible, and only then enable it for everything.
5. Upload limits: the Worker body limit (100 MB on Free/Pro) applies to WebDAV `PUT`; large recordings may fail. Either exclude recordings at first or give the endpoint a multipart path (the rclone-to-R2 route in `cloud-lab-integrations.md` F11).

**What not to do.** Do not try to reverse engineer the container's file format to extract pages. Even if possible, the payoff is small compared to the risk to the only copy of your coursework, and the export formats already give you PDF.

## 7. Phase 4: Calendar, Contacts, Mail and attachments (standards)

| Data | Method | Notes |
|---|---|---|
| Calendar | CalDAV against iCloud with an app-specific password; one-time Calendar Archive export | Pull `.ics` read-only; the new CalDAV Worker (`sync.md`) is the long-term home. Take the archive *before* turning off iCloud Calendars |
| Contacts | CardDAV likewise; Contacts Archive export | Same |
| Mail | IMAP (`imap.mail.me.com`) with an app-specific password, pulled by a read-only tool such as `mbsync` *(verify config)* | Attachments are inside the messages. Also copy the local Mail store as a second route |
| Messages in Mail attachments / Mail Drop | Part of the above | Mail Drop links expire after about 30 days; download any you need |

The 2FA-less, app-password route is actually the *safest* in this project, because the credential is scoped and revocable.

## 8. Phase 5: iMessage and its attachments

There is no web endpoint and no safe way to "mimic a browser": Messages in iCloud is end-to-end encrypted. What exists is on your Mac:

- `~/Library/Messages/chat.db` (SQLite) and `~/Library/Messages/Attachments/`.
- `imessage-exporter` (ReagentX) reads that database read-only, exports to TXT/HTML, handles replies, reactions, edited messages and attachments, and runs diagnostics. It needs **Full Disk Access** for your terminal.
- Alternative for the iPhone's own copy: an iPhone backup, readable with the same tool via `-p <backup path> -a iOS`.

**Plan.** Quit Messages. Copy `chat.db` (plus `-wal` and `-shm` files) and `Attachments/` to a working folder. Run the exporter against the copy. Then archive the *exports* and the *raw copy* to R2 under a prefix that is private and never exposed through a public link.

**Caveats.** The Mac's database only has what Messages in iCloud has downloaded; with a full iCloud, history can be incomplete and attachments may be missing. In Messages > Settings > iMessage, check the sync state and download attachments before copying. This route also contains other people's private messages: keep the mirror private, don't share it, and do not send it through any cloud AI service without thinking about that.

## 9. What would make this distinctive

Not a new login hack. The gaps in today's tools, and what to build on them:

1. **Content-addressed, verified mirror.** icloudpd keeps a local state database; rclone keeps nothing. Add a manifest (path, size, mtime, SHA-256 computed after download) stored in R2 next to the data. A nightly job compares it to the source and flags drift. This is the "scrub" from `sync.md` applied to iCloud.
2. **Append-only history.** Mirrors that follow Apple's deletions are not backups. Keep deletions as tombstones in the manifest and never remove objects (R2 lifecycle only for `trash/`).
3. **Unified browse layer.** One Gallery `/main/icloud/` view over Drive, Photos, Notability exports, Calendar archives and Message exports, using the viewer you already built. That is the "iCloud mirror" you asked for, and it also serves Android and Windows.
4. **Re-auth as a product feature.** The 30-day trust-token expiry is the main operational failure. Put a reminder event (`[URGENT]`, scored by Sill) and a `/health` field `icloud_session_days_left` on the Worker.
5. **Apple-change canary.** A tiny weekly job that lists one known folder and one known photo; failure alerts you before a full backup silently stops.

## 10. Infrastructure answers (from your first message)

- **Reverse proxy:** not needed. The Cloudflare Worker is already the front door.
- **Tailscale:** useful only to reach the Mac or SanDisk remotely from your own devices; free for personal use *(verify)*. Not part of the data path.
- **Vultr VPS:** not recommended for this. The jobs are infrequent and run fine from `launchd` on the Mac, where the Apple credentials already live. A VPS would hold your Apple trust token and add a server to maintain. Reconsider only if the Mac is off for long periods; a small instance then costs a few dollars a month *(verify pricing)* and should hold only R2 credentials, not Apple ones.
- **Arq:** keep it. It is your independent copy of the mirror and of the Mac. Point it at the mirror and the Notability snapshot; test a restore.

## 11. Endpoint recommendation

For `gallery.improvdiplomat.workers.dev/main`:

- **Ingest does not go through the Worker.** `rclone` writes straight to the `gallery-main` bucket under `icloud/…` (own token, scoped to that bucket).
- **Browse:** `/main/icloud/…` read-only, same Access gate as `/main`.
- **Notability only:** `/dav/notability/` as a separate, narrowly scoped route with its own app password and no delete.
- If WebDAV traffic grows or needs a WAF exception, move it to its own hostname (as `cloud-lab-integrations.md` section 3.1 already recommends for DAV).

One small inconsistency found: the Gallery README's Quick Action snippet points at `gallery/chau/copy-public-link.sh`, while its layout lists `mac/copy-public-link.sh`. Fix whichever is wrong during the rename.

## 12. Risks and how they are handled

| Risk | Handling |
|---|---|
| Apple changes the web API | Prefer supported routes; canary job; local-library exports as fallback |
| Account lockout from repeated logins | One trust token, throttled; no retries loop; no automated re-login |
| Notability data loss | Section 3 gate; no touching the container; test-restore |
| Credentials leak | Login keychain on the Mac; no Apple creds on Worker or VPS; scoped R2 tokens |
| Private messages exposed | Private prefix; no public links; not shared |
| Terms of service | rclone and icloudpd are widely used but unofficial; this is your own data on your own account, but Apple does not endorse the method |
| Incomplete source (iCloud full) | Free space first; verify sample files open |

## 13. Order of work

1. Section 3 gate (snapshot, in-app export, eviction check).
2. Section 4 inventory; save counts.
3. Section 7 (Calendar, Contacts, Mail): lowest risk, quick wins.
4. Section 5 Drive copy, then Photos.
5. Section 6 WebDAV endpoint, one subject, then all.
6. Section 8 iMessage.
7. Section 9 manifest, scrub, canary, browse layer.

## 14. Not covered here

The Developer cleanup and SanDisk/Ollama download, and the Sill panel and player changes in your message, are separate work. I have not touched them, and I have no access to your folders from this conversation, so nothing was deleted.
