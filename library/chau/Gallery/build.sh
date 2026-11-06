#!/bin/zsh
# Builds Gallery.app into /Applications.
#   zsh build.sh
# Then Command-drag /Applications/Gallery.app into the Finder sidebar (and the Dock if you like).
set -e

here="${0:A:h}"
app="/Applications/Gallery.app"
tmp="$(mktemp -d)"

swiftc -O "$here/main.swift" -o "$tmp/Gallery" -framework AppKit -framework LocalAuthentication

if pgrep -x Gallery >/dev/null; then
  osascript -e 'tell application id "local.gallery" to quit' >/dev/null 2>&1 || pkill -x Gallery || true
  sleep 1
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
mv "$tmp/Gallery" "$app/Contents/MacOS/Gallery"
cp "$here/Info.plist" "$app/Contents/Info.plist"

# the system's folder icon, so it reads as a place in the sidebar
icon="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericFolderIcon.icns"
[[ -f "$icon" ]] && cp "$icon" "$app/Contents/Resources/Gallery.icns"

codesign --force --sign - "$app"
rm -rf "$tmp"

echo "Built $app"
