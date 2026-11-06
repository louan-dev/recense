#!/bin/zsh
# Builds ~/Applications/Disks Helper.app and signs it with the Apple Development identity, so its Full Disk Access
# grant (System Settings › Privacy & Security) survives rebuilds. See main.swift for why it exists.
set -eu
here=${0:A:h}
app="$HOME/Applications/Disks Helper.app"
mkdir -p "$app/Contents/MacOS"
swiftc -O -swift-version 5 "$here/main.swift" -o "$app/Contents/MacOS/disks-helper"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.chauphan.disks-helper</string>
  <key>CFBundleName</key><string>Disks Helper</string>
  <key>CFBundleExecutable</key><string>disks-helper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSBackgroundOnly</key><true/>
</dict>
</plist>
EOF
id=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --sign "$id" --identifier com.chauphan.disks-helper "$app"
codesign --verify --strict "$app" && echo "built and signed: $app"
