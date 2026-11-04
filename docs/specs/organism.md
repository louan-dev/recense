# Sync · Gallery · Recense: one organism, three organs

**Status: PROPOSED** (written 2026-10-29 18:56 PDT from the owner's brief: "come up with a robust long-term serverless
backend design that could be used as a guide; decide whether Gallery should be folded into Sync, Gallery and Recense into
Sync, or another combination"). Becomes SETTLED when the owner says yes. Recorded as decision 8 in `PROGRESS.md` §8.
Where this file and an older spec disagree about **which project owns what**, this file wins once settled; it does not
change any decision about *how* a thing works.

## 0 · The answer
1. **Don't fold.** Keep three projects. Each has one job none of the others can do, and folding mixes code that changes
   every hour with code that must never lose a byte.
2. **Re-cut one boundary.** The blur comes from one misfiled job: **the sync engine** (catalog, event log, cursors,
   stable ids, conflict rules, delete guard, device registry) is specced and built inside Gallery
   (`gallery-nervous-system.md` "1 + 2 = the sync engine, in the Worker"; `gallery/src/fp.js`, `dav.js`, `tmp.js`,
   `archive.js`). That's Sync's job. Moving it to Sync gives Sync a clear place and makes Gallery a product again.
3. **Recense is a capability, not a fourth product.** It's the listening layer (transcribe, translate, measure the
   voice), shipped as modules: native Swift in Recense, web modules in Gallery, one data contract (`keep/<key>/`) between them.
4. **Recense doesn't fold into Gallery for iOS.** iOS has no surface for a Recense: no app can draw over other apps or hear
   another app's audio. The "player follows me" you want on iOS is **Gallery's playback leaving the Gallery app**
   (background audio, Lock Screen, Picture in Picture with the lyrics, a Live Activity), built from Recense's patterns (§6).

## 1 · What each one is

| | **Sync** | **Gallery** | **Recense** |
|---|---|---|---|
| One sentence | Everything I own is accounted for, safe, and reachable from any device. | The place where I and the people I invite experience and share my media. | What is happening right now on my Mac, at the edge of the screen. |
| Organ | Skeleton, blood and memory: custody and flow | Face and voice: where people meet the content | Senses: ambient perception on the device |
| Works alone? | **Must.** Never needs Gallery or Recense | Yes, without Recense. Needs Sync for bytes | Yes, offline, with the Worker unreachable (already a rule) |
| Change speed | Slow, every change tested | Fast, many UI changes a day | Fast, but it's a daily driver: idle cost matters |
| A bug means | Data lost or leaked | Something looks or sounds wrong | My Mac is annoying right now |
| Runs on | Cloudflare (Worker, R2, D1, Queues) + thin Mac/iOS adapters (launchd, mounts, File Provider) | Cloudflare (Worker, D1, Durable Objects) + web client + iOS/Mac app shell | macOS only (one app: strip, Recense, Nook, Draftpad) |

### Recense (the capability)
Transcription, translation, word timings, prosody (`features.json`), the vocal extractor, chords. **Produced** on the
Mac by Recense (it has the compute, the process tap, Groq and on-device ASR). **Stored** through Sync (bucket `recense-tmp`,
`keep/<key>/`). **Shown and corrected** in Gallery and in Recense's transcript panel. Keyed by content (ContentKey), so a
transcript follows the media to every copy and every device.

## 2 · What to protect and build on (the investor view)

**Sync: correctness is the asset.**
- *Moat:* hash-chained logs in one format (`event-log.md`): the ledger for the folders Sync observes (Obsidian, iCloud
  Drive, Calendar), the catalog for the R2 roots Sync owns, one verifier for both. Plus a write protocol that never
  loses an edit (based-on version, 412, keep both, trash, one delete guard), and Apple data out through standards only
  (EventKit `.ics`, CalDAV, WebDAV, sparse-bundle offsite disks). Anyone can rent storage. Few people have their own
  verifiable custody. *Not yet "every byte":* Main, Public and tmp have no catalog yet, and the sparse-bundle disks
  have no log at all.
