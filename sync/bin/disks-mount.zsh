#!/bin/zsh
# Offsite disks: APFS sparse bundles in gallery-archive/.disks/ hold the Photos library, ~/Library/Messages and
# ~/Library/Mail, so those grow in R2 and not on the internal disk. The Mac keeps only a capped cache.
# The bucket is reached straight through the S3 remote "gallery-archive" (jobs.conf), not the Worker: a rewritten 2 MB
# band must not leave a trash copy, and the Gallery app never lists dot folders at a bucket root.
# Image file name = volume name ("Messages Disk.sparsebundle" mounts at /Volumes/Messages Disk), because the
# ~/Library symlinks and the System Photo Library point at those paths.
# Run by launchd (com.chauphan.disks-mount): mount, attach every image, then watch.
#  - rclone gone: detach the images (their bytes live behind it) and exit, so launchd starts over.
#  - internal disk low: bands not yet uploaded can't leave the cache, so pause the processes filling the disks
#    (iCloud Photos and Messages downloads) until the uploads catch up.
set -u
MNT=$HOME/.disks
CACHE=$HOME/Library/Caches/rclone-disks
LOW_GB=5 HIGH_GB=8
WRITERS=(cloudphotod imagent IMTransferAgent)
export RCLONE_CONFIG=$HOME/.config/rclone/jobs.conf

say() { echo "$(date '+%F %T') $*"; }
notify() { osascript -e "display notification \"$1\" with title \"Offsite disks\"" >/dev/null 2>&1; }

# devices of attached images whose file lives under $MNT
images_here() {
  hdiutil info -plist | /usr/bin/python3 -I -c '
import plistlib, sys
mnt = sys.argv[1] + "/"
for im in plistlib.loads(sys.stdin.buffer.read()).get("images", []):
    if im.get("image-path", "").startswith(mnt):
        devs = [e["dev-entry"] for e in im.get("system-entities", []) if "dev-entry" in e]
        if devs: print(min(devs, key=len))
' "$MNT"
}
detach_all() {
  for d in $(images_here); do
    hdiutil detach "$d" >/dev/null 2>&1 || hdiutil detach "$d" -force >/dev/null 2>&1
    say "detached $d"
  done
}
paused=0
pause() { for p in $WRITERS; do pkill -STOP -x $p; done; }
resume() { for p in $WRITERS; do pkill -CONT -x $p; done; paused=0; }
RC=0
stop() {
  say "stopping"
  (( paused )) && resume
  detach_all
  (( RC )) && { kill $RC 2>/dev/null; wait $RC; }
  exit 0
}
trap stop TERM INT

# left over from a run that died: images first (they sit on the mount), then the mount
detach_all
if mount | grep -q " on $MNT "; then
  say "clearing a stale mount"
  umount -f "$MNT" 2>/dev/null || diskutil unmount force "$MNT" >/dev/null 2>&1
fi
mkdir -p "$MNT"

say "mounting"
/opt/homebrew/bin/rclone nfsmount gallery-archive:gallery-archive/.disks "$MNT" \
  --volname Disks -o nobrowse -o locallocks \
  --cache-dir "$CACHE" \
  --vfs-cache-mode full --vfs-cache-max-size 4G --vfs-cache-min-free-space 6G --vfs-cache-max-age 720h \
  --vfs-cache-poll-interval 30s --vfs-write-back 10s --dir-cache-time 5m \
  --contimeout 10s --timeout 60s --low-level-retries 10 --retries 3 \
  --log-level NOTICE &
RC=$!
for i in {1..60}; do mount | grep -q " on $MNT " && break; sleep 1; done
mount | grep -q " on $MNT " || { say "mount did not come up"; kill $RC 2>/dev/null; exit 1; }

# attach every image not attached yet; runs on each check, so an image that wasn't listed yet (offline at login,
# a new disk) gets attached later. A failure is reported once.
typeset -A failed
attach_new() {
  local img vol out
  local imgs=("$MNT"/*.sparsebundle(N))
  if (( ! ${#imgs} )) && [[ -z ${failed[none]:-} ]]; then
    failed[none]=1
    say "no images visible in $MNT: $(ls -la "$MNT" 2>&1 | head -4 | tr '\n' ' ')"
  fi
  for img in $imgs; do
    vol=/Volumes/${img:t:r}
    mount | grep -q " on $vol " && continue
    if out=$(hdiutil attach -owners on "$img" 2>&1) && mount | grep -q " on $vol "; then
      say "attached $vol"
      unset "failed[$vol]"
      # Messages started before its disk was there: restart it so it opens ~/Library/Messages again
      [[ $vol == "/Volumes/Messages Disk" && -L $HOME/Library/Messages ]] && killall imagent IMDPersistenceAgent 2>/dev/null
    elif [[ -z ${failed[$vol]:-} ]]; then
      failed[$vol]=1
      say "attach of ${img:t} did not land on $vol: $out"
      notify "${img:t:r} did not mount where Photos/Messages/Mail expect it"
    fi
  done
}

while kill -0 $RC 2>/dev/null; do
  attach_new
  free=$(( $(df -k "$HOME" | awk 'NR==2{print $4}') / 1048576 ))
  if (( free < LOW_GB )); then
    pause
    (( paused )) || { say "paused ${WRITERS[*]}: ${free} GB free"; notify "Paused iCloud Photos/Messages downloads: under ${LOW_GB} GB free until uploads catch up"; }
    paused=1
  elif (( paused && free >= HIGH_GB )); then
    resume; say "resumed: ${free} GB free"
  fi
  sleep 20 & wait $!
done
say "rclone exited"
(( paused )) && resume
detach_all
exit 1
