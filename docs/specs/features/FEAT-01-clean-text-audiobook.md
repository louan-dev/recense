# FEAT-01 · Clean text → chaptered audiobook
From: owner 2026-11-12 ("make a universal rule format for all digital text to run through clean and with chapters").
Study tool P2 (PLAYBOOK §3). Status `[~]`.

## Rule
Every digital text (PDF, TXT, later EPUB/DOCX/HTML) runs through one engine and one rule format.
Output: a reading copy (`clean.md`) and a voice copy (`speech.md`); headings become chapters.

## Format: TOML profiles in `text/rules/`
- `base.toml` applies to all text; a source profile `extends` it (e.g. `mpep.toml`).
- `[meta]`: `name`, `extends`, `lang`, `columns`, `top_band_pt`, `skip_leading_toc`.
- `[[rule]]`: `id`, `stage`, `match` (Python regex), `action`, `with`, `why`.
- Stages, in order:
  - `page`: one line at a time (headers, footers, folios).
  - `heading`: `#` chapter, `##` section; extras `until`, `join_next`.
  - `reflow`: engine step; joins hyphenated words and wrapped lines.
  - `text`: edits the reading copy; citations stay exact.
  - `speech`: edits the voice copy only.
- Actions: `drop`, `replace`, `heading`, `say` (`how` = `section` | `decimal`).

## Invariants (checks)
1. **No content loss:** word diff raw → `clean.md` drops only page furniture and the TOC; 0 words added.
2. Each numbered section in the source's TOC appears once as a heading, in order.
3. `test_rules.py`: pronunciation cases pass (e.g. `§ 1901.07(a)` → "section nineteen oh-one point oh seven a").
4. M4B chapter count = heading count (ffprobe).

## Voice
Kokoro-82M ONNX (`af_heart`), fully offline. Setup-only download: GitHub release
`thewh1teagle/kokoro-onnx` model-files-v1.0:
- `kokoro-v1.0.onnx` sha256 `7d5df8ec…3636a6c5`;
- `voices-v1.0.bin` sha256 `bca610b8…1fbf7d`.

## Open
- Per-word timings: Kokoro-ONNX gives sentence-level timing only; P2 asks for timings from TTS.
  Option: forced alignment of TTS audio against `speech.md` (same engine as P1).
- Vietnamese/French profiles and voices (PLAYBOOK §3 voice line).
