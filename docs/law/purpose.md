# Purpose

## What Recense is
**Recense is one system in three states.**
- **The strip** — Recense on a device, now: listening, writing, the edge of the screen (Mac, iPhone, iPad).
- **The library** — Gallery: your media, and the people you share it with.
- **The sync** — custody: every byte kept, accounted for, and carried between devices.

They are not three products.
Each carries the others' DNA: the strip writes what the sync keeps; the library shows what the strip heard.
One interface joins them, and that interface is Recense.
(Owner, 2026-11-05. Before that date the three were separate repos; see `structure.md`.)

## The principle: one matter, many states
Water can be ice, liquid or vapour and stay the same water.
It changes form and can change back.

Writing should behave the same way.
A thought begun with a pencil on the iPad, continued on a Mac keyboard,
then on a phone on the grass, then by voice, is **one thought on one page**.
Today's tools treat it as four files in four apps. Recense treats it as one matter in four states.

The owner's analogy: pencil (Notability), keyboard (Obsidian), touchscreen (LibreOffice), voice (Office)
as solid, liquid, gas and plasma.

A phase change conserves what it transforms: the same atoms carry through solid, liquid, gas and plasma,
rearranged, never reduced, and the change runs just as cleanly in reverse. That is the actual bar a thought
must clear moving between a page, a keyboard and a spoken sentence, not just the four-state image on its own.
The choice of instrument, a quill on vellum, a mechanical key, a glass touchscreen, a spoken word returned to
text, has stayed essentially the same choice since long before computers; Isidore of Seville was already
writing of the quill in the sixth century CE. Writing split across three devices and three postures today, each
landing in its own file, breaks the conservation the water analogy promises: the matter fragments instead of
changing phase and returning whole. That fragmentation, not the devices themselves, is the actual anomaly rule 2
below exists to close.

### Rules that follow
1. **One page, many inputs.** A continuation from any device or input mode lands on the same page, in order.
2. **Nothing splits.** No feature may force a new document because the device or the input changed.
3. **Every state can return to the seed.** Each passage keeps where it came from: device, input mode, time.
   You can trace a spoken sentence back to the typed and penned ones beside it.
4. **Transform, never replace.** Transcribing, translating, summarizing or reading aloud adds a new form linked
   to the original. The owner's words are never rewritten (playbook §2.2, §2.9).
5. **Markdown is the source of truth** for written pages: plain, portable, readable without Recense.

### The twelve crossings
Four states: **ink** (solid, stroke geometry fixed to a position), **type** (liquid, the markdown body),
**mark** (gas, highlight/selection/margin note, anchored to ranges), **voice** (plasma, speech and audio,
anchored to a moment).

Matter names only eight crossings, because matter only goes directly between adjacent states (plus solid↔gas).
Writing gets twelve: every sense addresses every other sense directly, so the four involving ink↔voice and
type↔voice have no name in physics. The unnamed four are design territory, not an error in the analogy.

| # | Crossing | Physics name | What it means on a page | State |
|---|---|---|---|---|
| 1 | ink → type | melting | handwriting becomes editable text | runs, one-way (`shared/inkocr.swift`, Vision, en/fr/vi; indexes for ⌘F, does not enter the body) |
| 2 | type → ink | freezing | a typed passage becomes a pencil-markable surface, strokes anchored to words | unbuilt (anchoring math = BUG-07) |
| 3 | type → mark | vaporizing | typed text becomes range-addressable, highlightable | partial (editor highlight machinery) |
| 4 | mark → type | condensing | a highlight collapses to a quoted block, a margin note settles inline | unbuilt |
| 5 | ink → mark | subliming | a circled region becomes a region-anchored comment, recognition skipped | unbuilt |
| 6 | mark → ink | deposition | a comment sets down as a hand-placed stroke | unbuilt |
| 7 | mark → voice | ionizing | a marked passage reads aloud; a spoken aside attaches to a range | partial |
| 8 | voice → mark | recombining | a spoken aside lands as a timestamped margin note, not body text | unbuilt |
| 9 | type → voice | — | text read aloud | runs (`shared/draftpadlibrary.swift`, `ReadAloud`, `willSpeakRange`) |
| 10 | voice → type | — | speech becomes editable text | runs (`shared/speechcore.swift`, SpeechAnalyzer + `strip/openears.swift` → `strip/ears/omni.py`) |
| 11 | ink → voice | — | handwriting read aloud, typed intermediate skipped | unbuilt |
| 12 | voice → ink | — | a spoken phrase pinned to a place on the page, not a moment in a timeline | unbuilt |

