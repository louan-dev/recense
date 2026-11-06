#!/bin/zsh
# md-mirror.zsh: every Markdown file made on this Mac, in the Obsidian vault as well (spec A11 N4). Three local pairs,
# kept in step both ways by rclone bisync: ~/Developer, ~/Desktop and ~/Documents ↔ <vault>/Mac/<name>. iCloud carries
# the vault's copies to the iPhone and iPad, and an edit made there reaches the original at the next pass.
#   Markdown only, minus the tool, build and backup folders (config/md-mirror.filters).
#   The same file edited on both sides: the newer wins, the other stays beside it as name.md.conflictN.
#   Whatever a pass overwrites or deletes, on either side, is kept first in
#   ~/Library/Application Support/md-mirror/backup/<time>/<name>/{mac,vault}: a note deleted on the iPhone can't take
#   the original with it. More than 10 % of a side deleted at once stops the pass.
#   Disk to disk: no network, no Worker requests.
#   md-mirror.zsh [--dry-run] [--resync] [--only NAME] [--verbose]
# launchd (com.chauphan.md-mirror) runs it every 5 minutes through Disks Helper, which passes no arguments (launchd's
# own zsh may not read Desktop or Documents); previews run this script directly.
set -u
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export RCLONE_CONFIG=/dev/null   # local paths only (rclone.conf is encrypted and would wait for its password)
HERE=${0:A:h}
FILTERS=${HERE:h}/config/md-mirror.filters
VAULT="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian"
STATE="$HOME/Library/Application Support/md-mirror"
DRY=() RESYNC=0 ONLY= Q=(-q)
while (( $# )); do case $1 in
  --dry-run) DRY=(--dry-run) ;; --resync) RESYNC=1 ;; --only) ONLY=$2; shift ;; --verbose) Q=(-v) ;;
  *) print -u2 "usage: md-mirror.zsh [--dry-run] [--resync] [--only NAME] [--verbose]"; exit 2 ;;
esac; shift; done

log() { print "$(date -u +%FT%TZ) $*"; }
notify() { /usr/bin/osascript -e "display notification \"$1\" with title \"Markdown mirror\"" >/dev/null 2>&1; }

[[ -d $VAULT ]] || { log "skip: no vault at $VAULT"; exit 0; }
mkdir -p "$STATE/bisync" "$STATE/state"
fhash=$(md5 -q $FILTERS)
# bisync keeps a .md5 beside its filters file: it reads a copy kept here, so nothing is written into the repo
F="$STATE/md-mirror.filters"
cmp -s $FILTERS "$F" || cp -f $FILTERS "$F"
BK="$STATE/backup/$(date +%F_%H%M%S)"
failed=()

for name in Developer Desktop Documents; do
  [[ -n $ONLY && $ONLY != $name ]] && continue
  src=$HOME/$name dst=$VAULT/Mac/$name
  [[ -d $src ]] || { log "$name: no folder, skipped"; continue; }
  ls "$src" >/dev/null 2>&1 || { log "$name: macOS blocks reading $src"; failed+="$name (give Disks Helper Full Disk Access)"; continue; }
  # no Markdown on either side (Desktop, Documents today): bisync refuses an empty listing, so the pair waits (Y8)
  if [[ -z $(rclone lsf -R --files-only --skip-links --filter-from $FILTERS "$src" 2>/dev/null | head -1) ]] &&
     [[ ! -d $dst || -z $(rclone lsf -R --files-only --skip-links --filter-from $FILTERS "$dst" 2>/dev/null | head -1) ]]; then
    continue
  fi
  mark=$STATE/state/$name.ok
  # the vault's folder gone after it was in step (moved out, say): made again empty, it would read as every note
  # deleted, so the pair stops until a --resync
  if [[ ! -d $dst && -f $mark ]] && (( ! RESYNC )); then
    log "$name: $dst is gone; run md-mirror.zsh --resync to start the pair over"; failed+=$name; continue
  fi
  mkdir -p "$dst"
  # first pass for a pair, or after the filter list changed: --resync joins both sides (nothing deleted; where both have
  # a file and they differ, the newer wins and the other goes to the backup folder)
  re=()
  if (( RESYNC )) || [[ ! -f $mark || $(cat $mark) != $fhash ]]; then re=(--resync --resync-mode newer); fi
  rclone bisync "$src" "$dst" --filters-file "$F" --skip-links --local-unicode-normalization --stats 0 $Q $DRY $re \
    --workdir "$STATE/bisync" --backup-dir1 "$BK/$name/mac" --backup-dir2 "$BK/$name/vault" \
    --compare size,modtime,checksum --conflict-resolve newer \
    --resilient --recover --max-lock 2m --max-delete 10
  rc=$?
  if (( rc == 0 )); then [[ -z $DRY ]] && print $fhash > $mark
  else failed+=$name; [[ $rc == 7 ]] && rm -f $mark 2>/dev/null; fi   # 7: bisync wants a --resync next time
done

if (( $#failed )); then log "failed: ${(j:, :)failed}"; notify "couldn't mirror: ${(j:, :)failed}"; exit 1; fi
log "ok"
