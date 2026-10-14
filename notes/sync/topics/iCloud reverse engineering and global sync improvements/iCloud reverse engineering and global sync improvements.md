# iCloud reverse engineering and global sync improvements

Project: Sync

Created: 2026-10-10T12:03:16.576Z

## User — 2026-10-10T12:03:23.607Z

continue the reverse engineering work around icloud, improvements as set forth in global sync engine.txt

## Claude — 2026-10-10T12:05:43.144Z

Writing the technical report now, after the matrix.

I wrote the technical report and a rewritten sync matrix, but nothing has run on your Mac, since I can't reach your folders from here. All the commands in the report are a plan.

**What the research found**
- **iCloud Drive and Photos:** the "mimic a browser login" route already exists. rclone's `iclouddrive` backend does the login with 2FA and a trust token that lasts about 30 days, and reads Photos with `--iclouddrive-service photos`. `icloudpd` does the same for Photos. I recommend using these rather than writing a new client.
- **Advanced Data Protection:** rclone's documentation conflicts. The current page says it works if "Access iCloud Data on the Web" is on, and an older page says it must be off. I would check your installed version before deciding anything, and not turn the protection off just to run a backup.
- **Notability:** iCloud Sync and Notability Cloud are mutually exclusive, so the old matrix's "migrate to Notability Cloud" was wrong and I corrected it. I would not read the container at all. Instead, point Notability's own Auto-Backup, which supports WebDAV, at a small endpoint on your Worker that writes to R2.
- **Calendar, Contacts and Mail with attachments:** these use open protocols (CalDAV, CardDAV, IMAP) with app-specific passwords, so they need no reverse engineering and are the safest part.
- **iMessage:** there is no web route to mimic, because Messages in iCloud is end-to-end encrypted. The only route is the local `chat.db` and `Attachments/` on the Mac, copied first and exported with `imessage-exporter`. The Mac's copy may be incomplete while iCloud is full.

**Where the real novelty is**
The login is already solved, so I focused the report on what comes after it. That means a verified mirror with a SHA-256 manifest, append-only history, a single browse view in `/main/icloud/`, and a re-login reminder before the trust token expires.

**Infrastructure answers**
- **Reverse proxy:** not needed.
- **Vultr VPS:** not recommended, because it would hold your Apple credentials.
- **Tailscale:** optional, only for remote access to your own machines.
- **Arq:** keep it.

**Before anything else**
The report starts with a safety gate for Notability. Take an Arq snapshot, do an in-app PDF export, and check that your iCloud storage isn't blocking the iPad's notes from reaching the Mac. Everything is copy-only, with no write path to Apple or the container.

I didn't do the Developer cleanup, the SanDisk/Ollama fix or the Sill and player changes from your earlier message. Those are separate threads.

Files are in `/mnt/user-data/outputs`:
- icloud-backend-technical-report.md
- sync-matrix.md

## User — 2026-10-10T12:29:46.674Z

think of a clever icloud mirror backend mirroring solution hack nobody as ever thought to do before or that has and is very little known and would be very well praised, write it in a report, and send back a code file  emphasizing what a sync engine should prioritize for back end engineering apples icloud and mirroring/mimicing it , that when implemented  mirrors icloud to any serices in the matrix in the md and allows them to sync. may involve an intermediary. advise

## Claude — 2026-10-10T12:34:20.088Z

Presenting the three files now.

I wrote `ledger-report.md` and `ledger.mjs`, an engine whose built-in 17-check self-test passes on Node 22 on Linux. The report also explains how it reaches each row of the matrix and gives a ten-minute first run.

**The idea: use Apple's own client as the protocol.**
- The Mac's iCloud client already logs in, decrypts and syncs, and leaves ordinary files in `~/Library/Mobile Documents/`. `ledger.mjs` watches that folder read-only and publishes what it sees as an append-only, SHA-256 content-addressed, hash-chained journal. It can write to a plain directory such as the SanDisk, or to R2 through rclone.
- Other services read the journal instead of talking to Apple. That means no Apple credentials and no 30-day trust token. Advanced Data Protection also stops mattering, since the data is already decrypted on the Mac.
- The Mac has to be the intermediary, because only Apple's client can read iCloud without reverse engineering. The Worker is the hub for browsing and WebDAV views. A VPS adds nothing here.

**On "nobody has done this":** I can't promise that. Arq, Carbon Copy Cloner and Duplicacy already handle the local iCloud folder and its placeholder files. What I didn't find in a short search is a tool that publishes a subscribable, tamper-evident feed with point-in-time restore. Do a proper prior-art search before calling it "first". The defensible claim is the combination and the priorities.

**What a sync engine should prioritize**
Each priority is tagged in the code (P1 to P10) and the self-test checks them. The ones that matter most:
- **Truth over completeness:** evicted placeholders are reported, never counted as backed up. A source that suddenly loses most of its files is refused, not tombstoned.
- **Never write to the source:** a hard denylist covers the Notability container, the Photos library and Messages.
- **Append-only history:** deletes are recorded as events and old objects stay. `restore --at <time>` brings back an earlier state.

**Tested and not tested**
- **Tested on Linux:** dry run writes nothing, identical content is stored once, re-runs are idempotent, tampering with the journal is detected, and restore works.
- **Not run:** the rclone sink, the macOS check for evicted files and `watch` mode, because I have neither rclone nor a Mac here. Try them on a small folder first.

**Not built yet**
- The Worker routes that read the journal.
- Two-way write-back for plain-file vaults.
- The Notability WebDAV endpoint.
- The pull jobs for Calendar, Contacts and Mail.

It also can't fix a full iCloud. If the iPad's changes never reached iCloud, the Mac never sees them.

**Where to start:** run `node ledger.mjs selftest` on your Mac. Then do a dry run on a copy of a small folder, and then point it at the Obsidian vault with a sink on the SanDisk. Notability stays off-limits to this tool.

Files are in `/mnt/user-data/outputs`:
- ledger-report.md
- ledger.mjs

## User — 2026-10-10T13:30:01.616Z

actually i sync my notability notes with icloud. thats why i use it and i also like their product. its true  that their new notbaility cloud is different than apples cloud. i was a grandfather user, and have been using apple icloud sync for my note for many years

## Claude — 2026-10-10T13:30:53.350Z
