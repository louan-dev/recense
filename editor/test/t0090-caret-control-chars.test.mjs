// Regression guard: T-0090 — on a page holding raw control characters (0x04, drawn by WebKit as ⌧ boxes),
// a click between them put the caret somewhere else. They must render as measured CodeMirror widgets.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createEditorState } from '../src/index.js';
import { highlightSpecialChars } from '@codemirror/view';

test('T-0090: the editor renders control characters as widgets (highlightSpecialChars)', () => {
  const src = readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
  assert.match(src, /highlightSpecialChars\(\{[^)]*render: renderControlChar/);
});

test('T-0090: the widget is a muted dot that names the character', async () => {
  const { renderControlChar } = await import('../src/index.js');
  const doc = { createElement: tag => ({ tag, attrs: {}, setAttribute(k, v) { this.attrs[k] = v; }, className: '', textContent: '' }) };
  const el = renderControlChar(4, null, '\u0004', doc);
  assert.equal(el.className, 'cm-control-char');
  assert.equal(el.textContent, '·');
  assert.equal(el.attrs.title, 'Control character U+0004');
  assert.ok(createEditorState('a\u0004b').state.doc.length === 3, 'the character stays in the file (BUG-18 A3)');
  assert.equal(typeof highlightSpecialChars, 'function');
});
