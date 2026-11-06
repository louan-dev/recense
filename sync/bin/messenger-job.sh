#!/bin/zsh
# messenger-job.sh: ingest new Meta export zips, then mirror the result (PROGRESS A8). launchd starts it when the
# inbox changes or a volume mounts. Exits 0 when the SanDisk is absent. R2 copy only through an rclone crypt remote.
set -u
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
# unattended jobs read only the scoped keys; the interactive rclone.conf may be locked behind Touch ID
export RCLONE_CONFIG=${RCLONE_CONFIG:-$HOME/.config/rclone/jobs.conf}
VOL=${MESSENGER_VOLUME:-/Volumes/SanDisk}
[[ -d $VOL ]] || { echo "$(date -u +%FT%TZ) skip: $VOL not mounted"; exit 0; }
DIR=${0:A:h}; NODE=${LEDGER_NODE:-/opt/homebrew/bin/node}
$NODE $DIR/../src/messenger.mjs ingest --inbox "$VOL/inbox/messenger" --out "$VOL/messenger" || \
  /usr/bin/osascript -e 'display notification "Messenger export shrank or failed; see ~/Library/Logs/ledger-messenger.log" with title "Ledger: messenger"' >/dev/null 2>&1
[[ -f $VOL/messenger/exports.json ]] || exit 0
$DIR/ledger-job.sh "$VOL/messenger" "$VOL/ledger/messenger" messenger || exit 1
# Off-site copy, encrypted: only when the owner has created the crypt remote (rclone config: r2-crypt).
if rclone listremotes | grep -qx 'r2-crypt:'; then $DIR/ledger-job.sh "$VOL/messenger" "rclone:r2-crypt:messenger" messenger; fi
