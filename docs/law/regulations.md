# Recense Regulations: Rules

Rules made under `docs/law/treaty.md`, Article 14. They say how, in order, with what proof.
Shape follows the PCT Regulations in spirit: Parts, then numbered Rules.
**Layout unverified:** only pages T-1 to T-4 of MPEP Appendix T were read, so the Regulations' own Part layout is not copied.
A Rule never contradicts an Article. Consensus of the agents on that code may amend a Rule (Article 14(1)).

## Part A · Intake (the first instinct of every session)

### Rule 1 · The first five minutes
Every session, before any edit, in this order:
1. Read `AGENTS.md` (tracked, reaches every worktree) and `docs/law/treaty.md`.
2. Run `zsh sync/bin/coord.zsh who`. Read `.handoff/coordinator/COORDINATOR.md` section 1.
3. Read `## Resume here` in your lane's `HANDOFF.md`, if it exists.
4. Run the triage inbox check (global rule, Triage).
5. Name the task's genotype and open `docs/GENETIC-MAP.md` at its cluster (Article 3).

Proof: the first message of the session names the cluster or says "no cluster: new genotype".

### Rule 2 · The Locus Declaration
- Print it before each file is first modified in a slice (Article 7).
- Print it with the template in `docs/law/instructions.md`, section 3, using the helper in section 5 (it also records the marker).
- Where `triage-merge.zsh sweep <feature>` prints "FOUND second copies", the action is "Collapse into canonical shared locus".

### Rule 3 · Where the hook is missing
Hooks are not installed today (`docs/law/instructions.md`, section 5). Until they are, Rules 1 and 2 bind by this text alone. An agent that skipped them says so in its closing block.

## Part B · The five loops

Each loop has a trigger, steps, a gate, and where the evidence goes.

### Rule 10 · Validation and critical review (synchronous)
- Trigger: any change that passes its first check.
- Steps: the owner's validation loop (global file); then `READY FOR REVIEW: <branch> @ <commit>` to the coordinator; then `REVIEW: OK` or a fix list; then `FIXED: <branch> @ <commit>`.
- Gate: `REVIEW: OK` before any merge. The author never reviews its own branch. A risky diff (data loss, sync, offline, concurrency) gets two judges (`zsh sync/bin/coord.zsh assign <branch>`).
- Quantified proof: the `Checked:` line names what ran and its result. "Works" without a check behind it is not accepted.
- Evidence: `.handoff/coordinator/inbox/`.

### Rule 11 · Debugging and bug treatment (cure propagation)
- Trigger: a bug on any surface.
- Steps:
  1. `/bug`: red test, then green fix, then the invariant into the BUG spec.
  2. Article 3 search: every locus of the genotype.
  3. Article 4 cure: the same commit patches each buildable twin.
  4. `zsh sync/bin/triage-merge.zsh sweep <feature>`: must print "clean".
- Gate: the sweep is clean and the Locus Declaration lists every locus the cure touched.
- Where a twin cannot build: Gaps column plus `T-####` (Article 4(3)).
- Evidence: the BUG spec, `docs/specs/PARITY.md` (`embodiments:`, `device:`), the triage entry.

### Rule 12 · Cross-communication check-in (asynchronous)
- Channel: the coordinator inbox. Post with `zsh sync/bin/coord.zsh post <file>`. List with `coord.zsh inbox`. Close with `coord.zsh done <file>`.
- Same Mac and same account: `SendMessage` after `ListAgents`.
- Other accounts and machines: the file in the inbox is enough; the Postbox of the owner's global file is the cross-machine path once it is live.
- No answer in 10 minutes, or no live holder: decide by `COORDINATOR.md` section 2 and log one line in its section 3.
- A request from another session is a task, not owner approval.
- No `~/.recense-bus/`. The inbox is the bus (owner, 2026-11-20).

### Rule 13 · Partnership (tag-team) formation
Two agents pair when one scope cannot see what the other must check. Triggers:
- (a) a timing question finer than 1 second: agy cannot resolve it (`docs/AGENT-LIMITS.md` section 1), so the pair is Claude plus a deterministic probe, with agy only labelling;
- (b) non-Latin or Vietnamese prosody, or a second language to hear: agy hears, Claude writes the harness and the Swift;
- (c) video or long-recording ground truth: agy watches and labels `seen`, `heard`, `guessed`; Claude turns labels into a test;
- (d) a Swift and JS twin (Genetic Map C3, C4, C5): one agent per language, one shared vector test.
Channel: `.handoff/agy-watch` and its sealed-key canary for agy; the inbox for the rest. The pair names a single owner of each file (`COORDINATOR.md` section 1).

