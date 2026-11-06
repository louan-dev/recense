# Unified offline-first system + redesign: Sync · Gallery · Recense

> **Context:** the Cloudflare account hit Error 1027 on 2026-11-03, and the owner wants Sync, Gallery and Recense to become one offline-first system: a law-practice file and study tool, an independent cloud, and a cheap audiovisual engine. Revised 2026-11-04 for the brain dump's new lines (17, 36–90): Obsidian everywhere (A11); the cloudless layer, failure modes and spend (A12); and, from the owner's 11-04 follow-ups, media replays and loops at zero Worker requests (A13) and ad hoc networks for share links and the offline layer (A14). Revised again on 2026-11-05 for the new note and the ⌘ recording:
> - one repo with Recense as the parent (A15);
> - the ask engine, the models and DEVONthink (A16);
> - seeding, offline-first links and one page across apps (A17);
> - two Recense bugs (R16, and R15 again);
> - gestures, haptics, languages and reading (B9–B11).
>
> This is a plan only; on approval it is saved verbatim to `~/Developer/sync/docs/specs/unified-offline-first-and-redesign.md`.
> Inputs: the brain dump (`…conflict1×8.conflict2.md`, 61,800 B, saved 11-04 01:59 and copied to `~/.gallery/tmp/`; docs-sync split it again at 10:40 and 10:45 PST, and the newer copy, `…conflict2.conflict1.md` at 62,114 B, adds the A13 request as line 10). On 11-05 the owner added a new note, `~/Developer/the 3-layer sync unification project is multimodal by nature, not…/….md` (64,772 B, an Apple Notes export of the brain dump with new lines 1–152), and the screen recording `~/Recordings/Bug holding cmd 2026-11-05 12.06.39 screen.mov`, READMEs/PROGRESS/BACKLOG/notes of sync, gallery and recense, sandisk-rescue notes, memory, six read-only audits (three on 11-05: the code, the repos, the vendor facts), live logs and launchd state (11-04 and 11-05), current Cloudflare, Apple and DEVONthink docs (links in A2 and A16).
> Paths are relative to `~/Developer`. Gallery Worker files (`main.js`, `dav.js`, `client/…`) live in `gallery/gallery/src/`; `apple/…` = `gallery/gallery/apple/…`.

## Executive summary
1. **Your files were never at risk on 11-03.** Error 1027 shuts only the Worker, the front door. R2 kept every object and the S3 door stayed open: the disk mounts that use it logged no quota errors while the WebDAV mount through the Worker logged 96 × 1027. It reopened by itself at 12:13 PST (the daily counter resets at 4 PM PST). No payment was needed.
2. **The bleed is one job.** `com.chauphan.docs-sync` runs rclone bisync over the Worker's WebDAV about 230 times a day at 400–550 requests each: ≈ 90k–126k of the account's ≈ 95k–145k requests/day. The same job nests the `.conflict1` suffixes (T1).
3. **Do today (A10):** five reversible config changes (four on the Mac, one cron line) cut the account to ≈ 2k–4k/day (≈ 5k–8k while the two Gallery Mac apps are open) with no app code change. They also end ≈ 115k R2 list operations a day (≈ $11/month).
4. **Your top item, Obsidian everywhere (A11):** one sync engine per folder. iCloud carries the vault once it has room, docs-sync stops writing into the vault, and a Mac-only job brings every markdown file from `~/Developer`, Desktop and Documents into the vault. The existing canary then proves Mac → iPhone → iPad. Free; 0 Worker requests.
5. **Tests:** today S1, S2, S3, S4, S6 and S8 fail; S5 and S7 are partial. The two added on 11-04 also fail: S9 (unlimited loops) and S10 (no router). The design passes all ten at ≈ 720 requests on a normal day and ≈ 1,020 on the worst, under 10k/40k with a 10× margin.
6. **Local-first, with Cloudflare as the safety net (A4, A12–A14, A17):**
   - Links can be made with no connection, and they open once the file reaches R2. Any device that holds a file can serve it. Seeding "through someone else's connection" works only through your own devices, or a person running Recense (A17).
   - Every device keeps its own copy and reaches R2 directly over the S3 API with its own key, as Recense already does.
   - Media plays and loops from that copy, so replays are unlimited at 0 requests, even offline. Today one Safari path costs ≈ 3,400 requests per hour of looping (A13).
   - Nearby devices talk directly over peer-to-peer Wi-Fi when there is no router. Share links still need the internet, with AirDrop as their offline twin (A14).
   - The Worker keeps share links, the web app, CalDAV, manifests and commits, so a Worker outage costs only those. No new server, no payment.
7. **One repo, one protocol:**
   - **One repo:** Recense becomes the parent folder and the one GitHub repo, with one-word feature folders (`strip`, `library`, `player`, `sync`, `calendar`, `docs`), three CLIs in their own worktrees, and a `/recense <part>` command. Each app still builds and deploys on its own. Unused files are deleted only on your yes, path by path (A15).
   - **One protocol:** root manifest (304 when unchanged), changes feed, ordered idempotent commits, presigning for the web. It extends the `fp.js` catalog log and the `event-log.md` hash chain. R2 only: no D1, no Durable Objects. A durable outbox and a breaker (soft 15k, hard 30k per device) pause calmly until the daily reset.
8. **Law and the ask engine:**
   - **Public law** (MPEP, USC, CFR) goes in Study.
   - **Client matters** go in DEVONthink on your FileVault-encrypted Mac. Matters syncs to iPhone and iPad at home; Sealed (encrypted) never leaves the Mac; Arq keeps an encrypted off-site copy. No custom vault to build (A6).
   - **Raven** (30 GiB in Main, indexed by Workers AI): stop indexing it now, and move it after the A6 checks.
   - **The ask engine** moves onto the device: Apple's model, offline, free and private, with a local index. DEVONthink becomes the Mac's local index, not the global one (A16).
9. **Urgent:**
   - Take the vault out of docs-sync (A11 N2): on 11-04 it split the brain dump twice while you typed.
   - Recense: the idle crash came back on 11-04 (R15), and holding ⌘ breaks the strip (R16). Both are small fixes.
   - Rotate the R2 key and the JWT secret.
   - Remove two unencrypted password exports.
   - Untrack the wrangler account file.
   - Stop the SanDisk agent.
   - Stop indexing Raven, and fix the bug that lets idle minutes spend the indexing budget (G20).
   - (The iOS apps are fine: re-signed on 11-03, 120 h left on 11-05.)
10. **Part B and spend:**
   - One shell (Library · Matters · Study · Folio · Player · Share), with your academic space named **Folio**.
   - One sync-state pill.
   - Light and high-contrast themes, VoiceOver and real captions.
   - Recense's dual edges.
   - Gestures replace buttons, but every action keeps a visible twin. A sound console without the home bars, and one global speed (B9).
   - Haptics and audio textures for emphasis, tested on yourself first (B10).
   - The apps in French and Vietnamese, and rails for reading long text (B11).
   - The free plan is enough. If you pay for one thing, the $99/yr Apple developer account beats Workers Paid (A12).

## What you have (one screen; for line 152 of the 11-05 note)
| Part | What it is | Where it runs | Code |
|---|---|---|---|
| **Recense**, the Mac app | The strip in your menu bar (clock, calendar, battery, mic, time zones), the listening surface (live transcripts, the karaoke light, loops, speed, sound), Draftpad and the menu-bar hider | your Mac, offline | `recense/recense/` → `strip/` (A15) |
| **Gallery** | Your library on the web and in Files (photos, recordings, documents), share links, the player and the Ask assistant | Cloudflare (a Worker + R2 storage), the web, and apps on iPhone, iPad and Mac | `gallery/gallery/` → `library/` |
| **Sync** | The Mac's background jobs (copies to R2, the vault journal, disk mounts, iOS re-signing), the calendar server, and the plans and runbooks | your Mac (launchd) and a second Worker | `sync/` → `sync/`, `calendar/`, `docs/` |
| **Your data** | R2 storage (≈ 77 GB known), the Obsidian vault in iCloud, DEVONthink (Raven today, Matters next), Arq backups | Cloudflare, iCloud, the Mac | — |
| **Wrong right now** | Recense closes when idle (a crash, R15) and holding ⌘ breaks the strip (R16). docs-sync still uses ≈ 90 % of the daily Worker budget and splits notes (T1). Nothing has been lost | — | A3, A10 |
| **What this plan does** | Fix those first (phase 0), make every device work offline with the cloud as backup (phases 1–8), make one repo (A15), and redesign the apps (Part B) | — | A9, A15, Part B |

