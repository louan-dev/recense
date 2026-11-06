# Offsite disks: Photos, Messages and Mail stores in R2

Three APFS disk images (sparse bundles, 2 MB bands) live in `gallery-archive/.disks/`:
`Photos Disk`, `Messages Disk`, `Mail Disk`. The Mac keeps only a cache per disk (`~/Library/Caches/rclone-disks`:
Photos 5 GB, Messages 2 GB, Mail 1 GB; each gives way under 6 GB free). Login item `com.chauphan.disks-mount` runs
`bin/disks-mount.zsh` through `~/Applications/Disks Helper.app` (log `~/Library/Logs/disks-mount.log`): one rclone
mount per disk at `~/.disks/<name>.sparsebundle`. Photos Disk and Mail Disk attach at `/Volumes/<name>`
(`~/Library/Mail` is a symlink to `/Volumes/Mail Disk/Mail`). **Messages Disk mounts right at `~/Library/Messages`**:
Messages' database service won't follow a symlink to another volume (it never starts and Messages hangs at launch).
The folder under that mount is empty and read-only, so nothing lands on the internal disk while the disk is away.
Mounting there needs **Full Disk Access for Disks Helper** (`~/Library/Messages` is privacy-protected).
The Gallery app never lists `.disks/` (dot folder at the bucket root).
- **Watchdog**: a disk whose rclone exits, or whose mount stops answering for ~1 minute (seen once under heavy load:
  rclone's NFS server dropped its connection and every read hung), is forced off and mounted again; a notification
  says so. Reopen Photos/Messages/Mail if they then show errors.
- **Big uploads slow the disk being written**: a disk's mount answers one request at a time, so while a large batch
  of new data uploads (~4 MB/s), reading data that isn't cached waits behind it. One mount per disk keeps Photos from
  stalling Messages and Mail.

- **Needs internet** to open: offline at login, the disks don't mount and Photos/Messages/Mail can't reach their data.
- **One Mac only**: never attach these images from a second Mac.
- **Low disk**: under 5 GB free the script pauses iCloud Photos/Messages downloads (notification) and resumes at 8 GB,
  because data not yet uploaded can't leave the cache.
- iCloud stays the master copy. A damaged disk is rebuilt from iCloud; only items not yet uploaded to iCloud are at risk.

## Owner steps (GUI)
0. **Disks Helper**: System Settings › Privacy & Security › Full Disk Access › + › `~/Applications/Disks Helper.app`
   (Shift-Cmd-G, `~/Applications`), switch it on. Without it, Messages Disk can't mount at login.
1. **Photos**: quit Photos. Hold Option while opening Photos, pick `Photos Disk › Photos Library.photoslibrary`.
   Photos › Settings › General › **Use as System Photo Library**. Settings › iCloud: iCloud Photos on,
   Optimize Mac Storage on. Once it looks right, the old `~/Pictures/Photos Library.photoslibrary` can go
   (a tar of it is in `gallery-main/files/Photos/`).
2. **Messages**: System Settings › Notifications › Messages › Allow notifications **off**.
   Then Messages › Settings › iMessage › **Enable Messages in iCloud**.
3. **Mail**: Mail › Settings › Accounts › iCloud › Download Attachments: **All**.

## Undo (per app)
- Messages: remove `"Messages Disk:…"` from `DISKS` in `bin/disks-mount.zsh` first (else the login item mounts it over
  the folder again), quit Messages, `hdiutil detach ~/Library/Messages`, `rmdir ~/Library/Messages`,
  `mv ~/Library/Messages.local-2026-10-29 ~/Library/Messages`, then `pkill -x imagent; pkill -f IMDPersistenceAgent.xpc`.
- Mail: quit Mail, `rm ~/Library/Mail` (removes only the link), `mv ~/Library/Mail.local-2026-10-29 ~/Library/Mail`.
- Photos: Option-open Photos, pick `~/Pictures/Photos Library.photoslibrary`, Use as System Photo Library.

## Add a disk
Create it on any rclone mount of `gallery-archive/.disks/` (file name = volume name), e.g. from a temporary
`rclone nfsmount gallery-archive:gallery-archive/.disks <dir>`:
`hdiutil create -size <N>g -type SPARSEBUNDLE -fs APFS -volname "<Name> Disk" -imagekey sparse-band-size=4096 <dir>/"<Name> Disk.sparsebundle"`.
Then add `"<Name> Disk:<cache cap>"` to `DISKS` in `bin/disks-mount.zsh` and restart the login item
(`launchctl kickstart -k gui/$(id -u)/com.chauphan.disks-mount`).
