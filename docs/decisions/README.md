# decisions/

Your decisions. Each file here is a copy of an output Claude generated (a proposal, checklist, report) with your input added.

## How it works

1. Claude writes an output in its usual place, for example `docs/proposals/A3-PROPOSAL.md`.
2. You copy it here and record a decision on every row.
3. The original stays untouched. This folder holds the decided copy only.

## Copy naming

`YYYYMMDD <ID> <name>.md`: the date the decision was made, the item ID, then the original name in lowercase words with spaces instead of hyphens.

Example: `docs/proposals/A3-PROPOSAL.md` is saved as `20261012 A3 proposal.md`.

## Copy format

The copy is identical to the original except for one change: a **Decision** column is added directly after **Proposed action**. Nothing else is edited, reordered or removed.

| # | Item | Size | Copy verified? | Proposed action | Decision |
|--:|---|--:|---|---|---|
| 1 | example row | 1 GB | No | Review, then delete | e.g. keep / delete / later, plus a note |

## Rules for Claude

- Read the newest file for an item before acting on it. A filled Decision cell is your final call and overrides the proposed action.
- Never edit, move, rename or delete files here. Never fill in a Decision cell.
- If a Decision cell is empty, the row is still undecided. Do not act on it.
- Never infer a decision from the Proposed action column.