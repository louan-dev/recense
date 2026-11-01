#!/bin/zsh
# Keeps /Applications/Sill.app on the latest pushed code, so "deploy sill" from a phone or cloud session needs nothing
# typed on this Mac. Every few minutes (a LaunchAgent; see install-autoupdate.sh) it fetches sill and gallery; when
# either has new commits on main it fast-forwards them, rebuilds with build.sh (signed here, so permissions carry over)
# and relaunches Sill if it was running.
#   zsh scripts/install-autoupdate.sh            install
#   zsh scripts/install-autoupdate.sh status     is it loaded; when did it last build
#   zsh scripts/install-autoupdate.sh remove     stop updating
setopt err_return
sill_dir="${0:A:h:h}"                 # sill/sill (build.sh lives here)
sill_repo="${sill_dir:h}"              # ~/Developer/sill
gallery_repo="$HOME/Developer/gallery" # build.sh copies Gallery's shared client code
lock="$HOME/Library/Caches/sill-autoupdate.lock"
stamp() { print -r -- "$(date '+%F %T') $*"; }

# One run at a time; a build on a busy Mac can outlast the interval.
mkdir "$lock" 2>/dev/null || { stamp "a run is already going; skipped"; return 0 2>/dev/null || exit 0; }
trap 'rmdir "$lock" 2>/dev/null' EXIT

# Fast-forward a repo to origin/main; prints "new" when it moved. Never merges, never touches uncommitted work:
# a working tree with local edits to the incoming files just waits for the next run.
advance() {
  local repo=$1 before after
  [[ -d $repo/.git ]] || return 0
  git -C "$repo" fetch -q origin main || { stamp "$repo: fetch failed (offline?)"; return 0; }
  before=$(git -C "$repo" rev-parse HEAD)
  [[ $(git -C "$repo" rev-parse --abbrev-ref HEAD) == main ]] || { stamp "$repo: not on main; left alone"; return 0; }
  git -C "$repo" merge -q --ff-only origin/main 2>/dev/null || { stamp "$repo: can't fast-forward (local commits or edits); left alone"; return 0; }
  after=$(git -C "$repo" rev-parse HEAD)
  [[ $before != $after ]] && print new
  return 0
}

changed=$(advance "$sill_repo")$(advance "$gallery_repo")
[[ -n $changed || $1 == now ]] || return 0 2>/dev/null || exit 0

stamp "new code; building $(git -C "$sill_repo" log -1 --format='%h %s' | cut -c1-80)"
running=0; pgrep -qx sill && running=1
cd "$sill_dir" && zsh build.sh || { stamp "build failed; see $sill_dir/.build-log.txt"; exit 1; }
if (( running )); then
  /Applications/Sill.app/Contents/MacOS/sill quit 2>/dev/null; sleep 2
  open -a /Applications/Sill.app
fi
stamp "installed"
