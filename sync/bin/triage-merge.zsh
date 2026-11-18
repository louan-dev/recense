#!/bin/zsh
# triage-merge: merges a triage fixer's branch into main with no AI call and no coordinator (owner, 2026-11-12).
# Runs hourly (launchd com.chauphan.triage-merge) and after each fixer exits. One branch at a time, under the BUILD LOCK.
# A branch work/t-#### merges only if every gate passes:
#   G1 its MERGE-QUEUE line says ready, and $STATE/<ID>.tests shows the regression test red before and green after;
#   G2 its diff touches only the scout's Where: files, their tests and README.md files (never .claude/** or settings);
#   G3 none of its files are uncommitted in main;
#   G4 merged first in a temporary worktree, where the Checks for each touched folder pass;
# then main fast-forwards to that merge, is pushed (never forced), the Mac app is installed if strip/ changed
# (iOS is left to the owner), the entry gets MERGED, and the worktree is cleaned up.
# Any failure: no merge; the entry gets "held: <gate>"; a notification gives one command to merge anyway or trash it.
# Selftest: zsh triage-merge.zsh selftest
# Registry verbs (PLAN-1118 §11b): `checks <feature>` runs one feature's Checks from docs/specs/PARITY.md and lists what only a device can prove;
# `sweep <feature>` finds a second copy of its symbols outside its home. Builds take the one BUILD LOCK, .handoff/build.lock (§12g).
set -u
SELF=${0:A}; HERE=${0:A:h}
[[ ${1:-} == selftest ]] && export TRIAGE_STATE=$(mktemp -d "${TMPDIR:-/tmp}/tm-state.XXXX")
setopt null_glob
unsetopt bg_nice

REPO=${TRIAGE_REPO:-/Users/chauphan/Developer/recense}
STATE=${TRIAGE_STATE:-$HOME/.local/state/triage-watch}
MQ=$REPO/.handoff/MERGE-QUEUE.md
WATCH=${TRIAGE_WATCH:-$HERE/triage-watch.zsh}
PUSH=${TRIAGE_PUSH:-1}
INSTALL=${TRIAGE_INSTALL:-1}
TOOLCHAIN=$REPO/.toolchain/CommandLineTools
LOG=$STATE/log
mkdir -p "$STATE"
say()    { print -r -- "$(date '+%F %T') merge: $*" >> "$LOG"; }
notify() { [[ -n ${TRIAGE_NO_NOTIFY:-} ]] || osascript -e "display notification \"$1\" with title \"Recense triage\"" >/dev/null 2>&1; say "notify: $1"; }
status() { zsh "$WATCH" status "$@"; }
g()      { git -C "$REPO" "$@"; }

# ---------- BUILD LOCK ----------
take_lock() {
  grep -q '^BUILD LOCK: free' "$MQ" 2>/dev/null || return 1
  sed -i '' "s/^BUILD LOCK: free.*/BUILD LOCK: triage-merge since $(date +%H:%M)/" "$MQ"
}
free_lock() { sed -i '' 's/^BUILD LOCK: triage-merge since .*/BUILD LOCK: free/' "$MQ"; }

# ---------- gates ----------
g1_ready_and_red_green() {
  local id=$1 br=$2 t=$STATE/$1.tests
  grep -E "^$br( |$)" "$MQ" | grep -qiv 'MERGED' || return 1
  grep -E "^$br( |$)" "$MQ" | grep -qi 'ready' || return 1
  [[ -f $t ]] || return 1
  grep -qE '^red [1-9][0-9]*$' "$t" && grep -qE '^green 0$' "$t"
}

changed_files() { g diff --name-only "main...$1"; }

