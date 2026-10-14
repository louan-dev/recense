# Draftpad Help Guide

## 1. Test from Terminal
Run these diagnostic commands to check if the binary exists and whether multiple background processes are conflicting:
```bash
cd ~/Developer/obsidian
ls -l draftpad
pgrep -lix draftpad
./draftpad status
./draftpad hide; sleep 1; ./draftpad show
```

## 2. Reset the App
Kill any lingering background processes before performing a clean rebuild:
```bash
./draftpad quit; sleep 1
pkill -ix draftpad; pkill -ix scratchpad
pgrep -lix draftpad          # should print nothing
zsh build.sh
./draftpad &
```

## 3. Check BetterTouchTool (BTT)
* Confirm BetterTouchTool is running in your menu bar.
* Locate your **3 Finger Swipe Up → Execute Shell Script** trigger and ensure **Gesture is Enabled** is checked.
* Select the trigger row and click the play (`▶`) button at the bottom of the action pane to test it.