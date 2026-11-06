import test from 'node:test';
import assert from 'node:assert/strict';

import { createEditorBridge } from '../src/bridge.js';
import { createEditorState } from '../src/index.js';

function createHarness({ initialDoc = '', debounceMs = 30 } = {}) {
  let { state } = createEditorState(initialDoc);
  let theme = 'dark';
  let fontSize = 18;
  let focused = false;
  let scroll = { top: 42, left: 0 };
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
    focusView: () => {
      focused = true;
    },
    getScroll: () => ({ ...scroll }),
    setScroll: next => {
      scroll = { ...next };
    },
    setTheme: mode => {
      theme = mode;
    },
    setFontSize: px => {
      fontSize = px;
    },
    globalObj: fakeWindow,
    debounceMs
  });

  return {
    get state() {
      return state;
    },
    get theme() {
      return theme;
    },
    get fontSize() {
      return fontSize;
    },
    get focused() {
      return focused;
    },
    get scroll() {
      return scroll;
    },
    posted,
    fakeWindow,
    dispatch,
    bridge
  };
}

test('M4: window.recenseEditor exposes setText, getText, focus, setTheme, setFontSize', () => {
  const h = createHarness({ initialDoc: 'Hello' });
  const api = h.fakeWindow.recenseEditor;
  assert.ok(api);
  assert.equal(typeof api.setText, 'function');
  assert.equal(typeof api.getText, 'function');
  assert.equal(typeof api.focus, 'function');
  assert.equal(typeof api.setTheme, 'function');
  assert.equal(typeof api.setFontSize, 'function');

  assert.equal(api.getText(), 'Hello');
  api.focus();
  assert.equal(h.focused, true);
  api.setTheme('light');
  assert.equal(h.theme, 'light');
  api.setFontSize(22);
  assert.equal(h.fontSize, 22);
});

test('M4: setText(s) preserves cursor and scroll, round-trips byte-for-byte, and never posts back to host', async () => {
  const h = createHarness({ initialDoc: 'First line\nSecond line', debounceMs: 25 });
  const api = h.fakeWindow.recenseEditor;

  // Move selection to offset 15
  h.dispatch({ selection: { anchor: 15, head: 15 } });
  assert.equal(h.state.selection.main.head, 15);

  // Host sets merged text (including un-renumbered list lines that must stay untouched)
  const merged = 'First line\nSecond line updated\n\n<!-- page -->\n\n5. Unchanged numbering';
  api.setText(merged);

  assert.equal(api.getText(), merged);
  assert.equal(h.state.selection.main.head, 15);
  assert.deepEqual(h.scroll, { top: 42, left: 0 });

  await new Promise(r => setTimeout(r, 50));
  assert.equal(h.posted.length, 0, 'setText must never post back to webkit.messageHandlers.editor');
});

test('M4: user edits debounce to 300ms and post full text string to window.webkit.messageHandlers.editor', async () => {
  const h = createHarness({ initialDoc: 'Draft', debounceMs: 30 });
  const api = h.fakeWindow.recenseEditor;

  h.dispatch({ changes: { from: 5, to: 5, insert: ' 1' } });
  h.dispatch({ changes: { from: 7, to: 7, insert: '2' } });

  // Synchronous getText() immediately returns latest text before debounce completes
  assert.equal(api.getText(), 'Draft 12');
  assert.equal(h.posted.length, 0);

  await new Promise(r => setTimeout(r, 55));
  assert.equal(h.posted.length, 1);
  assert.equal(h.posted[0], 'Draft 12');
  assert.equal(typeof h.posted[0], 'string');
});