g2_only_where_files() {
  local id=$1 br=$2 f w ok dir
  local -a where; where=(${(s:, :)$(zsh "$WATCH" where "$id")})
  (( ${#where} )) || return 1
  for f in ${(f)"$(changed_files $br)"}; do
    [[ $f == .claude/* || $f == */settings*.json || $f == settings*.json ]] && return 1
    ok=0
    for w in $where; do
      dir=${w:h}
      [[ $f == $w ]] && ok=1
      [[ ${f:t} == README.md ]] && [[ ${f:h} == $dir || $dir == ${f:h}/* ]] && ok=1
      [[ $f == ${w:r}.test.* || $f == ${w:r}_test.* || $f == ${w:r}Tests.* ]] && ok=1
      [[ $f == */test/* || $f == */tests/* || $f == */Tests/* ]] && [[ ${f:t:r} == ${w:t:r}* || ${f:t:r} == *${w:t:r}* ]] && ok=1
    done
    (( ok )) || { say "$id: $f is outside Where"; return 1; }
  done
}

g3_no_overlap() {
  local br=$1 f dirty
  dirty=$(g status --porcelain | cut -c4- | sed 's/.* -> //')
  for f in ${(f)"$(changed_files $br)"}; do
    print -r -- "$dirty" | grep -qxF -- "$f" && { say "$f is uncommitted in main"; return 1; }
  done
  return 0
}

# Checks per touched top-level folder, run inside the temporary worktree.
run_checks() {
  local tmp=$1 br=$2 top
  if [[ -n ${TRIAGE_CHECKS:-} ]]; then (cd "$tmp" && eval "$TRIAGE_CHECKS"); return; fi
  local -U tops; tops=(${(f)"$(changed_files $br | awk -F/ '{print ($1=="shared" && $2=="ShowsKit") ? "ShowsKit" : $1}')"})
  for top in $tops; do
    case $top in
      strip)    (cd "$tmp/strip" && DEVELOPER_DIR=$TOOLCHAIN swift build -c release --product recense --scratch-path .build-sdk27 --build-system native >/dev/null 2>&1) || return 1 ;;
      ShowsKit) (cd "$tmp/shared/ShowsKit" && swift test >/dev/null 2>&1) || return 1 ;;
      library|sync|calendar|editor) (cd "$tmp/$top" && npm test >/dev/null 2>&1) || return 1 ;;
      mobile)   xcodebuild -project "$tmp/mobile/ios/GalleryFiles.xcodeproj" -scheme GalleryFiles -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build >/dev/null 2>&1 || return 1 ;;
      docs|README.md) ;;
      *) say "no Check known for $top"; return 1 ;;
    esac
  done
}

hold() {
  local id=$1 br=$2 why=$3
  status "$id" "held: $why"
  notify "$id held ($why). Merge anyway: git -C $REPO merge --no-ff $br — or trash: trash $REPO/.claude/worktrees/${br#work/} && git -C $REPO branch -D $br"
  say "$id held: $why"
}

merge_one() {
  local id=$1 br=work/${1:l} tmp sha
  g1_ready_and_red_green "$id" "$br" || { hold "$id" "$br" "not ready, or no red→green test record"; return 1; }
  g2_only_where_files   "$id" "$br" || { hold "$id" "$br" "touches files outside Where"; return 1; }
  g3_no_overlap         "$br"       || { hold "$id" "$br" "overlaps uncommitted files in main"; return 1; }
  tmp=$STATE/merge-${1:l}
  rm -rf "$tmp"; g worktree prune
  g worktree add -q --detach "$tmp" main >> "$LOG" 2>&1 || { hold "$id" "$br" "temp worktree failed"; return 1; }
  if ! git -C "$tmp" -c user.name=triage-merge -c user.email=triage-merge@localhost merge -q --no-ff --no-edit "$br" >> "$LOG" 2>&1; then
    g worktree remove --force "$tmp"; hold "$id" "$br" "merge conflict"; return 1
  fi
  if ! run_checks "$tmp" "$br"; then g worktree remove --force "$tmp"; hold "$id" "$br" "Checks failed"; return 1; fi
  sha=$(git -C "$tmp" rev-parse HEAD)
  g worktree remove --force "$tmp"
  # main fast-forwards only to the commit that passed; the main checkout must be on main
  [[ $(g rev-parse --abbrev-ref HEAD) == main ]] || { hold "$id" "$br" "main checkout is not on main"; return 1; }
  g merge -q --ff-only "$sha" >> "$LOG" 2>&1 || { hold "$id" "$br" "main moved; fast-forward failed"; return 1; }
  print -r -- "MERGED ${sha[1,7]} $(date '+%m-%d') by triage-merge · $br · $id" >> "$MQ"
  local msg="$id merged (${sha[1,7]})"
  if (( PUSH )); then g push -q origin main >> "$LOG" 2>&1 && msg+=", pushed" || msg+=", push FAILED (run: git -C $REPO push origin main)"; fi
  if (( INSTALL )) && changed_files "$sha^1" | grep -q '^strip/'; then
    (cd "$REPO/strip" && zsh build.sh >> "$LOG" 2>&1 && ./recense selftest >> "$LOG" 2>&1) && msg+=", Mac app installed" || msg+=", Mac install or selftest FAILED (see $LOG)"
  fi
  g diff --name-only "$sha^1" "$sha" | grep -q '^mobile/' && msg+="; iPhone/iPad: install it yourself (zsh $REPO/mobile/ios/build.sh)"
  status "$id" MERGED "${sha[1,7]}"
  zsh "$WATCH" cleanup
  notify "$msg"
}

run() {
  local br id
  take_lock || { say "BUILD LOCK taken; try later"; return 0; }
  {
    for br in ${(f)"$(g for-each-ref --format='%(refname:short)' 'refs/heads/work/t-[0-9]*')"}; do
      g merge-base --is-ancestor "$br" main 2>/dev/null && continue
      id=${${br#work/}:u}
      grep -qE "^$br( |$)" "$MQ" || continue          # not offered yet
      grep -E "^$br( |$)" "$MQ" | grep -qi 'held' && continue
      merge_one "$id"
      break                                           # one branch per run
    done
  } always { free_lock }
}

# ---------- registry verbs: checks <feature>, sweep <feature> (PLAN-1118 §11b, §12g) ----------
# The registry is docs/specs/PARITY.md: one block per feature between "<!-- parity:begin F -->" and "<!-- parity:end -->".
ROOT=${TRIAGE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || print -r -- $REPO)}
PARITY=${TRIAGE_PARITY:-$ROOT/docs/specs/PARITY.md}
BLOCK_LOCK=${TRIAGE_BUILD_LOCK:-$REPO/.handoff/build.lock}   # one lock for every stream; the main checkout holds it

parity_block() { [[ -f $PARITY ]] && awk -v f="$1" '$0=="<!-- parity:begin " f " -->"{on=1;next} $0=="<!-- parity:end -->"{on=0} on' "$PARITY"; }
block_keys()   { print -r -- "$1" | sed -n "s/^$2: //p"; }

free_pct() {
  [[ -n ${TRIAGE_FREE_PCT:-} ]] && { print -r -- $TRIAGE_FREE_PCT; return; }
  memory_pressure 2>/dev/null | awk '/free percentage/{gsub("%","",$NF); print $NF}'
}

# Waits for 20 % free RAM, then takes build.lock (mkdir is atomic). Returns 1 after TRIAGE_LOCK_WAIT seconds.
take_build_lock() {
  local who=$1 waited=0 poll=${TRIAGE_LOCK_POLL:-120} max=${TRIAGE_LOCK_WAIT:-1800} pct
  mkdir -p "${BLOCK_LOCK:h}"
  while true; do
    pct=$(free_pct); pct=${pct:-100}
    if (( pct >= 20 )) && mkdir "$BLOCK_LOCK" 2>/dev/null; then print -r -- "$who $$ $(date +%T)" > "$BLOCK_LOCK/who"; return 0; fi
    (( waited >= max )) && return 1
    sleep $poll; (( waited += poll ))
  done
}
release_build_lock() { ${=TRIAGE_TRASH:-trash} "$BLOCK_LOCK" 2>/dev/null; }

# checks <feature>: runs only that feature's `check:` lines from the registry, prints the embodiments and the owed device checks.
cmd_checks() {
  local feat=${1:-} blk line spec dir cmd lock fail=0 n=0
  [[ -n $feat ]] || { print "usage: triage-merge.zsh checks <feature>"; return 2; }
  blk=$(parity_block "$feat")
  [[ -n $blk ]] || { print "no registry block '$feat' in $PARITY (add one: /parity $feat)"; return 2; }
  export RECENSE_TOOLCHAIN=${RECENSE_TOOLCHAIN:-$REPO/.toolchain/CommandLineTools}
  for line in ${(f)"$(block_keys "$blk" check)"}; do
    spec=$line; lock=0; (( n++ ))
    [[ $spec == "lock "* ]] && { lock=1; spec=${spec#lock }; }
    dir=${spec%% :: *}; cmd=${spec#* :: }
    if (( lock )) && ! take_build_lock "checks:$feat"; then print "FAIL lock    $dir :: $cmd (build.lock busy: $(cat $BLOCK_LOCK/who 2>/dev/null))"; fail=1; continue; fi
    {
      (( lock )) && trap 'release_build_lock; exit 130' INT TERM   # a Ctrl-C or kill never leaves the lock behind (review 5ee2110)
      if (cd "$ROOT/$dir" && ROOT=$ROOT eval "$cmd") >/dev/null 2>&1; then print "ok   $dir :: ${cmd[1,70]}"; else print "FAIL $dir :: ${cmd[1,70]}"; fail=1; fi
    } always {
      (( lock )) && { release_build_lock; trap - INT TERM; }
    }
  done
  (( n )) || { print "FAIL $feat has no check: line"; fail=1; }
  print "Embodiments: $(block_keys "$blk" embodiments)"
  for line in ${(f)"$(block_keys "$blk" device)"}; do print "Not checked (device): $line"; done
  (( fail )) && { print "checks $feat FAILED"; return 1; } || print "checks $feat ok"
}

# sweep <feature>: textual search (not an AST) for a definition of one of the block's `symbols:` outside its `home:`.
# Looks at func/class/struct/enum/actor/protocol/typealias/extension (Swift), function/class/const/let/var (JS) and def (Python); skips tests.
cmd_sweep() {
  local feat=${1:-} blk sym h f hit found=0 inhome
  [[ -n $feat ]] || { print "usage: triage-merge.zsh sweep <feature>"; return 2; }
  blk=$(parity_block "$feat")
  [[ -n $blk ]] || { print "no registry block '$feat' in $PARITY"; return 2; }
  local -a homes syms; homes=(${=$(block_keys "$blk" home)}); syms=(${=$(block_keys "$blk" symbols)})
  (( ${#syms} )) || { print "FAIL $feat has no symbols: line, nothing to sweep"; return 2; }
  cd "$ROOT" || return 2
  for sym in $syms; do
    for hit in ${(f)"$(grep -rnE --include='*.swift' --include='*.js' --include='*.mjs' --include='*.py' --include='*.ts' \
        --exclude-dir=node_modules --exclude-dir=.build --exclude-dir=.build-sdk27 --exclude-dir=dist --exclude-dir=.git \
        --exclude-dir=.claude --exclude-dir=.toolchain --exclude-dir=.test-build --exclude-dir=backups --exclude-dir=.scratch \
        --exclude-dir=test --exclude-dir=tests --exclude-dir=Tests --exclude-dir=docs \
        "(^|[^[:alnum:]_])((func|class|struct|enum|actor|protocol|typealias|extension|function|def)[[:space:]]+|(const|let|var)[[:space:]]+)$sym([^[:alnum:]_]|$)" . 2>/dev/null | sed 's#^\./##')"}; do
      f=${hit%%:*}; inhome=0
      for h in $homes; do [[ $f == ${~h}* ]] && inhome=1; done
      (( inhome )) || { print "SECOND COPY $sym at $hit"; found=1; }
    done
  done
  (( found )) && { print "sweep $feat FOUND second copies (delete them, do not wrap them)"; return 1; } || print "sweep $feat clean (textual search; ast-grep is not installed)"
}

# ---------- selftest ----------
selftest() {
  local d fail=0; d=$(mktemp -d "${TMPDIR:-/tmp}/tm.XXXX") || exit 1
  ok()  { print "ok   $1"; }
  bad() { print "FAIL $1"; fail=1; }
  export TRIAGE_REPO=$d/repo TRIAGE_FILE=$d/triage.md TRIAGE_NO_NOTIFY=1 TRIAGE_PUSH=0 TRIAGE_INSTALL=0 TRIAGE_CHECKS=true TRIAGE_TRASH="rm -rf"
  local R=$d/repo G=(-c user.email=t@t -c user.name=t)
  setup() {
    rm -rf $R $TRIAGE_STATE; mkdir -p $R/.handoff $R/app $TRIAGE_STATE
    git -C $R init -q -b main
    print "BUILD LOCK: free" > $R/.handoff/MERGE-QUEUE.md; : > $R/.handoff/LANES.md
    print 'x' > $R/app/main.js; print 'y' > $R/app/other.js; print '.handoff/' > $R/.gitignore
    git -C $R add . && git -C $R $G commit -qm init
    printf '# t\nNext ID: T-0002\n\n# Inbox\n- \n\n# Open\nArea: UI | Other\n\n## T-0001 · bug\n! NEW · UI · 2026-11-12 · owner\n> bug\nWhere: app/main.js\nRepro: x (guess)\n' > $TRIAGE_FILE
    git -C $R worktree add -q $R/.claude/worktrees/t-0001 -b work/t-0001
    git -C $R rev-parse main > $TRIAGE_STATE/t-0001.base
    print 'work/t-0001 · fix · ready' >> $R/.handoff/MERGE-QUEUE.md
    printf 'red 1\ngreen 0\n' > $TRIAGE_STATE/T-0001.tests
  }
  fixer_commits() { local f; for f in "$@"; do print fix >> $R/.claude/worktrees/t-0001/$f; done
    git -C $R/.claude/worktrees/t-0001 add -A && git -C $R/.claude/worktrees/t-0001 $G commit -qm fix; }
  merged() { git -C $R merge-base --is-ancestor work/t-0001 main 2>/dev/null; }

  setup; mkdir -p $R/.claude/worktrees/t-0001/app/test; fixer_commits app/main.js; print t > $R/.claude/worktrees/t-0001/app/test/main.test.js; git -C $R/.claude/worktrees/t-0001 add -A; git -C $R/.claude/worktrees/t-0001 $G commit -qm test
  zsh $SELF run
  git -C $R log --format=%s main | grep -qx test && [[ $(git -C $R log -1 --format=%s main) == Merge* ]] && ok "clean branch merges and main fast-forwards" || bad "clean merge"
  grep -q '^MERGED .* by triage-merge · work/t-0001' $R/.handoff/MERGE-QUEUE.md && ok "MERGED line by triage-merge" || bad "MERGED line"
  grep -q '· MERGED · triage-watch' $TRIAGE_FILE && ok "entry marked MERGED" || bad "entry MERGED"
  [[ ! -d $R/.claude/worktrees/t-0001 ]] && ok "worktree cleaned up" || bad "cleanup"
  grep -q '^BUILD LOCK: free' $R/.handoff/MERGE-QUEUE.md && ok "lock freed after the run" || bad "lock free"

  setup; fixer_commits app/main.js; : > $TRIAGE_STATE/T-0001.tests
  zsh $SELF run; ! merged && grep -q 'held: not ready, or no red→green' $TRIAGE_FILE && ok "G1 no red→green record → held" || bad "G1"

  setup; fixer_commits app/main.js; sed -i '' 's/ · ready$/ · working/' $R/.handoff/MERGE-QUEUE.md
  zsh $SELF run; ! merged && ok "G1 not ready → held" || bad "G1 ready"

  setup; fixer_commits app/main.js app/other.js
  zsh $SELF run; ! merged && grep -q 'held: touches files outside Where' $TRIAGE_FILE && ok "G2 outside Where → held" || bad "G2"

  setup; mkdir -p $R/.claude/worktrees/t-0001/.claude; fixer_commits app/main.js; print x > $R/.claude/worktrees/t-0001/.claude/settings.json; git -C $R/.claude/worktrees/t-0001 add -f -A; git -C $R/.claude/worktrees/t-0001 $G commit -qm s
  zsh $SELF run; ! merged && ok "G2 touches .claude/ → held" || bad "G2 .claude"

  setup; fixer_commits app/main.js; print dirty >> $R/app/main.js
  zsh $SELF run; ! merged && grep -q 'held: overlaps uncommitted' $TRIAGE_FILE && ok "G3 overlap with main → held" || bad "G3"

  setup; fixer_commits app/main.js
  TRIAGE_CHECKS=false zsh $SELF run; ! merged && grep -q 'held: Checks failed' $TRIAGE_FILE && ok "G4 Checks fail → held, main untouched" || bad "G4"

  setup; fixer_commits app/main.js; sed -i '' 's/^BUILD LOCK: free/BUILD LOCK: someone since 09:00/' $R/.handoff/MERGE-QUEUE.md
  zsh $SELF run; ! merged && grep -q '^BUILD LOCK: someone' $R/.handoff/MERGE-QUEUE.md && ok "BUILD LOCK respected" || bad "lock"


  # ---- registry verbs ----
  local RT=$d/reg; rm -rf $RT; mkdir -p $RT/docs/specs $RT/shared/voice $RT/shared/other $RT/shared/other/test
  cat > $RT/docs/specs/PARITY.md <<'PEOF'
<!-- parity:begin demo -->
feature: demo
home: shared/voice/ shared/lib*.swift
symbols: bestVoice Mixer
embodiments: mac=[ ] iphone=[ ] ipad=[ ] web=n/a
check: . :: true
check: lock shared :: test -d voice
device: Wi-Fi off, play on iPhone
<!-- parity:end -->
<!-- parity:begin bad -->
feature: bad
check: . :: false
<!-- parity:end -->
PEOF
  print 'func bestVoice() {}' > $RT/shared/voice/a.swift
  print 'struct Mixer {}' > $RT/shared/libmix.swift
  export TRIAGE_ROOT=$RT TRIAGE_BUILD_LOCK=$d/build.lock TRIAGE_FREE_PCT=50 TRIAGE_LOCK_POLL=1 TRIAGE_LOCK_WAIT=2
  local out; out=$(zsh $SELF checks demo 2>&1); local rc=$?
  (( rc == 0 )) && print -r -- $out | grep -q 'Not checked (device): Wi-Fi off' && print -r -- $out | grep -q 'Embodiments: mac=\[ \]' && ok "checks runs a feature's lines, prints embodiments and owed device checks" || bad "checks demo ($out)"
  [[ ! -d $d/build.lock ]] && ok "checks frees build.lock after a lock line" || bad "build.lock left behind"
  zsh $SELF checks bad >/dev/null 2>&1 && bad "checks bad should fail" || ok "a failing check line fails checks"
  zsh $SELF checks nope >/dev/null 2>&1; (( $? == 2 )) && ok "unknown feature → exit 2" || bad "checks unknown"
  mkdir $d/build.lock; print other > $d/build.lock/who
  out=$(zsh $SELF checks demo 2>&1); print -r -- $out | grep -q 'FAIL lock.*build.lock busy: other' && ok "held build.lock makes the lock line fail, not run" || bad "lock held ($out)"
  rm -rf $d/build.lock
  out=$(TRIAGE_FREE_PCT=10 zsh $SELF checks demo 2>&1); print -r -- $out | grep -q 'FAIL lock' && ok "under 20 % free RAM the lock line waits, then fails" || bad "ram gate"
  out=$(zsh $SELF sweep demo 2>&1); (( $? == 0 )) && ok "sweep: definitions inside the home are not second copies" || bad "sweep clean ($out)"
  print 'func bestVoice() {}' > $RT/shared/other/b.swift; print 'func bestVoice() {}' > $RT/shared/other/test/t.swift
  out=$(zsh $SELF sweep demo 2>&1); local rc2=$?
  (( rc2 == 1 )) && print -r -- $out | grep -q 'SECOND COPY bestVoice at shared/other/b.swift:1' && ! print -r -- $out | grep -q 'test/t.swift' && ok "sweep finds a second copy outside the home and skips tests" || bad "sweep copy ($out)"
  print 'const bestVoice = () => {}' > $RT/shared/other/c.js
  out=$(zsh $SELF sweep demo 2>&1); print -r -- $out | grep -q 'SECOND COPY bestVoice at shared/other/c.js:1' && ok "sweep finds a const-style second copy" || bad "sweep const ($out)"
  rm -f $RT/shared/other/c.js
  zsh $SELF checks demo >/dev/null 2>&1   # warm: the lock line must not leave build.lock behind when killed
  cat >> $RT/docs/specs/PARITY.md <<'PEOF'
<!-- parity:begin killme -->
feature: killme
check: lock . :: kill -TERM $$; sleep 5
<!-- parity:end -->
PEOF
  zsh $SELF checks killme >/dev/null 2>&1; [[ ! -d $d/build.lock ]] && ok "a killed checks run releases build.lock" || bad "build.lock leaked after kill"
  rm -rf $d/build.lock
  unset TRIAGE_ROOT TRIAGE_BUILD_LOCK TRIAGE_FREE_PCT TRIAGE_LOCK_POLL TRIAGE_LOCK_WAIT

  rm -rf $d $TRIAGE_STATE
  (( fail )) && { print "selftest FAILED"; exit 1; } || print "selftest ok"
}

case ${1:-run} in
  run) run ;;
  selftest) selftest ;;
  checks) shift; cmd_checks "$@"; exit $? ;;
  sweep) shift; cmd_sweep "$@"; exit $? ;;
  *) print "usage: triage-merge.zsh [run|selftest|checks <feature>|sweep <feature>]"; exit 2 ;;
esac
