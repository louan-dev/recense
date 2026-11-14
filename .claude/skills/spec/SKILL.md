---
name: spec
description: Turn a raw idea, triage entry or app study into a formal spec (FEAT, UI, PUB, INT, ADR) in docs/specs/ and its INDEX row. Use for "/spec", "write a spec", "make this a spec", or before building anything that has no spec yet.
---

# /spec · idea → spec

Law: `.claude/rules/spec-and-index-law.md`. No code in this skill.

## Steps
1. Read `docs/specs/INDEX.md`. If a spec already covers the idea, update it instead.
2. Source:
   - a triage entry `T-####` in `docs/specs/triage.md`, or
   - the owner's words in chat (`owner <date>`), or
   - a study's `NOTES.md` in `docs/specs/ui-teardowns/UI-xx-*/`.
3. Pick the type and next free number:
   - `FEAT` feature · `UI` interface or app study · `PUB` publishing/sharing · `INT` integration · `ADR` decision.
4. Write the file:
   - UI studies: `docs/specs/ui-teardowns/UI-xx-<name>/UI-xx.md`.
   - Others: `docs/specs/<TYPE>-xx-<name>.md`.
5. Header: `From: <T-#### | owner date> · Status: [ ]`.
6. Body, short lines:
   - **Built `[x]`** — what exists, with `file:line`.
   - **Planned `[ ]`** — numbered parts (P1, P2…), each with exact thresholds (ms, pt, px) and equations in LaTeX.
   - Invariants a test can check.
   - Planned code layout and test file names.
   - Done checks, including the real device the owner uses.
   - Assumptions labelled `assumption` or `(from memory — verify)`; facts checked this session labelled `checked`.
7. Clean-room: describe behaviour, timing and math only; never copy another app's code or assets.
8. INDEX: add the row `ID · title · [ ] · From · code pointer`.
9. Triage: under the entry, `- <date> · TRIAGED→spec · <agent> · Spec: <ID>` only if the owner or coordinator triaged it; else leave status alone and just add `Spec: <ID>`.
10. Offline-first gate: list every outside service the spec would touch and when.