## On approval (documentation only)
| # | Step | Rule |
|---|---|---|
| 1 | Save this file to `sync/docs/specs/unified-offline-first-and-redesign.md` (the owner's path; sync convention would file pending decisions under `docs/proposals/`) | owner request |
| 2 | Add row "Unified offline-first + redesign plan (spec saved) \| DONE" to `sync/notes/20261030-063714.md`, re-reading its header first | global + `CLAUDE.md` |
| 3 | Add one changelog entry at the top of `## CHANGELOG` in `sync/PROGRESS.md` (newest first: date, item, status, what, validation, next), re-reading it first | `sync/CLAUDE.md:31-32` |
| 4 | Archive the 10-29 handoff as `sync/.handoff/2026-10-29_164631_HANDOFF.md` (this spec cites its lines), then overwrite `sync/.handoff/HANDOFF.md` (date on line 1), run the zip command, and confirm `.handoff/` and `*-handoff.zip` are ignored | global `CLAUDE.md` |
| 5 | Update the memory: `sill-is-recense.md` (the GitHub repo is `louan-dev/recense`; Sill.app went to the Trash on 11-04), and one new note on DEVONthink To Go's sync limits (A16d) | memory hygiene |
| 6 | Nothing else. A10 changes, deploys, the A15 merge and deletions, and the owner's security actions all wait for the owner's go | plan only |
**Non-goals:** no implementation, no data migration (inventories and `.versions/` are additive; the Raven → Matters move is only proposed), no features beyond this plan.

**Verify the approval steps:** `cmp` the plan file with the saved spec; `grep -n "Unified offline-first" ~/Developer/sync/notes/20261030-063714.md ~/Developer/sync/PROGRESS.md` finds one line in each; `unzip -l ~/Developer/sync/sync-handoff.zip | grep HANDOFF.md`; `git -C ~/Developer/sync log -1` is unchanged (nothing committed).

## Owner answers (2026-11-03)
| Q | Answer | Design consequence |
|---|---|---|
| Who has accounts? | **Just me** | One user under `u/<userId>/` (naming from `sync/docs/specs/sync.md:35-43`). Per-principal budgets for owner devices and share-link tokens. No sign-up. S8 is tested on these seams. |
| Law data? | **Both, strictly separated** | Study and Folio in Gallery (shareable where licences allow, cloud processing OK) + **Matters, sealed by construction**: DEVONthink on the FileVault-encrypted Mac (Matters syncs to the phones at home; Sealed is encrypted and stays on the Mac), no links, no cloud processing (the on-device model at most), an Arq-encrypted off-site copy, retention and hold (A6). |
| Workers Paid? | **Free only, or offline-first sovereign cloud** | Free-plan budgets with margin. The breaker is the last line of defense. The relay box is a gated phase. |

## Success tests S1–S10 (S9 and S10 added 11-04)
| Test | Today | Evidence | After plan |
|---|---|---|---|
| S1 budget | **FAIL** | ≈ 95k–145k req/day, ~90 % from docs-sync; Error 1027 on 2026-11-03 (A1) | **PASS**: ≈ 720 normal day / ≈ 1,020 worst day (below) |
| S2 airplane | **FAIL** | The iOS Listen `unsent` set lives only in memory (`apple/HostApp/iOS/Listen.swift:172`), so queued uploads are forgotten on quit. A 409 replaces local edits with the server copy (`:261`). The web app has no offline mode | **PASS**: durable ordered outbox (phase 4) |
| S3 no polling | **FAIL** | docs-sync every ≤ 10 min and on every save. Web polls every 2 s / 5 s / 20 s (`client/gallery.js:7489,4384`, `main.js:566`). Mac File Provider every 60 s. iOS Listen every 60 s. Cron every minute | **PASS**: one root-manifest request, 304 when unchanged. Syncs only on app foreground, local change or user action |
| S4 breaker | **FAIL** | 1027 is not handled anywhere; raw HTML reaches toasts (B2 #1) | **PASS**: A8 |
| S5 R2-readable | PARTIAL | Open JSON (`keep/<key>/`) and catalog snapshots (`fp.js:8-11`), but no checksums, and replaced files go to trash | **PASS**: sha256 in the catalog = inventory; `.versions/`; a root README |
| S6 media bypass | **FAIL** | Every file, tile and Range chunk streams through the Worker (`main.js:669-689`, `public.js:944-980`, `common.js:49-60`). No presigning, static assets or Cache API anywhere | **PASS**: direct R2 with device keys (owner apps) + presigned GET/PUT (web, share pages) |
| S7 handoff | PARTIAL | `recense/recense/handoff.swift:87-103`: newest copy wins, silently. Gallery iOS uses a 60 s Worker timer | **PASS**: one cursor per device in `keep/listen/` via presigned PUT/GET, plus a "Continue" banner |
| S8 isolation | **FAIL** | Bearer token bundled in the iOS build (`apple/HostApp/iOS/App.swift:3-4,29-33`) with no per-device revoke; account-wide R2 key in Mac jobs (A3 X8) | **PASS (seams)**: per-device keys, `u/<userId>/`, per-principal budgets, bucket-scoped R2 keys |
| S9 loops | **FAIL** | Safari's effects path re-streams WAV/AIFF on every pass: ≈ 3,400 Worker requests per looping hour (`client/gallery.js:2382-2421`). The iOS app keeps no local copy, so nothing plays offline (`apple/HostApp/iOS/Player.swift:1-40`). Recense downloads a piece again each time it returns (`recense/recense/recense.swift:7784-7791`) | **PASS**: 0 Worker requests per pass, ≤ 1 R2 read per file per device per change, and loops work in airplane mode (A13) |
| S10 no router | **FAIL** | No app has a peer-to-peer path; the home-network path is only planned | **PASS**: peer-to-peer Wi-Fi between your own devices (A14) |

**S1 arithmetic for the new design** (requests/day; presigned R2 traffic = 0 Worker requests):
| Flow | Normal day | Worst day |
|---|---|---|
| iPhone: 40 opens × 1 manifest + 20 commits + 10 presign batches | 70 | 70 |
| iPad: 20 + 10 + 5 | 35 | 35 |
| Mac: 30 activations + 50 commits + 40 Recense layer commits | 120 | 120 |
| CalDAV/CardDAV on 3 devices, hourly fetch × ~2 requests | 150 | 150 |
| Share-page views: 50 × 2 (page + listing) | 100 | 100 |
| Gallery browsing: 50 folder views × 2 (HTML + listing with presigned tile URLs) | 100 | 100 |
| Gallery crons at `*/10` + nightly | 145 | 145 |
| docs-sync, archive-mount, ledger and disks on the S3 API | 0 | 0 |
| 10k-file import: 100 presign batches (100 each) + 100 commits | — | 200 |
| New device: changes feed, 1,000 entries per page, 100k objects | — | 100 |
| Media replays and loops, any number (A13) | 0 | 0 |
| **Total** | **≈ 720** | **≈ 1,020** (10× safety = 10.2k ≤ 40k) |
ASSUMED: 100 presigns fit within the free plan's 10 ms CPU. Bench this in phase 1; fallback is 25 per batch (the import then costs 500 requests).

## A1. Ground truth: who calls `*.improvdiplomat.workers.dev` (audit 2026-11-03)
Workers:
- **gallery** (`gallery/gallery/wrangler.toml`): R2 PUBLIC, MAIN, KEEP, TMP, ARCHIVE, NOTES_IMAGES, CALENDAR; AI + Vectorize; crons `* * * * *` and `0 3 * * *`. No static assets, no KV/D1/DO, no observability.
- **sync** (`sync/worker/wrangler.toml`): CalDAV on R2 `sync`, ctag only (`caldav.js:6-7`).

| #   | Caller                                                                                                                                               | Evidence                                                                                          | Schedule                                                                                                                   | Req/day                                                  | Worker |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- | ------ |
| 1   | **docs-sync**: 6–7 rclone bisync lanes + copies + a full `lsf -R` INDEX over WebDAV. WebDAV can't list recursively, so it costs 1 request per folder | `sync/bin/docs-sync.zsh:42-47,80-83,91-97`; `~/Library/LaunchAgents/com.chauphan.docs-sync.plist` | StartInterval 600 + WatchPaths on the vault + Throttle 120 → 229 runs (11-02), 247 by 16:46Z (11-03), 21–30/h while typing | ~400–550 per run × 229 ≈ **90k–126k**                    | Y      |
| 2   | archive-mount (rclone nfsmount over WebDAV)                                                                                                          | `sync/bin/archive-mount.zsh:12,31-38`                                                             | KeepAlive; `--dir-cache-time 1m`; statfs 404s are not cached                                                               | 0.3k–2.2k                                                | Y      |
| 3   | Gallery cron                                                                                                                                         | `worker.js:80-85`                                                                                 | every minute + nightly                                                                                                     | 1,441 (if cron runs count: ASSUMED yes)                  | Y      |
| 4   | Gallery web polling                                                                                                                                  | `client/gallery.js:7489,6125` (2 s), `:4384-4399` (5 s), `main.js:566` (20 s)                     | while a tab is visible                                                                                                     | 1,800 / 720 / 180 per hour per tab                       | Y      |
| 5   | CalDAV (Mac Calendar; iPhone unconfirmed)                                                                                                            | `sync/worker/src/caldav.js`                                                                       | Calendar refresh setting                                                                                                   | ~0.6k–0.9k at 5 min                                      | Y      |
| 6   | Mac Gallery File Provider re-signal                                                                                                                  | `apple/HostApp/macOS/main.swift:57-59` → `FileProviderCore/Core.swift:157-159`                    | every 60 s while the app runs                                                                                              | 1,440 (Gallery Files running since 11-03)                                  | Y      |
| 7   | Gallery browsing: HTML + 1 per tile + 1 per Range chunk                                                                                              | `main.js:354,372,669-689`; `public.js:944-980`; `common.js:49-60`                                 | page views                                                                                                                 | 25–60 per folder view; 3–20+ per video                   | Y      |
| 8   | Gallery.app Touch ID mount (rclone combine, Main over WebDAV)                                                                                        | `gallery/gallery/chau/Gallery/main.swift:30-46`                                                   | while open                                                                                                                 | ~1–3k (mounted at `~/.gallery` since 11-03 16:07, via `/main/nc/dav`)                                  | Y      |
| 9   | iOS Listen                                                                                                                                           | `apple/HostApp/iOS/Listen.swift:95-99,217-261`                                                    | 60 s timer while alive                                                                                                     | 60–120/h                                                 | Y      |
| 10  | "Move Offsite" Shortcut, Mac Services, Notability backup, link previews                                                                              | `sync/tools/shortcuts/`, `sync/bin/offsite-image.zsh:11,63`, `worker.js:54-56`, `public.js:1533`  | user/app actions                                                                                                           | small                                                    | Y      |
| —   | downloads-to-r2: `rclone move ~/Downloads gallery-tmp:` over S3 (`jobs.conf`) | `~/Library/LaunchAgents/com.chauphan.downloads-to-r2.plist` | StartInterval 180 + WatchPaths | **0 Worker**; ≤ 480 runs ≈ ≤ 480 R2 LISTs/day | N |
| —   | Recense: GalleryJob.media (every 15 min, ≥ 30 LIST pages), keep/locks (every 60 s), handoff, sweep                                                   | `recense/recense/recense.swift:5867-5890,6562,6636-6640,7072-7080`; `handoff.swift:48-66`         | timers                                                                                                                     | **0 Worker**; ≈ 4.3k R2 Class A/day (SigV4 direct to S3) | N      |
| —   | Firefox bridge                                                                                                                                       | installed `recense@local.xpi` → 127.0.0.1:47123 only                                              | —                                                                                                                          | 0                                                        | N      |
| —   | "sync-plan" Shortcut endpoint                                                                                                                        | `sync/PROGRESS.md:719`                                                                            | —                                                                                                                          | proposal only, does not exist                            | —      |
**Total ≈ 95k–145k/day** (rows 6 and 8 add ≈ 2.4k–4.4k while Gallery Files and Gallery.app run, as they have since 11-03).
- Error 1027 hit on 2026-11-03 from 08:46:57 to 12:13:33 PST (96 lines in `~/Library/Logs/archive-mount.log`).
- docs-sync logged "Gallery not reachable" from 16:46:56Z to 20:06:24Z.
- Unexplained: the 1027 cleared around 20:13Z, before the 00:00 UTC reset.

**Read-only commands for today's real counts.** Claude never types the token; the owner sets `CF_API_TOKEN` (Account Analytics: Read) and `CF_ACCOUNT_ID`.
```zsh
# Per-Worker totals since 00:00 UTC (this dataset has no path dimension)
curl -s https://api.cloudflare.com/client/v4/graphql -H "Authorization: Bearer $CF_API_TOKEN" \
  --data "$(jq -n --arg a "$CF_ACCOUNT_ID" --arg s "$(date -u +%Y-%m-%dT00:00:00Z)" --arg e "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{query:"query($a:string,$s:string,$e:string){viewer{accounts(filter:{accountTag:$a}){workersInvocationsAdaptive(limit:100,filter:{datetime_geq:$s,datetime_leq:$e}){sum{requests errors subrequests} dimensions{scriptName status}}}}}",variables:{a:$a,s:$s,e:$e}}')" \
  | jq '.data.viewer.accounts[0].workersInvocationsAdaptive'
# Per-route live sample (history needs Workers Logs, which is off; phase 1 turns it on)
cd ~/Developer/gallery/gallery && npx wrangler tail gallery --format json \
  | jq -r '.event.request.method+" "+(.event.request.url|sub("^https?://[^/]+";"")|sub("\\?.*$";"")|split("/")[0:4]|join("/"))' \
  | sort | uniq -c | sort -rn | head -20
```

## A2. Cloudflare facts (checked against current docs 2026-11-03)
| # | Claim | Status | Source |
|---|---|---|---|
| 1 | Free plan: 100,000 requests/day, reset at **00:00 UTC**. The docs say "Accounts on the Workers Free plan have a daily request limit", so the limit is account-wide, across all Workers including workers.dev | VERIFIED (per-account wording) | [limits](https://developers.cloudflare.com/workers/platform/limits/) |
| 2 | Over the limit → **Error 1027**. Routes on a zone can fail open (bypass the Worker) or fail closed (1027 page); workers.dev has no origin to fail open to | VERIFIED; workers.dev part ASSUMED | [limits](https://developers.cloudflare.com/workers/platform/limits/) |
| 3 | Paid: no daily cap; 10M requests/month included then $0.30 per million; 30M CPU-ms included then $0.02 per million; $5/month minimum | VERIFIED | [pricing](https://developers.cloudflare.com/workers/platform/pricing/) |
| 4 | Subrequests are not billed as requests. Free plan: 50 external + **1,000 internal-service (R2/KV/D1)** subrequests per invocation; Cache API calls share that quota | VERIFIED | [limits](https://developers.cloudflare.com/workers/platform/limits/) |
| 5 | Static asset requests are "free and unlimited". Paths matching `run_worker_first` invoke the Worker, count, and get 429 over the free limit | VERIFIED. That assets keep serving on a 1027 day: ASSUMED | [static assets billing](https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/) |
| 6 | "Workers run before the cache", so a cache hit served by a Worker still invokes it and counts | VERIFIED wording; counting ASSUMED by construction | [cache](https://developers.cloudflare.com/workers/reference/how-the-cache-works/) |
| 7 | Cache API on `*.workers.dev` is not documented, so the design doesn't rely on it | ASSUMED | same |
| 8 | Presigned URLs work only on the S3 host `<acct>.r2.cloudflarestorage.com` (not custom domains); GET/HEAD/PUT/DELETE; valid 1 s–7 days; signed with no call to R2 (aws4fetch works in a Worker); browsers need bucket CORS. The host differs, so they cost **0 Worker requests** | VERIFIED; 0-requests ASSUMED by construction | [presigned](https://developers.cloudflare.com/r2/api/s3/presigned-urls/) |
| 9 | Cron Triggers aren't listed as billable, but the pricing example bills an hourly cron as 720 requests/month, so each cron run is counted as 1 request here | ASSUMED (conservative) | [pricing](https://developers.cloudflare.com/workers/platform/pricing/) |
| 10 | Durable Objects (free): SQLite only; 100k requests/day, 13,000 GB-s/day, 5M rows read and 100k rows written per day, 5 GB | VERIFIED (not used: owner rule) | same |
| 11 | KV (free): 100k reads/day, **1k writes**, 1k deletes, 1k lists → never use KV for counters | VERIFIED | same |
| 12 | D1 (free): 5M rows read/day, 100k rows written/day, 5 GB, 10 databases | VERIFIED (not used: owner rule) | same |
| 13 | Queues (free): 10k operations/day, 24 h retention | VERIFIED | same |
| 14 | Analytics Engine (free): 100k data points/day, 10k queries/day; not billed today | VERIFIED | [AE pricing](https://developers.cloudflare.com/analytics/analytics-engine/pricing/) |
| 15 | Workers Logs: free plan 200k events/day, 3-day retention; needs `[observability] enabled = true`; Query Builder can group by `$workers.event.request.path`; moves to Observability pricing on 2026-12-01 | VERIFIED | [logs](https://developers.cloudflare.com/workers/observability/logs/workers-logs/), [query builder](https://developers.cloudflare.com/workers/observability/query-builder/) |
| 16 | GraphQL `workersInvocationsAdaptive` sums requests, errors and subrequests by script, status and time. It has **no path dimension** | VERIFIED | [GraphQL Workers](https://developers.cloudflare.com/analytics/graphql-api/tutorials/querying-workers-metrics/) |
| 17 | R2 pricing: Standard $0.015/GB-month; Infrequent Access $0.01 + $0.01/GB retrieval, 30-day minimum; Class A $4.50/M (List, Put, Copy, multipart); Class B $0.36/M (Get, Head); Delete free; egress free; free tier 10 GB-month + 1M Class A + 10M Class B per month (Standard only); GB-month = average of daily peaks, rounded up | VERIFIED | [R2 pricing](https://developers.cloudflare.com/r2/pricing/) |
| 18 | R2 has **no object versioning** (PutBucketVersioning is unimplemented), so versions must be kept by the app | VERIFIED | [S3 API compat](https://developers.cloudflare.com/r2/api/s3/api/) |
| 19 | R2 evaluates conditional PutObject (If-Match / If-None-Match) **atomically** → compare-and-swap without a database | VERIFIED | same |
| 20 | R2 supports SSE-C. It has no S3 Object Lock API, but it has **bucket locks** (scoped by prefix; age, date or indefinite; override lifecycle rules) | VERIFIED; free-tier availability ASSUMED | [bucket locks](https://developers.cloudflare.com/r2/buckets/bucket-locks/) |
| 21 | R2 encrypts at rest with AES-256 (GCM) under Cloudflare-managed keys; TLS in transit | VERIFIED | [data security](https://developers.cloudflare.com/r2/reference/data-security/) |
| 22 | Request bodies are capped at 100 MB (Free/Pro zones), so large uploads can't go through a Worker | VERIFIED | [limits](https://developers.cloudflare.com/workers/platform/limits/) |
| 23 | Free CPU is 10 ms per request. Catalog passes of 250–345 ms were recorded (`sync/PROGRESS.md:157`), which shows leeway in enforcement, not a guarantee | VERIFIED limit; leeway observed | [limits](https://developers.cloudflare.com/workers/platform/limits/) |
| 24 | In Oct 2024, free Workers were throttled below 100k → budget with margin | VERIFIED (third-party status mirror) | [isdown](https://isdown.app/status/cloudflare/incidents/322963-free-tier-workers-are-hitting-request-rate-limits-lower-than-what-is-documented) |

**"How many GBs, and what am I paying?"** (last recorded figures; no live query was run)
| Bucket | Last recorded | Source |
|---|---|---|
| gallery-main | 34.61 GiB / 29,645 objects (10-28), of which Raven is 30.36 GiB | `sync/.handoff/2026-10-28_071531_HANDOFF.md:80,148` |
| gallery-archive | Record It 3.86 GB, Downloads 0.62 GB, Voice Memos 8.25 GB, `.disks-test` 1.15 GiB, SanDisk Records 5.37 GB (10-28), plus the `.disks` bundles (caps 60/100/50 GB; actual size unknown) | `sync/PROGRESS.md:730-736`; `sync/.handoff/2026-10-29_164631_HANDOFF.md:19` |
| Photos library tar | 8.92 GB (no originals) | `sync/.handoff/2026-10-29_164631_HANDOFF.md:93-94` |
| sdddc3t00g46-sandisk | 6.07 GB / 1,238 objects (10-28) | `sandisk-rescue/scripts/r2-sandisk.json` |
| recense-tmp | keep/ 525 MB (11-03); tmp/ takes in ≈ 2.5 GB/day and keeps it 2 days | `~/Library/Logs/recense.log` |
| gallery-tmp, gallery-public, notes, notes-images, sync, sync-ledger, Arq | not recorded | — |
- **Storage:** about 77 GB known, plus the offsite disks and the unrecorded buckets. (77 − 10 free) × $0.015 ≈ **$1.00/month**, + $0.015 per extra GB.
- **Operations:**
  - Direct S3 traffic is ≈ 9k Class A/day.
  - **Through the Worker, every WebDAV PROPFIND also lists R2** (`dav.js:150-168`). So docs-sync adds ≈ 115k Class A/day ≈ 3.4M/month, which is ≈ **$11/month** above the 1M free tier if left as is (estimate; it started 10-31).
  - Workers cost $0 (free plan).
- **Exact numbers:** Dashboard → R2 → Overview (size and month-to-date Class A/B), and Billing → Billable usage.
- **CLI** (about 30 LISTs): `RCLONE_CONFIG=~/.config/rclone/jobs.conf rclone size gallery-main:gallery-main --fast-list` (the same for gallery-archive and gallery-tmp).

## A3. Gap map (every loose thread)
**Urgent: security and live hazards**
| ID | Item | App | Status | Blocked by | Source |
|---|---|---|---|---|---|
| X1 | Plain-text R2 key for the account-wide `sync-backup` token (Arq uses it too): rotate it, re-key Arq, scrub the file | Sync | pending | owner (dashboard) | `sync/decisions/20261022 ARQ-CHECKLIST.md:22-23` |
| X2 | JWT secret pasted in the recovery log: rotate | SanDisk | pending | owner | `sandisk-rescue/sandisk recovery log.txt:5,7` |
| X3 | Two password-manager exports unencrypted in R2 `sdddc3t00g46-sandisk/Backups/` | SanDisk | pending | owner: delete or encrypt | `sandisk-rescue/scripts/r2-sandisk.json`; `sync/docs/runbooks/sandisk-evac.md:17` |
| X4 | `.wrangler/cache/wrangler-account.json` is still tracked and in the pushed history of the repo, now `louan-dev/recense` (f8a9802); `.wrangler/` is not ignored | Recense | pending | owner: untrack; rewrite history? Check the repo's visibility first (A15e) | `recense/.gitignore:1-11` |
| X5 | Plain-text `rclone.conf.bak-*` copies left behind | Sync | pending | owner (agents can't `rm`) | `sync/PROGRESS.md:704` |
| X6 | Offsite sparse bundles (Photos/Messages/Mail copies) are unencrypted | Sync | decision | owner | `sync/docs/runbooks/offsite-disks.md:47` |
| X7 | **Raven client matters (29,354 files) are in Main and indexed by Workers AI + Vectorize**; no retention, hold or access policy | cross | pending | A6 | `gallery/.handoff/assistant-item2.md:7,11` |
| X8 | Mac jobs (`autoupload.sh`) use the account-wide key; they need bucket-scoped keys | SanDisk/Sync | blocked | dashboard key grant | `sandisk-rescue/.handoff/HANDOFF.md:162-163` |
| X9 | The vault's Share Note plugin publishes notes to a third-party server: fine for study notes, never for client matters | Sync | check | owner | `<vault>/.obsidian/plugins/share-note` |
| D1 | Stale `com.chauphan.sandisk-rescue` agent: running since 12:03 under `caffeinate -i`, polling for the drive every 0.3 s | SanDisk | pending | owner OK to unload | `~/Library/LaunchAgents/com.chauphan.sandisk-rescue.plist` |
| G12 | Free-team signing profiles: `resign-ios` re-signed the iOS apps on 11-03 at 12:00 with 28 h left; on 11-05 it reports 120 h left. It checks daily at noon | Gallery | **done (verified in the log)** | — | `~/Library/Logs/resign-ios.log` |
| R2 | The rename corrupted `recense/docs/architecture.md`: step 1 now reads "Kill Recense.app for good", which is the live app | Recense | pending (agent hazard) | doc fix | `recense/docs/architecture.md:10,14,20,29` |

**Quota and sync**
| ID | Item | App | Status | Blocked by | Source |
|---|---|---|---|---|---|
| Q1 | Quota bleed: docs-sync ≈ 90k–126k req/day | Sync | pending | A10 | A1 |
| T1 | Nested conflict suffixes; `draftpad.conflict38` | Sync/Recense | cause found | A10 #1, #3; phase 7 | A10 |
| Y8 | docs-sync failing live: Desktop lane "empty prior Path1 listing"; draftpad "hash is missing" | Sync | in progress | Desktop permissions; `--resync` | `~/Library/Logs/docs-sync.log` |
| Q2 | No 1027 handling, no counters, no breaker | all | pending | phase 1 | B2 #1 |
| Q3 | Media streamed through the Worker | Gallery | pending | phase 2 | A1 #7 |
| Q4 | Polling loops (web 2/5/20 s, Mac File Provider 60 s, iOS Listen 60 s, cron every minute) | Gallery | pending | phase 3 | A1 |
| Q5 | No durable outbox | Gallery/Recense | pending | phase 4 | `Listen.swift:172` |
| Q6 | Loop leaks: Safari's effects path re-streams WAV/AIFF on every pass (≈ 3,400 Worker requests per looping hour); the iOS app keeps no local copy | Gallery | pending | A13 L1–L5 | `client/gallery.js:2382-2421`; `apple/HostApp/iOS/Player.swift:1-40` |
| Q7 | Recense media ping-pong: the sweep uploads and deletes a piece, then downloads it again when it returns | Recense | pending | A13 L6 | `recense/recense/recense.swift:6047-6057,7784-7791` |
| Q8 | Clock-driven media loops: the Worker cron every minute for ≤ 5 useful runs; Mac File Provider every 60 s + the Worker's reconcile LIST; Recense's `keep/locks/` LIST every 60 s; handoff writes every 60 s while playing | all | pending | A13 L8–L9 | A13b |
| Q9 | No peer-to-peer path between your own devices | all | pending | A14 | — |
| Y6 | CalDAV Phase 0 round trip (G1): PROGRESS lists it as next, yet the account is "connected on all devices" | Sync | done-unverified | device check | `sync/PROGRESS.md:127` |
| Y7 | Move the ledger sinks to the `sync-ledger` bucket | Sync | blocked | one dashboard key grant | `sync/PROGRESS.md:152,160-162` |
| Y14 | Move the engine (fp/dav/tmp/archive) from Gallery to Sync (organism H5) | Sync/Gallery | pending | owner confirms §8 decision 8 | `sync/docs/specs/organism.md:81-90,128-145` |
| Y17 | Switchboard / Scheduler / Manager exist only as specs | Sync | blocked | missing iPhone addendum | `sync/PROGRESS.md:128` |
| Y1 | Arq restore drill | Sync | pending | — | `sync/PROGRESS.md:119` |
| Y2 | iCloud at 91.9 % vs the ≤ 75 % target | Sync | pending | owner on icloud.com | `sync/PROGRESS.md:120` |
| Y3 | Remotely Save (bucket `notes`) | Sync | in progress | owner token | `sync/PROGRESS.md:123` |
| Y4 | Ledger views in Gallery and Recense | cross | proposed | — | `sync/PROGRESS.md:124` |
| Y5 | Messenger backup tested on a synthetic export only | Sync | in progress | a real export | `sync/PROGRESS.md:125` |
| Y9 | Offsite disks: owner GUI steps remain; Messages Disk is not mounted | Sync | in progress | owner (Full Disk Access) | `sync/.handoff/2026-10-29_164631_HANDOFF.md:23-26,50-58` |
| Y10 | Export iCloud Photos originals (the tar has none) | Sync | pending | disk space, time | `sync/.handoff/2026-10-29_164631_HANDOFF.md:93-97` |
| Y11 | Delete local originals once verified | Sync | pending | owner + retention rule | `sync/.handoff/2026-10-29_164631_HANDOFF.md:47-48,101-104` |
| Y12 | Import the "Move Offsite" Shortcut on iPhone and iPad | Sync | pending | owner | `sync/notes/20261030-063714.md:3` |
| Y13 | Notability legacy snapshot | Sync | pending | — | `sync/PROGRESS.md:580` |
| Y15 | Lifecycle rule for `.uploads` | Sync/Gallery | pending | — | `sync/PROGRESS.md:254` |
| Y16 | Leftover Google Drive CloudStorage folder | Sync | pending | owner | `sync/PROGRESS.md:739-740` |
| Y18 | DEVONthink over Tailscale (not signed in). DEVONthink To Go's Bonjour sync can't cross Tailscale, so remote use needs the Server edition's web interface or a WebDAV sync store on the Mac (A16d) | Sync | in progress, re-scoped | owner sign-in; A16d | `sync/PROGRESS.md:129` |
| Y20 | Time Machine; Phi | Sync | proposed | disk | `sync/PROGRESS.md:67-99` |
| Y21 | Unnamed "A decision" | cross | blocked | owner | `sync/.handoff/2026-10-29_164631_HANDOFF.md:75-76` |
| Y22 | Arq bucket name mismatch | Sync | check | — | `ARQ-CHECKLIST.md:19` vs `PROGRESS.md:567` |
| Y23 | `sync/CLAUDE.md:8` still says "no remote", but origin is `louan-dev/sync`. PROGRESS.md's edits were committed on 11-04 (bdfc2cd) | Sync | pending | — | `sync/CLAUDE.md:8` |
| Y24 | `com.chauphan.ledger.icloud-drive` fails with `Unknown system error -11`: errno 11 on macOS is EDEADLK, which a read of an evicted iCloud file can return. Likely tied to iCloud being full | Sync | pending | A11 N1 | `~/Library/Logs/ledger-icloud-drive.log` |
| Y25 | Two engines on `~/Downloads`: docs-sync's two-way lane and downloads-to-r2's `move` | Sync | pending | A11 N2 | `sync/bin/docs-sync.zsh:4`; the downloads-to-r2 plist |

**SanDisk → unification**
| ID | Item | App | Status | Blocked by | Source |
|---|---|---|---|---|---|
| D2 | Remove the SanDisk exFAT line from `/etc/fstab` | SanDisk | pending | sudo (owner) | `/etc/fstab` |
| D3 | Where did the 61 rescued Records videos (18 GB) land? The archive listing shows only 21 / 5.37 GB | SanDisk | done-unverified | read-only listing with a scoped key | `sandisk-rescue/.handoff/HANDOFF.md:70-72` |
| D4 | Check 526 old-bucket files (≈ 6.95 GB) against the drive | SanDisk | pending | drive + read key | `sandisk-rescue/.handoff/HANDOFF.md:177-181` |
| D5 | Upload `to-archive/` (1.1 GB) after fixing its prefix (`chauphan/` → `archive/`) and switching to a scoped key | SanDisk→Gallery | pending | X8 | `sandisk-rescue/scripts/autoupload.sh` |
| D6 | Server-side copy of the old bucket into gallery-archive, check MD5s, retire `sdddc3t00g46-sandisk` | SanDisk→R2 | pending | D4, X3, X8 | `sandisk-rescue/.handoff/HANDOFF.md:180-181` |
| D7 | Dedupe Records twins (38) and unique files (23) against Main PLIv1 and the archive | cross | pending | D3, D6 | `sandisk-rescue/scripts/records-twins.txt` |
| D8 | 123 damaged Raven files + 19 zero-length objects in Main | Gallery | blocked | owner picks a source (BARG mailbox / Raven document system) | `sync/.handoff/2026-10-28_071531_HANDOFF.md:104-182` |
| D9 | Decide on 18,320 trash files (6.9 GB) and 3 ledger files that exist only on the drive | SanDisk | pending | owner | `sandisk-rescue/scripts/only-on-drive.txt` |
| D10 | Local cleanup folders (agents can't `rm`) | SanDisk | pending | owner | — |
| D11 | Empty, erase and f3-test the drive | SanDisk | pending | D3–D9 | `sync/docs/runbooks/sandisk-evac.md:64-78` |
| D12 | The pipeline still targets the old bucket (superseded) | SanDisk | pending | D1 | `sandisk-rescue/scripts/pipeline.sh:3` |

**Gallery**
| ID | Item | App | Status | Blocked by | Source |
|---|---|---|---|---|---|
| G1 | Branch `c0-c1-g3-g5` (C0 authorization, C1 D1, …) pushed, not merged | Gallery | in progress | G2 | `gallery/.handoff/HANDOFF.md` |
| G2 | D1 contradiction: owner spec says "no D1", §8 decision 3 adds it. **This plan needs no D1** | Gallery | blocked | owner | `gallery/notes/20261029-152324.md:1621`; `sync/PROGRESS.md:404` |
| G3 | Guest email/ICS flow; sender not configured | Gallery | blocked | owner | `gallery/notes/20261029-152324.md:1596-1623` |
| G4 | main is 2 commits ahead (undeployed); `homebar.js` uncommitted | Gallery | pending | owner OK to push | git |
| G5 | Failing UI test ("comments: right after posting…") | Gallery | in progress | fix | `gallery/.handoff/test-output.txt` |
| G6 | Workers AI's daily cap (error 4006): indexing stops for the day on it (`ai.js:365`). Questions have no cap and no 4006 handling, and the raw error is shown as the answer (`ai.js:202`; `client/assistant.js:148`) | Gallery | partial | A16 | `gallery/notes/20261029-152324.md:384,755` |
| G20 | **Idle runs spend the AI indexing budget.**<br>• `b.steps++` runs before `indexStep` (`ai.js:359-362`), so each idle minute spends a step, plus 2 R2 reads and 1 write.<br>• The 120-step budget is gone ≈ 2 h after 00:00 UTC, and new uploads wait until the next day.<br>• No test covers it | Gallery | bug found | count a step only when it indexed something; add a test; then A13 L9 | `gallery/gallery/src/ai.js:350-370`; `worker.js:84` |
| G7 | Notes items PENDING: 3, 10, 16, 17, 20, 21, 22, 25, 28, 29, 31, 32, 33, 35, 36, 40, 42. No status: 1, 5, 7, 8, 11, 19, 37, 43–46 | Gallery | pending | — | `gallery/notes/20261029-152324.md:7-56` |
| G8 | Whitacre transcript wiped; speech prosody not built | Gallery/Recense | pending | — | `gallery/.handoff/ITEM21.md:29-44` |
| G9 | Dense-track detector unverified and undeployed | Gallery/Recense | done-unverified | — | `gallery/.handoff/ITEM22.md` |
| G10 | ITEM38 icon uncommitted; leftover `/tmp/g15` worktree | Gallery | pending | — | `gallery/.handoff/ITEM38.md`, `ITEM15.md` |
| G11 | File Provider limits (rename/move gives 403, TextEdit can't open, 5 GiB cap) | Gallery | pending | — | `sync/docs/runbooks/gallery-drive.md:12-17` |
| G13 | `SERVICE_CLIENT_ID` accepts only the phone | Gallery | pending | — | `gallery/.handoff/assistant-item2.md:30-31` |
| G14 | Obsolete `ai/core.mjs`; unused Ollama (~3 GB) | Gallery | pending | — | `gallery/.handoff/assistant-item2.md:34,36` |
| G15 | Open question on gallery-public's 31-day rule | Gallery | blocked | owner | `sync/docs/proposals/r2-lifecycle-42.md:73` |
| G16 | LibraryHub Durable Object / WebSocket (not needed by this plan) | Gallery | proposed | — | `gallery/SYNC.md:1-9` |
| G17 | Main on iOS behind Face ID; the $99 account | Gallery | blocked | owner | `gallery/gallery/docs/architecture.md:145-151` |
| G18 | Stale docs ("No D1, KV or DO"; wrangler comments) | Gallery | pending | — | `gallery/CLAUDE.md:7` |
| G19 | C0's missing pieces | Gallery | in progress | — | `sync/PROGRESS.md:130,262` |

**Recense**
| ID | Item | App | Status | Blocked by | Source |
|---|---|---|---|---|---|
| R1 | Rename Sill → Recense: committed and pushed; the GitHub repo is now `louan-dev/recense`, and the docs in sync and gallery were renamed too (11-04). Left over: `recense/.build-log.txt` is tracked and modified | Recense | **done** | — | `recense/notes/20261031-145502.md:5-10`; git |
| R3 | `.claude/CLAUDE.md` contradicts itself (Groq, "no remote", standalone copy) | Recense | pending | — | `recense/.claude/CLAUDE.md:7,9-10,15,30` |
| R4 | The Nook fix is one unmerged commit on `claude/nook-fix-1f871c` (worktree `.claude/worktrees/nook-fix-1f871c`, 504 MB). It grows `nook.swift` from 149 to 441 lines on the old `sill/` paths. Autoupdate rebuilds `main` every 5 minutes and may overwrite a local build | Recense | in progress | rebase onto `recense/`, compare with the R16 fix, merge or drop (A15i) | `recense/.handoff/HANDOFF.md:2,11-13`; git |
| R5 | Custom language model fails | Recense | blocked | Apple API | `recense/docs/architecture.md:247` |
| R6 | Prosogram not started | Recense | pending | — | `recense/docs/architecture.md:304-336` |
| R7 | Reuse plan (CONTRACT.md, MANIFEST.json, Transcriber seam) | Recense | pending | — | `recense/docs/architecture.md:364-389` |
| R8 | Voice agenda steps 0–17; Hello Pronunciation phase 4 | Recense | pending | — | `recense/docs/recense-voice-vision.md:157-190` |
| R9 | SL1–SL7 (idle efficiency, Draftpad, widget panel…) | Recense | pending | — | `recense/.claude/CLAUDE.md:34-37,52-56` |
| R10 | Retranscribe Tsehaye | Recense | pending | owner presses Retranscribe | `sync/PROGRESS.md:418,748` |
| R11 | 47 owner items in the 10-26 notes have no per-row status | Recense/Gallery | pending | — | `recense/notes/20261026 Notes.md:2-48` |
| R12 | Repo clutter. Done on 11-04: `.stage.RceJ/`, the old Sill.app and the leftovers went to `~/.Trash/sill-leftovers-20261104`. Remaining: about 1.5 GB of old builds, worktrees and test output across recense and gallery (A15j) | Recense/Gallery | partial | your yes, path by path | A15j |
| R13 | Open "essentials" items (cloud-use disclosure, DEVONthink hub…) | Recense | pending | owner | `recense/docs/decisions-2026-10-07-essentials.md:13-26` |
| R14 | Re-check the macOS-upgrade risk list after 27.2; the bundle-ID change means permissions are asked again | Recense | done-unverified | owner | `recense/docs/architecture.md:288-302` |
| R15 | **"Closes while idle" (BD23) is a crash, and it has happened twice.**<br>• Both reports, 11-03 22:07 and 11-04 06:43, show `EXC_BREAKPOINT` (SIGTRAP) in `Features.measure` (`recense/recense/recense.swift:5040`), called from the idle-only `GalleryJob.measureMissing` (`:6801`).<br>• The launch agent has no KeepAlive, so after a crash Recense stays closed until you reopen it. On 11-05 it was running again, started by hand.<br>• Likely cause: `flux.sorted()[min(n - 1, …)]` at `:5074` reads index −1 when the audio has no frames (n = 0), e.g. a file that failed to decode; the log shows such failures on 11-03.<br>• `:5043` guards that case; `:5074` does not | Recense | cause likely, seen twice, not reproduced | a one-line `n > 0` guard + a test with empty audio. Then add `KeepAlive = {SuccessfulExit = false}` to the launch agent, so any future crash relaunches it | `~/Library/Logs/DiagnosticReports/recense-2026-11-03-220737.ips` |
| R16 | **Holding ⌘ breaks the strip** (recording of 11-05 12:06, 0:08–0:28).<br>• After ⌘ has been held for 0.7 s, the menu-bar hider expands and the hidden icons (⏺ ⑂ ✻) pop into the strip's place.<br>• The strip disappears, and the icons jump to the right edge and back.<br>• Cause: a global `flagsChanged` monitor fires on every held ⌘, including ordinary shortcuts and ⌘-Tab (`recense/recense/nook.swift:51-53,93-102`) | Recense | cause found | Fix: expand only while ⌘ is held with the pointer in the menu bar and no other key down, and keep the strip in place while the icons show. Also rename "Nook" to Recense (owner, 11-05) | `~/Recordings/Bug holding cmd 2026-11-05 12.06.39 screen.mov` |
| R17 | **Lyrics retrieval: grade D** (11-05 note, line 141). LRCLIB and Genius are free and cost 0 Worker requests, but the lookup wastes calls:<br>• Up to 4 LRCLIB searches per item, and ≈ 16 calls when the best match is under 35 % (`recense.swift:3018-3035,4020-4030`).<br>• It looks up every 30 s–20 min item, song or not (`:3732`), and an unconfirmed title match already counts as a song (`:3693,4006`).<br>• It runs a fuzzy search, sometimes by artist alone, instead of LRCLIB's exact `/api/get`, and sends no User-Agent.<br>• Only 503 is retried, and the last 7.5 s sleep is wasted.<br>• A failed lookup is saved as checked and never retried (`:4002`) | Recense | graded | Fix:<br>1. Look up only items that the on-device sound classifier (SoundAnalysis: music, singing) or the source marks as music.<br>2. One exact `/api/get` (title, artist, album, duration), one search as fallback, Genius only for a confirmed title.<br>3. A User-Agent naming Recense.<br>4. Back off on 429/5xx with Retry-After, with no sleep after the last try.<br>5. Re-check misses after 30 days or when the title changes.<br>6. Count an item as a song only when the duration matches within 2 s.<br>Expected: ≤ 2 calls per song, 0 for speech. Verify with a 50-item fixture that counts calls | `recense/recense/recense.swift:2995-3061,3693-4030` |

**Brain dump** (`…conflict1×8.conflict2.md`, 61,800 B, re-read 11-04; line numbers are for this version. The 10:45 copy adds the A13 request at line 10, so every later line there is 3 higher)
| ID | Item | App | Status | Blocked by | Line |
|---|---|---|---|---|---|
| BD1 | Law-practice file system + study tool | cross | planned | A5, A6, B3 | 4 |
| BD2 | What Sync is and controls; should it orchestrate continuity, handoff, share links? | Sync | decided | A4 | 7, 29, 100, 237 |
| BD3 | Tie up PROGRESS and SanDisk loose threads | cross | this table | — | 10 |
| BD4 | One organism: shared data layer, session continuity, handoff on every device pairing | Sync | planned | phases 3–5 | 14, 96, 98 |
| BD5 | Mac ↔ Gallery iOS file coherency with storage savings + backup | Sync/Gallery | partial (File Provider slice 1, offsite disks) | phases 2–4; A11 N7 | 21 |
| BD6 | Serverless backend; single vs sovereign vs multicloud | Sync | decided | A4, A12 | 25 |
| BD7 | Obsidian memory (its Helper grows past 4 GB) | owner | pending | tips: close graph/canvas, exclude attachments from indexing, fewer plugins (9 installed) | 33 |
| BD8 | Cadence/m4b engine: trigger-word sustain, call and response, mic shadowing, karaoke, rests | Recense | specified | A5, A7 | 36, 141–147 |
| BD9 | Ask engine: business hours from Contacts notes; trilingual summaries (share mode / study mode; screenplay form) | Recense | pending | on-device model; Matters excluded | 39 |
| BD10 | Harvard-level resources; questions for the cousin at Apple | owner | answered | A12i | 84 |
| BD11 | "How many GBs and fees" | Sync | answered | A2 | removed in the 11-04 edit |
| BD12 | Offline transcription → translation/transliteration → prosody + karaoke → TTS/STT | Recense | partial (ASR + translation on the Mac) | A7 | 94 |
| BD13 | Gallery player on Apple's engine; NUC/Pi/VPS expansion | Gallery/Sync | decided (Mac hub; a box only on triggers) | A4, A12 | 114 |
| BD14 | `/main/share` as a social NAS vs a private archive | Gallery | decided | A5 tiers | 119 |
| BD15 | Bionic reading; peripheral tunnel masking | Gallery/Recense | planned | B6 | 137–139 |
| BD16 | Per-file and per-section beats (≤ 3 variants, pin, pre-generate) | Recense | specified | A5, A7 | 151–202 |
| BD17 | Menu strip mod: TextSniper, superwhisper, dictionary/pronouncer | Recense | pending | — | 209 |
| BD18 | TextSniper-style OCR in the player | Gallery | pending | on-device Vision | 211 |
| BD19 | Draftpad sync and naming bug (conflict suffixes) | Recense/Sync | cause found | T1; A11 N2–N3 | 213, 239 |
| BD20 | New iOS location: Patent Law Corpus; handoff of Notability, Downloads, tmp | Gallery | pending | phase 5; Study; A11 N7 | 215 |
| BD21 | Summon opens Draftpad instead of Essentials (Bitwarden panel) | Recense | bug | — | 217 |
| BD22 | Extend a share link by 1 h / 1 d / 7 d / 30 d | Gallery | pending | B4 Share | 219 |
| BD23 | Recense closes while idle (not via hover-away) | Recense | **a crash; cause likely** | R15 | 221 |
| BD24 | Draftpad polish: home page auto-summary + TOC anchors; reopen to the default page; newest first; Ctrl-F; a trigger that works on Obsidian for iOS and Mac | Recense | pending | T1 first | 223, 239 |
| BD25 | Vocal extractor | Recense | unclear | owner detail | 225 |
| BD26 | Tile viewer kinetics on iOS (Exhibits › IMG_0280) | Gallery | pending | B4 viewer | 227, 231 |
| BD27 | Swap Revoke for Revert | Gallery | open question | owner | 229 |
| BD28 | Move files; upload AV as mp3/m4b; podcast-style interactive transcript; share from a timestamp so the recipient lands paused at that line | Gallery | pending (`?t=` doesn't exist) | presign + share API | 233 |
| BD29 | Select text anywhere (OCR) → AirDrop / save .md to Obsidian, Notability, DEVONthink | Gallery | pending | — | 235 |
| BD30 | Share link vs AirDrop md/pdf; open a shared timestamp in Recense and Gallery | Gallery/Sync | planned | A4 (Sync owns links), B4 | 237 |
| BD31 | Own mail client (iCloud/Proton/Gmail/Outlook), rules, attachments → R2 | new | deferred | outside the north star | 241 |
| BD32 | Gallery UI hybrid (Podcasts/Finder/Photos/shared album); annotate at a timestamp; notes field | Gallery | planned | Part B | 243 |
| BD33 | Guiding principles (end-to-end argument, Saltzer–Schroeder, Solid, OCFL, fixity, confidence, explicability; no events for request/response) | cross | applied | A4, A5, B7 | 246–268 |
| BD34 | SQLite + Stripe API ergonomics | Sync | applied | A4 (`opId` idempotency keys; SQLite on devices); A12g | 273 |
| BD35 | End-to-end AirDrop and cloudless offline file continuity | cross | planned | A11 N8; A12g (peer-to-peer) | 17 |
| BD36 | "I read half a word and guess the rest: ADHD, or am I stupid? Be honest" | owner | answered | A12h | 36 |
| BD37 | Audit for a cloudless setup: DEVONthink Server + Tailscale, offline maps, FMEA, two spend scenarios, donor codebases, two schools of thought, dual-citizen payoff, resources | cross | answered | A12 | 44 |
| BD38 | `ledger.mjs` and the canary: keep or abandon? | Sync | answered: keep | A12h | 46 |
| BD39 | How to handle patent-law documents | cross | answered | A6 | 49 |
| BD40 | Offline downloads | cross | planned | A12a (pinned offline) | 51 |
| BD41 | Buy a Crucial X10? | owner | answered: yes, once | A12h | 53 |
| BD42 | **Obsidian everywhere; tmp on every device (top item, 11-04)** | Sync/Gallery | planned | A11 | 55, 58 |
| BD43 | Recense ambidextrous dual sidebar; embedded web widgets (Find My, Mail) | Recense | planned | B4; SL7 | 60 |
| BD44 | Files must stay usable when Cloudflare closes the door; rebuild Gallery iOS? A better provider? | cross | answered | A4 second door; A12 | 62, 64 |
| BD45 | Dying code to retrofit or delete; share links offline; transcript storage requests | cross | answered | A12h | 68 |
| BD46 | Requests/day: offline media engine vs cloudless vs cloud vs both | Sync | answered | A12c | 70 |
| BD47 | One m4b standard for all uploads (Audiobook Builder) | Recense/Gallery | answered: small savings, except Safari loops | A7; A12h; A13 | 72 |
| BD48 | A space for your published work and readings, and its name | Gallery | decided: **Folio** | B3 | 74 |
| BD49 | en/fr/vi prosody datasets | Recense | answered: later; your own recordings first | A7 | 76 |
| BD50 | Reading list (Lea Ypi level); grading the 焦糖Radio episodes | owner | deferred: separate research session | — | 78 |
| BD51 | MacBook terminal from iPad/iPhone | owner | answered | A12h | 80 |
| BD52 | Reverse proxy / VPS: worth it? | Sync | answered: low | A12h | 82, 86 |
| BD53 | Cloudless vs one provider: cheaper? Higher quality? | Sync | answered: hybrid | A12c | 88 |
| BD54 | "Offline-first, and the network is an optimization, not a dependency" | cross | adopted as P0 | A4 | 102 |
| BD55 | Notation mod: add rests back | Recense | pending | R6; A5 m4b frame | 207 |
| BD56 | Replay and loop media endlessly with no Worker requests; test what the offline infrastructure adds | cross | planned | A13 | 10 (10:45 copy) |

**11-05 note** (`~/Developer/the 3-layer sync unification project is multimodal by nature, not…/….md`, 483 lines). Lines 1–152 are new. Lines 154–483 paste another tool's Gallery QA review and its Phases 1–4 plan; Phase 4 is reported done (120/120 viewer + 60/60 route tests), and that session tracks the rest.
| ID | Item | App | Status | Blocked by | Line |
|---|---|---|---|---|---|
| BD57 | One project: Recense as the parent of Sync, Gallery and the Mac app; one repo; regroup by feature; rename Nook to Recense; delete unused files; three CLIs in separate worktrees; `/recense player.js`-style commands; GitHub and front page | cross | planned | A15 | 1 |
| BD58 | "The app is broken"; ship it entirely in French or Vietnamese for people who download it in those languages | Recense; all | bug found (R16); i18n planned | R16; B11 | 3 |
| BD59 | Buttonless, gesture-driven comments, select, like, ask, "…" and download, keeping the social buttons visible | Gallery | planned | B9 | 5 |
| BD60 | Seed through someone else's connection: a link that works with no internet on your side | cross | answered | A17a | 7–8, 17 |
| BD61 | Audit the ask engine (cost, requests/day, network dependence) and choose the best model | Gallery/Recense | answered | A16 | 8–9 |
| BD62 | DEVONthink as the indexing layer for all files, reachable remotely; verdicts on your claims; effect on the ask agent | cross | answered | A16 | 10–14 |
| BD63 | Retrofit Gallery into an offline library without changing the UI; offline downloads and per-play queues | Gallery | planned | A13; A17e | 18–19 |
| BD64 | Text on any file → m4b; offline trilingual; offline audio summaries at every granularity; audio descriptions and sonified data; download any audio or video | cross | planned | A7; A16; A17e; B10 | 20–24 |
| BD65 | Writing continuity across ecosystems ("sync chameleon"); a super app vs a suite | cross | answered | A17d | 27, 149–150 |
| BD66 | Assume offline even when online; burst-sync; push share links through other connections; fallbacks; offline edits with version history | cross | answered | A17b | 29 |
| BD67 | Find and exploit iCloud glitches | Sync | answered: no (use the behaviour, not the bug) | A17c | 30, 146 |
| BD68 | One global speed control in Recense | Recense | planned | B9 | 32 |
| BD69 | Over-the-ear "textures" on the QC35 and skin-felt haptics to emphasise key words | Recense/Gallery | planned | B10 | 33, 131, 143 |
| BD70 | Haptics research; your accessibility profile (ambidexterity, ADHD, OCD, visual delays, colour blindness…); haptics for legal reading | cross | planned | B10 | 35–82 |
| BD71 | Ambidextrous, buttonless, hand-neutral gestures for the player and the mixing console; replace the two home bars; edge gestures; detents | Gallery/Recense | planned | B9 | 85–131 |
| BD72 | Draft layer renovation: self-updating TOC, m4b, offline queue, one page across pencil, keyboard, touch and voice; Recense on iOS; host or branch | Recense | planned | A17d | 133–139 |
| BD73 | Grade how efficiently lyrics are retrieved | Recense | answered | R17 | 141 |
| BD74 | "Help me understand what I have": anchoring yourself in a wall of text | owner | planned | B11 | 152 |
| BD75 | Another tool's Gallery QA review and Phases 1–4 | Gallery | in progress elsewhere | its own session | 154–483 |

## A4. Decisions (with rejected alternatives)
| Question | Decision | Rejected |
|---|---|---|
| What Sync owns | The **protocol** (manifest, changes feed, batch commit, presign), **share links**, **handoff cursors**, the **budget/breaker policy**, the Mac jobs (launchd) and specs/runbooks. This is organism.md's option H5: the engine moves from Gallery to Sync (`sync/docs/specs/organism.md:81-90`; owner confirmation pending). Gallery = library + player UI. Recense = ASR, translation and cadence engines on the Mac | Sync as a UI app; folding the three apps into one |
| Cloud | **One cloud (R2 + one thin Worker), ready to leave:** open formats, sha256 inventories, rclone-compatible paths (swap provider in a day), client matters reach it only as Arq ciphertext, plus an offline copy on an owner disk (A12) for 3-2-1 | Multicloud (twice the auth and cost for one user); paid EU "sovereign" providers (not free); Workers Paid (owner: free only) |
| Serverless vs box | Serverless now. A **gated relay box** (Pi 5 or N100 + SSD ≈ $200 once, ≈ $9/yr power) only if, after phase 4, the normal day exceeds 10k requests, or R2 exceeds ≈ $5/month (≈ 343 GB), or the Mac's job backlog exceeds 7 days | A box now: ops burden, home uplink, and it doesn't fix the real bleed (WebDAV bisync, media through the Worker) |
| Shared data layer | **Extend what's built:** the `fp.js` catalog (`.catalog/<root>/snapshot.json` + `log/<seq>.json`; its reconciler sees writes that bypass the Worker) and the `event-log.md` hash-chained format, applied to every root.<br>Endpoints:<br>• `GET /v1/manifest` (ETag/304 across all roots)<br>• `GET /v1/changes?root=&since=`<br>• `POST /v1/commit` (ordered ops, `opId` idempotency keys in Stripe's style)<br>• `POST /v1/presign`<br>Clients: one Swift package (Gallery iOS/Mac, Recense) + one JS module (web). R2 only | D1 (owner: "Do not introduce D1", `gallery/notes/20261029-152324.md:1621`); Durable Objects (owner: only for presence/co-editing, `gallery/CLAUDE.md:16`); KV (1k writes/day) |
| Where events fit | The change log is the event stream. Mac jobs react to it (new audio → transcribe; new transcript → m4b). Commit, presign and manifest stay plain request/response, so events never stand in for RPC (Idnani, InfoQ) | Queues or an event bus for request/response |
| Handoff | One cursor JSON per device in `keep/listen/` (the existing `handoff.swift` layout). Written with a cached presigned PUT on pause/background, read with a presigned conditional GET on foreground: 0 Worker requests. LAN Bonjour as a fast path. Apple Handoff can't include Recense: it needs a shared Team ID and Recense is self-signed ([Apple](https://developer.apple.com/documentation/foundation/implementing-handoff-in-your-app)) | NSUserActivity; push (no APNs on the free team) |
| Principle P0 | "Offline-first, and the network is an optimization, not a dependency" (brain dump line 102). Every feature states what it does with no network | — |
| Owner devices vs the Worker | **The second door:** Gallery iOS/Mac, Recense and the Mac jobs reach R2 directly over the S3 API. Each device has its own bucket-scoped key in the Keychain (Recense's SigV4 signer, `recense/recense/recense.swift:5867-5890`). The Worker serves share links, the web app, CalDAV, manifests and commits. A lost device loses only its own key | Owner devices that need the Worker for every byte (today) |
| Client matters | Two DEVONthink 4 databases (4.4.1 is installed) on the Mac, whose disk FileVault encrypts:<br>• **Matters** syncs to iPhone and iPad over the home network.<br>• **Sealed** is encrypted and stays on the Mac (A6, corrected 11-05).<br>Arq (client-side encrypted) is the off-site copy. Gallery and Recense never index or link them | A custom end-to-end-encrypted vault in Gallery: new crypto, key pairing and recovery to build and audit |
| Notes | One sync engine per folder. iCloud carries the vault now (A11), and its R2 copy comes from the ledger's read-only journal. If iCloud is dropped later (G1), switch to Remotely Save → R2 `notes` over S3 | Two engines on one folder (today bisync + iCloud: the cause of T1) |
| Home hub | The Mac, for now: `rclone serve webdav` (already installed) shares its library on the home network, advertised over Bonjour. An always-on box only if the triggers above fire | A VPS or a reverse proxy (A12h: low value) |

**Reuse map**
| Need | Reuse (file:line) | Extend / create |
|---|---|---|
| Changes feed + cursor | `gallery/gallery/src/fp.js:3-11,213-247` (`changes?since=`, 410 on an expired anchor), reconciler `fp.js:270-355` | extend to all roots + root-manifest ETag |
| Daily budget | `gallery/gallery/src/ai.js:345-372` (per-UTC-day budget file in R2) | extend into the request budget |
| 429 / Retry-After | `transcript.js:284,327`, `dav.js:556`, `identity.js:297` | add 1027 handling + a client breaker |
| Optimistic concurrency | `dav.js:226-232,278`, `sync/worker/src/caldav.js:180-191`, `main.js:103,778`, `listen.js:52-80`; client `client/gallery.js:379-386` | same pattern for `/v1/commit` |
| Presigning | Recense SigV4 signer `recense/recense/recense.swift:5867-5890` | Swift package; the Worker uses aws4fetch (new) |
| Outbox | `main.js:545-566` (localStorage replay), `recense.swift:786-822,5736` (ETag merge, ifAbsent/ifMatch), `Listen.swift:171-173` | durable ordered outbox with `opId` |
| Hash-chained journal | `sync/src/ledger.mjs:23,332,613` (+ `views/health.json`) | Matters export journal, only if counsel asks; health feeds the sync pill |
| Handoff records | `recense/recense/handoff.swift:1-12,48-66,106-114` (`keep/listen/`) | cursor schema with word index; surface conflicts |
| CalDAV | `sync/worker/src/caldav.js` (ctag only) | add sync-token (RFC 6578) |
| Probe + lock | `sync/bin/docs-sync.zsh:28-36,47` | breaker for the Mac jobs |

## A5. Data model
| Entity | Layout / key fields | Conflict rule |
|---|---|---|
| Existing files | Stay path-addressed (`files/<path>` etc.; no migration). The catalog snapshot gains `sha256` and becomes the OCFL-style inventory. Replaced bytes move to `.versions/<path>/<n>` (today they go to trash, `gallery/gallery/docs/architecture.md:95,98`) | ETag + If-Match per op. On mismatch, keep both as versions plus **one** deterministic sibling name `Name (conflict <device> <yyyy-mm-dd>).ext`; idempotent, so no chains |
| New derived media (m4b, stems, renders) | Content-addressed `u/<userId>/blobs/sha256/ab/<digest>` | immutable |
| Change log | `.catalog/<root>/log/<seq>.json` {seq, events[{op, path, etag, sha256, opId, hlc, device}], prevHash} | append-only; `opId` dedupes replays |
| Root manifest | `{roots: {main, archive, keep, notes, cal, listen, share: {seq, etag}}, budget}` | derived by the server |
| Calendar/contacts | CalDAV/CardDAV on Worker `sync` | ETag + If-Match; add sync-token |
| Notes (Obsidian, Draftpad) | Markdown | one sync engine per folder; 3-way merge against the base version, otherwise one sibling (above) |
| Transcript layers `keep/<key>/` | asr.json (per run), tr/<lang>.json, corrections.json, features.json (existing) | asr immutable per run; tr regenerated from `src`; corrections last-writer-wins per segment + field, with a divergent `from` shown as a conflict; features recomputed |
| m4b sidecar `m4b/<contentHash>/manifest.json` | **frame:** count-in, stinger, cue tone, pre-rest fill, 4/8-bar phrases<br>**sections:** tempo, felt tempo, key, groove, kit, loop, adlibs, seed = hash(content, section, variant), ≤ 3 variants, pin<br>**triggers:** word, segId, wordIdx, tMs, downbeat, sustainBeats, responseSlot {bar, beat, beats, who}<br>**also:** termRhythms in beats, stem digests, recipeHash | variant/pin last-writer-wins per section; stems immutable; per-device latency stays in device prefs |
| Matters (client data) | In DEVONthink, never in Gallery's R2 tree: groups Client → Matter (tags: docket, status, retention, hold) → Document, and DEVONthink keeps the versions. Audit: Arq's backup history + DEVONthink's log; add a hash-chained export journal (`ledger.mjs`) only if counsel asks | never auto-merged |
| Study | Source (MPEP/USC/CFR/case); Question {stem, trigger words, confusable pair}; Attempt {answer, correct, confidence, t} | append-only |
| Handoff cursor | `keep/listen/<device>.json` {item, positionMs, segId, wordIdx, rate, playing, hlc} | last-writer-wins by HLC; offer "Continue from iPad" rather than jumping silently |
| Share link | {id, scope (item or folder), expiresAt, opens} | server-authoritative; Matters documents are never in Gallery, so they can't be linked |

| Tier | Where | Who reads | Links | Cloud processing | Encryption |
|---|---|---|---|---|---|
| **Matters** (clients), with **Sealed** (a second, encrypted database for IDs, medical and financial records) | DEVONthink on the Mac. Matters is also on iPhone and iPad through home-network sync. Off-site only as Arq ciphertext in R2 | owner devices only | never | the on-device model only (A16) | FileVault, iOS data protection and the sync key. Sealed adds DEVONthink's AES-256. Arq encrypts client-side. Recovery passphrase on paper |
| **Private** | Main `files/…` | owner | per item, expiring | allowed | R2 at rest (Cloudflare keys) |
| **Folio** (your published work + readings you had access to) | Main `files/Folio/Authored/` and `files/Folio/Readings/`, pinned offline on the Mac and iPad | owner | Authored: per item; Readings: never (licences) | allowed (personal search only) | R2 at rest |
| **`/main/share`** (social NAS) | shared galleries | owner + link holders | default 7 days, 30 max | allowed | R2 at rest |

## A6. Law-practice requirements (verified where possible; the rest are flagged)
| Requirement | Source | Status | Design response | Check with a lawyer / ethics counsel |
|---|---|---|---|---|
| Reasonable efforts against inadvertent or unauthorized disclosure or access | USPTO 37 CFR 11.106(d) | VERIFIED ([LII](https://www.law.cornell.edu/cfr/text/37/11.106)) | Matters: FileVault, the encrypted Sealed database, sync on the home network only | Confirm which rules bind you (USPTO registration, state bar) |
| The same duty for state-bar lawyers | ABA MR 1.6(c); Oregon RPC 1.6(c) | ABA known; Oregon adoption ASSUMED | same | Yes |
| Cloud storage is allowed with vendor diligence: confidentiality terms, breach alerts, backup practices, periodic re-review | OSB Formal Op. 2011-188 (rev. 2015) | VERIFIED via summaries ([OSB PDF copy](https://inns.innsofcourt.org/media/50884/ethicsop2011-188.pdf)) | vendor-review record (R2, Arq, DEVONthink); client-side encryption reduces the trust needed in the vendor | Yes |
| Risk-based safeguards; encryption for highly sensitive data | ABA Formal Op. 477R | VERIFIED via summaries ([PDF](https://dev.americanbar.org/content/dam/aba/administrative/professional_responsibility/ethics-opinions/aba-formal-opinion-477.pdf)) | the Matters tier | — |
| Gen-AI on client information: informed consent for self-learning tools; boilerplate isn't enough | ABA Formal Op. 512 (2024-07-29) | VERIFIED via summaries ([ABA](https://www.americanbar.org/groups/litigation/resources/newsletters/ethics-professionalism/generative-ai-lawyers-part-2-maintaining-confidentiality/)) | Matters: on-device processing only (a local model at most); Workers AI's data use is ASSUMED to exclude training (verify) | **Yes: Raven is already indexed** |
| Electronic-only client files | OSB Formal Op. 2016-191 | ASSUMED (title only) | export + retention | Yes |
| Retention period / destruction | OSB PLF practice aids | ASSUMED | per-matter retention tags; legal hold = a frozen PDF/A export under a bucket-locked R2 prefix | Yes |
| Breach response duties | ABA Formal Op. 483 | ASSUMED | audit log + incident runbook | Yes |
| Export control of unpublished application technical data in the cloud | 37 CFR 5.11; 15 CFR 734.18 (end-to-end-encryption carve-out) | ASSUMED (operative text not retrieved) | encrypted database, US storage; ask before carrying client technical data abroad (dual-citizen travel) | **Yes (critical)** |
**Immediate (owner decision, no code):**
- Raven client matters (29,354 files / 30.36 GiB) sit in Main and are indexed by Workers AI + Vectorize.
- Exclude `files/Raven/` from AI indexing and from share links, and remove its vectors (owner approves).
- Move Raven into the Matters database only after the checks above, then delete it from Main.

**Matters mechanics (reuse; no new crypto):**
- **Store (corrected 11-05):** two DEVONthink databases on the Mac, whose disk is encrypted by FileVault (on, checked 11-05).
  - **Matters** is a normal database, so DEVONthink To Go can carry it.
  - **Sealed** is an encrypted database (AES-256) for IDs, medical and financial records. It stays on the Mac, because encrypted databases can't sync to DEVONthink To Go.
- **Reach:**
  - At home, iPhone and iPad sync Matters over Bonjour, which is encrypted by default, with a sync key set and DEVONthink To Go's passcode lock on.
  - Away from home, Bonjour can't cross Tailscale (A16d), so the phone works from its last synced copy, offline.
  - If you need remote sync later, add a WebDAV sync store on the Mac that is reachable only over Tailscale and carries an AES-256 sync key, or use the Server edition's web interface over Tailscale.
  - Never a cloud sync store (iCloud, Dropbox), never a share link.
- **AI:** both databases use Apple's on-device model as DEVONthink's AI provider (Pro edition), never a cloud provider (A16).
- **Copies:** Arq (client-side encrypted) to R2 and to the SSD; a recovery passphrase on paper.
- **Processing:** none in the cloud; a local model at most (SL4).
- **Retention and hold:** retention tags per matter. A legal hold is a frozen PDF/A export under a bucket-locked R2 prefix.
- **Export:** DEVONthink's export to plain files + an inventory.

**Patent-law documents (brain dump line 49):**
| Kind | Where | AI | Shareable |
|---|---|---|---|
| Public law: MPEP, 35 USC, 37 CFR, PTAB and court decisions | Study (Patent Law Corpus) | yes | yes |
| Your notes, outlines, question sets, m4b study sets | Study | yes | yes |
| Client files: applications, office actions, correspondence (Raven) | Matters | local only | never |
| Unpublished applications and technical data | Matters, US storage, encrypted | local only | never; ask before travelling with them |

## A7. Audiovisual efficiency (keep it cheap)
| Stage | Where | Trigger | Cost control | Reuse |
|---|---|---|---|---|
| ASR (en/fr SpeechTranscriber, vi DictationTranscriber, other languages Omnilingual) | Mac only (the iPad runs iPadOS 18.6: no SpeechAnalyzer) | new audio in the change log; idle + on AC power + thermal state nominal | content key (size + sha256 of the first/last 64 KiB): never transcribe the same content twice | `Episode.whisper()` seam, `ContentKey`, `GalleryJob` idle-only |
| Translation en/vi/fr + transliteration | Mac, on-device (Groq removed 10-30, `sync/PROGRESS.md:750-755`) | after ASR, when idle | skip unchanged lines by their `src` digest | `Keep.pushTranslation`, `r2KeepSent`, `canon.swift` |
| Stems (Demucs) | Mac, only for songs | on demand + idle (never while benchmarking; 8 GB RAM) | keep stems local / in tmp/ for 2 days; ship `features.json` instead of stems | `features.json`, `Cadence` |
| m4b build: narration + beat | Mac | on demand; pre-generate the next section during playback (≤ 2 ahead; stop below 30 % battery, `sync/PROGRESS.md:406`) | deterministic seed → cached by recipeHash; ≤ 3 variants per section | Apple premium voices on-device (free); Azure only for Study text, never Matters,, within its free tier (ASSUMED) |
| Beats | Mac | with the m4b | V1: one procedural groove from a CC0 sample kit, no ML. V2: seeded variation. V3: accuracy-driven density (the owner's build order) | brain-dump frame/variation layers |
| Upload | presigned PUT straight to R2 | after the build | skip if the blob hash exists; multipart above 100 MB | — |
| Playback on iPhone/iPad | presigned GET once, then offline cache | pinned folders or user choice | Range requests via presigned URLs (0 Worker requests) | — |
| Fixity | Mac, monthly, sampled | idle + AC | Class B GETs only; compare against the inventory sha256 | `ledger.mjs` |
| Markdown → m4b (brain dump line 44) | Mac, offline | on demand | Apple premium voices on-device → m4b with chapters from the headings (Audiobook Builder is installed; ffmpeg for scripted runs) → local library. Uploads wait for a network | Recense TTS, `features.json` |
| One m4b standard for every upload (line 72) | — | — | **Small request savings:** requests count operations, not bytes. The exception is looping on Safari with effects on: compressed audio loads once and loops free, while WAV/AIFF re-streams on every pass (A13a). Use m4a/m4b for study audio, and loop compressed files until A13 L1 ships | — |
| en/fr/vi prosody data (line 76) | Mac, local files | V3 | 0 requests. Start with your own shadowing recordings of the 20 confusable pairs; add public corpora after a licence check. Vietnamese is tonal, so a beat never bends its pitch: sustain by length and loudness | Recense prosody, R6 |

## A8. Request counter + breaker (wired to S4)
- **Client counter:**
  - Kept per device, persisted per UTC day. It counts Worker requests only; presigned R2 traffic is excluded.
  - Soft limit 15k: defer prefetching and background work.
  - Hard limit 30k (3 × 30k = 90k < 100k), or any 429 / Cloudflare 1027 page: the breaker goes **OPEN**. Whether 1027 arrives as status 429 is ASSUMED, so both are detected.
- **Server view, with no D1/DO:**
  - Each request writes one Analytics Engine data point (route, device, status).
  - The 10-minute cron totals today into `budget/<utc-date>.json`, using the `ai.js:345-372` pattern. The token it needs is set by the owner as a Worker secret.
  - Every manifest response carries that total, so account-wide limits (30k soft / 70k hard) switch every device into the same state.
- **While OPEN:**
  - Zero Worker requests; reads come from the cache.
  - Presigned R2 URLs still work, so media keeps playing.
  - Uploads continue into a pool of 20 presigned inbox slots per device (valid 7 days), committed after resume.
  - The pill reads "Paused until 4:00 PM" (local time).
- **Resume:** at 00:00 UTC plus 0–10 min of jitter, send one probe (the manifest). 200/304 → CLOSED, then replay the outbox in order. Otherwise OPEN again, honoring Retry-After.

## A9. Phased migration (safest first; each phase ships alone and can be switched off)
| # | Phase | Proves | Undo |
|---|---|---|---|
| 0 | A10 (config) + A11 (Obsidian everywhere) + the urgent rows (X1–X9, R15, R16, G20) + the deck fix (A13 L1) + the lyrics fix (R17) | S1 now; your top item; Recense stays open | restore the plists/scripts; move files back; revert L1 and the fixes |
| 0b | One repo (A15), on a quiet day with autoupdate and docs-sync paused | every app builds, tests and deploys from `louan-dev/recense` | the `pre-monorepo` tags and the old repos |
| 1 | Client counters, breaker, error catalog; one Analytics Engine data point per request; Workers Logs on; the loop-leak alarm (A13 L10); the ask fixes (A16c) | S4 + measurement | flag `breaker`; observability off |
| 2 | **The second door:** per-device R2 keys for Gallery iOS/Mac (Keychain; Recense's signer); presigned GET/PUT for the web and share pages, signed by the Worker with a bucket-scoped key the owner sets as a secret; Gallery.app's mount moves from WebDAV to S3; the local media store and loops from memory (A13 L2–L6); links minted offline (A17a) | S6, S8, S9 | flags `directR2` / `presign` → back to Worker streaming |
| 3 | Root manifest + changes feed for all roots; remove polling loops; CalDAV sync-token; File Provider `tmp` and `main` domains on iOS and Mac (A11 N7); events instead of timers and the Worker job on change (A13 L7–L9) | S3 | flag `manifest`; old endpoints kept |
| 4 | Durable outbox + ordered replay (Gallery iOS/Mac, web, Recense) | S2 | flag `outbox` |
| 5 | Handoff cursors + banner + LAN path, with peer-to-peer Wi-Fi on (A14); carry-and-forward through your own devices (A17a) | S7, S10 | flag `cursor`; `handoff.swift` paths unchanged |
| 6 | Inventories (sha256) + `.versions/` + monthly sampled fixity; Matters and Sealed into DEVONthink (after A6); the on-device ask with local indexes (A16c) | S5, A6 | additive files only |
| 7 | Notes: one engine per folder, base-version 3-way merge, one deterministic conflict name; the live page between nearby devices (A17c–d) | T1 | old bisync flags kept on a branch |
| 8 | Home hub: the Mac serves its library on the home network (`rclone serve webdav`, Bonjour); Recense hosts the peer-to-peer listener (A14); an always-on box only if the A4 triggers fire | works with no internet or router | stop the service |

**Simulation test (each phase must pass it before shipping)**
- **Harness:** `sync/tools/sim/` drives the Gallery Worker router with in-memory R2. It extends `gallery/gallery/test/routes.test.mjs` (check its bindings mock) and counts requests per route and per device.
- **Scenario:** 3 devices (Mac, iPad, iPhone) × 7 simulated days on a deterministic clock, with:
  - offline windows;
  - a 1027 at 09:00 on day 4;
  - a 10k-file import on day 3;
  - the **T1 case**: two devices edit one note while offline, then both reconnect.
- **Assertions:**
  - S1: daily totals ≤ 10k, and ≤ 40k on the import day.
  - S2: every op is applied once, in per-device order.
  - S3: a no-change sync costs exactly 1 request.
  - S4: zero requests while OPEN, then exactly one probe after 00:00 UTC.
  - S7: the cursor arrives within one foreground.
  - T1: no file name ever carries more than one conflict marker, and no text is lost.
  - S9: 10k loop passes per device per day add 0 Worker requests, and no R2 reads after each file's first fetch.

## A10. Do today: five reversible changes (1–4 on the Mac, no deploy)
| # | Change | Where | Saves/day | Undo |
|---|---|---|---|---|
| 1 | docs-sync: drop WatchPaths; StartInterval 600 → 3600 | `~/Library/LaunchAgents/com.chauphan.docs-sync.plist` (+ the `sync/launchd/` copy) | ~229 → 24 runs ≈ **−80k to −113k** | restore the plist; `launchctl bootout` / `bootstrap` |
| 2 | docs-sync: build INDEX (`lsf -R`, ~281 requests) nightly instead of every run | `sync/bin/docs-sync.zsh:91-97`, guarded by `[[ $(date +%H) == 03 ]]` | about −6k more | remove the guard |
| 3 | docs-sync: point bisync at the **existing S3 remote** (`jobs.conf` `gallery-main:`) instead of the Worker WebDAV. Do it after a `--dry-run` proves the key mapping, then one `--resync --resync-mode newer` run with `--backup-dir1`/`--backup-dir2` (a plain `--resync` lets Path1 win; this keeps the newer copy where both differ, saves the other, and deletes nothing). Add `--conflict-resolve newer`, so the newer copy keeps the name and the loser is renamed once, and `--fast-list` (S3 lists 1,000 keys per request; that bisync honours it is ASSUMED). The `fp.js` reconciler still sees direct writes (`fp.js:8-11`) | `sync/bin/docs-sync.zsh:42-47,80-83` | the rest of docs-sync → **0 Worker requests** and ≈ −115k Class A. S3 returns MD5s, which ends the "hash is missing" false conflicts | set `G` and the flags back |
| 4 | archive-mount: the same S3 switch (`gallery-archive:` is already in `jobs.conf`), or `--dir-cache-time 1h` | `sync/bin/archive-mount.zsh:12,31` | −0.3k to −2.2k | revert |
| 5 | Gallery cron `* * * * *` → `*/10 * * * *` (AI indexing is already capped at 120 steps/day) | `gallery/gallery/wrangler.toml` (deploy = commit + push) | −1.3k if cron runs count | revert |
**Result:** ≈ 95k–145k → **≈ 2k–4k requests/day** before any app change, plus ≈ 2.4k–4.4k while Gallery Files and Gallery.app are open (phases 2–3 remove both). Also set Apple Calendar's refresh to hourly on each device, and add `--no-traverse` to downloads-to-r2 (an empty run then lists nothing).

**Verify A10 (after the owner's go):** the next full UTC day's GraphQL total (A1 command) is under 5k (under 9k while the Gallery Mac apps stay open); `grep -c "hash is missing" ~/Library/Logs/docs-sync.log` stops growing (84 on 11-03); no new `*.conflict*` files appear in the vault; `launchctl print gui/$(id -u)/com.chauphan.docs-sync | grep -i interval` shows 3600.

**T1 (logged test case): the cause is confirmed.**
- **The command.** `sync/bin/docs-sync.zsh:80-83` runs `rclone bisync … --compare size,modtime --conflict-resolve none --conflict-loser num --conflict-suffix conflict --suffix-keep-extension --resilient --recover`.
- **What bisync does.** A note changed on both sides gets both copies renamed, to `.conflict1` and `.conflict2`.
- **Why the suffixes nest.**
  - Obsidian keeps the open note attached to the renamed file. At the next run that file looks changed on both sides again, so another suffix is added.
  - The deepest file is the original note (created 11-02 23:51:52), renamed nine times, one level per run (06:15 → 07:58).
- **Why "both sides changed" is mostly false.**
  - Uploads race the writer ("source file is being updated" ×10).
  - The Worker's WebDAV returns no checksum, so bisync can't prove two copies are identical ("failed to check as hash is missing", 84 log lines so far).
  - `--recover` compares against stale listings.
  - WatchPaths re-fires on bisync's own conflict files.
- **Draftpad.** `draftpad.md` reached `.conflict38` because Recense always rewrites one path (`recense/recense/app.swift:49,7555-7589`).
- **Ruled out.** Remotely Save is inert.
- **State of the vault.** It holds 11 variants and **no base file**, and **the chain is still growing**:
  - docs-sync's vault lane keeps succeeding (`ok` at 18:25Z, 18:41Z and 18:45Z on 11-04) while its Desktop lane fails with "empty prior Path1 listing".
  - While you typed the A13 request, the runs that ended at 18:41Z and 18:45Z split the note in two: `…conflict2.conflict2.md` (61,832 B, 10:40 PST) holds a half-typed "strengthen the replay logi", and `…conflict2.conflict1.md` (62,114 B, 10:45 PST) holds the full request. The two differ only in line 10.
  - Any save in the vault while docs-sync runs can split a note again, until A11 N2 lands. A11 N3 then cleans up.
- **Fix.** A10 #1 and #3 now; A11 N2–N3 next; phase 7 later.

## A11. Obsidian everywhere (your top item; brain dump lines 55–58)
**Goal:** every markdown file you make on the Mac, iPhone or iPad shows up, the same, in your Obsidian vault on all three, and `tmp` opens on all three. Free; 0 Worker requests; a few MB of iCloud. (Line 55's "save in Oregon" is read as "save in Obsidian".)

**Why it fails today**
| Cause | Evidence |
|---|---|
| iCloud is full, so the vault stops syncing and reads of evicted files fail | line 55 ("my iCloud is full again"); `sync/PROGRESS.md:120` (91.9 % vs the ≤ 75 % target); Y24 |
| Two engines write the vault: iCloud and docs-sync's two-way lane (T1) | `sync/bin/docs-sync.zsh:4,80-83` |
| Markdown made outside the vault (`~/Developer`, Desktop, Documents) is copied one way to Gallery Docs, never into the vault | `sync/bin/docs-sync.zsh:72-73` |
| `tmp` is on the Mac only: the File Provider registers just the Archive domain | `apple/HostApp/iOS/App.swift:8`, `apple/HostApp/macOS/main.swift:10` |
| Pasting a video gives "note not found", and media in the vault fills iCloud | line 55 |

**Steps** (N1–N6 and N8 are Mac-side settings and reversible; N7 is app work; N9 is a check)
| # | Step | How | Worker requests | Undo |
|---|---|---|---|---|
| N1 | Make room in iCloud (below 75 %) and keep the vault downloaded | `node ~/Developer/sync/src/ledger.mjs overflow --source <vault> --sink <sink> --max-mb 25 --total <plan>` lists what should leave (`sync/docs/runbooks/OVERFLOW.md:6`); move big files to Gallery Archive over S3; Photos originals follow Y10/Y11. In Finder, mark the vault **Keep Downloaded** so iCloud never evicts it (Y24) | 0 | move the files back |
| N2 | One engine per folder | Remove the vault and `~/Downloads` from docs-sync's two-way lanes and exclude `*.md` from its other lanes. The vault's R2 copy comes from `com.chauphan.ledger.obsidian`, healthy at 11-04 10:06Z | 0 (fewer) | restore the lanes |
| N3 | Clean up T1 | Diff the two newest brain-dump copies (on 11-04 they differ only in line 10), keep the newest as `20261102235159 Brain Dump.md`, and move the other variants (11 files in all on 11-04) and the `draftpad.conflict*` files into `_conflicts/2026-11-03/`. Nothing is deleted | 0 | move them back |
| N4 | Copy every markdown file into the vault | One Mac-only launchd job, every 5 minutes, runs three local `rclone bisync` pairs: `~/Developer`, `~/Desktop` and `~/Documents` ↔ `<vault>/Mac/<name>`. A `--filters-file` keeps `*.md` only, minus `.git/`, `node_modules/`, `.build/` and `backups/`. Flags: `--compare size,modtime,checksum --conflict-resolve newer`; one `--resync` the first time; no WatchPaths. An edit made on the iPhone flows back to the original file. iCloud carries the copies (a few MB) | 0 (disk to disk) | unload the job; move `<vault>/Mac/` out of the vault |
| N5 | New notes land in one place | Obsidian → Files and links → Default location for new notes: `Inbox/`. Draftpad stays one `draftpad.md` (SL3) | 0 | revert the setting |
| N6 | Prove it, Mac → iPhone → iPad | Reuse the canary: `swift ~/Developer/sync/tools/upload-status.swift "<vault>"` until 0 pending, then `node ~/Developer/sync/src/canary.mjs check --wait 60`. It passed once, on 10-13 (`sync/PROGRESS.md:516-518`) | 0 | — |
| N7 | `tmp` (and Main) in Files on iPhone and iPad | Register `tmp` and `main` File Provider domains next to Archive, after phase 3's manifest, so each costs ≤ 40 requests/day per device. downloads-to-r2 stays tmp's only writer | ≤ 40/day per device | remove the domains |
| N8 | Obsidian as the transit window again | Once N1–N4 hold, paste on one device and open on another. Universal Clipboard covers instant copy-paste between nearby devices | 0 | — |
| N9 | Media in notes | Keep video out of the vault and paste a Gallery link instead. Check whether the installed `images-uploader` plugin can send pasted media to the `notes-images` bucket, and which door it uses | check | — |

**Later (G1, if iCloud is dropped):** Remotely Save → R2 `notes` over S3 (installed, Y3; 0 Worker requests; works during a 1027), after phase 7, because the free plugin keeps the newer copy on a conflict (ASSUMED).
**Acceptance:** the canary passes. A new `~/Developer/<project>/notes/x.md` opens in Obsidian on the iPhone within the canary's 60 minutes, and an edit made there reaches the Mac original within the same window. No new `*.conflict*` file appears for 7 days. `tmp` opens in Files on both iOS devices.

## A12. The cloudless layer, failure modes and spend (brain dump lines 17, 44, 60–88)
**Verdict:** build local-first now. Your devices are the infrastructure and the free Cloudflare plan is the safety net: no new server, no payment.

**a. What keeps working where**
| Task | Home network, no internet | Worker closed (1027) | Everything up |
|---|---|---|---|
| Play or read pinned files | yes | yes | yes |
| Transcribe, translate, build m4b (Mac) | yes | yes | yes |
| Notes (Obsidian) | yes on each device; they meet again when the internet returns | yes | yes |
| Matters (DEVONthink) | yes: on the Mac, and phones sync at home | yes | yes; away from home, phones use their last synced copy (A6) |
| A file not yet on this device | from the Mac hub (phase 8) or AirDrop | yes, through the second door | yes |
| Calendar | cached; edits queue | cached; edits queue (CalDAV runs on the Worker) | yes |
| Share links for other people | no: AirDrop a file instead | no: AirDrop a file instead | yes |
| The web app on another computer | no | no | yes |

**b. Failure modes (FMEA)**
| Failure | Today | After the plan | Detected by | Residual risk |
|---|---|---|---|---|
| Worker closed (1027) | mounts and iOS apps stop; raw error pages (B2 #1) | "Paused" pill; device keys keep files moving; the outbox replays after 4 PM | breaker (A8) | low |
| Cloudflare-wide outage | everything in the cloud stops | behaves like "no internet" below | the pill | low–medium (Cloudflare has published multi-hour outage post-mortems) |
| No internet | streaming apps fail | pinned files, notes, Matters and Mac jobs keep working (a) | the pill | low |
| Power cut | Mac jobs stop | the same; jobs resume and catch up (`opId` makes replays safe) | launchd at boot | low |
| Mac lost or dead | it holds the only full copy of local work | restore from R2, Arq and the SSD; the iPad keeps its pinned files | — | medium until the SSD exists |
| iPhone lost | the bundled token gives full access (B2 #15) | revoke that device's key; nothing else changes | you | low |
| iCloud full | the vault stops syncing; evicted reads fail (Y24) | `ledger.mjs overflow` warns before 75 % (A11 N1) | ledger health | low |
| Free-team signing expires (every 7 days) | iOS apps stop launching | `resign-ios` weekly, or the $99/yr account (d) | launchd exit code | medium on free; none on paid |
| Forgotten password (DEVONthink, Arq) | — | recovery passphrase on paper, kept apart from the devices | — | low |
| Sync conflict | nested suffixes (T1) | one sibling file and a "Conflict" pill | the pill | low |
| Disk or flash failure | SanDisk-style loss | 3-2-1: device + SSD + R2, with monthly fixity | fixity (A7) | low |
| Cloudflare account suspended | the cloud copy is out of reach | restore from the SSD and Arq to any S3 provider; open formats and inventories make it a day's work | — | low–medium |

**c. Requests by architecture (lines 70, 88)**
| Architecture | Worker req/day | R2 Class A/day | Monthly | Survives 1027 | Survives no internet | Survives losing the Mac |
|---|---|---|---|---|---|---|
| Today | 95k–145k | ≈ 125k | ≈ $1 storage + ≈ $11 operations | no | no | partly |
| Cloud done right (phases 1–7) | ≈ 720–1,020 | ≤ 10k | ≈ $1 | yes | pinned files only | yes |
| Cloudless (devices + SSD) | 0 | 0 | $0 + an SSD | yes | yes | only with a disk kept elsewhere |
| **Hybrid (phases 1–8): recommended** | ≈ 720–1,020 | ≤ 10k | ≈ $1 + an SSD once | yes | yes, at home | yes |
The Mac's media engine (Recense) costs 0 Worker requests in every row. Its ≈ 4.3k R2 lists/day drop to ≈ 2.9k when the 60 s lock polling goes (h, line 68), and to near zero once it reads the change log (phase 3).

**d. Two reports: willing vs unwilling to pay (line 44)**
| Item | Willing to pay | Unwilling to pay |
|---|---|---|
| Notes | Obsidian Sync ≈ $4/month (ASSUMED) as the vault's one engine | A11 (iCloud + ledger); Remotely Save later |
| iOS apps | Apple Developer Program $99/yr: no 7-day expiry, TestFlight, Handoff, push | free team + `resign-ios` |
| Quota insurance | Workers Paid $5/month: not needed after A10 | the breaker (A8) |
| Local copies | a Crucial X10 SSD, once | an existing disk |
| Off-site | R2 ≈ $1–2/month | R2 under 10 GB, plus a second disk at a relative's, swapped monthly |
| Never worth it | VPS, reverse proxy, NAS, paid "sovereign cloud" | — |
| **Ceiling** | ≈ $160–170/yr + one SSD | $0/yr (+ an SSD if possible) |
**Is any of it a scam?** No, but most of it is unnecessary. You already own rclone, Arq, DEVONthink, Tailscale, Audiobook Builder and Obsidian, and Workers Paid only treats a symptom that A10 removes. The one payment that changes daily life is the $99 Apple account.

**e. Choices that compound (dual citizenship, line 44)**
| Choice | Payoff |
|---|---|
| Open formats + sha256 inventories | readable by any tool, in any country, for decades |
| Local-first devices + an SSD | works on a plane, abroad and during outages |
| Tailscale | reach the Mac from anywhere with no open ports |
| R2 jurisdiction-restricted buckets (EU; check availability on free) for personal data, if you move | data residence can follow you; client patent data stays in the US, encrypted |
| en/vi/fr strings from day one | the apps already speak each country you might live in |

**f. Donor codebases (line 44)**
| Project | Licence · origin | Verdict |
|---|---|---|
| rclone | MIT · UK | keep: it is already the donor (bisync, serve, mount, crypt) |
| Litestream | Apache-2.0 · US | only if a device's SQLite ever needs streaming backup to R2 |
| Automerge | MIT · Kleppmann's research group | phase 7, only if the 3-way merge falls short |
| PocketBase | MIT · Bulgaria | only if a local server with accounts is ever needed |
| Syncthing | MPL-2.0 · Sweden | skip: no official iOS client |
| Seafile | AGPL (server) · China | reference only |
| SiYuan | AGPL · China | no |
| AList → OpenList | AGPL · China | avoid: AList changed owners in 2025 (reported; ASSUMED) |
| nginx / Angie | BSD-2 · Russian origin | not needed (no reverse proxy) |
Rule: adopt whole, maintained tools behind open protocols (S3, WebDAV, CalDAV, SQLite); never transplant parts of their code. Check each licence before adopting.

**g. Two schools of thought (line 44)**
| School | Borrow | Where it lands here |
|---|---|---|
| Boring and proven | LOCKSS (Stanford: "lots of copies keep stuff safe"), 3-2-1 backups, plain files + checksums, SMTP store-and-forward (1982), rsync (Tridgell, ANU) | inventories, fixity, the outbox, rclone: compound interest for data |
| Hidden gems | Network.framework peer-to-peer over AWDL (AirDrop's radio link), the SQLite session extension (changesets), `sqlite3_rsync` (SQLite 3.47, 2024), `NSFileVersion` (iCloud's own conflict versions), Stripe's dated API versions + idempotency keys | the LAN path (phase 5), device stores, the conflict UI, `/v1/` with `opId` |

**h. Verdicts, by brain-dump line**
| Line | Question | Verdict |
|---|---|---|
| 36 | "I read half a word and guess the rest: ADHD, or am I stupid?" | **Not stupid.** Skilled readers predict words from partial views all the time (Rayner 1998, *Psychological Bulletin*). Committing to the guess before checking it is a speed–accuracy trade-off that impulsivity can tilt; only a clinical evaluation can say whether ADHD is part of it. Careful reading is slower by nature: silent reading averages ≈ 238 words a minute and reading aloud ≈ 183 (Brysbaert 2019, *Journal of Memory and Language*), and for statutes the slower pace is the right one. The design slows the commit, not you: trigger-word emphasis, attempt before reveal, the focus window (B6) |
| 44, 66 | DEVONthink Server + Tailscale? | **Not yet (corrected 11-05).**<br>• Phones sync at home over Bonjour, which can't cross Tailscale (A16d).<br>• If you need remote access, the Server edition's web interface over Tailscale is the option: a Tailscale ACL that admits only your devices, a strong password, no open ports. The upgrade costs $299–399.<br>• No reverse proxy |
| 44 | Offline maps: OpenStreetMap or Moovit? | Apple Maps offline areas (iOS 17+) day to day; Organic Maps (OpenStreetMap, fully offline) as the backup. Moovit: no (its offline support is limited; ASSUMED) |
| 44 | Can everything run offline? | Yes, except share links, the web app on other computers, and files not yet on the device (a) |
| 46 | Keep `ledger.mjs` and the canary? | **Keep both.** The ledger has 34 selftests and is healthy for the vault (11-04 10:06Z); fix its iCloud Drive sink (Y24). The canary becomes A11's acceptance test |
| 53 | Buy a Crucial X10? | **Yes, once.** This M1's USB runs at 10 Gb/s (≈ 1 GB/s), not the drive's 20 Gb/s. It is a copy, never the only copy |
| 55 | How much does Downloads → tmp cost? | Little: it uses S3, so 0 Worker requests and ≤ 480 R2 lists/day ≈ 1.4 % of the free Class A tier. Add `--no-traverse` so an empty run lists nothing |
| 62, 64 | Rebuild Gallery iOS, or change provider? | Neither: make the same app local-first on the same provider, with pinned offline files, the second door and the outbox (phases 2–4) |
| 68 | Which code dies? | **Retire:** WebDAV for the Mac jobs, media through the Worker, polling loops. **Retrofit:** WebDAV moves to the Mac hub (`rclone serve webdav`) for the home network. **Share links** stay on the Worker; AirDrop is their offline twin. **Transcripts:** `keep/<key>/` stays; its 60 s lock polling goes (≈ −1.4k lists/day). **Delete (owner):** Ollama ≈ 3 GB (G14), the 191 MB zip (R12), `/tmp/g15` (G10) |
| 72 | One m4b standard to save requests? | Small savings: requests count operations, not bytes. The exception is looping on Safari with effects on, where WAV/AIFF re-streams on every pass and m4a/m4b loads once (A13a). m4b becomes the playback standard for study audio; uploads dedupe by hash, use one PUT (multipart above 100 MB), and keep the local copy until the checksum matches |
| 74 | A name for the academic space | **Folio**: short, no other space starts with F, and the same word in French. Folder `Main/Folio/` with `Authored/` and `Readings/`, pinned offline |
| 76 | Prosody datasets now? | Not yet: your own recordings first (A7). Vietnamese is tonal, so beats never bend pitch |
| 78 | Reading list; grading 焦糖Radio | A separate research session; Recense transcribes the episodes first |
| 80 | The Mac's terminal from the iPad or iPhone | Turn on Remote Login, then `ssh <mac>.local` at home or the Mac's Tailscale address away, from any iOS SSH client. No port forwarding |
| 82, 86 | Reverse proxy or VPS? | Low value: one more server to patch and pay for, and it fixes nothing A10 doesn't. Revisit only if the A4 box triggers fire |
| 88 | Cloudless or one provider: cheaper? better? | Hybrid (c): the devices do the work; R2 keeps the off-site copy and the share links |

**i. Learn, and questions for your cousin at Apple (line 84)**
| Learn | For |
|---|---|
| MIT 6.033 Computer System Engineering (OCW) | the end-to-end argument, naming, fault tolerance |
| Kleppmann, *Designing Data-Intensive Applications* | replication, logs, conflicts |
| MIT 6.5840 (was 6.824) Distributed Systems lectures | replication and consensus in practice |
| Kleppmann et al., "Local-first software", Onward! 2019 (ACM) | the seven ideals this plan follows |
| Harvard CS50 | foundations, if wanted |
| WWDC File Provider sessions (2017 for iOS, 2021 for macOS) | the file layer Gallery uses |

Ask your cousin:
1. File Provider: how do we keep pinned files from being evicted, and should conflicts surface through `NSFileVersion`?
2. What limits apply to background peer-to-peer (Network.framework over AWDL) between one person's devices?
3. Can a free-team iOS app share Handoff or a Keychain group with a self-signed Mac app, or is a shared Team ID required?
4. Which SpeechAnalyzer locales run fully on-device on iPadOS 26?
5. Which survives an app quit for uploads: background URLSession, BGProcessingTask, or both?

## A13. Media loops at zero Worker requests (owner follow-up, 11-04; brain dump line 10 of the 10:45 copy)
**Goal:** replay a line, loop a segment or repeat a track as many times a day as you like for 0 Worker requests and at most one R2 read per file per device, online or offline. The same rule covers the loops that look after media in the background and the Worker's own job: cost follows changes, never the clock.
**Principle P1:** pay per change, never per pass. A loop pass is a local operation (memory or disk); the network moves a file once, when it is new or changed.

**a. What a loop costs today (read-only audit, 11-04)**
| Surface | How it loops | Bytes from | Worker requests per pass (10 s A–B / 3-min track) | Verdict |
|---|---|---|---|---|
| Web, Chrome | Track Loop sets `el.loop` (`client/gallery.js:1755-1761`); A–B seeks back on every frame (`:1707-1732`); a transcript tap seeks (`:4941-4944`); the timing editor loops a word or a line (`:5332-5339,5418-5426`) | Worker routes `/f/`, `/main/f/`, `/d/`, `/m/` → `serveObject` (`common.js:50-135`): `private, max-age=3600`, ETag, no 304 | 0 / 0 within the hour, then a full re-download (no 304 handling) | fine, with an hourly leak |
| Web, Safari or the iOS app's web view, no effects | the same | the same; WebKit's disk cache won't store media loads | ≈ 0–1 / ≈ 1–2 (estimate; S9 measures it) | small leak |
| **Web, Safari with EQ, Key, Room or vocal isolation on (or iOS volume < 100 %), WAV/AIFF** | `openSound` streams ≈ 1.49 s Range chunks and drops those behind the playhead (`client/gallery.js:1264-1314,2382-2421`) | Worker | **≈ 9–10 / ≈ 121**: ≈ 3,400 requests per hour on a 10 s loop, ≈ 2,400 on a track | **wasteful by design** |
| The same, compressed audio | one 128 KiB probe + one whole-file GET, decoded in memory (`:1265,1298`) | Worker | 0 / 0 after those two | fine |
| Gallery iOS/Mac app | the web player in a WKWebView; its `SchemeHandler` forwards every Range GET to the Worker through a default URLSession that stores no 206s (`apple/HostApp/iOS/Player.swift:1-40,90-107`) | Worker | as Safari | leak; **nothing plays offline** |
| Gallery File Provider | downloads on demand and can be evicted (no `contentPolicy`, `apple/Extension/FileProviderExtension.swift:7-31`) | Worker | — | the app's player never reads these copies |
| Share page `/d/` | as the web | Worker, plus one R2 read of the link record per Range request (`public.js:945`) | as the web, plus R2 reads | leak |
| Recense | commands the followed player: QuickTime `looping`, Music repeat one, the tab's `media.loop` (`recense/recense/recense.swift:6442-6476,7641`); A–B by a 20 Hz poll + AppleScript seek (`:7833-7836`); repeat-line `loopLine` (`:8681`, `:8010-8022`) | the player's own file or tab | **0 / 0** | fine |
| Recense, switching pieces | `Store.sweep` uploads a non-current piece to R2 `tmp/` and deletes it locally without checking R2 (`:6047-6057`); a Gallery video downloads again in full whenever it becomes current (`:7784-7791`) | R2 direct | 0 Worker; one full download + upload per switch | **wasteful** (ping-pong) |

**b. Background media loops today**
| Loop | Every | Cost per pass | Per day | Scales with |
|---|---|---|---|---|
| Worker cron `indexRun` (`worker.js:82`; `ai.js:350-370`) | 1 min | 1 invocation + 1 R2 read of the budget file. While steps remain, an idle run also spends one (2 R2 reads + 1 write), because `b.steps++` runs before `indexStep` (`ai.js:359-362`) | 1,440 runs. The 120-step budget is gone ≈ 2 h after the 4 PM reset whether or not anything was indexed, so later uploads wait a day (G20) | time |
| Mac File Provider signal (`apple/HostApp/macOS/main.swift:57-59`) | 60 s | 1 Worker GET `/changes`; the Worker's 60 s reconcile adds a full `archive/` LIST + ≈ 7 R2 ops (`fp.js:67,220-226,270-295`) | 1,440 Worker + ≈ 11.5k R2 | time |
| iOS Listen (`apple/HostApp/iOS/Listen.swift:96-100`) | 60 s, from launch | 1 Worker GET | up to 1,440 | time |
| Recense `GalleryJob.serve` (`recense.swift:7078`) | 60 s | 1 LIST of `keep/locks/` (+ per lock: GET, 1–2 Range GETs, GET + PUT) | 1,440 Class A | time |
| Recense `GalleryJob.run` (`:7072-7076`) | 15 min, idle only | full LISTs of `files/`, `keep/` and `tmp/` (`:6562,5846,6802`) | ≈ 2.9k Class A | time |
| Recense `Handoff.tick` (`:7082`; `handoff.swift:49-66,108-137`) | 5 s; network every 60 s while playing | 2 GETs + 2 PUTs, changed or not | up to 5.8k (playing all day) | time |
| Recense sweep (`:7070,7771`) | 6 h + after each load | changed items only + 1 `keep/` LIST a day | small | changes |
| Web folder-order poll (`main.js:547-566`) | 20 s while visible | 1 Worker GET | 180/hour per tab | time |
No app watches local files (no FSEvents, NSFilePresenter or NSMetadataQuery). The only push channels are Darwin notifications (`recense/recense/Captions.swift:32-43`) and Recense's localhost `/wait` long-poll (`recense.swift:7496`).

**c. Approaches compared: what the offline infrastructure is worth**
| Approach | First play | Each pass | Offline | Loop point | Device cost | Verdict |
|---|---|---|---|---|---|---|
| A. Stream through the Worker (today) | Worker requests per Range | 0–121 Worker requests (a) | no | seek gap | — | retire |
| B. Presigned R2 URLs (phase 2) | 0 Worker; R2 reads per Range | 0 Worker, but an R2 read whenever the browser re-requests | no | seek gap | — | first fetches on the web; not the answer for loops |
| C. Cache headers on the Worker routes (`immutable` on the content-addressed `/d/<id>/<etag12>/`; 304 via R2 `onlyIf`, as `images.js:63-76`) | as A | Chrome 0; Safari unchanged (WebKit won't store media loads) | no | — | — | stopgap only |
| D. **Local copy, loop from disk** (the device's store; at home the Mac hub fills it, A14) | 1 R2 read, or 0 from the Mac hub | **0** | **yes** | small seek gap | the file's size, capped | **the base** |
| E. **Loop from memory**: Web Audio `AudioBufferSourceNode` (`loop`, `loopStart`, `loopEnd`); `AVAudioPlayerNode.scheduleBuffer(…, options: .loops)`; video through `AVPlayerLooper(player:templateItem:timeRange:)` | from D | **0, no I/O** | yes | sample-accurate, no gap for audio buffers (`AVPlayerLooper` doesn't promise gapless) | ≈ 23 MB of memory per stereo minute (MDN: keep buffers under ≈ 45 s) | **A–B and line loops ≤ 45 s** |
| F. Service worker + Cache Storage (browsers) | one full GET (Cache Storage refuses 206s, so the whole file is cached) | 0 | yes | seek gap | browser quota | the web app in browsers; the iOS app uses D through its `SchemeHandler`, since a WKWebView service worker needs App-Bound Domains or an entitlement |
**Verdict:** the offline infrastructure is what makes loops free.
- Presigning (B) moves the cost from the Worker to R2, but it still pays per re-read and fails offline.
- Only a local copy (D) or memory (E) brings a pass to zero, online or off. The Mac hub and peer-to-peer Wi-Fi (A14) only change where the first copy comes from.
- **Best approach: D + E,** with F for browsers and B for first fetches.

**d. The design (reuse first)**
| # | Change | Reuses | Result |
|---|---|---|---|
| L1 | **Deck fix:** while A–B or Track Loop is on, keep the chunks between A and B instead of dropping those behind the playhead (≈ 1.7 MB of 16-bit PCM for a 10 s loop); above 64 MB, fetch the file once | `client/gallery.js:2391-2396` | ≈ 3,400 → 0 Worker requests per looping hour; ships alone (phase 0) |
| L2 | **One media store per device**, content-addressed (ETag / sha256), with pins (Folio, Study, "Keep offline") and an LRU cap for the rest (defaults: iPhone 2 GB, iPad 4 GB, Mac 20 GB; a setting). On iOS the app's own store is the pin: the File Provider's `.downloadEagerlyAndKeepDownloaded` is documented for macOS only | Recense `ContentKey`; `~/Library/Caches/recense`; on iOS a container shared with the File Provider extension (an App Group, if the free team allows it) | a file crosses the network once per device |
| L3 | **iOS/Mac app plays from the store:** the `SchemeHandler` answers Range requests from the local file (206 + `Content-Range`). On a miss it fetches the whole file once over the second door, stores it, then serves it. The File Provider extension reads the same store | `apple/HostApp/iOS/Player.swift:1-40` (already in the media path) | the app's player loops at 0 requests and plays offline |
| L4 | **Web:** a service worker precaches the whole file (presigned GET) and answers Range requests from the cache (Workbox-style `createPartialResponse`; `crossorigin` on the media element). The public share page does the same for each visitor and reads the link record once per page view, not per Range | phase 2 presign; `public.js:945` | browsers loop at 0 requests and play offline |
| L5 | **Loops from memory:** A–B and line loops ≤ 45 s decode once and loop sample-accurately (Web Audio in the web player; `AVAudioPlayerNode` `.loops` natively; `AVPlayerLooper(timeRange:)` for video). Longer loops stay on the file | the deck already decodes compressed audio in memory (`client/gallery.js:1265,1298`) | no gap at the loop point; 0 I/O |
| L6 | **Recense stops the ping-pong:** before uploading, the sweep checks by hash whether R2 already has the piece; recent and pinned pieces stay in the local store; a returning piece plays from it | `recense.swift:6047-6057,7784-7791`; `ContentKey` | one transfer per file, not one per switch |
| L7 | **Revalidate on change, not on time:** a cached file stays valid until the change log (phase 3) shows a new ETag; no hourly expiry | `fp.js:213-247` | 0 requests on a day with no changes |
| L8 | **Background loops become events:**<br>• FSEvents or NSFilePresenter watch the local folders.<br>• The Worker writes a tiny head object, `u/<userId>/head.json` (the latest `seq` per root), on each commit. Devices read it with one conditional GET straight from R2 on wake, network change or user action: an R2 read, 0 Worker requests.<br>• Locks are claimed with a conditional PUT (`If-None-Match`) when work starts, never listed every minute.<br>• Handoff writes only on pause and background.<br>• Listen and the Mac File Provider ask for `/changes` only when the head moved | `fp.js` change log; Recense's ETag/ifAbsent/ifMatch writes (`recense.swift:786-822`); `handoff.swift` | ≈ 0 Worker requests; R2 reads only when something changed |
| L9 | **The Worker's job runs on change:** drop the every-minute cron. Index new items from the commit request itself (`ctx.waitUntil`, no extra request; that it fits the free CPU limit is ASSUMED, so bench it in phase 1) and catch up at 03:00. Raven stays excluded (A6) | `ai.js:350`; `worker.js:80-85` | 1,440 → ≈ 1 cron run a day (A10 #5's `*/10` until then) |
| L10 | **Loop-leak alarm:** the A8 counter tags each request with its cause. Any request during a loop pass after the first play is logged as a leak, and that item switches to the store | A8 | regressions show up within a day |

**e. Test S9: measure it**
| Surface | How to count | Compare |
|---|---|---|
| Web (Chromium + WebKit) | extend `gallery/gallery/test/ui.test.mjs` with Playwright `page.on('request')` per host (Worker, R2, `blob:`); `tmpdeck.tmp.mjs:629` (`window.__pdcDeck`) forces the deck; `context.setOffline(true)` after the first play | A, C, D/F, E |
| Gallery iOS/Mac | count the `SchemeHandler`'s network fetches; `AVPlayerItemAccessLogEvent.numberOfMediaRequests` for native players | A, D, E |
| Recense | a selftest that wraps its one SigV4 request function with a counter and switches between two pieces 100 times | today vs L6 |
| Server side | the A1 GraphQL query (Worker requests) and R2's `r2OperationsAdaptiveGroups` grouped by `actionType`, before and after a one-hour loop session | all |
| Simulation | `sync/tools/sim/`: 3 devices × 7 days × 10k loop passes per device per day | the design |

- **Pass:** 1,000 passes of a 10 s segment and 8 hours of a repeating 3-minute track cost 0 Worker requests per pass and ≤ 1 R2 read per file per device per change, and the same loops run in airplane mode after the first play.
- **Expected:**
  - A: ≈ 2.4k–3.4k Worker requests per looping hour on the deck.
  - C: helps Chrome only.
  - D, E and F: 0.
- **WebKit gets its own run:** a third-party report says a looping `blob:` video was re-fetched on iOS/macOS 26 ([forum](https://developer.apple.com/forums/thread/792048)).

**Sources** (checked 11-04):
- **Web Audio:** [MDN AudioBufferSourceNode](https://developer.mozilla.org/en-US/docs/Web/API/AudioBufferSourceNode).
- **Service workers and Range requests:** [`Cache.put` rejects 206](https://w3c.github.io/ServiceWorker/#cache-put); [Workbox cached audio/video](https://developer.chrome.com/docs/workbox/serving-cached-audio-and-video); [WKWebView service workers need App-Bound Domains](https://webkit.org/blog/10882/app-bound-domains/).
- **Apple playback APIs:** [AVPlayerLooper timeRange](https://developer.apple.com/documentation/avfoundation/avplayerlooper/init(player:templateitem:timerange:)); [`.loops`](https://developer.apple.com/documentation/avfaudio/avaudioplayernodebufferoptions/loops); [`numberOfMediaRequests`](https://developer.apple.com/documentation/avfoundation/avplayeritemaccesslogevent/numberofmediarequests).
- **HTTP caching:** [RFC 9111 §3.3](https://www.rfc-editor.org/rfc/rfc9111#section-3.3); [WebKit NetworkCache.cpp](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/NetworkProcess/cache/NetworkCache.cpp) (`NoDueToStreamingMedia`).
- **R2:** [R2 metrics](https://developers.cloudflare.com/r2/platform/metrics-analytics/).
- **Not found in any doc:** R2 `response-cache-control` overrides on presigned GETs, and whether a ranged GET counts as exactly one Class B operation.

## A14. Ad hoc networks: share links and the offline infrastructure (owner follow-up in chat, 11-04)
**Verdict:** worth building between your own devices, marginal for sharing with other people.
- **What it adds:** peer-to-peer Wi-Fi is the "no router" layer under P0. The Mac hub, handoff and the outbox keep working on a train, in a courtroom or during an outage.
- **What it doesn't:**
  - It adds no copies; durability still comes from the SSD and R2.
  - It can't reach anyone outside the room.
  - On iOS it is a foreground feature (background behaviour ASSUMED; A12i question 2 asks your cousin).

**a. The options**
| Technology | Reach | Platforms | Needs | Use here | Verdict |
|---|---|---|---|---|---|
| Apple peer-to-peer Wi-Fi through Network.framework + Bonjour (`includePeerToPeer = true` on listener and browser; off by default) | a room, at Wi-Fi speed | Apple only | the local-network permission; no paid entitlement (ASSUMED) | Mac ↔ iPhone/iPad with no router: first copies for the media store (A13 D), handoff cursors, outbox exchange | **adopt** (phases 5, 8) |
| AirDrop | a room | Apple, plus Pixel 10 phones through Quick Share since 2025-11 (with the iPhone set to "Everyone for 10 minutes") | a person taps | the offline twin of a share link: **Send a copy** | **keep** |
| Multipeer Connectivity | the same radio | Apple only | — | — | skip: Network.framework covers it |
| Wi-Fi Aware (iOS 26) | a room | iPhone on iOS 26 and Android 8+; not the iPad on iPadOS 18.6 | an entitlement Apple must grant; pairing through AccessorySetupKit or DeviceDiscoveryUI; Android pairing still unreliable in developer reports | sharing with Android phones nearby | **watch** |
| Wi-Fi Direct; classic 802.11 ad hoc (IBSS) | — | Android and Windows; no iOS app support (ASSUMED) | — | — | no |
| Bluetooth LE | tens of metres, kilobytes per second | all | background modes | tiny "new changes" signals | later, only if needed |
| The Mac hub's page over your Wi-Fi + a QR code | your network | any browser | the guest joins your network | a read-only, expiring local page for a nearby non-Apple guest | niche; never Matters |
| Mesh and delay-tolerant apps (Briar, Bridgefy, LoRa radios) | kilometres, kilobits per second | varies | extra apps or hardware | messages, not files | no |

**b. Share links with and without a network**
| Situation | What works | How |
|---|---|---|
| Recipient anywhere, internet up | the share link | the Worker; media through presigned GETs (phase 2) |
| Your Worker closed (1027) | no live link; send a copy by Messages or Mail | the link works again after 4 PM |
| Recipient in the room, no internet, iPhone/Mac or Pixel 10 | AirDrop a copy: m4a/m4b with chapters and captions, or PDF/MD | **Send a copy** |
| Recipient in the room, no internet, any other device | the Mac hub's read-only local page through a QR code, ending with the session | **Show QR** (phase 8) |
| Your own devices | not a link: a handoff cursor plus the file, over peer-to-peer Wi-Fi | phases 5, 8 |
| Matters | never shared, by any route | A6 |
The share sheet gets three verbs: **Copy link**, **Send a copy** and **Show QR** (B4 Share).

**c. Fit with the rest of the plan**
- **Delay-tolerant by construction:** commits are idempotent (`opId`) and media is content-addressed. Any two devices that meet swap what the other lacks, and the same ops reach R2 later without duplicates (store-and-forward, A12g).
- **The push channel the free plan lacks:** with no APNs on the free team and no Durable Objects, the cloud can't push. When the iPhone and the Mac are near each other, the iPhone hands a job ("transcribe this") straight to Recense; otherwise the job waits in R2 for the Mac's next head check (A13 L8).
- **Mac side:** Recense hosts the listener; it is always running and already serves `127.0.0.1:47123`. Devices pair with TLS pre-shared keys derived from their device keys (S8).
- **Security:**
  - AirDrop's handshake can reveal hashed phone numbers and emails to nearby strangers (PrivateDrop, USENIX Security 2021).
  - So keep AirDrop receiving on Contacts Only, and never AirDrop client files.
  - DEVONthink's own sync stays on the home network, since Bonjour can't cross Tailscale (A16d).
- **Cost:** 0 requests and no new hardware. Wi-Fi Aware is the only option that would need the paid account (ASSUMED).

**d. Test S10:** put the Mac, iPhone and iPad on Wi-Fi with no network joined.
- The iPhone finds the Mac within 10 s.
- A 100 MB file arrives within 60 s.
- A handoff cursor lands on the same word.
- An outbox op made offline reaches R2 exactly once after reconnecting.

**Sources** (11-04):
- [Apple Wi-Fi Aware](https://developer.apple.com/documentation/wifiaware) and an [Android interop thread](https://developer.apple.com/forums/thread/790195).
- [Quick Share ↔ AirDrop, TechCrunch 2025-11-20](https://techcrunch.com/2025/11/20/androids-quick-share-now-works-with-iphones-airdrop-starting-with-the-pixel-10-lineup).
- Apple DTS forum threads: peer-to-peer must be opted into on both ends ([808917](https://developer.apple.com/forums/thread/808917)), and Wi-Fi and Bluetooth share one radio ([45283](https://developer.apple.com/forums/thread/45283)).

## A15. One project: Recense as the parent (11-05 note, line 1)
**Verdict:** accept one repo with one-word feature folders. Object to splitting each app's files across features: each app stays one buildable folder.
- **Can the codebases stay separate?** Yes, where it matters. They stay separate deployables (Recense.app, the Gallery Worker, the Gallery Apple apps, the CalDAV Worker, the Mac jobs), each with its own build, tests and deploy.
- **What joins them:** the protocol (A4) and shared code.
- **The rule still holds:** Recense never depends on the Worker (`recense/.claude/CLAUDE.md:20-21`). One repo doesn't merge the runtimes. That file's "Do not merge the projects" becomes "One repo, separate apps".

**a. What you have today** (read-only inventory, 11-05)
| Repo (GitHub) | On disk (of which `.git`) | State | What breaks if folders move |
|---|---|---|---|
| `recense` (`louan-dev/recense`, renamed from sill on 11-04) | 5.4 GB (14 MB). Mostly `.toolchain` 3.0 GB, builds 1.5 GB, `.claude` 504 MB, `.handoff` + zip 376 MB; source ≈ 2 MB | `main` = origin; 1 uncommitted file. The worktree `nook-fix-1f871c` holds 1 unmerged commit (`nook.swift` 149 → 441 lines, on the old `sill/` paths) | • `recense/build.sh:35` copies 6 files from `~/Developer/gallery/gallery/src/client`. If they're missing, it only warns and builds the app without the home bar.<br>• `scripts/autoupdate.sh:12` hard-codes the gallery repo, and `local.recense.autoupdate` pulls both repos and rebuilds every 5 minutes |
| `gallery` (`louan-dev/gallery`) | 892 MB (44 MB): `node_modules` 362 MB, `apple/build` 349 MB | `main` = origin; 5 edited files + untracked `notes/item16-rec/` (6.7 MB); 2 merged worktrees + 6 stale entries; an extra ref, `refs/snapshots/p2-pre` | `.github/workflows/deploy.yml` deploys on every push to `main` (`working-directory: gallery`, secret `GALLERY_GITHUB`) |
| `sync` (`louan-dev/sync`) | 7.1 MB (2.9 MB) | `main` = origin; clean | • 8 launch agents run `~/Developer/sync/bin/*`.<br>• The Finder Quick Action "Move Offsite" runs `sync/bin/offsite-image.zsh`.<br>• `bin/resign-ios.zsh:9` and `bin/caldav-passwd.sh` call into gallery.<br>• `bin/docs-sync.zsh:57` copies all of `~/Developer` to Gallery and never deletes, so a move leaves both old and new paths there |
| Outside the merge | `sandisk-rescue` 1.3 GB; `auto_avsr` 843 MB (someone else's project; its `venv` is 792 MB); `auditor` 4 MB; `acquisition` 2 MB (two launch agents run from it) | not git, except `auto_avsr` | — |
Cloudflare isn't affected: Workers and buckets are found by name, not by folder path.

**b. Options**
| Option | Verdict |
|---|---|
| A. One repo, with the three folders side by side as they are | Step 1 only. A day's work and nothing breaks, but it isn't the regroup you asked for |
| **B. One repo with one-word feature folders at the top. Each app stays whole inside the feature it serves, and shared code lives in one place** | **recommended** |
| C. Split every app's files by feature (e.g. the Worker's modules into `share/`, `ask/`, `files/`) | reject: every build, import path, Xcode reference and launch agent moves at once, and history becomes hard to follow |
| Keep three repos | reject: your reason (three chats and three plans for one system) stands |

**c. The tree (B)**
```
recense/               one repo: louan-dev/recense
├─ README.md           the front page (d)
├─ CLAUDE.md           one root guide, plus one in strip/, library/ and sync/
├─ strip/              Recense.app for the Mac: the strip, listening surface, sound engine,
│                      menu-bar hider and Draftpad (was recense/recense/, unchanged inside)
├─ library/            Gallery: the Worker, web app and tests, and the iPhone, iPad and Mac apps
│                      in library/apple/ (was gallery/gallery/, unchanged inside)
├─ player/             the one player Gallery and Recense share: home bar, key labels, room,
│                      prosody (was gallery/gallery/src/client/{homebar,keylabel,room,prosody}.*)
├─ sync/               the Mac's jobs, ledger, canary and launch-agent copies (was sync/{bin,src,tools,launchd})
├─ calendar/           the CalDAV Worker (was sync/worker/)
├─ docs/               plans, specs, runbooks, decisions, requests, PROGRESS, BACKLOG
└─ notes/              your inbox and task tables, in one place
```
- `player/` moves only if `wrangler deploy --dry-run` can bundle it from outside the Worker's folder. Otherwise it stays in `library/src/client/`, and Recense copies it from there.
- `.toolchain/`, `.handoff/` and the zip stay at the root, ignored by git.
- Each app keeps its own architecture doc.

**d. The front page** (`README.md` on GitHub)
```
# Recense
One system in three states: the strip on your Mac, the library in your cloud,
and the sync that carries one into the other. Offline first: the network is
an optimization, not a dependency.

[Preface link line, unchanged]

| Folder   | What it is                                    | Build or run                      |
|----------|-----------------------------------------------|-----------------------------------|
| strip    | Recense.app for the Mac                       | zsh strip/build.sh                |
| library  | Gallery: web app, share links, iOS & Mac apps | deploys on push to library/**     |
| player   | the player Gallery and Recense share          | built into both                   |
| sync     | the Mac's jobs, ledger and canary             | launch agents in sync/launchd/    |
| calendar | your calendar server (CalDAV)                 | npx wrangler deploy               |
| docs     | plans, specs, runbooks                        | start at docs/PROGRESS.md         |

Status · What works offline · Privacy: client matters never enter this repo · Changes
```

**e. GitHub** (pushing, archiving and adding secrets are your go; Claude never types a secret)
| # | Step |
|---|---|
| 1 | Freeze: pause `local.recense.autoupdate` and docs-sync. All three repos clean and pushed, and each tagged `pre-monorepo-<date>` |
| 2 | Keep the history:<br>• Rewrite fresh clones of gallery and sync with `git filter-repo --path-rename` (e.g. `gallery/:library/`, `worker/:calendar/`, `bin/:sync/bin/`), so `git log library/src/main.js` reaches the first commit without `--follow`.<br>• Merge them into recense with `git merge --allow-unrelated-histories`.<br>• Bring `refs/snapshots/p2-pre` along as `refs/snapshots/gallery/p2-pre`. |
| 3 | `git mv recense strip`, then fix the couplings (f) in the same commit series. Build every app and run every test before pushing |
| 4 | CI:<br>• `deploy.yml` moves to the root as `.github/workflows/library.yml`, with `paths: [library/**, player/**]`, `working-directory: library` and `cache-dependency-path: library/package-lock.json`.<br>• You add the `GALLERY_GITHUB` secret to `louan-dev/recense`. |
| 5 | Archive `louan-dev/gallery` and `louan-dev/sync` (read-only), each with one README line pointing to its new folder. Don't delete them: old links and history keep working |
| 6 | Check each repo's visibility first. If `louan-dev/recense` is public, settle X4 (the wrangler account file in its history) before the merge adds more to it |
| 7 | One claude.ai Project for the whole system: connect `louan-dev/recense` with the GitHub integration and pick `README.md`, `docs/` and the CLAUDE.md files, then sync it when files change. Projects have size limits (ASSUMED), so don't add `library/` whole |

**f. Couplings to fix in the same change**
| Coupling | Fix |
|---|---|
| `strip/build.sh:35` copies the home-bar files from `~/Developer/gallery/gallery/src/client` | copy from `../player/` (or `../library/src/client/`). A missing file becomes an error, not a warning |
| `strip/build.sh` finds the toolchain at `$PWD/../.toolchain` | unchanged: `.toolchain/` stays at the root |
| `scripts/autoupdate.sh:12` and its 5-minute agent | one repo to pull. It runs only in the main checkout, never in a worktree |
| 8 launch agents (and their copies in `sync/launchd/`) run `~/Developer/sync/bin/*` | point them at `~/Developer/recense/sync/bin/*` and reload each one. During the switch, a symlink `~/Developer/sync → recense/sync` keeps the old paths working; remove it afterwards |
| The "Move Offsite" Quick Action; `sync/bin/resign-ios.zsh:9`; `sync/bin/caldav-passwd.sh` | new paths |
| `sync/bin/docs-sync.zsh:57` copies `~/Developer` and never deletes | exclude the old folders after the move, or let A10/A11 retire this lane |
| Each CLAUDE.md says "repo root ~/Developer/x" and points to `../sync/PROGRESS.md`; recense's has 11 absolute paths and the notes-inbox trigger | one root CLAUDE.md plus `strip/`, `library/` and `sync/` ones (Claude Code reads the nearest); `docs/PROGRESS.md` |
| `~/Developer/.claude/launch.json` (`--prefix gallery/gallery`, an old `sill/` path) | new paths |
| Your global CLAUDE.md treats the first folder under `~/Developer` as the project root, so three CLIs in three worktrees would share one `.handoff/HANDOFF.md` and overwrite each other | amend it (your file, your call): in a worktree, write `.handoff/<worktree>/HANDOFF.md` |
| Session memory is kept per folder path (`~/.claude/projects/…`) | a new path starts empty: copy the memory folder once |

**g. Three CLIs at once: worktrees**
- Create each with `git worktree add .claude/worktrees/<area> -b work/<area>`, or with Claude Code's own worktree option, which uses the same folder. Each CLI works on its own branch and merges into `main` when done.
- Worktrees share one `.git`, so each costs only its files. `git sparse-checkout set library player docs` shrinks one further.
- The main checkout stays on `main`, and only there does autoupdate build the installed app.

**h. `/recense player.js`: one command for every part**
- **What it is:** a project skill, `.claude/skills/recense/SKILL.md`, called as `/recense <file | word | space>`.
- **What it does:**
  1. Finds the target. It tries a file name (`git ls-files`) first, then a feature word from a short map (`player`, `hider`, `sync`, `ask`, `share`…), then a code search, and asks when two match.
  2. Loads that folder's CLAUDE.md and its PROGRESS section.
  3. Opens or reuses that area's worktree (g).
- **Your example:** there's no `player.js` today. The map sends "player" to `homebar.js` and the player in `gallery.js`.

**i. "Nook" becomes plain Recense**
- **What you see:** no separate name anywhere. The menus already say "Hide Menu-Bar Icons" and "Menu-Bar Hider".
- **Code renames:**
  - `nook.swift` → `hider.swift`, and its symlink in `Sources/recense/`.
  - `Nook`, `NookPrefs`, `NookToggle` → `MenuBarHider`, `HiderPrefs`, `HiderToggle` (`app.swift:6493,6501,6890,7685`). Line 7685 finds the menu by its exact title, so the title and the code change together.
- **Settings:** `nookEnabled` → `hiderEnabled`, reading the old key once. Delete the stale `local.sill.nook.always` and `local.sill.nook.toggle` positions.
- **Docs:** ≈ 19 mentions.
- **Order:** fix R16, merge or drop the `nook-fix` branch (its commit sits on the old `sill/` paths), rename, then move folders.

**j. Files not in use: a delete list for your yes, path by path**
- Nothing is deleted until you say yes to each exact path.
- Files go to `~/.Trash/recense-cleanup-<date>/`, as on 11-04. Worktrees go through `git worktree remove`.

| Path | Size | Proposal |
|---|---|---|
| `recense/recense/.build` (the old build; `.build-sdk27` is the one in use) | 517 MB | delete (it rebuilds) |
| `recense/.claude/worktrees/nook-fix-1f871c` | 504 MB | remove after merging or dropping its one commit (R4) |
| `gallery/gallery/apple/build` (dated builds) | 349 MB | delete all but the newest |
| `gallery/gallery/{.test-build,.shots,test-results,test-fail.png}` | 44 MB | delete (test output) |
| `gallery/.claude/worktrees/*` (both merged) + 6 stale entries | 45 MB | `git worktree remove` + `git worktree prune` |
| `recense/recense/build/Recense.app` | 0.7 MB | delete (the installed copy is in /Applications) |
| `gallery/gallery/.retired` | 64 KB | remove from the tree (history keeps it) |
| branch `wip/main-uncommitted-2026-10-26` (marked replaced) | — | delete the branch |
| Tracked by mistake: `recense/.build-log.txt`, `_CodeSignature/`, `.wrangler/cache/wrangler-account.json` (X4), the generated `recense` launcher | small | untrack and ignore; keep the local files |
| `gallery/gallery/test/*.tmp.mjs` (31 throwaway tests) | 0.6 MB | delete 30. Keep `tmpdeck.tmp.mjs` (A13's test uses it), or fold it into `ui.test.mjs` |
| **Keep:** `.handoff/` and `recense-handoff.zip` (your handoff rule); `.toolchain/` (on-device speech builds) | — | keep |
| **Your call:**<br>• `.toolchain/pkgs` (installers, 403 MB; an offline reinstall needs them)<br>• `src/page/ui` design reference images (32 MB, tracked)<br>• `.handoff/variations.flac` (62 MB)<br>• `auto_avsr` (843 MB, someone else's project)<br>• old session memory `~/.claude/projects/-…-sill*` (134 MB)<br>• `sandisk-rescue` (keep until D3–D11 close) | — | ask |
The "delete" and "remove" rows alone free ≈ 1.46 GB.

**k. Order** (each step builds and passes its tests before the next; undo = the `pre-monorepo` tags and the old repos)
1. Fix R16 and R15; merge or drop `nook-fix`; rename Nook (i).
2. Clean up (j), after your yes.
3. Merge into `louan-dev/recense` with history (e), with the folders in (c) and the couplings in (f); move CI.
4. Worktrees, the `/recense` skill, the CLAUDE.md files, the memory copy (g, h).
5. Archive the old GitHub repos (your go).

**Verify:**
- `zsh strip/build.sh` builds with the home bar and no warning.
- The existing viewer and route tests pass in `library/`.
- `wrangler deploy --dry-run` passes for both Workers.
- `launchctl print` shows all 8 agents running from the new paths with exit 0 after one cycle.
- `git log library/src/main.js` reaches gallery's first commit.
- Three CLIs in three worktrees each write their own handoff.

## A16. The ask engine, the models and DEVONthink (11-05 note, lines 8–14)
**Verdict:**
- **The ask engine is too network-dependent:** your suspicion holds. Nothing works offline.
- **Move it onto the device:** Apple's on-device model on the Mac and iPhone, a local index on each device, and Workers AI only as an online fallback for the Library.
- **DEVONthink as the index for everything: reject.** As the Mac's local index for Matters, Study and Folio: accept.

**a. Today** (read-only audit, 11-05)
| Part | Fact | Source |
|---|---|---|
| Where | Gallery only, owner-only: one web page, opened by the ✦ button, `?ask=1`, ⌘K on the Mac, or the iOS app | `worker.js:107`; `page/gallery.js:62`; `client/assistant.js:196`; `apple/HostApp/macOS/Window.swift:61,252`; `apple/HostApp/iOS/Browser.swift:105,153,244` |
| Models | • Chat: `@cf/openai/gpt-oss-120b`.<br>• Planner, memory and classifier: `@cf/openai/gpt-oss-20b`.<br>• Embeddings: `@cf/baai/bge-m3`.<br>• `AI.toMarkdown` for documents.<br>• Vectorize index `gallery-ai` (1,024 dimensions, cosine) | `ai.js:29-31,475`; `wrangler.toml:69-77` |
| What's indexed | Main `files/` and Archive `archive/`. Only dot-folders are skipped, so `files/Raven/` (client matters) is indexed | `ai.js:36,378` |
| Per question | • 2 Worker requests (the answer, then a status check).<br>• 4 AI calls (plan, embeddings, chat, memory); a calendar question can take 6 tool rounds and up to 9 calls.<br>• 1–4 Vectorize queries.<br>• 4 R2 reads and up to 1 write | `ai.js:111,185-213`; `client/assistant.js:125,153` |
| Free limits | • 10,000 neurons a day for all AI calls, indexing included. After that, every call fails with 3036 / HTTP 429 until 00:00 UTC.<br>• Vectorize stores at most 5M dimensions: ≈ 4,880 vectors at 1,024 dimensions | [Workers AI pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/), [errors](https://developers.cloudflare.com/workers-ai/platform/errors/), [Vectorize pricing](https://developers.cloudflare.com/vectorize/platform/pricing/) |
| Failures | • Questions have no cap and no quota handling: the raw error becomes the answer.<br>• The code watches only for 4006, which the current error table no longer lists (3036 is the daily-limit code).<br>• Folder scope is applied after retrieval, so a small folder can return nothing.<br>• Idle runs spend the indexing budget (G20) | `ai.js:110,202,365`; `client/assistant.js:148` |
| Offline | Nothing works; only the chat history survives, in sessionStorage | `client/assistant.js:15` |
| Recense | No ask engine. It calls the Claude CLI for a notebook and, through `claude -p`, to turn text into calendar events. Both need the internet | `app.swift:6113,7351` |
**Cost:** $0 on the free plan, but the free allocation caps it. That's ≈ 300 neurons per question by the price list (ASSUMED; measure it), so ≈ 30 questions a day, and fewer on days with indexing.

**b. The models against your goals** (the goals on record: offline first (P0); free; client matters never leave your devices (A6, ABA 512); en/fr/vi; an 8 GB M1)
| Engine | Offline | Cost | Private | en / fr / vi | Limits | Verdict |
|---|---|---|---|---|---|---|
| **Apple Foundation Models, on-device** (≈ 3B parameters) | yes | free, unlimited | yes | yes; French and Vietnamese since 26.1 | 4,096 tokens per session, prompt and answer together, and Vietnamese uses ≈ 1 token per character. Runs on M1+ Macs and iPhone 15 Pro or later, but not on your iPad on iPadOS 18.6 | **The default**, Matters included: planning, classifying, short answers, summaries, event extraction, translation drafts. Guided generation returns typed answers, and tool calls reach your own data |
| Apple's Private Cloud Compute model (OS 27, same framework) | no | free, with a daily cap | Apple's private cloud | yes | 32K tokens | long documents outside Matters, when online |
| A local open model (MLX or llama.cpp): Qwen3-4B, 4-bit, ≈ 2.3 GB | yes | free | yes | yes. Qwen3 lists French and Vietnamese; Phi-4-mini and Llama 3.2 lack Vietnamese | Tight on 8 GB of RAM beside speech recognition: run it only when idle, one model at a time | optional long-context reader on the Mac. It replaces SL4's Phi plan, because Phi lacks Vietnamese |
| Workers AI (today) | no | free up to 10k neurons a day | Cloudflare | yes | quota; Raven exposure | online fallback for the Library only; never Matters |
| Cloud APIs (Claude, ChatGPT…) | no | paid | third party | yes | cost, confidentiality | never the default; never Matters |
**Choice:** Apple's on-device model as the engine. Private Cloud Compute or Workers AI only for long questions outside Matters, when online.

**c. One ask, two indexes**
| Index | Holds | Lives | Used by |
|---|---|---|---|
| Local | Matters, Study, Folio, pinned Library files, transcripts (`keep/`), notes and Draftpad | Each device: SQLite full-text search (FTS5) plus on-device embeddings, built from the media store (A13 L2). On the Mac, DEVONthink also holds Matters, Study and Folio | the ask sheet on that device, offline |
| Cloud | the Library, minus Raven and Matters | Vectorize (≈ 4,880 vectors on the free plan; measure today's count) | the web app, online |
- **Routing:** offline → local only. Matters → local only, never the cloud. Otherwise local first, and the cloud when the local answer is thin.
- **Tight retrieval:** a 4,096-token window holds about 3–5 short passages plus the answer. Long documents are summarised section by section first. Those summaries double as the m4b's "Summary" chapters (A17e).
- **Requests:** a local ask costs 0 Worker requests; a cloud ask costs 1, with the status check folded into the answer stream.
- **Fixes in phase 1:**
  - Exclude `files/Raven/` and remove its vectors (A6; needs your approval).
  - Handle 3036, 4006 and 429 through the error catalog (B7).
  - Filter by folder inside the Vectorize query.
  - Fold the status call into the stream.
  - Fix G20 and the comment at `wrangler.toml:71`.
- **Recense:** replace the `claude -p` event extraction (`app.swift:6113`) with on-device guided generation of a typed Event (title, start, end, place). The same tool-call pattern answers business hours from Contacts notes (BD9). Both work offline and cost nothing.

**d. DEVONthink: your claims, with verdicts** (DEVONthink 4.4.1 is installed; your edition is unknown)
| Your claim (lines 10–14) | Verdict | Facts |
|---|---|---|
| DEVONthink can join over the local network | **accept** | • DEVONthink To Go syncs over Bonjour on the home network, encrypted by default.<br>• The Server edition's web interface serves browsers on the network, with SSL and per-database permissions |
| If the local network is joined remotely (Tailscale), DEVONthink comes along | **object** | • Bonjour sync doesn't work over a VPN, and there's no field for an address (vendor manual; staff, Dec 2025).<br>• Away from home, a phone syncs only through a WebDAV or cloud sync store, or opens the Server edition's web interface. Tailscale makes that work with no open ports.<br>• Encrypted DEVONthink databases can't sync to DEVONthink To Go at all |
| So DEVONthink can index all the Cloudflare files | **reject** | • It indexes files on local or mounted volumes, and files that exist only in the cloud are unsupported. Indexing R2 means keeping ≈ 77 GB on the Mac, or mounting R2, reading every file and keeping the mount up.<br>• Vietnamese search isn't documented, and Vietnamese OCR wasn't supported (2020).<br>• It runs on the Mac only, so the web app, share pages and your iPad on 18.6 can't use it |
| Retrofit the ask engine around it for one offline-first whole | **accept the goal, object to the hub** | • One ask with two indexes (c) gives the cohesion without making one Mac app the single point of failure.<br>• DEVONthink is the Mac's local index for Matters, Study and Folio.<br>• Recense and agents reach it through AppleScript/JXA, or its MCP server (4.3+, Pro edition) |
| Cost–benefit of DEVONthink as the whole indexing layer | **rejects it; favours it as the local layer** | • **Costs:** disk for full local copies; a Mac that must stay awake; a $99 upgrade to Pro if you have Standard (needed for Apple's model and MCP); $299–399 to Server for remote web access. Prices come from vendor-page snippets.<br>• **Benefits:** offline full-text search, See Also/Classify and scripting. The local layer already gives you all of them |
| Effect of a global DEVONthink index on the ask agent's AI | **answered** | • **Privacy:** DEVONthink's AI sends the selected documents to whichever provider is set. A global index mixes Matters with everything else, so one cloud-provider setting would send client text out. Keep Matters in its own databases, with Apple's on-device model as their only provider.<br>• **Quality:** its search matches words, with fuzzy matching and See Also, not meaning. That is better for exact terms (MPEP §, "shall") and weaker for loose questions. The local index (c) does both.<br>• **Context:** the on-device model's 4k window needs scoped retrieval, and DEVONthink's groups help.<br>• **Availability:** the agent becomes Mac-bound. If the Mac sleeps, phones can't ask.<br>• **Cost per question:** $0 with the on-device model |

**e. Where DEVONthink fits now**
- **What it holds:** Matters and Sealed (A6), Study and Folio, on the Mac.
- **Its AI provider:**
  - Apple Intelligence (4.3+, Pro), or macOS 27's `fm serve` (4.4, Pro). Both run on the device.
  - LM Studio or Ollama with Qwen3-4B for long reads.
- **Raven** moves in after the A6 checks.

## A17. Seeding, offline-first links and one page across apps (11-05 note, lines 7–8, 16–30, 133–150)
**a. "Seed through someone else's connection" (lines 7–8). Verdict: object, then accept a narrower version.**
- **Why not as stated:** a link points at bytes somewhere reachable. If the bytes exist only on your offline device, nobody far away can fetch them, whatever their own connection. BitTorrent works the same way: every seed and peer must be online, and a seed with no internet seeds nobody.
- **What does work:**

| Version | Verdict | How |
|---|---|---|
| **Links minted offline** | **accept** | A link needs no network to create. The device signs a capability token with its own key (HMAC, verified by the Worker), or a presigned R2 GET (signing needs only the key; valid up to 7 days). Send it by AirDrop, or let Messages queue it. It opens as soon as the bytes are in R2: they were synced earlier, or your next connection uploads them. Revocation is a list in R2 that the Worker checks |
| **Carry-and-forward through your own devices** | **accept** | Mac offline, iPhone on cellular: the Mac hands the file to the iPhone over peer-to-peer Wi-Fi (A14), and the iPhone uploads it with its own key. "Another device's connection" works when you control the device |
| **A nearby person's connection** | **object** unless they run Recense | Their phone can relay only with software that takes the file and uploads it with one of your pre-minted upload slots (A8's 20 presigned inbox slots). AirDrop hands them the file but not the upload, so give them the file itself |
| **Any holder is a seed** (the BitTorrent idea that pays off) | **accept** | Files are content-addressed, so a device fetches from the nearest holder first (the Mac on the LAN or by peer-to-peer) and R2 second, checking the sha256 (A13 L2) |

**b. "Assume offline even when online; sync at lightning speed, then shut the port" (line 29). Verdict: accept, with one correction.**
- **Accept:** the outbox queues every edit offline. On a connection it sends them in one batch (ordered `/v1/commit`, presigned multi-file uploads), then stops. Every edit keeps its version (`.versions/`, A5).
- **Correction:** apps don't open or close Wi-Fi "ports"; iOS and macOS manage the radios. Apps instead stay off the network until there is work:
  - `NWPathMonitor` tells them when a connection appears.
  - `URLSession` can wait for connectivity, skip cellular (`allowsExpensiveNetworkAccess = false`) and respect Low Data Mode.
  - Background sessions finish the upload after the app closes.
- **Fallback ladder for a link:**
  1. your connection;
  2. your other devices' connections, by peer-to-peer;
  3. a nearby device running Recense;
  4. queued until any connection appears.
- **A VPS or reverse proxy adds nothing here:** your device still has to reach it (A12h).

**c. iCloud glitches (lines 30, 146). Verdict: reject the hack, accept the lesson.**
- **Reject:** deceiving or exploiting iCloud, or staying on an old OS to keep a glitch, breaks Apple's terms, risks data and leaves security holes. That conflicts with the duty of reasonable security for client data (A6). The next update closes the glitch and the kingdom falls with it.
- **Accept:** test iCloud's real behaviour and build on its public APIs:
  - `NSFileVersion`: iCloud already keeps conflict versions; show them in the Versions/Conflict UI.
  - `NSFileCoordinator` / `NSFilePresenter`: no T1-style write races.
  - `NSMetadataQuery`: download status.
  - Every glitch you find becomes a test in the A9 simulation, which is glitch-hunting that compounds.
- **The "zero-latency, buttery" feel of line 139:**
  - It came from Obsidian over iCloud while iCloud had room.
  - Reproduce it with no reverse engineering: when two devices are side by side, stream the open page between them as a CRDT (Automerge or Yjs) over peer-to-peer Wi-Fi, so letters appear live for 0 requests.
  - When the devices are apart, the page saves to disk and syncs on pause (one commit). Handoff-level latency, seconds, is what that case needs.

**d. One page across apps and instruments (lines 27, 133–139, 149–150). Verdict: accept the goal, object to bridging four apps live.**
- **The limit:** no app can write live into another app's open document.
  - Notability has no public API or live format (ASSUMED; it exports PDF/RTF/its own `.note`).
  - Word and LibreOffice co-edit live only through their own clouds.
- **What works: one canonical page that every instrument writes into, and adapters that export to each app.**

| Part | Design |
|---|---|
| The page | Markdown plus a sidecar with per-span provenance (device, instrument: pencil, keyboard, touch or voice, and time). That lets you "trace your voice text back to your pencil text" (line 149). A CRDT handles merges (phase 7) |
| Instruments | Keyboard (Mac, iPad); touch keyboard (iPhone); voice (on-device dictation, SpeechAnalyzer); pencil (a PencilKit canvas; handwriting recognised on-device, with the ink kept as an attachment span) |
| Phase transitions (your states of matter) | The page goes forward to `.odt`/`.docx` with pandoc (LibreOffice, Word), to Obsidian as plain Markdown (A11), and to Notability as PDF, one way. It comes back from `.odt`/`.docx` with pandoc and a 3-way merge against the base (A5): the reverse transition, with no words lost |
| Where it lives | Recense's Draftpad becomes the page (SL3: one `draftpad.md`) |
| Host or branch (line 135) | **Host:** the Mac side stays in the one Recense binary, which already owns Draftpad and the strip |
| Recense on iOS (line 136) | Recense is a Mac menu-bar app that uses private multitouch APIs, so it can't be ported as-is. Its iOS side is a new target in the one project (A15) sharing a Swift package (`RecenseCore`: page model, CRDT, sync): the page, capture (pencil, voice) and the player. One product, several binaries, one core |
| Super app vs suite (line 27) | **Object to a super app:** an Apple-platform app can't host system-wide input or replace other apps, and a mini-program runtime is a large build. Recense as one brand with three binaries (Mac strip, iOS app, web), one core and one protocol is the practical version of the same idea |

**e. The offline list (lines 16–26): where each item lives**
| Item | Where | Section |
|---|---|---|
| Seeding in sharing and sync | any holder serves the bytes | A17a |
| Gallery as an offline library, UI unchanged | media store + `SchemeHandler` + service worker | A13 L2–L4 |
| Offline downloads and per-play queues | "Keep offline" pins, plus a play queue that prefetches the next few items into the store while online | A13 L2 |
| Text in any file → m4b | a Mac Services / Share-extension action, "Make m4b", with on-device voices | A7 |
| Offline trilingual | translated interface (B11) + on-device translation (A7) | B11 |
| Offline audio summaries per file, section, chapter, post, paper, book, article, conversation or dataset | an on-device model summarises each section (A16), TTS speaks it, and it lands as a "Summary" chapter in the m4b | A16; A7 |
| Audio descriptions; sonified data | on-device image description; data sonification (pitch = value; gestures move through the planes, line 108) | B10 |
| Download any audio or video | a Download action on every media item you own. For third-party streams (YouTube…), only where the site's terms allow | B4 |
| End-to-end AirDrop; ad hoc networks | Send a copy; peer-to-peer Wi-Fi | A14 |

# PART B — UX/UI redesign (built on Part A's sync states)

Short paths: web = `gallery/gallery/src/`, apple = `gallery/gallery/apple/`, rec = `recense/recense/`, dp = `recense/reference/draftpad/`.

## B1. What exists (inventory)
| Layer | Gallery web | Gallery Apple | Recense (Mac) | Sync |
|---|---|---|---|---|
| Tokens | **4 competing `:root` sets:** `client/gallery.css:1-9`, `client/upload.css:2-9`, `worker.js:192`, and the spec `page/ui/README.md:14-28`. The README says `--bg #000`; the CSS says `#1c1c1e`. 36 hex + 111 rgba literals; the accent is hard-coded ~75× | System text styles (Dynamic Type) mostly; fixed sizes at `HostApp/iOS/Listen.swift:537,544`; hard-coded `.white` at `Browser.swift:153,244,531` | Constants `app.swift:47-70`; palette `app.swift:3607-3609` (bioCyan accent); 99 inline colour literals; fixed 8.5–15 pt `roundedFont()` (`app.swift:796-800`) | none |
| Theme | Dark only (`worker.js:159,188`, `client/gallery.css:1715`) | Follows the system, but the white icons break light mode | Forced `.darkAqua` (`app.swift:4006` …) | — |
| Units / motion / z | px only; 7+ easings; z-index up to 2147483600 (`client/gallery.css:2037`) | defaults | ~74 animation sites | — |
| Shell | Album top bar `page/gallery.js:53-118`; Shared tabs `client/sharedview.css:11-26` | Split-view sidebar `Browser.swift:100-142`; mostly web views (`Player.swift:83-107`); Mac window `HostApp/macOS/Window.swift:26-56` | Menu-bar panel modes `app.swift:1-30,78`; Nook `nook.swift` | — |
| Shared component | Home bar (player) `client/homebar.js`, `homebar.css:13-24`, **already copied into Recense** (`recense.swift:1166`) | — | — | — |
| Viewers | `#lb` `page/gallery.js:135-170`, plus a second Shared viewer `client/sharedview.js:396` | full-screen wrapper `Browser.swift:307-317` | caption overlay `recense.swift:1530` | — |
| Transcript / karaoke | `client/gallery.js:4604-4697` (gold `#FFD633` wipe); editor `5033+` | Read-along `Listen.swift:779-857` | Captions drawn **as images** (`recense.swift:2202-2443`) | — |
| Share UI | Create link 1/7/30 d (`page/gallery.js:198-209`); Invite 1 h…Never + Revoke (`176-197,535-572`); Shared detail `client/sharedview.js:233-393` | Create link `Browser.swift:326-361`; no link list, no revoke | — | — |
| Toasts | 3 systems: `page/gallery.js:219`, `client/gallery.js:1690`, `client/sharedview.js:50-58` | capsule `Browser.swift:283-291` | `recense.swift:1358` | macOS notifications |

## B2. Current-state audit (ranked, with file:line evidence)
| # | Issue | Evidence | Why it matters |
|---|---|---|---|
| 1 | Raw server text, including a Cloudflare 1027/429 HTML page, is shown in toasts | `client/sharedview.js:62→264,378,554,619`; `page/gallery.js:336-339,454,470`; `client/gallery.js:3674` | Trust; no next step on quota days (S4) |
| 2 | Network state is invisible on the web: refresh errors are swallowed, and an expired link silently stops refreshing | `client/gallery.js:7461-7468` | S2/S4 states must be visible |
| 3 | A failed correction save goes to a note hidden behind the viewer | `client/gallery.js:4316,4320` → `page/gallery.js:120`, `client/gallery.css:1388` | Silent data loss |
| 4 | iOS Listen keeps its unsent list in memory only, so it's lost on quit | `HostApp/iOS/Listen.swift:171-173,254` | Breaks S2 (durable outbox) |
| 5 | Conflicts are resolved silently (transcript merge, Listen 409 replace, handoff newest-wins) | `client/gallery.js:4289-4297`; `Listen.swift:241-261`; `rec/handoff.swift:87-103` | Users never see a conflict state |
| 6 | Share recipients see owner-only actions (Create link, Invite) that dead-end | `client/gallery.js:3783-3794,3570`; `worker.js:43-47` | Clarity, trust |
| 7 | The viewer has no visible Close and no Play button | `page/gallery.js:137-147`; `client/gallery.js:6950,7301` | Discoverability |
| 8 | VoiceOver: no accessibility modifiers in Gallery iOS or Recense; Recense captions are images | `apple/…/Browser.swift` (none); `rec/recense.swift:2233` | Accessibility (B6) |
| 9 | "Invite" means a private revocable link on the web but a public link on iOS; Revoke / Delete / Delete Shared Gallery naming split; two expiry option sets | `Browser.swift:405-407,596-597` vs `page/gallery.js:75-77,176-197`; `public.js:104,237` | Inconsistency with security consequences |
| 10 | Dead-end "Link not found" / "Link expired" pages | `invite.js:212-226`; `common.js:25-34`; `public.js:1488-1489` | Trust for strangers |
| 11 | No real caption tracks (no WebVTT); translations lack a `lang` tag | `client/gallery.js:2797,4836-4862,4981` | Captions vanish in PiP and AirPlay; vi/fr mispronounced |
| 12 | Reduce Motion is ignored by the karaoke wipe, the translation dissolve and Recense's panels | `client/gallery.js:4604-4697,5000-5014`; `rec/app.swift:61` | Vestibular safety |
| 13 | Secondary text contrast is 2.2–3.9:1 | `client/gallery.css:1921,1952`; `Listen.swift:813,825,847`; `rec/app.swift:3046` | Low vision |
| 14 | Touch targets under 44 pt | `client/gallery.css:357,685-694,1655`; `client/sharedview.css:24`; `rec/app.swift:749,3812` | Motor control, iPhone use |
| 15 | The iOS bearer token ships inside the app build (`ios/Secrets/token.json` from `ios/build.sh`) and is copied to the Keychain on first launch, with no pairing or per-device revoke. The Mac app quits silently without one | `HostApp/iOS/App.swift:3-4,29-33`; `HostApp/macOS/main.swift:44-47` | Security; the S8 key seam |
| 16 | Recense disappears while idle and it looks deliberate, but it is a crash (R15) | `rec/recense.swift:5074`; crash report 11-03 22:07 | Trust: things that vanish without a word feel like lost work |
**Good patterns to reuse:**
- Conflict copy at `client/gallery.js:389`: "Changed somewhere else since you opened it…"
- `identity.js:407`: "This link has expired / Ask for a new one…"
- `rec/recense.swift:3699-3704`, which names the exact Settings path.

## B3. Information architecture
**One shell, six spaces.** Same names, order and icons everywhere. iPad/Mac: a sidebar. iPhone: five tabs, with Player as the mini-player that opens full screen (the Music and Podcasts pattern). No two names share their first three letters, so a half-read word still picks the right space (A12h, line 36). The Recense strip shows the same pill + Player.
| Space | Holds | Primary app | Sealed? |
|---|---|---|---|
| Library | Files, photos, recordings, collections, Archive/Data | Gallery | no |
| Matters | Clients → Matters → Documents, opened in DEVONthink: the Mac app, and DEVONthink To Go on iPhone and iPad, synced at home. Sealed stays on the Mac | DEVONthink | **yes** (sealed by construction) |
| Study | Patent Law Corpus, question sets, confusable pairs, attempts, m4b study sets | Gallery + Recense | no |
| Folio | Your published work (Authored) and the research and literature you had access to (Readings) | Gallery | no; Readings are never shareable |
| Player | Now playing: transcript, karaoke/cadence, handoff, reading layouts | Recense engine; Gallery/Recense UI | inherits from the item |
| Share | My links (active/expired), exhibits, who opened them | Gallery | never for Matters |

**Sync-state language:** one pill and one copy table across all apps, driven by the Part A state machine.
| State | Trigger (Part A) | Shape (not colour alone) | Copy (en) | Announced |
|---|---|---|---|---|
| Up to date | outbox empty + last manifest 200/304 | check | "Up to date" (detail: "Checked 2 minutes ago") | no |
| Saving | request in flight > 2 s | arrows (static under Reduce Motion) | "Saving…" | no |
| Waiting | outbox not empty, not yet flushed | up arrow + count | "3 changes waiting to upload" | on entry only |
| Offline | no network / network error | wifi with slash | "Offline. Everything here still works. Changes upload when you're back." | once per session |
| Paused | breaker OPEN (1027/429/hard cap) | pause | "Cloud paused until 4:00 PM today. Keep working; 12 changes upload then." (local time, never "UTC") | once |
| Conflict | commit conflict / merge refused | two pages | "2 versions of “Brain Dump”. Choose one to keep." | yes, politely |
| Sealed | Matters item (DEVONthink) | lock | "Sealed: encrypted, only on your devices" | as a label |
vi/fr strings use the same keys (B6).

## B4. Pages and components
| Page | Sections (top → bottom) | Key changes |
|---|---|---|
| Shell | pill · search (⌘K) · space nav · mini-player | new pill; one toast module; one error catalog |
| Library | breadcrumbs · filter chips · grid/list · conflicts row (only when any) | viewer gets Close and Play, follow-the-finger swipe with momentum, and pinch-zoom (the "tile kinetics" mod) |
| Item sheet | preview · transcript · versions · share · info | the versions list doubles as the conflict resolver |
| Matters | lock state · last home-network sync · "Open in DEVONthink" | a status-and-launch page: client names, documents and deadlines never enter Gallery; no Share button |
| Folio | Authored · Readings · recently opened | new; pinned offline by default; no Share on Readings |
| Study | today's set · confusables (shall/may, owner/assignment…) · attempts | attempt before reveal; spaced review |
| Player | transcript (karaoke) · trigger-word emphasis · section beat (variant 1–3, pin) · handoff banner | "Continue from iPad at 12:34 — ‘shall’" banner; reading layouts; loops play from the local copy or from memory, with no gap at the loop point (A13) |
| Share | active links · expired · create (1 h, 1 d, 7 d, 30 d) · extend · stop sharing | one name for ending a link: **Stop sharing**; extend in place. Three verbs: **Copy link**, **Send a copy** (AirDrop, works offline), **Show QR** (same network) (A14) |
| Public share page | owner + expiry line · content · transcript with `?t=` deep link · privacy note | no owner actions; a useful expired page |
| Settings | Reading & Accessibility (first) · Sync & Storage (status in words) · Devices and their keys | new |
| Recense strip | pill · Essentials landing (Bitwarden panel), Draftpad second | fixes the landing order (brain-dump bug) |
| Recense dual edges (brain dump line 60; SL7) | **Make**: Draftpad, capture, dictation · **Check**: SL7 widgets (Find My first), calendar, sync pill, Matters lock | • Either or both can be open, sliding like Notification Center.<br>• Each opens from whichever edge you swipe in from: two fingers for Make, three for Check. The finger count decides, never the side (B9).<br>• Edge hover and a shortcut also open them.<br>• On your Mac the system's own edge swipe (Notification Center) and its three-finger gestures are off, so nothing clashes.<br>• At most two live web widgets on 8 GB; hidden ones keep a snapshot.<br>• An offline widget shows its last snapshot and its time, never invented data |

**Reuse / extend / create**
| Component | Today | Decision |
|---|---|---|
| Home bar (player controls) | `client/homebar.js`, shared with Recense | **Reuse**; extend with visible Play, ±15 s, Close |
| Viewer | 3 viewers | **Extend** `#lb`; retire the Shared viewer; the iOS wrapper keeps the web viewer |
| Transcript renderer | web `client/gallery.js:4604+`; iOS `Listen.swift:779+`; Recense images | **Extend** the web one as canonical; Recense captions become real text (VoiceOver) |
| Toast | 5 systems | **Extend** `#mtoast` (already announced, `page/gallery.js:219,275`) into one module; native mirrors it |
| Share sheet | 3 variants | **Extend** the web sheet; iOS calls the same API |
| Conflict UI | text conflict sheet `client/gallery.js:389`; Changes/Restore `5033+` | **Extend** into Versions/Conflicts |
| Tokens | 4 sets + Recense constants | **Create** one `tokens.json` → CSS + Swift |
| Sync pill, budget meter (in words), handoff banner, Matters lock badge, trigger-word emphasis, reading panel | none | **Create** |

## B5. Tokens and responsive behaviour
| Token group | Change |
|---|---|
| Colour | The README's semantic names (`--bg`, `--surface-1/2`, `--text-1/2/3`, `--accent`) win over `gallery.css`. Add a **light theme** and increased-contrast variants. State colours `--state-ok/wait/offline/paused/conflict/sealed`. Karaoke `--kara-now #FFD633`; upcoming words at opacity ≥ 0.55 (0.35 fails contrast) |
| Type | Web: rem + `clamp()`, respecting the browser's text size. Apple: text styles only. Recense: one UI text-size preference that scales the whole UI, not just captions |
| Reading | `--read-letter` (0 / .05em / .12em), `--read-word`, `--read-measure` (35ch focus / 60ch / 75ch), `--read-leading` (1.5 / 1.8), `--trigger-weight`, `--trigger-underline` |
| Space / radius | spacing 4·8·12·16·24·32; radius 6·10·14·24 |
| Motion | fast 150 ms, base 240 ms, slow 400 ms, one easing; all → 0 under Reduce Motion |
| Z | named layers: content, chrome, sheet, toast, modal |
| Layout | **iPhone:** tab bar, one column, mini-player.<br>**iPad:** sidebar + content; transcript beside the media in landscape.<br>**Mac:** sidebar + toolbar; the Recense strip uses the same tokens.<br>**Share page:** single column ≤ 720 px, follows the system light/dark setting |

## B6. Accessibility (first-class)
| Need | Requirement | Implementation note |
|---|---|---|
| Low vision | All text ≥ 4.5:1, secondary text included; light and high-contrast themes; 200 % text with nothing lost | fix B2 #13; rem units; Dynamic Type |
| Dyscalculia | Times in the local clock, never UTC; budgets in words ("plenty", "getting low", "paused"); durations like "about 3 minutes"; exact numbers on tap | copy table in B3 |
| ADHD / autistic | Predictable layout; one calm status; no surprise auto-play; beats change only at phrase/section boundaries; ≤ 3 variants per section + pin | matches the brain-dump cadence rules |
| Read carefully | A focus window that dims or blurs everything outside the current sentence (static under Reduce Motion); short lines; extra letter and word spacing; one sentence at a time; attempt before reveal | evidence below |
| Trigger words | shall/may/must/not/only/unless/except/any/each…: heavier weight + thick underline + a sustain in the cadence (never colour alone); an "announce emphasis" option for VoiceOver | renderer + the m4b manifest triggers |
| Bionic reading | Available but **off by default** (no evidence of benefit) | Reading panel |
| Motion | Karaoke wipe → instant highlight; no glow; panel animations → fades | B2 #12 |
| Captions / karaoke | Real WebVTT tracks (so they work in PiP, AirPlay and full screen); Recense captions as text views | B2 #11 |
| VoiceOver | A label on every icon button; custom views expose accessibility elements; a transcript rotor by line | B2 #8 |
| Trilingual en/vi/fr | Strings tables (`Localizable.xcstrings`, a web JSON catalog); `lang` on every translated line; vi line height ≥ 1.5 for stacked diacritics; fr narrow no-break space before `; : ! ?` and room for ~20 % longer strings; locale-aware dates (drop the forced UK format at `client/gallery.js:84-87`) | — |

**Evidence base**
| Feature | Evidence | Status | Decision |
|---|---|---|---|
| Extra letter spacing | Zorzi et al. 2012, PNAS 109:11455 ([PubMed](https://pubmed.ncbi.nlm.nih.gov/22665803/)) | VERIFIED | "Read carefully" spacing toggle |
| Short lines | Schneps et al. 2013, PLOS ONE, Harvard-Smithsonian ([DOAJ](https://doaj.org/article/f5229dc27a5a47a881e605bef86ca805)) | VERIFIED | Focus layout with few words per line |
| Bionic reading | "No, Bionic Reading does not work", Acta Psychologica 2024 ([VU](https://research.vu.nl/en/publications/no-bionic-reading-does-not-work/)) | VERIFIED (speed only) | optional, off by default |
| Attempt before reveal | Karpicke & Blunt 2011, Science 331:772 ([PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC3577217)) | VERIFIED | Study mode hides trigger words until you attempt them |
| Music under reading | Kämpfe, Sedlmeier & Renkewitz 2011, Psychology of Music ([SAGE](https://journals.sagepub.com/doi/10.1177/0305735610376261)): small negative effect on reading and memory | VERIFIED (abstract) | beats live in rests and response slots; A/B against no beat |
| Melody aids recall | Wallace 1994, JEP:LMC 20:1471 ([Springer](https://link.springer.com/article/10.3758/BF03193445)): mixed results; presentation-rate confound | VERIFIED (secondary) | a fixed frame layer per file |

## B7. Trust design
| Surface | What the user sees |
|---|---|
| Settings → Where your data lives | Three plain lines: "On this device", "In your cloud storage (Cloudflare R2)", "Sealed: encrypted on your devices; the cloud only stores locked copies" |
| Offline guarantee | The pill, plus a first-run line: "Works fully offline. The internet only moves copies." |
| Quota day | One banner with the local reset time and the queued count; no red, no modal (B3 Paused) |
| Errors | An error catalog maps every (status, code) to a calm sentence and one next step; raw server text is never shown (B2 #1) |
| Explicability | A "Why this word?" popover: what was heard, the confidence, the correction history (asr.json / corrections.json) |
| A family member opening a link | The owner's name, what was shared, the expiry in their local time, "Only people with this link can see this. No ads, no tracking." The name prompt says who sees comments and discloses the country flag |
| A stranger / expired link | "This link from Chau has ended. Ask Chau for a new one." No file names leak |
| Matters | No Share button anywhere; the documents stay in DEVONthink, sealed |

## B8. Order, risks, open questions
| Step | Depends on | Risk |
|---|---|---|
| 1 Error catalog + one toast + the pill (states from Part A) | phase 1 | low |
| 2 `tokens.json` + light/contrast themes | — | visual regressions → screenshot tests (existing Playwright `test-results/`) |
| 3 Share page + Share space (naming, expiry, `?t=`) | presign + share API | old links keep working (no URL change) |
| 4 Viewer (Close/Play/kinetics) + captions as WebVTT | — | gesture conflicts in the iOS web view |
| 5 Reading panel + trigger emphasis + attempt before reveal | m4b manifest (A5) | over-stimulation → conservative defaults |
| 6 VoiceOver / Dynamic Type pass (Gallery iOS, Recense) | 2 | rewriting Recense's image captions is large |
| 7 Matters status page (DEVONthink) | phase 6 | A6 ethics checks come first |
| 8 Folio + Study shelves | phase 2 (pinning) | licences on Readings |
| 9 Recense dual edges (SL7 + its mirror) | the SL7 Find My spike | memory on 8 GB; gesture clashes |
**Open questions (not blocking):**
- "Swap Revoke for Revert": just a rename, or a different action (undo the last change)?
- Organism H5 (moving the engine to Sync) and the D1 branch both need the owner's confirmation.

| Step (added 11-05) | Depends on | Risk |
|---|---|---|
| 10 Languages: catalogs, `lang`, locale formats (B11a) | 2 | strings missed in images → the pseudo-language test |
| 11 Reading rails: ribbon, reading mode, reflow, outline first (B11b) | 2, 5 | — |
| 12 Gesture grammar + visible twins; the stage-swipe finger check (B9b) | 4 | Safari's back/forward swipe → test in Safari first |
| 13 The console without the home bars; one global speed (B9c–d) | 12 | learnability → progressive zones |
| 14 Haptics and audio textures, Off · Emphasis · Words · Rhythm (B10) | 13; the self-test | a wrong cue teaches the wrong emphasis → closed word list |

## B9. Buttonless, hand-neutral gestures (11-05 note, lines 5, 32, 85–131)
**The rule (line 111):** meaning comes from direction and finger count, never from the side of the screen or the hand. Every position is measured from where your fingers land, so a zone is wherever you touch.
**Verdict:** accept, on one condition: every gesture keeps a visible twin that a single tap reaches.
- That is your "keep the social buttons visible" (line 5).
- It is also the accessibility rule: WCAG 2.2 criteria 2.5.1 (multi-finger and path gestures) and 2.5.7 (dragging) require a single-pointer alternative.
- VoiceOver users can't feel invisible zones.

**a. What exists today** (read-only audit, 11-05)
| Surface | Gestures | Haptics |
|---|---|---|
| Gallery web | • Stage swipes don't check the finger count, so a pinch may count as a swipe (`client/gallery.js:7626-7664`).<br>• Viewer framing drag/tap (`client/viewer-shell.js:80-125`).<br>• Swipe-to-delete comments (`:4058-4127`).<br>• The comment label ⇄ Share swipe (`:3970-3995`); its `preventDefault` is at `:3978`. The note's `:3738` is a zip import.<br>• Hold-to-seek and a Force Touch bookmark (`client/homebar.js:1114-1127`).<br>• Folder-chip long press (`main.js:593`).<br>• The "pinch over the lyrics" comment (`:805`) has no code | `navigator.vibrate` (`:5436`, `main.js:598`) does nothing on Apple devices |
| Gallery iOS (native parts) | pull to refresh; a context menu (`Browser.swift:240,488`); swipe actions (`Listen.swift:692`) | none |
| Recense | three-finger vertical swipes through MultitouchSupport (`app.swift:348-386`); a two-finger rest-hold (`:327`); two-finger panel paging (`:4791-4828`) | `NSHapticFeedbackManager` (`app.swift:872,2912,2932,3682,3730`) |
| Your Mac's settings | three- and four-finger system swipes are off, and so is Notification Center's edge swipe. Two-finger "swipe between pages" is at its default | — |
**Visible controls today:**
- Select / Select All / Deselect All (`page/gallery.js:60,67`), "…" (`:63-101`), Download (`:121`; `client/gallery.js:7197`).
- The comment label and field (`client/gallery.js:3953,4380`).
- Like beside Hide Comments (`:4210`). The viewer's `like` API (`:3643-3651`) is never called.
- Ask (`#aibtn`, `page/gallery.js:62`).
- The Mac toolbar mirrors them (`apple/HostApp/macOS/Window.swift:151-192`).

**b. The grammar** (the same on every surface; the last column is the visible twin, which stays)
| Meaning | iPhone / iPad | Mac trackpad | Feedback | Visible twin |
|---|---|---|---|---|
| Play / pause | tap | click; Space | — | — |
| Next / previous item | one-finger swipe sideways | two-finger swipe sideways, claimed from Safari's back/forward (`overscroll-behavior-x: none` plus a non-passive `wheel` listener, as at `:3978`) | a tick per item; a firmer thud at the first and last | — |
| Seek | press and hold, then drag sideways from that point | click and drag sideways | a tick per line (per word when zoomed in), with extra detents at bookmarks, A–B points and comment times | the time, shown only while dragging |
| Like | double-tap (`touch-action: manipulation` stops Safari's double-tap zoom) | double-click | the heart counts up | heart + count |
| Comments | swipe up | two-finger swipe up past the end | the sheet opens on "Add a comment…" | "n comments" + the "Add a comment…" line |
| Ask | two-finger swipe up | ⌘K | the Ask sheet opens on this item and time | an Ask chip |
| More ("…": download, share, info) | long press | force click or right click | the system menu | "…" |
| Select / deselect (grid) | two-finger drag across items, then tap to toggle | ⌘-click, Shift-click, drag a box | a tick per item | Select |
| Close | swipe down or pinch in | Esc or pinch in | — | — |
| With VoiceOver | every action above is a custom action, and every console control an adjustable value | — | — | — |
- **Finger counts on a Mac** reach only native code. A web page gets wheel deltas, pinch and click-drag. So the full grammar lives in Recense (raw touches) and the Gallery iOS app; Gallery in a Mac browser uses the trackpad column.
- **iOS edges:** never start a gesture at a screen edge (Home, Control Center, back).
- **Fix first:** the stage swipe must check that exactly one finger moved.

**c. The console without the two home bars (lines 116–118, 129)**
The console is the home bar's speed and sound controls: speed, level, tone (EQ), key, space (room) and voice.
- **Open it:** hold two fingers still anywhere: Recense's existing rest-hold (`app.swift:327`), a two-finger long press on iPhone and iPad, or press and hold in a Mac browser. Nothing appears on screen.
- **Choose a control by invisible zones:** move up or down from where you pressed. Each zone boundary ticks, and the number of ticks tells you where you are. The sound itself confirms it.
- **Change it:** move sideways. Detents tick, and the home value (1×, 100 %, flat, 0, off) is a thud.
- **Leave:** lift your fingers; values stay. A two-finger double-tap resets the control you're on.
- **Progressive:** the console starts with two zones (speed, level). Tone, key, space and voice unlock in Settings once those feel natural.
- **Hand-neutral:** zones are measured from your fingers, so they mirror themselves.
- **Is it allowed on Cloudflare, and does it work offline (line 129)?** Yes to both. Gestures and haptics run entirely on the device; Cloudflare only serves files.
```
 today: two home bars                      the console: nothing is drawn
┌────────────────────────────────┐        ┌────────────────────────────────┐
│                          ┃     │        │                                │
│          media           ┃ ◀── vertical │             media              │
│                          ┃     │  bar   │  hold two fingers anywhere,    │
│                          ┃     │        │  then move:                    │
│ ◀◀  ▶  ▶▶  ──●───────  1×  🔊  │        │      ↑↑  2 ticks  tone         │
└────────────────────────────────┘        │      ↑   1 tick   level        │
  ▲ horizontal home bar                   │      ●   ◀ speed ▶  (your hold)│
                                          │      ↓   1 tick   key          │
                                          │      ↓↓  2 ticks  space        │
                                          └────────────────────────────────┘
                                            the labels exist only in this sketch
```
- **Recense's three-finger swipes (layers) can stay:** your Mac has the system's three-finger gestures off. On a Mac with default settings they would also trigger Mission Control.

**d. One speed for everything (line 32)**
| Today | Change |
|---|---|
| Gallery web:<br>• The home bar's 0.5–2× slider has 7 steps (`client/homebar.js:106`; its comment at `:611` says 6).<br>• `<` / `>` keys (`client/gallery.js:7613`).<br>• Forced back to 1× in Safari when Sound is on (`:1745-1754`).<br>• Per page, never saved | one value per device, saved, and carried in the handoff cursor (`rate` is already in the A5 schema), so it follows you between devices |
| Recense: the home bar sends speed to a browser tab (`recense.swift:6475`) or QuickTime (`:6452`); nothing for Music (`:6465`) | Recense's control becomes the global one. Where a player can't change speed (Music), it says so instead of failing silently |
| Gallery iOS/Mac native: none | `AVPlayer.defaultRate` |
| — | the console's centre zone, with detents at 0.5, 0.75, 1, 1.25, 1.5 and 2×, and the thud at 1× |

## B10. Haptics and audio textures for reading and listening (lines 33, 35–82, 119–131, 143)
**Verdict:** accept haptics for orientation and emphasis, which the evidence supports. Object to haptics as a comprehension engine for dense legal text, which no study has shown. Your own three-condition test (c) decides.

**a. What each device can do**
| Device | Haptics | Limits |
|---|---|---|
| Mac trackpad (Force Touch) | three patterns: `.generic`, `.alignment`, `.levelChange` | felt only while a finger touches the trackpad; no strength or length control. The research's 3-second swell can't be made here |
| iPhone | Core Haptics: taps and continuous vibration with strength and sharpness, AHAP pattern files, sync with audio | not from a web page, because Safari has no vibration API. The Gallery iOS app can bridge it: page → `WKScriptMessageHandler` → Core Haptics |
| iPad | no built-in haptics: Apple's guidelines list them only for iPhone, Apple Watch and Force Touch Macs. An Apple Pencil Pro gives feedback while drawing (`UICanvasFeedbackGenerator`, iPadOS 17.5+), and so do some keyboard trackpads | sound and visual cues instead |
| Apple Watch (if you wear one) | wrist taps from a fixed set | a phone or a watch is the only place a swell can live |
| Bose QC35 | no vibration motor | **audio textures only** (d) |

**b. The cue vocabulary.** At most 3–4 cues per channel, and the modes are exclusive: **Off · Emphasis · Words · Rhythm**, a menu beside Show Captions.
| Mode | Cue | Mac trackpad | iPhone | Audio texture |
|---|---|---|---|---|
| Emphasis | Orientation: chapter, section and subsection starts (MPEP headings are already chapter markers), plus a cue that grows toward a chapter's end | `.levelChange` at chapters, `.alignment` at sections | three strengths; a slow swell near the end | the m4b frame's cue tone at chapter starts (A5) |
| Emphasis | Obligation words in three tiers: must/shall · may · must not/shall not. MPEP's "should" is a fourth: off by default, your call | `.alignment` on each word. The Mac can't vary strength, so the audio texture carries the tier | firm double · single soft · sharp triple | presence lift · slight widening · low thump |
| Emphasis | Defined terms (first use) and unless/except | `.generic` | light tick | — |
| Words | Your haptic score on the light's clock: line starts and word onsets. Words marked `un` are skipped, and a liaison run is one click | `.levelChange` / `.alignment` (your spec) | light ticks | — |
| Rhythm | Words, plus strong syllable onsets at least 100 ms apart | `.alignment` | lighter ticks | — |
- **Build once:** the haptic score is computed per episode and cached beside the prosody (`features.json`); playback only reads it.
- **Timing:** the light leads and the cue follows within ≈ 50 ms. Your 20–260 ms tolerance was measured on whole paragraphs, so single words need tighter timing.
- **Closed list only:** a wrong cue teaches the wrong emphasis (the "dark haptics" finding). Obligation cues fire only on listed words, which a keyword match finds reliably.
- **Review mode** replays the defined-term ticks, so you recall each definition before the audio gives it (line 80).

**c. Test it on yourself first (line 36)**
- Split an MPEP chapter into sections. Rotate three conditions across them: targeted cues, random cues and no cues.
- After each section, take Study's recall quiz: attempt before reveal, recorded as Attempts (A5).
- After about 30 sections, keep what beat random and drop the rest.

**d. The QC35's "over-the-ear textures" (lines 33, 131, 143)**
- **Verdict:** accept as audio emphasis, not as touch. The QC35 has no motor, but sound alone changes how texture feels (the ICAD survey of 89 papers; it measured sensation, not comprehension).
- **How:** Recense's sound chain (EQ, key and space in `recense/recense/soundengine.swift`) adds a word-length texture at each cue word's timestamp: a presence lift (must/shall), a slight stereo widening (may), a low thump (must not). It stays within the same three-cue ceiling.
- **Binaural beats: object.** The evidence that they help attention or memory is small and mixed. A Mono option stays for one-ear listening.
- **Legal design** (Haapio, Passera, Hagan; Brunschwig's multisensory law): the field has reached sight and sound. Touch for law is still a concept without tests, so your self-test (c) would be new evidence.

**e. Sonification and audio descriptions (lines 23, 108)**
- **Data planes:** one finger sideways moves through time, up and down through categories, and a pinch changes granularity. Each plane has its own timbre and values become pitch. A tick marks each data point, and holding still narrates.
- **First dataset:** the request budget and storage totals (A8, A2), numbers you'd rather hear than read. A calm tone rises toward the soft limit.
- **Audio descriptions** are written on the device (A16) and spoken as their own track, never mixed over speech.

## B11. Your languages, and reading without losing your place (lines 3, 92–107, 152)
**a. The whole app in French or Vietnamese (line 3)**
- **How it works:** iPhone, iPad and Mac show an app in the first language on your preferred list that the app ships, and people can pick a language per app in Settings. A web page reads the browser's languages.
- **So the work is:** translate every string, declare the languages, and format dates and numbers by locale.
- **Today** (string counts are estimates):
  - **Gallery Apple:** no string files. The iOS project knows only `en` and `Base` (`apple/ios/GalleryFiles.xcodeproj/project.pbxproj:67`). About 100 strings.
  - **Gallery web:**
    - `lang="en"` is hard-coded (`page/gallery.js:39`, `worker.js:160,188`, `shared.js:211`).
    - There is no catalog, and plurals are inline English (`client/gallery.js:3953`).
    - Dates are forced to UK format and 24-hour time (`:84,87`), while `client/viewer-sheet.js:34-36` uses the system's, so one viewer shows both (`:95`).
    - About 500 strings.
  - **Recense:** no languages declared, no `lang` (`homebar/index.html:5`), fixed `en_US_POSIX` date formats (`app.swift:3555-3560`). About 300 strings.

| Where | Steps |
|---|---|
| Recense, Gallery iOS/Mac | 1. Route every visible string through `String(localized:)`; SwiftUI `Text` already does.<br>2. One `Localizable.xcstrings` catalog with en, fr and vi, plurals included. Gallery adds `fr` and `vi` to its Xcode project's regions.<br>3. Recense builds without Xcode, so `build.sh` compiles the catalog into `fr.lproj` and `vi.lproj` (`xcstringstool`; ASSUMED, test it) and lists `CFBundleLocalizations` = en, fr, vi.<br>4. Dates, times, numbers and durations go through `FormatStyle`, never fixed formats.<br>5. Test with the `-AppleLanguages (fr)` launch argument, and with a pseudo-language to find clipped labels (French runs ≈ 20 % longer) |
| Gallery web, share pages | • One JSON catalog per language, bundled so it works offline.<br>• Choose by `navigator.languages`, or by the `Accept-Language` header for pages the Worker renders, with a setting to override.<br>• `lang` on `<html>` and on every translated line (B6).<br>• `Intl.DateTimeFormat`, `Intl.PluralRules` and `Intl.RelativeTimeFormat` replace the forced formats |
| Translations | drafted on the Mac by the on-device model (A16) and reviewed by you; legal copy never ships unreviewed |
| Content | transcripts and captions are already trilingual (A7); this work is the interface |

**b. Reading without losing your place (line 152)**
- **Plainly: it's not you.** Apple Notes' defaults are long lines of thin, low-contrast text with nothing to mark your place, and without glasses the lines blur. Your eye has nothing to hold, so it jumps.
- **The design gives it rails:**

| What happens (your words) | Rail | Where |
|---|---|---|
| "my eye loses its place" | **Margin ribbon:** a marker in the margin that survives scrolling and app switches (line 106); the current line is underlined | reader, Draftpad, transcripts |
| "fuzzy lines" | **Reading mode:** larger, heavier, high-contrast text; 1.8 line spacing; 45–60 characters per line; one centred column (line 102) | tokens (B5) |
| "jumping around to gather context" | **Outline first:** a long text opens with its headings and a three-line summary (A16), then the body. The table of contents updates itself (line 134) | reader, Draftpad |
| walls of text | **Reflow:** long paragraphs break into short chunks with space between (line 107). Focus shows one sentence at a time | reader |
| "leap to conclusions… fall into exam traps" | **Guard rails:** attempt before reveal; the trigger words (shall, may, unless…) weighted and underlined (B6, B10) | Study |
| losing your place while listening | Text, highlight and speech in sync, with a word-by-word reveal (line 104). A pause at each new chapter, with a short spoken summary of the last one (line 105) | Player |
| speak screen everywhere (lines 98, 103) | Already in the system, no code needed: Settings → Accessibility → Spoken Content. On iPhone and iPad, Speak Screen is a two-finger swipe down from the top; on the Mac, Speak Selection is ⌥Esc. Recense and Gallery must show real text, not pictures of text (B2 #8), for it to work | everywhere |
| mirroring (lines 92–94) | One symmetric centred column needs no left/right mirroring. Use CSS logical properties anyway (`margin-inline-start`…), so a mirrored layout or a right-to-left language is one attribute later | web |
- **For this plan:** read "What you have" first, then the summary. Every section opens with a one-line verdict.
