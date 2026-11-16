// Derived from Spec: UI-06
import test from 'node:test';
import assert from 'node:assert/strict';
import { PAGE_JOINER, inspectDraftpadPages, isMetaLine } from '../src/pages.js';
import {
  currentPage,
  pageCount,
  showPage,
  goToPage,
  newPage,
  promotePage,
  setPageSlot,
  pageSlots,
  slotPage,
  reopenTarget,
  swipeRightToLeft,
  pageModeExtension
} from '../src/pagemode.js';
import { createEditorState } from '../src/index.js';

function makeFakeView(initialDoc) {
  let { state } = createEditorState(initialDoc);
  return {
    get state() { return state; },
    scrollDOM: { scrollTop: 0, clientWidth: 400, scrollTo(o) { if (o && typeof o.top === 'number') this.scrollTop = o.top; } },
    dispatch(spec) { state = state.update(spec).state; }
  };
}

const three = () => ['Page A text', 'Page B text', 'Page C text'].join(PAGE_JOINER);
const bodies = view => inspectDraftpadPages(view.state.doc.toString()).map(p => p.rawContent.trim());

test('G3: goToPage jumps straight to a page', () => {
  const view = makeFakeView(three());
  assert.equal(goToPage(view, 2), true);
  assert.equal(currentPage(view.state), 2);
  assert.equal(goToPage(view, 9), false, 'out of range bounces');
  assert.equal(currentPage(view.state), 2);
});

test('G2/visible ＋: newPage opens an empty page at the front from any page', () => {
  const view = makeFakeView(three());
  showPage(view, 2);
  assert.equal(newPage(view), true);
  assert.equal(pageCount(view.state), 4);
  assert.equal(currentPage(view.state), 0);
  assert.equal(bodies(view)[0], '');
  assert.equal(newPage(view), false, 'no second empty page while the front one is empty');
});

test('G4: promotePage moves a page to the front; only the order changes', () => {
  const view = makeFakeView(three());
  const before = view.state.doc.length;
  assert.equal(promotePage(view, 2), true);
  assert.deepEqual(bodies(view), ['Page C text', 'Page A text', 'Page B text']);
  assert.equal(view.state.doc.length, before);
  assert.equal(currentPage(view.state), 0);
  assert.equal(promotePage(view, 0), false, 'front page is already at the front');
});

test('S1/S2: a slot is a hidden line on the page, one page per slot, and it moves with the page', () => {
  const view = makeFakeView(three());
  setPageSlot(view, 1, 3);
  assert.ok(view.state.doc.toString().includes('<!-- slot 3 -->'));
  assert.ok(isMetaLine('<!-- slot 3 -->'));
  assert.deepEqual(pageSlots(view.state.doc.toString()), { 3: 1 });
  setPageSlot(view, 2, 3);
  assert.deepEqual(pageSlots(view.state.doc.toString()), { 3: 2 });
  promotePage(view, 2);
  assert.deepEqual(pageSlots(view.state.doc.toString()), { 3: 0 });
  assert.equal(slotPage(view, 3), true);
  assert.equal(currentPage(view.state), 0);
  setPageSlot(view, 0, null);
  assert.deepEqual(pageSlots(view.state.doc.toString()), {});
  assert.ok(!view.state.doc.toString().includes('<!-- slot'));
});

test('S3: a slotted page with no words is not deleted by swipe', () => {
  const view = makeFakeView(['Page A text', '', 'Page C text'].join(PAGE_JOINER));
  setPageSlot(view, 1, 2);
  showPage(view, 1);
  swipeRightToLeft(view);
  assert.equal(pageCount(view.state), 3);
});

test('G1 kept: swipe off an empty page still deletes it', () => {
  const view = makeFakeView(['Page A text', '', 'Page C text'].join(PAGE_JOINER));
  showPage(view, 1);
  swipeRightToLeft(view);
  assert.equal(pageCount(view.state), 2);
});

test('R1: reopen on the last page, found by its first line when pages shifted', () => {
  const text = ['New', 'Page A text', 'Page B text'].join(PAGE_JOINER);
  assert.equal(reopenTarget(text, { index: 1, head: 'Page B text' }), 2);
  assert.equal(reopenTarget(text, { index: 1, head: 'gone' }), 1);
  assert.equal(reopenTarget(text, { index: 7, head: 'gone' }), 2);
  assert.equal(reopenTarget(text, null), 0);
});

test('K1: no page-navigation keys are bound', () => {
  const src = pageModeExtension.toString();
  assert.ok(!src.includes("'Mod-]'") && !src.includes("'Mod-['"));
});

test('Voice: promote, slot N and new page reach their UI-06 handlers', async () => {
  const { executeVoiceMove } = await import('../src/gestures.js');
  const ran = [];
  const h = { promotePage: () => ran.push('promote'), slotPage: n => ran.push(`slot${n}`), newPage: () => ran.push('new'),
    swipeLeftToRight: () => ran.push('newer'), swipeRightToLeft: () => ran.push('older') };
  assert.equal(executeVoiceMove('promote', h).action, 'promotePage');
  assert.equal(executeVoiceMove('slot 3', h).action, 'slotPage');
  assert.equal(executeVoiceMove('trang mới', h).action, 'newPage');
  assert.equal(executeVoiceMove('newer page', h).action, 'swipeLeftToRight');
  assert.equal(executeVoiceMove('older page', h).action, 'swipeRightToLeft');
  assert.deepEqual(ran, ['promote', 'slot3', 'new', 'newer', 'older']);
});
