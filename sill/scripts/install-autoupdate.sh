#!/bin/zsh
# Installs the LaunchAgent that runs scripts/autoupdate.sh every 5 minutes (and at login).
#   zsh scripts/install-autoupdate.sh            install
#   zsh scripts/install-autoupdate.sh status     show whether it is loaded and its last lines of log
#   zsh scripts/install-autoupdate.sh remove     stop updating; Sill itself stays
set -e

LABEL="local.sill.autoupdate"
script="${0:A:h}/autoupdate.sh"
target="$HOME/Library/LaunchAgents/$LABEL.plist"
log="$HOME/Library/Logs/sill-autoupdate.log"
domain="gui/$(id -u)"

case "${1:-install}" in
  status)
    launchctl print "$domain/$LABEL" >/dev/null 2>&1 && echo "agent: loaded" || echo "agent: not loaded"
    [[ -f $log ]] && tail -5 "$log"
    ;;
  remove)
    launchctl bootout "$domain/$LABEL" 2>/dev/null || true
    rm -f "$target"
    echo "Removed; Sill no longer updates itself."
    ;;
  install)
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    cat > "$target" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/zsh</string><string>$script</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
EOF
    plutil -lint "$target" >/dev/null
    launchctl bootout "$domain/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$domain" "$target"
    echo "Installed $target; Sill now rebuilds itself within 5 minutes of a push to main."
    ;;
esac
