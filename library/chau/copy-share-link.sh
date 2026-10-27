#!/bin/bash
#
# Finder Quick Action "Copy Share Link": select files, or a folder in Gallery/Public, and get a
# gallery link on the clipboard.
#
# Automator: New > Quick Action, receives files or folders in Finder, add "Run Shell Script"
# (shell /bin/bash, pass input as arguments) containing only:
#   exec /bin/bash "$HOME/Library/Application Support/Gallery/copy-share-link.sh" "$@"
#
# Two paths:
#   - Anything inside ~/Gallery/Public/<folder>: it is already online, so this only asks for that
#     folder's link. The folder's files expire with the link.
#   - Anything else: a live gallery is created first (the link works at once and items appear as
#     they land), then files go up smallest first. Over ~90 MB, in 32 MiB parts.
#
# It signs in as the owner with the Access service token kept in the Keychain
# (chau/setup.sh puts it there). Logs go to ~/Library/Logs/gallery-link.log.
#
# setup.sh copies this file to ~/Library/Application Support/Gallery/copy-share-link.sh, which is
# the path the Quick Action should call, so the Quick Action never depends on where the project lives.
#
# The uploads continue in a second copy of this script that is started in its own session (see the
# end of the file). Automator ends everything it started the moment the action returns, so a plain
# background job would be killed after the first few seconds.

set -u

# Quick Actions start with a bare PATH
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH"

# -------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------

BASE="${GALLERY_BASE:-https://gallery.improvdiplomat.workers.dev}"
BASE="${BASE%/}"
PUBLIC_DIR="${GALLERY_PUBLIC_DIR:-$HOME/Gallery/Public}"
DAYS="${GALLERY_DAYS:-7}"
OPEN_GALLERY="${GALLERY_OPEN:-1}"   # 1 = open the gallery in the browser once the link exists
PART_MB=32                          # R2 needs parts of at least 5 MiB
BIG=90000000                        # Cloudflare refuses single requests over 100 MB
RETRY_SLEEP=3

SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
RESUME="${GALLERY_RESUME:-}"   # set only in the detached copy that carries on uploading

LOG="$HOME/Library/Logs/gallery-link.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true
}

# when nobody is watching a terminal, keep stderr in the log instead of losing it
[ -t 2 ] || exec 2>>"$LOG"

log "============================================================"
log "Started with $# item(s) | script: $SELF | bash $BASH_VERSION | user: $(id -un)${RESUME:+ | resuming uploads}"

# -------------------------------------------------------------------
# macOS messages
# -------------------------------------------------------------------

alert() {
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'display alert (item 1 of argv) message (item 2 of argv) buttons {"OK"} default button "OK"' \
    -e 'end run' \
    "$1" "$2" >/dev/null 2>&1 || true
}

notify() {
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "Gallery"' \
    -e 'end run' \
    "$1" >/dev/null 2>&1 || true
}

# a short dialog that closes itself and never blocks the upload
toast_bg() {
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'display dialog (item 1 of argv) with title "Gallery" buttons {"OK"} default button "OK" giving up after 7' \
    -e 'end run' \
    "$1" >/dev/null 2>&1 &
}

# -------------------------------------------------------------------
# State
# -------------------------------------------------------------------

if [ -n "$RESUME" ] && [ -d "$RESUME" ]; then
  TMP="$RESUME"
else
  RESUME=""
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/gallery-link.XXXXXX")"
fi

ID=""
UPID=""
CUR_I=""
LIVE=0
MAXT=120

KEEP_TMP=0
trap '[ "$KEEP_TMP" = 1 ] || rm -rf "$TMP"' EXIT

mime_of() {
  /usr/bin/file -b --mime-type "$1" 2>/dev/null || echo "application/octet-stream"
}

fsize() { /usr/bin/stat -f%z "$1"; }
fmtime() { /usr/bin/stat -f%m "$1"; }

# percent-encode every byte
enc() {
  /usr/bin/printf %s "$1" | /usr/bin/od -An -v -tx1 | /usr/bin/tr -d ' \n' | /usr/bin/sed 's/../%&/g'
}

json_field() {
  /usr/bin/printf %s "$RESP" | /usr/bin/sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p"
}

# -------------------------------------------------------------------
# Owner credentials (an Access service token in the Keychain)
# -------------------------------------------------------------------

