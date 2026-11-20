# Recense Treaty: Articles

Done at `~/Developer/recense` on 2026-11-20, adopted by the owner.
Shape follows MPEP Appendix T, "Patent Cooperation Treaty and Regulations Under the PCT".
The parallel is structural. It gives no force by itself.
Force comes from two things only: this file's place in the order of authority (`docs/law/README.md`), and the hooks in `docs/law/instructions.md`.

Companions:
- Rules (loops and procedures): `docs/law/regulations.md`.
- Administrative Instructions (paths, templates, hooks): `docs/law/instructions.md`.
- The map every Article points into: `docs/GENETIC-MAP.md`. The index: `docs/PROVISIONAL-SPEC.md`, Appendix T.

## Table of contents

Introductory Provisions
- Article 1 · Establishment of the Union
- Article 2 · Definitions

Chapter I · Search and Cure
- Article 3 · The Search
- Article 4 · Universal Effect of a Cure
- Article 5 · Unity of Genotype and Reuse
- Article 6 · Local Requirements
- Article 7 · The Locus Declaration

Chapter II · Records
- Article 8 · Zero-Deletion Retrofit
- Article 9 · The Closing Duty

Chapter III · Common Provisions
- Article 10 · Persistent Priorities
- Article 11 · Effort and Elevation
- Article 12 · Ambidextrous Ergonomics
- Article 13 · Siblings

Chapter IV · Administrative Provisions
- Article 14 · Regulations and Administrative Instructions
- Article 15 · Disputes
- Article 16 · Amendment
- Article 17 · Entry into Force

## Preamble

The parties,
Desiring that one cure reach every copy of the fault it cures,
Desiring that what already works be reused before anything new is written,
Desiring that no document that governs the work is lost,
Desiring that every surface serve the owner's eyes, hands and attention alike,
Have concluded the present Treaty.

## Introductory Provisions

### Article 1 · Establishment of the Union

(1) The jurisdictions below constitute a Union for building, searching and curing Recense as one system:
- (i) `strip/` (the Mac);
- (ii) `mobile/` (iPhone and iPad);
- (iii) `shared/`;
- (iv) `library/` (web);
- (v) `editor/`;
- (vi) `sync/`.

(2) The acting entities are Claude, agy (Gemini) and Codex. Each is bound equally.

(3) The siblings `~/Developer/blur` and `~/Developer/auditor` belong to the Union as set out in Article 13.

(4) Order of authority, highest first:
- (i) the owner's words;
- (ii) `~/.claude/CLAUDE.md`;
- (iii) `docs/law/`, in this order: this Treaty, then `regulations.md`, then `instructions.md`, then the other law files;
- (iv) specs;
- (v) design notes;
- (vi) code.

(5) Nothing in this Treaty diminishes a rule of `docs/law/` or of the owner's global file. Where they differ, Article 16 governs.

### Article 2 · Definitions

For this Treaty and its companions:
- (i) "genotype" means logic that must exist once;
- (ii) "phenotype" means glue binding a genotype to one OS or screen;
- (iii) "embodiment" means one feature on one surface;
- (iv) "twin" means a second copy of logic;
- (v) "locus" means one place a twin lives: a file and a line range;
- (vi) "cure" means the change that fixes a bug;
- (vii) "collapse" means moving twins into one shared genotype;
- (viii) "slice" means one commit or one session's work on one task;
- (ix) "the Map" means `docs/GENETIC-MAP.md`;
- (x) "the registry" means `docs/specs/PARITY.md`.

## Chapter I · Search and Cure

### Article 3 · The Search

(1) A bug reported on one surface starts a search before any edit.

(2) The search reads, in this order:
- (i) the Map's cluster for that genotype;
- (ii) the registry block for the feature;
- (iii) `zsh sync/bin/triage-merge.zsh sweep <feature>`.

(3) The search names every locus. A genotype missing from the Map is added to it in the same slice.

