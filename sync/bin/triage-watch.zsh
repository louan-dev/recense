#!/bin/zsh
# triage-watch: runs when docs/specs/triage.md is saved (launchd WatchPaths) and hourly.
# The owner writes one plain line under # Inbox, any language. "!" first = urgent.
# 1. Filing: every Inbox line becomes a T-#### entry. Local, instant, no network.
#    "!" first → "! NEW" and queued; anything else (even "P1 - …") → "NEW" (later). Only "!" auto-starts.
# 2. Scout (Haiku, low effort, $0.10, read-only tools): writes Where:/Area:/Repro: (guess) under the entry, stops.
#    No files found → entry stays filed with a note + a notification; nothing more is spent.
# 3. Fixer (Sonnet, medium effort, per-run $ cap): /bug in its own worktree, narrow brief, one at a time.
#    Gates: daily $ budget (+ run count backstop), online, BUILD LOCK free, no duplicate FIXING entry or lane.
#    Urgent entries in the same Area filed within 10 min go into one run. Cost and turns → $STATE/usage.log.
# Off switch: launchctl bootout gui/$(id -u)/com.chauphan.triage-watch
# Selftest: zsh triage-watch.zsh selftest
set -u
SELF=${0:A}
[[ ${1:-} == selftest ]] && export TRIAGE_STATE=$(mktemp -d "${TMPDIR:-/tmp}/tw-state.XXXX")
setopt null_glob
unsetopt bg_nice

REPO=${TRIAGE_REPO:-/Users/chauphan/Developer/recense}
TRIAGE=${TRIAGE_FILE:-$REPO/docs/specs/triage.md}
STATE=${TRIAGE_STATE:-$HOME/.local/state/triage-watch}
CLAUDE=${TRIAGE_CLAUDE:-$HOME/.local/bin/claude}
DEBOUNCE=${TRIAGE_DEBOUNCE:-5}
SCOUT_BUDGET=${TRIAGE_SCOUT_BUDGET_USD:-0.10}
FIX_BUDGET=${TRIAGE_FIX_BUDGET_USD:-1.50}
BATCH_MIN=${TRIAGE_BATCH_MIN:-10}
QUEUE=$STATE/queue            # "T-#### <epoch filed>" per line, waiting
STARTS=$STATE/starts          # "YYYY-MM-DD T-####[,T-####]" per fixer start
USAGE=$STATE/usage.log        # "YYYY-MM-DD HH:MM role ids usage=<n> turns=<n>" (plan usage, API-dollar equivalent; nothing is billed)
LOG=$STATE/log
RUNNING=$STATE/running        # "<pid> T-####" while a fixer runs

mkdir -p "$STATE"
touch "$QUEUE" "$STARTS" "$USAGE"
say()    { print -r -- "$(date '+%F %T') $*" >> "$LOG"; }
notify() { [[ -n ${TRIAGE_NO_NOTIFY:-} ]] || osascript -e "display notification \"$1\" with title \"Recense triage\"" >/dev/null 2>&1; say "notify: $1"; }

online() {
  [[ -n ${TRIAGE_ONLINE:-} ]] && { [[ $TRIAGE_ONLINE == 1 ]]; return; }
  curl -s -m 5 -o /dev/null https://api.anthropic.com
}
build_lock_free() { grep -q '^BUILD LOCK: free' "$REPO/.handoff/MERGE-QUEUE.md" 2>/dev/null; }

debounce() {
  local last now
  last=$(stat -f %m "$TRIAGE" 2>/dev/null) || return 1
  while :; do
    sleep "$DEBOUNCE"
    now=$(stat -f %m "$TRIAGE" 2>/dev/null) || return 1
    [[ $now == $last ]] && return 0
    last=$now
  done
}

