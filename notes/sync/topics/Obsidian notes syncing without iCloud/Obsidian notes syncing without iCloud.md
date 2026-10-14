# Obsidian notes syncing without iCloud

Project: Sync

Created: 2026-10-09T23:14:45.310Z

## User — 2026-10-09T23:14:53.292Z

clever backdoor solution to have obsidian notes syncing like my current setup where obsidian folder is saved within an icloud folder. reverse engineer a similar approach that replicates icloud. tricks obsidian into thinking im using icloud, so that my obsidian notes may be saved natively on my current setup? file path of obsidian markdown files is here: '/Users/chauphan/Library/Mobile Documents/iCloud~md~obsidian/Documents'

## Claude — 2026-10-09T23:16:40.756Z

Nothing needs tricking on the Mac, and nothing can be tricked on the iPhone.

On the Mac, Obsidian just opens a folder. `iCloud~md~obsidian` is only where iCloud keeps the app's container. The constraint is iOS: Obsidian there can only reach vaults inside its own dedicated folder, either in iCloud Drive or in On My iPhone/iPad, and the usual explanation is that it needs whole-folder access for indexing, which iOS only grants inside the app's own locations. The OS grants that container to Obsidian's app ID, so as far as I know no other storage provider can impersonate it. The fix is to replace the sync layer, not to fake iCloud.

**Best fit: Remotely Save straight to R2**

Remotely Save is a community plugin that supports S3-compatible storage including Cloudflare R2, and it works on Obsidian mobile. It talks to R2's S3 API directly, so your Worker isn't involved.

- **Bucket:** create a third bucket, e.g. `notes`, with its own Object Read & Write token. Don't use `share`, because it has auto-deleting cleanup. Don't use `global/lib/files/` either, because an `rclone sync` of the library would delete anything it doesn't know about. A per-bucket token also means the credentials stored on your phone can't reach the library.
- **Endpoint:** `https://<accountid>.r2.cloudflarestorage.com`, region `auto`.
- **Connectivity check:** the plugin's R2 notes say Cloudflare rejects HeadBucket for Object Read & Write keys, which can trip its check.
- **CORS:** on current Obsidian versions you can skip the bucket CORS setup.
- **Sync timing:** it can't sync while Obsidian is in the background, so expect sync-on-open, interval or on-save rather than iCloud's instant feel.
- **Settings:** the `.obsidian` config folder isn't synced by default. Leave the plugin's optional encryption off if you want readable files in R2.

I haven't vetted it, but the plugin directory also lists a real-time sync plugin powered by your own Cloudflare Worker. That may be worth a look since you already run one.

**Alternative: keep iCloud as the iPhone's transport and bridge on the Mac**

The iPhone stays truly native, because Obsidian really is using iCloud. A launchd job on the Mac mirrors the vault to R2:

```bash
rclone bisync "$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian" r2:notes/Obsidian \
  --resync --dry-run
```

Run the first pass with `--resync --dry-run`, then drop both flags for the scheduled runs. Keep the vault set to stay downloaded, or rclone may read iCloud placeholders. R2 ends up as a copy while iCloud stays in the loop.

**Skip putting the vault inside `~/Studio`.** Your report notes that saving through the mount replaces objects and strips metadata. Mounts also tend to be unreliable at delivering file-change events, which Obsidian depends on. The iPhone couldn't use that location anyway.

**Migration for the Remotely Save route**

1. Zip a backup of the vault.
2. Copy (don't move) the vault to a local folder, open it as a vault on the Mac, install Remotely Save and run the first sync to push it up.
3. On the iPhone, create a new vault with the iCloud toggle off, install the plugin with the same bucket and token, and sync to pull.
4. Once both sides match, delete the iCloud copy so two sync systems don't fight over the same files.
5. If `scratchpad.swift` points at the old iCloud path for `scratchpaper.md`, repoint it to the new folder or leave a symlink at the old location.

Want me to write the launchd and rclone bridge, or walk through creating the bucket and token?

### Sources

- [Cannot open vault from folder](https://forum.obsidian.md/t/cannot-open-vault-from-folder/109782) — via web_search
- [Cannot open vault from folder](https://forum.obsidian.md/t/cannot-open-vault-from-folder/109782)
- [Full File System Access For The iOS App (Open Existing Vault/Folder)](https://forum.obsidian.md/t/full-file-system-access-for-the-ios-app-open-existing-vault-folder/28266?page=2) — via web_search
- [Full File System Access For The iOS App (Open Existing Vault/Folder)](https://forum.obsidian.md/t/full-file-system-access-for-the-ios-app-open-existing-vault-folder/28266?page=2)
- [remotely save](https://community.obsidian.md/plugins/remotely-save) — via web_search
- [remotely save](https://community.obsidian.md/plugins/remotely-save)
- [Merge branch 'master' into s3-docs](https://gitea.astro-vps.duckdns.org/bruno/remotely-save/commit/e3e8db04e2d84cf8d0df3f62c7e259abd95b50e6) — via web_search
- [Merge branch 'master' into s3-docs](https://gitea.astro-vps.duckdns.org/bruno/remotely-save/commit/e3e8db04e2d84cf8d0df3f62c7e259abd95b50e6)
- [obsidian remotely save](https://github.com/scruel/obsidian-remotely-save) — via web_search
- [obsidian remotely save](https://github.com/scruel/obsidian-remotely-save)
- [remotely save](https://github.com/ZeddYu/remotely-save) — via web_search
- [remotely save](https://github.com/ZeddYu/remotely-save)
- [assets offloader](https://community.obsidian.md/plugins/assets-offloader) — via web_search
- [assets offloader](https://community.obsidian.md/plugins/assets-offloader)
