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

# FEAT-24 lanes: screenshots and screen recordings follow the same hold-then-move rule (clock = last modified, which is the
# moment the system finished writing them; nothing here is delivered by AirDrop). Only files modified after LANE_SINCE are
# ever touched, so the owner's back catalogue stays where it is.
LANE_SINCE_ISO=${LANE_SINCE_ISO:-}      # empty = the moment the lanes first ran (stamped in ${STATE:r}-since), so the back catalogue is safe
SHOT_HOLD=120                          # a screenshot: long enough to paste or drag it
REC_HOLD=600                           # a recording: 10 min after it stops changing
SHOTS_DIR=${SHOTS_DIR:-$HOME/Documents/Screenshots}   # `defaults read com.apple.screencapture location`
RECS_DIR=${RECS_DIR:-$HOME/Recordings}                # where movies-to-recordings.sh routes video and audio
LANES_ON=${LANES_ON:-1}

# The pure lane rule. Args: now mtime hold since used(epoch|0) renamed tagged open  → ignore | keep | wait | move
lane_rule() {
  local now=$1 mtime=$2 hold=$3 since=$4 used=$5 renamed=$6 tagged=$7 open=$8
  (( mtime < since )) && { echo ignore; return }          # older than this feature: never touched
  [[ $renamed == 1 || $tagged == 1 ]] && { echo keep; return }   # the owner renamed or tagged it: theirs
  (( used > mtime + 5 )) && { echo keep; return }         # opened after it was written
  [[ $open == 1 ]] && { echo wait; return }               # still being written
  (( now - mtime >= hold )) && echo move || echo wait
}

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

