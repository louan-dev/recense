# Order: which wish is granted first

The rule every agent follows when deciding what to build, fix or resume next.
The owner's full text (2026-11-14) is kept private: `~/.claude/context/recense/research/2026-11-14-wish-order-law.md`.
`sync/src/wishrank.mjs` applies this file; where the two disagree, this file wins and the script is fixed.

## The rule
1. **Stars set the group.** More `*` before a wish = an earlier group. Six stars before five, five before four.
2. **Emphasis sets the order inside a group.** The wish the owner has returned to most goes first.
3. **Order of writing never decides.** A wish higher on a page, or said first, or said last, gains nothing by it.
4. **Buried wishes resurface.** Every wish since Recense was first conceived (including when it was Sill) is
   measured against the whole archive, not the current session. An old wish the owner kept returning to
   outranks a new one mentioned once.
5. **Every wish gets a turn.** The sequence has as many places as there are wishes.

## Definitions
- **Wish:** one line or passage in which the owner asks for something. Each becomes a triage entry (`T-####`).
- **Rating:** the run of `*` at the start of a wish (after `-`, `!`, `1)` or spaces).
  Stars on both sides of text (`*text*`, `**hello**`) are formatting, not a rating.
- **Rated twice:** the highest rating wins.
- **Emphasis:** the number of distinct days the wish appears in the owner's own words.
  - Sources: the owner's messages in every Claude transcript on this Mac (typed or pasted),
    and the owner's quotes in `triage.md` and `triage-archive.md`.
  - Not sources: agents' summaries, handoffs, specs, or anything Claude wrote.
  - An identical paste counts once, on its earliest day.
  - Claude has no hidden memory or cache: only files on disk count.
  - Each entry's `Keys:` line lists the patterns that recognize it. The owner can read and correct them.
- **Ties:** first more days; then more messages; then more files; then the owner decides.
  wishrank marks a full tie `TIE: owner decides`.

## Unrated wishes
- An unrated wish that echoes a rated one (`Echoes: T-####`) borrows that rating.
- Otherwise it goes after every rated wish,
  unless its emphasis beats every wish in the lowest rated group; then it joins that group.
- A lone rated wish among unrated ones goes first.

## Fix-now and paused work
- `!` (or the old `P1 - `) still means fix now: those come before everything else.
  Several `!` entries are ordered by this rule, never by filing order.
- The fix queue (`sync/bin/triage-watch.zsh`) asks wishrank for its order before each run.
- When an objective ends, resume the **highest-ranked** PAUSED objective, not the oldest.
  A `!` fix already in progress finishes first.

## When a wish is done
- "Fulfil" is a loop: build, test, harden, measure, repeat.
- "Fulfilled" ends the loop. A spec makes it checkable:
  - it names its Done checks;
  - it names one baseline (an app or a number today) the result must match or beat, with the measurement.
- The owner's stop rules (`~/.claude/CLAUDE.md`, Validation loop) still apply inside the loop.

## Running it
- `cd ~/Developer/recense/sync && node src/wishrank.mjs` prints the ranked queue with its evidence.
- `node src/wishrank.mjs order T-0001 T-0002` prints those ids in law order.
- `node src/wishrank.mjs selftest` checks every rule above.

## Amendments
- 2026-11-14 · owner, pasted law ("text presented higher/earlier disclosed does not imply more importance");
  written as rules by claude, with three clarifications the owner approved with the plan:
  emphasis is counted as days in the owner's words; "fulfilled" means a spec's Done checks plus a named
  baseline; only files on disk count. Replaces the FIFO fix queue in `triage-watch.zsh` and the global rule
  "resume the oldest PAUSED objective".
