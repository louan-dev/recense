# Parity map: where each feature lives
One row per feature. Shared = the one source; the rest are glue. Gaps = an embodiment that lacks it (file it in triage).

| Feature | Shared source | Mac | iPhone + iPad | Web | Gaps |
|---|---|---|---|---|---|
| Speech / live captions | `shared/speechcore.swift` | `strip/appear.swift` (LiveEar) | `mobile/ios/Broadcast/SampleHandler.swift` | — | "Show words sooner" Mac only (T-0004) |
| Draftpad editor | `editor/src/` | `strip/editorhost.swift` | `mobile/HostApp/iOS/Draftpad.swift` | — | Enter key on iOS (T-0001) |
| Draftpad file sync | `shared/notesync.swift` | strip | mobile | — | — |
| Transcript view + light | `shared/ShowsKit/` | strip | mobile | `library/src/client/gallery.js` | web light is a separate JS copy |
| Home bar, rooms, prosody | `library/src/client/` | copied by `strip/build.sh` | — | Gallery | iOS? (check) |
