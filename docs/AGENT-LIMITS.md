# Agent limits, with proof

What Claude, agy (Gemini through Antigravity) and Codex have each done in this codebase, and where they stopped.
Measured 2026-11-19 and 2026-11-20 from git, logs and the lane files. Owner's rule: no number without a source, no ceiling without a test.

Labels: **proven** (counted from a source named beside it), **inferred** (follows from proven facts), **untested** (no measurement; a canary is named).
Several sources are git-ignored lane files (`.handoff/`) or per-user logs. They are named in plain text so a reader on this Mac can open them.

## 1 · agy (Gemini through Antigravity)

Setup, **proven**:
- Model: "Gemini 4 Argon (High)" in `~/.gemini/antigravity-cli/settings.json`.
- Global rules: `~/.gemini/config/GEMINI.md` (65 lines). Repo rules: `GEMINI.md` (git-ignored, so absent from every worktree).
- A lane receives work only through its `INBOX.md`. It cannot receive `SendMessage`.

Output, **inferred** (authorship from lane names and "(agy)" merge subjects; the author name flips from the owner to `louan-dev` on 2026-11-14, so git cannot separate agents):
- 26 commits in 5 merges: M1 to M5 (5 commits, 11-06), E1 (7), A1 (1), E2 (4), strip A2 to C2 (9, 11-17).
- 63 file changes, +51,332 and −912 lines. The two largest merges include the generated `editor/dist/editor.html`.
- Lanes: `.handoff/LANES.md` lines 11, 12, 27, 29 and 30.
- Uncommitted agy work had to be rescued by the coordinator: commits `5f708c9` (+65/−1, 4 files), `4265a7c`, and `b2f864e` (+61/−1, `editor/src/pagemode.js`).

Strengths, **proven**:
- Watching long recordings. `gallery-media` lane: 25 of 25 recordings watched, including 2.15 GB (23:22) and 985 MB (22:05) captures that the plan had said to skip. 25 evidence files (799 lines), label counts 418 seen, 50 heard, 65 guessed. Evidence 018 transcribes English and French lyrics with timestamps.
- Producing editor code at volume (the 26 commits above).

Failures, **proven**:
- Quota: exhausted on 2026-11-08 05:35 (reset in 135 h 42 min) and 2026-11-11 14:57 (54 h 20 min). Logs: `~/.gemini/antigravity/log/cli-20261108_035414.log`, `cli-20261111_145731.log`. Only that log folder was searched; the 161 older log folders were not.
- Resumes: `agent-resume` resumed gemini 135 times (131 on `strip/HANDOFF.md`, 11-08 to 11-17) and logged 119 LIMITED on that lane (`~/Library/Logs/agent-resume.log`).
- Classification: all 25 triage entries it filed (T-0150 to T-0174, `docs/specs/triage.md`, local) came back with Area "Other".
- Wrong place: its worktree had been cleaned up, so it wrote into the main checkout (`.handoff/gallery-media/INBOX.md` line 65).
- `agy-watch` lane: 0 commits.
- Time resolution: canary 2 says it cannot resolve below 1-second buckets, about ±0.3 to 0.5 s (`.handoff/agy-watch/evidence/001-canary2.md` line 1). The current limit is 30 ms (`docs/specs/FEAT-04-exact-time-sync.md`). **That is more than 10 times coarser.**
- Canary 1 (a 12 s clip): the sealed answer key is not in the repo, so pass or fail is **untested**.

Conclusion, **inferred**: agy may watch, label and cross-check. It may not own timing.

Untested, with the canary to run:
- Context ceiling and tool ceiling. No log measures either. Canary: give one lane a task whose input grows by 25% per run until it truncates; record the size.
- Rate-limit history in the older install: `grep -rhiE 'RESOURCE_EXHAUSTED|quota' ~/.gemini/antigravity-cli/log | head`.

## 2 · Codex (OpenAI)

