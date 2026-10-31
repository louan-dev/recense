# Essentials layer: decisions (2026-10-07)

To merge into 06_DECISIONS / 01_CURRENT_STATE / 04_IDEAS.

## DECISIONS (Chau, 2026-10-07)

- **Design language = Chau's media player:** black glass, one calm blue at varying intensity, bioluminescent cyan as the only accent. No iridescence and no red. Every control is a line until reached for.
- **Shelf: REJECTED** (built, then removed). The usage ranking stays and is meant to decide which menu bar icons stay visible.
- **Clocks:** all three show on open, then each sinks into its own line at a different moment. Hover a line to raise that clock; dwell on its number for the weather.
- **Day strip:** keep the existing slider geometry (straight rows, rounded numbers, haptic snaps). Only space it out and center it.
- **Horizon (time rail):** no knob. A small dark dot ringed in bioluminescence marks now. Hover it and swipe two fingers right, and the glow stretches into the future. Units go hours → days (>24 h) → weeks (>7 d) → months (>3 w) → years, stacked ("1 mo 2 w"), with a haptic at each unit. The bioluminescent tone takes over the blue the further out you reach. Calendar events and Reminders with due times sit on it, brighter when sooner.
- **Left edge bar = recorder:** click records with the last sources, click again pauses, double-click stops. The live level is drawn on the line; dwell to slide out the full controls.
- **Right edge bar = vault:** click → Touch ID → vault. Two fingers up/down = brightness (EXPERIMENTAL, private DisplayServices). Canceling Touch ID → notebook (Obsidian + Claude CLI, with read-aloud). NEXT: the notebook is not built yet.
- **Home bar (bottom):** hover → shortcut pills.
- **Awake strip:** batteries, one global play/pause (the system media key), and the next event in blue. The resting strip stays blank.
- **Third panel (double swipe up, then two fingers right):** the terminal becomes a **DEVONthink hub**. NEXT.
- **Stats bar:** undecided (Chau will think about it).
- **Selective messages:** wanted. Full Disk Access is OK, and a Telegram bridge exists. NEXT: how the bridge delivers messages is still unknown.
- **Quick event capture from the pad** ("dentist fri 3pm" → Calendar event with an alarm): proposed, not yet confirmed.

## Constraints noted

- macOS 15.4+ restricts MediaRemote, so "is anything playing" can't be read reliably; the pause button shows whenever the strip is awake.
- Clock-app alarms and timers can't be read by other apps; Calendar alarms and Reminders can.
- iPhone/iPad battery: no public API.
- The notebook sends content to Claude (cloud) when asked, so it needs a disclosure when it opens.

## 2026-10-08 (round 5)

- **Layers inverted:** three fingers up: hidden → essentials → Draftpad. In essentials, new panels come in with two fingers right → left; Draftpad is a layer above.
- **Draftpad topics:** two fingers left → right starts the next or new topic, and each fresh topic opens with today's date centered on its first line (a compass, not a title; plain text in draftpad.md). Right → left goes back, and leaving a blank topic deletes it. The first topic is a hard stop. Time does not show in Draftpad.
- **Edge bars on every panel**, contextual (shown on hover).
- **Awake strip:** previous / new / next desktop; the next event reads "Wed +1 d 3 h" (today's weekday + time from now), in white.
- **Horizon:** fingers resting hold the reach; resting still for 0.5 s pins it (ring at the tip); it draws back slowly 3 s after the fingers lift.
- **Empty days** look ahead 3 days from that day; rows show date · time (or All day) and the location.
- **Audio:** in a test-tone check, computer audio was captured in both audio and screen recordings. The two-track mixdown is now an explicit mix (an export preset could drop a track), and recordings default to the Mac's built-in mic. AirPods as the mic force their low-quality call mode.

## 2026-10-08 (round 6)

- **Essentials panels flow left → right (two fingers):** essentials → DEVONthink hub → notebook. Right → left goes back. The terminal panel is removed.
- **DEVONthink hub:** search across DEVONthink, the Global Inbox by default, drop files to import into the Global Inbox, click to open in DEVONthink (AppleScript; it leaves DEVONthink closed unless asked).
- **Notebook:** the Claude CLI running in the Obsidian vault, with Read aloud for the selected text. Claude is a cloud service, and the panel says so. It's no longer reached by canceling Touch ID.
- **Awake strip:** the next event reads "NOW +x", where NOW is the anchor: the current moment. The new-desktop button is replaced by Mission Control, between the ‹ › desktop arrows.
- **Repeating events** show once on the horizon (the next occurrence). Empty days fall back to whatever comes next.
