# Sync: a standards-based sync foundation on Cloudflare

**Status:** planning, 2026-10-08. Supersedes `sill-sync.md`.
**Repo (new):** `~/Developer/sync` (one folder per project). The name "Sync" is a working title (see section 16).
**Owner:** Chau.

---

## 1. Purpose and goals

iCloud storage is full, so calendar entries made on the iPhone no longer reach the Mac, and Notability stopped syncing too. The wider aim is to stop depending on iCloud across everything Chau is building. This project is the foundation those things run on.

| # | Goal |
|---|---|
| G1 | Apple Calendar syncs between iPhone and Mac **without iCloud**, with no custom app on the iPhone. |
| G2 | **Cross-device**: anything that speaks the open standards works (Apple devices, Android through DAVx5, Thunderbird, and so on). |
| G3 | **One-person first**, built so **family** can be added later without a rewrite. |
| G4 | **Sharing**: other people can add events to the calendar, or an email address is added to an entry so that person gets reminded or can open the event and add it to their own calendar. |
| G5 | **Apple's native invite UI stays usable.** Chau uses it only occasionally but wants it as a feature that can be counted on. |
| G6 | **Robust and future-proof**: no single vendor, product or bucket can lose the data, and every piece can be replaced (sections 4 and 5). |
| G7 | Runs on **Cloudflare** as the primary platform, with **no Docker** and no always-on server to babysit. |

## 2. Who depends on it

| Consumer | What it needs | Through |
|---|---|---|
| **Sill** (macOS menu-bar panel) | Calendar read/write, invites, share links, a health cue | A CalDAV account in Calendar (native), plus `/api/share` and `/health` |
| **Shared gallery** | One link that shows several R2 files, Apple-minimalist page | The share module (tokens to objects) and the same page engine |
| **Private personal cloud lab** | *Not yet specified* | Open: files/WebDAV, or a custom API |
| **Draftpad / Obsidian vault** | File sync off iCloud Drive (the note path in Sill currently lives there) | The files module (later) |
| **Family** | Own accounts, shared calendars, invitations | Multi-user, permissions, scheduling |

Notability is mostly out of scope. Its own **Notability Cloud** sync does not use iCloud storage (check current Mac support), and its Third-Party Backup supports **WebDAV**, but that is a one-way backup, not live sync. This engine can be that backup target later.

## 3. Principles

1. **Standards at the edge.** CalDAV, CardDAV, WebDAV, iCalendar and vCard. Custom APIs only where no standard exists (gallery, lab). Standards are what make it universal; a proprietary protocol would need a client on every platform.
2. **Data stays open.** Calendars are `.ics`, contacts are vCard, files are plain files. Nothing is reachable only through our code.
3. **Ports and adapters.** The protocol logic is plain TypeScript behind small interfaces (`Store`, `Index`, `Mailer`, `Clock`). Cloudflare is an adapter, not the design.
4. **Every Cloudflare product has a named exit** (section 5).
5. **Per-user from day one.** Real user ids in URLs and storage keys, never `me`.
6. **Boring first.** One calendar, no Durable Objects, no `sync-collection` until the basics pass on real devices.
7. **Test against real Apple clients**, and against a reference server for the wire format.

## 4. "Visa-grade," defined honestly

"Visa-grade" is shorthand, not a measurable target, and no single cloud vendor delivers it. Cloudflare's own post-mortem covers a multi-hour outage on 2026-02-20, third-party tallies list several critical incidents across 2025 and 2026 (including about 5.5 hours in November 2025), and write-ups report R2-specific incidents in July and August 2026 (one claims a customer's bucket data was not yet restored days later). Those last items are blog posts, not Cloudflare post-mortems, so check cloudflarestatus.com. The point is not to leave Cloudflare. It is that a payments network gets its reliability from redundancy it owns, and Chau's equivalent is **independent copies in independent failure domains**.

Proposed objectives at personal scale:

