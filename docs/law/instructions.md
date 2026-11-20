# Recense Administrative Instructions

Paths, templates, commands and hook text made under `docs/law/treaty.md`, Article 14(2).
Any agent may correct a path that has moved. Nothing here may contradict an Article or a Rule.
Rules: `docs/law/regulations.md`. Map: `docs/GENETIC-MAP.md`. Index: `docs/PROVISIONAL-SPEC.md`, Appendix T.

## 1 · Where things are

Tracked (public repo, reaches every worktree):
- `AGENTS.md`: the first-instinct gate.
- `docs/law/treaty.md`, `regulations.md`, `instructions.md`: this law.
- `docs/GENETIC-MAP.md`: twin clusters and the routing table.
- `docs/specs/PARITY.md`: the registry (`<!-- parity:begin F -->` blocks). Read by `triage-merge.zsh checks|sweep`, the `/parity` skill and `coord.zsh gate`.
- `docs/AGENT-LIMITS.md`, `docs/AUDIO-COORDINATION.md`, `docs/COMMANDS.md`.

Local to the main checkout (git-ignored, absent from worktrees):
- `.claude/CLAUDE.md`, `GEMINI.md`, `.handoff/`.
- Coordinator: `.handoff/coordinator/COORDINATOR.md`, `CURRENT` (the lease), `inbox/`.
- Lanes: `.handoff/<area>/HANDOFF.md` (with `## Resume here`) and `INBOX.md`; `.handoff/LANES.md`; `.handoff/MERGE-QUEUE.md`.
- Triage: `docs/specs/triage.md`.

Per user (shared by the four accounts through symlinks):
- `~/.claude/CLAUDE.md`, `~/.claude/settings.json`, `~/.claude/skills`.
- Context and trackers: `~/.claude/context/recense/` (`INDEX.md`, `notes/`).
- agy: `~/.gemini/config/GEMINI.md`. Codex: `~/.codex/` (no instruction file yet).

## 2 · Commands every agent uses

- Who holds the lease: `zsh sync/bin/coord.zsh who`
- Post a message: `zsh sync/bin/coord.zsh post <file>`
- List and close inbox files: `zsh sync/bin/coord.zsh inbox` and `zsh sync/bin/coord.zsh done <file>`
- Pick a judge: `zsh sync/bin/coord.zsh assign <branch>`
- Find second copies of a feature: `zsh sync/bin/triage-merge.zsh sweep <feature>`
- Run a feature's checks and print its unchecked devices: `zsh sync/bin/triage-merge.zsh checks <feature>` (it runs the block's `check:` lines, which can build and take the build lock)
- Print the wish order: `cd sync && node src/wishrank.mjs`
- Sync selftests: `cd sync && npm test`
- Effort: `/effort high`, or `claude --effort xhigh`
- Open a terminal as account N: `cswap run N`

## 3 · The Locus Declaration

Full form (Article 7(1)), printed and recorded by the helper in section 5:

```
recense-locus declare "<genotype>" "Patch all loci together" <path:lines> <path:lines> ...
```

Prints:

```
Genotype / Bug DNA: <pattern or symbol>
All Matching Loci: <path:lines> <path:lines> ...
Action: Patch all loci together
```

The action is one of `Patch all loci together` or `Collapse into canonical shared locus`.
One locus (Article 7(2)): `recense-locus declare unique "patch" <path:lines>`.

## 4 · Closing block (Article 9)

At most 15 short lines. Then the `Checked:` line. Then the `[DONE: ...]` line.

```
CLOSING · <yyyy-mm-dd> · <agent id> · acct-<1-4> · Provisional Spec 2026-11-20
Scope: <what in Recense this touched, now>
Done: <completed items>
Bugs: <found; T-#### or BUG-##>
Loose ends: <unresolved, each with a path>
Next: <the exact command>
Plan: <path, or none>
Moat: <contender with its proof path, or none>
```

Notes:
- The account's email is not written. In the terminal only, `cswap list` shows which account is which.
- A moat entry needs a path or a measured result. Strong ones go to `~/.claude/context/recense/notes/MOAT.md`.

## 5 · Hooks (drafted and tested here; not installed)

