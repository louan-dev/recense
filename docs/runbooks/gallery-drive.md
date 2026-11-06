# Gallery as a drive · Mac and Windows

Main (and tmp) open as a folder through the Worker's WebDAV, behind Cloudflare Access. Every device has **its own Access service token**, so a lost device is cut off by revoking only its token. Writes go through the Worker: an overwrite keeps the old file in `trash/`, a delete moves it there, and an out-of-date save gets 412 instead of overwriting. No R2 key lives on the device.

| | URL (rclone `webdav`, vendor `nextcloud`) |
|---|---|
| Main | `https://gallery.improvdiplomat.workers.dev/main/nc/dav/files/owner/` |
| tmp (expires after 14 days) | `https://gallery.improvdiplomat.workers.dev/main/nc-tmp/dav/files/owner/` |

The `nextcloud` vendor is what makes files over 100 MB work (Cloudflare caps one request at 100 MB, so rclone sends chunks the Worker joins). The plain `/main/dav/` and `/main/dav-tmp/` also work, but only for files under 100 MB.

## Known limits (2026-10-27)
- **Renaming or moving a folder fails** (the Worker answers 403). Rename and move files freely; rename a folder from the Gallery web page or on the Mac with the S3 key. Not fixed yet.
- **TextEdit won't open files in the mounted folder** (it comes to the front and shows nothing; cause not found yet). Other apps work: VS Code edits and saves fine, and Quick Look previews. Seen on the Mac's rclone NFS mount; not tried on Windows.
- No WebDAV locking, so Office may open documents read-only.
- One file can be at most 5 GiB.
- A delete removes the file from the folder; it stays recoverable in `trash/` (Main only; tmp deletes for good).

## Check it works
With Gallery open: `zsh ~/Developer/gallery/gallery/chau/test-md-roundtrip.sh` (add `--open` to also open the note in your .md app). Eight checks: a new .md note is readable and lockable, it and two kinds of edit reach the server, an edit made on the server shows up on the Mac, and an out-of-date save is refused. First run 2026-10-27: 8/8; Mac → server about 6 s, server → Mac about 40 s (the folder listing refreshes every minute).

## New device: a service token for it
1. Cloudflare dashboard → Zero Trust → Access → Service credentials → Service Tokens → **Create Service Token**. Name it for the device (e.g. "Windows desktop"); duration: non-expiring. Copy the Client ID and Client Secret (the secret is shown once).
2. Access → Applications → the Gallery app → Policies: add the token to the policy that already lets the Mac's token in (action **Service Auth**).
3. Add its Client ID to the Worker's list (comma-separated, every device's ID; IDs aren't secret, keep the list on the recovery sheet):
   `npx wrangler secret put SERVICE_CLIENT_ID` → paste `<mac id>,<windows id>`.

## Mac
Gallery.app mounts it after Touch ID (Main over the Worker since 2026-10-27; Public and tmp still on their scoped S3 keys). It stays open until the Mac locks, sleeps, starts the screensaver or sits idle for 15 minutes. To go back to the S3 key for Main: `zsh ~/Developer/sync/bin/gallery-main-over-dav.zsh undo`. The Mac's token is in the Keychain as `gallery-access`.

## Windows
1. Install **WinFsp** (winfsp.dev, the MSI) and **rclone** (`winget install Rclone.Rclone`, then open a new terminal).
2. `rclone config` → `n` → name `gallery-main` → storage `webdav` → url: the Main URL above → vendor `nextcloud` → user and password: leave empty → **Edit advanced config: y** → `headers`: `CF-Access-Client-Id,<client id>,CF-Access-Client-Secret,<client secret>` → `nextcloud_chunk_size`: `50M` → keep the rest.
   Optional: the same again as `gallery-tmp` with the tmp URL.
3. Lock the config so the token isn't readable on disk: `rclone config encryption set`. Use the same password as the Mac's Gallery keys password, or a new one written on the recovery sheet.
4. Mount (asks for that password):
   `rclone mount gallery-main: G: --volname Gallery --vfs-cache-mode full --vfs-cache-max-age 72h --vfs-cache-min-free-space 5G`
   Close the window to unmount.
5. Check: `rclone lsf gallery-main: --max-depth 1` lists your top folders.

## Lost or retired device
Zero Trust → Service Tokens: **revoke** its token; remove its ID from `SERVICE_CLIENT_ID`. Nothing else changes and no file is touched.
