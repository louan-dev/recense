# Genetic Map

Where the same logic lives more than once in Recense, and what to do about it.
Snapshot: commit `8f9b3dd` (2026-11-19). Written 2026-11-20 under `docs/law/treaty.md` (Articles 3 to 5).
Every `path:start-end` below was read by an agent. Re-check them with the command at the end.

Proof labels:
- **read**: an agent read those lines.
- **ran**: a command ran and gave that result.
- **inferred**: follows from lines read, not run.
- **untested**: no evidence yet; the command to get it is named.
- **owner-stated**: from the owner, no file yet.

## 1 · Words used here

- **Genotype**: logic that must exist once. Lives in `shared/`, `editor/src/`, or `library/src/client/`.
- **Phenotype**: glue that binds the genotype to one OS or screen. Stays in `strip/`, `mobile/`, `library/src/`.
- **Embodiment**: one feature on one surface (Mac, iPhone, iPad, web). Embodiments share logic.
- **Twin**: a second copy of logic.
- **Locus**: one place a twin lives (file plus line range).
- **Cure**: the change that fixes a bug. A cure goes to every locus of the same genotype.

Tags used for every finding:
- `EXACT TWIN`: byte-identical or generated copy. Cure all together.
- `DRIFTED TWIN → collapse into shared/`: same language (Swift with Swift, JS with JS). A bug by `.claude/CLAUDE.md:28`.
- `DRIFTED TWIN → keep, add vector test`: across languages (Swift with JS). Allowed only with a guard test.
- `INTENTIONAL PHENOTYPE`: legitimate glue or a Mac-only feature.

Counted result: **zero byte-identical pairs** among tracked sources (sha256 sweep, **ran**, 2026-11-19).
Near-exact: `strip/bridge/room.js` (2 comment lines differ) and `strip/bridge/player-key.js` (1 line against 3).

## 2 · Lineage

### The one repo
- 2026-10-10 first commit. 2026-11-03 renamed Sill to Recense. 2026-11-05 cut over to one repo (`.claude/CLAUDE.md`, local file).
- Surfaces today:
  - Mac: `strip/` (Recense.app).
  - iPhone and iPad: `mobile/`. **One** shared file, `mobile/HostApp/iOS/Draftpad.swift`, serves both.
  - Web: `library/` (Gallery Worker and client), `editor/` (Draftpad, CodeMirror 6, one bundle).
  - Shared Swift: `shared/` (and the ShowsKit package inside it).
  - Mac jobs: `sync/`. Not app sync.
- `strip/Sources/recense/` holds 52 entries and all are symlinks (**ran**: no regular file). 31 point into `shared/`, 19 into `strip/`.

### Draftpad
- Ancestor: `reference/draftpad/draftpad.swift` (596 lines). `strip/app.swift:4-5` says the Mac app was built on it. Not a twin: 817 diff lines against the iOS file (**ran**, subagent).
- Now: editor JS in `editor/src/`, bundled to `editor/dist/editor.html`, hosted by two Swift files (cluster C1).

### Siblings
- **auditor** (`~/Developer/auditor`, 4.1 MB, no git). Patent-bar study auditor for DEVONthink and Claude (`pyproject.toml`, README).
  - Lineage named by the owner (**owner-stated**): cloud indexing, ask engine, DEVONthink, offlinehub, PLIv1, Practising Law Institute bar-prep material.
  - File evidence found (**read**):
    - ask engine: `docs/PROGRESS.md:746`, `docs/specs/unified-offline-first-and-redesign.md:29-33`, `docs/specs/unified-offline-first-and-redesign.md:1004`, `docs/specs/FEAT-32-recense-a-source.md:3`.
    - DEVONthink: the same spec (line 33) and `~/Developer/auditor/pyproject.toml`.
    - PLIv1: `docs/PROGRESS.md:1075` and `docs/PROGRESS.md:1088` (211 files held in R2 under `gallery-main/files/PLIv1`).
  - No file evidence yet for "cloud indexing" and "offlinehub". `offlinehub` may be the `hub/` folder (**inferred**, one name, no document says so).
  - `docs/specs/unified-offline-first-and-redesign.md:870` lists it as "outside the merge: not git".
