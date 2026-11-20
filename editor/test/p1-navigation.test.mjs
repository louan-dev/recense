import test from 'node:test';
import assert from 'node:assert/strict';
import { PAGE_JOINER, PAGE_MARKER, inspectDraftpadPages, formatDateLine } from '../src/pages.js';
import {
  hiddenRanges,
  currentPage,
  pageCount,
  showPage,
  swipeLeftToRight,
  swipeRightToLeft,
  openNewWindowOnLeft,
  deleteEmptyWindow,
  computeEffectiveDrag,
  syncPageFromScroll
} from '../src/pagemode.js';
import { createEditorState } from '../src/index.js';

function makeFakeView(initialDoc) {
  let { state } = createEditorState(initialDoc);
  const view = {
    get state() {
      return state;
    },
    scrollDOM: {
      scrollTop: 0,
      clientWidth: 400,
      scrollTo(opts) {
        if (opts && typeof opts.top === 'number') this.scrollTop = opts.top;
      }
    },
    dispatch(spec) {
      state = state.update(spec).state;
    }
  };
  return view;
}

// Amended by UI-14 (owner 2026-11-20): a swipe at window 0 shows the end card; new pages come from openNewWindowOnLeft / newPage.
test('P1 navigation: left-to-right swipe at window 0 reaches the end; an explicit new window opens on the left (top <!-- page --> block)', () => {
  const original = ['Friday, November 6, 2026\n\nTopic A', 'Monday, November 2, 2026\n\nTopic B'].join(PAGE_JOINER);
  const view = makeFakeView(original);
  const ends = [];
  view.__pageEnd = side => ends.push(side);

  assert.equal(currentPage(view.state), 0);
  assert.equal(pageCount(view.state), 2);

  // A swipe never makes a page: window 0 reports the newest end
  assert.equal(swipeLeftToRight(view), false);
  assert.deepEqual(ends, ['newest']);
  assert.equal(view.state.doc.toString(), original);

  // The explicit action (＋, menu, the end card) opens a new empty window on the left
  assert.equal(openNewWindowOnLeft(view), true);
  assert.equal(currentPage(view.state), 0);
  assert.equal(pageCount(view.state), 3);
  // UI-06 D3: the new page opens with today's date line, and an empty line for the caret before the marker
  // (Regression guard: UI-06 D3 — typed text must never join the <!-- page --> line).
  assert.equal(view.state.doc.toString(), `${formatDateLine()}\n\n${PAGE_JOINER}` + original);

  // Leaving that empty window by a swipe removes it and restores the .md file byte-for-byte (UI-14 E4)
  assert.equal(swipeRightToLeft(view), true);
  assert.equal(pageCount(view.state), 2);
  assert.equal(currentPage(view.state), 0);
  assert.equal(view.state.doc.toString(), original);
});

test('P1 navigation: 100 windows make 1 .md file, each window isolated, and round-trips byte-clean', () => {
  const view = makeFakeView('Window 1');
  for (let i = 2; i <= 100; i++) {
    assert.equal(openNewWindowOnLeft(view), true);
    const at = view.state.selection.main.head;   // UI-06 D3: under the new page's date line
    view.dispatch({
      changes: { from: at, to: at, insert: `Window ${i}` },
      selection: { anchor: at + `Window ${i}`.length }
    });
  }

  const fullMd = view.state.doc.toString();
  const pages = inspectDraftpadPages(fullMd);
  assert.equal(pages.length, 100, '100 windows in 1 .md file');
  assert.equal(fullMd.split(PAGE_MARKER).length - 1, 99, '99 <!-- page --> markers');
  assert.equal(pages[0].rawContent, `${formatDateLine()}\n\nWindow 100`, 'newest window is at the top of the .md file');
  assert.equal(pages[99].rawContent, 'Window 1', 'oldest window is at the bottom of the .md file');

  // Check isolation of window 0, window 49, and window 99
  for (const idx of [0, 49, 99]) {
    const hidden = hiddenRanges(fullMd, idx);
    let visible = '';
    let pos = 0;
    for (const r of hidden) {
      visible += fullMd.slice(pos, r.from);
      pos = r.to;
    }
    visible += fullMd.slice(pos);
    assert.equal(visible.replace(/^\n+|\n+$/g, ''), idx === 99 ? 'Window 1' : `${formatDateLine()}\n\nWindow ${100 - idx}`);
  }
});