CLIENT_ID="$(/usr/bin/security find-generic-password -s gallery-access -a client-id -w 2>/dev/null || true)"
CLIENT_SECRET="$(/usr/bin/security find-generic-password -s gallery-access -a client-secret -w 2>/dev/null || true)"

# -------------------------------------------------------------------
# HTTP: sets CODE (000 when the network failed) and RESP
# -------------------------------------------------------------------

CODE="000"
RESP=""

call() {
  CODE=$(
    /usr/bin/curl -sS --connect-timeout 20 --max-time "$MAXT" \
      -o "$TMP/resp" -w '%{http_code}' \
      -H "CF-Access-Client-Id: $CLIENT_ID" \
      -H "CF-Access-Client-Secret: $CLIENT_SECRET" \
      -H "x-gallery: 1" \
      "$@" 2>"$TMP/curl-error"
  ) || CODE="000"

  RESP="$(/bin/cat "$TMP/resp" 2>/dev/null || true)"
  [ "$CODE" = "000" ] && log "curl: $(/bin/cat "$TMP/curl-error" 2>/dev/null)"
  log "HTTP $CODE"
}

call_retry() {
  local tries=1

  while :; do
    call "$@"
    [ "$CODE" = "200" ] && return 0
    # refusals do not improve with retries
    case "$CODE" in 302|400|401|403|404|411|413) return 1 ;; esac
    [ "$tries" -ge 4 ] && return 1
    log "Retry $((tries + 1)) of 4"
    sleep $((RETRY_SLEEP * tries))
    tries=$((tries + 1))
  done
}

why() {
  case "$CODE" in
    302|401|403|404) echo "the Mac's sign-in was refused; run chau/setup.sh again, and check that the Access policy 'Service Auth' includes the token gallery-chau" ;;
    411) echo "the request had no length" ;;
    400) echo "bad request" ;;
    413) echo "file too large for one request" ;;
    429) echo "rate limited, try again shortly" ;;
    5*) echo "server error (HTTP $CODE)" ;;
    000) echo "no connection" ;;
    *) echo "HTTP $CODE" ;;
  esac
}

# -------------------------------------------------------------------
# Failure: stop the upload in progress, mark the gallery failed, say why
# -------------------------------------------------------------------

abort_upload() {
  [ -n "$UPID" ] || return 0
  log "Aborting multipart upload"
  call -X POST -d "" "$BASE/main/api/upload?action=abort&id=$ID&i=$CUR_I&uploadId=$(enc "$UPID")"
  UPID=""
}

cancel_link() {
  [ "$LIVE" = "1" ] || return 0
  log "Marking unfinished items failed"
  call -X POST -d "" "$BASE/main/api/link?action=cancel&id=$ID"
  LIVE=0
}

fail() {
  log "FAIL: $1"
  printf 'Gallery link failed: %s\n' "$1" >&2
  abort_upload
  cancel_link
  alert "Gallery link failed" "$1"
  exit 1
}

trap 'log "Interrupted"; abort_upload; cancel_link; exit 1' INT TERM

if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
  log "Keychain read returned nothing for service gallery-access"
  fail "This Mac isn't signed in to Gallery yet. Run chau/setup.sh once."
fi

# -------------------------------------------------------------------
# Upload one file: one request up to BIG, parts above it
# -------------------------------------------------------------------

