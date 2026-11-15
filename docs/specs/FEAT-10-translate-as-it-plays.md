# FEAT-10 · Translate the transcript as it plays (English, Tiếng Việt, Français), on the device

From: T-0068 (owner, 2026-11-14: "there isnt a way to translate the transcription as it plays in the original
language for vietnamese, frenc, english") · Status: `[~]` (iOS built; Mac with the library window, FEAT plan Phase 3)

## Why
For self-study the owner reads each line in its own language with its translation under it, while it plays.
The player's transcript view already draws a translation under a line (`TranscriptLine.translation`), but only
the Mac's English ones ever arrive; a file heard on the iPhone has none.

## What it does
- The transcript's menu (Transcript options) has one control, **Translate Into**: Automatic · English ·
  Tiếng Việt · Français · Off. It replaces "Show Translation" where it appears (one control per function).
  The choice is kept on the device (`recense.translateInto`, default Automatic).
- Each line's language is found on its own (Apple's NaturalLanguage, limited to en / vi / fr; a line too short to
  tell takes the language the file is heard in), because one lecture mixes the three.
- Its target: the choice; **Automatic** = English → Tiếng Việt, anything else → English (the rule
  `RecenseText.target` already uses). A line already in the target shows no translation.
- Translated on the device by `RecenseText.translate` (Apple Translation, installed language pairs, iOS / macOS 26).
  Each line once per target: kept in memory by text, so a transcript growing as it is heard costs only its new lines.
- A pair that isn't installed says so beside the transcript's source: "Tiếng Việt → English isn't installed:
  Settings › General › Language & Region › Translation Languages". Nothing else changes; the original stays.
- Off hides translations; it removes nothing.

## Code
- `shared/translateplan.swift` (pure): line language, target, and the plan (which lines take a kept
  translation, which lose one, which go to the translator, grouped by language pair).
- `mobile/HostApp/iOS/Translate.swift`: `PlaybackTranslator` runs the plan after every transcript change and
  every change of the choice; writes translations into `model.transcript` by line id.
- ShowsKit: `ShowsModel.translateInto` (kept on the device) + `translateIntoChanged` closure; `NowPlaying.swift`
  adds the Translate Into menu to the transcript's own ··· menu (`extra`, the existing extension point).

## Done checks
- `swiftc -O shared/translateplan.swift mobile/ios/Tests/translateplan/main.swift -o "$TMPDIR/translateplan" && "$TMPDIR/translateplan"` (ALL OK).
- `swift test` in `shared/ShowsKit`; iOS compile (GalleryFiles + RecenseGuest).
- iPhone (Mirroring): a file playing in Recense shows each line with its translation under it; changing Translate
  Into to Français changes them; Off hides them; airplane mode on, it still works for installed pairs.

## Offline gate
- Outside services: **none at use time.** Apple's language pairs download once (Settings), then live on the device.
