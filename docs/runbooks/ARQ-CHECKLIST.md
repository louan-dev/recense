# ARQ-CHECKLIST.md · A2 backup gate · 2026-10-13

Status: PROPOSED. The owner does this in Arq's GUI; nothing here has been automated or run.

## 0. What is on this Mac (checked 2026-10-13)
- `/Applications/Arq.app` is **Arq 5.7.8** (2019-era, legacy). No backup sets are configured (`~/Library/Arq/config` has only `app_config.plist`), the agent is not running, and Arq 5 has no CLI (`arqc` does not exist; its AppleScript suite only handles license URLs). 
- ==Arq 5.7.8 working on macos 15.5==
- SanDisk: `/Volumes/SanDisk`, 932 GiB exFAT, 796 GiB free. No Arq data on it yet.
- ==Don't use==
- Internal disk: about 12 GiB free, so dataless iCloud files must be materialized in batches (§3), not all at once.
- ==Note that icloud is set to optimize storage, note the distinction otherwise proceed==

- **Owner decision (2026-10-13): stay on Arq 5.7.8.** No CLI, so everything below is GUI; `backup-status` reports snapshot count as unknown for the Arq 5 layout and relies on the restore drill. Menu labels below are from Arq 5 memory: verify them on screen.
- ==No cli cornfirmed, client only--
- **exFAT caution:** the ledger hung on this SanDisk when macOS's `copyfile` also copied extended attributes (fixed in `src/ledger.mjs` by copying plain bytes). Arq 5 has not been seen writing to this drive yet: superseded: the destination is now R2 (§1).
- ==SanDisk not reliable source for data, goal is to evacuate out, and use s3 as the destination folder. I've configured. See 1.
## 1. Destination: Cloudflare R2 (owner decision 2026-10-14: the SanDisk is not a reliable destination)
1. Cloudflare → R2 → Create bucket **`arq`** (not `gallery-main`/`gallery-public`, not `notes`).
==there are two buckets: 5c22ec9b24a71b800fdd895001f64c23-arq for encrypted and sdddc3t00g46-sandisk for unencrypted data.
2. R2 → Manage API tokens → **Object Read & Write, scoped to `arq` only**. Keys go in the password manager, not this repo.
==sync-backup is the api token name accessing the two buckets in 1 .  i am putting the keys below for convenience.
access id: [redacted: password manager]
secret access key: [redacted: rotate this token, it was pasted in plain text 2026-10-22]
3. Arq 5 → Preferences → Destinations → + → **S3-Compatible Server** (label from memory; verify): server `https://<account-id>.r2.cloudflarestorage.com`, the token's keys, bucket `arq`. If Arq 5 insists on creating its own bucket, stop and tell Claude: a bucket-scoped token cannot create buckets.
==i let it create its own bucket. there was no other alternative to connect to s3. it was not acknowledging the bucket i made solely for the purpose of plugging the keys and endpoint to arq. its okay though, i found a workaround, and besides you are not wrong, arq can't create a bucket. arq inaccurately uses "bucket" for "folder." arq just created a folder within the bucket i made. i just deleted the folder, made a bucket using the generated name and gave sync-backup permission to read and write it.  i added via rclone config. currently stuck at the part of migrating the 140 gb of data via copy . sync-backup:sdddc3t00g46-sandisk --progress. write time was really slow so i cancelled. what i want to try next is copy r2 with autoresume , erase, reformat to APFS, move back the phi 3.5 and set up phi 4. my plan is below. you can edit anything below if there is a better approach.

---
REFINEMENTS TO THE SCRIPT WELCOMED; *open to trying transferring from windows 11 PC. the female is usb a, the male is usb-c and i would be transferring via a usb a female to male usb c adapter. so unsure about write speed. also unsure about ram, internal space, specs, would be useful to know what specs to look out for on the PC for the move.* 

osascript -e 'quit app "Ollama"' 2>/dev/null; pkill -ix ollama

sudo mdutil -i off /Volumes/SanDisk
diskutil list external
diskutil unmount /Volumes/SanDisk && diskutil mount readOnly disk4s2

cat > ~/sandisk-evac.sh <<'EOF'
#!/bin/zsh
SRC="/Volumes/SanDisk"
DST="sync-backup:sdddc3t00g46-sandisk"
LOG="$HOME/sandisk-evac.log"
OPTS=(--size-only --transfers 1 --checkers 2
      --s3-upload-concurrency 2 --s3-chunk-size 64M
      --s3-disable-checksum
      --retries 1 --low-level-retries 2
      --exclude ".Spotlight-V100/**" --exclude ".fseventsd/**"
      --exclude ".Trashes/**" --exclude ".TemporaryItems/**"
      --exclude "Data/phi/**"
      --log-file "$LOG" --log-level NOTICE)

