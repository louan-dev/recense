# Offsite disks: Photos, Messages and Mail stores in R2

Three APFS disk images (sparse bundles, 2 MB bands) live in `gallery-archive/.disks/`:
`Photos Disk`, `Messages Disk`, `Mail Disk`. The Mac keeps only a cache (`~/Library/Caches/rclone-disks`,
4 GB cap, gives way under 6 GB free). Login item `com.chauphan.disks-mount` (`bin/disks-mount.zsh`, log
`~/Library/Logs/disks-mount.log`) mounts the bucket folder at `~/.disks` and attaches each image at
`/Volumes/<image name>`. The Gallery app never lists `.disks/` (dot folder at the bucket root).

- **Needs internet** to open: offline at login, the disks don't mount and Photos/Messages/Mail can't reach their data.
- **One Mac only**: never attach these images from a second Mac.
- **Low disk**: under 5 GB free the script pauses iCloud Photos/Messages downloads (notification) and resumes at 8 GB,
  because data not yet uploaded can't leave the cache.
- iCloud stays the master copy. A damaged disk is rebuilt from iCloud; only items not yet uploaded to iCloud are at risk.

## Owner steps (GUI)
1. **Photos**: quit Photos. Hold Option while opening Photos, pick `Photos Disk › Photos Library.photoslibrary`.
   Photos › Settings › General › **Use as System Photo Library**. Settings › iCloud: iCloud Photos on,
   Optimize Mac Storage on. Once it looks right, the old `~/Pictures/Photos Library.photoslibrary` can go
   (a tar of it is in `gallery-main/files/Photos/`).
2. **Messages**: System Settings › Notifications › Messages › Allow notifications **off**.
   Then Messages › Settings › iMessage › **Enable Messages in iCloud**.
3. **Mail**: Mail › Settings › Accounts › iCloud › Download Attachments: **All**.

## Undo (per app)
- Messages / Mail: quit the app, `rm ~/Library/Messages` (removes only the link), then
  `mv ~/Library/Messages.local-2026-10-29 ~/Library/Messages`. Same with `Mail`.
- Photos: Option-open Photos, pick `~/Pictures/Photos Library.photoslibrary`, Use as System Photo Library.

## Add a disk
`hdiutil create -size <N>g -type SPARSEBUNDLE -fs APFS -volname "<Name> Disk" -imagekey sparse-band-size=4096 ~/.disks/"<Name> Disk.sparsebundle"`
(the file name must match the volume name). The next start of the login item attaches it.
