#!/bin/zsh
# triage-watch: runs when docs/specs/triage.md is saved (launchd WatchPaths).
# 1. Files every Inbox line "P1 - ...", "P2 - ...", "P3 - ..." as T-#### TRIAGED Pn. Local, instant, no network.
# 2. Each P1 is queued; the queue starts one `claude -p "/bug T-####"` at a time, in its own worktree,
#    at most 3 a day, only when online and the BUILD LOCK is free. Network is catch-up only.
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
DAILY_CAP=${TRIAGE_DAILY_CAP:-3}
QUEUE=$STATE/queue            # one T-#### per line, waiting to start
STARTS=$STATE/starts          # "YYYY-MM-DD T-####" per auto-start
LOG=$STATE/log
RUNNING=$STATE/running        # "<pid> T-####" while an agent runs

mkdir -p "$STATE"
touch "$QUEUE" "$STARTS"
say()    { print -r -- "$(date '+%F %T') $*" >> "$LOG"; }
notify() { [[ -n ${TRIAGE_NO_NOTIFY:-} ]] || osascript -e "display notification \"$1\" with title \"Recense triage\"" >/dev/null 2>&1; say "notify: $1"; }

online() {
  [[ -n ${TRIAGE_ONLINE:-} ]] && { [[ $TRIAGE_ONLINE == 1 ]]; return; }
  curl -s -m 5 -o /dev/null https://api.anthropic.com
}
build_lock_free() { grep -q '^BUILD LOCK: free' "$REPO/.handoff/MERGE-QUEUE.md" 2>/dev/null; }

# Wait until the file has been quiet for DEBOUNCE seconds (editors write several times).
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

