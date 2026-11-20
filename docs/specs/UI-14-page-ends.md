# UI-14 · Draftpad page ends: no dead end, either hand; the Content Manager

From: owner 2026-11-20 (sketch "Haptic Seam", Notability recordings 11-18 iPhone and 11-20 iPad)
Status: `[~]` E1–E7 built (slice 1); C1–C8 (Content Manager) and Z1–Z3 (zoom) `[ ]` written
Amends: UI-06 G1, G2, D3 (`ui-teardowns/UI-06-antinote-navigation/UI-06.md`). Law: `docs/law/interaction.md:28`, treaty Article 12.

## Verdict
**A horizontal swipe only ever moves between pages.**
**Past either end, the same end card appears. Nothing is made or lost by a swipe.**

## Terms
- **Page:** one section of `draftpad.md`, split by `<!-- page -->`. The file stays one endless document.
- **Newest end:** page 0, on the left. **Oldest end:** the last page, on the right (UI-06 Layout, unchanged).
- **End card:** a small card over the page, shown after a swipe past an end.
- **Empty page:** no text but its date line (UI-06 D3, `isWindowEmpty`).

## Facts this replaces (code before this spec)
- At page 0, swipe left→right made a new page (`pagemode.js:343-345`). At the last page, swipe right→left was a dead end (`:372`).
- Swipe right→left on an empty page deleted it (`:361`). One swipe meant move, make or delete, by page state.
- A Pencil stroke from the edge zone turned the page (`:793-797`); a finger from the same zone opens a wing.

## Rules (slice 1)
- **E1 · Move only.** Swipe left→right: one page newer. Swipe right→left: one page older. Trackpad, touch, mouse+Option, voice.
- **E2 · Both ends the same.** A swipe past either end, or "newer page" / "older page" at an end:
  - the page rubber-bands (0.25×) and settles back; no exit glide;
  - the `edge` haptic plays once (the seam), and the end card appears.
- **E3 · The end card** holds three buttons, in this order, the same at both ends:
  - **New page** (today's date; always at the newest end, so dates stay in order; the card says "at the front");
  - **Pages** (the Content Manager, C1; until it ships, the existing outline panel);
  - **Go to the other end** ("Go to oldest" at the newest end, "Go to newest" at the oldest end).
  - It closes on a swipe back, a tap outside, Escape, or any button. It never opens on its own.
- **E4 · Empty pages tidy themselves.** Leaving an empty page by a swipe removes it, when it is not the only page.
  - Only an empty page is removed: no text and no ink (a page whose strokes resolve to it is never empty;
    ink anchors by page, `resolveStrokeAnchor`). This guard also covers ··· › Delete page and voice.
  - An empty page at an end stays while you are on it (it is the page you just made).
- **E5 · One meaning at the edge.** A finger or a Pencil that starts in the edge zone (28 px; Pencil 42 px) belongs to the wing.
  It never turns the page (treaty Article 12(4): Pencil and finger work the same). Pencil turns pages with the bar's ‹ ›, the card, or voice.
- **E6 · Explicit making stays.** ＋, the ··· menu "New page" and voice "new page" still make a page (`newPage`), unchanged.
- **E7 · Every way in.** The end card is reachable by gesture, by the bar's ‹ › at an end, by voice ("newer page" at the front), and by Mac's step keys.

## Content Manager (slice 2, written)
Model: Notability's Content Manager (owner recordings). Clean-room: behaviour only.
- **C1 · Opens from:** the end card's Pages; a top-bar button; ··· › "Show Pages"; voice "show pages".
  iPad and Mac: a side panel on the side of the end you came from (else the end side of the layout). iPhone: a sheet.
- **C2 · Holds:** Search · "All pages ▾" filter with a count · numbered page thumbnails · Select · Expand · Close.
- **C3 · Thumbnails (owner 11-20):** each page drawn small, its number under it, the current one outlined.
- **C4 · Each thumbnail's ··· :** Open, Promote to front, Slot, Delete page. Select: many pages, then Delete.
- **C5 · Undo:** every add, delete and reorder is one editor change, so Undo (↶ in the panel and the bar, Edit › Undo, voice "undo") reverts it.
- **C6 · Reorder:** drag a thumbnail (same rule as UI-06 G4).
- **C7 · Search:** typed text, and ink where OCR text exists; hits counted, words bold.
- **C8 · Underlay feed (owner 11-20):** in a media note or any page with a recording, the list shows what you wrote, word by word, each with its note time;
  tap a word: the media (or the page's recording) jumps to that moment (FEAT-23 note time; FEAT-08 P6 real-life time).

## Zoom (slice 3, written)
- **Z1 · Thumbnails:** pinch, or − / + in the panel: 1 to 5 columns.
- **Z2 · Page:** pinch, or the ··· menu's larger / smaller text: text grows and reflows in the column; never sideways scroll.
- **Z3 · Mac:** trackpad pinch arrives as ctrl+wheel; the page bar's A− / A+ do the same.

## Checks
- `npm test` in `editor/`: `test/ui14-page-ends.test.mjs` (E1–E5), `test/p1-navigation.test.mjs` updated to E1–E4.
- Device: iPhone + iPad through iPhone Mirroring, swipe past both ends; Mac trackpad. `device:` owed until shot.
