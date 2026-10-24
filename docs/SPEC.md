# Spec — Gallery · Recense · Sync

Priority order for this week (weekly limit is tight):
1. **P1 — WebDAV + file dashboard (new folder, move)**, part of the master plan in `PROGRESS.md`
2. **P2 — Shared homebar redesign** (Gallery + Recense, same controls and code)
3. **P3 — Bugs** (tolerable, do later)

Each session reads only the section it needs.

---

## P1 — Gallery file dashboard + WebDAV

- Add controls to the file dashboard that fit `PROGRESS.md` and the design philosophy: a **New Folder** button and a **Move** action.
- Create the backend endpoints needed to create folders and move files **securely within the storage directory** (no path traversal, no escaping the root).
- Build **WebDAV** on top of this. It's needed anyway for:
  - exporting Notability notes as PDFs and viewing them in Obsidian
  - making it an iCloud mirror
- Follow the master plan in `PROGRESS.md`.

---

## P2 — Shared horizontal + vertical homebar (Gallery + Recense)

### Ground rule: the two players stay identical
The Recense player's homebar doesn't have the latest Gallery player changes. Both use the same horizontal homebar, so they **must stay identical**: any edit to one carries over to the other, both ways. Recense and Gallery reuse the same homebar controls and code, so share one implementation.

**Principle:** the horizontal bar handles sight, the vertical bar handles hearing. Group functions into sight and sound and fold them into the horizontal bar.

### Horizontal homebar (Gallery)
- **Remove the info icon.** Move every section of the info menu into the horizontal bar.
- **Positional rule (rule of thirds):** the bar is split into thirds. Each menu shows **at most 3 items**, placed above the positions of **Loop, A, B** (left, middle, right). Every menu follows this rule.
- **Language menu:** shows on hover over the line (Mac) or a tap on the line (mobile). Order left → middle → right: **Vietnamese, English, French**, above Loop / A / B.
- **Visual effect:** drop the Gaussian blur (lyrics already sit on a black background). Use a transparent, holographic "naked" effect like the EQ curves, on or below the bar. The time bar moves exactly as it does now; only its hitbox changes.
- **Above the line:** a horizontal barrel roll, so menus slide in threes.
- **Tap / press count opens:**
  1. **Text size menu**: three segments that reveal on slide. Left icon makes text smaller, middle shows the zoom value (tap resets to 100%), right icon makes text bigger. Moving the mouse away closes it. Design brief: playful three-segment geometry, unorthodox but instinctive, futuristic, sleek, visionary, in the player's design language, something new. Must have exactly three segments.
  2. **Rename · Change Cover · Delete Cover** (grouped triplet)
  3. **Download · Transpose · Share**: make icons for Download and Transpose, make all three white, and move them inside the homebar menu. Remove the Download button from the info menu. Their menus still pop up on click, but with **no fill and no border, white**. They turn **blue only on hover or selection**.
  4. **Add a comment…**: white, placed above the horizontal homebar. Tapping opens the comment view. With comments it shows **"n comments" in blue**. With none it shows **"Add a comment…" in white**. Remove its current spot below the thumbnail strip.
- **Remove the text size section from the info menu.**
- **Remove pinch to zoom** (it interferes too much with native controls).
- **Remove the blue back button.**
- **Remove that section and the pill icon at top right** (mobile + web). This version wins over anything that contradicts it.

### Vertical homebar (Gallery + Recense): original-language prominence
- Replace swipe up/down for volume with **original-language prominence**. This controls **opacity, not font size** (the horizontal bar handles text size).
- Scale: bottom = 0%, top = 100%.
  - **0%**: only the trailing language (the current language setting).
  - **1–50%**: the original language slowly appears above the trailing language. At **50%** both are fully crisp.
  - **50–90%**: the bottom (trailing) language fades out first, so at **90%** only the original language shows.
  - **90–100%**: a detent drops to blackout. **100%** is a blank canvas for blind listening.
- **Tap or press the vertical bar** to reset everything and turn it from blue back to white.
- Any adjustment on the outer vertical bar (text size, low, mid, high, C/Đô, reverb) turns the bar **blue**. Pressing it resets everything back to **white**.

### Gallery only (web + mobile): notation tags
- Change the notation property tags from a horizontal barrel to a **vertical barrel**. It shows one rectangle at a time: sliding up shows the previous one, sliding down shows the next.
- Reorder the first three: was **key, ton, tông**, now **C/Đô, Ton., Tông**. Everything after Tông stays the same.

### Recense only
- Embed the **same vertical bar** as Gallery, rescaled to fit the window. It's a stripped-down version that differs in scale: **no EQ curve**.
- **Hover over the vertical bar** shows the bookmark locations as a vertical list: no border, no fill, white text on black, as a vertical barrel. Think Bitwarden's transparent carousel in Sill, but front-facing and flat (not sideways or jagged).
- Same opacity slider gesture as Gallery.
- Horizontal homebar **excludes**: the Rename/Cover trio, Add a comment, and the Download/Transpose/Share trio.
- Horizontal homebar **includes**:
  - press the bar → set a bookmark
  - hover → bookmark menu
  - slide 1 → language
  - slide 2 → text size menu
  - slide 3 → Loop · A · B
  - slide 4 → playback speed ruler
  - slide 5 → Retranscribe · Export as MD · M4B

---

## P3 — Bugs (Recense + Gallery unless noted)

1. **Vietnamese subtitle overflow/clipping**: the line is locked to one line (`white-space: nowrap`) or wider than the viewport when scaled up, so both ends get clipped. Happens on iPhone 12 Pro Max in portrait.
2. **Comment button color**: "Add a comment…" is blue even with zero comments. It should be white with 0 comments and blue with 1 or more.
3. **Transcript viewer swipe-to-exit vs scroll**: scrolling back up hard closes the transcript. Remove the gesture, make it more resistant, or find a cleaner way to dismiss.
4. **Transcript editor has no trailing side**: it shows only the original ("front"). Add a "back" side to view and edit the trailing/translated text (for example, when English shows even though the language is set to French).
5. **Translation drifts mid-track**: with `ksitigarbha sutra chapter 1.flac`, French and Vietnamese start correctly but switch to English partway through. Find the root cause in the code and fix it for all future recordings.
6. **Retranscribe hangs** on "Waiting for transcript…" forever.
7. **Translation backend unclear**: document which endpoints and services handle translation, then tighten the pipeline.
8. **Gallery → Recense connection broken**: Recense no longer connects to or syncs with media playing from Gallery.
