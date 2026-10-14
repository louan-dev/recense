# Sync Matrix: Apple services, what leaves them, and how

**Status:** rewritten 2026-10-10. Replaces the 2026-10-08 version. Companion to `icloud-backend-technical-report.md`.
**Rule for every row:** the Mac and the cloud copy are both *copies*. Apple's side is never written to by this project.

## 1. The matrix

| Service | Where the data really lives | Supported way out (no reverse engineering) | Browser-mimic route (unofficial) | Verdict |
|---|---|---|---|---|
| **iCloud Drive** (incl. Obsidian vault, Draftpad) | iCloud container folders under `~/Library/Mobile Documents/` | Local folder (files may be evicted placeholders until downloaded) | `rclone` `iclouddrive` backend (SRP login, 2FA, trust token ~30 days) | **Use rclone.** One-way copy to R2 |
| **iCloud Photos & videos** | iCloud, mirrored to the local Photos library if "Download Originals" is on | Export from the local library (Photos "Export Unmodified Originals", or `osxphotos`; verify) | `rclone --iclouddrive-service photos`; `icloudpd` (Python) and `icloudpd-rs` | **Local export first, rclone/icloudpd for what is not local** |
| **Notability** (Chau: *iCloud Sync*, Classic/legacy user, kept on purpose) | Two different backends exist: *iCloud Sync* (container `ZP9ZJ4EF3S~com~gingerlabs~Notability`) or *Notability Cloud* (Ginger Labs' own servers). They are mutually exclusive. This setup stays on iCloud Sync | **Auto-Backup / Third-Party Backup** to WebDAV, Dropbox, Google Drive, OneDrive or Box (one-way; deleting a note never deletes the backup) | None worth building. The container holds Notability's own format and is a live mirror | **Keep iCloud Sync. Add the in-app Auto-Backup (one device only) to a WebDAV endpoint we run.** Never touch the container |
| **Apple Calendar** | iCloud CalDAV | Standard CalDAV (`caldav.icloud.com`) with an app-specific password; also Calendar > File > Export > Calendar Archive | Not needed | **Standards route.** Read-only pull of `.ics`; the new CalDAV Worker is the destination (see `sync.md`) |
| **Contacts** | iCloud CardDAV | CardDAV with an app-specific password; Contacts > File > Export > Contacts Archive | Not needed | Standards route |
| **Mail and email attachments** | iCloud Mail (IMAP) and Mail.app's local store | IMAP (`imap.mail.me.com`) with an app-specific password; a read-only IMAP puller (`mbsync`) | Not needed | **Standards route.** Attachments come with the messages |
| **iMessage** (the bubbles) and **iMessage attachments** | Local `~/Library/Messages/chat.db` plus `~/Library/Messages/Attachments/`, fed by Messages in iCloud | `imessage-exporter` (reads `chat.db` read-only; needs Full Disk Access); iPhone backups | **None.** Messages in iCloud is end-to-end encrypted with keys in iCloud Keychain; there is no web endpoint to mimic | **Local database only.** Copy first, export from the copy |
| **iCloud attachments in general** (Mail Drop, Messages, Notes) | Same containers as above | Same routes as above | n/a | Covered by the rows above |
| **Obsidian** | Plain Markdown files | Any file sync; Obsidian Sync; Git; Syncthing; S3/WebDAV community plugins (verify current options) | n/a | Plain files are the easiest case. See report section 8 |
| **DEVONthink** | Local database | WebDAV, Dropbox, local sync store, Bonjour; CloudKit | n/a | WebDAV to our endpoint is a candidate (verify) |

## 2. Corrections to the previous matrix

- **Notability.** Chau syncs through iCloud and wants to keep it that way, so there is no migration at all. The old matrix said "migrate to Notability Cloud". Notability's own help says iCloud Sync is unavailable in Notability Cloud, so they are separate worlds. Switching is a data migration, not a toggle. Do not do it as part of this project.
- **Reverse engineering.** The previous document implied every service needs it. Only iCloud Drive and Photos do, and the browser-mimic route is already implemented by `rclone` and `icloudpd`. Calendar, Contacts and Mail have open protocols. iMessage has no remote route at all.
- **Android and Windows.** iCloud Photos has no native client there; web only. This project's R2 mirror is what makes the data reachable from them.
- Removed the stray `[cite: n]` markers.

## 3. Direction of travel

```
Apple (iCloud / local)  ──read-only──▶  R2 mirror (gallery-main, prefix icloud/…)  ──▶  Arq + second copy
                                              ▲
Notability Auto-Backup ──WebDAV──▶  Worker /dav ──┘      (Apple is not involved)
```

Nothing flows back to Apple. Anything that must be edited elsewhere is edited in the mirror and stays there.

## 4. Next steps

1. Take the safety snapshot (report section 3) before any other command.
2. Run the read-only inventory (report section 4).
3. Configure `rclone` `iclouddrive`, and copy the Drive and Photos trees to R2 with `copy` only.
4. Stand up the Worker WebDAV endpoint and point Notability's Auto-Backup at it.
5. Pull Calendar, Contacts and Mail through their protocols.
6. Copy `chat.db` and `Attachments/`, export from the copy.
