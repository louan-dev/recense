# Gallery in Finder and Files, two-way and offline · proposal 2026-10-27

## What the owner wants
Gallery (Main, Public, tmp) as an ordinary location in **Finder on the Mac and the Files app on iPhone and iPad**. Open and edit files there both ways. Folders you choose stay **on the device and work with no connection**; offline edits sync when the connection returns. The Mac doesn't need to be on. Recent downloads on every device land in **tmp**, which expires after 14 days.

## Why earlier answers said no, and the way that works
The Files app's own "Connect to Server" (SMB only) can't send the Cloudflare Access token and has no offline copies, so that route really is closed. Every app that shows up in Files or Finder with offline copies (iCloud Drive, Dropbox, OneDrive, Nextcloud) does it through Apple's **File Provider** API. The provider is the code making the network requests, so it can send whatever credentials it needs. It shows everything, downloads on demand, keeps "Keep Downloaded" folders local, and the system queues offline edits for upload. That's the route.

## Constraints measured on 2026-10-27
- Main is 34.6 GiB / 29,646 files. The Mac has **6.8 GB free**, so offline means *chosen folders*, never everything. The iPhone's storage is unknown.
- Signing: Xcode 16.4, iOS 18.5 SDK, but the team is a **free Personal Team**. Its iPhone/iPad apps stop working after 7 days, and some capabilities (App Groups) may be refused. No iOS Simulator runtime is installed, and one needs ~8 GB, which won't fit.
- Cloudflare caps one request at 100 MB (handled: chunked uploads, 1cd3406) and at about 1,000 storage operations, so a big folder rename can't happen in one request.

## Two ways to get a File Provider onto all three devices
**A · Recommended: the free Nextcloud apps, with the Worker speaking Nextcloud.**
- **Clients:** Nextcloud's own apps, free from the App Store and auto-updating, are File Providers on iOS/iPadOS (a "Nextcloud" location in Files, "Available offline" per folder) and on macOS (desktop client, Finder location, "Always keep downloaded").
- **Worker:** gains the subset of Nextcloud's server API those apps use:
  - `status.php`, capabilities and user (OCS).
  - Login Flow v2.
  - `remote.php/dav/files/<user>/` with the `oc:` properties (fileid, permissions, size).
  - Chunked upload v2, mapped onto the same mounts as `/main/dav/`: Main and tmp, plus Public once it has a trash.
- **Rules unchanged:** writes keep using the Worker's trash, versions and ETag checks. No R2 key goes on any device.
- **The door, made safe:** these apps authenticate with Basic auth, so this is a door outside Access, which replaces the earlier decision "no Basic-auth door into Main".
  - Each device gets its **own app password**, issued only after you sign in through Access (Login Flow v2's approval page sits behind Access).
  - Passwords are stored only as SHA-256 hashes and are revocable one device at a time from a `/main` page.
  - Wrong passwords are rate-limited like `/dav/notability/`.
  - Everything sits under a sub-path (e.g. `/cloud/`), not the site root.
- **No Apple-side cost or tooling:** no $99, no Xcode builds for iOS, no 7-day expiry.
- **Risk:** it imitates someone else's server. Some app screens (Media, Activity, sharing) will be empty, and a future app update could need one more endpoint. Check before the iPhone: `nextcloudcmd` / the desktop client on this Mac against a local Worker.

**B · Our own Gallery app (Swift, NSFileProviderReplicatedExtension, iOS + iPadOS + macOS).**
- **How it works:** it talks to the existing `/main/nc/` WebDAV with each device's Access service token, so no new door is needed. It has full control: Downloads → tmp, Data Protection "complete" on iPhone, hiding the location on Mac screen lock.
- **What it needs:** the **Apple Developer Program, $99/yr**; the free team's 7-day expiry doesn't suit someone who forgets. It also needs about 10 GB free on the Mac for iOS device/simulator tooling, and a much larger build (sync engine, conflict copies, change detection).

**C · Local-first with only what's already on the devices (owner's constraint, 2026-10-27 21:10: no connection needed to use files, no third-party app, no app of our own).**
Nothing remote (RDP, a virtual computer, a cloud drive) can be reached without a connection. So "works with no connection" means a real copy on each device that catches up by itself when a connection appears.
- **Mac:** a normal folder `~/Gallery` holding the folders you pick. launchd (built in) runs `rclone bisync` (installed) both ways through the Worker whenever there's a connection: on FSEvents changes, and on wake. It's a real local folder, so TextEdit, Spotlight and Quick Look work offline. It uses a per-device Access token in `jobs.conf`.
- **iPhone / iPad:** a normal folder, Files › On My iPhone › Gallery, editable offline in Files. A **Shortcuts automation** (built into iOS, "Run Immediately") runs on joining any Wi-Fi, on plugging in to charge, and at set times. It sends the folder's manifest (names, sizes, dates) to a Worker endpoint with the device's Access token, gets back a plan (download / upload / delete / conflict → keep both), and carries it out. The logic lives in the Worker, where it's tested; the Shortcut stays a simple loop. It's built on the Mac and signed with `shortcuts sign`.
- **Downloads → tmp:** Safari saves into On My iPhone › Gallery › tmp › Downloads (Safari lets you pick On My iPhone folders). The next sync moves them to tmp, which has the 14-day expiry. The Mac keeps its agent.
- **Rules unchanged:** writes go through the Worker as now (trash, versions, ETag checks); no R2 keys on devices; no new door.
- **Limits:**
  - Only the chosen folders live on each device (Main is 34.6 GiB; the Mac has 6.8 GB free).
  - Sync happens at those moments, not continuously.
  - Shortcuts is slow for big video.
  - The same file edited on two devices between syncs → both kept, one renamed.
