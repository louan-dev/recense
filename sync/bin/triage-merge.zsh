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

  rm -rf $d $TRIAGE_STATE
  (( fail )) && { print "selftest FAILED"; exit 1; } || print "selftest ok"
}

case ${1:-run} in
  run) run ;;
  selftest) selftest ;;
  *) print "usage: triage-merge.zsh [run|selftest]"; exit 2 ;;
esac
