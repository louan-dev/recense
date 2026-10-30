# CLAUDE.md · Sill (macOS strip app) · repo root `~/Developer/sill`

Shared plan: `../sync/PROGRESS.md` (read §2 Rules every session, plus only the section for the task named). Detail: `../sync/BACKLOG.md`, open only the section you are on. Don't re-read unchanged files or re-plan. Nothing has been run on the owner's Mac unless §7 says so. Treat every claim as a lead to verify.

## One app, three faces (settled 2026-10-28; this wins over anything that contradicts it)
**Sill is the only app. There is no Recense app and no Recense process.** `sill/sill/recense.swift` (7.4k lines) *is*
Recense: the largest and newest source here. Sill owns the window, the audio engine (`sill/soundengine.swift`), the
localhost server on port 47123, the Groq calls, the caches and the keys. Verified 2026-10-28: `/Applications/Recense.app`
does not exist, no Recense process runs, and Sill holds 47123.

- **`sill/recense/` is dead.** An older, smaller (6.5k-line) copy of the app Recense used to be, with its own `build.sh`
  and `Info.plist` that make it look alive. Never build it, never edit it, never cite it as the source of truth. It is
  reference only, pending deletion by the Nook procedure below.
- **Recense is a surface inside Sill, not a dependency.** Live transcription, karaoke light, transcript edits, looping,
  speed, EQ/Key/Space, rename, download, transcript and M4B export, retranscribe, retranslate, vocal and instrumental
  extraction, share — all of it runs in Sill, in its own window, with Gallery's Worker unreachable and no second process.
  Transcription runs on this Mac (Apple SpeechAnalyzer, `sill/speech.swift`, since 2026-10-29; Groq only for languages
  it can't hear) and caches locally; `keep/<key>/` is a mirror for sharing with Gallery, merged on read, never required.
- **Gallery is two things to Sill:** shared client code (`homebar.js`, `homebar.css`, `keylabel.js`, `room.js`, and later
  `prosody.js`/`prosogram.js`) copied into the bundle by `build.sh`; and an optional cloud side (Worker + R2) for sync.
  `gallery:files/<path>` is one source among local files and followed players, gated on `Store.r2`. Do not merge the
  projects, and do not let Recense acquire a hard dependency on the Worker.
- **Where work goes:** Recense → `sill/sill/recense.swift`. The strip → `sill/sill/sill.swift`. The tap and audio chain →
  `sill/sill/soundengine.swift`. The home-bar host page → `sill/sill/homebar/index.html` (the one `build.sh` bundles).
  Shared JS → Gallery's `src/client/`, copied by `build.sh`.

## Where things are
- App: `sill/sill.swift` (about 7.6k lines), `sill/recense.swift` (7.4k, Recense), `sill/soundengine.swift` (the process tap and EQ/Key/Space chain), `sill/build.sh`, `sill/Package.swift`, `sill/Sources/`, `sill/README.md`, `sill/scripts/`.
- `backups/` holds 19 manual `sill.swift.pre-*` snapshots. Git replaces them: keep `backups/` out of git. Never overwrite them.
- Build: `cd ~/Developer/sill/sill && zsh build.sh`. Check how build.sh compiles (single file or Sources/) before adding files, and wire new files in.
- `.gitignore` before the first commit: `.build/`, `build/`, `*.bak`, `backups/`, `.env`, `.DS_Store`. Local git only, no remote, no push until the owner names a repo.
- Sill's own rule: consequential actions go draft, confirm, execute.

## Your items (from BACKLOG §SL and PROGRESS §5)
- **SL1 Daemon efficiency.** Measure first (CPU, CPU-time growth, wakeups) and report before and after. Leads: one permanent 1 Hz timer (~line 6225) that runs `pollExternal()` (stats `draftpad.md`), `updateClock()` and `restoreState()`; four 60 Hz timers (~856, 2645, 3447, 4843); two 20 Hz meter timers (~1872, 2031); `Process()`/osascript near 4912-4920; 11 event-monitor sites; MultitouchSupport callbacks. Prefer a file watcher (NSFilePresenter/DispatchSource) over polling, and tick the clock only while visible.
- **SL2 Strip and panels.** Event-title colours, battery colours (green ≥40, yellow 30-39, red ≤29, one constant each), audio-settings mirror, wake-strip timer, remove the Claude "smarter retry" for text calendar creation. Remove the standalone DEVONthink panel (becomes a widget, PROGRESS B2).
- **SL3 Draftpad** (stays one endless `draftpad.md`), **SL4** Phi source-grounded assistant (reuse the model on the SanDisk), **SL5** voice/OCR/compression, **SL6** cleanup.
- **B1** Notes in Sill (Obsidian, Notability read-only, filesystem). **A7** Sill status chip from `views/health.json`.
- Do one item per session, update §7 in `../sync/PROGRESS.md`, then stop.

## Owner decisions: Nook folds into Sill (supersedes BACKLOG SL6 wording)
Source to import: `~/Developer/nook/main.swift` (379 lines, `BarController`, `Rule`/`RuleAction`, `Prefs`). Copy it to `reference/` in this repo first so you can read it here.

1. **Import the menu-bar hider into Sill** as its own file, controlled by a **Sill setting that can be turned off**. When on, running Sill automatically installs the two divider status items and collapses so the hidden icons are out of sight. When off: no status items, no global mouse monitors, no timers.
2. **Two tiers, as in the Nook source:** `[ always-hidden ] ┆ [ hidden ] │ ‹› [ visible ] [ system ]`. Icons are placed by ⌘-dragging them left of a divider (macOS has no API to move other apps' icons; say so in the UI).
3. **Hover to peek:** hovering the first divider reveals the **hidden tier only**. It must never reveal the always-hidden tier. Source: `Prefs.hoverToPeek` (default on), `mouseMoved()`, the "Peek on Hover" menu toggle.
4. **Always-hidden tier:** revealed only on explicit action: option-click the ‹› toggle, or the menu entry "Reveal Always-Hidden Items" (right-click or control-click the toggle). Auto-collapses after the auto-hide delay (`Prefs.autoHideDelay`, default 3 s).
5. The owner has not seen hover-to-peek or the reveal option in the built `Nook.app`, which may predate the source. Do not assume they work: make both explicit and visible in Sill's settings, test them, and report.
6. Also bring over per-app Rules mode (`hideAll`, `showAll`, `showSelection`) if it builds cleanly; keep it reversible and resilient to macOS updates (reflow is unestablished in Sill's docs).
7. Idle cost must stay near zero (SL1): the global `mouseMoved` monitor exists only while the feature is on and the pointer work is cheap.
8. **Delete the old `~/Developer/nook` folder entirely, after the import:** build Sill, confirm hover and always-hidden work, confirm nothing else depends on Nook, make a recoverable snapshot zip outside the folder, then show the owner the exact path and delete only on explicit confirmation of that exact target. Never uninstall shared CLIs.

## New Nook: a widget panel inside Sill (separate session, after the import)
Not a standalone app. A notification-center-style panel that slides out from the **right screen edge**, summoned by a **three-finger right-to-left swipe**, hosting widgets. First widget: **Find My**, embedding the Find My app view. Name undecided; candidates Exedra, Eyvan.
- Sill already reads three-finger swipes via private MultitouchSupport (experimental) for layers (up/down) and panel paging. Read the gesture code, find a gesture that does not conflict (for example a right-edge-only trigger or a different finger count), and propose it before building.
- **Spike Find My first.** macOS has no public Find My API. Report plainly whether embedding the app view is possible; if not, list the fallbacks (Shortcuts, local cache needing Full Disk Access) with their risks. Never fake data.
- Add this as a new item (SL7) to `../sync/PROGRESS.md` §7 and record the decision in §8.

## Output
No routine narration, no whole-file dumps. Report decisions, blockers, validation, next action. Label status DONE (verified) / PARTIAL / BLOCKED / PROPOSED. Commit before you start each task.
## Changelog
After each step, append an entry under ## CHANGELOG in ../sync/PROGRESS.md: date and time from `date`, item ID, status (DONE/PARTIAL/BLOCKED), what changed, validation, next action. Keep §7 current.

## Live Notes Inbox Trigger (`/Users/chauphan/Developer/sill/notes`)
- **Rule override:** The "Don't re-read unchanged files" rule at the top does NOT apply to `/Users/chauphan/Developer/sill/notes`. Treat `notes/` as a live instruction inbox that the owner may edit and save while you are in the middle of a task.
- **Session baseline:** At the start of every task, run `mkdir -p /Users/chauphan/Developer/sill/notes && touch /Users/chauphan/Developer/sill/.handoff/.notes_sync` to set the timestamp baseline.
- **Mid-task polling:** Before every build (`zsh build.sh`), git commit, or transition between sub-steps, run this fast check for newly saved files in `notes/`:

    mkdir -p /Users/chauphan/Developer/sill/.handoff && \
    CHANGED=$(find /Users/chauphan/Developer/sill/notes -type f -not -name '.*' -newer /Users/chauphan/Developer/sill/.handoff/.notes_sync 2>/dev/null) && \
    if [ -n "$CHANGED" ]; then echo "NOTES_UPDATED:"; echo "$CHANGED"; touch /Users/chauphan/Developer/sill/.handoff/.notes_sync; fi

- **Action on trigger:** Whenever `NOTES_UPDATED:` lists any files, pause your current step immediately, read the revised file(s) in `/Users/chauphan/Developer/sill/notes`, fold the new requirements or changes into your active task plan, and execute them before finishing the session.