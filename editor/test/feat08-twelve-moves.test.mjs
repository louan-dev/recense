// Regression guard: FEAT-08
// The 12-move test (docs/specs/FEAT-08-draftpad-one-matter.md, "Done check"):
// one passage carried through all 12 crossings between ink, type, mark and voice.
// Pass = same page (no new file), nothing lost, nothing duplicated, every passage traces back to its seed,
// each crossing reverses (round trip returns the same matter).
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  CROSSINGS,
  CIRCUIT,
  createMatter,
  seedInkPassage,
  cross,
  reverseLast,
  toFiles,
  fromFiles,
  checkMatter,
  traceToSeed,
  wordsOf
} from '../src/matter.js';

const T0 = Date.UTC(2026, 10, 14, 9, 0, 0);
const BODY = 'Saturday, November 14, 2026\nSections written apart stay side by side.\n\n<!-- page -->\n\nOlder page.';
const IPAD = { device: 'iPad Air M2 13-inch', input: 'pencil', time: T0 };

function seededPage() {
  const ink = {
    version: 1,
    strokes: [
      { id: 's1', tool: 'pen', color: '#38bdf8', points: [[10, 30, 0.5], [60, 34, 0.6]], ocr: { g: 'g1', t: 'the interval' } },
      { id: 's2', tool: 'pen', color: '#38bdf8', points: [[70, 31, 0.5], [140, 35, 0.6]], ocr: { g: 'g1', t: 'is the music' } }
    ],
    removed: []
  };
  const m = createMatter({ text: BODY, ink });
  return seedInkPassage(m, { id: 'p1', strokeIds: ['s1', 's2'], seed: IPAD });
}

// What each move carries in (the host's part: a spoken aside, a pinned phrase, a dictation).
const SPOKEN = {
  audio: 'voice/2026-11-14T0905.m4a',
  words: [
    { w: 'keep', t0: 0.0, t1: 0.3 },
    { w: 'the', t0: 0.3, t1: 0.4 },
    { w: 'gap', t0: 0.4, t1: 0.8 }
  ]
};
function moveOpts(n, i) {
  const seed = { device: i % 2 ? 'Mac' : 'iPhone 12 Pro Max', input: n === 8 || n === 10 || n === 12 ? 'voice' : 'touch', time: T0 + (i + 1) * 60000 };
  if (n === 8) return { seed, spoken: SPOKEN, at: 12.5 };
  return { seed };
}

test('FEAT-08: the circuit names every one of the 12 crossings exactly once, each a move from the state reached', () => {
  assert.equal(CROSSINGS.length, 12);
  assert.deepEqual([...CIRCUIT].sort((a, b) => a - b), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
  let at = 'ink';
  for (const n of CIRCUIT) {
    const c = CROSSINGS.find(x => x.n === n);
    assert.equal(c.from, at, `crossing ${n} starts where the last one ended`);
    at = c.to;
  }
  assert.equal(at, 'ink', 'the circuit returns to the seed state');
});

test('FEAT-08: one passage through all 12 crossings: same page, nothing lost, nothing duplicated, traced to seed', () => {
  const start = seededPage();
  const startFiles = Object.keys(toFiles(start));
  const startWords = wordsOf(start.text);
  let m = start;
  const seen = [];
  CIRCUIT.forEach((n, i) => {
    const before = m;
    m = cross(m, n, 'p1', moveOpts(n, i));
    const c = CROSSINGS.find(x => x.n === n);
    assert.equal(m.side.passages.p1.phase, c.to, `after crossing ${n} the passage is ${c.to}`);
    const r = checkMatter(m, { before, origin: start });
    assert.deepEqual(r.problems, [], `crossing ${n} (${c.from}→${c.to}): ${r.problems.join('; ')}`);
    // same page: no new file, the page count unchanged
    assert.deepEqual(Object.keys(toFiles(m)), startFiles, `crossing ${n} made no new file`);
    // nothing lost: every word of the start still in the body
    for (const w of startWords) assert.ok(wordsOf(m.text).includes(w), `crossing ${n} kept the word "${w}"`);
    seen.push(n);
  });
  assert.deepEqual(seen, CIRCUIT);

  // every state is present at once (the triple point) and the ink words reached the body
  const p = m.side.passages.p1;
  for (const s of ['ink', 'type', 'mark', 'voice']) assert.ok(p.forms[s], `form ${s} present`);
  assert.ok(m.text.includes('the interval is the music'));
  // the spoken aside is kept with its audio and per-word times
  assert.ok(p.forms.voice.spoken.some(e => e.audio === SPOKEN.audio && e.words.length === 3));
  // the seed is traceable from the end
  const trace = traceToSeed(m, 'p1');
  assert.deepEqual(trace[0], { cross: 0, state: 'ink', ...IPAD });
  assert.equal(trace.length, 13);
  assert.deepEqual(trace.slice(1).map(t => t.cross), CIRCUIT);

  // each crossing reverses: undo all 12, the matter is the start again (exactly)
  for (let i = 0; i < 12; i++) m = reverseLast(m);
  assert.deepEqual(m, start);
});

test('FEAT-08: the three files round-trip (matter survives a save and a reload)', () => {
  let m = seededPage();
  CIRCUIT.forEach((n, i) => { m = cross(m, n, 'p1', moveOpts(n, i)); });
  const files = toFiles(m);
  assert.deepEqual(Object.keys(files), ['draftpad.md', 'draftpad.ink.json', 'draftpad.matter.json']);
  assert.equal(files['draftpad.md'], m.text);
  const back = fromFiles(files);
  assert.deepEqual(back, m);
  // the owner's text holds no sidecar data (rule 5: markdown readable without Recense)
  assert.ok(!files['draftpad.md'].includes('p1'));
  assert.ok(!files['draftpad.md'].includes('voice/'));
  // and the reloaded matter still reverses to the seed
  let r = back;
  for (let i = 0; i < 12; i++) r = reverseLast(r);
  assert.deepEqual(r, seededPage());
});
