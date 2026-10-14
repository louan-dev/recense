# Sill V0.1

A quiet panel at the top center of the screen with two surfaces:

- **Time** (default): the current time and date, small. It never takes keyboard focus.
- **Pad**: Draftpad, unchanged. Same paged strip, same `draftpad.md` in the Obsidian vault, same cursor memory.

One Swift file, built into `Sill.app` (so macOS shows it as "Sill" in Settings), plus `./sill`, a lowercase command for the terminal that runs the app's executable. No Dock icon, no menu bar icon. Built on `../draftpad/draftpad.swift`; the pad, file sync and paging code is carried over as is. `../draftpad/` itself is untouched and still works as a fallback.

## Build and run

```
cd ~/Developer/sill/sill
zsh build.sh
./sill &               # opens the time view
```

## Gestures

Layers (three fingers): hidden → essentials → Draftpad. Up goes one layer up, down one layer down.

| Where | Two fingers right → left | Two fingers left → right |
| --- | --- | --- |
| Essentials | Back toward essentials (the first panel; nothing before it) | Next panel: essentials → DEVONthink hub → notebook (Obsidian + Claude CLI) |
| Draftpad | Back toward the first topic; leaving a blank topic deletes it | Next topic; past the last one, a fresh topic opens, dated at the top |

The left bar (recorder / volume), right bar (vault / brightness) and bottom bar (R2) show on hover, on every panel.

Sill reads three-finger swipes itself (native, no BetterTouchTool needed). This uses Apple's private MultitouchSupport framework because macOS has no public API for system-wide three-finger swipes. It needs no permission prompt, ignores the Touch Bar, restarts after sleep, and is **experimental**: a macOS update could break it. `SILL_GESTURES=0 ./sill &` turns it off. Each detected swipe is logged to `~/Library/Logs/sill.log` when Sill runs from the login item.

It assumes macOS's own three-finger swipes are off (they are on this Mac: System Settings → Trackpad → More Gestures).

BetterTouchTool fallback: point any BTT trigger at `zsh ~/Developer/sill/sill/scripts/gesture.sh up` (or `down`, `hide`, `quit`). A double-fire from BTT plus native within half a second is ignored.

## Other controls

| Do this | Result |
| --- | --- |
| Click the time | Open the pad |
| Click the small time at the top of the pad | Back to the time view |
| Ctrl+Option+Space | Toggle the pad |
| Esc or ⌘W (in the pad) | Hide |
| Two fingers left, ⌘] | Next topic, deeper into the note. Past the last topic: start a new topic (appended to the bottom of `draftpad.md`). |
| Two fingers right, ⌘[ | Back toward the top. The first topic is a hard stop. |

## Commands

`./sill up | down | pad | time | show | hide | toggle | quit | status | background`

`status` prints `time`, `pad`, `hidden` or `not running`. Show-type commands launch Sill if it isn't running; `background` launches it hidden (the login item uses this).

## Start at login

```
zsh scripts/install-launchagent.sh           # install local.sill
zsh scripts/install-launchagent.sh status
zsh scripts/install-launchagent.sh remove
```

## Notes

- Draftpad and Sill both edit `draftpad.md` and both claim Ctrl+Option+Space, so run one at a time.
- Sill copies Draftpad's last page and cursor the first time it starts. Its own settings live in the `sill` defaults domain.
- The panel is fixed at the top center of the screen under the pointer; it is not draggable or resizable in V0.1. Sizes are at the top of `sill.swift`.
