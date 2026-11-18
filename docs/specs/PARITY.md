# Parity map: where each feature lives
One row per feature. Shared = the one source; the rest are glue. Gaps = an embodiment that lacks it (file it in triage).

| Feature | Shared source | Mac | iPhone + iPad | Web | Gaps |
|---|---|---|---|---|---|
| Speech / live captions | `shared/speechcore.swift` | `strip/appear.swift` (LiveEar) | `mobile/ios/Broadcast/SampleHandler.swift` | — | "Show words sooner" Mac only (T-0004) |
| Draftpad editor | `editor/src/` | `strip/editorhost.swift` | `mobile/HostApp/iOS/Draftpad.swift` | — | Enter key on iOS (T-0001) |
| Draftpad page bar + slots (UI-06) | `editor/src/pagemode.js`, `index.js` | dist only (editor reopens on first text) | `Draftpad.swift` calls `reopen()` | — | device checks owed (Mac, iPhone, iPad) |
| Draftpad file sync | `shared/notesync.swift` (rules), `shared/draftpadfile.swift` (`DraftpadNote`, `DraftpadInk`: load and save, BUG-29) | `strip/app.swift` load/saveNow, `strip/editorhost.swift` ink | `Draftpad.swift` `DraftpadFile` | — | the Mac has no live ink poll (iPad strokes show on the next Mac post or reopen); `saveEvents` still two copies (BUG-29); matter sidecar reads unreadable as nil (`MatterWrite.plan`) |
| Transcript view + light | `shared/ShowsKit/` | strip | mobile | `library/src/client/gallery.js` | web light is a separate JS copy |
| Caption painter: Learn, Follow, floating window (FEAT-05) | `shared/ShowsKit/` (`CaptionPainter`, planned) | `strip/recense.swift` `WordsView` + `Cadence` (second copy) | `Listen.swift` `TranscriptLight` + `FloatingCaption` (third copy) | `gallery.js` light; `learn.js` phrase rules twin `phrases()` | three copies until FEAT-05 P1–P3; floating window plain white on iOS (T-0031) |
| Headphone route, seats, two at once | `shared/bosebridge.swift` | `strip/bosebridge.swift` (menu + CoreAudio) | `mobile/HostApp/iOS/Headphones.swift` | — | battery level is Mac-only (no iOS API); live audio from another device is FEAT-15 P6 |
| Home bar, rooms, prosody | `library/src/client/` | copied by `strip/build.sh` | — | Gallery | iOS? (check) |
| Search pill + time ruler + speed/loop (FEAT-07, FEAT-16 P5) | ShowsKit `SearchPill.swift` + `Scrubber.swift` (Swift) and `library/src/client/homebar.js` (JS): twins | ShowsKit (NSHostingView) + `strip/homebar/index.html` | ShowsKit | `homebar.js` | two implementations; one-source decision with the coordinator (2026-11-16) |
