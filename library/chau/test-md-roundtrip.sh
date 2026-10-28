#!/bin/zsh
# Markdown round trip through Gallery's mounted Main folder: can a .md file be opened, and do edits reach the server
# (what the web Gallery and other devices see), and come back the other way?
#   zsh test-md-roundtrip.sh          (Gallery must be open: Touch ID first)
#   zsh test-md-roundtrip.sh --open   (also opens the file in your default .md app, to look at)
# Works in Main/DAV test/; every version it replaces stays in Gallery's trash.
set -u
DIR="$HOME/.gallery/Main/DAV test"
NAME="roundtrip-$(date +%H%M%S).md"
F="$DIR/$NAME"
URL="https://gallery.improvdiplomat.workers.dev/main/dav/DAV%20test/$NAME"
fails=0
pass() { print "PASS  $1"; }
fail() { print "FAIL  $1"; fails=$((fails + 1)); }
# the server's copy, read through the Worker with this Mac's Access token (never printed)
server() {
  curl -s -m 20 -H @<(printf 'CF-Access-Client-Id: %s\nCF-Access-Client-Secret: %s\n' \
    "$(security find-generic-password -s gallery-access -a client-id -w)" \
    "$(security find-generic-password -s gallery-access -a client-secret -w)") "$@" "$URL"
}
# wait up to $2 seconds for command $1 to succeed
within() { local t=0; until eval "$1" >/dev/null 2>&1; do (( t >= $2 )) && return 1; sleep 3; t=$((t + 3)); done; print -n "${t}s "; }

mount | grep -q " on $HOME/.gallery " || { print "Gallery isn't open: open it (Touch ID), then run this again."; exit 2; }
[[ -d $DIR ]] || mkdir "$DIR"

# 1. a new note, written the way most editors save (straight into the file)
printf '# Round trip\n\nv1 from the Mac %s\n' "$(date +%T)" > "$F"
[[ $(cat "$F") == *"v1 from the Mac"* ]] && pass "new .md readable on the Mac" || fail "new .md readable on the Mac"
python3 -I -c 'import fcntl,os,sys; fcntl.lockf(os.open(sys.argv[1], os.O_RDWR), fcntl.LOCK_EX|fcntl.LOCK_NB)' "$F" 2>/dev/null \
  && pass "file can be locked (apps need this to open it)" || fail "file can be locked (apps need this to open it)"
within '[[ $(server) == *"v1 from the Mac"* ]]' 90 && pass "new note reached the server" || fail "new note reached the server (90 s)"

# 2. an edit in place
printf '# Round trip\n\nv2 edited on the Mac %s\n' "$(date +%T)" > "$F"
within '[[ $(server) == *"v2 edited on the Mac"* ]]' 90 && pass "edit reached the server" || fail "edit reached the server (90 s)"

# 3. an edit saved the "safe" way (write a temporary file, then rename it over the note: Obsidian, VS Code, vim)
printf '# Round trip\n\nv3 safe-saved on the Mac %s\n' "$(date +%T)" > "$DIR/$NAME.tmp-save" && mv -f "$DIR/$NAME.tmp-save" "$F"
within '[[ $(server) == *"v3 safe-saved on the Mac"* ]]' 90 && pass "safe-save edit reached the server" || fail "safe-save edit reached the server (90 s)"

# 4. an edit made elsewhere (the web Gallery, another device) shows up on the Mac
etag=$(server -I | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '\r')
code=$(server -o /dev/null -w '%{http_code}' -X PUT -H "If-Match: $etag" --data-binary "# Round trip

v4 edited on the server $(date +%T)
")
[[ $code == 204 ]] && pass "edit on the server accepted" || fail "edit on the server accepted (HTTP $code)"
within '[[ $(cat "$F") == *"v4 edited on the server"* ]]' 120 && pass "server edit visible on the Mac" || fail "server edit visible on the Mac (120 s)"

# 5. a stale save from the Mac's point of view must not overwrite (the server keeps the newer text)
code=$(server -o /dev/null -w '%{http_code}' -X PUT -H "If-Match: $etag" --data-binary "stale")
[[ $code == 412 ]] && pass "out-of-date save refused (412)" || fail "out-of-date save refused (got $code)"

[[ ${1:-} == --open ]] && open "$F" && print "Opened $NAME in your default .md app: check it shows v4."
(( fails )) && print -n "\n$fails FAILED. " || print -n "\nAll passed. "
print "$((8 - fails)) of 8. Test note: Main/DAV test/$NAME (older versions are in Gallery's trash)."
exit $(( fails > 0 ))
