# Owner's screen recording, 2026-11-16 05:44 (iPad, 4:20, no sound)

Source: Gallery share `J6Y96zLjia2cxFpj6FFf`, `ScreenRecording_11-16-2026 05-44-25_1.MP4` (HEVC 2732×2048, silent audio track).
Frames here: one every 8 s, 9 per sheet (`sheet01`–`sheet04`, in time order, left to right, top to bottom).
Read by the coordinator session; what follows is what is on screen, not the owner's words.

The reference app (Notability-style ink toolbar, Apple Pencil Pro) over a violin-bridge measurement sheet. What it shows, in order:

1. **Hold-to-snap shapes beyond line/ellipse:** straight line, circle, triangle, rectangle, isosceles trapezoid, pentagon,
   a right triangle; a rough closed loop snaps to the nearest polygon with corner handles (blue dots) right after snap.
2. **Fill:** hint toast "Tap and hold inside any closed shape to fill it with your selected ink color."
3. **Lasso, two modes:** Freeform and Boxed (segmented control under the toolbar).
4. **Selection:** move, scale with a side handle (the whole group shrinks/grows), rotate (handle on a stem).
5. **Selection menu:** Style · Duplicate · Cut · Copy · Paste · Delete · › (more): Paste Image, Group, Save,
   Mirror Horizontally, Mirror Vertically. Long-press on empty canvas: Paste · Paste Image.
6. **Style panel (Stroke | Fill tabs):** width slider (1, 1.5, 2 …), four stroke styles (solid, pressure, dashed, dotted),
   two pages of colour swatches + colour wheel; applies to the selection.
7. **Magnifier loupe** with ✕ / ✓ over the page while placing.
8. **Apple Pencil Pro** squeeze/hover indicator ("Apple Pencil Pro 100%").

Draftpad today (UI-04 "Built"): snaps only loops → ellipse and near-straight → line (`editor/src/ink.js:462`).
Gaps 1–7 are the ink-parity work for the draftpad-ink lane.
