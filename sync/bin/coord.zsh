#!/bin/zsh
# coord: the coordinator is a file plus a lease (owner, 2026-11-18). No network, no AI call (except `spawn`).
#   Memory + rules: .handoff/coordinator/COORDINATOR.md (## 1 every session, ## 2 how to decide, ## 3 state)
#   Lease:          .handoff/coordinator/CURRENT (one line: "<id> · <name> · since <time> · by <who>" or "VACANT since <time>")
#   Panel:          .handoff/coordinator/PANEL (review judges, one line each)
#   Messages:       .handoff/coordinator/inbox/<yyyymmdd-hhmm>-<sender8>.md, handled ones in inbox/done/
#   Log:            ~/Recense/logs/coordinator.jsonl (the DebugChannel line shape)
# Verbs: who take retire post inbox done state-check reviewed join leave assign gate worktrees handoff-sweep
#        doctor hello spawn legacy-split trim selftest. Run `zsh coord.zsh help` for one line each.
# Hooks: SessionStart → `coord.zsh hello`, SessionEnd → `coord.zsh leave --hook`, Stop → doctor via coordinator-memory-check.
set -u
setopt null_glob extended_glob
unsetopt bg_nice
SELF=${0:A}

REPO=${COORD_REPO:-$HOME/Developer/recense}
H=${COORD_HOME:-$REPO/.handoff/coordinator}
Q=${COORD_QUEUE:-$REPO/.handoff/MERGE-QUEUE.md}
LOGS=${COORD_LOGS:-$HOME/Recense/logs}
ROOTS=(${=COORD_PROJECTS:-$HOME/.claude/projects $HOME/.claude-swap-backup/sessions/*/projects(N)})
SID=${CLAUDE_CODE_SESSION_ID:-${COORD_SID:-}}
GHOST=${COORD_GHOST:-9d8e0a68|chauphan-e0}
# the caps live here and nowhere else
CAP_LINES=220 CAP_BYTES=20480 CAP_TOP=40 CAP_WIDTH=160
LIVE_MIN=30 DEAD_MIN=360 BIG_TRANSCRIPT=${COORD_BIG:-3000000}

now() { date +%s; }
stamp() { date '+%Y-%m-%dT%H:%M'; }
mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
mins_since() { echo $(( ($(now) - $1) / 60 )); }

# one JSON line per event, same shape as shared/ShowsKit DebugChannel: {"t","feature","event","fields":{sorted}}
jq_s() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; print -rn -- "\"$s\""; }
log() {
  local ev=$1; shift
  local -a kv; local k body=""
  for k in "$@"; do kv+=("$k"); done
  for k in ${(o)kv}; do body+="${body:+,}$(jq_s ${k%%=*}):$(jq_s ${k#*=})"; done
  local t=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
  mkdir -p "$LOGS" 2>/dev/null
  print -r -- "{\"t\":\"$t\",\"feature\":\"coordinator\",\"event\":\"coordinator.$ev\",\"fields\":{$body}}" >> "$LOGS/coordinator.jsonl" 2>/dev/null
  return 0
}

# a mutex for read-check-write on coordinator files: mkdir is atomic
lock() { local d=$H/.$1.lock i=0; while ! mkdir "$d" 2>/dev/null; do (( ++i > 50 )) && { rm -rf "$d"; mkdir "$d" 2>/dev/null; break; }; sleep 0.1; done; }
unlock() { rmdir "$H/.$1.lock" 2>/dev/null; }

transcript() {   # newest transcript file of session $1, or nothing
  local id=$1 r f best="" bm=0
  [[ -z $id ]] && return
  for r in $ROOTS; do for f in $r/*/${id}*.jsonl(N); do (( $(mtime $f) > bm )) && { bm=$(mtime $f); best=$f; }; done; done
  print -r -- $best
}

# ---------- the lease ----------
holder_line() { [[ -f $H/CURRENT ]] && head -1 "$H/CURRENT" || print "VACANT since (never)"; }
holder_id() { local l=$(holder_line); [[ $l == VACANT* ]] && return; print -r -- ${${l%% · *}// /}; }
holder_name() { local l=$(holder_line); [[ $l == VACANT* ]] && return; local r=${l#* · }; print -r -- ${r%% · *}; }

state_of() {   # LIVE | QUIET | DEAD for session $1 (VACANT when empty); a fresh lease counts as LIVE
  local id=${1:-}
  [[ -z $id ]] && { print VACANT; return; }
  local tr=$(transcript $id) age=999999 lease=999999
  [[ -n $tr ]] && age=$(mins_since $(mtime $tr))
  [[ $id == $(holder_id) ]] && lease=$(mins_since $(mtime $H/CURRENT))
  (( lease < age )) && age=$lease
  if (( age < LIVE_MIN )); then print LIVE; elif (( age < DEAD_MIN )); then print QUIET; else print DEAD; fi
}

cmd_who() {
  local id=$(holder_id)
  case ${1:-} in
    --id) print -r -- $id; return ;;
    --name) print -r -- $(holder_name); return ;;
  esac
  [[ -z $id ]] && { print "VACANT · $(holder_line)"; return; }
  local tr=$(transcript $id) age="no transcript"
  [[ -n $tr ]] && age="transcript $(mins_since $(mtime $tr)) min ago, $(( $(stat -f %z $tr) / 1000000 )) MB"
  print "$(state_of $id) · $(holder_name) · $id · $age"
}

cmd_take() {
  local owner=0 name="" by=hook
  while (( $# )); do case $1 in --owner-said) owner=1; by=owner ;; *) name=$1 ;; esac; shift; done
  [[ -z $SID ]] && { print "take: no session id (CLAUDE_CODE_SESSION_ID)"; return 2; }
  [[ $REPO == *"/Library/Mobile Documents/"* ]] && { print "take: repo is inside iCloud Drive; mv is not atomic there"; return 2; }
  mkdir -p $H/archive
  lock take
  local cur=$(holder_id) st=$(state_of "$(holder_id)")
  if [[ -n $cur && $cur != $SID && $st == LIVE ]] && (( ! owner )); then
    unlock take; log standdown session=${SID[1,8]} holder=${cur[1,8]}
    print "STAND DOWN: $(holder_name) ($cur) holds the lease and is LIVE"; return 3
  fi
  [[ -z $name ]] && name=${COORD_NAME:-${SID[1,8]}}
  print -r -- "$(holder_line) · replaced $(stamp)" >> $H/archive/CURRENT.log
  print -r -- "$SID · $name · since $(stamp) · by $by" > $H/.CURRENT.$$ && mv -f $H/.CURRENT.$$ $H/CURRENT
  unlock take
  log take session=${SID[1,8]} previous=${cur[1,8]:-vacant} by=$by
  print "LEASE: $name ($SID) holds the coordinator lease."
  print "Next: read all of $H/COORDINATOR.md, then \`zsh $SELF inbox\`; \`done <file>\` each one handled; retire at your cap."
}

cmd_retire() {
  local force=0; [[ ${1:-} == --end || ${1:-} == --force ]] && force=1
  local cur=$(holder_id)
  [[ -n $cur && $cur != $SID ]] && (( ! force )) && { print "retire: you ($SID) do not hold the lease ($cur)"; return 2; }
  if ! cmd_state_check >/dev/null; then
    (( force )) || { cmd_state_check; print "retire: fix the state file first (it is the next holder's whole memory)"; return 1; }
    log retire.overcap session=${SID[1,8]}
  fi
  mkdir -p $H/archive
  print -r -- "$(holder_line) · retired $(stamp)" >> $H/archive/CURRENT.log
  print -r -- "VACANT since $(stamp)" > $H/.CURRENT.$$ && mv -f $H/.CURRENT.$$ $H/CURRENT
  log retire session=${SID[1,8]}
  print "VACANT: lease released."
}

# ---------- messages ----------
sign() { print -r -- "— Agent: claude · Session: ${SID:-unknown} · Dir: ${PWD}"; }

cmd_post() {   # post <file> (moved in) or post - (stdin); the sign line is added when missing
  local src=${1:-} kind=${2:-} f
  mkdir -p $H/inbox/done
  f=$H/inbox/$(date +%Y%m%d-%H%M)-${SID[1,8]:-unknown}${kind:+-$kind}
  local n=0 base=$f; while [[ -e $f.md ]]; do f=$base-$(( ++n )); done; f=$f.md
  if [[ $src == - || -z $src ]]; then cat > $f.tmp; else [[ -f $src ]] || { print "post: no file $src"; return 2; }; mv "$src" $f.tmp; fi
  grep -q '— Agent:' $f.tmp || sign >> $f.tmp
  mv $f.tmp $f
  log post file=${f:t} session=${SID[1,8]:-unknown}
  print "posted: inbox/${f:t}"
  local who=$(holder_name); [[ -n $who ]] && print "ping: SendMessage to \"$who\": new: inbox/${f:t}" || print "ping: no holder (VACANT); decide by COORDINATOR.md ## 2 after 10 min"
}

cmd_inbox() { local f; for f in $H/inbox/*.md(N.Om); do print -r -- "${f:t} · $(grep -m1 -v '^ *$' $f | cut -c1-110)"; done; }

cmd_done() {
  local f=${1:?done <file>}; f=${f:t}
  [[ -f $H/inbox/$f ]] || { print "done: no inbox/$f"; return 2; }
  mkdir -p $H/inbox/done; mv $H/inbox/$f $H/inbox/done/$f && log done file=$f && print "done: inbox/done/$f"
}

# ---------- the state file's caps ----------
cmd_state_check() {
  local f=${1:-$H/COORDINATOR.md} bad=0
  [[ -f $f ]] || { print "FAIL state: no $f"; return 1; }
  local lines=$(wc -l < $f | tr -d ' ') bytes=$(wc -c < $f | tr -d ' ')
  local top=$(awk '/^## 2/{exit} {n++} END{print n+0}' $f)
  local wide=$(awk -v w=$CAP_WIDTH '/^```/{c=!c; next} !c && length($0)>w {n++} END{print n+0}' $f)
  (( lines > CAP_LINES )) && { print "FAIL state: $lines lines (cap $CAP_LINES): collapse finished items to one line, move detail to archive/"; bad=1; }
  (( bytes > CAP_BYTES )) && { print "FAIL state: $bytes bytes (cap $CAP_BYTES)"; bad=1; }
  (( top > CAP_TOP )) && { print "FAIL state: ## 1 is $top lines (cap $CAP_TOP); every session reads it"; bad=1; }
  (( wide > 0 )) && { print "FAIL state: $wide lines over $CAP_WIDTH chars"; bad=1; }
  grep -qE '^[-* ]*Session:' $f && { print "FAIL state: a Session: line (agent-resume would revive a coordinator)"; bad=1; }
  (( bad )) || print "OK state: $lines lines, $bytes bytes, ## 1 $top lines"
  return $bad
}

# ---------- review ----------
queue_lines() { grep -F -- "$1" "$Q" 2>/dev/null; }
cmd_reviewed() {
  local br=${1:?reviewed <branch>} repo=${COORD_GIT:-$REPO}
  local tip=$(git -C $repo rev-parse --short=7 $br 2>/dev/null)
  local l=$(queue_lines "$br" | grep 'REVIEW: OK' | tail -1)
  [[ -z $l ]] && { print "reviewed no · $br tip ${tip:-?}"; return 1; }
  local c=$(print -r -- ${l##*REVIEW: OK} | grep -oE '\b[0-9a-f]{7,40}\b' | head -1)
  if [[ -n $c && -n $tip ]] && git -C $repo merge-base --is-ancestor $tip $c 2>/dev/null; then
    print "reviewed yes · at $c · tip $tip · current"; return 0
  fi
  print "reviewed yes · at ${c:-?} · tip $tip · STALE (commits after the review)"; return 1
}

panel_write() { print -r -- "$1" > $H/.PANEL.$$; mv -f $H/.PANEL.$$ $H/PANEL; }
cmd_join() {
  local id=${1:-$SID} name=${2:-${COORD_NAME:-${SID[1,8]}}}
  [[ -z $id ]] && return 2
  mkdir -p $H; touch $H/PANEL; lock panel
  if ! grep -q "^$id " $H/PANEL; then panel_write "$(cat $H/PANEL; print -r -- "$id · $name · joined $(stamp)")"; log join session=${id[1,8]}; fi
  unlock panel; sed -i '' '/^$/d' $H/PANEL
}
cmd_leave() {
  local hook=0; [[ ${1:-} == --hook ]] && { hook=1; shift; }
  local id=${1:-$SID}
  [[ -z $id ]] && return 0
  if [[ -f $H/PANEL ]]; then lock panel; panel_write "$(grep -v "^$id " $H/PANEL)"; unlock panel; sed -i '' '/^$/d' $H/PANEL; log leave session=${id[1,8]}; fi
  (( hook )) && [[ $(holder_id) == $id ]] && SID=$id cmd_retire --end >/dev/null
  return 0
}

author_of() { queue_lines "$1" | tail -1 | grep -oE 'Session: [0-9a-f]{8}' | tail -1 | cut -c10-; }
cmd_assign() {
  local br=${1:?assign <branch> [--risky]} risky=0; [[ ${2:-} == --risky ]] && risky=1
  local author=$(author_of $br) id sz best="" bsz=0 bopen=0 line
  [[ -f $H/PANEL ]] || { print "assign: no PANEL"; return 1; }
  while IFS= read -r line; do
    id=${line%% · *}; [[ -z $id ]] && continue
    [[ -n $author && $id == ${author}* ]] && continue
    [[ $(state_of $id) == LIVE ]] || continue
    local tr=$(transcript $id); sz=0; [[ -n $tr ]] && sz=$(stat -f %z $tr)
    local open=$(print -l $H/inbox/*-review-*-${id[1,8]}.md(N) | grep -c .)
    if [[ -z $best ]] || (( open < bopen || (open == bopen && sz < bsz) )); then best=$id; bsz=$sz; bopen=$open; fi
  done < $H/PANEL
  [[ -z $best ]] && { print "assign: no LIVE panel member other than the author (${author:-unknown}); use a fresh subagent judge"; log assign.none branch=$br; return 1; }
  local slug=${${br#work/}//[^A-Za-z0-9-]/-}
  local f=$H/inbox/$(date +%Y%m%d-%H%M)-review-$slug-${best[1,8]}.md
  mkdir -p $H/inbox/done
  { print "REVIEW REQUEST: $br @ $(git -C ${COORD_GIT:-$REPO} rev-parse --short=7 $br 2>/dev/null)"
    print "- Judge: $best (not the author ${author:-unknown}). Read only the diff and what it needs. Read-only: no builds."
    print "- Return triage lines: file:line · severity · evidence · proven/assumed/untested · smallest fix · its check."
    print "- Last line: REVIEW: OK <you> <commit>, or a fix list. Post it with \`coord.zsh post\`, then \`coord.zsh done ${f:t}\`."
    (( risky )) && print "- RISKY (data loss / sync / offline / concurrency): the holder adds one fresh subagent judge; both must say OK."
    sign; } > $f
  log assign branch=$br judge=${best[1,8]} risky=$risky
  print "assigned: $(grep "^$best " $H/PANEL | cut -d'·' -f2 | tr -d ' ') ($best) · inbox/${f:t}"
  (( risky )) && print "risky: add one fresh subagent judge as well"
  return 0
}

# ---------- merge gate ----------
features_touched() {   # registry blocks (docs/specs/PARITY.md) whose home: contains a changed file
  local br=$1 repo=${COORD_GIT:-$REPO} parity=${COORD_PARITY:-$REPO/docs/specs/PARITY.md}
  [[ -f $parity ]] || return
  local files=$(git -C $repo diff --name-only main...$br 2>/dev/null)
  awk -v files="$files" '
    BEGIN{ n=split(files, F, "\n") }
    /^<!-- parity:begin /{ feat=$3; next }
    /^home:/ && feat!="" { for (i=2;i<=NF;i++) { h=$i; gsub(/\*.*/,"",h); for (j=1;j<=n;j++) if (F[j]!="" && index(F[j],h)==1) hit[feat]=1 } }
    /^embodiments:/ && feat!="" { emb[feat]=substr($0, 14) }
    /^<!-- parity:end/{ feat="" }
    END{ for (f in hit) print f " · " emb[f] }' $parity
}
cmd_gate() {
  local br=${1:?gate <branch> [--dry]} dry=0 repo=${COORD_GIT:-$REPO} rc=0; [[ ${2:-} == --dry ]] && dry=1
  git -C $repo merge-base --is-ancestor $br main 2>/dev/null && print "merged yes" || print "merged no"
  cmd_reviewed $br || rc=1
  local mt; mt=$(git -C $repo merge-tree --write-tree --name-only main $br 2>&1)
  if (( $? == 0 )); then print "conflicts none"; else print "conflicts: $(print -r -- $mt | sed -n '2,/^$/p' | tr '\n' ' ')"; rc=1; fi
  local f; while IFS= read -r f; do
    [[ -z $f ]] && continue
    print "feature ${f}"
    (( dry )) && { print "  check: zsh $REPO/sync/bin/triage-merge.zsh checks ${f%% *}"; continue; }
    if zsh $REPO/sync/bin/triage-merge.zsh checks ${f%% *} > $TMPDIR/coord-gate-${f%% *}.log 2>&1; then print "  checks PASS"; else print "  checks FAIL (tail $TMPDIR/coord-gate-${f%% *}.log)"; rc=1; fi
  done <<< "$(features_touched $br)"
  log gate branch=$br rc=$rc
  return $rc
}

# ---------- maintenance (print only) ----------
REGEN='node_modules|\.playwright-browsers|\.toolchain|\.scratch|Secrets'
cmd_worktrees() {
  local repo=${COORD_GIT:-$REPO} p b
  git -C $repo worktree list --porcelain | awk '/^worktree /{p=$2} /^branch /{print p" "substr($2,12)} /^detached/{print p" -"}' |
  while read -r p b; do
    [[ $p == ${repo:A} ]] && continue
    local why="" size=$(du -sh $p 2>/dev/null | cut -f1)
    [[ $b == - ]] && why="detached"
    [[ -z $why ]] && ! git -C $repo merge-base --is-ancestor $b main 2>/dev/null && why="unmerged"
    [[ -z $why && -n $(git -C $p status --porcelain 2>/dev/null | grep -vE "^\?\? .*($REGEN)") ]] && why="has edits"
    if [[ -z $why ]]; then print "remove $p ($b, $size): git worktree remove --force $p && git branch -d $b"; else print "keep $p ($b, $size): $why"; fi
  done
  print "(cwd check: a process inside a worktree is invisible to the sandbox; run lsof +D <path> outside it before removing)"
}
cmd_handoff_sweep() {
  local hd=${COORD_HANDOFF:-$REPO/.handoff} repo=${COORD_GIT:-$REPO} d f
  for d in $hd/*(N/); do
    local n=${d:t}; [[ $n == (coordinator|coord-stateless|prototypes) ]] && continue
    if git -C $repo rev-parse -q --verify work/$n >/dev/null && git -C $repo merge-base --is-ancestor work/$n main; then
      print "move $d (work/$n merged) → ~/.claude/context/recense/handoff/lanes/$n"
    elif (( $(mins_since $(mtime $d)) > 7*24*60 )) && ! git -C $repo rev-parse -q --verify work/$n >/dev/null; then
      print "stale $d (no branch, untouched 7+ days)"
    fi
  done
  for f in $hd/*(N.); do
    [[ ${f:t} == (LANES.md|MERGE-QUEUE.md|MERGE-QUEUE-archive.md|HANDOFF.md|CHAT.md|build.lock|.notes_sync) ]] && continue
    print "loose $f ($(du -h $f | cut -f1))"
  done
}

# ---------- trim and split (moves; each verifies nothing was lost) ----------
cmd_trim() {   # trim <file> <archive> <egrep pattern>: matching lines move to the archive, verbatim
  local f=${1:?trim <file> <archive> <pattern>} a=${2:?} pat=${3:?} t=$TMPDIR/coord-trim.$$
  [[ -f $f ]] || { print "trim: no $f"; return 2; }
  grep -E -- "$pat" $f > $t.moved; grep -vE -- "$pat" $f > $t.kept
  local n=$(wc -l < $t.moved | tr -d ' ')
  (( n == 0 )) && { print "trim: nothing matches"; rm -f $t.*; return 0; }
  if [[ $(cat $t.kept $t.moved | sort | shasum) != $(sort $f | shasum) ]]; then print "trim: VERIFY FAILED, nothing changed"; rm -f $t.*; return 1; fi
  { [[ -f $a ]] || print "# Archive of ${f:t} (moved verbatim by coord.zsh trim)"; cat $t.moved; } >> $a
  mv $t.kept $f; rm -f $t.moved
  log trim file=${f:t} moved=$n
  print "trim: moved $n lines to $a; verify OK"
}

legacy_classify() {   # CLOSED | OPEN? | INFO | STALE for one entry file; $2 = its date (yyyymmdd)
  local e=$1 day=${2:-0} repo=${COORD_GIT:-$REPO} cutoff=${COORD_STALE_BEFORE:-20261117}
  local head=$(head -1 $e)
  if grep -qE 'MERGED|REVIEW: OK' <<< $head; then print CLOSED; return; fi
  local b open=0 merged=0 named=0 live=0
  for b in ${(u)$(grep -oE 'work/[A-Za-z0-9._-]*[A-Za-z0-9]' $e)}; do
    named=$(( named + 1 ))
    if git -C $repo merge-base --is-ancestor $b main 2>/dev/null; then merged=$(( merged + 1 ))
    elif git -C $repo rev-parse -q --verify $b >/dev/null 2>&1; then live=1; fi   # a branch that still exists, unmerged
  done
  grep -qiE 'READY FOR REVIEW|^## .*PLAN|for your OK|waits on|awaiting|\?$|\? |FIXED' $e && open=1
  if (( named > 0 && merged == named )); then print CLOSED
  elif (( day > 0 && day < cutoff && ! live )); then print STALE   # older than the cutoff and names no live branch
  elif (( open || live )); then print 'OPEN?'
  else print INFO; fi
}
cmd_legacy_split() {   # legacy-split <INBOX.md> [--dry] : one file per "## " entry; OPEN? → inbox/, rest → inbox/done/
  local src=${1:?legacy-split <INBOX.md> [--dry]} dry=0; [[ ${2:-} == --dry ]] && dry=1
  local w=$TMPDIR/coord-split.$$; rm -rf $w; mkdir -p $w
  awk -v w=$w 'BEGIN{n=1; f=sprintf("%s/%04d", w, n)} /^## /{ if (seen) { n++; f=sprintf("%s/%04d", w, n) } seen=1 } { print > f }' $src
  local e cls name h d s total=0 o=0 c=0 i=0; local -a manifest
  for e in $w/<->(n); do
    (( total++ ))
    h=$(grep -m1 '^## ' $e); d=$(print -r -- $h | grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2})?' | head -1)
    s=$(grep -oE 'Session: [0-9a-f]{8}' $e | tail -1 | cut -c10-); [[ -z $s ]] && s=unknown
    name="${${${d:-00000000}//-/}// /-}-${s}-${e:t}.md"; name=${name//:/}
    cls=$(legacy_classify $e ${${${d:-0}//-/}[1,8]})
    if [[ $cls == 'OPEN?' ]]; then o=$(( o + 1 )); else c=$(( c + 1 )); fi
    manifest+=("$cls $name")
    (( dry )) && print -r -- "$cls · $name · $(wc -l < $e | tr -d ' ') lines · ${h:0:90}"
  done
  local sum_src=$(shasum -a 256 < $src | cut -c1-64) sum_parts=$(cat $w/<->(n) | shasum -a 256 | cut -c1-64)
  [[ $sum_src == $sum_parts ]] || { print "legacy-split: SHA MISMATCH, nothing written"; rm -rf $w; return 1; }
  print "legacy-split: $total entries · OPEN? $o · CLOSED/INFO/STALE $c · sha-256 of the pieces == original"
  if (( ! dry )); then
    mkdir -p $H/inbox/done $H/archive; i=0
    for e in $w/<->(n); do
      cls=${manifest[++i]%% *}; name=${manifest[i]#* }
      [[ $cls == 'OPEN?' ]] && mv $e $H/inbox/$name || mv $e $H/inbox/done/$name
      print -r -- "$cls ${name}" >> $H/archive/legacy-manifest.txt
    done
    # re-verify from where the pieces landed, in manifest order
    local again=$(while read -r cls name; do [[ $cls == 'OPEN?' ]] && cat $H/inbox/$name || cat $H/inbox/done/$name; done < $H/archive/legacy-manifest.txt | shasum -a 256 | cut -c1-64)
    [[ $again == $sum_src ]] || { print "legacy-split: LANDED SHA MISMATCH; the original is untouched"; return 1; }
    log split entries=$total open=$o
    print "legacy-split: written and re-verified; the original can go to the Trash: trash $src"
  fi
  rm -rf $w
}

# ---------- doctor: the bug-detection loop (run by the Stop hook) ----------
routing_files() { print -l ${=COORD_ROUTING:-$HOME/.claude/CLAUDE.md $REPO/.handoff/LANES.md $H/COORDINATOR.md $REPO/.handoff/listen/HANDOFF.md $REPO/.handoff/shows/HANDOFF.md}; }
cmd_doctor() {
  local fix=0 bad=0 out f; [[ ${1:-} == --fix ]] && fix=1
  ok() { print "OK   $1"; }; ko() { print "FAIL $1"; bad=1; }
  # 1 lease
  local id=$(holder_id) st=$(state_of "$(holder_id)")
  if [[ ! -f $H/CURRENT ]]; then ko "1 lease: no CURRENT · fix: zsh $SELF take"
  elif [[ $st == DEAD ]]; then ko "1 lease: holder $id is DEAD · fix: a main-checkout session runs: zsh $SELF take"
  else ok "1 lease: $st${id:+ $id}"; fi
  # 2 caps
  out=$(cmd_state_check); [[ $? == 0 ]] && ok "2 $out" || ko "2 ${out//$'\n'/ · }"
  # 3 old open messages
  local old=($H/inbox/*.md(N.mh+24)); (( ${#old} )) && ko "3 inbox: ${#old} files open over 24 h (${old[1]:t}) · fix: handle, then coord done" || ok "3 inbox: none over 24 h"
  # 4 ghost routing
  local hits=$(routing_files | while read -r f; do [[ -f $f ]] && grep -lE -- "$GHOST" $f; done)
  [[ -n $hits ]] && ko "4 ghost: ${hits//$'\n'/ } name an abandoned coordinator" || ok "4 ghost: none"
  # 5 merge queue trimmed
  local m=$(grep -cE '^- .*MERGED' $Q 2>/dev/null); m=${m:-0}
  (( m > 0 )) && ko "5 queue: $m MERGED lines · fix: zsh $SELF trim $Q ${Q:r}-archive.md '^- .*MERGED'" || ok "5 queue: no MERGED lines"
  # 6 double holder: two takes by different sessions within 10 min with no standdown between
  local dbl=$(tail -200 $LOGS/coordinator.jsonl 2>/dev/null | python3 -I -c '
import sys, json, datetime
last=None
for l in sys.stdin:
    try: r=json.loads(l)
    except Exception: continue
    ev=r.get("event"); s=r.get("fields",{}).get("session"); t=datetime.datetime.fromisoformat(r["t"].replace("Z","+00:00"))
    if ev=="coordinator.standdown": last=None
    elif ev=="coordinator.take":
        if last and last[0]!=s and (t-last[1]).total_seconds()<600 and r["fields"].get("by")!="owner": print(last[0], s); last=None; continue
        last=(s,t)')
  [[ -n $dbl ]] && ko "6 double holder: $dbl took the lease within 10 min" || ok "6 double holder: none"
  # 7 the Stop hook knows the lease (regression: it once matched only "(coordinator)" and never fired)
  local hk=${COORD_HOOK:-$HOME/.local/bin/coordinator-memory-check}
  grep -q 'coord.zsh' $hk 2>/dev/null && ok "7 hook: reads the lease" || ko "7 hook: $hk does not call coord.zsh (role check is blind)"
  # 8 review requests unanswered over 10 min
  local rq=($H/inbox/*-review-*.md(N.mm+10)); (( ${#rq} )) && ko "8 review: ${#rq} requests unanswered 10+ min (${rq[1]:t}) · fix: reassign once, then mark UNREVIEWED" || ok "8 review: none waiting"
  # 9 a REVIEW: OK older than its branch tip
  local stale="" br
  for br in ${(u)$(grep 'REVIEW: OK' $Q 2>/dev/null | grep -v MERGED | grep -oE '^- work/[A-Za-z0-9._/-]+' | cut -c3-)}; do
    git -C ${COORD_GIT:-$REPO} rev-parse -q --verify $br >/dev/null || continue
    cmd_reviewed $br | grep -q STALE && stale+="$br "
  done
  [[ -n $stale ]] && ko "9 review: OK older than the tip on $stale" || ok "9 review: none stale"
  # the fixable-by-script part: dead panel members leave
  if (( fix )) && [[ -f $H/PANEL ]]; then
    local pid; for pid in ${(f)"$(cut -d' ' -f1 $H/PANEL)"}; do [[ -n $pid && $(state_of $pid) == DEAD ]] && cmd_leave $pid; done
  fi
  log doctor bad=$bad
  return $bad
}

# ---------- hooks ----------
hook_field() { python3 -I -c 'import sys,json
try: print(json.load(sys.stdin).get(sys.argv[1],""))
except Exception: print("")' "$1"; }

cmd_hello() {   # SessionStart: context for every session; take or join for Recense sessions. Never fails the session.
  local js=$(cat 2>/dev/null) id cwd role=""
  id=$(print -r -- $js | hook_field session_id); cwd=$(print -r -- $js | hook_field cwd)
  [[ -n $id ]] && SID=$id
  cwd=${${cwd:-$PWD}:A}
  if [[ $cwd == ${REPO:A}/.claude/worktrees/* ]]; then cmd_join >/dev/null 2>&1; role="worker + review panel member"
  elif [[ $cwd == ${REPO:A} || $cwd == ${REPO:A}/* ]]; then
    local st=$(state_of "$(holder_id)")
    if [[ $st == (VACANT|DEAD) ]] && cmd_take >/dev/null 2>&1; then role="coordinator (you took the free lease: read all of COORDINATOR.md, then coord.zsh inbox)"
    elif [[ $(holder_id) == $SID ]]; then role="coordinator (you hold the lease)"
    else role="worker in the main checkout"; fi
  fi
  local top=""; [[ -f $H/COORDINATOR.md ]] && top=$(awk '/^## 2/{exit} {print}' $H/COORDINATOR.md)
  local ctx="Recense coordinator: $(cmd_who)${role:+. Your role: $role}. Script: zsh $SELF (post, inbox, who). Never ask the owner for a session id.
$top"
  python3 -I -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":sys.argv[1]}}))' "$ctx"
  log hello session=${SID[1,8]:-unknown} role=${role%% *}
  return 0
}

cmd_spawn() {   # one fresh headless coordinator when the lease is free and work waits; at most one per hour
  local st=$(state_of "$(holder_id)")
  [[ $st == (VACANT|DEAD) ]] || { print "skip: holder is $st"; return 0; }
  local waiting=($H/inbox/*.md(N.mm+10)); (( ${#waiting} )) || { print "skip: nothing waiting 10+ min"; return 0; }
  local fails=$(cat $H/.spawn.fail 2>/dev/null || print 0)
  (( fails >= 3 )) && { print "skip: 3 failed spawns; fix, then trash $H/.spawn.fail"; return 0; }
  (( $(now) - $(mtime $H/.spawn.last) < 3600 )) && { print "skip: one spawn per hour"; return 0; }
  mkdir $H/.spawn.lock 2>/dev/null || { print "skip: a spawn is running"; return 0; }
  touch $H/.spawn.last
  local p="You are a fresh Recense coordinator started because work is waiting and nobody holds the lease. Run: zsh $SELF take. Then read all of $H/COORDINATOR.md, run zsh $SELF inbox, handle each file by the rules in its ## 2 (merges only after REVIEW: OK; code decisions by agent consensus, never the owner), record decisions in its ## 3, run zsh $SELF done <file> for each, then zsh $SELF retire. Do not resume any older session."
  local run=${COORD_CLAUDE:-claude} out=${COORD_SPAWN_LOG:-$HOME/Library/Logs/coord-spawn.log}
  ( cd $REPO && $run -p "$p" --permission-mode auto >> $out 2>&1; rc=$?
    if (( rc )); then print $(( fails + 1 )) > $H/.spawn.fail
      (( fails + 1 >= 3 )) && osascript -e 'display notification "3 coordinator spawns failed: see ~/Library/Logs/coord-spawn.log" with title "coord"' 2>/dev/null
    else rm -f $H/.spawn.fail; fi
    rmdir $H/.spawn.lock ) &!
  log spawn waiting=${#waiting}
  print "spawned: fresh coordinator (log $out)"
}

# ---------- selftest ----------
selftest() {
  local fail=0 T=$(mktemp -d "${TMPDIR:-/tmp}/coord-test.XXXX")
  export COORD_HOME=$T/h COORD_QUEUE=$T/q.md COORD_LOGS=$T/logs COORD_PROJECTS=$T/projects COORD_GIT=$T/repo COORD_REPO=$T/repo
  export COORD_ROUTING="$T/routing.md" COORD_HOOK=$T/hook COORD_PARITY=$T/parity.md COORD_HANDOFF=$T/handoff
  mkdir -p $T/h $T/projects/p $T/handoff
  t() { local name=$1 want=$2 got=$3; [[ $got == *$want* ]] || { print "FAIL $name: want '$want' got '${got[1,200]}'"; fail=1; }; }
  run() { zsh $SELF "$@" 2>&1; }
  # who / take / standdown / retire
  t who-vacant VACANT "$(run who)"
  t take-needs-id "no session id" "$(CLAUDE_CODE_SESSION_ID= COORD_SID= run take)"
  t take "LEASE" "$(CLAUDE_CODE_SESSION_ID=aaaaaaaa-1 run take)"
  t who-live "LIVE" "$(run who)"
  t standdown "STAND DOWN" "$(CLAUDE_CODE_SESSION_ID=bbbbbbbb-2 run take)"
  t owner-said "LEASE" "$(CLAUDE_CODE_SESSION_ID=bbbbbbbb-2 run take --owner-said)"
  t who-id "bbbbbbbb-2" "$(run who --id)"
  touch -t 202601010000 $T/h/CURRENT
  t dead "DEAD" "$(run who)"
  print -r -- '- a line' > $T/h/COORDINATOR.md
  t retire-not-holder "do not hold" "$(CLAUDE_CODE_SESSION_ID=cccccccc-3 run retire)"
  t retire "VACANT" "$(CLAUDE_CODE_SESSION_ID=bbbbbbbb-2 run retire)"
  # race: two takes at once leave exactly one holder; the other stands down
  ( CLAUDE_CODE_SESSION_ID=dddddddd-4 zsh $SELF take > $T/r1 2>&1 ) & ( CLAUDE_CODE_SESSION_ID=eeeeeeee-5 zsh $SELF take > $T/r2 2>&1 ) & wait
  t race-one-lease 1 "$(cat $T/r1 $T/r2 | grep -c LEASE)"
  t race-one-standdown 1 "$(cat $T/r1 $T/r2 | grep -c 'STAND DOWN')"
  # caps
  print '## 1\n- x\n## 2\n- y' > $T/c.md; t cap-ok "OK state" "$(run state-check $T/c.md)"
  { print '## 1'; for i in {1..41}; do print -r -- "- $i"; done; print '## 2'; } > $T/c.md; t cap-top "## 1 is" "$(run state-check $T/c.md)"
  { print '## 1'; print '## 2'; for i in {1..221}; do print -r -- "- $i"; done; } > $T/c.md; t cap-lines "lines (cap 220)" "$(run state-check $T/c.md)"
  { print '## 1'; print '## 2'; for i in {1..150}; do print -r -- "- ${(l:140::x::x:)${:-}}"; done; } > $T/c.md; t cap-bytes "bytes (cap 20480)" "$(run state-check $T/c.md)"
  { print '## 1'; print -r -- "- ${(l:170::x::x:)${:-}}"; } > $T/c.md; t cap-width "over 160" "$(run state-check $T/c.md)"
  print '## 1\n- Session: 1234' > $T/c.md; t cap-session "Session:" "$(run state-check $T/c.md)"
  # post / inbox / done
  print 'PLAN: a test' > $T/msg.md
  t post "posted: inbox/" "$(CLAUDE_CODE_SESSION_ID=ffffffff-6 run post $T/msg.md)"
  t post-moved "" "$([[ -e $T/msg.md ]] && print COPIED)"; [[ -e $T/msg.md ]] && { print "FAIL post copied instead of moving"; fail=1; }
  t post-signed "Session: ffffffff-6" "$(cat $T/h/inbox/*.md)"
  mkdir -p $T/h/inbox/done; print 'old' > $T/h/inbox/done/x.md
  t inbox-list "PLAN: a test" "$(run inbox)"; t inbox-skips-done 1 "$(run inbox | grep -c .)"
  local pf=$(ls $T/h/inbox/*.md | head -1)
  t done "done: inbox/done/" "$(run done ${pf:t})"; [[ -e $pf ]] && { print "FAIL done left the file"; fail=1; }
  # a git fixture: main, a merged branch, a reviewed branch, a stale review, a conflict
  git init -q -b main $T/repo && cd $T/repo && git config user.email t@t && git config user.name t
  mkdir -p shared/x && print a > shared/x/f.txt && git add . && git commit -qm base
  git checkout -qb work/merged && print b >> shared/x/f.txt && git commit -qam m && git checkout -q main && git merge -q --no-ff --no-edit work/merged
  git checkout -qb work/rev && print c > other.txt && git add . && git commit -qm r && local revtip=$(git rev-parse --short=7 HEAD)
  git checkout -qb work/stale && print d >> other.txt && git commit -qam s
  git checkout -q main && git checkout -qb work/clash && print X > shared/x/f.txt && git commit -qam clash
  git checkout -q main && print Y > shared/x/f.txt && git commit -qam main-side
  cd - >/dev/null
  print -l -- "- work/rev · thing · REVIEW: OK judge $revtip — Agent: claude · Session: 11111111-a" \
           "- work/stale · thing · REVIEW: OK judge $revtip — Agent: claude · Session: 22222222-b" \
           "- work/old · thing · MERGED abc1234" > $T/q.md
  t reviewed-current "current" "$(run reviewed work/rev)"
  t reviewed-stale "STALE" "$(run reviewed work/stale)"
  t reviewed-none "reviewed no" "$(run reviewed work/clash)"
  print -l -- '<!-- parity:begin xfeat -->' 'feature: xfeat' 'home: shared/x/' 'embodiments: mac=[x] iphone=[ ]' '<!-- parity:end -->' > $T/parity.md
  local g=$(run gate work/clash --dry)
  t gate-unmerged "merged no" "$g"; t gate-conflict "conflicts:" "$g"; t gate-feature "feature xfeat · mac=[x] iphone=[ ]" "$g"
  t gate-merged "merged yes" "$(run gate work/merged --dry)"
  # panel: join (parallel, no lost line), assign skips the author and dead members, leave
  ( CLAUDE_CODE_SESSION_ID=11111111-a zsh $SELF join ) & ( CLAUDE_CODE_SESSION_ID=33333333-c zsh $SELF join ) & wait
  t join-both 2 "$(grep -c . $T/h/PANEL)"
  print x > $T/projects/p/11111111-a.jsonl; print xx > $T/projects/p/33333333-c.jsonl
  t assign-not-author "33333333-c" "$(run assign work/rev)"
  t assign-file "REVIEW REQUEST" "$(cat $T/h/inbox/*-review-rev-33333333.md)"
  CLAUDE_CODE_SESSION_ID=33333333-c run leave >/dev/null
  t assign-none "no LIVE panel member" "$(run assign work/rev)"
  t leave "11111111-a" "$(cat $T/h/PANEL)"
  # trim: moves, verifies
  t trim "moved 1 lines" "$(run trim $T/q.md $T/q-archive.md '^- .*MERGED')"
  t trim-kept 2 "$(grep -c . $T/q.md)"; t trim-archived "MERGED abc1234" "$(cat $T/q-archive.md)"
  # legacy-split: pieces re-assemble to the original; open items land in inbox/
  print -l -- '# Inbox' 'preamble' '## 2026-11-08 10:30 · PLAN for your OK' 'body' '— Agent: claude · Session: 44444444-d · Dir: x' \
           '## 2026-11-09 · status MERGED work/merged' 'done' '## 2026-11-10 · heads-up' 'fyi' '## 2026-11-11 · READY FOR REVIEW: work/rev' 'x' > $T/INBOX.md
  t split-dry "4 entries · OPEN? 1 · CLOSED/INFO/STALE 3" "$(run legacy-split $T/INBOX.md --dry)"
  t split-nocutoff "OPEN? 2" "$(COORD_STALE_BEFORE=0 run legacy-split $T/INBOX.md --dry)"
  t split-stale "STALE · 20261108" "$(run legacy-split $T/INBOX.md --dry)"
  rm -rf $T/h/inbox; t split "re-verified" "$(run legacy-split $T/INBOX.md)"
  t split-open 1 "$(ls $T/h/inbox/*.md | grep -c .)"; t split-done 3 "$(ls $T/h/inbox/done/*.md | grep -c .)"
  t split-sender "44444444" "$(ls $T/h/inbox/done/)"
  # doctor: each invariant fails on a bad fixture
  print 'coordinator 9d8e0a68 lives here' > $T/routing.md; print '' > $T/hook
  local d=$(run doctor)
  t doc-ghost "FAIL 4 ghost" "$d"; t doc-hook "FAIL 7 hook" "$d"; t doc-review-stale "FAIL 9 review" "$d"
  print 'nothing' > $T/routing.md; print 'zsh coord.zsh who --id' > $T/hook
  d=$(run doctor); t doc-ghost-ok "OK   4 ghost" "$d"; t doc-hook-ok "OK   7 hook" "$d"
  print -r -- '- work/z · MERGED' >> $T/q.md; t doc-queue "FAIL 5 queue" "$(run doctor)"
  touch -t 202601010000 $T/h/inbox/*.md(N[1]); t doc-old "FAIL 3 inbox" "$(run doctor)"
  # double holder in the log
  print -l -- '{"t":"2026-11-18T10:00:00.000Z","feature":"coordinator","event":"coordinator.take","fields":{"by":"hook","session":"aaaa"}}' \
           '{"t":"2026-11-18T10:03:00.000Z","feature":"coordinator","event":"coordinator.take","fields":{"by":"hook","session":"bbbb"}}' >> $T/logs/coordinator.jsonl
  t doc-double "FAIL 6 double holder" "$(run doctor)"
  # log lines have the DebugChannel shape
  t log-shape '"feature":"coordinator","event":"coordinator.take","fields":{' "$(grep -m1 coordinator.take $T/logs/coordinator.jsonl)"
  # hello: a worktree session joins; a main-checkout session takes a free lease; output is hook JSON
  print -l -- '## 1 · Every session' '- read me' '## 2 · decide' '- rules' > $T/h/COORDINATOR.md
  rm -f $T/h/CURRENT
  local hj=$(print '{"session_id":"77777777-g","cwd":"'$T/repo'"}' | run hello)
  t hello-json '"additionalContext"' "$hj"; t hello-top "read me" "$hj"; t hello-no-rules "" "$(print -r -- $hj | grep -o rules)"
  t hello-took "77777777-g" "$(run who --id)"
  print '{"session_id":"88888888-h","cwd":"'$T/repo/.claude/worktrees/w'"}' | run hello >/dev/null
  t hello-joined "88888888-h" "$(cat $T/h/PANEL)"
  # leave --hook frees the lease of the holder that ends
  print '{}' | CLAUDE_CODE_SESSION_ID=x run leave --hook 77777777-g >/dev/null; t leave-hook "VACANT" "$(run who)"
  # spawn: needs a free lease and a message waiting 10+ min; once per hour; a stand-in for claude
  print 'wait' > $T/h/inbox/zz.md; touch -t 202601010000 $T/h/inbox/zz.md
  export COORD_CLAUDE=true COORD_SPAWN_LOG=$T/spawn.log
  t spawn "spawned" "$(run spawn)"; sleep 0.3
  t spawn-hourly "one spawn per hour" "$(run spawn)"
  CLAUDE_CODE_SESSION_ID=99999999-i run take >/dev/null; t spawn-held "skip: holder is LIVE" "$(run spawn)"
  rm -rf $T
  (( fail )) && { print "coord selftest FAILED"; return 1; }
  print "coord selftest OK"
}

help() { sed -n '2,11p' $SELF | cut -c3-; }

case ${1:-help} in
  who) shift; cmd_who "$@" ;;
  take) shift; cmd_take "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  post) shift; cmd_post "$@" ;;
  inbox) cmd_inbox ;;
  done) shift; cmd_done "$@" ;;
  state-check) shift; cmd_state_check "$@" ;;
  reviewed) shift; cmd_reviewed "$@" ;;
  join) shift; cmd_join "$@" ;;
  leave) shift; cmd_leave "$@" ;;
  assign) shift; cmd_assign "$@" ;;
  gate) shift; cmd_gate "$@" ;;
  worktrees) cmd_worktrees ;;
  handoff-sweep) cmd_handoff_sweep ;;
  doctor) shift; cmd_doctor "$@" ;;
  hello) cmd_hello ;;
  spawn) cmd_spawn ;;
  legacy-split) shift; cmd_legacy_split "$@" ;;
  trim) shift; cmd_trim "$@" ;;
  selftest) selftest ;;
  *) help ;;
esac
