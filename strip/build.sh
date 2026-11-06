#!/bin/zsh
# Builds Recense.app from app.swift, installs it as /Applications/Recense.app, and writes ./recense, a lowercase command for
# the terminal that runs the installed app. Living in /Applications keeps Recense a normal app to macOS (its icon and
# name in System Settings, permissions keyed to one place).
#   zsh build.sh              build for this Mac
#   zsh build.sh universal    build one binary that runs on Apple Silicon and Intel
set -e
cd "$(dirname "$0")"

first=$(grep -m1 -v '^[[:space:]]*$' app.swift)
if [[ "$first" != //* && "$first" != import* ]]; then
  echo "app.swift starts with unexpected text: $first" >&2
  exit 1
fi

app="build/Recense.app"
installed="/Applications/Recense.app"
mkdir -p build
exe="$app/Contents/MacOS/recense"
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources" && cp AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
printf "APPL????" > "$app/Contents/PkgInfo"
# Recense's open ears (ears/omni.py: the Omnilingual helper, run by ~/.local/share/recense/omni's Python) and the canon
# (canon/*.json: recited texts in languages no model hears; speech.swift, canon.swift).
rm -rf "$app/Contents/Resources/ears" "$app/Contents/Resources/canon"
mkdir -p "$app/Contents/Resources/ears" "$app/Contents/Resources/canon"
cp ears/omni.py "$app/Contents/Resources/ears/"
cp canon/*.json "$app/Contents/Resources/canon/"
# Recense's home bar: its host page (recense/homebar) plus the shared web modules from Gallery's client, which is their
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
  echo "warning: Recense home bar not bundled (needs recense/homebar/index.html and $GALLERY_CLIENT)"
fi

if [[ "$1" == "universal" ]]; then
  swiftc -O -target arm64-apple-macos14 app.swift -o .recense-arm64
  swiftc -O -target x86_64-apple-macos14 app.swift -o .recense-x86_64
  lipo -create -output "$exe" .recense-arm64 .recense-x86_64
  rm -f .recense-arm64 .recense-x86_64
else
  rm -f "$exe"
  # Recense's on-device ears (speech.swift: SpeechAnalyzer) compile only against a macOS 26+ SDK, and this Mac's Xcode
  # is 16.4 (SDK 15.5). Apple's Command Line Tools 27.2, unpacked (not installed) in ../.toolchain, build Recense when
  # they're there, in a build folder of their own; without them Recense builds as before and Recense hears through Groq.
  # (Their SwiftPM's default build system compiles SwiftTerm's Metal shader, and the tools have no `metal`: native.)
  tools=${RECENSE_TOOLCHAIN:-$PWD/../.toolchain/CommandLineTools} scratch=.build flags=()
  if [[ -x $tools/usr/bin/swift ]]; then export DEVELOPER_DIR=$tools; scratch=.build-sdk27; flags=(--build-system native); fi
  # A Swift package (see Package.swift) so Recense can use SwiftTerm for its terminal panel.
  if ! swift build -c release --product recense --scratch-path $scratch $flags > .build-log.txt 2>&1; then
    grep -E "error" .build-log.txt | head -20 >&2; echo "build failed (full log: .build-log.txt)" >&2; exit 1
  fi
  cp $scratch/release/recense "$exe"
  [[ -x "$exe" ]] || { echo "build failed" >&2; exit 1; }
fi

# Sign with the local "Recense Local Signing" certificate when it exists. Its signature stays the same across rebuilds,
# so macOS keeps Recense's Accessibility and Calendar permissions. Without it, fall back to ad-hoc signing
# (and re-grant Accessibility after every build).
# Prefer the Apple Development certificate (a real team ID: the keychain's "Always Allow" and macOS permissions
# survive rebuilds), then the local one, then ad-hoc.
dev=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
if [[ -n "$dev" ]]; then
  codesign --force --sign "$dev" --identifier local.recense "$app"
elif security find-identity -p codesigning 2>/dev/null | grep -q '"Recense Local Signing"'; then
  codesign --force --sign "Recense Local Signing" --identifier local.recense "$app"
else
  codesign --force --sign - --identifier local.recense "$app"
fi

# Install: replace /Applications/Recense.app with the fresh build (same signature, so permissions carry over).
rm -rf "$installed"
ditto "$app" "$installed"
lsr=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# only one Recense on disk: the installed one. Unregistering the build copy fails (-10814) when LaunchServices never
# saw it; that isn't a failed build (11-05: it stopped build.sh after the install, so autoupdate never relaunched).
$lsr -u "$PWD/$app" 2>/dev/null || true; rm -rf "$app"
$lsr -f "$installed"

# ./recense: the terminal command. A wrapper (not a copy) so there is only one executable and one identity.
rm -f recense
# When Recense isn't running yet, start it through LaunchServices (`open`), so Recense itself, not Terminal, is the app
# macOS asks permissions for. When it is running, the executable just hands the command over and exits.
print -r -- '#!/bin/zsh
app=/Applications/Recense.app
if ! pgrep -qx recense && [[ "${1:-time}" != (status|hide|quit|selftest) ]]; then
  exec open -a "$app" --args "${1:-time}"
fi
exec "$app/Contents/MacOS/recense" "$@"' > recense
chmod +x recense
echo "Built and installed $installed (and $(pwd)/recense)"
