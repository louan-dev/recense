---
name: recense
description: Open one part of the Recense repo to work on. `/recense <file | word | space>` finds the target (a file name, a feature word like player, hider, sync, ask, share, calendar), loads that folder's guide and PROGRESS section, and opens or reuses that area's worktree so several CLIs can work at once.
---

# /recense <target>

The repo is `~/Developer/recense` (one repo, separate apps; see the root `.claude/CLAUDE.md` table).

## 1. Find the target (stop at the first hit; if two match, ask one short question)
1. **File name:** `git -C ~/Developer/recense ls-files | grep -i -- "<target>"`. One hit: that file. Several in one folder: that folder.
2. **Feature word** (map):
   | word | where |
   |---|---|
   | player, homebar, home bar | `library/src/client/homebar.js` (+ `homebar.css`), the player in `library/src/client/gallery.js`; bundled into `strip/` by `strip/build.sh` |
   | keylabel, key, room, prosody, prosogram, cadence | `library/src/client/<word>.js` |
   | strip, clock, battery, draftpad | `strip/app.swift` |
   | listen, transcript, karaoke, recense | `strip/recense.swift` |
   | sound, eq, tap, engine | `strip/soundengine.swift` |
   | hider, menu bar, nook | `strip/hider.swift` |
   | lyrics | `strip/` (grep `lyrics`) |
   | library, gallery, worker, share, viewer | `library/src/` (`main.js`, `client/sharedview.js`, `client/gallery.js`) |
   | ask, assistant, ai, index | `library/src/ai.js`, `library/src/client/assistant.js` |
   | dav, webdav | `library/src/dav.js` |
   | apple, ios, ipad, iphone, mobile, files app | `mobile/` (shared Swift: `shared/`) |
   | sync, ledger, canary, md-mirror, docs-sync, mount, disks | `sync/` (`src/ledger.mjs`, `src/canary.mjs`, `bin/*.zsh`) |
   | calendar, caldav | `calendar/` |
   | plan, progress, backlog, spec | `docs/` |
3. **Code search:** `/usr/bin/grep -rIl --exclude-dir=node_modules --exclude-dir=.build-sdk27 -- "<target>" ~/Developer/recense/{strip,library/src,sync,calendar}` and take the folder with most hits.

## 2. Load the guide
- `strip/` → root `.claude/CLAUDE.md`; `library/` → `library/CLAUDE.md`; `sync/` → `sync/CLAUDE.md`.
- `docs/PROGRESS.md`: read §2 (Rules) and only the section for this area.

## 3. Open or reuse the area's worktree
- Area = the top folder (`strip`, `library`, `sync`, `calendar`, `docs`).
- If this session is already in a worktree for that area, stay. Otherwise:
  ```
  cd ~/Developer/recense
  git worktree list | grep -q "/.claude/worktrees/<area> " || git worktree add .claude/worktrees/<area> -b work/<area> main
  ```
  then work in `~/Developer/recense/.claude/worktrees/<area>` (optionally `git sparse-checkout set <area> docs`).
- Never build the installed app from a worktree: `strip/build.sh` installs to /Applications. In a worktree, build only to check it compiles, and let autoupdate install from `main`.
- Handoff from a worktree: `~/Developer/recense/.handoff/<area>/HANDOFF.md`.
- Done: commit on `work/<area>`, then from the main checkout `git merge --ff-only work/<area>` (or rebase first), and `git worktree remove .claude/worktrees/<area>`.

## 4. Report
One line: the target, the folder, the worktree, and the PROGRESS section loaded.
