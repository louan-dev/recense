# BUG-11 · A file played in Recense is heard in the last broadcast's language

From: T-0070 (owner, 2026-11-14: "in app transcription is inaccurate") · Device: iPhone 12 Pro Max, iPad ·
Status: `[~]` (fixed, owner's device check owed)

## What the owner sees
A file plays in Recense's player and its transcript is wrong: words that are not what was said.

## Red (what the code shows)
- `PlaybackEars.hear` (`mobile/HostApp/iOS/Ears.swift`) hears the file in `Listener.shared.lang`.
- With Hear in = Automatic, that is `spoken`: the language the *last broadcast* detected, `"en"` until one
  ran (`Listen.swift`). Nothing about the file itself.
- `SpeechAhead` (`shared/speechcore.swift`) hears every two-minute stretch in that one language and never
  checks it. A French or Vietnamese file is written out by the English model.
- Measured before (Listen S6 bench, 11-09): the wrong model gives 91–100 % word error rate.
- The Mac already picks a language per file (`strip/speech.swift`); the phone and iPad did not.

## Green (the fix)
- `SpeechAhead(url:lang:among:duration:)`: `among` is the languages to choose from (Automatic: en, fr, vi;
  a chosen language: just that one); `lang` is the fallback when nothing is heard.
- Before each stretch, with more than one candidate: each candidate hears the same `probe` (10 s) of it, at
  the playhead in the playhead's stretch, else at the stretch's start. Scores: `SpeechCore.sureness`, the
  rule the live language check (SpeechAuto) and the Mac use. The first choice is the surest outright; after
  that it changes only by `SpeechCore.pick`'s clear margin (1.5×). No speech in any → keep the current one.
- A candidate whose model isn't on the device is skipped (never downloaded at the moment of use).
- `heardIn` says which language the file is being heard in; Now Playing reads
  "Heard on this device in French (automatic)" (the language named in the device's own language), and
  FEAT-10's translation takes it as the source.
- Measured after (Mac, real engine, `say` recordings, fallback `en`): French en=0.2 fr=7.7 vi=0.8 → fr;
  Vietnamese en=0.1 fr=0.0 vi=6.3 → vi; English en=7.6 fr=1.3 vi=0.0 → en. Before, the French one came back
  "Like courage, jé, que, que, que, la, la, la…".

## Invariants (tested: `mobile/ios/Tests/aheadlang/main.swift`)
- `SpeechAhead.choose`: first choice = the surest (ties broken by the candidates' order); none above 0 → nil.
  After a choice: stays unless another is at least 1.5× surer.
- `SpeechAhead.window`: inside the playhead's stretch it starts at the playhead; otherwise at the stretch's
  start; never past the stretch's end; at least 3 s when the stretch has 3 s.
- Real engine on the Mac (`mobile/ios/Tests/aheadlang/run.zsh`): French, Vietnamese and English recordings
  (made with `say`), each heard on Automatic with the fallback `en` (what the phone passed before), come back
  with `heardIn` = their own language and words that read as it.

## Device check (owner, phone in hand)
Hear in = Automatic. Play a French file, then a Vietnamese one, in Recense: each transcript is in its own
language and Now Playing says which.
