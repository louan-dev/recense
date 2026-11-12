import test from 'node:test';
import assert from 'node:assert/strict';
import { EditorSelection } from '@codemirror/state';
import { createEditorState } from '../src/index.js';
import { legalNumberingExtension } from '../src/legal.js';

// T-0001: Enter on a list line ignored a non-empty selection (double-tap selects a word on a phone),
// so the selected text stayed and the break landed at the selection's head.
function runEnter(doc, anchor, head) {
  let { state } = createEditorState(doc);
  state = state.update({ selection: EditorSelection.single(anchor, head) }).state;
  const view = {
    get state() { return state; },
    dispatch(spec) { state = state.update(spec).state; }
  };
  const ext = legalNumberingExtension();
  const km = ext.flat(Infinity).find(e => e && e.value && Array.isArray(e.value) && e.value.some(k => k.key === 'Enter'));
  const enter = km.value.find(k => k.key === 'Enter');
  const handled = enter.run(view);
  return { handled, text: state.doc.toString() };
}

test('T-0001: Enter replaces the selected text on a list line', () => {
  const r = runEnter('1. Offer terms', 9, 14); // "terms" selected
  assert.equal(r.handled, true);
  assert.equal(r.text, '1. Offer \n2. ');
});