**Isothermal transforms** change the matter and leave the state alone (heating water leaves it water):
translation, summary, rephrasing. These run today (`strip/recense.swift`, `shared/recensetext.swift`)
and are governed by rule 4: each adds a linked form, the owner's words are never rewritten.

**Triple point** (water: 0.01 °C, 611.657 Pa — ice, liquid and vapour coexisting): the target state of a page.
All four states present at once, each reachable from any other, with no one of them privileged as "the real
document." This is what rule 1 means in physical terms.

**Critical point** (water: 373.95 °C, 22.064 MPa — liquid and gas become one supercritical fluid): the stronger
target. Type and voice stop being distinguishable to the system, so one search, one cursor and one edit reach
both. Further off than the triple point, and the more valuable of the two.

**The conservation law.** A crossing is a phase change only if its inverse exists and a round trip returns the
same matter. One-way crossings (today: #1) are conversions, and rule 2 is not satisfied by them.

**The arithmetic (why this stays maintainable).** Twelve crossings as twelve converters is O(n²): 12 at four
states, 20 at five. A canonical core is O(2n): 8 at four states, 10 at five, each state converting to and from
one neutral form. Markdown already holds that job (rule 5). But markdown carries a body and drops stroke
geometry, range anchors, audio offsets and prosody, so the canonical core holds the words and **each state keeps
a sidecar for what markdown cannot represent.** The sidecar is the mechanism of reversibility: whether a page
survives a crossing is a storage decision, not a conversion decision.

## Who it serves
The owner's "Purpose" list in `~/.claude/CLAUDE.md` is binding and is not repeated here.
In short: a law student working across borders and languages, who writes in pieces,
on many devices, in many postures, often offline, with eyes that tire and an ADHD mind.

Also anyone who:
- swaps devices constantly;
- records one stream of thought on different instruments;
- ideates in different places, and picks the device the place calls for.
They should never have to choose one app and stay in it for their ideas to land on the same page.

## How we find answers
- **Biology first.** Before inventing, ask how nature already solved it (phase change, adaptation, redundancy).
  It is a method for finding designs, not decoration.
- **Accessibility is a net gain.** Removing a barrier for one person improves the system for everyone.
- **Intent is not evidence.** A design meant to help eyes, attention or hearing is a hypothesis until tested.
  Claims say which it is: intent, hypothesis, observed, or tested.

## What Recense is not
- Not a dashboard, a widget collection, or a notification center.
- Not a store for information to pile up in: important things stay available without intruding.
- Not dependent on any one company (see `offline.md`).

## The measure
> Less friction between thought, awareness and action.

## Amendments
- 2026-11-14 · created; replaces `export/00_NORTH_STAR.md` (which described the Mac strip only).
- 2026-11-14 · owner, dictated in conversation: expanded the matter/states principle with the
  conservation-of-phase-change point and the quill-to-keyboard continuity, tying rule 2 to why fragmenting a
  thought across devices is the actual anomaly, not the devices themselves.
- 2026-11-14 · claude, at the owner's request ("devise what all possible phase transformations this document
  should include"): added **The twelve crossings** under rule 5. Derived from the owner's four-state mapping,
  with each crossing's status checked against the code on that date. The conservation law and the
  canonical-core-plus-sidecar arithmetic are engineering consequences, offered for the owner's confirmation
  before they bind as numbered rules.
- 2026-11-14 · owner, at plan approval (verbatim): "incorporate this im trying to model a file document and make it behave like the state of matter, how its matter is preserved and making the doucment undergo every possible phase transition, vulnerability is a great catalyst and a self renewing currency a portal of discovery, available through expression, writing presents as the one most disconnected that has the oportunity to be the closest with nature via intertwining the possible phase transformations that mental thought undergo much like the behavior of matter  through modern writing software and word processors, and from this"
  Adds two points to the principle: the page must undergo *every* phase transition (the twelve crossings above),
  and vulnerability is the catalyst: capture must cost near-zero effort and stay private by default.
  The owner's essay of the same day (the page in several states at once; no format commitment up front)
  is kept private: `~/.claude/context/recense/research/2026-11-14-wish-order-law.md` §3. Spec: FEAT-08.
