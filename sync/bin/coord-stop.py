#!/usr/bin/python3 -I
"""Stop hook for every Claude session (run as `zsh coord.zsh stop-hook`). Silent unless the lease holder must act.

- Runs `coord.zsh doctor --fix` (the bug-detection loop; script-fixable problems are fixed and logged, never shown).
- The lease holder only: blocks the stop once when
  1. this turn sent a message or wrote a coordinator/lane inbox file, but COORDINATOR.md was not updated in the turn;
  2. COORDINATOR.md breaks its caps (`coord.zsh state-check`);
  3. its transcript passed the size cap (a stand-in for ~50% context): it must `coord.zsh retire`, then end.
- Starts a fresh coordinator in the background when the lease is free and a message has waited 10+ min (`coord.zsh spawn`).
Any error: allow the stop. Nothing is ever trapped.
"""
import json, os, re, subprocess, sys
from datetime import datetime

COORD = os.environ.get("COORD_SELF") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "coord.zsh")
REPO = os.environ.get("COORD_REPO", os.path.expanduser("~/Developer/recense"))
HOME = os.environ.get("COORD_HOME", os.path.join(REPO, ".handoff/coordinator"))
STATE = os.path.join(HOME, "COORDINATOR.md")
BIG = int(os.environ.get("COORD_BIG", "3000000"))


def coord(*args, env=None):
    e = dict(os.environ, **(env or {}))
    return subprocess.run(["zsh", COORD, *args], capture_output=True, text=True, timeout=8, env=e)


def last_turn(transcript):
    """Entries after the last real user prompt (not a tool result), and that prompt's time."""
    rows = [json.loads(l) for l in open(transcript, encoding="utf-8") if l.strip()]
    start, t0 = 0, None
    for i, r in enumerate(rows):
        if r.get("type") != "user":
            continue
        c = (r.get("message") or {}).get("content")
        if isinstance(c, list) and any(isinstance(x, dict) and x.get("type") == "tool_result" for x in c):
            continue
        start, t0 = i, r.get("timestamp")
    return rows[start:], t0


def decided(rows):
    for r in rows:
        if r.get("type") != "assistant":
            continue
        for x in (r.get("message") or {}).get("content") or []:
            if not isinstance(x, dict) or x.get("type") != "tool_use":
                continue
            name, inp = x.get("name", ""), x.get("input") or {}
            if name == "SendMessage":
                return True
            path = str(inp.get("file_path", "")) + " " + str(inp.get("command", ""))
            if (".handoff/coordinator/inbox" in path) or re.search(r"\.handoff/[^/ ]+/INBOX\.md", path) \
                    or " post " in path and "coord.zsh" in path:
                return True
    return False


def block(reason):
    print(json.dumps({"decision": "block", "reason": reason}))


def main():
    data = json.load(sys.stdin)
    if data.get("stop_hook_active"):
        return
    sid = data.get("session_id", "")
    try:
        coord("doctor", "--fix")
    except Exception:
        pass
    holder = coord("who", "--id").stdout.strip()
    if sid and holder and sid == holder:
        tr = data.get("transcript_path", "")
        if tr and os.path.exists(tr):
            rows, t0 = last_turn(tr)
            if t0 and decided(rows):
                started = datetime.fromisoformat(t0.replace("Z", "+00:00")).timestamp()
                if not os.path.exists(STATE) or os.path.getmtime(STATE) < started:
                    return block("Coordinator memory: this turn sent or posted a decision, but COORDINATOR.md wasn't updated. "
                                 "Write each decision into its ## 3 now (one line each), then stop.")
        chk = coord("state-check")
        if chk.returncode != 0:
            return block("COORDINATOR.md breaks its caps: " + chk.stdout.strip().replace("\n", " · ") +
                         ". Collapse finished items to one line, move detail to archive/, then stop.")
        if tr and os.path.exists(tr) and os.path.getsize(tr) > BIG:
            mark = os.path.join(HOME, f".retire-asked-{sid[:8]}")
            if not os.path.exists(mark):
                open(mark, "w").close()
                return block(f"Your transcript is over {BIG // 1000000} MB (a fresh coordinator is cheaper). Update ## 3, "
                             f"run `zsh {COORD} retire`, tell the owner in one line, then end.")
    try:
        coord("spawn")
    except Exception:
        pass


try:
    main()
except Exception:
    pass
