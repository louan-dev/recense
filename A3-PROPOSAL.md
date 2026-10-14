# A3-PROPOSAL.md · free the iCloud quota · 2026-10-13

Status: PROPOSED. Nothing has been deleted, evicted or moved. Every row is the owner's call, done by the owner in Apple's own UI. Source: `AUDIT.md` (2026-10-14 01:12 UTC).

## Facts that decide the order
- **Plan size is unconfirmed.** `brctl quota` reports **16.4 GB remaining**. On a 5 GB plan that cannot be true, so either the plan is larger (50 GB would mean ~67% used) or `brctl` measures something else. `node ledger.mjs quota --total <plan>` computes usage once the plan size is known (target ≤60%, alert ≥80%).
- Evicting a local copy ("Remove Download") frees **no** quota. Deleting from iCloud Drive deletes on every device.
- Recently Deleted still counts until it is emptied or ages out (about 30 days).
- Only items with a verified copy (sha256 on the SanDisk via `backup-status` or the ledger) qualify for deletion. Today **none** do: A2's restore drill has not run.

## Candidates (largest first)
| # | Item | Size | Copy verified? | Proposed action (owner) |
|--:|---|--:|---|---|
| 1 | iCloud Drive **Recently Deleted** (`.Trash`, 687 files) | 13.0 GB | No (12.7 GB is cloud-only) | Owner skims it first (Finder → iCloud Drive → Recently Deleted, or iCloud.com → Drive → Recently Deleted). Anything to keep: Recover → materialize to SanDisk via ledger (`ARQ-CHECKLIST.md` §3) → Arq. Then "Delete All". Biggest single lever. |
| 1a | ↳ `20260804 Nicholle - SESSION SUMMARY.wav` | 11.3 GB | No | Decide keep vs drop. Keeping: recover, then copy straight to SanDisk (internal disk has ~12 GiB free, too tight to materialize locally); optionally transcode to FLAC/AAC before re-uploading anywhere. |
| 1b | ↳ `Alison Wood Brooks … .m4b`, `Foundation Workbook Guided .pdf`, `DynamicLakePro.app` | 0.6 GB | No | Likely re-downloadable; owner confirms. |
| 2 | `iCloud~com~apple~clips` (Clips projects) | 1.3 GB | No (fully local, so Arq can cover it) | Add to Arq sources, pass drill, then delete old projects in Clips. |
| 3 | WhatsApp iCloud chat backup (`Media.tar`, `Document.tar`) | 423 MB | No | WhatsApp → Settings → Chats → Chat Backup: exclude videos or turn off; keep a local export if needed. |
| 4 | Obsidian attachments (e.g. 73 MB `ScreenRecording….mov`) | ≤150 MB | No | Move to the A6 overflow lane (R2) with a pointer note once A5/A6 are verified. |
| 5 | Photos, device Backups, Messages, Mail | unknown | — | Need the Apple-side breakdown. If device Backups dominate: encrypted local Finder backup (covered by Arq) → turn off iCloud Backup for that device → delete its old iCloud backup. |

## After the owner acts
Re-run `node ledger.mjs audit --out AUDIT.md` (delta vs baseline is printed) and `node ledger.mjs quota --total <plan> --write`. Done when usage ≤60% (or the `.Trash` row is gone and the breakdown explains the rest).