- *Strengths already proven:* ledger selftest 34 ok; `verify --deep` 0 problems on Obsidian, iCloud Drive and Calendar
  (1,078 live); stale save → 412 live; 120 MB chunked upload hash-identical; Calendar backup DONE; CalDAV Worker
  deployed, 4/4 tests.
- *Refine next:* (1) the engine's convergence test (invariant 7: 3 devices, 1,000 ops, 50 seeds; not started);
  (2) restore drills (A2's restore is still not done; an untested backup isn't a backup); (3) a second failure domain
  (today everything is R2 plus one keyring flash drive).
- *Don't spend on:* screens. Sync's only UI is health files other projects display.

**Gallery: the player and the rooms are the asset.**
- *Moat:* a player that teaches language through media I own: bilingual karaoke with the prominence slider, Learn mode,
  notation modes (C/Đô, Ton., Tông), Key/EQ/Space, chords, the prosogram, and the home bar's design language (rule of
  thirds, transparent controls). Plus **Rooms**: invited people listen, comment and annotate under permissions the server
  enforces.
- *Strengths already proven:* deployed, 109 tests; invites (C0) live-verified against made-up, revoked and cross-folder
  tokens; the iOS app runs the same web player, so the rules can't drift.
- *Refine next:* (1) player consistency on every device (the SPEC P3 list); (2) C0's gaps (comment ownership by display
  name, per-invite permission toggles, view-only lock); (3) iOS playback that leaves the app (§6).
- *Don't spend on:* storage, mounts, sync plumbing. Those are Sync's.

**Recense: presence is the asset.**
- *Moat:* it hears and shapes **whatever** plays on the Mac (Core Audio process tap on YouTube, QuickTime, Music, any
  app), transcribes it live, and keeps time, calendar, notes and the menu bar at the edge of the screen. Gallery can only
  play Gallery's files; Recense works on everything.
- *Strengths already proven:* daily driver; Recense live with the quota fallback to on-device translation; the
  `Transcriber` seam designed; one app (the Recense.app ghost is understood).
- *Refine next:* (1) SL1 idle cost (the 1 Hz and 60 Hz timers); (2) the `Transcriber` seam, then offline ASR;
  (3) the Nook import and the widget panel.
