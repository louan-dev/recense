# FEAT-35 · Rhythm: texture, tempo sync and the drum track
From: owner 2026-11-18 (wish 8; PLAN-1118 §11c "Rhythmic texturization + tempo sync"; drums mandatory, owner 2026-11-18).
Status: `[ ]` written, P0 spike first.
Builds on: FEAT-01 (rules, voices, `shared/m4b/`). Uses, never edits: `cadence.js`, ShowsKit `Cadence` (Stream B, PLAN-1118 §12b).

## Verdict first
- **Rule:** every narration Recense renders from text has three layers of rhythm.
  - Texture: pauses and pace set by the text's structure.
  - Tempo: each phrase starts on a beat of one chosen tempo.
  - Drums: a drum setting that every narration carries, always.
- **The drum setting is data, never audio.** Each device plays the drums itself, offline.
- **The listener can turn the drums to level 0.** The setting itself never disappears.

## Terms (defined once)
- **Phrase:** the unit rendered alone. One sentence, one heading, one list item or one block quote.
- **BPM:** beats per minute. Beat period `T = 60 / BPM` seconds.
- **Quantum `q`:** half a beat, `q = T / 2`. Every phrase onset and end sits on a multiple of `q`.
- **Bar:** 4 beats in v1 (assumed; every v1 pattern is in 4).
- **Content clock:** seconds into the narration's audio, never the wall clock (the rule `Word.start` already follows, proven `shared/ShowsKit/Sources/ShowsKit/Word.swift:4`).
- **Narration:** one rendered M4B in the Audiobooks home with its sidecars (FEAT-01 A3).
- **Series:** every narration of the same source. Re-renders join the series and share its drum setting.

## Premises checked against the code (main 87bd9f9, 2026-11-18)
- **proven** Today's renderer uses fixed gaps: 450 ms between paragraphs, 1,200 ms between chapters (`text/audiobook.py:36`).
- **proven** Kokoro takes a `speed` argument; today it is always 1.0 (`text/audiobook.py:44`).
- **proven** Kokoro renders at 24,000 Hz (`text/audiobook.py:34`).
- **proven** Speech lines have ids under 2,000,000. Both Cadence copies leave them as heard and never realign their words (`shared/ShowsKit/Sources/ShowsKit/Cadence/Cadence.swift:34`, `CadenceAlign.swift:129`; `library/src/client/cadence.js:177`, `:187`, `:454`).
- **proven** `Line` holds timed `Word`s; one Codable shape for the Mac and iOS (`shared/transcript.swift:23`).
- **proven** Carry line-merges `.jsonl` files: two devices' lines are both kept (`shared/carrysync.swift:51-53`).
- **proven** FEAT-08's `mergeMatter` rebuilds the sidecar as `{version, passages, log}` and drops any other top-level key (`editor/src/matter.js:675-696`).
  - So a drum setting stored inside `draftpad.matter.json` would vanish at the first two-device merge.
- **proven** The one export queue exists: `ExportGate`, one export at a time (`shared/exportjobs.swift:56`, BUG-33).
- **proven** The ears env lives at `~/.local/share/recense/omni` (Python 3.10; `strip/openears.swift:14`).
- **proven** No debug-channel writer exists yet: no code writes `~/Recense/logs/`, and the folder is absent (checked 2026-11-18).
- **stated, not re-checked** Kokoro-ONNX gives sentence-level timing only (FEAT-01 "Open").
- **assumed, untested** hexgrad's PyTorch `kokoro` pipeline returns per-word start and end times for English.

## One home
- **Home: `shared/voice/`.** It holds the fit, the drum synthesizer, the drum patterns and the setting store.
  - Why: Swift that both apps compile lives in `shared/` (`.claude/CLAUDE.md` § Parity). The Mac renders; iPhone and iPad play and mix.
