# sandisk-evac.md · empty the SanDisk to R2, reformat APFS, models back · 2026-10-22

Status: PROPOSED. The owner runs every step; the erase is irreversible. Based on the owner's script in `decisions/20261022 ARQ-CHECKLIST.md`.

## What decides the speed (measured 2026-10-22)
- **Upload: 52.7 Mbps ≈ 6.6 MB/s.** 140 GB ≈ 6 h at full saturation, realistically 7–9 h. This is the ceiling on any computer on this network, so a Windows PC is not faster for the network part.
- Uplink responsiveness is "Low" (963 ms under load): a saturated upload makes everything else on the network sluggish. Use `--bwlimit` in the day, none overnight.
- The drive: the ledger hung and got EIO on this exFAT volume under macOS 15's FSKit exFAT driver (`mount` shows `fskit`). If the copy stalls again, that driver is the prime suspect, not the cable.

## Changes to the owner's script and why
| Change | Why |
|---|---|
| Find the partition by name, not `disk4s2` | Earlier `mount` showed the volume on **disk4s1**. Wrong ID = wrong volume. |
| **Remove `--s3-disable-checksum`** | Without stored MD5s, `rclone check` can only compare sizes. That's not enough proof to erase. Cost: rclone reads files >200 MB once more to hash them. |
| `rclone check` without `--size-only` | Compares MD5 where R2 has it; falls back to size only where it must, and says so. Optional gold standard: `--download` (R2 egress is free; re-reads both sides). |
| Exclude `._*`, `ledger/**`, `rclone-cache/**`, `System Volume Information/**` | AppleDouble junk; old vault mirror (superseded by R2 `gallery-main/ledger/obsidian`); cache; Windows metadata. |
| **Exclude `Backups/20250320 Passwords.csv` and `Backups/20250719 Proton Pass.zip`** | Plain-text password exports must not sit in an unencrypted bucket. Import them into the password manager, or copy them to the Arq bucket (encrypted), before the erase. |
| `Data/phi/**` excluded (as you had it) | Re-pull models instead of storing them (see §4). If `Data/phi` holds anything you made (Modelfiles, fine-tunes, prompts), remove this exclude. |
| `--bwlimit "08:00,30M 23:00,off"` | Keeps the network usable by day, full speed overnight. |
| Stats every 60 s to the log | You can see progress without `--progress` on screen. |

## 1. Prepare (Mac)
```zsh
osascript -e 'quit app "Ollama"' 2>/dev/null; pkill -ix ollama
DEV=$(diskutil info -plist /Volumes/SanDisk | plutil -extract DeviceIdentifier raw -o - -)   # expect disk4s1
echo $DEV
diskutil unmount /Volumes/SanDisk && diskutil mount readOnly $DEV   # read-only: no ._ files, no Spotlight writes
```

## 2. Copy with auto-resume
```zsh
cat > ~/sandisk-evac.sh <<'EOF'
#!/bin/zsh
SRC="/Volumes/SanDisk"
DST="sync-backup:sdddc3t00g46-sandisk"
LOG="$HOME/sandisk-evac.log"
FILTER=(--exclude "._*" --exclude ".Spotlight-V100/**" --exclude ".fseventsd/**"
        --exclude ".Trashes/**" --exclude ".TemporaryItems/**" --exclude "System Volume Information/**"
        --exclude "ledger/**" --exclude "rclone-cache/**" --exclude "Data/phi/**"
        --exclude "Backups/20250320 Passwords.csv" --exclude "Backups/20250719 Proton Pass.zip")
OPTS=(--size-only --transfers 2 --checkers 4 --s3-upload-concurrency 2 --s3-chunk-size 64M
      --retries 1 --low-level-retries 3 --bwlimit "08:00,30M 23:00,off"
      --stats 60s --stats-one-line --log-file "$LOG" --log-level NOTICE)

rclone lsd sync-backup: | grep -q sdddc3t00g46-sandisk || { echo "bucket not reachable"; exit 1; }
for n in {1..20}; do
  until diskutil info "$SRC" >/dev/null 2>&1; do echo "$(date +%T) waiting for the drive..."; sleep 10; done
  echo "$(date +%T) attempt $n"
  rclone copy "$SRC" "$DST" "${FILTER[@]}" "${OPTS[@]}" && break
  echo "$(date +%T) stopped; 90 s to cool, then resume"; sleep 90
done

diskutil info "$SRC" >/dev/null 2>&1 || { echo "drive not mounted: can't verify"; exit 1; }
rclone size "$SRC" "${FILTER[@]}"
rclone size "$DST"
rclone check "$SRC" "$DST" "${FILTER[@]}" --one-way --log-file "$LOG" --log-level NOTICE \
  && echo "VERIFIED: every file is in R2 (MD5 where available)" \
  || echo "NOT VERIFIED: do not erase. See $LOG"
EOF
caffeinate -is zsh ~/sandisk-evac.sh
```
Before the erase, also check that the log shows no "hash: not supported" lines for large files. If it does, run the check again with `--download`.

## 3. Erase and test (only after VERIFIED; irreversible)
```zsh
diskutil list external physical          # confirm the 1 TB SanDisk's disk number
diskutil eraseDisk APFS SanDisk GPT diskN
brew install f3 && f3write /Volumes/SanDisk && f3read /Volumes/SanDisk   # tests the whole capacity, catches fake or failing flash; slow
```
APFS can't be read by Windows. Fine if the drive stays with the Mac.

## 4. Models back (instead of copying `Data/phi`)
This Mac is an M1 with **8 GB RAM** and ~5 GiB free internal disk.
```zsh
mkdir -p /Volumes/SanDisk/ollama
launchctl setenv OLLAMA_MODELS /Volumes/SanDisk/ollama   # then restart Ollama; drive must be mounted; re-run after each reboot (not persistent)
ollama pull phi3.5          # 3.8B, ~2.2 GB
ollama pull phi4-mini       # 3.8B, ~2.5 GB: the Phi-4 that fits 8 GB RAM
```
**Not `phi4` (14B, ~9 GB):** it doesn't fit in 8 GB RAM and would page to disk at a crawl. For French and other non-Latin scripts, also try `gemma3:4b` (strong multilingual) and keep whichever translates better.
Obsidian: a local-LLM plugin (e.g. Copilot or Local GPT) pointed at `http://localhost:11434`.

## 5. Optional: copy from the Windows 11 PC instead
Worth trying only if the Mac copy keeps stalling (FSKit exFAT). Windows' exFAT driver is native and mature.
- Port: USB 3.x (blue insert or "SS" logo). USB 2.0 caps at ~35 MB/s, still above the 6.6 MB/s uplink. The USB-A female → USB-C male adapter is fine if it's rated USB 3.x.
- Network: wired Ethernet if possible. Same 52.7 Mbps ceiling.
- Specs: any 4 GB+ RAM PC works; no free disk needed (rclone streams).
- `winget install Rclone.Rclone`, then `rclone config` a new S3 remote (provider Cloudflare) with **a new, rotated** token. Don't copy `rclone.conf` across.
- Same command with Windows paths: `rclone copy E:\ sync-backup:sdddc3t00g46-sandisk <same filters/options>`.
