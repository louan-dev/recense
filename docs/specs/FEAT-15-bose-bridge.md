# FEAT-15 · Bose Bridge: one pair of QC SC, many sources

From: T-0059 (owner, 2026-11-14) · Status: `[~]` (P1–P5 built 2026-11-15; P6 and P7 are spikes, not built)

The owner's words, short: make the QuietComfort SC do what a 2nd-gen QC Ultra does, drop the Bose app,
hold three or more devices, take wired audio while charging or dead, play two symphonies at once,
and resume a passage from any device. Then tell the owner how to listen to two symphonies at once.

## The rule this spec applies
A pair of headphones is firmware plus two transducers. Recense cannot write that firmware.
So every goal splits in two:
- what the **headphones** must do → fixed, unless Bose ships it;
- what the **host** (Mac, iPhone, iPad) must do → ours, and where the gain is.

The QC SC's one Bluetooth link and its analog pair are the only two doors. The bridge's job is to put
everything the owner wants *behind* those doors, on the host side, where we own the code.

## What the hardware allows · evidence, 2026-11-15

**checked** (a named source says it)
- QC SC multipoint holds **two** source devices at once — Bose product page.
- QC Ultra Headphones (2nd Gen) multipoint also holds **two** — Bose press release, Bluetooth 5.4.
  → three simultaneous links is not a feature the QC SC is missing. No Bose model has it.
- QC SC ships with a **3.5 mm → 2.5 mm analog cable**; the 2.5 mm jack is on the headphones — Bose product page.
- The same analog path on the QC45 generation works **powered on or off**; passive means no ANC and no
  volume buttons — Bose QC45 owner's guide and support article.
- **Bluetooth is disabled while charging** on that generation — Bose QC45 support.
- QC SC support says plainly: *"The headphones don't play and aren't available in the Bose app while charging."*
- QC Ultra 2nd Gen adds **USB-C audio, 16-bit 44.1/48 kHz lossless**, which the QC SC has no hardware for — Bose press release.
- Headphone-side ANC modes, headphone EQ and button mapping travel over Bose's own **BMAP** protocol on a
  Bluetooth RFCOMM channel. Open-source implementations exist (`bosectl`, `bose-re`, `based-connect`).

**assumption** (nothing authoritative found; each one has a test below)
- Analog audio **while the USB-C cable charges** works, because the passive path is a wire to the drivers and
  charging only needs power into the cell. Bose documents the powered case only. → Owner's test A.
- The QC SC's USB-C port is **charge-only** (no USB audio class). No Bose document claims audio on it.
- Plugging the cable while powered on **drops the Bluetooth link** (user reports, not Bose).
- The BMAP libraries above are written against QC Ultra 2 and QC35. Untested on a QC SC.

## The five goals, sorted

**1 · No Bose app** — reachable for everything the owner uses it for.
- Reachable now, offline, no Bose app: which device plays, battery percent, route changes, low-battery
  warning, what to plug in when the link drops, and sound shaping (Recense's own three-band EQ, Key and
  Space in `strip/soundengine.swift`, which the Bose app cannot do at all).
- Not reachable without BMAP: ANC mode, headphone-side EQ, button mapping, firmware.
- Host-side EQ is the better place anyway: it also shapes the **wired** signal, which headphone EQ does not,
  and it survives a firmware update. P7 keeps the BMAP route open as a spike, not a dependency.

**2 · Three or more devices at once** — not on the headphones; reachable as a bridge.
- The 2-link cap is firmware, and the flagship has the same cap (evidence above). Nothing we write changes it.
- Drop the presumption that each device must own a link. One link belongs to the host; the host holds the sources.
  - Many sources on one device, mixed into that one link → **P4, built**.
  - Any device's *place in a piece* reaching any other device → **P3, built** (seats, offline).
  - Another device's *live audio* over the air into this host's mixer → **P6, spike** (needs streamed audio over
    `shared/p2ptransport.swift`; not built, and said so).
- So today: unlimited devices take turns in one second, two or more sources play together on the device in
  your hand, and the headphones never know the difference.

**3 · Wired audio while charging or dead** — reachable, and here the QC SC already beats the flagship.
- Passive wired works with the headphones **off or empty**: QC45-generation, checked. A QC Ultra 1st Gen must
  be powered on for its cable. So the cheaper pair is the resilient one.
