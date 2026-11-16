// Regression guard: BUG-18
import test from 'node:test';
import assert from 'node:assert/strict';
import { EditorState } from '@codemirror/state';
import { isWindowEmpty, controlCharFilter } from '../src/pages.js';

const EOT = '\x04';

// Regression guard: BUG-18
test('a page holding only control characters is empty, so swipe can delete it', () => {
  assert.equal(isWindowEmpty(`\n\n${EOT.repeat(16)}\n\n`), true);
  assert.equal(isWindowEmpty(`${EOT}\x7f\x08 \n`), true);
});

// Regression guard: BUG-18
test('a date heading plus control characters is still empty', () => {
  assert.equal(isWindowEmpty(`${EOT}${EOT}Friday, November 13, 2026${EOT}${EOT}`), true);
});

// Regression guard: BUG-18
test('real text with control characters mixed in is not empty', () => {
  assert.equal(isWindowEmpty(`${EOT}hello${EOT}`), false);
});

// Regression guard: BUG-18
test('typed or pasted control characters never reach the document; tab and newline do', () => {
  const state = EditorState.create({ doc: '', extensions: [controlCharFilter()] });
  const typed = state.update({ changes: { from: 0, insert: `a${EOT}${EOT}b\t\nc\x7f` }, userEvent: 'input.type' }).state;
  assert.equal(typed.doc.toString(), 'ab\t\nc');
  const pasted = state.update({ changes: { from: 0, insert: `${EOT}x` }, userEvent: 'input.paste' }).state;
  assert.equal(pasted.doc.toString(), 'x');
});

// Regression guard: BUG-18
test('a host load keeps the file as it is (cleanup is a separate, shown step)', () => {
  const state = EditorState.create({ doc: '', extensions: [controlCharFilter()] });
  const loaded = state.update({ changes: { from: 0, insert: `${EOT}x` } }).state;
  assert.equal(loaded.doc.toString(), `${EOT}x`);
});
