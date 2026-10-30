# Recovery · if you forget, lose or break something

Print this page. Keep one copy at home in a fixed spot and one with someone you trust. Everything is written so that **no single device, password or account can lock you out of your files**.

## The one rule
Your files in R2 (Main, Public, tmp, the ledger mirrors) are **never** encrypted with a password of yours. Passwords on this Mac only lock the **keys** that reach R2. Forgetting one costs about ten minutes in the Cloudflare dashboard; it never costs a file.

The only passwords that *do* lock data, so each has to be on the paper sheet below before it's set: Arq's backup password, FileVault's recovery key, a Time Machine passphrase (A9, later), an rclone crypt remote (`r2-crypt`, not created yet).

## Who opens what
| You have | You get in with |
|---|---|
| This Mac, a finger | Touch ID (daily) |
| This Mac, Touch ID broken or fingers re-enrolled | your Mac login password: the same prompt, "Use Password" |
| A new or repaired Mac | the **Gallery keys password** (typed once, then Touch ID again) |
| Nothing but a browser | Cloudflare dashboard: make new keys, below. Needs only your Cloudflare login |
| Lost the Cloudflare login | its email's account recovery (Google), then Cloudflare's 2FA backup codes |

No step uses your Apple ID. If you're locked out of your Apple ID, Gallery, R2 and the keys still work.

## Lost or stolen device
- **Mac:** Cloudflare dashboard → R2 → Manage API tokens: delete the tokens named for the Mac. Zero Trust → Access → Service credentials: revoke the Mac's service token, and remove its id from the `SERVICE_CLIENT_ID` list (`wrangler secret put SERVICE_CLIENT_ID`). Files are untouched.
- **iPhone / iPad:** delete their read-only token. Nothing else changes.
- **Any device using Gallery as a drive (Windows, a second Mac):** revoke its service token, as in `gallery-drive.md`.

## Forgot the Gallery keys password
1. Delete the locked config: `mv ~/.config/rclone/rclone.conf ~/.config/rclone/rclone.conf.forgotten`, and `rm ~/Library/Application\ Support/Gallery/config-pass.json`.
2. Cloudflare dashboard → R2 Object Storage → Manage API tokens → Create **Account** API token, Object Read & Write, specific bucket. One token each for `gallery-main` and `gallery-public` (and `gallery-tmp` if it's gone too).
3. In Terminal: `rclone config` → new remote → `s3` → `Cloudflare`, pasting each key when asked. Then `rclone config encryption set` with a **new** password; write it on the sheet first.
4. Open Gallery: Touch ID, type the new password once.
The unattended jobs (Downloads, ledger) keep running throughout: they use `~/.config/rclone/jobs.conf`, which is never locked.

## The paper sheet (fill in by hand; never in a file, chat or photo)
- Cloudflare login email: ____________  · 2FA backup codes: ____________
- Recovery for that email account: ____________
- Gallery keys password (locks `rclone.conf`): ____________
- Arq backup password: ____________
- FileVault recovery key (System Settings → Privacy & Security → FileVault): ____________
- Later: Time Machine passphrase ____________ · `r2-crypt` password + salt ____________
