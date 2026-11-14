# AGENTS.md · rules for every coding agent (Codex, Gemini, Claude, others)

One law for all agents. Read it before planning work in any part of this repo:

- `docs/law/` — what Recense is, its folders, what may need a network, how it behaves,
  and **which wish is granted first** (`docs/law/order.md`).
- `docs/specs/INDEX.md` — specs are law; code is derived from them.

Order of authority: the owner's words > `docs/law/` > specs > design notes > code.

Next task: `cd sync && node src/wishrank.mjs` prints the queue in law order.
Never pick work because it is higher on a page or was written first.
