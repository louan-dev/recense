# Interaction

The owner's "UI changes" audit in `~/.claude/CLAUDE.md` (one control per function, no leftovers,
every action has a visible control, motion respects Reduce Motion) is binding and is not repeated here.

## Quiet by default
- Capability is always available; it is shown only when relevant.
- Reduce steps, not features.
- Capture first, organize later: never ask where something belongs before it can be written.
- Context over dashboard: nothing appears just because there is room for it.
- When choices compete, in this order: reliability, data integrity, native integration,
  correct interaction, layout on each device, visual polish, decoration.

## Eyes
- Large text, narrow single column, short lines, vertical lists. No wide tables in reading views.
- Long paragraphs reflow into shorter chunks with space between them.
- The reader's place is never lost: a position marker survives switching, scrolling and rotating.
- Calm visuals: few colours, no decorative motion, high contrast.
- Never rely on colour alone (colour blindness): pair it with shape, position or text.

## Attention
- One focus at a time.
- Predictable: nothing changes under the reader's eyes. New results appear the next time a view opens.
- Guard rails before anything that can't be undone: draft, confirm, then act.
- Impulses are welcome: starting or resuming takes one action.

## Gestures
- **Meaning comes from direction and finger count, never from which hand or which side of the screen.**
- Scrubbing and sliders are anchor-relative: where the finger lands is zero; movement from there sets the change.
- Layouts mirror safely: use logical properties (start/end, not left/right).
- A gesture only speeds an action up. The same action also has a visible control, a menu item and a voice command.
- "Buttonless" means no chrome while working. Controls appear on demand,
  and anything that invites people to connect (comments, likes, sharing) stays visible.
- A gesture never fights the system: if macOS or iOS owns it (e.g. two-finger swipe for back), claim it explicitly or pick another.

## Haptics
Evidence and sources: `docs/research/haptics.md`.
- A haptic never carries meaning alone; sound or sight carries it too.
- At most 3–4 distinct levels per haptic dimension.
- Cue the right word, not many words: placement matters more than vibration.
- Timing comes from known word and syllable times, never from live audio analysis.
- Order: the light leads, the sound follows, the click lands last.
- A Mac trackpad can only click; swells and textures need a phone, a watch or headphones.
- No haptic claims better comprehension until a test on the owner shows it (see `purpose.md`, "Intent is not evidence").

## Languages
- Every visible string exists in English, French and Vietnamese.
- The app shows the language of the device it runs on, with no setting needed
  (Apple: string catalogs; web: the browser's language list). A per-app override is allowed.
- All three work offline: interface, voices, recognition, translation.
- Content mixes languages; every feature handles a page with more than one.

## Sound
- Anything visible can become audio: select it, hear it, in its own language.
- Read-aloud, transcription and translation run on the device.

## Amendments
- 2026-11-14 · created from the 2026-11-05 note; replaces `export/03_DESIGN_PHILOSOPHY.md`.
