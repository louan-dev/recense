#!/bin/zsh
# Keeps Recense (the iOS app, bundle com.chauphan.galleryfiles) on the iPad and iPhone past the free team's 7-day
# limit. Run daily by launchd (com.chauphan.resign-ios). Each device is checked on its own (11-06: the old check read
# only the Mac's cached profile, so once one device renewed, the other was never retried and lost the app):
# - a device whose app is missing, or was installed 5 days ago or more (or with --force), is rebuilt and reinstalled;
# - when the cached profile has 2 days or less left, it first moves to a dated folder (never deleted), so Xcode
#   issues a fresh 7-day one.
# A device that can't be reached gets a notification and is tried again on the next day's run.
#   zsh resign-ios.zsh [--force]
set -u
BUILD=${0:A:h}/../../library/apple/ios/build.sh
PD="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
RETIRED="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles (retired)"
LOG=$HOME/Library/Logs/resign-ios.log
STAMPS="$HOME/Library/Application Support/recense/resign-ios"   # one file per device; its date = the last install
APP=com.chauphan.galleryfiles
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

# does device $1 need a reinstall? (app missing, or installed 5 days ago or more)
due() {
  [[ ${FORCE:-} == 1 ]] && return 0
  xcrun devicectl device info apps --device $1 2>/dev/null | grep -q $APP || { say "$2: app missing"; return 0; }
  [[ -f "$STAMPS/$1" ]] || return 0
  (( $(date +%s) - $(stat -f %m "$STAMPS/$1") >= 5 * 86400 ))
}

[[ ${1:-} == --force ]] && FORCE=1
mkdir -p "$STAMPS"
remaining=$(left)
devices=$(xcrun devicectl list devices 2>/dev/null)
todo=() failed=()
for id name in ${(kv)DEVICES}; do
  if ! print -r -- "$devices" | grep "$id" | grep -q available; then
    say "$name: not reachable"; failed+=$name; continue
  fi
  due $id $name && todo+=$id
done

if (( ${#todo} == 0 )); then
  say "ok: $(( remaining / 3600 )) h left on the profile; every reachable device is current"
else
  if (( remaining <= 2 * 86400 )); then
    say "retiring the cached profile ($(( remaining / 3600 )) h left)"
    stamp="$RETIRED/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$stamp"
    for f in "$PD"/*.mobileprovision(N); do mv "$f" "$stamp/"; done
  fi
  for id in $todo; do
    name=${DEVICES[$id]}
    zsh $BUILD $id >> $LOG 2>&1
    rc=$?
    if (( rc == 0 )); then say "$name: installed"; touch "$STAMPS/$id"
    else say "$name: install failed (exit $rc)"; failed+=$name; fi
  done
fi

if (( ${#failed} )); then
  notify "Couldn't re-sign on ${(j:, :)failed}. Bring it near the Mac, unlocked; it's tried again tomorrow."
elif (( ${#todo} )); then
  notify "Re-signed Recense for 7 more days."
fi
say "done"
