#!/bin/zsh
# The always-on Chauphan mount: gallery-archive/chauphan/ through the Worker (/main/nc-archive/, Access, trash, chunked
# uploads) at ~/.chauphan, shown in Finder through ~/Cloud/Chauphan. Run by launchd (com.chauphan.archive-mount): it
# keeps rclone up, and rclone's timeouts turn a lost connection into an error instead of a frozen Finder.
# Unlike Gallery.app there is no Touch ID and no wipe on lock (spec: Decided 3). The cache is its own, on the internal
# disk: 2 GB, and it gives way before free space drops under 3 GB.
# Dot names (Finder's ._* and .DS_Store) stay out of it: the Worker refuses them, and rclone would retry them forever.
# The token is this Mac's Access service token from the Keychain (gallery-access), handed to rclone in its environment:
# never in a file, an argument or the log.
set -u
MNT=$HOME/.chauphan
URL=https://gallery.improvdiplomat.workers.dev/main/nc-archive/dav/files/owner/chauphan/

# launchd starts this only once rclone has exited, so a mount still listed is left over from it and answers nothing:
# clear it before mounting again
if mount | grep -q " on $MNT "; then
  echo "$(date) clearing a stale mount"
  umount -f "$MNT" 2>/dev/null || diskutil unmount force "$MNT" >/dev/null 2>&1
fi
mkdir -p "$MNT" "$HOME/Cloud"
[[ -e $HOME/Cloud/Chauphan ]] || ln -s "$MNT" "$HOME/Cloud/Chauphan"
[[ -e $HOME/Cloud/Gallery ]] || ln -s "$HOME/.gallery" "$HOME/Cloud/Gallery"

ID=$(security find-generic-password -s gallery-access -a client-id -w) || { echo "$(date) no gallery-access client-id in the Keychain"; exit 1; }
SEC=$(security find-generic-password -s gallery-access -a client-secret -w) || { echo "$(date) no gallery-access client-secret in the Keychain"; exit 1; }
export RCLONE_WEBDAV_HEADERS="CF-Access-Client-Id,$ID,CF-Access-Client-Secret,$SEC"
unset ID SEC
export RCLONE_CONFIG=/dev/null

echo "$(date) mounting"
exec /opt/homebrew/bin/rclone nfsmount ":webdav,url='$URL',vendor=nextcloud:" "$MNT" \
  --volname Chauphan -o nobrowse -o locallocks \
  --cache-dir "$HOME/Library/Caches/rclone-archive" \
  --vfs-cache-mode full --vfs-cache-max-size 2G --vfs-cache-min-free-space 3G --vfs-cache-max-age 168h \
  --vfs-write-back 5s --dir-cache-time 1h \
  --exclude '.*' \
  --contimeout 10s --timeout 30s --low-level-retries 3 --retries 3 \
  --log-level NOTICE
