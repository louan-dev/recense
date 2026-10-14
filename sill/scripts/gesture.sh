#!/bin/zsh
# The one script BetterTouchTool calls. Keeping the logic here means BTT never needs editing again
# when Sill's commands change.
#   zsh scripts/gesture.sh up      three-finger swipe up    → Draftpad (again → hide)
#   zsh scripts/gesture.sh down    three-finger swipe down  → time     (again → hide)
#   zsh scripts/gesture.sh hide | quit
S="${0:A:h:h}/sill"
cmd="${1:-up}"
if pgrep -qx sill; then
  "$S" "$cmd"
elif [[ "$cmd" != hide && "$cmd" != quit ]]; then
  nohup "$S" "$cmd" >/dev/null 2>&1 &
fi
