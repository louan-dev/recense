import test from 'node:test';
import assert from 'node:assert/strict';
import { undo } from '@codemirror/commands';

import { createEditorState } from '../src/index.js';
import {
  renumberLegalLists,
  continueLegalOnEnter,
  shiftLegalLevelAtCursor,
  computeMinimalTextChange
} from '../src/legal.js';
import { createEditorBridge, externalSetTextAnnotation } from '../src/bridge.js';
import { getRemoved } from '../src/removed.js';

test('Review Blocker B: CRLF, lone CR, and all Draftpad cases round-trip byte-for-byte on load and setText', () => {
  const cases = {
    crlf: 'Friday, November 6, 2026\r\nhello\r\n\r\n<!-- page -->\r\n\r\nx\r\n',
    loneCR: 'a\rb',
    trailing: 'a\n\n<!-- page -->\n\nb\n',
    notrail: 'a\n\n<!-- page -->\n\nb',
    emptyLast: 'a\n\n<!-- page -->\n\n',
    list: '1. a\n3. b'
  };

  for (const [name, v] of Object.entries(cases)) {
    const { state } = createEditorState(v);
    assert.equal(state.doc.toString(), v, `${name}: load must round-trip byte-for-byte`);

    const updated = state.update({
      changes: { from: 0, to: state.doc.length, insert: v },
      annotations: externalSetTextAnnotation.of(true)
    }).state;
    assert.equal(updated.doc.toString(), v, `${name}: setText must round-trip byte-for-byte`);
  }
});

test('Review Blocker A: typing or inserting lines elsewhere never rewrites untouched lists, years, decimals, or prose', () => {
  const doc =
    '1. Facts\n\n2. Issue\n\nThe year:\n1990. Court held\n(c) of the statute applies\n1.5 hours studied\n\nnew';
  const { state } = createEditorState(doc);
  const st = state.update({
    changes: { from: doc.length, insert: '\nline' },
    userEvent: 'input'
  }).state;

  assert.equal(st.doc.toString(), `${doc}\nline`);

  // Editing inside one list never renumbers a separate list in the same document
  const twoLists = '1. First list A\n3. First list B\n\n1. Active A\n2. Active B';
  const afterEnter = continueLegalOnEnter(twoLists, twoLists.length);
  assert.equal(
    afterEnter.text,
    '1. First list A\n3. First list B\n\n1. Active A\n2. Active B\n3. '
  );
});

test('Review Blocker A: renumberLegalLists preserves Roman case, CRLF, (h)/(i)/(j) letters, and prose citations', () => {
  const unchangedCases = [
    '(I) Intro\n(II) Body',
    'Facts:\n(i) one\n(ii) two',
    '(h) eight\n(i) nine\n(j) ten',
    '1. a\r\n2. b\r\n',
    'See:\n(v) supra\n(x) infra'
  ];

  for (const s of unchangedCases) {
    assert.equal(renumberLegalLists(s), s);
  }

  // Uppercase Roman numerals stay uppercase when renumbered
  assert.equal(
    renumberLegalLists('(I) Intro\n(III) Body'),
    '(I) Intro\n(II) Body'
  );

  // CRLF list renumbers while preserving \r\n
  assert.equal(
    renumberLegalLists('1. a\r\n3. b\r\n'),
    '1. a\r\n2. b\r\n'
  );
});

test('Review Should-fix: setText does not enter undo history and flushes pending 300ms edits before replacing', async () => {
  let { state } = createEditorState('Initial');
  const posted = [];
  const fakeWindow = {
    webkit: {
      messageHandlers: {
        editor: {
          postMessage(msg) {
            posted.push(msg);
          }
        }
      }
    }
  };

  let bridge;
  function dispatch(spec) {
    const tr = state.update(spec);
    state = tr.state;
    if (tr.docChanged && bridge) {
      bridge.notifyDocChanged([tr]);
    }
  }

  bridge = createEditorBridge({
    getState: () => state,
    dispatch,
    focusView: () => {},
    getScroll: () => ({ top: 0, left: 0 }),
    setScroll: () => {},
    setTheme: () => {},
    setFontSize: () => {},
    getRemoved: () => getRemoved(state),
    globalObj: fakeWindow,
    debounceMs: 200
  });

  // User types ' typed' (pending inside the 200ms debounce window)
  dispatch({
    changes: { from: 7, to: 7, insert: ' typed' },
    userEvent: 'input.type'
  });
  assert.equal(posted.length, 0);

  // Host calls setText before the 200ms debounce expires:
  // 1) Pending edit ('Initial typed') is flushed immediately so typing is not dropped
  // 2) Document is replaced with 'Synced from iPhone'
  // 3) Undo (⌘Z) does not revert 'Synced from iPhone' back to 'Initial typed'
  fakeWindow.recenseEditor.setText('Synced from iPhone');
  assert.deepEqual(posted, ['Initial typed']);
  assert.equal(fakeWindow.recenseEditor.getText(), 'Synced from iPhone');

  // Attempt undo on state: setText used Transaction.addToHistory.of(false)
  let undoRan = false;
  undo({
    state,
    dispatch(tr) {
      undoRan = true;
      state = tr.state;
    }
  });
  assert.equal(
    state.doc.toString().includes('Initial'),
    false,
    'Undo after setText must not restore pre-setText document'
  );
  void undoRan;
});

test('Review Should-fix: Enter, Tab, and list edits compute minimal line changes instead of replacing whole document', () => {
  const header = '# Big Outline\n\nParagraph 1\n\n';
  const list = '1. First\n2. Second';
  const footer = '\n\nParagraph 2\n\n# Footer';
  const doc = `${header}${list}${footer}`;

  const enterRes = continueLegalOnEnter(doc, header.length + '1. First'.length);
  const minEnter = computeMinimalTextChange(doc, enterRes.text);
  assert.ok(minEnter.from >= header.length, 'Change starts inside list, not at 0');
  assert.ok(minEnter.to <= header.length + list.length, 'Change ends inside list, not at doc.length');

  const tabRes = shiftLegalLevelAtCursor(doc, header.length + '1. First\n2. '.length, +1);
  const minTab = computeMinimalTextChange(doc, tabRes.text);
  assert.ok(minTab.from >= header.length, 'Tab change starts inside list');
  assert.ok(minTab.to <= header.length + list.length, 'Tab change ends inside list');
});
