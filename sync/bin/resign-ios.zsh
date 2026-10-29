#!/bin/zsh
# Keeps Gallery on the iPad and iPhone past the free team's 7-day limit. Run daily by launchd
# (com.chauphan.resign-ios). Once the installed profile has 2 days or less left (or with --force):
# 1. the cached profiles move to a dated folder (never deleted), so Xcode has to issue fresh 7-day ones;
# 2. Gallery is rebuilt and installed on each device this Mac can reach (cable, or Wi-Fi once paired).
# A device that can't be reached gets a notification and is tried again on the next day's run.
#   zsh resign-ios.zsh [--force]
set -u
BUILD=$HOME/Developer/gallery/gallery/apple/ios/build.sh
PD="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
RETIRED="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles (retired)"
LOG=$HOME/Library/Logs/resign-ios.log
typeset -A DEVICES=(  # CoreDevice id → name
  B8147E80-0DAE-5D60-BCF8-BCBF86AF1819 "iPad Air"
  3D4FD625-7DBE-5C6B-91ED-0FB9EF6F885F "iPhone 12 Pro Max"
)
say() { print -r -- "$(date '+%F %T') $*" >> $LOG; }
notify() { osascript -e "display notification \"$1\" with title \"Gallery\"" 2>/dev/null; }

# seconds left on the app's profile (0 when there is none)
left() {
  local f best=0 exp
  for f in "$PD"/*.mobileprovision(N); do
    security cms -D -i "$f" 2>/dev/null | grep -q '<string>48RZ72DNP3.com.chauphan.galleryfiles</string>' || continue
    exp=$(security cms -D -i "$f" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null)
    exp=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$exp" +%s 2>/dev/null || echo 0)
    (( exp > best )) && best=$exp
  done
  (( best > $(date +%s) )) && print $(( best - $(date +%s) )) || print 0
}

remaining=$(left)
if [[ ${1:-} != --force ]] && (( remaining > 2 * 86400 )); then
  say "ok: $(( remaining / 3600 )) h left, nothing to do"
  exit 0
fi

say "re-signing ($(( remaining / 3600 )) h left)"
stamp="$RETIRED/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$stamp"
for f in "$PD"/*.mobileprovision(N); do mv "$f" "$stamp/"; done

failed=()
devices=$(xcrun devicectl list devices 2>/dev/null)
for id name in ${(kv)DEVICES}; do
  if ! print -r -- "$devices" | grep "$id" | grep -q available; then
    say "$name: not reachable"; failed+=$name; continue
  fi
  if zsh $BUILD $id >> $LOG 2>&1; then say "$name: installed"
  else say "$name: install failed"; failed+=$name; fi
done

if (( ${#failed} )); then
  notify "Couldn't re-sign on ${(j:, :)failed}. Bring it near the Mac, unlocked; it's tried again tomorrow."
else
  notify "Re-signed on the iPad and iPhone for 7 more days."
fi
