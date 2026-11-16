// Regression guard: T-0094 — every pen stroke was drawn at one constant width.
import test from 'node:test';
import assert from 'node:assert/strict';
import { outlinePath, widthAt } from '../src/strokeoutline.js';

test('width follows pressure; 0.5 is the base width', () => {
  assert.equal(widthAt(4, 0.5), 4);
  assert.ok(widthAt(4, 0.9) > widthAt(4, 0.5));
  assert.ok(widthAt(4, 0.1) < widthAt(4, 0.5));
});
test('outline of a heavy-then-light stroke is wider at the start than the end', () => {
  const pts = [[0, 0, 0.9, 0], [50, 0, 0.9, 1], [100, 0, 0.1, 2], [150, 0, 0.1, 3]];
  const d = outlinePath(pts, 4);
  const nums = d.match(/-?\d+\.\d+/g).map(Number);
  const ys = [];
  for (const m of d.matchAll(/[ML] (-?[\d.]+) (-?[\d.]+)/g)) ys.push(+m[2]);
  assert.ok(Math.max(...ys.slice(0, 2)) !== undefined && nums.length > 8);
  const spanAt = x => { const v = []; for (const m of d.matchAll(/[ML] (-?[\d.]+) (-?[\d.]+)/g)) if (+m[1] === x) v.push(+m[2]); return Math.max(...v) - Math.min(...v); };
  assert.ok(spanAt(0) > spanAt(150) * 3);
});
test('one point gives no outline (a dot is drawn elsewhere)', () => {
  assert.equal(outlinePath([[1, 1, 0.5, 0]], 4), '');
});
