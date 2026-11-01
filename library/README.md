# gallery

The owner's library and share links, served at **https://gallery.improvdiplomat.workers.dev** (Cloudflare Worker + R2),
with native apps for macOS, iOS and iPadOS and a Finder/Files location.

## Why this exists
Gallery is where my library lives now that it no longer fits in iCloud or on an old MacBook with 8 GB of memory and a
disk that is always almost full. Photos, recordings, notes and calendars kept growing; failing SanDisk drives and a
full iCloud broke the syncing I depended on. So I moved things somewhere I can hold: R2 for storage, a Worker I wrote,
and native places in Finder and Files that still work when the connection doesn't. Apple Calendar gave way to my own
CalDAV, and confidential things stay mine.

But it is not only a storage story. I learn best through many senses at once, the way a song can teach a language
faster than a textbook ever did for me, so Gallery plays, shows, lights and translates what I keep, and shares
transcripts with Recense in Sill. I hope that turns everyday media into a playground for my family, for neighbours who
meet English as a barrier, for English speakers exploring other cultures and cities with a curious mind, and for
people with disabilities who deserve learning that meets them where they are. It is a small, humble attempt to make
technology a little more accessible and a little more humane, built from what has worked for me, and offered freely.

## Long-term outcomes
- Every file usable with no connection on Mac, iPhone and iPad, in each device's native place (Finder, Files).
- Edits flow both ways when a connection appears; nothing runs 24/7; R2 is the storage, the Worker the sync engine.
- One place to view, play, listen to, share and ask about everything the owner keeps.

## Addresses

| Address | What | Bucket |
|---|---|---|
| `/` | Make a new link from files on this device (owner only) | `gallery-public` |
| `/s/<id>` | A link: anyone who has it can view, download, comment and like | `gallery-public` |
| `/m/<token>` | A participant link to one folder (view / download / upload / comment) | `gallery-main` |
| `/main` | The library: browse, play, upload, rename, delete (owner only) | `gallery-main` |
| `/main/archive` | The archive's page and player, read-only | `gallery-archive` |
| `/main/shared` | Every live share link as an album, with Activity | `gallery-public` |
| `/main/dav-tmp/`, `/main/dav-archive/`, `/main/nc-archive/` | WebDAV for rclone mounts | `gallery-tmp`, `gallery-archive` |

On the Mac, **Gallery** in the Finder sidebar opens `~/Gallery` after Touch ID, with two folders:

- **Public**: each folder inside is one link, deleted when the link expires (7 days by default, 30 at most).
- **Main**: kept until you delete it. Deleted files go to `trash/` for 30 days.

`gallery-tmp` keeps everything for 14 days (`tmp/` links for 1 day).

## Features

### The viewer
- Grid, strip and viewer; click views or plays, never downloads. Info holds Download, Rename, Change Cover, Key, native
  language and New Window.