cd ~
rclone mkdir "$DST" || { echo "Can't write to $DST - fix the remote first"; exit 1; }

for n in {1..20}; do
  until diskutil info "$SRC" >/dev/null 2>&1; do
    echo "$(date +%T) waiting for the drive to come back..."; sleep 10
  done
  echo "$(date +%T) attempt $n"
  rclone copy "$SRC" "$DST" "${OPTS[@]}" --progress && break
  echo "$(date +%T) stopped - letting the drive cool 90s, then resuming"
  sleep 90
done

**stability test**

diskutil info "$SRC" >/dev/null 2>&1 || { echo "Drive not mounted - can't verify"; exit 1; }
rclone size "$SRC" "${OPTS[@]}"
rclone check "$SRC" "$DST" "${OPTS[@]}" --one-way \
  && echo "VERIFIED: every file on the drive is in R2 at the same size" \
  || echo "NOT VERIFIED - do not erase. See $LOG"
EOF
caffeinate -i zsh ~/sandisk-evac.sh

**delete if pass**

diskutil list external physical
diskutil eraseDisk APFS SanDisk GPT /dev/disk4

dd if=/dev/zero of=/Volumes/SanDisk/stress.bin bs=1m count=4000
sudo purge
dd if=/Volumes/SanDisk/stress.bin of=/dev/null bs=1m
rm /Volumes/SanDisk/stress.bin

**if still failing, inspect the power, heat, controller, diagnose and rethink**

log show --last 10m --info --predicate 'process == "kernel" OR process == "diskarbitrationd"' | grep -iE 'usb|disconnect|reset|overcurrent|timeout|i/o error' | tail -30

---
1. Set an Arq encryption password (password manager). Arq encrypts before upload, so R2 only ever holds ciphertext.
==the arq encryption password: [redacted: password manager]
2. **Size against R2's free tier (10 GB storage/month):** vault ~0.2 GB, Clips 1.3 GB, `~/Developer` 2.0 GB before excludes, Documents/Desktop and dotfiles small. Expect ~3–4 GB. Leave iCloud Drive out of Arq; the ledger covers it. Arq 5's budget setting: 8 GB, so thinning stays under the free tier.
3. **Unverified:** Arq 5.7.8 against R2's S3 API. First backup: only the vault. If it fails (signature/region errors: R2 wants region `auto`, aliased `us-east-1`), the fallback is the ledger to an encrypted R2 remote (`rclone crypt`), which already has `restore` and `verify --deep`.
==questions for you: 

==clarify the scope of the selected backup folders is meant to accomplish arq backup. im having a hard time figuring it out. i guess the perk is theres scheduled backups. still. the selection of folder paths is not adding up, help me see the fuller picture. why is facebook messenger, email attachments, message attachments , where do they go, theyre a backup too?  is this different from keeping notes in a unified r2 bucjet? i also dont know what files to put in encyrpted whether arq has an unencrypted version or if its all encrypted by default. this would goagainst our plan of actually being able to view or documents from anywhere without downloading from a web gallery. i also dont know whether it serves me at all to have encrypted files because im very forgetful so i dont want to risk losing access to anything i upload because im choosing something for the name of agency over my data and have the decision be so unsubstantiated against how i literally function in real life how im literally prone to forget and misplace things, and how ive literally lost all my emails on proton before when resetting the passwod that i started not to like proton anymore because it was too secure and unforgiving/uncompromising with my neurodivergence, no safety features, i didnt know the previous version so when i logged in using a new password it wiped all my emails that were in the inbox. i dont want that to happen again im trying to think of the long term consequences and i dont think im that important to hack lol. i dont even dare encrypt raven, its the embodiment of my mentor who i admire so much my atlas while im free on my own, so i absolutely cannot take any chances with raven even if i have to be less secure. back to arq, its similr to what ledger.mfs is coded to do - the mirror points to obsidian, webdav exports pdf of .nbn so they can be readible on obsidian. i would also add devonthink to the mix as the search layer. need a way of implement that fits with the overall objectives.  my own requirement is a configuration that works well in foreign languages slavik, cyrlic, pictographic languages, arabic, nonlatin, etc, as an example french law lectures and readings in the native language, live transcriptions, i really will count on dictation to aid my learning and need to translate readings , files , ebooks in french (it can be any language really because in my profession i will be working in cross border contexts) thats why i favor obsidian for the source of truth as well for the main plugin engine, the notability for the annotations, and the devonthink for more research in addition im not quite sure

