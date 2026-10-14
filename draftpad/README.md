# draftpad

A floating, Antinote-style note window for macOS that reads and writes one markdown file in an Obsidian vault. Pages sit side by side in a horizontal strip, each page scrolls vertically on its own, and the window reopens exactly where you stopped typing. Obsidian sees the same file, so edits show up in both places within about a second.

The whole app is one Swift source file that compiles to one small executable. There's no Xcode project, no Dock icon, and no menu bar icon.

**Built and verified on:** macOS Sequoia 15.5 (2026-10-03). The universal build targets macOS 12 and later, but Sequoia 15.5 is the only version it has been tested on.

**Gestures come from BetterTouchTool.** draftpad has no gesture code of its own. The intended way to use it is to swipe it into view, jot something down, and swipe it away, and that depends on [BetterTouchTool](https://folivora.ai) running three shell commands (`show`, `hide`, `quit`) against the running app. Without BetterTouchTool, the hotkey and the command line still work. Setup is in [BetterTouchTool setup](#bettertouchtool-setup-trackpad-gestures).

> **BetterTouchTool must be running, and set to open at login.** draftpad is built to be driven by BetterTouchTool gestures: every swipe or pinch that shows, hides, or quits it is a BetterTouchTool trigger running a shell command. If BetterTouchTool isn't running, the gestures silently do nothing, so a draftpad that is still running can't be summoned or dismissed by swiping. (The hotkey and the shell commands still work as a fallback.) Turn on BetterTouchTool's launch-at-startup option, or add it under System Settings → General → Login Items & Extensions, then log out and back in and test a swipe.

## Files

| File | What it is |
| --- | --- |
| `draftpad.swift` | The source. This is the part worth keeping. |
| `build.sh` | Compiles the source and catches stray text at the top of the file. |
| `README.md` | This file. |
| `scripts/install-launchagent.sh` | Starts draftpad at login (installs, checks, or removes the login item). |
| `scripts/uninstall.sh` | Removes draftpad and everything it created, including this folder and itself. |
| `launchagent/local.draftpad.plist.template` | The login item definition. The installer fills in your paths. |
| `draftpad` | The compiled executable (about 145 KB, arm64). Rebuild it any time. Not tracked by git. |

All names are lowercase, including the note file, `draftpad.md`, which matches the project name.

The examples below assume the project lives in `~/Developer/obsidian`. If yours is somewhere else, substitute your own folder.

## System requirements and installation

draftpad is a lightweight, single-file Swift/AppKit background utility with no Dock icon. It compiles from `draftpad.swift` into one small executable, so there's no Xcode project and nothing to drag into Applications.

### Minimum system requirements

- **macOS, on Apple Silicon or Intel.** `zsh build.sh` builds for the Mac you're on, and `zsh build.sh universal` builds one binary that runs natively on both architectures. The universal build targets macOS 12 and later. Sequoia 15.5 is the only version it has been tested on.
- **An existing Obsidian vault.** draftpad reads and writes a single local Markdown file, `draftpad.md`, directly in the vault folder. It does no syncing of its own. Keeping the vault in step across devices is up to whatever you already use, such as iCloud or Syncthing. The default location is mapped to my Mac, so check [The note file](#the-note-file) before you build.
- **The Xcode command line tools**, to compile the source: `xcode-select --install`.

### Dependencies and optional tools

- **[BetterTouchTool](https://folivora.ai) (BTT), optional.** It's needed only for trackpad gestures: swipe up to show, swipe right to hide, pinch in to quit. draftpad has no gesture code of its own.
- **Everything else works without BTT.** The Ctrl+Option+Space hotkey and the terminal commands in [Commands](#commands) don't depend on it.

### Installation and setup

1. **Install the command line tools** if you haven't already: `xcode-select --install`.
2. **Put the files in place.** The examples in this README assume the project lives in `~/Developer/obsidian/`. If yours is somewhere else, substitute your own folder.

   ```
   ~/Developer/obsidian/
   ├── draftpad.swift
   ├── build.sh
   ├── README.md
   ├── scripts/
   │   ├── install-launchagent.sh
   │   └── uninstall.sh
   └── launchagent/
       └── local.draftpad.plist.template
   ```

   The compiled `draftpad` executable ends up next to `draftpad.swift`. This folder is separate from your vault, which only holds the note file.
3. **Point it at your vault.** The default note path is directed to my Mac. Edit `defaultNotePath` near the top of `draftpad.swift` to match yours, or set `DRAFTPAD` when you launch. See [The note file](#the-note-file).
4. **Build it.**

   ```
   cd ~/Developer/obsidian
   zsh build.sh              # for this Mac
   zsh build.sh universal    # or: one binary for Apple Silicon and Intel
   ```

   Plain `swiftc -O draftpad.swift -o draftpad` also works.
5. **Run it.**

   ```
   ./draftpad &
   ```

   The first launch opens the window and creates `draftpad.md` in your vault if it doesn't exist yet. macOS may ask for access to the iCloud folder. Approve it.
6. **Add the controls you want (optional).** For gestures, create three Global BetterTouchTool triggers that run the `show`, `hide`, and `quit` shell scripts in [BetterTouchTool setup](#bettertouchtool-setup-trackpad-gestures). To have draftpad start at login, see [Start at login](#start-at-login).

## Commands

Run these against the running copy from Terminal, BetterTouchTool, or Shortcuts.

| Command | Copy is running | Nothing is running |
| --- | --- | --- |
| `./draftpad` | Brings up the existing window | Launches the app |
| `./draftpad show` | Shows the window | Launches the app (add `&`) |
| `./draftpad hide` | Hides the window | Prints "draftpad is not running", exits 1 |
| `./draftpad toggle` | Shows if hidden, hides if shown | Launches the app (add `&`) |
| `./draftpad quit` | Saves and quits | Prints "draftpad is not running", exits 1 |
| `./draftpad status` | Prints `visible` or `hidden` | Prints `not running`, exits 1 |
| anything else | Prints usage, exits 64 | Prints usage, exits 64 |

Only one copy can run at a time. Launching a second copy just brings up the first.

A command's exit code only says it was sent. Use `status` to confirm what the window actually did.

## Using the window

| Do this | Result |
| --- | --- |
| Ctrl+Option+Space | Show or hide. It reopens on the last page with the cursor where you left it. |
| Two fingers up or down | Scroll the current page. |
| Two fingers left or right | The pages follow your fingers and snap to the next or previous page. Pulling left past the last page opens a new one, but only if the last page has text. |
| ⌘] and ⌘[ | Next and previous page from the keyboard. |
| Esc or ⌘W | Hide. |
| ⌘Q (while focused) | Quit. |

Drag the window by its background and resize it from the edges. It remembers its position.

With BetterTouchTool set up, three more gestures control the window from anywhere. See the table in the next section.

## The note file

Pages are separated by `<!-- page -->`, which Obsidian hides in reading view. Don't delete those lines unless you want to merge pages.

The default path is `/Users/chauphan/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian/draftpad.md`, a note in an iCloud vault named "Obsidian".

> **Disclaimer:** that path is directed to an obsidian vault nestled within an iCloud folder on my Mac for automatic syncing. Copy and paste the path where your md files populate. Otherwise, it can be modified in either of two ways:
>
> - **Permanently:** edit `defaultNotePath` near the top of `draftpad.swift`, then rebuild with `zsh build.sh`.
> - **For one launch:** set the `DRAFTPAD` environment variable, as in `DRAFTPAD=/path/to/draftpad.md ./draftpad &`. It only applies to a copy you start from a shell with the variable set. The BetterTouchTool show script and the login item don't pass it, so they use the default path.

If you already have notes in a file with a different name, rename that file to `draftpad.md` in your vault before the first launch. Otherwise draftpad starts a new, empty note.

Other settings (`panelSize`, `fontSize`, the hotkey) are at the top of `draftpad.swift`.

## BetterTouchTool setup (trackpad gestures)

**BetterTouchTool is required for gestures only.** The Ctrl+Option+Space hotkey and the shell commands work on their own, without it.

BetterTouchTool (BTT) is what turns trackpad gestures into the `show`, `hide`, and `quit` commands. draftpad never receives a gesture directly, so BTT is the only gesture source and nothing can double-fire.

Create all three triggers under **Global** (the "All Apps" entry in BTT's app list). A trigger set under a specific app only fires while that app is frontmost, and draftpad never becomes the active app.

| Action | Gesture |
| --- | --- |
| Show | 3 Finger Swipe Up |
| Hide | 3 Finger Swipe Right |
| Quit | 5 Finger Pinch In |

The gestures are examples, and any BTT trigger can run these scripts. For each one, choose the action "Execute Shell Script / Task" with `/bin/zsh` as the interpreter, and paste the matching script. The scripts assume the project is in `~/Developer/obsidian`. Change the path if yours is elsewhere.

**Show** (3 Finger Swipe Up). It launches draftpad if it isn't running yet:

```
P="$HOME/Developer/obsidian/draftpad"
if pgrep -ix draftpad >/dev/null; then "$P" show; else nohup "$P" >/dev/null 2>&1 & fi
```

**Hide** (3 Finger Swipe Right):

```
"$HOME/Developer/obsidian/draftpad" hide
```

**Quit** (5 Finger Pinch In):

```
"$HOME/Developer/obsidian/draftpad" quit
```

The show script launches the app on first use, so you don't strictly need a login item. If you want draftpad running before your first gesture, see [Start at login](#start-at-login).

Before relying on the gestures:

- In System Settings → Trackpad → More Gestures, set Mission Control, App Exposé, and "Swipe between full-screen apps" to four fingers or off.
- Make sure no other Global trigger uses the same gesture. Two Global triggers on one gesture both fire.
- Check that BetterTouchTool is running. If it isn't, the gestures do nothing.

### Keeping a copy of the triggers

BTT stores its configuration in its own database, not in this folder. The table above is enough to recreate the triggers by hand. If you also want machine-readable copies in this repository, right-click each of the three triggers in BTT, choose **Copy JSON**, and save the result:

```
mkdir -p bettertouchtool
pbpaste > bettertouchtool/show.json     # repeat for hide.json and quit.json
```

Don't commit a full preset export. It contains every trigger you've configured, not just these three.

## Start at login

> **Two things need to start at login, not one.** The login item below starts draftpad. The gestures also need BetterTouchTool running, so make sure it launches at login too (see the note at the top).

A per-user LaunchAgent starts draftpad when you log in.

```
cd ~/Developer/obsidian
zsh scripts/install-launchagent.sh            # install (builds the binary first if it's missing)
zsh scripts/install-launchagent.sh status     # installed? loaded? running?
zsh scripts/install-launchagent.sh remove     # stop starting at login; the app and your notes stay
```

What to expect:

- The note window opens at every login, because draftpad shows its window whenever it launches. Press Esc to hide it.
- The agent stores the full path of the binary you built, so if you move this folder, run the installer again.
- It starts the app once per login and doesn't restart it. After `./draftpad quit` or `pkill`, draftpad stays quit until the next login or your next show gesture.
- Output goes to `~/Library/Logs/draftpad.log`.
- The first time it runs, macOS may ask for access to the iCloud folder. Approve it.
- On macOS 13 and later, System Settings → General → Login Items & Extensions may list it under "Allow in the Background". Leave it on.

A bare executable isn't an app, so Login Items isn't a good fit for draftpad. That's why start-at-login uses a LaunchAgent.

## Verify it works

Run this after every rebuild. It reports what the window did, not just whether a command was sent.

```
cd ~/Developer/obsidian
pgrep -lix draftpad
./draftpad status
./draftpad hide;   sleep 0.5; echo "after hide:   $(./draftpad status)"
./draftpad show;   sleep 0.5; echo "after show:   $(./draftpad status)"
./draftpad toggle; sleep 0.5; echo "after toggle: $(./draftpad status)"
./draftpad toggle; sleep 0.5; echo "after toggle: $(./draftpad status)"
./draftpad quit;   sleep 1;   echo "after quit:   $(./draftpad status)"
./draftpad hide;   echo "hide-when-stopped=$?"
```

Expected results, in order: `hidden`, `visible`, `hidden`, `visible`, `not running`, and `hide-when-stopped=1`. The first two lines should show one process and `visible`.

Then run these by hand:

1. **Pages and memory:** type `test1` on page 1, swipe left with two fingers past the end to open page 2, type `test2`, run `./draftpad quit`, then `./draftpad &`. It should reopen on page 2 with the cursor after `test2`. Swipe right with two fingers and return to 'test1' on page 1.
2. **Obsidian sync:** edit the note in Obsidian and watch draftpad update within about a second. Edit the note in draftpad and watch Obsidian update.
3. **One copy only:** swipe right with three fingers, run `./draftpad &` twice, then `pgrep -lix draftpad`. It should print one line.
4. **Gestures:** try each of the three BetterTouchTool triggers with a different app in front, and once while a full-screen app is in front.
5. **Keyboard:** while typing in the window, press ⌘W. It should hide.
6. **Start at login:** run `zsh scripts/install-launchagent.sh`, log out and back in, then run `pgrep -lix draftpad`. It should print one line, and `zsh scripts/install-launchagent.sh status` should say `loaded`.

Last verified: macOS Sequoia 15.5, 2026-10-03.

## Troubleshooting

- **Compile error mentioning "Draftpad · SWIFT" or other text on line 1 to 4:** stray text from a download card was pasted above the code. Delete everything above the `// draftpad.swift` line, or re-download the file. `zsh build.sh` detects this.
- **`no such file or directory: ./draftpad`:** the build failed or you're in the wrong folder. Run `cd ~/Developer/obsidian` and build again. The vault folder doesn't contain the source.
- **Several windows or copies:** run `pkill -ix draftpad`, then `pgrep -lix draftpad`. The second command should print nothing. The `-lix` flags use a lowercase L, not the number one.
- **Not in the Force Quit list:** expected. The app has no Dock icon, so macOS doesn't list it. Use `./draftpad quit`, or find it in Activity Monitor.
- **Esc does nothing:** a hold-Esc shortcut from another tool may grab it first. Use ⌘W.
- **The note can't be created on first launch:** macOS may be asking Terminal for access to the iCloud folder. Approve the prompt, or add Terminal under System Settings → Privacy & Security → Files and Folders.
- **A gesture does nothing:** check that BetterTouchTool is running, the trigger is under Global, and no other Global trigger or macOS gesture uses the same motion.
- **The window pops up at every login:** expected when the login item is installed. Press Esc, or run `zsh scripts/install-launchagent.sh remove` if you'd rather launch it with a gesture.
- **It doesn't start at login:** run `zsh scripts/install-launchagent.sh status`, then read `~/Library/Logs/draftpad.log`. If you moved the folder or rebuilt somewhere else, run the installer again.
- **A binary copied from another Mac won't open:** run `xattr -d com.apple.quarantine draftpad`, then `codesign --force --sign - draftpad`. Rebuilding on the new Mac avoids this.

## Keeping it durable

The source is the asset. The binary is disposable and takes seconds to rebuild.

- Keep the project in a git repository, and let Time Machine back up the folder too:

  ```
  cd ~/Developer/obsidian
  printf '%s\n' '/draftpad' '.draftpad-*' '.DS_Store' '*.log' > .gitignore
  git init -b main
  git add .gitignore README.md draftpad.swift build.sh scripts launchagent
  git commit -m "draftpad: initial version"
  ```

  Then create a repository on your git host, add it with `git remote add origin <url>`, and push. Don't add your note file, chat transcripts, or a full BetterTouchTool preset export to a public repository.
- Your notes live in the Obsidian vault, not in this folder, so they survive independently of the app.
- The scripts use `$HOME`. The one hardcoded path is the default note location, which you can change in `defaultNotePath` or override with `DRAFTPAD` (see [The note file](#the-note-file)).
- The app uses only public macOS APIs and has no dependencies beyond the command line tools.
- Record the macOS version you last verified on in the "Verify it works" section. If a future macOS update breaks something, that tells you where to start.

## Moving to a new Mac

1. Copy `draftpad.swift`, `build.sh`, `README.md`, `scripts/`, and `launchagent/` to the new Mac. Migration Assistant, git, or iCloud Drive all work.
2. Install the command line tools: `xcode-select --install`.
3. Let the Obsidian vault finish syncing.
4. If your username or vault location differs on the new Mac, edit `defaultNotePath` in `draftpad.swift` first.
5. Build on the new Mac with `zsh build.sh`. If you copy the binary instead, it only runs on the same chip family.
6. In BetterTouchTool, export your preset on the old Mac from the Preset menu and import it on the new one, or recreate the three triggers above. Those scripts use `$HOME`, so a different username doesn't matter for them.
7. Run `zsh scripts/install-launchagent.sh` if you want it to start at login.
8. Approve any permission prompts the first time it runs, then run the verification block.

Your window position and last-viewed page are stored by macOS in your user preferences, not in this folder. They reset on a new Mac, and nothing else is lost.

## Uninstall

```
cd ~/Developer/obsidian
zsh scripts/uninstall.sh --dry-run    # lists everything it would remove and changes nothing
zsh scripts/uninstall.sh              # removes it, after you type the folder name to confirm
```

It removes the running app, the login item, the saved window position and page, the log and temp files, this whole project folder (and its parent folder if that leaves it empty), and then the script itself.

It stops without removing anything if git shows uncommitted changes, unpushed commits, or no remote. Use `--force` to override that check, and `--yes` to skip the typed confirmation.

It leaves these alone:

- Your note file in the Obsidian vault.
- BetterTouchTool and its triggers. Delete the three Global triggers by hand.
- Your online git repository.
- Shared tools such as the Xcode command line tools and Homebrew packages.

## Design notes: why there's no Dock icon

draftpad runs as a background-only app with a non-activating window. Showing it doesn't take focus from the app you're typing in, it can appear over full-screen apps and on every Space, and it adds no Dock or Cmd-Tab entry. The trade-offs:

- macOS never lists it as an app, so Force Quit and the Dock can't see it. Use `quit` or Activity Monitor.
- It never becomes the frontmost app, so BetterTouchTool app-specific triggers can't target it. Global triggers don't care, which is why all three triggers above are Global.
- Permission prompts may name the app that launched it (Terminal or BetterTouchTool) instead of draftpad.

## Future directions / discussion

Ideas and open questions that the current code doesn't implement. They live here so that every section above describes only what draftpad does today.

- **A portable default note path.** The default is customized to my Mac. Use it as a template. Resolving it from the home folder would make it work under any username. Reading it from a config file, or from the login item's environment, would let the BetterTouchTool and login-item launches honour a custom path too, so nobody has to edit the source.
- **An `.app` bundle and a menu bar item.** Wrapping it in a bundle would add a bundle identifier, a proper name in prompts and Login Items, and an icon for Finder. It would not change how gestures reach it. A menu bar item is the lighter alternative if you want a visible handle.