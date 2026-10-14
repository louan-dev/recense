# A3-USAGE-TARGET.md · how full iCloud should be · 2026-10-14

Status: PROPOSED (owner asked for a recommendation). Nothing has been deleted or moved.

## Where the 184.6 GB is (icloud.com, 2026-10-13)
| Category | Size | Share |
|---|--:|--:|
| Photos (18,271 photos, 1,282 videos) | 149.6 GB | 81% |
| Messages | 22.6 GB | 12% |
| Documents (iCloud Drive + app folders) | 15.3 GB → about 2.6 GB after Recently Deleted was emptied (audit 2026-10-14; Apple's total has not caught up yet) | 8% → 1% |
| Mail | 3.5 GB | 2% |
| Device backups | 0 KB | – |

## Recommendation
1. **Keep the 200 GB plan.** Photos alone is 150 GB. Holding that in R2 costs about the same per month as the plan ($0.015/GB-month standard, $0.01 infrequent access) and loses iCloud Photos on every device. Dropping to 50 GB would mean taking ~140 GB of photos out of iCloud for a saving of about $2/month. Not worth it.
2. **Target ≤75% used (≤150 GB), alert at 85% (170 GB).** That leaves ≥50 GB free for the things that come and go (Drive files, notes, screenshots, Messages attachments, new photos and videos) and absorbs months of photo growth before the alert. 60% would mean moving ~65 GB of photos for no practical gain.
3. **How to get there (~22 GB more after Apple reflects the emptied trash, ~172 GB → ≤150 GB), in order:**
   - **Messages (22.6 GB), owner on the iPhone:** Settings → General → iPhone Storage → Messages → Review Large Attachments; delete old videos and files you don't need. Optional: Settings → Messages → Keep Messages → 1 Year. If any thread must be kept forever, export first (B4: copy `chat.db` on the Mac, export from the copy).
   - **Photos videos (1,282), only if Messages isn't enough:** archive the largest old videos to R2 (bucket `photo-archive`, rclone `crypt`, about $0.10/month per 10 GB), verify sha256, then the owner deletes them in Photos and empties Recently Deleted. Needs `osxphotos` (not installed; owner approves the install) and batches of ≤5 GB, because the Mac has ~12 GiB free.
4. Leave Mail (3.5 GB) and the Notability legacy iCloud copy (298 MB, superseded by Notability's server since June) alone for now. The legacy copy is the only second copy of those notes until Notability Auto-Backup (A6 WebDAV) exists.

## If approved
- `ledger quota` defaults change to `--target 75 --alert 85` (today: 60/80) and `~/.ledger/quota.json` is refreshed after each owner step.
- Done when `quota --total 200GB` reads `ok` (≤75%).
