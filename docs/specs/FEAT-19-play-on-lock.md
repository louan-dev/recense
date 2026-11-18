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
  - **P3 · built:** when the page is hidden and the system pauses a playing `<video>` (or pauses it up to 500 ms
    before the hide), the player plays it again, once per hide. A pause from the Lock Screen or headphones
    (`mediaSession` pause) or one while the page is seen holds. **proven** in Chromium with a faked hidden page
    (ui.test.mjs "FEAT-19: a video…"); **untested** on iOS Safari, which may refuse `play()` from the background
    (then the Lock Screen shows paused, truthfully, and PiP stays the path).
    Edge, accepted: the page's own Pause tapped less than half a second before locking is taken as the system's.
  - Home Screen web app (standalone): background audio and Now Playing as in Safari since iOS 15.4. **assumed**.

### S-editor · Recense in a browser (offline: the hub at https://recense.local; online: `/main/editor/`)
- **Fact:** the editor page plays no media in a browser. Seek and play go to the native host
  (`webkit.messageHandlers.audio`, `editor/src/audio.js:420, 926`); only pages are implemented in the library
  (`editor/src/library.js:19`). There is nothing for a Lock Screen to show.
- **P4 (built, branch `work/lockscreen`):** the Lock Screen wiring has one home, `library/src/client/mediasession.js`
  (`RecenseNowPlaying.bind(el, {title, artwork, onPrev, onNext})`, a classic script); the editor's esbuild bundles the
  same file. In a browser (no `webkit.messageHandlers.audio`) the editor menu has **Play a file…**: the system file
  picker, the file as an object URL (never leaves the device, works offline, no server), a real `<audio>`/`<video>`
  with the system's controls in one strip under the toolbar, closed by **Close player**. In the app the item hides:
  the native bridge owns the Lock Screen. **Later:** Gallery loads this module instead of its own copy (parity).

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
- **P2b · Who owns the sound (Gap B).** A mixable session is not made the Now Playing app (**documented**, Apple), so:
  while Recense plays its own file, the session is `.playback` without `.mixWithOthers` and owns Now Playing; it mixes
  only while Listen hears another app's sound (stopping that app would defeat Listen) or when nothing of ours is
  loaded. Rule (pure, tested): `NowPlayingInfo.ownsSession(holdsFile:hearingOutside:)` = `holdsFile && !hearingOutside`.
  The code already behaved so (BUG-10); the rule is now named, tested and the one place `NativePlayer.session` reads.
  Consequence, accepted: while Listen hears another app, that app's Lock Screen controls show, not ours.

## Checks
- `swiftc -O mobile/HostApp/iOS/BackgroundVideo.swift mobile/ios/Tests/backgroundvideo/main.swift -o "$TMPDIR/bgvideo" && "$TMPDIR/bgvideo"` → ALL OK.
- `swiftc` nowplaying test (BUG-09) still ALL OK.
- iOS compile (`CODE_SIGNING_ALLOWED=NO`).
- `npm test` in `library/` (Media Session tests).
- `node test/mediasession.test.mjs` in `library/` (the shared module, 7 checks).
- `npm test` in `editor/` (`feat19-fileplayer.test.mjs`); `npm run build`; then `library/test/editorpwa.test.mjs` (copies match).

## Device check (owner's iPhone and 13-inch iPad, screen locked)
1. Gallery in Safari: play an audio file, lock → it plays on; Lock Screen shows title, cover, scrubber; drag it → moves.
2. Same with a video file: note whether it pauses (S-web video limit); try PiP.
3. Recense app: play an audio file, lock → plays on, scrubber works. Then a video file: lock → its sound plays on (P2);
   unlock → picture resumes in step.
4. Recense app while Listen hears: lock → is our scrubber there? (Gap B)
5. Editor in Safari (`/main/editor/` or https://recense.local): menu → Play a file… → pick a sound file, lock →
   plays on; Lock Screen shows the file's name and a scrubber; Lock Screen pause holds.