- **blur** (`~/Developer/blur`, 80 KB, no git, created 2026-11-19). Two tools: `break` and `pomo`.
  - Lineage named by the owner (**owner-stated**): the Draftpad layer.
  - Proven ancestry for `pomo`: `reference/pomo/breakscreen.swift` (3,612 bytes) became `blur/pomo/src/breakscreen.swift` (136 lines). File names and sizes only; contents not diffed (**untested**).
- Neither sibling has version control. Law 1 for siblings is a twin notice plus a proposed patch, never a silent edit.

## 3 · Genotype and phenotype, by feature

Canonical (one copy; the rest is glue):
- Draftpad editor: `editor/src/` (genotype). Hosts are phenotype.
- Draftpad file rules: `shared/notesync.swift`, `shared/draftpadfile.swift`.
- Word timing, Swift: `shared/ShowsKit/Sources/ShowsKit/Cadence/Cadence.swift`, `.../CadenceAlign.swift`.
- Prosody: `library/src/client/prosody.js` (single implementation). `strip/prosody.swift` hosts it in a hidden web view (`docs/architecture.md:283-286`).
- Player: `library/src/client/` (copied into the Mac app by `strip/build.sh:37-43`).
- Homes and trash: `shared/homes.swift`.
- Speech engine: `shared/speechcore.swift` with Mac glue in `strip/speech.swift`. Layering, not twins (1,053 diff lines, **ran**).
- Bose bridge: `shared/bosebridge.swift` with Mac glue in `strip/bosebridge.swift` (691 diff lines, layering).

## 4 · Twin clusters, ranked

Each cluster names its PARITY block (`docs/specs/PARITY.md`). Blocks are added by the lane that touches the feature, so this map only proposes keys.

### C1 · Draftpad host bridge (Mac against iOS) · HIGH
- Loci:
  - `strip/editorhost.swift:336-545` (message handler, `saveEvents` at 480-516)
  - `mobile/HostApp/iOS/Draftpad.swift:219-345` (handler, `saveEvents` at 334-368)
- Both register the same nine handlers: `editor, link, ui, ink, matter, note, audio, calendar, wings` (`strip/editorhost.swift:177`, `mobile/HostApp/iOS/Draftpad.swift:158`). **read**
- Copies, line for line **read**:
  - `pageDate`: `strip/editorhost.swift:473-476` and `mobile/HostApp/iOS/Draftpad.swift:327-330` (same body).
  - `saveEvents`: the two ranges above (same flow, same strings but one).
  - `speak`: `strip/editorhost.swift:542-547` and `mobile/HostApp/iOS/Draftpad.swift:395-400` (same body).
  - `persistSyncedEventIds` and `reloadSyncedEventIds`: `strip/editorhost.swift:524-534` and `mobile/HostApp/iOS/Draftpad.swift:376-387`.
- Proof by the registry's own tool (**ran**, 2026-11-20, on a scratch copy of the registry with `symbols: saveEvents pageDate` added): `triage-merge.zsh sweep draftpad` reports second copies at `strip/editorhost.swift:480`, `mobile/HostApp/iOS/Draftpad.swift:334`, `strip/editorhost.swift:473` and `mobile/HostApp/iOS/Draftpad.swift:327`, plus a third `pageDate`, a free function at `strip/editorhost.swift:32` (it takes a page string, not an ISO string). The real block (`docs/specs/PARITY.md:66-77`) lists only `symbols: DraftpadNote DraftpadInk`, so today the sweep prints "clean" while the twins exist.
- Drift **read**:
  - Mac asks `requestFullAccessToEvents` (`strip/editorhost.swift:481`). iOS asks `requestWriteOnlyAccessToEvents` (`mobile/HostApp/iOS/Draftpad.swift:335`).
  - Mac reloads the saved ids at the start of `saveEvents` (`strip/editorhost.swift:484`) and calls `onEventsSaved` (`:509`). iOS does neither inside `saveEvents`.
  - Error text differs: "System Settings" on the Mac (`:488`), "Settings" on iOS (`:341`).
  - `trashFallback: Homes.url(.trash)` is passed only on iOS (`mobile/HostApp/iOS/Draftpad.swift:276`); the Mac passes none (`strip/editorhost.swift:403`).
