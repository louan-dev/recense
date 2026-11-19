// Regression guard: FEAT-08
// The one-matter core is reachable from the hosts, and the sidecar file travels with the page on Mac and iOS.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createMatter, seedInkPassage, seedVoicePassage, cross, reverseLast, checkMatter } from '../src/matter.js';

const read = p => readFileSync(new URL(p, import.meta.url), 'utf8');

test('FEAT-08: window.recenseEditor exposes the matter calls', () => {
  const src = read('../src/index.js');
  for (const k of ['getMatter:', 'setMatter:', 'mergeMatter:', 'seedPassage:', 'cross:', 'reverseCrossing:', 'crossings:']) {
    assert.ok(src.includes(k), `index.js exposes ${k}`);
  }
  assert.ok(src.includes('messageHandlers?.matter'), 'the sidecar is posted to the host');
  for (const k of ['setMatterDevice:', 'matterMenu:', 'runMatterAction:', 'openMatterMenu:', 'createMatterMenu(', 'onStrokeAdded:']) {
    assert.ok(src.includes(k), `index.js wires ${k}`);
  }
  assert.ok(src.includes('reverseLast(m, { device: matterDevice.get() })'), 'undo from the editor is per device');
  assert.ok(read('../src/ink.js').includes('onStrokeAdded(stroke)'), 'the ink layer reports each new stroke');
});

test('FEAT-08: Mac and iOS hosts read and write draftpad.matter.json beside the page', () => {
  for (const p of ['../../strip/editorhost.swift', '../../mobile/HostApp/iOS/Draftpad.swift']) {
    const s = read(p);
    assert.ok(s.includes('draftpad.matter.json'), `${p} names the sidecar`);
    assert.ok(/"ink", "matter"/.test(s), `${p} listens for matter`);
    assert.ok(s.includes('setMatter('), `${p} loads it into the editor`);
  }
});

test('FEAT-08: a CRLF page keeps its line endings through ink → type and voice → type', () => {
  const text = 'Saturday, November 14, 2026\r\nSections written apart.\r\n\r\n<!-- page -->\r\n\r\nOld.';
  const ink = { version: 1, removed: [], strokes: [{ id: 's1', tool: 'pen', points: [[10, 30, 0.5], [60, 34, 0.5]], ocr: { g: 'g', t: 'the music' } }] };
  const seed = { device: 'Mac', input: 'keys', time: 1 };
  let m = seedInkPassage(createMatter({ text, ink }), { id: 'p1', strokeIds: ['s1'], seed });
  m = seedVoicePassage(m, { id: 'p2', spoken: { audio: 'a.m4a', words: [{ w: 'gap', t0: 0, t1: 0.4 }] }, seed });
  const start = m;
  m = cross(m, 1, 'p1', { seed: { ...seed, time: 2 } });
  m = cross(m, 10, 'p2', { seed: { ...seed, input: 'voice', time: 3 } });
  assert.ok(!/[^\r]\n/.test(m.text), 'no bare \\n entered a CRLF page');
  assert.ok(m.text.includes('Sections written apart.\r\nthe music\r\ngap\r\n'));
  assert.deepEqual(checkMatter(m, { before: start, origin: start }).problems, []);
  assert.deepEqual(reverseLast(reverseLast(m)), start);
});