- Charging at the same time: assumption, with the owner's 60-second test A below.
- The software's share: see the cable, choose it, keep the Mac's speakers quiet, and say in plain words what
  to plug in for this exact model. That is P1 + P2, built.

**4 · Two symphonies at once** — not on the headphones; reachable in the host, and built.
- One A2DP stream, one analog pair: the headphones receive one signal. Two signals therefore have to become
  one before they leave the host. That is a mixer, not a headphone feature — and no QC Ultra has it either.
- Built as P4: N voices, each its own file and its own clock, per-voice gain and left/right placement,
  one engine, one output. Directions for the owner are at the end of this spec.

**5 · Resume a passage from another device** — reachable now, built as P3.
- Stands on FEAT-04's content clock and FEAT-09's carry. No new transport, no network, no Keep/R2
  (`strip/handoff.swift` is the R2 path and stays what it is; seats are the offline one).

## Where the QC SC is the better pair (the owner asked)
- **Dead-battery listening:** passive wired works at 0 % (checked). Ultra 1 needs power; Ultra 2's lossless
  USB-C path needs power too.
- **Fewer moving parts to lose:** physical buttons, no touch surface, no spatial-audio processing running
  down the cell. Labelled opinion, not a measurement.
- **Cheaper to replace** — which, for a pair that travels, is a reliability property.

## Built `[x]` (what this stands on)
- `strip/soundengine.swift` — the process tap, the three-band EQ/Key/Space chain, the peak limiter.
- `shared/fingerprint.swift` — the key a seat is filed under.
- `shared/ShowsKit/.../ContentClock.swift` — FEAT-04's clock, the unit a seat's position is in.
- `shared/carrysync.swift`, `shared/carrymanager.swift`, `shared/homes.swift` — FEAT-09 carry, the homes.
- The owner's own `Bose Bridge.app` (BoseBridgeApp.swift 63 lines, Engine.swift 488, build.sh 57), restored
  2026-11-15 to `~/.claude/context/recense/research/bose-bridge/`. Its route logic is the prior art for P1;
  it does not survive as a second app (see P2).

## Planned

### P1 `[x]` · The capability table and the route decision (shared)
`shared/bosebridge.swift`, platform-neutral, compiled by the Mac app and by the iOS project.
- `Phones` — `qcsc`, `qc45`, `ultra1`, `ultra2`, `other` — each with `Traits`:
  `wiredWhileOff`, `wiredWhileCharging`, `btWhileCharging`, `usbAudio`, `maxLinks`, and the sentence to show
  when the link drops. Every trait's source is in the table's comment, marked checked or assumption.
- `BridgeDecision.decide(ports:arrived:current:was:settings:)` — pure, no CoreAudio, no AVFoundation:
  ports in, chosen output + what to mute + where to pin the mic + the sentence out.
- Priority, strongest first: `phonesUSB > phonesBluetooth > jack > earbuds`.
- Rules it must obey:
  - A port that **just arrived** wins over everything (the owner plugged it in for a reason).
  - Nothing arrived and the current output is already a headphone port → **leave it alone** (a choice made in
    Sound settings sticks until the next plug).
  - Otherwise the strongest port left wins.
  - No headphone port at all → mute the built-in speakers when asked, and say what to plug in for this model.
  - On Bluetooth, the default input stays the built-in mic, so the link keeps stereo instead of dropping to
    call quality (`pinMic`).

### P2 `[x]` · The Mac glue, inside Recense — not a second app
`strip/bosebridge.swift`: CoreAudio HAL only (list devices, set default output/system output, mute, read the
battery through `system_profiler SPBluetoothDataType`), plus the menu.
- One app, one process (`.claude/CLAUDE.md`, "One app"). The owner's standalone menu-bar app is folded in:
  its headphones icon becomes a submenu under Recense's app menu, its toggles become Recense settings
  (`UserDefaults`, suite `local.recense`).
- Idle cost near zero (SL1): one HAL property listener, no polling; the battery is read every 5 minutes and
  only while the Bose is actually on Bluetooth.
- Reacts only when the device list changes, debounced 0.8 s, because a Bluetooth device appears in stages.

### P3 `[x]` · Seats: the same passage on the next device
`shared/bosebridge.swift`, `Seats`.
- One append-only file, `library/Listen/seats.jsonl`, inside a Home, so FEAT-09's carry already moves it
  between devices with no new transport and no network.
