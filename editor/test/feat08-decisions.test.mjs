// Regression guard: FEAT-08
// Decisions of 2026-11-16 (Q1 owner; Q2-4 coordinator under the owner's delegation), recorded in FEAT-08:
// 1 ink stays visible after #1 · 2 "> " markup is fine · 3 undo is per device, refuses when the passage changed
// · 4 every crossing is reachable from one Matter list on the passage, labelled by what you get.
// Also: #2 attaches new strokes to words; the sidecar compacts.
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  createMatter,
  seedInkPassage,
  seedTypePassage,
  cross,
  reverseLast,
  CIRCUIT,
  KEEP_REVERSIBLE,
  matterActions,
  menuForSelection,
  passageAt,
  attachStrokeToWord,
  traceToSeed,
  checkMatter
} from '../src/matter.js';

const BODY = 'Saturday, November 14, 2026\nSections written apart stay side by side.\n\n<!-- page -->\n\nOlder page.';
const S = (device, time, input = 'keys') => ({ device, input, time });
const twoPassages = () => seedTypePassage(
  seedTypePassage(createMatter({ text: BODY }), { id: 'p1', quote: 'written apart', seed: S('Mac', 1) }),
  { id: 'p2', quote: 'Older page', seed: S('iPhone', 1, 'touch') }
);

test('FEAT-08 Q1: after #1 the handwriting stays as it was, visible beside its words', () => {
  const ink = { version: 1, removed: [], strokes: [{ id: 's1', tool: 'pen', points: [[10, 30, 0.5], [60, 34, 0.5]], ocr: { g: 'g', t: 'the music' } }] };
  const m0 = seedInkPassage(createMatter({ text: BODY, ink }), { id: 'p1', strokeIds: ['s1'], seed: S('iPad', 1, 'pencil') });
  const m1 = cross(m0, 1, 'p1', { seed: S('iPad', 2, 'pencil') });
  assert.deepEqual(m1.ink, m0.ink, 'the strokes are untouched (no fade, no hidden flag)');
});

test('FEAT-08 Q3: undo is per device: the Mac undoes its own crossing, the iPhone\'s stays', () => {
  const start = twoPassages();
  const m1 = cross(start, 3, 'p1', { seed: S('Mac', 2) });
  const m2 = cross(m1, 9, 'p2', { seed: S('iPhone', 3, 'touch') });
  const r = reverseLast(m2, { device: 'Mac' });
  assert.equal(r.side.passages.p1.forms.mark, undefined, 'the Mac highlight is gone');
  assert.ok(r.side.passages.p2.forms.voice, 'the iPhone read-aloud stays');
  assert.deepEqual(r.side.log.map(e => e.seed.device), ['iPhone']);
  assert.deepEqual(reverseLast(r, { device: 'iPhone' }), start);
  assert.throws(() => reverseLast(start, { device: 'Mac' }), /nothing to reverse on Mac/);
});

test('FEAT-08 Q3: never undoes a passage another device changed since; refuses with a short note', () => {
  const m1 = cross(twoPassages(), 3, 'p1', { seed: S('Mac', 2) });
  const m2 = cross(m1, 9, 'p1', { seed: S('iPhone', 3, 'touch') });
  assert.throws(() => reverseLast(m2, { device: 'Mac' }), /changed since/);
  // the iPhone's own, being the last on p1, still reverses
  assert.deepEqual(reverseLast(m2, { device: 'iPhone' }), m1);
});

test('FEAT-08 Q4: the Matter list names what you get and runs the crossing', () => {
  const m = twoPassages();
  const acts = matterActions(m, 'p1');
  assert.deepEqual(acts.map(a => [a.id, a.label, a.from, a.to]), [
    ['cross-2', 'Pencil over', 'type', 'ink'],
    ['cross-3', 'Highlight', 'type', 'mark'],
    ['cross-9', 'Read aloud', 'type', 'voice']
  ]);
  const run = acts.find(a => a.id === 'cross-3').run(m, { seed: S('Mac', 5) });
  assert.equal(run.side.passages.p1.forms.mark.kind, 'highlight');
  assert.deepEqual(matterActions(m, 'nope'), []);
});

