// Regression guard: BUG-02
import test from 'node:test';
import assert from 'node:assert/strict';
import { decideAxis } from '../src/pagemode.js';

// Regression guard: BUG-02
test('no axis until the drag passes the 6 px slop (A1, owner 2026-11-16)', () => {
  assert.equal(decideAxis(3, 2), null);
  assert.equal(decideAxis(5, -5), null);
  // At the slop it locks: this is the number the owner asked to halve so the page follows the finger sooner.
  assert.equal(decideAxis(6, 0), 'h');
  assert.equal(decideAxis(0, 6), 'v');
});

// Regression guard: BUG-02
test('a slanted vertical scroll stays vertical (ratio 1.4)', () => {
  assert.equal(decideAxis(13, 10), 'v');
  assert.equal(decideAxis(14, 10), 'v');
  assert.equal(decideAxis(0, 12), 'v');
  assert.equal(decideAxis(-13, -10), 'v');
});

// Regression guard: BUG-02
test('a clearly sideways drag is a page swipe', () => {
  assert.equal(decideAxis(20, 10), 'h');
  assert.equal(decideAxis(-20, 5), 'h');
});
