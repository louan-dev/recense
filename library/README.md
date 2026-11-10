# gallery

Gallery is the `library/` folder of the one repo, `louan-dev/recense` (A15). My library and share links, served at **https://gallery.improvdiplomat.workers.dev** (Cloudflare Worker + R2),
with native apps for macOS, iOS and iPadOS and a Finder/Files location.

## Why this exists
Gallery is where my library lives now that it no longer fits in iCloud or on an old MacBook with 8 GB of memory and a
disk that is always almost full. Photos, recordings, notes and calendars kept growing; failing SanDisk drives and a
full iCloud broke the syncing I depended on. So I moved things somewhere I can hold: R2 for storage, a Worker I wrote,
and native places in Finder and Files that still work when the connection doesn't. Apple Calendar gave way to my own
CalDAV, and confidential things stay mine.

But it is not only a storage story. I learn best through many senses at once, the way a song can teach a language
faster than a textbook ever did for me, so Gallery plays, shows, lights and translates what I keep, and shares
transcripts with Recense. I hope that turns everyday media into a playground for my family, for neighbours who
meet English as a barrier, for English speakers exploring other cultures and cities with a curious mind, and for
people with disabilities who deserve learning that meets them where they are. It is a small, humble attempt to make
technology a little more accessible and a little more humane, built from what has worked for me, and offered freely.

