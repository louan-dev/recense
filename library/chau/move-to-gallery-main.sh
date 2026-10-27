#!/bin/bash
#
# Finder Quick Action "Move to Gallery Main" (SPEC 43): select files or folders in Finder,
# right click > Quick Actions > Move to Gallery Main, pick a folder in Main, and they go up.
# Each local item goes to the Trash (never deleted) only after all of its files arrived.
#
#   - Destination: a picker that walks Main's folders (GET /main/api/folders), with "New folder…"
#     (POST /main/api/folder).
#   - Files up to ~90 MB: PUT /main/api/file?key=<folder>/<name>&mtime=<ms> (the page's own upload).
#     Larger ones go through the rclone remote gallery-main (chau/setup.sh), since the Worker
#     refuses single requests over 100 MB.
#   - Folders keep their tree: each subfolder is made with POST /main/api/folder first.
#
# Signs in with the Access service token in the Keychain, the same as copy-share-link.sh.
# Log: ~/Library/Logs/gallery-move.log. Installed by chau/install-move-to-gallery-main.sh.

set -u
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH"

BASE="${GALLERY_BASE:-https://gallery.improvdiplomat.workers.dev}"; BASE="${BASE%/}"
BIG=90000000
LOG="$HOME/Library/Logs/gallery-move.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }
[ -t 2 ] || exec 2>>"$LOG"
log "==== Started with $# item(s)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

