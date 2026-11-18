// Regression guard: recfix audit 2026-11-16 — deleting a page, putting it in a slot and changing the text size
// had no visible control (swipe, dot hold, host call only). The owner's law: no action is gesture-only.
// Derived from Spec: UI-06, UI-07
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { stepFontSize, normalizeFontSize, FONT_STEP_PX } from '../src/theme.js';

const src = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');

test('recfix: the menu lists Delete empty page, Put in slot…, Larger text, Smaller text', () => {
  for (const [id, label] of [
    ['rc-delete-page-btn', 'Delete empty page'],
    ['rc-slot-btn', 'Put in slot…'],
    ['rc-larger-text-btn', 'Larger text'],
    ['rc-smaller-text-btn', 'Smaller text']
  ]) {
    assert.match(src, new RegExp(`makeMenuItem\\('${id}', '${label}'`), `${label} is a menu item`);
  }
  const appended = src.slice(src.indexOf('menu.append('), src.indexOf(');', src.indexOf('menu.append(')));
  for (const v of ['deletePageMenuBtn', 'slotMenuBtn', 'largerTextBtn', 'smallerTextBtn']) {
    assert.ok(appended.includes(v), `${v} is in the menu`);
    assert.match(src, new RegExp(`${v}\\.addEventListener\\('click'`), `${v} does something when clicked`);
  }
});

test('recfix: each item calls the same action as its gesture', () => {
  assert.match(src, /deletePageMenuBtn\.addEventListener\('click'[^\n]*deleteEmptyWindow\(view\)/);
  assert.match(src, /slotMenuBtn\.addEventListener[\s\S]{0,300}openDotSheet\(/);
  assert.match(src, /largerTextBtn\.addEventListener[^\n]*setFontSize\(stepFontSize\(currentFontSize, 1\)\)/);
  assert.match(src, /smallerTextBtn\.addEventListener[^\n]*setFontSize\(stepFontSize\(currentFontSize, -1\)\)/);
});

test('recfix: text size steps by 2 px and stays within 12–36', () => {
  assert.equal(FONT_STEP_PX, 2);
  assert.equal(stepFontSize(18, 1), 20);
  assert.equal(stepFontSize(18, -1), 16);
  assert.equal(stepFontSize(36, 1), 36);
  assert.equal(stepFontSize(12, -1), 12);
  assert.equal(stepFontSize(35, 1), 36);
  assert.equal(stepFontSize('x', 1), normalizeFontSize('x') + 2);
});