- One line per save: `{key, title, at (unix ms), position (s), rate, device, source}`.
  `key` = `Fingerprint`-style sha256 prefix of the title, lower-cased and space-collapsed — the same shape
  `Handoff.key` uses, so the two can be reconciled later without a migration.
- Reading a seat = the **newest line for that key wins**. Append-only plus newest-wins is why a merge can
  never lose a position: two devices writing at once produce two lines, not a conflict.
- `"jsonl"` joins `CarrySync.textExtensions` so carry line-merges this file instead of choosing a winner.
- Nothing is ever rewritten in place; compaction (keep the newest line per key) runs only when the file
  passes 2000 lines.

### P4 `[x]` · Two symphonies at once (shared, Mac + iPhone + iPad)
`shared/bosebridge.swift`, `Symphonies` — one `AVAudioEngine`, one `AVAudioPlayerNode` per voice, straight
into the main mixer, one output.
- Per voice: `gain` 0–1, `place` −1 (left) … +1 (right), its own position, its own rate of travel through
  its own file. Seek one voice and the other does not move.
- `place = ±1` is the two-ear split the owner asked for: symphony A in the left cup, B in the right.
- A voice that reaches its end stops itself; the others keep playing.
- Every voice writes a seat on pause and on stop (P3), so two symphonies resume as two symphonies.
- Headroom: the sum of voice gains is clamped to 1.0 before the mixer, so adding a second voice can never clip.
  $g'_i = g_i / \max(1, \sum_j g_j)$

### P5 `[x]` · The iPhone and iPad glue
`mobile/HostApp/iOS/Headphones.swift` + one row in `Places.swift`:
- the live route, read from `AVAudioSession.currentRoute` (no CoreAudio HAL on iOS);
- the model picker and the same sentence when the route drops;
- the seats list: every passage any device left behind, newest first, one tap to resume it here;
- the two-at-once mixer: pick from the Music and Listen homes, two sliders and a left/right placement each.
- iOS cannot read the Bose battery (no public API) — the screen says so instead of guessing.

### P6 `[ ]` · Spike: another device's live audio into this mixer
Streamed PCM over `shared/p2ptransport.swift` (MultipeerConnectivity) into a `Symphonies` voice.
Open questions a spike must answer: latency against the content clock, packet loss policy, battery.
Not built. Until it is, "three devices at once" means P3 + P4, and this spec says so out loud.

### P7 `[ ]` · Spike: BMAP over RFCOMM, so the Bose app is never needed again
`IOBluetooth` RFCOMM channel to the headphones, BMAP frames for ANC mode and headphone EQ.
Clean-room: from protocol notes only, never another project's code. Read-only first (battery, firmware
version), and no firmware write, ever, from Recense.

## Invariants (a test can check each one)
1. `decide` with one arrived Bluetooth Bose port and a current output of built-in speakers → chooses the Bose.
2. `decide` with nothing arrived and the current output already the jack → returns the jack unchanged.
3. `decide` with no headphone port and `muteSpeakers` on → returns the built-in speakers in `mute`.
4. `decide` on a `qcsc` with no headphone port → the sentence names the **2.5 mm cable** and says it works
   with the headphones off; on `ultra1` it says the headphones must stay powered on.
5. `Traits(.qcsc).maxLinks == 2` and `Traits(.ultra2).maxLinks == 2` — the flagship is no better.
6. `Traits(.qcsc).usbAudio == false`, `Traits(.ultra2).usbAudio == true`.
7. Two seats for one key, written a second apart, read back as the newer one.
8. A seats file with 2001 lines compacts to one line per key, newest kept, nothing lost.
9. `Symphonies` with two voices at gain 1.0 each renders with effective gain 0.5 each (no clipping).
10. A title's seat key ignores case and extra spaces, so the same piece is one seat on every device.
11. A launch with no headphone port and nothing lost **does not** mute the speakers (found on the owner's Mac,
    2026-11-15: the first build silenced the Mac at launch; only a route that was *lost* may mute).

## Code layout and tests
- `shared/bosebridge.swift` — P1, P3, P4 and `boseBridgeSelftest()` (the invariants above). It reaches the Mac
  build as `strip/Sources/recense/sharedbosebridge.swift`, a symlink (the glue file already owns the name).
  Seeking one voice while another plays is a device check, not a selftest: it needs real audio.
