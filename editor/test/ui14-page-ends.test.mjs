// Derived from Spec: UI-14 (E1–E5)
// Regression guard: UI-14 — the first page made a page on a swipe and the last page was a dead end;
// a swipe deleted an empty page; a Pencil from the edge turned the page where a finger opens a wing.
import test from 'node:test';
import assert from 'node:assert/strict';
import { EditorState } from '@codemirror/state';
import {
  pageModeExtension, setPageMode, setPageIndex, attachSwipePaging, currentPage, pageCount,
  swipeLeftToRight, swipeRightToLeft, stepPage, pageEndAhead, showPage
} from '../src/pagemode.js';
import { PAGE_JOINER } from '../src/pages.js';

globalThis.matchMedia = () => ({ matches: true });   // Reduce Motion: turns are synchronous

const A = 'Friday, November 6, 2026\n\nTopic A';
const B = 'Monday, November 2, 2026\n\nTopic B';
const C = 'Sunday, November 1, 2026\n\nTopic C';

function harness(doc = [A, B, C].join(PAGE_JOINER), index = 0) {
  let state = EditorState.create({ doc, extensions: pageModeExtension() })
    .update({ effects: [setPageMode.of(true), setPageIndex.of(index)] }).state;
  const L = {};
  const scrollDOM = {
    style: {}, clientWidth: 400, scrollLeft: 0, scrollTop: 0,
    addEventListener(n, f) { (L[n] = L[n] || []).push(f); },
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 400, height: 600 })
  };
  const ends = [];
  const view = { get state() { return state; }, dispatch(s) { state = state.update(s).state; }, scrollDOM, dom: { style: {} } };
  view.__pageEnd = side => ends.push(side);
  const edges = [];
  attachSwipePaging(view, { onEdgeZone: side => edges.push(side) });
  const fire = (n, e) => (L[n] || []).forEach(f => f({ preventDefault() {}, ...e }));
  return { view, fire, ends, edges, page: () => currentPage(view.state), doc: () => view.state.doc.toString() };
}
const touchSwipe = (fire, from, to) => {
  fire('touchstart', { touches: [{ clientX: from, clientY: 100 }] });
  fire('touchmove', { touches: [{ clientX: to, clientY: 100 }] });
  fire('touchend', { changedTouches: [{ clientX: to, clientY: 100 }] });
};

test('UI-14 E1/E2: past the newest end a touch swipe shows the end card and makes nothing', () => {
  const h = harness();
  const before = h.doc();
  touchSwipe(h.fire, 100, 220);           // left-to-right at page 0
  assert.equal(h.page(), 0);
  assert.equal(h.doc(), before, 'no page made by a swipe');
  assert.deepEqual(h.ends, ['newest']);
});

test('UI-14 E2: past the oldest end the same end card appears (no dead end)', () => {
  const h = harness(undefined, 2);
  const before = h.doc();
  touchSwipe(h.fire, 220, 100);           // right-to-left at the last page
  assert.equal(h.page(), 2);
  assert.equal(h.doc(), before);
  assert.deepEqual(h.ends, ['oldest']);
});

test('UI-14 E2: the Mac host swipe and stepPage reach the same ends', () => {
  const h = harness();
  assert.equal(h.view.__hostSwipe(140, true), 'ok');
  assert.equal(h.page(), 0);
  assert.equal(stepPage(h.view, -1), false);
  showPage(h.view, 2);
  assert.equal(stepPage(h.view, 1), false);
  assert.deepEqual(h.ends, ['newest', 'newest', 'oldest']);
});

test('UI-14 E1: in the middle a swipe moves one page each way', () => {
  const h = harness(undefined, 1);
  touchSwipe(h.fire, 220, 100);
  assert.equal(h.page(), 2);
  touchSwipe(h.fire, 100, 220);
  assert.equal(h.page(), 1);
  assert.deepEqual(h.ends, []);
});

test('UI-14 pageEndAhead names the end only in the direction of travel', () => {
  const h = harness();
  assert.equal(pageEndAhead(h.view.state, -1), 'newest');
  assert.equal(pageEndAhead(h.view.state, 1), null);
  showPage(h.view, 2);
  assert.equal(pageEndAhead(h.view.state, 1), 'oldest');
  assert.equal(pageEndAhead(h.view.state, -1), null);
});

test('UI-14 E4: leaving an empty page by a swipe removes it either way; text pages are never removed', () => {
  const empty = 'Saturday, November 7, 2026';   // date only = empty (UI-06 D3)
  // older swipe off an empty middle page
  const h = harness([A, empty, C].join(PAGE_JOINER), 1);
  assert.equal(swipeRightToLeft(h.view), true);
  assert.equal(pageCount(h.view.state), 2);
  assert.equal(h.doc(), [A, C].join(PAGE_JOINER));
  // newer swipe off an empty middle page lands on the newer page
  const g = harness([A, empty, C].join(PAGE_JOINER), 1);
  assert.equal(swipeLeftToRight(g.view), true);
  assert.equal(g.page(), 0);
  assert.equal(g.doc(), [A, C].join(PAGE_JOINER));
  // an empty page at the newest end stays while you are on it
  const f = harness([empty, A].join(PAGE_JOINER), 0);
  assert.equal(swipeLeftToRight(f.view), false);
  assert.equal(pageCount(f.view.state), 2);
  // a page with text is never removed by any swipe
  const t = harness([A, B, C].join(PAGE_JOINER), 1);
  swipeRightToLeft(t.view); swipeLeftToRight(t.view); swipeLeftToRight(t.view); swipeLeftToRight(t.view);
  assert.equal(pageCount(t.view.state), 3);
});

test('UI-14 E5: a Pencil from either edge zone goes to the wing and never turns the page', () => {
  for (const [x0, x1, side] of [[5, 200, 'left'], [395, 150, 'right']]) {
    const h = harness(undefined, 1);
    h.fire('pointerdown', { pointerType: 'pen', pointerId: 1, clientX: x0, clientY: 100 });
    h.fire('pointermove', { pointerType: 'pen', pointerId: 1, clientX: x1, clientY: 100 });
    h.fire('pointerup', { pointerType: 'pen', pointerId: 1, clientX: x1, clientY: 100 });
    assert.equal(h.page(), 1, `Pencil from the ${side} edge leaves the page`);
    assert.deepEqual(h.edges, [side]);
  }
});

test('UI-14 E5: a finger from the edge zone goes to the wing the same way', () => {
  const h = harness(undefined, 1);
  touchSwipe(h.fire, 5, 200);
  assert.equal(h.page(), 1);
  assert.deepEqual(h.edges, ['left']);
});

test('UI-14 E4: a page with only ink is never removed by a swipe or by Delete page', async () => {
  const { deleteEmptyWindow } = await import('../src/pagemode.js');
  const empty = 'Saturday, November 7, 2026';
  const h = harness([A, empty, C].join(PAGE_JOINER), 1);
  h.view.__pageHasInk = i => i === 1;
  const before = h.doc();
  assert.equal(swipeRightToLeft(h.view), true, 'still moves older');
  assert.equal(h.page(), 2);
  assert.equal(h.doc(), before, 'the inked page stays');
  showPage(h.view, 1);
  assert.equal(swipeLeftToRight(h.view), true);
  assert.equal(h.doc(), before);
  assert.equal(deleteEmptyWindow(h.view, 1), false);
  assert.equal(pageCount(h.view.state), 3);
});
