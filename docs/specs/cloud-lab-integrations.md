# Cloud Lab: integrations and the integrative approach

**Status:** revised 2026-10-08 after reading the complete `worker.js` (build `2026-10-07-lab-v1`). Companion to `sync.md` (the sync engine spec; read it first for the contract).
**Home:** the cloud lab Claude project (canonical). Recense gets only the slice at the end.
**IDs:** L1 to L16 keep their numbers from the earlier draft; L17 to L21 are new.

> **What changed in this revision.** The earlier draft said the lab was unspecified and that the gallery code was cut off at line 103. Both are out of date. The full file shows the lab already exists: `/lab` is an owner-only, read-only library over `lib/files/`, served by the same Worker, behind Cloudflare Access. This revision replaces "unknown" with the real shape, adds how the pieces fit together, lists gaps found in the code (section 4), and re-grades L1 to L16 against what the code actually does.
> **Still not known:** what the lab grows into beyond browsing and playing. The only hint in the code is "organizing will live in small JSON files beside them". Anything about that is marked **(assumption)**.

---

## 1. What is known (from the code)

| Piece | Facts |
|---|---|
| **Web Worker** (`worker.js`, build `2026-10-07-lab-v1`) | One plain-JS file. One R2 binding `BUCKET` (the `share` bucket). Secret `UPLOAD_PASSWORD`. Variables `OWNER_EMAIL`, `ACCESS_TEAM_DOMAIN`, `ACCESS_AUD` (without them `/lab` answers 404). A Cron Trigger that runs `cleanup`. No D1, no Queues, no `/health`. Pages and JSON carry an `x-version` header; file bytes do not |
| **Share module** | Keys `shares/<id>/<nnn>` (file), `.art` (cover), `.progress` (upload ring), `.manifest` (JSON written before any upload, so the link works at once). Ids are 8 to 32 letters and digits, chosen by the client (the upload page makes 12). 1 to 365 days (default 7), at most 1000 items. Files over about 90 MB go up as R2 multipart in 32 MiB parts. A share also works with **no manifest** (it exists if any ready object is under its prefix) |
| **Lab** | `/lab?p=<folder>` lists `lib/files/<path>` from R2 (folders, breadcrumbs, files) in the gallery viewer. `/lab/f/<path>` serves bytes, `?art=1` serves cover art cached at `lib/art/<path>`. Files get there by `rclone` straight into R2, so no upload passes through the Worker. Read-only today: owner gets 405 for anything but GET and HEAD. Dotfiles, `Thumbs.db`, `desktop.ini` are hidden. At most 5000 items per folder |
| **Lab access** | Cloudflare Access JWT, verified inside the Worker (RS256 signature against the team's published keys, audience, issuer, expiry), and the email must equal `OWNER_EMAIL`. Anyone else, and any misconfiguration, gets the same 404 as an unknown link |
| **Player** | Same viewer for shares and lab. Key shift of ±12 semitones without changing tempo (phase vocoder in an AudioWorklet served at `/player/key.js`), speed 0.5 to 2×, track loop, A–B loop, 3-band EQ (±15 dB), reverb (two rooms), a hold-to-open time ruler, picture-in-picture, a Safari "deck" path, and download of audio **with the sound baked into a WAV**. All settings live in page memory only |
| **Page engine** | `galleryPage(live, nav)` renders any item list: a share, or a lab folder. `live.title`, `live.heading`, `live.zip` reframe it; `nav` is raw HTML above the grid. Matching by base name already pairs a same-named image with an audio file as its cover |
| **Recense** (`app.swift`) | R2 tray over `rclone` (remote `r2`, bucket `share`); recorder (`.m4a` to the Voice Memos folder, `.mov` to `~/Recordings`); Media panel (Whisper transcripts to `~/Documents/Recense Transcripts`, ffmpeg compress); Finder Quick Action "Copy Share Link"; Bitwarden vault; DEVONthink hub; notebook panel running the Claude CLI in the Obsidian vault; voice "Side Quest" into Calendar; Draftpad note in iCloud Drive; agenda ranking that reads `[URGENT]`, `[DEADLINE]`, `[GOAL]` title markers |
| **Sync engine** (`sync.md`) | CalDAV on a Cloudflare Worker, R2 + D1, per-user ids, per-device passwords, share links, email in and out, second-vendor backup, `/health` (planned) |

## 2. What the lab is, and the role it plays

**The lab is the owner's private library:** files copied from drives, exactly as they were, browsed folder by folder and opened in the shared viewer and player. **(assumption)** The player's features (key without tempo, A–B loop, speed, EQ, baked-sound download) are practice and listening tools, so the library is probably audio-heavy. Confirm.

The earlier draft asked Chau to pick a role. The code settles most of it:

| Role | Status |
|---|---|
| **Apps** | **Built.** `/lab` is the first app. Recording pages, an admin page and event pages are the next ones |
| **Platform** | **Not built.** Identity, a prefix registry, replication, monitoring and the runbook come from the sync engine and apply to every app |
| **Sandbox** | **Absent.** Nothing isolates experiments from `lib/` or `shares/`. Recommendation: a separate bucket with no replication when one is needed |

## 3. How the pieces fit

### 3.1 Deployment shape (recommendation)

```
~/Developer/sync   (one repo)
  core/   ports (Store, Index, Mailer, Clock), ids, tokens, prefix registry     TypeScript
  dav/    CalDAV now; CardDAV and WebDAV later          -> Worker "dav"   at cal.<domain>
  web/    today's worker.js: share, upload, lab, player  -> Worker "web"   at share.<domain>
  ui/     page engine (GALLERY_CSS, GALLERY_JS, galleryPage) and the player
```

Two Workers, one repo, one R2 bucket binding each (plus D1). Why not one Worker:

- **Change safety** (`sync.md` section 4): a lab UI deploy must not be able to break calendar sync.
- **Different front doors:** the DAV hostname may need a WAF skip rule for Apple clients; the lab needs Access.
- **CPU:** lab listings and tag parsing are heavier than DAV requests, and the DAV Worker should stay small and deterministic.

The share module is a package both can import. Event pages (tier A) live on `web` and read the event through a service binding to `dav` (verify Workers RPC) or a read-only D1 query. Step one is only moving `worker.js` into `web/` unchanged.

### 3.2 Hostnames and Access

- `cal.<domain>` serves DAV. `share.<domain>` serves shares, the upload page and the lab at `/lab`, on a domain Chau controls with a low TTL.
- The Access application covers **`share.<domain>/lab*` only**. An application over the whole host would put every share link behind a login.
- The Worker verifies the Access token itself, so a request that reaches it around Access (for example on a `workers.dev` address) still gets 404. Keep that check when the code moves.
- `ACCESS_AUD` belongs to the Access application. If the application is recreated, `/lab` answers 404 until the variable is updated. Record the AUD in the repo's config notes and test `/lab` after any Access change.

### 3.3 Who can reach what

| Surface | Who | Mechanism today | Target |
|---|---|---|---|
| `/s/<id>`, `/f/<id>/<nnn>`, `/api/gallery`, `/player/key.js` | Anyone with the link | Capability URL; per-object `expires` | Same, plus revoke (L20) |
| `/` upload page | Anyone can load it; it does nothing without the password | Static HTML | Same |
| `/api/upload`, `/api/share` | The owner's tools: upload page, Finder Quick Action, curl | `x-password` equals `UPLOAD_PASSWORD` (one shared secret, plain `===`), checked in one function, `authed()` | Scoped, revocable tokens, constant-time (L2) |
| `/lab`, `/lab/f/*` | Owner in a browser | Access JWT checked in the Worker, email equals `OWNER_EMAIL` | Same; a user list when family arrives (L16) |
| `/dav/*` | Devices | Not built | Basic with per-device app passwords (`sync.md` section 9) |
| `/admin/*`, `/mcp` | Owner, Claude | Not built | Separate secret; OAuth or scoped token (L10, L15) |

A Cloudflare Access **service token cannot open `/lab`**: its JWT carries no email (a `common_name` instead; verify), so the owner check fails. Machines use `/api/*` or `/mcp`, never `/lab`.

### 3.4 Storage map (the prefix registry)

The earlier draft proposed `app/<service>/u/<userId>/...`, `sync.md` has `u/<userId>/cal/...` and `g/<shareId>/...`, and the code has `shares/` and `lib/`. Three layouts is too many. **Decision: the code's layout is canonical for what exists, keys never move** (the lab already states this rule). A small **prefix registry** in `core/` says what each prefix is, and everything else (cleanup, replication, scrub, tokens) reads it:

| Prefix | Service | Written by | Expires | Replicate | Rebuildable |
|---|---|---|---|---|---|
| `shares/<id>/<nnn>` and `.manifest` | share | Worker (upload API) | Yes, `expires` metadata, `cleanup` cron | **No** (L3) | No, by design |
| `shares/<id>/<nnn>.progress` | share | Worker | 2 days | No | Yes |
| `shares/<id>/<nnn>.art` | share | Worker (cache) | With its share | No | Yes, from the audio file |
| `lib/files/<path>` | lab | **rclone only** | Never | **Yes** (see rule 11) | It is the data |
| `lib/art/<path>` | lab | Worker (cache) | Never | No | Yes |
| `lib/meta/...` (new, L18) | lab | Worker, owner only | Never | **Yes** | No |
| `u/<userId>/cal/...`, `u/<userId>/trash/...` | dav | Worker | Trash 30 days | **Yes** | Index only |

`lib/` is the owner's, so in registry terms it is an alias for `u/<ownerId>/lib/`. Family users later get `u/<userId>/lib/` and nothing is renamed.

**The cleanup cron lists `shares/` only, and must stay that way.** That is why the lab can never expire. Every new job names its prefix; none may scan the bucket for "anything with an `expires`".

### 3.5 One bucket or two

The lab sits in the same bucket as the shares. R2 API tokens are scoped to a bucket (I know of no prefix scoping; verify), so an `rclone` token that can write `lib/files/` can also overwrite or delete `shares/`, and the engine's plan for a private bucket separate from `share` does not hold. **Recommendation: give the lab its own bucket (`lab`) and a second binding `LAB`** before the library gets large. The change is small: `labFolder`, `labFile` and `labArt` switch from `env.BUCKET` to `env.LAB`, and `rclone copy` moves the existing `lib/` over. The prefix names stay.

## 4. Gaps found in the code

| # | Finding | Why it matters | Fix |
|---|---|---|---|
| F1 | Share ids are chosen by the client: 12 letters and digits is about 71 bits, and the server accepts 8 to 32 characters (8 is about 48 bits). `start` overwrites an existing manifest with the same id | Rule 4 asks for at least 128 bits, server-issued | Server issues ids of 22 or more characters (22 is about 131 bits; 32 fits `ID_RE`); `start` refuses an id that exists; old links keep working (L20) |
| F2 | There is no revoke. A link dies only by expiry | Rule 4 asks for revocable | `action=revoke` deletes the share's prefix (L20) |
| F3 | The id is the R2 key prefix, so anyone who can list the bucket sees every live link. That includes an `rclone` token and a backup copy | Rule 4 asks for hashed at rest | Do not replicate `shares/` (L3). For new shares, decide whether to key by SHA-256 of the id and read the old layout as a fallback (L20) |
| F4 | `authed()` compares with `===` and there is one shared secret, kept in `localStorage` by the upload page | `sync.md` requires constant-time comparison and per-device revocation | L2 |
| F5 | There is no `/health`; unknown paths return the 404 page | The monitor, Recense's cue and `sync.md` all assume one | L14 |
| F6 | A lab folder is cut at 5000 items with no notice. Each view costs up to five uncached R2 list calls (1000 per call) | Silent loss of visible files; slow big folders | Notice and paging (L21); an index (L19) |
| F7 | `lib/art` is cached forever with no check that the source file is unchanged, and is never cleaned when the source is deleted | A replaced file shows its old cover; orphans pile up | Store the source etag and size with the art; sweep in the cron (L21) |
| F8 | Lab item ids (`n`) are positions in a sorted listing, so they shift when files are added. File URLs use the path and are stable | Anything saved about a file must not use `n` | Key by path (L18) |
| F9 | `notice(title)` writes its argument into HTML unescaped | Safe today (every caller passes a literal); unsafe the moment an event title or file name is passed | Escape it (L21) and see rule 3 |
| F10 | The page loads pdf.js (pinned 3.11.174) from cdnjs and client-zip (`@2`, unpinned) from jsDelivr, with no integrity hashes, on the same origin as the lab session. Every page also inlines the whole CSS and JS under `no-store` | Contradicts G6 (no single vendor); a compromised CDN script would run with the lab session | Self-host both from the Worker like `/player/key.js`, versioned and cacheable; add a CSP afterwards (L1, L21) |
| F11 | A request body over 100 MB is refused on Free and Pro, which is why the upload page does multipart. WebDAV clients do not | Large files cannot go through a Worker over WebDAV | Notes over WebDAV, large files over the S3 API (L7) |
| F12 | Manifest-less shares are valid, and older uploads (the Quick Action, curl; likely) depend on it | Moving the routes must not break it | Keep that path and test it (L1) |
| F13 | `cleanup` deletes only objects that carry `expires` metadata. Anything written into `shares/` without it, for example by `rclone`, lives forever | A permanent object in an ephemeral prefix | Rule 8 and rule 12 |
| F14 | Player settings (Key, Speed, EQ, Space, A–B points) live in page memory and reset on reload | The lab is where per-file settings would matter most | L18 |

## 5. Candidate integrations

Effort: **S** hours, **M** days, **L** weeks. Mark each **Keep / Strike / Later**.

### The share module and gallery

| ID | Integration | Effort | Notes |
|---|---|---|---|
| **L1** | Make `/api/share`, `/s/<id>`, `/f/<id>/<nnn>` the engine's **share module**; calendar share links (tier A) reuse the page engine | M | Move `worker.js` into `web/` unchanged first, then split it. Keep URL formats, `/player/key.js`, and the manifest-less path (F12). `galleryPage(live, nav)` is already generic: an event page puts its details in `nav`, and everything put there goes through `esc()`. Split the inline CSS and JS into versioned, cacheable assets and self-host pdf.js and client-zip (F10) |
| **L2** | Replace `UPLOAD_PASSWORD` with scoped, revocable service tokens | S | The seam is `authed()`, called by `upload()` and `shareSession()`. Add token lookup beside the password, compare in constant time, and let the upload page stop storing the secret in `localStorage`. The code names the Finder Quick Action as an uploader, so it very likely calls `/api/upload` with the password; confirm in `~/Library/Services` |
| **L3** | Bring the gallery bucket into the replication and backup set | S | **Resolved by the code: do not replicate `shares/`.** `cleanup` deletes by per-object `expires`, so a copy that loses the metadata would resurrect expired shares, and the key names are the links (F3). Replicate `lib/files/`, `lib/meta/` and `u/`. A share worth keeping is copied into the lab |
| **L4** | An **event page** with attached files: a calendar event shared with a gallery of documents or photos | M | Tiers A and L1 combined. Event titles are untrusted text (rule 3) |
| **L20** | Server-issued share ids, revoke, and the hashing decision | S to M | F1 to F3. Add `action=new` (server returns an id of 22 or more characters), make `start` refuse an existing id, add `action=revoke`. Ids stay inside `ID_RE` so old links still resolve. Recense's tray can delete a share prefix with `rclone` today; revoke makes it one call |

### The lab itself

| ID | Integration | Effort | Notes |
|---|---|---|---|
| **L17** | **Share from the lab:** a Share action in the lab's select mode creates a share link | M | Preferred design: manifest items carry a `ref` to `lib/files/<path>` instead of a copy. `file()` and `getGalleryData` follow a `ref` only if the key starts with `lib/files/` and the manifest was written by an authenticated session; expiry comes from the manifest, because lab objects carry none, and `cleanup` never touches the originals. No duplicated gigabytes. Simpler alternative: copy by streaming `get` into `put`, which keeps today's expiry and cleanup untouched but doubles storage for video. Refs for audio and video, copies acceptable for small files. Needs an owner-only POST route, so rule 10 applies |
| **L18** | **Lab metadata store:** favorites, collections, tags, notes, and saved player settings per file | M | **(assumption)** per-file Key, Speed, EQ, Space and named A–B sections for practice. JSON under **`lib/meta/`, not beside the files in `lib/files/`**: an `rclone sync` removes anything that is not on the drive, which is exactly why artwork already lives in `lib/art/`. Key by path, never by `n` (F8). One small file per collection so edits do not collide; last write wins is fine for one user. Needs `PUT /lab/api/meta` (today `/lab` returns 405 for anything but GET and HEAD). The player reads and writes its settings from it on open and close |
| **L19** | **Lab index in D1:** search, recent, counts, and fast folder pages | M | A `lab_files` table (path, size, mtime, type; later duration, title, tags) rebuilt by listing `lib/files/`, the same rebuildable-index pattern as `events` in `sync.md`. Fixes F6 for good, adds search across folders (the lab can only browse one folder at a time), and lets the scrub compare counts. Needs the engine's D1 (engine phase 1). Filled by the cron or after each `rclone` run |
| **L21** | **Lab hardening** | S | (a) a notice at 5000 items and paging by R2 cursor (F6); (b) art keyed to the source etag and size, orphans swept in the cron (F7); (c) escape `notice()` (F9); (d) self-host pdf.js and client-zip, pin versions, then add a CSP (F10); (e) measure CPU on the 5000-item page and the tag reader (`MAX_TAG` is 24 MB). If the Worker is on Workers Free (10 ms CPU per `sync.md`; verify), these may not fit |

### Recense with the lab

| ID | Integration | Effort | Notes |
|---|---|---|---|
| **L5** | Recordings and transcripts in the lab, shareable as a **recording page** | S, then M | Step 1 needs no Worker change: a Recense-triggered `rclone copy` of `~/Recordings` and `~/Documents/Recense Transcripts` into `lib/files/Recense/...`, which then browse and play in `/lab`. Step 2: the viewer already pairs a same-named image with an audio file as its cover; do the same for a transcript (`name.txt` or `.vtt`) shown in the info panel. Sharing a recording of other people needs their consent; opt-in per share (rule 7) |
| **L6** | Point Recense's R2 tray at the lab with its own remote and token | S | The `rclone` remote `r2` reads only `share`. Lab ingest needs **write**, so it needs its own token anyway, and its own bucket if D2 is taken. Follow rules 8 and 9 |
| **L7** | Move the Draftpad note and Obsidian vault off iCloud Drive | M to L | Notes are small, so WebDAV through the Worker is fine. Large files go to the S3 API directly, for the same reason the upload page does multipart (F11). Recense already notices external edits by file time; the conflict policy for the `<!-- page -->` format is the hard part |
| **L8** | A share pill that takes whatever is selected in Finder and returns a link | S | Extends the Quick Action. With L20 the pill asks the server for an id first |
| **L9** | **Invite field** on the voice draft card; the engine emails the `.ics` | M | Tier B in `sync.md`; Calendar's own invite UI is tier D |

### Claude with the lab

| ID | Integration | Effort | Notes |
|---|---|---|---|
| **L10** | A **remote MCP server** on a Worker: calendar (read, create), share-link creation, **lab list, search and read-metadata** | M | `/lab` cannot be reused (section 3.3), so `/mcp` has its own auth: OAuth or a scoped token. Start **read-only**, per-tool scopes, an audit log, and a confirmation step before any write. Untrusted text now includes event titles, inbound email, **file names, folder names and audio tags**. Search needs L19 |
| **L11** | Optionally route Recense's "Smarter" sentence parsing through the engine instead of a local `claude -p` call | S | Only if one place for the prompt and logs is wanted; local is simpler and sends less |

### Lab to Recense and the calendar

| ID | Integration | Effort | Notes |
|---|---|---|---|
| **L12** | Lab alerts as **calendar events**: a failed scrub, or `lib/files/` more than a day behind its replica, writes `[URGENT] ...` to the "Lab" calendar and Recense's agenda ranking puts it at the top with no Recense changes | S | The strongest low-effort win: it reuses the markers Recense already scores |
| **L13** | Restore drills, certificate and domain renewals, token rotations, and "check `/lab` still opens after any Access change" as recurring events | S | Reliability chores that actually get seen |
| **L14** | `/health`, then a health cue in Recense | S | `worker.js` has no `/health` (F5). Add a shallow `HEAD /health` (200 and `x-version`, no bindings touched, safe every minute) and a deep check behind a monitor token (one `head` of a canary key, one D1 `SELECT 1`). The external monitor reads `x-version` to see which build is serving. Then Recense's cue; update Recense's header comment |
| **L15** | One admin page: users, devices, tokens, shares, backup status | M | Reuses the page engine and is gated exactly like `/lab`. Needed before family accounts |
| **L16** | Family: shared calendars and galleries under the same accounts, with quotas | L | After tier D in `sync.md`. `OWNER_EMAIL` becomes a user table. When others can upload, keep the inline allowlist in `serveObject` (HTML and SVG are forced to download) and serve file bytes from a separate hostname, so an upload can never run on the owner's lab origin |

### Suggested order

- **Now (small, unlocks the rest):** L2, L3 (confirm the decision), L6, L12, L14, L20, L21 (a and c)
- **Next:** L1, L18, L5, L9, L10, L17, and L19 once D1 exists
- **Later:** L4, L7, L8, L11, L13, L15, L16

## 6. Rules for every lab service

1. Own prefix in the registry, own scoped token, own health check, own backup rule. No service reads another's data directly; use the engine's API or events.
2. **Expiring data is not backup data.** Resolved for gallery shares: not replicated (L3).
3. **Untrusted content is data, never instructions, and never raw HTML.** Inbound email, event titles, **file names, folder names and audio tags** can all carry text aimed at an AI or at the page. Escape on output (`esc()`); never pass them to `notice()` until it escapes.
4. Share links are **capability URLs**: server-issued, at least 128 bits (22 or more characters), expiring by default, revocable, and either hashed at rest or not replicated. Today's client-made 12-character ids are about 71 bits (F1).
5. Per-user prefixes from day one. `lib/` is the owner's alias for `u/<ownerId>/lib/`; no `me` paths.
6. A hostname plan before anything is public (`cal.`, `share.` on a domain Chau controls, low TTL so a standby can take over).
7. Anything that touches other people's voices, faces or emails gets an explicit opt-in.
8. **Anything the Worker writes lives outside `lib/files/`.** `rclone` owns that prefix, and a sync deletes strays. The same goes for anything written into `shares/`: it must carry `expires`, or it never goes away (F13).
9. **Ingest with `rclone copy`, or `sync` only with `--max-delete` and a `--backup-dir`.** A drive that mounts empty must not be able to wipe the library. R2 has no object versioning as far as I know (verify), so the second vendor's versioning is the only undo.
10. **Every state-changing lab route** (anything but GET and HEAD) checks the `Origin` header and requires a custom request header. Do not lean on the Access cookie's `SameSite` setting.
11. **Lab durability has two classes.** While a source drive exists, R2 is a mirror. When the drive is wiped or retired, R2 is the primary. Do not retire a drive until `lib/files/` is in the second vendor and the scrub is clean.
12. A new cron job names its prefix. Cleanup scope is `shares/` only.

## 7. Moving the current Worker onto this

1. Leave it running as is. Note the current `x-version`.
2. Decide D2. If the lab gets its own bucket: bind `LAB`, `rclone copy` `lib/` across, switch `labFolder`, `labFile` and `labArt` to `env.LAB`, and delete the old copy only after a scrub.
3. Add `/health` and token auth **beside** `UPLOAD_PASSWORD`; move Recense to a token (L14, L2).
4. Server-issued ids and revoke (L20). Old ids keep resolving.
5. Move `worker.js` into `web/` unchanged, then split the page engine, assets and player into `ui/`, and the share module and lab into modules behind the `Store` port. Keep `/s`, `/f`, `/api/*`, `/player/key.js` and `/lab` identical. Test: a manifest-less share, a multipart upload over 90 MB, a Range request in Safari, and `/lab` answering 404 when signed in as a different email.
6. Replication covers `lib/files/` and `lib/meta/`, not `shares/` (L3).
7. Retire `UPLOAD_PASSWORD`, which also removes the secret from the upload page's `localStorage`.

## 8. Decision checklist

- **D1.** Confirm the role: apps on a shared platform, no sandbox yet.
- **D2.** Lab in the `share` bucket, or its own bucket (recommended).
- **D3.** Two Workers (`dav`, `web`), as recommended, or one.
- **D4.** Access scope: `share.<domain>/lab*` only.
- Which of L1 to L21 stay, go or wait?
- Token scopes and names.
- Shares not replicated (L3): confirm. Hashed keys for new shares, yes or no (L20).
- Lab size, which feeds the second-vendor choice (S3 or B2).
- Is L10 read-only at first (recommended)?
- Hostnames and domain.
- **Still open:** what the lab grows into beyond browsing and playing (L18 and L19 rest on assumptions).

## 9. Corrections to apply to `sync.md`

| Section | Says | Should say |
|---|---|---|
| 2 (consumers table), lab row | Not yet specified | `/lab`: an owner-only library over `lib/files/` in the web Worker; see this document |
| 6 (R2 layout) | `g/<shareId>/...`; a private bucket separate from the gallery's `share` bucket | `shares/<id>/...` (live layout, keys do not move); add `lib/files/`, `lib/art/`, `lib/meta/`; lab data is currently in the `share` bucket (see D2) |
| 3 (principle 5) | Per-user, never `me` | Note that `lib/` is the owner's alias for `u/<ownerId>/lib/` |
| 4 (durability) | One class of data | Add the lab's two classes (rule 11) |
| 7 (`/health`) | Planned | Not in `worker.js` yet (F5) |
| 9 (constant-time comparison) | For the new engine | Also true of `authed()` today, which uses `===` (F4) |
| 11 (Workers Free CPU) | DAV-only concerns | Add the lab's 5000-item listing and tag parsing; measure |

## 10. Recense slice (paste this into the Recense project instead of the whole doc)

> **Sync and lab integrations (summary).** The sync engine and cloud lab are specified in the cloud lab project (`sync.md`, `cloud-lab-integrations.md`). The lab is already live at `/lab`: an owner-only library over `lib/files/`, behind Cloudflare Access. Recense's side:
> - Three edits from `sync.md` section 14: add `syncAccountName` and `syncCalendarTitle`; make `VoiceEntry.saveTapped()` prefer the synced calendar; call `store.refreshSourcesIfNecessary()` in `EssentialsView.surfaced()`.
> - Candidate integrations that touch Recense: L2 (a new token for the Copy Share Link pill, replacing the shared password), L5 (recordings and transcripts copied to `lib/files/Recense/` with `rclone copy`), L6 (R2 tray on its own remote and token; never `rclone sync` from a source that may be empty), L7 (Draftpad and vault off iCloud Drive), L8 (share pill, server-issued ids), L9 (Invite field), L12 and L14 (lab alerts need no Recense change; the health cue needs one).
> - Rule: any new network request in Recense must be reflected in the header comment that currently calls weather the only one.
