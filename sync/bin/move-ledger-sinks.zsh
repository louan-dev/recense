#!/bin/zsh
# move-ledger-sinks.zsh [--apply]: the ledger's mirrors leave Gallery's library bucket for Sync's own
# (docs/specs/organism.md §7, event-log.md §7): gallery-main/ledger/<source>/ → sync-ledger/<source>/.
# Without --apply it only checks and prints the plan. Nothing is deleted: the old copies stay until the owner removes
# them (the last line prints the command). Run it from Terminal or with "!" in Claude Code (it uses launchctl).
#
# Needs, once: the jobs' gallery-main key must reach the new bucket. Cloudflare dashboard → R2 → Manage API tokens →
# the token behind jobs.conf's "gallery-main" remote → Edit → add bucket "sync-ledger" (Object Read & Write) → Save.
set -u
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export RCLONE_CONFIG=${RCLONE_CONFIG:-$HOME/.config/rclone/jobs.conf}
APPLY=${1:-}
HERE=${0:A:h}
NODE=${LEDGER_NODE:-/opt/homebrew/bin/node}
LEDGER=$HERE/../src/ledger.mjs
AGENTS=$HOME/Library/LaunchAgents
OLD=gallery-main:gallery-main/ledger NEW=gallery-main:sync-ledger
typeset -A SRC
SRC[obsidian]="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian"
SRC[icloud-drive]="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
SRC[calendar]="${CAL_EXPORT_DIR:-$HOME/.ledger/export/calendar}"
SOURCES=(obsidian icloud-drive calendar)
fail() { print -u2 "move-ledger-sinks: $1"; exit 1; }

rclone lsf "$NEW" >/dev/null 2>&1 || {
  print "The jobs' key can't reach bucket sync-ledger yet. Cloudflare dashboard → R2 → Manage API tokens → edit the"
  print "token behind jobs.conf's gallery-main remote → add bucket sync-ledger (Object Read & Write) → Save. Then run again."
  exit 2
}
for s in $SOURCES; do
  print "$s: $(rclone size --json "$OLD/$s" | $NODE -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(j.count+" objects, "+(j.bytes/1048576).toFixed(1)+" MiB")})')  $OLD/$s → $NEW/$s"
done
[[ $APPLY == --apply ]] || { print "Dry run. Run again with --apply to move (the jobs pause for the copy)."; exit 0; }

for s in $SOURCES; do
  plist=$AGENTS/com.chauphan.ledger.$s.plist
  [[ -f $plist ]] || fail "no $plist"
  print "== $s"
  launchctl bootout gui/$UID "$plist" 2>/dev/null   # no run writes to the old sink while it's copied
  rclone copy "$OLD/$s" "$NEW/$s" --s3-no-check-bucket || fail "$s: copy failed (old sink untouched, job still stopped: launchctl bootstrap gui/$UID $plist)"
  $NODE $LEDGER verify --deep --sink "rclone:$NEW/$s" || fail "$s: the copy doesn't verify (old sink untouched; job stopped)"
  a=$($NODE $LEDGER fold --sink "rclone:$OLD/$s" | grep -m1 '"count"') b=$($NODE $LEDGER fold --sink "rclone:$NEW/$s" | grep -m1 '"count"')
  [[ $a == "$b" ]] || fail "$s: trees differ ($a vs $b)"
  # the state file is named after the sink: carry it over, or the first run would log every file as new
  so=$($NODE $LEDGER state-path --source "${SRC[$s]}" --sink "rclone:$OLD/$s") sn=$($NODE $LEDGER state-path --source "${SRC[$s]}" --sink "rclone:$NEW/$s")
  [[ -f $so ]] && cp -p "$so" "$sn"
  cp -p "$plist" "$plist.pre-sync-ledger"
  if [[ $s == calendar ]]; then # cal-job.sh takes the sink as its first argument
    plutil -insert ProgramArguments.1 -string "rclone:$NEW/$s" "$plist"
  else
    plutil -replace ProgramArguments.2 -string "rclone:$NEW/$s" "$plist"
  fi
  launchctl bootstrap gui/$UID "$plist" && launchctl kickstart gui/$UID/com.chauphan.ledger.$s
  print "$s: moved; job points at $NEW/$s (old plist kept as $plist.pre-sync-ledger)"
done
sleep 20
for s in $SOURCES; do $NODE $LEDGER health --sink "rclone:$NEW/$s" --max-age-hours 24; done
print "Done. When you're satisfied, the old copies can go: rclone purge $OLD   (not run)"
