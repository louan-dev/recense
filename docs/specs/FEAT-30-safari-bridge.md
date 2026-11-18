# FEAT-30 · Safari on iPhone and iPad tells Recense what plays, and when

From: owner 2026-11-14 ("fix the bug or do the plan for the safari extension or both"; T-0074 screenshots:
a lyric video in Safari) · Status: `[ ]` (plan; nothing built) · Depends on: FEAT-11 for P2

Today the phone can only listen to Safari (the broadcast). It hears words after they are sung, with a speech
engine that can be the weak one (T-0075). On the Mac, Firefox does better: the bridge tells Recense which file
plays and where, Recense transcribes the whole file ahead, and each word lights on time.
This feature gives Safari on iPhone and iPad the same bridge.

## Facts (checked, with evidence)
- **The Firefox bridge already does the job on the Mac.** `strip/bridge/` (v2.1.16) reports the playing
  `<audio>`/`<video>`: its address, position, paused, speed, and the active caption cue
  (`content.js:76-79`, T-0005). Recense lights words against those reports.
- **Its only tie to the Mac is one function.** `app(path, body)` (`content.js:20`) goes through the background
  script to `http://127.0.0.1:47123` (`background.js:2`). The controls come back on a held-open `/wait` request
  (`content.js:421-428`).
- **One Firefox-only call:** `wrappedJSObject` reads YouTube's video id (`content.js:30`). Safari has no such call.
- **The phone already lights a file on a player's clock.** The floating window shows the file's transcript,
  each word at its time (BUG-10, `Floating.swift`, own player).
- **The phone can fetch YouTube audio itself.** FEAT-11 spike PASS on the iPhone, 2026-11-14.
- **The broadcast route is weaker today.** iPhone float log 11-14 18:58:20: `engine=SFSpeechRecognizer`
  after a reinstall (T-0075). That engine gives no word times.

## Assumptions (unproven until S0 passes on the iPhone)
- A Safari Web Extension ships inside the iOS app as an app extension. The free team's profile allows it,
  as it allows the broadcast extension.
- The content script can read `currentTime`, `paused` and `playbackRate` of the page's video.
- The background script reaches a native handler in the extension (`browser.runtime.sendNativeMessage`).
  The handler can write to the keychain group that `Captions` already shares with the app.
- Safari wakes the background script for each message, although iOS suspends it between messages.
- m.youtube.com shows its captions as page text that the script can read.

## What the owner gets, by phase
- **S0:** nothing visible. The float log proves Safari's reports reach the app.
- **P1:** a video that already has a transcript lights word by word on Safari's clock.
  The transcript is one the Mac made, carried over by sync, or one this device made.
  A video with a caption track shows its captions on time.
  Lyrics drawn into the picture (the T-0074 video) still go through the broadcast.
- **P2:** any video. Recense fetches the audio once (FEAT-11), transcribes it on the device, and lights each
  word ahead of the voice. This covers the T-0074 lyric video.

## Planned `[ ]`
### S0 · Spike: one report reaches the app (iPhone, real device)
- Add an extension target to `mobile/ios/` (listed by hand in the pbxproj, like `Broadcast`).
- The content script sends one report a second while a video plays.
- The handler writes it to shared state, and the app writes `safari t=<s> rate=<r> playing` to `listen.floatLog`.
- Pass: the extension is turned on in Safari's settings. The log shows reports while YouTube plays in Safari,
  and the median delay from `sent` to the app is under 150 ms over 60 s.
- Fail: stop. The plan goes back to the owner with what blocked it.

### P1 · One bridge, two transports
- `content.js` gets its transport from the host, so the script never names its browser (law: structure §5):
  - Firefox: `fetch` to 127.0.0.1:47123, as today.
  - Safari: `sendNativeMessage`, plus a reply that carries the controls in place of `/wait`.
- YouTube's video id is read from the page address (`v=`), the same in both browsers. `wrappedJSObject` goes.
- Report rate: the bridge's own (on each change, plus ticks while playing).
- The app treats Safari as an outside player with a clock (FEAT-04 `ContentClock`), keyed by the media's
  address, the same key scheme as `keep/<key>/`.
- Which line the floating window shows (one at a time, never two):
  1. A transcript for that key, on Safari's clock.
  2. Else Safari's caption cue.
  3. Else the broadcast's live line (today's route).
- Strings (the extension's name and its one on/off entry) in English, French and Vietnamese.

### P2 · Words ahead for any video (after FEAT-11 merges)
- An address with no transcript: FEAT-11 fetches the audio only, SpeechAhead transcribes it on the device
  (BUG-11's file route), and the result is saved under the same key. From then on, rule 1 applies.

## Embodiments (PARITY)
- **iPhone, iPad:** this feature (one app, one extension).
- **Mac:** the Firefox bridge, which becomes the same script with the other transport.
  Safari on the Mac stays out: Recense.app is built by SwiftPM (`strip/build.sh`), with no app-extension
  packaging. Gap filed in PARITY.
- **Web:** none.

## Outside services (offline gate)
- **The site itself (YouTube and others):** the person is streaming it already. P1 adds no service.
- **P2's fetch (FEAT-11):** once per video, while online, which watching already needs. Kept on the device after.
- **Sync of the Mac's transcripts (`keep/<key>/`):** catch-up only. It never blocks.
- **No Cloudflare, no company service.** The extension and the app talk on the device.

## Risks (for the owner)
- iOS suspends the extension's background script. A report can arrive late, and S0 measures how late.
- YouTube changes its page. The Firefox bridge already lives with this, and one copy means one fix.
- The 7-day free profile expires the extension with the app. `sync/bin/resign-ios.zsh` already renews daily.
- Two routes at once (extension and broadcast). The order above decides, so the window never shows both.

## Done checks
- S0: the float log line and the delay median, from the iPhone (real device). Settings shown through iPhone Mirroring.
- P1: `node strip/bridge/test/ads.test.mjs` passes. On the Mac, Firefox still lights words in Recense's window.
  On the iPhone, a video the Mac transcribed lights in the floating window while Safari plays it.
- P2: the T-0074 lyric video lights each word before it is sung, on the iPhone. Screenshot through iPhone Mirroring.

## Open (owner or coordinator decides)
- Where the one bridge script lives. Either it stays in `strip/bridge/` and the iOS build copies it (as
  `library/src/client/` is copied into the Mac app), or it gets a new one-word folder. A new folder changes the
  structure law, so it is the owner's call.
