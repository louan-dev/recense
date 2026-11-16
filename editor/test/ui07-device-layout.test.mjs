// Derived from Spec: UI-07
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { deviceLayout, layoutVars } from '../src/devicelayout.js';

const row = l => [l.fontSize, l.columnCh, l.padX, l.padTop, l.padBottom];

test('UI-07: iPhone 12 Pro Max, portrait and landscape', () => {
  assert.deepEqual(row(deviceLayout(428, 926, true)), [18, 44, 16, 20, 96]);
  assert.deepEqual(row(deviceLayout(926, 428, true)), [18, 52, 24, 8, 48]);
});

test('UI-07: iPad Air M2 11-inch, portrait and landscape', () => {
  assert.deepEqual(row(deviceLayout(820, 1180, true)), [20, 58, 32, 32, 120]);
  assert.deepEqual(row(deviceLayout(1180, 820, true)), [20, 62, 48, 24, 96]);
});

test('UI-07: iPad Air M2 13-inch, portrait and landscape', () => {
  assert.deepEqual(row(deviceLayout(1024, 1366, true)), [21, 60, 40, 36, 120]);
  assert.deepEqual(row(deviceLayout(1366, 1024, true)), [21, 64, 56, 28, 96]);
});

test('UI-07: other sizes fall into the nearest row', () => {
  assert.equal(deviceLayout(390, 844, true).device, 'phone');      // iPhone 13/14
  assert.equal(deviceLayout(744, 1133, true).device, 'pad11');     // iPad mini
  assert.equal(deviceLayout(507, 1180, true).device, 'pad11');     // 11-inch split view
});

test('UI-07: a fine pointer (Mac) keeps the Mac box', () => {
  assert.equal(deviceLayout(428, 926, false), null);
  assert.equal(deviceLayout(1440, 900, false), null);
  assert.equal(layoutVars(null)['--rc-col'], null);
});

test('UI-07: the theme reads the layout variables, with the Mac box as fallback', () => {
  const theme = readFileSync(new URL('../src/theme.js', import.meta.url), 'utf8');
  assert.match(theme, /var\(--rc-col, \$\{COLUMN_CHARS\}ch\)/);
  assert.match(theme, /var\(--rc-pad-x, 20px\)/);
});

test('UI-07: a size the person picks wins over the device default', () => {
  const index = readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
  assert.match(index, /userFontSize\s*=\s*true/);
  assert.match(index, /if \(layout && !userFontSize\)/);
});

test('UI-07: the iOS host no longer forces a font size', () => {
  const host = readFileSync(new URL('../../mobile/HostApp/iOS/Draftpad.swift', import.meta.url), 'utf8');
  assert.doesNotMatch(host, /call\("setFontSize/);
});
