# Translation pipeline (Recense, Gallery)

Source of truth: `recense/recense.swift` on `claude/exciting-lumiere-9b0e58` (the standalone Recense copy, then `sill/recense/main.swift`, has since been deleted).

## Services and endpoints
| Step | Service | Endpoint / code |
|---|---|---|
| Transcription (original) | Groq Whisper | `https://api.groq.com/openai/v1/audio/transcriptions` (`cfg.base`) |
| English, Vietnamese, French | Groq chat, JSON mode, temperature 0 | `POST {cfg.base}/chat/completions` via `chatJSON` / `translateBatch` |
| Models (rotated on 429 / bad JSON) | `qwen/qwen3.8-27b`, `openai/gpt-oss-20b`, `openai/gpt-oss-120b` | `Models.pick()`, `Models.cool(model, s)` |
| Fallback when every model is cooling | Apple Translation (macOS 15+, on device) | `translateOnDevice` / `OnDevice`; lines marked `draft`, redone by a model later |
| Line reuse | local memory of translated lines | `Library.recall/remember` (`translations.json`) |
| Storage | R2 bucket `recense-tmp` | `keep/<key>/asr.json`, `keep/<key>/tr/{en,vi,fr}.json`, `corrections.json` |
| Gallery read | Worker `src/transcript.js` | `GET .../transcript` → lines with `en` + `tr.{vi,fr}`; `POST .../transcript/run` writes `keep/locks/<key>` |

## Order of work (`Episode.translateLoop`)
1. **Listener's language first near the playhead (new, P3 #5).** If `NativeLang.current` is vi/fr and a line in the next 60 s lacks it (`nativeBehind`), `nativeStep` runs before any English.
2. English for lines about to be heard, then the rest, then redo of on-device drafts.
3. vi/fr for the rest of the transcript (native language first), translated **from the original**, not from English. A line already in the target language is stored `same: true`.
4. Each translation is keyed by segment id with `src` = the words it was made from; a line remade or corrected drops its translation.

## Display rule
Window and Gallery show the listener's language per line where `tr/<lang>` has a matching `src`, **else the English**. That fallback is why a slow vi/fr queue showed as "drifting to English mid-track" (P3 #5): before the fix vi/fr only started once English had nothing left to do, so under Groq quota they fell behind the playhead.

## Retranscribe (P3 #6, #9)
Gallery `POST transcript/run {retranscribe:true, lang}` → lock `{state, redo, lang}`. Recense `GalleryJob.serve` takes it every minute while idle; if the file is the one playing (Gallery open on it), the playing episode is restarted from nothing (`restartFresh`) and the lock follows it (previously it waited for idle forever). A redo also sets aside local vi/fr (`setAsideTranslations`) so it retranslates.

## Known gaps
- `lang` is stored in the lock but Recense still orders vi/fr by its own `NativeLang.current`.
- Remembered English lines (`Library.recall`) are reused even on Retranscribe.
- R2 copies of old vi/fr stay until the new complete files replace them.
