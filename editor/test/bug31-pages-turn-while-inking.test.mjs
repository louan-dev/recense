// Derived from Spec: BUG-31
// Regression guard: BUG-31 — while an ink tool is chosen, wheel/touch/pointer/host swipes do not turn the page.
import test from 'node:test';
import assert from 'node:assert/strict';
import { EditorState } from '@codemirror/state';
import { pageModeExtension, setPageMode, setPageIndex, attachSwipePaging, currentPage, setPagesLocked, stepPage } from '../src/pagemode.js';
import { toolLocksPages, PALETTE_TOOLS, INK_TOOLS } from '../src/ink.js';
import { PAGE_JOINER } from '../src/pages.js';

// Reduce Motion path: the page turns synchronously (no glide timers) so the test can read it.
globalThis.matchMedia = () => ({ matches: true });
const text = ['Friday, November 6, 2026\n\nTopic A', 'Monday, November 2, 2026\n\nTopic B'].join(PAGE_JOINER);

function harness() {
  let state = EditorState.create({ doc: text, extensions: pageModeExtension() })
    .update({ effects: [setPageMode.of(true), setPageIndex.of(0)] }).state;
  const L = {};
  const scrollDOM = {
    style: {}, clientWidth: 400, scrollLeft: 0, scrollTop: 0,
    addEventListener(n, f) { (L[n] = L[n] || []).push(f); },
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 400, height: 600 })
  };
  const view = { get state() { return state; }, dispatch(s) { state = state.update(s).state; }, scrollDOM, dom: { style: {} } };
  attachSwipePaging(view);
  const fire = (n, e) => (L[n] || []).forEach(f => f({ preventDefault() {}, ...e }));
  return { view, fire, page: () => currentPage(view.state) };
}
const swipeTouch = fire => {
  fire('touchstart', { touches: [{ clientX: 200, clientY: 100 }] });
  fire('touchmove', { touches: [{ clientX: 100, clientY: 100 }] });
  fire('touchend', { changedTouches: [{ clientX: 100, clientY: 100 }] });
};

test('BUG-31: unlocked, a touch swipe and a host swipe turn the page', () => {
  const h = harness();
  swipeTouch(h.fire);
  assert.equal(h.page(), 1);
  const g = harness();
  assert.equal(g.view.__hostSwipe(-120, true), 'ok');
  assert.equal(g.page(), 1);
});

test('BUG-31: locked, touch, host swipe, wheel and Pencil edge drag leave the page', () => {
  const h = harness();
  setPagesLocked(h.view, true);
  swipeTouch(h.fire);
  assert.equal(h.page(), 0);
  assert.equal(h.view.__hostSwipe(-120, false), 'off');
  assert.equal(h.view.__hostSwipe(-120, true), 'off');
  h.fire('wheel', { deltaX: 200, deltaY: 0 });
  assert.equal(h.page(), 0);
  h.fire('pointerdown', { pointerType: 'pen', pointerId: 1, clientX: 5, clientY: 100 });
  h.fire('pointermove', { pointerType: 'pen', pointerId: 1, clientX: -120, clientY: 100 });
  h.fire('pointerup', { pointerType: 'pen', pointerId: 1, clientX: -120, clientY: 100 });
  assert.equal(h.page(), 0);
});

test('BUG-31: a visible control (the page bar calls stepPage) still turns the page while locked', () => {
  const h = harness();
  setPagesLocked(h.view, true);
  stepPage(h.view, 1, { allowCreate: false });
  assert.equal(h.page(), 1);
});

test('BUG-31: unlocking restores swiping', () => {
  const h = harness();
  setPagesLocked(h.view, true);
  setPagesLocked(h.view, false);
  swipeTouch(h.fire);
  assert.equal(h.page(), 1);
});

test('BUG-31: every drawing tool locks the pages; select (text) does not', () => {
  for (const t of [...INK_TOOLS, ...PALETTE_TOOLS.filter(t => t !== 'select')]) assert.equal(toolLocksPages(t), true, t);
  assert.equal(toolLocksPages('select'), false);
  assert.equal(toolLocksPages(undefined), false);
});