osa() { /usr/bin/osascript - "$@" 2>/dev/null; }
alert() { osa "$1" <<'AS' >/dev/null
on run argv
  display alert "Move to Gallery Main" message (item 1 of argv) as critical
end run
AS
}
notify() { osa "$1" <<'AS' >/dev/null
on run argv
  display notification (item 1 of argv) with title "Move to Gallery Main"
end run
AS
}
enc() { /usr/bin/python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
jstr() { /usr/bin/python3 -c 'import sys,json;print(json.dumps(sys.argv[1]))' "$1"; }

[ "$#" -gt 0 ] || { alert "Nothing was selected."; exit 1; }

CLIENT_ID="$(/usr/bin/security find-generic-password -s gallery-access -a client-id -w 2>/dev/null || true)"
CLIENT_SECRET="$(/usr/bin/security find-generic-password -s gallery-access -a client-secret -w 2>/dev/null || true)"
[ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] || { alert "The Mac's sign-in isn't set up. Run chau/setup.sh."; exit 1; }

CODE=""; RESP=""
call() {
  CODE=$(/usr/bin/curl -sS --connect-timeout 20 --max-time 3600 -o "$TMP/resp" -w '%{http_code}' \
    -H "CF-Access-Client-Id: $CLIENT_ID" -H "CF-Access-Client-Secret: $CLIENT_SECRET" -H "x-gallery: 1" \
    "$@" 2>>"$LOG") || CODE="000"
  RESP="$(/bin/cat "$TMP/resp" 2>/dev/null || true)"
  log "HTTP $CODE"
}

# ---- destination picker ----
folders_of() {   # prints one subfolder name per line
  call "$BASE/main/api/folders?p=$(enc "$1")"
  [ "$CODE" = "200" ] || return 1
  printf '%s' "$RESP" | /usr/bin/python3 -c 'import sys,json;[print(n) for n in json.load(sys.stdin)["folders"]]'
}

new_folder() {   # dir name -> 0 when made or already there
  call -X POST -H "content-type: application/json" \
    -d "{\"dir\":$(jstr "$1"),\"name\":$(jstr "$2")}" "$BASE/main/api/folder"
  [ "$CODE" = "200" ] || [ "$CODE" = "409" ]
}

HERE_ITEM="✓ Move here"; NEW_ITEM="+ New folder…"; UP_ITEM="↑ Up"
dir=""
while :; do
  list="$(folders_of "$dir")" || { alert "Couldn't read Main's folders (HTTP $CODE)."; exit 1; }
  choice="$(osa "${dir:-Main}" "$HERE_ITEM" "$NEW_ITEM" "$UP_ITEM" "$list" <<'AS'
on run argv
  set {here, hereItem, newItem, upItem, raw} to argv
  set opts to {hereItem, newItem}
  if here is not "Main" then set end of opts to upItem
  if raw is not "" then set opts to opts & paragraphs of raw
  set r to choose from list opts with title "Move to Gallery Main" with prompt ("Folder: " & here) default items {hereItem} OK button name "Choose" cancel button name "Cancel"
  if r is false then return ""
  return item 1 of r
end run
AS
)"
  case "$choice" in
    "") log "Cancelled"; exit 0 ;;
    "$HERE_ITEM") break ;;
    "$UP_ITEM") case "$dir" in */*) dir="${dir%/*}" ;; *) dir="" ;; esac ;;
    "$NEW_ITEM")
      name="$(osa <<'AS'
try
  return text returned of (display dialog "New folder name:" default answer "" with title "Move to Gallery Main")
on error
  return ""
end try
AS
)"
      [ -n "$name" ] || continue
      new_folder "$dir" "$name" || { alert "Couldn't make that folder (HTTP $CODE): $RESP"; continue; }
      dir="${dir:+$dir/}$name" ;;
    *) dir="${dir:+$dir/}$choice" ;;
  esac
done
log "Destination: ${dir:-Main}"

# ---- upload ----
mime_of() { /usr/bin/file -b --mime-type "$1" 2>/dev/null || echo application/octet-stream; }

put_file() {   # local-path dest-folder
  local f="$1" rel="${2:+$2/}$(basename "$1")" size mt
  size=$(/usr/bin/stat -f%z "$f"); mt=$(( $(/usr/bin/stat -f%m "$f") * 1000 ))
  log "Upload $f -> $rel ($size bytes)"
  if [ "$size" -gt "$BIG" ]; then
    command -v rclone >/dev/null || { log "rclone missing for a large file"; return 1; }
    rclone copyto "$f" "gallery-main:gallery-main/files/$rel" >>"$LOG" 2>&1
    return
  fi
  local tries
  for tries in 1 2 3; do
    call -X PUT -T "$f" -H "content-type: $(mime_of "$f")" "$BASE/main/api/file?key=$(enc "$rel")&mtime=$mt"
    [ "$CODE" = "200" ] && return 0
    case "$CODE" in 400|401|403|404|413) return 1 ;; esac
    sleep $((tries * 3))
  done
  return 1
}

put_tree() {   # local-folder dest-parent
  local d="$1" name; name="$(basename "$d")"
  new_folder "$2" "$name" || return 1
  local sub="${2:+$2/}$name" e ok=0
  for e in "$d"/* "$d"/.[!.]*; do
    [ -e "$e" ] || continue
    case "$(basename "$e")" in .DS_Store|.localized) continue ;; esac
    if [ -d "$e" ]; then put_tree "$e" "$sub" || ok=1
    else put_file "$e" "$sub" || ok=1; fi
  done
  return $ok
}

to_trash() {
  osa "$1" <<'AS' >/dev/null
on run argv
  tell application "Finder" to delete (POSIX file (item 1 of argv) as alias)
end run
AS
}

moved=0; failed=0
for item in "$@"; do
  if [ -d "$item" ]; then put_tree "$item" "$dir"; else put_file "$item" "$dir"; fi
  if [ $? -eq 0 ]; then to_trash "$item"; moved=$((moved + 1)); else failed=$((failed + 1)); log "FAILED $item"; fi
done

log "Done: $moved moved, $failed failed"
if [ "$failed" -gt 0 ]; then
  alert "$moved moved to ${dir:-Main}, $failed failed and stayed where they were. Log: ~/Library/Logs/gallery-move.log"
  exit 1
fi
notify "$moved item(s) moved to ${dir:-Main}"
