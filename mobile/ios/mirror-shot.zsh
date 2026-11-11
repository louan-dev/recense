#!/bin/zsh
# mirror-shot: test an iOS build on the real iPhone through iPhone Mirroring (owner, 2026-11-10: never the simulator).
# Launches Recense on the phone (optional), opens iPhone Mirroring on this Mac, and screenshots only its window.
# Usage: zsh mobile/ios/mirror-shot.zsh <out.png> [--launch]
# Run outside the sandbox (it needs CoreDevice, Launch Services and Apple Events). iPhone Mirroring needs the phone
# locked, nearby, on the same Apple Account, with Wi-Fi and Bluetooth on.
emulate -L zsh
out=${1:?usage: mirror-shot.zsh <out.png> [--launch]}
IPHONE=${IPHONE_UDID:-00008101-001A50643A98001E}
APP=${APP_ID:-com.chauphan.galleryfiles}   # APP_ID=com.chauphan.recense.guest for Recense Guest

if [[ $2 == --launch ]]; then
  xcrun devicectl device process launch --terminate-existing --device $IPHONE $APP >/dev/null \
    || { print -u2 "couldn't launch $APP on $IPHONE (is it installed and connected?)"; exit 1; }
fi

open -a "iPhone Mirroring" || exit 1
# The window's id, from CoreGraphics' window list (JavaScript for Automation, no extra tools).
wid() { osascript -l JavaScript -e '
  ObjC.import("CoreGraphics");
  const l = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0))) || [];
  const w = l.find(w => w.kCGWindowOwnerName === "iPhone Mirroring" && w.kCGWindowLayer === 0 && w.kCGWindowBounds.Height > 200);
  w ? w.kCGWindowNumber : ""'; }
id=""
for i in {1..40}; do id=$(wid); [[ -n $id ]] && break; sleep 0.25; done
[[ -n $id ]] || { print -u2 "iPhone Mirroring has no window (is the phone locked and nearby?)"; exit 1; }
sleep 1.5   # the mirrored screen settles after the app opens
screencapture -x -o -l $id "$out" && print -r -- "$out"
