#!/bin/zsh
# ledger-job.sh: one mirror pass for launchd (PROGRESS A5). Event-driven: launchd starts it when the
# source folder changes (WatchPaths) and once a day as a heartbeat. --materialize: a placeholder is not a backup.
#   ledger-job.sh SOURCE_DIR SINK ORIGIN
# Exits 0 when the sink's volume is absent (nothing to do until it mounts). Notifies only when something changes (the run
# starts or stops failing, held deletions appear or change, fold fails, the mirror goes stale), never on every run:
# WatchPaths starts this on every save, so one notification per run became one per Draftpad save (2026-11-05, D3).
set -u
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin   # launchd's PATH lacks Homebrew (rclone)
# unattended jobs read only the scoped keys; the interactive rclone.conf may be locked behind Touch ID
export RCLONE_CONFIG=${RCLONE_CONFIG:-$HOME/.config/rclone/jobs.conf}
SRC=$1 SINK=$2 ORIGIN=$3
NODE=${LEDGER_NODE:-/opt/homebrew/bin/node}
LEDGER=${0:A:h:h}/src/ledger.mjs
notify() { /usr/bin/osascript -e "display notification \"$1\" with title \"Ledger: $ORIGIN\"" >/dev/null 2>&1; }

if [[ $SINK == /Volumes/* ]]; then VOL=${SINK#/Volumes/}; VOL=/Volumes/${VOL%%/*}; [[ -d $VOL ]] || { echo "$(date -u +%FT%TZ) skip: $VOL not mounted"; exit 0; }; fi
MARKS=${LEDGER_HOME:-$HOME/.ledger}; WAS=none
# changed NAME VALUE: succeeds (and remembers VALUE) only when NAME's last value differs; WAS holds the value it replaced
changed() { local f="$MARKS/notified-$ORIGIN-$1" old=none; [[ -f $f ]] && old=$(<"$f"); [[ $2 == "$old" ]] && return 1; print -r -- "$2" >| "$f"; WAS=$old; }

echo "$(date -u +%FT%TZ) run $ORIGIN"
out=$($NODE $LEDGER run --source "$SRC" --sink "$SINK" --origin "$ORIGIN" --quiet-secs "${LEDGER_QUIET_SECS:-60}" --materialize --apply); rc=$?
[[ -n $out ]] && print -r -- "$out"
if (( rc )); then changed run failing && notify "mirror run failed; see ~/Library/Logs/ledger-$ORIGIN.log"; exit 1; fi
changed run ok && [[ $WAS == failing ]] && notify "mirror recovered"
held=$(print -r -- "$out" | sed -n 's/^held: \([0-9][0-9]*\) .*/\1/p' | tail -n 1); held=${held:-0}
changed held "$held" && (( held )) && notify "$held deletion(s) held by the guard; see sync/README.md (Held deletions)"
if $NODE $LEDGER fold --sink "$SINK" --write >/dev/null; then changed fold ok; else changed fold failing && notify "fold failed"; fi
if $NODE $LEDGER health --sink "$SINK" --max-age-hours 24; then changed health ok; exit 0; fi
changed health stale && notify "mirror is stale (lastOk > 1 day)"; exit 1
