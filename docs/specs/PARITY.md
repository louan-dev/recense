# Parity map: where each feature lives
One row per feature. Shared = the one source; the rest are glue. Gaps = an embodiment that lacks it (file it in triage).

| Feature | Shared source | Mac | iPhone + iPad | Web | Gaps |
|---|---|---|---|---|---|
| Speech / live captions | `shared/speechcore.swift` | `strip/appear.swift` (LiveEar) | `mobile/ios/Broadcast/SampleHandler.swift` | — | "Show words sooner" Mac only (T-0004) |
| Draftpad editor | `editor/src/` | `strip/editorhost.swift` | `mobile/HostApp/iOS/Draftpad.swift` | — | Enter key on iOS (T-0001) |
| Draftpad page bar + slots (UI-06) | `editor/src/pagemode.js`, `index.js` | dist only (editor reopens on first text) | `Draftpad.swift` calls `reopen()` | — | device checks owed (Mac, iPhone, iPad) |
| Draftpad file sync | `shared/notesync.swift` | strip | mobile | — | Mac load/save not on `readNote`/`planBlindSave` yet (T-0124); ink sidecar on both (T-0125) |
| Transcript view + light | `shared/ShowsKit/` | strip | mobile | `library/src/client/gallery.js` | web light is a separate JS copy |
| Headphone route, seats, two at once | `shared/bosebridge.swift` | `strip/bosebridge.swift` (menu + CoreAudio) | `mobile/HostApp/iOS/Headphones.swift` | — | battery level is Mac-only (no iOS API); live audio from another device is FEAT-15 P6 |
| Home bar, rooms, prosody | `library/src/client/` | copied by `strip/build.sh` | — | Gallery | iOS? (check) |
