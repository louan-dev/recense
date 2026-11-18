# FEAT-22 · Where notes, transcripts and the index live, how they catch up, and who sees them (Main and Guest)

From: owner 2026-11-16 (design review and the nine decisions listed below) · Status: `[ ]` written, not built
Linked specs: FEAT-23 (notes) · FEAT-21 (search) · FEAT-06 (homes) · FEAT-09 (Carry) · FEAT-02 (nearby transport) ·
FEAT-18 (the hub) · FEAT-10 (translation on the device) · FEAT-20 (the song light; lane sync-spec owns its timing).

Labels: **proven** = a test or the code shows it (file:line) · **assumed** · **untested**.

## Verdict
**Everything needed to read, write and play is a plain file on the device in hand.**
**Other devices are caught up later, by the nearest route that works. No company is on the required path.**
**Guest is the same app with a role value, not a second layout.**

## Terms
- **Main:** the owner's app. **Guest:** the app a loved one uses.
- **Role:** one value read at launch, `main` or `guest`. Views ask the role what to list; there is one set of views.
- **Catch-up:** copying changes between devices after the fact. It never makes a reader, writer or player wait.
- **Carry:** Recense's own device-to-device sync over Bluetooth and Wi-Fi, with no internet (FEAT-09).
- **Hub:** the owner's Mac answering at `https://recense.local` on the home network (FEAT-18).
- **Shelf:** a flat row of albums. No folders inside folders.

## The owner's decisions (2026-11-16; built in, not reopened)
1. One engine and one set of views for Main and Guest.
2. Guest opens on its own home: shared albums first. Never the owner's vault, private collections or admin controls.
3. Guest albums are flat shelves.
4. Each guest has a private "Mine". The owner sees nothing in it unless the guest shares it.
   The owner's Mac processes a guest's file only after that guest opts in.
5. Guest transcription runs on the guest's own device, offline. The Mac's heavier pass is a later upgrade.
6. Sync is catch-up and never blocks. A guest far away still works. Any company is optional, with an exit.
7. Every action has one visible control.
8. The shared audiovisual album starts as a thread of voice notes, each transcribed and translated.
   Calendar suggestions wait for the owner's own CalDAV server.
9. Mac and mobile differ by role, not look: the Mac is the hub (heavy work, full archive); phone and tablet capture and listen.

## Part A · Where things live

### The rule
One folder shape on every device (FEAT-06). Mac: `~/Recense/`. iPhone and iPad: `Documents/Recense/`, visible in Files.
**proven** `shared/homes.swift:74-81`.

```
Recense/
  library/…  downloads/  trash/     the media (the homes; carried today)
  keep/
    <key>/note.md                   the note (FEAT-23)            source of truth, synced
    <key>/lines.json                the transcript, as shown      source of truth, synced
    <key>/find.tsv                  the search index (FEAT-21)    derived, never synced
    <key>.v2.json, <key>.tr.*.json  the Mac's working files       stay as they are, Mac only
```

- **`lines.json`** is the transcript in the shape every screen already reads:
  `{ lines: [{ id, s, e, text, en, words: [{ t, s, e }] }] }`, corrections and translations merged in.
  **proven** that shape is decoded by `TranscriptSource.decode`, `shared/ShowsKit/Sources/ShowsKit/TranscriptSource.swift:30-40`,
  tests `TranscriptSourceTests`.
- **Who writes it:** the device that made or changed the transcript. The Mac after its pass or a correction;
  a phone after its own ears finish.
- **Upgrade rule:** a heavier pass replaces `lines.json` only if it is newer, and it carries every correction over.
  A correction that cannot be re-attached by time is kept and listed, never dropped. **assumed**; P2's check proves it.

