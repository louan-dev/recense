#!/bin/zsh
# One-off (item 17, 2026-10-31): gallery-archive/chauphan/ → gallery-archive/archive/. Copy, verify, then remove the old.
#   r2/rename-archive.sh <rclone R2 remote>    e.g. r2/rename-archive.sh r2
# Deploy the Worker (npx wrangler deploy) right after it finishes; until then the site still reads chauphan/.
set -euo pipefail
export RCLONE_CONFIG=${RCLONE_CONFIG:-$HOME/.config/rclone/jobs.conf}  # the remotes the jobs use (gallery-archive: lives here)
R=${1:?rclone remote name for R2}
rclone copy "${R}:gallery-archive/chauphan" "${R}:gallery-archive/archive" --metadata --transfers 16 --progress
rclone check "${R}:gallery-archive/chauphan" "${R}:gallery-archive/archive" --one-way
echo "Verified. Removing gallery-archive/chauphan/ …"
rclone purge "${R}:gallery-archive/chauphan"
echo "Done. Now: cd ~/Developer/gallery/gallery && npx wrangler deploy && apple/macos/build.sh"