# ---------- filing (offline) ----------
# Every non-empty Inbox line except the header is a note. Idempotent: a filed note leaves the Inbox.
# Prints "T-#### <epoch>" for each urgent entry.
file_inbox() {
  [[ -f $TRIAGE ]] || return 0
  if ! (( $+commands[${TRIAGE_PERL:-perl}] )); then
    say "layout skipped: perl missing"; file_inbox_awk; return
  fi
  TODAY=$(date +%F) NOW=$(date +%s) perl -CSD -e 'use utf8;
    my $f = shift; open my $in, "<:encoding(UTF-8)", $f or die; my @l = <$in>; close $in;
    my ($next) = map { /^Next ID: T-(\d+)/ ? $1 : () } @l; defined $next or exit 0;
    my (@keep, @new, $inbox);
    for (@l) {
      if (/^# Inbox/) { $inbox = 1; push @keep, $_; next }
      $inbox = 0 if /^# /;
      if ($inbox) {
        my $t = $_; $t =~ s/^\s+|\s+$//g;
        if ($t eq "" || $t eq "-" || $t =~ /^Write what went wrong/ || $t =~ /^Start with !/ || $t =~ /^Write here/) { push @keep, $_; next }
        $t =~ s/^-\s*//;
        my $p = 0;
        if    ($t =~ s/^!+\s*//)                 { $p = 1 }
        push @new, [$p, $t] if length $t; next;
      }
      push @keep, $_;
    }
    exit 0 unless @new;
    unless (grep { /^-\s*$/ } @keep) {
      for my $i (0..$#keep) { if ($keep[$i] =~ /^# Open/) { splice @keep, $i, 0, "- \n", "\n"; last } }
    }
    my (@urgent, $out);
    for my $n (@new) {
      my ($p, $txt) = @$n; my $id = sprintf "T-%04d", $next++;
      my @w = split /\s+/, $txt; my $title = join " ", @w[0 .. ($#w < 7 ? $#w : 7)];
      my $status = $p ? "! NEW" : "NEW";
      $out .= "\n## $id · $title\n$status · Other · $ENV{TODAY} · owner\n> $txt\n";
      push @urgent, $id if $p == 1;
    }
    s/^Next ID: T-\d+/sprintf "Next ID: T-%04d", $next/e for @keep;
    $keep[-1] .= "\n" unless $keep[-1] =~ /\n$/;
    open my $o, ">:encoding(UTF-8)", "$f.tmp.$$" or die; print $o @keep, $out; close $o;
    rename "$f.tmp.$$", $f or die;
    print "$_ $ENV{NOW}\n" for @urgent;
  ' "$TRIAGE"
}

# Fallback when perl is gone (Apple deprecated scripting runtimes): plain awk, same entries, no layout.
file_inbox_awk() {
  awk -v today="$(date +%F)" -v now="$(date +%s)" -v tmp="$TRIAGE.tmp.$$" '
    { l[++n] = $0 }
    END {
      for (i = 1; i <= n; i++) if (l[i] ~ /^Next ID: T-[0-9]+/) { nx = substr(l[i], 13) + 0; nxi = i }
      if (!nxi) exit
      for (i = 1; i <= n; i++) {
        if (l[i] ~ /^# Inbox/) { inb = 1; keep[++k] = l[i]; continue }
        if (l[i] ~ /^# /) inb = 0
        if (inb) {
          t = l[i]; gsub(/^[ \t]+|[ \t]+$/, "", t)
          if (t == "" || t == "-" || t ~ /^(Write what went wrong|Start with !|Write here)/) { keep[++k] = l[i]; continue }
          sub(/^-[ \t]*/, "", t); p = sub(/^!+[ \t]*/, "", t)
          if (t != "") { nt[++m] = t; np[m] = p }
          continue
        }
        keep[++k] = l[i]
      }
      if (!m) exit
      for (j = 1; j <= m; j++) {
        id = sprintf("T-%04d", nx++); w = split(nt[j], a, /[ \t]+/); ti = a[1]
        for (q = 2; q <= w && q <= 8; q++) ti = ti " " a[q]
        out = out "\n## " id " · " ti "\n" (np[j] ? "! NEW" : "NEW") " · Other · " today " · owner\n> " nt[j] "\n"
        if (np[j]) urg = urg id " " now "\n"
      }
      for (i = 1; i <= k; i++) { if (keep[i] ~ /^Next ID:/) keep[i] = sprintf("Next ID: T-%04d", nx); print keep[i] > tmp }
      printf "%s", out > tmp; close(tmp)
      printf "%s", urg
    }' "$TRIAGE" > "$STATE/awk.urgent" && [[ -f $TRIAGE.tmp.$$ ]] && mv "$TRIAGE.tmp.$$" "$TRIAGE"
  cat "$STATE/awk.urgent"
}

# ---------- entry helpers ----------
entry()      { awk -v id="$1" '/^## T-/{on=($2==id)} on' "$TRIAGE"; }
entry_area() { entry "$1" | awk 'NR==2{split($0,a," · "); print a[2]}'; }
entry_where(){ entry "$1" | sed -n 's/^Where: //p' | head -1; }
# Insert lines right after an entry's quote line.
add_lines() {  # append lines at the end of an entry, so its status reads in time order
  local id=$1; shift
  ID=$id ADDTXT="$(printf '%s\n' "$@")" perl -CSD -0777 -i -pe '
    BEGIN { use Encode; $id = $ENV{ID}; $add = decode_utf8($ENV{ADDTXT}); $add =~ s/\n*$// }
    s/(^## \Q$id\E .*?)\n*(?=\n## T-|\z)/$1\n$add\n/ms;
  ' "$TRIAGE"
}
set_area() { ID=$1 AREA=$2 perl -CSD -i -pe 'use utf8; $on = /^## \Q$ENV{ID}\E / ? 1 : (/^## T-/ ? 0 : $on); if ($on && / · Other · /) { s/ · Other · / · $ENV{AREA} · /; $on = 0 }' "$TRIAGE"; }


# Run claude -p, log cost and turns, print the result text.
ask_claude() {
  local role=$1 ids=$2 out; shift 2
  out=$STATE/$role-${ids//,/_}.json
  "$CLAUDE" -p --output-format json "$@" > "$out" 2>> "$LOG"
  local rc=$? cost turns
  # Usage limit: not counted against the budget or the run cap; the caller re-queues (exit 75).
  if (( rc != 0 )) && grep -qi 'limit' "$out" 2>/dev/null; then
    LIMIT_RESET=$(grep -oiE 'resets? [^"\\]*' "$out" | head -1)
    print -r -- "${LIMIT_RESET:-in about an hour}" > "$STATE/limit"
    say "$role $ids hit the usage limit (${LIMIT_RESET:-no reset time})"
    return 75
  fi
  cost=$(plutil -extract total_cost_usd raw -o - "$out" 2>/dev/null || print 0)
  turns=$(plutil -extract num_turns raw -o - "$out" 2>/dev/null || print 0)
  print "$(date '+%F %H:%M') $role $ids usage=$cost turns=$turns" >> "$USAGE"
  plutil -extract result raw -o - "$out" 2>/dev/null
  return $rc
}

# Status line under an entry: SCOUTING → FIXING → READY → MERGED (or WAITING / STOPPED), with a time.
status() { local id=$1 word=$2; shift 2; add_lines "$id" "- $(date '+%F %H:%M') · $word · triage-watch${1:+ · $*}"; }

# Put IDs back at the head of the queue after a usage limit; undo their run-cap count.
requeue_limit() {
  local ids=$1 reset; reset=$(<"$STATE/limit" 2>/dev/null)
  local id tmp=$QUEUE.tmp.$$
  { for id in ${(s:,:)ids}; do print "$id $(date +%s)"; status "$id" WAITING "usage limit; resumes after ${reset:-the reset}"; done; cat "$QUEUE"; } > "$tmp" && mv "$tmp" "$QUEUE"
  grep -v " $ids\$" "$STARTS" > "$STARTS.tmp" ; mv "$STARTS.tmp" "$STARTS"
  date -v+1H +%s > "$STATE/limit.until"
  notify "Usage limit: $ids resumes after ${reset:-the reset}"
}

# ---------- scout ----------
# Returns 0 when it found files (Where: written), 1 when not.
scout() {
  local id=$1 res where area repro
  [[ -n $(entry_where "$id") ]] && return 0
  status "$id" SCOUTING
  local rc
  res=$(cd "$REPO" && ask_claude scout "$id" --model haiku --effort low --max-budget-usd "$SCOUT_BUDGET" \
    --tools "Read,Grep,Glob" --permission-mode default \
"You are a scout for bug $id in this repo. Do not fix anything, do not edit files.
"mobile" means iOS and iPadOS: iPhone and iPad (Split View, Slide Over, Stage Manager windows) both count.
The owner's words: $(entry "$id" | sed -n 's/^> //p')
Find the 1-5 source files most likely involved (grep for names, UI strings, features). Keep it short.
Answer with exactly these lines and nothing else:
WHERE: <comma-separated repo paths, or NONE>
AREA: <one of: $(sed -n 's/^Area: //p' "$TRIAGE" | head -1)>
REPRO: <one-line guess at how to reproduce>"); rc=$?
  (( rc == 75 )) && return 2
  where=$(print -r -- "$res" | sed -n 's/^WHERE: *//p' | head -1)
  area=$(print -r -- "$res" | sed -n 's/^AREA: *//p' | head -1)
  repro=$(print -r -- "$res" | sed -n 's/^REPRO: *//p' | head -1)
  if [[ -z $where || $where == NONE ]]; then
    add_lines "$id" "- $(date +%F) · scout found no files: tell me where you saw it · scout"
    notify "$id: tell me where you saw it (scout found no files)"
    return 1
  fi
  add_lines "$id" "Where: $where" "Repro: $repro (guess)"
  [[ -n $area ]] && set_area "$id" "$area"
  return 0
}

# ---------- dedupe ----------
# Duplicate when another Open entry is FIXING on any of the same files, or a LANES line names one.
is_duplicate() {
  local id=$1 f others
  local -a files; files=(${(s:, :)$(entry_where "$id")})
  others=$(awk -v id="$1" '/^## T-/{cur=$2} cur!=id' "$TRIAGE" | awk '/^## T-/{e=$0; fx=0} / FIXING /{fx=1} /^Where: /{ if (fx) print }')
  for f in $files; do
    [[ -z $f ]] && continue
    print -r -- "$others" | grep -qF -- "$f" && { say "$id duplicate: $f already FIXING"; return 0; }
    grep -v '· done\|MERGED\|OUT' "$REPO/.handoff/LANES.md" 2>/dev/null | grep -qF -- "$f" && { say "$id duplicate: lane on $f"; return 0; }
  done
  return 1
}

# ---------- fixer ----------
agent_running() {
  [[ -f $RUNNING ]] || return 1
  local pid; pid=$(awk '{print $1}' "$RUNNING")
  [[ $pid == starting ]] && return 0
  kill -0 "$pid" 2>/dev/null && return 0
  say "stale running marker ($pid) cleared"; rm -f "$RUNNING"; return 1
}

start_fixer() {
  local ids=$1 first=${1%%,*} slug wt brief id
  slug=${first:l}; wt=$REPO/.claude/worktrees/$slug
  print "$(date +%F) $ids" >> "$STARTS"
  if [[ -n ${TRIAGE_DRY:-} ]]; then say "DRY fixer $ids"; return 0; fi
  if [[ -n ${TRIAGE_NO_WORKTREE:-} ]]; then wt=$REPO
  elif [[ ! -d $wt ]]; then   # a run resumed after a usage limit reuses its worktree
    git -C "$REPO" worktree add "$wt" -b "work/$slug" >> "$LOG" 2>&1 || { say "worktree failed for $ids"; return 1; }; fi
  brief=""
  for id in ${(s:,:)ids}; do
    brief+="$(entry "$id")"$'\n\n'
    status "$id" FIXING "branch work/$slug"
  done
  notify "Fixing $ids"
  print -r -- "$brief" > "$STATE/$first.brief"
  git -C "$wt" rev-parse HEAD > "$STATE/$slug.base" 2>/dev/null
  # Regression guard: the running marker is owned by the background fixer, so a second save never starts a second one.
  print "starting $ids" > "$RUNNING"
  # Regression guard (T-0001, 11-12): the fixer runs in its own session, so launchd ending this job can't kill it.
  # The child writes its pid to the marker only after setsid; wait for that (up to 5 s) so a kill can't race it.
  RUNNING=$RUNNING IDS=$ids perl -MPOSIX -e 'POSIX::setsid(); open my $m, ">", $ENV{RUNNING}; print $m "$$ $ENV{IDS}\n"; close $m; exec @ARGV' \
    zsh "$SELF" _fixer "$ids" "$wt" "$slug" </dev/null >/dev/null 2>&1 &!
  local i; for i in {1..50}; do [[ $(<"$RUNNING" 2>/dev/null) == starting* ]] || break; sleep 0.1; done
}

fixer_job() {
  local ids=$1 wt=$2 slug=$3 first=${1%%,*} brief rc id
  brief=$(<"$STATE/$first.brief")
  trap 'rm -f "$RUNNING"' EXIT INT TERM HUP
  # The prompt goes on stdin: --add-dir takes several folders and would swallow a trailing prompt (bug 11-12).
  # Steps written out, not "/bug": a slash skill may be missing on main (it was, 11-12: "/bug isn't available").
  local prompt="Fix bug ${ids//,/ } the red-green way: write a regression test that fails now, make the smallest fix, run it again until it passes.
Entries (from $TRIAGE, git-ignored, absolute path; write status lines there):
$brief
Work only in the files named on the Where: lines. Do not explore beyond them unless a failing test shows the cause is elsewhere.
The Repro: lines are a scout's guess; confirm with a test.
You are in worktree $wt on branch work/$slug. Record the regression test: run it before the fix and write 'red <exit code>', run it after and write 'green <exit code>', one per line, to $STATE/<ID>.tests for each ID.
Stop at a commit here plus one line in $REPO/.handoff/MERGE-QUEUE.md starting 'work/$slug' and ending '· ready'. Never merge, push or install.
Take the BUILD LOCK in that file before any build and free it after.
If this needs a stronger model, end your reply with the line 'BLOCKED: needs opus: <why>' and stop.
If a permission prompt, a platform limit or anything else blocks you, end your reply with the line 'BLOCKED: <why>' and stop."
  cd "$wt" && print -r -- "$prompt" | ask_claude fixer "$ids" --model sonnet --effort medium --max-budget-usd "$FIX_BUDGET" \
    --permission-mode default --add-dir "$REPO/docs/specs" "$STATE" "$REPO/.handoff" >> "$STATE/$first.out"
  rc=$?
  say "fixer $ids exit $rc"
  if (( rc == 75 )); then requeue_limit "$ids"; return 0; fi
  # A run with 0 usage in 0 turns never reached the model (our bug, not spending): it doesn't count toward
  # the record of fixer starts. Three in a row: the fixer is broken, stop auto-starting until the owner looks.
  local last void=0; last=$(tail -1 "$USAGE")
  if [[ $last == *" fixer $ids "(usage|cost)"=0 turns=0" ]]; then
    awk -v d="$(date +%F)" -v i="$ids" -v r="$rc" '!done && $1==d && $2==i { print > (FILENAME ".void.add"); done=1; next } { print }' "$STARTS" > "$STARTS.tmp" && mv "$STARTS.tmp" "$STARTS"
    [[ -f $STARTS.void.add ]] && { sed "s/\$/ · void: exit $rc/" "$STARTS.void.add" >> "$STATE/starts.void"; rm -f "$STARTS.void.add"; }
    say "void: $rc ($ids)"; void=1
    print "$ids" >> "$STATE/void.streak"
    if (( $(wc -l < "$STATE/void.streak") >= 3 )); then
      touch "$STATE/fixer.broken"; notify "fixer broken: see log"
    fi
  else
    rm -f "$STATE/void.streak"
  fi
  local own=0
  [[ -n ${TRIAGE_NO_WORKTREE:-} ]] && own=1
  [[ $(git -C "$wt" rev-parse HEAD 2>/dev/null) != $(<"$STATE/$slug.base" 2>/dev/null) ]] && own=1
  # Two failed runs in a row on one entry → HELD for the owner; no third try, so one hard bug can't eat the budget.
  local why n
  for id in ${(s:,:)ids}; do
    why=""
    # The agent can't always write outside its worktree; its last BLOCKED: line is read here instead.
    local blk; blk=$(grep -E '^\**BLOCKED:' "$STATE/$first.out" 2>/dev/null | tail -1 | sed -E 's/^\**BLOCKED:\**[[:space:]]*//')
    if [[ -n $blk ]]; then status "$id" HELD "needs you: $blk"; notify "$id needs you: $blk"; continue; fi
    if (( rc != 0 )); then why="exit $rc; see $STATE/$first.out"
    elif (( ! own )); then why="nothing committed"
    elif ! grep -q '^green 0$' "$STATE/$id.tests" 2>/dev/null; then why="test not green"; fi
    if [[ -z $why ]]; then rm -f "$STATE/$id.fails"; status "$id" READY "branch work/$slug"; continue; fi
    status "$id" STOPPED "$why"
    (( void )) && continue
    print -r -- "$why" >> "$STATE/$id.fails"; n=$(grep -c . "$STATE/$id.fails")
    (( n >= 2 )) && { status "$id" HELD "needs you: failed twice ($why)"; notify "$id held: failed twice, needs you"; }
  done
  notify "Done with $ids (exit $rc); see the merge queue"
  (( rc == 0 && own )) && [[ -z ${TRIAGE_NO_MERGE:-} ]] && zsh "${SELF:h}/triage-merge.zsh" run
}

requeue_limit_scout() {  # the ID is still in the queue; just mark it and pause
  local reset; reset=$(<"$STATE/limit" 2>/dev/null)
  status "$1" WAITING "usage limit; resumes after ${reset:-the reset}"
  date -v+1H +%s > "$STATE/limit.until"
}

# ---------- cleanup ----------
# A fixer's branch that is in main and has a clean worktree: trash the worktree, prune, delete the branch, mark MERGED.
cleanup() {
  local wt slug br ids id
  for wt in $REPO/.claude/worktrees/t-[0-9][0-9][0-9][0-9]; do
    slug=${wt:t}; br=work/$slug
    git -C "$REPO" merge-base --is-ancestor "$br" main 2>/dev/null || continue
    # Regression guard (T-0001, 11-12): merged means >=1 commit of its own; a branch still at its base is not merged.
    [[ -f $STATE/$slug.base && $(git -C "$REPO" rev-parse "$br") != $(<"$STATE/$slug.base") ]] || continue
    [[ -z $(git -C "$wt" status --porcelain 2>/dev/null) ]] || { say "$slug merged but not clean; kept"; continue; }
    ids=$(awk -v f="${slug:u}" '{ n=split($2,a,","); if (a[1]==f) print $2 }' "$STARTS" | tail -1); ids=${ids:-${slug:u}}
    ${=TRIAGE_TRASH:-trash} "$wt" && git -C "$REPO" worktree prune && git -C "$REPO" branch -d "$br" >> "$LOG" 2>&1 || { say "cleanup of $slug failed"; continue; }
    for id in ${(s:,:)ids}; do status "$id" MERGED "branch $br removed"; done
    say "cleaned $slug"
  done
}

# ---------- drain ----------
drain() {
  mkdir "$STATE/agent.lock" 2>/dev/null || { say "drain busy"; return 0; }
  {
    local head id t area ids batch_end
    head=$(head -1 "$QUEUE"); [[ -z $head ]] && return 0
    id=${head%% *}; t=${head##* }
    agent_running && { say "$id queued: a fixer is still running"; return 0; }
    if [[ -f $STATE/limit.until ]] && (( $(date +%s) < $(<$STATE/limit.until) )); then say "$id waits: usage limit"; return 0; fi
    rm -f "$STATE/limit.until"
    if (( $(grep -c . "$STATE/$id.fails" 2>/dev/null || print 0) >= 2 )); then
      grep -v "^$id " "$QUEUE" > "$QUEUE.tmp"; mv "$QUEUE.tmp" "$QUEUE"; say "$id dropped from queue: HELD (failed twice); trash $STATE/$id.fails to retry"; return 0
    fi
    if [[ -f $STATE/fixer.broken ]]; then say "$id waits: fixer broken (3 void runs); trash $STATE/fixer.broken after a fix"; return 0; fi
    online || { say "$id queued: offline"; return 0; }
    build_lock_free || { say "$id queued: BUILD LOCK taken"; return 0; }
    # scout every queued entry still without Where:
    local line qid
    for line in ${(f)"$(<$QUEUE)"}; do
      qid=${line%% *}
      scout "$qid"; case $? in
        1) sed -i '' "/^$qid /d" "$QUEUE" ;;
        2) requeue_limit_scout "$qid"; return 0 ;;
      esac
    done
    head=$(head -1 "$QUEUE"); [[ -z $head ]] && return 0
    id=${head%% *}; t=${head##* }
    if is_duplicate "$id"; then
      sed -i '' "/^$id /d" "$QUEUE"; add_lines "$id" "- $(date +%F) · skipped: same files already being fixed · triage-watch"; return 0
    fi
    # batch: same Area, filed within BATCH_MIN minutes of the head
    area=$(entry_area "$id"); ids=$id; batch_end=$(( t + BATCH_MIN * 60 ))
    for line in ${(f)"$(tail -n +2 $QUEUE)"}; do
      qid=${line%% *}
      (( ${line##* } <= batch_end )) && [[ $(entry_area "$qid") == $area ]] && ! is_duplicate "$qid" && ids+=",$qid"
    done
    for qid in ${(s:,:)ids}; do sed -i '' "/^$qid /d" "$QUEUE"; done
    start_fixer "$ids"
  } always { rmdir "$STATE/agent.lock" 2>/dev/null }
}

run() {
  mkdir "$STATE/file.lock" 2>/dev/null || exit 0
  {
    [[ -n ${TRIAGE_NO_DEBOUNCE:-} ]] || debounce || exit 0
    local filed; filed=$(file_inbox)
    for line in ${(f)filed}; do print "$line" >> "$QUEUE"; say "filed ${line%% *} (urgent), queued"; done
    cleanup
    drain
  } always { rmdir "$STATE/file.lock" 2>/dev/null }
}

weekly() {  # one line for the README: last 7 days
  awk -v since="$(date -v-7d +%F)" '$1>=since { sub(/^(usage|cost)=/,"",$5); sub("turns=","",$6); c+=$5; t+=$6; n++ }
    END { printf "last 7 days: %d runs, usage %.2f, %d turns\n", n, c, t }' "$USAGE"
}

# ---------- selftest ----------
selftest() {
  local d fail=0; d=$(mktemp -d "${TMPDIR:-/tmp}/tw.XXXX") || exit 1
  ok()  { print "ok   $1"; }
  bad() { print "FAIL $1"; fail=1; }
  export TRIAGE_FILE=$d/triage.md TRIAGE_STATE=$d/state TRIAGE_NO_DEBOUNCE=1 TRIAGE_NO_NOTIFY=1 TRIAGE_REPO=$d TRIAGE_NO_MERGE=1 \
         TRIAGE_ONLINE=1 TRIAGE_CLAUDE=$d/fake-claude TRIAGE_NO_WORKTREE=1
  mkdir -p $d/.handoff; print "BUILD LOCK: free" > $d/.handoff/MERGE-QUEUE.md; : > $d/.handoff/LANES.md
  # fake claude: scout answers from $d/scout-answer; fixer sleeps $d/fix-sleep seconds
  cat > $d/fake-claude <<EOF
#!/bin/zsh
if [[ -f $d/limit-\${\${*}[(w)5]} || -f $d/limit-all ]]; then
  print -r -- '{"is_error":true,"result":"Claude usage limit reached; resets 5pm (America/Los_Angeles)"}'; exit 1
fi
if [[ "\$*" == *haiku* ]]; then
  r=\$(cat $d/scout-answer); r=\${r//\$'\n'/\\\\n}
  print -r -- "{\"result\":\"\$r\",\"total_cost_usd\":0.02,\"num_turns\":3}"
else
  [[ "\$*" == *"--add-dir"*"$d/state"*"$d/.handoff"* ]] || { print -u2 "fixer can't write state or .handoff"; exit 1; }
  in=\$(cat); [[ "\$in" == "Fix bug "* ]] || { print -u2 "Error: Input must be provided either through stdin or as a prompt argument"; exit 1; }
  for i in \$(print -r -- "\${in%%the red-green*}" | grep -oE 'T-[0-9]{4}'); do
    [[ -f $d/nogreen ]] && print 'red 1\ngreen 1' > $d/state/\$i.tests || print 'red 1\ngreen 0' > $d/state/\$i.tests
  done
  [[ -f $d/blocked ]] && { print -r -- '{"result":"looked\\nBLOCKED: iOS refuses the window behind another app","total_cost_usd":0.2,"num_turns":5}'; exit 0; }
  [[ -f $d/void ]] && { print -r -- '{"result":"x","total_cost_usd":0,"num_turns":0}'; exit 0; }
  sleep \$(cat $d/fix-sleep 2>/dev/null || print 0)
  print -r -- '{"result":"fixed","total_cost_usd":0.50,"num_turns":12}'
fi
EOF
  chmod +x $d/fake-claude; print 0 > $d/fix-sleep
  scout_says() { print -r -- "$1" > $d/scout-answer; }
  newfile() { cat > $TRIAGE_FILE <<'EOF'
# Recense triage
Next ID: T-0001

# Inbox
Write what went wrong, one line.
Start with ! if it should be fixed now.

-

# Open
Area: Cadence | Ears | Bridge | Gallery | Sync | UI | Draftpad | Specs | Build | Other
EOF
  }
  inbox() { sed -i '' "s|^- *\$|$1|" $TRIAGE_FILE; }
  reset() { rm -rf $TRIAGE_STATE; mkdir -p $TRIAGE_STATE; newfile; }
  waitfix() { local i; sleep 0.3; for i in {1..60}; do [[ -f $TRIAGE_STATE/running ]] || return 0; sleep 0.1; done; }

  reset; scout_says $'WHERE: editor/src/ink.js\nAREA: Draftpad\nREPRO: hold squeeze, lift pencil'
  inbox '! no floating window over youtube.com in Safari'; zsh $SELF run; sleep 1
  grep -q '^## T-0001 · no floating window over youtube.com in Safari' $TRIAGE_FILE && grep -q '^! NEW · Draftpad' $TRIAGE_FILE && ok "! line filed as T-0001 ! NEW" || bad "! filed"
  grep -q '^Where: editor/src/ink.js' $TRIAGE_FILE && grep -q '^Repro: .*(guess)' $TRIAGE_FILE && ok "scout wrote Where + Repro (guess)" || bad "scout lines"
  grep -q ' scout T-0001 usage=0.02' $TRIAGE_STATE/usage.log && grep -q ' fixer T-0001 usage=0.50' $TRIAGE_STATE/usage.log && ok "scout → fixer, both logged" || bad "scout → fixer"
  grep -q 'FIXING · triage-watch' $TRIAGE_FILE && ok "entry marked FIXING" || bad "FIXING line"
  sed -n '/^# Inbox/,/^# Open/p' $TRIAGE_FILE | grep -q '^- *$' && ok "Inbox keeps one empty line" || bad "Inbox empty line"

  reset; inbox 'P2 - old later format'; zsh $SELF run
  ! grep -qE '^(TRIAGED|P[123] ·|! ?P[123])' $TRIAGE_FILE && grep -q '^NEW · Other' $TRIAGE_FILE && ok "no TRIAGED or P1/P2/P3 on new entries; P2 - = later" || bad "no P-levels"
  reset; inbox 'calendar colours too bright at night'; zsh $SELF run
  grep -q '^NEW · Other' $TRIAGE_FILE && [[ ! -s $TRIAGE_STATE/usage.log ]] && ok "plain line filed NEW, nothing spent" || bad "plain line"
  zsh $SELF run; [[ $(grep -c '^## T-' $TRIAGE_FILE) == 1 ]] && ok "second save files nothing twice" || bad "double save"

  reset; inbox 'P1 - x'; zsh $SELF run
  grep -q '^NEW · Other' $TRIAGE_FILE && grep -q '^> P1 - x$' $TRIAGE_FILE && [[ ! -s $TRIAGE_STATE/queue && ! -s $TRIAGE_STATE/usage.log ]] && ok "P1 - x is a later line: NEW, text kept, no agent" || bad "P1 is not urgent"

  reset; scout_says $'WHERE: NONE\nAREA: Other\nREPRO: unknown'
  inbox '! something odd somewhere'; zsh $SELF run
  grep -q 'scout found no files: tell me where you saw it' $TRIAGE_FILE && ! grep -q ' fixer ' $TRIAGE_STATE/usage.log && [[ ! -s $TRIAGE_STATE/queue ]] && ok "scout finds nothing → filed + note, no fixer" || bad "scout none"

  reset; scout_says $'WHERE: strip/app.swift\nAREA: UI\nREPRO: guess'
  print -r -- '- lane x · working on strip/app.swift · 2026-11-12' > $d/.handoff/LANES.md
  inbox '! strip flickers'; zsh $SELF run
  grep -q 'skipped: same files already being fixed' $TRIAGE_FILE && ! grep -q ' fixer ' $TRIAGE_STATE/usage.log && ok "duplicate of a lane → skipped" || bad "dedupe"
  : > $d/.handoff/LANES.md

  reset; scout_says $'WHERE: editor/src/ink.js\nAREA: Draftpad\nREPRO: guess'
  TRIAGE_ONLINE=0 zsh $SELF run   # nothing yet
  inbox '! first draftpad bug'; TRIAGE_ONLINE=0 zsh $SELF run
  inbox '! second draftpad bug'; TRIAGE_ONLINE=0 zsh $SELF run
  grep -c . $TRIAGE_STATE/queue | grep -q '^2$' && ok "offline: both queued" || bad "offline queue"
  zsh $SELF run; sleep 1
  [[ $(grep -c . $TRIAGE_STATE/starts) == 1 ]] && grep -q 'T-0001,T-0002' $TRIAGE_STATE/starts && ok "same Area within 10 min → one run" || bad "batch"

  reset; scout_says $'WHERE: a.js\nAREA: UI\nREPRO: guess'
  print "$(date '+%F %H:%M') fixer T-0099 usage=3.00 turns=40" > $TRIAGE_STATE/usage.log
  inbox '! over budget bug'; zsh $SELF run; sleep 1
  grep -q 'T-0001' $TRIAGE_STATE/starts && ok "no daily dollar stop: runs after \$3 spent" || bad "daily budget still stops"

  reset; scout_says $'WHERE: a.js\nAREA: UI\nREPRO: guess'; print 3 > $d/fix-sleep
  inbox '! slow agent A'; zsh $SELF run
  scout_says $'WHERE: b.js\nAREA: Sync\nREPRO: guess'
  sleep 1; inbox '! slow agent B'; zsh $SELF run
  [[ $(grep -c . $TRIAGE_STATE/starts) == 1 ]] && grep -q '^T-0002 ' $TRIAGE_STATE/queue && ok "one fixer at a time, second queued" || bad "one at a time"
  sleep 3; zsh $SELF run; sleep 4
  grep -q 'T-0002' $TRIAGE_STATE/starts && ok "drains after the first fixer exits" || bad "drain after exit"

  # B1: status lines with a time
  reset; scout_says $'WHERE: a.js\nAREA: UI\nREPRO: guess'; print 0 > $d/fix-sleep
  inbox '! status bug'; zsh $SELF run; sleep 1
  for w in SCOUTING FIXING READY; do
    grep -qE "^- [0-9-]{10} [0-9]{2}:[0-9]{2} · $w · triage-watch" $TRIAGE_FILE && ok "status line $w with time" || bad "status $w"
  done

  # B4: usage limit on the fixer → back at the head, not counted, resumes later
  reset; scout_says $'WHERE: a.js\nAREA: UI\nREPRO: guess'; : > $d/limit-sonnet
  inbox '! limit bug'; zsh $SELF run; sleep 1
  head -1 $TRIAGE_STATE/queue | grep -q '^T-0001 ' && ok "limit: T-0001 back at the head of the queue" || bad "limit requeue"
  [[ ! -s $TRIAGE_STATE/starts ]] && ! grep -q ' fixer ' $TRIAGE_STATE/usage.log && ok "limit: not counted in runs or budget" || bad "limit counted"
  grep -q 'WAITING · triage-watch · usage limit; resumes after resets 5pm' $TRIAGE_FILE && ok "limit: WAITING line with reset time" || bad "limit WAITING"
  rm -f $d/limit-sonnet; zsh $SELF run; sleep 1
  ! grep -q ' fixer ' $TRIAGE_STATE/usage.log && ok "limit: waits until the pause ends" || bad "limit pause"
  rm -f $TRIAGE_STATE/limit.until; zsh $SELF run; sleep 1
  grep -q ' fixer T-0001' $TRIAGE_STATE/usage.log && ok "limit: resumes after the pause" || bad "limit resume"

  # B3: cleanup of a merged, clean fixer worktree
  reset; unset TRIAGE_NO_WORKTREE
  ( cd $d && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init &&
    git worktree add -q .claude/worktrees/t-0042 -b work/t-0042 &&
    git -C .claude/worktrees/t-0042 -c user.email=t@t -c user.name=t commit -q --allow-empty -m fix &&
    git -c user.email=t@t -c user.name=t merge -q --no-edit work/t-0042 ) >/dev/null 2>&1
  print '\n## T-0042 · merged bug\n! NEW · UI · 2026-11-12 · owner\n> merged bug' >> $TRIAGE_FILE
  print "$(date +%F) T-0042" >> $TRIAGE_STATE/starts
  git -C $d rev-parse main~1 > $TRIAGE_STATE/t-0042.base
  TRIAGE_TRASH="rm -rf" zsh $SELF run
  [[ ! -d $d/.claude/worktrees/t-0042 ]] && ! git -C $d rev-parse -q --verify work/t-0042 >/dev/null && ok "cleanup: worktree and branch removed" || bad "cleanup"
  grep -q '· MERGED · triage-watch · branch work/t-0042 removed' $TRIAGE_FILE && ok "cleanup: MERGED line" || bad "cleanup MERGED"
  export TRIAGE_NO_WORKTREE=1

  # Regression guard (T-0001): status lines in time order
  reset; scout_says $'WHERE: a.js\nAREA: UI\nREPRO: guess'; print 0 > $d/fix-sleep
  inbox '! order bug'; zsh $SELF run; sleep 1
  local s1=$(grep -n '· SCOUTING ·' $TRIAGE_FILE | cut -d: -f1) s2=$(grep -n '^Where:' $TRIAGE_FILE | cut -d: -f1) s3=$(grep -n '· FIXING ·' $TRIAGE_FILE | cut -d: -f1) s4=$(grep -n '· READY ·' $TRIAGE_FILE | cut -d: -f1)
  (( s1 < s2 && s2 < s3 && s3 < s4 )) && ok "status lines in time order, below Where/Repro" || bad "order ($s1 $s2 $s3 $s4)"

  # Regression guard (T-0001): launchd kills the job's process group; the fixer must survive it
  reset; scout_says $'WHERE: a.js\nAREA: UI\nREPRO: guess'; print 2 > $d/fix-sleep
  inbox '! survive bug'
  perl -e 'setpgrp(0,0); exec @ARGV' zsh $SELF run & local pg=$!; wait $pg
  kill -TERM -- -$pg 2>/dev/null; sleep 5
  grep -q ' fixer T-0001 usage=0.50' $TRIAGE_STATE/usage.log && ok "fixer survives its parent's process group being killed" || bad "fixer killed with the group"
  grep -q 'AbandonProcessGroup</key><true/>' ${SELF:h:h}/launchd/com.chauphan.triage-watch.plist && ok "plist abandons the process group" || bad "plist AbandonProcessGroup"

  # Regression guard (T-0001): a branch with no commits of its own is not MERGED
  reset; unset TRIAGE_NO_WORKTREE
  ( cd $d && rm -rf .git .claude && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init &&
    git worktree add -q .claude/worktrees/t-0043 -b work/t-0043 ) >/dev/null 2>&1
  git -C $d rev-parse main > $TRIAGE_STATE/t-0043.base
  print '\n## T-0043 · empty branch\n! NEW · UI · 2026-11-12 · owner\n> empty branch' >> $TRIAGE_FILE
  TRIAGE_TRASH="rm -rf" zsh $SELF run
  [[ -d $d/.claude/worktrees/t-0043 ]] && ! grep -q 'MERGED' $TRIAGE_FILE && ok "branch with no own commits: kept, not MERGED" || bad "false MERGED"
  export TRIAGE_NO_WORKTREE=1

  # void runs ($0, 0 turns) don't count toward the cap; three in a row stop auto-starts
  reset; touch $d/void
  for n in 1 2 3; do inbox "! void bug $n"; zsh $SELF run; sleep 1; done
  [[ $(grep -c . $TRIAGE_STATE/starts) == 0 ]] && [[ $(grep -c 'void: exit 0' $TRIAGE_STATE/starts.void) == 3 ]] && ok "void runs set aside in starts.void" || bad "void runs counted"
  [[ -f $TRIAGE_STATE/fixer.broken ]] && grep -q 'fixer broken' $TRIAGE_STATE/log && ok "3 void runs → fixer broken, notified" || bad "fixer broken"
  inbox "! after broken"; zsh $SELF run; grep -q 'waits: fixer broken' $TRIAGE_STATE/log && ok "broken fixer: no auto-start" || bad "broken still starts"
  rm -f $d/void

  # no run cap: 5 starts in a day all run
  reset; scout_says $'WHERE: a.js\nAREA: UI\nREPRO: guess'
  for n in 1 2 3 4 5; do inbox "! capless bug $n"; zsh $SELF run; waitfix; done; zsh $SELF run; waitfix
  [[ $(grep ' fixer ' $TRIAGE_STATE/usage.log | grep -oE 'T-[0-9]{4}' | sort -u | grep -c .) == 5 ]] && ok "no cap: 5 fixer runs in a day" || { bad "cap still limits runs"; grep fixer $TRIAGE_STATE/usage.log; tail -5 $TRIAGE_STATE/log; }

  # two failed runs on one entry → HELD, no third run
  reset; scout_says $'WHERE: a.js\nAREA: UI\nREPRO: guess'; touch $d/nogreen; inbox "! hard bug"; zsh $SELF run; waitfix          # fake fixer writes no green 0 → fail 1
  print "T-0001 $(date +%s)" >> $TRIAGE_STATE/queue; zsh $SELF run; waitfix
  grep -q 'HELD · triage-watch · needs you: failed twice' $TRIAGE_FILE && ok "2 failed runs → HELD needs you" || { bad "no HELD after 2 fails"; sed -n '/^## T-0001/,$p' $TRIAGE_FILE; }
  print "T-0001 $(date +%s)" >> $TRIAGE_STATE/queue; zsh $SELF run; waitfix
  [[ $(grep -c ' fixer T-0001' $TRIAGE_STATE/usage.log) == 2 ]] && ok "held entry gets no third run" || bad "third run happened"
  rm -f $d/nogreen

  # the agent's BLOCKED: line → HELD needs you (the watcher writes it, not the agent)
  reset; scout_says $'WHERE: a.js\nAREA: UI\nREPRO: guess'; touch $d/blocked; inbox "! platform wall"; zsh $SELF run; waitfix
  grep -q 'HELD · triage-watch · needs you: iOS refuses the window behind another app' $TRIAGE_FILE && ok "BLOCKED: line → HELD needs you" || bad "BLOCKED not held"
  rm -f $d/blocked

  # perl gone: awk still files, and the log says so
  printf '# Recense triage\nNext ID: T-0050\n\n# Inbox\n- ! no perl crash here\n- later one\n\n# Open\n' > $TRIAGE_FILE
  out=$(TRIAGE=$TRIAGE_FILE STATE=$TRIAGE_STATE LOG=$TRIAGE_STATE/log TRIAGE_PERL=no-such-perl file_inbox)
  grep -q '^## T-0050 · no perl crash here' $TRIAGE_FILE && grep -q '^! NEW · Other' $TRIAGE_FILE && grep -q '^## T-0051 · later one' $TRIAGE_FILE \
    && grep -q '^Next ID: T-0052' $TRIAGE_FILE && [[ $out == "T-0050 "* ]] && grep -q 'layout skipped: perl missing' $TRIAGE_STATE/log \
    && ok "no perl: awk files lines, logs layout skipped" || bad "no-perl fallback"
  [[ -n ${TRIAGE_KEEP:-} ]] && print $d || rm -rf $d
  (( fail )) && { print "selftest FAILED"; exit 1; } || print "selftest ok"
}

case ${1:-run} in
  run) run ;;
  weekly) weekly ;;
  status) shift; status "$@" ;;
  where) entry_where "$2" ;;
  cleanup) cleanup ;;
  _fixer) shift; fixer_job "$@" ;;
  selftest) selftest ;;
  *) print "usage: triage-watch.zsh [run|weekly|status|where|cleanup|selftest]"; exit 2 ;;
esac