### What is true today (checked 2026-11-16)
- **proven** Three layouts exist for the same transcript:
  - Mac: flat files in `~/Recense/keep/` (`strip/keephome.swift:21`; 537 transcripts, 382 voice measures, counted on the owner's Mac);
  - iPhone and iPad: `Application Support/Recense/transcripts/`, one file per media path, not per key
    (`mobile/HostApp/iOS/Ears.swift:23-25`), hidden from Files;
  - Cloudflare R2: `keep/<key>/…` (`strip/recense.swift:330`, `shared/ShowsKit/Sources/ShowsKit/Model.swift:8`).
- **proven** A phone gets the Mac's transcript **only through the Cloudflare Worker** today:
  `TranscriptSource.swift:1-5` (device copy, else the Worker, else hear it here).
  - Applied to the owner's rule (no company on a required path): reading still works offline from the device copy,
    so the gate at the moment of use holds. But the only catch-up route is one company. **This spec closes that.**
- **proven** Carry does not carry `keep/`: it walks the homes only (`shared/homes.swift:343`), and its watcher
  ignores `keep/` on purpose (`shared/carrysync.swift:204-205`, T-0091: the cache was written every few seconds).
- **proven** Carry cannot merge text yet: a text conflict keeps both files (`shared/carrymanager.swift:443`;
  INDEX, FEAT-09: "text merge against a tracked base still open").
- **proven** The hub syncs one note with a three-way merge (`editor/src/hubsync.js:1-8`: `POST /api/note {base, mine}`),
  text only (FEAT-18 § H1).
- **proven** The three-way text merge exists and is shared: `shared/notesync.swift` (used by both Draftpad hosts).

## Part B · How devices catch up

### The ladder (first rung that answers wins; lower rungs are never required)
1. **This device.** Always first. Instant, offline.
2. **A paired device nearby** (Carry over Bluetooth or Wi-Fi; no internet, no router needed).
3. **The hub** on the home network (`recense.local`).
4. **Cloudflare R2 through the Worker.** Optional. For when the owner is away from home and from the other devices.
   Exit: `rclone copy` of the bucket to any S3-compatible store or a plain disk (config names: `~/.config/rclone/jobs.conf`).

### Rules
1. **Only two small files per item are carried from `keep/`:** `note.md` and `lines.json`. Never `find.tsv`,
   never the Mac's working files, never the cache. This keeps T-0091 fixed (no carry storm).
2. **A change is carried after 2 s of quiet** on that file, while a paired device is connected
   (Carry's own debounce: **proven** `shared/carrysync.swift:217` `quiet = 2`, `:231`).
3. **Notes merge three ways.** Each device remembers the text it last agreed on per note (`keep/<key>/.note.base`, hidden).
   Clean merge: one note. No clean merge: both kept side by side, named with device and time
   (Carry's keep-both rule, `shared/carryapply.swift:61,126-129`). Never last-writer-wins.
4. **Transcripts do not merge; the newer upgrade wins** under the upgrade rule above. Corrections merge by segment
   (the Mac's existing rule, `strip/recense.swift:715`).
5. **Nothing waits.** Typing, playing and searching never show a spinner for sync. A quiet line in the notes list
   says "Last caught up: 14:02 · iPad" (one line, no badge storm).
6. **A moment link resolves by the same ladder** (FEAT-23 rule 9): play the device copy; else ask a paired device;
   else the hub; else R2; else say "not on this device" and offer to fetch.

## Part C · Main and Guest

### Rules
1. **Role, not fork.** The Guest app is the same code with `role = guest`.
   - Today it is a compile flag that cuts the app down to Now Playing: **proven** `mobile/HostApp/iOS/GuestApp.swift:1-18`.
     That is the "lite layout" the owner rejected; this spec replaces it.
2. **What the role hides (one list, one test):** Matters, Sealed, Raven; the owner's vault and Draftpad vault;
   Carry pairing with the owner's devices; admin (tokens, hub, Terminal, Gallery archive).
   - **proven** the lock rule exists: `shared/ShowsKit/Sources/ShowsKit/Rules.swift:14-18`. **untested** for Sealed
     (the function names Matters and Raven only) and for a role value (none exists yet).
3. **Guest home, top to bottom:** **Shared** (one shelf of albums) · **Mine** · Now Playing. Nothing else.
4. **Mine** is `library/Mine/` on the guest's device, with its own `keep/`. It is never carried, synced or listed
   anywhere else. Notes a guest writes are in Mine, including notes on shared items (**open question 6**).
5. **Sharing is an explicit act with one control:** "Share to album…" on an item in Mine. It copies the item into
   `library/Shared/<album>/` and that folder is what catches up with the owner.
6. **Mac help is opt-in:** Guest settings has one switch, "Let the owner's Mac improve my transcripts", off by default.
   Off: the Mac never receives a guest's audio for processing. On: only items the guest has shared (**open question 7**).
7. **Guest transcription, translation and search run on the guest's device.**
   **proven** on-device ears exist for stored files: `mobile/HostApp/iOS/Ears.swift`, test `Ears.gate` (FEAT-16 P3).
   **proven (built, device check owed)** on-device translation: FEAT-10.
8. **An album is a show.** It reuses the show page and its rows (`ShowsKit` `Views/ShowPage.swift`, FEAT-07 P0).
9. **The first shared album is a thread of voice notes.** One control, **Record**, at the bottom of the album.
   Each recording is one `.m4a` plus its `lines.json`. Rows read oldest to newest, like a conversation.
   A row shows who, when, the first transcript line in the reader's language, and Play.
10. **Far away works.** A guest abroad records, transcribes, reads and plays with no network.
    Their shared album catches up by rung 2 or 3 when visiting, or by rung 4.
    - **proven** rung 4 exists for guests today as Gallery share links (BUG-20, BUG-23: guests add media to a link).
    - **untested** whether album content on rung 4 can be sealed so Cloudflare holds only ciphertext.
      A sealing layer exists in a spike (`shared/pieces/Sources/Pieces/Pieces.swift:44`, AES-GCM per piece). **Open question 5.**

## Outside services
| Service | When | Required? | Exit |
|---|---|---|---|
| None | reading, writing, playing, searching, transcribing, translating | — | — |
| Apple language packs (speech, translation) | once, at setup, per language | yes, once | already on the device afterwards; size and source recorded at download (FEAT-10) |
| Cloudflare Worker + R2 | catch-up rung 4 only | **no** | `rclone copy` to any S3-compatible store or disk; rungs 2 and 3 need no company |

## Phases (each ends with its check)
- **P1 · Carry takes `note.md` and `lines.json`** (Mac, iPhone, iPad). The Mac writes `lines.json` when a transcript
  completes or is corrected; iOS reads `keep/<key>/lines.json` before asking the Worker.
  - Check 1 (test, `carrysync`): a write to `keep/<key>/note.md` counts for the watcher; a write to
    `keep/<key>.v2.json` or `find.tsv` does not (guards T-0091).
  - Check 2 (canary, real path): with Wi-Fi off the router and Cloudflare blocked, a note line typed on the Mac
    appears on the iPhone, and a transcript made on the Mac opens on the iPhone. The owner confirms the phone side.
- **P2 · Three-way note merge with a tracked base; the upgrade rule for transcripts.**
  - Check: tests: two devices edit different lines → one merged note; the same line → both kept, nothing lost;
    a heavier pass replaces a phone transcript and all corrections survive or are listed.
- **P3 · The hub serves the same two files** (FEAT-18 H2 slice): `GET/POST /api/keep/<key>/note` (the H1 note protocol),
  `GET /api/keep/<key>/lines`. Check: hub test + the P1 canary with Bluetooth off.
- **G1 · The role value** replaces the `GUEST` compile flag; Guest shows Shared · Mine · Now Playing with the same views.
  - Check: test: with `role = guest`, no path under Matters, Sealed or Raven and no admin screen is reachable
    (a list of every route, asserted empty). Screenshot audit of Guest's home on iPhone.
- **G2 · Mine and "Share to album…".** Check: test: a file added in Mine never appears in any outgoing op log
  until shared; after sharing it does.
- **G3 · The voice-note thread.** Check (device): record in airplane mode → transcript and translation appear →
  later the row appears on the owner's phone.
- **G4 · The opt-in switch and the Mac's upgrade pass.** Check: test: switch off → the Mac's queue refuses a guest item.
- **P4 · One transcript layout on iOS** (move `Application Support/…/transcripts` to `keep/<key>/lines.json`, read-old-write-new).
  Check: an old device copy still opens after the move; nothing is deleted until the new file verifies.

## Reference (2026-11-18, research paste checked)
- `carrymanager.swift:480` still passes `base: [:]` (proven): P1's tracked base is the fix, as planned.
- Automerge (`automerge/automerge-swift`, MIT) is a study reference for how marks and cursors keep their place through concurrent edits
  (ink, voice pins, `segId` highlights). It is not a dependency: a Rust core behind a binary fails the 10-year, own-the-source rule.

## Risks and edge cases
- **Clock skew between devices** decides "newer". Use the ops log's order (FEAT-09), not wall-clock time alone.
- **`keep/` is visible in Files on iOS.** A person could delete a note there. It goes through the system's
  Recently Deleted; Recense never deletes a note itself outside rule FEAT-23/8.
- **A guest's device is not the owner's.** Nothing in this spec gives the owner remote control of it.
- **Sealed** is not covered by today's lock rule (see C2). G1's check must add it before Guest ships.
- **Playback lock across devices** (two devices playing in step) is out of scope here; see the claims table in
  `FEAT-21-23-open-questions.md` and lane sync-spec.