- **Zero connection between devices at all:** only a physical drive plugged into each one. The SanDisk Dual Drive works in Files on the iPad (USB-C) and on the iPhone 12 with Apple's Lightning to USB 3 adapter. Optional for big media; it's also lost easily, and exFAT isn't encrypted.

## The three gaps, either way
- **iPhone / iPad:** covered by the File Provider (A: Nextcloud app; B: Gallery app).
- **Public:** add a `PUBLIC_DAV` mount (`folders/`) with a trash in the public bucket (`trash/<day>/…`; today Public deletes are permanent), then expose it like Main.
- **Folder renames:** a resumable server-side move. Each call moves up to ~100 files with their art, comments, keys and order, saves a cursor in R2 and is called again until done. Renames are refused (rather than half-done) while a room/invite points into the folder; `invite.js` belongs to the C0 session. WebDAV folder MOVE uses it for small folders; File Providers loop it for big ones.
- **Downloads → tmp:**
  - Mac: unchanged (the agent, 14-day expiry).
  - iPhone/iPad: Settings → Apps → Safari → Downloads → Other… → the Gallery/Nextcloud location's `tmp/Downloads` if iOS lists it (check on the device). Otherwise "On My iPhone › Downloads" plus a share-sheet "Save to tmp".

## Privacy trade-off (owner decides)
Offline means real copies on the device. iPhone and iPad keep them encrypted while locked (device passcode). The Mac keeps them in `~/Library/CloudStorage`, readable while you're logged in and encrypted by FileVault when the Mac is off. Gallery.app (online, Touch ID, wiped on lock) can stay as the private route next to it.

## Order of work (each step: tests first, deploy only with the owner's yes)
1. Worker: Nextcloud-compatible layer (route A) + device app passwords + revoke page; Public mount with trash; resumable folder move. Run the Nextcloud desktop client and `nextcloudcmd` against Miniflare, then live.
2. Mac: Nextcloud desktop (File Provider mode). Pin a test folder, go offline, edit, reconnect, check the edit and trash on the server; run `chau/test-md-roundtrip.sh`-style checks against the CloudStorage path.
3. iPhone, iPad: Nextcloud app. Log in through Access, mark a folder "Available offline", airplane mode, edit a .md in Files, reconnect, check. Safari downloads → tmp.
4. Runbooks: `gallery-drive.md` (devices, revoke), `recovery.md` (lost device = revoke its app password).
