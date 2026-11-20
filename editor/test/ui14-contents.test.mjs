// Derived from Spec: UI-14 (C2–C8, Z1)
// Regression guard: UI-14 — deleting a page from the Overview must be one undoable change and never take ink.
import test from 'node:test';
import assert from 'node:assert/strict';
import { EditorState } from '@codemirror/state';
import { history, undo, redo } from '@codemirror/commands';
import { pageThumbs, filterThumbs, markHits, timedEntries, clockOf, stepCols, MIN_COLS, MAX_COLS } from '../src/contents.js';
import { pageModeExtension, setPageMode, setPageIndex, deletePage, pageCount, currentPage } from '../src/pagemode.js';
import { executeVoiceMove } from '../src/gestures.js';
import { PAGE_JOINER } from '../src/pages.js';
import { makeQuote } from '../src/matter.js';

const A = 'Friday, November 20, 2026\n\nPatent claims due\n<!-- slot 2 -->';
const B = 'Thursday, November 19, 2026\n\nLe café à Paris';
const C = 'Monday, November 2, 2026\n\nOldest notes';
const DOC = [A, B, C].join(PAGE_JOINER);

test('UI-14 C3: one thumbnail per page, numbered, date and slot read out of the text', () => {
  const t = pageThumbs(DOC);
  assert.equal(t.length, 3);
  assert.deepEqual(t.map(x => x.number), [1, 2, 3]);
  assert.equal(t[0].dateLine, 'Friday, November 20, 2026');
  assert.equal(t[0].text, 'Patent claims due');
  assert.equal(t[0].slot, 2);
  assert.equal(t[1].slot, null);
});

test('UI-14 C2/C7: search finds text any case, accents ignored, and handwriting; the filter keeps slotted pages', () => {
  const t = pageThumbs(DOC);
  assert.deepEqual(filterThumbs(t, { query: 'CAFE' }).map(x => x.index), [1]);
  assert.deepEqual(filterThumbs(t, { query: 'hello', inkText: i => (i === 2 ? 'hello world' : '') }).map(x => x.index), [2]);
  assert.deepEqual(filterThumbs(t, { filter: 'slotted' }).map(x => x.index), [0]);
  assert.equal(filterThumbs(t, { query: '' }).length, 3);
});

test('UI-14 C7: hits are marked for bold without changing the text', () => {
  const parts = markHits('Le café à Paris', 'cafe');
  assert.deepEqual(parts, [{ text: 'Le ', hit: false }, { text: 'café', hit: true }, { text: ' à Paris', hit: false }]);
  assert.equal(parts.map(p => p.text).join(''), 'Le café à Paris');
});

test('UI-14 C8: the page feed lists what was written on it with its note time, in time order', () => {
  const quote = (q) => { const off = DOC.indexOf(q); return makeQuote(DOC, off, q.length); };
  const side = { passages: {
    p2: { id: 'p2', seed: { time: '2026-11-20T09:05:00.000Z', media: { key: 'k1', t: 75.2 } }, forms: { type: quote('claims due') } },
    p1: { id: 'p1', seed: { time: '2026-11-20T09:00:00.000Z', media: { key: 'k1', t: 12 } }, forms: { type: quote('Patent') } },
    p3: { id: 'p3', seed: { time: '2026-11-19T10:00:00.000Z' }, forms: { type: quote('café') } }
  } };
  const page0 = timedEntries(DOC, side, 0);
  assert.deepEqual(page0.map(e => e.text), ['Patent', 'claims due']);
  assert.deepEqual(page0[0].media, { key: 'k1', t: 12 });
  const page1 = timedEntries(DOC, side, 1);
  assert.equal(page1.length, 1);
  assert.equal(page1[0].media, null);
  assert.equal(page1[0].at, '2026-11-19T10:00:00.000Z');
  assert.equal(page1[0].offset, DOC.indexOf('café'));
  assert.deepEqual(timedEntries(DOC, side, 2), []);
  assert.equal(clockOf(75.2), '1:15');
  assert.equal(clockOf(3725), '1:02:05');
});

test('UI-14 Z1: thumbnail columns stay between 1 and 5', () => {
  assert.equal(stepCols(MAX_COLS, 1), MAX_COLS);
  assert.equal(stepCols(MIN_COLS, -1), MIN_COLS);
  assert.equal(stepCols(2, 1), 3);
});

function view(doc, index = 0) {
  let state = EditorState.create({ doc, extensions: [pageModeExtension(), history()] })
    .update({ effects: [setPageMode.of(true), setPageIndex.of(index)] }).state;
  // dispatch takes a spec (pagemode) or a finished transaction (undo / redo)
  return { get state() { return state; }, dispatch: tr => { state = tr && tr.startState ? tr.state : state.update(tr).state; } };
}

test('UI-14 C4/C5: Delete page takes a page with text as one change; Undo brings it back byte for byte; Redo again', () => {
  const v = view(DOC, 1);
  assert.equal(deletePage(v, 1), true);
  assert.equal(pageCount(v.state), 2);
  assert.equal(v.state.doc.toString(), [A, C].join(PAGE_JOINER));
  assert.equal(undo({ state: v.state, dispatch: v.dispatch }), true);
  assert.equal(v.state.doc.toString(), DOC);
  assert.equal(redo({ state: v.state, dispatch: v.dispatch }), true);
  assert.equal(v.state.doc.toString(), [A, C].join(PAGE_JOINER));
});

test('UI-14 C4: Delete page refuses the only page and a page with ink', () => {
  const only = view(A, 0);
  assert.equal(deletePage(only, 0), false);
  const v = view(DOC, 0);
  v.__pageHasInk = i => i === 2;
  assert.equal(deletePage(v, 2), false);
  assert.equal(v.state.doc.toString(), DOC);
  assert.equal(currentPage(v.state), 0);
});

test('UI-14 C1: voice opens the Overview in English, French and Vietnamese', () => {
  for (const phrase of ['overview', 'show pages', 'aperçu', 'tổng quan']) {
    let n = 0;
    const r = executeVoiceMove(phrase, { toggleOverview: () => { n++; }, newPage: () => assert.fail('not a new page') });
    assert.equal(r.action, 'toggleOverview', phrase);
    assert.equal(n, 1);
  }
});

test('UI-14 regression: a hidden Overview or end card takes no space and no taps (display: flex must not beat [hidden])', async () => {
  const { readFileSync } = await import('node:fs');
  const css = readFileSync(new URL('../src/styles.css', import.meta.url), 'utf8');
  assert.match(css, /\.rc-cm\[hidden\],\s*\.rc-end-card\[hidden\]\s*\{\s*display:\s*none;/);
});

test('UI-14 Z2: a pinch sets the text size on 2 px steps inside 12–36', async () => {
  const { pinchFontSize } = await import('../src/theme.js');
  assert.equal(pinchFontSize(18, 1), 18);
  assert.equal(pinchFontSize(18, 1.5), 28);   // 27 → nearest even step
  assert.equal(pinchFontSize(18, 0.5), 12);   // floor
  assert.equal(pinchFontSize(30, 3), 36);     // ceiling
  assert.equal(pinchFontSize(18, NaN), 18);
});
