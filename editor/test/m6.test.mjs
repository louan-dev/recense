import test from 'node:test';
import assert from 'node:assert/strict';

import { PAGE_JOINER, inspectDraftpadPages } from '../src/pages.js';
import {
  hiddenRanges,
  pageModeField,
  setPageIndex,
  setPageMode,
  currentPage,
  stepPage,
  showPage,
  syncPageFromScroll
} from '../src/pagemode.js';
import { parseEmbedLine, embedSource, findEmbeds } from '../src/embeds.js';
import { urlAt, openURL } from '../src/links.js';
import {
  countMatches,
  findMatches,
  matchStatus,
  stepFind,
  searchHighlightField,
  openFindReplace,
  isFindReplaceOpen
} from '../src/search.js';
import { SearchQuery, setSearchQuery } from '@codemirror/search';
import { createEditorState, MENU_ACTIONS, formatPageIndicator } from '../src/index.js';
import { attachOutlineGestures } from '../src/outline.js';
import { postHaptic } from '../src/bridge.js';

const doc = ['Friday, November 6, 2026\n\nnewest', 'Monday, November 2, 2026\n\nmiddle', 'Thursday, October 8, 2026\n\nold']
  .join(PAGE_JOINER);

test('M6 pages: hidden ranges leave exactly one page visible, on whole lines', () => {
  for (let i = 0; i < 3; i++) {
    const hidden = hiddenRanges(doc, i);
    let shown = '';
    let pos = 0;
    for (const r of hidden) { shown += doc.slice(pos, r.from); pos = r.to; }
    shown += doc.slice(pos);
    const want = doc.split(PAGE_JOINER)[i];
    assert.equal(shown.replace(/^\n+|\n+$/g, ''), want, `page ${i}`);
    for (const r of hidden) {
      assert.ok(r.from === 0 || doc[r.from - 1] === '\n', 'starts at a line start');
      assert.ok(r.to === doc.length || doc[r.to] === '\n', 'ends at a line end');
    }
  }
  assert.deepEqual(hiddenRanges('one page only', 0), []);
});

test('M6 pages: page mode is on by default, page 0 is the top, and the cursor pulls the page along', () => {
  const { state } = createEditorState(doc);
  assert.equal(state.field(pageModeField).on, true);
  assert.equal(currentPage(state), 0);
  const deeper = state.update({ effects: setPageIndex.of(2) }).state;
  assert.equal(currentPage(deeper), 2);
  const back = deeper.update({ selection: { anchor: 3 } }).state;
  assert.equal(currentPage(back), 0, 'a cursor on page 0 shows page 0');
  const off = state.update({ effects: setPageMode.of(false) }).state;
  assert.equal(off.field(pageModeField).on, false);
  assert.equal(off.doc.toString(), doc, 'paging never changes the text');
});

test('E1 pages: page step lands on the next page heading in one continuous scroll with no hidden ranges', () => {
  let { state } = createEditorState(doc);
  const pages = inspectDraftpadPages(doc);

  const fakeView = {
    get state() { return state; },
    scrollDOM: { scrollTop: 0 },
    lineBlockAt(pos) {
      const lineNo = state.doc.lineAt(pos).number;
      return { top: (lineNo - 1) * 28, from: pos };
    },
    lineBlockAtHeight(y) {
      const lineNo = Math.max(1, Math.min(state.doc.lines, Math.floor(y / 28) + 1));
      const line = state.doc.line(lineNo);
      return { top: (lineNo - 1) * 28, from: line.from };
    },
    dispatch(spec) {
      state = state.update(spec).state;
    }
  };

  assert.equal(state.field(pageModeField).decos.size, 0, 'no hidden ranges in pageModeField');
  const moved1 = stepPage(fakeView, 1);
  assert.equal(moved1, true);
  assert.equal(currentPage(state), 1);
  assert.equal(state.selection.main.head, pages[1].from, 'lands on the next page date heading');
  assert.equal(state.field(pageModeField).decos.size, 0, 'still no hidden ranges after stepping');
  assert.ok(fakeView.scrollDOM.scrollTop > 0, 'glides scrollTop to page 1 heading');

  // Continuous scroll updates currentPage from the scroll position
  fakeView.scrollDOM.scrollTop = (state.doc.lineAt(pages[2].from).number - 1) * 28;
  assert.equal(syncPageFromScroll(fakeView), 2);
  assert.equal(currentPage(state), 2);

  // At the last page, stepping deeper returns false
  assert.equal(stepPage(fakeView, 1), false);
  // Stepping back glides to page 1, then page 0
  assert.equal(stepPage(fakeView, -1), true);
  assert.equal(currentPage(state), 1);
  assert.equal(showPage(fakeView, 0), 0);
  assert.equal(fakeView.scrollDOM.scrollTop, 0);
});

test('M6 embeds: only a line holding just ![](…pdf|image) embeds', () => {
  assert.deepEqual(parseEmbedLine('![paper](https://x.org/a.pdf)'), { kind: 'pdf', target: 'https://x.org/a.pdf', caption: 'paper' });
  assert.equal(parseEmbedLine('![](ink/2026-11-06.png)').kind, 'image');
  assert.equal(parseEmbedLine('see ![](a.pdf) inline'), null);
  assert.equal(parseEmbedLine('![](notes.md)'), null);
  assert.equal(findEmbeds('a\n![](b.pdf)\nc')[0].end, 'a\n![](b.pdf)'.length);
});

