# R2 lifecycle rules

Set in the dashboard (R2 > bucket > Settings > Object lifecycle rules). Recorded here so they live with the code.

| Bucket | Rule | Prefix | Action |
|---|---|---|---|
| `gallery-public` | expire-folders | `folders/` | Delete objects 31 days after upload |
| `gallery-main` | expire-trash | `trash/` | Delete objects 30 days after upload |

Both buckets also have Cloudflare's default rule that aborts unfinished multipart uploads after 7 days.

No rule may have an empty prefix: `gallery-main/files/` must never expire.