- **Texture data: `text/rules/*.toml` → `text/rules.json`** (FEAT-01 A1). Pauses are rule data, not code.
- **Mix into the export: `shared/m4b/`** (FEAT-01 A3). The drums enter the M4B there, nowhere else.
- **Web twin (P6 only): `library/src/client/drums.js`.**
  - A second copy of the synthesizer, kept because the browser cannot run Swift.
  - Pinned by one fixture, `shared/voice/drums-cases.json`. Registered as a gap in PARITY.md.
- Files (proposed names):
  - `shared/voice/Tempo.swift` — the fit and the BPM pick.
  - `shared/voice/Drums.swift` — the synthesizer.
  - `shared/voice/Rhythm.swift` — the setting record and its store.
  - `shared/voice/drums.json` — the patterns (data).
  - `shared/voice/drums-cases.json` — the fixture both synthesizers pass.

## Embodiments
- **Mac:** renders, fits, plays live drums, mixes the export, re-times on a tempo change.
- **iPhone:** plays the carried narration with live drums; all three controls; mixes the export (M4BWriter).
- **iPad:** the same as iPhone.
- **Web:** P6. Until then it plays the Mac's mixed export (drums at the level set at export time).

## T · Texture (the rules' `speech` stage)
### Format (added to FEAT-01's rule format)
- New table `[[texture]]` in `base.toml`; a profile may override a row by `structure`.
  - Keys: `structure`, `before_ms`, `after_ms`, `rate`, `boundary`.
  - `boundary` is one of `bar`, `beat`, `quantum`, `none`.
- New optional key on `[[rule]]`: `texture = "citation" | "quote" | "url"`.
  - When that rule fires inside a phrase, the phrase takes that texture's `rate`.
- Inline textures (`citation`, `quote`, `url`) set a rate only. Their `before_ms` and `after_ms` must be 0; the compiler rejects others.

### Initial values (all **assumed**, tuned at the voice gate, FEAT-01 A6)
- **Chapter heading (`#`):** before 1,200 ms · after 800 ms · rate 0.92 · boundary `bar`.
  - 1,200 ms is today's chapter gap (proven, `text/audiobook.py:36`).
- **Section heading (`##`):** before 900 ms · after 600 ms · rate 0.95 · boundary `beat`.
- **Paragraph end:** after 450 ms · rate 1.00 · boundary `beat`.
  - 450 ms is today's paragraph gap (proven, same line).
- **List item:** before 150 ms · after 350 ms · rate 0.97 · boundary `beat`.
- **Block quote (`>`):** before 300 ms · after 300 ms · rate 0.95 · boundary `beat`.
- **Sentence end, inside a paragraph:** after 250 ms · rate 1.00 · boundary `quantum`.
- **Clause split** (a sentence over 400 characters cut at `;`, `:` or `,` nearest its middle): after 120 ms · rate 1.00 · boundary `quantum`.
  - 400 characters is today's chunk limit (proven, `text/audiobook.py:28`).
- **Citation, inline:** rate 0.90.
- **Quote, inline:** rate 0.97.
- **URL read as "(link)":** rate 1.00.

### Rules of combination
- A phrase's target rate `ρ_i` = the smallest rate among the structures it holds. The slowest wins: legibility first.
- The gap after phrase `i`: `g_i = max(after_ms of i, before_ms of i+1) / 1000` seconds. Never the sum.
- The boundary class after phrase `i` = the stronger of the two rows' `boundary`, in the order `bar` > `beat` > `quantum`.

### Phrase splitting
- Split at `.`, `!`, `?`, `…` followed by whitespace, at a heading line, a list item and a block quote.
- Never split after a token in the profile's `[meta] no_break` list (e.g. `U.S.`, `C.F.R.`, `M.P.E.P.`, `No.`, `art.`).
- One splitter per runtime (Python, Swift, JS), pinned by `text/cases.tsv` rows with direction `phrases` (FEAT-01 A1).
  - Expected output: the phrases joined by ` | `.

## F · Tempo fit (the algorithm)
### Inputs
- Phrases `i = 1..N` in reading order, each with: text, language, `ρ_i`, `g_i`, boundary class.
- `d_i`: the speech-only duration of phrase `i`, rendered alone at speed 1.0.
  - Trim: drop leading and trailing 10 ms frames whose RMS is below the phrase's peak frame RMS − 40 dB (assumed threshold).
