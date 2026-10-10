# cloudflare

Each folder is one project.

## gallery

Public and a main library, served at **https://gallery.improvdiplomat.workers.dev**.

| Address | What | Bucket |
|---|---|---|
| `/` | Make a new link from files on this device (owner only) | `gallery-public` |
| `/s/<id>` | A link: anyone who has it can view and download | `gallery-public` |
| `/main` | The library: browse, play, upload, delete (owner only) | `gallery-main` |

On the Mac, **Gallery** in the Finder sidebar opens `~/Gallery` after Touch ID, with two folders:

- **Public**: each folder inside is one link, deleted when the link expires (7 days by default, 30 at most).
- **Main**: kept until you delete it. Deleted files go to `trash/` for 30 days.

### Layout

```
gallery/
  wrangler.toml         Worker config (no secrets)
  src/                  the Worker
    worker.js           routes
    access.js           owner check (Cloudflare Access token, verified here)
    public.js           links, uploads, the nightly cleanup
    main.js             the library
    art.js              cover art from audio files
    common.js           responses, file types, paths
    player-key.js       serves the player's Key processor
    page/               the HTML pages
    client/             the pages' CSS and browser scripts
  test/                 route tests and page tests (npm test)
  mac/
    setup.sh            one-time: rclone remotes and this Mac's sign-in
    Gallery/            the Touch ID launcher app (zsh build.sh)
    copy-public-link.sh the Finder Quick Action "Copy Public Link"
    rclone.conf.example the remotes, without keys
  r2/lifecycle.md       the buckets' lifecycle rules
```

### Deploy

```
cd gallery
npm install
npm test
npx wrangler deploy
```

Secrets (set once with `npx wrangler secret put <NAME>`):

| Name | Value |
|---|---|
| `ACCESS_AUD` | The Application Audience tag of the Access application "Gallery Main" |
| `OWNER_EMAIL` | The email allowed into Main |
| `SERVICE_CLIENT_ID` | The client ID of the Access service token "gallery-chau" |

Cloudflare settings that live outside this folder:

- Access application **Gallery Main**: `gallery.improvdiplomat.workers.dev/main`, policies: allow the owner's email; Service Auth for the token `gallery-chau`.
- R2 API tokens **gallery-public-chau** and **gallery-main-chau**: Object Read & Write, one bucket each.
- Lifecycle rules: `r2/lifecycle.md`.

### Mac setup

```
zsh gallery/mac/setup.sh          # paste the keys when asked; nothing is shown
zsh gallery/mac/Gallery/build.sh  # builds /Applications/Gallery.app
```

Then Command-drag `/Applications/Gallery.app` into the Finder sidebar. For the Quick Action, make an Automator Quick Action (files or folders in Finder, Run Shell Script, `/bin/bash`, input as arguments) containing:

```
exec /bin/bash "$HOME/Developer/cloudflare/gallery/chau/copy-public-link.sh" "$@"
```
