#!/bin/zsh
# Move Offsite: send images to R2 (notes-images, through Gallery's PUT /main/api/img), put the link on the
# clipboard, move the originals to the Trash once R2's SHA-256 matches the local file.
#
#   offsite-image.zsh [--md|--url] [--keep] [file…]    no files = the image on the clipboard
#
# Link form: --md gives ![](url), --url the bare URL; default = Markdown when the front app reads Markdown
# (Obsidian, DEVONthink, iA Writer, Typora, editors), else the URL.
# Auth: this Mac's Access service token in the Keychain (gallery-access). Log: ~/Library/Logs/offsite-image.log
set -u
API=${OFFSITE_API:-https://gallery.improvdiplomat.workers.dev/main/api/img}
LOG=~/Library/Logs/offsite-image.log
MD_APPS=(md.obsidian com.devon-technologies.think com.devon-technologies.think3 pro.writer.mac abnerworks.Typora
  com.microsoft.VSCode dev.zed.Zed com.sublimetext.4 com.coteditor.CotEditor com.barebones.bbedit)

form=auto keep=0
while [[ $# -gt 0 && $1 == --* ]]; do
  case $1 in --md) form=md ;; --url) form=url ;; --keep) keep=1 ;; *) print -u2 "unknown option $1"; exit 2 ;; esac
  shift
done

log() { print -r -- "$(date '+%F %T') $*" >> $LOG; }
note() { osascript -e "display notification \"${2//\"/}\" with title \"${1//\"/}\"" 2>/dev/null; }
fail() { log "FAIL $*"; note "Move Offsite failed" "$*"; print -u2 -- "$*"; exit 1; }

ID=$(security find-generic-password -s gallery-access -a client-id -w 2>/dev/null) || fail "no gallery-access token in the Keychain"
SEC=$(security find-generic-password -s gallery-access -a client-secret -w 2>/dev/null) || fail "no gallery-access secret in the Keychain"

if [[ $form == auto ]]; then
  front=$(lsappinfo info -only bundleid "$(lsappinfo front)" 2>/dev/null | sed -n 's/.*bundleID="\(.*\)".*/\1/p')
  form=url; (( ${MD_APPS[(Ie)$front]} )) && form=md
fi

tmp=$(mktemp -d -t offsite) || exit 1
trap 'rm -rf "$tmp"' EXIT

files=("$@") from_clip=0
if (( ! $#files )); then
  # clipboard → PNG file (screenshots copied with ⌃⇧⌘4, images copied in apps)
  osascript -e "set f to open for access (POSIX file \"$tmp/clipboard.png\") with write permission" \
    -e 'try' -e 'write (the clipboard as «class PNGf») to f' -e 'end try' -e 'close access f' >/dev/null 2>&1
  [[ -s $tmp/clipboard.png ]] || fail "no image on the clipboard"
  files=("$tmp/clipboard.png") from_clip=1
fi

links=() n=0
for f in $files; do
  [[ -f $f ]] || { log "skip (not a file) $f"; continue; }
  # macOS privacy (TCC) lets the file be seen but not read when Shortcuts has no access to its folder (Documents,
  # Desktop, Downloads): say what to allow instead of curl's "error encountered when reading a file"
  head -c 1 "$f" >/dev/null 2>&1 || fail "${f:t}: macOS blocked reading ${f:h:t}. Allow it: System Settings › Privacy & Security › Files & Folders › Shortcuts (or Full Disk Access › Shortcuts), then run Move Offsite again"
  name=${f:t}
  ext=${${name:e}:l}; [[ $from_clip == 1 ]] && ext=png
  resp=$(curl -sS --fail-with-body -X PUT --data-binary @"$f" \
    -H "CF-Access-Client-Id: $ID" -H "CF-Access-Client-Secret: $SEC" -H "X-Gallery: 1" \
    -H "Content-Type: application/octet-stream" \
    "$API?ext=${ext}&name=${name// /%20}" 2>&1) || fail "$name: upload refused: ${resp:0:200}"
  url=$(print -r -- $resp | plutil -extract url raw - 2>/dev/null)
  rsha=$(print -r -- $resp | plutil -extract sha256 raw - 2>/dev/null)
  lsha=$(shasum -a 256 "$f" | cut -c1-64)
  [[ -n $url && $rsha == $lsha ]] || fail "$name: R2 copy does not match (local $lsha, R2 ${rsha:-none})"
  if [[ $from_clip == 0 && $keep == 0 ]]; then
    trash "$f" 2>/dev/null || { log "uploaded but not trashed: $f"; note "Move Offsite" "$name is offsite but stayed here (Trash refused)"; }
  fi
  [[ $form == md ]] && links+=("![${name:r}]($url)") || links+=("$url")
  log "ok $form $f → $url"
  (( n++ ))
done
(( n )) || fail "nothing to send"

print -rn -- "${(F)links}" | pbcopy
print -r -- "${(F)links}"
note "Move Offsite" "$n image(s) offsite, link on the clipboard"
