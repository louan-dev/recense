#!/bin/zsh
# Builds Gallery (as "Gallery Files.app": /Applications/Gallery.app is the Touch ID mount app) (host app + File Provider extension) and installs it in /Applications.
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
  "$src/FileProviderCore/Core.swift" "$src/HostApp/macOS/main.swift" "$src/HostApp/macOS/Window.swift" \
  "$src/HostApp/iOS/Player.swift" \
  -framework AppKit -framework FileProvider -framework WebKit -framework SwiftUI -o "$app/Contents/MacOS/GalleryFiles"
cp "$here/Ext-Info.plist" "$ext/Contents/Info.plist"
# the cloud alone, on transparency: Finder's sidebar draws it as a template, so an opaque square turns into a black block
mkdir -p "$ext/Contents/Resources" && cp "$here/GalleryProvider.icns" "$ext/Contents/Resources/"
cp "$here/App-Info.plist" "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources" && cp "$here/GalleryFiles.icns" "$app/Contents/Resources/"
# Finder and its sidebar show "Gallery" even though the bundle is "Gallery Files.app" (Gallery.app is taken)
mkdir -p "$app/Contents/Resources/en.lproj"
printf 'CFBundleDisplayName = "Gallery";\nCFBundleName = "Gallery";\n' > "$app/Contents/Resources/en.lproj/InfoPlist.strings"
# Finder (and its sidebar) show "Gallery" though the bundle is named "Gallery Files.app"
mkdir -p "$app/Contents/Resources/en.lproj" && printf 'CFBundleDisplayName = "Gallery";\nCFBundleName = "Gallery";\n' > "$app/Contents/Resources/en.lproj/InfoPlist.strings"

codesign --force --sign "$sign" --entitlements "$here/Ext.entitlements" --timestamp=none "$ext"
codesign --force --sign "$sign" --entitlements "$here/App.entitlements" --timestamp=none "$app"
codesign --verify --deep --strict "$app"

pkill -x GalleryFiles 2>/dev/null || true
ditto "$app" "/Applications/Gallery Files.app"
echo "Built $out, installed /Applications/Gallery Files.app"
