# BUG-13 · Transcript lines cut off mid-sentence

From: T-0073 (owner, 2026-11-14: "sometimes the text cuts off") · Device: iPhone 12 Pro Max, iPad ·
Status: `[~]` (building)

## What the owner sees
A file heard on the phone shows its transcript in pieces. A line ends mid-sentence and the sentence goes on in the
next one.

## Red (what the code shows)
- `PlaybackEars.lines` (`mobile/HostApp/iOS/Ears.swift`) makes one line per phrase the transcriber returns, which
  is a breath, not a sentence.
- The phone's saved transcript of "French check" (11-14): 17 lines, of which only 3 end a sentence. It begins
  "This is the" / "resent player" / "check," / "one,".
- The Mac groups by sentence: `sentences` (an end mark . ? ! …, or a pause over 1.2 s), then `splitWords` (no line
  over 18 words). The rule lived only in `strip/recense.swift`. Parity: a second copy of logic is a bug.
- Each saved transcript keeps its fragments, so a file already heard stays cut until it is regrouped.

## Green (the fix)
- `Phrasing` (ShowsKit, one copy) holds the Mac's two rules unchanged: `sentences(_:pause:)` and `split(_:max:)`.
  The Mac's `sentences` and `splitWords` call them.
- `Phrasing.lines(_ words:max:)`: one line per sentence; a sentence over `longest` (18, the Mac's) words is split.
  - A line's text is its words joined by a space, with no space between two CJK characters (Chinese, Japanese).
  - Its id is its start in ms ("ms-0", "ms-1" on a tie). A line keeps its id as more of the file is heard.
- `PlaybackEars.lines` passes every phrase's words, in time order. A phrase with no timed words counts as one word.
- `Phrasing.regrouped`: on open, a transcript this device saved under the old rule is regrouped the same way.
  - Device-heard: every id "ms-n", every line with words, no translation, no chapter.
  - Anything else (the Mac's: plain ids, translations, chapters, songs) comes back unchanged.

## Invariants (tested: `shared/ShowsKit/Tests/ShowsKitTests/PhrasingTests.swift`)
- The phone's fragments "This is the" + "resent player" + "check," + "one," + "two, three, four," + "five." become
  one line, ending at "five."; the next line starts at "The".
- A pause over 1.2 s ends a line (1.3 s); a shorter one doesn't (1 s).
- An end mark inside a closing quote or bracket ends a line ("done.»").
- A 40-word sentence is split into lines of 18 words or fewer, at a comma where one is near.
- Ids are unique and by start; the same words give the same lines (regrouping twice changes nothing).
- `regrouped` leaves the Mac's lines (plain ids or a translation) exactly as they are.
- CJK words join with no space; Latin words with one.

## Device check (owner, phone in hand)
Play "French check" (heard before the fix) and a new file: each line is a whole sentence, or part of a long one,
never cut after "the".
