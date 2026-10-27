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
    public.js           links, uploads, comments, the nightly cleanup
    main.js             the library
    invite.js           participant links (/m/<token>)
    transcript.js       transcripts from Recense, content keys, locks
    corrections.js      corrections to transcripts, glossary, merging
    layout.js           where transcripts live in R2 (keep/<key>/...)
    art.js, tagwrite.js cover art: read from audio tags, written back into MP3/FLAC
    common.js           responses, file types, paths
    player-key.js       serves the player's Key processor
    page/               the HTML pages
    client/             the pages' CSS and browser scripts (gallery.js, keylabel.js, upload.js)
  test/                 route, transcript, key-label and page tests (npm test)
  chau/
    setup.sh            one-time: rclone remotes and this Mac's sign-in
    Gallery/            the Touch ID launcher app (zsh build.sh)
    copy-share-link.sh  the Finder Quick Action "Copy Share Link"
    rclone.conf.example the remotes, without keys
  r2/lifecycle.md       the buckets' lifecycle rules

## How it works

### Routes (worker.js)
- `/`, `/s/<id>`: public links (`public.js`). `upload` takes the owner's files into `gallery-public/folders/<id>/`; `gallery` and `galleryApi` render a link and list its items; `file` serves one item (ranges, inline, never an automatic download); `cleanup` (cron 03:00) deletes expired links and sweeps comments of deleted files.
- `/main...`: the owner's library, behind Access (`access.js`: `isOwner` verifies the Access JWT; anyone else gets the same 404). `mainFolder` lists a folder (`listFolder`, folder order in R2, `orderSweep`), `mainFile` serves a file, `mainUpload` / `mainDelete` (into `trash/` for 30 days) / `mainRename` (keeps `was` in the file's metadata) change it, `mainCover` / `mainCoverDelete` set or remove cover art (written into MP3/FLAC tags by `tagwrite.js`, otherwise kept in `art/`), `mainKey` stores a song's original key.
- `/main/api/link`: a share link made from files in Main (`linkApi`). `/main/api/invites`, `/m/<token>`: participant links (`invite.js`), one folder each, with view / download / upload / comment permissions, expiry and revoke; tokens are stored hashed.
- Comments (`commentApi`): JSON per folder in R2; on public links only the owner comments, on Main anyone allowed.
- `/main/api/transcript`, `/api/transcript`: a file's transcript (`transcript.js`), its corrections (`transcriptSave`, conditional on the version), and asking Recense for one (`transcriptRun`, a lock in `keep/locks/<key>`).

### Transcripts shared with Recense
Recense (the Mac app) transcribes Main's audio and video while it is idle and keeps every transcript in R2 under `keep/<key>/` (`asr.json`, `tr/en|vi|fr.json`, `corrections.json`, `history/`). The key is the file's **content key** (`fingerprintKey`): the first 24 hex of SHA-256 of `fp:<bytes>:<sha256 of the first 64 KiB>:<sha256 of the last 64 KiB>`. Recense computes the same for files on the Mac (`ContentKey` in `main.swift`), so the same recording is one transcript wherever it is played: on the Mac, in Gallery, renamed, moved or uploaded twice. Transcripts made before content keys are still found under the old path key (`transcriptKey`, SHA-256 of `gallery:files/<path>`), and through `keep/library.json` aliases (a recording Recense heard from another source, with its time shift).

### The viewer (client/gallery.js)
- Grid, strip and viewer; click views or plays, never downloads. Info holds Download, Rename, Change Cover, Key, native language and New Window.
- Player: rewind / play / forward, the time bar, Loop and A–B, Speed (pitch kept), volume. EQ panel: Low, Mid, High (one curve drawn from the real filter response), Key and Room. Sizes are tuned per device (`gallery.css`: phones, iPad Air 13", large monitors).
- Key: semitones up or down from the original key, named in the chosen notation (Key, Ton., Tông, Tonart, 調, 调, Sa, Maqam, Maqam¼, Cents; `keylabel.js`). A file with no stored key has it detected the first time it is opened (Krumhansl-Schmuckler on a chroma vector), so the labels name keys rather than counting +1, +2. The caption: tap for the next notation, right-click or two fingers down for the previous; the full list opens on a hold (touch), a press and one-finger swipe up, resting the pointer on it, or two fingers up on a trackpad.
- Learn mode: the transcript centred in the player, lines taking turns in two places; each word lights as it is heard and its translation in the native language (Vietnamese, French or English, from `tr/<lang>.json`) takes its place once read. Tap a line to go there and correct it; corrections save after a second and teach a one-word glossary.
- Downloads of audio with Key, EQ or Space on are rendered as heard (a WAV made in the page).
- Comments: under the item, Post / Delete / Cancel; swipe your own comment for Delete.

### Mac side (chau/)
`setup.sh` makes the rclone remotes for both buckets, `Gallery.app` mounts them at `~/Gallery` after Touch ID, `copy-share-link.sh` makes a public link from Finder. Sharing the mount between devices: see `SYNC.md`.

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
zsh gallery/chau/setup.sh          # paste the keys when asked; nothing is shown
zsh gallery/chau/Gallery/build.sh  # builds /Applications/Gallery.app
```

Then Command-drag `/Applications/Gallery.app` into the Finder sidebar. For the Quick Action, make an Automator Quick Action (files or folders in Finder, Run Shell Script, `/bin/bash`, input as arguments) containing:

```
exec /bin/bash "$HOME/Developer/gallery/gallery/chau/copy-share-link.sh" "$@"
```
