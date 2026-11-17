# BUG-26 · Pairing breaks on a duplicate message, a spoken code, or a second device nearby

From: T-0118, T-0119, T-0120 (pair-fix review R1–R3, 2026-11-16) ·
Guards: FEAT-09 P1/P1b, BUG-17 ·
Status: `[~]` (tested without radios; device check owed)

## What the owner would see
- "Code didn't match" on both devices although nothing was typed wrong.
- Saying the code to Siri ("one two three four five six") ends the pairing instead of asking again.
- With two devices nearby, the code shown or typed belongs to the other one.

## Red (read from code, merged 956793e)
- T-0118 · `fail()` sent `.refuse` for every error but `.refused`. A stale or duplicate message (`.outOfOrder`,
  the BUG-17 echo) tore down this flow and told the peer to tear down its own.
- T-0119 · `enterCode` passed the raw text to `CarryPasskey.enter`. Spoken words or non-ASCII digits
  (the fields filter with `isNumber`, which admits them) failed with `.badCommit`, and `fail()` ended the pairing.
- T-0120 · one set of prompt slots (`pairingCode`, `pairingWith`, `askingCode`) served every flow; a second flow
  overwrote them, `fail()` of any flow cleared them, and `enterCode` fell back to `flows.keys.first`.

## Green
- `PairFailure.endsFlow` (all but `.outOfOrder`) and `.tellsPeer` (all but `.outOfOrder` and `.refused`).
  `receivePair` ignores `.outOfOrder`; `fail()` sends refuse only when `tellsPeer`.
  The review asked for refuse on `.badCommit`/`.otherGroup` only; `.badKey` and `.unsealed` also tell the peer,
  since it would otherwise wait with no end.
- `CarryPasskey.normalize(text)`: any script's decimal digits, plus spoken digits in English, Vietnamese,
  French and Spanish (compared without marks), → six ASCII digits, or nil. `enterCode` with nil sets
  `lastError` ("That wasn't six digits…") and keeps asking.
- `PairPrompt.owns(holder, peer)`: one prompt at a time. A new flow starts only when the prompt is free or
  already this peer's; `apply` and `fail` touch the slots only for their owner; `enterCode` has no fallback.

## Invariants (tested: `mobile/ios/Tests/carrypair/main.swift`)
- outOfOrder: neither ends the flow nor tells the peer. badCommit and otherGroup: both. refused: ends, not echoed.
- "123 456", "one two three four five six", "một hai ba bốn năm sáu", "١٢٣٤٥٦", "１２３４５６" → "123456";
  five digits, an unknown word, or empty → nil.
- Prompt held by iPad: iPad keeps it, iPhone can't take it; a free prompt goes to the first.

## Device check (owed)
- iPhone: Shortcuts › "Enter Pairing Code" › say "one two three four five six" with the Mac's code: they pair.
- Say "one two banana": Recense asks again; the Mac still shows its code.
