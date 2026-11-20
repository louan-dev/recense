# AGENTS.md · rules for every coding agent (Codex, Gemini, Claude, others)

One law for all agents. Read it before planning work in any part of this repo:

- `docs/law/` — what Recense is, its folders, what may need a network, how it behaves,
  and **which wish is granted first** (`docs/law/order.md`).
- `docs/specs/INDEX.md` — specs are law; code is derived from them.

Order of authority: the owner's words > `docs/law/` > specs > design notes > code.

Next task: `cd sync && node src/wishrank.mjs` prints the queue in law order.
Never pick work because it is higher on a page or was written first.

## First instinct (treaty, 2026-11-20)
Read `docs/law/treaty.md` before any edit. Its laws, short:
1. One cure, every twin. A bug fixed on one surface is fixed at every locus of the same genotype, in the same commit, where that twin builds today (Article 4). `docs/GENETIC-MAP.md` lists the loci. `zsh sync/bin/triage-merge.zsh sweep <feature>` finds second copies.
2. Reuse before new. Transform existing code first. New code needs a stated net gain and goes to its canonical locus (Articles 5 and 6).
3. Before editing a file, print `Genotype / Bug DNA:`, `All Matching Loci:`, `Action:` (Article 7; template and helper in `docs/law/instructions.md`).
4. Never delete a governing document. Retrofit it (Article 8).
5. Serve the five standing priorities: syllable-synced audio, code-switching en/fr/vi, Draftpad parity with Notability, `keep/<contentKey>/` storage, reuse with 1:1 parity (Article 10).
6. Effort follows the task: medium, high, xhigh (Article 11). No function depends on which hand is used (Article 12).
Close each task with the block in `docs/law/instructions.md`, section 4.
