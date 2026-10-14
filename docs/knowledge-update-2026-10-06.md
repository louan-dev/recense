# Knowledge update — 2026-10-06 (Sill V0.1)

Entries to merge into the Knowledge files.

## 06_DECISIONS.md

### 2026-10-06 — Native three-finger gestures via MultitouchSupport (EXPERIMENTAL)

**Decision:** Sill reads three-finger swipe up/down itself using Apple's private MultitouchSupport framework. BetterTouchTool stays as a fallback (`scripts/gesture.sh`) until the native path has held up in daily use on the M1 MacBook Pro.

**Why not public APIs:** NSEvent global monitors don't deliver system-wide three-finger swipes. Public swipe events only reach the frontmost app's windows, and only when macOS is configured to produce them.

**Trade-offs accepted:** private API, so a macOS update can break it; it only reads touches and cannot suppress them, so macOS's own three-finger gestures must stay off (they are off on this Mac); no permission prompt was needed on macOS 15.5. The Touch Bar is ignored. Listeners restart after wake. Magic Trackpad hot-plug is not handled yet (restart Sill).

**Supersedes:** "BetterTouchTool as Scaffolding" is now the fallback path, not the primary one.

### 2026-10-06 — Gesture mapping settled

Three-finger swipe up → Draftpad (pad). Three-finger swipe down → time view. Repeating the same swipe hides the panel. The old BTT export that mapped swipe up to `draftpad hide` was stale; the live BTT trigger already ran `show`.

### 2026-10-06 — Sill V0.1 builds on Draftpad, does not replace it

`~/Developer/sill/sill/sill.swift` is derived from `draftpad.swift`; the pad, file sync, paging and cursor-memory code is unchanged. `~/Developer/sill/draftpad/` is kept intact as a working fallback. Same canonical `draftpad.md`.

## 01_CURRENT_STATE.md (replace the stale lines)

- Source now lives at `~/Developer/sill/` (`draftpad/` and `sill/`), not `~/Developer/obsidian/`. The old LaunchAgent `local.draftpad` and the BTT triggers still pointed at the old path on 2026-10-06, so they were silently broken.
- CURRENT: Sill V0.1 — top-center panel (time view default, Draftpad as second surface), no Dock icon, native three-finger swipe up/down (experimental), hotkey Ctrl+Option+Space, CLI `sill up|down|pad|time|show|hide|toggle|quit|status|background`.
- Remove "fully native global gesture capture" from "Not Yet Established"; it is now EXPERIMENTAL, pending daily-use verification.

## 09_CHANGELOG.md

- 2026-10-06: Sill V0.1 built on Draftpad. Native three-finger gestures added (experimental). Gesture mapping settled (up = pad, down = time).