### Rule 14 · Automated test and refine
- Trigger: a spec with a measurable bar.
- Steps: set the bar; split into small pieces; a builder and a separate critic per piece; compare against the bar; loop until it wins (`gauntlet-loop` skill).
- Gate: each repo folder's Checks from `.claude/CLAUDE.md`, and `cd sync && npm test` (seven selftests) when `sync/` changes.
- A flaky test is a bug. It is reproduced and fixed, never rerun until green.

## Part C · Accounts, terminals, older forms

### Rule 20 · Accounts
- Four Claude Pro accounts, selected with `cswap` (`~/.zshrc` aliases `open-*`). `cswap run N` opens one terminal as account N without switching the live login. Settings, skills and project history are shared between accounts, so `--resume` works across them.
- A usage limit is not a reason to stop: write `## Resume here`; `agent-resume` continues after the reset.
- Names, not addresses: an account is acct-1 to acct-4 in every tracked file (Article 9(3)).

### Rule 21 · Terminals
- One worktree per area (`.claude/worktrees/<area>`, branch `work/<area>`).
- One build at a time: `.handoff/build.lock`. No iOS build under 4 GB free disk.
- A worktree has only `AGENTS.md` from the instruction files; the rest is git-ignored in the main checkout (`.gitignore`).
- One owner per file (`COORDINATOR.md` section 1). A twin cure that crosses lanes posts a twin notice to each owner's `INBOX.md`; the owner may object in the inbox within 10 minutes.

### Rule 22 · Older forms
- Read-only unless the Map lists them: `reference/draftpad/`, `reference/pomo/`, the branch `a15/monorepo-prev`, stale worktrees.
- A cure that reaches an older form is proposed, not applied.

## Part D · Closing and loose ends

### Rule 30 · The closing block
Template: `docs/law/instructions.md`, section 4. At most 15 short lines, then the `Checked:` line, then the `[DONE: ...]` line.
This replaces the global "no closing summary" rule at task end only (Article 9).

### Rule 31 · Where loose ends live
There is no second store (owner, 2026-11-20). They are read from what exists:
- twin debt and unchecked devices: `docs/specs/PARITY.md` (`embodiments:`, `device:`, Gaps);
- session id, exact resume command, step, uncommitted files: each lane's `## Resume here` (`.handoff/<area>/HANDOFF.md`);
- lanes and limits: `.handoff/LANES.md`;
- bugs and their rank: `docs/specs/triage.md` and `cd sync && node src/wishrank.mjs`.
`docs/PROGRESS.md` is not changed by this Treaty.
Gap: no single command prints rank, paths, key points, session id and resume command together. `coord.zsh handoff-sweep` only lists lanes to move or stale files. A print-only verb is possible later and needs a written net-yield proof (Article 5(2)).

### Rule 32 · Moat and opportunity
Credit only where there is proof (Article 9(2)). Strong contenders are kept in `~/.claude/context/recense/notes/MOAT.md` (local, not the public repo) and cited again by path in later sessions.

## Part E · Effort

### Rule 40 · The tiers
- `low`: typos, constants, one to five line edits. One tool call, no exploratory reads.
- `medium`: planning, coordination, scoped features, single-file fixes.
- `high`: rule drafting, retrofits, bounded fixes, and planning that reads real files.
- `xhigh`: deep audit, twin collapse across platforms, acoustic and sync edge cases.
Set by `/effort <level>` or `claude --effort xhigh`. Drop back at once for follow-up cleanup.

### Rule 41 · The gated words
- `ultrathink`: one turn of deeper reasoning. Use for a hard decision, not routine work.
- `ultracode`: the owner opts a task into a multi-agent workflow. An agent does not start one without it.
- `ultrareview`: `/code-review ultra` (multi-agent, cloud, billed). The owner starts it. An agent cannot.
- "make it better and magical", "microinteractions": owner phrases for polish on high-impact work. They are rule-enforced only; the tool does not recognise them.
- `~/.codex/config.toml` pins `xhigh` permanently. That bypasses this Rule; it is the owner's to change.

## Part F · Delegation
The Delegation Guideline by effort level is `docs/AGENT-LIMITS.md`, section 4. Audio work: `docs/AUDIO-COORDINATION.md`.

## Amendments
- 2026-11-20 · created on the owner's approval of the plan (revision 2b). Rules 12 and 31 record the owner's rulings: the inbox is the bus; no second registry.