test('M6 embeds: inside Recense, targets go through recense-file:', () => {
  assert.equal(embedSource('https://x.org/a b.pdf', true), 'recense-file://remote/https%3A%2F%2Fx.org%2Fa%20b.pdf');
  assert.equal(embedSource('Draftpad ink/a b.png', true), 'recense-file://vault/Draftpad%20ink/a%20b.png');
  assert.equal(embedSource('https://x.org/a.pdf', false), 'https://x.org/a.pdf');
});

test('M6 links: the URL under the cursor; Markdown links give their target', () => {
  const line = '- read [the paper](https://doi.org/10.1/x) and https://arxiv.org/pdf/2408.06449.';
  assert.equal(urlAt(line, 10), 'https://doi.org/10.1/x');
  assert.equal(urlAt(line, line.length - 5), 'https://arxiv.org/pdf/2408.06449');
  assert.equal(urlAt(line, 2), null);
  const posted = [];
  assert.equal(openURL('https://a.b', { webkit: { messageHandlers: { link: { postMessage: u => posted.push(u) } } } }), true);
  assert.deepEqual(posted, ['https://a.b']);
});

test('M6 find: counts matches case-insensitively', () => {
  const { state } = createEditorState('Patent patent PATENT pat');
  assert.equal(countMatches(state, new SearchQuery({ search: 'patent' })), 3);
  assert.equal(countMatches(state, new SearchQuery({ search: '' })), 0);
});

test('E1 find: highlights every match, moves selection to match n, scrolls into view, and formats "3 of 12"', () => {
  const twelveDoc = [
    'Friday, November 6, 2026\n\nclaim one and claim two and claim three and claim four',
    'Monday, November 2, 2026\n\nclaim five and claim six and claim seven and claim eight',
    'Thursday, October 8, 2026\n\nclaim nine and claim ten and claim eleven and claim twelve'
  ].join(PAGE_JOINER);

  let { state } = createEditorState(twelveDoc);
  const effectsLog = [];
  const fakeView = {
    get state() { return state; },
    scrollDOM: { scrollTop: 0, clientHeight: 200 },
    lineBlockAt(pos) { return { top: state.doc.lineAt(pos).number * 24 }; },
    dispatch(spec) {
      const tr = state.update(spec);
      state = tr.state;
      if (spec.effects) {
        const list = Array.isArray(spec.effects) ? spec.effects : [spec.effects];
        effectsLog.push(...list);
      }
    }
  };

  const query = new SearchQuery({ search: 'claim', caseSensitive: false });
  fakeView.dispatch({ effects: setSearchQuery.of(query) });

  const all = findMatches(state, query);
  assert.equal(all.length, 12);

  // Typing word-by-word (delta = 0) selects match 1 without skipping ahead
  const m1 = stepFind(fakeView, 0);
  assert.equal(m1.label, '1 of 12');
  assert.equal(state.selection.main.from, all[0].from);
  assert.equal(state.selection.main.to, all[0].to);

  // Stepping twice (Enter / ↓ / next) lands on match 3 of 12 and scrolls it into view
  stepFind(fakeView, 1);
  const m3 = stepFind(fakeView, 1);
  assert.equal(m3.index, 3);
  assert.equal(m3.count, 12);
  assert.equal(m3.label, '3 of 12');
  assert.equal(matchStatus(state, query).label, '3 of 12');
  assert.equal(state.selection.main.from, all[2].from);
  assert.equal(state.selection.main.to, all[2].to);
  assert.ok(m3.scrollEffect, 'dispatches scrollIntoView effect');

  // Stepping to match 6 on page 1 moves currentPage to 1 and updates scrollTop
  stepFind(fakeView, 1);
  stepFind(fakeView, 1);
  const m6 = stepFind(fakeView, 1);
  assert.equal(m6.label, '6 of 12');
  assert.equal(currentPage(state), 1, 'moves to the match on another page');
  assert.ok(fakeView.scrollDOM.scrollTop > 0, 'scrolls the match into view');

  // Every match is highlighted in searchHighlightField, and match 6 has cm-searchMatch-selected
  const decos = state.field(searchHighlightField);
  const classes = [];
  decos.between(0, state.doc.length, (from, to, val) => {
    classes.push({ from, to, cls: val.spec.class });
  });
  assert.equal(classes.length, 12);
  assert.equal(classes[5].cls, 'cm-searchMatch cm-searchMatch-selected');
  assert.equal(classes[0].cls, 'cm-searchMatch');
});

test('E1 outline vs find: opening find closes the outline', () => {
  let outlineOpen = true;
  let { state } = createEditorState('# Heading\n\nBody text', {
    onOpenFind: () => {
      outlineOpen = false;
    }
  });
  const fakeView = {
    get state() { return state; },
    dispatch(spec) {
      state = state.update(spec).state;
    }
  };

  assert.equal(outlineOpen, true);
  assert.equal(isFindReplaceOpen(state), false);
  openFindReplace(fakeView);
  assert.equal(isFindReplaceOpen(state), true);
  assert.equal(outlineOpen, false, 'opening find closes the outline');
});