- `B`: tempo in BPM (integer). `T = 60 / B`. `q = T / 2`.
- Bounds: `s_min = 0.85`, `s_max = 1.15` (owner, PLAN-1118 §11c).
  - Speed `s > 1` is faster. Rendered duration = `d / s`.
- Bar `M = 4` beats. Grid origin `t0 = 0`.

### Outputs, per phrase
- `a_i` onset (content clock, seconds) · `k_i` length in quanta · `s_i` speed · `r_i` residual silence (seconds) · `e_i = a_i + k_i·q` slot end.

### Equations
1. **Lead-in:** `a_1 = M·T`. One bar of drums before the first word, so the start is predictable.
2. **Feasible lengths:** `K_i = { k ∈ ℤ, k ≥ 1 : s_min ≤ d_i / (k·q) ≤ s_max }`.
   - Equivalently, the integers in `[ d_i / (s_max·q) , d_i / (s_min·q) ]`.
3. **When `K_i` is not empty:**
   - `k_i = argmin over k ∈ K_i of | ln(d_i / (k·q)) − ln ρ_i |`.
   - Tie: the larger `k` (slower, calmer).
   - `s_i = d_i / (k_i·q)`. `r_i = 0`.
4. **When `K_i` is empty (failure: out of range):**
   - It can happen only when `d_i < q / (1/s_min − 1/s_max) ≈ 3.258·q ≈ 1.63·T`.
   - `k_i = ⌈ d_i / (s_min·q) ⌉`. `s_i = s_min`.
   - `r_i = k_i·q − d_i / s_min`. Proven by the ceiling: `0 < r_i < q`.
   - The residual is silence after the speech. The slot still ends on the grid, so the next onset stays on it.
   - Log `rhythm.fit_miss`.
5. **Next onset**, by the boundary class after phrase `i`:
   - `quantum`: `a_{i+1} = e_i + n_i·q`, with `n_i = max(1, ⌊ g_i/q + 1/2 ⌋)`.
   - `beat`: `a_{i+1} = T · ⌈ (e_i + max(g_i, q)) / T ⌉`.
   - `bar`: `a_{i+1} = M·T · ⌈ (e_i + max(g_i, q)) / (M·T) ⌉`. Every chapter starts on a downbeat.
6. **Words:** a word timed `(u, v)` inside the trimmed phrase render at speed 1.0 becomes
   - `Word.start = a_i + u / s_i` and `Word.end = a_i + v / s_i`.
   - When the times come from the render at `s_i` itself: `a_i + u` and `a_i + v`.
7. **End of narration:** the drums stop at the end of the bar that holds `e_N`.

### Default BPM (from the narration's pace)
- Pace `P = 60 · W / Σ d_i` words a minute, where `W` = words in the speech copy.
- Start: `B0 = clamp(round(P / 2), 60, 100)`. One beat per two words. Range assumed: calm, near a resting heart rate.
- Search `B ∈ {B0 − 8 … B0 + 8} ∩ [60, 100]`, integers.
- `cost(B) = (1/N)·Σ_i | ln(s_i(B) / ρ_i) | + misses(B) / N`.
- Pick the lowest cost. Tie: nearer `B0`, then the smaller `B`.
- `d_i` does not depend on `B`, so the search is arithmetic only: no re-render.
- A listener's BPM (`bpmAuto = false`) skips the search. Its range: 50 to 140 (assumed).

### Applying the speed
- Backend with native speed (Kokoro: proven argument): render phrase `i` again at `s_i`, trim, measure `d'_i`.
  - If `| d'_i − (k_i·q − r_i) | > 10 ms`: time-stretch by `c_i = d'_i / (k_i·q − r_i)`.
  - Stretch: `AVAudioUnitTimePitch` in offline manual rendering (Apple, on device, pitch kept).
  - `| ln c_i | > ln 1.05` logs `rhythm.stretch_large` (assumed limit).
