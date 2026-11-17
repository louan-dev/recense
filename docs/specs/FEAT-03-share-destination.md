# FEAT-03 · Share: consolidated cross-device destination

From: T-0035 · Status: `[ ]`

**Revised 2026-11-16 (owner: "Yes, spec it"; lane notes-search-curve):** one landing place, not two.
Arrivals land in `Recense/downloads/` and are sorted into their home by the watcher that already exists;
there is no `Recense/share/`. The first iOS route is "Open with Recense" (declared file types); the Share
Extension comes second. What happens after landing (the item's note, the ▶ link back to it) is FEAT-23 P0b.

One destination for anything shared to Recense, from any mechanism, on
any device. Not "AirDrop" — AirDrop is one entry path among several
(see P1). Renamed from AirDrop to Share 2026-11-12 (triage.md T-0035)
because the receiver mechanism already covers the whole system Share
Sheet, not AirDrop alone.

## Built `[x]`
- **The exact local-folder-plus-manifest pattern this spec reuses**
  already exists for a sibling case: `shared/mediadownload.swift:66`
  (`Recense/downloads/`) + `:72` (`manifest.json` beside it) + `:125`
  `adopt()` — sweeps in files placed there by Finder, Pulltube, **or
  AirDrop** and records them with sha256. Share lands **in the same**
  `Recense/downloads/` (revised 2026-11-16), not a new folder or mechanism.
- Mac already has outgoing AirDrop: `mobile/HostApp/macOS/Window.swift:103`
  `airDrop()` — sends picked items out via `NSSharingService(.sendViaAirDrop)`.
  This spec is the opposite direction (receiving); the two don't overlap
  in code but both live near `Window.swift`.
- `mobile/Extension/FileProviderExtension.swift` — existing File Provider
  extension pattern (same source macOS + iOS) relevant to P2's folder exposure.

## Planned `[ ]`

### P1 · Three input mechanisms, one destination
1. **First (iOS): "Open with Recense"** — the app declares the file types it opens, so AirDrop offers it
   directly (FEAT-23 P0b, spike S1). **First (Mac):** the watcher also takes AirDrop arrivals from
   `~/Downloads`, recognised by the system's `sharingd` arrival mark (FEAT-23 P0b, spike S2).
   **Second: Share Extension (iOS) / Share Menu item (Mac)** — registers Recense
   as a destination in the system Share Sheet. Receives from AirDrop,
   Messages, Mail, Safari, "Save to Files," any app's Share action —
   AirDrop is one path in, not the feature.
2. **Bluetooth** — via FEAT-02's `shared/p2ptransport.swift`. No Share
   Sheet involved; a direct peer session, same landing folder as P2.
3. **QR code** — not a transport, a pairing trigger. Device A runs a
   small local server (reuse the pattern of Recense's existing localhost
   server, port 47123, per `.claude/CLAUDE.md`'s Recense section — a
   second instance or a route on the same one, TBD at `/derive`); the
   QR encodes that address; device B scans with its camera and pulls
   the file over plain HTTP on the LAN. The only one of the three that
   reaches non-Apple devices (any camera + browser, no app install) —
   relevant for sharing with people outside the Apple ecosystem.

### P2 · Local landing folder (revised 2026-11-16: `downloads/`, the one that exists)
- **Superseded below:** arrivals land in `Recense/downloads/` and its manifest; the watcher
  (`strip/app.swift:6808`, BUG-16) sorts them into their home (`shared/homes.swift:161-163`). The bullets
  below are the 2026-11-12 draft, kept for the record; read `share/` as `downloads/`.
- Mac: `~/Recense/share/`, sibling to the existing `~/Recense/downloads/`.
- iOS/iPadOS: the app's equivalent container path — **assumption,
  verify at `/derive`:** likely `Documents/share/` inside the app
  sandbox, mirroring how `mediadownload.swift`'s model half is already
  shared across platforms (per its header comment).
- `manifest.json` beside it, same shape as `DownloadEntry` (source,
  size, sha256) — generalize `Downloads`'s type or mirror it; `/derive`
  decides which, not this spec.
- Every arrival gets its sha256 recorded at landing time: tamper-evidence,
  not just dedup — matters more here than for downloads, since Share can
  carry documents the owner needs to prove are unaltered later (see P5).

### P3 · R2 catch-up mirror (never the first landing spot)
- Revised 2026-11-16: an arrival is an ordinary item in its home, so it catches up by FEAT-22's ladder
  (this device → a paired device by Carry → the hub → R2, optional and last). No mirror of its own.
- Decision already logged in `triage.md` T-0035 (2026-11-12): AirDrop
  needs no network, so Share's landing must not need one either. R2 is
  catch-up only, per the offline-first gate's sync exception.

### P4 · The Recense window (Mac)
- Owner asked: "we need to build out the recense window. what should it
  look like?" — **not decided**, needs its own pass (UI, not this
  spec's P1–P3 plumbing). Proposed scope for a follow-up: a Share tab or
  section in the existing Mac window (`Window.swift`) listing
  `Recense/downloads/`'s manifest, newest first, with source icon (AirDrop /
  Bluetooth / QR) and sha256 status. **Flag to owner:** this needs its
  own design pass before `/derive`, not folded into P1–P3's plumbing work.

