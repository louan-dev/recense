# BUG-17 · Pairing finishes on the Mac only; the iPhone stays unpaired

From: T-0081 (owner, 2026-11-15: "doesnt work To pair, open Library › Devices › Pair a Device… on the iPhone") ·
Guards: FEAT-09 P1 · Device: iPhone 12 Pro Max (00008101-001A50643A98001E), iPad, Mac ·
Status: `[~]` (fixed, tests green; device check owed)

## What the owner sees
- iPhone › Library › Devices: "No paired devices yet." after pairing with the Mac.
- Carry Now stays disabled on the iPhone.

## Red (what the code and the devices show)
- Evidence on the Mac: `~/Recense/.carry/peers.json` lists "iPad" (04:38:10Z) and "iPhone" (04:39:03Z).
  The Keychain holds a group (`local.recense.carry` / `group`). So the Mac finished both pairings; the phones did not.
- Cause 1, the group was rejected. After "They match", one side seals the group secret and sends `.group`.
  The other side's `CarryManager.receivePair` first called `CarryPairSession.receive(.group)`.
  `receive` throws `outOfOrder` for `.group`, so the code never reached `finishPairing`.
  The sender had already saved the peer. Result: one-sided, every time.
  Reproduced without radios: `receive(offer.message)` throws `outOfOrder`.
- Cause 2, no recovery. Once the Mac lists the iPhone, `connected` skipped the exchange for a listed peer.
  The Mac's menu and the CLI also hid listed peers from the pick list. So re-pairing could not fix it.
- Cause 3, two groups. Neither side knew whether the other already held a group.
  With both taps in flight, the committer could make a new group while the other sent its own.
- Smaller, same flow:
  - "Stop Pairing" called `stop()`, which turned the link off until relaunch.
  - Each `start()` made a new advertiser and browser. The new browser had not seen the peers on screen.
  - `recense carry pair` could invite the running Recense.app on the same Mac (same name).
  - "Confirm Pairing" (voice) said "Paired" after 10 s even when the other side had not confirmed.
- Cause 4, one invite only (owner's run, 11-15 11:58: `recense carry pair` printed its first line, then nothing).
  The Mac invited a device once. If that device was not looking yet, it turned the invite down, and no one asked
  again. The owner had to start both within 10 s, on two devices, in the right order.

## Green (the fix)
- `CarryPairFlow` (`shared/carrypair.swift`): one side's whole pairing, taps included. Pure.
  - Their sealed group arriving before this side's own tap is held. The tap opens it. No tap, no pairing.
  - `hello` carries `grouped` (optional, so an older hello still decodes).
  - Exactly one side sends a group: the one that holds one, else the committer.
  - Two existing groups are refused, never merged (unchanged rule, FEAT-09 P1).
  - A second tap while waiting changes nothing.
- `CarryManager` drives the flow:
  - It pairs a listed peer again while "Pair a Device…" is on; the new entry replaces the old one.
  - A hello that beats the `.connected` callback starts the flow.
  - "Pair a Device…" also starts the flow with peers already connected.
  - `stopPairing()` ends the pairing only; the link stays on.
- `pairCandidates`: every nearby device but this one. Used by the iOS list, the Mac menu, Siri and the CLI.
- `P2PTransport.advertise()` / `browse()` keep the running ones.
- "Confirm Pairing" says "Waiting for <name> to confirm too" until the other side confirms.
- `CarryInvites.due`: a picked device that has not connected is invited again every 11 s, past the 10 s invite
  timeout, until it pairs or "Stop Pairing". Either device may start first.
- `recense carry pair` says where to go on the phone, keeps trying, and says every 15 s when it has seen no device.

## Invariants (tested: `mobile/ios/Tests/carrypair/main.swift`; condensed in `recense selftest`)
- For each of {Mac has a group, neither has one, iPhone has one} × {Mac taps first, iPhone first, both first}:
  - both show the same code;
  - BOTH sides finish;
  - both end in the same group;
  - an existing group is kept;
  - each saves the other's name.
- The receiver does not pair before its own tap; its tap opens the held group.
- Two taps while waiting are harmless; the group still lands after them.
- Two devices that each hold a different group are refused (`otherGroup`).
- An older peer's `hello` without `grouped` still decodes.
- Re-invite: nothing before 11 s; each picked device still nearby after that; never one already connected.
- Mutation check: holding the group replaced by the old `throw` → the suite fails.

## Recovering devices paired one-sidedly
- Nothing to delete. On both devices, open Devices › Pair a Device….
- Pick the other device. Compare the codes. Tap They Match on both.
- The Mac's stale entry is replaced.

## Device check (owed)
- iPhone ↔ Mac: both list each other after They Match.
- A file renamed in Library › Music on one appears renamed on the other after Carry Now.
