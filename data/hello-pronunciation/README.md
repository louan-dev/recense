# Hello Pronunciation reference set

Cécilia Jourdan & Marie-Lola Sendra, *Hello Pronunciation: Mastering the Sounds of Spoken French* (Hello French NYC), and
her 253 recordings. Used with Cécilia's consent (owner confirmed 2026-10-27). Media stay in the **private** R2 bucket; only
this index is in git.

## Where things are

| What | Where |
|---|---|
| Index (sounds, examples, notes, lessons, clip metadata) | `index.json` (this folder) |
| Source PDF (63 pp, 11.2 MB) | `r2://recense-tmp/hello-pronunciation/source/hello-pronunciation.pdf` |
| Audio: 253 original m4a clips (AAC mono, 48 kHz ×248, 44.1 kHz ×5; 47.2 MB, 77 min) | `r2://recense-tmp/hello-pronunciation/audio/<wix-hash>.m4a` |
| Diagrams: 16 lip photos (PNG with alpha) + 9 mouth cross-sections (rendered with numbered markers), 5.0 MB | `r2://recense-tmp/hello-pronunciation/diagrams/<sound>_<kind>_p<page>.png` |
| Generator scripts, Wix track list, audio manifest | `tools/` |

`recense-tmp` lifecycle only expires `tmp/`, so `hello-pronunciation/` persists. List with `tools/r2aws s3 ls s3://recense-tmp/hello-pronunciation/ --recursive`
(`r2aws` reads keys from `~/.config/recense/config` and never prints them).

Rebuild the index (PyMuPDF venv; nothing is written locally except the index):

```bash
python -I tools/hp_build.py "<pdf>" tools/tracks.tsv index.json /tmp/plan.json tools/audio_manifest.json
python -I tools/verify.py "<pdf>" index.json
```

## index.json in short