**Proven: no evidence that Codex has acted on this codebase.**
- `git log --all -i --grep=codex`, `git branch -a | grep -i codex`, and a repo-wide search for "codex" found nothing relevant.
- `~/.codex` was last written 2026-10-09. It holds 2 session files (2026-10-08) with working folders `~/Developer/sill` and `~/Developer`. Of 4,286 log rows, 0 mention "recense".
- `which codex` finds no binary. `~/.codex/config.toml` pins `model_reasoning_effort = "xhigh"`.
- Mentions are only `AGENTS.md` and wish T-0057, "Cross-agent rules for Gemini and Codex" (`docs/specs/triage.md`, 2026-11-14).

Result: **0 tasks, 0 commits, 0 measurements.** Any ceiling is **untested**.
Canary before it earns scope: a read-only review of one seeded-bug diff (a known twin drift from `docs/GENETIC-MAP.md`, C1). Pass means it names both loci.

## 3 · Claude

**Proven:**
- 1,000 commits across all refs; 353 on first-parent `main`; 114 merges; 67 distinct `work/*` branches merged. First commit 2026-10-10.
- Co-author trailers appear on 266 commits (Opus 5.5: 247; Sonnet 4.6: 8; Sonnet 5: 6; Opus 5: 5). They stop after 2026-11-16, so these are lower bounds.
- Busiest days (all refs): 2026-11-18 with 165 commits, 2026-11-16 with 133.
- Usage limits, from `~/Library/Logs/agent-resume.log` (3,237 lines): 556 resumes in all (421 claude, 135 gemini). LIMITED lines per day: 11-10: 32; 11-11: 22; 11-12: 21; 11-13: 14; 11-14: 21; 11-15: 54; 11-16: 87; 11-17: 32; 11-18: 4; 11-19: 0. 21 "GAVE UP" lines.
- Four Pro accounts (`cswap`). Weekly usage is per account and changes daily; this file does not record it.

Limits, **inferred**:
- A session hits a usage ceiling several times a day at the busiest rate. The loop must therefore keep `## Resume here` current (global rule).
- Builds are bound by disk and by one build lock (`.handoff/build.lock`), not by Claude.

Untested: per-model commit share after 2026-11-16 (no trailers). Command: `grep -l 'commit' ~/.claude/projects/*/*.jsonl`.

## 4 · Delegation Guideline by effort level

One rule first: **a task goes to the agent whose measured strength it needs, and its proof comes back in the same form for every agent.**

### Medium (planning, coordination, bookkeeping)
- Owner of the task: Claude.
- Reviewer: the coordinator lease holder, or a second Claude session that did not author it.
- Proof returned: the lane file updated (`## Resume here`), plan posted to the inbox, tracker row set.
- agy: not used. Codex: not used.

### High (rule drafting, retrofits, bounded fixes, reads of real files)
- Owner: Claude for Swift, architecture, rules and the harness.
- agy may take: a bounded editor (`editor/src/`) task with a written done-check. Its work is rescued by commit, never left uncommitted.
- Reviewer: not the author. Docs-only diffs: the coordinator. Code: a panel judge (`coord.zsh assign <branch>`).
- Proof returned: Checks from `.claude/CLAUDE.md`, a deletions-column of 0 for retrofits, citations that resolve.
- Codex: read-only review on probation (section 2).

### Xhigh (deep audit, twin collapse across platforms, acoustic and sync edge cases)
- Owner: Claude for the audit, the collapse and the proof harness. In this audit Claude read the clusters end to end and cited them; no other agent has been tried on that work.
- agy pairs when the task needs ears or eyes: a recording to watch, a second language, a video ground truth. It labels `seen`, `heard` or `guessed`. It does not time.
- Timing is owned by deterministic on-device code (`shared/speechcore.swift`, Cadence, `reviews/align-probe`), not by any agent.
- Reviewer: two judges for data-loss, sync, offline or concurrency diffs, one of them fresh.
- Proof returned: the measured number against the limit in the spec, on the real device where one is reachable.
- Codex: none until its canary passes.

## 5 · Gaps in this file
- No per-task cost (tokens or time) is recorded for any agent. Source needed: the agents' own session logs.
- agy authorship is inferred, not recorded. A lane that writes `Agent:` in every commit message would fix this.
