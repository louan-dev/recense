# BUG-03 · Follow mode floating window: no line-change animation
From: T-0031
Status: `[~]` building

## Symptom
When the floating window is in **Follow** mode (look ≠ "learn"), new current lines appear
instantly — no fade. Learn mode fades each new line in over 0.55 s (0.15 s gap then 0.4 s
ramp), matching the in-app preview.

## Root cause
`Listener.frame()` follow branch (`Listen.swift:1173`) creates rows with the default
`alpha = 1.0`, never reading the slot timestamps that `changed()` already maintains for
both modes.

Learn branch (`Listen.swift:1162`) correctly reads `slots[k].since`:
```swift
let t = wall.timeIntervalSince(slots[k].since)
let a = old ? 1 - t / 0.15 : min(1, (t - 0.15) / 0.4)
```

Follow branch ignores it:
```swift
rows.append(FloatingCaption.Row(line: ..., on: true, t: now))  // alpha = 1.0 always
```

`animate()` already fires for follow mode (it loops on `slots[k].since < 0.55 s`) — the
30 fps redraw is in place; only the alpha calculation is missing.

## Fix
In `frame()` follow branch, compute `curAlpha` from `slots[p % 2].since`, identical to
learn's formula but without the "old" (fade-out) half:

```swift
let t = wall.timeIntervalSince(slots[p % 2].since)
let curAlpha = t < 0.15 ? 0.0 : min(1.0, (t - 0.15) / 0.4)
rows.append(FloatingCaption.Row(line: line(sentences[p], said: true), on: true, t: now, alpha: curAlpha))
```

## Invariant (regression guard)
`frame()` follow branch: when `slots[p % 2].since` is within 0.55 s of `wall`, the
returned current row's `alpha < 1.0`.
