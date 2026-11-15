#!/bin/zsh
# Rebuilds the yt-dlp-on-iOS spike in a scratch folder (nothing here ships in the app).
#   zsh setup.zsh <scratch dir> [device UDID]
# One-time downloads (offline gate: setup only), each pinned:
#   BeeWare Python-Apple-support 3.14-b14 (CPython 3.14.10 for iOS), 37,299,470 bytes,
#   sha256 703ff822529f46edcbcd8b88096b2544f6990f3109ad38b4b4b61bb489a7c1ee
#   https://github.com/beeware/Python-Apple-support/releases/download/3.14-b14/Python-3.14-iOS-support.b14.tar.gz
#   yt-dlp 2026.10.26 + certifi 2026.10.23 from PyPI (pure Python)
set -e
here="${0:A:h}"
out="${1:?scratch dir}"; dev="${2:-}"
tgz=Python-3.14-iOS-support.b14.tar.gz
sum=703ff822529f46edcbcd8b88096b2544f6990f3109ad38b4b4b61bb489a7c1ee
mkdir -p "$out" && cd "$out"
[[ -f $tgz ]] || curl -sLO "https://github.com/beeware/Python-Apple-support/releases/download/3.14-b14/$tgz"
print "$sum  $tgz" | shasum -a 256 -c -
tar xzf $tgz
mv testbed/iOSTestbed testbed/iOSTestbed.xcodeproj .
mv iOSTestbed/app_packages iOSTestbed/app_packages.readme
python3 -m pip install -q --target iOSTestbed/app_packages yt-dlp==2026.10.26 certifi==2026.10.23
cp "$here/SceneDelegate.m" iOSTestbed/SceneDelegate.m
cp "$here/spike.py" iOSTestbed/app/spike.py
sed -i '' -e 's/DEVELOPMENT_TEAM = "";/DEVELOPMENT_TEAM = 48RZ72DNP3;/' \
  -e 's/PRODUCT_BUNDLE_IDENTIFIER = org.python.iOSTestbed;/PRODUCT_BUNDLE_IDENTIFIER = local.recense.ytdlpspike;/' \
  -e 's/IPHONEOS_DEPLOYMENT_TARGET = 15.0;/IPHONEOS_DEPLOYMENT_TARGET = 16.0;/' iOSTestbed.xcodeproj/project.pbxproj
# The testbed's Info.plist hardcodes its own id; it must match the signed one or iOS refuses the install (0xe8008016).
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.recense.ytdlpspike' iOSTestbed/iOSTestbed-Info.plist
x27=/Applications/Xcode-27.2.0.app/Contents/Developer
[[ -d $x27 ]] && export DEVELOPER_DIR=$x27
xcodebuild -project iOSTestbed.xcodeproj -scheme iOSTestbed -configuration Debug -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates SYMROOT="$out/build" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
[[ -z $dev ]] && exit 0
xcrun devicectl device install app --device "$dev" "$out/build/Debug-iphoneos/iOSTestbed.app"
# The app runs once on launch and never exits; read its log, then stop it (Ctrl-C).
xcrun devicectl device process launch --console --terminate-existing --device "$dev" local.recense.ytdlpspike
