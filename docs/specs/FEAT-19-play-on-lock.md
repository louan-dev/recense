# FEAT-19 · Playback survives the Lock Screen and leaving the app, with a Lock Screen scrubber, everywhere

From: T-0132 (owner, 2026-11-16: "this applies everywhere: cloudflare, offline recenese and online recense, on mobile,
media should still play even outside the browser and locked screen and shuold have its own lockscreen scrubber")
Status: `[~]` · Builds on: SPEC 69 (Gallery Now Playing), BUG-09 (iOS Now Playing)

Labels: **proven** = a test or a device run in this repo shows it · **documented** = Apple/WebKit says so, not run
here · **assumed** = believed, not shown · **untested** = open.

## The rule
Wherever Recense plays a file, it:
1. keeps playing when the screen locks or the person leaves the browser or app;
2. shows its own title, cover and a scrubber on the Lock Screen and in Control Center;
3. obeys the Lock Screen: play, pause, drag the scrubber (seek), previous / next where there is a queue.

## Surface table (lane lockscreen-everywhere, 2026-11-16)
Every place Recense plays a file. "Locked" = goes on with the screen locked or the browser/app left.

| Surface | Locked / backgrounded | Now Playing info | Scrubber (seek) | Status | Where |
|---|---|---|---|---|---|
| Gallery web player (every browser; Cloudflare `/main`, offline hub) | audio: yes, `audioSession.type="playback"`, Web Audio kept alive (**assumed** iOS); video: Safari pauses it, PiP is the path; **new**: `enterpictureinpicture` action + `autopictureinpicture` so browsers with automatic PiP float it on | title, cover, loop line | `setPositionState` + `seekto`; ⏮/⏭; no ±10 s | **proven** Chromium (ui.test.mjs "item 11", "FEAT-19: the lock screen scrubber…", "FEAT-19: a playing video registers…") | `library/src/client/gallery.js:1808-1887`, `:1031-1059` |
| Shared links `/s/<id>` (visitors) | as Gallery: the same player (`public.js` serves Gallery) | as Gallery | as Gallery | **proven** via Gallery's tests | `library/src/client/gallery.js` |
| Shared section viewer `/main/shared` (owner; also Library › Shared in the iOS app) | audio: plain `<audio>`; video: Safari limit as above | **new**: title, cover (`f.thumb`) | **new**: `setPositionState` + `seekto`; ⏮/⏭ through the share's files (the next one plays); dropped on Done | **proven** Chromium (ui.test.mjs "FEAT-19: a file played in the Shared viewer…", red without the fix) | `library/src/client/sharedview.js:470-530` |
| Editor (Draftpad: Mac, iPhone, iPad, offline hub, `/main/editor/`) | **new (P4)**: a recording embedded in a note (`![caption](file.m4a)`) plays in the note; a playing one survives its line scrolling out of view (a hidden holder) | **new**: caption, else the file name | **new**: `setPositionState` + `seekto`; no ±10 s, no ⏮/⏭ (no queue yet) | **proven** Chromium (editor/test/feat19-embed-player.test.mjs, red without the holder); apps: coded, not compiled (Range serving, inline video) | `editor/src/embeds.js`, `library/src/client/nowplaying.js`, `shared/embedfiles.swift` (`ByteRange`), `mobile/HostApp/iOS/Draftpad.swift:165` |
| iPhone/iPad: our player (stored shows, Archive, music) | yes: `UIBackgroundModes audio`, `.playback` | title, album, duration, elapsed, rate | `changePlaybackPositionCommand`; ±15/30; play/pause/toggle | **proven** (Tests/nowplaying, swiftc on the Mac) · device check owed (BUG-09) | `mobile/HostApp/iOS/NativePlayer.swift:91-120`, `NowPlayingInfo.swift` |
| iPhone/iPad: our player's video | sound plays on (P2: the layer lets go in background) | as above | as above | **proven** rule (Tests/backgroundvideo) · device check owed | `mobile/HostApp/iOS/BackgroundVideo.swift`, `NativePlayer.swift` |
| iPhone/iPad: our player while Listen hears (Gap B) | yes | **new**: ours while it plays (session no longer mixes then) | as our player | coded, **not compiled here** (no Swift toolchain), rule in Tests/nowplaying · device check owed | `NowPlayingInfo.swift:23`, `NativePlayer.swift:70-86` |
| iPhone/iPad: Listen itself (broadcast of another app) | the other app plays; Listen keeps awake with a silent sound in the floating window | the heard app's own | the heard app's own (by design: Recense mixes, never takes it) | as built (BUG-10) | `mobile/HostApp/iOS/Listen.swift:938-1020` |
| iPhone/iPad: Gallery's page in the app (`PlayerView`, WKWebView) | `UIBackgroundModes audio`; WebKit sets the session while it plays (**assumed**) | Media Session as Gallery (**assumed**: WKWebView in an app) | as Gallery (**assumed**) | **untested** on device | `mobile/HostApp/iOS/Player.swift:90-104`, `Browser.swift:131-143` |
| Mac strip (Recense window) | n/a: plays nothing of its own. The sound is the browser page's (Gallery or any site); the window steers it through the extension; `VideoBackdrop` is muted | the browser's (Safari/Chrome take Gallery's Media Session into macOS Now Playing) | the browser's | by design | `strip/bridge/content.js`, `strip/recense.swift:912-922` |

## Surfaces

### S-web · Gallery's player (`library/src/client/gallery.js`, every browser, the apps' web views)
Already built (SPEC 69, notes 27). Kept as is:
- A real `<audio>`/`<video>` element plays (`playsinline`); Web Audio only reshapes it. **proven** (ui.test.mjs).
- `navigator.mediaSession`: metadata (title, artwork), `play`, `pause`, `seekto`, `previoustrack`, `nexttrack`;
  `setPositionState({duration, playbackRate, position})` on pause, ratechange, durationchange, seeked, timeupdate,
  so iOS draws a scrubber. **proven** in Chromium (ui.test.mjs:740-773); **assumed** on iOS Safari.
- `seekbackward` / `seekforward` stay unset: the web cannot add buttons, and with them iOS replaces ⏮/⏭ by ±10 s.
  The scrubber does that job (SPEC 69's choice, kept).
- `navigator.audioSession.type = "playback"`: sound with the ringer switch on silent and after leaving. **assumed** (Safari 17+).
- iOS interrupts Web Audio in the background: the context is asked back on statechange and visibility; if it stays
  down 3 s the element pauses so the Lock Screen tells the truth. **assumed** on device.
- iOS Safari limits:
  - `<video>` in a backgrounded or locked tab: Safari pauses it unless in Picture in Picture. **untested** here;
    PiP is the path (the player's PiP control).
  - Home Screen web app (standalone): background audio and Now Playing as in Safari since iOS 15.4. **assumed**.

### S-shared · the Shared section's viewer (`library/src/client/sharedview.js`, `/main/shared`, the app's Library › Shared)
- Before: plain `<audio controls>` / `<video controls>`, no Media Session: the Lock Screen showed the page's title and
  no ⏮/⏭. Now (2026-11-16) the same rules as S-web: metadata (name without extension, cover), play, pause, seekto,
  `setPositionState`, ⏮/⏭ through the share's files (only where there is one), `audioSession.type = "playback"`;
  cleared on Done. **proven** in Chromium (ui.test.mjs).

### S-editor · recordings in a note (P4, built 2026-11-16 on the owner's "yes it should")
- **Before:** the editor played no media. Its transcript pane sent seek and bookmark to the host, which hands them to
  `onAudioAction`, which nothing sets; only section summaries were spoken.
- **Now:** a line holding only `![caption](target)` whose target is a recording (m4a, mp3, wav, aac, aif, caf, flac,
  ogg, opus) or a video (mp4, m4v, mov, webm) shows a player under it, as PDFs and images already did. The text stays
  plain Markdown (Obsidian reads the same line). Dropping such a file inserts the line.
- **Lock Screen:** `library/src/client/nowplaying.js`, the Lock Screen half of the player, kept in the player's one
  home and bundled into the editor. It follows Gallery's rules (SPEC 69): a playback session, title, play, pause,
  seekto, `setPositionState`; one element at a time (starting one pauses the other).
- **Scrolling:** CodeMirror removes a widget scrolled far out of view, and a removed element stops. A playing
  recording moves to a hidden holder and comes back when its line is drawn again; a paused one stops and gives the
  Lock Screen back.
- **In the apps:** targets go through `recense-file:` (`shared/embedfiles.swift`). It now answers `Range` requests
  (206), which WebKit needs to play media. iPhone/iPad Draftpad plays video inline. Web files over 100 MB are not
  cached (the existing limit), so such a recording plays only from the vault.
- **Not yet:** ⏮/⏭ between a note's recordings; the transcript pane following and seeking the embedded recording;
  Gallery's EQ, Key and Speed (Gallery's player is one script tied to its page; the editor uses the browser's
  controls).

### S-ios · Recense on iPhone and iPad (`mobile/`)
Already built (BUG-09):
- `UIBackgroundModes` = `audio` (App-Info.plist, Guest-Info.plist). **proven** (file).
- `AVAudioSession` `.playback` while our player holds a file (`NativePlayer.session`). **proven** (code).
- `MPNowPlayingInfoCenter`: title, album, duration, elapsed, rate. **proven** (`Tests/nowplaying`).
- `MPRemoteCommandCenter`: play, pause, toggle, skip ±15/30, `changePlaybackPositionCommand` (the scrubber). **proven** (code).

New in this feature:
- **P2 · Video keeps its sound on lock.** iOS pauses an `AVPlayer` that is attached to an `AVPlayerLayer` when the
  app goes to the background (**documented**, Apple: "Playing audio from a video asset in the background").
  So the video view lets go of the player when the app leaves the foreground and takes it back when it returns.
  The picture resumes where the sound is. Rule (pure, tested): `BackgroundVideo.attached(active:)` = `active`.
- **Gap B (coded 2026-11-16, not compiled here):** while Listen heard a broadcast the session mixed with others, and a
  mixable session is not made the Now Playing app, so a file played then had no scrubber. Rule (pure, tested):
  `NowPlayingInfo.ownsSession(holdsFile:playing:hearing:)` = holds a file and (plays or nothing hears). The player
  takes the sound on Play even while Listen hears, and mixes again when paused while hearing (BUG-10 kept: the heard
  app is never stopped by a paused Recense).

## Checks
- `swiftc -O mobile/HostApp/iOS/BackgroundVideo.swift mobile/ios/Tests/backgroundvideo/main.swift -o "$TMPDIR/bgvideo" && "$TMPDIR/bgvideo"` → ALL OK.
- `swiftc` nowplaying test (BUG-09) still ALL OK.
- iOS compile (`CODE_SIGNING_ALLOWED=NO`).
- `npm test` in `library/` (Media Session tests). `ONLY=FEAT-19 node test/ui.test.mjs` runs the two scrubber guards.
- `swiftc` nowplaying test also covers Gap B's `ownsSession` (5 new checks).

## Device check (owner's iPhone and 13-inch iPad, screen locked)
1. Gallery in Safari: play an audio file, lock → it plays on; Lock Screen shows title, cover, scrubber; drag it → moves.
2. Same with a video file: note whether it pauses (S-web video limit); try PiP.
3. Recense app: play an audio file, lock → plays on, scrubber works. Then a video file: lock → its sound plays on (P2);
   unlock → picture resumes in step.
4. Recense app while Listen hears: lock → is our scrubber there? (Gap B)
5. Recense app › Library › Shared: open a share with a song, play, lock → title, cover, scrubber; ⏭ plays the next.

## Handoff (lane lockscreen-everywhere, 2026-11-16)
**Built, per surface**
- Gallery web player, shared links `/s/`: already complete (SPEC 69). Added for video: the Media Session
  `enterpictureinpicture` action (Chromium's automatic PiP on leaving the tab) and the `autopictureinpicture` attribute
  (an installed web app's video floats on when left); a song registers neither. `library/src/client/gallery.js`.
- Shared section viewer (`/main/shared`, also the app's Library › Shared): new Media Session: title, cover, play, pause,
  `seekto` with `setPositionState` (valid length/place, rate never 0), ⏮/⏭ through the share's files (the next one
  plays), no ±10 s, `audioSession.type = "playback"`, cleared on Done. `library/src/client/sharedview.js`.
- iPhone/iPad, our player while Listen hears (Gap B): the session rule now counts "playing", so Play takes a non-mixing
  session and Recense becomes the Now Playing app (scrubber shown); paused while hearing, it mixes again.
  `NowPlayingInfo.ownsSession`, `NativePlayer.session(hearing:playing:)`, re-applied on pause in `refresh()`.
  **Coded, not compiled** (no Swift toolchain in this session); device check owed.
- Editor (P4, after the owner's "yes it should"): embedded recordings and videos play in the note, with the Lock
  Screen's title and scrubber, and play on when scrolled away. Apps: `recense-file:` serves byte ranges; iPhone/iPad
  Draftpad plays video inline. Apps' part **coded, not compiled**.
- Mac strip: plays nothing of its own (the browser page does; the backdrop video is muted): nothing to build.

**Tests**
- `library/` `npm test`: 291 ok, 2 FAIL. Both FAILs also fail on main without this branch ("Home bar: Delete Cover…",
  "SPEC P3 12: Download bakes in EQ…" — a download-name assertion); not touched here. New: 2 tests
  ("FEAT-19: a file played in the Shared viewer…", "FEAT-19: a playing video registers…", the latter with the
  738-byte fixture `test/fixtures/tiny.webm`), each red on main's code, green with the fix.
  Run with `CHROMIUM=/opt/pw-browsers/chromium` in this container.
- `editor/` `npm test`: 259 tests, 258 pass, 0 fail, 1 skipped (the WebKit PWA test: no WebKit here). New:
  `test/feat19-embed-player.test.mjs` (2 tests; the browser one fails with a plain pause on scroll-away).
- `mobile/ios/Tests/byterange`: 10 checks for `ByteRange`, **not run here**; see the command in its header.
- `mobile/ios/Tests/nowplaying`: 5 new checks for `ownsSession`. **Not run here** (no swiftc); run on the Mac:
  `swiftc -O mobile/HostApp/iOS/NowPlayingInfo.swift mobile/ios/Tests/nowplaying/main.swift -o "$TMPDIR/nowplaying" && "$TMPDIR/nowplaying"` → ALL OK.
  Then the unsigned compile (`CODE_SIGNING_ALLOWED=NO`) for Recense and RecenseGuest.

**Unverified**
- iOS Safari: Media Session scrubber, `audioSession`, Web Audio surviving the lock (all **assumed**).
- Video in a locked Safari tab pauses (WebKit's rule); PiP is the only path. Not changed.
- Gallery's page inside the app (`PlayerView`, WKWebView): whether WebKit publishes Now Playing for an app's web view,
  and whether Listen's mixable session (when our native player holds no file) keeps it from being Now Playing.
- Gap B on device: whether taking the session on Play while the broadcast hears disturbs ReplayKit capture.

**Device checks** (screen locked each time)
- iPhone 12 Pro Max and iPad Air M2 13-inch:
  1. Safari › Gallery: play a song, lock → plays on; title, cover, scrubber; drag → moves; ⏭ → next song.
  2. Safari › Gallery: a video, lock → note pause; PiP then lock → sound and picture go on.
  3. Recense › Library › Shared › a share with two songs: play the first, lock → title, cover, scrubber; drag; ⏭ plays the second; Done clears the Lock Screen.
  4. Recense › Archive: a song, lock → BUG-09 scrubber; a video, lock → sound goes on (P2); unlock → picture in step.
  5. Recense with Listen on and hearing YouTube: pause YouTube, play a song in Recense, lock → Recense's title and scrubber (Gap B); pause from the Lock Screen, play YouTube → YouTube plays, Listen still hears.
  6. Recense › Library (Gallery's page in the app): play a song, lock → is there a scrubber? (WKWebView, untested)
  7. Draftpad: type `![Test](<a recording in the vault.m4a>)` on its own line → a player shows; play, lock → title
     "Test", scrubber, drag works; unlock, scroll far down while it plays → it plays on; a `.mov` plays inline.
- Mac: Recense › Draftpad, the same as check 7 (media keys and Control Center's Now Playing). Then `zsh strip/build.sh`
  and `recense selftest` (shared/embedfiles.swift changed).
- Mac: Safari and Chrome › Gallery and `/main/shared`: play, lock the Mac (⌃⌘Q), unlock → still playing; Control Center's Now Playing shows title and scrubber; media keys pause/play; the Recense window still lights words.

**Decisions** (owner, 2026-11-16: "do whatever you think is best"; taken by the lane, each reversible)
1. Gap B, paused while Listen hears: Recense mixes again. The heard app is never stopped by a paused Recense (BUG-10
   kept); Recense's paused controls may give way to the heard app's. Play in Recense takes them back.
2. Locked video in Safari: PiP stays the path (WebKit pauses a hidden video, no page can stop that). Browsers with
   automatic PiP now get it (enterpictureinpicture + autopictureinpicture). No sound-only fallback: a second element on
   the same file would be a second player and break the Web Audio graph (EQ, Key, Speed).
3. P4 reopened by the owner ("yes it should"): built as recordings embedded in a note (S-editor). The Lock Screen
   half is the shared module in `library/src/client/`, not a second copy of Gallery's player.
