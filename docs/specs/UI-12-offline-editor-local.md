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
- **P6 · The browser player (FEAT-19 S-editor P4).** `[~]` (lane editor-player, 2026-11-16) In a browser the editor plays its own
  recording through Gallery's player rules, embedded, not re-written. Code: `editor/src/player.js` (the adapter),
  `library/src/client/webplayer.js` (the player's rules, home `library/src/client/`, bundled into `editor.html` by esbuild).
  - **One interface, two backends.** `load(src, title)`, `play()`, `pause()`, `toggle()`, `seek(t)`, `setRate(r)`,
    `setLoop(a, b)` (`b <= a` clears it). Backend **host** when `webkit.messageHandlers.audio` exists, else **web**.
  - **I1 Host wins.** With a native host the adapter only posts to `webkit.messageHandlers.audio`, as today:
    `{action:'seek', time}` unchanged; `play`/`pause`/`rate`/`loop`/`load` are new posts the hosts pass to
    `onAudioAction` (nothing set there today, so no behaviour changes). No `<audio>` element is made, no Media Session set.
  - **I2 Web plays.** With no host the same calls drive one `<audio>` element with Gallery's rules: pitch kept at speed,
    play at the end starts over, A–B loop, `audioSession.type = "playback"`, Media Session title/artwork, `play`, `pause`,
    `seekto`, `setPositionState` (valid length, rate never 0), no ±10 s, dropped when the recording is closed (FEAT-19 S-web).
    The transcript follows the element's time (`updateTime`), so cue highlight and cue-tap seek work as with a host.
  - **I3 Offline plays what the device holds.** A recording plays with no network when it is a `blob:`/`data:` URL (a file
    picked on this device), is in Cache Storage (S1's cache), or comes from the page's own origin when that origin is the
    local hub (loopback or `.local`). Anything else, offline, is refused before play with one plain line:
    "This recording isn't on this device. It needs a connection." Never a spinner; a load error says so the same way.
  - **I4 One player.** No second copy of the rules in `editor/`. When Gallery's `gallery.js` adopts `webplayer.js`
    (owed, after lane lockscreen-everywhere lands: it edits the same lines) the rules have one source in fact, not just in law.
  - **Done checks.** E1 (node, tagged `// Regression guard: UI-12`): the host backend posts and makes no element; the web
    backend drives the element; availability rule per source kind. E2 (Playwright, Chromium, `dist/editor.html`, no host):
    a generated 3 s tone loads, plays (`currentTime` advances), seeks, sets `navigator.mediaSession.metadata.title` and a
    position state; offline (`context.setOffline`) a remote URL gives the plain line and does not play.
    E3 (device): see Handoff.

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

## Handoff (lane editor-player, P6, 2026-11-16)
**Built**
- `editor/src/player.js`: one interface (`load`, `play`, `pause`, `toggle`, `seek`, `setRate`, `setLoop`, `state`, `close`)
  with two backends. **host** when `webkit.messageHandlers.audio` exists: each call is a post to it, and `seek` posts
  `{action:'seek', time}` exactly as before. **web** otherwise: it drives Gallery's player rules.
  Also `mediaAvailability(src)`, which returns device / cached / network / unavailable, and the browser-only transport
  (Play/Pause, time, scrubber, speed 1×→1.25→1.5→2→0.75, "Choose a recording…" picker, status line).
- `library/src/client/webplayer.js` (new, Gallery's folder): the rules lifted from `gallery.js` `buildMedia`.
  Pitch is kept at speed. Play at the end starts over. A–B loop and track loop. `audioSession.type="playback"`.
  Media Session: title, artwork, the loop shown on the second line, play, pause, `seekto`, `setPositionState` (length
  only when known, rate never 0), ⏮ starts over, no ±10 s, dropped on close. It is a plain script, and esbuild bundles
  it into `editor.html`.
- `editor/src/audio.js`: the sidecar owns a player. `seek` goes through it, and it gains `load/play/pause/toggle/
  setRate/setLoop`. `setAudioTranscript({src})` loads. In a browser the pane carries the transport and stays shown while
  a recording is loaded. `index.js` adds `recenseEditor.loadAudio/playAudio/pauseAudio/seekAudio/setAudioRate/
  setAudioLoop/audioState/showAudio`. `styles.css` adds `.rc-player*` (blue text controls). `editor/dist` is rebuilt.

**Tests**
- `editor/` `npm test`: 265 tests, 264 pass, 0 fail, 1 skipped (the S1 WebKit PWA test, skipped as on main). 8 tests
  are new, all tagged `// Regression guard: UI-12`:
  - 7 node tests in `test/ui12-player.test.mjs`: host wins, seek unchanged, the web backend, time drives the highlight,
    the offline refusal, the availability table, and "bundled, not copied".
  - 1 Chromium test in `test/ui12-player-browser.test.mjs`, run on the built `dist/editor.html` served from
    127.0.0.1 with no host and with `CHROMIUM=/opt/pw-browsers/chromium`. It uses a 4 s tone generated by ffmpeg, held
    as a blob, with the context offline. A real click plays it and `currentTime` advances. Seek to 2.5 s works.
    `mediaSession.metadata.title` is "Test tone" and `playbackState` is playing, then paused. `setPositionState` gets
    duration 4 and position ≥ 2.4. Speed 1.5 works. A remote URL loaded offline gives the plain line, does not play,
    shows no spinner and raises no page errors.
- `library/` `npm test` (Chromium): 289 ok, 2 FAIL. Both fail on main too ("Home bar: Delete Cover…", "SPEC P3 12…").
  `webplayer.js` is not referenced by library code yet.

**Unverified**
- `gallery.js` has not adopted `webplayer.js` yet (I4). Until it does, the rules exist twice: the original in
  `gallery.js` and the lifted copy here. Lane lockscreen-everywhere edits those same lines (`gallery.js:1808-1887`, plus
  a third copy in `sharedview.js`), so I left Gallery alone to avoid a conflict. That lane also added
  `enterpictureinpicture` for video. `webplayer.js` is audio-only, so it does not need it.
- **Merge note:** lockscreen-everywhere rewrites the same FEAT-19 S-editor P4 line, to "closed: the editor plays no
  media". This branch sets it to `[~]` built. Keep this side: the owner's objective reopened it.
- Only Chromium was run. Safari/WebKit (Lock Screen scrubber, `audioSession`, background play) is **assumed**, as for
  Gallery.
- `.local` / loopback counting as "on this device" is a rule. It has not been checked against a real local hub, because
  the hub (UI-12 P1/P2) is not built yet. In the test, `setOffline` also blocks loopback.
- A picked file is a `blob:` URL. It plays offline for that page's life, but it is **not** stored, so it is gone after a
  reload.
- Hosts get new posts (`load`, `play`, `pause`, `toggle`, `rate`, `loop`, `close`). Today both hosts pass these to
  `onAudioAction` and act only on `speakSummary`, so nothing changes. That was read in code, not run.

**Device checks** (`dist/pwa/` or `editor.html` served from a local origin; play a short m4a picked with "Choose a recording…")
- iPhone 12 Pro Max, Safari:
  1. Open the transcript pane (`recenseEditor.showAudio()` for now) and pick a song. Press Play, then lock: does it
     play on?
  2. On the Lock Screen: title, a scrubber that seeks, ⏮ starting it over, Pause/Play.
  3. Speed 1.5×: is the pitch kept?
- iPad Air M2 13-inch, Safari: the same three steps, in portrait and landscape. Check the transport row wraps and does
  not cover the cues.
- Mac Safari and Chrome: play, then check Control Center's Now Playing for title and scrubber. Media keys should pause
  and play. Seek from Control Center.
- Offline, Wi-Fi off: open from cache and pick a local file. It should play, with no request made.
  Then load a Gallery URL. You should see "This recording isn't on this device. It needs a connection." at once, and no
  spinner.
- In the Recense app (host present): the editor must look and behave exactly as before, with no transport row in the
  pane.

**Owner questions**
1. Where should the player's way in live in the browser editor? Today the pane only opens from a host's transcript, or
   through `recenseEditor.showAudio()`. Options: a wing card, a page embed of an audio file, or the Draftpad menu.
2. Should a picked recording be kept on the device (IndexedDB, next to the text), so it still plays offline after a
   reload? That costs storage, and it would be a one-time copy.
3. The Wings "QuickTime" card (`editor/src/wings.js:698`) has its own `<video>` with speed and loop: a second player in
   the editor. Should it move onto this adapter? That belongs to lanes draftpad-*, so it is not touched here.

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
