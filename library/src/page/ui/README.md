# Gallery UI Reference (`ui/`)


**What this UI is.** A dark, touch-first photo-album interface modeled on Apple Photos *Shared Albums* (iOS 26 look, but with glass limited as described in §1.1). It has three levels: a **Collections feed** of album cards, an **Album** (hero card plus thumbnail grid, with a selection mode), and a **Viewer** where one media item fills the screen and can shrink to make room for a comment thread. Everything is black, rounded and blue-accented. **Liquid glass is reserved for exactly three controls (§1.1); every other control is plain blue text or icon.**

**Provenance and honesty tags.**
- All screenshots come from an iPhone 12 Pro Max: 1284×2778 px at 3×, i.e. a **428×926 pt** viewport. Dimensions below are in pt unless marked `px`.
- `[m]` = measured from pixels. `[e]` = visual estimate (±3 pt). `[i]` = inferred from comparing screenshots or from the directive; not directly visible. `[d]` = a rule you stated directly; it overrides what the screenshots show.
- Photos, names and dates inside the screenshots are placeholder content. Reproduce the **chrome**, not the pictures.
- `public/` contains no images. See [Public side](#7-public-side-no-references-supplied).

---

## 1. Design tokens

| Token | Value | Use |
|---|---|---|
| `--bg` | `#000000` | viewer background, comment area, thread |
| `--surface-1` | `#1c1c1e` | selection toolbar, capsules, "+" tile `[m]` |
| `--surface-2` | `#302f33` | Presented-by panel `[m]`; nav header is `#323035` |
| `--hairline` | `#2a2a2c`, 1 px | row separators; start at x=15 pt, run to the right edge `[m]` |
| `--text` | `#ffffff` (sampled `#fafafa`) | primary text |
| `--text-2` | `#939297` | timestamps `[m]` |
| `--text-dim` | `#7c797f` | `{currentFolder}` in breadcrumb `[m]` |
| `--blue` | `#0a84ff` nominal | links, active tab, pills. Sampled values vary with antialiasing: `#1384e8` nav text, `#009afe` Download pill, `#0084ff` in `upload vibrant.svg` |
| `--blue-dim-fill` / `--blue-dim-text` | `#245170` / `#7a8188` | disabled Download/Upload pill `[m]` |
| `--glass` | `rgba(255,255,255,.12)` + `backdrop-filter: blur(20px) saturate(1.8)` + 1 px `rgba(255,255,255,.28)` border `[e]` | **only the three playback controls (§1.1)**. Glass tints toward the media behind it |
| `--ctl` | 17 pt, regular, `--blue`, no background, no border | the "Select All" / "Deselect All" look `[d]`: used for every other button, toggle and link |

### 1.1 Control styling rules `[d]` (directed by you)
1. **Exactly three glass badges**: the three playback controls in the media player: **rewind** (left), **pause/play** (center), **forward** (right), at the fixed anchors below. Icons stay white; the center shows pause while playing and play while paused. **Nowhere else** gets glass. Share, like and `Hide Comments` are plain blue `--ctl` controls (§3.2).
2. **Everything else** (back, `Select`, `Cancel`, `Select All`, `Deselect All`, ⋯, `+`, trash, search, sort, tab labels, segmented-control labels, menu rows, Live Text, mute, play on the item card, share, like, `Hide Comments`, the comment count, `Activity`, and **`Add a comment…`**) uses `--ctl`: same font and same blue as `Select All`. Icon-only buttons are blue glyphs with no badge. Where a control must separate from a bright photo, use a top/bottom dark scrim gradient (`rgba(0,0,0,.45)`→0, about 96 pt) rather than a badge.
3. Toggles and tabs show state by a flat `--surface-1` fill behind the active item, never by glass. Labels stay blue in both states.
4. Non-interactive labels (the viewer's date and time, `Posted by…`, `You liked this`, comment text) stay white or gray, not blue.
5. Disabled controls: `--ctl` at 40% opacity (dim pills in §5.7 keep their own dim colors).
6. Destructive menu rows (`Delete Shared Album`, `Unsubscribe`) are also `--ctl` blue. There is no red in the UI.

**Type (SF Pro / `-apple-system`).** Body and comment text 17 pt (line pitch 22 pt) `[m]`. Meta lines 13 pt: author bold white, timestamp regular `--text-2` `[m]`. Section and album titles bold, about 28 pt `[e]`. Controls use `--ctl` (17 pt regular blue). The glass center pill label is 17 pt medium white.

**Shape.** The three glass controls are 48 pt `[m]`. Other icon buttons have a 44 pt hit area and no visible badge. Pills are fully rounded. Menus have a radius of about 34 pt `[e]`. Album cards have a radius of about 26 pt on the feed and about 20 pt in the row `[e]`.

**Fixed anchors (viewer, bottom bar).** 28 pt from the left, right and bottom edges `[m]`: rewind circle 48×48 (center x=52), pause/play pill 133×48 (center x=214, the screen center; the screenshot's geometry is kept), forward circle 48×48 (center x=376). The playback bar shows for audio/video only; photos have none `[i]`.

---

## 2. Screen map and states

```
Collections feed ──tap card──▶ Album (hero + 3-col grid)
      │                          │  ├─ overflow menu (owner / participant)
      │                          │  ├─ Select mode ─▶ Download / Upload bar, Delete bar
      │                          │  └─ tap thumbnail ─▶ Viewer
      └─ Shared Albums row       └──────────────────────  Viewer: COLLAPSED ⇄ EXPANDED (comments)
```

Z-order, bottom to top: media → thumbnail strip / thread → floating glass controls → menus → system banners (the AirPods pill in `participation.PNG` is an iOS overlay, not part of this UI).

---

## 3. Media-player geometry (the core behavior)

Two viewer states share the same anchors; only the media box and the lower region change.

| | **COLLAPSED** (`common/collapse.PNG`) | **EXPANDED** (`common/expand.PNG`, `main/participation.PNG`) |
|---|---|---|
| Media box | full viewport, 428×926, aspect-fit on black | **428×428 square pinned to y=0** `[m]` (media ends at 427.7 pt in both screenshots) |
| Photo fit | contain | cover, top-aligned: bottom of portrait images is cropped, top caption stays visible `[i]` |
| Audio/video | full size | shrink to fit the square, **keep both playback bars visible** (directive §1.3) |
| Thumbnail strip | visible, about 30 pt tall, bottom edge at y≈796, just above the action row `[e]` | **hidden** |
| Region below media | none | action row at y=428–472, then thread from y=472 down to the playback bar (top at 842); scrolls; composer sits directly under the newest comment |
| Action row (plain blue, §3.2) | y≈800–844: `Share`, `Like`, count (`Add a comment` → `X comment`) | y=428–472: `Share`, `Like`, `Hide Comments` |
| Playback bar (3 glass, audio/video) | rewind · pause/play · forward at y=850–898 | same |
| Top bar | back, date/time label (plain white text, no pill), trash, ⋯ (blue glyphs, no badges) | same; trash is absent when the viewer cannot delete `[i]` |
| Right-edge extras | Live Text and mute as blue glyphs stacked above the strip (contextual: images with text, videos) | blue comment-bubble glyph at about (x=388, y=285) in `expand.PNG` `[m]` |
| **Time bar + audio bar** | aligned per §3.1 to the full box | re-anchored to the 428×428 box per §3.1 |

### 3.1 Time bar and audio bar alignment `[d]`
The horizontal **time bar** and vertical **audio bar** are anchored to the **media box M** (not the viewport), so they re-align automatically in both states and never overlap each other, the three glass controls, or the thumbnail strip. Numbers are proposed defaults, not measured.
- **Shared look:** 4 pt track, white at 35% opacity, `--blue` fill, 12 pt thumb, 44 pt hit area (audio bar 32 pt wide). Same easing and same gesture sensitivity (the two-finger vertical gesture on the audio bar mirrors the horizontal timeline gesture).
- **Symmetric insets:** time bar starts 16 pt from M's left edge; audio bar sits 16 pt from M's right edge (column x=380→412, track center x=396). The time bar ends 8 pt before that column (x=16→372), so both share one gutter.
- **Time bar y:** centerline 24 pt above M's bottom in EXPANDED (≈404). In COLLAPSED, 16 pt above the top of the thumbnail strip (strip top ≈766 → centerline ≈750).
- **Audio bar length and y:** 40% of M's height, clamped 120–240 pt, vertically centered in M, and its bottom end stays at least 24 pt above the time bar's centerline. EXPANDED ≈171 pt long, COLLAPSED 240 pt.
- **Both bars animate with M** during the collapse/expand transition (same duration and curve), so the pair keeps its L-shaped relationship throughout.
- Keep the audio bar clear of the right-edge Live Text/mute glyphs: those stack at least 16 pt below the audio bar's lower end, or move left of the column.

### 3.2 Action row `[d]`
Because the three glass slots now hold rewind/pause/forward, share, like and comments move to a flat row of blue `--ctl` controls: `Share` and `Like` left, count/`Hide Comments` right, 44 pt tall. EXPANDED: directly under the media (y=428–472), so everything below the media in the screenshots (the `liked` and `Posted by` rows, comments, field) sits 44 pt lower than measured. COLLAPSED: y≈800–844, between the thumbnail strip and the playback bar. Layout is my proposal; the placement was not in your references.

**Transitions.** Collapsed → Expanded: tap the comment count in the action row; media scales and slides up to the square, strip fades out, thread slides up. Expanded → Collapsed: tap `Hide Comments`, swipe down (mobile), two-finger downward gesture (Mac), or `Delete`/`Cancel` in the composer (§4.4). Selected media, playback position and audio settings persist across the toggle. Cancelling comment entry restores the previous layout without submitting.

**What toggling each element does to geometry**
- Comments open: media 926→428 pt tall, thread region appears, strip disappears.
- Comments closed: reverse. The bottom bar never moves.
- Select mode (album level): nav gains a second bar (§4.1); the feed/grid shifts down by that bar's height.
- Download/Upload panel enabled: panel grows 44→65 px tall (+48%), title goes regular→bold, pill goes 104×29→146×38 px (§4.5).
- Overflow menu open: a 246×273 pt solid sheet overlays and dims the album; layout beneath does not move.

---

## 4. `main/` components

### 4.1 `main/nav.jpg`: breadcrumb and selection toolbar (4628×928 px)
Two stacked rows.
- **Header** (`#323035`): `Main Gallery` bold white, one space, then `{currentFolder}` regular `--text-dim`. **No slash.** The image shows the literal placeholder text `{currentFolder}`; substitute the real folder name.
- **Selection toolbar** (`#1e1c1f`, about the same height as the header): left `Select All` in blue; right group a circled-ellipsis icon (blue outline, three dots) then `Cancel` in blue. All three are text/icon buttons with no fill.

```jsx
const Breadcrumb = ({ currentFolder }) => (
  <div className="breadcrumb"><strong>Main Gallery</strong>{' '}
    <span className="text-dimmed">{currentFolder}</span></div>
);
// .breadcrumb strong { color:#fff; font-weight:700 }  .text-dimmed { color:#7c797f; font-weight:400 }
```
**Geometry:** the toolbar exists only in Select mode. Hidden otherwise.

### 4.2 `main/feed.PNG`: Collections feed
- **Top:** back circle (left), centered title `Albums` (semibold 17), right side `+` and `⋯` as blue glyphs (no capsule).
- **Segmented control** below: `Personal | Shared | Activity`, three equal segments in a `--surface-1` capsule; labels blue; active segment marked by a lighter flat pill behind it.
- **Grid:** 2 columns of **184×184 square cards**, x = 24→208 and 220→404, so 24 pt side margins and a 12 pt gutter; rows start at y=161 with 12 pt row gap `[m]`.
- **Card:** photo cover, title bottom-left in white with a dark scrim, circular owner badge top-right (about 30 pt, 2 pt white ring, avatar photo or initials on gray, e.g. `DP`). A card with no title shows a people glyph bottom-left (shared indicator).
- **Floating bottom controls:** a flat `--surface-1` tab capsule `Library | Collections` bottom-left (about 189×58; blue labels, active tab on a lighter flat pill) and a 62 pt flat `--surface-1` circle with a blue search glyph bottom-right `[e]`.

### 4.3 `main/row.jpg`: "Shared Albums" row (1284×588 px)
- Header: `Shared Albums` bold about 28 pt with a gray `>` chevron; right side a dark capsule `Activity` (blue text) and a dark circle with a blue down-chevron.
- Horizontal scroller of **118×118 pt cards**, 12 pt gap, 24 pt leading inset, radius about 20 pt `[m/e]`, same badge and title treatment as feed cards.

### 4.4 `main/participation.PNG` and `main/thread.jpg`: viewer, expanded
`participation.PNG` shows the expanded viewer for an item with **no comments yet**. Below the 428-pt media:
| y (pt) | Row |
|---|---|
| 428–469 | `You liked this` (13 pt; "You" bold) `[m]` |
| 469 | hairline |
| 469–504 | `Posted by {Name} {Mon D, YYYY at HH:MM}`: name bold white, date `--text-2` |
| 504 | hairline |
| 504→ | `Add a comment…` input, 17 pt **`--blue`** (`--ctl`), no box or border; becomes the composer below |

Action row (§3.2) under the media: `Like` shows a filled thumbs-up glyph when liked, outline when not. Audio/video items also show the glass playback bar.

**Composer `[d]`.** A text field in exactly the style of `thread.jpg` (no box or border, 16 pt left padding, hairline above, 17 pt) sits **directly under the newest comment** at all times, so it moves down as comments are added. Placeholder `Add a comment…` in `--ctl` blue; typed text white. Focusing it shows `Post`, `Delete`, `Cancel` (all `--ctl` blue) right-aligned in an extra 44 pt row under the input.
- `Post`: submits and **stays expanded**; a fresh empty field appears under the new comment, so you can post consecutive comments without limit. Disabled (40%) while the draft is empty. The count becomes `X comment`.
- `Delete`: removes a comment **I posted**: my most recent one in the thread, the one directly above the field. Disabled (40%) if I have posted none.
- `Cancel`: removes the draft.
- **`Delete` and `Cancel` both return to COLLAPSED view**: media 428→926, thread hides, strip returns, time and audio bars re-anchor (§3).
- Geometry while composing: the field row grows by 44 pt, the thread scrolls to keep the field visible, the media stays 428×428, and the playback bar gives way to the keyboard.
- Who sees it: Main shows it to participants allowed to comment. Public shows it **only to me**, and I can post consecutive comments; visitors see no field and no options.

`thread.jpg` (1284×1687 px) shows the scrolled thread:
- Each comment is a row: body 17 pt white, then a meta line `**Author** Mon D, YYYY at HH:MM` (self shows as `You`). Left padding 16 pt, wrap limit about 20 pt from the right.
- One-line row pitch **52 pt**; two-line rows add 22 pt per extra line. Hairline between every row. Consecutive comments by the same author get their own meta line (no grouping).
- Order: oldest first, newest last; `Add a comment…` directly under the newest.
- Emoji render inline at body size.

`[i]` Open question: `expand.PNG` shows a comment row and input but no `Posted by` or `liked` rows. Recommended rule: `Posted by` always shows first; the `liked` row shows only when likes ≥ 1.

### 4.5 `main/panel dim.png` (585×44 px) and `main/panel vibrant.png` (585×65 px)
The **Presented-by panel**: a `#302f33` bar docked at the bottom of a shared collection, naming me and offering Download.
| | dim | vibrant |
|---|---|---|
| Height | 44 px | 65 px |
| Left label | `Presented by {Owner}` regular white about 13 pt, one line | same text bold, larger, top-left, room for a second line |
| Pill | **104×29 px**, fill `#384453`, gray text | **146×38 px**, fill about `#4193f2`, white semibold text |
| Meaning | nothing selected, Download disabled | at least one item selected, Download enabled |

Pill radius = half its height. Transition: animate height, pill size and color together (about 200 ms).

---

## 5. `common/` components

### 5.1 Item card: `common/item.jpg` (1267×1292 px, about 422×431 pt)
Album hero. Full-bleed cover image. Bottom-left: title (`Food Updates`, bold about 28 pt white), below it a line with a stack icon, `2 Items` (white, 17 pt) and a small blue circled-info icon. Bottom-right: play control as a blue triangle glyph (no badge; the screenshot's gray circle is superseded by §1.1). Inset about 15 pt from the left and bottom `[e]`.
Item-count rule from the directive: **hide the count at root level**; the count styling is bold white (the "creepy cute Halloween nail art" reference *is* this image).
**Geometry:** the hero is about 519 pt tall in the Album screen; the grid begins directly below it.

### 5.2 Album with owner menu: `common/close.PNG`
Album screen with the overflow menu open. Top: back chevron (left) and `Select` (right), both `--ctl` with no badge. Hero as in 5.1. Below: **3-column grid of square tiles about 142 pt, 1 pt gutters, edge to edge** (y about 519–665), last tile is a `#1c1c1e` tile with a blue `+` (add media). Bottom-left: blue sort/filter glyph on a flat `--surface-1` circle.
**Menu** (solid `--surface-1` sheet, not glass; x=70→316, width 246, height about 273, radius about 34): header row with 40 pt rounded thumbnail, album name bold 17, `1 Participant` gray with people icon, edit-square icon right; hairline; `Share` (share icon) and `Add Photos` (plus), both blue `--ctl`; hairline; `Delete Shared Album` in `--ctl` blue with a trash icon (wraps to two lines). Tap outside to close.

### 5.3 Participant menu: `common/leave.jpg` (1284×1190 px)
Same menu, participant variant: header shows `2 Participants`; destructive row is **`Unsubscribe`** (blue, ⊖ icon) instead of Delete. **Rule `[i]`:** my destructive action deletes the album; a participant's action only leaves it. Background is the blurred album behind. Top bar uses plain blue `--ctl` as in 5.2.

### 5.4 `common/select.png` (632×64 px) and `common/deselect.png` (633×66 px)
Crops of the selection toolbar (§4.1). `Select All` flips to `Deselect All` once everything is selected. Background `#1c1c1e`; texts and ⋯ in blue.

### 5.5 `common/delete select.jpg` (1046×258 px)
Delete bar, shown when at least one item is selected: black background, left label `N Photos Selected` (white, semibold about 22 pt `[e]`; singular `1 Photo Selected`), right a 48 pt flat `--surface-1` circle with a blue trash icon. Tapping the trash asks for confirmation before deleting.

### 5.6 `common/delete dim.png` (510×196 px)
**Filename mismatch.** This image is a *dimmed Download pill*, not a delete control. Treat it as a duplicate of the Download dim state (5.7). The actual delete visual is `delete select.jpg`; there is no separate dim delete reference (see §8).

### 5.7 `common/download dim.jpg`, `common/download vibrant.jpg`, `common/upload dim.jpg`, `common/upload vibrant.svg`
One pill, two states, two verbs.
| File | State | Spec |
|---|---|---|
| `download vibrant.jpg` (1284×199 px) | enabled | row bg `#323136`; pill **312×80 px** (about 104×27 pt), fill `#009afe`, white semibold 17 pt "Download"; 16 pt from the right edge, vertically centered `[m]` |
| `download dim.jpg` (2752×1536 px) | disabled | pill **700×192 px** at x=1952–2652, y=672–864: right-aligned (96% across), vertically centered; fill `#245170`, text `#7a8188` |
| `upload dim.jpg` | disabled | identical geometry and colors, label "Upload" |
| `upload vibrant.svg` | enabled | 150×60 viewBox; `rect x=15 y=10 w=120 h=40 rx=20 fill=#0084ff`; blue glow filter (`feGaussianBlur stdDeviation=4`, glow alpha slope 0.7); label 18 px, weight 600, white, `-apple-system` |

Both `dim` JPGs have a **checkerboard baked into the pixels** (a fake transparency preview). Do not reproduce the checkerboard; use the pill only.
Enable rules: Download enabled when ≥1 item is selected and the viewer may download; Upload enabled when the viewer has upload rights on that collection. Disabled pills ignore pointer events.

### 5.8 `common/collapse.PNG`: viewer, collapsed
Full-bleed media (see §3). Top row over a dark scrim: back chevron (left), **date/time label** centered as plain white text (two lines: `4 October` semibold, `19:19` smaller; no pill), trash and ⋯ (right), all blue glyphs. Bottom: floating thumbnail strip (selected thumb slightly larger), time bar and audio bar per §3.1, then the action row (blue: `Share`, `Like`, `Add a comment`/`X comment`) and, for audio/video, the glass playback bar: rewind, pause/play, forward. Right edge: stacked blue Live Text and mute glyphs.

### 5.9 `common/expand.PNG`: viewer, expanded
See §3. Top row: back, date/time label (`June 1, 2022` / `16:21`, plain text), ⋯ only, all blue glyphs. Below the square media: one comment (`Omg` + `Duy Phan Jun 1, 2022 at 16:24`), hairline at 480 pt, `Add a comment…` at about 501–513 pt. Time bar and audio bar inside the square per §3.1. Action row (`Share`, `Like`, `Hide Comments`) under the media; playback bar for audio/video. The composer and its `Post`/`Delete`/`Cancel` options (§4.4) sit under the newest comment.

---

## 6. Interaction matrix

| Trigger | Shows | Hides / disables | Geometry effect |
|---|---|---|---|
| Tap card | Album | feed | hero + grid |
| Tap title / (i) / ⋯ | overflow menu (owner or participant variant) | | overlay only |
| `Select` | selection toolbar, tile checkmarks | `Select` pill | content shifts down one bar |
| ≥1 selected | delete bar, Download pill vibrant | dim pill | panel 44→65 px |
| `Cancel` | restores browse mode | selection bar, delete bar | content returns up |
| Tap thumbnail | Viewer, collapsed | album chrome | media 428×926 |
| Comment count / bubble | Expanded | thumbnail strip | media → 428×428 |
| `Hide Comments` / swipe down / `Cancel` / `Delete` | Collapsed | thread, composer | media → full |
| Like | blue glyph fills, `You liked this` row | | none |
| `Post` | new comment, fresh field under it | | stays expanded |
| Rewind / pause-play / forward | seek, toggle icon | | none |
| Focus `Add a comment…` | `Post`, `Delete`, `Cancel` (blue) | playback bar yields to keyboard | field row +44 pt |

---

## 7. Public side (no references supplied)

`ui/public/` is empty. The following is **derived from the directive, not from images** `[i]`: public visitors see the Presented-by panel with Download, the viewer in both states, and **comments I wrote only**: visitors get no comment field, no like, no `Post`/`Delete`/`Cancel`, no trash or ⋯, no `Main Gallery` breadcrumb; I see the §4.4 composer and can post consecutive comments. Main shows the full two-way set. Enforce this on the server; hiding controls is not access control.

## 8. Open items in the reference set
1. `public/` has no screenshots; public-side visuals are unspecified.
2. `common/delete dim.png` shows a Download pill (name mismatch); no dim-delete reference exists.
3. Pill aspect ratios disagree: SVG 3.0:1, dim JPGs 3.65:1, Download vibrant 3.9:1, panel pills 3.6:1. Use the per-context sizes above.
4. `expand.PNG` vs `participation.PNG` disagree on the `Posted by` and `liked` rows (rule proposed in §4.4).
5. `nav.jpg` contains a literal `{currentFolder}`; no folder-name truncation behavior is shown.
6. Rewind/forward step size is unspecified (proposed: 10 s per tap). Photos have no playback bar.
7. `Delete` targets your most recent comment; say if you want to pick a specific one instead.
8. The action row (§3.2) is my placement for Share/Like/Hide Comments, since their screenshot slots now hold the playback controls.
9. Time/audio bar numbers (§3.1) are proposed defaults, not measured.
10. Screenshots still show glass on back, date pill, ⋯, `Select`, menus, and the share/like/center-pill bar (now rewind/pause/forward); §1.1 overrides them. Screenshots also show red destructive rows; those are now blue.
11. Glass blur radius, exact corner radii and animation durations are estimates; confirm on device.