- Backend without native speed (VieNeu: untested): time-stretch the speed-1.0 render by `s_i`.
- Which path sounds better is a P0 question, judged by agy.

### The narration sidecar `<stem>.narration.json` (schema v1)
- `v`: 1.
- `series`: 12 lowercase hex characters, minted at the first render of a source.
- `source`: `{ "home": <Home rawValue>, "path": <relative path>, "sha256": <hex of the source bytes> }`.
- `made`: ISO 8601 UTC with milliseconds. `dev`: the rendering device's carry id.
- `render`: `{ "bpm": int, "auto": bool, "q": seconds, "bar": 4, "lead": seconds, "voiceRms": dBFS }`.
- `voices`: `[{ "lang", "backend", "voice" }]`.
- `phrases`: `[{ "i", "line", "a", "k", "s", "r", "d", "struct", "rate" }]`.
- `chapters`: `[{ "title", "a" }]`.
- It holds no document words beyond chapter titles.

### Words into the light (Line/Word, unchanged)
- One `Line` per phrase. Ids `1 … N`, always under 2,000,000 (speech).
- Its `Word`s carry the fitted times (equation 6) and the phrase's language in `lang`.
- `english`: `[]` when the line is English. Otherwise left out, so FEAT-10 translates it like any transcript (assumed consistent with FEAT-10).
- Written as the narration's transcript in `keep/<key>.v2.json`, key = the M4B's fingerprint. The same place every recording's transcript lives.
- **Hard rule: this stream never edits `cadence.js` or ShowsKit `Cadence`.** The light runs on narration because the ids say "speech".
- Word-time sources, in order:
  1. The backend's own timestamps (P0 decides which backends give them).
  2. Fallback, the ears on the rendered audio: Apple SpeechAnalyzer (`strip/speech.swift`) for en and fr; Omnilingual (`strip/openears.swift`) for vi.
     - The text is known, so the recognized words are aligned to it by edit distance.
     - A word with no match takes times interpolated between its neighbours by character count.

## D · The drum track (mandatory, owner 2026-11-18)
### The setting record: `library/Audiobooks/rhythm-<series>.jsonl`
- **Where:** in the Audiobooks home, beside the narrations, one file per series.
  - Why not inside `draftpad.matter.json`: `mergeMatter` drops unknown keys (proven, above).
  - Why not `<stem>.rhythm.jsonl`: a re-render makes a new stem, and the setting must outlive it.
  - Why not beside the source: Recense writes nothing into the owner's source folders (Legal, the vault).
- **Format:** JSON Lines, UTF-8, append-only. One line per committed change.
- **Line schema v1** (every key required):
  - `v`: 1.
  - `t`: milliseconds since the Unix epoch (integer). Orders edits only; never a media time.
  - `dev`: the writing device's carry id (string).
  - `pattern`: an id in `shared/voice/drums.json`.
  - `bpm`: integer, 50 to 140. With `bpmAuto = true` it records the derived value at write time and binds nothing.
  - `bpmAuto`: boolean. `true` = follow the narration's pace.
  - `level`: integer, 0 to 100. 0 = silent.
  - `prev`: integer, 1 to 100. The level "Drums on" restores.
- Example:
  - `{"v":1,"t":1763481600000,"dev":"mac-1","pattern":"pulse","bpm":76,"bpmAuto":true,"level":40,"prev":40}`
- **Current setting:** the valid line with the greatest `t`; tie: the greater `dev` in byte order.
- **Invalid line** (bad JSON, `v` > 1, a value out of range): skipped, logged `rhythm.record_skip`, never deleted or rewritten.
- **Unknown pattern id:** the line stays valid. Playback uses `pulse`; the control says "This pattern isn't on this device: Pulse plays".
- **No valid line:** the defaults apply. `pulse`, `bpmAuto = true`, `level = 40`, `prev = 40` (level assumed).
  - The defaults are shown as the setting. Nothing is written until the listener changes something.
- **Writes:** one line per committed change (button press, menu pick, voice command, slider release).
  - Changes on one device within 1,000 ms collapse into the last one (assumed).