- Tag: `DRIFTED TWIN → collapse into shared/` (Swift with Swift). `docs/specs/PARITY.md:10` (Draftpad file sync row) already admits "saveEvents still two copies (BUG-29)".
- Note: iPhone and iPad are already one file. The split is Mac against iOS.
- Page marker twin: `strip/app.swift:75-100` (`pageMarker`, `parsePages`) against `editor/src/pages.js:4` and `editor/src/pages.js:119-122`. Cross-language. `shared/draftpadlibrary.swift:38` hard-codes the separator. `DRIFTED TWIN → keep, add vector test`. **inferred** (agent read; vector test absent).
- PARITY block: exists, `draftpad` (`docs/specs/PARITY.md:66-77`). Propose adding `symbols: saveEvents pageDate speak` after the collapse.

### C2 · Editor bundle (one build, several copies) · HIGH
- Genotype: `editor/dist/editor.html` (1,706,357 bytes). Mac copies it at build time (`strip/build.sh:47-48`). iOS bundles it (`mobile/ios/GalleryFiles.xcodeproj/project.pbxproj`, lines 42-43, per an earlier agent; not re-read) and loads it at `mobile/HostApp/iOS/Draftpad.swift:171-172`.
- Hub copy: `editor/dist/pwa/index.html` (1,713,363 bytes).
- Hand copy: `library/src/client/editorpwa/index.html` (1,691,555 bytes). `cmp -s` says **all three differ** (**ran**). `sw.js` differs between `editor/dist/pwa` and `library/src/client/editorpwa`. `manifest.webmanifest` and `icon.svg` match.
- Guard: `library/test/editorpwa.test.mjs:14-19` asserts byte identity of four files. By the `cmp` result it **should fail now**; not run (**untested**; running it writes files).
- Tag: `EXACT TWIN` by design, currently stale. Cure: rebuild `editor/` and recopy.
- Language twin inside the bundle: `editor/src/matter.js:94-109` (`guessLang`) is copied into `library/src/client/editorpwa/index.html`. Generated, so it follows the cure above.

### C3 · Word timing, Cadence (Swift with JS) · HIGH
- Loci:
  - `library/src/client/cadence.js:1-6` (565 lines)
  - `shared/ShowsKit/Sources/ShowsKit/Cadence/Cadence.swift:123`
  - `shared/ShowsKit/Sources/ShowsKit/Cadence/CadenceAlign.swift:4`
- Both say "rule for rule … change one, change the other". **read**
- Guard: fixture `shared/ShowsKit/Tests/ShowsKitTests/Fixtures/songlight.json`, written by `library/test/songlight.test.mjs:16-47` and read by the Swift test. It pins one song's `fit` and `pin`. Whether `syllables` and `align` are covered: **untested** (`grep -n "fit\|align\|syllab" library/test/songlight.test.mjs library/test/cadence.test.mjs`).
- Stale pointer: `library/src/client/cadence.js:2` names `recense/recense/recense.swift`, which no longer exists.
- The Mac now calls the ShowsKit `Cadence` (`strip/recense.swift:16` imports ShowsKit; no second `enum Cadence` in `strip/recense.swift`, **ran**). `docs/specs/PARITY.md` still says "`WordsView` + `Cadence` (second copy)". **Probably stale; untested.**
- Web light: `library/src/client/gallery.js` is a separate JS copy (`docs/specs/PARITY.md:11`).
- No code constant implements any sync tolerance. "25 ms lock" is recorded as untested in `docs/specs/FEAT-07-search-pill-haptic-ruler.md:241`. The specs now say 30 ms target, 40 ms blocks (commit `8f9b3dd`).
- Tag: `DRIFTED TWIN → keep, add vector test` (guard exists for `fit`/`pin`).
- PARITY row: Transcript view + light (`docs/specs/PARITY.md:11`); no registry block yet. Proposed: `home: shared/ShowsKit/Sources/ShowsKit/Cadence/ library/src/client/cadence.js`.