Why hooks: prose can be skipped. A hook runs every time.
Status: tested on fake sessions on 2026-11-20 (8 cases: undeclared source edit blocked; docs, outside-repo, declared, worktree-path, other-session, off-switch and bad-JSON cases as expected).
Assumed from the Claude Code hooks documentation, **untested in a live session**: a `PreToolUse` hook that exits 2 blocks the tool call and shows stderr to the agent; `SessionStart` stdout is added to the session; the hook input is JSON with `session_id` and `tool_input.file_path`.

What the gate does:
- Blocks `Edit` and `Write` on a source file in `~/Developer/recense` (`swift js mjs zsh sh py css html`) until this session has run `recense-locus declare` naming that file.
- Lets pass: docs, markdown, `.claude/`, `.handoff/`, files outside the repo, and anything it cannot parse (it fails open).
- Off switch: `RECENSE_LOCUS_OFF=1`.

The files below are the single source. The extract command in the next step writes them.

<!-- file:recense-locus -->
```zsh
#!/bin/zsh
# recense-locus: the Locus Declaration (docs/law/treaty.md, Article 7) and its marker.
#   recense-locus declare "<genotype>" "<action>" <path[:lines]>...
# Prints the three lines and records each path for this session, so recense-locus-gate lets edits to it through.
set -u
sid=${CLAUDE_CODE_SESSION_ID:-nosession}
dir=${RECENSE_LOCUS_DIR:-$HOME/.recense-locus}
case ${1:-} in
  declare)
    shift; g=${1:?genotype}; a=${2:?action}; shift 2
    (( $# )) || { print "recense-locus: name at least one path"; exit 2; }
    mkdir -p $dir
    print "Genotype / Bug DNA: $g"; print "All Matching Loci: $*"; print "Action: $a"
    for p in "$@"; do print -r -- "${p%%:*}" >> $dir/$sid.loci; done ;;
  *) print "usage: recense-locus declare <genotype> <action> <path[:lines]>..."; exit 2 ;;
esac
```
<!-- endfile -->

<!-- file:recense-locus-gate -->
```zsh
#!/bin/zsh
# recense-locus-gate: Claude Code PreToolUse hook for Edit|Write (docs/law/treaty.md, Article 7).
# Blocks an edit to a source file in the Recense repo until this session has declared it with recense-locus.
# Exit 2 = block, with the reason on stderr. RECENSE_LOCUS_OFF=1 turns it off.
[[ -n ${RECENSE_LOCUS_OFF:-} ]] && exit 0
in=$(cat)
read -r sid f < <(print -r -- $in | python3 -c 'import sys,json
d=json.load(sys.stdin); print(d.get("session_id") or "nosession", (d.get("tool_input") or {}).get("file_path",""))' 2>/dev/null)
[[ -n ${f:-} ]] || exit 0
norm() { local p=$1; p=${p#$HOME/Developer/recense/}; p=${p#.claude/worktrees/*/}; print -r -- $p }
[[ $f == $HOME/Developer/recense/* ]] || exit 0
n=$(norm $f)
case $n in docs/*|*.md|.claude/*|.handoff/*) exit 0 ;; esac
case ${n:e} in swift|js|mjs|zsh|sh|py|css|html) ;; *) exit 0 ;; esac
dir=${RECENSE_LOCUS_DIR:-$HOME/.recense-locus}
if [[ -f $dir/$sid.loci ]]; then
  while IFS= read -r l; do [[ $(norm $l) == $n ]] && exit 0; done < $dir/$sid.loci
fi
print -u2 "Locus Declaration missing for $n. Run: recense-locus declare \"<genotype>\" \"Patch all loci together\" $n"
exit 2
```
<!-- endfile -->

