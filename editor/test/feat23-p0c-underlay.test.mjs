// Derived from Spec: FEAT-23 P0c (A1 the underlay on annotate)
// The note appears only on the first note, removes itself when emptied, re-weaves by time, and leaves no lock behind.
// Regression guard: T-0181 — a line note typed in the transcript pane reached no store (A1 rule 9).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createMediaNotes } from '../src/medianote.js';
import { DEBOUNCE_MS } from '../src/bridge.js';
import { createAudioSidecar } from '../src/audio.js';

const read = p => readFileSync(new URL(p, import.meta.url), 'utf8');
const KEY = '0123456789abcdef01234567';
const OTHER = 'fedcba9876543210fedcba98';

function fake({ ink = { version: 1, strokes: [], removed: [] } } = {}) {
  const posts = [];
  const logs = [];
  const order = [];
  let clock = 1000;
  const ed = { text: 'Draftpad page\n', ink, matter: { version: 1, passages: {}, log: [] } };
  const notes = createMediaNotes({
    getText: () => ed.text, setText: t => { order.push('setText'); ed.text = t; },
    getInk: () => ed.ink, setInk: i => { ed.ink = i; },
    getMatter: () => ed.matter, setMatter: m => { ed.matter = m; },
    flush: () => {}, resetHistory: () => {},
    unlockPages: () => { order.push('unlock'); posts.push({ channel: 'ui', body: { pagesLocked: false } }); },
    post: (channel, body) => posts.push({ channel, body }),
    now: () => clock,
    log: (name, fields) => logs.push({ name, ...fields })
  });
  return { ed, notes, posts, logs, order, tick: ms => { clock += ms; } };
}
const saves = posts => posts.filter(p => p.channel === 'note' && p.body.action === 'save');

test('FEAT-23 P0c check 1: the A1 trigger table, row by row', () => {
  assert.equal(DEBOUNCE_MS, 300, 'the save is the editor\'s debounced flush, 300 ms');
  const { ed, notes, posts, logs, tick } = fake();
  notes.open(KEY, { text: '' });
  for (const blank of [' ', '\t', '\n', ' \n\t ']) {
    ed.text = blank;
    assert.equal(notes.routeText(ed.text), true, 'taken by the note (never draftpad.md)');
  }
  assert.equal(saves(posts).length, 0, 'whitespace alone writes nothing; no empty file is made');
  tick(420);
  notes.setInput('type');
  ed.text = ' a';
  notes.routeText(ed.text);
  assert.equal(saves(posts).length, 1, 'the first character that is not whitespace writes note.md at the next flush');
  const first = logs.find(l => l.name === 'media-notes.underlay.first');
  assert.deepEqual({ key: first.key, input: first.input, ms: first.ms }, { key: KEY, input: 'type', ms: 420 });

  const d = fake();
  d.notes.open(KEY, { text: '' });
  assert.equal(d.notes.dictation('the hol', false), null, 'a partial (volatile) result writes nothing');
  assert.equal(saves(d.posts).length, 0);
  assert.equal(d.notes.dictation('the holding', true), 'the holding', 'the first final word is written');
  d.ed.text = 'the holding';
  d.notes.routeText(d.ed.text);
  assert.equal(saves(d.posts).length, 1);
  assert.equal(d.logs.find(l => l.name === 'media-notes.underlay.first').input, 'dictate');
});

test('FEAT-23 P0c check 2: emptied, then focus leaves → the host is asked to trash note.md; never before', () => {
  const { ed, notes, posts, logs } = fake();
  notes.open(KEY, { text: 'kept words\n' });
  ed.text = '  \n';
  notes.routeText(ed.text);
  assert.ok(!posts.some(p => p.body.action === 'trash'), 'empty while the caret is still there: the region stays, no timer');
  notes.dictationRunning(true);
  assert.equal(notes.blur(), 'kept', 'dictation running: not empty');
  notes.dictationRunning(false);
  assert.equal(notes.blur(), 'trashed');
  assert.deepEqual(posts.filter(p => p.body.action === 'trash').map(p => p.body), [{ action: 'trash', key: KEY }]);
  assert.equal(logs.filter(l => l.name === 'media-notes.underlay.empty').at(-1).outcome, 'trashed');
  assert.equal(notes.blur(), 'none', 'nothing left to trash');
  ed.text = 'undo brought it back';
  notes.routeText(ed.text);
  assert.equal(saves(posts).at(-1).body.text, 'undo brought it back', 'Edit › Undo brings it back at the next flush');

  const inked = fake({ ink: { version: 1, strokes: [], removed: [] } });
  inked.notes.open(KEY, { text: '', ink: { version: 1, strokes: [{ id: 's1', t: 3 }], removed: [] } });
  assert.equal(inked.notes.blur(), 'kept', 'a stroke is not empty');

  const closing = fake();
  closing.notes.open(KEY, { text: 'x' });
  closing.ed.text = '';
  closing.notes.close();
  assert.ok(closing.posts.some(p => p.body.action === 'trash'), 'the player closing or the item changing is focus leaving');
  assert.equal(closing.ed.text, 'Draftpad page\n');
});

