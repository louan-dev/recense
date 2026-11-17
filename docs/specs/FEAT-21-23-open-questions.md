# FEAT-07 · 21 · 22 · 23 · Open questions for the owner, and the build order

Written 2026-11-16 (lane notes-search-curve) after the owner's design review.
Covers: per-media notes (FEAT-23), one search (FEAT-21), where things live and Main / Guest (FEAT-22),
the pill and the sound curve (FEAT-07, FEAT-16).

**How to answer:** reply with the number and the letter, for example `1A 2A 3B`. Unanswered = the recommended choice (A).

## The seven questions

**1. All notes on one page: a list, or one long document?**
- **A (recommended): a list of notes, newest first, 20 at a time; a tap opens that note.**
  Why: one focus at a time, and it stays light on the 8 GB Mac.
- B: every note stitched into one endless scrolling document, as the first draft had it.
  Cost: hundreds of sections in one editor page; slower, and a larger thing to lose in a bad sync.

**2. Reverb is in today's sound tray but not in your list of seven. What happens to it?**
- **A (recommended): it leaves the curve and becomes one item in the ··· menu ("Room sound: Off / Room / Hall").**
  Why: seven beads is already the most a phone's width holds at a comfortable size.
- B: remove it everywhere.
- C: it becomes an eighth bead (columns shrink to 46 pt on a small phone).

**3. What should "Clean" do?**
- **A (recommended): first version = a fixed voice-clarity setting: cut rumble below 90 Hz, lift speech slightly.
  It is labelled "Clean (tone)" until real noise removal exists.**
  Why: it can be built now with parts that already work; real noise removal on the device is untested.
- B: wait, and ship Clean only when it truly removes background noise. The bead is hidden until then.

**4. On a picture, what does the Sound button's place and the two-finger gesture do?**
- **A (recommended): a light curve with three beads, Light · Contrast · Warmth, for viewing only; the file never changes.**
  Why: same place, same motion, and it serves eye comfort.
- B: nothing. The button is hidden on pictures and two fingers zoom as usual.

**5. A guest far away: may their shared album catch up through Cloudflare for now?**
- **A (recommended): yes, as the optional last route, sealed so Cloudflare stores only unreadable data,
  with the documented exit (`rclone copy` to any other store).**
  Why: it is the only route that reaches another country today; nearby and home routes are tried first and it is never required.
- B: no. Far guests catch up only when they visit, until your own server is reachable from outside.

**6. A guest writes a note on a shared item. Who sees it?**
- **A (recommended): only that guest. It lives in their Mine until they press "Share note".**
  Why: it matches your rule that nothing a guest adds is visible to you unless they share it.
- B: everyone in the album sees notes on shared items at once.

**7. The switch "Let the owner's Mac improve my transcripts": how wide is one yes?**
- **A (recommended): one switch per guest, covering only items that guest has already shared.**
  Why: one decision, easy to understand and to turn off; private items are never sent.
- B: asked again for every item.

## Settled without asking (say so if any is wrong)
- Speed moves into the curve; its old control is removed on each surface when the curve ships there.
- The Note button sits in Now Playing's top bar, not on the pill.
- Search across everything lives in Library › Search; the pill's Find covers one item and hands over with one row.
- Accents are ignored in search unless you type them; then exact matches come first.
- Two devices editing one note: merged when clean, both kept when not. Never "last one wins".
- No haptic on the iPad Air: sight carries every detent there.
- AirDrop to the Mac makes the note quietly (marked New in the notes list); on iPhone and iPad the note opens at once.
- A note links to its media by key; where the file sits now is shown, never saved into the note.

## Build order

**Rule used:** ship first what is usable alone on your devices; nothing waits for a sibling feature.

1. **First to your Mac, iPhone and iPad: the note on one device (FEAT-23 P0).**
   - You get: a Note button in Now Playing; a note per item in Draftpad with the transcript beside it;
     tap a line to drop a time link; tap the link to play from there.
   - Usable alone: yes. The note is a plain file in `Recense/keep/<key>/note.md`, visible in Files.
   - Rough edge, stated: the note stays on the device it was written on until step 2.
   - Size: small. One editor rule (open `recense://` links), one host change per platform (swap the document).
1b. **Arrivals open as a note (FEAT-23 P0b), right after step 1.** AirDrop a file → it lands in its home with its note
   and a ▶ link back to it. Two 30-minute spikes first (iPhone "Open with Recense"; Mac AirDrop mark).
2. **Notes and transcripts on every device, with no Cloudflare on the path (FEAT-22 P1, then P2).**
3. **Search everything (FEAT-21 P1 → P2 → P3).**
4. **The sound curve with its Sound button on the web and the Mac (FEAT-07 P4, P5).** The engine already exists there.
5. **The curve and Speed on iPhone and iPad (FEAT-07 P6);** the note's light and the notes list (FEAT-23 P1, P2).
6. **Guest as a role: Shared · Mine (FEAT-22 G1, G2);** then the voice-note thread (G3) and the opt-in (G4).
7. **Later, each behind a spike or a question:** tone controls on mobile (FEAT-07 P7), Clean (P8), pictures (P9),
   the hub serving notes (FEAT-22 P3), "Move Media and Note to Trash…" (FEAT-23 P3).

## Claims in the reviewed plan that had no test
The table is in FEAT-07 § "Claims from the reviewed plan, checked 2026-11-16".
Short form: `GLIDE = 12` exists but means something else; the other four (381/381 parity, ≤ 25 ms lock,
sub-15 ms link, the 24-byte tick) are **untested** from this repository. None of the five is relied on by these specs.
