#!/bin/zsh
# cal-job.sh: export every calendar to .ics (EventKit, read-only), then mirror the export with the ledger
# (PROGRESS B4, toward G1). launchd runs it on a schedule; the ledger journal keeps every version.
set -u
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
OUT=${CAL_EXPORT_DIR:-$HOME/.ledger/export/calendar}
SINK=${1:-rclone:gallery-main:gallery-main/ledger/calendar}
DIR=${0:A:h}
if ! $DIR/cal-export --out "$OUT"; then
  /usr/bin/osascript -e 'display notification "calendar export failed (Calendar access?); see ~/Library/Logs/ledger-calendar.log" with title "Ledger: calendar"' >/dev/null 2>&1
  exit 1
fi
LEDGER_QUIET_SECS=0 exec $DIR/ledger-job.sh "$OUT" "$SINK" calendar