<!-- file:install-law-hooks.py -->
```python
#!/usr/bin/python3 -I
# Adds the Recense law hooks to Claude Code settings without touching the hooks already there:
#   PreToolUse (Edit|Write) -> recense-locus-gate      (docs/law/treaty.md, Article 7)
#   SessionStart (extra command) -> prints AGENTS.md "First instinct" section
# Saves the old "hooks" block first. Safe to run twice. Usage: install-law-hooks.py [settings.json]
import json, os, sys

S = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.claude/settings.json")
GATE = os.path.expanduser("~/.local/bin/recense-locus-gate")
DIGEST = "sed -n '/^## First instinct/,$p' ~/Developer/recense/AGENTS.md"
if not os.path.exists(GATE) and len(sys.argv) == 1:
    sys.exit(f"stop: {GATE} does not exist; extract it first (docs/law/instructions.md, section 5)")

d = json.load(open(S))
if not os.path.exists(S + ".before-law-hooks.json"):
    open(S + ".before-law-hooks.json", "w").write(json.dumps(d.get("hooks", {}), indent=2))
h = d.setdefault("hooks", {})

def has(entries, cmd):
    return any(c.get("command") == cmd for e in entries for c in e.get("hooks", []))

pre = h.setdefault("PreToolUse", [])
if not has(pre, GATE):
    pre.append({"matcher": "Edit|Write", "hooks": [{"type": "command", "command": GATE, "timeout": 10}]})
start = h.setdefault("SessionStart", [])
if not has(start, DIGEST):
    start.append({"hooks": [{"type": "command", "command": DIGEST, "timeout": 10}]})

tmp = S + ".tmp"
json.dump(d, open(tmp, "w"), indent=2)
json.load(open(tmp))
os.replace(tmp, S)
print("law hooks installed: PreToolUse Edit|Write, SessionStart digest. Old hooks saved to", S + ".before-law-hooks.json")
```
<!-- endfile -->


Install, three steps. Each is a command for the owner to paste.

1. Extract the three files into `~/.local/bin`:

```
for f in recense-locus recense-locus-gate install-law-hooks.py; do awk -v n="$f" '$0=="<!-- file:"n" -->"{g=1;next} $0=="<!-- endfile -->"{g=0} g && !/^```/' ~/Developer/recense/docs/law/instructions.md > ~/.local/bin/$f && chmod +x ~/.local/bin/$f; done
```

   This writes the three scripts.

2. Run the coordinator hook installer first if it has not run (`python3 -I ~/.claude/context/recense/handoff/install-coord-hooks.py`). It replaces `SessionStart`, `SessionEnd` and `Stop`, so the law installer must come after it.

3. Add the law hooks:

```
python3 -I ~/.local/bin/install-law-hooks.py
```

   This adds a `PreToolUse` gate and a second `SessionStart` command, keeps every other hook, and saves the old block to `~/.claude/settings.json.before-law-hooks.json`.

To remove: restore that backup block into `~/.claude/settings.json`.

## 6 · The harmonize procedure (what the `monorepo-harmonize` skill follows)

1. Name the genotype. Open `docs/GENETIC-MAP.md` at its cluster.
2. Run `zsh sync/bin/triage-merge.zsh sweep <feature>`. A "FOUND second copies" line is a collapse candidate.
3. List the embodiments from `docs/specs/PARITY.md`.
4. Declare (section 3).
5. Cure every locus that builds today in one commit. Mark unverified devices (`[ ]`, `device:`). Leave an unbuildable twin alone and file its gap (Article 4).
6. After a change to a cluster, edit its lines in `docs/GENETIC-MAP.md` and run the citation check.

## 7 · The citation check

Prints `BAD` or `MISSING` for any `path:start-end` in a file that falls outside the cited file. Run from the repo root:

```
perl -ne 'while(/`([A-Za-z0-9_.\/@-]+\.[a-z]+):(\d+)(?:-(\d+))?`/g){print "$1 $2 ".($3//$2)."\n"}' docs/GENETIC-MAP.md | sort -u | while read p a b; do [ -f "$p" ] || { echo "MISSING $p"; continue; }; n=$(wc -l <"$p"); (( b>=a && b<=n )) || echo "BAD $p:$a-$b (file has $n lines)"; done
```

It proves a range fits its file, not that the words match. Spot-check a few by hand. Replace the file name to check another document.

## 8 · Zero-deletion proof (Article 8)

For each retrofitted tracked file, the third column must be 0:

```
git diff --numstat -- AGENTS.md docs/law/README.md
```

## Amendments
- 2026-11-20 · created on the owner's approval of the plan (revision 2b).
