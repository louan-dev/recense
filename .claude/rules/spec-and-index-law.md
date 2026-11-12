# Spec and index law

**Specs are law; code is their derived artifact.**

## Before planning or coding
- Read `docs/specs/INDEX.md`, then only the specs the task names.
- Run the triage inbox check (`~/.claude/CLAUDE.md`, Triage) on `docs/specs/triage.md`.
- Never read `docs/specs/**/_raw/**` or `docs/specs/**/_traces/**` (blocked in settings).
- Open a screenshot only when a note cites it, e.g. `(01)` → `01-*.png` in that folder.

## Binding specs
- `FEAT-*`, `UI-*`, `PUB-*`, `INT-*`, `ADR-*`, `BUG-*` are engineering specs, not suggestions.
- Use their millisecond, point and pixel thresholds exactly. Equations exactly.
- A spec that is wrong or unclear: change the spec first, say why, then the code.

## Code headers
- Each file or function derived from a spec starts with `// Derived from Spec: <ID>` (`#` in Python/shell).
- Each test that guards a bug starts with `// Regression guard: <BUG-ID>`.

## Red-Green-Spec (every bug)
1. Red: a test that fails for the reason in the bug.
2. Green: the smallest fix that makes it pass.
3. Spec: the invariant the test proves goes into the BUG file and the spec it guards.
4. Index: the BUG row's status in `INDEX.md`.

## Live index
- Status: `[ ]` written · `[~]` building · `[x]` built and checked.
- Update the row in the same commit as the change.
- Each row names where it came from: `T-####` or `owner <date>`.

## Triage link
- Bug → `/bug` makes `BUG-xx`; feature → `/spec` makes `FEAT-xx` / `UI-xx`.
- The spec header says `From: T-####`.
- The triage entry gets `- <date> · FIXING · <agent> · Spec: <ID>`; on ship, `FIXED · <commit>`.

## Clean-room
- Other apps are studied for state machines, timing, math and ergonomics only.
- No third-party SaaS SDKs, UI kits or external databases. Native Apple frameworks, Web APIs, Python, our Worker.
