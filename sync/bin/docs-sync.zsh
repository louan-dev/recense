#!/bin/zsh
# docs-sync.zsh: every readable or editable document on this Mac, in one place: Gallery Main › Docs (gallery notes
# 20261029 item 42). Seen in the Gallery app on iPhone/iPad, Gallery in Finder and Files, and the website.
#   Two-way (rclone bisync): Obsidian vault, iCloud Drive, Documents, Desktop, Downloads, Temporary.
#     An edit on either side reaches the other at the next pass; same file edited on both → both kept.
#   One-way (copy, never deletes): Voice Memos → Docs/Recordings, Developer → Docs/Developer, Notability's PDF backups → Docs/Notability.
#   Docs/INDEX.md lists everything, by source.
# Writes go through the Worker's WebDAV with this Mac's Access token (Keychain gallery-access), so every file Gallery
# replaces or deletes goes to Gallery's trash; files a pass would delete on the Mac are kept in ~/.docs-sync/kept.
#   docs-sync.zsh [--dry-run] [--resync] [--only NAME]
# launchd (com.chauphan.docs-sync) runs it every 10 minutes through Disks Helper (Full Disk Access).
set -u
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export RCLONE_CONFIG=${RCLONE_CONFIG:-$HOME/.config/rclone/jobs.conf}   # only for Notability's S3 source
HERE=${0:A:h}
STATE=$HOME/.docs-sync
CONF=${HERE:h}/config
DRY=() RESYNC=0 ONLY=
while (( $# )); do case $1 in
  --dry-run) DRY=(--dry-run) ;; --resync) RESYNC=1 ;; --only) ONLY=$2; shift ;;
  *) print -u2 "usage: docs-sync.zsh [--dry-run] [--resync] [--only NAME]"; exit 2 ;;
esac; shift; done

notify() { /usr/bin/osascript -e "display notification \"$1\" with title \"Docs sync\"" >/dev/null 2>&1; }
log() { print "$(date -u +%FT%TZ) $*"; }

mkdir -p $STATE/{bisync,kept,state}
# one pass at a time: launchd can start one while a long first upload is still running
LOCK=$STATE/lock
if ! mkdir $LOCK 2>/dev/null; then
  if kill -0 "$(cat $LOCK/pid 2>/dev/null)" 2>/dev/null; then log "skip: a pass is running"; exit 0; fi
  print $$ > $LOCK/pid   # the last pass died; take its lock over
else
  print $$ > $LOCK/pid
fi
trap 'rm -f $LOCK/pid; rmdir $LOCK 2>/dev/null' EXIT

# Main through the Worker (Access, trash, versions, chunked uploads); the token never leaves the Keychain otherwise
ID=$(security find-generic-password -s gallery-access -a client-id -w 2>/dev/null)
SEC=$(security find-generic-password -s gallery-access -a client-secret -w 2>/dev/null)
[[ -n $ID && -n $SEC ]] || { log "no Access token in the Keychain (gallery-access)"; notify "no Gallery token in the Keychain"; exit 1; }
export RCLONE_WEBDAV_URL=https://gallery.improvdiplomat.workers.dev/main/nc/dav/files/owner/
export RCLONE_WEBDAV_VENDOR=nextcloud RCLONE_WEBDAV_NEXTCLOUD_CHUNK_SIZE=50M
export RCLONE_WEBDAV_HEADERS="CF-Access-Client-Id,$ID,CF-Access-Client-Secret,$SEC"
unset ID SEC
G=:webdav:Docs
rclone lsf --max-depth 1 :webdav: >/dev/null 2>&1 || { log "skip: Gallery not reachable"; exit 0; }

# name | Mac folder | mode
SOURCES=(
  "Obsidian|$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian|two-way"
  "iCloud Drive|$HOME/Library/Mobile Documents/com~apple~CloudDocs|two-way"
  "Documents|$HOME/Documents|two-way"
  "Desktop|$HOME/Desktop|two-way"
  "Downloads|$HOME/Downloads|two-way"
  "Temporary|$HOME/Temporary|two-way"
  "Developer|$HOME/Developer|one-way"   # git repos + live notes: two-way split notes into .conflict copies
  "Recordings|$HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings|one-way"
)
COMMON=(--local-unicode-normalization --webdav-nextcloud-chunk-size 50M --transfers 4 --checkers 8 --stats 0 -q)
failed=()