- *Don't spend on:* browsing the library (Gallery's), storage (Sync's).

**The compounding asset across all three:** the `keep/` corpus. Transcripts with word timings, human corrections and
voice features, keyed by content over a library I own. Every correction makes every later replay better, on every
device. Protect the schema and ContentKey like a database schema.

## 3 · The hypotheticals

| Option | Verdict | Why |
|---|---|---|
| **H1** Gallery folds into Sync | No | Sync would absorb the 85+ player items in SPEC.md; custody code would redeploy for every cosmetic change; one bad UI deploy could reach the write path. |
| **H2** Gallery and Recense fold into Sync | No | A monolith in two languages and three runtimes (Worker, macOS app, iOS app). It's the opposite of "copy this folder and it still works." |
| **H3** Recense folds into Gallery (Recense = Gallery for Mac and iOS) | No | Recense's unique power is following *any* app's audio and owning the screen's edge; neither is about the library, and Recense must work with Gallery unreachable. On iOS a Recense can't exist (Apple wall), so there is nothing to fold. |
| **H4** Sync folds into Gallery (where the nervous-system spec drifted) | No | Custody would belong to the project with the most churn; Calendar, Messenger, the ledger and the offsite disks have nothing to do with a gallery. |
| **H5** Three projects, engine moved to Sync, Recense as a shared capability | **Yes** | Each project gets one job; features combine through contracts (§5), not shared internals. |
| **H6** One monorepo, three packages | Not now | Repo layout matters less than ownership. Three repos with history and rules already exist; revisit only if shared modules get painful to copy. |

## 4 · Where a feature goes (the rules)

Ask in order; the first yes wins.
1. **Would it still matter if nobody ever looked at it?** It decides what is true about data, keeps it safe, moves
   bytes between places, devices or standards → **Sync**.
2. **Is it about a person experiencing, organizing or sharing something in the library, on any device?** → **Gallery**.
3. **Is it about this Mac right now, across apps, needing OS-level access?** → **Recense**.
4. **Is it about understanding audio** (words, timing, language, voice, chords, stems)? → **Recense modules**: the engine
   where the compute is (Recense), the display where the viewer is (Gallery and Recense).
5. **None of these?** It's probably a new product built from the blocks (example: the Calendar Desk scheduler = Sync's
   CalDAV + Recense's cards + its own decision logic). Give it its own name and folder; don't stuff it into one of the three.

**Dependency direction (one way only):** Recense → Gallery modules (optional) → Sync. Recense → Sync directly is fine
(health, CalDAV). **Sync never depends on Gallery or Recense. Gallery never depends on Recense.**

**An app bundle can carry modules from any project.** Gallery's iOS app carries Sync's File Provider core; Recense carries
Gallery's home bar. Ownership follows the module, not the icon on the Home Screen.

| Feature (from SPEC/BACKLOG) | Owner | Note |
|---|---|---|
| Trash, versions, 412, delete guard, chunked uploads | Sync | write protocol |
| Catalog, change feed, reconciler, stable ids (`fp.js`) | Sync | moves from Gallery (§7) |
| WebDAV/Nextcloud endpoints, mounts, Touch ID key unlock, wipe on lock | Sync | adapters; the Gallery.app window is just their carrier |
| File Provider extension (`FileProviderCore`) | Sync | shipped inside the Gallery app |
| Downloads → tmp, 14-day expiry | Sync | custody lane |
| Calendar backup, CalDAV, Messenger, offsite disks, ledger | Sync | |
| `resign-ios.zsh` (re-signs the Gallery app) | Gallery | build ops for Gallery's app; move from `sync/bin` |
| Player, home bar, prominence, notation, Learn mode, chords display | Gallery | web modules, hosted by Recense too |
| Rooms, invites, comments, reactions, annotations, share links | Gallery | D1 tables in `migrations/0001_init.sql` are Gallery's |
| iOS browser, player, lock-screen playback, PiP lyrics | Gallery | §6 |
| `/main/ledger/` browsing (A7) | Gallery displays, Sync produces `views/tree.json` | |
| Process tap, EQ on any app, strip, Nook, Draftpad, widgets, Find My | Recense | |
| Health chip | Recense displays, Sync produces `views/health.json` | |
| Transcription, translation, extractor, prosody measurement | Recense | |
| Transcript corrections | Recense contract, edited from Gallery and Recense | conditional writes, merge per field |

## 5 · The contracts (the building blocks)
Projects talk only through these. Each is versioned (`"v": 1` in the payload or `/v1/` in the path); a breaking change
gets a new version and the old one keeps working until every consumer has moved.

| Contract | Producer | Consumers | Today |
|---|---|---|---|
| Catalog API: `items`, `changes?since=`, `content` (Range) | Sync | Gallery web + iOS, File Provider, Mac adapters | `fp.js` slice 1 (in Gallery) |
| Write API: PUT/MOVE/DELETE with `If-Match`, 412, trash, 409 `needs-confirmation` | Sync | everyone who writes bytes | `dav.js` (in Gallery) |
| Device registry: one Access service token per device, last seen, cursor, budget, pins | Sync | Gallery `/main` (shows it) | tokens done; registry not built |
| Standards: CalDAV, WebDAV, later CardDAV | Sync | Apple apps, rclone, Notability, Windows | CalDAV Worker, `/dav/notability/` |
| Event log v2 (`event-log.md`): one format, chain, delete guard, verifier | Sync (ledger + catalog) | devices, `restore`, `verify`, Gallery A7 | ledger writes v2; catalog chained, not deployed |
| `views/health.json`, `views/tree.json` | Sync | Recense chip, Gallery A7 | one pair per ledger sink (`<sink>/views/`): health on every run, tree on `fold --write`; no combined view yet |
| `keep/<key>/` (asr, tr/<lang>, corrections, history, features.json, library.json aliases) | Recense | Gallery, Recense | live; write the schema down as `keep/SCHEMA.md` |
| Recense localhost API (port 47123) | Recense | Gallery pages on the Mac | live |
| Web modules (`homebar`, `keylabel`, `room`, `prosody`, `prosogram`) with `CONTRACT.md` + `MANIFEST.json` | Gallery | Recense, Gallery iOS, prototypes | planned in `recense/docs/architecture.md` Track W |
| Sound commands (`cmd`, `fx`, `lang`, `size`, `chord`, …) between home bar and a sound engine | Gallery (home bar) | Recense's native chain; Gallery iOS's native chain (§6) | live in Recense |
| `?embed=1` | Gallery | Recense | live |
| Rooms API (`/m/<token>`) | Gallery | invitees' browsers | C0 live |

## 6 · iOS: the player that follows you

**What iOS allows (Apple walls):** no app draws over other apps; no app hears another app's audio; there's no menu bar.
iPhone 12 Pro Max and iPad Air have no Dynamic Island. **What it does allow, for media the app itself plays:**
1. **Background audio** (Background Modes: audio, `AVAudioSession` category `.playback`): keeps playing on the Home
   Screen, in other apps, with the screen locked.
2. **Now Playing and remote commands** (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`): Lock Screen, Control
   Center, headphones and CarPlay show the real title, cover and scrubber (SPEC 69).
3. **Picture in Picture with custom content** (`AVPictureInPictureController` with an `AVSampleBufferDisplayLayer`
   content source, iOS 15+): a floating window over the Home Screen and other apps that can show **the karaoke lines**,
   drawn frame by frame. This is the closest thing to Recense's floating transcript panel that iOS allows.
4. **A Live Activity** (ActivityKit, Lock Screen and the notification list): current line, title, progress. Updated by
   the app while it plays in the background; remote push updates need APNs (paid account).
*Verify on device:* PiP for custom content, and a Live Activity widget extension on the free Personal Team. The
extension ships inside the Gallery app, but it shares data with the app through App Groups, and test (a) in
`gallery/docs/architecture.md` §7 decides whether the free team allows those.

**The gap today:** the iOS app plays through Gallery's web player in a `WKWebView`, and `apple/HostApp/iOS/` has no
`AVAudioSession`, `MPNowPlayingInfoCenter` or PiP code. Web Audio (the EQ and Key worklets) is suspended when the app
goes to the background. So playback that leaves the app needs a **native sound engine on iOS**.

**The design, reusing what Recense already proved:** keep the web home bar as the UI (one player, rules can't drift), and
let it drive a native engine through the same command set Recense's home-bar host uses. On iOS the engine is
`AVAudioEngine` + `AVAudioUnitEQ` + `AVAudioUnitTimePitch` + `AVAudioUnitReverb` playing the app's own files (Recense's
process tap is macOS-only). Lines for PiP and the Live Activity are drawn with Core Text into pixel buffers, from the
same `keep/<key>/` transcript. Two consequences:
- **New shared Swift module `SoundChain`:** one command contract, two backends: `tap` (macOS, any app; today's
  `soundengine.swift`) and `player` (iOS and macOS, own files). Owned by Gallery (it serves the home bar's contract);
  Recense hosts the tap backend.
- **The line renderer must not depend on AppKit** (today Recense draws with `NSAttributedString` in AppKit views). A
  Core Text version is the portable one; Recense can adopt it later, not before it's needed.

**Order:** (1) native playback + background audio + Now Playing, web UI unchanged except it sends commands instead of
playing; (2) EQ/Key/Space on the native chain, compared by ear against the web chain; (3) PiP with lines; (4) Live
Activity. Each step ends with a test on the iPhone 12 Pro Max and the iPad Air: lock the screen, open another app, use the
Lock Screen controls.

## 7 · The long-term serverless backend

```
                 Apple apps, rclone, Notability, Windows        Invitees' browsers
                          │ CalDAV / WebDAV / Nextcloud                 │ /m/<token>, /s/<id>
 Mac (Recense, launchd,      ▼                                             ▼
 mounts) · iOS (Gallery ┌──────────────────────────────┐  RPC   ┌──────────────────────────────┐
 app + File Provider) ─▶│ SYNC Worker (custody)         │◀──────│ GALLERY Worker (product)      │
   Access token per     │ catalog · change feed ·       │service│ /main pages · player assets · │
   device               │ write protocol · devices ·    │binding│ rooms · invites · comments ·  │
                        │ standards · health            │       │ covers · public links         │
                        └──┬──────────┬─────────┬───────┘       └──┬───────────┬────────────────┘
                           │          │         │                   │           │
                     R2 buckets   D1 sync   Queue ◀── R2 event   D1 gallery   Durable Object
                     (bytes +     (devices, │      notifications (rooms,      (presence,
                     .catalog/)   caldav    ▼                     members,    co-editing,
                     main, public, index)  replicator → 2nd       comments,   live change
                     archive, tmp,         vendor (versioned,     reactions,  fan-out)
                     recense-tmp,          Object Lock)           annotations)
                     notes, sync
```

**Workers.** Two, joined by a service binding (Workers RPC: no extra hop to the internet, no extra auth). **Every URL
devices use today stays the same:** the Gallery Worker routes `/main/api/fp/*`, `/main/dav*`, `/main/nc*` to Sync
through the binding, so no device is reconfigured and no Access token changes. The Sync Worker keeps its own hostname
for CalDAV.

**Who writes what (single writer per object class).**
| Store | Owner | Writes | Reads |
|---|---|---|---|
| R2 file objects (main `files/`, public, archive, tmp) | Sync | Sync's write API in the Worker, and Sync's own Mac jobs with scoped keys (Downloads → tmp, folder moves into the archive). The catalog records every write, including the direct ones. Gallery's covers and tag rewrites move onto the write API (today `art.js`/`tagwrite.js` write Main directly) | anyone with a binding, read-only |
| R2 `.catalog/<root>/` | Sync | the catalog only (`fp.js`, later the Sync Worker) | devices through the catalog API; `ledger.mjs verify` |
| R2 `gallery-main/ledger/<source>/` | Sync | the ledger jobs only (rclone, scoped key); to move into a Sync bucket on the owner's yes | `restore`, `verify`, Gallery A7 |
| R2 `recense-tmp/keep/` | Recense | Recense (transcripts), Gallery (corrections), conditional writes with merge | Gallery, Recense |
| D1 `sync` | Sync | Sync | Sync |
| D1 `gallery` | Gallery | Gallery | Gallery |
| Durable Objects | Gallery | Gallery | Gallery |
No project reads another project's database. If it needs something, it calls the owner's API or reads a published view.

**Change notification without polling.**
- **Writes through Sync** append to the catalog log at once (already designed: create-only puts on the next seq).
- **Writes around Sync** (rclone, the R2 dashboard): R2 event notifications → a Queue → Sync appends the event. This
  replaces the reconciler's "on demand if older than 60 s" with push; the reconciler stays as the nightly check (03:00)
  that proves the log is complete. *Verify:* event notifications and Queues may need the Workers Paid plan.
- **Web pages:** Sync publishes each appended batch to Gallery's Durable Object hub, which fans it out over hibernating
  WebSockets (the `gallery/SYNC.md` LibraryHub, now fed by Sync's log instead of owning one).
- **File Provider:** polls `changes` every 60 s on macOS and on system schedule on iOS, because push needs APNs (Apple
  wall, paid account). Stated, not hidden.

**Identity.** Sync owns *devices and the owner* (Access service tokens, the device registry). Gallery owns *people and
rooms* (invite tokens ≥128-bit stored as hashes, permissions, revocation). A participant never gets a Sync credential:
Gallery checks the room's permission, then reads or writes through Sync on the participant's behalf, and Sync records
`by` in the event.

**Durability.** R2 is one failure domain. Target (from `sync.md` §4): versioned copies at a second vendor with Object
Lock (replicator off the Queue), nightly D1 exports to the same place, local mirror on the Mac, restore drilled twice a
year. Claim no 3-2-1 until a restore from the second vendor has been tested.

**Exits.** Each Cloudflare product keeps a named replacement (`sync.md` §5): Workers → Node/Deno behind the same ports;
R2 → S3/B2/filesystem; D1 → SQLite; Queues → a cron reconcile; Durable Objects → plain polling at a lower tier. Data stays
open: plain files, `.ics`, JSON.

## 8 · Getting there without breaking anything

| Step | What | Test | Moves code? |
|---|---|---|---|
| 0 | Owner says yes to this file. Update `CLAUDE.md` in all three repos and the nervous-system spec's ownership lines (not its decisions). | the three CLAUDE.md files agree | no |
| 0b | **One event-log format** (`event-log.md`): ledger v2, chained catalog, one delete guard, one verifier. Also fixed the catalog's false `410` on every incremental check. | ledger selftest 42 ok (was 34); live journals verify unchanged; gallery routes 47 pass; cross-check 0 problems | DONE, live (Gallery 0b0ab499); ledger-sink move waits on one dashboard step |
| 1 | **Boundary inside the Gallery Worker:** move `fp.js`, `dav.js`, `tmp.js`, `archive.js` and the catalog code into `gallery/src/engine/`; a test fails if `engine/` imports anything outside it. | `npm test` unchanged + the new import test | within one repo |
| 2 | Write `keep/SCHEMA.md` and `MANIFEST.json` + `CONTRACT.md` for the web modules (already ordered in Recense's architecture). | Recense's no-upward-imports test | no |
| 3 | **Extract the engine** into the Sync Worker; Gallery forwards the same URLs through a service binding. Deploy behind the same paths. | every live test in `gallery-nervous-system.md` "Facts" passes again (120 MB hash, 412, trash, kill -9) | yes |
| 4 | Engine convergence test (invariant 7) in Sync's repo. | 50 seeds pass | — |
| 5 | iOS native playback (§6 order). | lock screen, other app, PiP | Gallery |
| 6 | R2 event notifications → Queue → catalog; replicator to the second vendor. | a write via rclone shows in `changes` without a reconcile; restore from the second vendor | Sync |
| 7 | Move `resign-ios.zsh` to Gallery; split `PROGRESS.md` so each repo carries its own status, with this file as the shared constitution. | | ops |

Steps 1–2 can start now and are reversible. Step 3 needs the owner's deploy yes, and it should wait until the
other session's uncommitted C0/D1 work in the Gallery repo is committed.

## 9 · Enforcement
- **No upward imports:** a test per repo greps shared modules and the engine for host names (Recense's rule, extended to
  `engine/`).
- **Contracts have versions** and a fixture test on both sides (producer emits it, consumer parses it).
- **Every new backlog item names its owner** using §4. An item that names two owners is two items.
- **Each repo's `CLAUDE.md` opens with its one sentence from §1** and the "don't spend on" line from §2.

## 10 · Open (owner)
1. Yes or no to H5 (§3) and to moving the engine (steps 1 and 3).
2. Workers Paid ($5/month) for Queues and R2 event notifications, or keep the 60 s on-demand reconcile.
3. iOS: start the native playback (§6 step 1) now, or after the File Provider slices.
4. A second vendor for the replicator (S3 or B2) and when.
