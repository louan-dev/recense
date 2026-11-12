# iOS Podcasts: capture notes (2026-11-08)

iPhone 12 Pro Max via iPhone Mirroring. PNG, 440x964. Mac files: 25-*.

## What screenshots cannot show
- **Speed slider haptics:** one haptic tap per speed increment (owner, on device).
- **Row swipe haptics:** swiping an episode row, left or right, gives a vibration haptic (owner, on device).
- **Word highlight is live:** spoken words turn bright as they are said; the active line is bold;
  upcoming words stay dim (13, 13b, 17).

## Hidden interactions found
- **Swipe right on an episode row** -> Mark as Played (purple, stretches for a full swipe) + Play Next (orange); vibration haptic (owner) (70, 71).
- **Scroll a list** -> large title collapses into the nav bar (73).
- **Swipe the full player down** -> it shrinks back toward the mini player, following the finger (74).
- **Swipe the mini player up** -> the player sheet grows out of it (75).
- **Swipe Up Next cards sideways** -> carousel pages card by card (76).
- **Play Next** (from a row swipe) adds the episode under Queue, with Clear and drag handles (78).
- **Drag the scrubber** -> chapter bar and title follow the new position (79: back to Introduction).
- **Pull down on Home** -> refresh spinner above Up Next (80).
- **Show Episodes list** has All / Unplayed / Played / Downloaded tabs (81).
- **Hold a row, show cover or episode** -> lifted preview + menu; hold menus add **Add to Queue**,
  Follow/Unfollow, Settings (show), Mark as Unplayed, which the '...' menus lack (82-85).
- **Search field focused** -> Recently Searched with an Apple Podcasts / Library scope switch (86).
- **Half swipe right** shows labels under the buttons: Played, Play Next (88).
- **Hold a downloaded episode** -> menu adds red **Remove Download** (89).
- **Episode page, bottom:** Transcript preview 'Automatically transcribed', then Information:
  Show, Frequency, Published, Length, Rating (87). Video episodes show the video at the top (90).
- **Transcript page** shows chapter headings inline ('Electrolysis Basics') (91).
- **Swipe LEFT on a downloaded episode** (Library > Downloaded > show) -> Save + red Remove Download;
  a full swipe removes the download at once, no confirm (92-95).
- **Swipe right toggles:** on a played episode the button reads Unplayed (96).
- **Swipe back from the left edge** -> previous page slides in with the gesture (72).
- **Press and hold a transcript line** -> Play / Share from <time>... / Select Text... / Report (40).
- **Select Text** -> full transcript page with handles; menu Play, Copy, Share from <time>,
  Find Selection, Look Up, Translate, Search Web (43, 44). Translate opens the default
  translation app (DeepL here) (45).
- **Tap a transcript line** -> playback jumps to that line.
- **Swipe sideways on the speed steps** -> fine slider "Adjust Playback Speed" with ticks (31).
- **Press and hold a card or episode row** -> lifted preview + Download/Save/Share + menu (46, 62).
- **Press and hold the chapter bar or a chapter row** -> same as a tap (opens list / jumps).

## Share-from
- Sender: share sheet header "From Start >" -> Options: From Start / From <current time> (20-23).
- Transcript line share pre-sets "From <line time>" (41).
- AirDrop to own Mac: phone shows Waiting... then Sent (24, 24b).
- Receiver (Mac): Podcasts opens the episode with "Play from 17:50" (25-1..3).

## Chapters (The Daily, auto-generated)
- Chapter bar under the title; list labelled "Automatically created", numbered, with lengths;
  current chapter shows time remaining; past chapters dim (50, 51, 55).
- Chapter heading inside transcript; scrubber segmented by chapter (50).
- Chapter name prefixes the title in player and mini player (52, 53, 56).

## Not captured (mirroring limits)
- Synthetic drags and scrolls do not reach the phone; swipes were done by the owner on the
  Mac trackpad while the window was recorded once per second (70-96).
- **Row swipes are bidirectional on every episode** (owner, on device), each side with its own icons:
  one side: Played (Unplayed if played) + Add to Queue / Play Next (71, 96, 97);
  other side: Save + Download; Save flips to Unsave (orange, crossed bookmark) when saved and
  Download (blue, down arrow, widest = full-swipe action) flips to Remove Download (red) when
  downloaded (93, 98, 99).
- Below-the-fold content of most pages (87 shows one episode page's bottom).
- Mac Podcasts is blocked for computer use by policy; 25-* are full-screen Mac captures
  taken before that was known.
