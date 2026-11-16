// Derived from Spec: UI-04 P1 — dual-mode squeeze.
// idle → pressed → (released before 250 ms) tap | (held 250 ms) holding → released (pick) | cancelled.
// The host sends every squeeze phase with the Pencil's hover point; the timing lives here, so every
// host shares one state machine.
export const SQUEEZE_HOLD_MS = 250;

/**
 * phase(name, x, y): name is 'began' | 'changed' | 'ended' | 'cancelled'.
 * Callbacks: onTap(), onHold(x, y), onMove(x, y), onRelease(x, y), onCancel().
 */
export function createSqueeze({
  onTap = () => {}, onHold = () => {}, onMove = () => {}, onRelease = () => {}, onCancel = () => {},
  holdMs = SQUEEZE_HOLD_MS,
  setTimer = (fn, ms) => setTimeout(fn, ms),
  clearTimer = id => clearTimeout(id)
} = {}) {
  let state = 'idle';
  let timer = null;
  let x = 0, y = 0;

  const stopTimer = () => { if (timer !== null) { clearTimer(timer); timer = null; } };
  const at = (nx, ny) => { if (Number.isFinite(nx)) x = nx; if (Number.isFinite(ny)) y = ny; };

  function phase(name, nx, ny) {
    at(Number(nx), Number(ny));
    switch (name) {
      case 'began':
        stopTimer();
        state = 'pressed';
        timer = setTimer(() => { timer = null; if (state === 'pressed') { state = 'holding'; onHold(x, y); } }, holdMs);
        return state;
      case 'changed':
        if (state === 'holding') onMove(x, y);
        return state;
      case 'ended':
        stopTimer();
        if (state === 'holding') onRelease(x, y);
        else onTap();   // pressed, or a discrete squeeze that only reports "ended"
        state = 'idle';
        return state;
      case 'cancelled':
        stopTimer();
        if (state === 'holding') onCancel();
        state = 'idle';
        return state;
      default:
        return state;
    }
  }

  return { phase, state: () => state };
}

/**
 * The editor's squeeze entry point. `toggle()` wakes or sleeps the palette; `radial()` returns the
 * radial menu ({ open, move, release, close }) or null while UI-04 P2 isn't built — then a hold
 * falls back to the palette toggle on release, so a long squeeze never does less than it did.
 * Returns host(phase, x, y) → the machine's state.
 */
export function squeezeHost({ toggle, radial = () => null, setTimer, clearTimer } = {}) {
  let menu = null;
  const sq = createSqueeze({
    onTap: () => toggle(),
    onHold: (x, y) => { menu = radial(); if (menu) menu.open(x, y); },
    onMove: (x, y) => { if (menu) menu.move(x, y); },
    onRelease: (x, y) => { if (menu) menu.release(x, y); else toggle(); menu = null; },
    onCancel: () => { if (menu) menu.close(); menu = null; },
    ...(setTimer ? { setTimer } : {}),
    ...(clearTimer ? { clearTimer } : {})
  });
  return (phase, x, y) => sq.phase(phase, x, y);
}