### C4 · Home bar, scrubber, search pill (Swift with JS) · MEDIUM
- Loci:
  - `shared/ShowsKit/Sources/ShowsKit/Views/Scrubber.swift` (153 lines)
  - `shared/ShowsKit/Sources/ShowsKit/Views/SearchPill.swift` (78 lines)
  - `library/src/client/homebar.js:222-228` (3,627 lines; says "rule for rule")
  - `library/src/client/homebar.css` (2,063 lines)
  - `strip/homebar/index.html` (482 lines; Mac host page)
- `docs/specs/PARITY.md:15` says: "two implementations; one-source decision pending".
- Tag: `DRIFTED TWIN → keep, add vector test`. No guard found.
- PARITY block: exists as a table row (`docs/specs/PARITY.md:15`); no registry block yet.

### C5 · ContentKey and keep/ layouts · HIGH
- ContentKey loci **read** (subagent):
  - `shared/ShowsKit/Sources/ShowsKit/Model.swift:16-60`
  - `strip/recense.swift:2755-2802` (`cacheKey`, `enum ContentKey`)
  - `library/src/transcript.js:43-64`
  - vectors `shared/ShowsKit/Tests/ShowsKitTests/ContractTests.swift:9-25`
- All three hash `fp:<size>:<head sha256>:<tail sha256>`, first 24 hex, span 65,536. A Node reimplementation gave the two literals in `ContractTests.swift:13,20` (**ran**). The Mac enum was not run (**untested**: `cd shared/ShowsKit && swift test --filter ContractTests`).
- Drift:
  - `strip/recense.swift:2784-2792` and `shared/ShowsKit/Sources/ShowsKit/Model.swift:39-48` are copy-pasted `ofFile` bodies. Tag: `DRIFTED TWIN → collapse into shared/`. The Mac already imports ShowsKit (`strip/recense.swift:16`).
  - Legacy key on "?": JS hashes the whole string (`library/src/transcript.js:44-46`); Swift cuts at "?" (`strip/recense.swift:2756`). A file named `a?b.mp3` would get different legacy keys. Node side **ran**; Swift side **untested**.
  - Fallback to the legacy key: `strip/recense.swift:2799-2802` and `:6329-6337`.
  - `writeLinesFile` says "a content key, never an address key" (`strip/recense.swift:3529-3543`), but its pattern `^[0-9a-f]{24}$` also matches a legacy key. iOS reads under the content key only (`mobile/HostApp/iOS/Ears.swift:23-31`), so a legacy item's `lines.json` is never found.
- JS side tag: `DRIFTED TWIN → keep, add vector test`. The JS tests use their own copies (`library/test/transcript.test.mjs:155-161`, `library/test/ui.test.mjs:176-181`), not the pinned literals.
- Listen key, three identical Swift expressions: `strip/handoff.swift:28-31`, `shared/bosebridge.swift:235-238`, `mobile/HostApp/iOS/Listen.swift:60-63`. Tag: `DRIFTED TWIN → collapse into shared/`. JS twin: `library/src/listen.js:19-23`. Whitespace sets differ (`\s` includes U+FEFF; Swift `isWhitespace` does not). No shared vector.
- Layouts under keep/ (three on disk):
  - R2 per item: `library/src/layout.js:1-60`, mirrored in `strip/recense.swift:5417-5442`.
  - Mac flat files: `strip/keephome.swift:1-60` (`<key>.v2.json` and siblings).
  - Phone and carry: `shared/carrysync.swift:291-317` (only `note.md` and `lines.json` travel), `shared/medianotefiles.swift:1-226`, `mobile/HostApp/iOS/Draftpad.swift:115-135`.
  - `keep/listen/` has two layouts: `shared/ShowsKit/Sources/ShowsKit/Model.swift:197-209` (per device) against `library/src/listen.js:1-70` and `strip/handoff.swift:3-4` (by title hash).
- Blind overwrite of `note.md`: none found. `shared/medianotefiles.swift:46-65` writes a conflict sibling on mismatch. Caveat: `append` (`:202-210`) is read-modify-write without a base check; `ink` and `matter` (`:194-201`) overwrite but do not travel.
- PARITY blocks: `notes` and `carry` exist (`docs/specs/PARITY.md:80-91`, `docs/specs/PARITY.md:92-103`). Propose `symbols: ContentKey listenKey` on a new `contentkey` block.

