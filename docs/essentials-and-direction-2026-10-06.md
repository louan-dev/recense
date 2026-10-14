# Sill: essentials panel and direction model (2026-10-06)

From Chau's design message on 2026-10-06. To be merged into 01_CURRENT_STATE, 04_IDEAS and 06_DECISIONS.

## CURRENT (built 2026-10-06)

- Every surface uses one panel size (460 × 320 pt), so switching never shrinks or grows the panel.
- Gesture levels: three-finger up goes hidden → Draftpad → essentials; three-finger down goes back one level.
- The time is a pyramid: local time top center, Vietnam (Asia/Ho_Chi_Minh) bottom left, US Eastern bottom right. The clocks show for 2.5 s, then each folds into its own bar. Hovering the clocks unfolds them, then shows the Salem, OR weather in °F. Moving away tucks the weather in, then folds the clocks.
- Local bar color = time until the next timed Apple Calendar event in the next 24 h: red ≤ 1 h, yellow ≤ 6 h, green > 6 h, gray if there's nothing. The 1 h red threshold encodes the "it takes about twice as long" rule (≈30 min of real room). These are a starting point, not a settled hierarchy.
- The next 4 Calendar events are listed under the clocks.
- Launcher row: Calendar, Voice Memos, iCloud Drive, and every shortcut in a Shortcuts folder named "Sill".
- Weather comes from Open-Meteo, Sill's only network call: one request every 30 min with fixed Salem coordinates. Switch: `weatherEnabled`.
- Permissions: Calendars (full access), and Accessibility for the three-finger scroll filter. The binary is ad-hoc signed as `local.sill`, so every rebuild needs Accessibility turned off and on again.

## NEXT (selected, not built)

- **Terminal panel**: a third panel, reached by going up to essentials and then swiping left with two fingers. It needs a real terminal emulator (SwiftTerm), which is Sill's first package dependency and means moving from one swiftc file to a Swift package. That's worth doing deliberately, not in passing.
- **Copy Share Link**: it's a Finder Quick Action (`~/Library/Services/Copy Share Link.workflow`). Quick Actions act on a Finder selection, so the easiest way to use it from Sill is to remake it as a shortcut and put it in the "Sill" folder.
- **AirPods battery**: readable from Bluetooth when connected.

## EXPLORING / constrained

- **iPhone and iPad battery**: macOS has no public API for this. The system Batteries widget uses private frameworks. Either accept a fragile private path, or show only Mac and AirPods.
- **Timers as deadlines**: the Clock app's timers aren't readable by other apps. Calendar events (and possibly Reminders with due times) are the reliable sources of "next deadline".

## FUTURE / declined for now

- **Password manager inside Sill**: declined. Bitwarden isn't installed as a Mac app here (it's likely the browser extension). Rebuilding a password manager adds security risk for no gain. A launcher button for the Bitwarden app is fine if it gets installed.
- **R2-backed Markdown syncing to Cloud Lab**: FUTURE, a separate conversation. `draftpad.md` stays in the iCloud Obsidian vault.
- **Right side: clipboard, file drop, file shelf**: FUTURE. The direction is reserved now.
- **Two-finger swipe right from essentials**: unassigned on purpose.

## Direction model (DECISION, proposed wording)

- **Left = iterative, ephemeral** (live thought, the terminal, scratch). **Right = documenting, storing** (clipboard, shelf, files).
- **Up = open or resurface, down = close.** One more level per swipe.
- **Ambidextrous rule (proposal):** a gesture names where you go, not which way content slides. "Swipe left" always means "go to the left thing", whatever the natural-scrolling setting and whichever hand is used. The mapping is symmetric, so each direction has one meaning, and no gesture relies on a dominant-hand reach (no corner or edge-only triggers).
- **Draftpad: topics, not pages (DECISION, Chau, 2026-10-06).** `draftpad.md` is one continuous top-down document divided into topics. A two-finger swipe left moves deeper, to the next topic. Swiping left past the last topic ends that topic and starts a new one, appended at the bottom of the file. A swipe right moves back toward the top of the document, and the first topic is a hard stop: nothing can be created before it. Within a topic you scroll vertically from its start to its end. This is how the paging already worked; only the name changes (page → topic). The divider in the file stays `<!-- page -->`, which Obsidian hides, so the vault still reads as one long note.
