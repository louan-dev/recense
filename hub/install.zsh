#!/bin/zsh
# Derived from Spec: FEAT-18 (H1). Builds the hub, makes its certificates if missing, and starts it as a background
# service that comes back after a reboot or a crash. No admin password: it is a login agent, so it runs while you are
# logged in. (For the Mac mini with nobody logged in, see hub/README.md: a LaunchDaemon, one sudo command.)
#   zsh hub/install.zsh [mac|mini]
set -euo pipefail
NAME=${1:-mac}
HERE=${0:A:h}
REPO=${HERE:h}
BIN=$HOME/.local/bin/recense-hub
LABEL=local.recense.hub
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
LOG=$HOME/Library/Logs/recense-hub.log

tools=${RECENSE_TOOLCHAIN:-$REPO/.toolchain/CommandLineTools}
[[ -x $tools/usr/bin/swift ]] || tools=$HOME/Developer/recense/.toolchain/CommandLineTools
cd $HERE
if [[ -x $tools/usr/bin/swift ]]; then
  DEVELOPER_DIR=$tools swift build -c release --build-system native --scratch-path .build-sdk27
  built=.build-sdk27/release/recense-hub
else
  swift build -c release
  built=.build/release/recense-hub
fi
mkdir -p $HOME/.local/bin $HOME/Library/LaunchAgents $HOME/Library/Logs
cp $built $BIN

[[ -f $HOME/.config/recense/hub/tls.p12 ]] || zsh $HERE/scripts/hub-ca.zsh $NAME
[[ -f $REPO/editor/dist/pwa/index.html ]] || { echo "no page at $REPO/editor/dist/pwa: run npm run build in editor/"; exit 1; }

cat > $PLIST <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>Label</key><string>$LABEL</string>
 <key>ProgramArguments</key><array>
  <string>$BIN</string><string>serve</string>
  <string>--shell</string><string>$REPO/editor/dist/pwa</string>
  <string>--name</string><string>$NAME</string>
 </array>
 <key>RunAtLoad</key><true/>
 <key>KeepAlive</key><true/>
 <key>ThrottleInterval</key><integer>10</integer>
 <key>StandardOutPath</key><string>$LOG</string>
 <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
EOF
plutil -lint $PLIST
launchctl bootout gui/$UID/$LABEL 2>/dev/null || true
launchctl bootstrap gui/$UID $PLIST
sleep 2
echo "hub started. Log: $LOG"
curl -s --cacert $HOME/.config/recense/hub/recense-hub-root.pem https://recense.local/api/health || echo "(not answering yet: tail $LOG)"
echo
