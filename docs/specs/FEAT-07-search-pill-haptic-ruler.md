# FEAT-07 · Transcript search pill + the sound curve (haptic zoning of the time ruler and the sound controls)

From: T-0045 (owner 2026-11-14, rated ******, wishrank #1 of the rated wishes) · Status: `[~]` P0–P2 built; P3 and the sound curve (P4–P8) written, not built
Revised 2026-11-16 (lane notes-search-curve) after the owner's design review: **read § "Revision 2026-11-16" at the end first.**
It replaces rule 3, phase P4 and the first Open item, and it settles what the pill holds.
Builds on: the player pill design (owner + coordinator 2026-11-08, `.handoff/player/INBOX.md` P2).
Lane: player (`.claude/worktrees/player`, `work/player`).

## The owner's words (2026-11-14, verbatim)
> ****** plan a transcript wide recense search pill scrubber on transcript player and a zero ui vibration haptic zoning redesign of the media player timeruler and eq controls and media-player wide implementation of the redesign

## What it is
- **One pill** at the bottom of the transcript player. It replaces the mini player and the classic scrubber.
  - Tap → it becomes the transcript search bar (whole transcript, every language it holds).
  - Long press 0.35 s (haptic) → it becomes the scrubber; the same touch slides it.
  - Swipe left → right: A/B loop menu. Right → left: speed slider. (P2 rules, unchanged.)
- **Haptic zoning:** while the finger is on the ruler or an EQ control, the phone tells you where you are by touch,
  so your eyes can stay on the text.
- **Media-player wide:** the same pill and zoning on every player surface (Mac, iPhone, iPad, web).

## Rules
1. **Search hits are places on the ruler.** Results show as marks on the scrubber track; sliding across a hit
   gives the strongest detent. Tapping a result plays from its first word (word times: FEAT-04 `Word`).
2. **Three haptic levels, never more** (`docs/law/interaction.md` § Haptics; research: 3–4 levels per dimension):
   - light: every sentence boundary (from the transcript's line times);
   - medium: chapter or section start, and A/B points;
   - strong: a search hit, and the start/end of the media.
3. **EQ zoning:** each band slider gives a medium detent at 0 dB and a light detent every 3 dB; the end stops are strong.
4. **"Zero UI" means no extra chrome, not no visible path** (owner rules: every action has a visible control;
   law: a haptic never carries meaning alone). While held, the pill shows the time (start · current · −remaining),
   the band's dB value, and the hit count. "Go to time…" and "Find in transcript…" stay in the ··· menu.
   VoiceOver: adjustable action on the pill (±15 s) and on each band (±1 dB).
5. **Rate limit:** at most one detent per 40 ms; a fast slide plays only the strongest detent crossed.
6. **Reduce Motion:** morphs become swaps. Haptics follow the system "System Haptics" switch.
7. **Seek rules from `Views/Scrubber.swift` stay:** seek at most every 90 ms, land on the last value, show the landed time 1.7 s.
8. **One source:** zoning logic (where the detents are) lives in `shared/ShowsKit` (Swift) and the player's JS in
   `library/src/client/`; hosts only play the haptic. The Mac uses the trackpad's haptic (`NSHapticFeedbackManager`)
   where present; web has no haptic and shows the marks only.

## Offline gate
- No outside service. Search runs over the local transcript; haptics are on-device.

## Done checks
1. Unit tests (ShowsKit): detent positions for a fixture transcript (sentence, chapter, hit, ends) and for EQ ±12 dB;
   the 40 ms limit drops weaker detents in a fast slide.
2. UI tests: tap → search; hold 0.35 s → scrub from the playhead; a scrub never changes typed search text;
   a tap never seeks; each swipe opens the right control; A/B menu stays open through A, B, Clear.
3. Device (iPhone + iPad via iPhone Mirroring, Mac trackpad): eyes closed, find the third search hit and
   0 dB on a band by touch alone; screenshot the held state on each surface (UI audit in `~/.claude/CLAUDE.md`).
4. **Baseline to beat:** Apple Podcasts on iOS (scrubber: no transcript search on the track, no detents)
   and Voice Memos (no search). Measure: time to reach the 3rd mention of a word in a 30-minute episode.
   Done = faster than Podcasts' transcript view on the same episode, 3 tries each, numbers recorded here.

## Phases
- P1 zoning model + tests (ShowsKit), no UI.
- P2 pill: search mode + hit marks (iOS/iPadOS), then the Mac and web.
- P3 haptic ruler (iOS), trackpad (Mac).
- P4 EQ zoning (Mac strip EQ in `strip/soundengine.swift` first: it is the only EQ today).

## Open
- Open: does the iPhone's EQ exist yet? Today only the Mac has EQ (`strip/soundengine.swift`). P4 on mobile waits on it.
- Open: haptic for comprehension is a hypothesis (`docs/research/haptics.md`); this spec claims navigation speed only.

## P0 · The Music list (owner 2026-11-15, folded into FEAT-07)
> play , pause, rename, loop can be folded into the feat-07 task … tap on the music tile and it lists music you can
> slide to delete, you can rename the track and have that track update the name across all devices

From: owner 2026-11-15 (screenshot: Library › Recently Updated › **Music**, iPhone).
- **Where:** the Music show (`library/Music`, `Home.music`) opens ShowsKit's `ShowPage`. The same page on iPhone, iPad
  and the Mac's Recense window (the Mac hosts ShowsKit's views in an `NSHostingView`).
- **Each track row:**
  - Play / Pause: the row's capsule shows pause while that track plays, and a tap pauses it.
  - Rename…: an alert with the name, its extension kept. The file is renamed in place, so Carry sees a `move`
    (same SHA-256, new path) and every paired device replays it.
  - Loop: repeats the playing track at its end, never more than one track. Its state shows on the capsule (repeat.1).
  - Delete: **slide left → right** (the leading edge; a full swipe deletes). The file goes to `trash/` with its origin
    (`Homes.remove`), so Restore works, and Carry replays the `trash`. Played and Save move to the trailing edge.
- **Every action is also in the row's ··· menu and its context menu** (never a gesture alone).
- **One source:** the views and the rules live in ShowsKit. The file work goes through `ShowsModel.files` (a host protocol),
  which both apps implement over `shared/homes.swift` (`Homes.rename`, `Homes.remove`).
- **Name rules:** trimmed; empty, `/`, a leading `.`, or a name already there → refused with a reason, nothing moved.
  The manifest (`.recense-index.json`) is updated in the same step.

### P0 done checks
1. `homes` selftest: rename moves the bytes, keeps the SHA, updates the manifest, and refuses a clash or a bad name.
2. `carrysync` test: a rename between two scans is one `move` op.
3. The device: the Music tile on iPhone and iPad (iPhone Mirroring) and on the Mac. Delete, rename, loop and play/pause work,
   and the rename shows on the other device after Carry Now.

## P1–P2 as built (2026-11-15): the pill
- Changed from "tap → search, hold → scrub" (above). The scrubber keeps its own touch, so a tap or slide still seeks
  (rule 7 and Scrubber's tap-to-jump). Find opens from the pill's **magnifier** (or ··· › Find in Transcript…). In Find,
  a 0.35 s hold or the **waveform** button goes back to scrubbing.
- Find: case and accents ignored (đ = d), over the words and the translation, recomputed as lines arrive
  (`TranscriptFind`). The count reads "2 of 5". ⌃/⌄ go to the previous/next match: it plays from there and the view keeps
  following the voice. With no player (Listen), it scrolls there instead.
- Hits are accent marks on the scrubber's track. Sliding across one plays the strong detent, a chapter the medium, a line the light.
  At most one each 40 ms. iPhone: Taptic Engine. Mac: trackpad.
- Now Playing opens at full height or half ("minimized"); the transcript and the pill work at both.
- Translation follows the voice (FEAT-10): `TranslationCadence`. Word j of m takes the time of source word ⌊j·n/m⌋,
  so the voice's pauses carry into the translation. With no word times, the words are spread evenly over the line.
- P1–P2 done checks: ShowsKit `TranscriptFindTests` and `TranslationCadenceTests` pass. On the iPhone, Find works while
  the transcript arrives and autoscrolls, at both heights.

---

## Revision 2026-11-16 · The pill, settled; the sound curve, redesigned

Linked specs: FEAT-16 P5 (where the pill is placed) · FEAT-21 (search across everything) · FEAT-23 (the Note button) ·
FEAT-20 (the song light; its timing belongs to lane sync-spec and is not changed here).
Labels: **proven** = a test or the code shows it (file:line) · **assumed** · **untested**.

### Verdict
- **The pill: keep what is built. Add one button (Sound). Add nothing else to it.**
- **The sound curve: one visible Sound button opens it. Two fingers are the fast path, never the only path.**
  The plan's "invisible zone with no button" is rejected (owner, 2026-11-16).
- **Reuse:** the curve is the web tray that already exists, redrawn with seven beads. No new engine on the Mac or the web.

### Terms
- **Pill:** the one rounded bar at the bottom of a player.
- **Bead:** one round handle on the curve. One bead per sound control. It moves up and down only.
- **Curve:** the line drawn through the beads; its shape is the sound's shape at a glance.
- **Zone:** the column of the screen that belongs to one bead.
- **Detent:** a small felt click at a meaningful place.
- **Neutral:** the value that changes nothing (1× speed, 0 dB, original key).

### A · The pill (FEAT-07 P1–P2 as built, FEAT-16 P5 as placed)
Left to right, and nothing else:
1. **Magnifier** → Find in this item (built). Its last result row hands over to Search everything (FEAT-21 rule 6).
2. **The stroke** → the scrubber, with hit marks (built).
3. **Sound** → the sound curve (new; section B). Shown only when the item has sound.
- The **Note** button is not on the pill. It is in Now Playing's top bar (FEAT-23 rule 7). Hearing and seeking
  live on the pill; writing lives at the top. Two places, two kinds of action.
- **Speed leaves its old place.** Today Speed is a slide of the web bar (`library/src/client/homebar.js:39`, `:825`)
  and a right-to-left swipe in this spec's first section. When the curve ships on a surface, Speed is a bead there
  and the old control is removed on that surface in the same change (one control per function).
- Status by surface is FEAT-16's table. Still **untested** on a device: the Mac strip's Find and the iPad and Listen screenshots.

### B · The sound curve

#### What you see
- **At rest:** the Sound button on the pill. White when every bead is neutral; blue when anything is changed
  (the rule the web bar already follows, `homebar.js:19`).
- **Open (tap the button, or ··· › Sound…):** a card rises from the pill and covers the lower two fifths.
  The transcript stays visible above it. One line of seven beads, each in its own column:

  **Speed · Vocals · Low · Mid · High · Clean · Key**

  - Above each bead: its name. Below: its value in words ("1.25×", "Voice only", "+3 dB", "On", "Đô +2").
  - The bead in hand grows; the other six dim to 35 %. One focus at a time.
  - **Flat** (one button, top right of the card) puts every bead back to neutral. It exists today for the EQ (`homebar.js:2317`).
  - The card folds 2.4 s after the last touch (the web bar's own timing, `homebar.js:1767`), or on a tap outside.
- **Width check:** seven columns on the iPhone 12 Pro Max (428 pt wide) are 61 pt each; on a 375 pt phone, 53 pt.
  Both are above the 44 pt touch minimum. **assumed** (arithmetic; P4's screenshot proves it).
- **A bead that cannot be heard here is drawn hollow** and says why in one line when touched
  ("Vocals needs this song's separation from the Mac"). The pattern exists: `sound.why`, `homebar.js:2282`.

#### The seven beads
| Bead | Range | Neutral | Steps |
|---|---|---|---|
| Speed | 0.5× to 2× | 1× | 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2 (`homebar.js:106`) |
| Vocals | Music only · As recorded · Voice only | As recorded | three (`homebar.js:2330-2334`) |
| Low | −15 to +15 dB at 160 Hz | 0 dB | 1 dB (`homebar.js:2292-2298`) |
| Mid | −15 to +15 dB at 1 kHz | 0 dB | 1 dB |
| High | −15 to +15 dB at 5 kHz | 0 dB | 1 dB |
| Clean | Off · On | Off | two (**open question 3**: what Clean does) |
| Key | −12 to +12 semitones | original key | 1 semitone (`KEY_MAX`, `homebar.js:2300`) |

Reverb ("Space") is in today's tray and not in the owner's list of seven: **open question 2**.

#### The fast path: two fingers
- **Two fingers down on the player** (not on a thin bar) opens the card at once, so the gesture is always seen.
  - Why not a thin bar: on a phone two fingers rarely both land on a 44 px bar. **proven** as a recorded finding:
    `homebar.js:1983-1985` ("notes 40").
- The bead whose column is under the midpoint of the two fingers is in hand. Up and down moves it.
- Sliding sideways across a column edge takes the next bead. The card shows which. Lift: the value stays.
- **Mac:** a two-finger scroll while the pointer is over the open card moves the bead under the pointer.
  Elsewhere two fingers keep scrolling the transcript (`strip/recense.swift:1962-1987`). No clash.
- **Draftpad pages (FEAT-23):** two fingers scroll the page (UI-04 P6, `editor/src/ink.js:1685`).
  There is no fast path there; the Sound button is the way.

#### What the hand feels (replaces rule 3 above)
Three levels, as rule 2 already requires:
- **light:** every step of a bead (on Low, Mid and High: every 3 dB, as rule 3 had it);
- **medium:** neutral; and crossing into another bead's zone;
- **strong:** the top and bottom stops.
At most one each 40 ms (rule 5). A haptic never carries meaning alone (law, `docs/law/interaction.md:38`):
every detent also snaps the bead and flashes the value.

| Device | Felt | Evidence |
|---|---|---|
| iPhone | yes (Taptic Engine) | **proven** call pattern in use: `shared/ShowsKit/Sources/ShowsKit/Views/Scrubber.swift:48-52` |
| Mac | a click on a Force Touch trackpad only | **proven** `Scrubber.swift:54`; law `interaction.md:43` |
| iPad Air | **nothing is felt** (no Taptic Engine); sight carries all of it | **assumed** from Apple's hardware (owner's brief); P6 checks on the device |
| Web | nothing felt; marks and snaps only | rule 8 above |

#### What can be heard, by surface (today)
| Surface | Works today | Evidence |
|---|---|---|
| Mac strip | Low, Mid, High, Key, Vocals (a stereo cut), Reverb; Speed is passed to the followed player | **proven** `strip/soundengine.swift:117-125,175-194`; `homebar.js:31` |
| Web (Gallery) | Speed, Low, Mid, High, Key, Reverb; Vocals where the host can | **proven** `homebar.js:2273-2298`, `:2335-2336` |
| iPhone, iPad | none of the seven has a control; the player is a plain `AVPlayer` | **proven** `mobile/HostApp/iOS/NativePlayer.swift:13`; no EQ or pitch unit anywhere in `mobile/HostApp/iOS/` (searched 2026-11-16) |
| Clean | nowhere | **proven** absent: no match for "clean" or "denoise" in `strip/soundengine.swift`, `homebar.js`, `gallery.js` |

### C · The same gesture on pictures
- **Verdict (recommended; open question 4):** a picture has no sound, so the same button in the same place opens
  a **light curve** with three beads: **Light · Contrast · Warmth**.
- It changes how the picture is shown on this device. It never changes the file. Flat puts it back.
- It is kept per device, not per picture: one comfortable setting for a reading session (eye strain).
- Video keeps the sound curve only. One button, one curve per kind of item.
- **assumed** buildable with what the platforms give (SwiftUI's brightness and contrast modifiers; CSS `filter` on the web).
  Not run here.

### Outside services
- **None, at any time.** Sound is processed on the device. No download.
- Vocals on a phone depends on a file the Mac made earlier (the song's separation). It arrives by FEAT-22's
  catch-up and is never fetched at the moment of use; without it the bead is hollow.

### Phases (replace P4; P1–P3 above stand)
- **P4 · The curve on the web tray** (one source, `library/src/client/homebar.js`, so the Mac strip gets it too):
  seven beads, the Sound button on the pill, Flat, hollow beads. Old Speed slide removed there.
  - Check: `library/test/ui.test.mjs` cases: tap Sound → card; each bead moves and reports its value; Flat resets;
    a host without `sound.vox` shows Vocals hollow with its reason; no Speed control remains outside the card.
  - Check: screenshot at 375 pt and 428 pt width: seven columns, none under 44 pt. UI audit named.
- **P5 · Two fingers** (web and Mac). Check: UI test with two synthetic touches: card opens, zone picked by
  midpoint, sideways changes bead, lift keeps the value; Reduce Motion: the card appears with no slide.
- **P6 · iPhone and iPad: the card and Speed.** The same card in ShowsKit; Speed through `AVPlayer`'s own rate.
  The other six are hollow with their reasons. Haptic levels on iPhone.
  - Check (ShowsKit test): zone and detent model, 40 ms limit. Check (device, iPhone Mirroring; iPad): eyes closed
    on the iPhone, find 1× by touch; on the iPad confirm by sight alone.
- **P7 · iPhone and iPad: Low, Mid, High, Key.** Needs the player moved onto an audio engine. **untested**; starts with
  a 30-minute spike that may fail: does the FEAT-19 Lock Screen playback survive the move? Its answer decides P7.
- **P8 · Clean** (after open question 3) and **Vocals on mobile** (after FEAT-22 P1 carries the Mac's files).
- **P9 · The light curve on pictures** (after open question 4).

### Claims from the reviewed plan, checked 2026-11-16
| Claim | Finding | Label |
|---|---|---|
| `GLIDE = 12` in `homebar.js` | Exists, at `library/src/client/homebar.js:1468` (not in `editor/`). It is a **count of scroll steps** that marks a trackpad's momentum glide, not a time or a distance. It has nothing to do with the sound curve. | **proven** (as a constant); the plan's use of it is **unsupported** |
| "381/381 song parity" for Cadence | One line in `.handoff/prosody/HANDOFF.md:8`; the harness was in a session scratchpad and is not in the repo. `main` uses a different route (cadence.js in JavaScriptCore, FEAT-20). 382 voice measures exist on the Mac, which fits the count. | **untested** from this repo |
| "≤ 25 ms" cross-device playback lock | No code and no measurement in `shared/`, `strip/` or `mobile/`. The nearest numbers are different things: the owner's 50 ms allowance against the Mac (FEAT-20) and 0.186 s Bluetooth latency (BUG-12). | **untested** |
| "sub-15 ms" link latency | `shared/p2ptransport.swift` measures no latency. | **untested** |
| The 24-byte clock tick format | No such type on `main`. | **untested** (not found); belongs to lane sync-spec |

### Risks and edge cases
- **Seven beads are the ceiling.** An eighth control does not go on the curve; it goes in ···.
- **Two fingers in a scrolling transcript** on iOS: the system may read them as a scroll or a zoom first. **untested**;
  P5's device check decides whether the fast path starts only on the pill's row.
- **Key and Speed together** on mobile depend on P7.
- **Haptics for comprehension** remain a hypothesis (first Open list); this revision claims only "find neutral without looking".
