# BUG-05 · The old transcript stays when new media starts

From: T-0044 (owner, 2026-11-12: "the devices cannot discriminate between an old and new file, so the transcription
from an old doesnt clear when you start a new media") · Devices: iPhone, iPad, Mac · Status: `[ ]`

## What the owner sees
They switch to another video or song. The new words are appended under the old transcript instead of starting fresh.

## Red (what the code shows, 2026-11-12)
- iOS starts a new episode only when a broadcast starts (`fresh()`, `mobile/HostApp/iOS/Listen.swift:337`, `:515`) or after
  180 s with no new line (`:844`); `adoptIfResumed()` (`:711`) re-joins the last episode.
- Episodes are keyed by date and language, so two clips on the same day in the same language share one key.
- Nothing reads which media is playing. iOS gives no third-party app another app's now-playing item (assumed: no public API).
- Mac path: not yet checked (P3 below).

## Green (the fix)
1. **Recense's own player:** an item change starts a new episode at once (the player knows its item).
2. **Episode keys are a UUID**, not date + language.
3. **Other apps' sound (broadcast):** cut when
   - the sound locks onto a different stored item (fingerprint, FEAT-04), or
   - a sound gap ≥ 1.5 s is followed by a change of language or of voice.
4. **A visible "New" control** in the transcript's ··· menu and the voice command "new" (every action has a control).

## Guard invariant
Two different media played one after the other, within 3 minutes, never share an episode.

## Checks
1. Red test first: two clips 60 s apart, same language, same day → today they append (fails); after the fix, two episodes.
2. Own player: switching items in a test transport gives two episode UUIDs.
3. iPhone Mirroring: play video A, then B within a minute → B's transcript starts empty; screenshot.
4. Mac: the same two-clip check, `strip/recense selftest` line.

## Phases
- P1 own player + UUID keys (iOS, then Mac).
- P2 broadcast cut rules + "New" control.
- P3 Mac path diagnosed and fixed.