upload_one() {
  local f="$1" i="$2"
  local size name mime qs

  size="$(fsize "$f")"
  name="$(basename "$f")"
  mime="$(mime_of "$f")"
  CUR_I="$i"
  qs="id=$ID&i=$i&name=$(enc "$name")&days=$DAYS&t=$(( $(fmtime "$f") * 1000 ))&hasArt=0"

  log "Uploading #$((i + 1)): $name ($size bytes, $mime)"

  if [ "$size" -le "$BIG" ]; then
    MAXT=900
    call_retry -X PUT -T "$f" -H "content-type: $mime" "$BASE/main/api/upload?$qs" ||
      fail "$name: $(why)"
    MAXT=120
    return 0
  fi

  local part_bytes total parts n etag
  part_bytes=$((PART_MB * 1024 * 1024))
  total=$(( (size + part_bytes - 1) / part_bytes ))

  call -X POST -d "" "$BASE/main/api/upload?action=start&$qs&total=$total&type=$(enc "$mime")"
  [ "$CODE" = "200" ] || fail "$name: could not start the upload ($(why))"

  UPID="$(/usr/bin/printf %s "$RESP" | /usr/bin/tr -d '\r\n ')"
  [ -n "$UPID" ] || fail "$name: the server returned no upload id"

  parts=""
  n=1

  while [ "$n" -le "$total" ]; do
    /bin/dd if="$f" of="$TMP/chunk" bs=1048576 skip=$(( (n - 1) * PART_MB )) count="$PART_MB" 2>/dev/null
    notify "$name: part $n of $total"

    MAXT=900
    call_retry -X PUT -T "$TMP/chunk" -H "content-type: application/octet-stream" \
      "$BASE/main/api/upload?action=part&id=$ID&i=$i&uploadId=$(enc "$UPID")&part=$n&total=$total" ||
      fail "$name: part $n of $total failed ($(why))"
    MAXT=120

    etag="$(/usr/bin/printf %s "$RESP" | /usr/bin/tr -d '"\r\n ')"
    [ -n "$etag" ] || fail "$name: part $n returned no ETag"

    parts="$parts{\"partNumber\":$n,\"etag\":\"$etag\"},"
    n=$((n + 1))
  done

  rm -f "$TMP/chunk"

  call_retry -X POST -H "content-type: application/json" --data "[${parts%,}]" \
    "$BASE/main/api/upload?action=complete&id=$ID&i=$i&uploadId=$(enc "$UPID")" ||
    fail "$name: could not finish ($(why))"

  UPID=""
}

# smallest first, so photos are viewable while a big video is still going up
make_order() {
  ORDER=$(
    j=0
    for f in "${FILES[@]}"; do
      printf '%s %s\n' "$(fsize "$f")" "$j"
      j=$((j + 1))
    done | /usr/bin/sort -n | /usr/bin/cut -d' ' -f2
  )
}

run_uploads() {
  local idx ok=0 _

  for idx in $ORDER; do
    upload_one "${FILES[$idx]}" "$idx"
  done

  # -------------------------------------------------------------------
  # Check the gallery shows everything (informational only)
  # -------------------------------------------------------------------

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    case "$(/usr/bin/curl -sS --max-time 30 "$BASE/api/gallery?id=$ID" 2>/dev/null)" in
      *'"complete":true'*) ok=1; break ;;
    esac
    sleep 1
  done

  [ "$ok" = "1" ] || log "Warning: the gallery did not confirm every item within 10s"

  LIVE=0
  log "Done: $LINK"
  notify "All $COUNT file(s) uploaded."
}

# -------------------------------------------------------------------
# The detached copy: the link exists already, so it only uploads
# -------------------------------------------------------------------

if [ -n "$RESUME" ]; then
  ID="${GALLERY_ID:-}"
  LINK="${GALLERY_LINK:-}"
  [ -n "$ID" ] || fail "The upload helper started without a link."

  LIVE=1
  FILES=()

  while IFS= read -r f; do
    [ -n "$f" ] && FILES+=("$f")
  done < "$TMP/files.txt"

  COUNT="${#FILES[@]}"
  log "Detached uploader running for $LINK ($COUNT file(s), pid $$)"

  make_order
  run_uploads
  exit 0
fi

# -------------------------------------------------------------------
# Input: arguments, or one path per line on stdin
# -------------------------------------------------------------------

if [ "$#" -eq 0 ] && [ ! -t 0 ]; then
  while IFS= read -r -t 5 f || [ -n "$f" ]; do
    f="${f%$'\r'}"
    [ -n "$f" ] && set -- "$@" "$f"
    f=""
  done
fi

[ "$#" -gt 0 ] || fail "Nothing was selected. In Automator, set 'Pass input' to 'as arguments'."

# -------------------------------------------------------------------
# How long the link lasts (GALLERY_DAYS skips the question)
# -------------------------------------------------------------------

if [ -z "${GALLERY_DAYS:-}" ]; then
  pick="$(
    /usr/bin/osascript \
      -e 'choose from list {"1 day", "7 days", "30 days"} with title "Gallery" with prompt "Link expires after:" default items {"7 days"}' \
      2>/dev/null
  )"
  case "$pick" in
    "1 day") DAYS=1 ;;
    "7 days") DAYS=7 ;;
    "30 days") DAYS=30 ;;
    *) log "Cancelled at the expiry choice"; exit 0 ;;
  esac
  log "Expiry: $DAYS day(s)"
fi