test('FEAT-08 Q4: two labels that read the same say where they come from', () => {
  const ink = { version: 1, removed: [], strokes: [{ id: 's1', tool: 'pen', points: [[10, 30, 0.5], [60, 34, 0.5]], ocr: { g: 'g', t: 'the music' } }] };
  let m = seedInkPassage(createMatter({ text: BODY, ink }), { id: 'p1', strokeIds: ['s1'], seed: S('iPad', 0, 'pencil') });
  const spoken = { audio: 'a.m4a', words: [{ w: 'gap', t0: 0, t1: 0.4 }] };
  CIRCUIT.forEach((n, i) => { m = cross(m, n, 'p1', { seed: S('Mac', i + 1), ...(n === 8 ? { spoken } : {}) }); });
  const labels = matterActions(m, 'p1').map(a => a.label);
  assert.ok(labels.includes('Make text from pencil') && labels.includes('Make text from voice'));
  assert.ok(labels.includes('Read aloud from text') && labels.includes('Read aloud from pencil'));
  assert.equal(new Set(labels).size, labels.length, 'no two items read the same');
});

test('FEAT-08 Q4: a selection that is not a passage yet becomes one when a crossing is chosen', () => {
  const m = twoPassages();
  const from = BODY.indexOf('side by side');
  const menu = menuForSelection(m, from, from + 'side by side'.length);
  assert.equal(menu.pid, null);
  assert.deepEqual(menu.actions.map(a => a.label), ['Pencil over', 'Highlight', 'Read aloud']);
  const after = menu.actions[1].run(m, { seed: S('Mac', 7) });
  const pid = passageAt(after, from + 2);
  assert.ok(pid && pid !== 'p1' && pid !== 'p2');
  assert.equal(after.side.passages[pid].forms.mark.anchor.quote, 'side by side');
  assert.deepEqual(traceToSeed(after, pid).map(t => t.cross), [0, 3]);
  // the selection inside p1 opens p1's menu
  assert.equal(menuForSelection(m, BODY.indexOf('apart'), BODY.indexOf('apart') + 3).pid, 'p1');
  assert.deepEqual(menuForSelection(m, 0, 0).actions, []);
});

test('FEAT-08 #2: a stroke drawn over a frozen passage attaches to the word under it', () => {
  const frozen = cross(twoPassages(), 2, 'p1', { seed: S('iPad', 2, 'pencil') });
  const m = { ...frozen, ink: { ...frozen.ink, strokes: [{ id: 'u1', tool: 'pen', points: [[100, 40, 0.5], [140, 40, 0.5]] }] } };
  const at = BODY.indexOf('apart') + 2;
  const out = attachStrokeToWord(m, 'u1', at);
  assert.deepEqual(out.ink.strokes[0].word, { pid: 'p1', i: 1, w: 'apart' });
  assert.ok(out.side.passages.p1.forms.ink.strokes.includes('u1'));
  assert.deepEqual(checkMatter(out, { before: m, origin: m }).problems, []);
  // outside any frozen passage: nothing changes
  assert.equal(attachStrokeToWord(m, 'u1', BODY.indexOf('Older')), m);
  // the passage changed since #2, so #2 is not silently undone
  assert.throws(() => reverseLast(out, { device: 'iPad' }), /changed since/);
});

test('FEAT-08: the sidecar compacts: old crossings keep their trace, only recent ones keep their undo', () => {
  let m = twoPassages();
  const size0 = JSON.stringify(m.side).length;
  for (let i = 0; i < 100; i++) m = cross(m, 9, 'p1', { seed: S('Mac', 10 + i) });
  assert.equal(traceToSeed(m, 'p1').length, 101, 'every crossing still traced');
  assert.equal(m.side.log.filter(e => e.undo).length, KEEP_REVERSIBLE);
  const per = (JSON.stringify(m.side).length - size0) / 100;
  assert.ok(per < 600, `a compacted crossing costs little (${Math.round(per)} bytes each)`);
  for (let i = 0; i < KEEP_REVERSIBLE; i++) m = reverseLast(m, { device: 'Mac' });
  assert.throws(() => reverseLast(m, { device: 'Mac' }), /too old/);
});
