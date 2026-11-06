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
- **Language menu:** shows on hover over the line (Mac) or a tap on the line (mobile). Order left → middle → right: **Vietnamese, English, French**, above Loop / A / B. *Moved into the transcript editor by item 57.*
- **Visual effect:** for audio, drop the Gaussian blur (lyrics already sit on a black background). Use a transparent, holographic "naked" effect like the EQ curves, on or below the bar. The time bar moves exactly as it does now; only its hitbox changes. **For videos only, item 38 supersedes this** (frosted glass on the horizontal bar).
- **Above the line:** a horizontal barrel roll, so menus slide in threes.
- **Slides** (navigated by swiping over the menu, per item 39, which supersedes tap count):
- **Hover rule (all slides):** every item lights up blue on hover, like the Vietnamese · English · French trio. This includes the playback speed control. Fix every slide that lacks it.
  1. **Text size menu**: three segments that reveal on slide. Left icon makes text smaller, middle shows the zoom value (tap resets to 100%), right icon makes text bigger. Moving the mouse away closes it. Design brief: playful three-segment geometry, unorthodox but instinctive, futuristic, sleek, visionary, in the player's design language, something new. Must have exactly three segments.
  2. **Rename · Change Cover · Delete Cover** (grouped triplet)
  3. *(Moved into the transcript editor by item 57.)* **Download · Retranscribe · Transpose · Share** (the outer appearance must be 3 items: fold icons onto each other to keep the 3-item rule). Retranscribe is one button that retranscribes and retranslates, wired to the selected language. Download, Transpose, Share: make icons for Download and Transpose, make all three white, and move them inside the homebar menu. Remove the Download button from the info menu. Their menus still pop up on click, but with **no fill and no border, white**. They turn **blue only on hover or selection**.
  4. **Add a comment…**: *superseded by item 41*, which keeps it centered below the thumbnail strip, not in the homebar. Colors still apply: Tapping opens the comment view. With comments it shows **"n comments" in blue**. With none it shows **"Add a comment…" in white**. Each media has the right to preview how many comments there are. With the comment bar inside the homebar, decide how new comments should be displayed. Remove its current spot below the thumbnail strip.
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
- Allow playback on locked screen.

### Recense only
*Items 53, 54 and 57 supersede parts of this section: the vertical bar is Gallery's 1:1 (EQ included, no bookmark list on hover), and language, Download · Retranscribe · Export, and the bookmarks live in the transcript editor.*
- Embed the **same vertical bar** as Gallery, rescaled to fit the window. ~~It's a stripped-down version that differs in scale: **no EQ curve**.~~ *(item 54)*
- ~~**Hover over the vertical bar** shows the bookmark locations as a vertical list: no border, no fill, white text on black, as a vertical barrel. Think Bitwarden's transparent carousel in Recense, but front-facing and flat (not sideways or jagged).~~ *(items 53, 54)*
- Same opacity slider gesture as Gallery.
- Horizontal homebar **excludes**: the Rename/Cover trio, Add a comment, and Transpose/Share trio.
- Horizontal homebar **includes**:
  - press the bar → set a bookmark
  - hover → bookmark menu
  - slide 1 → language
  - slide 2 → text size menu
  - slide 3 → Loop · A · B, record/shadowing function at A-B.
  - slide 4 → playback speed ruler
  - slide 5 → Download played audio · Retranscribe (one button: retranscribe + retranslate, wired to the selected language) · Export as MD · M4B. This is more than 3 items, so fold icons onto each other to keep an outer appearance of 3.
