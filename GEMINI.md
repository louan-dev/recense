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

## Outputs
- Answer first. No preamble, no restating the question, no closing summary.
- Don't explain code unless asked. Show diffs/changed lines, not whole files.
- Don't re-read files already in context. Read only the line ranges needed.
- Keep command output small (head/tail/grep); never dump full logs.
- Don't add features, abstractions, or refactors beyond what was asked.
- If the request is ambiguous, ask one short question instead of guessing.

## Effort & Session Optimization (Token Savings)
- **Match effort to task complexity (never default to max effort):**
  - **Low effort** (typos, constants, 1–5 line edits, simple lookups, git/config tweaks): zero exploratory reads, zero multi-step planning, edit directly in 1 tool call.
  - **Medium effort** (scoped features, single-file bug fixes, UI tweaks): read only the target function/line range, apply the patch, then run the validation loop below.
  - **High effort** (multi-file architecture, concurrency/timer spikes, complex debugging): brief plan first, verify assumptions, then execute. Drop back to low/medium immediately for follow-up cleanup.
- **Task done = save, then clear:** when a task finishes (or I switch to an unrelated one), update the
  tracker and HANDOFF.md, package the handoff zip into `~/.claude/context/<project>/handoff/` (when resuming,
  look there first), then end with one line: `[DONE: run /clear — next: <task> at <low|medium|high> effort]`.
  Nothing needed later may live only in the conversation.
- **CLI effort cue:** If the owner's current request is mismatched with high reasoning overhead, prepend a 1-line note (`[TIP: /effort low]` or `[TIP: /effort medium]`) before answering.

# UI changes 
Before reporting any UI change done, screenshot every screen you touched and audit it:
- One control per function, one function per control: no duplicate buttons, no two back buttons, no lookalike icons that do different things.
- Nothing carried over from another platform or an older version (web leftovers in a native app: text links, web scrollbars, page-style headers, reload flashes) unless I asked for it.
- Every action has one visible control (button, menu or voice). Gestures and microinteractions make it faster; they are never the only way.
- Motion confirms an action and respects Reduce Motion; nothing moves for decoration.
If anything fails, fix it and screenshot again. Name the audit in the Checked: line.

# UI changes 
Before reporting any UI change done, screenshot every screen you touched and audit it:
- One control per function, one function per control: no duplicate buttons, no two back buttons, no lookalike icons that do different things.
- Nothing carried over from another platform or an older version (web leftovers in a native app: text links, web scrollbars, page-style headers, reload flashes) unless I asked for it.
- Every action has one visible control (button, menu or voice). Gestures and microinteractions make it faster; they are never the only way.
- Motion confirms an action and respects Reduce Motion; nothing moves for decoration.
If anything fails, fix it and screenshot again. Name the audit in the Checked: line.

# Offline-first gate 
Before proposing a design or writing code, list every outside service it touches (Cloudflare, Workers, R2, Groq, any API, CDN or SDK) and when it is needed.
- Needed at the moment of use: stop. Redesign it to run locally first.
- Needed once for setup (language packs, dictionaries, songs, maps, models): allowed. Store it on the device with its source, size and checksum.
- Needed to reach another person or device (share, sync): allowed only as catch-up that never blocks, with a self-hosted path; any company is optional and has a migration command.
Never make Cloudflare, or any single company, a required piece. Name each outside service in the Checked: line.

# Inventive by default: suspend disbelief
Never answer "impossible" or "can't" and stop. Assume it is possible and find the way:
1. Name the presumption that makes it look impossible (e.g. "the sender must be online").
2. Drop that presumption and say what becomes possible.
3. Look past the common answer: protocols, old or forgotten techniques, other fields, open-source practitioners, how it's done in other countries.
4. Give the nearest version that works now, then the route to the full version.
Possible is the stance, not a claim: label what is proven, assumed or untested, and never say it works without a check.
