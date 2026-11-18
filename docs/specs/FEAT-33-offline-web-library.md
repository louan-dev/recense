# FEAT-33 · The web library works with no network: pin an item, open it in Safari offline, one explorer on every surface

From: owner 2026-11-18 (research paste: "offline file explorer … browser with zero Wi-Fi … or a Recense Wing"; validated against main f655021) · Status: `[ ]` spec, S0 spike first · Effort: medium, in slices
Builds on: UI-12 (editor PWA service worker), FEAT-18 H2 (hub library), PLAN-1118 §5j step 8 (one client build, three origins), FEAT-22 (Main and Guest roles).

## Verdict first
- **Affirm the goal, object to the paste's framing.** The paste offers two surfaces with one engine. That engine is already planned: §5j step 8 and FEAT-18 H2.
- **What is genuinely missing:** the browser itself keeps nothing.
  - Proof: `§5j` says "No service worker except the editor PWA". `library/src/client/` has no cache of media.
  - So a Safari tab with no network shows nothing, even for an item played yesterday.
- **The piece this spec adds:** "Pin offline" in the web client, plus one explorer view that every host shows.

## Premises checked against the code (2026-11-18)
- **A browser can't run the app from a `file://` page:** true in substance, so not attempted.
- **A service worker pattern already exists:** `editor/src/pwa/sw.js` and `library/src/client/editorpwa/sw.js`.
  - They cache the shell and never cache `/api/`. **Reused as is.**
- **An index of the homes exists:** `.recense-index.json` (`shared/homes.swift`). **Reused**; the explorer reads it.
- **The hub serves media:** false today. `hub/` answers only `/api/health` and `/api/note`. Media serving is FEAT-18 H2.
- **The Worker already answers range requests** (`archive.js:78`, `common.js:115`): proven.
- **OPFS, `showDirectoryPicker`, `RecenseBridge`, `matters-index.json`:** none exist in the repo.
  - `showDirectoryPicker` is Chromium-only. Safari and Firefox lack it, and they are the owner's browsers.
- **"The WKWebView is capped at 2 live views for 8 GB":** no such cap is in the code. It is unmeasured, so not adopted.

## S0 · Spike: does Safari play a pinned file offline (untested; it decides everything below)
- A 60-minute `.m4a` and a 10-minute `.mp4` go into Cache Storage. The service worker answers `Range` with `206` cut from the cached Blob.
- **Pass:** in airplane mode, seek to 45:00 and play, on:
  - iPhone and iPad, in a Safari tab and as a Home Screen web app
  - Mac Safari and Firefox
- **Also measure:**
  - the quota (`navigator.storage.estimate()`)
  - whether `navigator.storage.persist()` is granted
  - whether pins survive 8 days without opening the page
    - WebKit clears script-written storage after 7 days without use, except for Home Screen apps (**assumed**, WebKit policy of 2020)
- **If Cache Storage fails the range test:** try OPFS (`navigator.storage.getDirectory()`) as the store.
- **If both fail:** pinned items play only inside the apps and the hub, and the page says so. Nothing is faked.

## S1 · The client shell opens with no network
- The web client gets the UI-12 service worker pattern: shell cached, `/api/` never cached, a sign-in redirect never cached.
- One worker file for the three origins (Worker, hub, app WebView), as §5j step 8 asks.
- **Done when:** with Wi-Fi off, the Gallery page opens on the iPhone in under 1 s from the cache and lists the pinned items.

## S2 · Pin offline
- Each item has a "Keep offline" control: a visible button, a menu entry and VoiceOver, never a gesture alone.
- Pinning stores:
  - the media
  - `asr.json` and every `tr/<lang>.json`
  - `features.json`
  - the item's note
- Each part's sha256 is checked against the manifest; a mismatch is not kept and says why.
- **Guests:** they pin only what their link gives them.
- **Done when:** a pinned item plays, lights its words and switches en/fr/vi in airplane mode. Unpinning frees its bytes, and the explorer's size badge proves it.

## S3 · One explorer view
- `library/src/client/explorer.js`: the homes and their items, read from `.recense-index.json` (through hub `/api/library`, FEAT-18 H2) or from the Worker's listing.
- **Facets:** Has transcript · Languages (en / fr / vi) · Has note · Kept offline.
- Folder sizes are counted only when a folder is opened, never in one walk of the whole tree.
- **Hosts:** the web page, the hub, the Mac wing panel (`editor/src/wingpanel.js` exists; read how it hosts before S3) and the iOS app's web places.
  - One file, no second copy (the parity law).
- **Dropping an item on Draftpad** inserts a link to it at the playhead's time. It reuses FEAT-23's moment links, not a new link format.

## Offline and ownership (the gate)
- **First load:** needs one origin (Worker, hub or app) once. After that, nothing is needed at the moment of use.
- **Catch-up:** new pins download when a network returns, without ever blocking playback.
- **No company is required:** the hub serves the same client.

## Not adopting (and why)
- **`showDirectoryPicker`:** Chromium-only. The owner's browsers lack it.
- **happy-opfs, OPFS.ts:** licence not stated (GitHub reports NOASSERTION), and our use is a few calls. Study only.
- **opfs-explorer:** only its lazy folder-size idea is taken (S3).
- **A sound preview when the pointer hovers:** sound that starts without an action breaks "predictable, low clutter". A preview is a deliberate tap.
- **filebrowser (Go):** a second server beside the hub.

## Owed
- S0 results decide S2's store.
- The wing panel's host model must be read before S3.