for s in $SOURCES; do
  name=${s%%|*} rest=${s#*|} src=${rest%|*} mode=${rest##*|}
  [[ -n $ONLY && $ONLY != $name ]] && continue
  [[ -d $src ]] || { log "$name: no folder, skipped"; continue; }
  # Voice Memos lives in another app's container: macOS blocks it until Disks Helper has Full Disk Access
  ls "$src" >/dev/null 2>&1 || { log "$name: macOS blocks reading $src"; failed+="$name (give Disks Helper Full Disk Access)"; continue; }
  filters=$CONF/docs-sync.filters; [[ $name == Obsidian ]] && filters=$CONF/docs-sync-obsidian.filters
  fhash=$(md5 -q $filters)
  if [[ $mode == one-way ]]; then
    # made here, never edited elsewhere (recordings, code and its notes): copy new ones, never delete
    rclone copy "$src" "$G/$name" --filter-from $filters $COMMON $DRY || failed+=$name
    continue
  fi
  # first pass for a folder, or after the filter list changed: --resync joins both sides (nothing deleted)
  mark=$STATE/state/$name.ok
  re=()
  if (( RESYNC )) || [[ ! -f $mark || $(cat $mark) != $fhash ]]; then re=(--resync); rclone mkdir "$G/$name"; fi
  rclone bisync "$src" "$G/$name" --filters-file $filters $COMMON $DRY $re \
    --workdir $STATE/bisync --backup-dir1 "$STATE/kept/$name" \
    --compare size,modtime --conflict-resolve none --conflict-loser num --conflict-suffix conflict --suffix-keep-extension \
    --resilient --recover --max-lock 15m --max-delete 25 --no-slow-hash
  rc=$?
  if (( rc == 0 )); then [[ -z $DRY ]] && print $fhash > $mark
  else failed+=$name; [[ $rc == 7 ]] && rm -f $mark 2>/dev/null; fi   # 7: bisync wants a --resync next time
done

# Notability's own PDF backups (its WebDAV Auto-Backup) are kept outside Main's files; show them under Docs too
if [[ -z $ONLY || $ONLY == Notability ]]; then
  rclone copy gallery-main:gallery-main/notability-backup "$G/Notability" --filter-from $CONF/docs-sync.filters $COMMON $DRY || failed+=Notability
fi

# Docs/INDEX.md: every document, by source, linked (relative links open in Gallery, Obsidian and Finder)
if [[ -z $DRY ]]; then
  idx=$STATE/INDEX.md
  rclone lsf -R --files-only --format tsp --separator $'\t' $G 2>/dev/null | LC_ALL=C sort -t$'\t' -k3 | python3 -I -c '
import sys, urllib.parse
rows = [l.rstrip("\n").split("\t") for l in sys.stdin if l.count("\t") == 2]
rows = [(t, int(s), p) for t, s, p in rows if p != "INDEX.md"]
by = {}
for t, s, p in rows:
    by.setdefault(p.split("/")[0] if "/" in p else "(top)", []).append((t, s, p))
out = ["# Docs", "", f"{len(rows)} documents, kept in step with the Mac by docs-sync. Newest first in each source.", ""]
for src in sorted(by):
    out += [f"## {src} ({len(by[src])})", ""]
    for t, s, p in sorted(by[src], key=lambda r: r[0], reverse=True):
        out.append(f"- [{p.split(chr(47), 1)[-1]}]({urllib.parse.quote(p)}) · {t[:10]} · {s / 1e6:.1f} MB" if s >= 1e5 else
                   f"- [{p.split(chr(47), 1)[-1]}]({urllib.parse.quote(p)}) · {t[:10]}")
    out.append("")
sys.stdout.write("\n".join(out))
' > $idx.new
  if [[ -s $idx.new ]] && ! cmp -s $idx.new $idx; then
    rclone copyto $idx.new $G/INDEX.md -q && mv -f $idx.new $idx
  fi
fi

if (( $#failed )); then log "failed: ${(j:, :)failed}"; notify "couldn't sync: ${(j:, :)failed}"; exit 1; fi
log "ok"
