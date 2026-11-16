# UI-12 · The editor at a local path: offline by default, sync on a drip

From: owner 2026-11-16 ("I want it without being behind cloudflare. It should be like a local path that can load on a
browser and any device that syncs routinely when it has a connection, edit or upload. It should behave like something
starved of water, one drip of connection it uses it to its full advantage to sync everything then goes back offline.
Like it prefers being offline and will connect in and out when necessary and never connected as the default")
· Status: `[~]` S1 built but the wrong shape (see Amendments); S2–S5 `[ ]`
Law: `docs/law/offline.md` (assume no connection; the share ladder; the network is an optimization, never a dependency).
Lanes: `editor/` (the page), `strip/` + `mobile/HostApp/` (the local origin), `shared/carry*.swift` (the drip).

## The rule from the owner
1. **A local path, not a URL someone else gates.** The editor opens because the device is on, not because a network is.
2. **Any device.** Mac, iPhone, iPad, in a browser.
3. **Offline is the resting state.** Not a fallback mode, not a degraded mode: the default.
4. **One drip, used fully.** The moment a connection exists, everything queued goes, both ways, in one burst.
5. **Then let go.** No connection is held open. Never connected as the default.

## What exists (facts, 2026-11-16)
- `editor/dist/editor.html` — one self-contained file, no external subresource, opens offline from disk today.
- `editor/src/pwa/sw.js` + `editor/dist/pwa/` — service worker, manifest, icon: cache the page once, open from cache after.
- `editor/src/webstore.js` — in a browser there is no native host, so text and ink land in IndexedDB. Its own header:
  *"Nothing leaves the device."* No sync path exists for the browser editor.
- `library/src/editorpwa.js` + `library/src/worker.js:100-102` — S1 as built: `/main/editor/` on the Cloudflare Worker,
  owner-only behind Access. **This is the shape the owner rejected**: a network precondition to open your own editor.
- `shared/p2ptransport.swift` (FEAT-02, P1–P3 built) — MultipeerConnectivity: Bluetooth or peer-to-peer Wi-Fi, no router,
  no internet, no company in the middle.
- `shared/carrysync.swift`, `carrymanager.swift`, `carryapply.swift` (FEAT-09, P1–P4 built, device check owed) — pair once,
  then an append-only ops log; devices exchange "how much of yours have I applied", send only the difference, never
  overwrite. **This is already the drip**, for Homes' files, between native apps.
- `shared/notesync.swift` — 3-way merge (base / mine / theirs) through `NSFileCoordinator`, used for `draftpad.md` today.
- Gaps named in FEAT-09 itself: carry starts on "Carry Now" or at launch, not when two paired devices simply meet; a real
  text conflict keeps both because no base is tracked; the browser editor is not a carry participant at all.
- `docs/law/offline.md` ladder steps 2–4 (store-and-forward, our own relay) are the owner's direction, unspecced, untested.

## The decision (owner, 2026-11-16)
- **Host:** a local origin on each device. The Mac serves the page to itself; the iOS/iPadOS app serves it to itself.
  A real origin is what makes the service worker and durable IndexedDB work at all — `file://` gives neither in Safari,
  and is not a usable surface on iPhone or iPad. **The page does not change; only its host does.**
- **Distance:** peer-to-peer first; when the devices are apart, a relay we own (the Mac mini, a VPS) holds the ops until
  the other side wakes. Ladder step 3. Never a third party, and the relay stays replaceable.

## Shape
- **The page is the same page.** `editor/dist/` is built once and served by whichever host is local. One bundle, three hosts.
- **The save contract is the same contract.** The page keeps posting to `webkit.messageHandlers.{editor,ink}`. On a native
  host those already land in files. In the browser-on-local-origin case the host bridges them into the **same carry ops log**,
  so a page edited in a browser and a page edited in the app are one matter, not two (FEAT-08).
- **IndexedDB stops being the store and becomes the outbox.** What `webstore.js` keeps is the queue of unsettled ops, not
  the only copy. It survives a quit; it is drained on the next drip.
- **Learning there is something waiting, without being connected:** on a connectivity change (and only then), exactly one
  conditional request to the relay. `304` → close the link and go back offline. Anything else → drain both ways, then close.
  Zero requests while idle. This is the one place the design spends a request, and it spends one.

## Phases
- **P1 · Local origin, Mac.** `strip/` serves `editor/dist/` on `127.0.0.1` at a stable port, loopback only, no LAN
  exposure; the page's saves land in `draftpad.md` and `draftpad.ink.json` through `notesync.swift` as the native host does.
- **P2 · Local origin, iOS/iPadOS.** The same, served by the app to its own WKWebView and to Safari on the device.
- **P3 · The browser page joins carry.** The host turns the page's posts into ops on the existing log; `CarryApply` settles
  them. Draftpad text uses `notesync.swift`'s 3-way merge against a tracked base, so a conflict merges instead of keeping
  both (closes FEAT-09's named gap for Draftpad's own pages).
- **P4 · Meet and drain.** Carry starts when two paired devices meet, with no "Carry Now" pressed (FEAT-09 P4's open half).
- **P5 · The relay (ladder step 3).** A server we own holds ops for devices that are apart. One conditional request per
  connectivity change; no polling; no held connection. Needs its own spike before code, per `docs/law/offline.md`.

## Build notes, phase by phase (lane offline-editor, 2026-11-16; branch `work/offline-editor`)
Each phase is written here before its code. "Coded, not compiled" = Swift written in a Linux container with no
toolchain: the owner's Mac build and `recense selftest` are the first compile.

### P1 · as built: the Mac local origin
- **What:** `shared/localorigin.swift` (one copy, Mac and iOS: Network.framework only). A tiny HTTP/1.1 server bound to
  `127.0.0.1:47823` (stable; `RECENSE_ORIGIN_PORT` overrides for one launch). Never `0.0.0.0`: the listener's required
  local endpoint is the loopback address and `acceptLocalOnly` is on. Every response carries `Connection: close`;
  no keep-alive, nothing held.
- **Routes:** `GET /` → the editor page (`editor/dist/pwa/index.html`, copied into the bundle by `strip/build.sh` with
  `sw.js`, `manifest.webmanifest`, `icon.svg`). `GET /ui12/state` → the page's three files as they are now.
  `POST /ui12/drain` → the page's outbox; each entry lands through `notesync.swift`.
- **Who may call:** a request whose `Host` is not `127.0.0.1:<port>` or `localhost:<port>` is refused (DNS rebinding);
  a POST whose `Origin` is not the same origin is refused (another web page in the same browser cannot write).
  The API answers no CORS headers, so another origin cannot read `/ui12/state` either.
- **The save contract, unchanged:** channel `editor` → `draftpad.md` through `planNoteSave(base:mine:theirs:)`, the very
  function `App.saveNow` uses (write / adopt / merge / conflict sibling). Channels `ink` → `draftpad.ink.json` and
  `matter` → `draftpad.matter.json` (FEAT-08's sidecar, lane draftpad-matter): written when the file still equals the
  entry's base; otherwise the host answers with the file, and the page unions it with its own merge
  (`mergeInk` / `mergeMatter`) and sends again. Swift never merges JSON it does not own.
- **Check (selftest `localOriginSelftest`, no socket):** request parsing; `/` serves the page with `text/html`; a path
  outside the bundle is refused; wrong `Host` → 403; foreign `Origin` → 403; a drain on a temp vault writes the text,
  a drain against a changed file merges both sides through `planNoteSave`, the same lines changed both ways keeps the
  other side in the sibling; a stale ink base returns the file instead of writing; the bind address is `127.0.0.1`.
- **Device check owed (Mac):** `curl -sI http://127.0.0.1:47823/` → 200; `curl -sI http://<the Mac's LAN IP>:47823/`
  from the iPhone → refused; Safari at `http://127.0.0.1:47823/` opens the editor; text typed lands in `draftpad.md`.

### P2 · as built: the iOS/iPadOS local origin
- **What:** the same `shared/localorigin.swift`, started by the app (`mobile/HostApp/iOS/Draftpad.swift`) with the
  vault `DraftpadFile` already uses. Safari on the same device opens `http://127.0.0.1:47823/`.
- **The app's own WKWebView keeps loading the bundled page from disk** with its native handlers: it already opens with
  no network and saves through the same files. Loading it over loopback would only add a dependency on the server
  running. (Owner question 1.)
- **iOS stops the server when the app is suspended.** The page still opens in Safari from its service-worker cache, and
  edits wait in the outbox (P3) until the app is next in front. That is the outbox's job.
- **Check:** shared with P1's selftest (same file). Device check owed: iPhone and iPad, radios off, Safari opens the
  page, the text reaches the app's Draftpad.

### P3 · as built: the browser page joins carry
- **Outbox (`editor/src/webstore.js`):** IndexedDB keeps, per channel, `{base, mine}`: the text the host last
  confirmed and what the page holds now. Ten edits are one entry (the earliest base, the latest text) because a 3-way
  merge from the earliest base is the same merge. It survives a quit. It is drained to the local host on: page load,
  each change (debounced), `online`, and the page coming to the front. Never on a timer. When the host is not there the
  entry simply stays.
- **Answers:** `written` → settled, base = mine. `merged`/`adopted` → the page shows the host's result if nothing was
  typed meanwhile; if something was, the entry's base becomes what was sent, so the next drain merges the new typing
  onto the result. `stale` (ink, matter) → the page unions the file into its own, re-queues.
- **Carry (`shared/carrysync.swift`, `carrymanager.swift`, `carryapply.swift`):** a changed file's `put` op now records
  its parent (`base`, the sha it was edited from). `decide` gets that parent as its base, so "unchanged since the base"
  → replace and "both changed" on text → `merge3`, closing FEAT-09's named gap. Bases live in
  `Recense/.carry/base/<sha256>` (text files only). After an op settles, the scan's memory of that file is the version
  just received, so the receiver never echoes it back as its own edit. Draftpad's three files ride the same log as a
  home named `draftpad` (the vault folder, not under `~/Recense`): `draftpad.md` merges by lines; a JSON sidecar that
  both sides changed lands beside it, and the page unions it on the next load (`mergeInk`/`mergeMatter`), then the
  sibling goes to trash.
- **Check:** `editor` `npm test`, new tests tagged `// Regression guard: UI-12` (outbox coalescing, survives a quit,
  merged answer with and without typing meanwhile, stale JSON unions, no request while idle, no request off-device).
  Swift selftest cases: put records its parent; fast-forward replaces; both changed text merges; no base → keep both.

### P4 · as built: meet and drain
- FEAT-09 P4's automatic trigger (connect, change, foreground) is built for homes. The open half here: a Draftpad
  write (native editor, local origin, an iCloud arrival) is a change too. Mac: the FSEvents stream also watches the vault
  folder, counting only `draftpad.md`, `draftpad.ink.json`, `draftpad.matter.json` (`DraftpadCarry.counts`). iOS: the
  file's own save posts the change. Page: the outbox drains when the host is reachable again, nothing pressed.
- **Check:** selftest for `DraftpadCarry.counts` (vault files count, other vault files do not); JS: `online` and
  `visibilitychange` drain the outbox once, with no timer left behind.

### P5 · the relay (ladder step 3): spike first, then a minimal relay we own
- See "P5 spike" below, then `relay/` (Node, no dependencies). Not deployed anywhere.

## Done checks
- **D1 Airplane open.** Radios off, app never launched this boot: the editor opens at its local path on Mac, iPhone and
  iPad, and accepts text and ink. Network requests to open: **0**.
- **D2 Idle silence.** Editor open, nothing changed, one hour, a connection available: **0** network requests.
- **D3 One drip.** Device A edits offline; A and B are brought together; without anyone pressing anything, B has A's edit
  and A has B's. Measure time from meeting to settled, and that no connection is held after (**0** open sockets to the
  relay, **0** further requests until the next change).
- **D4 Nothing lost.** Both sides edit the same page while apart; after settling, every line from both sides is present,
  once, and the page traces back to its seeds (FEAT-08's rule). Words lost: **0**.
- **D5 Survives a quit.** Edits made offline, app force-quit before any connection: after relaunch they are still queued
  and still settle on the next drip.
- **D6 No Cloudflare in the path.** With `gallery.improvdiplomat.workers.dev` unreachable (hosts file or radios off),
  D1–D5 all still pass.
- **D7 Distance.** A edits in one place, B is elsewhere; when each next has a connection, both converge through our own
  relay, with one conditional request per connectivity change and none while idle.

## Baseline to beat (law: `docs/law/order.md`, "When a wish is done")
**Baseline: `draftpad.md` in the Obsidian vault on iCloud Drive today** — the sync this replaces. Measure, on the same
page and the same three devices:
| Measure | iCloud Drive today | UI-12 must |
|---|---|---|
| Open and edit with radios off, cold | works (Obsidian local) | match |
| Requests while idle, per hour | iCloud: continuous, not knowable to us | **0**, and knowable |
| Time from reconnect to the other device's edit arriving | measure 5 runs, record median | match or beat |
| Words lost when both sides edited while apart | measure (iCloud keeps conflict copies) | **0**, merged, not a sibling file |
| Works with no internet at all, two devices in a room | **fails** (needs iCloud) | **passes** (p2p) |
Record the five numbers in this file when P1 lands, and again at each phase.

## Amendments
- 2026-11-16 · **S1 is kept as code, demoted as a destination.** `/main/editor/` behind Access (commits `bd708ca`,
  `13a3935`) proved the page caches and runs offline after one visit, and `editor/src/pwa/`, `webstore.js` and
  `ui12-pwa.test.mjs` are all reused unchanged here. But it makes a network a precondition to open the editor, which
  `docs/law/offline.md` forbids, so it is no longer the way in. Whether the route is removed outright or left as the
  relay's own page host is the owner's call.
- 2026-11-16 · Known drift from S1, to fix whichever host wins: `library/src/client/editorpwa/{index.html,sw.js}` was
  last copied at `13a3935` and is two commits behind `editor/dist/` (`a126d09` pen strokes, `0438faf` date/heading
  colour). The copy is manual (`library/src/editorpwa.js` header).
- 2026-11-16 · This spec is UI-12's first written form; the id was already cited in code and tests with no spec or
  INDEX row behind it.