test('FEAT-23 P0c check 3: re-weave — corrected lines change no byte of the note files; the lit line is B\'s', () => {
  const text = `a [00:05](recense://${KEY}?t=5)\nb [00:20](recense://${KEY}?t=20)\nc [01:00](recense://${KEY}?t=60)\n`;
  const ink = { version: 1, strokes: [{ id: 's1', t: 33.4 }], removed: [] };
  const matter = { version: 1, passages: { p1: { id: 'p1', seed: { device: 'iPhone', input: 'keys', time: 1, media: { key: KEY, t: 44.2 } }, forms: {} } }, log: [] };
  const { ed, notes, posts } = fake();
  notes.open(KEY, { text, ink, matter });
  const before = [ed.text, JSON.stringify(ed.ink), JSON.stringify(ed.matter)];
  const A = [{ start: 0, end: 10, text: 'one' }, { start: 10, end: 30, text: 'two' }, { start: 30, end: 90, text: 'three' }];
  const B = [{ start: 0, end: 4, text: 'one' }, { start: 4, end: 21, text: 'two' }, { start: 21, end: 50, text: 'three' }, { start: 50, end: 90, text: 'four' }];
  const wa = notes.reweave(A, 'load');
  const n = posts.length;
  const wb = notes.reweave(B, 'retranscribe');
  assert.equal(posts.length, n, 'a re-weave posts nothing');
  assert.deepEqual([ed.text, JSON.stringify(ed.ink), JSON.stringify(ed.matter)], before, 'note.md, note.ink.json, note.matter.json byte-identical');
  assert.deepEqual(wa.map(x => [x.t, x.line]), [[5, 0], [20, 1], [33.4, 2], [44.2, 2], [60, 2]]);
  assert.deepEqual(wb.map(x => [x.t, x.line]), [[5, 1], [20, 1], [33.4, 2], [44.2, 2], [60, 3]]);
  const other = fake();
  other.notes.open(KEY, { text: `[00:09](recense://${OTHER}?t=9)` });
  assert.deepEqual(other.notes.reweave(A), [], 'a link to another item is not this item\'s time');
});

test('FEAT-23 P0c check 4: BUG-31 inside the underlay — the page posts { pagesLocked: false } first when the region hides', () => {
  const { notes, posts, order } = fake();
  notes.open(KEY, { text: 'x' });
  order.length = 0;
  notes.close();
  assert.deepEqual(order.slice(0, 2), ['unlock', 'setText'], 'unlocked before the region hides');
  assert.ok(posts.some(p => p.channel === 'ui' && p.body.pagesLocked === false));
  const idx = read('../src/index.js');
  assert.ok(/unlockPages: \(\) =>/.test(idx), 'index.js gives the note its unlock');
  assert.ok(idx.includes("'media-notes.lock'"), 'a tool change in a note logs media-notes.lock');
  assert.ok(!read('../src/pagemode.js').includes('rc-transcript'), 'the page lock never reaches the transcript region');
});

test('FEAT-23 A1 rule 9 / T-0181: a pane line note and a bookmark join the note; nothing is keyed by cueId', () => {
  const { ed, notes, posts } = fake();
  assert.deepEqual(notes.lineNote(KEY, 724.8, 'compare the dissent'),
    { append: `[12:04](recense://${KEY}?t=724) compare the dissent` }, 'note not open: the host appends the line');
  assert.deepEqual(posts.at(-1), { channel: 'note', body: { action: 'append', key: KEY, line: `[12:04](recense://${KEY}?t=724) compare the dissent` } });
  assert.equal(notes.lineNote('', 3, 'x'), null, 'no item key: no note to join');
  notes.open(KEY, { text: 'mine\n' });
  const n = posts.length;
  assert.deepEqual(notes.lineNote(KEY, 5, ''), { insert: `[00:05](recense://${KEY}?t=5)` }, 'open: written into the page (a bookmark has no text)');
  assert.equal(posts.length, n, 'the open page saves it like typing');
  assert.equal(ed.text, 'mine\n');

  const seen = [];
  const sidecar = createAudioSidecar({
    cues: [{ id: 'c0', start: 12.5, end: 15, text: 'held' }, { id: 'c1', start: 16, end: 19, text: 'affirmed' }],
    onInsertToPage: () => seen.push('page'),
    onLineNote: n => { seen.push(n); return true; },
    globalObj: null
  });
  sidecar.annotateCue(0, 'key point', { lineNote: true });
  sidecar.annotateCue(0, 'key point', { lineNote: true });
  sidecar.toggleBookmarkCue(1);
  sidecar.toggleBookmarkCue(1);
  assert.deepEqual(seen, [{ start: 12.5, text: 'key point' }, { start: 16, text: '' }],
    'once per new text (Enter then blur is one note); a bookmark once; nothing went into draftpad.md\'s page');
});
