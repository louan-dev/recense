// Regression guard: BUG-02
import test from 'node:test';
import assert from 'node:assert/strict';
import { decideAxis } from '../src/pagemode.js';

// Regression guard: BUG-02
test('no axis until the drag passes the 12 px slop', () => {
  assert.equal(decideAxis(5, 3), null);
  assert.equal(decideAxis(11, -11), null);
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
