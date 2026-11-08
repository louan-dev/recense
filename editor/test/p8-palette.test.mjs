// Regression: a plain mouse drag that starts in the margin selects text; it must not turn
// (or create) a page. Option + drag, and the Pencil from the edge, still page.
import test from 'node:test';
import assert from 'node:assert/strict';
import { EditorState } from '@codemirror/state';
import { attachSwipePaging, pageModeExtension, pageCount } from '../src/pagemode.js';

function harness() {
  const listeners = {};
  let state = EditorState.create({ doc: 'Topic A\n<!-- page -->\nTopic B', extensions: [pageModeExtension()] });
  const view = {
    get state() { return state; },
    dispatch(spec) { state = state.update(spec).state; },
    scrollDOM: {
      clientWidth: 800,
      scrollTop: 0,
      scrollLeft: 0,
      style: {},
      addEventListener(name, fn) { (listeners[name] = listeners[name] || []).push(fn); },
      scrollTo() {}
    },
    contentDOM: { style: {} }
  };
  attachSwipePaging(view);
  const fire = (name, e) => (listeners[name] || []).forEach(fn => fn({ type: name, pointerId: 1, ...e }));
  const drag = (pointerType, extra = {}) => {
    fire('pointerdown', { pointerType, clientX: 10, clientY: 100, ...extra });
    fire('pointermove', { pointerType, clientX: 300, clientY: 104, ...extra });
    fire('pointerup', { pointerType, clientX: 300, clientY: 104, ...extra });
  };
  return { view, drag };
}

test('P8: mouse drag from the margin selects text, never adds a page', () => {
  const { view, drag } = harness();
  const before = pageCount(view.state);
  drag('mouse');
  assert.equal(pageCount(view.state), before);
  assert.equal(view.contentDOM.style.transform || '', '', 'the page did not slide');
});

test('P8: Option + mouse drag still pages', () => {
  const { view, drag } = harness();
  drag('mouse', { altKey: true });
  assert.notEqual(view.contentDOM.style.transform, undefined, 'the drag reached the pager');
});

import { ERASER_RADIUS, eraseWholeStrokes } from '../src/ink.js';

test('P8: the eraser ring is the reach: a stroke just inside it goes, just outside it stays', () => {
  const r = ERASER_RADIUS['eraser-whole'];
  const line = () => [{ id: 's', tool: 'pen', points: [[0, 0], [100, 0]] }];
  const inside = eraseWholeStrokes(line(), [[50, r - 0.1]], r);
  const outside = eraseWholeStrokes(line(), [[50, r + 0.1]], r);
  const left = x => x.remaining;
  assert.equal(left(inside).length, 0);
  assert.equal(left(outside).length, 1);
});

import { wheelColor, hslToHex } from '../src/ink.js';

test('P8: colour wheel: red at the top, cyan at the bottom, white in the middle', () => {
  assert.equal(hslToHex(0, 1, 0.5), '#ff0000');
  assert.equal(wheelColor(0, -80, 80), '#ff0000');
  assert.equal(wheelColor(0, 80, 80), '#00ffff');
  assert.equal(wheelColor(0, 0, 80, 1), '#ffffff');
});

import { groupHandwriting, findInkText } from '../src/ink.js';

test('P8: handwriting groups by place and time; Find reads it in any case, accents ignored', () => {
  const st = (id, x, y, at, extra = {}) => ({ id, tool: 'pen', at, points: [[x, y], [x + 30, y + 5]], ...extra });
  const groups = groupHandwriting([
    st('a', 10, 10, 1000), st('b', 50, 12, 2000),            // one word, written together
    st('c', 400, 300, 2500),                                 // far away: its own group
    st('d', 80, 14, 20000),                                  // back beside the first, 18 s later: a new group
    { id: 'h', tool: 'highlighter', at: 1, points: [[0, 0]] }, // highlighter is not handwriting
    st('e', 10, 10, 1, { ocr: { g: 'ink-x', t: 'done' } })   // already read
  ], 28);
  assert.deepEqual(groups.map(g => g.strokes.map(s => s.id)), [['a', 'b'], ['c'], ['d']]);
  const read = [
    st('a', 0, 0, 1, { ocr: { g: 'ink-a', t: 'Hợp đồng mua bán' } }),
    st('b', 0, 0, 1, { ocr: { g: 'ink-a', t: 'Hợp đồng mua bán' } }),
    st('c', 0, 0, 1, { ocr: { g: 'ink-c', t: 'Contrat de vente' } })
  ];
  assert.deepEqual(findInkText(read, 'hop dong').map(m => m.id), ['ink-a'], 'accents ignored, one hit per group');
  assert.deepEqual(findInkText(read, 'CONTRAT').map(m => m.id), ['ink-c']);
  assert.deepEqual(findInkText(read, '').length, 0);
});
