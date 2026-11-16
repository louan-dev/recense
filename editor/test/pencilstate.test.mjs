// Derived from Spec: UI-04 P1 — dual-mode squeeze. Regression guard: BUG-01 (a quick squeeze still toggles the palette).
import test from 'node:test';
import assert from 'node:assert/strict';

import { createSqueeze, SQUEEZE_HOLD_MS } from '../src/pencilstate.js';

// A fake clock: timers fire only when the test advances time.
function clock() {
  let now = 0, seq = 0;
  const timers = new Map();
  return {
    setTimer: (fn, ms) => { const id = ++seq; timers.set(id, { at: now + ms, fn }); return id; },
    clearTimer: id => timers.delete(id),
    advance(ms) {
      now += ms;
      for (const [id, t] of [...timers]) if (t.at <= now) { timers.delete(id); t.fn(); }
    }
  };
}
function machine() {
  const log = [];
  const c = clock();
  const sq = createSqueeze({
    onTap: () => log.push('tap'),
    onHold: (x, y) => log.push(`hold ${x},${y}`),
    onMove: (x, y) => log.push(`move ${x},${y}`),
    onRelease: (x, y) => log.push(`release ${x},${y}`),
    onCancel: () => log.push('cancel'),
    setTimer: c.setTimer, clearTimer: c.clearTimer
  });
  return { sq, c, log };
}

test('P1: the hold threshold is 250 ms', () => {
  assert.equal(SQUEEZE_HOLD_MS, 250);
});

test('P1: released at 249 ms is a tap (today\'s palette toggle)', () => {
  const { sq, c, log } = machine();
  sq.phase('began', 10, 20);
  c.advance(249);
  sq.phase('ended', 10, 20);
  assert.deepEqual(log, ['tap']);
  assert.equal(sq.state(), 'idle');
});

test('P1: held 250 ms opens at the hover point; release reports where', () => {
  const { sq, c, log } = machine();
  sq.phase('began', 10, 20);
  c.advance(250);
  assert.equal(sq.state(), 'holding');
  sq.phase('changed', 40, 20);
  sq.phase('ended', 60, 25);
  assert.deepEqual(log, ['hold 10,20', 'move 40,20', 'release 60,25']);
  assert.equal(sq.state(), 'idle');
});

test('P1: a changed phase before 250 ms only updates the point the hold opens at', () => {
  const { sq, c, log } = machine();
  sq.phase('began', 10, 20);
  sq.phase('changed', 12, 22);
  c.advance(250);
  assert.deepEqual(log, ['hold 12,22']);
});

test('P1: cancelled before the hold does nothing; after it closes without a pick', () => {
  const a = machine();
  a.sq.phase('began', 1, 1);
  a.sq.phase('cancelled');
  a.c.advance(500);
  assert.deepEqual(a.log, []);
  const b = machine();
  b.sq.phase('began', 1, 1);
  b.c.advance(300);
  b.sq.phase('cancelled');
  assert.deepEqual(b.log, ['hold 1,1', 'cancel']);
});

test('P1: a discrete squeeze (only "ended", as older hosts send) is a tap', () => {
  const { sq, log } = machine();
  sq.phase('ended', 5, 5);
  assert.deepEqual(log, ['tap']);
});

test('P1: a second began while one is in flight restarts cleanly', () => {
  const { sq, c, log } = machine();
  sq.phase('began', 1, 1);
  c.advance(100);
  sq.phase('began', 2, 2);
  c.advance(200);
  assert.deepEqual(log, [], 'the first timer was cleared');
  c.advance(50);
  assert.deepEqual(log, ['hold 2,2']);
});

// Wired into the editor API.
test('P1: onPencilSqueeze — quick squeeze toggles the palette; a hold with no radial menu yet toggles on release', async () => {
  const { squeezeHost } = await import('../src/pencilstate.js');
  let toggles = 0, menu = null;
  const c = clock();
  const host = squeezeHost({ toggle: () => { toggles++; return true; }, radial: () => menu, setTimer: c.setTimer, clearTimer: c.clearTimer });
  host('began', 0, 0); c.advance(100); host('ended', 0, 0);
  assert.equal(toggles, 1, 'quick squeeze');
  host('began', 0, 0); c.advance(300); host('ended', 0, 0);
  assert.equal(toggles, 2, 'until P2 builds the radial menu, a long squeeze still wakes the palette (no regression)');
  const seen = [];
  menu = { open: (x, y) => seen.push(`open ${x},${y}`), move: (x, y) => seen.push(`move ${x},${y}`), release: (x, y) => seen.push(`release ${x},${y}`), close: () => seen.push('close') };
  host('began', 5, 6); c.advance(300); host('changed', 7, 8); host('ended', 9, 9);
  assert.deepEqual(seen, ['open 5,6', 'move 7,8', 'release 9,9']);
  assert.equal(toggles, 2, 'with a radial menu, a hold never toggles the palette');
});
