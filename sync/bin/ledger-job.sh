#!/bin/zsh
# ledger-job.sh: one mirror pass for launchd (PROGRESS A5). Event-driven: launchd starts it when the
# source folder changes (WatchPaths), when a volume mounts (StartOnMount), and once a day as a heartbeat.
#   ledger-job.sh SOURCE_DIR SINK ORIGIN
# Exits 0 when the sink's volume is absent (nothing to do until it mounts). Notifies on failure or staleness.
set -u
SRC=$1 SINK=$2 ORIGIN=$3
NODE=${LEDGER_NODE:-/opt/homebrew/bin/node}
LEDGER=${0:A:h:h}/ledger.mjs
notify() { /usr/bin/osascript -e "display notification \"$1\" with title \"Ledger: $ORIGIN\"" >/dev/null 2>&1; }

if [[ $SINK == /Volumes/* ]]; then VOL=${SINK#/Volumes/}; VOL=/Volumes/${VOL%%/*}; [[ -d $VOL ]] || { echo "$(date -u +%FT%TZ) skip: $VOL not mounted"; exit 0; }; fi
echo "$(date -u +%FT%TZ) run $ORIGIN"
if ! $NODE $LEDGER run --source "$SRC" --sink "$SINK" --origin "$ORIGIN" --apply; then notify "mirror run failed; see ~/Library/Logs/ledger-$ORIGIN.log"; exit 1; fi
$NODE $LEDGER fold --sink "$SINK" --write >/dev/null || notify "fold failed"
$NODE $LEDGER health --sink "$SINK" --max-age-hours 24 || { notify "mirror is stale (lastOk > 1 day)"; exit 1; }