- Menu bar settings: **remove Play** (CC on/off does the same thing).
- Same hover rule: every slide item lights up blue on hover.

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
9. *(Resolved in P2: Retranscribe joins the Download slide in both apps, folded to 3 items.)* **ensure** retranscribe combines retranslation and retranscription, and is wired to the selected language. and ensure there is a retranscribe button on gallery and recense within the horizontal homebar consistent with the design choices.
10. Semitone labels are inconsistent. on some tracks they display as numbers instead of root + extension, i.e., m/maj, T/t, + accidental, i.e., #, b, natural, H (b narutal), B (B flat)
11. Changes on the media, i.e. selected notation mode, eq settings, prominence settings,  do not stick when creating a share link.
12. **Baked-in download** broken.
13. Recense freezes
14. pre viewable document files don't show their thumbnails (gallery)
15. redundant en - vi - fr tab on top right (recense)
16. move the horizontal and vertical bar in the black zone above the thumbnail (gallery mobile website)
17. recense is transcribing ads on genius
18. displayed transcriptions and audio freezes, sometimes separately sometimes together (recense)
19. clicking inside viewport and pressing space outside the window should pause/unpause
20. recense menu icon should light up when its work, and dim when its not working/not 
21. there is a static sound followed by silent audio when descending the vertical slider
22. unable to open/edit transcripts on all media. use anatolia.mp3 in main gallery as a case study. tapping on clicking on the lyrics does not open the editor.
23. gallery viewer showing on "follow" instead of "learn" mode
24. visions, diaspora shows up on transcriptions *Owner 2026-10-27: drop, case-insensitively, a standalone segment that is only one of: `Thank you.`, `Thanks for watching!`, `Um`, `Thank you for watching.`, `Subtitles by the Amara.org community`, `Visions, diaspora`, `Visions diaspora`, `[BLANK_AUDIO]`, `[Music]`, `[Applause]`; one constant holds the list.*
25. take out borders around a, 100%, and A. it should match the art style as the loop-a-b menu wherein they appear to be icons floating above the homebar and selecting them highlights them blue. for other slides within the homebar, keep the icon, take out their words underneath, e.g., take out the word download, leave the download icon exactly where it is. do this for every component on the slide.
26. Please update the CSS for the text containers so that the text automatically wraps and stays strictly bounded within the visible viewport without overflowing off-screen.
27. bring back the old learn mode view. learn mode is currently displaying one line at a time, this is problematic as it clips time off from the last word being displayed 
28. *(See P2 Recense: remove Play from menu bar settings.)* the play menu within the homebar wasn't removed
29. pressing the yellow button on the recense window, i.e.having recense in the background with loop on doesnt allow audio to continue looping from a different tab
30. add an option in the vertical homebar a way to strip the vocals and just keep the background sound, e.g., make a song into an instrumental (extractor). the function should live inside the vertical homebar, similar to the slides in the horizontal homebar. it should follow the transparent aesthetic
31. media tiles are displayed as their thumbnails instead of being a black background when you view a track, that way the transparency of the homebars dont clash with the cover art.
32. the CC on/off function in the menu settings hides window instead of being wired to play/pause from whatever tab its on
33. the transcription display doesnt show the old learn mode view, two lines, original language first, selected language trailing the original language. restore in recense AND gallery.
34. gallery in localhost has no way of protecting others from going inside of it. it needs to ask for touchid.
35. pause/unpause doesnt work when you open a file in gallery. currently only plays when you refresh which brings you back to the root, then click back into the file . for example, going from qua con me, exiting out to root, going to the walton.flac for the first time doesnt let you play it unless you refresh the page, are redirected back to the root, click back into the viewer for the walton.flac and click blank the viewport, i.e. area where the cover art is.
36. refresh takes user to root instead of staying on the page viewing the media
37. allow to skip ads from within recense
38. FOR VIDEOS, apply a macOS-style frosted glass effect to the horizontal bar. currently, only vertical homebar has it. It needs a backdrop blur (`blur(16px)`), a dark semi-transparent background (`rgba`) so it darkens whatever scrolls underneath it, a very subtle 1px white border with low opacity to catch the light on top, smooth rounded corners, and a soft drop shadow for depth
39. the horizontal homebar slides by clicking the bar instead of horizontally swiping over the menu inbounds. left swipe goes forward and right swipe goes to the previous slide. 
40. there should be a vertical widget menu within the vertical homebar . swiping up and down the menu - not the bar - the inbounds of the menu - brings you forward and back. add a chord detector widget. if there is a transcription, the detected chords display directly above the transcribed text. If there is no transcription, the chords display where the transcribed text would be and follow the harmonic changes. if the key was modified after selecting the transcribed language, i.e., the trailing language, the chord notation displays the most recent selected key. if the transcribed language was set to vietnamese, and later in the EQ settings, for example, the notation was switched from Tông to ton, the chords will be notated in ton, i.e., solfege in french. if there are no adjustments to the key beyond the selected language, the default notation is wired to selected language. i.e., the slide that appears upon hover over the homebar, i.e. Vietnamese - English - French
41. restore the original position, i.e., centered below the thumbnail strip, of the Add a comment.../ n comment. where there is no comment , the text color is white. where there is a comment, the text color is blue.
42. make download destination a temporary r2 bucket that self deletes *Owner 2026-10-27: draft the lifecycle rule (bucket, prefix, days) before anything touches production; baseline abort incomplete multipart after 1 day, expire only temporary prefixes (`tmp/`) after 1 day, never root media or backups. Proposal: `docs/proposals/r2-lifecycle-42.md`.*
43. make a quick action from macbook . right click > move to gallery main > select destination 
44. option to select language, learn/follow view, download, export as mc, export as m4b, should exist inside the transcript editor
45. downlaod in the download-transpose-share trio should be replaced with retranscribe, in which retranscribe and retranslate are folded into the retranscribe button and wired to the set language.
46. **Recense icon does nothing** (since the Recense app was folded into the strip app, then named Sill): pressing the Recense icon used to show an opaque window; now nothing happens. Recense commit `f609d0a` (branch `claude/exciting-lumiere-9b0e58`) reports a fix; verify it and finish it if needed. Priority in P3a.
47. for the prominence setting on the vertical bar, at 0% to 50%, i.e., under 50%, the light follows the selected language while the original language is being pronounced. above 50% until 90%, the light follows the original language. above 90% the light doesnt follow any letters, because there are none to display.
48. **(Recense) Strip date, left of the battery.** *Format and order superseded by item 61* (time, then "Mon, 26 Oct", then battery). The original recipe, for reference: a shared `DateFormatter` just above `final class BatteryRow: NSView {`; a `date` label above `battery` in the strip's properties, set up like the battery (`roundedFont(11, .semibold)`, white at 0.85) and added to `content` between `countdown` and `battery`; in `layoutStatic()` the date takes the battery's old spot and the battery moves right; the tick sets it right after `weather.stringValue = ""`.