### C6 · Language handling, en/fr/vi · HIGH
- Four detectors, four answers **read**:
  - `editor/src/matter.js:94-109`: one Vietnamese letter makes the whole string `vi`; defaults to `en`. Guard is JS-only (`editor/test/bug-guesslang-vi-fr.test.mjs`).
  - `shared/translateplan.swift:9-26`: needs 3 words and p ≥ 0.6.
  - `shared/transcript.swift:98-143`: open-set, no word minimum, `prefix(2)` turns "yue" into "yu".
  - `shared/speechcore.swift:88-102`: constrained list; below 3 words a neutral 0.5.
- Five lists, same set, different order and names **read**:
  - `editor/src/langs.js:5-6` (en fr vi)
  - `shared/ShowsKit/Sources/ShowsKit/Langs.swift:7-22` (en fr vi, endonyms)
  - `shared/speechcore.swift:77-86` (duplicates `Langs.locale`) → `DRIFTED TWIN → collapse into shared/`
  - `library/src/layout.js:23` (en vi fr)
  - `library/src/client/homebar.js:107-113` (vi en fr)
  - JS with JS: `DRIFTED TWIN → collapse into shared/`. Swift with JS: `keep, add vector test`.
- Three-letter codes: the Mac emits `yue` and `kab` (`strip/openears.swift:297-304`); the Worker's `spokenOf` (`library/src/transcript.js:193-205`) turns them into `yu` and `ka` (Georgian). No vector.
- Language tags are dropped: `shared/transcript.swift` (`transcriptLine`, around line 168) and `mobile/HostApp/iOS/Ears.swift:130-135` rebuild `Word` without `lang`. iOS also picks one language per 120 s stretch (`shared/speechcore.swift:715-839`).
- Non-Latin is Mac-only **read**: `strip/speech.swift:253-344`, `strip/openears.swift:161-305`, `strip/canon.swift:1-60`, `strip/ears/omni.py:59-72`. iOS has none of it (`grep -rn "OpenEars|Tongue|Canon|scriptOf" mobile/` is empty). Tag: `INTENTIONAL PHENOTYPE` today. The Python script table against the Swift one: `keep, add vector test`.
- PARITY row: Languages (`docs/specs/PARITY.md:6`); no registry block yet. Propose `symbols: guessLang detectLanguage LANGS`.

### C7 · Trash, delete, restore · HIGH (data)
- Canonical: `shared/homes.swift:231-247` (`Homes.remove`), `:289-304` (restore), `:307-310` (`deleteForever`). Visible `trash/` folder with a `from:` tag.
- Swift paths that bypass it **read**:
  - `shared/destinations.swift:94-109`: dead twin (only caller is a test, `mobile/ios/Tests/destinations/main.swift:64`).
  - `shared/medianotefiles.swift:95-108`: iOS fallback writes no manifest and no `from:` tag; cannot be restored.
  - `mobile/HostApp/iOS/Listen.swift:459-474`: moves into `trash/` with no tag.
  - `shared/carryapply.swift:87-100` and `strip/keephome.swift:73-80`: two hidden set-aside sinks. No retention code for either.
  - `shared/ShowsKit/Sources/ShowsKit/Model.swift:113-117` writes `.trash`; `shared/homes.swift:15-30` writes `trash`. `shared/ShowsKit/Sources/ShowsKit/Model.swift:9` says "30 days"; `shared/homes.swift:6-7` says nothing is deleted unless the owner says so. No sweeper found.
  - Tag for all: `DRIFTED TWIN → collapse into shared/` (route through `Homes.remove`).
