#!/bin/zsh
# Builds Gallery for iPhone/iPad and installs it on a connected device.
#   zsh build.sh [device name or id]     (default: the first available iPhone or iPad)
# Free Personal Team: Xcode registers the device and makes a 7-day profile; after 7 days run this again.
# The device's Access token goes into the app from the Keychain (gallery-access-<device> if it exists, else
# gallery-access) as Secrets/token.json, which git ignores. Each build goes to a fresh folder; nothing is deleted.
set -e
here="${0:A:h}"
out="${here:h}/build/ios-$(date +%Y%m%d-%H%M%S)"
dev="${1:-}"
if [[ -z $dev ]]; then
  dev=$(xcrun devicectl list devices 2>/dev/null | awk '/available/ && /(iPhone|iPad)/ {print $(NF-4); exit}')
fi
[[ -n $dev ]] || { echo "No iPhone or iPad available: plug it in, unlock it, trust this Mac."; exit 1; }
name=$(xcrun devicectl list devices 2>/dev/null | awk -v d="$dev" '$0 ~ d {print tolower($0)}' | grep -o -E 'ipad|iphone' | head -1)
svc=gallery-access-$name
security find-generic-password -s $svc >/dev/null 2>&1 || svc=gallery-access
umask 077
id=$(security find-generic-password -s $svc -a client-id -w)
secret=$(security find-generic-password -s $svc -a client-secret -w)
print -r -- "{\"id\":\"$id\",\"secret\":\"$secret\"}" > "$here/Secrets/token.json"
unset id secret
echo "token: $svc"
udid=$(xcrun devicectl device info details --device "$dev" 2>/dev/null | awk -F': ' '/udid/ {print $2; exit}')
xcodebuild -project "$here/GalleryFiles.xcodeproj" -scheme GalleryFiles -configuration Debug \
  -destination "id=$udid" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  SYMROOT="$out" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)|Signing|Provisioning" || true
app="$out/Debug-iphoneos/Gallery Files.app"
[[ -d $app ]] || { echo "Build failed (see above)"; exit 1; }
xcrun devicectl device install app --device "$dev" "$app"
echo "Installed on $dev. Open Gallery once; the Chauphan location is in Files › Browse."