- `sounds[]` (23): `id`, `ipa`, `kind` (vowel / semi_vowel / consonant / letter_rule), `name` (the book's heading), `spellings[{letters, condition}]`,
  `analogy{english_word, letters, text}`, `how_to`, `intro`, `mouth_steps[]`, `audio` (the sound on its own), `examples[{word, ipa, translation,
  spelling, audio, audio_scope, audio_title, pdf_page}]`, `notes[{text, audio[], pdf_page}]`, `diagrams[{kind, r2, pdf_page}]`, `source.pdf_pages`, `flags[]`.
- `general[]`: section overviews (the three “EUH” sounds, how to pronounce nasal vowels, with its cross-section).
- `lessons[]` (154): every other clip (themes 1–6, 8 intro and R, 9 phrases, 10 vocabulary), each with the PDF page and the text printed beside its link.
- `clips{hash}`: title, r2 path, PDF pages, measured duration, bytes, codec, sample rate, channels.

Conventions: IPA is as printed. The book writes every French R as ʀ (U+0280, explained on p43); prosody.js writes `ʁ`. Nasal vowels use combining
U+0303, NFC. `audio_scope: "row"` means one clip reads both words on that table row. The site's player durations were wrong (3,255 s total against 4,634 s measured), so only the ffprobe values are kept.

## How it was checked

- PyMuPDF text with tildes re-attached in stream order (pdfplumber drops them). Rows come from the drawn table rules; columns from the header cells.
- 117 examples: every word and IPA string is in its page's text layer; IPA inventory scan finds only one non-IPA letter (`c`, see below).
- Audio ↔ row: 92 examples have site titles numbered “… - N” and every N equals the row's position; the other 25 are titled by spelling/sound
  (“- oi”, “- ph”, “C - k” …) and all match their row. PDF link hash set == site hash set (253).
- Diagrams reviewed on a contact sheet; 4 decorative pictures excluded (p37 cheese, p40 bicycle, p44 two “Bonjour” graphics).
- Visually checked pages 30, 33 and 38 against the index.

## Owner spot-check list

1. **[ɔ] note, “Southern accent” clip** (p32): the site files it as `T7 - The Sound [ɛ] - Attention - Southern accent`, but the text is in the [ɔ] note. Attached there; listen to confirm.
2. **Letter S notes** (p42): `Attention - 1` / `- 2` attached by order (1 → “final s silent: les fraises”, 2 → “sc, t, x: scène, patience, dix”). Listen.
3. **[œ̃] note** (p35): one untitled “Attention” clip attached to the only note (“une brune”). Likely right.
4. **`ã` versus `ɑ̃`**: the book prints `[mãʒe]` (p30) and `[ʀapidəmã] or [ʀapidmã]` (p33) with ã, but `ɑ̃` elsewhere, including `manger [mɑ̃ʒe]` on p23. Kept as printed and flagged. Decide whether tests normalise ã → ɑ̃.
5. **`une crêpe [yn cʀɛp]`** (p31): `c` where `[k]` is expected. A book typo, kept and flagged.
6. **No English analogy** in the book for 15 entries (e-closed, eu-open, schwa, u, an, in, on, hu, w, letters C/G/S, f, gn, r). For tap-to-hear, use her `how_to` sentence for these (e.g. [y]: say “ee” with O-shaped lips).
7. **Diagrams**: cross-sections exist only for ɛ, ə, y, ɑ̃, ɛ̃, ɔ̃, ɲ, ʀ and the nasal overview, and lip photos for 16 sounds. Marker 1 (lips) sits on the lip photo, so some panels show only markers 2–4. Four panels keep a corner of the round “tap here” badge.
8. **Lesson text** is whatever is printed beside each link, so it can be clipped (e.g. “Mandatory Liaisons” rows keep 1–2 of their examples) or show glyph-order artifacts (“a fni al b”). Check before turning it into tests.
9. **[e] sub-heading**: “AT THE END OF WORDS ONLY:” is stored as the condition for er / ez / es (p30). Check that reading.

## Phase 4 plan (not started)

### (a) `prosody.hello.test.js`: her examples as known answers (≈ ½ day)

Same style as `.handoff/prototypes/_shared/prosody.test.js`; it reads `../../../data/hello-pronunciation/index.json`.

1. **Links (frLink / frInner)** from the IPA, done automatically: in each multi-word example, a missing space at a word boundary means a link. The consonant at the
   join is the expected `sound`: `vous allez [vuzale]` → z, `un autre [œ̃notʀ]` → n, `des huîtres [dezɥitʀ]` → z. A kept space means no link:
   `un haricot [œ̃ˈaʀiko]` (h aspiré). Map ʀ → ʁ before comparing. 7 such examples are in the sound tables (`une histoire [ynistwaʀ]`, `mes affaires [mezafɛʀ]` …), plus the T5/T6 lesson lines.
2. **Status** comes from the T6 lesson titles: Mandatory → `obligatory` (`des hôtels`, `en Angleterre`, `Elles aiment`), Optional → `optional`
   (`des entrées offertes`, `On mangeait ensemble`), Prohibited → `null` (`Le vin est blanc`, `L’appartement est`, `Un plat et un dessert`).
   Enchaînements → `enchainement` (`une orange`, `Elle a été`, `Il est parti par amour`). Liaison sounds come from the T6 rows: `les amis` z,
   `un petit arbre` / `un grand écrivain` t (d → t), `un endroit` n, `mon premier amour` ʁ, `trop épicé` p. These are hand-checked (item 8 above).
3. **Mute e and syllables (frSyllables)**: syllable count = vowel nuclei in her IPA (semi-vowels j ɥ w excluded), for all 117 examples. The [ə] rows give
   labelled cases: mandatory (`mercredi`, `l’enregistrement`), optional (`rapidement`, `une chemise`: both counts accepted), silent final
   (`les fromages`, `une voiture`). Plus the T5 sentences: `petite` mute, and `Je ne me maquille que le dimanche`.
4. **Nasals and denasalisation**: [ɑ̃ œ̃ ɛ̃ ɔ̃] rows (spelling → nasal), `un brun`/`une brune`, `un ami` (denasal false, already a known answer).
5. Expect some disagreements to be prosody.js bugs and some to be book choices. Report them; don't fix the rules to match the book blindly.

### (b) Calibrating on clean native speech (≈ 1–1.5 days)

1. Stream each clip from R2 (`r2aws s3 cp …m4a -`), decode with ffmpeg to 16-bit PCM on a pipe, and run Recense's `Features` pass
   (recense/main.swift ~3805: per 10 ms db, onset, pitch MIDI×100, clarity, voiced). This needs a headless entry point, either a CLI flag or a
   small Swift target that reuses `Features`; check whether one exists first. Write `features/<hash>.json` to R2, not to disk.
2. Checks:
   - Pitch: T4 clips are labelled declarative (expect a falling final contour) or question (expect a rising one).
   - The vowel clips should show steady f0 inside each vowel.
   - Loudness and voiced: tune `floor` on clean, un-separated speech. Two-word rows should give two voiced stretches; T10 vocabulary lists one per word.
   - Timing: word starts against Groq word timings on the same clips. They are short, so this is cheap.
3. Feed one T6 clip into the opus-lane prototype in place of the synthesized `fr-speech` clip. Liaisons are then drawn on real speech
   whose expected links come from (a).