- **Sync:** carry line-merges `.jsonl` (proven). Two devices that both change it offline keep both lines; the latest wins everywhere.
- **Lifetime:** no control deletes the setting. The file goes only with its series, through FEAT-29's Trash, never at once.

### Patterns: `shared/voice/drums.json` (data; v1 values **assumed**, the owner picks by taste)
- Shape: `[{ "id", "label": {"en","fr","vi"}, "beatsPerBar": 4, "hits": [{ "at": beat in the bar, "voice", "vel": 0–1 }] }]`.
- `pulse` (default): `low` on every beat, vel 0.8.
- `heart`: `low` on every beat, vel 0.8, and `low` at +0.3 beat, vel 0.45.
- `walk`: `low` on beats 1 and 3, `brush` on beats 2 and 4.
- `frame`: `low` on 1, `mid` on 3, `brush` on 4.5.
- No cymbals and no hi-hats in v1: bright transients are the likeliest to overload (assumed).

### Synthesis: `shared/voice/Drums.swift` (values **assumed**, judged by agy and the owner)
- `low`: sine sweeping `55 + 40·e^(−t/0.03)` Hz; attack 5 ms linear; decay `e^(−t/0.18)`; 600 ms long.
- `mid`: sine 120 Hz plus its second harmonic at 0.3; attack 5 ms; decay `e^(−t/0.09)`; 300 ms long.
- `brush`: white noise from a fixed-seed generator, band-passed 1.5–5 kHz; attack 5 ms; decay `e^(−t/0.05)`; 200 ms long.
- Everything low-passed at 6 kHz. Attacks never shorter than 5 ms.
- Hit `m` of the grid starts at sample `round(t_m · sampleRate)`. Deterministic: the same input gives the same samples.
- **Level → gain:** drum RMS over one bar = `voiceRms + (0.4·level − 40)` dB, for level 1 to 100.
  - Level 100 = as loud as the voice; level 50 = 20 dB under it; level 40 (default) = 24 dB under it.
  - Level 0 = no drum samples at all.

### Live playback (every device)
- The drums run on the narration's content clock, never the wall clock.
- They play at `render.bpm` of the narration being played.
- The player's own speed control scales voice and drums together. Speed and tempo are two functions with two controls.
- Pause stops the drums. Seek resumes them at the right phase at once.
- If the drums cannot share the narration's audio engine, they re-anchor at every seek, rate change and phrase onset.
- Level changes ramp linearly over 200 ms. A pattern change waits for the next bar line.
- **A tempo change** (BPM or "Match the voice"):
  - The Mac re-times the series in `ExportGate`: re-fit, then a new narration under a free name.
  - The old narration moves to Trash only after the new one is written and checked (chapter count and duration).
  - iPhone, iPad and web save the change; the Mac re-times when carry brings it (catch-up).
  - Until then the drums keep `render.bpm`, so they stay aligned.
  - The control says: "Tempo 80 · plays at 76 until the Mac re-times it."

### The export mixes the drums in (`shared/m4b/`)
- "Export audiobook…" (a copy for other apps) mixes voice + drums at the current setting.
- `mix = voice + gain·drums`. If the peak exceeds −1 dBFS, the whole mix is scaled down. No limiter: deterministic.
- Level 0: no drum samples are added.
- The narration in the Audiobooks home stays voice-only. Inside Recense the drums are always live, so the level stays adjustable.

### The visible control for each parameter (never a gesture alone)
- **Entry:** a "Drums" button in the narration player's controls, labelled with the level ("Drums 40").
  - Also in the player's ··· menu: "Drums ▸". Mac, iPhone, iPad, web.
- **Pattern:**
  - Button: the Drums sheet lists the patterns vertically; one tap picks; the current one is checked.
  - Menu: "Drums ▸ Pattern ▸ <name>".
  - Voice: "drums pattern <name>".
