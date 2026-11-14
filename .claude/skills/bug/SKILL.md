---
name: bug
description: Fix a bug test-first (Red-Green-Spec) and write its guard invariant back into a BUG spec and the spec it guards. Use for "/bug", a triage entry marked as a bug, or any defect found while working.
---

# /bug · red → green → guard

Law: `.claude/rules/spec-and-index-law.md`.

## Steps
1. Find or file it:
   - from triage: the `T-####` entry in `docs/specs/triage.md`.
   - found outside your task: file it in triage as the global rule says, then stop (add, don't fix).
2. Write `docs/specs/bugs/BUG-xx-<name>.md`:
   - `From: T-#### · Status: [~] · Spec: <guarded spec ID>`.
   - Repro: exact steps, device, what happens, what should happen.
   - Observed or anticipated, said plainly.
3. INDEX row `BUG-xx · … · [~]`. Triage line `- <date> · FIXING · <agent> · Spec: BUG-xx`.
4. **Red:** a test that fails for this bug's reason. Header `// Regression guard: BUG-xx`. Run it; show it fails.
5. Root cause before patching. Same failure twice → find the cause; three failed fixes → stop and show evidence.
6. **Green:** the smallest fix. Run the test, then the touched folder's full Checks.
7. **Guard back-propagation:**
   - the invariant the test proves → `## Invariants` in the BUG file.
   - the same invariant, one line → the guarded spec (e.g. UI-04 P1), citing `BUG-xx`.
8. Real path: the device or page where the bug appeared; else exact steps for the owner.
9. INDEX → `[x]`; triage → `FIXED · <commit>` (agents may set FIXED only).
10. Commit test, fix, BUG file, spec and INDEX together.