### Article 4 · Universal Effect of a Cure

(1) A cure has effect at every locus of its genotype, as a filing under the PCT has effect in each designated State (PCT Article 11(3)).

(2) Where a twin builds today, the cure is made in the same commit.
- (i) A check that cannot run today leaves the embodiment `[ ]` in `embodiments:` and adds a `device:` line.
- (ii) The `Checked:` line names the device as unverified.

(3) Where a twin cannot be built today, it is left untouched. The reachable surfaces ship. The gap goes to the registry's Gaps column and to one triage entry (`T-####`).

(4) Twins in one language collapse into `shared/` instead of being patched twice. Twins across languages stay and gain a vector or fixture test.

(5) Fixing one surface and leaving the same fault, buildable, on another is a breach of this Article.

### Article 5 · Unity of Genotype and Reuse

(1) The existing codebase is the primary source. An agent transforms, recycles, renovates or retrofits what exists before writing new code (cf. PCT Rule 13, unity of invention).

(2) New code is allowed only where the agent shows a net gain:
- (i) fewer loci, or fewer lines, or one fewer rule to keep in step;
- (ii) the existing code that was considered, named with its path.

(3) Every new variable, token or helper goes to its canonical locus in the Map, section 5.

### Article 6 · Local Requirements

(1) No surface may require a form different from or additional to the shared form (cf. PCT Article 27(1)).

(2) `strip/`, `mobile/` and `library/src/` hold glue only.

### Article 7 · The Locus Declaration

(1) Before any file is modified, the agent prints:
- (i) `Genotype / Bug DNA:` the pattern or symbol;
- (ii) `All Matching Loci:` the paths and line ranges, across Mac, iPhone, iPad and web;
- (iii) `Action:` "Patch all loci together" or "Collapse into canonical shared locus".

(2) Where the search finds one locus, one line suffices: `Genotype: unique · Loci: <path:lines> · Action: patch`.

(3) The marker that proves the declaration is set out in `docs/law/instructions.md`.

## Chapter II · Records

### Article 8 · Zero-Deletion Retrofit

