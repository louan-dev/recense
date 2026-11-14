---
name: derive
description: Build code from an existing spec in docs/specs/, tests first, with zero third-party dependencies, and mark its INDEX row. Use for "/derive <ID>", "build UI-04 P1", "implement the spec".
---

# /derive <ID> · spec → tests → code

Law: `.claude/rules/spec-and-index-law.md`.

## Steps
1. Read `docs/specs/INDEX.md`, then the spec named. Only the parts asked (e.g. `UI-04 P1`).
2. If the spec is unclear or a threshold is missing: stop and fix the spec first (or ask one question).
3. Confirm every API the spec names exists (SDK header, `--help`, source) before using it.
4. INDEX row → `[~]`. Triage entry, if any → `- <date> · FIXING · <agent> · Spec: <ID>`.
5. Tests first, from the spec's invariants and thresholds:
   - boundaries on both sides (e.g. 249 ms and 250 ms).
   - each test file starts with `// Derived from Spec: <ID>`.
6. Run them: they must fail (red) for the right reason.
7. Code:
   - header `// Derived from Spec: <ID> <part>`.
   - native Apple frameworks, Web APIs, Python, our Worker only. No SaaS SDKs, UI kits or outside databases.
   - logic in one shared place (e.g. `editor/src/` for Draftpad), native layers thin.
8. Run the touched folder's Checks (`.claude/CLAUDE.md`) until green.
9. Real path: the device or page the owner uses; if you can't reach it, write the exact steps for them.
10. Spec: move the part from Planned `[ ]` to Built `[x]` with `file:line`.
11. INDEX row → `[x]` when every part asked is built and checked. Triage → `FIXED · <commit>`.
12. Commit tests, code, spec and INDEX together.
