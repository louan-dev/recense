# Parity map: where each feature lives
One row per feature. Shared = the one source; the rest are glue. Gaps = an embodiment that lacks it (file it in triage).

| Feature | Shared source | Mac | iPhone + iPad | Web | Gaps |
|---|---|---|---|---|---|
| Languages: list, Follow in, Heard in (FEAT-10 amendment) | Swift `shared/ShowsKit/.../Langs.swift`; browser `Homebar.LANGS` (`library/src/client/homebar.js`); editor `editor/src/langs.js`; Worker `library/src/layout.js` | ShowsKit menu (stored); `NativeLang`, `speech.swift` read `Langs` | ShowsKit menu + `Translate.swift`, `Shows.swift` (Heard in = Listen's Hear in) | `gallery.js` reads `Homebar.LANGS` | T-0178: `speechcore.swift` + `inkocr.swift` keep own lists (Broadcast has no ShowsKit; Vision codes); Listen "Show in" is a second Follow in; Draftpad "Translate into: Auto"; Mac translates nothing yet (Phase 3) |
| Speech / live captions | `shared/speechcore.swift` | `strip/appear.swift` (LiveEar) | `mobile/ios/Broadcast/SampleHandler.swift` | — | "Show words sooner" Mac only (T-0004) |
| Draftpad editor | `editor/src/` | `strip/editorhost.swift` | `mobile/HostApp/iOS/Draftpad.swift` | — | Enter key on iOS (T-0001) |
| Draftpad page bar + slots (UI-06) | `editor/src/pagemode.js`, `index.js` | dist only (editor reopens on first text) | `Draftpad.swift` calls `reopen()` | — | device checks owed (Mac, iPhone, iPad) |
| Draftpad file sync | `shared/notesync.swift` (rules), `shared/draftpadfile.swift` (`DraftpadNote`, `DraftpadInk`: load and save, BUG-29) | `strip/app.swift` load/saveNow, `strip/editorhost.swift` ink | `Draftpad.swift` `DraftpadFile` | — | the Mac has no live ink poll (iPad strokes show on the next Mac post or reopen); `saveEvents` still two copies (BUG-29); iOS `loadMatter` still reads an unreadable sidecar as "" (its first post then merges, T-0176) |
| Transcript view + light | `shared/ShowsKit/` | strip | mobile | `library/src/client/gallery.js` | web light is a separate JS copy |
| Caption painter: Learn, Follow, floating window (FEAT-05) | `shared/ShowsKit/` (`CaptionPainter`; `FloatingFrames` for the iOS window, BUG-24 P1b) | `strip/recense.swift` `WordsView` + `Cadence` (second copy) | the floating window uses the shared painter (`FloatingCaption.swift` is glue, 11-18); in-app Learn/Follow not yet | `gallery.js` light; `learn.js` phrase rules twin `phrases()` | Mac painter is a second copy until FEAT-05 P2; iOS in-app modes until P3 (T-0031's window part done 11-18) |
| Headphone route, seats, two at once | `shared/bosebridge.swift` | `strip/bosebridge.swift` (menu + CoreAudio) | `mobile/HostApp/iOS/Headphones.swift` | — | battery level is Mac-only (no iOS API); live audio from another device is FEAT-15 P6 |
| Home bar, rooms, prosody | `library/src/client/` | copied by `strip/build.sh` | — | Gallery | iOS? (check) |
| Search pill + time ruler + speed/loop (FEAT-07, FEAT-16 P5) | ShowsKit `SearchPill.swift` + `Scrubber.swift` (Swift) and `library/src/client/homebar.js` (JS): twins | ShowsKit (NSHostingView) + `strip/homebar/index.html` | ShowsKit | `homebar.js` | two implementations; one-source decision with the coordinator (2026-11-16) |

## Registry (read by `triage-merge.zsh checks|sweep <feature>` and by `/parity`; PLAN-1118 §11b)
One block per feature, between the two marker lines. A lane adds its block when it touches the feature; no big bang.
Keys (one per line, `key: value`):
- `home:` space-separated paths (a folder ends in `/`; a `*` glob is allowed) where the logic lives. Code anywhere else is glue.
- `note:` free text.
- `symbols:` names defined only in the home; `sweep` reports a definition of one outside it as a second copy.
- `embodiments:` `mac= iphone= ipad= web=`; `[ ]` not done, `[x]` built and device-checked, `n/a` not applicable.
- `events:` debug-channel events (`shared/ShowsKit/.../DebugChannel.swift`, `library/src/client/debuglog.js`) → `~/Recense/logs/<feature>.jsonl`.
- `spec:` the specs that govern it.
- `check:` repeatable. `[lock] <dir> :: <command>`. `lock` = takes the BUILD LOCK (a Swift or Xcode build, Playwright). `$ROOT` is the checkout, `$TMPDIR` scratch.
- `device:` repeatable; a check only a person on a device can do. `checks` prints these as "Not checked".

<!-- parity:begin narration -->
feature: narration
home: shared/voice/
symbols: bestVoice
embodiments: mac=[ ] iphone=[ ] ipad=[ ] web=n/a
events: narration.render narration.phrase narration.error
spec: FEAT-01 FEAT-35
check: . :: python3 -I text/test_rules.py
device: Wi-Fi off, play a narrated page on iPhone through iPhone Mirroring, screen-recorded
<!-- parity:end -->

<!-- parity:begin m4b -->
feature: m4b
home: shared/m4b/ shared/exportjobs.swift
note: shared/m4b/ (ChapterPlan, M4BWriter, one serial queue) is the home; exportjobs.swift stays until it lands
symbols: ChapterPlan M4BWriter ExportJobs ExportGate
embodiments: mac=[ ] iphone=[ ] ipad=[ ] web=[ ]
events: m4b.plan m4b.encode m4b.done m4b.error
spec: FEAT-01 BUG-33
check: lock . :: zsh mobile/ios/Tests/partsresume/run.zsh
check: lock strip :: zsh build.sh && ./recense selftest exportjobs downloads
device: BUG-33 device check; ffprobe shows chapters and a language tag; plays offline on iPhone
<!-- parity:end -->

<!-- parity:begin draftpad -->
feature: draftpad
home: editor/src/ shared/draftpadfile.swift shared/notesync.swift
note: editor/src/ is the editor; the two Swift files are the file and sync rules
symbols: DraftpadNote DraftpadInk
embodiments: mac=[ ] iphone=[ ] ipad=[ ] web=n/a
events: draftpad.load draftpad.save draftpad.merge draftpad.conflict
spec: FEAT-08 FEAT-23 UI-06 BUG-29
check: editor :: npm test
check: lock . :: swiftc -O shared/notesync.swift shared/draftpadfile.swift mobile/ios/Tests/draftpadfile/main.swift -o "$TMPDIR/draftpadfile" && "$TMPDIR/draftpadfile"
check: lock . :: swiftc -O shared/notesync.swift mobile/ios/Tests/notesave/main.swift -o "$TMPDIR/notesave" && "$TMPDIR/notesave"
device: a timestamped canary line, Mac to iPhone and back
<!-- parity:end -->

<!-- parity:begin notes -->
feature: notes
home: shared/notesync.swift
note: the rules; the data is `keep/<key>/note.md` per media item (FEAT-23)
symbols: NoteRead BlindSave Unsaved NoteSave
embodiments: mac=[ ] iphone=[ ] ipad=[ ] web=[ ]
events: notes.load notes.save notes.link notes.unlinked
spec: FEAT-23 FEAT-22 T-0114
check: lock . :: swiftc -O shared/notesync.swift mobile/ios/Tests/notesave/main.swift -o "$TMPDIR/notesave" && "$TMPDIR/notesave"
device: a moment link made on one device opens at that second on another
<!-- parity:end -->

<!-- parity:begin carry -->
feature: carry
home: shared/carry*.swift
note: carrysync, carryapply, carrymanager, carrypair, carryauth
symbols: CarrySync CarryManager CarryPairSession CarryAuthMessage
embodiments: mac=[ ] iphone=[ ] ipad=[ ] web=n/a
events: carry.pair carry.send carry.apply carry.conflict carry.error
spec: FEAT-09 FEAT-22 SEC-02
check: lock . :: swiftc -O shared/notesync.swift shared/carrysync.swift mobile/ios/Tests/carrysync/main.swift -o "$TMPDIR/carrysync" && "$TMPDIR/carrysync"
device: pair once, change a file on each device, both converge; Wi-Fi off, edit, Wi-Fi on, catches up
<!-- parity:end -->

<!-- parity:begin home -->
feature: home
home: editor/src/
symbols: weave
note: UI-13 woven Home (editor/src/weave.js, planned) and FEAT-07 haptic zoning (ShowsKit HapticZones, planned)
embodiments: mac=[ ] iphone=[ ] ipad=[ ] web=n/a
events: home.open home.weave home.anchor home.todo home.pip haptic.zone haptic.fire
spec: UI-13 FEAT-07 FEAT-23
check: editor :: npm test
check: lock shared/ShowsKit :: swift test
device: iPhone and iPad, Wi-Fi off, screen-recorded: Home shows what plays; typing at 3:10 anchors at 3:10; PiP floats on leaving the app
<!-- parity:end -->

<!-- parity:begin vault -->
feature: vault
home: shared/vault/
symbols: Vault
note: SEC-03 password manager; nothing built until the threat model is reviewed. The check below is the generic carry test; the vault-specific check arrives with P2
embodiments: mac=[ ] iphone=[ ] ipad=[ ] web=n/a
events: vault.open vault.lock vault.sync vault.conflict vault.error
spec: SEC-03 SEC-02
check: lock . :: swiftc -O shared/notesync.swift shared/carrysync.swift mobile/ios/Tests/carrysync/main.swift -o "$TMPDIR/carrysync" && "$TMPDIR/carrysync"
device: P0: the same entry opens on Mac and iPhone; change on each, carry, both converge
<!-- parity:end -->
