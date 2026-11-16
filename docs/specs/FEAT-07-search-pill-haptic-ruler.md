# FEAT-07 · Transcript search pill + haptic zoning of the time ruler and EQ

From: T-0045 (owner 2026-11-14, rated ******, wishrank #1 of the rated wishes) · Status: `[ ]`
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