- Player: rewind / play / forward, time bar, Loop and A–B, Speed 0.5×…2× (pitch kept), volume. EQ panel: Low, Mid,
  High, Key and Room. Sized per device (phones, iPad Air 13", large monitors).
- Key: semitones from the original key, named in the chosen notation (Key, Ton., Tông, Tonart, 調, 调, Sa, Maqam,
  Maqam¼, Cents). A file with no stored key has it detected on first open.
- Downloads of audio with Key, EQ or Space on are rendered as heard.
- Comments under each item: Post / Delete / Cancel; swipe your own comment for Delete.
- Documents open as pages: PDF, Markdown, Word (.docx), plain text. In Main, Markdown and plain-text files have
  **Edit** / **Save** / **Cancel** on the page (iPhone and iPad too): the save is refused if the file changed elsewhere
  since it was opened, and the version it replaces goes to the trash.
- **Docs** in Main holds every document from the Mac (Obsidian, iCloud Drive, Documents, Downloads, Developer,
  Google Drive, Voice Memos, Notability's PDFs), kept in step both ways by Sync's `bin/docs-sync.zsh`; `Docs/INDEX.md`
  lists them by source.

### Learn mode, karaoke light and notation
- The transcript centred in the player; each word lights as it is heard and its translation (Vietnamese, French or
  English) takes its place once read. Tap a line to go there and correct it; corrections save after a second and teach
  a glossary, and keep the voice's timing.
- The light follows the voice: syllables from the vocal stem, words hung on them, unsung words never lit, held notes
  held, each syllable swept at its sung speed. On iOS Safari it follows what the speakers play.
- Word timing by ear in the transcript editor: pick a word and its stretch loops; tap Start as the voice reaches it
  and End as it lets go, the way A and B are set (drag a mark or ← → for a hundredth). The ear anchors the word and
  the voice's syllables are stretched onto it, so the light follows the voice, never lagging or rushing. "Same in N
  repeats" gives a chorus or ad-lib sung again the same timing. Auto hands the word back to the voice.
- The editor is quiet: Changes · a grabber · Done; the tools fold under the grabber (tap, or rest the pointer on it).
  Paused with no line up, a grabber where the lines show opens the editor.
  A word being timed keeps its marks up when the phone is turned or the server's lines come back; on a short
  landscape screen the editor ends above the strip, comment field and home-bar grabber.
- Notation as a vocal score: prosody ribbon preloaded as a ghost with a gold sweep, turquoise liaison ties, fermatas,
  pp…ff, chords and sung notes; Chinese tones in Chao numbers, Arabic syllables from vowels and harakat.
- Every script laid out correctly, each word tagged with its own `lang=`:
  - Written without spaces between words: Chinese, Japanese, Thai, Lao, Khmer, Burmese, Tibetan (a typed correction
    is cut into words again, so the light still moves word by word).
  - Right to left, laid out by the browser's bidi (Latin names and numbers keep their order): Arabic, Persian, Urdu,
    Hebrew, Syriac, Thaana.
  - Other non-Latin scripts:
    - Europe and Central Asia: Cyrillic (Russian, Ukrainian, Belarusian, Bulgarian, Serbian, Macedonian, Kazakh,
      Kyrgyz, Tajik, Tatar, Bashkir, Mongolian), Greek, Armenian, Georgian, traditional Mongolian.
    - East Asia: Korean (Hangul).
    - South Asia: Devanagari (Hindi, Marathi, Nepali, Sanskrit), Bengali (Bengali, Assamese), Gurmukhi (Punjabi),
      Gujarati, Odia, Tamil, Telugu, Kannada, Malayalam, Sinhala.
    - Africa: Ge'ez (Amharic, Tigrinya), Tifinagh (Tamazight), Coptic.
  - The light reaches marks above and below the letters.

### Transcripts shared with Recense
Recense (in Sill, on the Mac) transcribes Main's audio and video while idle and keeps every transcript in R2 under
`keep/<key>/` (`asr.json`, `tr/en|vi|fr.json`, `corrections.json`, `history/`). The key is the file's **content key**:
the first 24 hex of SHA-256 of `fp:<bytes>:<sha256 of the first 64 KiB>:<sha256 of the last 64 KiB>`, computed the
same way on the Mac, so one recording has one transcript wherever it plays, renamed, moved or uploaded twice.
`keep/library.json` aliases a recording heard from another source, with its time shift.
A corrected line keeps the space typed before `! ? ; :` (French writes `fini !`); a space before `, . …` and the
Arabic and Ethiopic stops is dropped. Sill joins words by the same rule. Pushing to `main` deploys: GitHub Actions installs the test browsers, runs `npm test`, then `wrangler deploy`.

### Sharing
- Share links from Main, the archive or the apps; each draws a large preview card in iMessage, Messenger and Telegram.
- Guests comment and like under a name given once (random HttpOnly cookie, stored hashed), editing only their own.
- `/main/shared`: Personal | Shared | Activity (participant uploads, likes, comments); Delete expires a link now.
- Participant links: one folder each, with permissions, expiry and revoke; tokens stored hashed.

### Assistant
Ask from the top bar (⌘K), scoped This folder | Main | Archive | All. Plans searches, cites sources, keeps memories;
published references are trusted, the owner's own writing once checked. Calendar: reads the owner's events and the
iCloud backup, creates and edits events, invites with a texted link. Indexing runs in bounded steps from a one-minute
cron.

### Gallery for iPhone and iPad (apple/ios, apple/HostApp/iOS)
- A Files-like browser over Main and the archive, with Gallery's own player and Learn mode inside the app
  (`gallery://` scheme handler), and an Assistant button on each folder (⌘K on an iPad keyboard).
- Gallery as a location in the Files app (File Provider extension), with the app's icon and a shared Keychain token.
- Folders have the site's header, a … menu and Select: Download (Save to Files), AirDrop, Create Share Link, Invite,
  Add Media (Photos or Files), New Folder. Writes never overwrite.
- **Listen**: Recense on the iPhone and iPad. Start it from Control Center › Screen Recording › Gallery; the broadcast
  extension hears whatever is playing in any app, recognised on the device in its own language, cut into sentences
  and translated with Apple's on-device Translation. Lines float in a Picture in Picture window over every app,
  in Follow (sentence and translation, newest word lit) or Learn (two sentences taking turns); in the app, Read along
  with Copy, Clear and full screen. What's heard is kept per episode in the same transcript store as the Mac.
  The floating window draws as Sill's overlay does (same yellow, semibold words, the translation a step quieter);
  its middle button holds the words where they are and play shows the newest. Read along shows a word only once
  speech recognition has stopped rewriting it (Settle), so sentences grow calmly.
- **Export on iPhone/iPad**: the transcript editor's Export as MD and Export as M4B work in the app: the page hands
  the file to the app, which offers Save to Files; the M4B is made on the device (AAC, title, transcript as lyrics;
  no chapters yet).

### Gallery for the Mac (apple/macos, apple/HostApp/macOS)
- The whole site in a native window through the Mac's token, with an Assistant button (⌘K), the same … menu and
  Select, Download to Downloads and native AirDrop.
- Gallery as a location in Finder (File Provider extension). Deletes go both ways: what Gallery deletes leaves
  Finder, and a file deleted in Finder or Files goes to Gallery's trash for 30 days (`DELETE /main/api/fp/<root>/item`);
  folders are deleted in Gallery.

### The feed (fp.js)
Catalog and event log over Main and the archive: stable ids, md5 from R2 etags, one junk/churn list shared with Sync's
ledger, time-boxed passes that fit the Worker's CPU, batches older than 30 days in `history/`.

## Layout

```
gallery/
  wrangler.toml         Worker config (no secrets)
  src/                  the Worker
    worker.js           routes
    access.js           owner check (Cloudflare Access token, verified here)
    public.js           links, uploads, comments, preview cards, the nightly cleanup
    main.js             the library
    invite.js           participant links (/m/<token>)
    shared.js           /main/shared and Activity
    archive.js          /main/archive
    dav.js              WebDAV (chunked uploads past the 100 MB request cap)
    fp.js               the feed and app writes
    tmp.js              gallery-tmp
    listen.js           Listen on iPhone/iPad
    transcript.js       transcripts, content keys, locks
    corrections.js      corrections, glossary, timing overrides
    layout.js           where transcripts live in R2 (keep/<key>/...)
    ai.js, ai-core.js   the Assistant
    calendar.js         the Assistant's calendar
    images.js           /main/api/img and /i/ (Obsidian images)
    art.js, tagwrite.js cover art: read from audio tags, written back into MP3/FLAC
    common.js           responses, file types, paths
    player-key.js       serves the player's Key processor
    page/               the HTML pages
    client/             CSS and browser scripts (gallery.js, cadence.js, prosody.js, prosogram*.js, keylabel.js,
                        homebar.js, room.js, assistant.js, sharedview.js, upload.js)
  test/                 route, transcript, cadence, feed, assistant and page tests (npm test)
  apple/
    ios/                the iPhone/iPad project (GalleryFiles.xcodeproj), Broadcast extension, build.sh
    macos/              the Mac app's plists and build.sh
    HostApp/            the apps' SwiftUI sources (iOS: Browser, Player, Listen, Captions; macOS)
    Extension/          the File Provider extension
    FileProviderCore/   code shared by the apps and the extension
    Icon/               the app icon, drawn in code
  docs/architecture.md  File Provider design and the app's interface
  migrations/           D1 drafts
  chau/
    setup.sh            one-time: rclone remotes and this Mac's sign-in
    Gallery/            the Touch ID mount app (zsh build.sh)
    copy-share-link.sh  Finder Quick Action "Copy Share Link"
    move-to-gallery-main.sh, install-move-to-gallery-main.sh  Finder Quick Action "Move to Gallery Main"
    test-md-roundtrip.sh  Markdown open + edit round trip through the mounted Main folder
    rclone.conf.example the remotes, without keys
  r2/lifecycle.md       the buckets' lifecycle rules
```

## Routes (worker.js)
- `/`, `/s/<id>`: public links (`public.js`). `upload` takes the owner's files into `gallery-public/folders/<id>/`;
  `gallery` and `galleryApi` render a link and list its items; `file` serves one item (ranges, inline); `cleanup`
  (cron 03:00) deletes expired links and sweeps comments of deleted files. `GET /api/og-image/<id>` serves the preview
  picture.
- `/main...`: behind Access (`isOwner` verifies the Access JWT; anyone else gets the same 404). `mainFolder`,
  `mainFile`, `mainUpload`, `mainDelete` (into `trash/` for 30 days), `mainRename` (keeps `was` in metadata),
  `mainCover` / `mainCoverDelete`, `mainKey`.
- `/main/api/link`: a share link from Main (`linkApi`). `/main/api/invites`, `/m/<token>`: participant links.
- Shared Albums (notes 20261029 item 16), laid out like iOS Photos: on Main's root the row glides card by card
  (about 3 in view, the next peeking, wrapping both ways); Activity posts show the shared pictures large with a
  blue Like; an album opens on its cover with ▶ for a slideshow. Every file in a share is its own thread (comments, likes). People with an
  upload link can add files (`POST /api/upload?action=reserve`, then multipart parts, `guestUploadApi`); they expire
  with the link and show in Activity. Invite (Main) uploads stay until deleted. Links made from the archive are
  view-and-comment only (no posting, no `?dl=1`) until the owner turns on Subscribers Can Post / Allow Downloads on
  the share's page (`PATCH /main/api/shares/<kind>/<id>`).
- Data: `/main/archive?p=Data` (first at the archive's root; iOS Locations › Data) shows the Mac's offsite disks in
  `gallery-archive/.disks/` with their sizes (counted daily into `cache/disks.json`); exports land in
  `archive/Data/<disk>/` and show as files.
- Comments (`commentApi`): JSON per folder in R2.
- `/main/api/transcript`, `/api/transcript`: a file's transcript, its corrections (conditional on the version), and
  asking Recense for one (a lock in `keep/locks/<key>`).
- `/main/api/ai/*`: the Assistant. `PUT /main/api/img`: an Obsidian image, answered with its public `/i/` URL.

## Commands

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
| `SERVICE_CLIENT_ID` | The client IDs of the Access service tokens (one per device) |

Cloudflare settings outside this folder:

- Access application **Gallery Main**: `gallery.improvdiplomat.workers.dev/main`; allow the owner's email; Service Auth
  for each device's token.
- R2 API tokens: Object Read & Write, one bucket each.
- Lifecycle rules: `r2/lifecycle.md`.

### Native apps

```
zsh gallery/apple/ios/build.sh [device name or id]   # builds and installs on a connected iPhone or iPad
zsh gallery/apple/macos/build.sh                     # builds and installs the Mac app in /Applications
```

Signed with a free Personal Team, so the iOS profile lasts 7 days; `../sync/bin/resign-ios.zsh` re-signs it daily
when 2 days or less are left. The device's Access token comes from the Keychain (`gallery-access-<device>`, else
`gallery-access`) into `Secrets/token.json`, which git ignores.

### Mac setup

```
zsh gallery/chau/setup.sh          # paste the keys when asked; nothing is shown
zsh gallery/chau/Gallery/build.sh  # builds /Applications/Gallery.app
```

`Gallery.app` unlocks an encrypted `rclone.conf` with Touch ID, mounts the buckets hidden at `~/Gallery`, stays open
until lock, sleep or idle, and wipes its cache on close. Command-drag it into the Finder sidebar. Sharing the mount
between devices: `SYNC.md`.

For the Quick Action, make an Automator Quick Action (files or folders in Finder, Run Shell Script, `/bin/bash`, input
as arguments) containing:

```
exec /bin/bash "$HOME/Developer/gallery/gallery/chau/copy-share-link.sh" "$@"
```
