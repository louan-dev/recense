# Spotify playlist: capture notes (2026-11-08)

Reference for Recense's shared playlist. iPhone 12 Pro Max via iPhone Mirroring, PNG 450 wide.
Artwork on Home did not load (phone at 3% battery).

## Captured
- **Home** (00): filter chips All / Music / Podcasts / Audiobooks, recent tiles.
- **Your Library** (01): Playlists / Podcasts / Albums chips, Recents sort, grid toggle;
  rows show "Playlist · <owner>" (Midnight · CP, Timor-Leste playlist · Cyril).
- **Playlist page** (02): 2x2 mosaic cover from the first four tracks, title, owner avatar + name,
  "1 save · 65h 40m" with a public globe, row: cover thumb, saved ✓, download, "...",
  shuffle, big Play; track rows with "..." each; mini player above the tab bar.
- **Playlist "..." (someone else's playlist)** (03): header "1 save · Public playlist";
  Share, Remove from Your Library, Download (Premium), Exclude from taste profile,
  Add to Profile, Add to other playlist, Move to folder ›, Report.
- **Share** (04, 05): a preview card (cover, title, "Playlist by CP", first 4 tracks, Spotify mark),
  3 colour dots, sideways card carousel; people row: Search, Create group, recent contact;
  apps row: Copy link, WhatsApp, Messages, Status, TikTok...
- **Track "..."** (06): Share, Add to Liked Songs, Add to playlist, Hide in this playlist,
  Exclude track from taste profile, Add to Queue, Go to radio, Go to album.

## Owner's plan for Recense (2026-11-08)
- This is how a playlist of podcasts will look in Recense. A playlist is **single** (one owner,
  like Midnight, 02) or **shared** (several people add to it).

## Shared playlist ("Collaborative public space playlist", found via Search, 07)
- **Header:** title, a description line, then **stacked overlapping avatars** + "<owner> **+ 4 others**",
  then globe + "197 saves · 28h 18m" (08, 14 = avatars loaded: logo, photo, letter "S").
- **Added-by circle:** every track's cover carries a small round avatar of whoever added it,
  overlapping its bottom-right corner (08, close-up 09).
  Tapping the circle just plays the track; it is not its own button (12).
- **"+ 4 others" -> People sheet:** each person with avatar, name, role and count:
  "Owner · 369 songs", "Collaborator · 18 songs" ... with › (10).
- **A person -> sheet:** View profile, Follow, Show Spotify Code (11).
- **Playing row:** title turns green with an equaliser icon; mini player and big button show pause (12).
- **Playlist "..." (shared, not mine):** Share, Add to Your Library, Download, Exclude,
  Add to other playlist, Report, Eat this playlist, Show Spotify Code (13).
- Track "..." is the same as on a single playlist (06); no "added by" line in view.

## Add to playlist (owner asked: add Gnossienne No.1 to Zen, 2026-11-08)
- Track "..." > **Add to playlist** opens **Save in**: Cancel / Done, New playlist, Find playlist,
  Sort, then your playlists each with a ⊕ and song count, folders with › (15).
- Tapping ⊕ turns it into a green ✓ and the count updates at once (Zen 2 -> 3 songs) (16).
  Several playlists can be ticked before Done.
- **Done** closes the sheet; no toast was caught (frames every ~0.15 s). The track row and the
  mini player now show a green ✓ in place of ⊕ (17).
- In Zen the track is **appended at the end** (3rd of 3) (18, 19).
- **Own playlist controls:** "+" beside the owner avatar (invite collaborators), Add, Edit,
  Sort, Name & details, a share icon in the action row, editable description, and
  "Recommended songs" below the tracks (18, 19). The "+" invite screen was not opened.

## Mixed-media playlist: songs + podcast episodes (owner: "its important if we mix mp3s and podcast episodes")
- Recense's playlists must hold audio files (MP3s) and podcast episodes in **one list**; Zen is the reference.
- **Adding an episode** (owner did it on the phone): the sheet reads **"Saved in"**, with
  **Your Episodes** pinned above the search (✓), and Zen's count reads **"3 songs, 1 episode"** (20).
- After Done: back on Your Episodes, the episode row shows a green ✓ (21).
- **Header updates:** the cover becomes a 2x2 mosaic of the first four items' art, the podcast art
  included; duration 10 min -> 1h 40m (22).
- **Rows differ by kind** (23):
  - **Song:** one compact line: art, title, artist, "...".
  - **Episode:** a taller card: podcast art, two-line title, show name, two-line description,
    "date · 13min left · Finished ✓" with a progress bar, then its own action row
    (..., share, download, round play).
  - The episode keeps its own listening progress inside the playlist.
- A new item goes to the end of the list; "Recommended songs" follows the list.
- A full-screen trackpad scroll (computer_batch scroll) does reach Spotify, and the header
  collapses as you scroll (23).

## Remove from this playlist (owner asked: remove Gnossienne and Kimerer, 2026-11-08)
- On your **own** playlist the item "..." gains **Remove from this playlist** and **Add note**.
  - Song menu: Share, Add to playlist, Exclude from taste profile, Remove from this playlist,
    Add note, Add to Queue, Go to radio, Go to album (24).
  - Episode menu: Share, Add to playlist, Remove from this playlist, Add to Queue,
    **Mark as not started**, Download, Show Spotify Code, Add note (27).
- Remove applies **at once, no confirmation**; the sheet slides down (25).
- A white **toast** fades in above the mini player: "Removed <full title>." (wraps to two lines
  for a long episode title); no Undo button; stays several seconds (26, 28, 29).
- Header duration updates (1h 40m -> 1h 37m -> 7 min); the mini player's ✓ returns to ⊕.
- Zen is back to its original two songs (30).

## Name & details (owner asked: write a word and save, 2026-11-08)
- Button on your own playlist opens a sheet: Cancel | "Name & details" | Save (grey until a change);
  cover with a pencil, Name field, Description box, then Make private, Delete playlist (31).
- Typing ", serene" at the end of the description turns Save green (32).
- Save: the sheet slides down; no toast (34). The header description is cut with "see more";
  tapping it expands the full text in place, now ending "... rhythmically static, serene" (33).
- The added word is still in Zen's description.

## "+" beside the owner (own playlist)
- Opens the same **People** sheet as a shared playlist, with an **Add collaborator** row (+)
  on top, then "Louan · Owner · 2 songs ›" (35). So a single playlist becomes shared from this
  sheet; single and shared use one screen. Add collaborator itself was not tapped.
- **Closing:** tap above the sheet; it slides straight down and the dim lifts together, done in
  about one frame (~0.15 s); no bounce (36 open, 37 sliding, 38 closed).

## Playlist "..." on your own playlist
- Header "Zen · Public playlist"; Share, Download (Premium), **Add to this playlist, Edit playlist,
  Name & details, Create cover art**, Exclude from taste profile, **Make playlist private** (39).
- **Swipe-down micro-interaction (owner, on device):** after pressing "...", swiping down on the
  sheet pulls the menu down with the finger (the grabber pill on top marks it as draggable);
  release to dismiss. Not recorded here: synthetic drags do not reach the phone.
  Owner first said it matches the Podcasts player pull-down (`docs/specs/ui-teardowns/UI-02-podcasts/` 74),
  then: "its not exactly the same". Owner recorded it on the trackpad (57-64):
  - **Spotify sheet:** a half-height sheet moves straight down with the finger, keeping its full
    width and size; the dim behind fades **in step with the drag** (57 open, 58 quarter,
    59 half, 60 low). It can be held low with only its header peeking (62) and pulled back up,
    the dim returning with it (63); let go low and it slides away (64).
  - After it closed, Zen showed a **"Find on this page"** search bar at the top (61): the
    downward drag carried on into the page and revealed it.
  - **Podcasts player (`podcasts-ios/` 74):** a full-screen player that drags down as a rounded
    card over the page behind, which shows at **full brightness** (no dim to fade).
  - So: the same drag-to-dismiss, but Spotify fades a dim with the drag on a partial sheet,
    and Podcasts moves a whole-screen player over an undimmed page.
  - Read from stills about 0.15 s apart; the springiness on release cannot be judged from them.
- **Closing:** tap above; the sheet slides down while the dim lifts, about 0.3 s (40 open,
  41 mid-slide, 42 closed).
- **Opening:** tap "..."; the dim starts as the sheet's top edge appears at the bottom, the sheet
  rises and settles, about 0.3 s, the mirror of the close (43 closed, 44 appearing, 45 rising,
  46 settling, 47 open).

## Make playlist private (owner asked, 2026-11-08)
- "..." > Make playlist private: the menu slides away first (49), then a centred white dialog
  **fades in** (50): "Make this playlist private?" / "Only you (and people you invite) will see
  this playlist. We'll also remove it from your profile." / green **Make private** / Cancel (48).
- The one action in this research that asks before acting.
- Confirm: the dialog fades out (51a); a white toast **"Playlist is now Private"** shows for about
  3.5 s above the mini player, then fades (51b).
- Header: the globe beside the duration becomes a **lock** (52).

## Make playlist public (owner asked, 2026-11-08)
- While private, the "..." header reads "Private playlist" and the last item becomes
  **Make playlist public** with a globe icon (53).
- **No confirmation** (asymmetric: going private asks, going public does not). The menu slides
  away (54); toast **"Playlist is now Public"** for about 3.5 s (55); lock back to globe (56).
- Zen is public again; its description still ends ", serene".

## Not captured yet
- Rows added by different people (all four in view were the owner's): needs a scroll, which
  synthetic input cannot do; the owner scrolls while the window is recorded.
- Owner-side controls (Invite collaborators, remove a collaborator, make collaborative) appear
  only on a playlist you own; making one changes the Spotify account.
- Gestures (swipe a row to queue, press and hold, drag to reorder) need the owner on the trackpad.
- Receiving end of a share link.
