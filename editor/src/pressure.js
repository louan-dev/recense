// Derived from Spec: UI-04 P5 — finger and trackpad write like the Pencil.
// Pencil reports real pressure; a finger or trackpad reports a constant, so a stroke would have
// one flat width. Synthesize pressure from drawing speed instead: slow = heavy, fast = light.
// These numbers are DEFAULTS (a guess to be tuned on the owner's devices), not measured values.
export const PRESSURE_SLOW = 0.75;     // pressure at or below SPEED_SLOW
export const PRESSURE_FAST = 0.3;      // pressure at or above SPEED_FAST
export const SPEED_SLOW = 0.2;         // px/ms
export const SPEED_FAST = 2.5;         // px/ms
export const PRESSURE_SMOOTH = 0.35;   // weight of the new sample (0..1); lower = calmer width
export const PRESSURE_START = 0.5;

/** True when the device reports its own usable pressure (a Pencil, not a finger or trackpad). */
export function hasRealPressure(ev) {
  return ev && ev.pointerType === 'pen' && typeof ev.pressure === 'number' && ev.pressure > 0;
}

/** Pressure for a point at speed `v` (px/ms): pure, monotone, clamped. */
export function pressureForSpeed(v) {
  if (!(v > SPEED_SLOW)) return PRESSURE_SLOW;
  if (v >= SPEED_FAST) return PRESSURE_FAST;
  const f = (v - SPEED_SLOW) / (SPEED_FAST - SPEED_SLOW);
  return PRESSURE_SLOW + (PRESSURE_FAST - PRESSURE_SLOW) * f;
}

/**
 * Pressure for the next sample. `prev` is the previous point [x, y, p, t] or null.
 * Real Pencil pressure passes through untouched; everything else is synthesized and smoothed.
 */
export function nextPressure(ev, x, y, t, prev) {
  if (hasRealPressure(ev)) return ev.pressure;
  if (!prev) return PRESSURE_START;
  const dt = t - prev[3];
  if (!(dt > 0)) return prev[2];
  const v = Math.hypot(x - prev[0], y - prev[1]) / dt;
  return prev[2] + (pressureForSpeed(v) - prev[2]) * PRESSURE_SMOOTH;
}
