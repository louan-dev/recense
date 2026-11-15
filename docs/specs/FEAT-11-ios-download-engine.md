# FEAT-11 · Downloads on iPhone and iPad, no Mac in the loop

From: T-0049 · Status: `[ ]` · owner 2026-11-14 ("build a PullTube iOS engine")

Paste a link on the iPhone or iPad; the file lands in `Recense/downloads/`
with its manifest entry. The Mac is never asked. Today iOS can only queue
a request for the Mac (`downloads/.queue/`, `shared/mediadownload.swift`).

## Facts (proven, with evidence)
- **yt-dlp needs neither ffmpeg nor a JS runtime to fetch** YouTube's
  separate streams (Mac, 2026-11-14, yt-dlp 2026.10.26, PATH without
  ffmpeg/deno/node): audio `140` m4a 9.8 MB and video `160` h264 4.1 MB,
  about 2 s each. Test video: Big Buck Bunny `aqz-KE-bpKQ` (Blender, CC BY).
- **AVFoundation joins them by passthrough** (no re-encode): composition
  with both tracks → `AVAssetExportSession` Passthrough → `.mp4`,
  0.46 s on the Mac; playable, `vide` + `soun`; frame times identical to
  the source (frame 301 at 9.966667 s in both).
- **AVFoundation reads YouTube's DASH files at twice their length**
  (1269.13 s for a 634.57 s film; both audio and video). The file's own
  `moov/mvhd` holds the true length (9746944 / 15360 = 634.57 s).
  Rule: every time range is clamped to the `mvhd` duration.
- **iOS forbids subprocesses** (PEP 730), so yt-dlp can never call
  ffmpeg there. Everything ffmpeg did moves to AVFoundation (table below).

## Assumptions (unproven until the device run passes)
- Embedded CPython 3.14 (BeeWare Python-Apple-support `3.14-b14`) imports
  yt-dlp and reaches YouTube over HTTPS on the iPhone (certifi bundled).
- AVFoundation on iOS behaves as on the Mac (same DASH doubling, same fix).
- yt-dlp's no-JS YouTube path keeps working. yt-dlp calls it deprecated
  ("some formats may be missing"); see P4.

## Embodiments (PARITY)
- Mac: unchanged (yt-dlp + ffmpeg, `shared/mediadownload.swift`).
- iPhone + iPad: this spec. Web: none (a browser cannot run yt-dlp).
- Shared logic goes in `shared/` so the Mac can later use the same
  format choice and join plan.

## Outside services (offline gate)
- **The media site itself** (YouTube etc.), at the moment of download.
  Unavoidable for a download; offline the request is kept in
  `downloads/.queue/` and runs on reconnect (`NWPathMonitor`, as on the
  Mac). Nothing blocks.
- **One-time, at build time, bundled in the app:**
  - BeeWare Python-Apple-support 3.14-b14, 37,299,470 bytes,
    sha256 `703ff822529f46edcbcd8b88096b2544f6990f3109ad38b4b4b61bb489a7c1ee`,
    github.com/beeware/Python-Apple-support (BSD-style; CPython PSF licence).
  - yt-dlp 2026.10.26 + certifi 2026.10.23 from PyPI (Unlicense; MPL 2.0).
- No Cloudflare, no Groq, no company of ours in the path.

## What replaced ffmpeg
| yt-dlp + ffmpeg (Mac) | iOS replacement |
|---|---|
| merge `bv+ba` | P1 join: composition + passthrough |
| `-x --audio-format m4a` | pick an m4a format, remux by passthrough (DASH → plain m4a) |
| `--remux-video mp4` | passthrough export |
| subtitles | yt-dlp writes `.vtt` itself (no ffmpeg); untested |
| `--download-sections` | trim the composition's time range (P3) |
| ffprobe codecs | `AVAssetTrack.formatDescriptions` |
| embed thumbnail | `AVMetadataItem` artwork on export (P3) |
Codecs: H.264 + AAC only, the ones every iPhone and iPad decodes; VP9
and AV1 are not chosen (AV1 decode needs A17 Pro / M3 or later).

## Planned `[ ]`

### P1 · Engine (pure logic first, tests before code)
- `shared/downloadplan.swift`, no AVFoundation, no Python, testable with
  `swiftc` on the Mac:
  - `pickFormats(info:mode:maxHeight:)` → format ids from yt-dlp's
    info JSON (`formats[]`: `format_id`, `vcodec`, `acodec`, `ext`,
    `height`, `tbr`). Audio: best `ext == m4a` audio-only. Video: best
    `vcodec ^= avc1`, `height <= maxHeight`. A single muxed mp4 wins when
    it is as good (no join needed).
  - `mvhdDuration(_ data:)` → true length from the file head (v0 and v1 boxes).
  - `joinPlan(video:audio:)` → range = min of both `mvhd` durations.