test('P1 navigation: per-window cursor and vertical scroll stay inside each window and never cross topics', () => {
  const doc = ['Topic Zero\nLine 2\nLine 3', 'Topic One\nParagraph B', 'Topic Two\nParagraph C'].join(PAGE_JOINER);
  const view = makeFakeView(doc);

  // Move cursor inside window 0 and scroll down
  view.dispatch({ selection: { anchor: 6 } });
  view.scrollDOM.scrollTop = 180;
  assert.equal(syncPageFromScroll(view), 0, 'scrolling inside window 0 never changes currentPage');

  // Swipe right-to-left to window 1
  assert.equal(swipeRightToLeft(view), true);
  assert.equal(currentPage(view.state), 1);
  assert.equal(view.scrollDOM.scrollTop, 0, 'window 1 starts at its own scrollTop 0');

  const pages = inspectDraftpadPages(view.state.doc.toString());
  view.dispatch({ selection: { anchor: pages[1].from + 4 } });
  view.scrollDOM.scrollTop = 95;
  syncPageFromScroll(view);

  // Swipe left-to-right back to window 0: restores window 0's cursor (6) and scrollTop (180)
  assert.equal(swipeLeftToRight(view), true);
  assert.equal(currentPage(view.state), 0);
  assert.equal(view.state.selection.main.head, 6);
  assert.equal(view.scrollDOM.scrollTop, 180);

  // Swipe right-to-left back to window 1: restores window 1's cursor and scrollTop (95)
  assert.equal(swipeRightToLeft(view), true);
  assert.equal(currentPage(view.state), 1);
  assert.equal(view.state.selection.main.head, pages[1].from + 4);
  assert.equal(view.scrollDOM.scrollTop, 95);
});

test('P1 navigation: deleting an empty middle or trailing window removes its <!-- page --> block cleanly', () => {
  const doc = ['First', '   ', 'Third'].join(PAGE_JOINER);
  const view = makeFakeView(doc);

  showPage(view, 1);
  assert.equal(currentPage(view.state), 1);
  assert.equal(swipeRightToLeft(view), true, 'swiping right-to-left on empty middle window deletes it');
  assert.equal(view.state.doc.toString(), ['First', 'Third'].join(PAGE_JOINER));
  assert.equal(pageCount(view.state), 2);
  assert.equal(currentPage(view.state), 1);
});

// Amended by UI-14 E2: both ends rubber-band the same (0.25x); the middle never does.
test('P1 navigation: rubber-band effectiveDrag is the same at both ends', () => {
  const one = makeFakeView('Topic 1');
  assert.equal(computeEffectiveDrag(one.state, 80, 400), 20, 'only window: pulling newer is damped');
  assert.equal(computeEffectiveDrag(one.state, -80, 400), -20, 'only window: pulling older is damped');

  const three = makeFakeView(['A', 'B', 'C'].join(PAGE_JOINER));
  assert.equal(computeEffectiveDrag(three.state, 80, 400), 20, 'window 0: newer end damped');
  assert.equal(computeEffectiveDrag(three.state, -80, 400), -80, 'window 0: older is free');
  showPage(three, 1);
  assert.equal(computeEffectiveDrag(three.state, 80, 400), 80);
  assert.equal(computeEffectiveDrag(three.state, -80, 400), -80);
  showPage(three, 2);
  assert.equal(computeEffectiveDrag(three.state, -80, 400), -20, 'last window: older end damped');
});

test('P1 navigation: date-only window is treated as empty and deleted on right-to-left swipe, and Pencil/touchcancel work', () => {
  const datedEmpty = ['Friday, November 6, 2026\n\n', 'Monday, November 2, 2026\n\nReal body'].join(PAGE_JOINER);
  const view = makeFakeView(datedEmpty);
  assert.equal(pageCount(view.state), 2);
  assert.equal(swipeRightToLeft(view), true, 'date-only window is deleted on right-to-left swipe');
  assert.equal(pageCount(view.state), 1);
  assert.equal(view.state.doc.toString(), 'Monday, November 2, 2026\n\nReal body');
});

