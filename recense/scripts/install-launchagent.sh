#!/bin/zsh
# Starts Recense automatically when you log in, using a per-user LaunchAgent.
#   zsh scripts/install-launchagent.sh           install (builds the binary first if it is missing)
#   zsh scripts/install-launchagent.sh status    show whether the login item is installed and loaded
#   zsh scripts/install-launchagent.sh remove    remove the login item only; the app and your notes stay
set -e

LABEL="local.recense"
root="${0:A:h:h}"                                   # the project folder (this script lives in scripts/)
template="$root/launchagent/$LABEL.plist.template"
target="$HOME/Library/LaunchAgents/$LABEL.plist"
bin="/Applications/Recense.app/Contents/MacOS/recense"
log="$HOME/Library/Logs/recense.log"
domain="gui/$(id -u)"

case "${1:-install}" in
  status)
    [[ -f "$target" ]] && echo "plist:  installed at $target" || echo "plist:  not installed"
    if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then echo "agent:  loaded"; else echo "agent:  not loaded"; fi
    if pgrep -x recense >/dev/null; then echo "app:    running"; else echo "app:    not running"; fi
    ;;

  remove)
    launchctl bootout "$domain/$LABEL" 2>/dev/null || true
    rm -f "$target"
    echo "Removed the login item. Recense itself and your notes are untouched."
    ;;

  install)
    [[ -f "$template" ]] || { echo "Missing $template" >&2; exit 1; }
    [[ -x "$bin" ]] || zsh "$root/build.sh"
    [[ -x "$bin" ]] || { echo "Build failed: $bin does not exist" >&2; exit 1; }

    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

    plist="$(<"$template")"
    plist="${plist//__RECENSE_BIN__/$bin}"
    plist="${plist//__RECENSE_LOG__/$log}"
    print -r -- "$plist" > "$target"
    plutil -lint "$target" >/dev/null

    # Replace any older copy of the agent, then load the new one.
    launchctl bootout "$domain/$LABEL" 2>/dev/null || true
    launchctl enable "$domain/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$domain" "$target"

    echo "Installed $target"
    echo "Recense will now start at every login, hidden until you summon it."
    echo "Check any time with:  zsh scripts/install-launchagent.sh status"
    ;;

  *)
    echo "usage: zsh scripts/install-launchagent.sh [install|status|remove]" >&2
    exit 64
    ;;
esac