- `mobile/HostApp/iOS/PyEngine.swift` (glue): starts CPython once on a
  background thread, runs `downloader.py` (resolve → JSON; download one
  format id to a path). One download at a time.
- `mobile/HostApp/iOS/Join.swift` (glue): composition + passthrough
  export, clamped by `joinPlan`. Writes into `Recense/downloads/`, then
  `Downloads.record()` (sha256, `via: "yt-dlp-ios"`).

### P2 · The flow
- Library › Downloads › Paste link (button, menu and voice; no
  gesture-only path). Choose Audio / Audio + Video / Video (`DownloadMode`).
- Progress row; Cancel. Offline → queued, says so in one line.
- The existing "Ask the Mac" path stays as a fallback when the engine fails.
- Share Extension entry ("Download with Recense") comes from FEAT-03 P1;
  not required for P2.

### P3 · PullTube features
Quality cap (360–2160), trim by timecodes, subtitles, cover art + title.

### P4 · Keep it working for years
- yt-dlp breaks when YouTube changes, every few weeks. A bundled copy
  ages. Update path: the app fetches a newer yt-dlp wheel (pure Python)
  from PyPI, checks PyPI's published sha256, unpacks it into
  Application Support ahead of the bundled copy; bundled copy stays as
  the fallback. **Owner decision:** downloading code is refused by App
  Store review; fine for our own signed builds.
- JS challenges: if YouTube stops serving formats to the no-JS path,
  run yt-dlp's challenge solver (yt-dlp-ejs) in JavaScriptCore, which
  iOS ships, through a yt-dlp JS-runtime plugin. Untested; spike first.

## Risks (for the owner)
- **YouTube's Terms of Service forbid downloading** except where YouTube
  offers it. App Store review refuses apps that do it. This engine
  stays in our own dev-signed builds; never TestFlight or the App Store.
- App size: +19.8 MB download, +58.8 MB installed (Python stdlib minus
  its test suite, idlelib, tkinter, ensurepip, turtledemo; yt-dlp 24 MB).
- Free Personal Team signing still expires every 7 days (unchanged).

## Done checks
1. `swiftc` test of `downloadplan.swift`: format pick on a recorded
   info JSON (audio 140, video ≤1080 avc1), mvhd on the real DASH head
   (634.57 s, not 1269.13), join range = min of both.
2. iPhone and iPad: paste the CC BY test link, Audio → `.m4a` in
   `Recense/downloads/`, manifest sha256 matches `shasum -a 256`; plays
   in Recense's player for its true length.
3. Audio + Video → one `.mp4`, `vide` + `soun`, length within 0.1 s of
   `mvhd`; the picture and the sound in step (watch 10 s at 5:00).
4. Airplane mode → queued; reconnect → done, no tap needed.
5. iPhone Mirroring screenshot of the Downloads screen, UI audit.

## Spike result · 2026-11-14 · iPhone 12 Pro Max, real device · PASS
- Rebuild: `zsh spike/ios-ytdlp/setup.zsh <scratch dir> <device UDID>`.
- CPython 3.14.10 (BeeWare) + yt-dlp 2026.10.26, embedded, run in the app process.
  subprocess is refused, as expected; ffmpeg is absent.
- Downloads without a JS runtime: format 140 (AAC m4a, 10.3 MB) in 2.39 s,
  format 134 (360p H.264, 18.3 MB) in 2.10 s.
- DASH duration trap: AVFoundation reports 1269 s, about twice the true 634.6 s
  in each file's own mvhd header. Fix proven: remux the audio to M4A by passthrough (0.13 s),
  then insert both tracks clamped to the mvhd duration.
- Join: passthrough export to MP4 in 2.80 s, 28.5 MB, tracks avc1 + aac,
  634.57 s. AVPlayer reached ready + playing (seeked to 60 s, at 64.66 s after 6 s).
- Not covered: the ffmpeg-only paths (merge `160+140`, mp3 extraction). The merge run
  stalled at "Downloading webpage" once. They are now behind `SPIKE_FFMPEG=1` with
  socket_timeout 20 s. Higher formats (VP9/AV1, above 1080p) were not tried.
