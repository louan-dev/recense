#!/bin/zsh
# Offsite disks: APFS sparse bundles in gallery-archive/.disks/ hold the Photos library, ~/Library/Messages and
# ~/Library/Mail, so those grow in R2 and not on the internal disk. The Mac keeps only a capped cache per disk.
# The bucket is reached straight through the S3 remote "gallery-archive" (jobs.conf), not the Worker: a rewritten 2 MB
# band must not leave a trash copy, and the Gallery app never lists dot folders at a bucket root.
# One rclone mount per disk: an NFS mount answers one request at a time, so with one shared mount a Photos upload
# backlog stalled Messages for minutes (2026-10-29). Each disk's folder is mounted at ~/.disks/<name>.sparsebundle and
# attached from there at /Volumes/<name>; the ~/Library symlinks and the System Photo Library point at those paths.
# Run by launchd (com.chauphan.disks-mount) through Disks Helper.app: zsh started by launchd itself is refused the
# network mounts ("Operation not permitted").
#  - a disk's rclone gone, or its mount not answering for ~1 minute (rclone's NFS server wedged once under load,
#    2026-10-29: reads hung until the mount was forced off): force that disk off and mount it again. Only bands
#    already uploaded or kept dirty in the cache are safe; the forced detach can lose writes still in flight.
#  - internal disk low: bands not yet uploaded can't leave the cache, so pause the processes filling the disks
#    (iCloud Photos and Messages downloads) until the uploads catch up.
set -u
setopt NO_BG_NICE            # zsh would run the rclone jobs at nice 5
BASE=$HOME/.disks
CACHE=$HOME/Library/Caches/rclone-disks   # each mount keeps its own subtree (vfs/…/.disks/<name>.sparsebundle)
# name : local cache cap [: where the volume mounts, default /Volumes/<name>]. Messages mounts right at
# ~/Library/Messages: its sandboxed database service won't follow a symlink to another volume (it never starts, and
# Messages hangs at launch). The empty folder under that mount is read-only, so nothing lands on the internal disk
# while the disk is away.
DISKS=("Photos Disk:5G" "Messages Disk:2G:$HOME/Library/Messages" "Mail Disk:2G")
vol_of() { local rest=${1#*:}; [[ $rest == *:* ]] && echo "${rest#*:}" || echo "/Volumes/${1%%:*}"; }
LOW_GB=5 HIGH_GB=8
WRITERS=(cloudphotod imagent IMTransferAgent)
export RCLONE_CONFIG=$HOME/.config/rclone/jobs.conf

say() { echo "$(date '+%F %T') $*"; }
notify() { osascript -e "display notification \"$1\" with title \"Offsite disks\"" >/dev/null 2>&1; }
mounted() { mount | grep -q " on $1 "; }

# devices of attached images whose file lives under $BASE
images_here() {
  hdiutil info -plist | /usr/bin/python3 -I -c '
import plistlib, sys
base = sys.argv[1] + "/"
for im in plistlib.loads(sys.stdin.buffer.read()).get("images", []):
    if im.get("image-path", "").startswith(base):
        devs = [e["dev-entry"] for e in im.get("system-entities", []) if "dev-entry" in e]
        if devs: print(min(devs, key=len))
' "$BASE"
}
detach_all() {
  for d in $(images_here); do
    hdiutil detach "$d" >/dev/null 2>&1 || hdiutil detach "$d" -force >/dev/null 2>&1
    say "detached $d"
  done
}
unmount_all() {
  local spec mnt
  for spec in $DISKS; do
    mnt="$BASE/${spec%%:*}.sparsebundle"
    mounted "$mnt" && { umount -f "$mnt" 2>/dev/null || diskutil unmount force "$mnt" >/dev/null 2>&1; }
  done
}
paused=0
pause() { for p in $WRITERS; do pkill -STOP -x $p; done; }
resume() { for p in $WRITERS; do pkill -CONT -x $p; done; paused=0; }
typeset -a PIDS
stop() {
  say "stopping"
  (( paused )) && resume
  detach_all
  (( ${#PIDS} )) && { kill $PIDS 2>/dev/null; wait $PIDS 2>/dev/null; }
  exit ${1:-0}
}
trap 'stop 0' TERM INT

# left over from a run that died: images first (they sit on the mounts), then the mounts
detach_all
unmount_all

start_disk() {  # $1 = index into DISKS
  local name=${DISKS[$1]%%:*} cap=${${DISKS[$1]#*:}%%:*}
  local mnt="$BASE/$name.sparsebundle"
  mkdir -p "$mnt"
  say "mounting $name (cache $cap)"
  /opt/homebrew/bin/rclone nfsmount "gallery-archive:gallery-archive/.disks/$name.sparsebundle" "$mnt" \
    --volname "$name" -o nobrowse -o locallocks \
    --cache-dir "$CACHE" \
    --vfs-cache-mode full --vfs-cache-max-size $cap --vfs-cache-min-free-space 6G --vfs-cache-max-age 720h \
    --vfs-cache-poll-interval 30s --vfs-write-back 10s --dir-cache-time 5m \
    --contimeout 10s --timeout 60s --low-level-retries 10 --retries 3 \
    --log-level NOTICE &
  local pid=$!          # through a plain variable: PIDS[$1]=$! stores the text "$!" in zsh
  PIDS[$1]=$pid
}
# force one disk off (its rclone is gone or wedged) and mount it again; attach_new attaches it once it answers
recover_disk() {
  local name=${DISKS[$1]%%:*}
  local mnt="$BASE/$name.sparsebundle"
  kill -9 ${PIDS[$1]} 2>/dev/null
  local vol=$(vol_of ${DISKS[$1]})
  umount -f "$mnt" 2>/dev/null || diskutil unmount force "$mnt" >/dev/null 2>&1
  mounted "$vol" && hdiutil detach "$vol" -force >/dev/null 2>&1
  unset "probe_pid[$1]"; strikes[$1]=0
  notify "$name stopped answering and was remounted; reopen Photos/Messages/Mail if they show errors"
  start_disk $1
}
# a lookup of a random name must reach rclone (no client cache) and answer within one 20 s round; a probe still
# running at the next round is a strike, three in a row mean the mount is wedged
typeset -A probe_pid strikes
answering() {
  local i=$1 name=${DISKS[$1]%%:*}
  local p=${probe_pid[$i]:-}
  if [[ -n $p ]] && kill -0 $p 2>/dev/null; then
    strikes[$i]=$(( ${strikes[$i]:-0} + 1 ))
  else
    strikes[$i]=0
    stat "$BASE/$name.sparsebundle/.alive-$RANDOM$RANDOM" >/dev/null 2>&1 &
    local sp=$!
    probe_pid[$i]=$sp
  fi
  (( ${strikes[$i]} < 3 ))
}

for i in {1..${#DISKS}}; do start_disk $i; done

# attach every disk whose mount is up and whose volume isn't there yet; runs on each check, so a disk whose mount
# came up late (offline at login) is attached later. A failure is reported once.
typeset -A failed
attach_new() {
  local spec name mnt vol out
  local -a where
  for spec in $DISKS; do
    name=${spec%%:*}; mnt="$BASE/$name.sparsebundle"; vol=$(vol_of $spec)
    mounted "$vol" && continue
    mounted "$mnt" || continue
    where=(); [[ $vol == /Volumes/* ]] || where=(-mountpoint "$vol" -nobrowse)
    if out=$(hdiutil attach -owners on $where "$mnt" 2>&1) && mounted "$vol"; then
      say "attached $vol"
      unset "failed[$vol]"
      # Messages started before its disk was there: restart it so it opens ~/Library/Messages again
      # (by full path: killall matches 16 characters, so it misses IMDPersistenceAgent, which then keeps the old
      # chat.db open)
      [[ $name == "Messages Disk" ]] && { pkill -x imagent; pkill -f IMDPersistenceAgent.xpc; }
    elif [[ -z ${failed[$vol]:-} ]]; then
      failed[$vol]=1
      say "attach of $name did not land on $vol: $out"
      notify "$name did not mount where Photos/Messages/Mail expect it"
    fi
  done
}

for i in {1..60}; do
  n=0; for spec in $DISKS; do mounted "$BASE/${spec%%:*}.sparsebundle" && (( n++ )); done
  (( n == ${#DISKS} )) && break
  sleep 1
done

while :; do
  for i in {1..${#DISKS}}; do
    name=${DISKS[$i]%%:*}
    if ! kill -0 ${PIDS[$i]} 2>/dev/null; then
      say "rclone for $name exited"; recover_disk $i
    elif mounted "$BASE/$name.sparsebundle" && ! answering $i; then
      say "$name not answering for a minute: remounting"; recover_disk $i
    fi
  done
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
