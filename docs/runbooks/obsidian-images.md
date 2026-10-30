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

## Check
`curl -sI https://gallery.improvdiplomat.workers.dev/i/<key>` → 200, `image/…`, `immutable`. Any other path under
`/i/` → 404.

## Undo
Links are plain URLs: download `notes-images` (`rclone copy`) back into `Attachments/` and replace
`https://gallery.improvdiplomat.workers.dev/i/attachments/<ext>/<h2>/<hash>.<ext>` with the local file name.
Deleting the token stops uploads; removing the route stops the links.
