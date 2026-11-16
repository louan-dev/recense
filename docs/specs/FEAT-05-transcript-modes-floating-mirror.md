# FEAT-05 · Transcript modes (Transcript · Learn · Follow) and the floating window as a mirror

From: owner 2026-11-12 (goal message), T-0030, T-0031, T-0032 · Status: `[ ]`
Lane: transcript-modes (`.claude/worktrees/transcript-modes`, `work/transcript-modes`).
Builds on: FEAT-04 (content clock), FEAT-10 (translation cadence), BUG-12 (output latency), BUG-13 (sentence lines).

## The owner's words (2026-11-12)
> the floating window must look like Untitled.mov / Untitled 2.mov … no in-app dock and no Learn/Follow toggle …
> Learn = original first, which dissolves into the translation at the same position, with highlight …
> Follow = original top, translation bottom, word-by-word highlight … NO REGULAR PLAIN WHITE TEXT.

## Evidence: the reference videos, measured 2026-11-16 (ffmpeg frames at 2 fps, ImageMagick colour histograms)
- `~/Documents/Untitled.mov` (Learn, 626×204, 60 fps) and `~/Documents/Untitled 2.mov` (Follow, 626×204, 60 fps).
- There is **no panel**: the text sits straight on what is behind it, centred, with a soft shadow.
- Three text colours, measured on the glyph cores:
  - spoken: white `#F2F1F1`;
  - the word being spoken: gold `#F5E399`, **filled per character** up to the voice ("Al|l", "pr|ayed", "ré|véler");
  - not yet spoken: grey, measured `#909090` over a mid-grey window; that is white at about 55%.
- A new line appears **whole and grey, at once**, then fills from the left. Nothing slides or fades in.
- Follow: the original is semibold, up to 3 lines; the translation is regular weight, the same size, up to 2 lines,
  one line-height below. The translation's light moves word for word, in step with the original.
- Learn (Untitled.mov): one line, semibold, as above. (The phrase-by-phrase turn into the translation is the owner's
  2026-11-12 choice below; the video shows a single-language line.)

## Rules
1. **One painter.** `CaptionPainter` (ShowsKit) draws every caption: in-app Learn and Follow, the Mac floating panel,
   and the iOS floating window's frames. Same inputs give the same pixels on every surface.
   Today's three copies (`WordsView` + `Cadence` on the Mac, `TranscriptLight` on iOS, the web's own) are a bug (parity law).
2. **Colours:** spoken `#F2F1F1`, current gold `#F5E399`, upcoming white at 55%. No plain white line anywhere.
   The fill edge is per character: the fraction of the current word heard (`Cadence.progress`) picks the glyph.
3. **Three modes, one switch:** Transcript (the scrolling Podcasts-style list), Learn, Follow.
   The switch is in the transcript editor's top row (SPEC 57: language · view). It is also in ··· and by voice ("Transcript", "Learn", "Follow").
   Switching takes < 100 ms and keeps the reader's place.
4. **Learn, each phrase as heard (owner 2026-11-12):**
   - a phrase (`learn.js` `phrasesOf`, the Swift `phrases()`) turns into its translation `TURN` = 0.3 s after its last word is heard, in place;
   - while a line is heard, it is part translation (heard, white) and part original (not yet heard, grey);
   - the line re-flows, so each phrase's width eases from the original's to the translation's over 0.3 s and the line re-centres:
     no gaps, no overlap (today's gaps: `strip/recense.swift:2151`, `:2386-2425`);
   - Reduce Motion: a crossfade with no width animation;
   - no prosody in Learn (PLAYBOOK §3).
5. **Follow:** original on top (semibold, ≤ 3 lines), translation under it (regular, ≤ 2 lines), both lit word for word.
   The translation's words take their times from `TranslationCadence` (FEAT-10).
6. **Floating window = mirror:** the same mode and the same frame as in-app, scaled to its box. Removed:
   - the iOS "Look" section and preview (`Listen.swift:1398-1408`);
   - the Mac in-app dock (`Overlay.host(in:)`, `recense.swift:1493`);
   - the hidden Learn/Follow toggle.
7. **iOS floating frames:** drawn into pixel buffers at display rate, each stamped with its presentation time on the
   layer's timebase. This replaces one `ImageRenderer` image per word start, capped at 10/s (`Listen.swift:1142-1200`).
   The canvas aspect is chosen per device and orientation (T-0032).
8. **Size:** the in-app caption text scales with the reader's text size (the home bar's size slide); the floating
   panel on the Mac resizes by drag; the text fits 2 lines per language at every size, shrinking before it cuts.
9. **Clock:** own player = the sound's clock plus output latency (BUG-12 already does this on iOS; the Mac gets the same in T2).
   Live sound from other apps keeps its labelled delay.

## Thresholds (binding)
- Light edge within **16.7 ms** of the voice at the speaker (own player, measured by the timing rig).
- Floating window within **1 frame** of in-app.
- Mode switch **< 100 ms**.
- Learn turn **0.3 s** ± 1 frame after a phrase's last word.

## Offline gate
None at the moment of use. Translation is Apple's on-device Translation (FEAT-10); the painter is local drawing.

## Done checks
1. ShowsKit `swift test`: golden images of `CaptionPainter` at fixed times — Learn mid-turn, Follow mid-word,
   a line change (whole and grey at once), the per-character gold edge. Pixel colours within ±3 of the values above.
2. Mac: `zsh strip/build.sh` + `strip/recense selftest`; a screenshot of each mode, in-app and floating.
3. iOS compile, installed on iPhone and iPad; iPhone Mirroring screenshots of each mode, in-app and floating.
4. Timing rig: click track with known onsets → screen recording with sound → ffmpeg onset vs. lit frame ≤ 16.7 ms.
5. UI audit (`~/.claude/CLAUDE.md`): one switch, no dock, no leftover toggle, Reduce Motion respected.

## Phases
- P1 `CaptionPainter` + Learn re-flow in ShowsKit, with golden tests. No surface changes.
- P2 Mac: floating panel and in-app modes use it; dock and toggle removed; display-link clock.
- P3 iPhone and iPad: in-app modes and the floating window's pixel buffers.
- P4 prosody-paced fill (Follow and Transcript only), from `features.json`.

## Open
- The owner's iPhone recording `ScreenRecording_11-12-2026 20-24-30_1.MOV` was never found; if it shows more, P1 adds it.