49. **(Recense, P3a)** The Recense window doesn't follow the global play/pause button (the keyboard's ⏯, Recense's strip ⏯): its play state and highlighting stay as they were.
50. **(Recense, P3a)** Swipe and long hold on the Recense window's home bar don't behave like Gallery's horizontal home bar. The time ruler must share the window with the displayed lines without taking over the view: no clipped text, no overlap, no crowding, and the window keeps its shape (no growing or shrinking when the ruler opens).
51. **(Recense, P3a)** The Recense window doesn't follow volume changes made in QuickTime. Volume must follow the volume controls of any media source. *Owner's decision (2026-10-26): add a volume control to the Recense window that follows and sets the playing source's own volume.*

52. **(Gallery + Recense: the shared vertical bar) Tare must not block the EQ.** Today a tap on the bar while it is blue resets everything, so once the EQ has been changed the tray can't be opened again to keep adjusting it. Adjusting is iterative: the tray must open as many times as wanted. Tare stays on the vertical bar, but it must resist accidents and forgive them. *Decision (owner may overrule):* a tap always opens or closes the tray and never resets; tare is a deliberate **press and hold** on the bar (a ring fills while you hold; let go early and nothing happens); after a tare, a tap on the bar within a few seconds **undoes** it. *Owner confirmed 2026-10-27: a single tap never resets (too easy to trigger by accident); the long press tares/resets to zero.*
53. **(Recense) Remove the bookmark mark that appears when hovering the player.** It is out of place. Bookmarks move inside the transcript editor (item 57).
54. **(Recense) The vertical bar mirrors Gallery's 1:1 and shares its code.** Same functions as Gallery's (prominence, the tray with Low · Mid · High, C/Đô, Reverb, tare), rescaled to the window. *Supersedes P2 "Recense only": "a stripped-down version… no EQ curve" and "hover over the vertical bar shows the bookmark locations".*
55. **(Gallery) Bar positions.** On iPhone 12 Pro Max, portrait and landscape, the horizontal and vertical bars sit too high: lower them. On the MacBook they are close but something is off: bring them closer to the thumbnail strip.
56. **(Gallery) Transcript under the browser chrome.** On iPhone 12 Pro Max in landscape the top half of the transcribed text is covered by the browser's address bar and the date and time strip. The transcript must adapt to the orientation and stay inside what is visible.
57. **(Gallery + Recense) The transcript editor holds the tools.** Clicking or tapping the transcribed text opens the transcript editor (today it does nothing). Inside it: **language** (Vietnamese · English · French, moved out of the horizontal bar's hover), **view mode** (Follow · Learn), **Clear** (clears the whole transcript, e.g. an instrumental misheard as words), **Download**, **Share**, **Transpose**, **Retranscribe** (retranscribe and retranslate in one button, wired to the selected language), **Export as MD**, **Export as M4B** (M4B is the endpoint: the intermediate file it makes today is folded into it). In Recense also the bookmarks (item 53). All of these leave the horizontal bar. *Supersedes, as to where they live: P2 "Language menu", slide 3, Recense slides 1 and 5, and items 44 and 45.* Same in Gallery and in Recense.
58. **(For an ultracode run) Hi-fi sound throughout audio edits**: EQ, C/Đô, reverb, speed, the extractor, and every download with the sound baked in.
59. **(Recense) Learn mode: two lines per page, recovered.** The light crosses the bottom line; when it finishes, the bottom line stays and the next line fades in slowly at the top; the light crosses the top line; when it finishes, the next line fades in where the bottom line was, while the top line stays; and so on. Each line is one complete thought. Every line is the **same size**, uniform from the first transcribed line to the last (none bigger or smaller). The selected language trails the original. *Same as items 27 and 33 for Recense; supersedes the one-line barrel (§6).*
60. **(Recense) Swipe and hold holds the ruler.** The gesture must not only bring up the time ruler: while held, the ruler stays up at the playhead's current position as the audio plays, until you let go. Gallery's home bar already does this; mirror it in the Recense player.
61. **(Recense) Strip order: time, date, battery.** Left to right: the time as `hh:mm:ss`, then the date as `ddd, ## mmm` (three-letter weekday, a comma, the day, three-letter month: "Mon, 26 Oct"), then the battery. *Supersedes item 48's "Mon 26 Oct".*

62. **(Gallery) Semitone labels as note names in every notation mode.** On C/Đô (and every other mode) the Key label shows numbers (`+2`) on some tracks. It must read as a note: C/D/E/F/G/A/B or Do/Ré/Mi…, with m/maj, T/t and accidentals, across ALL notation modes. *Restates item 10.* *Owner 2026-10-27: with no key detected, show `Key: —`, and the offset only when shifted (`Key: — (+2 st)`, `— (−1 st)`); never a made-up root such as C.*
63. **(Gallery) Changing the key on `anatolia.mp3` (main gallery) in the vertical bar froze the audio and the page; a refresh doesn't recover it.**
64. **(Gallery + Recense) Take the Play · −15 · +15 trio out of the horizontal bar.**
65. **(Gallery + Recense) The slides' swipe hitbox.** Today a swipe changes slides only with the pointer on an icon. The swipe area is the rectangle above the stroke, as wide as the bar (its start to its end) and as tall as the tallest icon: every speed, the gaps between them and the space between A and B included. Two fingers left/right (one finger on mobile) move forward and back; past the last slide comes the first.
66. **(Recense) Text Size above 100% cuts off the top lines.** The text must wrap inside the viewport at every size; if there is a size past which two lines can't reliably show at once, cap the magnification there.
67. **(Recense) Return in the transcript editor saves and puts the window back to its size** (it must not stay elongated).
68. **(Recense) Too much space under the horizontal bar.** Use the centre bottom bar of Recense's essentials window (the one controlling R2) as the model: both the horizontal and the vertical bar very close to the edge, with the same space under them as R2's.
69. **(Gallery, iOS) Lock screen Now Playing.** On iPhone 12 Pro Max and iPad Air M3, when Gallery media is playing and the screen locks, the Now Playing scrubber keeps working, and the widget shows the media's real title (not "Music" for every file).
70. **(Recense + Gallery) Videos in Recense.** Video files from Gallery also show in Recense (so far only audio). Reference file in R2: `ScreenRecording_10-24-2026 23-06-12_1.mov` (30 s), to check that the audiovisual embed works inside Recense.
71. **(Gallery) Notes 23: the home bar fits the black band on a 12 Pro Max** (portrait and landscape, each its own dimensions). Built by another session; test "Notes 23" in ui.test.mjs.
72. **(Recense) Notes 24: the editor holds the whole transcript** on a vertical barrel (before above, after below); scroll or click a line to save, jump there and edit it.
73. **(Gallery) Notes 25: only a tap sets the speed**; a swipe over the speeds turns the slide.
74. **(Gallery) Notes 26: MacBook slide swipe**: a light two-finger swipe turns the slide; a swipe that starts over the slides is theirs to the end, never Time Seeking.
75. **(Gallery) Notes 27: audio goes on in the background** (browser left, phone locked): the audio session is "playback" and interrupted Web Audio asks to resume.
76. **(Gallery) Notes 28: the karaoke light keeps time at every speed**, 0.5× to 2×.
77. **(Gallery) Notes 29: Edit left of Delete** in the swipe reveal; editing changes the text, never the posted time.
78. **(Recense) Notes 30: Recense's tray shapes the sound itself** (native chain for every followed player, Gallery pages included; the page's chain is only the fallback).
79. **(Gallery) Notes 31: [Ambient Sounds] only on black**, the cover as the thumbnail.
80. **(Recense) Notes 32: Recense's tray has everything Gallery's has**, working without Gallery: EQ, Key, Space, the extractor, the chord detector.
81. **(Recense + Gallery) Notes 33: the light as a picture of the voice** (features.json): swell, lift, shiver, thin, soft.
82. **(Recense) Notes 34: the prominence slider works as in Gallery** (the trailing language stacked under the original at their opacities).
83. **(Gallery) Notes 35: a held two-finger swipe on a MacBook keeps the ruler's place** while the media plays; the next hand movement lands there.
84. **(Recense) Notes 36: a⁻ and A⁺ go the right way**: Text Size only grows with A⁺, up to what fits.

85. **(Recense) Notes 37: the strip reads time · date · the four icons (Side Quest, recorder, ⏯, Recense) · batteries**, so the icons never reach the event name.

*Source of 71–84: `~/Developer/recense/notes/20261026 Notes.md` items 23–36 (appended by the owner 2026-10-27 ~05:55).*

*Source of 49–70: `~/Developer/recense/notes/20261026 Notes.md` (62–70 added 2026-10-27 from notes the owner appended after 61).*

*Note: item 45 supersedes P2's folded Download slide in Gallery. The trio becomes Retranscribe · Transpose · Share, so no folding is needed. Item 57 then moves the trio (and Download) into the transcript editor.*

### P4
embed recense within sill. it should be a menu within the left vertical bar. the menu becomes its own page similar to clicking the right vertical bar > bitwarden. the page is a viewport embed in recense. fill color of recense = fill color of recense. 