- **Tempo:**
  - Buttons: "Slower" and "Faster" (−2 / +2 BPM), the number between them.
  - Button: "Match the voice" (sets `bpmAuto = true`).
  - Menu: "Drums ▸ Tempo ▸ Slower / Faster / Match the voice".
  - Voice: "drums slower", "drums faster", "drums match the voice".
- **Level:**
  - Buttons: "Softer" and "Louder" (−10 / +10), the number between them.
  - Button: "Off" (level 0). When the level is 0 it reads "On" and restores `prev`.
  - A slider as a speed-up. VoiceOver adjusts it by 10.
  - Menu: "Drums ▸ Level ▸ Softer / Louder / Off / On".
  - Voice: "drums softer", "drums louder", "drums off", "drums on".
- **Action ids** for FEAT-34's catalogue: `drums.pattern.<id>`, `drums.tempo.slower`, `drums.tempo.faster`, `drums.tempo.match`, `drums.level.softer`, `drums.level.louder`, `drums.off`, `drums.on`.
- French and Vietnamese voice phrases are data, written by agy and reviewed before they ship.

## Sensory and ADHD rules (binding)
- **Level 0 is always one step away:** the "Off" button, the menu item and the voice command.
- **Off never removes the setting.** The Drums button stays, showing "Drums 0".
- **Predictable:** the same pattern and tempo on every play; no randomness; chapters start on a downbeat.
- **No sudden change:** 200 ms level ramps; pattern changes at the bar line; no jumps in tempo mid-phrase.
- **Low clutter:** one Drums button; the sheet holds three rows (Pattern, Tempo, Level) and one "Done".
- **No visual beat:** nothing on screen pulses or flashes with the drums.
- **Motion:** the sheet opens with a 150 ms fade; with Reduce Motion, no animation at all.
- **Soft timbre:** attacks ≥ 5 ms; nothing above 6 kHz; no cymbals.

## Debug channel: `~/Recense/logs/rhythm.jsonl`
- iPhone and iPad: `Recense/logs/rhythm.jsonl` inside the app's container (assumed path).
- Writer: the shared JSONL writer from PLAN-1118 §11b (Stream B). Not built yet (proven above): P2 waits for it or logs nothing.
- Every event: `ts` (ISO 8601 UTC, ms), `dev`, `ev`.
- No event carries the document's words.
- Events:
  - `rhythm.fit` — `series`, `stem`, `bpm`, `auto`, `q`, `phrases`, `misses`, `meanAbsLn`, `sMin`, `sMax`, `ms`.
  - `rhythm.fit_miss` — `series`, `i`, `d_ms`, `k`, `r_ms`, `struct`.
  - `rhythm.bpm_pick` — `series`, `pace_wpm`, `b0`, `picked`, `cost`.
  - `rhythm.stretch_large` — `stem`, `i`, `c`.
  - `rhythm.words` — `stem`, `source` (`backend` | `ears-speechanalyzer` | `ears-omni`), `words`, `lines`, `matched`, `interpolated`.
  - `rhythm.onsets` — `stem`, `n`, `p95_ms`, `max_ms`, `pass` (written by the check tool).
  - `rhythm.setting` — `series`, `field`, `from`, `to`, `via` (`button` | `menu` | `voice` | `shortcut`).
  - `rhythm.record_skip` — `series`, `line_no`, `reason`.
  - `rhythm.synth` — `stem`, `pattern`, `bpm`, `level`, `event` (`start` | `stop` | `seek` | `rate`).
  - `rhythm.drift` — `stem`, `at_s`, `ms` (drums against the voice, at each phrase onset).
  - `rhythm.retime` — `series`, `from_bpm`, `to_bpm`, `old_stem`, `new_stem`, `ok`.
  - `rhythm.mix` — `stem`, `level`, `peak_dbfs`, `scaled_db`.

## Phases (each ships alone)
### P0 · Spike (throwaway, in a scratchpad; ships a decision)
- S0a: does `kokoro-onnx` expose per-token durations? Does hexgrad's `kokoro` give word times in en and fr?
- S0b: does VieNeu take a speed? Does it give word times?
- S0c: native speed against `AVAudioUnitTimePitch` at 0.85 and 1.15, 3 clips per language. agy judges blind.
- S0d: the ears fallback against Kokoro's own word times on 10 English clips.
- S0e: run each with the network blocked. Anything that fetches at run time fails the gate (misaki may fetch a spaCy model: assumed).
- **Gate:** this spec's premises updated with proven / untested results and the backend picks.

