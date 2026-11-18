// Derived from Spec: FEAT-08 P5
// The hosts name the device; the Mac re-reads the sidecar while open.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createMatter, seedInkPassage, cross, createMatterDevice } from '../src/matter.js';

const read = p => readFileSync(new URL(p, import.meta.url), 'utf8');
const MAC_UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15';
const IPHONE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15';

test('FEAT-08 P5: after setMatterDevice("Mac mini") a crossing logs device "Mac mini"', () => {
  const dev = createMatterDevice({ userAgent: MAC_UA, maxTouchPoints: 0 });
  assert.equal(dev.get(), 'Mac', 'before the host names it, the user agent guesses');
  assert.equal(dev.set('Mac mini'), 'Mac mini');
  const ink = { version: 1, removed: [], strokes: [{ id: 's1', tool: 'pen', points: [[10, 30, 0.5], [60, 34, 0.5]], ocr: { g: 'g', t: 'gap' } }] };
  let m = seedInkPassage(createMatter({ text: 'Day\n', ink }), { id: 'p1', strokeIds: ['s1'], seed: { device: dev.get(), input: 'pencil', time: 1 } });
  m = cross(m, 1, 'p1', { seed: { device: dev.get(), input: 'keys', time: 2 } });
  assert.equal(m.side.log.at(-1).seed.device, 'Mac mini');
});

test('FEAT-08 P5: a later user-agent guess never replaces the host\'s name; an empty name is refused', () => {
  const dev = createMatterDevice({ userAgent: MAC_UA, maxTouchPoints: 0 });
  dev.set('Mac mini');
  assert.equal(dev.guess({ userAgent: IPHONE_UA, maxTouchPoints: 5 }), 'Mac mini');
  assert.equal(dev.set(''), 'Mac mini');
  assert.equal(dev.set('   '), 'Mac mini');
  assert.equal(dev.set(null), 'Mac mini');
  const fresh = createMatterDevice({ userAgent: MAC_UA, maxTouchPoints: 0 });
  assert.equal(fresh.guess({ userAgent: IPHONE_UA, maxTouchPoints: 5 }), 'iPhone', 'unnamed: the guess may change');
});

test('FEAT-08 P5: the editor uses one device holder, and both hosts name the device at load', () => {
  const idx = read('../src/index.js');
  assert.ok(idx.includes('createMatterDevice('), 'index.js holds the device through createMatterDevice');
  assert.ok(/setMatterDevice: name => matterDevice\.set\(name\)/.test(idx), 'the setter goes through the guard');
  for (const p of ['../../strip/editorhost.swift', '../../mobile/HostApp/iOS/Draftpad.swift']) {
    const s = read(p);
    assert.ok(s.includes('setMatterDevice(') && s.includes('P2PTransport.deviceName()'), `${p} names the device with the carry name`);
  }
});

test('FEAT-08 P5: the Mac re-reads the sidecar while open and merges it (mergeMatter), as iOS does on its poll', () => {
  const host = read('../../strip/editorhost.swift');
  assert.ok(/func pollMatter\(\)/.test(host), 'EditorHost.pollMatter exists');
  assert.ok(/pollMatter[\s\S]{0,1200}mergeMatter\(/.test(host), 'it hands a changed file to the page to merge');
  assert.ok(read('../../strip/app.swift').includes('editor?.pollMatter()'), 'App.pollExternal calls it');
});