# File P-lines from the Inbox. Idempotent: a filed line leaves the Inbox, so a second run finds nothing.
# Prints the IDs of new P1 entries.
file_inbox() {
  [[ -f $TRIAGE ]] || return 0
  local tmp=$TRIAGE.tmp.$$
  TODAY=$(date +%F) perl -e '
    my $f = shift; open my $in, "<", $f or die; my @l = <$in>; close $in;
    my ($next) = map { /^Next ID: T-(\d+)/ ? $1 : () } @l; defined $next or exit 0;
    my (@keep, @new, $inbox);
    for (@l) {
      $inbox = 1 if /^# Inbox/; $inbox = 0 if /^# Open/;
      if ($inbox && /^\s*-?\s*P([123])\s*-\s*(\S.*?)\s*$/) { push @new, [$1, $2]; next }
      push @keep, $_;
    }
    exit 0 unless @new;
    # keep exactly one empty "- " line in the Inbox
    unless (grep { /^- \s*$/ } @keep) {
      for my $i (0..$#keep) { if ($keep[$i] =~ /^# Open/) { splice @keep, $i, 0, "- \n", "\n"; last } }
    }
    my @p1; my $out = "";
    for my $n (@new) {
      my ($p, $txt) = @$n; my $id = sprintf "T-%04d", $next++;
      my @w = split /\s+/, $txt; my $title = join " ", @w[0 .. ($#w < 7 ? $#w : 7)];
      $out .= "\n## $id · $title\nTRIAGED P$p · Other · $ENV{TODAY} · owner\n> P$p - $txt\n";
      push @p1, $id if $p == 1;
    }
    s/^Next ID: T-\d+/sprintf "Next ID: T-%04d", $next/e for @keep;
    $keep[-1] .= "\n" unless $keep[-1] =~ /\n$/;
    open my $o, ">", "$f.tmp.$$" or die; print $o @keep, $out; close $o;
    rename "$f.tmp.$$", $f or die;
    print "$_\n" for @p1;
  ' "$TRIAGE"
}

starts_today() { grep -c "^$(date +%F) " "$STARTS" 2>/dev/null || true; }

start_agent() {
  local id=$1 slug=${1:l} wt
  wt=$REPO/.claude/worktrees/$slug
  if [[ -n ${TRIAGE_DRY:-} ]]; then say "DRY start $id"; print "$(date +%F) $id" >> "$STARTS"; return 0; fi
  if [[ -n ${TRIAGE_NO_WORKTREE:-} ]]; then wt=$REPO
  else git -C "$REPO" worktree add "$wt" -b "work/$slug" >> "$LOG" 2>&1 || { say "worktree failed for $id"; return 1; }; fi
  print "$(date +%F) $id" >> "$STARTS"
  notify "Agent started on $id"
  # Regression guard: the running marker is owned by the background agent, not by drain's lock,
  # so a second save can never start a second agent while the first still runs.
  print "starting $id" > "$RUNNING"
  (
    trap 'rm -f "$RUNNING"' EXIT INT TERM HUP
    cd "$wt" && "$CLAUDE" -p --permission-mode default --add-dir "$REPO/docs/specs" \
"/bug $id
The entry is in $TRIAGE (absolute path; git-ignored, so not in this worktree). Read only that entry and write its status lines there.
You are in worktree $wt on branch work/$slug. Fix it test-first as /bug says.
Stop at a commit on this branch plus one line in $REPO/.handoff/MERGE-QUEUE.md. Never merge, push or install.
Take the BUILD LOCK in that file before any build and free it after.
If a permission prompt or anything else blocks you, write '$id blocked: <why>' to $STATE/blocked and stop." \
      >> "$STATE/$id.out" 2>&1
    rc=$?
    say "agent $id exit $rc"
    notify "Agent finished $id (exit $rc); see the merge queue"
  ) &!
  print "$! $id" > "$RUNNING"
}

# True while a started agent is still alive; clears a marker whose process is gone.
agent_running() {
  [[ -f $RUNNING ]] || return 1
  local pid; pid=$(awk '{print $1}' "$RUNNING")
  [[ $pid == starting ]] && return 0
  kill -0 "$pid" 2>/dev/null && return 0
  say "stale running marker ($pid) cleared"; rm -f "$RUNNING"; return 1
}

# Start queued P1s, one at a time, within the daily cap, online, BUILD LOCK free.
drain() {
  mkdir "$STATE/agent.lock" 2>/dev/null || { say "agent running; queue waits"; return 0; }
  {
    local id
    id=$(head -1 "$QUEUE")
    [[ -z $id ]] && return 0
    agent_running && { say "$id queued: an agent is still running"; return 0; }
    if (( $(starts_today) >= DAILY_CAP )); then notify "$id waits: $DAILY_CAP auto-starts used today"; return 0; fi
    online || { say "$id queued: offline"; return 0; }
    build_lock_free || { say "$id queued: BUILD LOCK taken"; return 0; }
    sed -i '' '1d' "$QUEUE"
    start_agent "$id"
  } always { rmdir "$STATE/agent.lock" 2>/dev/null }
}

run() {
  mkdir "$STATE/file.lock" 2>/dev/null || exit 0
  {
    [[ -n ${TRIAGE_NO_DEBOUNCE:-} ]] || debounce || exit 0
    local ids; ids=$(file_inbox)
    for id in ${(f)ids}; do print "$id" >> "$QUEUE"; say "filed $id (P1), queued"; done
    drain
  } always { rmdir "$STATE/file.lock" 2>/dev/null }
}

selftest() {
  local d; d=$(mktemp -d "${TMPDIR:-/tmp}/tw.XXXX") || exit 1
  export TRIAGE_FILE=$d/triage.md TRIAGE_STATE=$d/state TRIAGE_NO_DEBOUNCE=1 TRIAGE_NO_NOTIFY=1 TRIAGE_DRY=1 TRIAGE_REPO=$d
  mkdir -p $d/.handoff; print "BUILD LOCK: free" > $d/.handoff/MERGE-QUEUE.md
  cat > $TRIAGE_FILE <<'EOF'
# Recense triage
Next ID: T-0001

# Inbox
Write here.

P1 - no floating window over youtube.com in Safari
P2 - calendar colours too bright at night
-

# Open
Area: Other
EOF
  local fail=0
  ok()  { print "ok   $1"; }
  bad() { print "FAIL $1"; fail=1; }
  TRIAGE_ONLINE=1 zsh $SELF run
  grep -q '^## T-0001 · no floating window over youtube.com in Safari' $TRIAGE_FILE && grep -q '^TRIAGED P1 ' $TRIAGE_FILE && ok "P1 filed as T-0001" || bad "P1 filed"
  grep -q '^## T-0002 · calendar colours' $TRIAGE_FILE && grep -q '^TRIAGED P2 ' $TRIAGE_FILE && ok "P2 filed as T-0002" || bad "P2 filed"
  grep -q '^Next ID: T-0003' $TRIAGE_FILE && ok "Next ID raised to T-0003" || bad "Next ID"
  sed -n '/^# Inbox/,/^# Open/p' $TRIAGE_FILE | grep -q '^P[123] -' && bad "Inbox cleared" || ok "Inbox cleared"
  sed -n '/^# Inbox/,/^# Open/p' $TRIAGE_FILE | grep -q '^- *$' && ok "empty - line kept" || bad "empty - line kept"
  [[ $(grep -c ' T-0001$' $TRIAGE_STATE/starts) == 1 ]] && ok "P1 started one agent" || bad "P1 agent start"
  grep -q 'T-0002' $TRIAGE_STATE/starts && bad "P2 started no agent" || ok "P2 started no agent"
  TRIAGE_ONLINE=1 zsh $SELF run
  [[ $(grep -c '^## T-' $TRIAGE_FILE) == 2 ]] && ok "second save files nothing twice" || bad "double save"
  sed -i '' 's/^- $/P1 - offline bug/' $TRIAGE_FILE
  TRIAGE_ONLINE=0 zsh $SELF run
  grep -q '^T-0003$' $TRIAGE_STATE/queue && ! grep -q 'T-0003' $TRIAGE_STATE/starts && ok "offline: T-0003 filed and queued" || bad "offline queue"
  TRIAGE_ONLINE=1 zsh $SELF run
  grep -q 'T-0003' $TRIAGE_STATE/starts && ok "back online: queue drained" || bad "queue drain"
  for n in 4 5; do sed -i '' "s/^- \$/P1 - cap bug $n/" $TRIAGE_FILE; TRIAGE_ONLINE=1 zsh $SELF run; done
  [[ $(grep -c "^$(date +%F) " $TRIAGE_STATE/starts) == 3 ]] && grep -q '^T-0005$' $TRIAGE_STATE/queue && ok "daily cap 3: T-0005 waits" || bad "daily cap"
  sed -i '' 's/^BUILD LOCK: free/BUILD LOCK: someone since 10:00/' $d/.handoff/MERGE-QUEUE.md
  : > $TRIAGE_STATE/starts
  TRIAGE_ONLINE=1 zsh $SELF run
  grep -q 'T-0005' $TRIAGE_STATE/starts && bad "BUILD LOCK respected" || ok "BUILD LOCK respected"
  # Regression guard: one agent at a time while a real (background) agent runs.
  : > $TRIAGE_STATE/starts; : > $TRIAGE_STATE/queue
  sed -i '' 's/^BUILD LOCK: .*/BUILD LOCK: free/' $d/.handoff/MERGE-QUEUE.md
  print '#!/bin/zsh\nsleep 3' > $d/fake-claude; chmod +x $d/fake-claude
  ( unset TRIAGE_DRY; export TRIAGE_CLAUDE=$d/fake-claude TRIAGE_NO_WORKTREE=1 TRIAGE_ONLINE=1
    sed -i '' 's/^- $/P1 - slow agent A/' $TRIAGE_FILE; zsh $SELF run
    sleep 1
    sed -i '' 's/^- $/P1 - slow agent B/' $TRIAGE_FILE; zsh $SELF run )
  local a=$(grep -c . $TRIAGE_STATE/starts)
  [[ $a == 1 ]] && grep -q '^T-0007$' $TRIAGE_STATE/queue && ok "two saves 1 s apart: one agent, second queued" || bad "one agent at a time (starts=$a)"
  sleep 3
  ( unset TRIAGE_DRY; export TRIAGE_CLAUDE=$d/fake-claude TRIAGE_NO_WORKTREE=1 TRIAGE_ONLINE=1; zsh $SELF run )
  grep -q 'T-0007' $TRIAGE_STATE/starts && ok "drains after the first agent exits" || bad "drain after exit"
  sleep 4
  rm -rf $d
  (( fail )) && { print "selftest FAILED"; exit 1; } || print "selftest ok"
}

case ${1:-run} in
  run) run ;;
  selftest) selftest ;;
  *) print "usage: triage-watch.zsh [run|selftest]"; exit 2 ;;
esac