test('E1 lighter toolbar: menu keeps every action reachable and page indicator formats current page', () => {
  assert.deepEqual(MENU_ACTIONS, [
    'outline',
    'find',
    'newerPage',
    'olderPage',
    'pages',
    'newestFirst',
    'theme'
  ]);
  assert.equal(formatPageIndicator(0, 3), 'Page 1 of 3');
  assert.equal(formatPageIndicator(2, 3), 'Page 3 of 3');
});

test('E1 outline gestures: left-edge swipe opens outline; Esc or tap outside closes it', () => {
  const listeners = {};
  const container = {
    addEventListener(type, fn) {
      listeners[type] = fn;
    }
  };
  const insideNode = {};
  const outsideNode = {};
  const outlineEl = {
    contains(target) {
      return target === insideNode;
    }
  };

  let open = false;
  attachOutlineGestures(container, outlineEl, {
    isOpen: () => open,
    onOpen: () => { open = true; },
    onClose: () => { open = false; }
  });

  // Swipe starting away from the left edge does not summon the outline
  listeners.touchstart({ touches: [{ clientX: 90, clientY: 120 }] });
  listeners.touchend({ changedTouches: [{ clientX: 180, clientY: 125 }] });
  assert.equal(open, false);

  // Swipe in from the left edge (clientX <= 28) opens the outline
  listeners.touchstart({ touches: [{ clientX: 12, clientY: 120 }] });
  listeners.touchend({ changedTouches: [{ clientX: 80, clientY: 125 }] });
  assert.equal(open, true);

  // Tapping inside the outline keeps it open; tapping outside closes it
  listeners.pointerdown({ target: insideNode });
  assert.equal(open, true);
  listeners.pointerdown({ target: outsideNode });
  assert.equal(open, false);

  // Escape closes the outline when open
  open = true;
  listeners.keydown({ key: 'Escape', preventDefault() {} });
  assert.equal(open, false);
});

test('E1 haptics: posts { haptic: "snap" } on page step/scroll, "edge" at ends or find wrap, and "open" on outline', () => {
  const haptics = [];
  const fakeWindow = {
    webkit: {
      messageHandlers: {
        ui: {
          postMessage(msg) {
            haptics.push(msg);
          }
        }
      }
    }
  };

  let { state } = createEditorState(doc);
  const fakeView = {
    get state() { return state; },
    scrollDOM: { scrollTop: 0 },
    lineBlockAt(pos) {
      const lineNo = state.doc.lineAt(pos).number;
      return { top: (lineNo - 1) * 28, from: pos };
    },
    lineBlockAtHeight(y) {
      const lineNo = Math.max(1, Math.min(state.doc.lines, Math.floor(y / 28) + 1));
      const line = state.doc.line(lineNo);
      return { top: (lineNo - 1) * 28, from: line.from };
    },
    dispatch(spec) {
      state = state.update(spec).state;
    }
  };

  // Stepping to page 1 posts { haptic: 'snap' }
  assert.equal(stepPage(fakeView, 1, { globalObj: fakeWindow }), true);
  assert.deepEqual(haptics, [{ haptic: 'snap' }]);

  // Stepping before page 0 posts { haptic: 'edge' }
  assert.equal(stepPage(fakeView, -1, { globalObj: fakeWindow }), true);
  assert.equal(stepPage(fakeView, -1, { globalObj: fakeWindow }), false);
  assert.deepEqual(haptics, [{ haptic: 'snap' }, { haptic: 'snap' }, { haptic: 'edge' }]);

  // Find wrapping around the document posts { haptic: 'edge' }
  haptics.length = 0;
  fakeView.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: '2026' })) });
  stepFind(fakeView, 0, { globalObj: fakeWindow });
  stepFind(fakeView, 1, { globalObj: fakeWindow });
  stepFind(fakeView, 1, { globalObj: fakeWindow });
  const wrappedStep = stepFind(fakeView, 1, { globalObj: fakeWindow });
  assert.equal(wrappedStep.wrapped, true);
  assert.deepEqual(haptics, [{ haptic: 'edge' }]);

  // Opening outline posts { haptic: 'open' }
  assert.equal(postHaptic('open', fakeWindow), true);
  assert.deepEqual(haptics[haptics.length - 1], { haptic: 'open' });
});

test('M6 insertBlock: the line lands under the cursor line and posts like typing', () => {
  const { state } = createEditorState('one\ntwo');
  const line = state.doc.lineAt(1);
  const next = state.update({ changes: { from: line.to, insert: '\n![](<Draftpad ink/a.png>)' } }).state;
  assert.equal(next.doc.toString(), 'one\n![](<Draftpad ink/a.png>)\ntwo');
  assert.equal(findEmbeds(next.doc.toString())[0].target, 'Draftpad ink/a.png');
  assert.equal(findEmbeds(next.doc.toString())[0].kind, 'image');
});
