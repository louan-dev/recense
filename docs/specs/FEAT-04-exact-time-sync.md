# FEAT-04 · Exact time sync for stored transcripts

From: owner 2026-11-12 ("allowing exact time synchronization.", forwarded by chauphan-88) · Status: `[~]` P1+P2 built (coordinator chauphan-97, 11-12); P3 parked until the aligner is handed over

Goal: when Recense hears content it already has a transcript for, each word lights on the sound's own clock,
not after it is heard. The transcript is found and the place is kept by an acoustic fingerprint (hashes only, never audio).

## Built `[x]`
- `shared/fingerprint.swift` (`Fingerprint.phased`, `locateLive`, `encode`/`decode`) and `shared/CaptionSeek.swift`
  (`refTime`, `wordIndex`). Tested, called by nothing on iOS (chauphan-88, 2026-11-12).
- iOS stores per-word times (`mobile/HostApp/iOS/Listen.swift:25`), but in seconds since 1970, not seconds into the recording.

## Holes (verified 2026-11-12 in main 4265a7c unless marked)
1. No App Group: `mobile/ios/App.entitlements` and `Ext.entitlements` share only a Keychain group. The broadcast
   extension can't read stored transcripts.
2. Corrected 11-12: Listen episodes were already local first (`library/Listen/<key>.json`, background fetch). The gap was the
   unsent-upload queue, in memory only; P2 keeps it across launches. Transcripts never fetched stay P4.
3. Two clocks: Mac `keep/<key>/asr.v2.json` words are offsets into the recording; iOS words are wall-clock.
4. Bulk preload: rclone gets 403 on `recense-tmp` (chauphan-88, not re-checked).
- Blocker: the aligner fails availability (93% nil at 10 dB SNR, 100% nil at 1.02x speed or faster;
  `.handoff/shows/HANDOFF.md`). Its fix lives as 451 uncommitted lines in the shows worktree.

## Planned `[ ]`
- P1 One clock: every stored word carries seconds into the recording, in one word type. Today there are two with the
  same fields: `Word` (`shared/transcript.swift:13`) and `TranscriptWord` (ShowsKit `Transcript.swift:12`); fold to one (PLAYBOOK §2.4). iOS writes `word time − episode start`;
  old wall-clock files migrate on read. Check: a unit test reads both formats to the same offsets.
- P2 Local first: Listen reads `library/Listen/<key>.json` and a `<key>.fp` fingerprint sidecar before any fetch;
  fetch is catch-up only. Check: opens a stored transcript in Airplane Mode.
- P3 Match in the app: the extension sends fingerprint words of the last ~15 s every 2-3 s over the Keychain item
  plus a Darwin notification; the app runs `CaptionSeek.refTime`, locks after two calls agree within 0.1 s,
  and re-matches to follow pause, seek and ads. Check: a harness plays a stored song from offset X and the lock
  lands within 50 ms; then the device through iPhone Mirroring.
- P4 Preload: Mac to iPhone over FEAT-02 (P2P); the Worker only as catch-up.

## Outside services
- Gallery Worker (`/main/api/listen`): catch-up only after P2. Never needed at the moment of use.
- R2: holds the Mac's transcripts; reached only through catch-up or P2P from the Mac.

## Open (coordinator)
- Who owns `shared/fingerprint.swift` round 3 and the availability fix.
- Whether this lane may edit `Listen.swift` (listen lane a62f8a72).