### P5 · Legal-document handling — scope not yet confirmed by owner
Raised in chat 2026-11-12, logged in `triage.md` T-0035 as **open**:
owner has not yet said whether this folds into FEAT-03 or becomes its
own spec. Written here as the default assumption pending that answer:
- Encrypt before any R2 touch (reuse the `rclone crypt` pattern from
  `sync/`'s messenger backup, A8 in `docs/PROGRESS.md` — "Private
  prefix, never public" is already the precedent for sensitive material).
- Never auto-expire: route to a permanent tier, not a `tmp/`-style
  cache (Recense's existing media cache expires in ~9 days — wrong
  default for a legal document).
- sha256 on arrival (already covered by P2) doubles as chain-of-custody
  here, not just dedup.
- Default: local + peer-to-peer only; cloud mirror (P3) becomes opt-in,
  not automatic, for anything tagged legal.
- **Open legal question, not a technical one:** whether routing
  privileged material through any third party (even encrypted) raises a
  confidentiality issue under the owner's jurisdiction's rules. Not
  resolved here — flagged as unverified in `triage.md`.

## Invariants
- Unplug Wi-Fi, AirDrop a file to the Mac: it is in its home (via `Recense/downloads/`), with its
  note (FEAT-23 P0b), before Wi-Fi reconnects. If this fails, the design regressed to
  cloud-dependent (this is the literal check the owner asked for 2026-11-12).
- A file landed via any of the three P1 mechanisms produces exactly one
  manifest entry with a sha256 — no duplicate records for the same bytes.
- One manifest (`Recense/downloads/`'s), so one reader; no second parser exists to drift.

## Planned code layout (for `/derive`)
- `shared/mediashare.swift` (or a generalized `shared/mediadownload.swift`
  — `/derive` decides) — manifest, `adopt()`-equivalent, sha256.
- iOS Share Extension target (new, under `mobile/`).
- Mac Share Menu service (new, under `mobile/HostApp/macOS/` or `strip/`).
- QR path: local HTTP route + QR generation (device A), scan + fetch (device B).
- `editor/test/` or `mobile/ios/Tests/` equivalents — exact names at `/derive`.

## Done checks
- `zsh strip/build.sh` + `strip/recense selftest` (Mac).
- iOS compile (`.claude/CLAUDE.md` Checks table).
- Real-device check (owner): AirDrop a file to the Mac with Wi-Fi off,
  confirm it lands in its home with its note; repeat the same drop to iPhone
  and iPad; confirm all three show the manifest entry with matching sha256.
- P4 (window UI) and P5 (legal handling) need their own Done checks once scoped.

## Offline-first gate
- **AirDrop, Bluetooth, QR-to-local-HTTP:** no outside service, ever —
  all three are on-device or LAN-only.
- **R2 (Cloudflare):** touched only in P3, only after local landing,
  only as catch-up — never required at receive time, never blocking.
- **For P5 (legal, if folded in):** R2 becomes opt-in, not automatic,
  for anything tagged legal — stricter than the general case.