English works like the shared tuning of modern instruments, which divides the octave into twelve equal steps. It lets
players from many traditions perform together, and it softens some of the colour that belongs to each key. Fluency in
it is distributed by region and privilege, and by curricula that governments choose for reasons of their own, while
the tools that turn speech into text learned mostly from English and a handful of powerful languages. So spoken wisdom
in English and in other languages face each other through glass, visible in outline while the words go unheard.
Gallery and Recense try, in a small way, to open that window: the original keeps its colour, a translation supplies
the common tuning, and a link carries both to someone who goes looking. The longer essay is in Recense's
[preface](https://github.com/louan-dev/recense/blob/main/docs/recense-preface.md).

## Long-term outcomes
- Every file usable with no connection on Mac, iPhone and iPad, in each device's native place (Finder, Files).
- Edits flow both ways when a connection appears; nothing runs 24/7; R2 is the storage, the Worker the sync engine.
- One place to view, play, listen to, share and ask about everything I keep.

## Addresses

| Address | What | Bucket |
|---|---|---|
| `/` | Make a new link from files on this device (only you) | `gallery-public` |
| `/s/<id>` | A link: anyone who has it can view, download, comment and like | `gallery-public` |
| `/m/<token>` | A participant link to one folder (view / download / upload / comment) | `gallery-main` |
| `/m/<token>/feed.xml` | A show's podcast feed, for an invite to a folder made by `chau/show.mjs` | `gallery-main` |
| `/main` | The library: browse, play, upload, rename, delete (only you) | `gallery-main` |
| `/main/archive` | The archive's page and player, read-only | `gallery-archive` |
| `/main/shared` | Every live share link as an album, with Activity | `gallery-public` |
| `/main/dav-tmp/`, `/main/dav-archive/`, `/main/nc-archive/` | WebDAV for rclone mounts | `gallery-tmp`, `gallery-archive` |

On the Mac, **Gallery** in the Finder sidebar opens `~/Gallery` after Touch ID, with two folders:

- **Public**: each folder inside is one link, deleted when the link expires (7 days by default, 30 at most).
- **Main**: kept until you delete it. Deleted files go to `trash/` for 30 days.

`gallery-tmp` keeps everything for 14 days (`tmp/` links for 1 day).

## Features

### The viewer
- Viewer shell (G3, `src/client/viewer-shell.js` + `.css`, over gallery.js through `window.__galleryViewer`): the framing states only, with a spring (stiffness 320, damping 32, mass 1) that follows the finger 1:1, translate3d and scale only, on the media layer. **A Full-bleed** (tap the media from B: 100%, no radius, top bar and bottom row faded and untappable), **B Framed** (default: scale .82, radius 24px, black around, a soft glow of the item's own artwork behind it), **C Docked** (swipe up or Info: the media docks above the sheet; a phone on its side keeps the media beside it; the bottom row steps aside). The top bar, the thumbnail strip with "Add a comment…", the home bar and the sound stroke are the viewer's own (gallery.js, homebar.js) and the shell never draws, moves or fades the two home bars. (2026-11-02: the round-back/two-line top bar, the 2D scrubber, the action capsule and the centred filmstrip were tried and taken out again; the dock height is the viewer's own `--mh`.) One active item (`#lb[data-active]`) drives stage, strip, title and sheet. A click views or plays, never downloads.
- State C sheet (G5, `src/client/viewer-sheet.js` + `.css`), the same for every kind of item, top to bottom: the comments, each cut to three lines with a blue "more" (a tap on a word opens it, the edit caret on that word); the inspector, a Transcript | Info pill (transcript lines with their times; editing one loops it until Save or Cancel and saves a `line:<n>` override; Info is the file's name, type, size, length and EXIF); the cards rise in one after another; the metadata card, "Day • Date • Time" with a blue Adjust (time, location); name, type, size, length and camera are in Info, not on the card — overrides are non-destructive (`/main/api/meta`, D1 `metadata_overrides` + `revisions`, else `meta/<path>.json` in R2), marked "edited"; Revoke drops one, Clear writes a revision first, Changes lists every revision with Restore; the map (Leaflet 1.9.4 from unpkg, OpenStreetMap tiles, no key, darkened), the item as a rounded thumbnail pin, the folder's other items in view from `GET /main/api/geo?dir=&s=&w=&n=&e=` (or `/m/<token>/api/geo`, only what the link may see) on every move, close pins grouped with a count, a tap opens that item; the map keeps its own drags; Adjust moves the pin, Revoke puts it back; no place, no card. Invitees see the card and map read-only. EXIF is read from JPEGs only (40 new files per request, cached per ETag in `geo/<dir>/.geo.json`).
- Grid, strip and viewer; click views or plays, never downloads. Info holds Download, Rename, Change Cover, Key, native
  language and New Window.
- Collection search (Goal 43.32): a Search pill above the grid ("Search <collection>"). It matches notes and
  comments, cached transcript lines, titles, paths, dates and kinds; results are grouped by year, newest first, with
  the match marked and a "Show All Results for …" row; ✕ or Esc restores the grid. Rows use light thumbnails (no
  `<audio>`/`<video>`). Add Media is hidden on read-only roots (Archive).
- On iPhone and iPad, smaller decode limits (whole-file decode up to 24 MB or 8 min, key detection up to 20 MB), and
  key detection pauses while the deck decodes.
- Home-bar swipes in a browser: a momentum glide (12+ steps, each no bigger than the last, under 80 ms apart) is
  never the fingers, so the seek lands where they lifted; a swipe that just stops stays held. Item 31: the notation
  toggle sits on the music page beside Chords, and a chord shows only after holding 1 s on ~1 s-smoothed chroma.
- Player: rewind / play / forward, time bar, Loop and A–B, Speed 0.5×…2× (pitch kept), volume. EQ panel: Low, Mid,
  High, Key and Room. Sized per device (phones, iPad Air 13", large monitors).
- Loops cost no requests on Safari and in the iPhone and iPad browsers: with Sound on (EQ, Key, Room or vocal
  isolation), a WAV or AIFF plays through the deck, which streams it in chunks of about 1.5 s. While A–B or Track Loop
  is on, the deck reads ahead in loop order (A's chunk after B's, nothing past B) and keeps the loop's bytes in memory,
  up to 64 MB (about 6 minutes of CD audio), so every pass after the first plays from memory. A longer loop streams as
  before and says so in the console.
- Key: semitones from the original key, named in the chosen notation (Key, Ton., Tông, Tonart, 調, 调, Sa, Maqam,
  Maqam¼, Cents). A file with no stored key has it detected on first open.
- Downloads of audio with Key, EQ or Space on are rendered as heard.
- Comments under each item: Post / Delete / Cancel; swipe your own comment for Delete.
- Posting someone else's words: tap your name on your comment and type who said it (empty puts your name back).
  API: `PUT /main/api/caption` with `{ op: "add", text, as }` or `{ op: "label", cid, as }`; owner only, edit/delete stay yours.
- Who said it: an invitee posts as the name on their invitation (one invitation per name, never the owner's). The first
  write with an invite link accepts it and makes one guest (`src/identity.js`, records under `guests/`, `sessions/` in
  the MAIN bucket); from then on the link opens only for that guest, signed in on any of their devices: by passkey
  (iCloud Keychain or any provider), a one-time link made on a signed-in device (comments › Devices), or an emailed link
  once email is set up (bind `send_email` as `EMAIL` and set `EMAIL_FROM`; until then the email option is hidden).
  Revoke ends every session and the guest can't sign back in. `/m/<token>/invite.ics` is the invitation's calendar
  event (Gallery access, start = created, end = expiry, link as location and URL, a reminder before the end); the
  owner's Invite sheet has Calendar (while the link is known), each guest's devices, passkey and email, and Sign Out.
  A guest on a share
  link types a name once, in the field above their first comment; the server keeps it with their cookie, so it can't be
  changed or be an invitee's. Each comment carries a tiny flag: the country Cloudflare sees the connection from
  (`request.cf.country`, set by the server only; a VPN moves it). All of it lives in the Worker and R2; WebDAV has no part.
- Documents open as pages: PDF, Markdown, Word (.docx), plain text. In Main, Markdown and plain-text files have
  **Edit** / **Save** / **Cancel** on the page (iPhone and iPad too): the save is refused if the file changed elsewhere
  since it was opened, and the version it replaces goes to the trash.
- **Docs** in Main holds every document from the Mac (Obsidian, iCloud Drive, Documents, Downloads, Developer,
  Google Drive, Voice Memos, Notability's PDFs), kept in step both ways by Sync's `bin/docs-sync.zsh`; `Docs/INDEX.md`
  lists them by source.

- Swiping (P0): only the item on stage is live; its neighbours are at most a decoded picture. Leaving an item pauses and empties its media, revokes its blob: URLs, shrinks its canvases and aborts its key detection, which now starts only after 1.5 s on one track; the AudioContext is suspended while nothing plays. A swipe within 280 ms of the last shows the cover and mounts the player once swiping stops. Back to the folder always draws (the grid is rebuilt if empty and repainted; also on `pageshow`).
- Editing your comment: the caret lands on the character you tapped (found on pointerdown, before the keyboard moves the page); the field takes the comment's typography and the thread holds still until the viewport settles.
- Tests: `node test/viewer.test.mjs` (in `npm test`) runs each viewer regression on iPad Air 13", MacBook Pro 13" and iPhone 12 Pro Max, portrait and landscape, touch and pointer; failures leave screenshots in `gallery/test/.shots/viewer/`.
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
- A whole stanza by ear: Whole line loops the line; tap its first beat, then its last, and it loops between them
  until Use this cadence (or Retry). The words then follow the voice inside those two beats; if that still isn't it,
  Trace it: slide a finger along the line as it is sung and each word takes its start, end and fill from the path.
  Back to the voice undoes it. One word at a time, the trace pad under Start and End shows the word itself in white
  (no graph, nothing moving through it): touch it and the word loops with a breath before it, slide along it as it
  is sung and the light copies the finger, never going back; ↑ ↓ for faster or slower at first, double-tap for the
  voice. The finger counts anywhere in the pad's height, so it can slide under the letters without hiding them, and
  a long line shrinks onto one row. Tracing the line loops that line alone (1.5 s pre-roll).
- Fixes (item 40 bug report): a word's light always reaches its last letter; the notation under a line fades with
  its words; an editor field saves only text typed into it, onto the line it was opened on, and Restore only onto
  the line the change was made on (one line's words had landed on another's).
  The Prosody / Chords / Notes toggle lives on the EQ's music page, beside Chords.
  Item 31: chords and notes show in Learn only (not Follow); the chord readout smooths the chroma over ~1 s and shows a
  chord only once it has held for 1 s; a notated note is the longest steady pitch run in the syllable, read against the
  track's own tuning.
- The editor is quiet: Changes · a grabber · Done; the tools fold under the grabber (tap, or rest the pointer on it).
  Paused with no line up, a grabber where the lines show opens the editor.
  A word being timed keeps its marks up when the phone is turned or the server's lines come back; on a short
  landscape screen the editor ends above the strip, comment field and home-bar grabber.
  While the editor is open the thumbnail strip and Share step aside; Done brings them back.
  What plays keeps the top of the screen while editing (the video, or the lines on audio), the editor is a pane
  under it that ends above the home bars, which stay with all they do; on a short landscape screen the video is on
  the left and the editor beside it.
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
Recense (on the Mac) transcribes Main's audio and video while idle and keeps every transcript in R2 under
`keep/<key>/` (`asr.json`, `tr/en|vi|fr.json`, `corrections.json`, `history/`). The key is the file's **content key**:
the first 24 hex of SHA-256 of `fp:<bytes>:<sha256 of the first 64 KiB>:<sha256 of the last 64 KiB>`, computed the
same way on the Mac, so one recording has one transcript wherever it plays, renamed, moved or uploaded twice.
`keep/library.json` aliases a recording heard from another source, with its time shift.
A corrected line keeps the space typed before `! ? ; :` (French writes `fini !`); a space before `, . …` and the
Arabic and Ethiopic stops is dropped. Recense joins words by the same rule. Pushing to `main` a change under `library/` deploys (`.github/workflows/library.yml`): GitHub Actions installs the test browsers and `xmllint` (the feed test validates the podcast XML with it), runs `npm test`, then `wrangler deploy`. The comment swipe-to-delete UI test waits for the thread's scroll to settle before it swipes, so a slow runner no longer fails it (it had blocked every deploy since 11-05).

### Storage
- Buckets: `gallery-public` (Public) and `gallery-main` (Main), plus the read-only archive; on the Mac they mount at
  `~/Gallery` through `Gallery.app`. Transcripts and their timing live under `keep/<key>/` (asr.json, tr/<lang>.json,
  corrections.json, features.json). Comments, captions and folder order are JSON objects in R2 (Main comments move to D1 once it is bound, below).

- D1 (C1, `src/d1.js`, `migrations/`): invitations, folder locks, Main comments and likes, annotations, metadata overrides and their revisions. Used once the `DB` binding exists; R2 JSON is copied in lazily on first read and kept as a backup. Until then everything stays in R2 as before. The database `gallery` exists (id in `gallery/wrangler.toml`); apply the schema with `npx wrangler d1 migrations apply gallery --remote` before the first deploy that uses it.

### Sharing
- Share links from Main, the archive or the apps; each draws a large preview card in iMessage, Messenger and Telegram.
- Guests comment and like under a name given once (random HttpOnly cookie, stored hashed), editing only their own.
- `/main/shared`: Personal | Shared | Activity (participant uploads, likes, comments); Delete expires a link now.
- Participant links (`/m/<token>`, `src/invite.js`): one folder each; tokens are 32 random bytes, stored as SHA-256 only. Permissions view, download, upload, comment, react, annotate (defaults: all but annotate; a room never uploads); per-file overrides; a view-only lock per invitation and per folder (`PUT /main/api/invites/locks {dir, locked}`); no expiry unless set; revoke. Every check is in the Worker; an unknown, expired or revoked link is one 404, and no request through a link can delete or replace the owner's files, comments or annotations. Download off still plays media inline but refuses `?dl=1` and non-playable files.
- Annotations (`src/annotations.js`): notes pinned to a time or a spot of a Main file; owner at `/main/api/annotations`, invitees at `/m/<token>/api/annotations` with the annotate permission, deleting only their own.
- Link answers from `/main/api/link` carry `href`, the absolute link, beside the relative `url`.

### Shows (private podcasts, `chau/show.mjs`)
- A Markdown outline becomes a show: one episode per `## ` section, spoken by a macOS voice, AAC `.m4a`.
- Publish (renders, then syncs to Main's `Shows/<show>/` over the rclone remote `gallery-main`; a section you drop goes to `trash/<date>/`):
  `node chau/show.mjs publish <outline.md>` (show name = the `# ` title; `--show <name>` to choose).
- Languages: `--lang vi` (Linh), `--lang fr` (Thomas, else Amélie), default English (Ava Premium); `--voice <name>` picks any installed voice (`say -v '?'`).
- Rendered audio is cached in `~/Library/Caches/recense-shows`, so a re-publish only speaks changed sections. `--dry-run` renders without uploading.
- Client matters never leave the Mac (A6): an outline is refused when it sits under a `Matters` or `Raven` folder, when the show's name says Matters or Raven, or when its front matter or a `#matters` / `#raven` tag does. This is a guard on names and tags, not a classifier: a client document copied elsewhere, renamed and untagged, gets through, so keep client work out of outlines you publish.
- Licensed course material (PLIv1) is for your own listening, never shared.
  - An outline is licensed when its front matter says `source: PLIv1…` or `licensed: true`, or when you publish
    with `--licensed`.
  - `publish` writes `"licensed": true` into `.show.json` and prints no invite hint.
  - `invite` reads the show's `.show.json` first. It refuses a licensed show, and any show whose `.show.json` can't
    be read, before any link is made.
  - Listen to a licensed show in Recense, signed in, not through a feed link.
- Headings and show names are stored in Unicode NFC (as rclone stores names), so Vietnamese text pasted from a PDF names the same file the feed looks up. Two sections with the same heading get different episode ids.
- The episode list is `.show.json` in the show's folder (hidden in Gallery's folder view).
- The feed link (after the Worker with `src/feed.js` is deployed): `node chau/show.mjs invite "<show>" --name <who> [--days 30] [--guest]`.
  It prints `https://…/m/<token>/feed.xml`; on the iPhone: Podcasts > Library > ••• > Follow a Show by URL…, paste it.
  The feed link is view-only, so it never gets locked to one signed-in browser. `--guest` adds a second link, the web page, where they can also react and comment.
  Both expire after `--days`; `node chau/show.mjs revoke <id>` (the id it printed) ends one at once.
- The feed (`GET /m/<token>/feed.xml`, `src/feed.js`): RSS 2.0 with the iTunes namespace, `itunes:type` serial, episodes in outline order; each enclosure is the link's own `/m/<token>/f/<file>`, so every download is checked like any other. A wrong, expired or revoked token, a folder with no show, or a show with nothing this link may see is the same 404.

### Assistant
Ask from the top bar (⌘K), scoped This folder | Main | Archive | All. Plans searches, cites sources, keeps memories;
published references are trusted, your own writing once checked. Calendar: reads your events and the
iCloud backup, creates and edits events, invites with a texted link. Indexing runs in bounded steps from a cron every
10 minutes (every minute until 2026-11-05), within a daily budget of AI-using steps that idle runs no longer spend.
Main's `Raven/` (client matters) is never indexed or answered from; its old vectors leave on the next sweep.

### Native apps (moved)
Recense for iPhone and iPad, and the retiring Gallery for the Mac, are in `../mobile/` (`mobile/README.md`).

### The feed (fp.js)
Catalog and event log over Main and the archive: stable ids, md5 from R2 etags, one junk/churn list shared with Sync's
ledger, time-boxed passes that fit the Worker's CPU, batches older than 30 days in `history/`.

## Layout

```
gallery/
  wrangler.toml         Worker config (no secrets)
  src/                  the Worker
    worker.js           routes
    access.js           checks it is you (Cloudflare Access token, verified here)
    public.js           links, uploads, comments, preview cards, the nightly cleanup
    main.js             the library
    invite.js           participant links (/m/<token>)
    feed.js             a show's podcast feed (/m/<token>/feed.xml)
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
    page/               the HTML pages; page/ui/README.md holds the interface rules (the reference images
                        were removed 11-05; git history keeps them)
    client/             CSS and browser scripts (gallery.js, learn.js, cadence.js, prosody.js, prosogram*.js, keylabel.js,
                        homebar.js, room.js, assistant.js, sharedview.js, upload.js). learn.js holds Learn's pure
                        rules (phrases, beats, clause ends; global RecenseLearn), loaded before gallery.js and shared
                        with Draftpad's editor
  test/                 route, transcript, cadence, feed, assistant and page tests (npm test)
  (the iPhone, iPad and Mac apps moved to ../mobile/ on 11-06)
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
- `/`, `/s/<id>`: public links (`public.js`). `upload` takes your files into `gallery-public/folders/<id>/`;
  `gallery` and `galleryApi` render a link and list its items; `file` serves one item (ranges, inline); `cleanup`
  (cron 03:00) deletes expired links and sweeps comments of deleted files. `GET /api/og-image/<id>` serves the preview
  picture.
- `/main...`: behind Access (`isOwner` verifies the Access JWT; anyone else gets the same 404). `mainFolder`,
  `mainFile`, `mainUpload`, `mainDelete` (into `trash/` for 30 days), `mainRename` (keeps `was` in metadata),
  `mainCover` / `mainCoverDelete`, `mainKey`.
- `/main/api/link`: a share link from Main (`linkApi`). `/main/api/invites`, `/m/<token>`: participant links.
- Cover blur and Edit Cover (notes 20261029 item 16): covers on the front pages keep their art and colours but text
  in them is blurred (lines show, words don't), Medium by default. Each card has its own cover and level, set in the
  Edit Cover panel: on the site ⋯ › Edit Cover on Main's front page (starts on the selected card; chips switch card)
  and Edit Cover on a share link's page in Exhibits; in the app ⋯ › Edit Cover or long-press an Archive card. Pick
  any picture in the folder, then Off/Low/Medium/High. Saved in `cards.json` (`/main/api/cards`, place main or
  archive) and a link's manifest (`coverBlur`, link arrange API). Site: `src/client/coverblur.js` (finds text by
  dense colourless edges); app: Vision's text boxes. Inside a folder nothing is blurred. Exhibits list cards blur too.
- Renames reach share links: renaming a Main file updates the links made from it (`renameInLinks`), so Exhibits and
  Activity ("Visionary & 7 more") show the new name.
- Front pages (notes 20261029 item 16): on the site's Main root each collection is a rounded square card wearing
  its first picture or video, 2 columns scrolling down; the app's Archive root does the same (covers from
  `/main/archive?covers=1`). The app's home is Galleries: Ask and Listen on top, then Main, Archive and Data as
  cards, then Exhibits. The Activity tab's Personal is now Main. Inside folders nothing changed.
- Exhibits (was Shared Albums; notes 20261029 item 16): the header and a front card (the newest share's cover) open
  the Activity feed; top-bar controls (Personal/Shared/Activity, back, +, ⋯, lightbulb) are white and turn blue on
  hover or press; Ask beside ⋯ is now just the lightbulb. In the iPhone/iPad app Exhibits is its own place under
  Locations (`/main?exhibits=1`) and Main leaves it out; Copy Link / Open on a share go through the app
  (clipboard, Safari) since the page runs on gallery://.
- Shared Albums (notes 20261029 item 16), laid out like iOS Photos: on Main's root the row glides card by card
  (about 3 in view, the next peeking, wrapping both ways); Activity posts show the shared pictures large with a
  blue Like; an album opens on its cover with ▶ for a slideshow. Every file in a share is its own thread (comments, likes). People with an
  upload link can add files (`POST /api/upload?action=reserve`, then multipart parts, `guestUploadApi`); they expire
  with the link and show in Activity. Invite (Main) uploads stay until deleted. Links made from the archive are
  view-and-comment only (no posting, no `?dl=1`) until you turn on Subscribers Can Post / Allow Downloads on
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
cd ~/Developer/recense/library
npm install
npm test
npx wrangler deploy
```

Secrets (set once with `npx wrangler secret put <NAME>`):

| Name | Value |
|---|---|
| `ACCESS_AUD` | The Application Audience tag of the Access application "Gallery Main" |
| `OWNER_EMAIL` | Your email, the only one allowed into Main |
| `SERVICE_CLIENT_ID` | The client IDs of the Access service tokens (one per device) |

Cloudflare settings outside this folder:

- Access application **Gallery Main**: `gallery.improvdiplomat.workers.dev/main`; allow your email; Service Auth
  for each device's token.
- R2 API tokens: Object Read & Write, one bucket each.
- Lifecycle rules: `r2/lifecycle.md`.

### Native apps
The iPhone, iPad and Mac apps moved to `../mobile/` (11-06): see `mobile/README.md`. They use this Worker's API.

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
exec /bin/bash "$HOME/Developer/recense/library/chau/copy-share-link.sh" "$@"
```
