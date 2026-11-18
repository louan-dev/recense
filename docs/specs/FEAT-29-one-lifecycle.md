# FEAT-29 · One lifecycle per item

From: owner 2026-11-18 (PLAN-1118 §5h: "all app uploads and Cloudflare locations have an offline destination; expiry matched") · Status: `[~]` P0 built (Gallery share links); P1+ written in the plan, not yet specced in full

## Rule (the plan, §5h)
- An item's expiry is one absolute date, stamped once, carried with the item; every copy obeys that date.
- Expiry moves to Trash, never deletes at once (P1+).
- **Keep** clears the expiry for evidence, legal and Matters material, and pinned items. One visible control per item.

## P0 · Keep on a share link (built 2026-11-18)
- `POST /main/api/link?action=keep&id=<id>` (owner only, through `/main` Access) sets `manifest.keep = true` and
  `manifest.exp = max(exp, now + 365 days)` (365 days is the link maximum).
- While `keep` is set and `exp` is in the future, the nightly cleanup never deletes the link's objects, and `/f/<id>/<n>`
  and its cover art never answer "Link expired", even when an item's own `expires` stamp has passed.
- Invariant (test `FEAT-29 Keep`, `library/test/routes.test.mjs`): a kept link's expired-stamped item survives cleanup
  and still serves; an unkept expired item still goes; non-owners get no Keep.
- First use: the bug intake link (PLAN-1118 §0), which would otherwise expire 2026-12-16.
- Not yet: a Keep button in the Gallery UI (P1); un-keep; the Trash step; Mac and phone copies obeying the same date.
