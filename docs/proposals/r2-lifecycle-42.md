# Proposal · R2 lifecycle rules for SPEC 42 (temporary downloads) · 2026-10-27 · NOT APPLIED

The owner's baseline (2026-10-27):
- Abort incomplete multipart uploads after **1 day**.
- Auto-expire **only temporary/staging prefixes** (`tmp/`, `.handoff/`) after **1 day**.
- Never auto-expire root media or permanent backups.

Nothing below has been run. Each command changes production Cloudflare config, so the owner runs it or approves it one by one.

## What exists today (read with `wrangler r2 bucket lifecycle list`, 2026-10-27 01:40)
| Bucket | Rule | Prefix | Action |
|---|---|---|---|
| gallery-main | Default Multipart Abort Rule | (all) | abort multipart after 7 d |
| gallery-main | expire-trash | `trash/` | expire after 30 d |
| gallery-public | Default Multipart Abort Rule | (all) | abort multipart after 7 d |
| gallery-public | expire-folders | `folders/` | **expire after 31 d** (all public shared folders, media included) |
| recense-tmp | Default Multipart Abort Rule | (all) | abort multipart after 7 d |
| recense-tmp | expire-tmp | `tmp/` | expire after 3 d, abort multipart after 1 d |
| gallery-tmp | — | — | **bucket does not exist yet** |

Warnings:
- **`recense-tmp` is not temporary despite its name.** It holds the permanent transcripts (`keep/…`). Never add an all-prefix expiry to it.
- **gallery-public `expire-folders` already auto-deletes public folders after 31 days**, media included. If that isn't intended, it breaks "never auto-expire root media". Owner to confirm. I'm proposing no change to it here.

## Proposed

### 1. New bucket `gallery-tmp`: SPEC 42's self-deleting downloads
- **Target bucket:** `gallery-tmp` (dedicated; wrangler.toml binding `TMP`)
- **Prefix:** `tmp/`
- **Expiration:** 1 day
- **Abort multipart:** 1 day

```bash
npx wrangler r2 bucket create gallery-tmp
npx wrangler r2 bucket lifecycle add gallery-tmp tmp-expire-1d tmp/ --expire-days 1 --abort-multipart-days 1
npx wrangler r2 bucket lifecycle list gallery-tmp
```

The same rule as the API body (`PUT /accounts/{account_id}/r2/buckets/gallery-tmp/lifecycle`; note that a PUT **replaces** every rule on the bucket):
```json
{
  "rules": [
    {
      "id": "tmp-expire-1d",
      "enabled": true,
      "conditions": { "prefix": "tmp/" },
      "deleteObjectsTransition": { "condition": { "type": "Age", "maxAge": 86400 } },
      "abortMultipartUploadsTransition": { "condition": { "type": "Age", "maxAge": 86400 } }
    }
  ]
}
```

**Code change this needs:** `gallery/src/tmp.js` today writes keys at the bucket root (`<id>/<name>`), and its header suggests a whole-bucket rule (`lifecycle add gallery-tmp expire-1d --expire-days 1`). To match the owner's prefix-only rule, it must write `tmp/<id>/<name>` (the PUT, the GET lookup and `tmpSweep`'s `list({ prefix: "tmp/" })`), and that header comment must be updated. Another session is building 42 right now (`src/tmp.js`, 01:33). This file is for that builder.

### 2. Abort incomplete multipart uploads after 1 day, on the existing buckets
This only touches uploads that never finished. Finished objects are never affected. The 7-day default rule stays, and the shorter one wins.
```bash
npx wrangler r2 bucket lifecycle add gallery-main   abort-multipart-1d "" --abort-multipart-days 1
npx wrangler r2 bucket lifecycle add gallery-public abort-multipart-1d "" --abort-multipart-days 1
npx wrangler r2 bucket lifecycle add recense-tmp    abort-multipart-1d "" --abort-multipart-days 1
```
Not included: the Arq bucket (`c267690e…-arq`). Arq manages its own uploads and backups, and is a permanent backup.

### 3. Not proposed / left alone
- `.handoff/` exists only locally (`~/Developer/*/.handoff`). No bucket has that prefix, so it needs no rule.
- recense-tmp `tmp/` stays at 3 days. Lowering it to 1 day could delete staging audio for a transcription still queued. Owner can ask for 1 day.
- No rule on `files/`, `keep/`, `art/`, `invites/`, `comments`, or any bucket root.

## Owner checklist
1. Approve 1 (bucket + rule) → the builder moves keys under `tmp/` → run the three commands → `lifecycle list` shows `tmp-expire-1d`.
2. Approve 2 (three commands).
3. Say whether gallery-public `expire-folders` (31 d) is intended.