# lane_due NAME DIR HOLD GLOB: prints the file names (top level of DIR) that are due.
lane_due() {
  local name=$1 dir=$2 hold=$3 glob=$4 mode=$5
  [[ -d $dir ]] || return 0
  local now=${NOW:-$(date +%s)} since st="${STATE:r}-$name.tsv"
  mkdir -p "${STATE:h}"; [[ -f $st ]] || : > "$st"
  if [[ -n $LANE_SINCE_ISO ]]; then since=$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$LANE_SINCE_ISO" +%s)
  else
    local sf="${STATE:r}-since"
    if [[ -s $sf ]]; then since=$(<"$sf"); else since=$now; [[ $mode == plan ]] || print -r -- "$now" > "$sf"; fi
  fi
  local ns; ns=$(mktemp "${TMPDIR:-/tmp}/lane-state.XXXX")
  local f b ino mtime prev renamed tagged used d open verdict
  for f in "$dir"/*(.N); do
    b=${f:t}
    [[ $b == ${~glob} ]] || continue
    read -r ino mtime < <(stat -f '%i %m' "$f") || continue
    prev=$(awk -F'\t' -v i="$ino" '$1==i{print $2; exit}' "$st")
    renamed=0; [[ $prev == KEEP ]] && renamed=1; [[ -n $prev && $prev != KEEP && $prev != $b ]] && renamed=1
    tagged=0; xattr -p com.apple.metadata:_kMDItemUserTags "$f" >/dev/null 2>&1 && tagged=1
    used=0; d=$(mdls -raw -name kMDItemLastUsedDate "$f" 2>/dev/null)
    [[ $d == *"+0000"* ]] && used=$(date -j -u -f '%Y-%m-%d %H:%M:%S +0000' "$d" +%s 2>/dev/null || echo 0)
    open=0; lsof -- "$f" >/dev/null 2>&1 && open=1
    verdict=$(lane_rule "$now" "$mtime" "$hold" "$since" "$used" $renamed $tagged $open)
    [[ $verdict == ignore ]] && continue
    if [[ $verdict == keep ]]; then printf '%s\tKEEP\n' "$ino" >> "$ns"; else printf '%s\t%s\n' "$ino" "$b" >> "$ns"; fi
    [[ $verdict == move ]] && print -r -- "$b"
  done
  mv "$ns" "$st"
}

# move_dir SRC DESTPATH LISTFILE
move_list() {
  local src=$1 dest=$2 list=$3
  local -a cfg; [[ -n $RCONF ]] && cfg=(--config "$RCONF")
  /opt/homebrew/bin/rclone move "$src" "$dest" "${cfg[@]}" --files-from-raw "$list" \
    --suffix ".replaced-$(date +%Y%m%d-%H%M%S)" --suffix-keep-extension \
    --log-file "$LOG" --log-level INFO < /dev/null
}

# one lane: NAME DIR HOLD PREFIX GLOB [plan]
run_lane() {
  local name=$1 dir=$2 hold=$3 prefix=$4 glob=$5 mode=$6
  local list; list=$(mktemp "${TMPDIR:-/tmp}/lane-list.XXXX")
  lane_due "$name" "$dir" "$hold" "$glob" "$mode" > "$list"
  if [[ -s $list ]]; then
    if [[ $mode == plan ]]; then sed "s|^|$name: |" "$list"; else move_list "$dir" "$DEST/$prefix" "$list"; fi
  fi
  rm -f "$list"
}

lanes() {
  [[ $LANES_ON == 1 ]] || return 0
  run_lane screenshots "$SHOTS_DIR" $SHOT_HOLD screenshots 'Screenshot *.(png|jpg|jpeg|heic)' "$1"
  run_lane screenrec   "$SHOTS_DIR" $REC_HOLD  recordings  'Screen Recording *.mov' "$1"
  run_lane recordings  "$RECS_DIR"  $REC_HOLD  recordings  '*.(mov|mp4|m4v|m4a|mp3|wav|aif|aiff|caf|flac|ogg|opus|webm|mkv)' "$1"
}

move_due() {
  local list; list=$(mktemp "${TMPDIR:-/tmp}/hold-list.XXXX")
  due_list > "$list"
  if [[ ! -s $list ]]; then rm -f "$list"; lanes "$1"; return 0; fi
  [[ $1 == plan ]] && { cat "$list"; rm -f "$list"; lanes plan; return 0; }
  # a file already in the bucket under the same name is renamed aside (kept), never overwritten
  local -a cfg; [[ -n $RCONF ]] && cfg=(--config "$RCONF")
  /opt/homebrew/bin/rclone move "$DL" "$DEST" "${cfg[@]}" --files-from-raw "$list" \
    --suffix ".replaced-$(date +%Y%m%d-%H%M%S)" --suffix-keep-extension \
    --log-file "$LOG" --log-level INFO < /dev/null   # never wait for a password prompt
  local rc=$?; rm -f "$list"; lanes "$1"; return $rc
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
  # lane rule: now mtime hold since used renamed tagged open
  l() { local want=$1; shift; local got; got=$(lane_rule "$@"); [[ $got == $want ]] || { echo "FAIL lane $*: want $want got $got"; fail=1 }; }
  l ignore 1000 100 120 500 0 0 0 0    # older than the feature: never touched
  l wait   1000 900 120 0 0 0 0 0      # 100 s old
  l move   1020 900 120 0 0 0 0 0      # exactly the hold
  l move   9000 900 120 0 0 0 0 0      # long past (restart)
  l keep   9000 900 120 0 0 1 0 0      # renamed
  l keep   9000 900 120 0 0 0 1 0      # tagged
  l keep   9000 900 120 0 910 0 0 0    # opened after it was written
  l move   9000 900 120 0 903 0 0 0    # 3 s of slack
  l wait   9000 900 120 0 0 0 0 1      # still open (being recorded)
  # real run: temp Downloads, local destination, real rclone
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/hold-real.XXXX")
  mkdir -p "$T/dl" "$T/dest"; : > "$T/none.conf"
  mkdir -p "$T/shots" "$T/recs"; export SHOTS_DIR="$T/shots" RECS_DIR="$T/recs" LANE_SINCE_ISO=2020-01-01T00:00:00Z
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
  # lanes, real: screenshot 200 s old, recording 200 s old, tagged shot, a page of the owner's own, a pre-feature shot
  local old; old=$(date -v-200S +%Y%m%d%H%M.%S)
  echo s > "$T/shots/Screenshot 2026-11-17 at 10.00.00.png"; touch -t $old "$T/shots/Screenshot 2026-11-17 at 10.00.00.png"
  echo s > "$T/shots/Screenshot tagged.png"; touch -t $old "$T/shots/Screenshot tagged.png"; xattr -w com.apple.metadata:_kMDItemUserTags x "$T/shots/Screenshot tagged.png"
  echo r > "$T/shots/Screen Recording 2026-11-17 at 10.01.00.mov"; touch -t $old "$T/shots/Screen Recording 2026-11-17 at 10.01.00.mov"
  echo p > "$T/shots/Drafting-Page_01.png"; touch -t $old "$T/shots/Drafting-Page_01.png"
  echo o > "$T/shots/Screenshot 2019.png"; touch -t 201901010000 "$T/shots/Screenshot 2019.png"
  echo v > "$T/recs/talk.m4a"; touch -t $old "$T/recs/talk.m4a"
  NOW=$(( $(date +%s) + 0 )) zsh "$SELF" >/dev/null 2>&1
  [[ ! -e "$T/shots/Screenshot 2026-11-17 at 10.00.00.png" && -f "$T/dest/screenshots/Screenshot 2026-11-17 at 10.00.00.png" ]] || { echo "FAIL lane: 200 s old screenshot not moved"; fail=1 }
  [[ -f "$T/shots/Screen Recording 2026-11-17 at 10.01.00.mov" && -f $T/recs/talk.m4a ]] || { echo "FAIL lane: recording left before its 10 min"; fail=1 }
  NOW=$(( $(date +%s) + REC_HOLD )) zsh "$SELF" >/dev/null 2>&1
  [[ -f "$T/dest/recordings/Screen Recording 2026-11-17 at 10.01.00.mov" && -f "$T/dest/recordings/talk.m4a" ]] || { echo "FAIL lane: recordings not moved after 10 min"; fail=1 }
  [[ -f "$T/shots/Screenshot tagged.png" && -f "$T/shots/Drafting-Page_01.png" && -f "$T/shots/Screenshot 2019.png" ]] || { echo "FAIL lane: tagged / owner's / old file moved"; fail=1 }
  rm -rf "$T"
  (( fail )) && { echo "downloads-hold selftest FAILED"; exit 1 }
  echo "downloads-hold selftest OK"
}

case ${1:-} in
  selftest) selftest ;;
  plan) move_due plan ;;
  *) move_due ;;
esac