| Property | Target | How |
|---|---|---|
| **Durability** | An acknowledged event is never lost | Copies in 5 places: iPhone, Mac, R2 (primary), a second vendor (S3 or B2), and a local Mac mirror. Backup bucket has versioning and Object Lock |
| **Availability** | Calendar always usable; sync at least 99.9% monthly; an hours-long outage is tolerated | Each device keeps a full copy and queues writes, so an outage delays sync, it does not lose events |
| **RPO** (data at risk) | 24 h at first, then about 5 min | Nightly copy first; later R2 event notifications to a Queue to a replicator Worker (verify) |
| **RTO** (time to recover) | 1 h to stand up the standby | Written runbook, drilled twice a year |
| **Integrity** | Corruption detected within 24 h | Nightly scrub compares object counts and hashes between primary and backup |
| **Change safety** | A bad deploy is undone in minutes | Versioned deployments, gradual rollout, instant rollback, never change primary and standby on the same day |

Not claimed: five-nines availability. Calendar sync does not need it, because the devices are replicas.

## 5. Architecture and stack decisions

```
iPhone / Mac / other CalDAV clients
        │  HTTPS, Basic auth with per-device app passwords
        ▼
  Cloudflare Worker  (core: protocol logic behind ports)
        ├─ R2   ← calendar objects (.ics), shared files
        ├─ D1   ← users, ACLs, share tokens, sync revisions, calendar index
        └─ Email Service / Email Routing ← invitations out, replies in
        │
        ├─ replicator ──▶ Second vendor: S3 (or B2), versioned + Object Lock
        └─ nightly D1 export ──▶ same second vendor
Local Mac: rclone mirror      Standby: cold server at another vendor (runbook)
External uptime monitor from a different provider
```

| Layer | Primary (Cloudflare) | Named exit | Notes |
|---|---|---|---|
| Compute | Workers | Node/Deno/Lambda via the ports | Keep the Worker small and deterministic |
| Object store | R2 | S3, B2, or the local filesystem | R2 is **one failure domain**, never the only copy |
| Index / metadata | D1 | SQLite or Postgres | Transactions (batch) for cross-user writes; gives a monotonic revision for sync tokens |
| Email | Email Service (beta) | SES, Postmark or Resend behind `Mailer` | Sending to arbitrary recipients needs Workers Paid; inbound uses Email Routing and Email Workers |
| DNS | Cloudflare DNS | any DNS | Use a hostname Chau controls with a low TTL, so DNS can repoint to the standby **without re-adding accounts on devices** |
| Backup | S3 (or B2) | any S3-compatible store | Write-only credentials for the replicator (no delete permission) |
| Standby | cold server at another vendor | n/a | Radicale (`pip`, no Docker) loads the `.ics` backup in minutes; later the same core on Node through an `FsStore` adapter |

Recommendation in one line: **Cloudflare as the front door and primary store, a second vendor holding independent versioned copies, and a standby that can take over.** A single-vendor all-AWS build is possible but adds setup and AWS has had major outages too, so it does not remove the need for a second copy.

## 6. Data model