(1) Governing documents are retrofitted and harmonised. They are never deleted: `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `PROGRESS.md`, skills, worktree plans, specs, and this Treaty.

(2) A retrofit adds. A duplicate is annotated and pointed at its source.

(3) Proof: `git diff --numstat` over each retrofitted tracked file shows 0 in the deletions column.

(4) Scratch is not a governing document and goes to the Trash as the owner's housekeeping rule says.

### Article 9 · The Closing Duty

(1) At the end of each task or session the agent prints a closing block, at most 15 short lines:
- (i) scope touched, in relation to the codebase now;
- (ii) bugs found, loose ends, unresolved items, completed items;
- (iii) next steps, each with its exact command;
- (iv) the plan file path, if any;
- (v) signature: agent id, account slot (acct-1 to acct-4), date, and the Provisional Spec's date.

(2) A moat or opportunity is credited sparingly and only where it has merit.
- (i) It cites proof: a path or a measured result.
- (ii) A validated strong contender is tracked and cited again in later sessions.
- (iii) A theme without proof is not written.

(3) The account's email appears only in the terminal. It is never written to a tracked file.

## Chapter III · Common Provisions

### Article 10 · Persistent Priorities

(1) Every rule, audit and test loop serves these five areas:
- (i) syllable-synced audio precision;
- (ii) code-switching transcription and multilingual support (en, fr, vi, and non-Latin prosody);
- (iii) 1:1 Notability parity with Draftpad on Mac, iPhone and iPad;
- (iv) transcription storage: `keep/<contentKey>/` bundles and offline durability;
- (v) codebase reuse and 1:1 cross-device parity.

(2) The numeric limits for (i) are those in `docs/specs/FEAT-04-exact-time-sync.md` and `docs/specs/FEAT-20-prosody-on-ios.md`. They are cited, not copied, so there is one source.

(3) These areas filter rules and audits. They do not reorder the work queue, which stays in the wish order of `docs/law/order.md`.

### Article 11 · Effort and Elevation

(1) Effort follows the task:
- (i) `medium`: planning and coordination;
- (ii) `high`: rule drafting, retrofits, bounded fixes, and planning that reads real files;
- (iii) `xhigh`: the deep audit, twin collapse across platforms, acoustic and sync edge cases.

(2) The owner's lower tier, `low`, for typos and one-line edits, is kept.

(3) Gated words, used only where the weight is earned:
- (i) `ultrathink`: deeper reasoning for one turn;
- (ii) `ultracode`: opts a task into a multi-agent workflow; costly;
- (iii) `ultrareview`: a cloud multi-agent review the owner starts; billed; an agent never starts it;
- (iv) "make it better and magical" and "microinteractions": owner phrases that raise polish effort on high-impact work. Enforced by this Article alone, not by the tool.

(4) An agent does not raise its own effort for routine work.

### Article 12 · Ambidextrous Ergonomics

(1) No function depends on which hand, thumb, finger or side of the screen performs it (`docs/law/interaction.md:28`).

(2) A control placed at one edge has a mirror or a movable twin, or is reachable from the other edge.

(3) Layout uses logical properties: start and end, not left and right (`docs/law/interaction.md:30`). Physical left and right are for hardware facts only, such as a camera or a Pencil tip.

(4) The Pencil and the finger work the same in either hand. Palm rejection never assumes a writing hand.

(5) On iPhone, every primary action is reachable by either thumb without a second hand, and never by a gesture alone (`docs/law/interaction.md:31`).

(6) Touch, Pencil, trackpad, keyboard and voice reach the same actions on Mac, iPhone and iPad.

(7) A handedness preference may later bias placement. It never gates a function, and the default stays neutral.

(8) Each change to a screen is audited once with the layout mirrored: every action is still reachable.

### Article 13 · Siblings

(1) `~/Developer/blur` and `~/Developer/auditor` are siblings. Their lineage is traced in the Map, section 2. Where the owner has named a lineage that no file shows, the Map says "owner-stated".

(2) While a sibling has no version control, an agent does not edit it. It leaves a twin notice and a proposed patch.

(3) A cure for a genotype shared with a sibling is proposed to the sibling in the same slice.

## Chapter IV · Administrative Provisions

### Article 14 · Regulations and Administrative Instructions

(1) The Rules (loops, protocols, delegation) are in `docs/law/regulations.md`. Consensus of the agents on that code may amend them.

(2) The Administrative Instructions (paths, templates, hooks, commands) are in `docs/law/instructions.md`. Any agent may correct a path that has moved.

(3) Neither may contradict this Treaty.

### Article 15 · Disputes

(1) Code decisions are made by consensus of the agents on that code, with evidence marked proven, assumed or untested.

(2) A tie, or 20 minutes of silence: the holder of the coordinator lease decides (`zsh sync/bin/coord.zsh who`). If there is no live holder, the rules of `.handoff/coordinator/COORDINATOR.md`, section 2, apply and one line is logged in its section 3.

(3) The owner decides vision, concepts and redesigns, and every item on that file's "Ask the owner" list.

### Article 16 · Amendment

(1) Only the owner amends this Treaty.

(2) Each amendment is a dated line in the list below.

### Article 17 · Entry into Force

This Treaty enters into force when the owner's approval of the plan that created it is recorded and the branch carrying it is merged.

## Amendments
- 2026-11-20 · created on the owner's approval of the plan "PCT-Model Constitution, Genetic Map and Provisional Spec" (revision 2b). Article 12 added at the owner's request.
- Open: the sync limits in Article 10(2). The owner's paste named 25 ms lock and 50 ms stress; the specs say 30 ms target and 40 ms blocks (commit `8f9b3dd`). Until the owner says which, the specs are the source.
