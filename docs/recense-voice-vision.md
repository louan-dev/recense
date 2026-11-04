# Recense voice: vision, state, and the prompt agenda

Read this first in any session about prosody, the prosogram, pronunciation, or the learner respellings.
The live session state is `.handoff/HANDOFF.md`; this file is the durable picture and changes only when a decision does.
For where code lives and how it is reused, read `docs/architecture.md`; for what counts as an app, `.claude/CLAUDE.md`
§ "One app, three faces".

> **Pending change, 2026-10-28:** the owner is replacing Groq/Whisper with on-device speech so transcription runs
> offline. That removes the rate limit that currently caps corpus work — but **word timings are load-bearing here**:
> `prosody.js`'s `invert()` turns `Word.start/end` into the syllable windows every pitch and loudness number is measured
> over. If on-device timings are coarser than Whisper's, every number in this file changes. The spike that settles it,
> and the three other things the swap breaks, are in `docs/architecture.md` § "Offline ASR". Do that spike before
> trusting any score recorded under Groq timings.

## The vision
Recense makes a show or song in someone else's language easy to follow, then easy to *say*: the karaoke light and a live
prosogram show how each syllable is voiced, a respelling in the learner's own spelling shows how to make the sounds, and
when the learner says the line back, their own contour is drawn against the speaker's in the same normalised space.
Following is comprehension. Saying it back is what turns comprehension into instinct. Both halves are the product.

Three learners, three directions:

| Learner | Speaks | Learns | Respelling written in | Dialect |
|---|---|---|---|---|
| Owner | English | French | English approximations of French (Cécilia Jourdan's method, *Hello Pronunciation*) | — |
| Mama, cousins | Vietnamese | English | Vietnamese (chữ quốc ngữ) approximations of English | **Southern (confirmed 2026-10-28)** |
| Her | French | English | French-spelling approximations of English | — |

The bar: someone reading the code sees accurate pitch tracking, real syllabic nuclei, perceptual stylization (Mertens'
glissando thresholds), pitch shown against the speaker's own range, and **numbers that prove it** against known answers.
Personal use inside Recense first; later its own app so the others can use it.

## Where things are (verified 2026-10-27, re-verified against the code 2026-10-28)
- **`recense/recense/recense.swift` (7,378 lines) is Recense.** It is the largest and newest source in the repo, Recense owns the
  window, and `Features.measure` lives there (~3875 in the old numbering). `recense/main.swift` (6,557 lines) is a **dead
  older copy** of the app Recense used to be: not installed, not running, never the source of truth. Do not edit it, do
  not build it, do not cite it. See `.claude/CLAUDE.md` § "One app, three faces".
- `Features`: per 10 ms db, onset, pitch (YIN 70–1000 Hz, 32 ms window, MIDI × 100), clarity, voiced, measured on the
  Demucs vocal stem. Cached per item at `keep/<key>/features.json` (the same scheme Gallery uses), so anything that
  changes its shape re-measures the library.
- `.handoff/prototypes/_shared/prosody.js` (627 lines): the prosogram logic, in JS.
  - French: rhythmic groups, final stress, liaison and enchaînement (`frLink`), mute e and syllables (`frSyllables`).
  - Vietnamese: syllables, tone marks, Chao tone numbers, glottal breaks. **Northern norm only** (`VI_TONE`, line 40–49)
    — wrong dialect for the people this is for, see "Southern Vietnamese".
  - Stylization: a syllable is level or a glissando; the reference pitch follows the register (clip median plus a
    15-syllable median); a 5-frame median then mean smooths it. **Nuclei come from the spelling (vowel letters), not from the audio.**
  - What it does well, and should not be lost in any rewrite: the measured contour is *projected* onto the tone or
    intonation template with a regression coefficient (line 511–515), so the mark decides the direction and the voice
    decides how far; one fixed semitone scale per clip, so an interval is the same height everywhere; named intervals
    between syllables.
  - English: only a generic fallback syllabifier (~line 239). **No English rules.**
- `.handoff/prototypes/prosogram/index.html`: the prosogram view (staff = reference ±4 st, segments, glides, liaison ties, tones).
- Clips: `_shared/clips/` has fr-speech, vi-speech, soro (music). **No en-speech, en-music, fr-music or vi-music here yet**
  (the owner has these on localhost: copy them in).
- *Hello Pronunciation* dataset: `datasets/French/hello-pronunciation/` (index.json: 23 sounds, 117 examples, 253 clips on R2 private
  bucket recense-tmp). Phases 1–3 done; Phase 4 plan in its README. Author consented; never publish the data.
- A headless entry point exists as a pattern (`--corrections-selftest`, `--match` … in main.swift ~6367); no `--features` yet.

## What the code actually does (read before planning accuracy work)
Five facts found by reading the source, each of which changes a plan step.

1. **Syllable timing depends on the rendering device's font metrics.** `defaultMeasure()` (prosody.js 609–622) places
   character boundaries with `ctx.measureText`. Those become `s.u0/s.un/s.u1`, which `invert()` turns into `s.t0/s.t1` —
   the windows every pitch and loudness number is measured over. In Node, `OffscreenCanvas` and `document` are both
   undefined, the `catch` fires, and the fallback is uniform `i / length` spacing (line 617). **A headless run and the
   on-screen prosogram therefore measure different time windows for the same syllable**, so a headless test validates a
   pipeline nobody sees. Timing must come from the audio and the alignment; glyph widths belong only in the drawing code.
2. **`clarity` is measured, stored, serialised and read by nothing.** main.swift:3935 computes `100 × (1 − aperiodicity)`
   and writes it into `features.json`; no reader exists in prosody.js or the prosogram. Low clarity with energy present
   and low f0 *is* glottalisation — `nặng` and `ngã` — not a crack. Weakness 6 below is fixable today by reading a field
   that is already written.
3. **`voiced` is pure energy, independent of pitch and clarity** (main.swift:3944, `db >= floor`). Unvoiced fricatives
   count as voiced; creaky low-energy phonation falls below the floor. `nặng` ends in exactly that state, so the gate
   discards the end of the tone we most need to see.
4. **`features.json` cannot support the planned Viterbi step.** `measure` keeps one lag per frame (3929–3939) and throws
   away the CMND curve; pYIN-style Viterbi needs the candidate set. So that work is a *schema* change, not a scoring
   change. Version the schema and record the measurement parameters in the file **before** anything caches it.
5. **One reference pitch per clip, however many people are speaking.** `gRef` is the median over all syllables and `span`
   is p95−p5 clamped to 8–18 st (prosody.js 409–410); there is no diarisation. A two-character scene or a duet pools a
   man and a woman into one range, so every tone height and intonation event in that clip reads wrong. The intended
   audience watches shows, so this breaks the real use case more directly than anything else on the list.

## Weaknesses to fix, in order of payoff
Reordered 2026-10-28: cheap fixes that make later measurements trustworthy come first.

1. Octave errors, in the cents domain: pitch is already MIDI × 100, and an octave error is exactly ±1200. Snap any frame
   within tolerance of ±1200 of the local median back onto it. Near-zero cost, no schema change. Do this before Viterbi
   and the residue will be small.
2. Gate `voiced` on `clarity` (fact 2, 3) so creak reads as creak and fricatives stop counting as voice.
3. Decouple syllable timing from glyph metrics (fact 1). Until this is done, no headless number means anything.
4. Stylization with Mertens' **two** thresholds: the glissando threshold 0.32/T² st/s, and the *differential* glissando
   threshold at half that value, which decides whether two successive movements are heard as one. Without the second one
   the contour over-segments. Move this early: a stylized contour is a few line segments instead of a frame array, which
   makes it readable and makes every later test cheaper to write, store and diff.
5. Nuclei from text only: add acoustic nucleus detection (intensity peak in a voiced stretch, −3 dB left / −9 dB right,
   min duration) and snap the text syllables to it. Lands on trustworthy frames once 1–3 are done.
6. Crack detection (`thin`, 3 st in 30 ms) fires on octave errors; after 1 and 2 it can be gated properly.
7. Range: replace the percentile heuristic with a fit (see "Free supervision" below), and diarise — k-means on two
   features, median pitch and spectral tilt, two or three clusters, per-cluster range. No model needed.
8. Viterbi over retained YIN candidates (needs fact 4's schema); later RMVPE/CREPE via Core ML for singing.
9. No English: syllabifier, lexical stress, English test clips.
10. No measured accuracy anywhere: every step above ships with a test and a number.

## Free supervision (the trick worth building the plan around)
**Vietnamese orthography encodes tone.** Every Vietnamese word in any transcript is therefore a labelled tone example, at
no annotation cost. Two uses:

- **Test data for nothing.** Thousands of labelled syllables from VIVOS or Common Voice vi, without annotating anything.
  (Once ASR is on-device there is no rate limit, so this can run across the whole library rather than a sample.)
- **Solving the range problem properly.** Instead of estimating the speaker's range as p5–p95 clamped to 8–18 st, *fit the
  range so the tone categories separate maximally*. The labels are free, so this is supervised calibration that looks
  unsupervised, costs one pass, and is strictly better than a percentile heuristic. The same idea generalises: for English,
  fit so stressed and unstressed separate; for French, Rhapsodie's prosodic boundaries let the rhythmic-group heuristic
  (currently a FUNC-word rule with a ≥3-syllable counter, prosody.js 349–362) be *scored* instead of guessed.

**The trick has one hole, and it is exactly our dialect.** Orthography gives six tone labels, but a Southern speaker
produces five: `hỏi` and `ngã` are written apart and said the same. Fit six categories on Southern audio and the fit tries
to separate two classes that are acoustically identical, which corrupts the range it is supposed to estimate. So the label
map is dialect-dependent: **collapse `hỏi` and `ngã` into one class before fitting, and score tone accuracy on five
classes, not six.** VIVOS and Common Voice vi are mixed-dialect, so either filter by speaker region or fit per speaker.

## Datasets
- French: *Hello Pronunciation* (known answers for links, syllables, mute e, contours); Rhapsodie (prosodic annotation,
  freely available); PFC (access-restricted: check before planning around it).
- English: LibriTTS + Montreal Forced Aligner (syllable/phone times); Buckeye (conversation); MIR-1K / MDB-stem-synth
  (sung pitch with ground truth). **CMUdict gives phonemes and stress digits but no syllable boundaries** — a syllabifier
  over the phoneme string (maximum onset, English onset legality) is still needed.
- Vietnamese: VIVOS, Common Voice vi, VLSP. **None of these carry tone annotation** — the transcript is the label (see
  Free supervision). That gives expected categories, not measured f0.
- Learner English: L2-ARCTIC (includes Vietnamese speakers, annotated errors); AixOx-type corpora for French speakers (check access).
- **Speech f0 ground truth, currently missing from the plan entirely.** The laryngograph sets are PTDB-TUG, Keele, FDA and
  CSTR. Cheaper and better aimed: hand-correct f0 in Praat over ~2 minutes each of fr-speech and vi-speech and own a gold
  set in the two priority languages. Without this, the only real pitch number in the whole plan is RPA on MDB-stem-synth,
  which is sung English — i.e. the plan never measures pitch accuracy in the languages it prioritises.

## The imitation loop (the half that was missing)
Measuring someone else's voice better does not make mama fluent. Producing sound and finding out whether it landed does.
The infrastructure already exists and only needs wiring:

- `Features.measure` takes any `[Float]`; it does not care whether the audio is a show or a microphone.
- Normalisation is already per-speaker, so a Vietnamese woman who can never match an American man's absolute pitch can
  match the normalised contour — which is exactly what prosody.js already computes.
- `player-key.js`'s phase vocoder already slows audio without shifting pitch, so a line plays at 0.6× and the target
  contour stays valid.

**Build:** record the learner saying the line, run the same pipeline, draw their prosogram against the speaker's in the
same normalised space. Score three ways — DTW distance on the normalised semitone track; per-syllable tone-category
agreement for Vietnamese; stress-placement agreement for English. One number and one picture.

Two things this unlocks:
- **For her (French → English), show stress as a prosogram event, not a diacritic.** French has no lexical stress, so she
  cannot reliably *hear* English stress; she can see it, because the stressed syllable is measurably higher and longer and
  both are already measured. It aims the prosogram's one unique strength at the exact gap her L1 leaves.
- **Drills generated from each learner's own misses, on clips they already watched.** Immersion-grounded practice instead
  of textbook practice.

## Prompt agenda
Send one per session, in order. Each starts: "Read docs/recense-voice-vision.md and .handoff/HANDOFF.md first."
Order revised 2026-10-28. French and Vietnamese first, English later; the old numbering is kept in brackets so earlier
notes still resolve.

| # | Step | Effort | Was |
|---|---|---|---|
| 0 | `--features <audio> <out.json>` headless flag on `recense/recense/recense.swift` reusing `Features.measure`, **with a versioned schema** carrying candidates, clarity and the measurement parameters. Run it on all clips and the *Hello Pronunciation* clips (Phase 4(b), streamed from R2). | medium | [4] |
| 1 | Cents-domain octave snap + gate `voiced` on `clarity`. Report octave-error rate before and after. | low | new |
| 2 | Decouple syllable timing from glyph metrics; prove a headless run and a browser run agree. | medium | new |
| 3 | Expected-answer files for fr-speech and fr-music **plus a hand-corrected f0 gold set**, and the scoring runner that prints one accuracy line per clip. | medium | [1, fr] |
| 4 | *Hello Pronunciation* tests, Phase 4(a): `prosody.hello.test.js`. Report disagreements; don't bend rules to the book. | medium | [2] |
| 5 | Stylization with both glissando thresholds, shared by Swift and JS or moved fully to one side. | high | [8] |
| 6 | Acoustic nuclei in `Features` + snapping text syllables to them, so liaison and enchaînement sit on the right syllables. Score on every expected.json. | high | [6] |
| 7 | Range by tone/stress separability + k-means diarisation. Score before and after. | high | [3, 7] |
| 8 | Viterbi over retained candidates; score on MDB-stem-synth (RPA, octave-error rate) and on the f0 gold set. | high | [7] |
| 9 | **Southern tone templates**: `VI_TONE_S` plus a dialect flag — five categories, `hỏi`/`ngã` merged, no glottal break on the merged tone. The Northern set stays untouched for Northern material. | medium | new |
| 10 | Vietnamese expected answers: tone per syllable for vi-speech and vi-music, **five-way Southern**. Runner already exists from step 3. | medium | [1, vi] |
| 11 | Tone accuracy on vi-music and VIVOS / Common Voice vi, orthography as the label with `hỏi`/`ngã` collapsed. Those corpora are mixed-dialect: filter by region or fit per speaker. | medium | [10] |
| 12 | Vietnamese tuning of range and thresholds: tone heights land right, creaky `nặng` stops reading as a crack, level tones stay apart from contour tones (`ngang` from `sắc`, the merged dipping tone's dip). | high | [7, 8 again] |
| 13 | **The imitation loop**: record, measure, overlay, score. | high | new |
| 14 | Add English to prosody.js: syllabify from CMUdict phonemes (with a syllabifier and fallback rules), lexical stress, reduced vowels, phrase-final events. Make the en clips' expected.json pass; show them in the prosogram. | high | [3] |
| 15 | Respelling tables with the *owned / near / fresh* status column. Vietnamese→English for mama and cousins on **Southern** anchors (retroflex `tr`/`s`/`r` owned; /z/, /v/, /θ/, /ð/ and the final /n/–/ŋ/, /t/–/k/ contrasts fresh), checked against L2-ARCTIC Vietnamese speakers' errors; French→English for her (English phoneme → nearest French spelling, flags for th, h, short i, word stress). List the words that need a native check. | medium | [9, 5] |
| 16 | Plan the split: a shared voice module (Features, prosody, respelling, imitation) used by both Recense and a standalone Recense client. | high | [11] |
| 17 | Build the client: onboarding by learner language pair **and dialect**, no Recense dependencies. | high | [12] |

**French is done when:** fr-speech, fr-music and the *Hello Pronunciation* tests all pass with figures recorded before and
after, the f0 gold set gives an RPA and an octave-error rate, and fr-music looks right in the prosogram.

**Vietnamese is done when:** tone accuracy is measured on the owner's clips and on VIVOS, the range fit separates the five
Southern categories, and vi-music shows the right tones in the prosogram.

**Neither is done until someone who is not the owner can read the picture.** After French, show the prosogram to mama or a
cousin. If they cannot read it, no accuracy number saves it. This is the real product risk and it is currently unmeasured.

**Timing:** steps 0–2 are under a day together. French (3–8) about 2 days, since 5–8 are high effort. Vietnamese (9–12)
about 1 day, because it reuses that work.

## Southern Vietnamese (confirmed 2026-10-28)
Mama and the cousins speak **Southern**. prosody.js encodes the Northern norm, so as it stands it would show them tones
they do not produce and mark their correct speech wrong. This is a correctness problem, not a preference, and it reaches
further than the tone table.

**Tones.** Southern has five categories where the orthography writes six: `hỏi` and `ngã` merge into a single dipping
tone, without the glottal interruption Northern `ngã` carries. Consequences:
- A second template set, `VI_TONE_S`, with a dialect flag — not an edit to the Northern one, which stays correct for
  Northern material.
- `ngã`'s glottal break (`glottal: .5`, prosody.js line 46) must not fire for Southern. Today it draws a cut that a
  Southern speaker never makes.
- Tone scoring is five-way. Marking a Southern speaker wrong for not distinguishing `hỏi` from `ngã` is the single most
  damaging thing this tool could do to someone's confidence, and it is the default behaviour right now.

**Consonants, which decide the respelling table.** Southern is not merely a different accent here; it has a *different
set of anchors* for English sounds, and some of them are better than Northern's:
- **Retroflexes are preserved.** `tr` /ʈ/, `s` /ʂ/, `r` /ʐ/ stay distinct, where Northern merges them. So English *r*,
  *sh* and *ch* have real native anchors — a Southern speaker can be pointed at a sound they already own. A Northern
  speaker cannot.
- **No /z/ at all.** Southern `d` and `gi` are /j/, not /z/. So English *z* (zoo, is, lose) has **no native anchor**, and
  respelling it as `d` actively teaches the wrong sound.
- **Final consonants merge**: `-n` toward `-ng`, `-t` toward `-c` in several vowel contexts. English final /n/ vs /ŋ/ and
  /t/ vs /k/ are therefore genuinely hard, which matches the L2-ARCTIC Vietnamese error pattern.
- **`v`** is commonly /j/ in casual Southern speech, so English /v/ needs teaching rather than approximating.

**So the respelling table needs a third column, not two.** Not just "English sound → Vietnamese spelling", but a status
per sound: *owned* (an anchor exists — point at it), *near* (an anchor exists with a flagged difference), *fresh* (no
anchor — must be taught as a new sound, never approximated). For Southern, `fresh` holds at least /z/, /v/, /θ/, /ð/ and
the final /n/–/ŋ/ and /t/–/k/ contrasts. A table without that column quietly teaches wrong sounds for its own entries.

## Open questions
- Does *her* French→English table need regional treatment too, or is standard metropolitan French the right anchor set?

## Rules carried between sessions
- Never publish or redistribute Cécilia Jourdan's material; private R2 only. **Make this structural, not a note:** a
  content-addressed manifest (sha256 per clip, licence, `publishable` flag) and a test that fails if anything
  non-publishable is reachable from committed or deployed code. Same shape as `sync/src/ledger.mjs`'s hash-chained
  journal — reuse it rather than writing a new one.
- Every accuracy change reports a number before and after.
- Respelling tables are checked by native speakers (owner, mama, cousins, her) before they count as done.
- `features.json` is cached per item and shared with Gallery's `keep/<key>/` scheme: a schema change means a re-measure,
  so version it and never change it casually.
