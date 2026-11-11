#!/bin/zsh
# Builds Recense (the iOS app, formerly Gallery) for iPhone/iPad and installs it on a connected device.
#   zsh build.sh [device name or id]     (default: the first available iPhone or iPad)
#   zsh build.sh --guest [device]        Recense Guest (Now Playing only, iPhone): installs it, and writes an unsigned
#                                        .ipa (build/guest-<date>/RecenseGuest.ipa) to sign with Sideloadly
# Free Personal Team: Xcode registers the device and makes a 7-day profile; after 7 days run this again.
# The device's Access token goes into the app from the Keychain (gallery-access-<device> if it exists, else
# gallery-access) as Secrets/token.json, which git ignores. Each build goes to a fresh folder; nothing is deleted.
set -e
# Xcode 27.2 (iOS 27.2 SDK: SpeechAnalyzer); Xcode 16.4 stays only as a fallback until it is retired.
x27=/Applications/Xcode-27.2.0.app/Contents/Developer
[[ -z ${DEVELOPER_DIR:-} && -d $x27 ]] && export DEVELOPER_DIR=$x27
here="${0:A:h}"
guest=0; [[ ${1:-} == --guest ]] && { guest=1; shift }
out="${here:h}/build/ios-$(date +%Y%m%d-%H%M%S)"
dev="${1:-}"
if [[ -z $dev ]]; then
  # the Identifier column (a model like "iPhone 12 Pro Max (iPhone13,4)" has spaces, so no counting from the end);
  # physical only: since Xcode 27 booted simulators are listed as "connected" too
  dev=$(xcrun devicectl list devices 2>/dev/null | awk '/ (available|connected)/ && /(iPhone|iPad)/ && / physical/ {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F-]{27}$/ || $i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')
fi
[[ -n $dev ]] || { echo "No iPhone or iPad available: plug it in, unlock it, trust this Mac."; exit 1; }
udid=$(xcrun devicectl device info details --device "$dev" 2>/dev/null | awk -F': ' 'tolower($0) ~ /udid/ {print $2; exit}' | tr -d ' ')
if (( guest )); then
  # no token, no File Provider: nothing in it reaches Gallery
  gout="${here:h}/build/guest-$(date +%Y%m%d-%H%M%S)"
  xcodebuild -project "$here/GalleryFiles.xcodeproj" -scheme RecenseGuest -configuration Debug -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO SYMROOT="$gout/unsigned" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
  [[ -d "$gout/unsigned/Debug-iphoneos/Recense Guest.app" ]] || { echo "Unsigned guest build failed (see above)"; exit 1; }
  mkdir -p "$gout/Payload" && cp -R "$gout/unsigned/Debug-iphoneos/Recense Guest.app" "$gout/Payload/"
  (cd "$gout" && zip -qry RecenseGuest.ipa Payload) && echo "Unsigned: $gout/RecenseGuest.ipa (sign it in Sideloadly with the guest's Apple ID)"
  xcodebuild -project "$here/GalleryFiles.xcodeproj" -scheme RecenseGuest -configuration Debug \
    -destination "id=$udid" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    SYMROOT="$out" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)|Signing|Provisioning" || true
  app="$out/Debug-iphoneos/Recense Guest.app"
  [[ -d $app ]] || { echo "Build failed (see above)"; exit 1; }
  xcrun devicectl device install app --device "$dev" "$app"
  echo "Installed Recense Guest on $dev."
  exit 0
fi
name=$(xcrun devicectl list devices 2>/dev/null | awk -v d="$dev" '$0 ~ d {print tolower($0)}' | grep -o -E 'ipad|iphone' | head -1)
svc=gallery-access-$name
security find-generic-password -s $svc >/dev/null 2>&1 || svc=gallery-access
umask 077
id=$(security find-generic-password -s $svc -a client-id -w)
secret=$(security find-generic-password -s $svc -a client-secret -w)
print -r -- "{\"id\":\"$id\",\"secret\":\"$secret\"}" > "$here/Secrets/token.json"
unset id secret
echo "token: $svc"
xcodebuild -project "$here/GalleryFiles.xcodeproj" -scheme GalleryFiles -configuration Debug \
  -destination "id=$udid" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  SYMROOT="$out" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)|Signing|Provisioning" || true
app="$out/Debug-iphoneos/Gallery Files.app"
[[ -d $app ]] || { echo "Build failed (see above)"; exit 1; }
xcrun devicectl device install app --device "$dev" "$app"
echo "Installed on $dev. Open Recense once; the Archive location is in Files › Browse, Draftpad is in its sidebar."
