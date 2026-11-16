// Derived from Spec: UI-04 P5
import test from 'node:test';
import assert from 'node:assert/strict';
import { nextPressure, pressureForSpeed, PRESSURE_SLOW, PRESSURE_FAST, PRESSURE_START } from '../src/pressure.js';

test('Pencil pressure passes through', () => {
  assert.equal(nextPressure({ pointerType: 'pen', pressure: 0.62 }, 5, 5, 10, [0, 0, 0.5, 0]), 0.62);
});
test('finger start is the default, not 0', () => {
  assert.equal(nextPressure({ pointerType: 'touch', pressure: 0 }, 0, 0, 0, null), PRESSURE_START);
});
test('speed maps slow=heavy, fast=light, monotone, clamped', () => {
  assert.equal(pressureForSpeed(0), PRESSURE_SLOW);
  assert.equal(pressureForSpeed(99), PRESSURE_FAST);
  assert.ok(pressureForSpeed(1) < pressureForSpeed(0.5));
});
test('finger stroke varies width: fast samples end lighter than slow ones', () => {
  let slow = [0, 0, 0.5, 0], fast = [0, 0, 0.5, 0];
  for (let i = 1; i <= 20; i++) {
    slow = [i * 0.1, 0, nextPressure({ pointerType: 'touch' }, i * 0.1, 0, i * 8, slow), i * 8];
    fast = [i * 30, 0, nextPressure({ pointerType: 'mouse' }, i * 30, 0, i * 8, fast), i * 8];
  }
  assert.ok(slow[2] > fast[2]);
  assert.ok(fast[2] >= PRESSURE_FAST - 1e-9 && slow[2] <= PRESSURE_SLOW + 1e-9);
});
test('zero time gap keeps previous pressure', () => {
  assert.equal(nextPressure({ pointerType: 'touch' }, 9, 9, 5, [0, 0, 0.6, 5]), 0.6);
});
