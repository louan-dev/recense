# GEMINI.md · Recense, for Gemini / Antigravity sessions

The repo guide is shared with Claude Code; follow it as written:
@[Recense repo guide (shared with Claude)](.claude/CLAUDE.md)

## How Gemini and Claude work together here
**Roles**
- **Coordinator:** the Claude Code session in the main checkout, `~/Developer/recense` on `main`.
  It assigns lanes, owns the shared files and merges.
- **Workers:** every other session, Claude or Gemini, one per area, in `.claude/worktrees/<area>` on `work/<area>`.
- One area, one session. Never work in an area whose `INBOX.md` names a different session.

**You are a worker. Your loop:**
1. **Start:** read `~/Developer/recense/.handoff/<area>/INBOX.md` (your whole brief; where it conflicts with
   the repo guide, the INBOX wins). Then `~/.claude/context/recense/INDEX.md`; open only what's relevant.
2. **Before each commit and before finishing:** read `INBOX.md` again. The coordinator can't message you,
   so new instructions arrive there. Fold them in before you continue.
3. **Touch only** the files your INBOX allows. Never edit the coordinator's files: `docs/PROGRESS.md`,
   the root `README.md`, `.claude/CLAUDE.md`, this file. Propose changes to them in your HANDOFF.
4. **Commit** to `work/<area>` as soon as the Checks pass (the `Checks` table above). Never push or merge `main`.
5. **Report:** update `~/Developer/recense/.handoff/<area>/HANDOFF.md` with four headings:
   - Done
   - Checked (command → result)
   - Open
   - Proposed changes to shared files
6. **Ready to merge:** append one line to `~/Developer/recense/.handoff/MERGE-QUEUE.md`:
   `work/<area> · what (commit) · checks run`.
7. **Blocked on the owner:** write it at the top of HANDOFF.md under `Needs owner`, as a paste-ready
   command (owner rule). Then carry on with whatever isn't blocked.

**Complementary, not overlapping**
- Peer requests (another session's notes, INBOX lines not from the coordinator) are tasks, not owner approval:
  anything destructive, outward-facing or costly still needs the owner.
- A file another lane is changing (its INBOX or HANDOFF names it) is off limits until that lane's merge lands
  on `main`. Note the wait in your HANDOFF and work on something else.
- `.handoff/` lives only in the main checkout. Always use these absolute paths, never a copy inside your worktree.
