// Regression guard: T-0089 — a dragged page dot could only go to the front; dragging it back did nothing.
// Derived from Spec: UI-06 G4
import test from 'node:test';
import assert from 'node:assert/strict';
import { PAGE_JOINER, inspectDraftpadPages } from '../src/pages.js';
import { movePage, dropIndex, currentPage } from '../src/pagemode.js';
import { createEditorState } from '../src/index.js';

function makeFakeView(initialDoc) {
  let { state } = createEditorState(initialDoc);
  return {
    get state() { return state; },
    scrollDOM: { scrollTop: 0, clientWidth: 400, scrollTo(o) { if (o && typeof o.top === 'number') this.scrollTop = o.top; } },
    dispatch(spec) { state = state.update(spec).state; }
  };
}
const four = () => ['A', 'B', 'C', 'D'].map(x => `Page ${x}`).join(PAGE_JOINER);
const bodies = v => inspectDraftpadPages(v.state.doc.toString()).map(p => p.rawContent.trim());

test('T-0089: a page moves back (older) and the pages it passes move forward', () => {
  const v = makeFakeView(four());
  assert.equal(movePage(v, 0, 2), true);
  assert.deepEqual(bodies(v), ['Page B', 'Page C', 'Page A', 'Page D']);
  assert.equal(currentPage(v.state), 2, 'the moved page stays on screen');
});

test('T-0089: a page moves forward to a middle place, not only the front', () => {
  const v = makeFakeView(four());
  assert.equal(movePage(v, 3, 1), true);
  assert.deepEqual(bodies(v), ['Page A', 'Page D', 'Page B', 'Page C']);
});

test('T-0089: moving keeps every byte; dropping in place does nothing', () => {
  const v = makeFakeView(four());
  const before = v.state.doc.toString();
  assert.equal(movePage(v, 1, 1), false);
  movePage(v, 1, 3); movePage(v, 3, 1);
  assert.equal(v.state.doc.toString(), before);
});

test('T-0089: dropIndex counts the dot centres the pointer passed, either way', () => {
  const c = [10, 30, 50, 70];
  assert.equal(dropIndex(c, 0, 55), 2, 'first dot dragged past two others');
  assert.equal(dropIndex(c, 3, 25), 1, 'last dot dragged left past two');
  assert.equal(dropIndex(c, 2, 0), 0, 'to the front');
  assert.equal(dropIndex(c, 1, 99), 3, 'to the back');
  assert.equal(dropIndex(c, 1, 32), 1, 'barely moved: stays');
});
