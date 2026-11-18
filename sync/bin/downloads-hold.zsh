#!/bin/zsh
# Moves finished files from ~/Downloads to the gallery-tmp R2 bucket (auto-deleted by lifecycle rule).
# Derived from: owner 2026-11-17, "airdrops received by mac stay in downloads for 2 minutes before moving to tmp".
#
# Why this exists: the old agent ran `rclone move --min-age 2m`, and rclone's age is the file's MODIFIED time.
# AirDrop keeps the sender's modified time, so a file AirDropped today but made last week moved at once.
# Rule: a file the system marked as arriving through sharingd (AirDrop) ages from its ARRIVAL (the stamp inside its quarantine mark).
#   - due when now - arrival >= HOLD_SECONDS
#   - never moved if it was opened or renamed during the hold (it is the owner's now; it stays in Downloads)
#   - restart-safe: the clock is stored on the file itself, so a quit, reboot or missed run changes nothing
# Every other file keeps the old rule (modified at least 2 minutes ago, newer than MAX_AGE).
# Offline note: the move needs the network; a file simply stays until the next run (WatchPaths / 180 s).
#
# Run: zsh downloads-hold.zsh          (the launch agent does this)
#      zsh downloads-hold.zsh selftest (rule tests, then a real run on a temp folder)
#      zsh downloads-hold.zsh plan     (prints what would move, moves nothing)

HOLD_SECONDS=120                       # THE number: how long an AirDrop arrival stays in Downloads
OTHER_MIN_AGE=120                      # the old rule for everything else
MAX_AGE_ISO="2026-10-28T01:24:54Z"     # as before: files older than this never move
SELF=$0
DL=${DOWNLOADS:-$HOME/Downloads}
DEST=${HOLD_DEST:-gallery-tmp:gallery-tmp}
STATE=${HOLD_STATE:-$HOME/Library/Application Support/Recense/airdrop-hold.tsv}   # inode<TAB>name (rename detector)
LOG=${HOLD_LOG:-$HOME/Library/Logs/downloads-to-r2.log}
RCONF=${HOLD_RCONF-$HOME/.config/rclone/jobs.conf}   # HOLD_RCONF="$T/none.conf" = none (tests)

# The pure rule. Args: now birth mtime airdrop(1/0) lastused(epoch or 0) renamed(1/0)
# Prints "move" or "wait" or "keep" (keep = hands off for good: opened or renamed in the hold).
hold_rule() {
  local now=$1 birth=$2 mtime=$3 air=$4 used=$5 renamed=$6
  if [[ $air == 1 ]]; then
    [[ $renamed == 1 ]] && { echo keep; return }
    (( used > birth + 5 )) && { echo keep; return }        # 5 s of slack: the system stamps "last used" at arrival
    (( now - birth >= HOLD_SECONDS )) && echo move || echo wait
  else
    (( now - mtime >= OTHER_MIN_AGE )) && echo move || echo wait
  fi
}

