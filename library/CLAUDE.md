# CLAUDE.md · Gallery (Cloudflare Worker + R2) · repo root `~/Developer/gallery`

Shared plan: `../sync/PROGRESS.md` (read §2 Rules every session, plus §6 for Track C) and `../sync/BACKLOG.md` (open only the §G section you are on). Before touching the viewer or comments read `gallery/src/page/ui/README.md` §1.1, §3, §4.4, §7. Don't re-read unchanged files or re-plan. Nothing has run on the owner's Mac unless §7 says so.

## Where things are
- Worker: `gallery/src/worker.js`, `public.js`, `main.js`, `access.js`, `common.js`; client in `gallery/src/client/`; UI contract and screenshots in `gallery/src/page/ui/` (`common/`, `main/`; `public/` is empty).
- Buckets: `gallery-public` (public) and `gallery-main` (main). Cron 03:00. Comments, captions and folder order are JSON objects in R2. No D1, KV or Durable Objects yet.
- `/main` is owner-only via Cloudflare Access; everyone else gets an indistinguishable 404 by design (`access.js`, `isOwner()`).
- Tests: `npm test` (miniflare + playwright; `node_modules` was not shipped, run `npm install` once). Scripts: `gallery/chau/setup.sh`, `copy-share-link.sh` (README says `mac/` and `copy-public-link.sh`: reconcile).
- Missing from the uploads: `playerv12` (player reference). Ask the owner, else use the current player in `src/client/gallery.js`.
- Git exists here. Keep out of git and out of anything shared: `.wrangler/`, `old-versions.zip` (contains account metadata), `node_modules/`, `.test-build/`, `*.bak`, `src/page/ui.zip`, `.env`. Remove clutter only with the owner's confirmation. No push or deploy without explicit confirmation. Never print or commit wrangler secrets.

## Your items (BACKLOG §G, PROGRESS §6 Track C)
Security before cosmetics: **C0 server-side authz, then C1 D1 data**, before UI polish.
- **C0/G1** participant surface outside Access (for example `/m/<token>`): per-person invite tokens (≥128-bit, store the hash), scoped to one folder; permissions view, download, upload, comment, react, annotate; expiry or none; revoke; per-media overrides; document-level view-only lock; participants cannot delete owner content. Tests: unauthenticated, expired, revoked, direct URL, cross-folder, public/main separation. A hidden control is not access control. Today the invite flow yields no usable link (`linkApi`, `public.js:75`).
- **C1** add D1 (shares, members, comments, reactions, annotations); blobs stay in R2; migrate JSON comment maps lazily. Durable Objects only for presence and co-editing; no polling.
- **G2** upload availability, **G3** viewer and R2 panel (click means view or play, never auto-download; explicit Go to File), **G4** layout, topic grouping, hide item count at root, **G5** panel, comments, gestures, **G6** Rooms and annotations, **G7** two-way R2 editing (versioned save-back first, conditional put on ETag), **G8** audio correctness and EQ, **G9** bugs: `/main` 404 in Chrome (check Access coverage, cookie, `/main` vs `/main/`; give the owner a real sign-in path), repair `chau/` scripts.
- **A7** read-only `/main/ledger/` browsing `views/tree.json`, after Sync's A5.
- Public side stays one-way (owner comments only); main is two-way with participant uploads. Enforce in the backend, state it in the UI.

## UI rules from the owner (apply with the README)
- Liquid-glass badges only on the 3 media-player playback controls (rewind, pause, forward). Everywhere else, buttons and toggles use the same font and blue as "Select All" / "Deselect All", including "Add a comment...".
- Destructive menu rows are blue, no red. Expanded comment field has three blue options: Post, Delete (removes a comment they posted), Cancel (removes the draft); both return to collapsed view. The comment field sits directly under the latest comment. On public view the owner can post consecutive comments.
- Time bar and audio bar must realign with each other in expanded and collapsed views. Test iPad Air 13" M3, MacBook Pro 13" M1, iPhone 12 Pro Max, portrait and landscape, touch and pointer.
- Recense embeds Gallery through `?embed=1` and `views/health.json`: keep that contract, do not merge the projects.

## Output
No routine narration, no whole-file dumps. Report decisions, blockers, validation (run the narrowest test, then regressions), next action. Update `../sync/PROGRESS.md` §7 and stop. Label status DONE (verified) / PARTIAL / BLOCKED / PROPOSED.