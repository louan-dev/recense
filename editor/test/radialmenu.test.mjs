// Derived from Spec: UI-04 P2 — radial menu geometry and hit-test.
// Regression guard: UI-04
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  radialHitTest, radialItemPos, createRadialMenu,
  RADIAL_DEADZONE, RADIAL_INNER_R, RADIAL_OUTER_R
} from '../src/radialmenu.js';
import { squeezeHost } from '../src/pencilstate.js';

test('ring radii are the spec numbers: deadzone 28, inner 68, outer 112', () => {
  assert.equal(RADIAL_DEADZONE, 28);
  assert.equal(RADIAL_INNER_R, 68);
  assert.equal(RADIAL_OUTER_R, 112);
});

test('27.9 pt from the centre is the deadzone: nothing picked', () => {
  assert.equal(radialHitTest(0, -27.9, 5, 3), null);
  assert.equal(radialHitTest(0, 0, 5, 3), null);
});

test('28 pt is the inner ring', () => {
  assert.deepEqual(radialHitTest(0, -28, 5, 3), { ring: 'inner', index: 0 });
});

test('68 pt picks the inner item under the angle', () => {
  for (let i = 0; i < 5; i++) {
    const p = radialItemPos(i, 5, 68);
    assert.deepEqual(radialHitTest(p.x, p.y, 5, 0), { ring: 'inner', index: i });
  }
});

test('112 pt is the outer ring; empty outer ring picks nothing', () => {
  const p = radialItemPos(2, 4, 112);
  assert.deepEqual(radialHitTest(p.x, p.y, 5, 4), { ring: 'outer', index: 2 });
  assert.equal(radialHitTest(p.x, p.y, 5, 0), null);
});

test('far past the outer ring picks nothing', () => {
  assert.equal(radialHitTest(0, -400, 5, 4), null);
});

test('item 0 is straight up and items go clockwise', () => {
  const p0 = radialItemPos(0, 4, 68);
  assert.ok(Math.abs(p0.x) < 1e-9 && p0.y < 0);
  const p1 = radialItemPos(1, 4, 68);
  assert.ok(p1.x > 0 && Math.abs(p1.y) < 1e-9);   // right of centre (clockwise on screen)
});

test('a held squeeze opens the menu, release over an item picks it, deadzone release picks nothing', () => {
  const picks = [];
  const menu = createRadialMenu({
    doc: null,
    items: { inner: [{ id: 'select' }, { id: 'pen' }, { id: 'highlighter' }, { id: 'eraser-whole' }], outer: [] },
    onPick: it => picks.push(it.id)
  });
  let timer = null;
  const host = squeezeHost({
    toggle: () => picks.push('toggle'),
    radial: () => menu,
    setTimer: fn => { timer = fn; return 1; },
    clearTimer: () => { timer = null; }
  });
  host('began', 100, 100);
  timer();   // held 250 ms
  assert.equal(menu.isOpen(), true);
  host('changed', 168, 100);
  host('ended', 168, 100);   // right: item 1 of 4
  assert.deepEqual(picks, ['pen']);
  assert.equal(menu.isOpen(), false);

  host('began', 100, 100);
  timer();
  host('ended', 110, 100);   // 10 pt: deadzone
  assert.deepEqual(picks, ['pen']);
  assert.equal(menu.isOpen(), false);
});

test('a quick squeeze still toggles the palette (BUG-01), never the menu', () => {
  const picks = [];
  const menu = createRadialMenu({ doc: null, items: { inner: [{ id: 'pen' }] }, onPick: it => picks.push(it.id) });
  const host = squeezeHost({
    toggle: () => picks.push('toggle'),
    radial: () => menu,
    setTimer: () => 1, clearTimer: () => {}
  });
  host('began', 0, 0);
  host('ended', 0, 0);
  assert.deepEqual(picks, ['toggle']);
  assert.equal(menu.isOpen(), false);
});