==does it fit our objective to make one api token for backups and then add buckets for every media source eg notes, attachments, chats, split, it by encryption type. the gallery, gallery-main, gallery-public was a very well thought about plan, im wondering if we can keep that thoughtful efficient backend routning going , i feel like by making sync-backup its just like a random token very loosely integrated because its not interwoven into gallery at all and i feel like i could do more? idk. since we defined sync as the engine under what gallery is capable of, and gallery is sort of mirroring the invisible aspects of sync but sync is what makes gallery and recense truly powerful idk, all the backnd and api has been so thoughtfully designed and routed in galery i feel like doing it myself just makes me feel like its lacking something like it is such an abrupt addition so something that is so functional, like its the random nail popping out in a very fine tuned / tight knit system lol, it doesnt feel tied in enough . maybe thats the point and it shouldnt? idk. maybe its fine as it is?

==tell me whether its a smart long term play to back up this folder.
'/Users/chauphan/Pictures/Photos Library.photoslibrary'==

==i also found out the true location of my notability notes is in this folder. is it worth backing up a folder in arq? encrypted or unencrypted bucket? the goal is to be able to edit copies and have ledger capture the changes two ways. i heard theres. a watch function. advise. add to progress.md if you see compatibility with goals
'/Users/chauphan/Library/Mobile Documents/ZP9ZJ4EF3S~com~gingerlabs~Notability/Documents'

==do we upload the path '/Users/chauphan/Library/Mobile Documents/com~apple~CloudDocs', instead of obsidian since it lives in this path? or do we uploadthe obsidian icloud and icloud as paths? because it is confirmed obsidian lives in the icloud folder, why would you upload the parent and subfolder when you can just upload the parent ==

==should i ditch icloud? is it cheaper per month to downsize to 5 gb and keep everything on cloudflare?==
## 2. Backup plan (one plan, destination R2 `arq`)
**Sources**
- `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian` (the vault)
- Notability in-app export folder: _owner names the path_ (Notability → Settings → Auto-Backup, PDF + Note). Never the `…~gingerlabs~Notability` container.
- `~/Documents`, `~/Desktop`
- `~/Developer`
- Dotfiles: `~/.zshrc`, `~/.zprofile`, `~/.config`, `~/.ssh`, `~/.gnupg`, `~/.npmrc`, `~/.ledger` (Arq encrypts; these hold keys, so the Arq password matters)
- `~/Library/Mobile Documents/iCloud~com~apple~clips` (Clips projects, 1.3 GB, fully local; A3 row 2: back up, pass the drill, then the owner deletes old projects in Clips)
- ~~iCloud Drive~~: not in Arq (R2 free-tier size); the ledger mirrors it

**Excludes** (Arq: plan → Edit → Exclude, wildcard rules)
`/Volumes/**` · `~/Library/Caches` · `**/.Trash` · `**/node_modules` · `**/.build` · `**/build` · `**/DerivedData` · `**/*.bak` · ledger sinks and stages (`/Volumes/SanDisk/ledger/**`, `/Volumes/SanDisk/stage/**`) · `~/.ollama`, `~/.nvm`, `~/.docker`, `~/.android` (re-downloadable) · `.env` stays included (encrypted) but never in git

**Schedule:** hourly. Thinning: hourly for 24 h, daily for 30 days, weekly after that, inside the 8 GB budget (§1.5). Formerly: no budget cap on the SanDisk at first.

## 3. Materialize before backing up (a placeholder is not a backup)
`AUDIT.md` shows 443 dataless files (13.3 GB), 12.7 GB of them in iCloud Drive's `.Trash`. Outside the trash about 0.6 GB is cloud-only (WhatsApp backup tars, Obsidian attachments, Drive/Downloads). Batch them through the ledger so only one batch sits on the internal disk at a time:
```
node src/ledger.mjs run --source "<folder>" --sink /Volumes/SanDisk/ledger/<name> --materialize --stage-dir /Volumes/SanDisk/stage --apply   # ledger sink; moving to R2 is pending owner OK (see PROGRESS A5)
```
Recently Deleted (`.Trash`) items are not backup sources; the owner decides about them in A3.
==emptied icloud drive. im not sure what you're asking, for anything i didnt complete, finish it for me==
## 4. Gate: verified restore
1. Run the first backup; wait for it to finish.
2. Arq → Restore → pick 3–5 files from the vault (include one attachment) → restore to `~/Desktop/arq-restore-test` (not over the originals).
3. Check:
```
node ~/Developer/sync/src/ledger.mjs backup-status --source "$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian" --restored ~/Desktop/arq-restore-test
```
Pass = exit 0, every restored file's sha256 equals the source. Result is kept in `~/.ledger/backup-status.json`. A3 stays blocked until this passes.
==i believe this has been done now, please double check==