### P1 · Texture
- `[[texture]]` and the `texture` key in the TOML; compiled into `rules.json`.
- The phrase splitter in the three runtimes; `phrases` rows in `cases.tsv`.
- The render uses the texture's pauses and rates. No beat grid yet.
- **Ships:** narrations that breathe by structure, on every device through carry.
- **Checks:**
  - `cases.tsv` passes in Python, Swift and JS.
  - On the speed-1.0 render, every gap is within ±10 ms of its table value.

### P2 · Tempo fit and the light
- `Tempo.swift`; the assembly; `<stem>.narration.json`; the Lines in `keep/<key>.v2.json`.
- **Ships:** narrations whose phrases start on a beat; the light runs on them on the Mac and iOS.
- **Checks:**
  - Fit tests: a feasible phrase; an infeasible short phrase (`k = ⌈d/(s_min·q)⌉`, `s = 0.85`, `0 < r < q`); a tie (the larger `k`); a chapter onset on a bar start; a BPM pick.
  - Phrase onsets against `a_i`: every one within 10 ms on the assembled PCM; within 25 ms on the decoded M4B (assumed tolerances).
  - Speech ends: within 20 ms of `e_i − r_i` on the assembled PCM.
  - Every speed in `[0.85, 1.15]`.
  - Light: every narration line id < 2,000,000; a Cadence pass leaves its word times unchanged.

### P3 · Drums on the Mac
- `Rhythm.swift`, `Drums.swift`, `drums.json`; live drums; the Drums button, menu and voice; Mac re-time.
- **Ships:** drums under every narration on the Mac.
- **Checks:**
  - Record: absent file → defaults; two devices' offline lines merge, the latest wins; an invalid line is skipped and kept; level 0 keeps the control.
  - Synth: hit `m` starts at sample `round(t_m·sr)` exactly (0 samples error) offline.
  - Drift: drums against voice ≤ 20 ms at p95 over a 30-minute narration (assumed tolerance).

### P4 · iPhone and iPad
- Live drums on the carried narration; the same controls; tempo changes go to the Mac by carry.
- **Ships:** drums on both devices, offline.
- **Checks:** the P3 drift check on each device (from `rhythm.drift`).

### P5 · The export mixes the drums
- `shared/m4b/` mixes on the Mac and on iOS.
- **Checks:**
  - Decoded drum onsets within 2 ms of the grid.
  - Level 0: the mix minus the voice-only render is below −60 dBFS RMS.
  - `ffprobe` chapters unchanged.

### P6 · Web
- `library/src/client/drums.js` (Web Audio) passes `drums-cases.json`; the web player's controls.
- Offline web changes queue in the browser and reach the Mac when it is reachable (assumed, FEAT-33).

### Later, not promised: P7 · re-time on the device
- iPhone and iPad re-fit from the carried render, without the Mac. Stretch ratios up to `1.15/0.85`; quality untested.

## Judges
- **Code** measures onsets against the grid (the checks above).
- **agy** judges the feel from recordings: does each phrase land; is the drum level comfortable (PLAN-1118 §12f).
  - Request: `.claude/worktrees/agy/.handoff/agy/INBOX.md`; its verdict line goes into the merge-queue proof.
- **The owner** picks the voices and the patterns (taste).

## Device checks
- **Mac:**
  - Play a narration. The Drums button shows. Change pattern, tempo and level by button, by menu and by voice.
  - "Off": silence, and the button still reads "Drums 0". "On": the previous level returns.
  - Screenshot each state; run the UI audit (one control per function, no gesture-only path).