**R2** (private bucket, no public access, no `r2.dev`, reached by Worker binding only; separate from the gallery's `share` bucket):

```
u/<userId>/cal/<calId>/e/<resource>.ics    event, byte for byte as the client sent it
u/<userId>/trash/<calId>/<resource>.<unix>.ics   copy on DELETE; lifecycle expires after 30 days
g/<shareId>/...                             gallery and shared-file objects
```

`customMetadata` on each event: `uid`, `dtstart`, `dtend`, `recur` (`none`, `until:<iso>`, `open`). ETag is R2's own.

**D1** tables (sketch): `users`, `devices` (per-device app-password hash, revocable), `calendars` (owner, name, color, current revision), `acl` (calendar, user, privilege), `events` (calendar, resource, uid, etag, dtstart, dtend, recur, revision, deleted), `shares` (token hash, target, expiry, permissions).

**What is rebuildable and what is not.** The `events` index is rebuilt by listing R2. `users`, `devices`, `acl` and `shares` are **not** derivable, so they are exported nightly to the second vendor.

## 7. Protocol surface

Core (v1), as before:

| Path | Methods | Notes |
|---|---|---|
| `/.well-known/caldav` | GET | 301 to `/dav/` |
| `/dav/` | OPTIONS, PROPFIND | `DAV: 1, calendar-access`; `current-user-principal` |
| `/dav/principals/<userId>/` | PROPFIND | `calendar-home-set`, `calendar-user-address-set` |
| `/dav/calendars/<userId>/` | PROPFIND (Depth 1) | calendar list |
| `/dav/calendars/<userId>/<calId>/` | PROPFIND, REPORT, PROPPATCH | `getctag`, `getetag`, `supported-calendar-component-set`, `calendar-color`; REPORT: `calendar-query`, `calendar-multiget`, later `sync-collection` |
| `.../<resource>.ics` | GET, PUT, DELETE | `If-Match` / `If-None-Match` honored |
| `/admin/*` | POST | calendar and user provisioning, separate secret |
| `/health` | HEAD/GET | for Sill and the external monitor |

Later: **scheduling** (RFC 6638: `schedule-inbox`, `schedule-outbox`, `calendar-auto-schedule` in the `DAV:` header), CardDAV, a files module over WebDAV.

## 8. Sharing and invitations

| Tier | What it does | Needs |
|---|---|---|
| **A. Event share link** | A landing page with the details and "Add to calendar" (`.ics` with a built-in alarm, so the recipient's own calendar reminds them). No account | Share module, page template shared with the gallery |
| **B. Email invite from Sill** | An "Invite" field on Sill's voice draft card makes the engine email the `.ics` | Email Service, `/api/share` |
| **C. Inbound events** | Others email an invite to an address on Chau's domain; an Email Worker parses the `.ics` into an **Inbox** calendar as pending; Chau accepts it into the main calendar. No shared credentials | Email Routing, Inbox calendar |
| **D. Native invite UI** | Chau adds an email to an event in Apple's Calendar and invitations just work: external attendees get an iMIP email (RFC 6047), replies (`METHOD:REPLY`) come back by email and update the attendee status; internal users get the event in their schedule inbox | CalDAV scheduling (RFC 6638) plus iMIP |
| **E. Shared calendars** | Family accounts with per-calendar permissions | D1 ACLs |

Why D is its own tier: scheduling is the largest single piece (implicit scheduling on PUT, inbox/outbox collections, free/busy, reply handling) and writes touch more than one user's data, which is why D1 transactions matter. A, B and C give most of the value earlier and are not wasted when D arrives. **Phase 0 must check** whether Apple's Calendar shows the invitee field on a plain CalDAV account, and exactly which properties it needs once scheduling is advertised (use a scheduling-capable server such as Baïkal/sabre-dav as the reference; verify).

Sill note: EventKit does not let apps add attendees as far as I know, so Sill's invite path (B) goes through the engine, while Calendar's own UI uses D.

## 9. Accounts, auth, security

- Basic auth over HTTPS only, with **per-device app passwords** (32+ random characters, stored hashed, individually revocable) so a lost phone can be cut off alone. Constant-time comparison.
- WAF rate limit on failed auth for the sync hostname. If Cloudflare bot rules answer 403 to Apple's clients, add a skip rule for that hostname (test early).
- Private bucket, Worker-binding access only (no S3 keys in the Worker), nothing public. Share tokens are random, hashed at rest, expiring, and revocable.
- Never log event content.
- Not end-to-end encrypted: the server reads events to answer time-range queries and to send invitations.
- Secrets live in Worker secrets. The replicator's credentials can write but not delete.

## 10. Reliability runbook

1. **Replication.** Phase 3a: a nightly cron copies new and changed objects to the second vendor. Phase 3b: R2 event notifications to a Queue to a replicator Worker, for minutes-level RPO (verify availability and limits).
2. **Backup bucket.** Versioning and Object Lock on, replicator cannot delete. A bug or bad deploy cannot erase the backup.
3. **Nightly D1 export** to the same bucket.
4. **Local mirror.** `rclone` to this Mac on a schedule. Use a **new** remote and token for this bucket (the existing token reads only `share`).
5. **Scrub.** Nightly compare of counts and hashes, primary versus backup; alert on any difference.
6. **Restore drill**, twice a year: rebuild D1 from R2, then rebuild from the backup alone into a fresh bucket and standby, and time it against the RTO.
7. **Monitoring.** An external uptime check from a different provider hits `/health` and a real `PROPFIND`; alerts go to the phone.
8. **Deploys.** Versioned deployments with gradual rollout; keep a one-command rollback; never deploy the Worker and change DNS or the standby on the same day.
9. **Incident response.** If Cloudflare is down: devices keep working offline; do nothing unless it exceeds the RTO, then follow the standby runbook (repoint DNS).

## 11. Known constraints and risks

| Risk | Handling |
|---|---|
| Workers Free has a 10 ms CPU limit per request (reported; verify) | No RRULE expansion on the server, no XML/iCalendar libraries, string-built XML; Workers Paid if needed (Email Service also needs it) |
| `MKCALENDAR` reportedly never reaches a Worker (workerd issue #6877; re-test) | Calendars are provisioned by `/admin`; "New Calendar" in that account on a device will fail, which is acceptable |
| iOS gets no push from third-party CalDAV (as far as I know) | Devices fetch on a schedule and when Calendar opens; Sill nudges a refresh on the Mac |
| Cloudflare WAF/bot rules may block DAV clients | Skip rule for the hostname; test in phase 0 |
| R2 and Cloudflare incidents | Section 4: second vendor, replicas, standby |
| Apple clients are picky about discovery and property names | Golden files captured from Radicale; real iPhone and Mac testing from phase 0 |
| Email Service is beta | `Mailer` port with a SES/Postmark/Resend fallback |
| CalDAV scheduling is a large build | Tiers A to C first; D has its own phase |
| Shared recurring-event edge cases (exceptions, time zones) | Store verbatim, let clients expand, test the cases below |

## 12. Migration (nothing is deleted until the end)

1. **Back up first.** Mac Calendar: File, Export, Calendar Archive.
2. Deploy the Worker, create R2 and D1, create the user and the calendar "Sill".
3. Add the CalDAV account on the **Mac** (System Settings, Internet Accounts, Add Other Account, CalDAV) and on the **iPhone** (Settings, Calendar, Accounts, Add Account, Other, CalDAV).
4. **Rescue unsynced iPhone events:** open each, edit, change its Calendar to the new one. Moving across accounts is allowed and uploads it.
5. Import the archive into the new calendar on the Mac.
6. Set the new calendar as default on both devices.
7. Verify for a few days with the acceptance tests.
8. Only then turn off iCloud Calendars and choose **Keep on My iPhone / Mac**.

## 13. Phases and exit criteria

| Phase | Scope | Done when |
|---|---|---|
| **0 Spike** | Minimal Worker both Apple clients accept; check the invitee UI; check WAF; capture Radicale/Baïkal reference traffic | Create one event on iPhone and see it on the Mac |
| **1 Calendar MVP** | Section 7 core, R2 + D1, per-device passwords, trash, `/admin`, golden-file tests | Acceptance tests below pass on a real iPhone and Mac |
| **2 Sill** | Section 14 edits, health cue | Voice entry saves into the synced calendar |
| **3 Reliability** | 3a nightly copy, backup bucket, D1 export, local mirror, scrub, monitor; 3b event-driven replication; first restore drill | A drill meets the RTO and the scrub is clean |
| **4 Sharing A to C** | Share links, Sill email invite, Inbox calendar | A friend adds an event from a link and from an email |
| **5 Multi-user and native invites (D, E)** | Family accounts, ACLs, CalDAV scheduling, iMIP, reply handling | Invite an outside email from Apple's Calendar and see the reply update |
| **6 Modules** | Files over WebDAV (Obsidian vault off iCloud Drive), contacts, reminders, gallery on the share module, cloud lab | Per module |

**Acceptance tests (real iPhone and Mac):** create, edit and delete each way; edit offline then reconnect; all-day and multi-day events; a recurring event with one edited occurrence; alarms fire on both devices; an event in another time zone; a 500-event import; two devices editing the same event (the later write wins and nothing is lost silently); a bad password is rejected and a revoked device stops syncing.

## 14. Sill integration (changes to `sill.swift`)

Reading needs **nothing**: Sill already queries `EKEventStore` across all calendars and observes `.EKEventStoreChanged`. Three small edits:

```swift
// 1) Settings block
let syncAccountName = "Sill Sync"   // the Description typed when adding the CalDAV account
let syncCalendarTitle = "Sill"

// 2) VoiceEntry.saveTapped(): write to the synced calendar (iCloud also reports as a CalDAV source)
func syncCalendar(_ store: EKEventStore) -> EKCalendar? {
    store.calendars(for: .event).first {
        $0.source.title == syncAccountName && $0.title == syncCalendarTitle && $0.allowsContentModifications
    }
}
// guard let cal = syncCalendar(store) ?? store.defaultCalendarForNewEvents else { ... }

// 3) Top of EssentialsView.surfaced(): nudge a pull when the panel opens
store.refreshSourcesIfNecessary()
```

Confirm that `source.title` equals the account description on this macOS. Later: a health cue from `/health`, an Invite field on the draft card (tier B), and an Inbox-pending count. Any new network request should be reflected in the header comment that currently calls weather Sill's only one.

## 15. Later modules

- **Files** (WebDAV or S3-compatible) so the Obsidian vault and Draftpad note leave iCloud Drive; check what Obsidian sync plugins support for S3/WebDAV before building.
- **Gallery** as a consumer of the share module.
- **Contacts** (CardDAV) and **Reminders** (VTODO; some newer Reminders features are iCloud-only, so check what a CalDAV list keeps).
- **Cloud lab**: define its needs first.

## 16. Open decisions

- Final project name (neutral, since the gallery and lab will depend on it).
- Hostname and domain, and which registrar (ideally independent of the host).
- Second vendor: S3 versus B2.
- Workers Free versus Paid (CPU headroom and Email Service both point to Paid).
- Whether to keep iCloud as a read-only archive after migration step 8.
- What the private cloud lab needs to sync.

## 17. Prior art and sources (checked 2026-10-08)

CalDAV on Workers already exists, so this is not a first; what is distinct here is the redundancy design, the R2-plus-D1 split with a rebuildable index, per-device passwords, native invite support, and the shared foundation for several apps. Check each repo's license before borrowing code.

- github.com/WANGPLab/CF-Workers-CalDAV (Workers + D1 + R2 + KV)
- github.com/William-Tong/cloudflare-worker-caldav (Workers + D1)
- github.com/retogo/icloud-calendar-mcp (Workers Free CPU note)
- github.com/cloudflare/workerd/issues/6877 (MKCALENDAR)
- github.com/bitfireAT/davx5-ose/discussions/801 (Cloudflare blocking a DAV client)
- blog.cloudflare.com/cloudflare-outage-february-20-2026 (Cloudflare post-mortem)
- Third-party incident write-ups (bex.co, codercops.com, theplanetsoft.com): unverified by Cloudflare
- Cloudflare Email Service docs; flaviocopes.com/cloudflare-email-service (beta, Workers Paid for arbitrary recipients)
- support.gingerlabs.com: Notability Cloud FAQ; Auto-Backup/Third-Party Backup guide
- RFC 4791 (CalDAV), RFC 6638 (scheduling), RFC 6047 (iMIP), RFC 5546 (iTIP), RFC 6578 (sync-collection)