# -------------------------------------------------------------------
# Already online: a folder (or anything inside one) in Gallery/Public
# -------------------------------------------------------------------

case "$1" in
  "$PUBLIC_DIR"/*)
    rel="${1#"$PUBLIC_DIR"/}"
    folder="${rel%%/*}"

    if [ "$folder" = "$rel" ] && [ -f "$1" ]; then
      fail "Put it in a folder inside Public first; each folder there is one link."
    fi

    for f in "$@"; do
      case "$f" in
        "$PUBLIC_DIR/$folder"|"$PUBLIC_DIR/$folder"/*) ;;
        *) fail "Choose items from one Public folder at a time." ;;
      esac
    done

    log "Public folder: $folder"
    call -X POST -d "" "$BASE/main/api/link?action=folder&name=$(enc "$folder")&days=$DAYS"

    case "$CODE" in
      200) ;;
      410) fail "\"$folder\" had expired, so it was deleted." ;;
      404) fail "\"$folder\" isn't online yet. Wait for it to finish copying, then try again." ;;
      *) fail "Could not get a link for \"$folder\" ($(why))" ;;
    esac

    path="$(json_field url)"
    [ -n "$path" ] || fail "The server sent no link back."

    LINK="$BASE$path"
    log "Folder link: $LINK"

    if /usr/bin/printf %s "$LINK" | /usr/bin/pbcopy; then
      notify "Link copied for \"$folder\". It expires with the folder."
    else
      toast_bg "$LINK"
    fi

    echo "$LINK"
    exit 0
    ;;
esac

# -------------------------------------------------------------------
# New link from files
# -------------------------------------------------------------------

FILES=("$@")
COUNT="$#"

for f in "${FILES[@]}"; do
  [ -f "$f" ] || fail "Not a file: $f (to share a folder, put it in Gallery/Public)"
done

# one line per file: size, taken (ms), type, name
: > "$TMP/items.txt"

for f in "${FILES[@]}"; do
  printf '%s\t%s\t%s\t%s\n' \
    "$(fsize "$f")" "$(( $(fmtime "$f") * 1000 ))" "$(enc "$(mime_of "$f")")" "$(enc "$(basename "$f")")" \
    >> "$TMP/items.txt"
done

log "Creating a live gallery for $COUNT file(s)"
call -X POST -H "content-type: text/plain" --data-binary "@$TMP/items.txt" \
  "$BASE/main/api/link?action=start&days=$DAYS"

[ "$CODE" = "200" ] || fail "Could not create the link ($(why))"

ID="$(json_field id)"
[ -n "$ID" ] || fail "The server sent no link back."

LIVE=1
LINK="$BASE/s/$ID"
log "Link: $LINK"

if /usr/bin/printf %s "$LINK" | /usr/bin/pbcopy; then
  COPIED="Link copied."
else
  COPIED="Link ready (couldn't copy it)."
fi

notify "$COPIED Uploading $COUNT file(s)..."
toast_bg "$COPIED

Your gallery is live: items appear as they finish uploading.

$LINK"

if [ "$OPEN_GALLERY" = "1" ]; then
  /usr/bin/open "$LINK" >/dev/null 2>&1 &
fi

# Foreground mode (for Terminal debugging): GALLERY_FOREGROUND=1
if [ "${GALLERY_FOREGROUND:-0}" = "1" ]; then
  make_order
  run_uploads
  echo "$LINK"
  exit 0
fi

# Normal mode: hand the uploads to a second copy of this script and return now, so the Quick Action
# finishes at once, the link is already on the clipboard, and the gallery fills in live.
# The copy gets its own session (perl's setsid; macOS has no setsid command), because Automator
# ends everything left in its own session when the action returns.
printf '%s\n' "${FILES[@]}" > "$TMP/files.txt"
KEEP_TMP=1

if [ -x /usr/bin/perl ]; then
  GALLERY_RESUME="$TMP" GALLERY_ID="$ID" GALLERY_LINK="$LINK" \
    /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/bash "$SELF" </dev/null >/dev/null 2>&1 &
else
  GALLERY_RESUME="$TMP" GALLERY_ID="$ID" GALLERY_LINK="$LINK" \
    nohup /bin/bash "$SELF" </dev/null >/dev/null 2>&1 &
fi

log "Uploads continuing in a detached process (pid $!)"
disown 2>/dev/null || true

echo "$LINK"
exit 0