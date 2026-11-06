# Obsidian images → R2 ("S3 Image Sync" plugin, id `images-uploader` 1.0.10)

The plugin uploads a note's local images to R2 and rewrites the link to a public URL. It runs only when you start
it (auto-scan stays off: no polling). Pieces:

| Piece | Value |
|---|---|
| Bucket | `notes-images` (own bucket: Remotely Save syncs `notes`, so images there would come back into the vault) |
| Key | plugin default `attachments/{ext}/{hash2}/{hash}.{ext}` (SHA-256, content-addressed) |
| Public URL | `https://gallery.improvdiplomat.workers.dev/i/<key>`: Gallery Worker route `src/images.js`, read-only, serves only keys of that shape, cached forever; the bucket itself stays private (no r2.dev) |
| Token | R2 API token, **Object Read & Write, `notes-images` only**; lives only in the plugin's settings |
| Vault folder | `Attachments/` (new pastes land there; the plugin only processes this folder) |
| Local copy | Delete policy **Ask each time**. The ledger already mirrors the vault to `gallery-main/ledger/obsidian` |

Caveat: an uploaded image needs a connection to show. Images you need offline (iPhone, plane) stay local: don't
upload them, or choose "keep" when the plugin asks to delete.

## One-time setup
1. Bucket: `cd ~/Developer/gallery/gallery && npx wrangler r2 bucket create notes-images`
2. Deploy Gallery with the `/i/` route (binding `NOTES_IMAGES` in `wrangler.toml`). Deploy from a commit, not the
   working tree, when other uncommitted work is present: `git archive <commit> | tar -x -C <scratch>`, symlink
   `node_modules`, `npx wrangler deploy`.
3. Token: Cloudflare dashboard › R2 › Manage API tokens › Create › **Object Read & Write** › Specific bucket
   `notes-images` › no expiry. Copy the Access Key ID + Secret (shown once).
4. Obsidian › Settings › Files and links › Default location for new attachments › "In the folder specified below"
   › `Attachments`.
5. Obsidian › Settings › S3 Image Sync:
   - Provider **Cloudflare R2** · Endpoint `https://7a7972b724b508c99a42844632b8a44c.r2.cloudflarestorage.com`
     · Region `auto` · Bucket `notes-images` · Access Key ID / Secret from step 3
   - Public access URL `https://gallery.improvdiplomat.workers.dev/i`
   - Upload path template: leave the default
   - Image folder `Attachments` · Delete policy **Ask each time** · Auto-scan **off**
   - **Test connection**, then a **dry run**, then upload.
6. Settings sync to the iPhone/iPad with the vault (`.obsidian/plugins/images-uploader/data.json`, secret included),
   so set it up once on the Mac.

## Move Offsite: any app, Mac + iPhone/iPad
Same bucket and key as the plugin (the same picture is stored once). Flow: image → `PUT /main/api/img`
(Access service token + `X-Gallery: 1`) → R2 answers `{url, sha256}` → the device checks sha256 against its own copy
→ the original goes to the Trash (Mac) / Recently Deleted (iPhone, after iOS asks) → the link is on the clipboard.
**Nothing expires in `notes-images`**: the link must outlive the original.

What a pasted link becomes:
| Where | Result |
|---|---|
| Markdown (Obsidian, DEVONthink Markdown, iA Writer, Typora, `.md`) | image shows, loaded from R2 |
| `.odt` (LibreOffice: Insert › Image, tick **Link**, paste the URL as the file name) | image shows, linked |
| `.docx` (Word for Mac: Insert › Pictures › Picture from File, paste URL, **Link to File**) | works in Word, fragile; Pages can't |
| Apple Notes, Notability, DEVONthink RTF, `.txt` | a tappable link only (these formats can't show a linked image; pasting the picture itself would copy it back in) |

- **Mac**: `sync/bin/offsite-image.zsh [--md|--url] [--keep] [file…]` (no files = clipboard image). Markdown link when
  the front app reads Markdown, else the bare URL. Log `~/Library/Logs/offsite-image.log`. Shortcut
  `sync/tools/shortcuts/Move Offsite (Mac).shortcut` wraps it: Finder › right-click › Quick Actions, menu bar, or a
  hotkey (with nothing selected it takes the clipboard image).
- **Finder Quick Action**: `sync/tools/quick-actions/Move Offsite.workflow` (Automator, installed in
  `~/Library/Services`). The Shortcut's Quick Action can't read Finder files (TCC: "macOS blocked reading …"), so
  untick its "Use as Quick Action". Install: `cp -R` it to `~/Library/Services/`, then
  `/System/Library/CoreServices/pbs -update`.
- **iPhone/iPad**: `sync/tools/shortcuts/Move Offsite (iPhone).shortcut`: Share Sheet from Photos/screenshots.
  Asks for the device's token on import (not stored in the file). Copies the URL; deletes the photos only after the
  hash matched (iOS confirms). In Obsidian on iOS, paste the image itself: the plugin does the rest.

Setup (owner):
1. Deploy Gallery with `a942b18` (the upload route). Live now is 2045487 + the `/i/` route only.
2. Mac: Shortcuts › Settings › Advanced › **Allow Running Scripts**; `open "sync/tools/shortcuts/Move Offsite (Mac).shortcut"`
   › Add; in its ⓘ: Use as Quick Action (Finder, Services), Pin in Menu Bar, Add Keyboard Shortcut (e.g. ⌃⌥⌘O).
   First run: Keychain asks for `gallery-access` → Always Allow.
3. One token per device (Zero Trust › Access › Service Auth), each in the Gallery application's Service Auth
   policy and in the Worker's `SERVICE_CLIENT_ID` list (comma-separated; `wrangler secret put` replaces the whole
   list, so always pass all of them). Since 2026-10-30: Mac `gallery-access` (Keychain), iPhone `gallery-ios`
   (`aa419e6a….access`), iPad `gallery-ios-black` (`4052f8b2….access`). Revoke one token to cut off one device:
   `MAC=$(security find-generic-password -s gallery-access -a client-id -w) && [ -n "$MAC" ] && printf '%s,%s,%s' "$MAC" <iphone-id> <ipad-id> | npx wrangler secret put SERVICE_CLIENT_ID`
4. AirDrop `Move Offsite (iPhone).shortcut` to each device › Add Shortcut › paste Client ID + Secret.

Not tested: both Shortcuts (signed, not imported or run; importing needs your click). The Mac script was tested
against a local stand-in for the Worker (upload, sha check, Trash, clipboard, Markdown/URL, clipboard image,
no-image error); the Worker route by `test/images.test.mjs` (8 ok).

## Check
`curl -sI https://gallery.improvdiplomat.workers.dev/i/<key>` → 200, `image/…`, `immutable`. Any other path under
`/i/` → 404.

## Undo
Links are plain URLs: download `notes-images` (`rclone copy`) back into `Attachments/` and replace
`https://gallery.improvdiplomat.workers.dev/i/attachments/<ext>/<h2>/<hash>.<ext>` with the local file name.
Deleting the token stops uploads; removing the route stops the links.
