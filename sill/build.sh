#!/bin/zsh
# Builds Sill.app from sill.swift, installs it as /Applications/Sill.app, and writes ./sill, a lowercase command for
# the terminal that runs the installed app. Living in /Applications keeps Sill a normal app to macOS (its icon and
# name in System Settings, permissions keyed to one place).
#   zsh build.sh              build for this Mac
#   zsh build.sh universal    build one binary that runs on Apple Silicon and Intel
set -e
cd "$(dirname "$0")"

first=$(grep -m1 -v '^[[:space:]]*$' sill.swift)
if [[ "$first" != //* && "$first" != import* ]]; then
  echo "sill.swift starts with unexpected text: $first" >&2
  exit 1
fi

app="build/Sill.app"
installed="/Applications/Sill.app"
mkdir -p build
exe="$app/Contents/MacOS/sill"
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources" && cp AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
printf "APPL????" > "$app/Contents/PkgInfo"
# Recense's home bar: its host page (sill/homebar) plus the shared web modules from Gallery's client, which is their
# one canonical home (docs/architecture.md § Track W). Each knows nothing about its host; Gallery's Worker serves them
# and this copies them into the bundle. homebar.js/css = the bar itself; keylabel.js (the Key's names) and room.js (the
# reverb's rooms) for the sound tray (SPEC 54); prosody.js + prosogram.js for the live prosogram.
# TODO: replace this list with a MANIFEST.json read, so a module's consumers are declared instead of typed here.
GALLERY_CLIENT=${GALLERY_CLIENT:-$HOME/Developer/gallery/gallery/src/client}
HB_MODULES=(homebar.js homebar.css keylabel.js room.js prosody.js prosogram.js)
if [[ -f homebar/index.html && -f $GALLERY_CLIENT/homebar.js && -f $GALLERY_CLIENT/homebar.css ]]; then
  mkdir -p "$app/Contents/Resources/homebar"
  cp homebar/index.html "$app/Contents/Resources/homebar/"
  for m in $HB_MODULES; do
    if [[ -f $GALLERY_CLIENT/$m ]]; then
      cp "$GALLERY_CLIENT/$m" "$app/Contents/Resources/homebar/"
    else
      echo "warning: shared module not bundled: $GALLERY_CLIENT/$m"
    fi
  done
else
  echo "warning: Recense home bar not bundled (needs sill/homebar/index.html and $GALLERY_CLIENT)"
fi

if [[ "$1" == "universal" ]]; then
  swiftc -O -target arm64-apple-macos14 sill.swift -o .sill-arm64
  swiftc -O -target x86_64-apple-macos14 sill.swift -o .sill-x86_64
  lipo -create -output "$exe" .sill-arm64 .sill-x86_64
  rm -f .sill-arm64 .sill-x86_64
else
  rm -f "$exe"
  # Recense's on-device ears (speech.swift: SpeechAnalyzer) compile only against a macOS 26+ SDK, and this Mac's Xcode
  # is 16.4 (SDK 15.5). Apple's Command Line Tools 27.2, unpacked (not installed) in ../.toolchain, build Sill when
  # they're there, in a build folder of their own; without them Sill builds as before and Recense hears through Groq.
  tools=${SILL_TOOLCHAIN:-$PWD/../.toolchain/CommandLineTools} scratch=.build
  if [[ -x $tools/usr/bin/swift ]]; then export DEVELOPER_DIR=$tools; scratch=.build-sdk27; fi
  # A Swift package (see Package.swift) so Sill can use SwiftTerm for its terminal panel.
  if ! swift build -c release --product sill --scratch-path $scratch > .build-log.txt 2>&1; then
    grep -E "error" .build-log.txt | head -20 >&2; echo "build failed (full log: .build-log.txt)" >&2; exit 1
  fi
  cp $scratch/release/sill "$exe"
  [[ -x "$exe" ]] || { echo "build failed" >&2; exit 1; }
fi

# Sign with the local "Sill Local Signing" certificate when it exists. Its signature stays the same across rebuilds,
# so macOS keeps Sill's Accessibility and Calendar permissions. Without it, fall back to ad-hoc signing
# (and re-grant Accessibility after every build).
# Prefer the Apple Development certificate (a real team ID: the keychain's "Always Allow" and macOS permissions
# survive rebuilds), then the local one, then ad-hoc.
dev=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
if [[ -n "$dev" ]]; then
  codesign --force --sign "$dev" --identifier local.sill "$app"
elif security find-identity -p codesigning 2>/dev/null | grep -q '"Sill Local Signing"'; then
  codesign --force --sign "Sill Local Signing" --identifier local.sill "$app"
else
  codesign --force --sign - --identifier local.sill "$app"
fi

# Install: replace /Applications/Sill.app with the fresh build (same signature, so permissions carry over).
rm -rf "$installed"
ditto "$app" "$installed"
lsr=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$lsr -u "$PWD/$app" 2>/dev/null; rm -rf "$app"          # only one Sill on disk: the installed one
$lsr -f "$installed"

# ./sill: the terminal command. A wrapper (not a copy) so there is only one executable and one identity.
rm -f sill
# When Sill isn't running yet, start it through LaunchServices (`open`), so Sill itself, not Terminal, is the app
# macOS asks permissions for. When it is running, the executable just hands the command over and exits.
print -r -- '#!/bin/zsh
app=/Applications/Sill.app
if ! pgrep -qx sill && [[ "${1:-time}" != (status|hide|quit) ]]; then
  exec open -a "$app" --args "${1:-time}"
fi
exec "$app/Contents/MacOS/sill" "$@"' > sill
chmod +x sill
echo "Built and installed $installed (and $(pwd)/sill)"