- `strip/bosebridge.swift` — P2, CoreAudio + the menu. 4 call sites in `strip/app.swift`.
- `mobile/HostApp/iOS/Headphones.swift` — P5. 1 row in `mobile/HostApp/iOS/Places.swift`.
- `shared/carrysync.swift` — one line: `jsonl` in `textExtensions`.
- Checks: `zsh strip/build.sh`, `strip/recense selftest`, the iOS compile, then both devices.

## Offline-first gate
Outside services this feature touches: **none**, at any moment.
- CoreAudio, AVFoundation, AVAudioSession, `system_profiler`, MultipeerConnectivity — all on the device.
- No Bose app, no Bose account, no Cloudflare, no R2, no Worker, no Groq.
- One-time downloads: none.
- The web was used today to write this spec's evidence section, never at run time.

## Done checks
1. `zsh strip/build.sh` builds and installs Recense.app. — **Mac**
2. `strip/recense selftest` passes, including the ten invariants above. — **Mac**
3. `xcodebuild … -destination 'generic/platform=iOS'` compiles the shared logic for iOS. — **iPhone + iPad**
4. `zsh mobile/ios/build.sh` installs on the iPhone, then on the iPad; the Headphones place opens, shows the
   real route, and plays two files at once with the left/right split audible. — **owner's devices**
5. The Mac's Bose Bridge submenu shows the real route and the real battery percent with the QC SC connected.
6. Carry a seat: pause a piece on the iPhone, Carry Now, and the Mac's seats list offers that exact second.

## Directions for the owner · two symphonies at once

### A · The 60-second test that settles the charging question
Plug the USB-C charger into the headphones **and** the audio cable into the Mac, then play something.
```zsh
afplay /System/Library/Sounds/Glass.aiff
```
One line on what it does: plays a short sound through whatever the Mac's output is right now.
If you hear it with the charger in, wired-while-charging is confirmed; tell me and I will mark the spec
`checked`. If you hear nothing, try it again with the headphones switched **off** — that is the passive path.

### B · Two symphonies, inside Recense (the built path)
1. Open the Recense menu (the app menu at the top of the strip) → **Bose Bridge** → **Two At Once…**
2. Pick the first piece. It starts.
3. Open the same menu again → **Two At Once…** → pick the second. Both now play.
4. Under each piece: **Left / Centre / Right** places it in that ear, and **Louder / Quieter** sets its share.
5. On the iPhone or iPad: **Places → Headphones → Two at once**, same two controls under each row.
6. Pause either one and its place is kept; the other keeps playing.

On the Mac, the exact command for step 1 without the menu:
```zsh
~/Applications/Recense.app/Contents/MacOS/recense symphonies ~/Recense/library/Music/a.m4a ~/Recense/library/Music/b.m4a
```
One line: plays both files at once through the current output, A in the left ear, B in the right.

### C · Two symphonies without Recense, on the Mac
1. Open Audio MIDI Setup: **Finder → Applications → Utilities → Audio MIDI Setup**.
2. Bottom-left **+** → **Create Multi-Output Device**.
3. Tick the Bose (or **External Headphones** when you are on the cable).
4. Play piece one in Music, piece two in QuickTime Player, and set each app's own volume.
   macOS mixes every app into one output by itself — two players are already two symphonies.
5. Per-app volume lives in **System Settings → Sound → Output**, or in each app.

Or in one line, two players at once, no settings at all:
```zsh
afplay ~/Music/a.m4a & afplay ~/Music/b.m4a & wait
```
One line: starts both files at the same moment and waits for both to finish.

### D · Two symphonies by wire, no computer
A passive 3.5 mm Y-cable (two sources into one pair of headphones) does work, but the two sources fight each
other's output stage: the volume sags and one source can bleed into the other.
- Better: a **passive 2-into-1 mini mixer** with a volume knob per input (≈ €15, no battery, nothing to charge).
- Then: phone → input 1, iPad → input 2, the 3.5 mm → 2.5 mm cable → the QC SC, headphones off. Fully passive,
  works at 0 % battery, no app, no pairing.
- What will **not** work on a QC SC: the cable and Bluetooth at the same time (assumption, user reports).
  If you want one wired source and one wireless source, the mixer belongs on the host, which is path B.

## Amendments
- 2026-11-15 · written from T-0059; P1–P5 built the same day, P6 and P7 left as spikes.
- 2026-11-15 · invariant 11 added after the live Mac check: the first build muted the built-in speakers at launch
  because no headphone port was present. Muting now needs a route that was actually lost.