skip_name() {   # the old --exclude list
  local f=$1
  [[ $f == */.* || $f == .* ]] && return 0
  case $f in *.crdownload|*.part|*.opdownload|*.download|*.download/*|*.tmp) return 0 ;; esac
  return 1
}

# Print the relative paths due to move, one per line (NUL-free; names with newlines are left alone).
due_list() {
  local now=${NOW:-$(date +%s)} maxage; maxage=$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$MAX_AGE_ISO" +%s)
  mkdir -p "${STATE:h}"; [[ -f $STATE ]] || : > "$STATE"
  local newstate; newstate=$(mktemp "${TMPDIR:-/tmp}/hold-state.XXXX")
  local f rel ino birth mtime air used renamed prev q d
  find "$DL" -type f -not -name '.*' 2>/dev/null | while IFS= read -r f; do
    rel=${f#$DL/}
    skip_name "$rel" && continue
    [[ $rel == *$'\n'* ]] && continue
    read -r ino birth mtime < <(stat -f '%i %B %m' "$f") || continue
    q=$(xattr -p com.apple.quarantine "$f" 2>/dev/null)
    air=0; [[ $q == *';sharingd;'* ]] && air=1
    # ARRIVAL = the stamp the system writes into the quarantine mark when sharingd delivers the file (hex seconds, second
    # field). Proven on the owner's Mac: birth time is NOT it (APFS pulls it back to the sender's old mtime), the stamp is.
    [[ $air == 1 ]] && birth=$(( 16#${${(s:;:)q}[2]} ))
    # the cut-off keeps the old backlog out: it reads the modified time, but an AirDrop file's is the sender's, so its arrival
    (( (air == 1 ? birth : mtime) < maxage )) && continue
    renamed=0; prev=$(awk -F'\t' -v i="$ino" '$1==i{print $2; exit}' "$STATE")
    if [[ $air == 1 ]]; then
      [[ $prev == KEEP ]] && renamed=1
      [[ -n $prev && $prev != KEEP && $prev != $rel ]] && renamed=1
      used=0
      d=$(mdls -raw -name kMDItemLastUsedDate "$f" 2>/dev/null); [[ $d == *"+0000"* ]] && used=$(date -j -u -f '%Y-%m-%d %H:%M:%S +0000' "$d" +%s 2>/dev/null || echo 0)
    fi
    local verdict; verdict=$(hold_rule "$now" "$birth" "$mtime" $air "${used:-0}" $renamed)
    if [[ $air == 1 ]]; then
      if [[ $verdict == keep ]]; then printf '%s\tKEEP\n' "$ino" >> "$newstate"; else printf '%s\t%s\n' "$ino" "$rel" >> "$newstate"; fi
    fi
    [[ $verdict == move ]] && print -r -- "$rel"
  done
  # state keeps only inodes still present (a deleted or moved file drops out)
  mv "$newstate" "$STATE"
}

move_due() {
  local list; list=$(mktemp "${TMPDIR:-/tmp}/hold-list.XXXX")
  due_list > "$list"
  if [[ ! -s $list ]]; then rm -f "$list"; return 0; fi
  [[ $1 == plan ]] && { cat "$list"; rm -f "$list"; return 0; }
  # a file already in the bucket under the same name is renamed aside (kept), never overwritten
  local -a cfg; [[ -n $RCONF ]] && cfg=(--config "$RCONF")
  /opt/homebrew/bin/rclone move "$DL" "$DEST" "${cfg[@]}" --files-from-raw "$list" \
    --suffix ".replaced-$(date +%Y%m%d-%H%M%S)" --suffix-keep-extension \
    --log-file "$LOG" --log-level INFO < /dev/null   # never wait for a password prompt
  local rc=$?; rm -f "$list"; return $rc
}

selftest() {
  local fail=0
  t() { local want=$1; shift; local got; got=$(hold_rule "$@"); [[ $got == $want ]] || { echo "FAIL rule $*: want $want got $got"; fail=1 }; }
  # now birth mtime air used renamed
  t wait 1000 950 1  1 0 0          # AirDrop, 50 s in, sender's mtime is last year: waits
  t wait 1000 950 100 1 0 0         # (mtime irrelevant for AirDrop)
  t wait 1069 950 1  1 0 0          # 119 s
  t move 1070 950 1  1 0 0          # exactly 120 s
  t move 5000 950 1  1 0 0          # long past: moves at once (restart case)
    t keep 1000 950 1  1 960 0        # opened 10 s after arrival: keep
  t keep 5000 950 1  1 0 1          # renamed: keep even when due
  t wait 1000 500 960 0 0 0         # not AirDrop: old rule, modified 40 s ago
  t move 1000 500 880 0 0 0         # not AirDrop: modified 120 s ago
  t move 1000 999 100 0 0 0         # not AirDrop: birth is irrelevant, mtime old
  # (the 951 case above is inside the 5 s slack so it must NOT be keep)
  [[ $(hold_rule 1000 950 1 1 951 0) == wait ]] && : || { echo "FAIL slack: want wait"; fail=1 }
  # real run: temp Downloads, local destination, real rclone
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/hold-real.XXXX")
  mkdir -p "$T/dl" "$T/dest"; : > "$T/none.conf"
  export DOWNLOADS="$T/dl" HOLD_DEST="$T/dest" HOLD_STATE="$T/state.tsv" HOLD_LOG="$T/log" HOLD_RCONF="$T/none.conf"
  local Q; Q=$(printf '0083;%x;sharingd;3238FECF-F0EA-486F-8DCD-A461CFF76411' $(date +%s))   # arrival = now, as sharingd stamps it
  echo air > "$T/dl/air.txt";  xattr -w com.apple.quarantine "$Q" "$T/dl/air.txt"; touch -t 202001010000 "$T/dl/air.txt"   # old sender mtime
  echo ren > "$T/dl/ren.txt";  xattr -w com.apple.quarantine "$Q" "$T/dl/ren.txt"
  echo web > "$T/dl/web.txt";  xattr -w com.apple.quarantine '0083;1;Safari;X' "$T/dl/web.txt"; touch -t 202611010000 "$T/dl/web.txt"
  echo clash-new > "$T/dl/dup.txt"; xattr -w com.apple.quarantine "$Q" "$T/dl/dup.txt"; echo clash-old > "$T/dest/dup.txt"
  zsh "$SELF" plan > "$T/p0"; [[ -z $(grep -E 'air|ren|dup' "$T/p0") ]] || { echo "FAIL real: AirDrop file due at t=0 (the old bug)"; fail=1 }
  grep -q web.txt "$T/p0" || { echo "FAIL real: non-AirDrop old file should be due"; fail=1 }
  mv "$T/dl/ren.txt" "$T/dl/ren2.txt"                       # renamed inside the hold
  zsh "$SELF" plan > "$T/p1"                                   # sees the rename
  local now0; now0=$(date +%s)
  NOW=$(( now0 + HOLD_SECONDS + 1 )) zsh "$SELF" plan > "$T/p2"
  grep -q '^air.txt$' "$T/p2" || { echo "FAIL real: air.txt not due after hold"; fail=1 }
  grep -q 'ren' "$T/p2" && { echo "FAIL real: renamed file would move"; fail=1 }
  NOW=$(( now0 + HOLD_SECONDS + 1 )) zsh "$SELF" >/dev/null 2>&1
  [[ -f $T/dest/air.txt && ! -e $T/dl/air.txt ]] || { echo "FAIL real: air.txt not moved"; fail=1 }
  [[ -f $T/dl/ren2.txt ]] || { echo "FAIL real: renamed file left Downloads"; fail=1 }
  [[ $(cat "$T/dest/dup.txt") == clash-new && $(ls "$T/dest" | grep -c '^dup\.replaced-.*\.txt$') == 1 ]] || { echo "FAIL real: name clash did not keep both"; ls "$T/dest"; fail=1 }
  rm -rf "$T"
  (( fail )) && { echo "downloads-hold selftest FAILED"; exit 1 }
  echo "downloads-hold selftest OK"
}

case ${1:-} in
  selftest) selftest ;;
  plan) move_due plan ;;
  *) move_due ;;
esac