- Intentional: Mac `trashItem` calls for files outside the homes (`strip/app.swift:2812-2819`, `:7005`, `shared/mediadownload.swift:441`). All use `try?`, so a failure keeps the file.
- Worker JS **read**: `library/src/main.js:908-930`, `library/src/dav.js:333-355`, `library/src/fp.js:237-257`. Four code sites build trash keys with two stamp formats (`library/src/main.js:917`, `:930`, `library/src/dav.js:342`, `library/src/fp.js:254`). Tag: `DRIFTED TWIN → collapse into shared/` (one JS helper).
- Exact twin: `GUARD` and `massDelete` in `sync/src/ledger.mjs:84-90` and `library/src/fp.js:64-65`. JS with JS. Tag: `EXACT TWIN`. Swift has no equivalent guard.
- **Data-loss risks (not fixed here; filed for owner lanes):**
  - `mobile/HostApp/iOS/Listen.swift:544-545` permanently deletes an episode's heard sentences. The swipe at `:1456` has no confirmation. Automatic deletes at `:493`, `:524`, `:719`.
  - `strip/app.swift:6252-6260` removes `<base> (N MB).<ext>` on every attempt with no existence check.
  - `library/src/main.js:922-924` drops the comment and share-key mapping when a file is trashed; neither comes back with the file.
  - No caller of restore or `deleteForever` outside the self-test (`shared/homes.swift:479-497`). **inferred**; search command in section 7.
- PARITY block: none (the existing `home` block, `docs/specs/PARITY.md:104-115`, covers `editor/src/`, not trash). Propose a `trash` block: `home: shared/homes.swift`, `symbols: remove restore deleteForever freeName`.

### C8 · Small near-exact copies (JS with JS) · LOW
- `strip/bridge/player-key.js:929` against `library/src/client/player-key.js:929-931`: the strip copy lacks `ctx`. Stale. Tag: `DRIFTED TWIN → collapse into shared/`.
- `strip/bridge/room.js` against `library/src/client/room.js`: lines 1-2 (comments) differ. Tag: `EXACT TWIN` in code.
- Both strip copies are tracked; neither is covered by `HB_MODULES` (`strip/build.sh:37-43`). No test (`strip/bridge/test` holds only `ads.test.mjs`).
- Not twins: `homebar.js homebar.css keylabel.js room.js prosody.js prosogram.js` are copied at build time (`strip/build.sh:37-43`).

### C9 · Mac and iOS speech and Bose layers · LOW
- `strip/speech.swift` with `shared/speechcore.swift` (1,053 diff lines) and `strip/bosebridge.swift` with `shared/bosebridge.swift` (691). Layering: glue over a shared core. `INTENTIONAL PHENOTYPE`.

### H · Handedness (Treaty Article 12) · MEDIUM
Measured, 2026-11-20 (**ran**; occurrences, overlapping alternations, so approximate):
- CSS, physical against logical properties:
  - `editor/src/*.css`: 55 against 0 (all in `editor/src/styles.css`).
  - `library/src/client/*.css`: 166 against 6 (`homebar.css` 71/1, `gallery.css` 64/5, `sharedview.css` 21/0).
  - `strip/homebar/*.html`: 6 against 0.
  - Generated bundles excluded (`editor/dist`, `library/src/client/editorpwa/index.html`).
- Swift:
  - `mobile/HostApp`: 19 logical (`.leading/.trailing`); layout use of physical `left/right` on two lines (`mobile/HostApp/iOS/Draftpad.swift:569`, `:601`).
  - `shared/ShowsKit`: 29 logical; 2 physical (both `chevron.right` symbols).
  - `strip/*.swift`: 42 `leadingAnchor/trailingAnchor`, 0 `leftAnchor/rightAnchor`; 14 `NSTextAlignment` assignments.
  - `layoutDirection`, `semanticContentAttribute`: **0** in `mobile`, `shared`, `strip`.
- Side-placed controls **read**:
  - Mirrored: wings `editor/src/wings.js:529-571`, `:1825-1856`, `:2073-2095`; haptic zones `editor/src/gestures.js:36-47`; Pencil edge swipes both sides `mobile/HostApp/iOS/Draftpad.swift:569-577`, `:595-602`; Mac three-finger `strip/wingpanels.swift:26-34`.
  - One-sided: sound tray `.p-ctrl` is right-edge only (`library/src/client/gallery.css:558-565`, `strip/homebar/index.html:37-40`); the full-screen player close is top-leading only (`mobile/HostApp/iOS/Browser.swift:316-321`).
  - `swapWings` has no visible touch control; callers are voice and the host API (`editor/src/gestures.js:322-331`, `editor/src/index.js:1253`).
  - `mobile/HostApp/iOS/Draftpad.swift:241` says a wing button stays when edge swipes are off; none was found. With an ink tool selected, touch access to the wings is **untested**.
