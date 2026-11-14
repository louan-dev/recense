# Haptics for reading and listening · evidence

Collected 2026-11-05 from the owner's note; filed 2026-11-14.
The rules drawn from it are in `docs/law/interaction.md`. This file is evidence, not law.
Figures below are as summarized in the note; re-check a source before citing it in a spec.

## What studies showed
- **Text-to-Haptics** (Stroinski et al.): one cue per sentence, on one word, timed from the TTS word timings,
  chosen by sentiment from 14 mid-air ultrasound patterns. Targeted cues beat randomly placed ones:
  the benefit comes from *where* the cue lands, not from vibration itself.
  Each cue was a 3 s swell (1 s up, 1 s hold, 1 s down). Cue density was never varied (about 10 a minute).
- **Following the voice** (pitch, loudness) helped hearing speech in noise.
  2026 results: synchronous vibration improved comprehension with several talkers in the background;
  amplitude-synced vibration improved recall in noise and lowered skin conductance; self-reported load didn't change.
- **Event or meaning cues** helped engagement and memory. Neither kind has shown better comprehension of dense text.
- **FeelSleeve** (Disney Research): 44 children; story-event haptics (rain, a heartbeat) raised comprehension
  in one story from 58.3% to 68.2% (p = 0.04). The other story was at ceiling; reading speed didn't change.
  Semantic effects fit narrative, not dense legal text.
- **Automatic XML creation** (Okuno et al.): automated audiobook haptic annotation with a sensory-word lexicon;
  the same group built a multisensory audiobook app and authoring tool. Closest to an audiobook use.
- **Identifiable levels:** one haptic dimension carries about 3–4 levels, versus 5–7 for sound or vision.
- **Blind and low-vision musicians** (10, workshops): simple alerts worked; following rich vibration while playing
  raised cognitive load; single pitches were hard to decode. One wanted cues ahead of time, as landmarks.
- **Tactile Melodies:** frequency analysis of polyphonic audio was inaccurate; they switched to MIDI.
  5 of 8 identified every song by touch (choosing among 3 memorized songs: weak evidence).
- **Haptic Wave** (Arts 2023, 20 blind sound creatives): feel a waveform's amplitude while scrubbing.
- **Audio pseudo-haptics** (ICAD survey, 89 papers): sound alone can change felt roughness or weight; sync matters.
  It measures sensation, not comprehension.
- **Sync tolerance** (10 students): reading → speech → image → haptic, with haptics 20–260 ms behind,
  drew complaints from under 20%. Tested on paragraphs; per-word tolerance is likely tighter.
- **Dark Haptics:** cues steer behaviour, so a wrong cue teaches the wrong emphasis.
- **Legal design:** Haapio, Passera and Hagan lead visual contract design (Passera: 124 professionals, 24 countries);
  their 2024 comic-contracts chapter adds audio. Brunschwig (Zurich) names tactile-kinesthetic law
  as a branch of multisensory law; conceptual, no tests found.

## Proposed for Recense (untested)
- **Cheap self-test first:** split a chapter into sections; give each targeted cues, random cues or none;
  take a recall quiz per section.
- **Orientation** (best supported): scrub detents at chapter, section and subsection boundaries, strength by level (max 3);
  a progress cue that grows toward the end (Delft thesis idea, untested).
- **Obligation words in legal text:** three patterns for must/shall, may, must-not, on those words only.
  Decide deliberately whether MPEP's "should" gets its own tier.
- **Defined terms and exceptions:** one light tick at a term's first use and at "unless/except";
  a review mode replays the ticks so the reader recalls the definition first.
- **Mac trackpad score:** line start → `.levelChange`, word onset → `.alignment`; skip unlit words;
  a joined (liaison) run is one click. Optional "Rhythm" level on strong syllable onsets, ≥100 ms apart.
  Menu: Off / Words / Rhythm. Clicks land only while fingers rest on the trackpad.
- **Haptic score** built once per episode, on the light's clock, cached like the prosody.
- **Headphones (QC35):** EQ or reverb shaping as an emphasis cue. Supported for sensation only (ICAD).

## Sources
- Apple HIG, Gestures: https://developer.apple.com/design/human-interface-guidelines/gestures
- Apple HIG, Playing haptics: https://developer.apple.com/design/human-interface-guidelines/playing-haptics
- https://www.tandfonline.com/doi/full/10.1080/10447318.2025.2464899
- https://advanced.onlinelibrary.wiley.com/doi/10.1002/aisy.202400758
- https://arxiv.org/pdf/2408.06449
- https://cil.csit.carleton.ca/b/wp-content/uploads/2023/11/3597638.3608397.pdf
- https://link.springer.com/chapter/10.1007/978-3-031-04536-3_13
- https://pmc.ncbi.nlm.nih.gov/articles/PMC7237382/
- https://www.mdpi.com/2076-0752/12/4/154
- https://elmcip.net/critical-writing/reading-digits-haptic-reading-processes-experience-digital-literary-works/
- https://www.science.org/doi/10.1126/sciadv.adz5937
- https://www.cs.unm.edu/~zhuwang/assets/pdf/Audio_Pseudo_haptics_Survey_ICAD.pdf
- https://medium.com/@mksaraf12/bridging-past-future-with-haptic-technology-0ca6f4095c40
- FeelSleeve, Disney Research (the note's link was malformed; find the paper by title).
