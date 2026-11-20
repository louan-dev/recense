# Audio coordination: agy and Claude

How agy (extra eyes and ears) and Claude split audio work in Recense.
Governed by `docs/law/regulations.md`, Rules 13 and 40. Evidence is `docs/AGENT-LIMITS.md`; where a clause rests on that file it says so.
Labels: **proven**, **inferred**, **untested**.

## 1 · Principle

**No agent owns timing.** Timing is measured by deterministic on-device code against a number in a spec. Agents watch, hear, label and cross-check; they write the harness that measures.

Why, **proven**:
- agy's own canary says it cannot resolve below 1-second buckets (about ±0.3 to 0.5 s). The limit is 30 ms (`docs/specs/FEAT-04-exact-time-sync.md:32`). That is more than 10 times coarser (`docs/AGENT-LIMITS.md`, section 1).
- A deterministic probe already anchors words: `reviews/align-probe` (local, `~/.claude/context/recense/reviews/`) anchored 97.5% of a lecture, longest gap 3.6 s (context INDEX, 2026-11-12).

## 2 · Strengths and weaknesses

### agy
Strengths, **proven**:
- Watches and listens to long recordings: 25 of 25 media items, including 2.15 GB and 985 MB captures.
- Labels what it perceives as `seen`, `heard` or `guessed` (418, 50, 65 labels across 25 evidence files).
- Transcribes lyrics in two languages with timestamps at second grain (evidence 018).
Weaknesses, **proven**:
- Time resolution about 1 s.
- Quota: exhausted twice in 9 days; one lane resumed 135 times.
- Classification: 25 of 25 triage entries landed in Area "Other".
- Writes into the main checkout when its worktree is gone.
Not tested: context and tool ceilings; any claim about Vietnamese tone accuracy (no measurement found).

### Claude
Strengths, **proven**:
- Reads a code cluster end to end with line citations (this audit, `docs/GENETIC-MAP.md`).
- Swift and architecture; test harnesses; the ShowsKit, `shared/` and `strip/` work (266 commits carry a Claude trailer, a lower bound, `docs/AGENT-LIMITS.md` section 3).
Weaknesses, **proven**:
- Cannot hear or watch media by itself. Anything about sound or picture comes from a harness or from agy.
- Usage limits: 87 LIMITED lines on its worst day (`docs/AGENT-LIMITS.md`, section 3).

## 3 · Who does what, by domain

Each domain: the deterministic owner, then agy, then Claude, effort, and the proof bar.

### Transcription and code-switching
- Owner in code: Mac `strip/speech.swift` (merges the runner-up phrase by phrase), open ears `strip/openears.swift`; iOS `shared/speechcore.swift` (one language per 120 s stretch). Detail and drift: `docs/GENETIC-MAP.md`, C6.
- agy: hears a recording and labels each stretch with its language; marks code-switch points as `heard` or `guessed`.
- Claude: writes the harness that compares the engine's words and language tags to agy's labels and to known text; fixes Swift.
- Effort: `xhigh` for a cross-platform change (Mac merges per phrase; iOS does not), `high` for a bounded fix.
- Bar: the Mac's file transcript on the same recording (`docs/specs/bugs/BUG-24-mobile-light-word-only.md`).
- Drift to cure first: dropped `Word.lang` (`mobile/HostApp/iOS/Ears.swift:130-135`).

### Translation and multilingual work
- Owner in code: `shared/translateplan.swift`, `shared/ShowsKit/Sources/ShowsKit/Langs.swift`.
- agy: second-language reader for a sample; flags a wrong or flat translation. Labelled `heard` or `guessed`.
- Claude: the plan, the language lists, the vector tests (Map C6).
- Effort: `high`.
- Bar: a vector test pinned in Swift and JS.

### Syllable timing and prosody
- Owner in code: `library/src/client/prosody.js` (one implementation), Cadence (`library/src/client/cadence.js` with `shared/ShowsKit/Sources/ShowsKit/Cadence/`), `reviews/align-probe`.
- agy: **none on the number.** It may watch a lit playback and say "feels early" as a `heard` label.
- Claude: the measurement harness and the fix.
- Effort: `xhigh`.
- Bar: the limit in `docs/specs/FEAT-04-exact-time-sync.md:32` and `docs/specs/FEAT-20-prosody-on-ios.md:23`. No code constant implements it today, so the first task is a measurement, on the device (**untested**).

### Beat tracing and pronunciation
- Owner in code: `keep/<key>/features.json` (voiced, onset, pitch every 10 ms of the vocal stem; described in `library/src/client/cadence.js:1-6`). Voices: Kokoro for English and French, VieNeu v3 Turbo for Southern Vietnamese (coordinator precedent; the owner rejects monotone voices).
- agy: listens to a voice sample and labels naturalness and pronunciation as `heard`. A person's ear overrules it.
- Claude: wiring and tests; never judges the sound itself.
- Effort: `high`. Bar: the owner listens; no claim of better comprehension until tested (`docs/law/interaction.md:36-44`).
- Not available: an acoustic aligner (`shared/fingerprint.swift`, 93% nil at 10 dB SNR, coordinator precedent 2026-11-16).

### Legal and casual dictation
- Owner in code: the Draftpad editor (`editor/src/legal.js`) and `shared/voiceappend.swift`, hosted by `strip/editorhost.swift` and `mobile/HostApp/iOS/Draftpad.swift`.
- agy: hears legal dictation (en, fr, vi mixed) and lists the terms the engine got wrong.
- Claude: the rule that corrects them; both hosts receive it (Treaty Article 4).
- Effort: `high`. Bar: the owner's own words are never rewritten; generated text says "added".

### Custom audio rules and slang databases
- Owner in code: `strip/canon.swift` (recited texts), `datasets/`, and the pronunciation and glossary files under `keep/<key>/` (`strip/recense.swift:5417-5442`).
- agy: proposes entries from what it heard, each marked `heard` or `guessed`, with the clip location.
- Claude: stores them in one place and refuses an entry without its source (owner rule: generated text cites its source or says "added").
- Effort: `high`. Bar: every entry cites a clip or a person; no unsourced entry.

## 4 · How a pair runs

1. The owner or Claude writes a task into the agy lane's `INBOX.md` (agy cannot receive `SendMessage`).
2. agy works in its own worktree, text only; media stays in Gallery.
3. agy's findings come back as an evidence file under `.handoff/agy-watch/` with labels.
4. Claude turns labels into a test, fixes the code, and posts READY FOR REVIEW (Rule 10).
5. The sealed-key canary keeps agy honest: a clip with a hidden answer, checked after the run (`.handoff/agy-watch/evidence/`, local).
6. A usage limit on either side: the lane's `## Resume here` carries on (Rule 20).
