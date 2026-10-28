#!/bin/zsh
# Builds "Gallery Files.app" (host app + File Provider extension) and installs it in /Applications.
#   zsh build.sh
# Signed with this Mac's Apple Development certificate (free Personal Team, team 48RZ72DNP3). The App Group is
# team-prefixed, so macOS needs no provisioning profile. Each build goes to a fresh folder under apple/build/;
# nothing is deleted.
set -e
here="${0:A:h}"
src="${here:h}"
out="$src/build/$(date +%Y%m%d-%H%M%S)"
app="$out/Gallery Files.app"
ext="$app/Contents/PlugIns/GalleryProvider.appex"
sign="Apple Development: chaulphan@icloud.com"
target=arm64-apple-macos13.0

mkdir -p "$app/Contents/MacOS" "$ext/Contents/MacOS"
swiftc -O -target $target -parse-as-library -application-extension -module-name GalleryProvider \
  "$src/FileProviderCore/Core.swift" "$src/Extension/FileProviderExtension.swift" \
  -framework FileProvider -Xlinker -e -Xlinker _NSExtensionMain -o "$ext/Contents/MacOS/GalleryProvider"
swiftc -O -target $target -module-name GalleryFiles \
  "$src/FileProviderCore/Core.swift" "$src/HostApp/macOS/main.swift" \
  -framework AppKit -framework FileProvider -o "$app/Contents/MacOS/GalleryFiles"
cp "$here/Ext-Info.plist" "$ext/Contents/Info.plist"
cp "$here/App-Info.plist" "$app/Contents/Info.plist"

codesign --force --sign "$sign" --entitlements "$here/Ext.entitlements" --timestamp=none "$ext"
codesign --force --sign "$sign" --entitlements "$here/App.entitlements" --timestamp=none "$app"
codesign --verify --deep --strict "$app"

pkill -x GalleryFiles 2>/dev/null || true
ditto "$app" "/Applications/Gallery Files.app"
echo "Built $out, installed /Applications/Gallery Files.app"