- **iPhone, through iPhone Mirroring, never the simulator:**
  - Airplane Mode on: Settings ▸ Airplane Mode.
  - Play a carried narration. The drums play. Softer, Louder, Off, On, a pattern change.
  - Tempo change: the honest "plays at … until the Mac re-times it" line shows.
  - Record the iPhone Mirroring window with sound; agy judges it.
- **iPad:** iPhone Mirroring cannot reach it.
  - The owner runs the iPhone steps on the iPad and records with Control Center ▸ Screen Recording (microphone on).
  - Then AirDrops the recording to the Mac for agy.
- **Web (P6):** Safari with Wi-Fi off on a pinned narration (FEAT-33); the drums play.

## Offline-first gate
- **At the moment of use: no outside service.**
  - Drums are synthesized on the device from `drums.json`, bundled in the app.
  - The fit is arithmetic. Playback reads local files.
  - Rendering runs on the Mac with models already installed (FEAT-01 A4).
- **Setup only:**
  - Nothing new beyond FEAT-01's voice models.
  - If P0 picks hexgrad's PyTorch `kokoro` for word times: PyPI `kokoro` and `misaki`, Hugging Face `hexgrad/Kokoro-82M`, and any spaCy model misaki needs.
    - Stored beside the ears env with source, size and sha256 (`TO FILL at install`).
    - Memory: one model in memory at a time on the 8 GB Mac (research note, 2026-11-08).
- **Reaching another device:**
  - The drum setting travels by carry (self-hosted, peer to peer, catch-up; never blocks playback).
  - A tempo change from iPhone, iPad or web waits for the Mac and never blocks listening.
- **Cloudflare, the Worker, R2, Groq:** none.

## Open questions
- Q1 (decided 2026-11-18: accepted as written) (coordinator): the setting lives in `library/Audiobooks/rhythm-<series>.jsonl`, not in FEAT-08's `draftpad.matter.json` (see D). Fold it into the matter sidecar once `mergeMatter` keeps unknown keys?
- Q2 (decided 2026-11-18 by coordinator 821ba9ec, owner may overrule: default 40, level 0 one tap away) (owner, taste): the default level, 40 (24 dB under the voice). Or 0 until first turned on?
- Q3 (decided 2026-11-18 by coordinator 821ba9ec: YES, a quiet-day switch) (owner): a global "quiet day" switch that silences every narration without changing any item's setting?
- Q4 (decided 2026-11-18: yes; request to Stream B, owner of shared/carry/) (coordinator): does carry carry `library/Audiobooks/` to iPhone and iPad? Assumed from PLAN-1118 §5k step 6 and FEAT-22.

## Registry block (for PARITY.md)
```
<!-- parity:begin rhythm -->
feature: rhythm · texture, tempo sync, mandatory drum track (FEAT-35)
home: shared/voice/ (Tempo.swift, Drums.swift, Rhythm.swift, drums.json, drums-cases.json); texture data text/rules/*.toml → text/rules.json; mix shared/m4b/
symbols: Tempo.fit, Tempo.pickBpm, Drums.render, RhythmRecord, RhythmStore.current
embodiments: [ ] mac · [ ] iphone · [ ] ipad · [ ] web (P6)
events: rhythm.fit, rhythm.fit_miss, rhythm.bpm_pick, rhythm.stretch_large, rhythm.words, rhythm.onsets, rhythm.setting, rhythm.record_skip, rhythm.synth, rhythm.drift, rhythm.retime, rhythm.mix
spec: docs/specs/FEAT-35-rhythm-and-drums.md
check (proposed, not yet run): strip/recense selftest rhythm
check (proposed, not yet run): python3 -I text/test_rules.py (phrases rows of text/cases.tsv)
device: Mac: drums play; Off keeps "Drums 0"; every parameter by button, menu, voice
device: iPhone (iPhone Mirroring, Airplane Mode): narration + drums offline; level 0; pattern change
device: iPad (owner's screen recording): the iPhone steps
gaps: web plays the Mac's mixed export until P6; web drums.js is a pinned twin of Drums.swift; a tempo change on iPhone, iPad or web waits for the Mac (P7 not promised)
<!-- parity:end -->
```