- Palm rejection assumes no writing hand (`editor/src/palm.js:15`); its constants are "assumed, not measured" (`editor/src/palm.js:3`).
- No handedness preference is stored or detected. Mirror tests exist for wings (`editor/test/p6-wings.test.mjs:425`, `:473`, `:761`); no test renders a right-to-left layout.
- The claim "ambidextrous" in `editor/src/wings.js:2` is partly borne out: the wings are symmetric; the sound tray and the player close are not.

## 5 · Canonical routing table

Where a new variable, token or helper goes. One target each.
- A date or ISO helper used by a host, and the calendar save (`pageDate`, `saveEvents`): `shared/` (Swift), one copy called by both hosts. The exact file is chosen by the lane that does the C1 collapse; no new file is made here.
- A page marker: `editor/src/pages.js`; Swift reads it from one constant in `shared/draftpadlibrary.swift`.
- A content key: `shared/ShowsKit/Sources/ShowsKit/Model.swift` (`ContentKey`). The Mac enum becomes a call.
- A language list, name or locale: `shared/ShowsKit/Sources/ShowsKit/Langs.swift`; JS reads a generated list.
- A language detector: one Swift function in `shared/`; the JS one stays with a vector test.
- A delete or set-aside: `shared/homes.swift` (`Homes.remove`).
- A trash key in the Worker: one helper in `library/src/`.
- A word-timing rule: `shared/ShowsKit/Sources/ShowsKit/Cadence/`, mirrored in `library/src/client/cadence.js` with a fixture.
- A control placed by side: both sides, or reachable from the other (Treaty Article 12).
- A layout property: logical (`start/end`, `.leading/.trailing`).
- Anything a Mac-only feature needs: `strip/`, and listed as `INTENTIONAL PHENOTYPE` here.

## 6 · Law 1 in one paragraph

On a bug report: find its genotype here. List every locus. If a twin builds today, patch it in the same commit and mark unchecked devices (`[ ]`, `device:`). If it cannot build, leave it, ship the rest, and record the gap in `docs/specs/PARITY.md` (Gaps) and as a `T-####`. Same-language twins: collapse into `shared/` rather than patching twice.

## 7 · Not yet known, and how to find out

- Swift `ContentKey` output: `cd shared/ShowsKit && swift test --filter ContractTests`.
- Worker `fingerprintKey` on real data: `cd library && node test/transcript.test.mjs`.
- Whether `editorpwa.test.mjs` fails: `cd library && node test/editorpwa.test.mjs` (writes files).
- Whether anything restores from trash: `grep -rnE 'restore\(|deleteForever' mobile strip shared --include='*.swift' | grep -v 'shared/homes.swift'`.
- Whether a wing button exists on iOS: `grep -rnE "wing" editor/src/index.js editor/src/pages.js editor/src/libraryui.js | grep -iE 'createElement|button'`.
- Cadence fixture coverage: `grep -n "fit\|align\|syllab" library/test/songlight.test.mjs library/test/cadence.test.mjs`.
- Worker trash expiry: `npx wrangler r2 bucket lifecycle list <bucket>` (needs the account).
- Which files compile into iOS: `grep -n "shared" mobile/ios/GalleryFiles.xcodeproj/project.pbxproj`.

## 8 · Check these citations

Run from the repo root. Prints `BAD` or `MISSING` for any cited `path:start-end` outside its file:

```
perl -ne 'while(/`([A-Za-z0-9_.\/@-]+\.[a-z]+):(\d+)(?:-(\d+))?`/g){print "$1 $2 ".($3//$2)."\n"}' docs/GENETIC-MAP.md | sort -u | while read p a b; do [ -f "$p" ] || { echo "MISSING $p"; continue; }; n=$(wc -l <"$p"); (( b>=a && b<=n )) || echo "BAD $p:$a-$b (file has $n lines)"; done
```

It checks that a range fits its file, not that the words match. Spot-check a few by hand.
`.claude/CLAUDE.md` is git-ignored, so it is `MISSING` inside a worktree; run the check in the main checkout.
