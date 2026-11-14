# iOS Photos video viewer: capture notes (2026-11-08)

Model for Recense's Gallery media viewer (`library/src/client/viewer-shell.js`, `viewer-sheet.js`).
iPhone 12 Pro Max via iPhone Mirroring. PNG, 450 wide (00-10 are 440).
Video: ScreenRecording_11-05-2026 11-19-33_1, 4:33, HEVC, 1284x2778, 51.15 fps.

## Viewer
- **Top:** back, centred date pill (day + time), "..." (01).
- **Bottom bar:** Share | Favorite + Info + Edit (one grouped pill) | Delete (01).
- **Playback strip:** play/pause, scrubber, mute, then a filmstrip of neighbouring items (01, 02).
- **Tap the video** hides every control; tap again brings them back (03).
- **"..." menu:** Duplicate, Hide, Show in All Photos, Slideshow, Add to Album,
  Adjust Date & Time, Adjust Location, Delete (04).
- **Live Text button** on a paused frame lifts the text and shows chips for found
  data (time, date) (24).

## Owner decision for Recense (2026-11-08)
- Owner's words: "the row with buttons and the thumbnail strip and scrubber will not be
  excluded when the same gesture happens in our sourcecode"; then "neither will the back
  button or the ...".
- Reading: in Recense's viewer, the button row, thumbnail strip, scrubber, back button and
  "..." all **stay on screen** through the swipe-up / Info shape shift; only the media changes
  shape. This differs from Photos, which fades the header (back, date, "...") and scrubber out.
- The shape shifts below are the reference for the media's own motion.

## Geometry (shape shifts)
- **Controls shown:** media is an inset card, rounded corners, black margins, scaled to sit
  between the header and the toolbar (40, 43).
- **Tap -> controls hide:** chrome fades out while the media grows to full bleed and its corners
  square off; tap again reverses it (40-42 hide, 43-44 show). About 0.3 s.
- **Double-tap:** same as a single tap on this video; no zoom seen. The video has the phone's
  shape (1284x2778), so a fill-zoom would look the same; a landscape video is needed to check (45).
- **Info open (button here; swipe up on device):** media slides up and grows to full width,
  corners square, its top runs under the status bar and is cropped; header and scrubber fade out;
  the Info sheet rises into the space below; toolbar stays with Info filled (46-49).
- **Info close:** reverse; media shrinks back down into the rounded inset card and the
  header and scrubber fade in (50-52).
- Swipe up itself was not recorded (synthetic swipes do not reach the phone).

## Info panel (slides up under the media)
- Caption field "Add a Caption" (05, 10).
- Date + time with **Adjust** (08); source file name with a cloud icon.
- Card: capture type (Screen Recording), codec badge (HEVC), a decorative ⦿ (tap does nothing),
  lens line, resolution + size, fps | length (05).
- **Add a location...** opens "Enter New Location" search (09), results by Map Locations (12).
- After choosing a place: a **map card** with the item's thumbnail pinned, the area name
  ("Mid Cambridge ›") and **Adjust** (13).
- **Show in All Photos** jumps to the Library grid scrolled to the item (25).

## Map
- Tapping the map card opens a full map: close X, map style, locate, 3D; the item sits as a
  thumbnail pin (14).
- **Show Nearby Photos** adds other photos as thumbnail pins with counts; the button flips to
  **Hide Nearby Photos** (15).
- Tapping a pin opens a "Places · N Items" grid with Select, "...", filter and Show Summary (16).

## Adjust Location and Revert
- Adjust on a set location: search prefilled with the address, a red **No Location** row,
  the place under Map Locations, and a red **Revert** button top right (17).
- **Revert applies at once, with no confirmation:** the location vanished and the panel went back
  to "Add a location..." (the video is back to its original metadata).

- **Header with a place:** the date pill gains a top line, "Mid Cambridge" over "Thursday 11:19" (38).
- **No Location** removes the place at once, no confirmation; the pill drops back to one line (39).
- Location search with no match shows "No Results ... Try a new search." (37).

## Adjust Date & Time: modify and Revert
- Sheet shows Original and Adjusted rows, a month calendar, a Time pill, Time Zone (08).
- Tapping the Time pill makes it typeable; typing 1030 sets 10:30:00, and a footnote reads
  "The original photo will be adjusted by -49 minutes, 33 seconds" (26).
- **Adjust** saves; the viewer header changes to the new time (27).
- Reopening an adjusted item: the blue Adjust button becomes a red **Revert** (28).
- **Revert applies at once, no confirmation;** the header returns to 11:19 (29).
- Same pattern as location: Revert shows only once something differs from the original.

## Slideshow ("..." > Slideshow)
- Plays full screen with music, no chrome (30).
- Tap: back, sound, "...", centre pause, mini filmstrip, Music button, grid button (31).
- Header while playing: date over the track name ("Better 4 U (Instrumental)") (32).
- **Music button -> Memory Mixes:** swipeable cards (page dots), current track + look
  ("Original"), add-music and look buttons, reset (circular arrow) top left (33).
- Add-music -> **Music** picker: Top Suggestions, Soundtracks, Apple Music Suggestions,
  Browse, Categories, See All; X and ✓ (34).
- Look button -> **Memory Looks:** 12 looks (Original, B&W Film, Noir Film, Bright, Fade,
  Contrast, Warm/Cool x Bright/Fade/Contrast) (35).
- End of slideshow: last slide dimmed with Replay, Favorite, Share (36).

## Editor (Edit / sliders icon)
- Top: Cancel, Done (disabled until a change), mute, a speed gauge, "..." (18).
- Tabs: Video (trim filmstrip with handles, play) (18), Adjust (dials row) (19),
  Filters (Original + strip) (20), Crop (straighten/aspect, rotate, flip, dials) (21).
- "..." menu: Copy Edits, Paste Edits, Save as Duplicate, Appearance ›, Undo, Redo (22).
- Speed gauge = **Playback Speed:** 100% (50 fps) / 50% (25 fps) (23).
- Cancel with no change closes at once, no prompt.

## Share
- Share sheet and its Options (06, 07).

## Not captured
- Gestures (swipe down to dismiss, swipe between items, pinch, press and hold, scrub drag):
  synthetic drags do not reach the phone; they need the owner on the trackpad while the window
  is recorded, as done for Podcasts.
- Favorite and Delete were not tapped (they change the library).
